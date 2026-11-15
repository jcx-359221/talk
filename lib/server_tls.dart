import 'dart:convert';
import 'dart:io';

import 'package:basic_utils/basic_utils.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';

import 'secure_cache.dart';

const _serverTlsIdentityKey = 'direct-host-tls-identity';

class ServerUnavailableException implements Exception {
  const ServerUnavailableException();
}

String serverConnectionErrorMessage(Object error) =>
    error is ServerUnavailableException || error is SocketException
        ? '服务器未启动，请联系管理员启动后重试。'
        : '无法连接服务器，请稍后重试。';

class ServerTlsIdentity {
  const ServerTlsIdentity({
    required this.certificate,
    required this.privateKey,
    required this.fingerprint,
  });

  final List<int> certificate;
  final List<int> privateKey;
  final String fingerprint;
}

Future<ServerTlsIdentity> loadOrCreateServerTlsIdentity(
  InviteHostStore cache,
) async {
  final stored = cache.value(_serverTlsIdentityKey) as String?;
  if (stored != null) {
    final decoded = jsonDecode(stored);
    if (decoded is! Map ||
        decoded['certificate'] is! String ||
        decoded['private_key'] is! String) {
      throw const FormatException('Saved TLS identity is invalid.');
    }
    return _serverTlsIdentity(
      decoded['certificate'] as String,
      decoded['private_key'] as String,
    );
  }

  final keyPair = CryptoUtils.generateRSAKeyPair(keySize: 2048);
  final privateKey = keyPair.privateKey as RSAPrivateKey;
  final publicKey = keyPair.publicKey as RSAPublicKey;
  const subject = {'CN': 'Consent Chat Server'};
  final request = X509Utils.generateRsaCsrPem(
    subject,
    privateKey,
    publicKey,
    san: const ['localhost'],
  );
  final certificate = X509Utils.generateSelfSignedCertificate(
    privateKey,
    request,
    3650,
    sans: const ['localhost'],
    extKeyUsage: const [ExtendedKeyUsage.SERVER_AUTH],
  );
  final encodedPrivateKey = CryptoUtils.encodeRSAPrivateKeyToPem(privateKey);
  await cache.putValue(
    _serverTlsIdentityKey,
    jsonEncode({
      'certificate': certificate,
      'private_key': encodedPrivateKey,
    }),
  );
  return _serverTlsIdentity(certificate, encodedPrivateKey);
}

ServerTlsIdentity _serverTlsIdentity(
  String certificate,
  String privateKey,
) {
  final certificateBytes = utf8.encode(certificate);
  final privateKeyBytes = utf8.encode(privateKey);
  SecurityContext(withTrustedRoots: false)
    ..useCertificateChainBytes(certificateBytes)
    ..usePrivateKeyBytes(privateKeyBytes);
  final der = CryptoUtils.getBytesFromPEMString(certificate);
  return ServerTlsIdentity(
    certificate: certificateBytes,
    privateKey: privateKeyBytes,
    fingerprint: sha256.convert(der).toString(),
  );
}

String formatCertificateFingerprint(String fingerprint) {
  final bytes = RegExp('.{2}').allMatches(fingerprint.toUpperCase());
  return bytes.map((match) => match.group(0)!).join(':');
}

String _pinKey(Uri serverUri) =>
    'direct-server-tls-pin:${serverUri.host}:${serverUri.port}';

String serverCertificatePinCacheKey(Uri serverUri) => _pinKey(serverUri);

Future<void> clearServerCertificatePin(
  Uri serverUri,
  SecureCache cache,
) =>
    cache.deleteValue(_pinKey(serverUri));

