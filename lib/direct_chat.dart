import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:record/record.dart';
import 'package:uuid/uuid.dart';
import 'package:video_player/video_player.dart';
import 'package:video_thumbnail/video_thumbnail.dart';
import 'package:vibration/vibration.dart';

import 'app_log.dart';
import 'client_background_service.dart';
import 'message_crypto.dart';
import 'server_tls.dart';
import 'secure_cache.dart';
import 'video_call.dart';

const _uuid = Uuid();
final _directVideoThumbnailCache = <String, Future<Uint8List?>>{};
final _directMemoryImageCache = <String, MemoryImage>{};
final _directVideoImageCache = <String, MemoryImage>{};

MemoryImage _directMemoryImage(String data) =>
    _directMemoryImageCache.putIfAbsent(data, () {
      if (_directMemoryImageCache.length >= 64) {
        _directMemoryImageCache.remove(_directMemoryImageCache.keys.first);
      }
      return MemoryImage(base64Decode(data));
    });

MemoryImage _directVideoMemoryImage(String path, Uint8List bytes) =>
    _directVideoImageCache.putIfAbsent(path, () {
      if (_directVideoImageCache.length >= 32) {
        _directVideoImageCache.remove(_directVideoImageCache.keys.first);
      }
      return MemoryImage(bytes);
    });

Future<Directory> directCacheRoot() async {
  final base = Platform.isWindows
      ? Directory(r'D:\talk\ConsentChatData')
      : await getApplicationSupportDirectory();
  await base.create(recursive: true);
  return base;
}

Future<Directory> directCacheDirectory(
  String category, {
  List<String> segments = const [],
}) async {
  final safeSegments = [category, ...segments].map(
    (segment) => segment
        .replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_')
        .replaceAll(RegExp(r'^\.{1,2}$'), '_'),
  );
  final base = await directCacheRoot();
  final directory = Directory(
    [base.path, ...safeSegments].join(Platform.pathSeparator),
  );
  await directory.create(recursive: true);
  return directory;
}

String _directAttachmentExtension(String fileName) {
  final normalized = fileName.replaceAll('\\', '/').split('/').last;
  final dot = normalized.lastIndexOf('.');
  if (dot < 0 || dot == normalized.length - 1) return '.video';
  final extension = normalized.substring(dot);
  return RegExp(r'^\.[A-Za-z0-9]{1,10}$').hasMatch(extension)
      ? extension.toLowerCase()
      : '.video';
}

class DirectDownloadCancelled implements Exception {
  const DirectDownloadCancelled();
}

String? directOutgoingVideoPath(Map<String, dynamic> message) {
  if (message['sender'] != 'client' ||
      !(message['mime_type'] as String? ?? '').startsWith('video/')) {
    return null;
  }
  return message['source_file_path'] as String?;
}

typedef DirectAttachmentDownload = Future<String> Function(
  ValueChanged<int> onProgress,
  bool Function() isCancelled,
);

class DirectAttachmentDownloads {
  DirectAttachmentDownloads._();

  static final instance = DirectAttachmentDownloads._();

  final Map<String, _ActiveDirectDownload> _active = {};
  final Map<String, String> _completedPaths = {};
  final Map<String, ValueNotifier<int?>> _progressNotifiers = {};
  Future<void> _videoDownloadQueue = Future<void>.value();

  int? progressFor(String key) => _active[key]?.progress;
  ValueNotifier<int?> progressListenable(String key) =>
      _progressNotifiers.putIfAbsent(key, () => ValueNotifier<int?>(null));

  Future<String> download({
    required String key,
    required int expectedSize,
    required DirectAttachmentDownload download,
    bool sequential = false,
    ValueChanged<int>? onProgress,
  }) async {
    final active = _active[key];
    if (active != null) {
      if (onProgress != null) active.listeners.add(onProgress);
      onProgress?.call(active.progress);
      try {
        return await active.future;
      } finally {
        if (onProgress != null) active.listeners.remove(onProgress);
      }
    }

    final completedPath = _completedPaths[key];
    if (completedPath != null) {
      final file = File(completedPath);
      if (await file.exists() && await file.length() == expectedSize) {
        onProgress?.call(100);
        return completedPath;
      }
      _completedPaths.remove(key);
    }

    final task = _ActiveDirectDownload();
    if (onProgress != null) task.listeners.add(onProgress);
    _active[key] = task;
    progressListenable(key).value = task.progress;
    Future<String> operation() =>
        download((progress) {
              task.progress = progress;
              progressListenable(key).value = progress;
              for (final listener in task.listeners.toList()) {
                listener(progress);
              }
            }, () => task.cancelled)
            .then((path) {
              _completedPaths[key] = path;
              return path;
            })
            .whenComplete(() {
              if (identical(_active[key], task)) _active.remove(key);
              progressListenable(key).value = null;
              task.listeners.clear();
            });
    if (sequential) {
      final queued = _videoDownloadQueue.then((_) => operation());
      _videoDownloadQueue = queued.then<void>(
        (_) {},
        onError: (Object _, StackTrace __) {},
      );
      task.future = queued;
    } else {
      task.future = operation();
    }
    try {
      return await task.future;
    } finally {
      if (onProgress != null) task.listeners.remove(onProgress);
    }
  }

  void cancel(String key) {
    final task = _active[key];
    if (task != null) task.cancelled = true;
  }
}

class DirectVideoUploads {
  DirectVideoUploads._();

  static final instance = DirectVideoUploads._();

  Future<void> _queue = Future<void>.value();

  Future<T> enqueue<T>(Future<T> Function() upload) {
    final queued = _queue.then((_) => upload());
    _queue = queued.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return queued;
  }
}

class _ActiveDirectDownload {
  int progress = 0;
  bool cancelled = false;
  late Future<String> future;
  final listeners = <ValueChanged<int>>{};
}

const directMediaFileExtensions = [
  '3gp',
  'avi',
  'bmp',
  'flv',
  'gif',
  'heic',
  'jpeg',
  'jpg',
  'm4v',
  'mkv',
  'mov',
  'mp4',
  'mpeg',
  'mpg',
  'png',
  'webm',
  'webp',
  'wmv',
];

class DirectPickedFile {
  const DirectPickedFile({
    required this.name,
    required this.size,
    this.path,
    this.readStream,
  });

  final String name;
  final int size;
  final String? path;
  final Stream<List<int>>? readStream;
}

Future<List<DirectPickedFile>> pickDirectMediaFiles() async {
  if (Platform.isAndroid || Platform.isIOS) {
    final selected = await ImagePicker().pickMultipleMedia();
    final files = <DirectPickedFile>[];
    for (final file in selected) {
      files.add(
        DirectPickedFile(
          name: file.name,
          path: file.path,
          size: await file.length(),
          readStream: file.openRead(),
        ),
      );
    }
    return files;
  }

  final result = await FilePicker.platform.pickFiles(
    type: Platform.isWindows ? FileType.custom : FileType.media,
    allowedExtensions: Platform.isWindows ? directMediaFileExtensions : null,
    allowMultiple: true,
    withReadStream: true,
  );
  return [
    for (final file in result?.files ?? const <PlatformFile>[])
      DirectPickedFile(
        name: file.name,
        size: file.size,
        path: file.path,
        readStream: file.readStream,
      ),
  ];
}

Future<String?> createDirectMediaPreview({
  required String filePath,
  required String mimeType,
}) async {
  try {
    final bytes = mimeType.startsWith('video/')
        ? await _createVideoThumbnail(filePath)
        : await _createImagePreview(filePath);
    if (bytes == null || bytes.isEmpty) return null;
    return base64Encode(bytes);
  } catch (error, stackTrace) {
    AppLogger.log(
      'media.preview_generation_failed',
      level: 'warning',
      details: {'mime_type': mimeType},
      error: error,
      stackTrace: stackTrace,
    );
    return null;
  }
}

Future<Uint8List?> _createVideoThumbnail(String filePath) {
  final cached = _directVideoThumbnailCache[filePath];
  if (cached != null) return cached;
  final future = _generateVideoThumbnail(filePath);
  _directVideoThumbnailCache[filePath] = future;
  unawaited(
    future.then((bytes) {
      if (bytes == null &&
          identical(_directVideoThumbnailCache[filePath], future)) {
        _directVideoThumbnailCache.remove(filePath);
      }
    }),
  );
  return future;
}

Future<Uint8List?> _generateVideoThumbnail(String filePath) async {
  try {
    if (Platform.isWindows) {
      return await _createWindowsVideoThumbnail(filePath);
    }
    for (final timeMs in [1000, 0]) {
      final thumbnail = await VideoThumbnail.thumbnailData(
        video: filePath,
        timeMs: timeMs,
        imageFormat: ImageFormat.JPEG,
        maxWidth: 360,
        quality: 55,
      );
      if (thumbnail != null && thumbnail.isNotEmpty) return thumbnail;
    }
    return null;
  } catch (error, stackTrace) {
    AppLogger.log(
      'media.preview_generation_failed',
      level: 'warning',
      details: {'mime_type': 'video/*'},
      error: error,
      stackTrace: stackTrace,
    );
    return null;
  }
}

Future<Uint8List?> _createWindowsVideoThumbnail(String filePath) async {
  if (!await File(filePath).exists()) return null;
  const script = r'''
$ErrorActionPreference = 'Stop'
$source = @"
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Runtime.InteropServices;

[StructLayout(LayoutKind.Sequential)]
public struct ThumbnailSize { public int Width; public int Height; }

[ComImport]
[Guid("BCC18B79-BA16-442F-80C4-8A59C30C463B")]
[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IShellItemImageFactory {
  [PreserveSig]
  int GetImage(ThumbnailSize size, uint flags, out IntPtr bitmap);
}

public static class VideoThumbnailExtractor {
  [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = true)]
  private static extern int SHCreateItemFromParsingName(
    string path, IntPtr bindContext, ref Guid interfaceId, out IShellItemImageFactory item);

  [DllImport("gdi32.dll")]
  private static extern bool DeleteObject(IntPtr handle);

  public static string Create(string path) {
    Guid interfaceId = new Guid("BCC18B79-BA16-442F-80C4-8A59C30C463B");
    IShellItemImageFactory item;
    Marshal.ThrowExceptionForHR(SHCreateItemFromParsingName(path, IntPtr.Zero, ref interfaceId, out item));
    IntPtr handle;
    Marshal.ThrowExceptionForHR(item.GetImage(new ThumbnailSize { Width = 360, Height = 220 }, 8, out handle));
    try {
      using (Bitmap bitmap = Image.FromHbitmap(handle))
      using (MemoryStream stream = new MemoryStream()) {
        bitmap.Save(stream, ImageFormat.Jpeg);
        return Convert.ToBase64String(stream.ToArray());
      }
    } finally {
      DeleteObject(handle);
      Marshal.ReleaseComObject(item);
    }
  }
}
"@
Add-Type -TypeDefinition $source -ReferencedAssemblies System.Drawing
[VideoThumbnailExtractor]::Create($env:CONSENT_CHAT_VIDEO_PATH)
''';
  final process = await Process.start(
    'powershell.exe',
    ['-NoProfile', '-NonInteractive', '-STA', '-Command', script],
    environment: {...Platform.environment, 'CONSENT_CHAT_VIDEO_PATH': filePath},
    runInShell: true,
  );
  final stdout = StringBuffer();
  final stderr = StringBuffer();
  final stdoutSubscription = process.stdout
      .transform(utf8.decoder)
      .listen(stdout.write);
  final stderrSubscription = process.stderr
      .transform(utf8.decoder)
      .listen(stderr.write);
  try {
    final exitCode = await process.exitCode.timeout(
      const Duration(minutes: 2),
      onTimeout: () {
        process.kill();
        throw TimeoutException('Windows video thumbnail generation timed out.');
      },
    );
    await stdoutSubscription.cancel();
    await stderrSubscription.cancel();
    if (exitCode != 0) {
      throw StateError(
        'Windows thumbnail generation failed (exit $exitCode): '
        '${stderr.toString().trim()}',
      );
    }
    final encoded = stdout.toString().trim();
    if (encoded.isEmpty) {
      throw StateError('Windows did not return a video thumbnail.');
    }
    return base64Decode(encoded);
  } finally {
    await stdoutSubscription.cancel();
    await stderrSubscription.cancel();
  }
}

Future<Uint8List?> _createImagePreview(String filePath) async {
  final source = await File(filePath).readAsBytes();
  final decoded = img.decodeImage(source);
  if (decoded == null) return null;
  final thumbnail = img.copyResize(
    decoded,
    width: 360,
    interpolation: img.Interpolation.average,
  );
  return Uint8List.fromList(img.encodeJpg(thumbnail, quality: 60));
}

int compareDirectMessages(
  Map<String, dynamic> left,
  Map<String, dynamic> right,
) {
  final timestampOrder = DateTime.parse(left['created_at'].toString())
      .compareTo(DateTime.parse(right['created_at'].toString()));
  if (timestampOrder != 0) return timestampOrder;
  return left['id'].toString().compareTo(right['id'].toString());
}

