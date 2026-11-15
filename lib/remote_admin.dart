import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:pinyin/pinyin.dart';
import 'package:record/record.dart';
import 'package:uuid/uuid.dart';

import 'app_log.dart';
import 'app_config.dart';
import 'direct_chat.dart';
import 'server_tls.dart';
import 'secure_cache.dart';
import 'video_call.dart';

const _uuid = Uuid();
const _pendingAdminUploadsKey = 'remote-admin-pending-uploads';

enum RemoteAdminSortField {
  firstConnection('首次连接时间'),
  recentChat('最近聊天时间'),
  nameInitial('姓名首字母'),
  inviteCodeInitial('邀请码首字母'),
  remarkInitial('备注首字母');

  const RemoteAdminSortField(this.label);

  final String label;
}

int compareRemoteAdminRecords(
  Map<String, dynamic> left,
  Map<String, dynamic> right,
  RemoteAdminSortField field, {
  required bool ascending,
}) {
  int result;
  switch (field) {
    case RemoteAdminSortField.firstConnection:
      if (DateTime.tryParse(left['created_at']?.toString() ?? '') == null ||
          DateTime.tryParse(right['created_at']?.toString() ?? '') == null) {
        result = _compareRecordDates(left['created_at'], right['created_at']);
        return result == 0 ? _compareRecordIdentity(left, right) : result;
      }
      result = _compareRecordDates(left['created_at'], right['created_at']);
      break;
    case RemoteAdminSortField.recentChat:
      if (DateTime.tryParse(left['last_chat_at']?.toString() ?? '') == null ||
          DateTime.tryParse(right['last_chat_at']?.toString() ?? '') == null) {
        result = _compareRecordDates(
          left['last_chat_at'],
          right['last_chat_at'],
        );
        return result == 0 ? _compareRecordIdentity(left, right) : result;
      }
      result = _compareRecordDates(left['last_chat_at'], right['last_chat_at']);
      break;
    case RemoteAdminSortField.nameInitial:
      result = _compareRecordText(
        _recordName(left),
        _recordName(right),
        initialOnly: true,
      );
      break;
    case RemoteAdminSortField.inviteCodeInitial:
      result = _compareRecordText(
        left['invite_code']?.toString() ?? left['code']?.toString() ?? '',
        right['invite_code']?.toString() ?? right['code']?.toString() ?? '',
        initialOnly: true,
      );
      break;
    case RemoteAdminSortField.remarkInitial:
      result = _compareRecordText(
        left['remark']?.toString() ?? '',
        right['remark']?.toString() ?? '',
        initialOnly: true,
      );
      break;
  }
  if (result == 0) {
    result = _compareRecordIdentity(left, right);
  }
  return ascending ? result : -result;
}

int _compareRecordIdentity(
  Map<String, dynamic> left,
  Map<String, dynamic> right,
) => (left['code'] ?? left['invite_code'] ?? left['client_id'])
    .toString()
    .compareTo(
      (right['code'] ?? right['invite_code'] ?? right['client_id']).toString(),
    );

String _recordName(Map<String, dynamic> record) =>
    record['client_name']?.toString() ??
    record['device_name']?.toString() ??
    '';

int _compareRecordDates(Object? left, Object? right) {
  final leftDate = DateTime.tryParse(left?.toString() ?? '');
  final rightDate = DateTime.tryParse(right?.toString() ?? '');
  if (leftDate == null && rightDate == null) return 0;
  if (leftDate == null) return 1;
  if (rightDate == null) return -1;
  return leftDate.compareTo(rightDate);
}

int _compareRecordText(String left, String right, {required bool initialOnly}) {
  final leftValue = _recordSortText(left, initialOnly: initialOnly);
  final rightValue = _recordSortText(right, initialOnly: initialOnly);
  final initialOrder = leftValue.compareTo(rightValue);
  return initialOrder == 0
      ? left.toLowerCase().compareTo(right.toLowerCase())
      : initialOrder;
}

String _recordSortText(String value, {required bool initialOnly}) {
  final normalized = value.trim().toLowerCase();
  if (!initialOnly || normalized.isEmpty) return normalized;
  final initials = PinyinHelper.getShortPinyin(normalized).toLowerCase();
  return String.fromCharCodes(initials.runes.take(1));
}

class RemoteManagementApi {
  RemoteManagementApi(
    this.serverUri,
    this.adminCode, {
    required this.certificateFingerprint,
  }) : _client = createPinnedHttpClient(certificateFingerprint);

  final Uri serverUri;
  final String certificateFingerprint;
  final String adminCode;
  final HttpClient _client;

  void close() => _client.close(force: true);

  Future<Map<String, dynamic>> state() => _request('GET', '/admin/state');

  Future<Map<String, dynamic>> startVideoCall(String clientId) => _request(
    'POST',
    '/admin/video-call/start',
    body: {'client_id': clientId},
  );

  Future<List<Map<String, dynamic>>> pollVideoCallSignals(
    String clientId,
  ) async {
    final response = await _request(
      'GET',
      '/admin/video-call/signals?client_id=${Uri.encodeQueryComponent(clientId)}',
    );
    final signals = response['signals'];
    if (signals is! List) {
      throw const FormatException('服务器返回了无效通话信令。');
    }
    return signals.whereType<Map>().map(Map<String, dynamic>.from).toList();
  }

  Future<void> sendVideoCallSignal({
    required String clientId,
    required String callId,
    required String type,
    String? sdp,
    Map<String, dynamic>? candidate,
  }) async {
    await _request(
      'POST',
      '/admin/video-call/signal',
      body: {
        'client_id': clientId,
        'call_id': callId,
        'type': type,
        if (sdp != null) 'sdp': sdp,
        if (candidate != null) 'candidate': candidate,
      },
    );
  }

  Future<Map<String, dynamic>> videoCallIceServers() =>
      _request('GET', '/admin/video-call/ice-servers');

  Future<void> saveVideoCallIceServers({
    required String stunUrl,
    required String turnUrl,
    required String turnUsername,
    required String turnPassword,
  }) async {
    await _request(
      'POST',
      '/admin/video-call/ice-servers',
      body: {
        'stun_url': stunUrl,
        'turn_url': turnUrl,
        'turn_username': turnUsername,
        'turn_password': turnPassword,
      },
    );
  }

  Future<List<Map<String, dynamic>>> messages(String clientId) async {
    final result = await _request(
      'GET',
      '/admin/messages?client_id=${Uri.encodeQueryComponent(clientId)}',
    );
    final items = result['messages'];
    if (items is! List) throw const FormatException('服务器返回了无效会话。');
    final messages = items
        .whereType<Map>()
        .map(Map<String, dynamic>.from)
        .toList();
    return messages..sort(compareDirectMessages);
  }

  Future<Map<String, dynamic>> clientAvatars(String clientId) => _request(
    'GET',
    '/admin/client-avatar?client_id=${Uri.encodeQueryComponent(clientId)}',
  );

  Future<void> uploadServerAvatar({
    required String clientId,
    required String data,
    required String mimeType,
  }) async {
    await _request(
      'POST',
      '/admin/client-avatar',
      body: {
        'client_id': clientId,
        'avatar_data': data,
        'avatar_mime_type': mimeType,
      },
    );
  }

  Future<void> sendText(
    String clientId,
    String text, {
    required String messageId,
  }) async {
    await _request(
      'POST',
      '/admin/message',
      body: {'client_id': clientId, 'id': messageId, 'body': text},
    );
  }

  Future<void> deleteMessages(
    String clientId,
    Iterable<String> messageIds,
  ) async {
    await _request(
      'POST',
      '/admin/delete-messages',
      body: {'client_id': clientId, 'message_ids': messageIds.toList()},
    );
  }

  Future<void> sendVibrationAlert(String clientId) async {
    await _request(
      'POST',
      '/admin/message',
      body: {
        'client_id': clientId,
        'id': _uuid.v4(),
        'type': 'vibration_alert',
        'body': '',
      },
    );
  }

  Future<void> sendMedia({
    required String clientId,
    required String fileName,
    required String mimeType,
    required List<int> bytes,
  }) async {
    await _request(
      'POST',
      '/admin/message',
      body: {
        'client_id': clientId,
        'id': _uuid.v4(),
        'file_name': fileName,
        'mime_type': mimeType,
        'data': base64Encode(bytes),
        'body': '',
      },
    );
  }

