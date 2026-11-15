import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:uuid/uuid.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'app_config.dart';
import 'app_log.dart';
import 'client_apk_builder.dart';
import 'direct_chat.dart';
import 'message_crypto.dart';
import 'server_tls.dart';
import 'secure_cache.dart';

const _uuid = Uuid();

String _encryptMediaChunk(Map<String, Object?> arguments) =>
    DailyInviteCipher(arguments['code'] as String)
        .encrypt(base64Encode(arguments['bytes'] as List<int>));

String _decryptMediaChunk(Map<String, Object?> arguments) =>
    DailyInviteCipher(arguments['code'] as String)
        .decrypt(arguments['ciphertext'] as String);

String _pendingAttachmentExtension(String fileName) {
  final normalizedName = fileName.replaceAll('\\', '/').split('/').last;
  final dot = normalizedName.lastIndexOf('.');
  if (dot <= 0) return '.attachment';
  final extension = normalizedName.substring(dot).toLowerCase();
  return RegExp(r'^\.[a-z0-9]{1,12}$').hasMatch(extension)
      ? extension
      : '.attachment';
}

class InviteHostController extends ChangeNotifier {
  InviteHostController(this._cache, {Directory? mediaDirectory})
      : _providedMediaDirectory = mediaDirectory;

  static const _allowedIpsKey = 'direct-host-allowed-ips';
  static const _registeredClientsKey = 'direct-host-clients';
  static const _availableInviteCodesKey = 'direct-host-available-invite-codes';
  static const _invalidInviteCodesKey = 'direct-host-invalid-invite-codes';
  static const _inviteCodeCreatedAtKey = 'direct-host-invite-code-created-at';
  static const _messagesKey = 'direct-host-messages';
  static const _mediaKey = 'direct-host-media';
  static const _localMediaPathsKey = 'direct-host-local-media-paths';
  final InviteHostStore _cache;
  final Directory? _providedMediaDirectory;
  Directory? _mediaRoot;
  HttpServer? _server;
  final Map<String, InviteClientRequest> _clients = {};
  final Set<String> _allowedIps = {};
  final Map<String, Map<String, dynamic>> _registeredClients = {};
  final Set<String> _availableInviteCodes = {};
  final Set<String> _invalidInviteCodes = {};
  final Map<String, String> _inviteCodeCreatedAt = {};
  final List<Map<String, dynamic>> _messages = [];
  final Map<String, Map<String, dynamic>> _media = {};
  final Map<String, String> _localMediaPaths = {};
  final Map<String, Map<String, dynamic>> _uploads = {};
  final Map<String, List<DateTime>> _failedAttempts = {};
  String? _inviteCode;
  String? _certificateFingerprint;
  String? _error;
  bool _disposed = false;
  bool _savedStateLoaded = false;

  bool get isRunning => _server != null;
  int get port => _server?.port ?? 8443;
  String? get adminCodeForDisplay => _inviteCode;
  String? get error => _error;
  String? get certificateFingerprint => _certificateFingerprint;
  List<InviteClientRequest> get clients => _clients.values.toList()
    ..sort((left, right) => right.lastSeen.compareTo(left.lastSeen));
  Set<String> get allowedIps => Set.unmodifiable(_allowedIps);
  String? avatarForClient(String clientId) =>
      _registeredClients[clientId]?['avatar_data'] as String?;
  String? serverAvatarForClient(String clientId) =>
      _registeredClients[clientId]?['server_avatar_data'] as String?;
  String? deviceIdentityForClient(String clientId) =>
      _registeredClients[clientId]?['device_identity'] as String?;
  List<Map<String, dynamic>> get registeredClients =>
      _registeredClients.values.map((client) {
        final details = Map<String, dynamic>.from(client)
          ..remove('device_identity')
          ..remove('token');
        return details;
      }).toList()
        ..sort(
          (left, right) => (right['last_seen'] as String).compareTo(
            left['last_seen'] as String,
          ),
        );
  List<Map<String, dynamic>> get inviteCodes {
    final entries = <String, Map<String, dynamic>>{
      for (final code in _availableInviteCodes)
        code: {
          'code': code,
          'status': '可用',
          'created_at': _inviteCodeCreatedAt[code],
        },
    };
    for (final client in _registeredClients.values) {
      final code = client['invite_code'];
      if (code is! String || code.isEmpty) continue;
      entries.putIfAbsent(code, () {
        final revoked =
            client['revoked'] == true || _invalidInviteCodes.contains(code);
        return {
          'code': code,
          'status': revoked ? '已失效' : '已绑定',
          'client_id': client['client_id'],
          'client_name': client['client_name'],
          'device_name': client['device_name'] ?? client['client_name'],
          'remark': client['remark'],
          'ip': client['ip'],
          'revoked': revoked,
          'created_at': client['created_at'],
          'last_seen': client['last_seen'],
          'last_chat_at': _lastChatAt(client['client_id'] as String?),
        };
      });
    }

    for (final code in _invalidInviteCodes) {
      entries.putIfAbsent(
        code,
        () => {
          'code': code,
          'status': '已失效',
          'created_at': _inviteCodeCreatedAt[code],
        },
      );
    }
    return entries.values.toList()
      ..sort((left, right) => (left['code'] as String).compareTo(
            right['code'] as String,
          ));
  }

  List<Map<String, dynamic>> messagesFor(
    String clientId, {
    bool includeExpired = false,
  }) =>
      _messages
          .where(
            (message) =>
                message['client_id'] == clientId &&
                (includeExpired || isDirectMessageVisible(message)),
          )
          .map((message) => Map<String, dynamic>.from(message))
          .toList()
        ..sort(compareDirectMessages);

  String? localMediaPathForMessage(String clientId, String messageId) =>
      _localMediaPaths['$clientId:$messageId'];

  Future<void> rememberLocalMediaPath(
    String clientId,
    String messageId,
    String filePath,
  ) async {
    _localMediaPaths['$clientId:$messageId'] = filePath;
    await _saveLocalMediaPaths();
    _notify();
  }

  Future<void> forgetLocalMediaPath(String clientId, String messageId) async {
    _localMediaPaths.remove('$clientId:$messageId');
    await _saveLocalMediaPaths();
    _notify();
  }

  Future<void> savePendingMediaMessage(Map<String, dynamic> message) async {
    final messageId = message['id']?.toString();
    final clientId = message['client_id']?.toString();
    if (messageId == null ||
        clientId == null ||
        message['pending'] != true ||
        messageId.isEmpty) {
      throw ArgumentError('Invalid pending attachment message.');
    }
    _messages.removeWhere(
      (item) =>
          item['client_id'] == clientId && item['id'].toString() == messageId,
    );
    _messages.add(Map<String, dynamic>.from(message));
    await _cache.putMapList(_messagesKey, _messages);
    _notify();
  }

  Future<void> updatePendingMediaMessage(
    String clientId,
    String messageId,
    Map<String, Object?> updates, {
    bool persist = true,
  }) async {
    final message = _messages
        .where((item) =>
            item['client_id'] == clientId &&
            item['id'].toString() == messageId &&
            item['pending'] == true)
        .firstOrNull;
    if (message == null) return;
    message.addAll(updates);
    if (persist) await _cache.putMapList(_messagesKey, _messages);
    _notify();
  }

  Future<void> deleteMessages(
    String clientId,
    Iterable<String> messageIds,
  ) async {
    if (!_registeredClients.containsKey(clientId)) {
      throw StateError('Unknown client.');
    }
    final ids = messageIds.toSet();
    if (ids.isEmpty || ids.length > 500 || ids.any((id) => id.isEmpty)) {
      throw ArgumentError('Select between 1 and 500 messages to delete.');
    }
    final abandonedUploads = _uploads.entries
        .where(
          (entry) =>
              entry.value['client_id'] == clientId &&
              ids.contains(entry.value['message_id']?.toString()),
        )
        .toList();
    for (final entry in abandonedUploads) {
      _uploads.remove(entry.key);
      final directory = Directory(entry.value['directory'] as String);
      if (await directory.exists()) await directory.delete(recursive: true);
    }
    final removed = _messages
        .where(
          (message) =>
              message['client_id'] == clientId &&
              ids.contains(message['id']?.toString()),
        )
        .toList();
    if (removed.isEmpty && abandonedUploads.isEmpty) return;
    _messages.removeWhere(
      (message) =>
          message['client_id'] == clientId &&
          ids.contains(message['id']?.toString()),
    );
    _localMediaPaths.removeWhere(
      (key, _) =>
          key.startsWith('$clientId:') &&
          ids.contains(key.substring(clientId.length + 1)),
    );
    final referencedMediaIds = _messages
        .map((message) => message['media_id'])
        .whereType<String>()
        .toSet();
    final orphanedMediaIds = _media.keys
        .where(
          (mediaId) =>
              _media[mediaId]?['client_id'] == clientId &&
              !referencedMediaIds.contains(mediaId),
        )
        .toList();
    for (final mediaId in orphanedMediaIds) {
      _media.remove(mediaId);
      final mediaDirectory = await _getMediaDirectory(mediaId);
      if (await mediaDirectory.exists()) {
        await mediaDirectory.delete(recursive: true);
      }
    }
    await _cache.putMapList(_messagesKey, _messages);
    await _cache.putMapList(_mediaKey, _media.values.toList());
    await _saveLocalMediaPaths();
    AppLogger.log('message.deleted', details: {'count': removed.length});
    _notify();
  }

  Map<String, dynamic>? mediaForMessage(Map<String, dynamic> message) {
    final id = message['media_id'];
    if (id is! String) return null;
    final media = _media[id];
    return media == null ? null : Map<String, dynamic>.from(media);
  }

  Future<String> downloadMediaToFile(
    Map<String, dynamic> message, {
    ValueChanged<int>? onProgress,
    bool Function()? isCancelled,
  }) async {
    final mediaId = message['media_id'] as String?;
    if (mediaId == null) throw StateError('Attachment is unavailable.');
    final media = _media[mediaId];
    if (media == null) throw StateError('Attachment is unavailable.');
    final client = _registeredClients[media['client_id']];
    if (client == null) throw StateError('Attachment owner is unavailable.');
    final directory = await directCacheDirectory(
      'server-downloads',
      segments: [media['client_id'] as String, mediaId],
    );
    final safeName = (media['file_name'] as String).replaceAll(
      RegExp(r'[^A-Za-z0-9._-]'),
      '_',
    );
    final path = '${directory.path}${Platform.pathSeparator}$safeName';
    final existingFile = File(path);
    final partialFile = File('$path.partial');
    final chunkCount = media['chunk_count'] as int;
    final expectedSize = media['size'] as int;
    final resumeIndex = await prepareDirectPartialDownload(
      outputFile: existingFile,
      partialFile: partialFile,
      chunkCount: chunkCount,
      expectedSize: expectedSize,
    );
    if (resumeIndex == chunkCount) {
      onProgress?.call(100);
      return path;
    }
    final output = partialFile.openWrite(mode: FileMode.append);
    try {
      onProgress?.call((resumeIndex * 100 ~/ chunkCount).clamp(0, 100));
      for (var index = resumeIndex; index < chunkCount; index++) {
        if (isCancelled?.call() == true) {
          throw const DirectDownloadCancelled();
        }
        final mediaDirectory = await _getMediaDirectory(mediaId);
        final chunkFile = File(
          '${mediaDirectory.path}${Platform.pathSeparator}$index.chunk',
        );
        final bytes = media['encrypted'] == false
            ? await chunkFile.readAsBytes()
            : base64Decode(await compute(_decryptMediaChunk, {
                'code': client['invite_code'] as String,
                'ciphertext': await chunkFile.readAsString(),
              }));
        if (isCancelled?.call() == true) {
          throw const DirectDownloadCancelled();
        }
        output.add(bytes);
        await output.flush();
        onProgress?.call(
          ((index + 1) * 100 ~/ chunkCount).clamp(0, 100),
        );
      }
      if (isCancelled?.call() == true) {
        throw const DirectDownloadCancelled();
      }
      await output.flush();
      await output.close();
      await finishDirectPartialDownload(
        outputFile: existingFile,
        partialFile: partialFile,
        expectedSize: expectedSize,
      );
      return path;
    } catch (_) {
      await output.close();
      rethrow;
    } finally {
      await output.close();
    }
  }

  Future<Directory> _getMediaRoot() async {
    final existing = _mediaRoot;
    if (existing != null) return existing;
    final directory =
        _providedMediaDirectory ?? await directCacheDirectory('server-media');
    await directory.create(recursive: true);
    await for (final entity in directory.list()) {
      if (entity is Directory &&
          entity.path
              .split(Platform.pathSeparator)
              .last
              .startsWith('upload-')) {
        await entity.delete(recursive: true);
      }
    }
    _mediaRoot = directory;
    return directory;
  }

  Future<Directory> _getMediaDirectory(String mediaId) async {
    final currentRoot = await _getMediaRoot();
    final current = Directory(
      '${currentRoot.path}${Platform.pathSeparator}$mediaId',
    );
    if (await current.exists() || _providedMediaDirectory != null) {
      return current;
    }
    final support = await getApplicationSupportDirectory();
    final legacy = Directory(
      '${support.path}${Platform.pathSeparator}consent-chat-media'
      '${Platform.pathSeparator}$mediaId',
    );
    return await legacy.exists() ? legacy : current;
  }

