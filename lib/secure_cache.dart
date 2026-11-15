import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path_provider/path_provider.dart';

Future<void> purgeClientChatFiles({
  required Iterable<Map<String, dynamic>> messages,
  required Directory supportDirectory,
  required Directory temporaryDirectory,
}) async {
  final pendingRoot = Directory(
    '${supportDirectory.path}${Platform.pathSeparator}pending-attachments',
  );
  for (final message in messages) {
    final messageId = message['id']?.toString();
    if (messageId == null ||
        !RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(messageId)) {
      continue;
    }

    final pendingPath =
        '${pendingRoot.path}${Platform.pathSeparator}$messageId';
    final pendingDirectory = Directory(pendingPath);
    if (await pendingDirectory.exists()) {
      await pendingDirectory.delete(recursive: true);
    }

    final mediaId = message['media_id']?.toString();
    final allowedPrefixes = <String>{'${messageId}_'};
    if (mediaId != null &&
        RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(mediaId)) {
      allowedPrefixes.add('${mediaId}_');
    }
    for (final field in ['media_path', 'file_path']) {
      final path = message[field];
      if (path is! String || path.isEmpty) continue;
      final file = File(path);
      if (file.parent.absolute.path != temporaryDirectory.absolute.path ||
          !allowedPrefixes.any(
            (prefix) => file.uri.pathSegments.last.startsWith(prefix),
          )) {
        continue;
      }
      if (await file.exists()) await file.delete();
    }
  }
}

abstract interface class InviteHostStore {
  Object? value(String key);
  List<Map<String, dynamic>> mapList(String key);
  Future<void> putValue(String key, Object value);
  Future<void> putMapList(String key, List<Map<String, dynamic>> value);
}

class SecureCache implements InviteHostStore {
  SecureCache._(this._box);

  static const _keyName = 'consent_chat_cache_key';
  final Box<dynamic> _box;
  final Set<String> _purgedClientIds = {};

  @override
  Object? value(String key) => _box.get('app:$key');

  String? text(String key) => value(key) as String?;

  @override
  Future<void> putValue(String key, Object value) {
    final clientId = _clientIdForMessagesKey(key);
    if (clientId != null && _purgedClientIds.contains(clientId)) {
      return Future<void>.value();
    }
    return _box.put('app:$key', value);
  }

  Future<void> putText(String key, String value) => putValue(key, value);

  Future<void> deleteValue(String key) => _box.delete('app:$key');

  @override
  List<Map<String, dynamic>> mapList(String key) {
    final stored = value(key);
    if (stored is! List) return [];
    return stored
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
  }

  @override
  Future<void> putMapList(String key, List<Map<String, dynamic>> value) =>
      putValue(key, value);

  static String? _clientIdForMessagesKey(String key) {
    const prefix = 'direct-messages:';
    if (!key.startsWith(prefix)) return null;
    return key.substring(prefix.length);
  }

  Future<void> purgeClientChatData(String clientId) async {
    if (clientId.isNotEmpty) _purgedClientIds.add(clientId);
    final messageCacheKey =
        clientId.isEmpty ? null : 'direct-messages:$clientId';
    final messages = messageCacheKey == null
        ? <Map<String, dynamic>>[]
        : mapList(messageCacheKey);
    await _box.flush();

    final keysToDelete = _box.keys.whereType<String>().where((key) {
      return (messageCacheKey != null && key == 'app:$messageCacheKey') ||
          (clientId.isNotEmpty && key == 'app:direct-avatar:$clientId') ||
          (clientId.isNotEmpty && key == 'app:direct-token:$clientId') ||
          key == 'app:direct-invite-code' ||
          key == 'app:direct-client-id' ||
          key == 'app:direct-client-name' ||
          key == 'app:direct-client-device-name' ||
          (clientId.isNotEmpty && key.startsWith('outbox:$clientId:')) ||
          (clientId.isNotEmpty && key.startsWith('messages:$clientId:')) ||
          (clientId.isNotEmpty && key.startsWith('friends:$clientId')) ||
          (clientId.isNotEmpty && key.startsWith('conversation:$clientId:'));
    }).toList();
    await _box.deleteAll(keysToDelete);

    await purgeClientChatFiles(
      messages: messages,
      supportDirectory: await getApplicationSupportDirectory(),
      temporaryDirectory: await getTemporaryDirectory(),
    );
  }

  static Future<SecureCache> open() async {
    await Hive.initFlutter();
    const storage = FlutterSecureStorage();
    var encodedKey = await storage.read(key: _keyName);
    if (encodedKey == null) {
      final random = Random.secure();
      final key = List<int>.generate(32, (_) => random.nextInt(256));
      encodedKey = base64UrlEncode(key);
      await storage.write(key: _keyName, value: encodedKey);
    }

    final key = base64Url.decode(encodedKey);
    if (key.length != 32) {
      throw StateError('The encrypted cache key is invalid.');
    }
    final box = await Hive.openBox<dynamic>(
      'private_cache',
      encryptionCipher: HiveAesCipher(key),
    );
    return SecureCache._(box);
  }

  List<Map<String, dynamic>> messages(String userId, String conversationId) {
    final value = _box.get('messages:$userId:$conversationId');
    if (value is! List) return [];
    return value
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
  }

  Future<void> saveMessages(
    String userId,
    String conversationId,
    List<Map<String, dynamic>> messages,
  ) {
    return _box.put('messages:$userId:$conversationId', messages);
  }

  List<Map<String, dynamic>> friends(String userId) {
    final value = _box.get('friends:$userId');
    if (value is! List) return [];
    return value
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
  }

  Future<void> saveFriends(String userId, List<Map<String, dynamic>> friends) {
    return _box.put('friends:$userId', friends);
  }

  String? conversationId(String userId, String peerId) {
    return _box.get('conversation:$userId:$peerId') as String?;
  }

  Future<void> saveConversation(
    String userId,
    String peerId,
    String conversationId,
  ) {
    return _box.put('conversation:$userId:$peerId', conversationId);
  }

  Map<String, dynamic>? pending(String userId, String id) {
    final value = _box.get('outbox:$userId:$id');
    if (value is! Map) return null;
    return Map<String, dynamic>.from(value);
  }

  List<Map<String, dynamic>> pendingMessages(
    String userId,
    String conversationId,
  ) {
    return _box.keys
        .whereType<String>()
        .where((key) => key.startsWith('outbox:$userId:'))
        .map((key) => _box.get(key))
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .where((item) => item['conversation_id'] == conversationId)
        .toList();
  }

  Iterable<String> pendingKeys(String userId) => _box.keys
      .whereType<String>()
      .where((key) => key.startsWith('outbox:$userId:'));

  Future<void> queue(String userId, Map<String, dynamic> message) {
    return _box.put('outbox:$userId:${message['id']}', message);
  }

  Future<void> removePending(String userId, String id) =>
      _box.delete('outbox:$userId:$id');
}