  Future<void> sendMediaFile({
    required String clientId,
    required String messageId,
    required String fileName,
    required String mimeType,
    required String filePath,
    required int fileSize,
    ValueChanged<int>? onProgress,
    bool Function()? isCancelled,
    String? previewData,
  }) {
    Future<void> upload() => _sendMediaFile(
      clientId: clientId,
      messageId: messageId,
      fileName: fileName,
      mimeType: mimeType,
      filePath: filePath,
      fileSize: fileSize,
      onProgress: onProgress,
      isCancelled: isCancelled,
      previewData: previewData,
    );
    return mimeType.startsWith('video/')
        ? DirectVideoUploads.instance.enqueue(upload)
        : upload();
  }

  Future<void> _sendMediaFile({
    required String clientId,
    required String messageId,
    required String fileName,
    required String mimeType,
    required String filePath,
    required int fileSize,
    ValueChanged<int>? onProgress,
    bool Function()? isCancelled,
    String? previewData,
  }) async {
    if (fileSize <= 0) throw const FileSystemException('File is empty.');
    final start = await _request(
      'POST',
      '/admin/media/start',
      body: {
        'client_id': clientId,
        'id': messageId,
        'file_name': fileName,
        'mime_type': mimeType,
        'size': fileSize,
        if (previewData != null) 'preview_data': previewData,
      },
    );
    if (start['already_sent'] == true) {
      onProgress?.call(100);
      return;
    }
    final uploadId = start['upload_id'];
    if (uploadId is! String) {
      throw const FormatException('服务器未创建附件上传。');
    }
    try {
      void throwIfCancelled() {
        if (isCancelled?.call() == true) {
          throw const _AdminUploadCancelled();
        }
      }

      throwIfCancelled();
      final file = File(filePath);
      if (await file.length() != fileSize) {
        throw const FileSystemException('Selected file changed before upload.');
      }
      const chunkSize = 1024 * 1024;
      final rawVideo = mimeType.startsWith('video/');
      var offset = 0;
      var index = 0;
      while (offset < fileSize) {
        throwIfCancelled();
        final end = (offset + chunkSize).clamp(0, fileSize);
        final bytes = await file
            .openRead(offset, end)
            .fold<List<int>>(<int>[], (all, next) => all..addAll(next));
        await _request(
          'POST',
          '/admin/media/$uploadId/chunk/$index',
          body: rawVideo ? null : {'data': base64Encode(bytes)},
          binaryBody: rawVideo ? bytes : null,
        );
        offset += bytes.length;
        index++;
        onProgress?.call((offset * 98 ~/ fileSize).clamp(0, 98));
      }
      throwIfCancelled();
      await _request(
        'POST',
        '/admin/media/$uploadId/complete',
        body: {'size': fileSize, 'chunk_count': index},
      );
      onProgress?.call(100);
    } catch (_) {
      try {
        await _request('POST', '/admin/media/$uploadId/cancel', body: const {});
      } on Exception {
        // The server also removes abandoned uploads on the next start.
      }
      rethrow;
    }
  }

  Future<String> downloadMediaToFile({
    required String mediaId,
    required int chunkCount,
    required int expectedSize,
    required String outputPath,
    ValueChanged<int>? onProgress,
    bool Function()? isCancelled,
  }) async {
    await File(outputPath).parent.create(recursive: true);
    final outputFile = File(outputPath);
    final partialFile = File('$outputPath.partial');
    final resumeIndex = await prepareDirectPartialDownload(
      outputFile: outputFile,
      partialFile: partialFile,
      chunkCount: chunkCount,
      expectedSize: expectedSize,
    );
    if (resumeIndex == chunkCount) return outputPath;
    final output = partialFile.openWrite(mode: FileMode.append);
    try {
      onProgress?.call((resumeIndex * 100 ~/ chunkCount).clamp(0, 100));
      for (var index = resumeIndex; index < chunkCount; index++) {
        if (isCancelled?.call() == true) {
          throw const DirectDownloadCancelled();
        }
        final response = await _request(
          'GET',
          '/admin/media/$mediaId/chunk/$index',
          binaryResponse: true,
        );
        if (isCancelled?.call() == true) {
          throw const DirectDownloadCancelled();
        }
        final binaryData = response['binary_data'];
        if (binaryData is List) {
          output.add(List<int>.from(binaryData));
        } else if (response['data'] is String) {
          output.add(base64Decode(response['data'] as String));
        } else {
          throw const FormatException('服务器返回了无效附件分块。');
        }
        await output.flush();
        onProgress?.call(((index + 1) * 100 ~/ chunkCount).clamp(0, 100));
      }
      if (isCancelled?.call() == true) {
        throw const DirectDownloadCancelled();
      }
      await output.flush();
      await output.close();
      await finishDirectPartialDownload(
        outputFile: outputFile,
        partialFile: partialFile,
        expectedSize: expectedSize,
      );
      return outputPath;
    } catch (_) {
      await output.close();
      rethrow;
    } finally {
      await output.close();
    }
  }

  Future<void> changeClientInviteCode(String clientId, String code) async {
    await _request(
      'POST',
      '/admin/client-invite-code',
      body: {'client_id': clientId, 'code': code},
    );
  }

  Future<void> setClientRemark(String clientId, String remark) async {
    await _request(
      'POST',
      '/admin/client-remark',
      body: {'client_id': clientId, 'remark': remark},
    );
  }

  Future<void> revokeInviteCode(String code) async {
    await _request('POST', '/admin/revoke-invite-code', body: {'code': code});
  }

  Future<void> addInviteCodes(String codes) async {
    await _request('POST', '/admin/invite-codes', body: {'codes': codes});
  }

  Future<void> uploadLogs(String content) async {
    await _request('POST', '/admin/logs', body: {'content': content});
  }

  Future<Map<String, dynamic>> _request(
    String method,
    String path, {
    Map<String, Object?>? body,
    List<int>? binaryBody,
    bool binaryResponse = false,
  }) async {
    final stopwatch = Stopwatch()..start();
    AppLogger.log(
      'http.request',
      details: {'method': method, 'route': path.split('?').first},
    );
    try {
      final request = await _client.openUrl(method, serverUri.resolve(path));
      request.headers.set('X-Admin-Code', adminCode);
      if (body != null) {
        final encodedBody = jsonEncode(body);
        request.headers.contentType = ContentType.json;
        request.contentLength = utf8.encode(encodedBody).length;
        request.write(encodedBody);
      } else if (binaryBody != null) {
        request.headers.contentType = ContentType(
          'application',
          'octet-stream',
        );
        request.contentLength = binaryBody.length;
        request.add(binaryBody);
      }
      final response = await request.close().timeout(
        const Duration(seconds: 20),
      );
      late final String text;
      if (binaryResponse) {
        final responseBytes = await response
            .fold<List<int>>(<int>[], (all, next) => all..addAll(next))
            .timeout(const Duration(seconds: 20));
        if (response.statusCode >= 200 &&
            response.statusCode < 300 &&
            response.headers.contentType?.mimeType ==
                'application/octet-stream') {
          AppLogger.log(
            'http.response',
            details: {
              'method': method,
              'route': path.split('?').first,
              'status': response.statusCode,
              'duration_ms': stopwatch.elapsedMilliseconds,
            },
          );
          return {'binary_data': responseBytes};
        }
        text = utf8.decode(responseBytes);
      } else {
        text = await utf8.decoder.bind(response).join();
      }
      final decoded = jsonDecode(text);
      if (decoded is! Map) throw const FormatException('服务器响应无效。');
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final error = decoded['error']?.toString();
        throw HttpException(
          error == 'unauthorized'
              ? '管理员口令错误或已更换。'
              : '服务器错误：${decoded['message'] ?? error}',
        );
      }
      AppLogger.log(
        'http.response',
        details: {
          'method': method,
          'route': path.split('?').first,
          'status': response.statusCode,
          'duration_ms': stopwatch.elapsedMilliseconds,
        },
      );
      return Map<String, dynamic>.from(decoded);
    } catch (error, stackTrace) {
      AppLogger.log(
        'http.failure',
        level: 'error',
        details: {'method': method, 'route': path.split('?').first},
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }
}

class _AdminUploadCancelled implements Exception {
  const _AdminUploadCancelled();
}

Future<String?> _openRemoteAttachment(
  RemoteManagementApi api,
  Map<String, dynamic> message, {
  required BuildContext context,
  ValueChanged<int>? onProgress,
  bool Function()? shouldOpen,
}) async {
  final savedMediaPath =
      message['media_path'] as String? ??
      (message['encrypted_local'] == true
          ? null
          : message['file_path'] as String?);
  final mediaId = message['media_id'];
  final clientId = message['client_id']?.toString() ?? 'unknown';
  if ((savedMediaPath == null || !await File(savedMediaPath).exists()) &&
      mediaId is String &&
      message['chunk_count'] is int) {
    final directory = await directCacheDirectory(
      'admin-downloads',
      segments: [clientId, mediaId],
    );
    final safeName = (message['file_name'] as String? ?? 'attachment')
        .replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final path = '${directory.path}${Platform.pathSeparator}$safeName';
    final cachedFile = File(path);
    final expectedSize = message['media_size'] as int? ?? 0;
    if (!await cachedFile.exists() ||
        await cachedFile.length() != expectedSize) {
      await DirectAttachmentDownloads.instance.download(
        key: 'admin:$clientId:$mediaId',
        expectedSize: expectedSize,
        sequential: (message['mime_type'] as String? ?? '').startsWith(
          'video/',
        ),
        onProgress: onProgress,
        download: (onProgress, managerCancelled) => api.downloadMediaToFile(
          mediaId: mediaId,
          chunkCount: message['chunk_count'] as int,
          expectedSize: expectedSize,
          outputPath: path,
          onProgress: onProgress,
          isCancelled: managerCancelled,
        ),
      );
    } else {
      onProgress?.call(100);
    }
    message['media_path'] = path;
  }
  if (shouldOpen?.call() == false) return null;
  return openDirectAttachment(message, context: context);
}

class RemoteAdminApp extends StatefulWidget {
  const RemoteAdminApp({required this.cache, super.key});