Future<String> _decryptLocalMediaChunksToFile({
  required String messageCode,
  required String encryptedDirectory,
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
  if (resumeIndex == chunkCount) {
    if (await partialFile.exists()) {
      await finishDirectPartialDownload(
        outputFile: outputFile,
        partialFile: partialFile,
        expectedSize: expectedSize,
      );
    }
    return outputPath;
  }
  final output = partialFile.openWrite(mode: FileMode.append);
  try {
    onProgress?.call((resumeIndex * 100 ~/ chunkCount).clamp(0, 100));
    for (var index = resumeIndex; index < chunkCount; index++) {
      if (isCancelled?.call() == true) {
        throw const DirectDownloadCancelled();
      }
      final ciphertext = await File(
        '$encryptedDirectory${Platform.pathSeparator}$index.chunk',
      ).readAsString();
      final plaintext = await compute(_decryptDirectPayload, {
        'code': messageCode,
        'ciphertext': ciphertext,
      });
      if (isCancelled?.call() == true) {
        throw const DirectDownloadCancelled();
      }
      output.add(base64Decode(plaintext));
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

Future<int> prepareDirectPartialDownload({
  required File outputFile,
  required File partialFile,
  required int chunkCount,
  required int expectedSize,
}) async {
  const chunkSize = 1024 * 1024;
  if (expectedSize <= 0 ||
      chunkCount <= 0 ||
      (expectedSize + chunkSize - 1) ~/ chunkSize != chunkCount) {
    throw const FileSystemException('Invalid attachment size or chunk count.');
  }
  if (await outputFile.exists()) {
    if (await outputFile.length() == expectedSize) {
      if (await partialFile.exists()) await partialFile.delete();
      return chunkCount;
    }
    await outputFile.delete();
  }
  if (!await partialFile.exists()) return 0;
  final length = await partialFile.length();
  if (length > expectedSize) {
    await partialFile.delete();
    return 0;
  }
  if (length == expectedSize) {
    await finishDirectPartialDownload(
      outputFile: outputFile,
      partialFile: partialFile,
      expectedSize: expectedSize,
    );
    return chunkCount;
  }
  final resumeBytes = length == expectedSize
      ? length
      : length - length % chunkSize;
  if (resumeBytes != length) {
    final handle = await partialFile.open(mode: FileMode.writeOnly);
    await handle.truncate(resumeBytes);
    await handle.close();
  }
  return (resumeBytes ~/ chunkSize).clamp(0, chunkCount);
}

Future<void> finishDirectPartialDownload({
  required File outputFile,
  required File partialFile,
  required int expectedSize,
}) async {
  if (!await partialFile.exists() ||
      await partialFile.length() != expectedSize) {
    throw const FileSystemException('Downloaded attachment is incomplete.');
  }
  if (await outputFile.exists()) await outputFile.delete();
  await partialFile.rename(outputFile.path);
}

bool isDirectMessageVisible(Map<String, dynamic> message, {DateTime? now}) {
  final createdAt = DateTime.tryParse(message['created_at']?.toString() ?? '');
  if (createdAt == null) return false;
  final age = (now ?? DateTime.now()).toUtc().difference(createdAt.toUtc());
  return age >= Duration.zero && age < const Duration(hours: 1);
}

DateTime? directMediaCleanupAt(
  Map<String, dynamic> message, {
  Duration retention = const Duration(minutes: 30),
}) {
  if (message['pending'] == true) return null;
  final sentAt = DateTime.tryParse(message['created_at']?.toString() ?? '');
  return sentAt?.add(retention);
}

bool hasDirectAttachment(Map<String, dynamic> message) =>
    message['media_id'] is String ||
    message['media_path'] is String ||
    message['file_path'] is String ||
    message['source_file_path'] is String ||
    message['media_data'] is String;

bool isDirectClientMessageVisible(
  Map<String, dynamic> message, {
  DateTime? now,
}) {
  if (message['pending'] == true) return true;
  final createdAt = DateTime.tryParse(message['created_at']?.toString() ?? '');
  if (createdAt == null) return false;
  final age = (now ?? DateTime.now()).toUtc().difference(createdAt.toUtc());
  return age >= Duration.zero && age < const Duration(minutes: 30);
}

bool directMessageListsEqual(
  List<Map<String, dynamic>> left,
  List<Map<String, dynamic>> right,
) {
  if (identical(left, right)) return true;
  if (left.length != right.length) return false;
  const comparedFields = [
    'id',
    'sender',
    'body',
    'created_at',
    'media_id',
    'file_name',
    'mime_type',
    'media_size',
    'chunk_count',
    'media_data',
    'preview_data',
    'media_path',
    'source_file_path',
    'file_path',
    'encrypted_local',
    'pending',
    'sent',
    'delivery_state',
    'prepare_progress',
    'upload_progress',
    'upload_error',
  ];
  for (var index = 0; index < left.length; index++) {
    final leftMessage = left[index];
    final rightMessage = right[index];
    for (final field in comparedFields) {
      if (leftMessage[field] != rightMessage[field]) return false;
    }
  }
  return true;
}

List<Map<String, dynamic>> mergeDirectMessageSnapshots({
  required List<Map<String, dynamic>> localMessages,
  required List<Map<String, dynamic>> sentMessages,
  required List<Map<String, dynamic>> receivedMessages,
  required Set<String> sendingMessageIds,
}) {
  final mergedById = <String, Map<String, dynamic>>{
    for (final message in localMessages)
      if (message['pending'] == true && message['sender'] == 'client')
        message['id'].toString(): Map<String, dynamic>.from(message),
    for (final message in sentMessages)
      message['id'].toString(): Map<String, dynamic>.from(message),
    for (final message in receivedMessages)
      if (message['pending'] != true)
        message['id'].toString(): Map<String, dynamic>.from(message),
  };
  final previousById = {
    for (final message in localMessages) message['id'].toString(): message,
  };
  const localOnlyFields = [
    'file_path',
    'media_path',
    'source_file_path',
    'upload_id',
    'encrypted_local',
    'chunk_count',
    'preview_data',
  ];
  for (final message in mergedById.values) {
    final id = message['id'].toString();
    final previous = previousById[id];
    if (previous != null) {
      for (final field in localOnlyFields) {
        if (message[field] == null && previous[field] != null) {
          message[field] = previous[field];
        }
      }
      if (previous['sent'] == true) message['sent'] = true;
    }
    if (sendingMessageIds.contains(id)) {
      message
        ..['pending'] = true
        ..['upload_progress'] = previous?['upload_progress'] as int? ?? 0
        ..['delivery_state'] = previous?['delivery_state'] ?? 'uploading';
    }
  }
  for (final message in sentMessages) {
    mergedById[message['id'].toString()]!
      ..['sent'] = true
      ..['delivery_state'] = 'sent'
      ..['upload_progress'] = 100;
  }
  return mergedById.values
      .where(
        (message) =>
            message['pending'] == true || isDirectMessageVisible(message),
      )
      .toList()
    ..sort(compareDirectMessages);
}

class DirectChatApi {
  DirectChatApi(
    this.serverUri, {
    required String messageCode,
    required this.certificateFingerprint,
  }) : _messageCode = messageCode,
       _httpClient = createPinnedHttpClient(certificateFingerprint);

  final Uri serverUri;
  final String certificateFingerprint;
  final String _messageCode;
  final HttpClient _httpClient;

  void close() => _httpClient.close(force: true);

  Future<Map<String, dynamic>> validate({
    required String code,
    required String clientId,
    required String clientName,
    String deviceName = '',
    String? deviceIdentity,
    required String token,
  }) async {
    final response = await _request(
      'POST',
      '/validate',
      body: {
        'code': code,
        'client_id': clientId,
        'client_name': clientName,
        'device_name': deviceName,
        if (deviceIdentity != null) 'device_identity': deviceIdentity,
        'token': token,
      },
    );
    if (response.statusCode != HttpStatus.ok) {
      if (const {
        HttpStatus.badRequest,
        HttpStatus.unauthorized,
        HttpStatus.forbidden,
        HttpStatus.notFound,
        HttpStatus.gone,
        HttpStatus.unprocessableEntity,
      }.contains(response.statusCode)) {
        throw DirectChatValidationRejectedException(response.statusCode);
      }
      throw HttpException('Server returned HTTP ${response.statusCode}.');
    }
    return response.json;
  }

  Future<List<Map<String, dynamic>>> messages({
    required String clientId,
    required String token,
    ValueChanged<int>? onProgress,
  }) async {
    final response = await _request(
      'GET',
      '/messages',
      clientId: clientId,
      token: token,
    );
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException('Server returned HTTP ${response.statusCode}.');
    }
    final encryptedMessages = response.json['messages_cipher'];
    if (encryptedMessages is! String) {
      throw const FormatException('Invalid messages response.');
    }
    final plaintext = await compute(_decryptDirectPayload, {
      'code': _messageCode,
      'ciphertext': encryptedMessages,
    });
    final decoded = jsonDecode(plaintext);
    if (decoded is! List) {
      throw const FormatException('Invalid encrypted messages response.');
    }
    return decoded.whereType<Map>().map(Map<String, dynamic>.from).toList();
  }

  Future<List<Map<String, dynamic>>> pollVideoCallSignals({
    required String clientId,
    required String token,
  }) async {
    final response = await _request(
      'GET',
      '/video-call/signals',
      clientId: clientId,
      token: token,
    );
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException('Server returned HTTP ${response.statusCode}.');
    }
    final signals = response.json['signals'];
    if (signals is! List) {
      throw const FormatException('Invalid video call signaling response.');
    }
    return signals.whereType<Map>().map(Map<String, dynamic>.from).toList();
  }

  Future<void> sendVideoCallSignal({
    required String clientId,
    required String token,
    required String callId,
    required String type,
    String? sdp,
    Map<String, dynamic>? candidate,
  }) async {
    final response = await _request(
      'POST',
      '/video-call/signal',
      clientId: clientId,
      token: token,
      body: {
        'call_id': callId,
        'type': type,
        if (sdp != null) 'sdp': sdp,
        if (candidate != null) 'candidate': candidate,
      },
    );
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException('Server returned HTTP ${response.statusCode}.');
    }
  }

  Future<void> deleteMessages({
    required String clientId,
    required String token,
    required Iterable<String> messageIds,
  }) async {
    final ids = messageIds.toList();
    if (ids.isEmpty || ids.length > 500) {
      throw ArgumentError('Select between 1 and 500 messages to delete.');
    }
    final response = await _request(
      'POST',
      '/messages/delete',
      clientId: clientId,
      token: token,
      body: {'message_ids': ids},
    );
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException(_serverError(response));
    }
  }

  Future<Map<String, dynamic>> profile({
    required String clientId,
    required String token,
  }) async {
    final response = await _request(
      'GET',
      '/profile',
      clientId: clientId,
      token: token,
    );
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException('Server returned HTTP ${response.statusCode}.');
    }
    return response.json;
  }

  Future<void> uploadAvatar({
    required String clientId,
    required String token,
    required String data,
    required String mimeType,
  }) async {
    final response = await _request(
      'POST',
      '/profile',
      clientId: clientId,
      token: token,
      body: {'avatar_data': data, 'avatar_mime_type': mimeType},
    );
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException('Server returned HTTP ${response.statusCode}.');
    }
  }

  Future<Map<String, dynamic>> send({
    required String clientId,
    required String token,
    required String messageId,
    required String body,
    ValueChanged<int>? onProgress,
  }) async {
    final encryptedBody = await compute(_encryptDirectPayload, {
      'code': _messageCode,
      'plaintext': body,
    });
    final response = await _request(
      'POST',
      '/messages',
      clientId: clientId,
      token: token,
      onProgress: onProgress,
      body: {'id': messageId, 'body': encryptedBody},
    );
    if (response.statusCode != HttpStatus.created) {
      throw HttpException('Server returned HTTP ${response.statusCode}.');
    }
    return _decryptMessageResponse(response.json);
  }

  Future<Map<String, dynamic>> sendMedia({
    required String clientId,
    required String token,
    required String messageId,
    required String fileName,
    required String mimeType,
    required String data,
    String body = '',
    String? previewData,
    ValueChanged<int>? onProgress,
  }) async {
    if (mimeType.startsWith('video/')) {
      final bytes = base64Decode(data);
      if (bytes.isEmpty) throw const FileSystemException('File is empty.');
      final file = File(
        '${Directory.systemTemp.path}${Platform.pathSeparator}'
        'direct-video-${_uuid.v4()}.video',
      );
      await file.writeAsBytes(bytes, flush: true);
      try {
        return await sendMediaFile(
          clientId: clientId,
          token: token,
          messageId: messageId,
          fileName: fileName,
          mimeType: mimeType,
          filePath: file.path,
          fileSize: bytes.length,
          rawVideoChunks: true,
          body: body,
          previewData: previewData,
          onProgress: onProgress,
        );
      } finally {
        if (await file.exists()) await file.delete();
      }
    }
    final encodedBody = await compute(_encodeDirectMediaRequest, {
      'code': _messageCode,
      'id': messageId,
      'file_name': fileName,
      'mime_type': mimeType,
      'data': data,
      'body': body,
    });
    final response = await _request(
      'POST',
      '/media',
      clientId: clientId,
      token: token,
      encodedBody: encodedBody,
      onProgress: onProgress,
    );
    if (response.statusCode != HttpStatus.created) {
      throw HttpException('Server returned HTTP ${response.statusCode}.');
    }
    return _decryptMessageResponse(response.json);
  }

  Future<Map<String, dynamic>> sendMediaFile({
    required String clientId,
    required String token,
    required String messageId,
    required String fileName,
    required String mimeType,
    required String filePath,
    required int fileSize,
    bool encryptedChunks = false,
    bool rawVideoChunks = false,
    int? sourceChunkCount,
    String body = '',
    String? previewData,
    Future<void> Function(String uploadId, int nextChunk)? onUploadState,
    ValueChanged<int>? onProgress,
    bool Function()? isCancelled,
  }) {
    Future<Map<String, dynamic>> upload() => _sendMediaFile(
      clientId: clientId,
      token: token,
      messageId: messageId,
      fileName: fileName,
      mimeType: mimeType,
      filePath: filePath,
      fileSize: fileSize,
      encryptedChunks: encryptedChunks,
      rawVideoChunks: rawVideoChunks,
      sourceChunkCount: sourceChunkCount,
      body: body,
      previewData: previewData,
      onUploadState: onUploadState,
      onProgress: onProgress,
      isCancelled: isCancelled,
    );
    return mimeType.startsWith('video/')
        ? DirectVideoUploads.instance.enqueue(upload)
        : upload();
  }

  Future<Map<String, dynamic>> _sendMediaFile({
    required String clientId,
    required String token,
    required String messageId,
    required String fileName,
    required String mimeType,
    required String filePath,
    required int fileSize,
    bool encryptedChunks = false,
    bool rawVideoChunks = false,
    int? sourceChunkCount,
    String body = '',
    String? previewData,
    Future<void> Function(String uploadId, int nextChunk)? onUploadState,
    ValueChanged<int>? onProgress,
    bool Function()? isCancelled,
  }) async {
    if (fileSize <= 0) throw const FileSystemException('File is empty.');
    final isVideo = mimeType.startsWith('video/');
    if (rawVideoChunks && !isVideo) {
      throw ArgumentError('Raw media upload is only supported for video.');
    }
    final sendRawVideo = isVideo;
    const chunkSize = 1024 * 1024;
    final metadataCipher = await compute(_encryptDirectPayload, {
      'code': _messageCode,
      'plaintext': jsonEncode({
        'id': messageId,
        'file_name': fileName,
        'mime_type': mimeType,
        'size': fileSize,
        'body': body,
        if (previewData != null) 'preview_data': previewData,
      }),
    });
    final start = await _request(
      'POST',
      '/media/start',
      clientId: clientId,
      token: token,
      body: {'metadata_cipher': metadataCipher},
    );
    if (start.statusCode == HttpStatus.created &&
        start.json['message_cipher'] is String) {
      return _decryptMessageResponse(start.json);
    }
    if (start.statusCode != HttpStatus.created ||
        start.json['upload_id'] is! String) {
      throw HttpException(_serverError(start));
    }
    final uploadId = start.json['upload_id'] as String;
    final nextChunk = start.json['next_chunk'] as int? ?? 0;
    if (nextChunk < 0) {
      throw const FormatException('Server returned an invalid upload offset.');
    }
    await onUploadState?.call(uploadId, nextChunk);
    try {
      void throwIfCancelled() {
        if (isCancelled?.call() == true) {
          throw const _DirectUploadCancelled();
        }
      }

      throwIfCancelled();
      final file = File(filePath);
      if (!encryptedChunks) {
        final actualSize = await file.length();
        if (actualSize != fileSize) {
          throw const FileSystemException(
            'Selected file changed before upload.',
          );
        }
      } else if (sourceChunkCount == null || sourceChunkCount <= 0) {
        throw const FileSystemException(
          'Encrypted attachment chunks are missing.',
        );
      }
      var index = nextChunk;
      var offset = (nextChunk * chunkSize).clamp(0, fileSize);
      if (index >
          (sourceChunkCount ?? (fileSize + chunkSize - 1) ~/ chunkSize)) {
        throw const FormatException('Server upload offset exceeds attachment.');
      }
      onProgress?.call((offset * 98 ~/ fileSize).clamp(0, 98));
      while (offset < fileSize) {
        throwIfCancelled();
        final end = (offset + chunkSize).clamp(0, fileSize);
        final bytes = encryptedChunks
            ? isVideo
                  ? base64Decode(
                      await compute(_decryptDirectPayload, {
                        'code': _messageCode,
                        'ciphertext': await File(
                          '$filePath${Platform.pathSeparator}$index.chunk',
                        ).readAsString(),
                      }),
                    )
                  : <int>[]
            : await file
                  .openRead(offset, end)
                  .fold<List<int>>(<int>[], (all, next) => all..addAll(next));
        final encrypted = encryptedChunks
            ? isVideo
                  ? null
                  : await File('$filePath${Platform.pathSeparator}$index.chunk')
                        .readAsString()
            : sendRawVideo
            ? null
            : await compute(_encryptDirectPayload, {
                'code': _messageCode,
                'plaintext': base64Encode(bytes),
              });
        final response = await _request(
          'POST',
          '/media/$uploadId/chunk/$index',
          clientId: clientId,
          token: token,
          encodedBody: sendRawVideo
              ? bytes
              : Uint8List.fromList(utf8.encode(encrypted!)),
          encodedBodyContentType: sendRawVideo
              ? ContentType('application', 'octet-stream')
              : ContentType.json,
        );
        if (response.statusCode != HttpStatus.ok) {
          throw HttpException(_serverError(response));
        }
        offset += encryptedChunks
            ? (fileSize - offset).clamp(0, chunkSize)
            : bytes.length;
        index++;
        onProgress?.call((offset * 98 ~/ fileSize).clamp(0, 98));
      }
      throwIfCancelled();
      if (encryptedChunks && index != sourceChunkCount) {
        throw const FileSystemException(
          'Encrypted attachment chunks are incomplete.',
        );
      }
      final completeCipher = await compute(_encryptDirectPayload, {
        'code': _messageCode,
        'plaintext': jsonEncode({'size': fileSize, 'chunk_count': index}),
      });
      final complete = await _request(
        'POST',
        '/media/$uploadId/complete',
        clientId: clientId,
        token: token,
        body: {'completion_cipher': completeCipher},
        timeout: const Duration(minutes: 5),
      );
      if (complete.statusCode != HttpStatus.created) {
        throw HttpException(_serverError(complete));
      }
      onProgress?.call(100);
      return await _decryptMessageResponse(complete.json);
    } catch (error) {
      if (error is _DirectUploadCancelled) {
        await _request(
          'POST',
          '/media/$uploadId/cancel',
          clientId: clientId,
          token: token,
          body: const {},
        );
      }
      rethrow;
    }
  }

  Future<String> downloadMediaToFile({
    required String clientId,
    required String token,
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
          '/media/$mediaId/chunk/$index',
          clientId: clientId,
          token: token,
          allowBinaryResponse: true,
        );
        if (isCancelled?.call() == true) {
          throw const DirectDownloadCancelled();
        }
        if (response.statusCode != HttpStatus.ok ||
            (response.binaryData == null &&
                response.json['chunk_cipher'] is! String &&
                response.json['chunk_data'] is! String)) {
          throw HttpException(_serverError(response));
        }

        if (response.binaryData != null) {
          output.add(response.binaryData!);
        } else {
          final chunkData = response.json['chunk_data'];
          if (chunkData is String) {
            output.add(base64Decode(chunkData));
          } else {
            final plaintext = await compute(_decryptDirectPayload, {
              'code': _messageCode,
              'ciphertext': response.json['chunk_cipher'] as String,
            });
            output.add(base64Decode(plaintext));
          }
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

  Future<String> decryptLocalMediaToFile({
    required String encryptedDirectory,
    required int chunkCount,
    required int expectedSize,
    required String outputPath,
    ValueChanged<int>? onProgress,
    bool Function()? isCancelled,
  }) => _decryptLocalMediaChunksToFile(
    messageCode: _messageCode,
    encryptedDirectory: encryptedDirectory,
    chunkCount: chunkCount,
    expectedSize: expectedSize,
    outputPath: outputPath,
    onProgress: onProgress,
    isCancelled: isCancelled,
  );

  String _serverError(_ApiResponse response) =>
      response.json['message'] as String? ??
      response.json['error'] as String? ??
      'Server returned HTTP ${response.statusCode}.';

  Future<Map<String, dynamic>> downloadMedia({
    required String clientId,
    required String token,
    required String mediaId,
  }) async {
    final response = await _request(
      'GET',
      '/media/$mediaId',
      clientId: clientId,
      token: token,
    );
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException('Server returned HTTP ${response.statusCode}.');
    }
    final contentCipher = response.json['content_cipher'];
    if (contentCipher is! String) {
      throw const FormatException('Server returned invalid attachment data.');
    }
    final decoded = jsonDecode(
      await compute(_decryptDirectPayload, {
        'code': _messageCode,
        'ciphertext': contentCipher,
      }),
    );
    if (decoded is! Map ||
        decoded['file_name'] is! String ||
        decoded['mime_type'] is! String ||
        decoded['data'] is! String) {
      throw const FormatException('Server returned invalid encrypted media.');
    }
    return Map<String, dynamic>.from(decoded);
  }

  Future<void> uploadLogs({
    required String clientId,
    required String token,
    required String content,
  }) async {
    final response = await _request(
      'POST',
      '/logs',
      clientId: clientId,
      token: token,
      body: {'content': content},
    );
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException('Server returned HTTP ${response.statusCode}.');
    }
  }

  Future<Map<String, dynamic>> _decryptMessageResponse(
    Map<String, dynamic> response,
  ) async {
    final encrypted = response['message_cipher'];
    if (encrypted is! String) {
      throw const FormatException('Server returned an invalid message.');
    }
    final decoded = jsonDecode(
      await compute(_decryptDirectPayload, {
        'code': _messageCode,
        'ciphertext': encrypted,
      }),
    );
    if (decoded is! Map) {
      throw const FormatException(
        'Server returned an invalid encrypted message.',
      );
    }
    return Map<String, dynamic>.from(decoded);
  }

  Future<_ApiResponse> _request(
    String method,
    String path, {
    String? clientId,
    String? token,
    Map<String, Object?>? body,
    List<int>? encodedBody,
    ContentType? encodedBodyContentType,
    bool allowBinaryResponse = false,
    ValueChanged<int>? onProgress,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final requestUri = path.startsWith('https://')
        ? Uri.parse(path)
        : serverUri.resolve(path);
    final stopwatch = Stopwatch()..start();
    AppLogger.log(
      'http.request',
      details: {'method': method, 'route': requestUri.path},
    );
    try {
      final request = await _httpClient.openUrl(method, requestUri);
      if (clientId != null) {
        request.headers.set('X-Client-Id', clientId);
        request.headers.set('X-Client-Token', token ?? '');
      }
      if (encodedBody != null) {
        request.headers.contentType =
            encodedBodyContentType ?? ContentType.json;
        request.contentLength = encodedBody.length;
        final chunks = (() async* {
          const chunkSize = 256 * 1024;
          var sentBytes = 0;
          var lastProgress = -1;
          for (
            var offset = 0;
            offset < encodedBody.length;
            offset += chunkSize
          ) {
            final end = (offset + chunkSize).clamp(0, encodedBody.length);
            sentBytes += end - offset;
            final progress = (sentBytes * 100 ~/ encodedBody.length).clamp(
              0,
              100,
            );
            if (progress != lastProgress) {
              lastProgress = progress;
              onProgress?.call(progress);
            }
            yield encodedBody.sublist(offset, end);
          }
        })();
        await request.addStream(chunks);
      } else if (body != null) {
        request.headers.contentType = ContentType.json;
        final encoded = jsonEncode(body);
        final bytes = utf8.encode(encoded);
        request.contentLength = bytes.length;
        await request.addStream(Stream<List<int>>.value(bytes));
        onProgress?.call(100);
      }
      final response = await request.close().timeout(timeout);
      late final String text;
      if (allowBinaryResponse) {
        final responseBytes = await response
            .fold<List<int>>(<int>[], (all, next) => all..addAll(next))
            .timeout(timeout);
        if (response.statusCode >= 200 &&
            response.statusCode < 300 &&
            response.headers.contentType?.mimeType ==
                'application/octet-stream') {
          AppLogger.log(
            'http.response',
            details: {
              'method': method,
              'route': requestUri.path,
              'status': response.statusCode,
              'duration_ms': stopwatch.elapsedMilliseconds,
            },
          );
          return _ApiResponse(
            response.statusCode,
            const {},
            Uint8List.fromList(responseBytes),
          );
        }
        text = utf8.decode(responseBytes);
      } else {
        text = await utf8.decoder.bind(response).join().timeout(timeout);
      }
      late final Object? decoded;
      try {
        decoded = jsonDecode(text);
      } on FormatException {
        throw const FormatException('Server returned invalid JSON.');
      }
      if (decoded is! Map) {
        throw const FormatException('Server returned an invalid response.');
      }
      AppLogger.log(
        'http.response',
        details: {
          'method': method,
          'route': requestUri.path,
          'status': response.statusCode,
          'duration_ms': stopwatch.elapsedMilliseconds,
        },
      );
      return _ApiResponse(
        response.statusCode,
        Map<String, dynamic>.from(decoded),
      );
    } catch (error, stackTrace) {
      AppLogger.log(
        'http.failure',
        level: 'error',
        details: {'method': method, 'route': requestUri.path},
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }
}

String _encryptDirectPayload(Map<String, Object?> arguments) =>
    DailyInviteCipher(arguments['code'] as String)
        .encrypt(arguments['plaintext'] as String);

String _decryptDirectPayload(Map<String, Object?> arguments) =>
    DailyInviteCipher(arguments['code'] as String)
        .decrypt(arguments['ciphertext'] as String);

Uint8List _encodeDirectMediaRequest(Map<String, Object?> arguments) {
  final encrypted = DailyInviteCipher(arguments['code'] as String).encrypt(
    jsonEncode({
      'file_name': arguments['file_name'],
      'mime_type': arguments['mime_type'],
      'data': arguments['data'],
      'body': arguments['body'],
    }),
  );
  return Uint8List.fromList(
    utf8.encode(
      jsonEncode({'id': arguments['id'], 'content_cipher': encrypted}),
    ),
  );
}

class _ApiResponse {
  const _ApiResponse(this.statusCode, this.json, [this.binaryData]);

  final int statusCode;
  final Map<String, dynamic> json;
  final Uint8List? binaryData;
}

class DirectChatValidationRejectedException implements Exception {
  const DirectChatValidationRejectedException(this.statusCode);

  final int statusCode;

  @override
  String toString() =>
      'Server rejected client validation with HTTP $statusCode.';
}

class _DirectUploadCancelled implements Exception {
  const _DirectUploadCancelled();
}

class DirectAudioPlayback {
  final _player = AudioPlayer();
  final activeMessageId = ValueNotifier<String?>(null);
  final isPlaying = ValueNotifier<bool>(false);

  DirectAudioPlayback() {
    _player.onPlayerStateChanged.listen((state) {
      isPlaying.value = state == PlayerState.playing;
      if (state == PlayerState.completed) activeMessageId.value = null;
    });
  }

  Future<String?> toggle({
    required String messageId,
    required String path,
  }) async {
    try {
      if (activeMessageId.value == messageId) {
        if (isPlaying.value) {
          await _player.pause();
        } else {
          await _player.resume();
        }
      } else {
        await _player.stop();
        activeMessageId.value = messageId;
        await _player.play(DeviceFileSource(path));
      }
      return null;
    } catch (error, stackTrace) {
      AppLogger.log(
        'client.audio_playback_failed',
        level: 'error',
        error: error,
        stackTrace: stackTrace,
      );
      activeMessageId.value = null;
      return '无法播放语音：$error';
    }
  }
}

final directAudioPlayback = DirectAudioPlayback();

Future<String?> openDirectAttachment(
  Map<String, dynamic> message, {
  BuildContext? context,
}) async {
  final mimeType =
      message['mime_type'] as String? ??
      directMimeTypeForFile(message['file_name']?.toString() ?? '');
  final isAudio = mimeType.startsWith('audio/');
  final messageId = message['id'].toString();
  final savedPath =
      message['media_path'] ??
      message['source_file_path'] ??
      message['file_path'];
  if (savedPath is String && await File(savedPath).exists()) {
    if (isAudio) {
      return directAudioPlayback.toggle(messageId: messageId, path: savedPath);
    }
    if (context != null &&
        context.mounted &&
        await _showDirectAttachmentInApp(
          context,
          savedPath,
          mimeType,
          message['file_name']?.toString() ?? savedPath,
        )) {
      return null;
    }
    final result = await OpenFilex.open(savedPath, type: mimeType);
    return result.type == ResultType.done
        ? null
        : '没有可打开此附件的应用：${result.message}';
  }
  final encoded = message['media_data'];
  if (encoded is! String) return null;
  final directory = await directCacheDirectory(
    'opened-attachments',
    segments: [message['media_id']?.toString() ?? message['id'].toString()],
  );
  final safeName = (message['file_name'] as String? ?? 'attachment').replaceAll(
    RegExp(r'[^A-Za-z0-9._-]'),
    '_',
  );
  final path = '${directory.path}${Platform.pathSeparator}$safeName';
  await File(path).writeAsBytes(base64Decode(encoded), flush: true);
  if (isAudio) {
    return directAudioPlayback.toggle(messageId: messageId, path: path);
  }
  if (context != null &&
      context.mounted &&
      await _showDirectAttachmentInApp(
        context,
        path,
        mimeType,
        message['file_name']?.toString() ?? safeName,
      )) {
    return null;
  }
  final result = await OpenFilex.open(path, type: mimeType);
  return result.type == ResultType.done
      ? null
      : '没有可打开此附件的应用：${result.message}';
}

Future<bool> _showDirectAttachmentInApp(
  BuildContext context,
  String path,
  String mimeType,
  String fileName,
) async {
  final extension = fileName.split('.').last.toLowerCase();
  if (mimeType.startsWith('image/') &&
      const {'jpg', 'jpeg', 'png', 'gif', 'webp'}.contains(extension)) {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => Dialog.fullscreen(
        child: Scaffold(
          appBar: AppBar(
            title: Text(fileName, maxLines: 1, overflow: TextOverflow.ellipsis),
            leading: IconButton(
              icon: const Icon(Icons.close),
              onPressed: () => Navigator.of(dialogContext).pop(),
            ),
          ),
          body: Center(
            child: InteractiveViewer(
              minScale: 0.5,
              maxScale: 8,
              child: Image.file(File(path), fit: BoxFit.contain),
            ),
          ),
        ),
      ),
    );
    return true;
  }
  if (mimeType.startsWith('video/') &&
      (Platform.isAndroid || Platform.isIOS) &&
      const {'mp4', 'm4v', 'mov', '3gp'}.contains(extension)) {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => Dialog.fullscreen(
        child: _DirectVideoAttachmentViewer(
          file: File(path),
          fileName: fileName,
          onClose: () => Navigator.of(dialogContext).pop(),
        ),
      ),
    );
    return true;
  }
  if (extension == 'pdf') {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => Dialog.fullscreen(
        child: Scaffold(
          appBar: AppBar(
            title: Text(fileName, maxLines: 1, overflow: TextOverflow.ellipsis),
            leading: IconButton(
              icon: const Icon(Icons.close),
              onPressed: () => Navigator.of(dialogContext).pop(),
            ),
          ),
          body: PdfViewer.file(path),
        ),
      ),
    );
    return true;
  }
  if (const {'txt', 'md', 'csv', 'log', 'json', 'xml'}.contains(extension)) {
    final file = File(path);
    if (await file.length() > 1024 * 1024) return false;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => Dialog.fullscreen(
        child: Scaffold(
          appBar: AppBar(
            title: Text(fileName, maxLines: 1, overflow: TextOverflow.ellipsis),
            leading: IconButton(
              icon: const Icon(Icons.close),
              onPressed: () => Navigator.of(dialogContext).pop(),
            ),
          ),
          body: FutureBuilder<String>(
            future: file.readAsString(),
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return Center(child: Text('无法读取文件：${snapshot.error}'));
              }
              if (!snapshot.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              return SelectionArea(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    snapshot.data!,
                    style: const TextStyle(fontFamily: 'monospace'),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
    return true;
  }
  return false;
}

class _DirectVideoAttachmentViewer extends StatefulWidget {
  const _DirectVideoAttachmentViewer({
    required this.file,
    required this.fileName,
    required this.onClose,
  });

  final File file;
  final String fileName;
  final VoidCallback onClose;

  @override
  State<_DirectVideoAttachmentViewer> createState() =>
      _DirectVideoAttachmentViewerState();
}

class _DirectVideoAttachmentViewerState
    extends State<_DirectVideoAttachmentViewer> {
  late final VideoPlayerController _controller;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller = VideoPlayerController.file(widget.file);
    _controller
        .initialize()
        .then((_) {
          if (mounted) setState(() {});
        })
        .catchError((Object error, StackTrace stackTrace) {
          AppLogger.log(
            'attachment.video_initialize_failed',
            level: 'error',
            error: error,
            stackTrace: stackTrace,
          );
          if (mounted) setState(() => _error = '无法播放此视频：$error');
        });
    _controller.addListener(_refresh);
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _controller.removeListener(_refresh);
    _controller.dispose();
    super.dispose();
  }

  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes;
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    final duration = _controller.value.duration;
    final position = _controller.value.position;
    final maxMilliseconds = duration.inMilliseconds > 0
        ? duration.inMilliseconds
        : 1;
    final currentMilliseconds = position.inMilliseconds
        .clamp(0, maxMilliseconds)
        .toDouble();
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(
          widget.fileName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: widget.onClose,
        ),
      ),
      body: Center(
        child: _error != null
            ? Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  _error!,
                  style: const TextStyle(color: Colors.white),
                  textAlign: TextAlign.center,
                ),
              )
            : !_controller.value.isInitialized
            ? const CircularProgressIndicator()
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AspectRatio(
                    aspectRatio: _controller.value.aspectRatio,
                    child: VideoPlayer(_controller),
                  ),
                  Row(
                    children: [
                      IconButton(
                        color: Colors.white,
                        icon: Icon(
                          _controller.value.isPlaying
                              ? Icons.pause
                              : Icons.play_arrow,
                        ),
                        onPressed: () => _controller.value.isPlaying
                            ? _controller.pause()
                            : _controller.play(),
                      ),
                      Text(
                        _formatDuration(position),
                        style: const TextStyle(color: Colors.white),
                      ),
                      Expanded(
                        child: Slider(
                          value: currentMilliseconds,
                          max: maxMilliseconds.toDouble(),
                          onChanged: (value) => _controller.seekTo(
                            Duration(milliseconds: value.round()),
                          ),
                        ),
                      ),
                      Text(
                        _formatDuration(duration),
                        style: const TextStyle(color: Colors.white),
                      ),
                      const SizedBox(width: 12),
                    ],
                  ),
                ],
              ),
      ),
    );
  }
}