  Future<String?> _generateUploadPreview(
    Map<String, dynamic> upload,
    Map<String, dynamic> client,
  ) async {
    final mimeType = upload['mime_type'] as String? ?? '';
    if (!Platform.isWindows ||
        !mimeType.startsWith('video/') ||
        upload['chunk_count'] is! int ||
        (upload['chunk_count'] as int) <= 0) {
      return null;
    }
    Directory? temporaryDirectory;
    IOSink? output;
    try {
      final previewRoot = await directCacheDirectory('preview-temp');
      temporaryDirectory =
          await previewRoot.createTemp('consent-chat-preview-');
      final extension =
          _pendingAttachmentExtension(upload['file_name'] as String);
      final videoFile = File(
        '${temporaryDirectory.path}${Platform.pathSeparator}video$extension',
      );
      output = videoFile.openWrite();
      final uploadDirectory = upload['directory'] as String;
      for (var index = 0; index < (upload['chunk_count'] as int); index++) {
        final chunkFile = File(
          '$uploadDirectory${Platform.pathSeparator}$index.chunk',
        );
        final bytes = upload['encrypted'] == false
            ? await chunkFile.readAsBytes()
            : base64Decode(await compute(_decryptMediaChunk, {
                'code': client['invite_code'] as String,
                'ciphertext': await chunkFile.readAsString(),
              }));
        output.add(bytes);
      }
      await output.flush();
      await output.close();
      output = null;
      return await createDirectMediaPreview(
        filePath: videoFile.path,
        mimeType: mimeType,
      );
    } catch (error, stackTrace) {
      AppLogger.log(
        'server.video_preview_generation_failed',
        level: 'warning',
        details: {'mime_type': mimeType},
        error: error,
        stackTrace: stackTrace,
      );
      return null;
    } finally {
      try {
        await output?.close();
        if (temporaryDirectory != null && await temporaryDirectory.exists()) {
          await temporaryDirectory.delete(recursive: true);
        }
      } on FileSystemException catch (error, stackTrace) {
        AppLogger.log(
          'server.video_preview_temp_cleanup_failed',
          level: 'warning',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> start({
    required int port,
    required String code,
    required List<int> certificate,
    required List<int> privateKey,
    required String certificateFingerprint,
    InternetAddress? bindAddress,
  }) async {
    AppLogger.log('server.start_requested', details: {'port': port});
    await _loadSavedState();
    if (_server != null) {
      throw StateError('The invite server is already running.');
    }
    final normalizedCode = code.trim();
    if (normalizedCode.length < 8 || normalizedCode.length > 256) {
      throw ArgumentError('The invite code must be 8 to 256 characters.');
    }
    if (port < 1024 || port > 65535) {
      throw ArgumentError('Use a port from 1024 to 65535.');
    }
    final securityContext = SecurityContext(withTrustedRoots: false)
      ..useCertificateChainBytes(certificate)
      ..usePrivateKeyBytes(privateKey);
    _certificateFingerprint = certificateFingerprint;
    final server = await HttpServer.bindSecure(
      bindAddress ?? InternetAddress.anyIPv4,
      port,
      securityContext,
      shared: true,
    );
    if (Platform.isAndroid) {
      try {
        await WakelockPlus.enable();
      } catch (error) {
        await server.close(force: true);
        throw StateError('Could not keep the server phone awake: $error');
      }
    }
    _inviteCode = normalizedCode;
    _error = null;
    _server = server;
    AppLogger.log('server.started', details: {'port': server.port});
    server.listen(
      (request) {
        unawaited(_handleRequestSafely(request));
      },
      onError: (Object error) {
        _error = 'Server socket error: $error';
        AppLogger.log(
          'server.socket_error',
          level: 'error',
          error: error,
        );
        _notify();
      },
    );
    _notify();
  }

  Future<void> _handleRequestSafely(HttpRequest request) async {
    try {
      await _handleRequest(request);
    } catch (error, stackTrace) {
      _error = 'Request handling failed: $error';
      debugPrintStack(label: _error, stackTrace: stackTrace);
      AppLogger.log(
        'http.request_failed',
        level: 'error',
        details: {'method': request.method, 'route': request.uri.path},
        error: error,
        stackTrace: stackTrace,
      );
      _notify();
      try {
        await _respond(request, HttpStatus.internalServerError, {
          'error': 'internal_error',
        });
      } catch (responseError, responseStack) {
        _error =
            'Request handling failed: $error; error response failed: $responseError';
        debugPrintStack(label: _error, stackTrace: responseStack);
        _notify();
      }
    }
  }

  Future<void> stop() async {
    final server = _server;
    if (server == null) return;
    _server = null;
    _inviteCode = null;
    _certificateFingerprint = null;
    await server.close(force: true);
    AppLogger.log('server.stopped');
    if (Platform.isAndroid) {
      try {
        await WakelockPlus.disable();
      } catch (error) {
        _error =
            'Server stopped but screen wake lock could not be released: $error';
        _notify();
        rethrow;
      }
    }
    _notify();
  }

  void changeInviteCode(String code) {
    final normalizedCode = code.trim();
    if (normalizedCode.length < 8 || normalizedCode.length > 256) {
      throw ArgumentError('The invite code must be 8 to 256 characters.');
    }
    _inviteCode = normalizedCode;
    _failedAttempts.clear();
    AppLogger.log('admin.password_changed');
    _notify();
  }

  Future<void> addInviteCodes(String input) async {
    final codes = input
        .split(RegExp(r'[\r\n,;]+'))
        .map((code) => code.trim())
        .where((code) => code.isNotEmpty)
        .toList();
    if (codes.isEmpty) throw ArgumentError('请输入至少一个邀请码。');
    final uniqueCodes = <String>{};
    for (final code in codes) {
      if (code.length < 8 || code.length > 256) {
        throw ArgumentError('每个邀请码必须为 8 到 256 个字符。');
      }
      if (_constantTimeEquals(code, _inviteCode ?? '')) {
        throw ArgumentError('客户端邀请码不能与管理员口令相同。');
      }
      if (!uniqueCodes.add(code) || _availableInviteCodes.contains(code)) {
        throw ArgumentError('邀请码重复：$code');
      }
      if (_invalidInviteCodes.contains(code)) {
        throw ArgumentError('该邀请码已失效，请输入新的邀请码。');
      }
      final alreadyAssigned = _registeredClients.values.any(
        (client) =>
            client['revoked'] != true &&
            client['invite_code'] is String &&
            _constantTimeEquals(client['invite_code'] as String, code),
      );
      if (alreadyAssigned) throw ArgumentError('邀请码已绑定客户端：$code');
    }
    final createdAt = DateTime.now().toUtc().toIso8601String();
    _availableInviteCodes.addAll(uniqueCodes);
    for (final code in uniqueCodes) {
      _inviteCodeCreatedAt[code] = createdAt;
    }
    await _saveInviteCodes();
    AppLogger.log(
      'invite_codes.added',
      details: {'count': uniqueCodes.length},
    );
    _notify();
  }

  Future<void> revokeInviteCode(String code) async {
    _availableInviteCodes.remove(code);
    _invalidInviteCodes.add(code);
    final revokedAt = DateTime.now().toUtc().toIso8601String();
    for (final client in _registeredClients.values) {
      if (client['invite_code'] == code) {
        client['revoked'] = true;
        client['revoked_at'] = revokedAt;
        client['token'] = _randomToken(32);
      }
    }
    await _saveInviteCodes();
    await _saveRegisteredClients();
    AppLogger.log('invite_code.revoked');
    _notify();
  }

  Future<void> changeClientInviteCode(String clientId, String code) async {
    final normalizedCode = code.trim();
    if (normalizedCode.length < 8 || normalizedCode.length > 256) {
      throw ArgumentError('The invite code must be 8 to 256 characters.');
    }
    final client = _registeredClients[clientId];
    if (client == null) throw StateError('Unknown client.');
    if (_constantTimeEquals(normalizedCode, _inviteCode ?? '')) {
      throw ArgumentError(
          'The client invite code cannot be the admin password.');
    }
    if (_invalidInviteCodes.contains(normalizedCode)) {
      throw ArgumentError('该邀请码已失效，请输入新的邀请码。');
    }
    final isAlreadyAssigned = _registeredClients.values.any(
      (other) =>
          other['client_id'] != clientId &&
          other['invite_code'] is String &&
          _constantTimeEquals(other['invite_code'] as String, normalizedCode),
    );
    if (isAlreadyAssigned) {
      throw ArgumentError('This invite code is already assigned to a client.');
    }
    final previousCode = client['invite_code'];
    if (previousCode is String && previousCode != normalizedCode) {
      _invalidInviteCodes.add(previousCode);
      _availableInviteCodes.remove(previousCode);
    }
    _availableInviteCodes.remove(normalizedCode);
    client['invite_code'] = normalizedCode;
    client['token'] = _randomToken(32);
    client['revoked'] = false;
    client.remove('revoked_at');
    await _saveRegisteredClients();
    await _saveInviteCodes();
    AppLogger.log('client.invite_code_changed');
    _notify();
  }

  Future<void> setClientRemark(String clientId, String remark) async {
    final client = _registeredClients[clientId];
    if (client == null) throw StateError('Unknown client.');
    final normalizedRemark = remark.trim();
    if (normalizedRemark.length > 80) {
      throw ArgumentError('备注不能超过 80 个字符。');
    }
    client['remark'] = normalizedRemark;
    await _saveRegisteredClients();
    AppLogger.log('client.remark_changed');
    _notify();
  }

  Future<void> setServerAvatarForClient(
    String clientId, {
    required String data,
    required String mimeType,
  }) async {
    final client = _registeredClients[clientId];
    if (client == null ||
        !_setAvatarFields(
          client,
          {
            'server_avatar_data': data,
            'server_avatar_mime_type': mimeType,
          },
          'server_avatar_data',
          'server_avatar_mime_type',
        )) {
      throw ArgumentError('无效的客户端头像。');
    }
    await _saveRegisteredClients();
    _notify();
  }

  Future<void> bindIp(String address) async {
    final ip = normalizeIp(address);
    _allowedIps.add(ip);
    await _saveAllowedIps();
    AppLogger.log('ip.allowlisted');
    _notify();
  }

  Future<void> unbindIp(String address) async {
    final ip = normalizeIp(address);
    _allowedIps.remove(ip);
    await _saveAllowedIps();
    AppLogger.log('ip.removed_from_allowlist');
    _notify();
  }

  Future<void> sendMessage(
    String clientId,
    String body, {
    String? messageId,
  }) async {
    final trimmed = body.trim();
    if (trimmed.isEmpty || trimmed.length > 8000) {
      throw ArgumentError('Message must contain 1 to 8000 characters.');
    }
    if (!_registeredClients.containsKey(clientId)) {
      throw StateError('Unknown client.');
    }
    _messages.add({
      'id': messageId ?? _randomToken(16),
      'client_id': clientId,
      'sender': 'server',
      'body': trimmed,
      'created_at': DateTime.now().toUtc().toIso8601String(),
    });
    await _cache.putMapList(_messagesKey, _messages);
    AppLogger.log('message.sent', details: {'type': 'text'});
    _notify();
  }

  Future<void> sendVibrationAlert(String clientId) async {
    if (!_registeredClients.containsKey(clientId)) {
      throw StateError('Unknown client.');
    }
    _messages.add({
      'id': _randomToken(16),
      'client_id': clientId,
      'sender': 'server',
      'body': '管理端向你发送了震动提醒。',
      'type': 'vibration_alert',
      'created_at': DateTime.now().toUtc().toIso8601String(),
    });
    await _cache.putMapList(_messagesKey, _messages);
    AppLogger.log('message.vibration_alert_sent');
    _notify();
  }

  Future<void> sendMedia({
    required String clientId,
    required String messageId,
    required String fileName,
    required String mimeType,
    required String data,
    String body = '',
  }) async {
    if (!_registeredClients.containsKey(clientId)) {
      throw StateError('Unknown client.');
    }
    await _storeMediaMessage(
      clientId: clientId,
      sender: 'server',
      messageId: messageId,
      fileName: fileName,
      mimeType: mimeType,
      data: data,
      body: body,
    );
    AppLogger.log('message.sent', details: {
      'type': 'attachment',
      'mime_type': mimeType,
      'bytes': base64Decode(data).length,
    });
    _notify();
  }

  Future<Map<String, dynamic>> sendMediaFile({
    required String clientId,
    required String messageId,
    required String fileName,
    required String mimeType,
    required String filePath,
    required int fileSize,
    String body = '',
    String? previewData,
    ValueChanged<int>? onProgress,
  }) async {
    final client = _registeredClients[clientId];
    if (client == null) throw StateError('Unknown client.');
    final existing = _messages.where(
      (message) =>
          message['client_id'] == clientId &&
          message['id'] == messageId &&
          message['media_id'] is String,
    );
    if (existing.isNotEmpty) {
      onProgress?.call(100);
      return Map<String, dynamic>.from(existing.first);
    }
    if (fileSize <= 0 ||
        messageId.isEmpty ||
        messageId.length > 128 ||
        fileName.trim().isEmpty ||
        fileName.length > 255 ||
        mimeType.trim().isEmpty ||
        mimeType.length > 128 ||
        body.length > 8000) {
      throw ArgumentError('Invalid attachment metadata.');
    }
    final file = File(filePath);
    if (await file.length() != fileSize) {
      throw const FileSystemException('Selected file changed before upload.');
    }
    const chunkSize = 1024 * 1024;
    final root = await _getMediaRoot();
    final mediaId = _randomToken(18);
    final staging = Directory(
      '${root.path}${Platform.pathSeparator}upload-$mediaId',
    );
    await staging.create(recursive: true);
    var offset = 0;
    var chunkCount = 0;
    try {
      while (offset < fileSize) {
        final end = (offset + chunkSize).clamp(0, fileSize);
        final bytes = await file.openRead(offset, end).fold<List<int>>(
          <int>[],
          (all, next) => all..addAll(next),
        );
        final chunkFile = File(
          '${staging.path}${Platform.pathSeparator}$chunkCount.chunk',
        );
        if (mimeType.startsWith('video/')) {
          await chunkFile.writeAsBytes(bytes, flush: true);
        } else {
          final encrypted = await compute(_encryptMediaChunk, {
            'code': client['invite_code'] as String,
            'bytes': bytes,
          });
          await chunkFile.writeAsString(encrypted, flush: true);
        }
        offset += bytes.length;
        chunkCount++;
        onProgress?.call((offset * 98 ~/ fileSize).clamp(0, 98));
      }
    } catch (_) {
      if (await staging.exists()) await staging.delete(recursive: true);
      rethrow;
    }
    final destination = Directory(
      '${root.path}${Platform.pathSeparator}$mediaId',
    );
    await staging.rename(destination.path);
    final trimmedName = fileName.replaceAll('\\', '/').split('/').last.trim();
    final media = <String, dynamic>{
      'id': mediaId,
      'client_id': clientId,
      'file_name': trimmedName,
      'mime_type': mimeType.trim(),
      'encrypted': !mimeType.startsWith('video/'),
      'size': fileSize,
      'chunk_count': chunkCount,
    };
    final message = <String, dynamic>{
      'id': messageId,
      'client_id': clientId,
      'sender': 'server',
      'body': body.trim(),
      'created_at': DateTime.now().toUtc().toIso8601String(),
      'media_id': mediaId,
      'file_name': trimmedName,
      'mime_type': mimeType.trim(),
      'media_size': fileSize,
      'chunk_count': chunkCount,
      if (previewData != null) 'preview_data': previewData,
    };
    final pendingMessage = _messages
        .where(
          (item) =>
              item['client_id'] == clientId &&
              item['id'] == messageId &&
              item['pending'] == true,
        )
        .firstOrNull;
    _media[mediaId] = media;
    if (pendingMessage != null) _messages.remove(pendingMessage);
    _messages.add(message);
    try {
      await _cache.putMapList(_mediaKey, _media.values.toList());
      await _cache.putMapList(_messagesKey, _messages);
    } catch (_) {
      _media.remove(mediaId);
      _messages.remove(message);
      if (pendingMessage != null) _messages.add(pendingMessage);
      if (await destination.exists()) await destination.delete(recursive: true);
      rethrow;
    }
    onProgress?.call(100);
    AppLogger.log('message.sent', details: {
      'type': 'attachment',
      'mime_type': mimeType,
      'bytes': fileSize,
    });
    _notify();
    return message;
  }

  @override
  void dispose() {
    _disposed = true;
    final server = _server;
    _server = null;
    _inviteCode = null;
    _certificateFingerprint = null;
    if (server != null) {
      unawaited(server.close(force: true));
      if (Platform.isAndroid) unawaited(WakelockPlus.disable());
    }
    super.dispose();
  }

  Future<void> _handleRequest(HttpRequest request) async {
    AppLogger.log('http.request', details: {
      'method': request.method,
      'route': request.uri.path,
    });
    if (request.method == 'GET' && request.uri.path == '/health') {
      await _respond(request, HttpStatus.ok, {'ok': true});
      return;
    }
    if (request.uri.path.startsWith('/admin/')) {
      await _handleAdminRequest(request);
      return;
    }
    final clientIp = normalizeIp(request.connectionInfo!.remoteAddress.address);
    final requestClientId = request.headers.value('X-Client-Id');
    final requestClient =
        requestClientId == null ? null : _registeredClients[requestClientId];
    _recordRequest(
      clientIp,
      clientId: requestClientId,
      clientName: requestClient?['client_name'] as String?,
    );

    if (request.method == 'POST' && request.uri.path == '/validate') {
      await _handleValidate(request, clientIp);
      return;
    }
    if (request.method == 'POST' && request.uri.path == '/messages/delete') {
      await _handleClientMessageDeletion(request);
      return;
    }
    if (request.uri.path == '/messages' &&
        (request.method == 'GET' || request.method == 'POST')) {
      await _handleMessages(request, clientIp);
      return;
    }

    if (request.uri.path == '/media' && request.method == 'POST') {
      await _handleMediaUpload(request, clientIp);
      return;
    }
    if (request.uri.path.startsWith('/media/') && request.method == 'POST') {
      await _handleMediaUpload(request, clientIp);
      return;
    }
    if (request.uri.path.startsWith('/media/') && request.method == 'GET') {
      await _handleMediaDownload(request, clientIp);
      return;
    }
    if (request.method == 'POST' && request.uri.path == '/logs') {
      await _handleClientLogUpload(request, clientIp);
      return;
    }
    if (request.uri.path == '/profile' &&
        (request.method == 'GET' || request.method == 'POST')) {
      await _handleClientProfile(request);
      return;
    }
    await _respond(request, HttpStatus.notFound, {'error': 'not_found'});
  }

  Future<void> _handleClientMessageDeletion(HttpRequest request) async {
    final clientId = request.headers.value('X-Client-Id');
    final token = request.headers.value('X-Client-Token');
    final client = clientId == null ? null : _registeredClients[clientId];
    if (client == null ||
        !_constantTimeEquals(token ?? '', client['token'] as String)) {
      await _respond(request, HttpStatus.forbidden, {'error': 'unauthorized'});
      return;
    }
    final payload = await _readJsonPayload(request, 64 * 1024);
    if (payload is! Map ||
        payload['message_ids'] is! List ||
        (payload['message_ids'] as List).any(
          (id) => id is! String || id.isEmpty || id.length > 128,
        )) {
      await _respond(request, HttpStatus.badRequest, {
        'error': 'invalid_message_ids',
      });
      return;
    }
    try {
      await deleteMessages(
        clientId!,
        (payload['message_ids'] as List).cast<String>(),
      );
    } on ArgumentError {
      await _respond(request, HttpStatus.badRequest, {
        'error': 'invalid_message_ids',
      });
      return;
    }
    await _respond(request, HttpStatus.ok, {'ok': true});
  }

  Future<void> _handleAdminRequest(HttpRequest request) async {
    final suppliedCode = request.headers.value('X-Admin-Code') ?? '';
    if (!_constantTimeEquals(suppliedCode, _inviteCode ?? '')) {
      await _respond(request, HttpStatus.forbidden, {'error': 'unauthorized'});
      return;
    }
    if (request.method == 'POST' && request.uri.path == '/admin/media/start') {
      try {
        final payload = await _readJsonPayload(request, 64 * 1024);
        if (payload is! Map ||
            payload['client_id'] is! String ||
            payload['id'] is! String ||
            payload['file_name'] is! String ||
            payload['mime_type'] is! String ||
            payload['size'] is! int ||
            (payload['preview_data'] != null &&
                (payload['preview_data'] is! String ||
                    (payload['preview_data'] as String).length > 512 * 1024))) {
          await _respond(
              request, HttpStatus.badRequest, {'error': 'invalid_request'});
          return;
        }
        final clientId = payload['client_id'] as String;
        if (!_registeredClients.containsKey(clientId)) {
          await _respond(
              request, HttpStatus.badRequest, {'error': 'invalid_client'});
          return;
        }
        final existing = _messages.where(
          (message) =>
              message['client_id'] == clientId &&
              message['id'] == payload['id'],
        );
        if (existing.isNotEmpty) {
          await _respond(request, HttpStatus.created, {'already_sent': true});
          return;
        }
        final size = payload['size'] as int;
        final fileName = (payload['file_name'] as String)
            .replaceAll('\\', '/')
            .split('/')
            .last
            .trim();
        if (size <= 0 ||
            (payload['id'] as String).isEmpty ||
            (payload['id'] as String).length > 128 ||
            fileName.isEmpty ||
            fileName.length > 255 ||
            (payload['mime_type'] as String).length > 128) {
          await _respond(
              request, HttpStatus.badRequest, {'error': 'invalid_attachment'});
          return;
        }
        final root = await _getMediaRoot();
        final uploadId = _randomToken(24);
        final directory = Directory(
          '${root.path}${Platform.pathSeparator}upload-$uploadId',
        );
        await directory.create(recursive: true);
        _uploads[uploadId] = {
          'client_id': clientId,
          'message_id': payload['id'],
          'file_name': fileName,
          'mime_type': payload['mime_type'],
          'encrypted': !(payload['mime_type'] as String).startsWith('video/'),
          'size': size,
          'body': '',
          if (payload['preview_data'] is String)
            'preview_data': payload['preview_data'],
          'directory': directory.path,
          'chunk_count': 0,
          'received_bytes': 0,
          'admin_upload': true,
        };
        await _respond(request, HttpStatus.created, {'upload_id': uploadId});
      } on FileSystemException catch (error) {
        await _respond(
            request, 507, {'error': 'disk_error', 'message': error.message});
      }
      return;
    }
    if (request.method == 'POST' &&
        request.uri.path.startsWith('/admin/media/')) {
      final path = request.uri.pathSegments;
      if (path.length == 4 && path[3] == 'cancel') {
        final upload = _uploads.remove(path[2]);
        if (upload == null || upload['admin_upload'] != true) {
          await _respond(
              request, HttpStatus.notFound, {'error': 'upload_not_found'});
          return;
        }
        try {
          final directory = Directory(upload['directory'] as String);
          if (await directory.exists()) await directory.delete(recursive: true);
          await _respond(request, HttpStatus.ok, {'ok': true});
        } on FileSystemException catch (error) {
          await _respond(
              request, 507, {'error': 'disk_error', 'message': error.message});
        }
        return;
      }
      if (path.length == 5 && path[3] == 'chunk') {
        final upload = _uploads[path[2]];
        final index = int.tryParse(path[4]);
        if (upload == null ||
            upload['admin_upload'] != true ||
            index == null ||
            index != upload['chunk_count'] ||
            request.contentLength <= 0 ||
            request.contentLength > 2 * 1024 * 1024) {
          await _respond(
              request, HttpStatus.badRequest, {'error': 'invalid_chunk'});
          return;
        }
        try {
          final bool isEncrypted = upload['encrypted'] != false;
          final List<int> bytes;
          if (isEncrypted) {
            final payload = await _readJsonPayload(request, 2 * 1024 * 1024);
            if (payload is! Map || payload['data'] is! String) {
              throw const FormatException('Invalid chunk.');
            }
            bytes = base64Decode(payload['data'] as String);
          } else {
            bytes = await request.fold<List<int>>(
              <int>[],
              (all, next) => all..addAll(next),
            );
          }
          if (bytes.isEmpty || bytes.length > 1024 * 1024) {
            throw const FormatException('Invalid chunk.');
          }
          final chunkFile = File(
            '${upload['directory']}${Platform.pathSeparator}$index.chunk',
          );
          if (isEncrypted) {
            final client = _registeredClients[upload['client_id']];
            if (client == null) throw StateError('Unknown client.');
            final encrypted = await compute(_encryptMediaChunk, {
              'code': client['invite_code'] as String,
              'bytes': bytes,
            });
            await chunkFile.writeAsString(encrypted, flush: true);
          } else {
            await chunkFile.writeAsBytes(bytes, flush: true);
          }
          upload['chunk_count'] = index + 1;
          upload['received_bytes'] =
              (upload['received_bytes'] as int) + bytes.length;
          if ((upload['received_bytes'] as int) > (upload['size'] as int)) {
            throw const FormatException('Attachment size mismatch.');
          }
          await _respond(request, HttpStatus.ok, {'ok': true});
        } on FormatException {
          await _respond(
              request, HttpStatus.badRequest, {'error': 'invalid_chunk'});
        } on FileSystemException catch (error) {
          await _respond(
              request, 507, {'error': 'disk_error', 'message': error.message});
        }
        return;
      }
      if (path.length == 4 && path[3] == 'complete') {
        final uploadId = path[2];
        final upload = _uploads[uploadId];
        if (upload == null || upload['admin_upload'] != true) {
          await _respond(
              request, HttpStatus.notFound, {'error': 'upload_not_found'});
          return;
        }
        try {
          final payload = await _readJsonPayload(request, 4096);
          if (payload is! Map ||
              payload['size'] != upload['size'] ||
              payload['size'] != upload['received_bytes'] ||
              payload['chunk_count'] != upload['chunk_count'] ||
              (payload['chunk_count'] as int? ?? 0) <= 0) {
            throw const FormatException('Attachment size mismatch.');
          }
          final mediaId = _randomToken(18);
          final root = await _getMediaRoot();
          await Directory(upload['directory'] as String).rename(
            '${root.path}${Platform.pathSeparator}$mediaId',
          );
          _media[mediaId] = {
            'id': mediaId,
            'client_id': upload['client_id'],
            'file_name': upload['file_name'],
            'mime_type': upload['mime_type'],
            'encrypted': upload['encrypted'] != false,
            'size': upload['size'],
            'chunk_count': upload['chunk_count'],
            if (upload['preview_data'] is String)
              'preview_data': upload['preview_data'],
          };
          final message = <String, dynamic>{
            'id': upload['message_id'],
            'client_id': upload['client_id'],
            'sender': 'server',
            'body': '',
            'created_at': DateTime.now().toUtc().toIso8601String(),
            'media_id': mediaId,
            'file_name': upload['file_name'],
            'mime_type': upload['mime_type'],
            'media_size': upload['size'],
            'chunk_count': upload['chunk_count'],
            if (upload['preview_data'] is String)
              'preview_data': upload['preview_data'],
          };
          _messages.add(message);
          _uploads.remove(uploadId);
          await _cache.putMapList(_mediaKey, _media.values.toList());
          await _cache.putMapList(_messagesKey, _messages);
          _notify();
          await _respond(request, HttpStatus.created, {'ok': true});
        } on FormatException {
          await _respond(
              request, HttpStatus.badRequest, {'error': 'invalid_attachment'});
        } on FileSystemException catch (error) {
          await _respond(
              request, 507, {'error': 'disk_error', 'message': error.message});
        }
        return;
      }
    }
    if (request.method == 'GET' && request.uri.path == '/admin/state') {
      final clients = registeredClients.map((client) {
        return Map<String, dynamic>.from(client)
          ..remove('token')
          ..remove('avatar_data')
          ..remove('avatar_mime_type')
          ..remove('server_avatar_data')
          ..remove('server_avatar_mime_type')
          ..['last_chat_at'] = _lastChatAt(client['client_id'] as String?);
      }).toList();
      await _respond(request, HttpStatus.ok, {
        'allowed_ips': _allowedIps.toList(),
        'requests': _clients.values
            .map((client) => {
                  'address': client.address,
                  'first_seen': client.firstSeen.toUtc().toIso8601String(),
                  'last_seen': client.lastSeen.toUtc().toIso8601String(),
                  'requests': client.requests,
                })
            .toList(),
        'registered_clients': clients,
        'invite_codes': inviteCodes,
      });
      return;
    }
    if (request.method == 'POST' && request.uri.path == '/admin/logs') {
      await _handleAdminLogUpload(request);
      return;
    }
    if (request.uri.path == '/admin/client-avatar' &&
        (request.method == 'GET' || request.method == 'POST')) {
      await _handleAdminClientAvatar(request);
      return;
    }
    if (request.method == 'POST' && request.uri.path == '/admin/invite-codes') {
      final payload = await _readJsonPayload(request, 64 * 1024);
      if (payload is! Map || payload['codes'] is! String) {
        await _respond(request, HttpStatus.badRequest, {
          'error': 'invalid_request',
        });
        return;
      }
      try {
        await addInviteCodes(payload['codes'] as String);
      } on ArgumentError {
        await _respond(request, HttpStatus.badRequest, {
          'error': 'invalid_invite_codes',
        });
        return;
      }
      await _respond(request, HttpStatus.created, {'ok': true});
      return;
    }
    if (request.method == 'GET' && request.uri.path == '/admin/messages') {
      final clientId = request.uri.queryParameters['client_id'];
      if (clientId == null || !_registeredClients.containsKey(clientId)) {
        await _respond(request, HttpStatus.badRequest, {
          'error': 'invalid_client',
        });
        return;
      }
      await _respond(request, HttpStatus.ok, {
        'messages': messagesFor(clientId, includeExpired: true),
      });
      return;
    }
    if (request.method == 'POST' &&
        request.uri.path == '/admin/delete-messages') {
      final payload = await _readJsonPayload(request, 64 * 1024);
      if (payload is! Map ||
          payload['client_id'] is! String ||
          payload['message_ids'] is! List ||
          (payload['message_ids'] as List).any((id) => id is! String)) {
        await _respond(request, HttpStatus.badRequest, {
          'error': 'invalid_request',
        });
        return;
      }
      try {
        await deleteMessages(
          payload['client_id'] as String,
          (payload['message_ids'] as List).cast<String>(),
        );
      } on ArgumentError {
        await _respond(request, HttpStatus.badRequest, {
          'error': 'invalid_message_ids',
        });
        return;
      } on StateError {
        await _respond(request, HttpStatus.badRequest, {
          'error': 'invalid_client',
        });
        return;
      }
      await _respond(request, HttpStatus.ok, {'ok': true});
      return;
    }
    if (request.method == 'POST' &&
        request.uri.path == '/admin/client-invite-code') {
      final payload = await _readJsonPayload(request, 4096);
      if (payload is! Map ||
          payload['client_id'] is! String ||
          payload['code'] is! String) {
        await _respond(request, HttpStatus.badRequest, {
          'error': 'invalid_request',
        });
        return;
      }
      try {
        await changeClientInviteCode(
          payload['client_id'] as String,
          payload['code'] as String,
        );
      } on ArgumentError {
        await _respond(request, HttpStatus.badRequest, {
          'error': 'invalid_invite_code',
        });
        return;
      } on StateError {
        await _respond(request, HttpStatus.badRequest, {
          'error': 'invalid_client',
        });
        return;
      }
      await _respond(request, HttpStatus.ok, {'ok': true});
      return;
    }
    if (request.method == 'POST' &&
        request.uri.path == '/admin/client-remark') {
      final payload = await _readJsonPayload(request, 4096);
      if (payload is! Map ||
          payload['client_id'] is! String ||
          payload['remark'] is! String) {
        await _respond(request, HttpStatus.badRequest, {
          'error': 'invalid_request',
        });
        return;
      }
      try {
        await setClientRemark(
          payload['client_id'] as String,
          payload['remark'] as String,
        );
      } on ArgumentError {
        await _respond(request, HttpStatus.badRequest, {
          'error': 'invalid_remark',
        });
        return;
      } on StateError {
        await _respond(request, HttpStatus.badRequest, {
          'error': 'invalid_client',
        });
        return;
      }
      await _respond(request, HttpStatus.ok, {'ok': true});
      return;
    }
    if (request.method == 'POST' &&
        request.uri.path == '/admin/revoke-invite-code') {
      final payload = await _readJsonPayload(request, 4096);
      if (payload is! Map || payload['code'] is! String) {
        await _respond(request, HttpStatus.badRequest, {
          'error': 'invalid_request',
        });
        return;
      }
      await revokeInviteCode(payload['code'] as String);
      await _respond(request, HttpStatus.ok, {'ok': true});
      return;
    }
    if (request.method == 'GET' &&
        request.uri.path.startsWith('/admin/media/')) {
      final path = request.uri.pathSegments;
      final mediaId = path.length >= 3 ? path[2] : '';
      final media = _media[mediaId];
      if (media == null) {
        await _respond(request, HttpStatus.notFound, {'error': 'not_found'});
        return;
      }
      if (path.length == 5 && path[3] == 'chunk') {
        final index = int.tryParse(path[4]);
        final client = _registeredClients[media['client_id']];
        if (index == null ||
            index < 0 ||
            index >= (media['chunk_count'] as int? ?? 0) ||
            client == null) {
          await _respond(request, HttpStatus.notFound, {'error': 'not_found'});
          return;
        }
        try {
          final mediaDirectory = await _getMediaDirectory(mediaId);
          final chunkFile = File(
            '${mediaDirectory.path}${Platform.pathSeparator}$index.chunk',
          );
          if (media['encrypted'] == false) {
            await _respondBytes(
              request,
              HttpStatus.ok,
              await chunkFile.readAsBytes(),
            );
          } else {
            final data = await compute(_decryptMediaChunk, {
              'code': client['invite_code'] as String,
              'ciphertext': await chunkFile.readAsString(),
            });
            await _respond(request, HttpStatus.ok, {'data': data});
          }
        } on FileSystemException catch (error) {
          await _respond(request, HttpStatus.internalServerError, {
            'error': 'disk_error',
            'message': error.message,
          });
        }
        return;
      }
      await _respond(request, HttpStatus.ok, {
        'file_name': media['file_name'],
        'mime_type': media['mime_type'],
        'size': media['size'],
        'chunk_count': media['chunk_count'],
      });
      return;
    }
    if (request.method == 'POST' && request.uri.path == '/admin/message') {
      final payload = await _readJsonPayload(request, 42 * 1024 * 1024);
      if (payload is! Map ||
          payload['client_id'] is! String ||
          payload['id'] is! String) {
        await _respond(request, HttpStatus.badRequest, {
          'error': 'invalid_request',
        });
        return;
      }
      final clientId = payload['client_id'] as String;
      if (payload['data'] is String &&
          payload['file_name'] is String &&
          payload['mime_type'] is String) {
        try {
          await sendMedia(
            clientId: clientId,
            messageId: payload['id'] as String,
            fileName: payload['file_name'] as String,
            mimeType: payload['mime_type'] as String,
            data: payload['data'] as String,
            body: payload['body'] as String? ?? '',
          );
        } on ArgumentError {
          await _respond(request, HttpStatus.badRequest, {
            'error': 'invalid_attachment',
          });
          return;
        } on StateError {
          await _respond(request, 413, {'error': 'storage_limit'});
          return;
        }
      } else if (payload['body'] is String) {
        try {
          if (payload['type'] == 'vibration_alert') {
            await sendVibrationAlert(clientId);
          } else {
            await sendMessage(
              clientId,
              payload['body'] as String,
              messageId: payload['id'] as String,
            );
          }
        } on ArgumentError {
          await _respond(request, HttpStatus.badRequest, {
            'error': 'invalid_message',
          });
          return;
        }
      } else {
        await _respond(request, HttpStatus.badRequest, {
          'error': 'invalid_request',
        });
        return;
      }
      await _respond(request, HttpStatus.created, {'ok': true});
      return;
    }
    if (request.method == 'POST' && request.uri.path == '/admin/allow-ip') {
      final payload = await _readJsonPayload(request, 4096);
      if (payload is! Map || payload['address'] is! String) {
        await _respond(request, HttpStatus.badRequest, {
          'error': 'invalid_request',
        });
        return;
      }
      try {
        await bindIp(payload['address'] as String);
      } on FormatException {
        await _respond(request, HttpStatus.badRequest, {'error': 'invalid_ip'});
        return;
      }
      await _respond(request, HttpStatus.ok, {'ok': true});
      return;
    }
    if (request.method == 'POST' && request.uri.path == '/admin/revoke-ip') {
      final payload = await _readJsonPayload(request, 4096);
      if (payload is! Map || payload['address'] is! String) {
        await _respond(request, HttpStatus.badRequest, {
          'error': 'invalid_request',
        });
        return;
      }
      try {
        await unbindIp(payload['address'] as String);
      } on FormatException {
        await _respond(request, HttpStatus.badRequest, {'error': 'invalid_ip'});
        return;
      }
      await _respond(request, HttpStatus.ok, {'ok': true});
      return;
    }
    await _respond(request, HttpStatus.notFound, {'error': 'not_found'});
  }

  Future<void> _handleAdminLogUpload(HttpRequest request) async {
    final payload = await _readJsonPayload(request, 6 * 1024 * 1024);
    if (payload is! Map || payload['content'] is! String) {
      await _respond(request, HttpStatus.badRequest, {
        'error': 'invalid_log',
      });
      return;
    }
    final content = payload['content'] as String;
    if (content.isEmpty || utf8.encode(content).length > 5 * 1024 * 1024) {
      await _respond(request, HttpStatus.badRequest, {
        'error': 'invalid_log',
      });
      return;
    }
    try {
      await AppLogger.saveUploadedLog(
        fileName: 'server-mobile',
        content: content,
      );
      AppLogger.log('logs.received', details: {
        'app': 'server-mobile',
        'bytes': utf8.encode(content).length,
      });
      await _respond(request, HttpStatus.ok, {'ok': true});
    } catch (error, stackTrace) {
      AppLogger.log(
        'logs.save_failed',
        level: 'error',
        details: {'app': 'server-mobile'},
        error: error,
        stackTrace: stackTrace,
      );
      await _respond(request, HttpStatus.internalServerError, {
        'error': 'log_save_failed',
      });
    }
  }

  Future<void> _handleClientProfile(HttpRequest request) async {
    final clientId = request.headers.value('X-Client-Id');
    final token = request.headers.value('X-Client-Token');
    final client = clientId == null ? null : _registeredClients[clientId];
    if (client == null ||
        client['revoked'] == true ||
        !_constantTimeEquals(token ?? '', client['token'] as String)) {
      await _respond(request, HttpStatus.forbidden, {'error': 'unauthorized'});
      return;
    }
    if (request.method == 'POST') {
      final payload = await _readJsonPayload(request, 2 * 1024 * 1024);
      if (payload is! Map ||
          !_setAvatarFields(
            client,
            payload,
            'avatar_data',
            'avatar_mime_type',
          )) {
        await _respond(request, HttpStatus.badRequest, {
          'error': 'invalid_avatar',
        });
        return;
      }
      await _saveRegisteredClients();
    }
    await _respond(request, HttpStatus.ok, {
      'avatar_data': client['avatar_data'],
      'avatar_mime_type': client['avatar_mime_type'],
      'server_avatar_data': client['server_avatar_data'],
      'server_avatar_mime_type': client['server_avatar_mime_type'],
    });
  }

  Future<void> _handleAdminClientAvatar(HttpRequest request) async {
    if (request.method == 'GET') {
      final clientId = request.uri.queryParameters['client_id'];
      final client = clientId == null ? null : _registeredClients[clientId];
      if (client == null) {
        await _respond(request, HttpStatus.badRequest, {
          'error': 'invalid_client',
        });
        return;
      }
      await _respond(request, HttpStatus.ok, {
        'avatar_data': client['avatar_data'],
        'avatar_mime_type': client['avatar_mime_type'],
        'server_avatar_data': client['server_avatar_data'],
        'server_avatar_mime_type': client['server_avatar_mime_type'],
      });
      return;
    }
    final payload = await _readJsonPayload(request, 2 * 1024 * 1024);
    if (payload is! Map || payload['client_id'] is! String) {
      await _respond(request, HttpStatus.badRequest, {
        'error': 'invalid_request',
      });
      return;
    }
    final client = _registeredClients[payload['client_id']];
    final avatarPayload = <Object?, Object?>{
      'server_avatar_data': payload['avatar_data'],
      'server_avatar_mime_type': payload['avatar_mime_type'],
    };
    if (client == null ||
        !_setAvatarFields(
          client,
          avatarPayload,
          'server_avatar_data',
          'server_avatar_mime_type',
        )) {
      await _respond(request, HttpStatus.badRequest, {
        'error': 'invalid_avatar',
      });
      return;
    }
    await _saveRegisteredClients();
    await _respond(request, HttpStatus.ok, {'ok': true});
  }

  bool _setAvatarFields(
    Map<String, dynamic> client,
    Map payload,
    String dataField,
    String mimeField,
  ) {
    final data = payload[dataField];
    final mimeType = payload[mimeField];
    if (data == null && mimeType == null) {
      client.remove(dataField);
      client.remove(mimeField);
      return true;
    }
    if (data is! String ||
        mimeType is! String ||
        !const {'image/jpeg', 'image/png', 'image/webp'}.contains(mimeType)) {
      return false;
    }
    try {
      final bytes = base64Decode(data);
      if (bytes.isEmpty || bytes.length > 1024 * 1024) return false;
    } on FormatException {
      return false;
    }
    client[dataField] = data;
    client[mimeField] = mimeType;
    return true;
  }

  Future<void> _handleClientLogUpload(
    HttpRequest request,
    String clientIp,
  ) async {
    final clientId = request.headers.value('X-Client-Id');
    final token = request.headers.value('X-Client-Token');
    final client = clientId == null ? null : _registeredClients[clientId];
    if (client == null ||
        client['revoked'] == true ||
        !_constantTimeEquals(token ?? '', client['token'] as String)) {
      await _respond(request, HttpStatus.forbidden, {'error': 'unauthorized'});
      return;
    }
    final payload = await _readJsonPayload(request, 6 * 1024 * 1024);
    if (payload is! Map || payload['content'] is! String) {
      await _respond(request, HttpStatus.badRequest, {
        'error': 'invalid_log',
      });
      return;
    }
    final content = payload['content'] as String;
    if (content.isEmpty || utf8.encode(content).length > 2 * 1024 * 1024) {
      await _respond(request, HttpStatus.badRequest, {
        'error': 'invalid_log',
      });
      return;
    }
    try {
      await AppLogger.saveUploadedLog(
        fileName: 'client-mobile',
        content: content,
      );
      AppLogger.log('logs.received', details: {
        'app': 'client-mobile',
        'bytes': utf8.encode(content).length,
      });
      await _respond(request, HttpStatus.ok, {'ok': true});
    } catch (error, stackTrace) {
      AppLogger.log(
        'logs.save_failed',
        level: 'error',
        details: {'app': 'client-mobile'},
        error: error,
        stackTrace: stackTrace,
      );
      await _respond(request, HttpStatus.internalServerError, {
        'error': 'log_save_failed',
      });
    }
  }

  Future<Object?> _readJsonPayload(HttpRequest request, int maxBytes) async {
    if (request.contentLength <= 0 || request.contentLength > maxBytes) {
      return null;
    }
    try {
      return jsonDecode(await utf8.decoder.bind(request).join());
    } on FormatException {
      return null;
    }
  }

  Future<void> _handleValidate(HttpRequest request, String clientIp) async {
    final length = request.contentLength;
    if (length <= 0 || length > 4096) {
      await _respond(request, HttpStatus.badRequest, {
        'error': 'invalid_request',
      });
      return;
    }

    late final Object? payload;
    try {
      payload = jsonDecode(await utf8.decoder.bind(request).join());
    } on FormatException {
      await _respond(request, HttpStatus.badRequest, {
        'error': 'invalid_request',
      });
      return;
    }
    if (payload is! Map ||
        payload['code'] is! String ||
        payload['client_id'] is! String ||
        payload['client_name'] is! String ||
        payload['token'] is! String ||
        (payload['device_identity'] != null &&
            payload['device_identity'] is! String) ||
        (payload['device_name'] != null && payload['device_name'] is! String)) {
      await _respond(request, HttpStatus.badRequest, {
        'error': 'invalid_request',
      });
      return;
    }

    final recentFailures = (_failedAttempts[clientIp] ?? [])
        .where((time) => DateTime.now().difference(time).inSeconds < 60)
        .toList();
    _failedAttempts[clientIp] = recentFailures;
    if (recentFailures.length >= 20) {
      await _respond(request, HttpStatus.tooManyRequests, {
        'error': 'try_again_later',
      });
      return;
    }
    final suppliedCode = (payload['code'] as String).trim();
    final requestedClientId = (payload['client_id'] as String).trim();
    final clientName = (payload['client_name'] as String).trim();
    final deviceIdentity = (payload['device_identity'] as String? ?? '').trim();
    final deviceName = (payload['device_name'] as String? ??
            _registeredClients[requestedClientId]?['device_name'] as String? ??
            clientName)
        .trim();
    final suppliedToken = payload['token'] as String;
    if (requestedClientId.isEmpty ||
        requestedClientId.length > 128 ||
        clientName.isEmpty ||
        clientName.length > 80 ||
        deviceName.isEmpty ||
        deviceName.length > 80 ||
        suppliedCode.length < 8 ||
        suppliedCode.length > 256 ||
        _constantTimeEquals(suppliedCode, _inviteCode ?? '')) {
      await _respond(request, HttpStatus.badRequest, {
        'error': 'invalid_request',
      });
      return;
    }
    if (deviceIdentity.length > 128) {
      await _respond(request, HttpStatus.badRequest, {
        'error': 'invalid_request',
      });
      return;
    }
    _recordClientDetails(
      clientIp,
      clientId: requestedClientId,
      clientName: clientName,
    );
    if (_invalidInviteCodes.contains(suppliedCode)) {
      await _respond(request, HttpStatus.ok, {
        'valid': false,
        'error': 'invite_invalidated',
      });
      return;
    }
    var clientId = requestedClientId;
    var existing = _registeredClients[clientId];
    if (existing == null && deviceIdentity.isNotEmpty) {
      final matchingDevice = _registeredClients.values.where(
        (client) =>
            client['revoked'] != true &&
            client['device_identity'] == deviceIdentity,
      );
      if (matchingDevice.isNotEmpty) {
        final deviceOwner = matchingDevice.first;
        if (!_constantTimeEquals(
          deviceOwner['invite_code'] as String? ?? '',
          suppliedCode,
        )) {
          await _respond(request, HttpStatus.ok, {'valid': false});
          return;
        }
        clientId = deviceOwner['client_id'] as String;
        existing = deviceOwner;
      }
    }
    if (existing?['revoked'] == true) {
      await _respond(request, HttpStatus.ok, {
        'valid': false,
        'error': 'invite_invalidated',
      });
      return;
    }
    final assignedCode = existing?['invite_code'];
    if (assignedCode is String &&
        !_constantTimeEquals(suppliedCode, assignedCode)) {
      await _respond(request, HttpStatus.ok, {'valid': false});
      return;
    }
    final codeOwner = _registeredClients.values.any(
      (client) =>
          client['client_id'] != clientId &&
          client['revoked'] != true &&
          client['invite_code'] is String &&
          _constantTimeEquals(
            client['invite_code'] as String,
            suppliedCode,
          ),
    );
    if (codeOwner) {
      recentFailures.add(DateTime.now());
      _availableInviteCodes.remove(suppliedCode);
      _invalidInviteCodes.add(suppliedCode);
      final revokedAt = DateTime.now().toUtc().toIso8601String();
      for (final client in _registeredClients.values) {
        if (_constantTimeEquals(
          client['invite_code'] is String
              ? client['invite_code'] as String
              : '',
          suppliedCode,
        )) {
          client['revoked'] = true;
          client['revoked_at'] = revokedAt;
          client['token'] = _randomToken(32);
        }
      }
      await _saveInviteCodes();
      await _saveRegisteredClients();
      _notify();
      await _respond(request, HttpStatus.ok, {
        'valid': false,
        'error': 'invite_already_assigned',
      });
      return;
    }
    if (existing == null && !_availableInviteCodes.contains(suppliedCode)) {
      recentFailures.add(DateTime.now());
      await _respond(request, HttpStatus.ok, {
        'valid': false,
        'error': 'invalid_invite_code',
      });
      return;
    }
    final token = existing != null &&
            _constantTimeEquals(suppliedToken, existing['token'] as String)
        ? existing['token'] as String
        : _randomToken(32);
    _registeredClients[clientId] = {
      ...?existing,
      'client_id': clientId,
      'client_name': clientName,
      'device_name': deviceName,
      if (deviceIdentity.isNotEmpty) 'device_identity': deviceIdentity,
      'token': token,
      'invite_code': suppliedCode,
      'ip': clientIp,
      'created_at':
          existing?['created_at'] ?? DateTime.now().toUtc().toIso8601String(),
      'last_seen': DateTime.now().toUtc().toIso8601String(),
      'revoked': false,
    };
    _availableInviteCodes.remove(suppliedCode);
    await _saveRegisteredClients();
    await _saveInviteCodes();
    _notify();
    await _respond(request, HttpStatus.ok, {
      'valid': true,
      'token': token,
      'client_id': clientId,
    });
  }

  Future<void> _handleMessages(HttpRequest request, String clientIp) async {
    final clientId = request.headers.value('X-Client-Id');
    final token = request.headers.value('X-Client-Token');
    if (clientId == null) {
      await _respond(request, HttpStatus.forbidden, {'error': 'unauthorized'});
      return;
    }
    final client = _registeredClients[clientId];
    if (client == null ||
        !_constantTimeEquals(token ?? '', client['token'] as String)) {
      await _respond(request, HttpStatus.forbidden, {'error': 'unauthorized'});
      return;
    }
    final now = DateTime.now().toUtc();
    final previousSeen =
        DateTime.tryParse(client['last_seen']?.toString() ?? '');
    final shouldPersist = client['ip'] != clientIp ||
        previousSeen == null ||
        now.difference(previousSeen) >= const Duration(seconds: 30);
    client['ip'] = clientIp;
    if (shouldPersist) {
      client['last_seen'] = now.toIso8601String();
      await _saveRegisteredClients();
    }
    if (request.method == 'GET') {
      await _respond(request, HttpStatus.ok, {
        'messages_cipher': DailyInviteCipher(
          client['invite_code'] as String,
        ).encrypt(jsonEncode(
          messagesFor(clientId)
              .where((message) => message['pending'] != true)
              .toList(),
        )),
      });
      return;
    }
    if (request.contentLength <= 0 || request.contentLength > 64000) {
      await _respond(request, HttpStatus.badRequest, {
        'error': 'invalid_request',
      });
      return;
    }
    late final Object? payload;
    try {
      payload = jsonDecode(await utf8.decoder.bind(request).join());
    } on FormatException {
      await _respond(request, HttpStatus.badRequest, {
        'error': 'invalid_request',
      });
      return;
    }
    if (payload is! Map ||
        payload['body'] is! String ||
        payload['id'] is! String ||
        (payload['id'] as String).trim().isEmpty ||
        (payload['id'] as String).length > 128 ||
        (payload['body'] as String).isEmpty ||
        (payload['body'] as String).length > 16000) {
      await _respond(request, HttpStatus.badRequest, {
        'error': 'invalid_request',
      });
      return;
    }
    final body = DailyInviteCipher(client['invite_code'] as String)
        .decrypt(payload['body'] as String);
    if (body.trim().isEmpty || body.length > 8000) {
      await _respond(request, HttpStatus.badRequest, {
        'error': 'invalid_request',
      });
      return;
    }
    final messageId = (payload['id'] as String).trim();
    final existingMessage = _messages.where(
      (message) =>
          message['client_id'] == clientId && message['id'] == messageId,
    );
    if (existingMessage.isNotEmpty) {
      await _respond(request, HttpStatus.created, {
        'message_cipher': DailyInviteCipher(client['invite_code'] as String)
            .encrypt(jsonEncode(existingMessage.first)),
      });
      return;
    }
    final message = <String, dynamic>{
      'id': messageId,
      'client_id': clientId,
      'sender': 'client',
      'body': body.trim(),
      'created_at': DateTime.now().toUtc().toIso8601String(),
    };
    _messages.add(message);
    await _cache.putMapList(_messagesKey, _messages);
    _notify();
    await _respond(request, HttpStatus.created, {
      'message_cipher': DailyInviteCipher(client['invite_code'] as String)
          .encrypt(jsonEncode(message)),
    });
  }

  Future<void> _handleMediaUpload(HttpRequest request, String clientIp) async {
    final clientId = request.headers.value('X-Client-Id');
    final token = request.headers.value('X-Client-Token');
    if (clientId == null) {
      await _respond(request, HttpStatus.forbidden, {'error': 'unauthorized'});
      return;
    }

    Future<void> handleMediaStart(HttpRequest request, String clientIp) async {
      final clientId = request.headers.value('X-Client-Id');
      final token = request.headers.value('X-Client-Token');
      final client = clientId == null ? null : _registeredClients[clientId];
      if (client == null ||
          !_constantTimeEquals(token ?? '', client['token'] as String)) {
        await _respond(
            request, HttpStatus.forbidden, {'error': 'unauthorized'});
        return;
      }
      try {
        final payload = await _readJsonPayload(request, 64 * 1024);
        if (payload is! Map || payload['metadata_cipher'] is! String) {
          await _respond(
              request, HttpStatus.badRequest, {'error': 'invalid_request'});
          return;
        }
        final metadata = jsonDecode(
          DailyInviteCipher(client['invite_code'] as String)
              .decrypt(payload['metadata_cipher'] as String),
        );
        if (metadata is! Map ||
            metadata['id'] is! String ||
            metadata['file_name'] is! String ||
            metadata['mime_type'] is! String ||
            metadata['size'] is! int ||
            metadata['body'] is! String ||
            (metadata['preview_data'] != null &&
                (metadata['preview_data'] is! String ||
                    (metadata['preview_data'] as String).length >
                        512 * 1024))) {
          throw const FormatException('Invalid attachment metadata.');
        }
        final messageId = metadata['id'] as String;
        final existing = _messages.where(
          (message) =>
              message['client_id'] == clientId && message['id'] == messageId,
        );
        if (existing.isNotEmpty) {
          await _respond(request, HttpStatus.created, {
            'message_cipher': DailyInviteCipher(client['invite_code'] as String)
                .encrypt(jsonEncode(existing.first)),
          });
          return;
        }
        final fileName = (metadata['file_name'] as String)
            .replaceAll('\\', '/')
            .split('/')
            .last
            .trim();
        final mimeType = (metadata['mime_type'] as String).trim();
        final size = metadata['size'] as int;
        if (messageId.isEmpty ||
            messageId.length > 128 ||
            fileName.isEmpty ||
            fileName.length > 255 ||
            mimeType.isEmpty ||
            mimeType.length > 128 ||
            size <= 0 ||
            (metadata['body'] as String).length > 8000) {
          throw const FormatException('Invalid attachment metadata.');
        }
        final resumableUpload = _uploads.entries.where((entry) {
          final upload = entry.value;
          return upload['admin_upload'] != true &&
              upload['client_id'] == clientId &&
              upload['message_id'] == messageId;
        }).firstOrNull;
        if (resumableUpload != null) {
          final upload = resumableUpload.value;
          if (upload['file_name'] != fileName ||
              upload['mime_type'] != mimeType ||
              upload['size'] != size ||
              upload['body'] != metadata['body']) {
            await _respond(request, HttpStatus.conflict, {
              'error': 'upload_metadata_conflict',
            });
            return;
          }
          await _respond(request, HttpStatus.created, {
            'upload_id': resumableUpload.key,
            'next_chunk': upload['chunk_count'],
          });
          return;
        }
        final root = await _getMediaRoot();
        final uploadId = _randomToken(24);
        final directory = Directory(
          '${root.path}${Platform.pathSeparator}upload-$uploadId',
        );
        await directory.create(recursive: true);
        _uploads[uploadId] = {
          'client_id': clientId,
          'message_id': messageId,
          'file_name': fileName,
          'mime_type': mimeType,
          'encrypted': !mimeType.startsWith('video/'),
          'size': size,
          'body': metadata['body'] as String,
          if (metadata['preview_data'] is String)
            'preview_data': metadata['preview_data'],
          'directory': directory.path,
          'chunk_count': 0,
          'received_bytes': 0,
        };
        _registeredClients[clientId]!['last_seen'] =
            DateTime.now().toUtc().toIso8601String();
        _registeredClients[clientId]!['ip'] = clientIp;
        await _saveRegisteredClients();
        await _respond(request, HttpStatus.created, {
          'upload_id': uploadId,
          'next_chunk': 0,
        });
      } on FormatException {
        await _respond(
            request, HttpStatus.badRequest, {'error': 'invalid_attachment'});
      } on FileSystemException catch (error) {
        await _respond(
            request, 507, {'error': 'disk_error', 'message': error.message});
      }
    }

    Future<void> handleMediaChunkOrComplete(HttpRequest request) async {
      final clientId = request.headers.value('X-Client-Id');
      final token = request.headers.value('X-Client-Token');
      final client = clientId == null ? null : _registeredClients[clientId];
      if (client == null ||
          !_constantTimeEquals(token ?? '', client['token'] as String)) {
        await _respond(
            request, HttpStatus.forbidden, {'error': 'unauthorized'});
        return;
      }
      final parts = request.uri.pathSegments;
      if (parts.length == 3 &&
          parts[0] == 'media' &&
          parts[2] == 'cancel' &&
          request.method == 'POST') {
        final upload = _uploads[parts[1]];
        if (upload == null ||
            upload['client_id'] != clientId ||
            upload['admin_upload'] == true) {
          await _respond(
              request, HttpStatus.notFound, {'error': 'upload_not_found'});
          return;
        }
        try {
          final directory = Directory(upload['directory'] as String);
          if (await directory.exists()) await directory.delete(recursive: true);
          _uploads.remove(parts[1]);
          await _respond(request, HttpStatus.ok, {'ok': true});
        } on FileSystemException catch (error) {
          await _respond(
              request, 507, {'error': 'disk_error', 'message': error.message});
        }
        return;
      }
      if (parts.length == 4 &&
          parts[0] == 'media' &&
          parts[2] == 'chunk' &&
          request.method == 'POST') {
        final upload = _uploads[parts[1]];
        if (upload == null ||
            upload['client_id'] != clientId ||
            upload['admin_upload'] == true) {
          await _respond(
              request, HttpStatus.notFound, {'error': 'upload_not_found'});
          return;
        }
        final index = int.tryParse(parts[3]);
        if (index == null ||
            index != upload['chunk_count'] ||
            request.contentLength <= 0 ||
            request.contentLength > 2 * 1024 * 1024) {
          await _respond(
              request, HttpStatus.badRequest, {'error': 'invalid_chunk'});
          return;
        }
        try {
          final isEncrypted = upload['encrypted'] != false;
          final String? ciphertext;
          final List<int> bytes;
          if (isEncrypted) {
            ciphertext = await utf8.decoder.bind(request).join();
            bytes = base64Decode(
              DailyInviteCipher(client['invite_code'] as String)
                  .decrypt(ciphertext),
            );
          } else {
            ciphertext = null;
            bytes = await request.fold<List<int>>(
              <int>[],
              (all, next) => all..addAll(next),
            );
          }
          if (bytes.isEmpty ||
              bytes.length > 1024 * 1024 ||
              (!isEncrypted && request.contentLength > 1024 * 1024)) {
            throw const FormatException('Invalid attachment chunk.');
          }
          final directory = Directory(upload['directory'] as String);
          final chunkFile = File(
            '${directory.path}${Platform.pathSeparator}$index.chunk',
          );
          if (isEncrypted) {
            await chunkFile.writeAsString(ciphertext!, flush: true);
          } else {
            await chunkFile.writeAsBytes(bytes, flush: true);
          }
          upload['chunk_count'] = index + 1;
          upload['received_bytes'] =
              (upload['received_bytes'] as int) + bytes.length;
          if ((upload['received_bytes'] as int) > (upload['size'] as int)) {
            throw const FormatException('Attachment size mismatch.');
          }
          await _respond(request, HttpStatus.ok, {'ok': true});
        } on FormatException {
          await _respond(
              request, HttpStatus.badRequest, {'error': 'invalid_chunk'});
        } on FileSystemException catch (error) {
          await _respond(
              request, 507, {'error': 'disk_error', 'message': error.message});
        }
        return;
      }
      if (parts.length == 3 &&
          parts[0] == 'media' &&
          parts[2] == 'complete' &&
          request.method == 'POST') {
        final uploadId = parts[1];
        final upload = _uploads[uploadId];
        if (upload == null ||
            upload['client_id'] != clientId ||
            upload['admin_upload'] == true) {
          await _respond(
              request, HttpStatus.notFound, {'error': 'upload_not_found'});
          return;
        }
        try {
          final payload = await _readJsonPayload(request, 4096);
          if (payload is! Map || payload['completion_cipher'] is! String) {
            throw const FormatException('Invalid completion request.');
          }
          final completion = jsonDecode(
            DailyInviteCipher(client['invite_code'] as String)
                .decrypt(payload['completion_cipher'] as String),
          );
          if (completion is! Map ||
              completion['size'] != upload['size'] ||
              completion['size'] != upload['received_bytes'] ||
              completion['chunk_count'] != upload['chunk_count'] ||
              (completion['chunk_count'] as int? ?? 0) <= 0) {
            throw const FormatException('Attachment size mismatch.');
          }
          if (upload['preview_data'] is! String) {
            final previewData = await _generateUploadPreview(upload, client);
            if (previewData != null) upload['preview_data'] = previewData;
          }
          final mediaId = _randomToken(18);
          final root = await _getMediaRoot();
          final destination = Directory(
            '${root.path}${Platform.pathSeparator}$mediaId',
          );
          await Directory(upload['directory'] as String)
              .rename(destination.path);
          final media = <String, dynamic>{
            'id': mediaId,
            'client_id': clientId,
            'file_name': upload['file_name'],
            'mime_type': upload['mime_type'],
            'encrypted': upload['encrypted'] != false,
            'size': upload['size'],
            'chunk_count': upload['chunk_count'],
            if (upload['preview_data'] is String)
              'preview_data': upload['preview_data'],
          };
          _media[mediaId] = media;
          final message = <String, dynamic>{
            'id': upload['message_id'],
            'client_id': clientId,
            'sender': 'client',
            'body': (upload['body'] as String).trim(),
            'created_at': DateTime.now().toUtc().toIso8601String(),
            'media_id': mediaId,
            'file_name': upload['file_name'],
            'mime_type': upload['mime_type'],
            'media_size': upload['size'],
            'chunk_count': upload['chunk_count'],
            if (upload['preview_data'] is String)
              'preview_data': upload['preview_data'],
          };
          _messages.add(message);
          _uploads.remove(uploadId);
          await _cache.putMapList(_mediaKey, _media.values.toList());
          await _cache.putMapList(_messagesKey, _messages);
          _notify();
          await _respond(request, HttpStatus.created, {
            'message_cipher': DailyInviteCipher(client['invite_code'] as String)
                .encrypt(jsonEncode(message)),
          });
        } on FormatException {
          await _respond(
              request, HttpStatus.badRequest, {'error': 'invalid_attachment'});
        } on FileSystemException catch (error) {
          await _respond(
              request, 507, {'error': 'disk_error', 'message': error.message});
        }
        return;
      }
      await _respond(request, HttpStatus.notFound, {'error': 'not_found'});
    }

    if (request.uri.path == '/media/start') {
      await handleMediaStart(request, clientIp);
      return;
    }
    if (request.uri.path.startsWith('/media/')) {
      await handleMediaChunkOrComplete(request);
      return;
    }
    final client = _registeredClients[clientId];
    if (client == null ||
        !_constantTimeEquals(token ?? '', client['token'] as String)) {
      await _respond(request, HttpStatus.forbidden, {'error': 'unauthorized'});
      return;
    }
    if (request.contentLength <= 0 ||
        request.contentLength > 42 * 1024 * 1024) {
      await _respond(request, HttpStatus.badRequest, {
        'error': 'invalid_request',
      });
      return;
    }
    late final Object? payload;
    try {
      payload = jsonDecode(await utf8.decoder.bind(request).join());
    } on FormatException {
      await _respond(request, HttpStatus.badRequest, {
        'error': 'invalid_request',
      });
      return;
    }
    if (payload is! Map ||
        payload['id'] is! String ||
        payload['content_cipher'] is! String) {
      await _respond(request, HttpStatus.badRequest, {
        'error': 'invalid_request',
      });
      return;
    }
    final messageId = payload['id'] as String;
    final existing = _messages.where(
      (message) =>
          message['client_id'] == clientId && message['id'] == messageId,
    );
    if (existing.isNotEmpty) {
      await _respond(request, HttpStatus.created, {
        'message_cipher': DailyInviteCipher(client['invite_code'] as String)
            .encrypt(jsonEncode(existing.first)),
      });
      return;
    }
    try {
      final content = jsonDecode(
        DailyInviteCipher(client['invite_code'] as String)
            .decrypt(payload['content_cipher'] as String),
      );
      if (content is! Map ||
          content['file_name'] is! String ||
          content['mime_type'] is! String ||
          content['data'] is! String ||
          content['body'] is! String) {
        throw const FormatException('Invalid encrypted attachment.');
      }
      final message = await _storeMediaMessage(
        clientId: clientId,
        sender: 'client',
        messageId: messageId,
        fileName: content['file_name'] as String,
        mimeType: content['mime_type'] as String,
        data: content['data'] as String,
        body: content['body'] as String,
      );
      _registeredClients[clientId]!['last_seen'] =
          DateTime.now().toUtc().toIso8601String();
      _registeredClients[clientId]!['ip'] = clientIp;
      await _saveRegisteredClients();
      _notify();
      await _respond(request, HttpStatus.created, {
        'message_cipher': DailyInviteCipher(
          _registeredClients[clientId]!['invite_code'] as String,
        ).encrypt(jsonEncode(message)),
      });
    } on ArgumentError {
      await _respond(request, HttpStatus.badRequest, {
        'error': 'invalid_attachment',
      });
    } on FormatException {
      await _respond(request, HttpStatus.badRequest, {
        'error': 'invalid_attachment',
      });
    } on StateError {
      await _respond(request, 413, {
        'error': 'storage_limit',
      });
    }
  }

  Future<void> _handleMediaDownload(
    HttpRequest request,
    String clientIp,
  ) async {
    final clientId = request.headers.value('X-Client-Id');
    final token = request.headers.value('X-Client-Token');
    final path = request.uri.pathSegments;
    final isChunk = path.length == 4 && path[2] == 'chunk';
    final mediaId = path.length == 2 || isChunk ? path[1] : '';
    final client = clientId == null ? null : _registeredClients[clientId];
    if (client == null ||
        !_constantTimeEquals(token ?? '', client['token'] as String) ||
        _media[mediaId]?['client_id'] != clientId) {
      await _respond(request, HttpStatus.forbidden, {'error': 'unauthorized'});
      return;
    }
    final media = _media[mediaId]!;
    if (isChunk) {
      final index = int.tryParse(path[3]);
      if (index == null ||
          index < 0 ||
          index >= (media['chunk_count'] as int? ?? 0)) {
        await _respond(request, HttpStatus.notFound, {'error': 'not_found'});
        return;
      }
      try {
        final mediaDirectory = await _getMediaDirectory(mediaId);
        final file = File(
          '${mediaDirectory.path}${Platform.pathSeparator}$index.chunk',
        );
        if (media['encrypted'] == false) {
          await _respondBytes(
            request,
            HttpStatus.ok,
            await file.readAsBytes(),
          );
        } else {
          await _respond(request, HttpStatus.ok, {
            'chunk_cipher': await file.readAsString(),
          });
        }
      } on FileSystemException catch (error) {
        await _respond(request, HttpStatus.internalServerError, {
          'error': 'disk_error',
          'message': error.message,
        });
      }
      return;
    }
    if (media['data'] is! String) {
      await _respond(
          request, HttpStatus.badRequest, {'error': 'chunk_required'});
      return;
    }
    await _respond(request, HttpStatus.ok, {
      'content_cipher': DailyInviteCipher(
        client['invite_code'] as String,
      ).encrypt(jsonEncode({
        'file_name': media['file_name'] as String,
        'mime_type': media['mime_type'] as String,
        'data': media['data'] as String,
      })),
    });
  }

  Future<Map<String, dynamic>> _storeMediaMessage({
    required String clientId,
    required String sender,
    required String messageId,
    required String fileName,
    required String mimeType,
    required String data,
    required String body,
  }) async {
    final trimmedName = fileName.replaceAll('\\', '/').split('/').last.trim();
    if (messageId.trim().isEmpty ||
        messageId.length > 128 ||
        trimmedName.isEmpty ||
        trimmedName.length > 255 ||
        mimeType.trim().isEmpty ||
        mimeType.length > 128 ||
        body.length > 8000) {
      throw ArgumentError('Invalid attachment metadata.');
    }
    late final List<int> bytes;
    try {
      bytes = base64Decode(data);
    } on FormatException {
      rethrow;
    }
    if (bytes.isEmpty) throw ArgumentError('Attachment must not be empty.');
    final mediaId = _randomToken(18);
    final client = _registeredClients[clientId];
    if (client == null) throw StateError('Unknown client.');
    const chunkSize = 1024 * 1024;
    final root = await _getMediaRoot();
    final directory = Directory(
      '${root.path}${Platform.pathSeparator}$mediaId',
    );
    await directory.create(recursive: true);
    var chunkCount = 0;
    final cipher = DailyInviteCipher(client['invite_code'] as String);
    for (var offset = 0; offset < bytes.length; offset += chunkSize) {
      final end = (offset + chunkSize).clamp(0, bytes.length);
      final encrypted =
          cipher.encrypt(base64Encode(bytes.sublist(offset, end)));
      await File(
        '${directory.path}${Platform.pathSeparator}$chunkCount.chunk',
      ).writeAsString(encrypted, flush: true);
      chunkCount++;
    }
    final media = <String, dynamic>{
      'id': mediaId,
      'client_id': clientId,
      'file_name': trimmedName,
      'mime_type': mimeType.trim(),
      'size': bytes.length,
      'chunk_count': chunkCount,
    };
    _media[mediaId] = media;
    await _cache.putMapList(_mediaKey, _media.values.toList());
    final message = <String, dynamic>{
      'id': messageId.trim(),
      'client_id': clientId,
      'sender': sender,
      'body': body.trim(),
      'created_at': DateTime.now().toUtc().toIso8601String(),
      'media_id': mediaId,
      'file_name': trimmedName,
      'mime_type': mimeType.trim(),
      'media_size': bytes.length,
      'chunk_count': chunkCount,
    };
    _messages.add(message);
    await _cache.putMapList(_messagesKey, _messages);
    return message;
  }

  Future<void> _loadSavedState() async {
    if (_savedStateLoaded) return;
    final storedIps = _cache.value(_allowedIpsKey);
    if (storedIps is List) {
      _allowedIps.addAll(storedIps.whereType<String>());
    }
    var removedLegacyIdentityData = false;
    for (final savedClient in _cache.mapList(_registeredClientsKey)) {
      final client = Map<String, dynamic>.from(savedClient);
      removedLegacyIdentityData |= client.remove('identity_number') != null;
      final id = client['client_id'];
      if (id is String && client['token'] is String) {
        _registeredClients[id] = client;
      }
    }
    if (removedLegacyIdentityData) await _saveRegisteredClients();
    final storedInviteCodes = _cache.value(_availableInviteCodesKey);
    if (storedInviteCodes is List) {
      _availableInviteCodes.addAll(storedInviteCodes.whereType<String>());
    }
    final storedInviteCodeCreatedAt = _cache.value(_inviteCodeCreatedAtKey);
    if (storedInviteCodeCreatedAt is Map) {
      for (final entry in storedInviteCodeCreatedAt.entries) {
        if (entry.key is String && entry.value is String) {
          _inviteCodeCreatedAt[entry.key as String] = entry.value as String;
        }
      }
    }
    final storedInvalidCodes = _cache.value(_invalidInviteCodesKey);
    if (storedInvalidCodes is List) {
      _invalidInviteCodes.addAll(storedInvalidCodes.whereType<String>());
    }
    for (final savedPath in _cache.mapList(_localMediaPathsKey)) {
      final savedClientId = savedPath['client_id'];
      final savedMessageId = savedPath['message_id'];
      final filePath = savedPath['file_path'];
      if (savedClientId is String &&
          savedMessageId is String &&
          filePath is String) {
        _localMediaPaths['$savedClientId:$savedMessageId'] = filePath;
      }
    }
    if (_cache.value('direct-host-identity-required-invite-codes') != null) {
      await _cache.putValue(
        'direct-host-identity-required-invite-codes',
        <String>[],
      );
    }
    var pendingMessagesNeedSave = false;
    for (final savedMessage in _cache.mapList(_messagesKey)) {
      final message = Map<String, dynamic>.from(savedMessage);
      if (message['pending'] == true &&
          (message['delivery_state'] == 'preparing' ||
              message['delivery_state'] == 'uploading' ||
              message['delivery_state'] == 'queued')) {
        var filePath = message['file_path'] as String?;
        final expectedSize = message['media_size'];
        var hasFile = filePath != null &&
            expectedSize is int &&
            await File(filePath).exists() &&
            await File(filePath).length() == expectedSize;
        if (!hasFile &&
            filePath != null &&
            expectedSize is int &&
            message['file_name'] is String) {
          final extension =
              _pendingAttachmentExtension(message['file_name'] as String);
          if (extension != '.attachment') {
            final recoveredPath =
                '${File(filePath).parent.path}${Platform.pathSeparator}'
                '${message['id']}$extension';
            final recoveredFile = File(recoveredPath);
            if (await recoveredFile.exists() &&
                await recoveredFile.length() == expectedSize) {
              filePath = recoveredPath;
              message['file_path'] = recoveredPath;
              hasFile = true;
            }
          }
        }
        if (hasFile) {
          message['delivery_state'] = 'queued';
        } else {
          message
            ..['delivery_state'] = 'failed'
            ..['upload_error'] = '待发送附件文件不存在，请重新选择文件。';
        }
        pendingMessagesNeedSave = true;
      }
      _messages.add(message);
    }
    for (final savedMedia in _cache.mapList(_mediaKey)) {
      final media = Map<String, dynamic>.from(savedMedia);
      final id = media['id'];
      if (id is! String) continue;
      if (media['data'] is String) {
        final clientId = media['client_id'];
        final client = clientId is String ? _registeredClients[clientId] : null;
        if (client != null) {
          final bytes = base64Decode(media['data'] as String);
          const chunkSize = 1024 * 1024;
          final root = await _getMediaRoot();
          final directory = Directory(
            '${root.path}${Platform.pathSeparator}$id',
          );
          await directory.create(recursive: true);
          final cipher = DailyInviteCipher(client['invite_code'] as String);
          var count = 0;
          for (var offset = 0; offset < bytes.length; offset += chunkSize) {
            final end = (offset + chunkSize).clamp(0, bytes.length);
            await File(
              '${directory.path}${Platform.pathSeparator}$count.chunk',
            ).writeAsString(
              cipher.encrypt(base64Encode(bytes.sublist(offset, end))),
              flush: true,
            );
            count++;
          }
          media
            ..remove('data')
            ..['size'] = bytes.length
            ..['chunk_count'] = count;
        }
      }
      media.remove('data');
      _media[id] = media;
    }
    await _cache.putMapList(_mediaKey, _media.values.toList());
    if (pendingMessagesNeedSave) {
      await _cache.putMapList(_messagesKey, _messages);
    }
    _savedStateLoaded = true;
  }

  Future<void> _saveLocalMediaPaths() => _cache.putMapList(
        _localMediaPathsKey,
        _localMediaPaths.entries.map((entry) {
          final separator = entry.key.indexOf(':');
          return {
            'client_id': entry.key.substring(0, separator),
            'message_id': entry.key.substring(separator + 1),
            'file_path': entry.value,
          };
        }).toList(),
      );

  Future<void> _saveAllowedIps() =>
      _cache.putValue(_allowedIpsKey, _allowedIps.toList());

  Future<void> _saveRegisteredClients() => _cache.putMapList(
        _registeredClientsKey,
        _registeredClients.values.toList(),
      );

  Future<void> _saveInviteCodes() async {
    await _cache.putValue(
      _availableInviteCodesKey,
      _availableInviteCodes.toList(),
    );
    await _cache.putValue(
      _invalidInviteCodesKey,
      _invalidInviteCodes.toList(),
    );
    await _cache.putValue(
      _inviteCodeCreatedAtKey,
      Map<String, String>.from(_inviteCodeCreatedAt),
    );
  }

  String? _lastChatAt(String? clientId) {
    if (clientId == null) return null;
    DateTime? latest;
    for (final message in _messages) {
      if (message['client_id'] != clientId) continue;
      final timestamp =
          DateTime.tryParse(message['created_at']?.toString() ?? '');
      if (timestamp != null && (latest == null || timestamp.isAfter(latest))) {
        latest = timestamp;
      }
    }
    return latest?.toUtc().toIso8601String();
  }

  String _randomToken(int byteLength) {
    final random = Random.secure();
    return base64UrlEncode(
      List<int>.generate(byteLength, (_) => random.nextInt(256)),
    ).replaceAll('=', '');
  }

  void _recordRequest(
    String clientIp, {
    String? clientId,
    String? clientName,
  }) {
    final previous = _clients[clientIp];
    if (previous == null && _clients.length >= 2048) {
      final oldest = _clients.values.reduce(
        (left, right) => left.lastSeen.isBefore(right.lastSeen) ? left : right,
      );
      _clients.remove(oldest.address);
      _failedAttempts.remove(oldest.address);
    }
    _clients[clientIp] = InviteClientRequest(
      address: clientIp,
      firstSeen: previous?.firstSeen ?? DateTime.now(),
      lastSeen: DateTime.now(),
      requests: (previous?.requests ?? 0) + 1,
      clientId: clientId ?? previous?.clientId,
      clientName: clientName ?? previous?.clientName,
    );
    _notify();
  }

  void _recordClientDetails(
    String clientIp, {
    required String clientId,
    required String clientName,
  }) {
    final previous = _clients[clientIp];
    if (previous == null) return;
    _clients[clientIp] = InviteClientRequest(
      address: previous.address,
      firstSeen: previous.firstSeen,
      lastSeen: previous.lastSeen,
      requests: previous.requests,
      clientId: clientId,
      clientName: clientName,
    );
    _notify();
  }

  Future<void> _respond(
    HttpRequest request,
    int status,
    Map<String, Object?> payload,
  ) async {
    AppLogger.log('http.response', details: {
      'method': request.method,
      'route': request.uri.path,
      'status': status,
    });
    request.response
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..headers.set(HttpHeaders.cacheControlHeader, 'no-store')
      ..headers.set('X-Content-Type-Options', 'nosniff');
    request.response.write(jsonEncode(payload));
    await request.response.close();
  }

  Future<void> _respondBytes(
    HttpRequest request,
    int status,
    List<int> bytes,
  ) async {
    AppLogger.log('http.response', details: {
      'method': request.method,
      'route': request.uri.path,
      'status': status,
    });
    request.response
      ..statusCode = status
      ..headers.contentType = ContentType('application', 'octet-stream')
      ..headers.set(HttpHeaders.cacheControlHeader, 'no-store')
      ..headers.set('X-Content-Type-Options', 'nosniff')
      ..contentLength = bytes.length;
    request.response.add(bytes);
    await request.response.close();
  }
}

class InviteClientRequest {
  const InviteClientRequest({
    required this.address,
    required this.firstSeen,
    required this.lastSeen,
    required this.requests,
    this.clientId,
    this.clientName,
  });

  final String address;
  final DateTime firstSeen;
  final DateTime lastSeen;
  final int requests;
  final String? clientId;
  final String? clientName;
}

String normalizeIp(String address) {
  final trimmed = address.trim();
  final parsed = InternetAddress.tryParse(trimmed);
  if (parsed == null) throw FormatException('Invalid IP address: $address');
  final mapped = RegExp(
    r'^::ffff:(\d{1,3}(?:\.\d{1,3}){3})$',
    caseSensitive: false,
  ).firstMatch(parsed.address);
  if (mapped != null) return mapped.group(1)!;
  if (parsed.type != InternetAddressType.IPv6) return parsed.address;

  final groups = List<int>.generate(8, (index) {
    final offset = index * 2;
    return (parsed.rawAddress[offset] << 8) | parsed.rawAddress[offset + 1];
  });
  var bestStart = -1;
  var bestLength = 1;
  for (var index = 0; index < groups.length;) {
    if (groups[index] != 0) {
      index++;
      continue;
    }
    var end = index + 1;
    while (end < groups.length && groups[end] == 0) {
      end++;
    }
    if (end - index > bestLength) {
      bestStart = index;
      bestLength = end - index;
    }
    index = end;
  }
  if (bestStart == -1) {
    return groups.map((group) => group.toRadixString(16)).join(':');
  }

  final before =
      groups.take(bestStart).map((group) => group.toRadixString(16)).join(':');
  final after = groups
      .skip(bestStart + bestLength)
      .map((group) => group.toRadixString(16))
      .join(':');
  return '$before::$after';
}

bool _constantTimeEquals(String input, String expected) {
  final inputBytes = utf8.encode(input);
  final expectedBytes = utf8.encode(expected);
  var difference = inputBytes.length ^ expectedBytes.length;
  final length = inputBytes.length > expectedBytes.length
      ? inputBytes.length
      : expectedBytes.length;
  for (var index = 0; index < length; index++) {
    final left = index < inputBytes.length ? inputBytes[index] : 0;
    final right = index < expectedBytes.length ? expectedBytes[index] : 0;
    difference |= left ^ right;
  }
  return difference == 0;
}

class InviteHostApp extends StatefulWidget {
  const InviteHostApp({
    this.onBack,
    this.bindAddress,
    required this.cache,
    super.key,
  });

  final VoidCallback? onBack;
  final InternetAddress? bindAddress;
  final InviteHostStore cache;

  @override
  State<InviteHostApp> createState() => _InviteHostAppState();
}

class _InviteHostAppState extends State<InviteHostApp> {
  late final InviteHostController _controller;
  final _code = TextEditingController();
  final _inviteCodesInput = TextEditingController();
  final _inviteSearch = TextEditingController();
  final _clientChatSearch = TextEditingController();
  final _port = TextEditingController(text: '8443');
  String _inviteFilter = '全部';
  bool _isAddingInviteCodes = false;
  bool _busy = false;
  String? _error;
  Timer? _adminCodeSaveTimer;
  final Map<String, String> _downloadedMediaPaths = {};
  final Set<String> _activeAdminUploads = {};
  final Set<String> _queuedAdminUploadIds = {};
  Future<void> _adminUploadQueue = Future<void>.value();

  @override
  void initState() {
    super.initState();
    _controller = InviteHostController(widget.cache);
    _code.text = widget.cache.value('direct-host-admin-code') as String? ??
        widget.cache.value('remote-admin-code') as String? ??
        '';
  }

  @override
  void dispose() {
    _controller.dispose();
    _adminCodeSaveTimer?.cancel();
    _code.dispose();
    _inviteCodesInput.dispose();
    _inviteSearch.dispose();
    _clientChatSearch.dispose();
    _port.dispose();
    super.dispose();
  }

  Future<void> _uploadPendingAdminMessage(
    Map<String, dynamic> message,
  ) async {
    final messageId = message['id'].toString();
    if (!_queuedAdminUploadIds.add(messageId)) return;
    final queued = _adminUploadQueue.then(
      (_) => _uploadPendingAdminMessageNow(message),
    );
    _adminUploadQueue = queued.then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {
        AppLogger.log(
          'admin.attachment_queue_failed',
          level: 'error',
          error: error,
          stackTrace: stackTrace,
        );
      },
    );
    try {
      await queued;
    } finally {
      _queuedAdminUploadIds.remove(messageId);
    }
  }

  Future<void> _uploadPendingAdminMessageNow(
    Map<String, dynamic> message,
  ) async {
    final messageId = message['id'].toString();
    final clientId = message['client_id'].toString();
    if (!_activeAdminUploads.add(messageId)) return;
    try {
      final savedPath = message['file_path'];
      if (savedPath is! String || !await File(savedPath).exists()) {
        throw const FileSystemException('待发送附件文件不存在。');
      }
      var filePath = savedPath;
      final sourceFile = File(filePath);
      final fileSize = message['media_size'] as int;
      if (await sourceFile.length() != fileSize) {
        throw const FileSystemException('待发送附件大小已变化。');
      }
      final extension = _pendingAttachmentExtension(
        message['file_name'] as String,
      );
      if (sourceFile.uri.pathSegments.last.endsWith('.attachment') &&
          extension != '.attachment') {
        final renamedPath =
            '${sourceFile.parent.path}${Platform.pathSeparator}$messageId$extension';
        final renamedFile = File(renamedPath);
        if (await renamedFile.exists()) {
          if (await renamedFile.length() != fileSize) {
            throw const FileSystemException('待发送附件文件名冲突。');
          }
          await sourceFile.delete();
        } else {
          await sourceFile.rename(renamedPath);
        }
        filePath = renamedPath;
        await _controller.updatePendingMediaMessage(
          clientId,
          messageId,
          {'file_path': filePath},
        );
      }
      var previewData = message['preview_data'] as String?;
      final mimeType = message['mime_type'] as String;
      if (previewData == null &&
          (mimeType.startsWith('image/') || mimeType.startsWith('video/'))) {
        previewData = await createDirectMediaPreview(
          filePath: filePath,
          mimeType: mimeType,
        );
        if (previewData != null) {
          message['preview_data'] = previewData;
          await _controller.updatePendingMediaMessage(
            clientId,
            messageId,
            {'preview_data': previewData},
          );
        }
      }
      await _controller.updatePendingMediaMessage(
        clientId,
        messageId,
        {
          'delivery_state': 'uploading',
          'upload_progress': 0,
          'pending': true,
        },
      );
      await _controller.sendMediaFile(
        clientId: clientId,
        messageId: messageId,
        fileName: message['file_name'] as String,
        mimeType: mimeType,
        filePath: filePath,
        fileSize: fileSize,
        previewData: previewData,
        onProgress: (progress) {
          unawaited(_controller.updatePendingMediaMessage(
            clientId,
            messageId,
            {'upload_progress': progress},
            persist: false,
          ));
        },
      );
      await _controller.rememberLocalMediaPath(clientId, messageId, filePath);
    } catch (error, stackTrace) {
      AppLogger.log(
        'admin.attachment_upload_failed',
        level: 'error',
        details: {'client_id': clientId, 'message_id': messageId},
        error: error,
        stackTrace: stackTrace,
      );
      await _controller.updatePendingMediaMessage(
        clientId,
        messageId,
        {
          'delivery_state': 'failed',
          'upload_error': error.toString(),
        },
      );
      if (mounted) {
        setState(() => _error = '附件发送失败，可在聊天中重试：$error');
      }
    } finally {
      _activeAdminUploads.remove(messageId);
    }
  }

  Future<void> _toggleServer() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_controller.isRunning) {
        AppLogger.log('server.stop_requested');
        await _controller.stop();
        return;
      }
      final port = int.tryParse(_port.text.trim());
      if (port == null) throw StateError('Enter a valid server port.');
      final code = _code.text.trim();
      _adminCodeSaveTimer?.cancel();
      await _saveAdminCode(code);
      final identity = await loadOrCreateServerTlsIdentity(widget.cache);
      await _controller.start(
        port: port,
        code: code,
        certificate: identity.certificate,
        privateKey: identity.privateKey,
        certificateFingerprint: identity.fingerprint,
        bindAddress: widget.bindAddress,
      );
      AppLogger.log('server.start_succeeded', details: {'port': port});
    } catch (error) {
      AppLogger.log('server.start_or_stop_failed',
          level: 'error', error: error);
      if (mounted) setState(() => _error = 'Could not start server: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _saveAdminCode(String code) async {
    if (code.isEmpty) return;
    await widget.cache.putValue('direct-host-admin-code', code);
    await widget.cache.putValue('remote-admin-code', code);
  }

  Future<void> _changeCode(BuildContext context) async {
    final newCode = await _askForSecret(
      context: context,
      title: 'Change admin password',
      label: 'New admin password (at least 8 characters)',
    );
    if (!context.mounted) return;
    if (newCode == null) return;
    try {
      _controller.changeInviteCode(newCode);
      _code.text = newCode.trim();
      await _saveAdminCode(newCode.trim());
      if (mounted && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Admin password changed.')),
        );
      }
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  Future<void> _addInviteCodes(
    BuildContext context, {
    VoidCallback? onAdded,
  }) async {
    try {
      await _controller.addInviteCodes(_inviteCodesInput.text);
      _inviteCodesInput.clear();
      onAdded?.call();
      if (mounted) setState(() {});
      if (mounted && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('客户端邀请码已添加。')),
        );
      }
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  Future<void> _showInviteDetails(
    BuildContext context,
    Map<String, dynamic> invite,
  ) async {
    final code = invite['code'].toString();
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('邀请码信息'),
        content: SizedBox(
          width: 440,
          child: ListView(
            shrinkWrap: true,
            children: [
              ListTile(
                  title: const Text('邀请码'), subtitle: SelectableText(code)),
              ListTile(
                title: const Text('状态'),
                subtitle: Text(invite['status'].toString()),
              ),
              ListTile(
                title: const Text('姓名'),
                subtitle: Text(invite['client_name']?.toString() ?? '尚未使用'),
              ),
              ListTile(
                title: const Text('手机名称'),
                subtitle: Text(invite['device_name']?.toString() ?? '尚未使用'),
              ),
              ListTile(
                title: const Text('公网 IP'),
                subtitle: Text(invite['ip']?.toString() ?? '尚未使用'),
              ),
              ListTile(
                title: const Text('客户端 ID'),
                subtitle: SelectableText(
                  invite['client_id']?.toString() ?? '尚未使用',
                ),
              ),
              if (invite['created_at'] != null)
                ListTile(
                  title: const Text('首次注册'),
                  subtitle: Text(
                    _dateTime(DateTime.parse(invite['created_at'].toString())),
                  ),
                ),
              if (invite['last_seen'] != null)
                ListTile(
                  title: const Text('最近活动'),
                  subtitle: Text(
                    _dateTime(DateTime.parse(invite['last_seen'].toString())),
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Future<void> _showClientDetails(
    BuildContext context,
    Map<String, dynamic> client,
  ) async {
    final clientId = client['client_id'] as String;
    final code = client['invite_code']?.toString() ?? '';
    final apkNameController = TextEditingController();
    var buildingApk = false;
    try {
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (dialogContext, setDialogState) => AlertDialog(
            title: Text(
              '客户端管理：${(client['remark'] as String? ?? '').isNotEmpty ? client['remark'] : client['client_name'] ?? client['device_name']}',
            ),
            content: SizedBox(
              width: 440,
              child: SelectionArea(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    ListTile(
                      title: const Text('姓名'),
                      subtitle:
                          SelectableText(client['client_name'].toString()),
                    ),
                    ListTile(
                      title: const Text('手机名称'),
                      subtitle: SelectableText(
                        client['device_name']?.toString() ??
                            client['client_name'].toString(),
                      ),
                    ),
                    ListTile(
                      title: const Text('备注'),
                      subtitle: SelectableText(
                        (client['remark'] as String? ?? '').isEmpty
                            ? '未设置'
                            : client['remark'].toString(),
                      ),
                      trailing: IconButton(
                        tooltip: '修改备注',
                        onPressed: () => _editClientRemark(context, client),
                        icon: const Icon(Icons.edit),
                      ),
                    ),
                    ListTile(
                      title: const Text('客户端 ID'),
                      subtitle: SelectableText(clientId),
                    ),
                    ListTile(
                      title: const Text('设备标识（哈希 Android ID）'),
                      subtitle: SelectableText(
                        _controller.deviceIdentityForClient(clientId) ??
                            '未提供（旧客户端）',
                      ),
                    ),
                    ListTile(
                      title: const Text('邀请码 / 状态'),
                      subtitle: SelectableText(
                        '$code · ${client['revoked'] == true ? '已撤销' : '有效'}',
                      ),
                    ),
                    ListTile(
                      title: const Text('公网 IP'),
                      subtitle: SelectableText(client['ip'].toString()),
                    ),
                    if (client['created_at'] is String)
                      ListTile(
                        title: const Text('首次注册'),
                        subtitle: SelectableText(
                          _dateTime(DateTime.parse(
                            client['created_at'] as String,
                          )),
                        ),
                      ),
                    if (client['last_seen'] is String)
                      ListTile(
                        title: const Text('最近活动'),
                        subtitle: SelectableText(
                          _dateTime(DateTime.parse(
                            client['last_seen'] as String,
                          )),
                        ),
                      ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: apkNameController,
                      enabled: !buildingApk,
                      decoration: const InputDecoration(
                        labelText: 'APK 名称',
                        hintText: '输入名称后生成 chat_client_名称.apk',
                      ),
                    ),
                    const SizedBox(height: 8),
                    FilledButton.icon(
                      onPressed: buildingApk || !Platform.isWindows
                          ? null
                          : () async {
                              final deviceIdentity =
                                  _controller.deviceIdentityForClient(clientId);
                              if (deviceIdentity == null) {
                                ScaffoldMessenger.of(dialogContext)
                                    .showSnackBar(
                                  const SnackBar(
                                    content: Text('此客户端没有设备标识，不能编译专属 APK。'),
                                  ),
                                );
                                return;
                              }
                              setDialogState(() => buildingApk = true);
                              try {
                                final outputPath = await buildDeviceClientApk(
                                  requestedName: apkNameController.text,
                                  deviceIdentity: deviceIdentity,
                                  serverUrl: Uri.parse(serverBaseUrl)
                                      .replace(port: _controller.port)
                                      .toString(),
                                );
                                if (dialogContext.mounted) {
                                  ScaffoldMessenger.of(dialogContext)
                                      .showSnackBar(
                                    SnackBar(
                                        content: Text('APK 已生成：$outputPath')),
                                  );
                                }
                              } catch (error) {
                                if (dialogContext.mounted) {
                                  ScaffoldMessenger.of(dialogContext)
                                      .showSnackBar(
                                    SnackBar(content: Text('编译失败：$error')),
                                  );
                                }
                              } finally {
                                if (dialogContext.mounted) {
                                  setDialogState(() => buildingApk = false);
                                }
                              }
                            },
                      icon: buildingApk
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.android),
                      label: Text(
                        buildingApk ? '正在编译，请稍候…' : '为此设备编译唯一 APK',
                      ),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('关闭'),
              ),
              if (code.isNotEmpty && client['revoked'] != true)
                TextButton(
                  onPressed: () async {
                    try {
                      await _controller.revokeInviteCode(code);
                      if (dialogContext.mounted) Navigator.pop(dialogContext);
                    } catch (error) {
                      if (dialogContext.mounted) {
                        ScaffoldMessenger.of(dialogContext).showSnackBar(
                          SnackBar(content: Text('撤销失败：$error')),
                        );
                      }
                    }
                  },
                  child: const Text('撤销授权'),
                ),
              FilledButton(
                onPressed: () {
                  Navigator.pop(dialogContext);
                  _changeClientInviteCode(context, client);
                },
                child: const Text('更换邀请码'),
              ),
            ],
          ),
        ),
      );
    } finally {
      apkNameController.dispose();
    }
  }

  Future<void> _editClientRemark(
    BuildContext context,
    Map<String, dynamic> client,
  ) async {
    final controller = TextEditingController(
      text: client['remark']?.toString() ?? '',
    );
    final remark = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('设置客户端备注'),
        content: TextField(
          controller: controller,
          maxLength: 80,
          decoration: const InputDecoration(hintText: '例如：家人手机、工作设备'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (remark == null) return;
    try {
      await _controller.setClientRemark(
        client['client_id'] as String,
        remark,
      );
    } catch (error) {
      if (mounted && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('保存备注失败：$error')),
        );
      }
    }
  }

  Future<void> _changeClientInviteCode(
    BuildContext context,
    Map<String, dynamic> client,
  ) async {
    final clientId = client['client_id'] as String;
    final newCode = await _askForSecret(
      context: context,
      title: 'Change ${client['client_name']} invite code',
      label: 'New unique invite code (at least 8 characters)',
    );
    if (!context.mounted) return;
    if (newCode == null) return;
    try {
      await _controller.changeClientInviteCode(clientId, newCode);
      if (mounted && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('邀请码已更新，旧客户端的授权将被撤销。'),
          ),
        );
      }
    } catch (error) {
      if (mounted) {
        setState(() => _error = 'Could not change client code: $error');
      }
    }
  }

  Future<String?> _askForSecret({
    required BuildContext context,
    required String title,
    required String label,
  }) {
    final text = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: text,
          obscureText: true,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(labelText: label),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, text.text),
            child: const Text('Confirm'),
          ),
        ],
      ),
    ).whenComplete(text.dispose);
  }