  final SecureCache cache;

  @override
  State<RemoteAdminApp> createState() => _RemoteAdminAppState();
}

class _RemoteAdminAppState extends State<RemoteAdminApp> {
  final _navigatorKey = GlobalKey<NavigatorState>();
  final _code = TextEditingController();
  final _clientSearch = TextEditingController();
  final _inviteSearch = TextEditingController();
  Timer? _timer;
  RemoteManagementApi? _api;
  Map<String, dynamic>? _snapshot;
  String? _error;
  bool _busy = false;
  RemoteAdminSortField _clientSortField = RemoteAdminSortField.firstConnection;
  RemoteAdminSortField _inviteSortField = RemoteAdminSortField.firstConnection;
  bool _clientSortAscending = false;
  bool _inviteSortAscending = false;
  int _selectedPage = 0;
  final List<Map<String, dynamic>> _pendingAdminUploads = [];
  final Set<String> _activeAdminUploadIds = {};
  final Set<String> _cancelledAdminUploadIds = {};
  Future<void> _pendingAdminWrite = Future<void>.value();
  Future<void> _adminUploadQueue = Future<void>.value();
  void Function(void Function())? _activeChatUpdater;

  BuildContext get _dialogContext {
    final context = _navigatorKey.currentState?.overlay?.context;
    if (context == null) {
      throw StateError('The management page is not available.');
    }
    return context;
  }

  @override
  void initState() {
    super.initState();
    _pendingAdminUploads.addAll(widget.cache.mapList(_pendingAdminUploadsKey));
    final savedCode = widget.cache.text('remote-admin-code');
    _code.text = savedCode ?? '';
    if (savedCode != null && savedCode.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _connect();
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _api?.close();
    _code.dispose();
    _clientSearch.dispose();
    _inviteSearch.dispose();
    super.dispose();
  }

  Future<void> _persistPendingAdminUploads() {
    final write = _pendingAdminWrite.then((_) {
      final snapshot = _pendingAdminUploads
          .map((message) => Map<String, dynamic>.from(message))
          .toList();
      return widget.cache.putMapList(_pendingAdminUploadsKey, snapshot);
    });
    _pendingAdminWrite = write.catchError((
      Object error,
      StackTrace stackTrace,
    ) {
      AppLogger.log(
        'admin.pending_upload_cache_write_failed',
        level: 'error',
        error: error,
        stackTrace: stackTrace,
      );
    });
    return _pendingAdminWrite;
  }

  void _savePendingAdminUploads() {
    unawaited(_persistPendingAdminUploads());
  }

  void _rememberPendingAdminUpload(Map<String, dynamic> message) {
    final messageId = message['id'].toString();
    final index = _pendingAdminUploads.indexWhere(
      (item) => item['id'].toString() == messageId,
    );
    if (index == -1) {
      _pendingAdminUploads.add(message);
    } else {
      _pendingAdminUploads[index] = message;
    }
    _savePendingAdminUploads();
  }

  void _forgetPendingAdminUpload(String messageId) {
    _pendingAdminUploads.removeWhere(
      (item) => item['id'].toString() == messageId,
    );
    _savePendingAdminUploads();
  }

  void _refreshActiveChat() {
    _activeChatUpdater?.call(() {});
  }

  Future<void> _connect() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      AppLogger.log('admin.connect_started');
      final uri = Uri.parse(serverBaseUrl);
      final dialogContext = _navigatorKey.currentState?.overlay?.context;
      if (dialogContext == null) {
        throw StateError('The connection dialog is not available.');
      }
      final fingerprint = await ensureServerCertificatePinned(
        dialogContext,
        uri,
        widget.cache,
        confirmOnFirstUse: false,
      );
      final api = RemoteManagementApi(
        uri,
        _code.text.trim(),
        certificateFingerprint: fingerprint,
      );
      late final Map<String, dynamic> snapshot;
      try {
        snapshot = await api.state();
      } catch (_) {
        api.close();
        rethrow;
      }
      await widget.cache.putText('remote-admin-code', _code.text.trim());
      if (!mounted) {
        api.close();
        return;
      }
      _api?.close();
      setState(() {
        _api = api;
        _snapshot = snapshot;
        _error = null;
      });
      AppLogger.log('admin.connected', details: {'server': uri.authority});
      _timer?.cancel();
      _timer = Timer.periodic(const Duration(seconds: 3), (_) => _refresh());
    } catch (error) {
      AppLogger.log('admin.connect_failed', level: 'error', error: error);
      if (mounted) setState(() => _error = '连接失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _refresh() async {
    final api = _api;
    if (api == null || _busy) {
      return;
    }
    try {
      final snapshot = await api.state();
      if (mounted &&
          (jsonEncode(snapshot) != jsonEncode(_snapshot) || _error != null)) {
        setState(() {
          _snapshot = snapshot;
          _error = null;
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = '服务器未启动或暂时无法连接：$error');
    }
  }

  Future<void> _uploadLogs() async {
    final api = _api;
    if (api == null) return;
    try {
      AppLogger.log('logs.upload_started');
      await api.uploadLogs(await AppLogger.readForUpload());
      AppLogger.log('logs.upload_succeeded');
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('运行日志已上传到电脑服务器。')));
      }
    } catch (error, stackTrace) {
      AppLogger.log(
        'logs.upload_failed',
        level: 'error',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) setState(() => _error = '日志上传失败：$error');
    }
  }