String directMimeTypeForFile(String fileName) {
  final extension = fileName.split('.').last.toLowerCase();
  return switch (extension) {
    'jpg' || 'jpeg' => 'image/jpeg',
    'png' => 'image/png',
    'gif' => 'image/gif',
    'webp' => 'image/webp',
    'heic' => 'image/heic',
    'mp4' || 'm4v' => 'video/mp4',
    'mov' => 'video/quicktime',
    '3gp' => 'video/3gpp',
    'avi' => 'video/x-msvideo',
    'flv' => 'video/x-flv',
    'mkv' => 'video/x-matroska',
    'mpeg' || 'mpg' => 'video/mpeg',
    'webm' => 'video/webm',
    'wmv' => 'video/x-ms-wmv',
    'mp3' => 'audio/mpeg',
    'm4a' || 'aac' => 'audio/mp4',
    'wav' => 'audio/wav',
    'ogg' || 'opus' => 'audio/ogg',
    'amr' => 'audio/amr',
    'pdf' => 'application/pdf',
    'txt' => 'text/plain',
    'md' => 'text/markdown',
    'csv' => 'text/csv',
    'log' => 'text/plain',
    'json' => 'application/json',
    'xml' => 'application/xml',
    'doc' => 'application/msword',
    'docx' =>
      'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'xls' => 'application/vnd.ms-excel',
    'xlsx' =>
      'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'ppt' => 'application/vnd.ms-powerpoint',
    'pptx' => 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
    _ => 'application/octet-stream',
  };
}