Future<String> ensureServerCertificatePinned(
  BuildContext context,
  Uri serverUri,
  SecureCache cache, {
  bool confirmOnFirstUse = true,
}) async {
  final expectedFingerprint = cache.text(_pinKey(serverUri));
  final httpClient = HttpClient(
    context: SecurityContext(withTrustedRoots: false),
  )..connectionTimeout = const Duration(seconds: 12);
  String? observedFingerprint;
  int? healthStatus;
  Object? connectionError;
  httpClient.badCertificateCallback = (certificate, host, port) {
    final fingerprint = sha256.convert(certificate.der).toString();
    observedFingerprint = fingerprint;
    if (expectedFingerprint != null) {
      return fingerprint == expectedFingerprint;
    }
    return true;
  };

  try {
    final request = await httpClient.getUrl(serverUri.resolve('/health'));
    final response = await request.close().timeout(
          const Duration(seconds: 20),
        );
    await response.drain<void>();
    healthStatus = response.statusCode;
  } catch (error) {
    connectionError = error;
  } finally {
    httpClient.close(force: true);
  }

  final fingerprint = observedFingerprint;
  if (fingerprint == null) {
    throw const ServerUnavailableException();
  }
  if (expectedFingerprint != null && fingerprint == expectedFingerprint) {
    if (connectionError != null) {
      throw const ServerUnavailableException();
    }
    if (healthStatus != HttpStatus.ok) {
      throw HttpException(
        '服务器健康检查返回 HTTP $healthStatus。',
        uri: serverUri,
      );
    }
    return expectedFingerprint;
  }
  if (!confirmOnFirstUse) {
    if (expectedFingerprint != null) {
      throw const HttpException('服务器身份验证失败。');
    }
    if (connectionError != null) {
      throw const ServerUnavailableException();
    }
    if (healthStatus != HttpStatus.ok) {
      throw HttpException(
        '服务器健康检查返回 HTTP $healthStatus。',
        uri: serverUri,
      );
    }
    await cache.putText(_pinKey(serverUri), fingerprint);
    return fingerprint;
  }
  if (!context.mounted) {
    throw StateError('连接界面已关闭，无法确认服务器证书。');
  }

  if (connectionError == null && healthStatus != HttpStatus.ok) {
    throw HttpException(
      '服务器健康检查返回 HTTP $healthStatus。',
      uri: serverUri,
    );
  }
  if (connectionError != null &&
      (expectedFingerprint == null || fingerprint == expectedFingerprint)) {
    throw const ServerUnavailableException();
  }

  final trusted = await _confirmServerFingerprint(
    context,
    fingerprint,
    previousFingerprint: expectedFingerprint,
  );
  if (!trusted) throw const HttpException('已取消服务器证书验证。');
  await cache.putText(_pinKey(serverUri), fingerprint);
  return fingerprint;
}

Future<bool> _confirmServerFingerprint(
  BuildContext context,
  String fingerprint, {
  String? previousFingerprint,
}) async {
  return await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(
            previousFingerprint == null ? '首次验证服务器证书' : '服务器证书已更换',
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                previousFingerprint == null
                    ? '请将下方指纹与电脑服务器窗口中的 TLS 指纹逐字比对。'
                        '只有一致时才继续；否则取消连接。'
                    : '证书与上次固定的证书不同。请确认电脑端已重新生成证书，'
                        '并与电脑窗口中的新指纹逐字比对；不一致时请取消。',
              ),
              if (previousFingerprint != null) ...[
                const SizedBox(height: 12),
                const Text('之前的指纹：'),
                SelectableText(
                    formatCertificateFingerprint(previousFingerprint)),
              ],
              const SizedBox(height: 12),
              const Text('当前服务器指纹：'),
              SelectableText(
                formatCertificateFingerprint(fingerprint),
                style: Theme.of(dialogContext).textTheme.bodySmall,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('指纹核对一致，信任'),
            ),
          ],
        ),
      ) ??
      false;
}

HttpClient createPinnedHttpClient(String fingerprint) => HttpClient(
      context: SecurityContext(withTrustedRoots: false),
    )
      ..connectionTimeout = const Duration(seconds: 12)
      ..badCertificateCallback = (certificate, host, port) =>
          sha256.convert(certificate.der).toString() == fingerprint;