  Future<void> _changeClientInviteCode(Map<String, dynamic> client) async {
    final controller = TextEditingController();
    final code = await showDialog<String>(
      context: _dialogContext,
      builder: (context) => AlertDialog(
        title: Text('更换 ${client['client_name']} 的邀请码'),
        content: TextField(
          controller: controller,
          obscureText: true,
          autocorrect: false,
          enableSuggestions: false,
          decoration: const InputDecoration(labelText: '新邀请码（至少 8 位）'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('确认更换'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (code == null || code.trim().length < 8) return;

    try {
      await _api!.changeClientInviteCode(
        client['client_id'] as String,
        code.trim(),
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('邀请码已更换，旧客户端的授权将被撤销；请把新码交给对应客户端。')),
        );
        await _refresh();
      }
    } catch (error) {
      if (mounted) setState(() => _error = '更换客户端邀请码失败：$error');
    }
  }

  Future<void> _showClientManagement(Map<String, dynamic> client) async {
    final code = client['invite_code']?.toString() ?? '';
    await showDialog<void>(
      context: _dialogContext,
      builder: (dialogContext) => AlertDialog(
        title: Text('客户端管理：${client['client_name']}'),
        content: SizedBox(
          width: 420,
          child: ListView(
            shrinkWrap: true,
            children: [
              ListTile(
                title: const Text('姓名'),
                subtitle: Text(client['client_name'].toString()),
              ),
              ListTile(
                title: const Text('手机名称'),
                subtitle: Text(
                  client['device_name']?.toString() ??
                      client['client_name'].toString(),
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
                  onPressed: () => _editClientRemark(client),
                  icon: const Icon(Icons.edit),
                ),
              ),
              ListTile(
                title: const Text('邀请码 / 状态'),
                subtitle: Text(
                  '$code · ${client['revoked'] == true ? '已撤销' : '有效'}',
                ),
              ),
              ListTile(
                title: const Text('公网 IP'),
                subtitle: Text(client['ip'].toString()),
              ),
            ],
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
                  await _api!.revokeInviteCode(code);
                  await _refresh();
                  if (dialogContext.mounted) Navigator.pop(dialogContext);
                } catch (error) {
                  if (dialogContext.mounted) {
                    ScaffoldMessenger.of(dialogContext)
                        .showSnackBar(SnackBar(content: Text('撤销失败：$error')));
                  }
                }
              },
              child: const Text('撤销授权'),
            ),
          FilledButton(
            onPressed: () {
              Navigator.pop(dialogContext);
              _changeClientInviteCode(client);
            },
            child: const Text('更换邀请码'),
          ),
        ],
      ),
    );
  }

  Future<String?> _editClientRemark(Map<String, dynamic> client) async {
    final controller = TextEditingController(
      text: client['remark']?.toString() ?? '',
    );
    final remark = await showDialog<String>(
      context: _dialogContext,
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
    if (remark == null) return null;
    try {
      await _api!.setClientRemark(client['client_id'] as String, remark);
      client['remark'] = remark;
      _refreshActiveChat();
      await _refresh();
      return remark;
    } catch (error) {
      if (mounted) setState(() => _error = '保存备注失败：$error');
      return null;
    }
  }

  Future<void> _openChat(Map<String, dynamic> client) async {
    final api = _api!;
    final clientId = client['client_id'] as String;
    final chatClient = client;
    final text = TextEditingController();
    final recorder = AudioRecorder();
    var messages = <Map<String, dynamic>>[];
    var avatars = <String, dynamic>{};
    var recording = false;
    var loading = false;
    var selectionMode = false;
    final selectedMessageIds = <String>{};
    final downloadingMessageIds = <String>{};
    final downloadProgress = <String, int>{};
    var dialogOpen = true;
    String? chatError;
    Timer? timer;
    Timer? avatarTimer;
    var pendingUploadsResumed = false;
    var deletingMessages = false;
    var messageRevision = 0;
    final isRevoked = client['revoked'] == true;
    final optimisticMessages = <Map<String, dynamic>>[];

    Future<bool> refresh(
      void Function(void Function()) update, {
      bool waitForCurrentRequest = false,
    }) async {
      while (loading && waitForCurrentRequest && dialogOpen) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      if (loading || deletingMessages || !dialogOpen) return false;
      loading = true;
      final revision = messageRevision;
      try {
        final latest = await api.messages(clientId);
        if (revision != messageRevision || deletingMessages || !dialogOpen) {
          return false;
        }
        final previousById = {
          for (final message in messages) message['id'].toString(): message,
        };
        for (final message in latest) {
          final previous = previousById[message['id'].toString()];
          if (previous != null &&
              message['media_path'] is! String &&
              previous['media_path'] is String) {
            message['media_path'] = previous['media_path'];
          }
        }
        final receivedIds = latest
            .map((message) => message['id'].toString())
            .toSet();
        final pendingCountBeforeRefresh = _pendingAdminUploads.length;
        _pendingAdminUploads.removeWhere((pending) {
          final delivered =
              pending['client_id'] == clientId &&
              receivedIds.contains(pending['id'].toString());
          return delivered;
        });
        if (_pendingAdminUploads.length != pendingCountBeforeRefresh) {
          _savePendingAdminUploads();
        }
        final oldCombined = [...messages, ...optimisticMessages]
          ..sort(compareDirectMessages);
        final pendingUploads = _pendingAdminUploads.where(
          (message) => message['client_id'] == clientId,
        );
        final remainingById = <String, Map<String, dynamic>>{
          for (final message in optimisticMessages)
            if (!receivedIds.contains(message['id'].toString()))
              message['id'].toString(): message,
          for (final message in pendingUploads)
            message['id'].toString(): message,
        };
        final remainingOptimistic = remainingById.values.toList();
        final newCombined = [...latest, ...remainingOptimistic]
          ..sort(compareDirectMessages);
        if (dialogOpen) {
          if (!directMessageListsEqual(oldCombined, newCombined) ||
              chatError != null) {
            update(() {
              messages = latest;
              optimisticMessages
                ..clear()
                ..addAll(remainingOptimistic);
              chatError = null;
            });
          }
          return true;
        }
      } catch (error) {
        final nextError = '读取失败：$error';
        if (dialogOpen && chatError != nextError) {
          update(() => chatError = nextError);
        }
      } finally {
        loading = false;
      }
      return false;
    }

    void queueAttachment(
      Map<String, dynamic> message,
      void Function(void Function()) update,
    ) {
      final messageId = message['id'].toString();
      if (!_activeAdminUploadIds.add(messageId)) return;
      final queuedUpload = _adminUploadQueue.then((_) async {
        try {
          if (_cancelledAdminUploadIds.contains(messageId)) {
            _forgetPendingAdminUpload(messageId);
            optimisticMessages.removeWhere(
              (item) => item['id'].toString() == messageId,
            );
            final stagedPath = message['staged_file_path'];
            if (stagedPath is String && await File(stagedPath).exists()) {
              await File(stagedPath).delete();
            }
            return;
          }
          final filePath = message['file_path'];
          if (filePath is! String || !await File(filePath).exists()) {
            throw const FileSystemException('找不到待上传的原文件，请重新选择。');
          }
          message
            ..['delivery_state'] = 'uploading'
            ..['upload_progress'] = 0;
          _rememberPendingAdminUpload(message);
          if (dialogOpen) {
            update(() {});
          } else {
            _refreshActiveChat();
          }
          await api.sendMediaFile(
            clientId: clientId,
            messageId: messageId,
            fileName: message['file_name'] as String,
            mimeType: message['mime_type'] as String,
            filePath: filePath,
            fileSize: message['media_size'] as int,
            previewData: message['preview_data'] as String?,
            isCancelled: () => _cancelledAdminUploadIds.contains(messageId),
            onProgress: (progress) {
              final previous = message['upload_progress'] as int? ?? 0;
              if (progress != 100 && progress - previous < 2) return;
              message['upload_progress'] = progress;
              _rememberPendingAdminUpload(message);
              if (dialogOpen) {
                update(() {});
              } else {
                _refreshActiveChat();
              }
            },
          );
          final stagedPath = message['staged_file_path'];
          if (stagedPath is String) {
            try {
              final stagedFile = File(stagedPath);
              if (await stagedFile.exists()) await stagedFile.delete();
            } on FileSystemException catch (error, stackTrace) {
              AppLogger.log(
                'admin.pending_attachment_cleanup_failed',
                level: 'warning',
                error: error,
                stackTrace: stackTrace,
              );
            }
          }
          _forgetPendingAdminUpload(messageId);
          optimisticMessages.removeWhere(
            (item) => item['id'].toString() == messageId,
          );
          if (dialogOpen) await refresh(update);
          if (!dialogOpen) _refreshActiveChat();
        } catch (error) {
          if (_cancelledAdminUploadIds.contains(messageId)) {
            _forgetPendingAdminUpload(messageId);
            optimisticMessages.removeWhere(
              (item) => item['id'].toString() == messageId,
            );
            final stagedPath = message['staged_file_path'];
            if (stagedPath is String && await File(stagedPath).exists()) {
              await File(stagedPath).delete();
            }
          } else {
            message
              ..['delivery_state'] = 'failed'
              ..['upload_error'] = error.toString();
            _rememberPendingAdminUpload(message);
            if (dialogOpen) {
              update(() => chatError = '发送失败，附件仍保留，可重试：$error');
            }
          }
          if (dialogOpen) update(() {});
          if (!dialogOpen) _refreshActiveChat();
        } finally {
          _activeAdminUploadIds.remove(messageId);
          _cancelledAdminUploadIds.remove(messageId);
        }
      });
      _adminUploadQueue = queuedUpload.catchError((
        Object error,
        StackTrace stackTrace,
      ) {
        AppLogger.log(
          'admin.attachment_queue_failed',
          level: 'error',
          error: error,
          stackTrace: stackTrace,
        );
      });
    }

    Future<void> pickAndSend(
      FileType type,
      void Function(void Function()) update,
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
        if (dialogOpen) update(() => chatError = '打开相册失败：$error');
        return;
      }
      if (files.isEmpty || !dialogOpen) return;

      final pendingFiles = <(DirectPickedFile, Map<String, dynamic>)>[];
      update(() {
        for (final file in files) {
          final message = <String, dynamic>{
            'id': _uuid.v4(),
            'client_id': clientId,
            'sender': 'server',
            'body': '',
            'created_at': DateTime.now().toUtc().toIso8601String(),
            'file_name': file.name,
            'mime_type': directMimeTypeForFile(file.name),
            'media_size': file.size,
            if (file.path != null) 'file_path': file.path,
            'pending': true,
            'delivery_state': 'preparing',
            'upload_progress': 0,
          };
          optimisticMessages.add(message);
          _rememberPendingAdminUpload(message);
          pendingFiles.add((file, message));
        }
        chatError = null;
      });

      for (final (file, message) in pendingFiles) {
        try {
          if (file.size <= 0) {
            throw const FileSystemException('所选文件为空。');
          }
          var path = file.path;
          if (path == null && file.readStream != null) {
            final clientId = message['client_id']?.toString() ?? 'unknown';
            final pendingDirectory = await directCacheDirectory(
              'pending-attachments',
              segments: [clientId],
            );
            path =
                '${pendingDirectory.path}${Platform.pathSeparator}${message['id']}.attachment';
            final output = File(path).openWrite();
            await output.addStream(file.readStream!);
            await output.flush();
            await output.close();
            message['staged_file_path'] = path;
          }
          if (path == null) {
            throw const FileSystemException('无法读取所选文件。');
          }
          final mimeType = message['mime_type'] as String;
          if (mimeType.startsWith('image/') || mimeType.startsWith('video/')) {
            final previewData = await createDirectMediaPreview(
              filePath: path,
              mimeType: mimeType,
            );
            if (previewData != null) {
              message['preview_data'] = previewData;
            }
          }
          message
            ..['file_path'] = path
            ..['delivery_state'] = 'queued';
          _rememberPendingAdminUpload(message);
          if (dialogOpen) update(() {});
          queueAttachment(message, update);
        } catch (error) {
          message
            ..['delivery_state'] = 'failed'
            ..['upload_error'] = error.toString();
          _rememberPendingAdminUpload(message);
          if (dialogOpen) {
            update(() => chatError = '附件准备失败，文件仍保留：$error');
          }
        }
      }
    }

    Future<void> cancelAttachment(
      Map<String, dynamic> message,
      void Function(void Function()) update,
    ) async {
      final messageId = message['id'].toString();
      _cancelledAdminUploadIds.add(messageId);
      optimisticMessages.removeWhere(
        (item) => item['id'].toString() == messageId,
      );
      _forgetPendingAdminUpload(messageId);
      final stagedPath = message['staged_file_path'];
      if (stagedPath is String && !_activeAdminUploadIds.contains(messageId)) {
        try {
          final stagedFile = File(stagedPath);
          if (await stagedFile.exists()) await stagedFile.delete();
        } catch (error, stackTrace) {
          AppLogger.log(
            'admin.cancelled_attachment_cleanup_failed',
            level: 'warning',
            error: error,
            stackTrace: stackTrace,
          );
        }
      }
      if (!_activeAdminUploadIds.contains(messageId)) {
        _cancelledAdminUploadIds.remove(messageId);
      }
      if (dialogOpen) update(() {});
    }

    Future<void> deleteSelected(void Function(void Function()) update) async {
      if (selectedMessageIds.isEmpty) return;
      final confirmed = await showDialog<bool>(
        context: _dialogContext,
        builder: (context) => AlertDialog(
          title: const Text('删除聊天记录'),
          content: Text('确定永久删除选中的 ${selectedMessageIds.length} 条消息及其附件吗？'),
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
      final deletingIds = selectedMessageIds.toSet();
      final pendingMessages = <String, Map<String, dynamic>>{
        for (final message in optimisticMessages)
          if (deletingIds.contains(message['id'].toString()) &&
              message['pending'] == true)
            message['id'].toString(): message,
        for (final message in _pendingAdminUploads)
          if (message['client_id'] == clientId &&
              deletingIds.contains(message['id'].toString()))
            message['id'].toString(): message,
      };
      final persistedIds = messages
          .where((message) => deletingIds.contains(message['id'].toString()))
          .map((message) => message['id'].toString())
          .toSet();
      messageRevision++;
      deletingMessages = true;
      try {
        if (persistedIds.isNotEmpty) {
          await api.deleteMessages(clientId, persistedIds);
        }
        for (final message in pendingMessages.values) {
          await cancelAttachment(message, update);
        }
        update(() {
          messages.removeWhere(
            (message) => deletingIds.contains(message['id'].toString()),
          );
          optimisticMessages.removeWhere(
            (message) => deletingIds.contains(message['id'].toString()),
          );
          selectedMessageIds.clear();
          selectionMode = false;
          chatError = null;
        });
      } catch (error) {
        update(() => chatError = '删除聊天记录失败：$error');
      } finally {
        deletingMessages = false;
        unawaited(refresh(update));
      }
    }

    Future<void> sendText(void Function(void Function()) update) async {
      final body = text.text.trim();
      if (body.isEmpty || isRevoked) return;
      text.clear();
      final messageId = _uuid.v4();
      update(() => chatError = null);
      final optimistic = <String, dynamic>{
        'id': messageId,
        'client_id': clientId,
        'sender': 'server',
        'body': body,
        'created_at': DateTime.now().toUtc().toIso8601String(),
        'pending': true,
      };
      update(() => optimisticMessages.add(optimistic));
      try {
        await api.sendText(clientId, body, messageId: messageId);
        optimistic['pending'] = false;
        update(() {});
        unawaited(refresh(update));
      } catch (error) {
        update(() {
          optimisticMessages.remove(optimistic);
          if (text.text.isEmpty) text.text = body;
          chatError = '服务器未启动或发送失败：$error';
        });
      }
    }

    Future<void> sendVibrationAlert(
      void Function(void Function()) update,
    ) async {
      try {
        await api.sendVibrationAlert(clientId);
        await refresh(update);
      } catch (error) {
        update(() => chatError = '发送震动提醒失败：$error');
      }
    }

    Future<void> startVideoCall(void Function(void Function()) update) async {
      final callContext = _dialogContext;
      try {
        final response = await api.startVideoCall(clientId);
        final callId = response['call_id'];
        final rawIceServers = response['ice_servers'];
        if (callId is! String || rawIceServers is! List) {
          throw const FormatException('服务器返回了无效视频通话配置。');
        }
        final iceServers = rawIceServers
            .whereType<Map>()
            .map(Map<String, dynamic>.from)
            .toList();
        if (!callContext.mounted) {
          await api.sendVideoCallSignal(
            clientId: clientId,
            callId: callId,
            type: 'hangup',
          );
          return;
        }
        await showDialog<void>(
          context: callContext,
          barrierDismissible: false,
          builder: (callContext) => DirectVideoCallDialog(
            callId: callId,
            clientSide: false,
            iceServers: iceServers,
            sendSignal: (type, {sdp, candidate}) => api.sendVideoCallSignal(
              clientId: clientId,
              callId: callId,
              type: type,
              sdp: sdp,
              candidate: candidate,
            ),
            pollSignals: () => api.pollVideoCallSignals(clientId),
            onClose: () => Navigator.of(callContext).pop(),
          ),
        );
      } catch (error) {
        update(() => chatError = '发起视频通话失败：$error');
      }
    }

    Future<void> openAttachment(
      Map<String, dynamic> message,
      void Function(void Function()) update,
    ) async {
      final messageId = message['id'].toString();
      final localPath =
          message['media_path'] as String? ??
          (message['encrypted_local'] == true
              ? null
              : message['file_path'] as String?);
      if (localPath != null) {
        final localFile = File(localPath);
        if (await localFile.exists() && await localFile.length() > 0) {
          message['media_path'] = localPath;
          try {
            final error = await openDirectAttachment(
              message,
              context: _dialogContext,
            );
            if (error != null && dialogOpen) {
              update(() => chatError = error);
            }
          } catch (error) {
            if (dialogOpen) update(() => chatError = '无法打开附件：$error');
          }
          return;
        }
      }
      if (!downloadingMessageIds.add(messageId)) return;
      update(() => downloadProgress[messageId] = 0);
      try {
        final error = await _openRemoteAttachment(
          api,
          message,
          context: _dialogContext,
          shouldOpen: () => dialogOpen,
          onProgress: (progress) {
            downloadProgress[messageId] = progress;
            if (dialogOpen) update(() {});
          },
        );
        if (error != null && dialogOpen) {
          update(() => chatError = error);
        }
      } on DirectDownloadCancelled {
        // The user cancelled; the incomplete file has already been removed.
      } catch (error) {
        if (dialogOpen) update(() => chatError = '无法下载附件：$error');
      } finally {
        downloadingMessageIds.remove(messageId);
        downloadProgress.remove(messageId);
        if (dialogOpen) update(() {});
      }
    }

    try {
      messages = await api.messages(clientId);
      final deliveredIds = messages
          .map((message) => message['id'].toString())
          .toSet();
      _pendingAdminUploads.removeWhere(
        (pending) =>
            pending['client_id'] == clientId &&
            deliveredIds.contains(pending['id'].toString()),
      );
      for (final pending in _pendingAdminUploads.where(
        (message) => message['client_id'] == clientId,
      )) {
        if (!_activeAdminUploadIds.contains(pending['id'].toString()) &&
            (pending['delivery_state'] == 'uploading' ||
                pending['delivery_state'] == 'preparing')) {
          pending['delivery_state'] = 'queued';
        }
        optimisticMessages.add(pending);
      }
      _savePendingAdminUploads();
    } catch (error) {
      chatError = '读取聊天记录失败：$error';
    }
    try {
      avatars = await api.clientAvatars(clientId);
    } catch (error) {
      chatError ??= '读取头像失败：$error';
    }
    if (!mounted) {
      await recorder.dispose();
      text.dispose();
      return;
    }
    await _navigatorKey.currentState!.push<void>(
      MaterialPageRoute<void>(
        builder: (pageContext) => StatefulBuilder(
          builder: (context, update) {
            _activeChatUpdater = update;
            if (!pendingUploadsResumed) {
              pendingUploadsResumed = true;
              for (final pending in optimisticMessages.where(
                (message) =>
                    message['delivery_state'] == 'queued' &&
                    message['file_path'] is String,
              )) {
                queueAttachment(pending, update);
              }
            }
            timer ??= Timer.periodic(
              const Duration(seconds: 3),
              (_) => refresh(update),
            );
            avatarTimer ??= Timer.periodic(const Duration(seconds: 30), (
              _,
            ) async {
              try {
                final latestAvatars = await api.clientAvatars(clientId);
                if (!dialogOpen) return;
                final changed = [
                  'avatar_data',
                  'server_avatar_data',
                ].any((key) => latestAvatars[key] != avatars[key]);
                if (changed) {
                  update(() => avatars = latestAvatars);
                }
              } catch (error) {
                if (dialogOpen) update(() => chatError = '刷新头像失败：$error');
              }
            });
            final messagesById = {
              for (final message in messages) message['id'].toString(): message,
              for (final message in optimisticMessages)
                message['id'].toString(): message,
            };
            final visibleMessages = messagesById.values.toList()
              ..sort(compareDirectMessages);
            return Scaffold(
              appBar: AppBar(
                title: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Text('聊天', style: TextStyle(fontSize: 15)),
                    Text(
                      '与 ${(chatClient['remark'] as String? ?? '').isNotEmpty ? chatClient['remark'] : chatClient['client_name'] ?? chatClient['device_name']} 聊天'
                      '${isRevoked ? '（历史记录）' : ''}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                  ],
                ),
                actions: [
                  TextButton.icon(
                    onPressed: () async {
                      final result = await FilePicker.platform.pickFiles(
                        type: FileType.image,
                        allowMultiple: false,
                        withData: true,
                      );
                      if (result == null || result.files.isEmpty) return;
                      final file = result.files.first;
                      final bytes = file.bytes;
                      if (bytes == null || bytes.isEmpty) return;
                      if (bytes.length > 1024 * 1024) {
                        update(() => chatError = '头像图片不能超过 1 MB。');
                        return;
                      }
                      final mimeType = directMimeTypeForFile(file.name);
                      if (!const {
                        'image/jpeg',
                        'image/png',
                        'image/webp',
                      }.contains(mimeType)) {
                        update(() => chatError = '头像仅支持 JPG、PNG 或 WebP 图片。');
                        return;
                      }
                      final encoded = base64Encode(bytes);
                      update(() {
                        avatars['server_avatar_data'] = encoded;
                        avatars['server_avatar_mime_type'] = mimeType;
                        chatError = null;
                      });
                      try {
                        await api.uploadServerAvatar(
                          clientId: clientId,
                          data: encoded,
                          mimeType: mimeType,
                        );
                      } catch (error) {
                        update(() => chatError = '头像上传失败：$error');
                      }
                    },
                    icon: const Icon(Icons.add_a_photo_outlined, size: 18),
                    label: const Text('上传头像'),
                  ),
                  IconButton(
                    tooltip: '客户端管理',
                    onPressed: () => _showClientManagement(client),
                    icon: const Icon(Icons.manage_accounts_outlined),
                  ),
                ],
              ),
              body: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Column(
                    children: [
                      SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: [
                            FilledButton.tonalIcon(
                              onPressed: () => update(() {
                                selectionMode = !selectionMode;
                                selectedMessageIds.clear();
                              }),
                              icon: Icon(
                                selectionMode ? Icons.close : Icons.checklist,
                              ),
                              label: Text(selectionMode ? '完成管理' : '管理聊天记录'),
                            ),
                            if (selectionMode) ...[
                              const SizedBox(width: 8),
                              OutlinedButton(
                                onPressed: () => update(() {
                                  final selectableIds = visibleMessages
                                      .map(
                                        (message) => message['id'].toString(),
                                      )
                                      .toSet();
                                  if (selectedMessageIds.containsAll(
                                    selectableIds,
                                  )) {
                                    selectedMessageIds.clear();
                                  } else {
                                    selectedMessageIds
                                      ..clear()
                                      ..addAll(selectableIds);
                                  }
                                }),
                                child: Text(
                                  selectedMessageIds.isNotEmpty &&
                                          visibleMessages.every(
                                            (message) =>
                                                selectedMessageIds.contains(
                                                  message['id'].toString(),
                                                ),
                                          )
                                      ? '取消全选'
                                      : '全选',
                                ),
                              ),
                              const SizedBox(width: 8),
                              FilledButton.icon(
                                onPressed: selectedMessageIds.isEmpty
                                    ? null
                                    : () => deleteSelected(update),
                                icon: const Icon(Icons.delete_outline),
                                label: Text(
                                  '删除${selectedMessageIds.isEmpty ? '' : ' (${selectedMessageIds.length})'}',
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      if (chatError != null)
                        Align(
                          alignment: Alignment.centerLeft,
                          child: Text(chatError!),
                        ),
                      Expanded(
                        child: visibleMessages.isEmpty
                            ? const Center(child: Text('还没有一小时内的消息'))
                            : ListView(
                                padding: const EdgeInsets.all(8),
                                reverse: true,
                                children: [
                                  for (final message
                                      in visibleMessages.reversed)
                                    Row(
                                      children: [
                                        if (selectionMode)
                                          Checkbox(
                                            value: selectedMessageIds.contains(
                                              message['id'].toString(),
                                            ),
                                            onChanged: (selected) => update(() {
                                              final id = message['id']
                                                  .toString();
                                              if (selected == true) {
                                                selectedMessageIds.add(id);
                                              } else {
                                                selectedMessageIds.remove(id);
                                              }
                                            }),
                                          ),
                                        Expanded(
                                          child: Builder(
                                            builder: (context) {
                                              final mediaId =
                                                  message['media_id'];
                                              final downloadKey =
                                                  mediaId is String
                                                  ? 'admin:${message['client_id']}:$mediaId'
                                                  : null;
                                              Widget buildBubble(
                                                int? activeProgress,
                                              ) => DirectMessageBubble(
                                                key: ValueKey(
                                                  message['id'].toString(),
                                                ),
                                                message: message,
                                                outgoing:
                                                    message['sender'] ==
                                                    'server',
                                                avatarData:
                                                    message['sender'] ==
                                                        'server'
                                                    ? avatars['server_avatar_data']
                                                          as String?
                                                    : avatars['avatar_data']
                                                          as String?,
                                                onOpenAttachment: () =>
                                                    openAttachment(
                                                      message,
                                                      update,
                                                    ),
                                                downloading:
                                                    downloadingMessageIds
                                                        .contains(
                                                          message['id']
                                                              .toString(),
                                                        ) ||
                                                    activeProgress != null,
                                                downloadProgress:
                                                    downloadProgress[message['id']
                                                        .toString()] ??
                                                    activeProgress,
                                                onCancelDownload: () {
                                                  final clientId =
                                                      message['client_id']
                                                          ?.toString() ??
                                                      'unknown';
                                                  final mediaId =
                                                      message['media_id'];
                                                  if (mediaId is String) {
                                                    DirectAttachmentDownloads
                                                        .instance
                                                        .cancel(
                                                          'admin:$clientId:$mediaId',
                                                        );
                                                  }
                                                },
                                                onRetry:
                                                    message['delivery_state'] ==
                                                            'failed' &&
                                                        message['file_path']
                                                            is String
                                                    ? () {
                                                        message
                                                          ..['delivery_state'] =
                                                              'queued'
                                                          ..['upload_progress'] =
                                                              0;
                                                        _rememberPendingAdminUpload(
                                                          message,
                                                        );
                                                        queueAttachment(
                                                          message,
                                                          update,
                                                        );
                                                      }
                                                    : null,
                                                onCancel:
                                                    message['pending'] == true
                                                    ? () => cancelAttachment(
                                                        message,
                                                        update,
                                                      )
                                                    : null,
                                              );
                                              if (downloadKey == null) {
                                                return buildBubble(null);
                                              }
                                              return ValueListenableBuilder<
                                                int?
                                              >(
                                                valueListenable:
                                                    DirectAttachmentDownloads
                                                        .instance
                                                        .progressListenable(
                                                          downloadKey,
                                                        ),
                                                builder:
                                                    (
                                                      context,
                                                      activeProgress,
                                                      _,
                                                    ) => buildBubble(
                                                      activeProgress,
                                                    ),
                                              );
                                            },
                                          ),
                                        ),
                                      ],
                                    ),
                                ],
                              ),
                      ),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Expanded(
                            child: TextField(
                              controller: text,
                              onChanged: (_) => update(() {}),
                              minLines: 1,
                              maxLines: 5,
                              keyboardType: TextInputType.multiline,
                              textInputAction: TextInputAction.send,
                              onSubmitted: (_) => sendText(update),
                              scrollPhysics: const ClampingScrollPhysics(),
                              decoration: const InputDecoration(
                                hintText: '输入回复',
                              ),
                            ),
                          ),
                          if (text.text.trim().isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(left: 8),
                              child: FilledButton(
                                onPressed: isRevoked
                                    ? null
                                    : () => sendText(update),
                                child: const Text('发送'),
                              ),
                            ),
                        ],
                      ),
                      SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: [
                            IconButton(
                              tooltip: '呼叫客户端视频',
                              onPressed: isRevoked
                                  ? null
                                  : () => startVideoCall(update),
                              constraints: const BoxConstraints.tightFor(
                                width: 52,
                                height: 52,
                              ),
                              padding: EdgeInsets.zero,
                              icon: const Icon(Icons.video_call),
                            ),
                            IconButton(
                              tooltip: '发送震动提醒',
                              onPressed: isRevoked
                                  ? null
                                  : () => sendVibrationAlert(update),
                              constraints: const BoxConstraints.tightFor(
                                width: 52,
                                height: 52,
                              ),
                              padding: EdgeInsets.zero,
                              icon: const Icon(Icons.vibration),
                            ),
                            IconButton(
                              tooltip: '选择图片或视频',
                              onPressed: isRevoked
                                  ? null
                                  : () => pickAndSend(FileType.media, update),
                              constraints: const BoxConstraints.tightFor(
                                width: 52,
                                height: 52,
                              ),
                              padding: EdgeInsets.zero,
                              icon: const Icon(Icons.photo_library_outlined),
                            ),
                            IconButton(
                              tooltip: '选择文件',
                              onPressed: isRevoked
                                  ? null
                                  : () => pickAndSend(FileType.any, update),
                              constraints: const BoxConstraints.tightFor(
                                width: 52,
                                height: 52,
                              ),
                              padding: EdgeInsets.zero,
                              icon: const Icon(Icons.attach_file),
                            ),
                            IconButton(
                              tooltip: recording ? '停止并发送语音' : '录制语音',
                              onPressed: isRevoked
                                  ? null
                                  : () async {
                                      try {
                                        if (recording) {
                                          final path = await recorder.stop();
                                          update(() => recording = false);
                                          if (path == null) return;
                                          final file = File(path);
                                          await api.sendMediaFile(
                                            clientId: clientId,
                                            messageId: _uuid.v4(),
                                            fileName:
                                                'voice-${DateTime.now().millisecondsSinceEpoch}.m4a',
                                            mimeType: 'audio/mp4',
                                            filePath: path,
                                            fileSize: await file.length(),
                                          );
                                          await file.delete();
                                          await refresh(update);
                                        } else {
                                          if (!await recorder.hasPermission()) {
                                            throw StateError('未获准使用麦克风。');
                                          }
                                          final path =
                                              '${Directory.systemTemp.path}${Platform.pathSeparator}voice-${_uuid.v4()}.m4a';
                                          await recorder.start(
                                            const RecordConfig(
                                              encoder: AudioEncoder.aacLc,
                                            ),
                                            path: path,
                                          );
                                          update(() => recording = true);
                                        }
                                      } catch (error) {
                                        update(() {
                                          recording = false;
                                          chatError = '语音操作失败：$error';
                                        });
                                      }
                                    },
                              constraints: const BoxConstraints.tightFor(
                                width: 52,
                                height: 52,
                              ),
                              padding: EdgeInsets.zero,
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
              ),
            );
          },
        ),
      ),
    );
    dialogOpen = false;
    _activeChatUpdater = null;
    timer?.cancel();
    avatarTimer?.cancel();
    await recorder.dispose();
    text.dispose();
  }

  Future<void> _addInviteCodes() async {
    final controller = TextEditingController();
    final codes = await showDialog<String>(
      context: _dialogContext,
      builder: (context) => AlertDialog(
        title: const Text('创建客户端邀请码'),
        content: TextField(
          controller: controller,
          minLines: 1,
          maxLines: 5,
          autocorrect: false,
          enableSuggestions: false,
          decoration: const InputDecoration(hintText: '输入邀请码；每行一个，至少 8 位'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('创建'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (codes == null || codes.trim().isEmpty) return;
    try {
      await _api!.addInviteCodes(codes);
      await _refresh();
      if (mounted) {
        ScaffoldMessenger.of(_dialogContext)
            .showSnackBar(const SnackBar(content: Text('客户端邀请码已创建。')));
      }
    } catch (error) {
      if (mounted) setState(() => _error = '创建邀请码失败：$error');
    }
  }

  Future<void> _revokeInviteCode(String code) async {
    try {
      await _api!.revokeInviteCode(code);
      await _refresh();
    } catch (error) {
      if (mounted) setState(() => _error = '撤销邀请码失败：$error');
    }
  }

  Widget _sortControls({
    required String keyPrefix,
    required RemoteAdminSortField field,
    required bool ascending,
    required ValueChanged<RemoteAdminSortField> onFieldChanged,
    required VoidCallback onDirectionChanged,
  }) {
    return Row(
      children: [
        Expanded(
          child: DropdownButton<RemoteAdminSortField>(
            key: ValueKey('$keyPrefix-sort-field'),
            value: field,
            isExpanded: true,
            items: [
              for (final option in RemoteAdminSortField.values)
                DropdownMenuItem(
                  value: option,
                  child: Text('排序：${option.label}'),
                ),
            ],
            onChanged: (value) {
              if (value != null) onFieldChanged(value);
            },
          ),
        ),
        IconButton(
          key: ValueKey('$keyPrefix-sort-direction'),
          tooltip: ascending ? '升序' : '降序',
          onPressed: onDirectionChanged,
          icon: Icon(ascending ? Icons.arrow_upward : Icons.arrow_downward),
        ),
      ],
    );
  }

  List<Map<String, dynamic>> _sortedRecords({
    required List<Map<String, dynamic>> records,
    required RemoteAdminSortField sortField,
    required bool ascending,
  }) {
    return records.toList()..sort(
      (left, right) => compareRemoteAdminRecords(
        left,
        right,
        sortField,
        ascending: ascending,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final api = _api;
    if (api == null) {
      return MaterialApp(
        navigatorKey: _navigatorKey,
        title: '聊天管理端',
        theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
        home: Scaffold(
          appBar: AppBar(title: const Text('连接电脑服务器')),
          body: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              const Text('服务器地址已内置，只需输入管理员口令。'),
              TextField(
                controller: _code,
                obscureText: true,
                decoration: const InputDecoration(labelText: '管理员口令'),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              FilledButton(
                onPressed: _busy ? null : _connect,
                child: Text(_busy ? '正在连接…' : '连接'),
              ),
            ],
          ),
        ),
      );
    }

    final inviteCodes = (_snapshot?['invite_codes'] as List? ?? [])
        .whereType<Map>()
        .map(Map<String, dynamic>.from)
        .toList();
    final clients = (_snapshot?['registered_clients'] as List? ?? [])
        .whereType<Map>()
        .map(Map<String, dynamic>.from)
        .toList();
    final query = _clientSearch.text.trim().toLowerCase();
    final filteredClients = clients.where((client) {
      final values = [
        client['remark'],
        client['device_name'],
        client['client_name'],
        client['client_id'],
        client['ip'],
      ];
      return values.any(
        (value) => value?.toString().toLowerCase().contains(query) == true,
      );
    }).toList();
    final sortedClients = _sortedRecords(
      records: filteredClients,
      sortField: _clientSortField,
      ascending: _clientSortAscending,
    );
    final inviteQuery = _inviteSearch.text.trim().toLowerCase();
    final filteredInvites = inviteCodes.where((invite) {
      final values = [
        invite['code'],
        invite['client_name'],
        invite['device_name'],
        invite['remark'],
        invite['status'],
      ];
      return values.any(
        (value) =>
            value?.toString().toLowerCase().contains(inviteQuery) == true,
      );
    }).toList();
    final sortedInvites = _sortedRecords(
      records: filteredInvites,
      sortField: _inviteSortField,
      ascending: _inviteSortAscending,
    );
    return MaterialApp(
      navigatorKey: _navigatorKey,
      title: '聊天管理端',
      theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
      home: Scaffold(
        appBar: AppBar(
          title: Text(_selectedPage == 0 ? '消息列表' : '邀请码管理'),
          actions: [
            IconButton(
              tooltip: '上传运行日志',
              onPressed: _uploadLogs,
              icon: const Icon(Icons.upload_file),
            ),
            IconButton(
              tooltip: '断开连接',
              onPressed: () {
                _timer?.cancel();
                setState(() {
                  _api = null;
                  _snapshot = null;
                });
              },
              icon: const Icon(Icons.logout),
            ),
          ],
        ),
        body: RefreshIndicator(
          onRefresh: _refresh,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              if (_selectedPage == 0) ...[
                Text(
                  '客户端聊天（${filteredClients.length}）',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                TextField(
                  controller: _clientSearch,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                    labelText: '搜索客户端备注、手机名称或 IP',
                    prefixIcon: Icon(Icons.search),
                  ),
                ),
                _sortControls(
                  keyPrefix: 'client',
                  field: _clientSortField,
                  ascending: _clientSortAscending,
                  onFieldChanged: (value) =>
                      setState(() => _clientSortField = value),
                  onDirectionChanged: () => setState(
                    () => _clientSortAscending = !_clientSortAscending,
                  ),
                ),
                if (sortedClients.isEmpty)
                  Text(clients.isEmpty ? '尚无已连接客户端。' : '没有符合条件的客户端。'),
                for (final client in sortedClients)
                  Card(
                    child: ListTile(
                      leading: Icon(
                        DateTime.now()
                                    .difference(
                                      DateTime.tryParse(
                                            client['last_seen'].toString(),
                                          ) ??
                                          DateTime.fromMillisecondsSinceEpoch(
                                            0,
                                          ),
                                    )
                                    .inSeconds <
                                30
                            ? Icons.circle
                            : Icons.phone_android,
                        color:
                            DateTime.now()
                                    .difference(
                                      DateTime.tryParse(
                                            client['last_seen'].toString(),
                                          ) ??
                                          DateTime.fromMillisecondsSinceEpoch(
                                            0,
                                          ),
                                    )
                                    .inSeconds <
                                30
                            ? Colors.green
                            : null,
                      ),
                      onTap: () => _openChat(client),
                      title: Text(
                        '${(client['remark'] as String? ?? '').isNotEmpty ? client['remark'] : client['client_name'] ?? client['device_name']}'
                        '${client['revoked'] == true ? '（授权已撤销）' : ''}',
                      ),
                      subtitle: Text(
                        '邀请码：${client['invite_code'] ?? '未绑定'}'
                        '${client['last_chat_at'] == null ? '' : ' · 最近聊天：${_formatDate(client['last_chat_at'])}'}',
                      ),
                      trailing: const Icon(Icons.chevron_right),
                    ),
                  ),
              ] else ...[
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '客户端邀请码（${filteredInvites.length}）',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    FilledButton.icon(
                      onPressed: _addInviteCodes,
                      icon: const Icon(Icons.add),
                      label: const Text('创建邀请码'),
                    ),
                  ],
                ),
                TextField(
                  controller: _inviteSearch,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                    labelText: '搜索邀请码、姓名或备注',
                    prefixIcon: Icon(Icons.search),
                  ),
                ),
                _sortControls(
                  keyPrefix: 'invite',
                  field: _inviteSortField,
                  ascending: _inviteSortAscending,
                  onFieldChanged: (value) =>
                      setState(() => _inviteSortField = value),
                  onDirectionChanged: () => setState(
                    () => _inviteSortAscending = !_inviteSortAscending,
                  ),
                ),
                if (sortedInvites.isEmpty)
                  Text(inviteCodes.isEmpty ? '尚未创建邀请码。' : '没有符合条件的邀请码。'),
                for (final invite in sortedInvites)
                  ListTile(
                    leading: Icon(
                      invite['status'] == '可用'
                          ? Icons.vpn_key
                          : invite['status'] == '已绑定'
                          ? Icons.verified_user
                          : Icons.key_off,
                    ),
                    title: SelectableText(invite['code'].toString()),
                    subtitle: Text(
                      '${invite['status']}${invite['client_name'] == null ? '' : ' · ${invite['client_name']}'}'
                      '${invite['remark'] == null || invite['remark'] == '' ? '' : ' · ${invite['remark']}'}',
                    ),
                    trailing: IconButton(
                      tooltip: '撤销邀请码',
                      onPressed: invite['status'] == '已失效'
                          ? null
                          : () => _revokeInviteCode(invite['code'].toString()),
                      icon: const Icon(Icons.block),
                    ),
                  ),
              ],
            ],
          ),
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _selectedPage,
          onDestinationSelected: (index) {
            setState(() => _selectedPage = index);
          },
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.chat_bubble_outline),
              selectedIcon: Icon(Icons.chat_bubble),
              label: '消息列表',
            ),
            NavigationDestination(
              icon: Icon(Icons.vpn_key_outlined),
              selectedIcon: Icon(Icons.vpn_key),
              label: '邀请码管理',
            ),
          ],
        ),
      ),
    );
  }

  String _formatDate(Object? value) {
    final date = DateTime.tryParse(value?.toString() ?? '');
    if (date == null) return '未知';
    final local = date.toLocal();
    return '${local.year}-${local.month.toString().padLeft(2, '0')}-'
        '${local.day.toString().padLeft(2, '0')} '
        '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
  }
}