  Future<void> _replyToClient(
    BuildContext context,
    Map<String, dynamic> client,
  ) async {
    final clientId = client['client_id'] as String;
    final isRevoked = client['revoked'] == true;
    final input = TextEditingController();
    final recorder = AudioRecorder();
    final screenSize = MediaQuery.of(context).size;
    final chatWidth = (screenSize.width - 96).clamp(240.0, 900.0).toDouble();
    final messageHeight =
        (screenSize.height - 400).clamp(120.0, 600.0).toDouble();
    String? mediaError;
    var recording = false;
    var dialogOpen = true;
    VoidCallback? refreshListener;
    var refreshListenerAdded = false;
    var pendingUploadsScheduled = false;
    var selectionMode = false;
    final selectedMessageIds = <String>{};
    final optimisticMessages = <Map<String, dynamic>>[];
    final downloadingMessageIds = <String>{};
    final downloadProgress = <String, int>{};

    Future<void> openMessageAttachment(
      Map<String, dynamic> message,
      void Function(void Function()) setDialogState,
    ) async {
      final messageId = message['id'].toString();
      final localPath = message['media_path'] as String? ??
          _controller.localMediaPathForMessage(clientId, messageId) ??
          (message['encrypted_local'] == true
              ? null
              : message['file_path'] as String?);
      if (localPath != null) {
        final localFile = File(localPath);
        if (await localFile.exists() && await localFile.length() > 0) {
          message['media_path'] = localPath;
          final error = await openDirectAttachment(message);
          if (error != null && context.mounted) {
            ScaffoldMessenger.of(context)
                .showSnackBar(SnackBar(content: Text(error)));
          }
          return;
        }
        await _controller.forgetLocalMediaPath(clientId, messageId);
        message.remove('media_path');
      }
      if (!downloadingMessageIds.add(messageId)) return;
      setDialogState(() => downloadProgress[messageId] = 0);
      try {
        if (message['media_path'] is! String && message['media_id'] is String) {
          final mediaId = message['media_id'] as String;
          final path = await DirectAttachmentDownloads.instance.download(
            key: 'host:$clientId:$mediaId',
            expectedSize: message['media_size'] as int? ?? 0,
            sequential:
                (message['mime_type'] as String? ?? '').startsWith('video/'),
            onProgress: (progress) {
              downloadProgress[messageId] = progress;
              if (dialogOpen) setDialogState(() {});
            },
            download: (onProgress, isCancelled) =>
                _controller.downloadMediaToFile(
              message,
              isCancelled: isCancelled,
              onProgress: onProgress,
            ),
          );
          _downloadedMediaPaths[messageId] = path;
          message['media_path'] = path;
          if (dialogOpen) setDialogState(() {});
        }
        if (!dialogOpen) return;
        final error = await openDirectAttachment(message);
        if (error != null && context.mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(error)));
        }
      } on DirectDownloadCancelled {
        // The user cancelled; the incomplete file has already been removed.
      } catch (error) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('无法下载附件：$error')),
          );
        }
      } finally {
        downloadingMessageIds.remove(messageId);
        downloadProgress.remove(messageId);
        if (dialogOpen) setDialogState(() {});
      }
    }

    Future<void> sendMedia(
      String name,
      String mimeType,
      String? sourcePath,
      Stream<List<int>>? sourceStream,
      int fileSize,
      void Function(void Function()) setDialogState, [
      Map<String, dynamic>? retryMessage,
    ]) async {
      if (isRevoked) return;
      final messageId = retryMessage?['id'] as String? ?? _uuid.v4();
      final temporary = retryMessage ??
          <String, dynamic>{
            'id': messageId,
            'client_id': clientId,
            'sender': 'server',
            'body': '',
            'created_at': DateTime.now().toUtc().toIso8601String(),
            'file_name': name,
            'mime_type': mimeType,
            'media_size': fileSize,
            'pending': true,
            'delivery_state': 'preparing',
            'upload_progress': 0,
          };
      setDialogState(() {
        temporary
          ..remove('upload_error')
          ..['delivery_state'] = 'preparing'
          ..['upload_progress'] = 0
          ..['pending'] = true;
      });
      if (fileSize <= 0) {
        temporary['delivery_state'] = 'failed';
        temporary['upload_error'] = '所选文件为空。';
        await _controller.savePendingMediaMessage(temporary);
        setDialogState(() => mediaError = '所选文件为空。');
        return;
      }
      String? localPath;
      try {
        if (sourcePath != null) {
          temporary['file_path'] = sourcePath;
          await _controller.savePendingMediaMessage(temporary);
        }
        final pendingDirectory = await directCacheDirectory(
          'pending-attachments',
          segments: [clientId],
        );
        final extension = _pendingAttachmentExtension(name);
        final desiredPath =
            '${pendingDirectory.path}${Platform.pathSeparator}$messageId$extension';
        final retryPath = retryMessage?['file_path'];
        final reusablePath = retryPath is String ? retryPath : sourcePath;
        if (reusablePath != null &&
            reusablePath.startsWith(
                '${pendingDirectory.path}${Platform.pathSeparator}') &&
            await File(reusablePath).exists() &&
            await File(reusablePath).length() == fileSize) {
          if (reusablePath == desiredPath) {
            localPath = reusablePath;
          } else {
            await File(reusablePath).rename(desiredPath);
            localPath = desiredPath;
          }
        } else {
          localPath = desiredPath;
          final stream = sourceStream ??
              (sourcePath == null ? null : File(sourcePath).openRead());
          if (stream == null) throw const FileSystemException('无法读取所选文件。');
          final outputFile = File(localPath);
          final output = outputFile.openWrite();
          var copied = 0;
          try {
            await for (final chunk in stream) {
              copied += chunk.length;
              output.add(chunk);
            }
            await output.flush();
          } finally {
            await output.close();
          }
          if (copied != fileSize) {
            throw const FileSystemException('复制附件时文件大小发生变化。');
          }
        }
        temporary
          ..['file_path'] = localPath
          ..['delivery_state'] = 'queued'
          ..['pending'] = true;
        await _controller.savePendingMediaMessage(temporary);
        setDialogState(() {});
        unawaited(_uploadPendingAdminMessage(temporary));
        if (dialogOpen) setDialogState(() => mediaError = null);
      } catch (error) {
        if (localPath != null) {
          final localFile = File(localPath);
          if (!await localFile.exists() ||
              await localFile.length() != fileSize) {
            if (await localFile.exists()) await localFile.delete();
          }
        }
        temporary
          ..['delivery_state'] = 'failed'
          ..['upload_error'] = error.toString()
          ..['file_path'] = sourcePath;
        await _controller.savePendingMediaMessage(temporary);
        if (dialogOpen) setDialogState(() => mediaError = '附件发送失败，可重试：$error');
      } finally {
        if (dialogOpen) setDialogState(() {});
      }
    }

    Future<void> pickAndSendMedia(
      FileType type,
      void Function(void Function()) setDialogState,
    ) async {
      if (isRevoked) return;
      late final List<DirectPickedFile> files;
      try {
        if (type == FileType.media) {
          files = await pickDirectMediaFiles();
        } else {
          final result = await FilePicker.platform.pickFiles(
            type: type,
            allowMultiple: true,
            withReadStream: true,
          );
          files = [
            for (final file in result?.files ?? const <PlatformFile>[])
              DirectPickedFile(
                name: file.name,
                size: file.size,
                path: file.path,
                readStream: file.readStream,
              ),
          ];
        }
      } catch (error) {
        if (dialogOpen) setDialogState(() => mediaError = '打开相册失败：$error');
        return;
      }
      if (files.isEmpty) return;
      await Future.wait([
        for (final file in files)
          sendMedia(
            file.name,
            directMimeTypeForFile(file.name),
            file.path,
            file.readStream,
            file.size,
            setDialogState,
          ),
      ]);
    }

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            refreshListener ??= () {
              if (dialogOpen && dialogContext.mounted) {
                final latestClient = _controller.registeredClients
                    .where((entry) => entry['client_id'] == clientId)
                    .firstOrNull;
                if (latestClient != null) {
                  client['remark'] = latestClient['remark'];
                }
                setDialogState(() {});
              }
            };
            if (!refreshListenerAdded) {
              _controller.addListener(refreshListener!);
              refreshListenerAdded = true;
            }
            if (!pendingUploadsScheduled) {
              pendingUploadsScheduled = true;
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (!dialogOpen) return;
                for (final message in _controller.messagesFor(
                  clientId,
                  includeExpired: true,
                )) {
                  if (message['pending'] == true &&
                      message['delivery_state'] == 'queued') {
                    unawaited(_uploadPendingAdminMessage(message));
                  }
                }
              });
            }
            final messagesById = {
              for (final message
                  in _controller.messagesFor(clientId, includeExpired: true))
                message['id'].toString(): message,
              for (final message in optimisticMessages)
                message['id'].toString(): message,
            };
            final messages = messagesById.values.toList()
              ..sort(compareDirectMessages);
            final selectableMessages = messages
                .where((message) => message['pending'] != true)
                .toList();
            final selectableMessageIds = selectableMessages
                .map((message) => message['id'].toString())
                .toSet();
            final allMessagesSelected = selectableMessageIds.isNotEmpty &&
                selectedMessageIds.containsAll(selectableMessageIds);
            Future<void> sendText() async {
              final body = input.text.trim();
              if (body.isEmpty || isRevoked) return;
              input.clear();
              final temporary = <String, dynamic>{
                'id': _uuid.v4(),
                'client_id': clientId,
                'sender': 'server',
                'body': body,
                'created_at': DateTime.now().toUtc().toIso8601String(),
                'pending': true,
              };
              setDialogState(() => optimisticMessages.add(temporary));
              try {
                await _controller.sendMessage(clientId, body);
                optimisticMessages.remove(temporary);
                if (dialogOpen) setDialogState(() {});
              } catch (error) {
                if (dialogOpen) {
                  setDialogState(() {
                    optimisticMessages.remove(temporary);
                    input.text = body;
                    _error = '发送失败：$error';
                  });
                }
              }
            }

            Future<void> sendVibrationAlert() async {
              try {
                await _controller.sendVibrationAlert(clientId);
                if (dialogOpen) setDialogState(() {});
              } catch (error) {
                if (dialogOpen) {
                  setDialogState(() => _error = '发送震动提醒失败：$error');
                }
              }
            }

            Future<void> deleteSelected() async {
              if (selectedMessageIds.isEmpty) return;
              final confirmed = await showDialog<bool>(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('删除聊天记录'),
                  content: Text(
                    '确定永久删除选中的 ${selectedMessageIds.length} 条消息及其附件吗？',
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('取消'),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('删除'),
                    ),
                  ],
                ),
              );
              if (confirmed != true) return;
              try {
                await _controller.deleteMessages(clientId, selectedMessageIds);
                selectedMessageIds.clear();
                selectionMode = false;
                if (dialogOpen) setDialogState(() {});
              } catch (error) {
                if (dialogOpen) {
                  setDialogState(() => _error = '删除聊天记录失败：$error');
                }
              }
            }

            return AlertDialog(
              title: Row(
                children: [
                  Expanded(
                    child: Text(
                      '与 ${(client['remark'] as String? ?? '').isNotEmpty ? client['remark'] : client['client_name'] ?? client['device_name']} 聊天'
                      '${isRevoked ? '（授权已撤销，历史记录）' : ''}',
                    ),
                  ),
                  if (selectionMode)
                    IconButton(
                      tooltip: selectedMessageIds.isEmpty
                          ? '请选择消息'
                          : '删除 ${selectedMessageIds.length} 条消息',
                      onPressed:
                          selectedMessageIds.isEmpty ? null : deleteSelected,
                      icon: const Icon(Icons.delete_outline),
                    ),
                  IconButton(
                    tooltip: selectionMode ? '取消选择' : '选择删除消息',
                    onPressed: () => setDialogState(() {
                      selectionMode = !selectionMode;
                      selectedMessageIds.clear();
                    }),
                    icon: Icon(
                      selectionMode ? Icons.close : Icons.checklist,
                    ),
                  ),
                  IconButton(
                    tooltip: '客户端管理',
                    onPressed: () => _showClientDetails(context, client),
                    icon: const Icon(Icons.manage_accounts_outlined),
                  ),
                ],
              ),
              content: SizedBox(
                width: chatWidth,
                height: messageHeight + (selectionMode ? 120 : 64),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (selectionMode)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Row(
                          children: [
                            OutlinedButton.icon(
                              onPressed: () => setDialogState(() {
                                if (allMessagesSelected) {
                                  selectedMessageIds.clear();
                                } else {
                                  selectedMessageIds
                                    ..clear()
                                    ..addAll(selectableMessageIds);
                                }
                              }),
                              icon: Icon(
                                allMessagesSelected
                                    ? Icons.remove_done
                                    : Icons.select_all,
                              ),
                              label: Text(
                                allMessagesSelected ? '取消全选' : '全选',
                              ),
                            ),
                            const SizedBox(width: 12),
                            Text('已选 ${selectedMessageIds.length} 条'),
                          ],
                        ),
                      ),
                    SizedBox(
                      height: messageHeight,
                      child: messages.isEmpty
                          ? const Center(child: Text('还没有消息'))
                          : ScrollConfiguration(
                              behavior: ScrollConfiguration.of(context)
                                  .copyWith(scrollbars: false),
                              child: ListView(
                                reverse: true,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                ),
                                children: [
                                  for (final message in messages.reversed)
                                    Row(
                                      children: [
                                        if (selectionMode &&
                                            message['pending'] != true)
                                          Checkbox(
                                            value: selectedMessageIds.contains(
                                              message['id'].toString(),
                                            ),
                                            onChanged: (selected) =>
                                                setDialogState(() {
                                              final id =
                                                  message['id'].toString();
                                              if (selected == true) {
                                                selectedMessageIds.add(id);
                                              } else {
                                                selectedMessageIds.remove(id);
                                              }
                                            }),
                                          ),
                                        Expanded(
                                            child: _messageBubble(
                                          message,
                                          onRetry: message['delivery_state'] ==
                                                      'failed' &&
                                                  message['file_path'] is String
                                              ? () => sendMedia(
                                                    message['file_name']
                                                        as String,
                                                    message['mime_type']
                                                        as String,
                                                    message['file_path']
                                                        as String,
                                                    null,
                                                    message['media_size']
                                                        as int,
                                                    setDialogState,
                                                    message,
                                                  )
                                              : null,
                                          downloading:
                                              downloadingMessageIds.contains(
                                            message['id'].toString(),
                                          ),
                                          downloadProgress: downloadProgress[
                                              message['id'].toString()],
                                          onCancelDownload: () {
                                            final mediaId = message['media_id'];
                                            if (mediaId is String) {
                                              DirectAttachmentDownloads.instance
                                                  .cancel(
                                                'host:$clientId:$mediaId',
                                              );
                                            }
                                          },
                                          onOpenAttachment: () =>
                                              openMessageAttachment(
                                            message,
                                            setDialogState,
                                          ),
                                        )),
                                      ],
                                    ),
                                ],
                              ),
                            ),
                    ),
                    if (mediaError != null)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          mediaError!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Expanded(
                          child: TextField(
                            controller: input,
                            onChanged: (_) => setDialogState(() {}),
                            minLines: 1,
                            maxLines: 5,
                            keyboardType: TextInputType.multiline,
                            textInputAction: TextInputAction.newline,
                            scrollPhysics: const ClampingScrollPhysics(),
                            decoration: InputDecoration(
                              hintText: isRevoked ? '授权已撤销，仅可查看历史记录' : '输入回复',
                            ),
                            enabled: !isRevoked,
                          ),
                        ),
                        if (input.text.trim().isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(left: 4),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Text('发送'),
                                IconButton(
                                  tooltip: '发送',
                                  onPressed: sendText,
                                  icon: const Icon(Icons.send),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                    Align(
                      alignment: Alignment.center,
                      child: Wrap(
                        alignment: WrapAlignment.center,
                        children: [
                          IconButton(
                            tooltip: '发送震动提醒',
                            onPressed: isRevoked ? null : sendVibrationAlert,
                            icon: const Icon(Icons.vibration),
                          ),
                          IconButton(
                            tooltip: '发送图片或视频',
                            onPressed: isRevoked
                                ? null
                                : () => pickAndSendMedia(
                                      FileType.media,
                                      setDialogState,
                                    ),
                            icon: const Icon(Icons.image),
                          ),
                          IconButton(
                            tooltip: '发送文件',
                            onPressed: isRevoked
                                ? null
                                : () => pickAndSendMedia(
                                      FileType.any,
                                      setDialogState,
                                    ),
                            icon: const Icon(Icons.attach_file),
                          ),
                          IconButton(
                            tooltip: '上传此客户端的服务端头像',
                            onPressed: isRevoked
                                ? null
                                : () async {
                                    try {
                                      final result =
                                          await FilePicker.platform.pickFiles(
                                        type: FileType.image,
                                        allowMultiple: false,
                                        withData: true,
                                      );
                                      if (result == null ||
                                          result.files.isEmpty) {
                                        return;
                                      }
                                      final file = result.files.first;
                                      final bytes = file.bytes;
                                      if (bytes == null || bytes.isEmpty) {
                                        setDialogState(
                                          () => mediaError = '无法读取头像文件。',
                                        );
                                        return;
                                      }
                                      final mimeType =
                                          directMimeTypeForFile(file.name);
                                      if (bytes.length > 1024 * 1024 ||
                                          !const {
                                            'image/jpeg',
                                            'image/png',
                                            'image/webp',
                                          }.contains(mimeType)) {
                                        setDialogState(
                                          () => mediaError =
                                              '头像仅支持不超过 1 MB 的 JPG、PNG 或 WebP 图片。',
                                        );
                                        return;
                                      }
                                      await _controller
                                          .setServerAvatarForClient(
                                        clientId,
                                        data: base64Encode(bytes),
                                        mimeType: mimeType,
                                      );
                                      setDialogState(() => mediaError = null);
                                    } catch (error) {
                                      if (dialogOpen) {
                                        setDialogState(
                                          () => mediaError = '上传服务端头像失败：$error',
                                        );
                                      }
                                    }
                                  },
                            icon: const Icon(Icons.account_circle_outlined),
                          ),
                          IconButton(
                            tooltip: recording ? '停止并发送语音' : '录制语音',
                            onPressed: isRevoked
                                ? null
                                : () async {
                                    try {
                                      if (recording) {
                                        final path = await recorder.stop();
                                        setDialogState(() => recording = false);
                                        if (path == null) return;
                                        final file = File(path);
                                        await sendMedia(
                                          'voice-${DateTime.now().millisecondsSinceEpoch}.m4a',
                                          'audio/mp4',
                                          path,
                                          null,
                                          await file.length(),
                                          setDialogState,
                                        );
                                        await file.delete();
                                      } else {
                                        if (!await recorder.hasPermission()) {
                                          throw StateError('麦克风权限被拒绝。');
                                        }
                                        final directory =
                                            await getTemporaryDirectory();
                                        final path =
                                            '${directory.path}${Platform.pathSeparator}voice-${_uuid.v4()}.m4a';
                                        await recorder.start(
                                          const RecordConfig(
                                            encoder: AudioEncoder.aacLc,
                                          ),
                                          path: path,
                                        );
                                        setDialogState(() => recording = true);
                                      }
                                    } catch (error) {
                                      if (dialogContext.mounted) {
                                        setDialogState(
                                          () => recording = false,
                                        );
                                      }
                                      if (mounted) {
                                        setState(
                                          () => _error = '语音操作失败：$error',
                                        );
                                      }
                                    }
                                  },
                            icon: Icon(
                              recording ? Icons.stop_circle : Icons.mic,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('关闭'),
                ),
              ],
            );
          },
        );
      },
    );
    dialogOpen = false;
    final listener = refreshListener;
    if (listener != null) _controller.removeListener(listener);
    await recorder.dispose();
    input.dispose();
  }

  Widget _messageBubble(
    Map<String, dynamic> message, {
    VoidCallback? onRetry,
    VoidCallback? onOpenAttachment,
    VoidCallback? onCancelDownload,
    bool downloading = false,
    int? downloadProgress,
  }) {
    final media = _controller.mediaForMessage(message);
    final displayMessage = {
      ...message,
      if (media != null) 'media_size': media['size'],
      if (_controller.localMediaPathForMessage(
              message['client_id'] as String, message['id'].toString()) !=
          null)
        'media_path': _controller.localMediaPathForMessage(
          message['client_id'] as String,
          message['id'].toString(),
        ),
      if (_downloadedMediaPaths[message['id'].toString()] != null)
        'media_path': _downloadedMediaPaths[message['id'].toString()],
    };
    Widget buildBubble(int? activeProgress) => DirectMessageBubble(
          key: ValueKey(message['id'].toString()),
          message: displayMessage,
          outgoing: message['sender'] == 'server',
          avatarData: message['sender'] == 'server'
              ? _controller
                  .serverAvatarForClient(message['client_id'] as String)
              : _controller.avatarForClient(message['client_id'] as String),
          onRetry: onRetry,
          downloading: downloading || activeProgress != null,
          onCancelDownload: onCancelDownload,
          downloadProgress: downloadProgress ?? activeProgress,
          onOpenAttachment: onOpenAttachment ??
              () async {
                try {
                  if (displayMessage['media_path'] is! String &&
                      displayMessage['media_id'] is String) {
                    displayMessage['media_path'] =
                        await _controller.downloadMediaToFile(displayMessage);
                  }
                  final error = await openDirectAttachment(displayMessage);
                  if (error != null && mounted) {
                    ScaffoldMessenger.of(context)
                        .showSnackBar(SnackBar(content: Text(error)));
                  }
                } catch (error) {
                  if (mounted) {
                    ScaffoldMessenger.of(context)
                        .showSnackBar(SnackBar(content: Text('无法打开附件：$error')));
                  }
                }
              },
        );
    final mediaId = message['media_id'];
    if (mediaId is! String) return buildBubble(null);
    return ValueListenableBuilder<int?>(
      valueListenable: DirectAttachmentDownloads.instance.progressListenable(
        'host:${message['client_id']}:$mediaId',
      ),
      builder: (context, activeProgress, _) => buildBubble(activeProgress),
    );
  }

  String _dateTime(DateTime value) =>
      value.toLocal().toString().substring(0, 16);

  Size _dialogContentSize(
    BuildContext context, {
    required double width,
    required double height,
  }) {
    final screenSize = MediaQuery.of(context).size;
    final availableWidth = screenSize.width - (Platform.isWindows ? 96 : 32);
    final availableHeight =
        (screenSize.height - 240).clamp(120.0, height).toDouble();
    return Size(
      width < availableWidth ? width : availableWidth,
      height < availableHeight ? height : availableHeight,
    );
  }

  Future<void> _showInviteCodesDialog(BuildContext context) {
    _isAddingInviteCodes = false;
    return showDialog<void>(
      context: context,
      builder: (dialogContext) => AnimatedBuilder(
        animation: _controller,
        builder: (context, _) => StatefulBuilder(
          builder: (context, setDialogState) {
            final dialogSize = _dialogContentSize(
              context,
              width: 620,
              height: 520,
            );
            final query = _inviteSearch.text.trim().toLowerCase();
            final invites = _controller.inviteCodes.where((item) {
              final status = item['status'].toString();
              if (_inviteFilter != '全部' && status != _inviteFilter) {
                return false;
              }
              final searchText = [
                item['code'],
                item['client_name'],
                item['device_name'],
                item['ip'],
              ].whereType<Object>().join(' ').toLowerCase();
              return query.isEmpty || searchText.contains(query);
            }).toList();
            return AlertDialog(
              title: const Text('邀请码管理'),
              content: SizedBox(
                width: dialogSize.width,
                height: dialogSize.height,
                child: Column(
                  children: [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: () => setDialogState(
                          () => _isAddingInviteCodes = !_isAddingInviteCodes,
                        ),
                        icon: Icon(
                          _isAddingInviteCodes ? Icons.close : Icons.add,
                        ),
                        label: Text(
                          _isAddingInviteCodes ? '取消添加邀请码' : '批量添加邀请码',
                        ),
                      ),
                    ),
                    if (_isAddingInviteCodes) ...[
                      const Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          '每行输入一个 8 到 256 位邀请码。每个口令只允许绑定一个客户端。',
                        ),
                      ),
                      TextField(
                        controller: _inviteCodesInput,
                        minLines: 2,
                        maxLines: 3,
                        autocorrect: false,
                        enableSuggestions: false,
                        decoration: const InputDecoration(
                          hintText: '每行一个邀请码',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      Align(
                        alignment: Alignment.centerRight,
                        child: FilledButton.icon(
                          onPressed: () => _addInviteCodes(
                            context,
                            onAdded: () => setDialogState(
                              () => _isAddingInviteCodes = false,
                            ),
                          ),
                          icon: const Icon(Icons.add),
                          label: const Text('添加邀请码'),
                        ),
                      ),
                    ] else ...[
                      TextField(
                        controller: _inviteSearch,
                        onChanged: (_) => setDialogState(() {}),
                        decoration: const InputDecoration(
                          labelText: '搜索邀请码、姓名、手机名称或 IP',
                          prefixIcon: Icon(Icons.search),
                          isDense: true,
                        ),
                      ),
                      DropdownButtonFormField<String>(
                        initialValue: _inviteFilter,
                        decoration: const InputDecoration(labelText: '分类'),
                        items: const [
                          DropdownMenuItem(value: '全部', child: Text('全部')),
                          DropdownMenuItem(value: '可用', child: Text('可用')),
                          DropdownMenuItem(value: '已绑定', child: Text('已绑定')),
                          DropdownMenuItem(value: '已失效', child: Text('已失效')),
                        ],
                        onChanged: (value) {
                          if (value != null) {
                            setDialogState(() => _inviteFilter = value);
                          }
                        },
                      ),
                      Expanded(
                        child: invites.isEmpty
                            ? Center(
                                child: Text(
                                  _controller.inviteCodes.isEmpty
                                      ? '尚未添加客户端邀请码。'
                                      : '没有符合条件的邀请码。',
                                ),
                              )
                            : ListView.builder(
                                itemCount: invites.length,
                                itemBuilder: (context, index) {
                                  final invite = invites[index];
                                  final status = invite['status'];
                                  return ListTile(
                                    leading: Icon(
                                      status == '可用'
                                          ? Icons.vpn_key
                                          : status == '已绑定'
                                              ? Icons.verified_user
                                              : Icons.key_off,
                                    ),
                                    title: Text(invite['code'].toString()),
                                    subtitle: Text(
                                      '$status${invite['client_name'] == null ? '' : ' · ${invite['client_name']}'}',
                                    ),
                                    onTap: () =>
                                        _showInviteDetails(context, invite),
                                    trailing: IconButton(
                                      tooltip: '撤销邀请码',
                                      onPressed: status == '已失效'
                                          ? null
                                          : () => _controller.revokeInviteCode(
                                                invite['code'].toString(),
                                              ),
                                      icon: const Icon(Icons.block),
                                    ),
                                  );
                                },
                              ),
                      ),
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('关闭'),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Future<void> _showClientManagementDialog(BuildContext context) =>
      showDialog<void>(
        context: context,
        builder: (dialogContext) => AnimatedBuilder(
          animation: _controller,
          builder: (context, _) {
            final dialogSize = _dialogContentSize(
              context,
              width: 760,
              height: 620,
            );
            return AlertDialog(
              scrollable: true,
              title: const Text('客户端管理'),
              content: SizedBox(
                width: dialogSize.width,
                height: dialogSize.height,
                child: ListView(
                  children: [
                    Text(
                      '已注册客户端',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    if (_controller.registeredClients.isEmpty)
                      const ListTile(title: Text('尚无已通过验证的客户端。'))
                    else
                      for (final client in _controller.registeredClients)
                        Card(
                          child: ExpansionTile(
                            leading: Icon(
                              client['revoked'] == true
                                  ? Icons.block
                                  : DateTime.now()
                                              .difference(DateTime.parse(
                                                client['last_seen'].toString(),
                                              ))
                                              .inSeconds <
                                          30
                                      ? Icons.circle
                                      : Icons.phone_android,
                              color: client['revoked'] == true
                                  ? Theme.of(context).colorScheme.error
                                  : null,
                            ),
                            title: Text(
                              (client['remark'] as String? ?? '').isNotEmpty
                                  ? client['remark'].toString()
                                  : (client['client_name'] ??
                                          client['device_name'])
                                      .toString(),
                            ),
                            subtitle: Text(
                              client['revoked'] == true
                                  ? '已撤销'
                                  : 'IP：${client['ip']} · 邀请码：${client['invite_code'] ?? '无'}',
                            ),
                            children: [
                              ListTile(
                                title: const Text('客户端 ID'),
                                subtitle: SelectableText(
                                  client['client_id'].toString(),
                                ),
                              ),
                              ListTile(
                                title: const Text('备注'),
                                subtitle: Text(
                                  (client['remark'] as String? ?? '').isEmpty
                                      ? '未设置'
                                      : client['remark'].toString(),
                                ),
                                trailing: IconButton(
                                  tooltip: '修改备注',
                                  onPressed: () =>
                                      _editClientRemark(context, client),
                                  icon: const Icon(Icons.edit),
                                ),
                              ),
                              ListTile(
                                title: const Text('首次注册 / 最近活动'),
                                subtitle: Text(
                                  '${_dateTime(DateTime.parse(client['created_at'].toString()))} / '
                                  '${_dateTime(DateTime.parse(client['last_seen'].toString()))}',
                                ),
                              ),
                              Align(
                                alignment: Alignment.centerRight,
                                child: IconButton(
                                  tooltip: '更换此客户端邀请码',
                                  onPressed: () =>
                                      _changeClientInviteCode(context, client),
                                  icon: const Icon(Icons.key),
                                ),
                              ),
                            ],
                          ),
                        ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('关闭'),
                ),
              ],
            );
          },
        ),
      );

  Future<void> _showClientChatsDialog(BuildContext context) async {
    final client = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          final dialogSize = _dialogContentSize(
            context,
            width: 560,
            height: 500,
          );
          final query = _clientChatSearch.text.trim().toLowerCase();
          final clients = _controller.registeredClients.where((client) {
            return [
              client['remark'],
              client['device_name'],
              client['client_name'],
              client['ip'],
            ].any(
              (value) =>
                  value?.toString().toLowerCase().contains(query) == true,
            );
          }).toList();
          return AlertDialog(
            title: const Text('客户端聊天'),
            content: SizedBox(
              width: dialogSize.width,
              height: dialogSize.height,
              child: Column(
                children: [
                  TextField(
                    controller: _clientChatSearch,
                    onChanged: (_) => setDialogState(() {}),
                    decoration: const InputDecoration(
                      labelText: '搜索备注、手机名称或 IP',
                      prefixIcon: Icon(Icons.search),
                    ),
                  ),
                  Expanded(
                    child: clients.isEmpty
                        ? Center(
                            child: Text(
                              _controller.registeredClients.isEmpty
                                  ? '尚无可聊天的客户端。'
                                  : '没有符合条件的客户端。',
                            ),
                          )
                        : ListView(
                            children: [
                              for (final client in clients)
                                ListTile(
                                  leading:
                                      const Icon(Icons.chat_bubble_outline),
                                  title: Text(
                                    (client['remark'] as String? ?? '')
                                            .isNotEmpty
                                        ? client['remark'].toString()
                                        : (client['client_name'] ??
                                                client['device_name'])
                                            .toString(),
                                  ),
                                  subtitle: Text(
                                    '${client['revoked'] == true ? '已撤销 · ' : ''}'
                                    '${client['ip']} · 最近活动 ${_dateTime(DateTime.parse(client['last_seen'].toString()))}',
                                  ),
                                  trailing: const Icon(Icons.chevron_right),
                                  onTap: () =>
                                      Navigator.pop(dialogContext, client),
                                ),
                            ],
                          ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('关闭'),
              ),
            ],
          );
        },
      ),
    );
    if (client != null && mounted && context.mounted) {
      await _replyToClient(context, client);
    }
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Invite Server',
        theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
        home: AnimatedBuilder(
          animation: _controller,
          builder: (context, _) => Scaffold(
            appBar: AppBar(
              title: const Text('邀请码服务器'),
              leading: widget.onBack == null
                  ? null
                  : IconButton(
                      tooltip: 'Back',
                      onPressed: _controller.isRunning ? null : widget.onBack,
                      icon: const Icon(Icons.arrow_back),
                    ),
            ),
            body: LayoutBuilder(
              builder: (context, constraints) => SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 760),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          _controller.isRunning ? '服务运行中' : '服务已停止',
                          style: Theme.of(context).textTheme.headlineSmall,
                        ),
                        const SizedBox(height: 16),
                        if (!_controller.isRunning) ...[
                          TextField(
                            controller: _code,
                            obscureText: true,
                            onChanged: (value) {
                              _adminCodeSaveTimer?.cancel();
                              _adminCodeSaveTimer = Timer(
                                const Duration(milliseconds: 300),
                                () => _saveAdminCode(value.trim()),
                              );
                            },
                            decoration: const InputDecoration(
                              labelText: '管理员连接口令',
                            ),
                          ),
                          const SizedBox(height: 8),
                          TextField(
                            controller: _port,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(
                              labelText: 'HTTPS 端口',
                            ),
                          ),
                        ] else ...[
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: const Icon(Icons.dns_outlined),
                            title: Text('HTTPS 端口 ${_controller.port}'),
                            subtitle: Text(
                              '${Uri.parse(serverBaseUrl).replace(port: _controller.port)}\nTLS 指纹已自动固定',
                            ),
                          ),
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: const Icon(Icons.key),
                            title: const Text('管理员口令（已显示）'),
                            subtitle: SelectableText(
                              _controller.adminCodeForDisplay ?? '未设置',
                            ),
                            trailing: IconButton(
                              tooltip: '复制管理员口令',
                              onPressed: _controller.adminCodeForDisplay == null
                                  ? null
                                  : () => Clipboard.setData(
                                        ClipboardData(
                                          text:
                                              _controller.adminCodeForDisplay!,
                                        ),
                                      ),
                              icon: const Icon(Icons.copy),
                            ),
                          ),
                          OutlinedButton.icon(
                            onPressed: () => _changeCode(context),
                            icon: const Icon(Icons.key),
                            label: const Text('更换管理员口令'),
                          ),
                        ],
                        const SizedBox(height: 12),
                        FilledButton.icon(
                          onPressed: _busy ? null : _toggleServer,
                          icon: Icon(
                            _controller.isRunning
                                ? Icons.stop
                                : Icons.play_arrow,
                          ),
                          label: Text(
                            _busy
                                ? '正在处理…'
                                : _controller.isRunning
                                    ? '停止服务器'
                                    : '启动 HTTPS 服务器',
                          ),
                        ),
                        if (_controller.isRunning) ...[
                          const SizedBox(height: 24),
                          Wrap(
                            spacing: 12,
                            runSpacing: 12,
                            children: [
                              OutlinedButton.icon(
                                onPressed: () =>
                                    _showInviteCodesDialog(context),
                                icon: const Icon(Icons.vpn_key_outlined),
                                label: const Text('邀请码管理'),
                              ),
                              OutlinedButton.icon(
                                onPressed: () =>
                                    _showClientManagementDialog(context),
                                icon:
                                    const Icon(Icons.manage_accounts_outlined),
                                label: const Text('客户端管理'),
                              ),
                              OutlinedButton.icon(
                                onPressed: () =>
                                    _showClientChatsDialog(context),
                                icon: const Icon(Icons.chat_bubble_outline),
                                label: const Text('客户端聊天'),
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          Text(
                            '服务设备需保持运行。客户端首次连接会自动固定证书，证书变更时需重新配置客户端。',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                        if (_error != null || _controller.error != null) ...[
                          const SizedBox(height: 12),
                          Text(
                            _error ?? _controller.error!,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
}