class DirectChatClientApp extends StatefulWidget {
  const DirectChatClientApp({
    required this.api,
    required this.clientId,
    required this.clientName,
    required this.deviceName,
    required this.inviteCode,
    required this.cache,
    super.key,
  });

  final DirectChatApi api;
  final String clientId;
  final String clientName;
  final String deviceName;
  final String inviteCode;
  final SecureCache cache;

  @override
  State<DirectChatClientApp> createState() => _DirectChatClientAppState();
}

class _DirectChatClientAppState extends State<DirectChatClientApp> {
  final _navigatorKey = GlobalKey<NavigatorState>();
  String? _token;
  String? _error;
  late String _clientName;
  late final TextEditingController _clientNameController;
  final _chatScreenKey = GlobalKey<_DirectChatScreenState>();
  bool _busy = true;
  bool _exiting = false;

  @override
  void initState() {
    super.initState();
    _clientName = widget.cache.text('direct-client-name') ?? widget.clientName;
    _clientNameController = TextEditingController(text: _clientName);
    _connect();
  }

  @override
  void dispose() {
    _clientNameController.dispose();
    widget.api.close();
    super.dispose();
  }

  Future<void> _connect() async {
    AppLogger.log(
      'client.connect_started',
      details: {'server': widget.api.serverUri.authority},
    );
    try {
      final response = await widget.api.validate(
        code: widget.inviteCode,
        clientId: widget.clientId,
        clientName:
            widget.cache.text('direct-client-name') ?? widget.clientName,
        deviceName: widget.deviceName,
        token: widget.cache.text('direct-token:${widget.clientId}') ?? '',
      );
      if (response['valid'] != true) {
        final message = switch (response['error']) {
          _ => '邀请码错误或客户端认证失败。',
        };
        throw StateError(message);
      }
      final token = response['token'];
      if (token is! String || token.isEmpty) {
        throw const FormatException('Server did not return a client token.');
      }
      await widget.cache.putText('direct-token:${widget.clientId}', token);
      if (!mounted) return;
      setState(() {
        _token = token;
        _error = null;
        _busy = false;
      });
      AppLogger.log('client.connected');
      unawaited(_uploadLogs());
    } catch (error) {
      AppLogger.log('client.connect_failed', level: 'error', error: error);
      if (!mounted) return;
      setState(() {
        _error = serverConnectionErrorMessage(error);
        _busy = false;
      });
    }
  }

  Future<void> _exitClient() async {
    if (_exiting) return;
    _exiting = true;
    AppLogger.log('client.user_exit_requested');
    try {
      await stopClientBackgroundService();
    } catch (error, stackTrace) {
      AppLogger.log(
        'client.background_service_stop_failed',
        level: 'error',
        error: error,
        stackTrace: stackTrace,
      );
    }
    if (mounted) await SystemNavigator.pop();
  }

  Future<void> _uploadLogs() async {
    final token = _token;
    if (token == null) return;
    try {
      AppLogger.log('logs.upload_started');
      await widget.api.uploadLogs(
        clientId: widget.clientId,
        token: token,
        content: await AppLogger.readForUpload(),
      );
      AppLogger.log('logs.upload_succeeded');
    } catch (error, stackTrace) {
      AppLogger.log(
        'logs.upload_failed',
        level: 'error',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> _editClientName() async {
    final dialogContext = _navigatorKey.currentContext;
    if (dialogContext == null) {
      AppLogger.log('client.name_editor_unavailable', level: 'warning');
      return;
    }
    _clientNameController.text = _clientName;
    final name = await showDialog<String>(
      context: dialogContext,
      builder: (context) => AlertDialog(
        title: const Text('修改显示名称'),
        content: TextField(
          controller: _clientNameController,
          autofocus: true,
          maxLength: 80,
          style: const TextStyle(fontSize: 14),
          decoration: const InputDecoration(labelText: '客户端名称'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(context, _clientNameController.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty || name == _clientName) return;
    final token = _token;
    if (token == null) return;
    try {
      final response = await widget.api.validate(
        code: widget.inviteCode,
        clientId: widget.clientId,
        clientName: name,
        deviceName: widget.deviceName,
        token: token,
      );
      if (response['valid'] != true) {
        throw StateError('服务器未接受新的显示名称。');
      }
      final updatedToken = response['token'];
      if (updatedToken is! String || updatedToken.isEmpty) {
        throw const FormatException('服务器未返回有效的客户端授权。');
      }
      await widget.cache.putText('direct-client-name', name);
      await widget.cache.putText(
        'direct-token:${widget.clientId}',
        updatedToken,
      );
      if (!mounted) return;
      setState(() {
        _clientName = name;
        _token = updatedToken;
      });
    } catch (error, stackTrace) {
      AppLogger.log(
        'client.name_update_failed',
        level: 'error',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) {
        final messengerContext = _navigatorKey.currentContext;
        if (messengerContext != null && messengerContext.mounted) {
          ScaffoldMessenger.of(messengerContext)
              .showSnackBar(SnackBar(content: Text('名称修改失败：$error')));
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    navigatorKey: _navigatorKey,
    title: 'Consent Chat',
    theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
    home: PopScope<Object?>(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_exitClient());
      },
      child: Scaffold(
        appBar: AppBar(
          automaticallyImplyLeading: false,
          leading: IconButton(
            tooltip: '修改名称',
            onPressed: () => unawaited(_editClientName()),
            icon: const Icon(Icons.edit_outlined),
          ),
          title: InkWell(
            onTap: () => unawaited(_editClientName()),
            child: Text(
              _clientName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 16),
            ),
          ),
          actions: [
            if (_token != null)
              TextButton.icon(
                onPressed: () => _chatScreenKey.currentState?._uploadAvatar(),
                icon: const Icon(Icons.add_a_photo_outlined),
                label: const Text('上传头像'),
              ),
          ],
        ),
        body: _busy
            ? const Center(child: CircularProgressIndicator())
            : _token == null
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _error ?? 'Unable to connect.',
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 12),
                      FilledButton(
                        onPressed: () {
                          setState(() => _busy = true);
                          _connect();
                        },
                        child: const Text('重试连接'),
                      ),
                    ],
                  ),
                ),
              )
            : DirectChatScreen(
                key: _chatScreenKey,
                api: widget.api,
                clientId: widget.clientId,
                token: _token!,
                cache: widget.cache,
              ),
      ),
    ),
  );
}

class DirectChatScreen extends StatefulWidget {
  const DirectChatScreen({
    required this.api,
    required this.clientId,
    required this.token,
    required this.cache,
    super.key,
  });

  final DirectChatApi api;
  final String clientId;
  final String token;
  final SecureCache cache;

  @override
  State<DirectChatScreen> createState() => _DirectChatScreenState();
}

class _DirectChatScreenState extends State<DirectChatScreen> {
  final _text = TextEditingController();
  final _scrollController = ScrollController();
  Timer? _pollTimer;
  Timer? _videoCallInviteTimer;
  Timer? _profileTimer;
  Timer? _mediaCleanupTimer;
  final _recorder = AudioRecorder();
  List<Map<String, dynamic>> _messages = [];
  bool _recording = false;
  bool _polling = false;
  bool _exitingForServerShutdown = false;
  bool _showingVibrationAlert = false;
  bool _pollingVideoCallInvites = false;
  final Set<String> _handledVideoCallIds = {};
  int _consecutiveServerFailures = 0;
  final Set<String> _sendingMessageIds = {};
  final Set<String> _cancelledMessageIds = {};
  final Set<String> _downloadingMessageIds = {};
  final Set<String> _selectedMessageIds = {};
  final Map<String, int> _downloadProgress = {};
  Future<void> _attachmentQueue = Future<void>.value();
  Future<void> _cacheWrite = Future<void>.value();
  String? _error;
  String? _myAvatar;
  String? _otherAvatar;
  bool _selectionMode = false;
  bool _deletingMessages = false;
  int _messageRevision = 0;

  String get _cacheKey => 'direct-messages:${widget.clientId}';

  @override
  void initState() {
    super.initState();
    final cachedMessages = widget.cache.mapList(_cacheKey);
    final now = DateTime.now();
    final expiredMessages = cachedMessages
        .where((message) => !isDirectClientMessageVisible(message, now: now))
        .toList();
    _messages =
        cachedMessages
            .where((message) => isDirectClientMessageVisible(message, now: now))
            .toList()
          ..sort(compareDirectMessages);
    if (expiredMessages.isNotEmpty) {
      unawaited(_persistMessages());
      unawaited(_purgeExpiredMessageAttachments(expiredMessages));
    }
    for (final message in _messages.where(
      (message) => message['pending'] == true,
    )) {
      message['upload_progress'] = 0;
      message
        ..remove('upload_error')
        ..['delivery_state'] = 'queued';
    }
    _myAvatar = widget.cache.text('direct-avatar:${widget.clientId}');
    unawaited(_scheduleMediaCleanup());
    unawaited(_refreshProfile());
    _poll();
    _pollTimer = Timer.periodic(const Duration(seconds: 3), (_) => _poll());
    _videoCallInviteTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => unawaited(_pollVideoCallInvites()),
    );
    _profileTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _refreshProfile(),
    );
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _videoCallInviteTimer?.cancel();
    _profileTimer?.cancel();
    _mediaCleanupTimer?.cancel();
    _recorder.dispose();
    _text.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _pollVideoCallInvites() async {
    if (_pollingVideoCallInvites || !mounted) return;
    _pollingVideoCallInvites = true;
    try {
      final events = await widget.api.pollVideoCallSignals(
        clientId: widget.clientId,
        token: widget.token,
      );
      for (final event in events) {
        final callId = event['call_id'];
        if (event['type'] != 'incoming' ||
            callId is! String ||
            !_handledVideoCallIds.add(callId)) {
          continue;
        }
        await _showIncomingVideoCall(event);
      }
    } catch (error, stackTrace) {
      AppLogger.log(
        'video_call.invite_poll_failed',
        level: 'warning',
        error: error,
        stackTrace: stackTrace,
      );
    } finally {
      _pollingVideoCallInvites = false;
    }
  }

  Future<void> _showIncomingVideoCall(Map<String, dynamic> invite) async {
    final callId = invite['call_id'];
    if (callId is! String || !mounted) return;
    final accepted = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: const Text('视频通话邀请'),
        content: const Text('服务端正在呼叫。接听后摄像头和麦克风将保持开启。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('拒绝'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            icon: const Icon(Icons.videocam),
            label: const Text('接听'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    try {
      await widget.api.sendVideoCallSignal(
        clientId: widget.clientId,
        token: widget.token,
        callId: callId,
        type: accepted == true ? 'accept' : 'reject',
      );
      if (accepted != true || !mounted) return;
      final rawIceServers = invite['ice_servers'];
      final iceServers = rawIceServers is List
          ? rawIceServers
                .whereType<Map>()
                .map(Map<String, dynamic>.from)
                .toList()
          : const <Map<String, dynamic>>[
              {
                'urls': ['stun:stun.l.google.com:19302'],
              },
            ];
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => DirectVideoCallDialog(
          callId: callId,
          clientSide: true,
          iceServers: iceServers,
          sendSignal: (type, {sdp, candidate}) =>
              widget.api.sendVideoCallSignal(
                clientId: widget.clientId,
                token: widget.token,
                callId: callId,
                type: type,
                sdp: sdp,
                candidate: candidate,
              ),
          pollSignals: () => widget.api.pollVideoCallSignals(
            clientId: widget.clientId,
            token: widget.token,
          ),
          onClose: () => Navigator.of(dialogContext).pop(),
        ),
      );
    } catch (error, stackTrace) {
      AppLogger.log(
        'video_call.invite_response_failed',
        level: 'error',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) setState(() => _error = '视频通话信令失败：$error');
    }
  }

  Future<void> _refreshProfile() async {
    try {
      final profile = await widget.api.profile(
        clientId: widget.clientId,
        token: widget.token,
      );
      final myAvatar = profile['avatar_data'] as String?;
      final avatar = profile['server_avatar_data'] as String?;
      if (!mounted || (avatar == _otherAvatar && myAvatar == _myAvatar)) return;
      setState(() {
        _myAvatar = myAvatar;
        _otherAvatar = avatar;
      });
      if (myAvatar != null) {
        await widget.cache.putText(
          'direct-avatar:${widget.clientId}',
          myAvatar,
        );
      }
    } catch (error, stackTrace) {
      AppLogger.log(
        'client.profile_refresh_failed',
        level: 'warning',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> _uploadAvatar() async {
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
      if (mounted) setState(() => _error = '头像图片不能超过 1 MB。');
      return;
    }
    final mimeType = directMimeTypeForFile(file.name);
    if (!const {'image/jpeg', 'image/png', 'image/webp'}.contains(mimeType)) {
      if (mounted) setState(() => _error = '头像仅支持 JPG、PNG 或 WebP 图片。');
      return;
    }
    final encoded = base64Encode(bytes);
    setState(() {
      _myAvatar = encoded;
      _error = null;
    });
    await widget.cache.putText('direct-avatar:${widget.clientId}', encoded);
    try {
      await widget.api.uploadAvatar(
        clientId: widget.clientId,
        token: widget.token,
        data: encoded,
        mimeType: mimeType,
      );
    } catch (error) {
      if (mounted) setState(() => _error = '头像上传失败：$error');
    }
  }

  Future<void> _poll() async {
    if (_polling || _deletingMessages) return;
    _polling = true;
    final revision = _messageRevision;
    final wasNearEnd =
        !_scrollController.hasClients ||
        _scrollController.position.extentAfter < 80;
    try {
      final sent = <Map<String, dynamic>>[];
      for (final pending in _messages.where(
        (message) =>
            message['pending'] == true &&
            message['delivery_state'] != 'failed' &&
            !_sendingMessageIds.contains(message['id'].toString()) &&
            !_cancelledMessageIds.contains(message['id'].toString()),
      )) {
        try {
          _updateMessageStatus(pending['id'].toString(), {
            'delivery_state': pending['file_path'] is String
                ? 'uploading'
                : 'sending',
          });
          final response = pending['file_path'] is String
              ? await widget.api.sendMediaFile(
                  clientId: widget.clientId,
                  token: widget.token,
                  messageId: pending['id'].toString(),
                  fileName: pending['file_name'].toString(),
                  mimeType: pending['mime_type'].toString(),
                  filePath: pending['file_path'] as String,
                  fileSize: pending['media_size'] as int,
                  encryptedChunks: pending['encrypted_local'] == true,
                  rawVideoChunks:
                      pending['encrypted_local'] != true &&
                      (pending['mime_type'] as String? ?? '').startsWith(
                        'video/',
                      ),
                  sourceChunkCount: pending['chunk_count'] as int?,
                  body: pending['body']?.toString() ?? '',
                  previewData: pending['preview_data'] as String?,
                  onUploadState: (uploadId, _) async {
                    _updateMessageStatus(pending['id'].toString(), {
                      'upload_id': uploadId,
                    });
                    await _persistMessages();
                  },
                  isCancelled: () =>
                      _cancelledMessageIds.contains(pending['id'].toString()),
                  onProgress: (progress) =>
                      _updateUploadProgress(pending['id'].toString(), progress),
                )
              : await widget.api.send(
                  clientId: widget.clientId,
                  token: widget.token,
                  messageId: pending['id'].toString(),
                  body: pending['body'].toString(),
                );
          response['sent'] = true;
          response['delivery_state'] = 'sent';
          response['upload_progress'] = 100;
          if (pending['file_path'] is String) {
            await _removePendingAttachmentDirectory(pending);
            pending
              ..remove('file_path')
              ..remove('encrypted_local')
              ..remove('chunk_count');
          }
          sent.add(response);
        } on Exception {
          _updateMessageStatus(pending['id'].toString(), {
            'delivery_state': 'failed',
            'upload_progress': 0,
            'upload_error': '连接失败，请重试。',
          });
        }
      }
      final received = (await widget.api.messages(
        clientId: widget.clientId,
        token: widget.token,
      )).where(isDirectClientMessageVisible).toList();
      if (_deletingMessages || revision != _messageRevision) return;
      final previousById = {
        for (final message in _messages) message['id'].toString(): message,
      };
      final merged = mergeDirectMessageSnapshots(
        localMessages: _messages,
        sentMessages: sent,
        receivedMessages: received,
        sendingMessageIds: _sendingMessageIds,
      );
      merged.removeWhere((message) => !isDirectClientMessageVisible(message));
      final newVibrationAlert = received.where((message) {
        return message['type'] == 'vibration_alert' &&
            !_messages.any((existing) => existing['id'] == message['id']);
      }).firstOrNull;
      final messagesChanged = !directMessageListsEqual(_messages, merged);
      if (messagesChanged) await _persistMessages(merged);
      if (!mounted) return;
      _consecutiveServerFailures = 0;
      if (messagesChanged) {
        setState(() {
          _messages = merged;
        });
        unawaited(_scheduleMediaCleanup());
      }

      if (sent.isNotEmpty) {
        AppLogger.log(
          'client.queued_messages_sent',
          details: {'count': sent.length},
        );
      }
      if (newVibrationAlert != null) {
        unawaited(_showVibrationAlert());
      }
      final hasNewMessages = merged.any(
        (message) => !previousById.containsKey(message['id'].toString()),
      );
      if (messagesChanged && hasNewMessages && wasNearEnd) _scrollToEnd();
    } catch (error) {
      AppLogger.log('client.sync_failed', level: 'error', error: error);
      if (error is SocketException || error is TimeoutException) {
        _consecutiveServerFailures++;
        if (_consecutiveServerFailures >= 3) {
          await _exitForServerShutdown();
          return;
        }
      }
    } finally {
      _polling = false;
    }
  }

  Future<void> _deleteSelectedMessages() async {
    if (_selectedMessageIds.isEmpty || _deletingMessages) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除聊天记录'),
        content: Text('确定永久删除选中的 ${_selectedMessageIds.length} 条消息及其附件吗？'),
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
    if (confirmed != true || !mounted) return;
    final ids = _selectedMessageIds.toSet();
    final removed = _messages
        .where((message) => ids.contains(message['id'].toString()))
        .map(Map<String, dynamic>.from)
        .toList();
    _cancelledMessageIds.addAll(ids);
    _messageRevision++;
    setState(() {
      _deletingMessages = true;
      _error = null;
    });
    try {
      await widget.api.deleteMessages(
        clientId: widget.clientId,
        token: widget.token,
        messageIds: ids,
      );
      if (!mounted) return;
      setState(() {
        _messages.removeWhere((message) => ids.contains(message['id']));
        _selectedMessageIds.clear();
        _selectionMode = false;
      });
      await _persistMessages();
      await _purgeDeletedMessageFiles(removed);
    } catch (error, stackTrace) {
      AppLogger.log(
        'client.messages_delete_failed',
        level: 'error',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) setState(() => _error = '删除聊天记录失败：$error');
    } finally {
      _deletingMessages = false;
      if (mounted) unawaited(_poll());
    }
  }

  Future<void> _scheduleMediaCleanup({bool retry = false}) async {
    try {
      _mediaCleanupTimer?.cancel();
      if (retry) {
        _mediaCleanupTimer = Timer(
          const Duration(minutes: 1),
          () => unawaited(_cleanupSentAttachmentFiles()),
        );
        return;
      }
      final now = DateTime.now();
      DateTime? nextRun;
      for (final message in _messages) {
        final expiresAt = directMediaCleanupAt(message);
        if (expiresAt == null) continue;
        if (nextRun == null || expiresAt.isBefore(nextRun)) {
          nextRun = expiresAt;
        }
      }
      if (nextRun == null) return;
      final delay = nextRun.difference(now);
      _mediaCleanupTimer = Timer(
        delay.isNegative ? Duration.zero : delay,
        () => unawaited(_cleanupSentAttachmentFiles()),
      );
    } catch (error, stackTrace) {
      AppLogger.log(
        'client.media_cleanup_schedule_failed',
        level: 'warning',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> _cleanupSentAttachmentFiles() async {
    if (!mounted) return;
    if (_polling ||
        _deletingMessages ||
        _sendingMessageIds.isNotEmpty ||
        _downloadingMessageIds.isNotEmpty) {
      await _scheduleMediaCleanup(retry: true);
      return;
    }
    try {
      var changed = false;
      final now = DateTime.now();
      for (final message in _messages) {
        final cleanupAt = directMediaCleanupAt(message);
        if (cleanupAt == null || now.isBefore(cleanupAt)) {
          continue;
        }
        if (!hasDirectAttachment(message)) continue;
        final messageId = message['id']?.toString();
        if (messageId == null ||
            !RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(messageId)) {
          continue;
        }
        final mediaId = message['media_id']?.toString();
        if (mediaId != null &&
            RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(mediaId)) {
          final downloadDirectory = await directCacheDirectory(
            'client-downloads',
            segments: [widget.clientId, mediaId],
          );
          if (await downloadDirectory.exists()) {
            try {
              await downloadDirectory.delete(recursive: true);
            } on FileSystemException catch (error, stackTrace) {
              AppLogger.log(
                'client.media_cleanup_failed',
                level: 'warning',
                details: {'media_id': mediaId},
                error: error,
                stackTrace: stackTrace,
              );
            }
          }
        }
        final pendingDirectory = await directCacheDirectory(
          'pending-attachments',
          segments: [widget.clientId, messageId],
        );
        if (await pendingDirectory.exists()) {
          try {
            await pendingDirectory.delete(recursive: true);
          } on FileSystemException catch (error, stackTrace) {
            AppLogger.log(
              'client.pending_media_cleanup_failed',
              level: 'warning',
              details: {'message_id': messageId},
              error: error,
              stackTrace: stackTrace,
            );
          }
        }
        for (final field in ['media_path', 'file_path']) {
          final localPath = message[field];
          if (localPath is String &&
              await _isManagedClientCachePath(localPath)) {
            try {
              await File(localPath).delete();
            } on FileSystemException catch (error, stackTrace) {
              AppLogger.log(
                'client.local_media_cleanup_failed',
                level: 'warning',
                details: {'message_id': messageId},
                error: error,
                stackTrace: stackTrace,
              );
            }
          }
        }
        final sourcePath = message['source_file_path'];
        if (sourcePath is String &&
            RegExp(
              r'(^|[\\/])voice-[A-Za-z0-9-]+\.m4a$',
              caseSensitive: false,
            ).hasMatch(sourcePath) &&
            await _isManagedClientCachePath(sourcePath)) {
          try {
            await File(sourcePath).delete();
          } on FileSystemException catch (error, stackTrace) {
            AppLogger.log(
              'client.recording_cleanup_failed',
              level: 'warning',
              details: {'message_id': messageId},
              error: error,
              stackTrace: stackTrace,
            );
          }
        }
        if (message.remove('media_path') != null) changed = true;
        if (message.remove('media_data') != null) changed = true;
        if (message.remove('file_path') != null) changed = true;
        if (message.remove('source_file_path') != null) changed = true;
        if (message.remove('encrypted_local') != null) changed = true;
      }
      final previousLength = _messages.length;
      _messages.removeWhere((message) {
        final cleanupAt = directMediaCleanupAt(message);
        return cleanupAt != null && !now.isBefore(cleanupAt);
      });
      if (_messages.length != previousLength) changed = true;
      if (changed) {
        if (mounted) setState(() {});
        await _persistMessages();
      }
    } catch (error, stackTrace) {
      AppLogger.log(
        'client.media_cleanup_failed',
        level: 'warning',
        error: error,
        stackTrace: stackTrace,
      );
    } finally {
      await _scheduleMediaCleanup();
    }
  }

  Future<bool> _isManagedClientCachePath(String path) async {
    final file = File(path);
    if (!await file.exists()) return false;
    final resolvedPath = await file.resolveSymbolicLinks();
    final normalizedPath = resolvedPath.toLowerCase();
    final tempDirectory = await getTemporaryDirectory();
    final roots = <String>[
      (await directCacheRoot()).path,
      (await getApplicationSupportDirectory()).path,
      tempDirectory.path,
    ];
    for (final root in roots) {
      final normalizedRoot = Directory(root).absolute.path
          .replaceAll(RegExp(r'[\\/]+$'), '')
          .toLowerCase();
      if (normalizedPath.startsWith(
        '$normalizedRoot${Platform.pathSeparator}'.toLowerCase(),
      )) {
        return true;
      }
    }
    return false;
  }

  Future<void> _purgeExpiredMessageAttachments(
    Iterable<Map<String, dynamic>> messages,
  ) async {
    try {
      for (final message in messages) {
        final messageId = message['id']?.toString();
        if (messageId == null ||
            !RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(messageId)) {
          continue;
        }
        final mediaId = message['media_id']?.toString();
        if (mediaId != null &&
            RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(mediaId)) {
          final downloadDirectory = await directCacheDirectory(
            'client-downloads',
            segments: [widget.clientId, mediaId],
          );
          if (await downloadDirectory.exists()) {
            await downloadDirectory.delete(recursive: true);
          }
        }
        final pendingDirectory = await directCacheDirectory(
          'pending-attachments',
          segments: [widget.clientId, messageId],
        );
        if (await pendingDirectory.exists()) {
          await pendingDirectory.delete(recursive: true);
        }
        for (final field in ['media_path', 'file_path']) {
          final localPath = message[field];
          if (localPath is String &&
              await _isManagedClientCachePath(localPath)) {
            await File(localPath).delete();
          }
        }
        final sourcePath = message['source_file_path'];
        if (sourcePath is String &&
            RegExp(
              r'(^|[\\/])voice-[A-Za-z0-9-]+\.m4a$',
              caseSensitive: false,
            ).hasMatch(sourcePath) &&
            await _isManagedClientCachePath(sourcePath)) {
          await File(sourcePath).delete();
        }
      }
    } catch (error, stackTrace) {
      AppLogger.log(
        'client.expired_media_cleanup_failed',
        level: 'warning',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> _removePendingAttachmentDirectory(
    Map<String, dynamic> message,
  ) async {
    final messageId = message['id']?.toString();
    if (messageId == null ||
        !RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(messageId)) {
      return;
    }
    final directory = await directCacheDirectory(
      'pending-attachments',
      segments: [widget.clientId, messageId],
    );
    if (await directory.exists()) await directory.delete(recursive: true);
  }

  Future<void> _purgeDeletedMessageFiles(
    Iterable<Map<String, dynamic>> messages,
  ) async {
    for (final message in messages) {
      final messageId = message['id']?.toString();
      if (messageId == null ||
          !RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(messageId)) {
        continue;
      }
      final pendingDirectory = await directCacheDirectory(
        'pending-attachments',
        segments: [widget.clientId, messageId],
      );
      if (await pendingDirectory.exists()) {
        await pendingDirectory.delete(recursive: true);
      }
      final mediaId = message['media_id']?.toString();
      if (mediaId == null ||
          !RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(mediaId)) {
        continue;
      }
      final downloadDirectory = await directCacheDirectory(
        'client-downloads',
        segments: [widget.clientId, mediaId],
      );
      if (await downloadDirectory.exists()) {
        await downloadDirectory.delete(recursive: true);
      }
    }
  }

  Future<void> _exitForServerShutdown() async {
    if (_exitingForServerShutdown) return;
    _exitingForServerShutdown = true;
    _pollTimer?.cancel();
    AppLogger.log('client.server_unavailable_exit');
    try {
      await stopClientBackgroundService();
    } catch (error, stackTrace) {
      AppLogger.log(
        'client.background_service_stop_failed',
        level: 'error',
        error: error,
        stackTrace: stackTrace,
      );
    }
    if (mounted) await SystemNavigator.pop();
  }

  Future<void> _showVibrationAlert() async {
    if (_showingVibrationAlert || !mounted) return;
    _showingVibrationAlert = true;
    try {
      await Vibration.vibrate(pattern: const [0, 500, 250, 500]);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('震动提醒'),
          content: const Text('管理端向你发送了震动提醒。'),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('知道了'),
            ),
          ],
        ),
      );
    } catch (error, stackTrace) {
      AppLogger.log(
        'client.vibration_alert_failed',
        level: 'error',
        error: error,
        stackTrace: stackTrace,
      );
    } finally {
      _showingVibrationAlert = false;
    }
  }

  void _send() {
    final body = _text.text.trim();
    if (body.isEmpty) return;
    AppLogger.log(
      'client.message_send_started',
      details: {'characters': body.length},
    );
    final pendingMessage = <String, dynamic>{
      'id': _uuid.v4(),
      'client_id': widget.clientId,
      'sender': 'client',
      'body': body,
      'created_at': DateTime.now().toUtc().toIso8601String(),
      'pending': true,
      'delivery_state': 'sending',
      'upload_progress': 0,
    };
    _text.clear();
    FocusScope.of(context).unfocus();
    setState(() {
      _messages = [..._messages, pendingMessage]..sort(compareDirectMessages);
      _error = null;
    });
    _sendingMessageIds.add(pendingMessage['id'] as String);
    _scrollToEnd();
    unawaited(_sendPendingMessage(pendingMessage, body));
  }

  Future<void> _sendPendingMessage(
    Map<String, dynamic> pendingMessage,
    String body,
  ) async {
    final messageId = pendingMessage['id'] as String;
    unawaited(
      _persistMessages().catchError((Object error, StackTrace stackTrace) {
        AppLogger.log(
          'client.message_queue_save_failed',
          level: 'error',
          error: error,
          stackTrace: stackTrace,
        );
      }),
    );
    try {
      final message = await widget.api.send(
        clientId: widget.clientId,
        token: widget.token,
        messageId: messageId,
        body: body,
      );
      message['sent'] = true;
      message['delivery_state'] = 'sent';
      message['upload_progress'] = 100;
      final merged = <Map<String, dynamic>>[
        for (final item in _messages)
          if (item['id'] != message['id']) item,
        message,
      ]..sort(compareDirectMessages);
      if (mounted) setState(() => _messages = merged);
      unawaited(
        _persistMessages().catchError((Object error, StackTrace stackTrace) {
          AppLogger.log(
            'client.message_cache_write_failed',
            level: 'error',
            error: error,
            stackTrace: stackTrace,
          );
        }),
      );
      AppLogger.log('client.message_sent');
      _scrollToEnd();
    } catch (error) {
      AppLogger.log('client.message_send_failed', level: 'error', error: error);
      if (mounted) {
        _updateMessageStatus(messageId, {
          'delivery_state': 'failed',
          'upload_progress': 0,
        });
      }
    } finally {
      _sendingMessageIds.remove(messageId);
    }
  }

  Future<void> _persistMessages([List<Map<String, dynamic>>? messages]) {
    final snapshot = (messages ?? _messages)
        .map((message) => Map<String, dynamic>.from(message))
        .toList();
    final write = _cacheWrite.then(
      (_) => widget.cache.putMapList(_cacheKey, snapshot),
    );
    _cacheWrite = write.catchError((Object error, StackTrace stackTrace) {
      AppLogger.log(
        'client.message_cache_write_failed',
        level: 'error',
        error: error,
        stackTrace: stackTrace,
      );
    });
    return write;
  }

  Future<void> _pickAttachment(FileType type) async {
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
      if (mounted) setState(() => _error = '打开相册失败：$error');
      return;
    }
    if (files.isEmpty) return;
    final selectedMessages = [
      for (var index = 0; index < files.length; index++)
        <String, dynamic>{
          'id': _uuid.v4(),
          'client_id': widget.clientId,
          'sender': 'client',
          'body': '',
          'created_at': DateTime.now().toUtc().toIso8601String(),
          'file_name': files[index].name,
          'mime_type': directMimeTypeForFile(files[index].name),
          'media_size': files[index].size,
          if (files[index].path != null) 'file_path': files[index].path,
          if (files[index].path != null) 'source_file_path': files[index].path,
          'pending': true,
          'delivery_state': index == 0 ? 'preparing' : 'queued',
          'upload_progress': 0,
        },
    ];
    final previewFutures = files.map((file) {
      final mimeType = directMimeTypeForFile(file.name);
      if (file.path == null ||
          (!mimeType.startsWith('image/') && !mimeType.startsWith('video/'))) {
        return null;
      }
      return createDirectMediaPreview(filePath: file.path!, mimeType: mimeType);
    }).toList();
    setState(() {
      _messages = [..._messages, ...selectedMessages]
        ..sort(compareDirectMessages);
      _error = null;
    });
    _sendingMessageIds.addAll(
      selectedMessages.map((message) => message['id'] as String),
    );
    await _persistMessages();
    _scrollToEnd();
    for (var index = 0; index < files.length; index++) {
      if (_cancelledMessageIds.contains(selectedMessages[index]['id'])) {
        _sendingMessageIds.remove(selectedMessages[index]['id']);
        continue;
      }
      _updateMessageStatus(selectedMessages[index]['id'] as String, {
        'delivery_state': 'preparing',
        'prepare_progress': 0,
      });
      try {
        await _sendAttachment(
          files[index].name,
          directMimeTypeForFile(files[index].name),
          files[index].path,
          files[index].readStream,
          files[index].size,
          existingPendingMessage: selectedMessages[index],
          previewFuture: previewFutures[index],
        );
      } catch (error, stackTrace) {
        _sendingMessageIds.remove(selectedMessages[index]['id']);
        _updateMessageStatus(selectedMessages[index]['id'] as String, {
          'delivery_state': 'failed',
          'upload_error': error.toString(),
        });
        AppLogger.log(
          'client.attachment_send_failed',
          level: 'error',
          details: {'mime_type': selectedMessages[index]['mime_type']},
          error: error,
          stackTrace: stackTrace,
        );
      }
    }
  }

  Future<void> _toggleRecording() async {
    if (_recording) {
      try {
        final path = await _recorder.stop();
        if (mounted) setState(() => _recording = false);
        if (path == null) return;
        final file = File(path);
        await _sendAttachment(
          'voice-${DateTime.now().millisecondsSinceEpoch}.m4a',
          'audio/mp4',
          path,
          null,
          await file.length(),
        );
        await file.delete();
      } catch (error) {
        if (mounted) {
          setState(() {
            _recording = false;
            _error = '语音录制或发送失败：$error';
          });
        }
      }
      return;
    }
    try {
      if (!await _recorder.hasPermission()) {
        setState(() => _error = '未获准使用麦克风。');
        return;
      }
      final directory = await getTemporaryDirectory();
      final path =
          '${directory.path}${Platform.pathSeparator}voice-${_uuid.v4()}.m4a';
      await _recorder.start(
        const RecordConfig(encoder: AudioEncoder.aacLc),
        path: path,
      );
      if (mounted) setState(() => _recording = true);
    } catch (error) {
      if (mounted) setState(() => _error = '无法开始录音：$error');
      AppLogger.log(
        'client.recording_start_failed',
        level: 'error',
        error: error,
      );
    }
  }

  Future<void> _sendAttachment(
    String fileName,
    String mimeType,
    String? sourcePath,
    Stream<List<int>>? sourceStream,
    int fileSize, {
    Map<String, dynamic>? existingPendingMessage,
    Future<String?>? previewFuture,
  }) async {
    final pendingMessage =
        existingPendingMessage ??
        <String, dynamic>{
          'id': _uuid.v4(),
          'client_id': widget.clientId,
          'sender': 'client',
          'body': '',
          'created_at': DateTime.now().toUtc().toIso8601String(),
          'file_name': fileName,
          'mime_type': mimeType,
          'media_size': fileSize,
          if (sourcePath != null) 'file_path': sourcePath,
          if (sourcePath != null) 'source_file_path': sourcePath,
          'pending': true,
          'delivery_state': 'preparing',
          'upload_progress': 0,
        };
    final messageId = pendingMessage['id'] as String;
    if (existingPendingMessage == null) {
      setState(() {
        _messages = [..._messages, pendingMessage]..sort(compareDirectMessages);
        _error = null;
      });
    }
    _sendingMessageIds.add(messageId);
    await _persistMessages();
    _scrollToEnd();
    if (_cancelledMessageIds.contains(messageId)) {
      _sendingMessageIds.remove(messageId);
      _cancelledMessageIds.remove(messageId);
      return;
    }
    String? localPath;
    String? localDirectoryPath;
    var localChunkCount = 0;
    final previewResult =
        previewFuture ??
        (sourcePath != null &&
                (mimeType.startsWith('image/') || mimeType.startsWith('video/'))
            ? createDirectMediaPreview(filePath: sourcePath, mimeType: mimeType)
            : null);
    if (previewResult != null) {
      unawaited(
        previewResult.then((previewData) {
          if (previewData == null || _cancelledMessageIds.contains(messageId)) {
            return Future<void>.value();
          }
          pendingMessage['preview_data'] = previewData;
          _updateMessageStatus(messageId, {'preview_data': previewData});
          return _persistMessages().catchError((
            Object error,
            StackTrace stackTrace,
          ) {
            AppLogger.log(
              'client.message_cache_write_failed',
              level: 'error',
              error: error,
              stackTrace: stackTrace,
            );
          });
        }),
      );
    }
    try {
      if (fileSize <= 0) throw const FileSystemException('所选文件为空。');
      final pendingDirectory = await directCacheDirectory(
        'pending-attachments',
        segments: [widget.clientId, messageId],
      );
      localDirectoryPath = pendingDirectory.path;
      final stream =
          sourceStream ??
          (sourcePath == null ? null : File(sourcePath).openRead());
      if (stream == null) {
        throw const FileSystemException('无法读取所选文件。');
      }
      const chunkSize = 1024 * 1024;
      var copied = 0;
      void updatePreparationProgress(int copiedBytes) {
        final preparationProgress = (copiedBytes * 100 ~/ fileSize).clamp(
          0,
          100,
        );
        final previousPreparationProgress =
            pendingMessage['prepare_progress'] as int? ?? -1;
        if (preparationProgress == 100 ||
            preparationProgress - previousPreparationProgress >= 2) {
          pendingMessage['prepare_progress'] = preparationProgress;
          _updateMessageStatus(messageId, {
            'prepare_progress': preparationProgress,
          });
        }
      }

      await pendingDirectory.create(recursive: true);
      if (mimeType.startsWith('video/')) {
        final extension = _directAttachmentExtension(fileName);
        final stagedVideo = File(
          '${pendingDirectory.path}${Platform.pathSeparator}video$extension',
        );
        localPath = stagedVideo.path;
        final output = stagedVideo.openWrite();
        try {
          var unflushedBytes = 0;
          await for (final chunk in stream) {
            if (_cancelledMessageIds.contains(messageId)) {
              throw const _DirectUploadCancelled();
            }
            output.add(chunk);
            copied += chunk.length;
            unflushedBytes += chunk.length;
            updatePreparationProgress(copied);
            if (unflushedBytes >= chunkSize) {
              await output.flush();
              unflushedBytes = 0;
            }
          }
          await output.flush();
        } finally {
          await output.close();
        }
        localChunkCount = (fileSize + chunkSize - 1) ~/ chunkSize;
      } else {
        localPath = pendingDirectory.path;
        final pendingChunk = <int>[];
        Future<void> saveChunk() async {
          if (pendingChunk.isEmpty) return;
          final encrypted = await compute(_encryptDirectPayload, {
            'code': widget.api._messageCode,
            'plaintext': base64Encode(pendingChunk),
          });
          await File(
            '${pendingDirectory.path}${Platform.pathSeparator}$localChunkCount.chunk',
          ).writeAsString(encrypted, flush: true);
          localChunkCount++;
          pendingChunk.clear();
        }

        await for (final chunk in stream) {
          if (_cancelledMessageIds.contains(messageId)) {
            throw const _DirectUploadCancelled();
          }
          copied += chunk.length;
          updatePreparationProgress(copied);
          var offset = 0;
          while (offset < chunk.length) {
            final available = chunkSize - pendingChunk.length;
            final end = (offset + available).clamp(0, chunk.length);
            pendingChunk.addAll(chunk.sublist(offset, end));
            offset = end;
            if (pendingChunk.length == chunkSize) await saveChunk();
          }
        }
        await saveChunk();
      }
      if (copied != fileSize) {
        throw const FileSystemException('复制附件时文件大小发生变化。');
      }
      final previewData = await previewResult;
      if (previewData != null) {
        pendingMessage['preview_data'] = previewData;
      }
      pendingMessage
        ..['file_path'] = localPath
        ..['encrypted_local'] = !mimeType.startsWith('video/')
        ..['chunk_count'] = localChunkCount;
      _updateMessageStatus(messageId, {
        'delivery_state': 'queued',
        'prepare_progress': 100,
        'file_path': localPath,
        'encrypted_local': !mimeType.startsWith('video/'),
        'chunk_count': localChunkCount,
        if (previewData != null) 'preview_data': previewData,
      });
      await _persistMessages();
    } catch (error) {
      if (localDirectoryPath != null) {
        final directory = Directory(localDirectoryPath);
        if (await directory.exists()) await directory.delete(recursive: true);
      }
      _sendingMessageIds.remove(messageId);
      if (_cancelledMessageIds.remove(messageId)) {
        if (mounted) {
          setState(() {
            _messages.removeWhere((message) => message['id'] == messageId);
          });
        }
        await _persistMessages();
        return;
      }
      _updateMessageStatus(messageId, {
        'delivery_state': 'failed',
        'upload_error': error.toString(),
        if (sourcePath != null) 'file_path': sourcePath,
      });
      await _persistMessages();
      return;
    }
    _updateMessageStatus(messageId, {
      'delivery_state': 'queued',
      'upload_progress': 0,
    });
    final queuedUpload = _attachmentQueue.then((_) async {
      try {
        if (_cancelledMessageIds.contains(messageId)) {
          final localDirectory = Directory(localDirectoryPath!);
          if (await localDirectory.exists()) {
            await localDirectory.delete(recursive: true);
          }
          if (mounted) {
            setState(() {
              _messages.removeWhere((message) => message['id'] == messageId);
            });
          }
          await _persistMessages();
          return;
        }
        if (mounted) {
          _updateMessageStatus(messageId, {'delivery_state': 'uploading'});
        }
        final message = await widget.api.sendMediaFile(
          clientId: widget.clientId,
          token: widget.token,
          messageId: messageId,
          fileName: fileName,
          mimeType: mimeType,
          filePath: localPath!,
          fileSize: fileSize,
          encryptedChunks: mimeType.startsWith('video/') ? false : true,
          rawVideoChunks: mimeType.startsWith('video/'),
          sourceChunkCount: localChunkCount,
          previewData: pendingMessage['preview_data'] as String?,
          onUploadState: (uploadId, _) async {
            _updateMessageStatus(messageId, {'upload_id': uploadId});
            await _persistMessages();
          },
          isCancelled: () => _cancelledMessageIds.contains(messageId),
          onProgress: (progress) => _updateUploadProgress(messageId, progress),
        );
        var localCopyRetained = false;
        try {
          final localDirectory = Directory(localDirectoryPath!);
          if (await localDirectory.exists()) {
            await localDirectory.delete(recursive: true);
          }
        } on FileSystemException catch (error) {
          localCopyRetained = true;
          AppLogger.log(
            'client.pending_attachment_cleanup_failed',
            level: 'warning',
            error: error,
          );
        }
        final confirmed = {
          ...message,
          if (sourcePath != null) 'source_file_path': sourcePath,
          if (localCopyRetained) ...{
            'file_path': localPath,
            'encrypted_local': !mimeType.startsWith('video/'),
            'chunk_count': localChunkCount,
          },
          'pending': false,
          'sent': true,
          'delivery_state': 'sent',
          'upload_progress': 100,
        };
        final merged = <Map<String, dynamic>>[
          for (final item in _messages)
            if (item['id'] != message['id']) item,
          confirmed,
        ]..sort(compareDirectMessages);
        if (mounted) setState(() => _messages = merged);
        unawaited(_persistMessages());
        unawaited(_scheduleMediaCleanup());
        AppLogger.log(
          'client.attachment_sent',
          details: {'bytes': fileSize, 'mime_type': mimeType},
        );
        _scrollToEnd();
      } catch (error) {
        if (_cancelledMessageIds.contains(messageId)) {
          final localDirectory = Directory(localDirectoryPath!);
          if (await localDirectory.exists()) {
            await localDirectory.delete(recursive: true);
          }
          if (mounted) {
            setState(() {
              _messages.removeWhere((message) => message['id'] == messageId);
            });
          }
          await _persistMessages();
          return;
        }
        AppLogger.log(
          'client.attachment_send_failed',
          level: 'error',
          details: {'mime_type': mimeType},
          error: error,
        );
        if (mounted) {
          _updateMessageStatus(messageId, {
            'delivery_state': 'failed',
            'upload_progress': 0,
            'upload_error': error.toString(),
          });
        }
      } finally {
        _sendingMessageIds.remove(messageId);
        _cancelledMessageIds.remove(messageId);
      }
    });
    _attachmentQueue = queuedUpload.catchError((
      Object error,
      StackTrace stackTrace,
    ) {
      AppLogger.log(
        'client.attachment_queue_failed',
        level: 'error',
        details: {'message_id': messageId},
        error: error,
        stackTrace: stackTrace,
      );
    });
    await _persistMessages();
    await queuedUpload;
  }

  void _updateUploadProgress(String messageId, int progress) {
    final message = _messages
        .where((item) => item['id'] == messageId)
        .firstOrNull;
    final previous = message?['upload_progress'] as int? ?? -1;
    if (message == null ||
        previous == progress ||
        (progress != 100 && previous >= 0 && progress - previous < 2)) {
      return;
    }
    _updateMessageStatus(messageId, {'upload_progress': progress});
  }

  void _updateMessageStatus(String messageId, Map<String, Object?> status) {
    if (!mounted) return;
    setState(() {
      for (final message in _messages) {
        if (message['id'] == messageId) message.addAll(status);
      }
    });
  }

  void _retryMessage(String messageId) {
    final message = _messages
        .where((item) => item['id'] == messageId)
        .firstOrNull;
    if (message == null) return;
    message.remove('upload_error');
    _updateMessageStatus(messageId, {
      'delivery_state': 'queued',
      'upload_progress': 0,
    });
    unawaited(_persistMessages());
    unawaited(_poll());
  }

  void _cancelDownload(String messageId) {
    final message = _messages
        .where((item) => item['id'].toString() == messageId)
        .firstOrNull;
    if (message == null) return;
    DirectAttachmentDownloads.instance.cancel(_downloadKey(message));
  }

  String _downloadKey(Map<String, dynamic> message) {
    final messageId = message['id'].toString();
    if (message['encrypted_local'] == true &&
        message['media_path'] is! String) {
      return 'direct-local:${widget.clientId}:$messageId';
    }
    final mediaId = message['media_id'];
    if (mediaId is String) return 'direct:${widget.clientId}:$mediaId';
    return 'direct-local:${widget.clientId}:$messageId';
  }

  Future<String> _prepareAttachment(Map<String, dynamic> message) async {
    final messageId = message['id'].toString();
    final existingPath =
        message['media_path'] ??
        message['source_file_path'] ??
        message['file_path'];
    if (existingPath is String && await File(existingPath).exists()) {
      return existingPath;
    }
    if (!_downloadingMessageIds.add(messageId)) {
      throw StateError('附件正在下载。');
    }
    setState(() {
      _downloadProgress[messageId] = 0;
      _error = null;
    });
    try {
      final localSource = message['file_path'];
      if (message['encrypted_local'] == true &&
          localSource is String &&
          await Directory(localSource).exists() &&
          message['media_path'] is! String) {
        final directory = await directCacheDirectory(
          'client-downloads',
          segments: [widget.clientId, 'local', messageId],
        );
        final safeName = (message['file_name'] as String? ?? 'attachment')
            .replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
        final path = '${directory.path}${Platform.pathSeparator}$safeName';
        await DirectAttachmentDownloads.instance.download(
          key: 'direct-local:${widget.clientId}:$messageId',
          expectedSize: message['media_size'] as int? ?? 0,
          onProgress: (progress) {
            if (mounted) {
              setState(() => _downloadProgress[messageId] = progress);
            }
          },
          download: (onProgress, isCancelled) =>
              widget.api.decryptLocalMediaToFile(
                encryptedDirectory: localSource,
                chunkCount: message['chunk_count'] as int,
                expectedSize: message['media_size'] as int,
                outputPath: path,
                isCancelled: isCancelled,
                onProgress: onProgress,
              ),
        );
        message['media_path'] = path;
        await _persistMessages();
        if (mounted) setState(() {});
      }
      final savedMediaPath = message['media_path'] ?? message['file_path'];
      if ((savedMediaPath is! String || !await File(savedMediaPath).exists()) &&
          message['media_id'] is String &&
          message['chunk_count'] is int) {
        final directory = await directCacheDirectory(
          'client-downloads',
          segments: [widget.clientId, message['media_id'] as String],
        );
        final safeName = (message['file_name'] as String? ?? 'attachment')
            .replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
        final path = '${directory.path}${Platform.pathSeparator}$safeName';
        await DirectAttachmentDownloads.instance.download(
          key: 'direct:${widget.clientId}:${message['media_id']}',
          expectedSize: message['media_size'] as int? ?? 0,
          sequential: (message['mime_type'] as String? ?? '').startsWith(
            'video/',
          ),
          onProgress: (progress) {
            if (mounted) {
              setState(() => _downloadProgress[messageId] = progress);
            }
          },
          download: (onProgress, isCancelled) => widget.api.downloadMediaToFile(
            clientId: widget.clientId,
            token: widget.token,
            mediaId: message['media_id'] as String,
            chunkCount: message['chunk_count'] as int,
            expectedSize: message['media_size'] as int,
            outputPath: path,
            isCancelled: isCancelled,
            onProgress: onProgress,
          ),
        );
        message['media_path'] = path;
        await _persistMessages();
        if (mounted) setState(() {});
      }
      final localPath =
          message['media_path'] ??
          message['source_file_path'] ??
          message['file_path'];
      if (localPath is String && await File(localPath).exists()) {
        return localPath;
      }
      final encoded = message['media_data'];
      if (encoded is String) {
        final directory = await directCacheDirectory(
          'opened-attachments',
          segments: [message['media_id']?.toString() ?? messageId],
        );
        final safeName = (message['file_name'] as String? ?? 'attachment')
            .replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
        final path = '${directory.path}${Platform.pathSeparator}$safeName';
        await File(path).writeAsBytes(base64Decode(encoded), flush: true);
        message['media_path'] = path;
        return path;
      }
      throw StateError('附件文件尚未下载。');
    } finally {
      _downloadingMessageIds.remove(messageId);
      _downloadProgress.remove(messageId);
      if (mounted) setState(() {});
    }
  }

  Future<void> _openAttachment(Map<String, dynamic> message) async {
    try {
      final outgoingVideoPath = directOutgoingVideoPath(message);
      final path =
          outgoingVideoPath != null && await File(outgoingVideoPath).exists()
          ? outgoingVideoPath
          : await _prepareAttachment(message);
      final error = await openDirectAttachment({
        ...message,
        'media_path': path,
      }, context: context);
      if (error != null && mounted) setState(() => _error = error);
    } on DirectDownloadCancelled {
      // Keep completed chunks so the next attempt can resume.
    } catch (error, stackTrace) {
      AppLogger.log(
        'client.attachment_open_failed',
        level: 'error',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) setState(() => _error = '无法打开附件：$error');
    }
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final visibleMessages = _messages
        .where(isDirectMessageVisible)
        .toList(growable: false);
    return Column(
      children: [
        if (_error != null)
          MaterialBanner(
            content: Text(_error!),
            actions: [TextButton(onPressed: _poll, child: const Text('重试'))],
          ),
        Expanded(
          child: visibleMessages.isEmpty
              ? const Center(child: Text('还没有消息'))
              : ListView(
                  controller: _scrollController,
                  padding: const EdgeInsets.all(12),
                  children: [
                    for (final message in visibleMessages)
                      Builder(
                        builder: (context) {
                          final messageId = message['id'].toString();
                          final mediaId = message['media_id'];
                          final downloadKey =
                              mediaId is String ||
                                  message['encrypted_local'] == true
                              ? _downloadKey(message)
                              : null;
                          Widget buildBubble(
                            int? activeProgress,
                          ) => DirectMessageBubble(
                            key: ValueKey(messageId),
                            message: message,
                            outgoing: message['sender'] == 'client',
                            avatarData: message['sender'] == 'client'
                                ? _myAvatar
                                : _otherAvatar,
                            onOpenAttachment: () => _openAttachment(message),
                            onRetry: message['delivery_state'] == 'failed'
                                ? () => _retryMessage(messageId)
                                : null,
                            downloading:
                                _downloadingMessageIds.contains(messageId) ||
                                activeProgress != null,
                            onCancelDownload: () => _cancelDownload(messageId),
                            downloadProgress:
                                _downloadProgress[messageId] ?? activeProgress,
                            showTimestamp: false,
                          );
                          Widget selectableBubble(Widget bubble) {
                            if (!_selectionMode) return bubble;
                            return Row(
                              children: [
                                Checkbox(
                                  value: _selectedMessageIds.contains(
                                    messageId,
                                  ),
                                  onChanged: _deletingMessages
                                      ? null
                                      : (selected) => setState(() {
                                          if (selected == true) {
                                            _selectedMessageIds.add(messageId);
                                          } else {
                                            _selectedMessageIds.remove(
                                              messageId,
                                            );
                                          }
                                        }),
                                ),
                                Expanded(child: bubble),
                              ],
                            );
                          }

                          if (downloadKey == null) {
                            return selectableBubble(buildBubble(null));
                          }
                          return ValueListenableBuilder<int?>(
                            valueListenable: DirectAttachmentDownloads.instance
                                .progressListenable(downloadKey),
                            builder: (context, activeProgress, _) =>
                                selectableBubble(buildBubble(activeProgress)),
                          );
                        },
                      ),
                  ],
                ),
        ),
        if (_selectionMode)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Row(
              children: [
                TextButton(
                  onPressed: _deletingMessages
                      ? null
                      : () => setState(() {
                          if (_selectedMessageIds.length ==
                              visibleMessages.length) {
                            _selectedMessageIds.clear();
                          } else {
                            _selectedMessageIds
                              ..clear()
                              ..addAll(
                                visibleMessages.map(
                                  (message) => message['id'].toString(),
                                ),
                              );
                          }
                        }),
                  child: Text(
                    _selectedMessageIds.length == visibleMessages.length
                        ? '取消全选'
                        : '全选',
                  ),
                ),
                Text('已选 ${_selectedMessageIds.length} 条'),
                const Spacer(),
                TextButton(
                  onPressed: _deletingMessages
                      ? null
                      : () => setState(() {
                          _selectionMode = false;
                          _selectedMessageIds.clear();
                        }),
                  child: const Text('取消'),
                ),
                FilledButton.icon(
                  onPressed: _selectedMessageIds.isEmpty || _deletingMessages
                      ? null
                      : _deleteSelectedMessages,
                  icon: _deletingMessages
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.delete_outline),
                  label: const Text('删除'),
                ),
              ],
            ),
          )
        else
          Align(
            alignment: Alignment.centerRight,
            child: IconButton(
              tooltip: '选择并删除聊天记录',
              onPressed: () => setState(() => _selectionMode = true),
              icon: const Icon(Icons.checklist),
            ),
          ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _text,
                        onChanged: (_) => setState(() {}),
                        minLines: 1,
                        maxLines: 5,
                        keyboardType: TextInputType.multiline,
                        textInputAction: TextInputAction.send,
                        onSubmitted: (_) => _send(),
                        scrollPhysics: const ClampingScrollPhysics(),
                        decoration: const InputDecoration(
                          hintText: '发给管理端手机',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                    if (_text.text.trim().isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(left: 8),
                        child: FilledButton(
                          onPressed: _send,
                          child: const Text('发送'),
                        ),
                      ),
                  ],
                ),
                Row(
                  children: [
                    IconButton(
                      tooltip: '发送图片或视频',
                      onPressed: () => _pickAttachment(FileType.media),
                      constraints: const BoxConstraints.tightFor(
                        width: 52,
                        height: 52,
                      ),
                      padding: EdgeInsets.zero,
                      icon: const Icon(Icons.image),
                    ),
                    IconButton(
                      tooltip: '发送文件',
                      onPressed: () => _pickAttachment(FileType.any),
                      constraints: const BoxConstraints.tightFor(
                        width: 52,
                        height: 52,
                      ),
                      padding: EdgeInsets.zero,
                      icon: const Icon(Icons.attach_file),
                    ),
                    IconButton(
                      tooltip: _recording ? '停止并发送语音' : '录制语音',
                      onPressed: _toggleRecording,
                      constraints: const BoxConstraints.tightFor(
                        width: 52,
                        height: 52,
                      ),
                      padding: EdgeInsets.zero,
                      icon: Icon(_recording ? Icons.stop_circle : Icons.mic),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class DirectMessageBubble extends StatelessWidget {
  const DirectMessageBubble({
    required this.message,
    required this.outgoing,
    this.avatarData,
    this.onRetry,
    this.onCancel,
    this.onCancelDownload,
    this.downloadProgress,
    this.downloading = false,
    this.showTimestamp = true,
    required this.onOpenAttachment,
    super.key,
  });

  final Map<String, dynamic> message;
  final bool outgoing;
  final String? avatarData;
  final VoidCallback? onRetry;
  final VoidCallback? onCancel;
  final VoidCallback? onCancelDownload;
  final int? downloadProgress;
  final bool downloading;
  final bool showTimestamp;
  final VoidCallback onOpenAttachment;

  Widget _previewPlaceholder(bool isVideo) => ColoredBox(
    color: Colors.black12,
    child: Center(
      child: Icon(
        isVideo ? Icons.video_file_outlined : Icons.image_outlined,
        size: 48,
        color: Colors.black45,
      ),
    ),
  );

  Widget _mediaPreview(BuildContext context, String mimeType) {
    final isVideo = mimeType.startsWith('video/');
    final previewData = message['preview_data'];
    final mediaPath =
        directOutgoingVideoPath(message) ??
        message['media_path'] as String? ??
        (message['encrypted_local'] == true
            ? null
            : message['file_path'] as String?);
    final locallyAvailable =
        mediaPath != null ||
        message['encrypted_local'] == true ||
        message['media_data'] is String ||
        previewData is String;
    final Widget image;
    if (isVideo && previewData is String) {
      image = Image(
        image: _directMemoryImage(previewData),
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => _previewPlaceholder(isVideo),
      );
    } else if (!isVideo && message['media_data'] is String) {
      image = Image(
        image: _directMemoryImage(message['media_data'] as String),
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => _previewPlaceholder(isVideo),
      );
    } else if (isVideo && mediaPath != null) {
      image = FutureBuilder<Uint8List?>(
        future: _createVideoThumbnail(mediaPath),
        builder: (context, snapshot) {
          final bytes = snapshot.data;
          if (bytes == null || bytes.isEmpty) {
            return _previewPlaceholder(isVideo);
          }
          return Image(
            image: _directVideoMemoryImage(mediaPath, bytes),
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => _previewPlaceholder(isVideo),
          );
        },
      );
    } else if (mediaPath != null) {
      image = Image.file(
        File(mediaPath),
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => _previewPlaceholder(isVideo),
      );
    } else if (previewData is String) {
      image = Image(
        image: _directMemoryImage(previewData),
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => _previewPlaceholder(isVideo),
      );
    } else {
      image = _previewPlaceholder(isVideo);
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(9),
      child: SizedBox(
        width: 280,
        height: 170,
        child: Stack(
          fit: StackFit.expand,
          children: [
            image,
            if (isVideo && locallyAvailable)
              const Center(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Color(0x99000000),
                    shape: BoxShape.circle,
                  ),
                  child: Padding(
                    padding: EdgeInsets.all(12),
                    child: Icon(
                      Icons.play_arrow,
                      color: Colors.white,
                      size: 32,
                    ),
                  ),
                ),
              ),
            if (!locallyAvailable || downloading)
              Center(
                child: Material(
                  color: Colors.black54,
                  shape: const CircleBorder(),
                  child: SizedBox(
                    width: 54,
                    height: 54,
                    child: downloading
                        ? Stack(
                            alignment: Alignment.center,
                            children: [
                              CircularProgressIndicator(
                                value: downloadProgress == null
                                    ? null
                                    : downloadProgress! / 100,
                                color: Colors.white,
                              ),
                              if (downloadProgress != null)
                                Text(
                                  '$downloadProgress%',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 11,
                                  ),
                                ),
                            ],
                          )
                        : IconButton(
                            tooltip: '下载并打开',
                            onPressed: onOpenAttachment,
                            icon: const Icon(
                              Icons.download,
                              color: Colors.white,
                            ),
                          ),
                  ),
                ),
              ),
            if (downloading && onCancelDownload != null)
              Positioned(
                top: 6,
                right: 6,
                child: Material(
                  color: Colors.black54,
                  shape: const CircleBorder(),
                  child: IconButton(
                    tooltip: '取消下载',
                    onPressed: onCancelDownload,
                    visualDensity: VisualDensity.compact,
                    iconSize: 18,
                    color: Colors.white,
                    icon: const Icon(Icons.close),
                  ),
                ),
              ),
            if (isVideo)
              Positioned(
                left: 8,
                right: 8,
                bottom: 6,
                child: Text(
                  '${message['file_name'] ?? '视频'} · ${formatDirectFileSize(message['media_size'] as int? ?? 0)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    shadows: [Shadow(blurRadius: 4, color: Colors.black)],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _audioPlaybackButton(String messageId) =>
      ValueListenableBuilder<String?>(
        valueListenable: directAudioPlayback.activeMessageId,
        builder: (context, activeMessageId, _) => ValueListenableBuilder<bool>(
          valueListenable: directAudioPlayback.isPlaying,
          builder: (context, isPlaying, _) {
            final playing = activeMessageId == messageId && isPlaying;
            return IconButton(
              tooltip: playing ? '暂停语音' : '播放语音',
              onPressed: downloading ? null : onOpenAttachment,
              icon: Icon(
                playing ? Icons.pause_circle_filled : Icons.play_circle_fill,
              ),
            );
          },
        ),
      );

  @override
  Widget build(BuildContext context) {
    final mimeType = message['mime_type'] as String? ?? '';
    final isVisualMedia =
        mimeType.startsWith('image/') || mimeType.startsWith('video/');
    final hasAttachment =
        message['file_path'] is String ||
        message['media_id'] != null ||
        message['media_data'] is String ||
        message['file_name'] is String;
    final createdAt = showTimestamp
        ? DateTime.parse(message['created_at'].toString()).toLocal()
        : null;
    final timestamp = createdAt == null
        ? null
        : '${createdAt.year}-${createdAt.month.toString().padLeft(2, '0')}-${createdAt.day.toString().padLeft(2, '0')} '
              '${createdAt.hour.toString().padLeft(2, '0')}:${createdAt.minute.toString().padLeft(2, '0')}';
    return Align(
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (timestamp != null)
            Padding(
              padding: const EdgeInsets.only(top: 5, bottom: 2),
              child: Text(
                timestamp,
                key: ValueKey('message-timestamp-${message['id']}'),
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ),
          Align(
            alignment: outgoing ? Alignment.centerRight : Alignment.centerLeft,
            child: Row(
              mainAxisSize: MainAxisSize.max,
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: outgoing
                  ? MainAxisAlignment.end
                  : MainAxisAlignment.start,
              children: [
                if (!outgoing) ...[
                  _MessageAvatar(
                    data: avatarData,
                    onTap: avatarData == null
                        ? null
                        : () => showDirectAvatarPreview(context, avatarData!),
                  ),
                  const SizedBox(width: 6),
                ],
                Flexible(
                  child: Card(
                    margin: const EdgeInsets.symmetric(
                      vertical: 2,
                      horizontal: 2,
                    ),
                    color: outgoing
                        ? Theme.of(context).colorScheme.primaryContainer
                        : Theme.of(context).colorScheme.secondaryContainer,
                    shape: RoundedRectangleBorder(
                      side: BorderSide(
                        color: outgoing
                            ? Theme.of(context).colorScheme.primary
                            : Theme.of(context).colorScheme.secondary,
                        width: 1.2,
                      ),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(10),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (message['media_id'] != null ||
                              message['file_path'] is String ||
                              message['media_data'] is String) ...[
                            if (isVisualMedia)
                              GestureDetector(
                                onTap: downloading ? null : onOpenAttachment,
                                child: _mediaPreview(context, mimeType),
                              )
                            else
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    mimeType.startsWith('audio/')
                                        ? Icons.audio_file
                                        : Icons.insert_drive_file,
                                  ),
                                  if (mimeType.startsWith('audio/')) ...[
                                    _audioPlaybackButton(
                                      message['id'].toString(),
                                    ),
                                  ],
                                  const SizedBox(width: 8),
                                  Flexible(
                                    child: InkWell(
                                      onTap: downloading
                                          ? null
                                          : onOpenAttachment,
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            message['file_name']?.toString() ??
                                                '附件',
                                            overflow: TextOverflow.ellipsis,
                                            maxLines: 2,
                                            style: const TextStyle(
                                              fontSize: 12,
                                            ),
                                          ),
                                          Text(
                                            formatDirectFileSize(
                                              message['media_size'] as int? ??
                                                  0,
                                            ),
                                            style: Theme.of(context)
                                                .textTheme
                                                .labelSmall,
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                  if (downloading) ...[
                                    const SizedBox(width: 8),
                                    Text('${downloadProgress ?? 0}%'),
                                    IconButton(
                                      tooltip: '取消下载',
                                      onPressed: onCancelDownload,
                                      icon: const Icon(Icons.close),
                                    ),
                                  ],
                                ],
                              ),
                          ],
                          if ((message['body']?.toString() ?? '').isNotEmpty)
                            ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 280),
                              child: Text(message['body']?.toString() ?? ''),
                            ),
                          if (outgoing &&
                              hasAttachment &&
                              message['pending'] == true &&
                              (message['delivery_state'] == 'preparing' ||
                                  message['delivery_state'] == 'queued' ||
                                  message['delivery_state'] ==
                                      'uploading')) ...[
                            const SizedBox(height: 8),
                            _AttachmentUploadProgress(
                              progress: message['delivery_state'] == 'preparing'
                                  ? message['prepare_progress'] as int? ?? 0
                                  : message['upload_progress'] as int? ?? 0,
                              label: switch (message['delivery_state']) {
                                'preparing' => '准备中',
                                'queued' => '排队中',
                                _ => '上传中',
                              },
                            ),
                          ],
                          if (outgoing &&
                              (message['delivery_state'] == 'failed' ||
                                  (hasAttachment &&
                                      (message['pending'] == true ||
                                          message['sent'] == true)))) ...[
                            const SizedBox(height: 4),
                            _MessageDeliveryStatus(
                              message: message,
                              onRetry: onRetry,
                              onCancel: onCancel,
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
                if (outgoing) ...[
                  const SizedBox(width: 6),
                  _MessageAvatar(
                    data: avatarData,
                    onTap: avatarData == null
                        ? null
                        : () => showDirectAvatarPreview(context, avatarData!),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 5),
        ],
      ),
    );
  }
}

class _AttachmentUploadProgress extends StatelessWidget {
  const _AttachmentUploadProgress({required this.progress, this.label = '上传中'});

  final int progress;
  final String label;

  @override
  Widget build(BuildContext context) {
    final value = progress.clamp(0, 100);
    return SizedBox(
      width: 280,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('$label $value%', style: Theme.of(context).textTheme.labelSmall),
          const SizedBox(height: 3),
          LinearProgressIndicator(value: value / 100),
        ],
      ),
    );
  }
}

class _MessageAvatar extends StatelessWidget {
  const _MessageAvatar({required this.data, this.onTap});

  final String? data;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    customBorder: const CircleBorder(),
    child: CircleAvatar(
      radius: 17,
      backgroundImage: data == null ? null : _directMemoryImage(data!),
      child: data == null
          ? Image.asset(
              'assets/app_icon.png',
              width: 26,
              height: 26,
              fit: BoxFit.cover,
            )
          : null,
    ),
  );
}

class _MessageDeliveryStatus extends StatelessWidget {
  const _MessageDeliveryStatus({
    required this.message,
    this.onRetry,
    this.onCancel,
  });

  final Map<String, dynamic> message;
  final VoidCallback? onRetry;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    if (message['delivery_state'] == 'failed') {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (onCancel != null)
            IconButton(
              tooltip: '删除待发送附件',
              onPressed: onCancel,
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints.tightFor(width: 28, height: 28),
              icon: const Icon(Icons.close, size: 16, color: Colors.red),
            )
          else
            const Icon(Icons.close, size: 16, color: Colors.red),
          if (onRetry != null)
            TextButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh, size: 14),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                minimumSize: const Size(32, 24),
              ),
              label: const Text('重发', style: TextStyle(fontSize: 11)),
            ),
        ],
      );
    }
    if (onCancel != null) {
      return TextButton.icon(
        onPressed: onCancel,
        icon: const Icon(Icons.close, size: 14),
        label: const Text('取消', style: TextStyle(fontSize: 11)),
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          minimumSize: const Size(48, 36),
          tapTargetSize: MaterialTapTargetSize.padded,
        ),
      );
    }
    return const SizedBox.shrink();
  }
}

Future<void> showDirectAvatarPreview(
  BuildContext context,
  String encoded,
) async {
  await showDialog<void>(
    context: context,
    builder: (context) => Dialog(
      child: InteractiveViewer(
        child: Image.memory(base64Decode(encoded), fit: BoxFit.contain),
      ),
    ),
  );
}

String formatDirectFileSize(int bytes) {
  if (bytes < 0) return '大小未知';
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB', 'TB', 'PB'];
  var size = bytes.toDouble();
  var unit = -1;
  do {
    size /= 1024;
    unit++;
  } while (size >= 1024 && unit < units.length - 1);
  final formatted = size >= 10 || size == size.roundToDouble()
      ? size.toStringAsFixed(0)
      : size.toStringAsFixed(1);
  return '$formatted ${units[unit]}';
}
