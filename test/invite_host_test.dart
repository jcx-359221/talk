import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:consent_chat/direct_chat.dart';
import 'package:consent_chat/invite_host.dart';
import 'package:consent_chat/message_crypto.dart';
import 'package:consent_chat/remote_admin.dart';
import 'package:consent_chat/server_tls.dart';
import 'package:consent_chat/secure_cache.dart';

class _MemoryStore implements InviteHostStore {
  final Map<String, Object> values = {};

  @override
  Object? value(String key) => values[key];

  @override
  List<Map<String, dynamic>> mapList(String key) =>
      (values[key] as List<Map<String, dynamic>>?) ?? [];

  @override
  Future<void> putValue(String key, Object value) async {
    values[key] = value;
  }

  @override
  Future<void> putMapList(String key, List<Map<String, dynamic>> value) async {
    values[key] = value.map((item) => Map<String, dynamic>.from(item)).toList();
  }
}

void main() {
  test('remote admin sorting handles pinyin initials and direction', () {
    final li = <String, dynamic>{
      'client_id': 'li',
      'client_name': '李四',
      'created_at': '2026-02-01T00:00:00Z',
      'last_chat_at': '2026-02-03T00:00:00Z',
    };
    final zhang = <String, dynamic>{
      'client_id': 'zhang',
      'client_name': '张三',
      'created_at': '2026-01-01T00:00:00Z',
      'last_chat_at': '2026-02-02T00:00:00Z',
    };
    expect(
      compareRemoteAdminRecords(
        li,
        zhang,
        RemoteAdminSortField.nameInitial,
        ascending: true,
      ),
      lessThan(0),
    );
    expect(
      compareRemoteAdminRecords(
        li,
        zhang,
        RemoteAdminSortField.nameInitial,
        ascending: false,
      ),
      greaterThan(0),
    );
    expect(
      compareRemoteAdminRecords(
        li,
        zhang,
        RemoteAdminSortField.recentChat,
        ascending: true,
      ),
      greaterThan(0),
    );
  });

  group('normalizeIp', () {
    test('canonicalizes IP-mapped IPv4 addresses', () {
      expect(normalizeIp('::ffff:192.0.2.10'), '192.0.2.10');
    });

    test('canonicalizes IPv6 addresses', () {
      expect(normalizeIp('2001:0db8:0:0::1'), '2001:db8::1');
    });

    test('rejects invalid addresses', () {
      expect(() => normalizeIp('example.invalid'), throwsFormatException);
    });
  });

  test('invite manager tracks and revokes IP allowlist entries', () async {
    final controller = InviteHostController(_MemoryStore());
    addTearDown(controller.dispose);

    await controller.bindIp('::ffff:192.0.2.10');
    expect(controller.allowedIps, contains('192.0.2.10'));

    await controller.unbindIp('192.0.2.10');
    expect(controller.allowedIps, isEmpty);
  });

  test('default server bind accepts IPv6 and IPv4 connections', () async {
    final store = _MemoryStore();
    final identity = await loadOrCreateServerTlsIdentity(store);
    final controller = InviteHostController(store);
    final portProbe = await ServerSocket.bind(InternetAddress.loopbackIPv6, 0);
    final port = portProbe.port;
    await portProbe.close();
    await controller.start(
      port: port,
      code: 'admin-password-123',
      certificate: identity.certificate,
      privateKey: identity.privateKey,
      certificateFingerprint: identity.fingerprint,
    );
    addTearDown(() async {
      await controller.stop();
      controller.dispose();
    });

    final client = createPinnedHttpClient(identity.fingerprint);
    addTearDown(() => client.close(force: true));
    for (final host in ['[::1]:$port', '127.0.0.1:$port']) {
      final request = await client.getUrl(Uri.https(host, '/health'));
      final response = await request.close();
      expect(response.statusCode, HttpStatus.ok);
      expect(await response.transform(utf8.decoder).join(), '{"ok":true}');
    }
  });

  test(
    'video call ICE configuration validates and persists TURN settings',
    () async {
      final store = _MemoryStore();
      final controller = InviteHostController(store);
      addTearDown(controller.dispose);

      await controller.saveVideoCallIceServers(
        stunUrl: 'stun:stun.example.com:3478',
        turnUrl: 'turn:turn.example.com:3478',
        turnUsername: 'turn-user',
        turnPassword: 'turn-secret',
      );
      expect(controller.videoCallIceServers, [
        {
          'urls': ['stun:stun.example.com:3478'],
        },
        {
          'urls': ['turn:turn.example.com:3478'],
          'username': 'turn-user',
          'credential': 'turn-secret',
        },
      ]);

      await expectLater(
        controller.saveVideoCallIceServers(
          stunUrl: 'https://stun.example.com',
          turnUrl: '',
          turnUsername: '',
          turnPassword: '',
        ),
        throwsArgumentError,
      );
    },
  );

  test(
    'server-sent media keeps its local path private and persistent',
    () async {
      final store = _MemoryStore();
      store.values['direct-host-messages'] = <Map<String, dynamic>>[
        {
          'id': 'message-one',
          'client_id': 'client-one',
          'sender': 'server',
          'body': '',
          'created_at': DateTime.now().toUtc().toIso8601String(),
          'media_id': 'media-one',
          'file_name': 'video.mp4',
          'mime_type': 'video/mp4',
          'media_size': 10,
        },
      ];
      final firstController = InviteHostController(store);
      await firstController.rememberLocalMediaPath(
        'client-one',
        'message-one',
        r'D:\talk\media\video.mp4',
      );
      firstController.dispose();

      final identity = await loadOrCreateServerTlsIdentity(store);
      final controller = InviteHostController(store);
      final portProbe = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final port = portProbe.port;
      await portProbe.close();
      await controller.start(
        port: port,
        code: 'admin-password-123',
        certificate: identity.certificate,
        privateKey: identity.privateKey,
        certificateFingerprint: identity.fingerprint,
        bindAddress: InternetAddress.loopbackIPv4,
      );
      addTearDown(() async {
        await controller.stop();
        controller.dispose();
      });

      expect(
        controller.localMediaPathForMessage('client-one', 'message-one'),
        r'D:\talk\media\video.mp4',
      );
      final visibleMessage = controller.messagesFor('client-one').single;
      expect(visibleMessage.containsKey('media_path'), isFalse);
    },
  );

  test(
    'pending host attachments are persisted and their progress is updated',
    () async {
      final store = _MemoryStore();
      final controller = InviteHostController(store);
      addTearDown(controller.dispose);
      final message = <String, dynamic>{
        'id': 'pending-attachment',
        'client_id': 'client-1',
        'sender': 'server',
        'body': '',
        'created_at': DateTime.now().toUtc().toIso8601String(),
        'file_name': 'video.mp4',
        'mime_type': 'video/mp4',
        'media_size': 100,
        'file_path': 'pending/video.mp4',
        'pending': true,
        'delivery_state': 'queued',
        'upload_progress': 0,
      };

      await controller.savePendingMediaMessage(message);
      await controller.updatePendingMediaMessage(
        'client-1',
        'pending-attachment',
        {'delivery_state': 'uploading', 'upload_progress': 42},
        persist: false,
      );

      expect(controller.messagesFor('client-1').single['upload_progress'], 42);
      expect(
        store.mapList('direct-host-messages').single['delivery_state'],
        'queued',
      );
      await controller.updatePendingMediaMessage(
        'client-1',
        'pending-attachment',
        {'upload_progress': 42},
      );
      expect(
        store.mapList('direct-host-messages').single['upload_progress'],
        42,
      );
    },
  );

  test('server TLS identity is generated once and securely reusable', () async {
    final store = _MemoryStore();
    final first = await loadOrCreateServerTlsIdentity(store);
    final second = await loadOrCreateServerTlsIdentity(store);

    expect(first.fingerprint, hasLength(64));
    expect(second.fingerprint, first.fingerprint);
    expect(utf8.decode(first.certificate), contains('BEGIN CERTIFICATE'));
    expect(utf8.decode(first.privateKey), contains('BEGIN PRIVATE KEY'));
    expect(formatCertificateFingerprint(first.fingerprint), contains(':'));
  });

  test('server startup removes legacy identity records', () async {
    final store = _MemoryStore()
      ..values['direct-host-clients'] = <Map<String, dynamic>>[
        {
          'client_id': 'legacy-phone',
          'token': 'legacy-token',
          'identity_number': 'legacy-private-data',
        },
      ]
      ..values['direct-host-identity-required-invite-codes'] = <String>[
        'legacy-code',
      ];
    final identity = await loadOrCreateServerTlsIdentity(store);
    final controller = InviteHostController(store);
    final portProbe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = portProbe.port;
    await portProbe.close();
    await controller.start(
      port: port,
      code: 'admin-password-123',
      certificate: identity.certificate,
      privateKey: identity.privateKey,
      certificateFingerprint: identity.fingerprint,
      bindAddress: InternetAddress.loopbackIPv4,
    );
    addTearDown(() async {
      await controller.stop();
      controller.dispose();
    });

    expect(
      controller.registeredClients.single.containsKey('identity_number'),
      isFalse,
    );
    expect(
      store
          .mapList('direct-host-clients')
          .single
          .containsKey('identity_number'),
      isFalse,
    );
    expect(store.value('direct-host-identity-required-invite-codes'), isEmpty);
  });

  test('connection failure message does not expose endpoint details', () {
    expect(
      serverConnectionErrorMessage(const SocketException('connection refused')),
      '服务器未启动，请联系管理员启动后重试。',
    );
    expect(
      serverConnectionErrorMessage(const HttpException('TLS detail')),
      '无法连接服务器，请稍后重试。',
    );
  });

  test('client chat history is hidden after one hour, not thirty minutes', () {
    final now = DateTime.utc(2026, 11, 14, 10);
    final message = <String, dynamic>{
      'id': 'recent-message',
      'created_at': now.subtract(const Duration(minutes: 30)).toIso8601String(),
    };
    expect(isDirectMessageVisible(message, now: now), isTrue);
    message['created_at'] = now
        .subtract(const Duration(hours: 1))
        .toIso8601String();
    expect(isDirectMessageVisible(message, now: now), isFalse);
  });

  test('client invite codes bind uniquely and can be revoked', () async {
    final store = _MemoryStore();
    final identity = await loadOrCreateServerTlsIdentity(store);
    final mediaDirectory = Directory('test/.attachment-test-media');
    final controller = InviteHostController(
      store,
      mediaDirectory: mediaDirectory,
    );
    addTearDown(() async {
      if (await mediaDirectory.exists()) {
        await mediaDirectory.delete(recursive: true);
      }
    });
    final portProbe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = portProbe.port;
    await portProbe.close();
    var activePort = port;
    await controller.start(
      port: port,
      code: 'admin-password-123',
      certificate: identity.certificate,
      privateKey: identity.privateKey,
      certificateFingerprint: identity.fingerprint,
      bindAddress: InternetAddress.loopbackIPv4,
    );
    addTearDown(() async {
      await controller.stop();
      controller.dispose();
    });

    final client = createPinnedHttpClient(identity.fingerprint);
    addTearDown(() => client.close(force: true));
    var remoteAdmin = RemoteManagementApi(
      Uri.https('127.0.0.1:$port'),
      'admin-password-123',
      certificateFingerprint: identity.fingerprint,
    );

    Future<Map<String, dynamic>> validate(
      String clientId,
      String code, {
      String token = '',
      String? deviceIdentity,
      String? clientName,
    }) async {
      final request = await client.postUrl(
        Uri.https('127.0.0.1:$activePort', '/validate'),
      );
      request.headers.contentType = ContentType.json;
      final body = jsonEncode({
        'code': code,
        'client_id': clientId,
        'client_name': clientName ?? clientId,
        if (deviceIdentity != null) 'device_identity': deviceIdentity,
        'identity_number': 'legacy-field-is-ignored',
        'token': token,
      });
      request.contentLength = utf8.encode(body).length;
      request.write(body);
      final response = await request.close();
      return Map<String, dynamic>.from(
        jsonDecode(await utf8.decoder.bind(response).join()) as Map,
      );
    }

    final first = await validate('phone-one', 'client-code-one');
    expect(first['valid'], isFalse);
    expect(first['error'], 'invalid_invite_code');

    await remoteAdmin.addInviteCodes(
      'client-code-one\nclient-code-two\nclient-code-three',
    );
    final adminState = await remoteAdmin.state();
    expect(
      (adminState['invite_codes'] as List)
          .whereType<Map>()
          .map((invite) => invite['code'])
          .toSet(),
      containsAll(['client-code-one', 'client-code-two', 'client-code-three']),
    );
    expect(
      (adminState['invite_codes'] as List).whereType<Map>().every(
        (invite) => invite['created_at'] is String,
      ),
      isTrue,
    );
    var registrationWasPublished = false;
    void observeRegisteredClient() {
      if (controller.registeredClients.any(
        (client) => client['client_id'] == 'phone-one',
      )) {
        registrationWasPublished = true;
      }
    }

    controller.addListener(observeRegisteredClient);
    final registered = await validate(
      'phone-one',
      'client-code-one',
      deviceIdentity: 'stable-device-hash-one',
    );
    controller.removeListener(observeRegisteredClient);
    expect(registered['valid'], isTrue);
    expect(registered['client_id'], 'phone-one');
    expect(registrationWasPublished, isTrue);
    final registeredPhone = controller.registeredClients.singleWhere(
      (c) => c['client_id'] == 'phone-one',
    );
    expect(registeredPhone['client_name'], 'phone-one');
    expect(registeredPhone['device_name'], 'phone-one');
    expect(registeredPhone['ip'], isA<String>());
    expect(registeredPhone['created_at'], isA<String>());
    expect(registeredPhone['last_seen'], isA<String>());
    final clientToken = registered['token'] as String;
    final renamed = await validate(
      'phone-one',
      'client-code-one',
      token: clientToken,
      clientName: '新客户端名称',
    );
    expect(renamed['valid'], isTrue);
    expect(
      controller.registeredClients.singleWhere(
        (client) => client['client_id'] == 'phone-one',
      )['client_name'],
      '新客户端名称',
    );
    expect(
      controller.registeredClients.single.containsKey('identity_number'),
      isFalse,
    );
    expect(
      store.mapList('direct-host-clients').single['device_identity'],
      'stable-device-hash-one',
    );
    expect(
      controller.registeredClients.single.containsKey('device_identity'),
      isFalse,
    );
    expect(
      controller.deviceIdentityForClient('phone-one'),
      'stable-device-hash-one',
    );
    expect(controller.registeredClients.single.containsKey('token'), isFalse);
    final clientApi = DirectChatApi(
      Uri.https('127.0.0.1:$port'),
      messageCode: 'client-code-one',
      certificateFingerprint: identity.fingerprint,
    );
    final callResponse = await remoteAdmin.startVideoCall('phone-one');
    final callId = callResponse['call_id'] as String;
    expect(callResponse['ice_servers'], isA<List>());
    final incomingCall = await clientApi.pollVideoCallSignals(
      clientId: 'phone-one',
      token: clientToken,
    );
    expect(incomingCall.single['type'], 'incoming');
    expect(incomingCall.single['call_id'], callId);
    await clientApi.sendVideoCallSignal(
      clientId: 'phone-one',
      token: clientToken,
      callId: callId,
      type: 'accept',
    );
    expect(
      (await remoteAdmin.pollVideoCallSignals('phone-one')).single['type'],
      'accept',
    );
    await remoteAdmin.sendVideoCallSignal(
      clientId: 'phone-one',
      callId: callId,
      type: 'offer',
      sdp: 'server-offer-sdp',
    );
    final offer = await clientApi.pollVideoCallSignals(
      clientId: 'phone-one',
      token: clientToken,
    );
    expect(offer.single['sdp'], 'server-offer-sdp');
    await clientApi.sendVideoCallSignal(
      clientId: 'phone-one',
      token: clientToken,
      callId: callId,
      type: 'answer',
      sdp: 'client-answer-sdp',
    );
    expect(
      (await remoteAdmin.pollVideoCallSignals('phone-one')).single['sdp'],
      'client-answer-sdp',
    );
    await remoteAdmin.sendVideoCallSignal(
      clientId: 'phone-one',
      callId: callId,
      type: 'hangup',
    );
    expect(
      (await clientApi.pollVideoCallSignals(
        clientId: 'phone-one',
        token: clientToken,
      )).single['type'],
      'hangup',
    );
    final avatar = base64Encode([1, 2, 3, 4]);
    await clientApi.uploadAvatar(
      clientId: 'phone-one',
      token: clientToken,
      data: avatar,
      mimeType: 'image/png',
    );
    await remoteAdmin.uploadServerAvatar(
      clientId: 'phone-one',
      data: avatar,
      mimeType: 'image/png',
    );
    final clientProfile = await clientApi.profile(
      clientId: 'phone-one',
      token: clientToken,
    );
    expect(clientProfile['avatar_data'], avatar);
    expect(clientProfile['server_avatar_data'], avatar);
    expect(controller.avatarForClient('phone-one'), avatar);
    expect(controller.serverAvatarForClient('phone-one'), avatar);
    final adminAvatars = await remoteAdmin.clientAvatars('phone-one');
    expect(adminAvatars['avatar_data'], avatar);
    expect(adminAvatars['server_avatar_data'], avatar);
    final secondClient = await validate('phone-two', 'client-code-three');
    expect(secondClient['valid'], isTrue);
    final secondAvatar = base64Encode([5, 6, 7, 8]);
    await remoteAdmin.uploadServerAvatar(
      clientId: 'phone-two',
      data: secondAvatar,
      mimeType: 'image/png',
    );
    final secondClientApi = DirectChatApi(
      Uri.https('127.0.0.1:$port'),
      messageCode: 'client-code-three',
      certificateFingerprint: identity.fingerprint,
    );
    final secondClientProfile = await secondClientApi.profile(
      clientId: 'phone-two',
      token: secondClient['token'] as String,
    );
    expect(secondClientProfile['server_avatar_data'], secondAvatar);
    expect(controller.serverAvatarForClient('phone-two'), secondAvatar);
    expect(controller.serverAvatarForClient('phone-one'), avatar);
    final firstClientProfile = await clientApi.profile(
      clientId: 'phone-one',
      token: clientToken,
    );
    expect(firstClientProfile['server_avatar_data'], avatar);
    await remoteAdmin.setClientRemark('phone-one', '备注手机');
    final validatedAgain = await clientApi.validate(
      code: 'client-code-one',
      clientId: 'phone-one',
      clientName: 'phone-one',
      deviceName: 'phone-one',
      deviceIdentity: 'stable-device-hash-one',
      token: clientToken,
    );
    expect(validatedAgain['valid'], isTrue);
    final firstRegisteredClient = controller.registeredClients.singleWhere(
      (client) => client['client_id'] == 'phone-one',
    );
    expect(firstRegisteredClient['remark'], '备注手机');
    expect(firstRegisteredClient['avatar_data'], avatar);

    await remoteAdmin.sendText(
      'phone-one',
      'encrypted server reply',
      messageId: 'admin-message-id',
    );
    final clientState = await remoteAdmin.state();
    final phoneState = (clientState['registered_clients'] as List)
        .whereType<Map>()
        .singleWhere((client) => client['client_id'] == 'phone-one');
    expect(phoneState['last_chat_at'], isA<String>());
    final remotePasswordChange = await client.postUrl(
      Uri.https('127.0.0.1:$port', '/admin/invite-code'),
    );
    remotePasswordChange.headers
      ..set('X-Admin-Code', 'admin-password-123')
      ..contentType = ContentType.json;
    const changeBody = '{"code":"new-admin-password-123"}';
    remotePasswordChange.contentLength = utf8.encode(changeBody).length;
    remotePasswordChange.write(changeBody);
    final passwordChangeResponse = await remotePasswordChange.close();
    expect(passwordChangeResponse.statusCode, HttpStatus.notFound);
    expect(
      controller.messagesFor('phone-one', includeExpired: true).single['id'],
      'admin-message-id',
    );
    await controller.savePendingMediaMessage({
      'id': 'admin-pending-video',
      'client_id': 'phone-one',
      'sender': 'server',
      'body': '',
      'created_at': DateTime.now().toUtc().toIso8601String(),
      'file_name': 'sending.mp4',
      'mime_type': 'video/mp4',
      'media_size': 1024,
      'pending': true,
      'delivery_state': 'uploading',
      'upload_progress': 35,
    });

    final messagesRequest = await client.getUrl(
      Uri.https('127.0.0.1:$port', '/messages'),
    );
    messagesRequest.headers.set('X-Client-Id', 'phone-one');
    messagesRequest.headers.set('X-Client-Token', clientToken);
    final messagesResponse = await messagesRequest.close();
    final messagesPayload =
        jsonDecode(await utf8.decoder.bind(messagesResponse).join()) as Map;
    expect(
      jsonEncode(messagesPayload),
      isNot(contains('encrypted server reply')),
    );
    final decrypted = DailyInviteCipher('client-code-one')
        .decrypt(messagesPayload['messages_cipher'] as String);
    expect(decrypted, contains('encrypted server reply'));
    expect(decrypted, isNot(contains('admin-pending-video')));
    final textUploadProgress = <int>[];
    await clientApi.send(
      clientId: 'phone-one',
      token: clientToken,
      messageId: 'client-message-id',
      body: 'client message without IP approval',
      onProgress: textUploadProgress.add,
    );
    expect(textUploadProgress, contains(100));
    expect(
      controller
          .messagesFor('phone-one', includeExpired: true)
          .any(
            (message) =>
                message['body'] == 'client message without IP approval',
          ),
      isTrue,
    );

    final mediaUploadProgress = <int>[];
    final uploadFile = File('test/.attachment-upload.bin');
    final uploadBytes = List<int>.generate(
      1024 * 1024 + 64,
      (index) => index % 251,
    );
    await uploadFile.writeAsBytes(uploadBytes, flush: true);
    addTearDown(() async {
      if (await uploadFile.exists()) await uploadFile.delete();
    });
    final uploadChunks = Directory('test/.attachment-upload-chunks');
    await uploadChunks.create(recursive: true);
    final localCipher = DailyInviteCipher('client-code-one');
    const uploadChunkSize = 1024 * 1024;
    for (
      var offset = 0, index = 0;
      offset < uploadBytes.length;
      offset += uploadChunkSize, index++
    ) {
      final end = (offset + uploadChunkSize).clamp(0, uploadBytes.length);
      await File('${uploadChunks.path}${Platform.pathSeparator}$index.chunk')
          .writeAsString(
            localCipher.encrypt(base64Encode(uploadBytes.sublist(offset, end))),
            flush: true,
          );
    }
    addTearDown(() async {
      if (await uploadChunks.exists()) {
        await uploadChunks.delete(recursive: true);
      }
    });
    await expectLater(
      clientApi.sendMediaFile(
        clientId: 'phone-one',
        token: clientToken,
        messageId: 'resumable-client-media',
        fileName: 'resumable-file.txt',
        mimeType: 'text/plain',
        filePath: uploadChunks.path,
        fileSize: uploadBytes.length,
        encryptedChunks: true,
        sourceChunkCount: 2,
        onProgress: (progress) {
          if (progress > 0) throw StateError('Simulated client interruption');
        },
      ),
      throwsStateError,
    );
    final resumedClientApi = DirectChatApi(
      Uri.https('127.0.0.1:$port'),
      messageCode: 'client-code-one',
      certificateFingerprint: identity.fingerprint,
    );
    addTearDown(resumedClientApi.close);
    var resumedAtChunk = -1;
    final resumedMessage = await resumedClientApi.sendMediaFile(
      clientId: 'phone-one',
      token: clientToken,
      messageId: 'resumable-client-media',
      fileName: 'resumable-file.txt',
      mimeType: 'text/plain',
      filePath: uploadChunks.path,
      fileSize: uploadBytes.length,
      encryptedChunks: true,
      sourceChunkCount: 2,
      onUploadState: (_, nextChunk) async {
        resumedAtChunk = nextChunk;
      },
    );
    expect(resumedAtChunk, 1);
    expect(resumedMessage['chunk_count'], 2);

    final uploadedClientMessage = await clientApi.sendMediaFile(
      clientId: 'phone-one',
      token: clientToken,
      messageId: 'client-media-message-id',
      fileName: 'client-file.txt',
      mimeType: 'text/plain',
      filePath: uploadChunks.path,
      fileSize: uploadBytes.length,
      encryptedChunks: true,
      sourceChunkCount: 2,
      previewData: base64Encode([1, 2, 3]),
      onProgress: mediaUploadProgress.add,
    );
    expect(mediaUploadProgress, isNotEmpty);
    expect(mediaUploadProgress.last, 100);
    expect(uploadedClientMessage['chunk_count'], 2);
    expect(uploadedClientMessage['preview_data'], base64Encode([1, 2, 3]));
    expect(
      (await remoteAdmin.messages('phone-one')).singleWhere(
        (message) => message['id'] == 'client-media-message-id',
      )['preview_data'],
      base64Encode([1, 2, 3]),
    );
    final uploadedMedia = controller.mediaForMessage(uploadedClientMessage);
    expect(uploadedMedia, isNotNull);
    expect(uploadedMedia!.containsKey('data'), isFalse);
    final storedChunk = File(
      '${mediaDirectory.path}${Platform.pathSeparator}'
      '${uploadedClientMessage['media_id']}${Platform.pathSeparator}0.chunk',
    );
    expect(await storedChunk.exists(), isTrue);
    expect(
      await storedChunk.readAsString(),
      isNot(contains('client attachment')),
    );
    final videoUploadFile = File('test/.client-video.mp4');
    final videoBytes = List<int>.generate(4097, (index) => index % 251);
    await videoUploadFile.writeAsBytes(videoBytes, flush: true);
    addTearDown(() async {
      if (await videoUploadFile.exists()) await videoUploadFile.delete();
    });
    final uploadedVideoMessage = await clientApi.sendMediaFile(
      clientId: 'phone-one',
      token: clientToken,
      messageId: 'client-video-message-id',
      fileName: 'client-video.mp4',
      mimeType: 'video/mp4',
      filePath: videoUploadFile.path,
      fileSize: videoBytes.length,
      rawVideoChunks: true,
      previewData: base64Encode([7, 8, 9]),
    );
    final uploadedVideoMedia = controller.mediaForMessage(uploadedVideoMessage);
    expect(uploadedVideoMedia?['encrypted'], isFalse);
    final rawVideoChunk = File(
      '${mediaDirectory.path}${Platform.pathSeparator}'
      '${uploadedVideoMessage['media_id']}${Platform.pathSeparator}0.chunk',
    );
    expect(await rawVideoChunk.readAsBytes(), videoBytes);
    final uploadedLegacyMethodVideo = await clientApi.sendMedia(
      clientId: 'phone-one',
      token: clientToken,
      messageId: 'client-video-legacy-method',
      fileName: 'legacy-method-video.mp4',
      mimeType: 'video/mp4',
      data: base64Encode(videoBytes),
    );
    final uploadedLegacyMethodMedia = controller.mediaForMessage(
      uploadedLegacyMethodVideo,
    );
    expect(uploadedLegacyMethodMedia?['encrypted'], isFalse);
    final legacyMethodChunk = File(
      '${mediaDirectory.path}${Platform.pathSeparator}'
      '${uploadedLegacyMethodVideo['media_id']}${Platform.pathSeparator}0.chunk',
    );
    expect(await legacyMethodChunk.readAsBytes(), videoBytes);
    final downloadedVideo = File('test/.client-video-download.mp4');
    await clientApi.downloadMediaToFile(
      clientId: 'phone-one',
      token: clientToken,
      mediaId: uploadedVideoMessage['media_id'] as String,
      chunkCount: uploadedVideoMessage['chunk_count'] as int,
      expectedSize: videoBytes.length,
      outputPath: downloadedVideo.path,
    );
    expect(await downloadedVideo.readAsBytes(), videoBytes);
    addTearDown(() async {
      if (await downloadedVideo.exists()) await downloadedVideo.delete();
      if (await File('${downloadedVideo.path}.partial').exists()) {
        await File('${downloadedVideo.path}.partial').delete();
      }
    });
    final downloadedFile = File('test/.attachment-download.bin');
    final partialPath = File('${downloadedFile.path}.partial');
    await expectLater(
      clientApi.downloadMediaToFile(
        clientId: 'phone-one',
        token: clientToken,
        mediaId: uploadedClientMessage['media_id'] as String,
        chunkCount: uploadedClientMessage['chunk_count'] as int,
        expectedSize: uploadBytes.length,
        outputPath: downloadedFile.path,
        onProgress: (progress) {
          if (progress == 50) throw StateError('Simulated client interruption');
        },
      ),
      throwsStateError,
    );
    expect(await partialPath.length(), 1024 * 1024);
    final resumedDownloadProgress = <int>[];
    await clientApi.downloadMediaToFile(
      clientId: 'phone-one',
      token: clientToken,
      mediaId: uploadedClientMessage['media_id'] as String,
      chunkCount: uploadedClientMessage['chunk_count'] as int,
      expectedSize: uploadBytes.length,
      outputPath: downloadedFile.path,
      onProgress: resumedDownloadProgress.add,
    );
    expect(resumedDownloadProgress, contains(50));
    expect(resumedDownloadProgress.last, 100);
    expect(await downloadedFile.readAsBytes(), uploadBytes);
    addTearDown(() async {
      if (await downloadedFile.exists()) await downloadedFile.delete();
      if (await partialPath.exists()) await partialPath.delete();
    });

    await controller.stop();
    final restartedController = InviteHostController(
      store,
      mediaDirectory: mediaDirectory,
    );
    final restartedPortProbe = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final restartedPort = restartedPortProbe.port;
    await restartedPortProbe.close();
    await restartedController.start(
      port: restartedPort,
      code: 'admin-password-123',
      certificate: identity.certificate,
      privateKey: identity.privateKey,
      certificateFingerprint: identity.fingerprint,
      bindAddress: InternetAddress.loopbackIPv4,
    );
    activePort = restartedPort;
    remoteAdmin = RemoteManagementApi(
      Uri.https('127.0.0.1:$activePort'),
      'admin-password-123',
      certificateFingerprint: identity.fingerprint,
    );
    addTearDown(() async {
      await restartedController.stop();
      restartedController.dispose();
    });
    final restartedApi = DirectChatApi(
      Uri.https('127.0.0.1:$restartedPort'),
      messageCode: 'client-code-one',
      certificateFingerprint: identity.fingerprint,
    );
    final afterRestart = await restartedApi.messages(
      clientId: 'phone-one',
      token: clientToken,
    );
    final restoredMessage = afterRestart.singleWhere(
      (message) => message['id'] == 'client-media-message-id',
    );
    final restartedDownload = File('test/.attachment-restart-download.bin');
    await restartedApi.downloadMediaToFile(
      clientId: 'phone-one',
      token: clientToken,
      mediaId: restoredMessage['media_id'] as String,
      chunkCount: restoredMessage['chunk_count'] as int,
      expectedSize: restoredMessage['media_size'] as int,
      outputPath: restartedDownload.path,
    );
    expect(await restartedDownload.readAsBytes(), uploadBytes);
    addTearDown(() async {
      if (await restartedDownload.exists()) await restartedDownload.delete();
    });

    await remoteAdmin.sendMediaFile(
      clientId: 'phone-one',
      messageId: 'server-file-message-id',
      fileName: 'server-file.txt',
      mimeType: 'text/plain',
      filePath: uploadFile.path,
      fileSize: uploadBytes.length,
      previewData: base64Encode([4, 5, 6]),
    );
    await remoteAdmin.sendMediaFile(
      clientId: 'phone-one',
      messageId: 'server-video-message-id',
      fileName: 'server-video.mp4',
      mimeType: 'video/mp4',
      filePath: videoUploadFile.path,
      fileSize: videoBytes.length,
      previewData: base64Encode([8, 9, 10]),
    );
    final uploadedServerVideo = restartedController
        .messagesFor('phone-one', includeExpired: true)
        .singleWhere((message) => message['id'] == 'server-video-message-id');
    expect(
      restartedController.mediaForMessage(uploadedServerVideo)?['encrypted'],
      isFalse,
    );
    expect(uploadedServerVideo['preview_data'], base64Encode([8, 9, 10]));
    final serverVideoDownload = File('test/.server-video-download.mp4');
    await remoteAdmin.downloadMediaToFile(
      mediaId: uploadedServerVideo['media_id'] as String,
      chunkCount: uploadedServerVideo['chunk_count'] as int,
      expectedSize: uploadedServerVideo['media_size'] as int,
      outputPath: serverVideoDownload.path,
    );
    expect(await serverVideoDownload.readAsBytes(), videoBytes);
    addTearDown(() async {
      if (await serverVideoDownload.exists()) {
        await serverVideoDownload.delete();
      }
      final partial = File('${serverVideoDownload.path}.partial');
      if (await partial.exists()) await partial.delete();
    });
    final uploadedMediaMessage = restartedController
        .messagesFor('phone-one', includeExpired: true)
        .singleWhere((message) => message['file_name'] == 'server-file.txt');
    expect(uploadedMediaMessage['preview_data'], base64Encode([4, 5, 6]));
    final uploadedMediaId = uploadedMediaMessage['media_id'] as String;
    final adminDownload = File('test/.admin-attachment-download.bin');
    final adminPartial = File('${adminDownload.path}.partial');
    await expectLater(
      remoteAdmin.downloadMediaToFile(
        mediaId: uploadedMediaId,
        chunkCount: uploadedMediaMessage['chunk_count'] as int,
        expectedSize: uploadedMediaMessage['media_size'] as int,
        outputPath: adminDownload.path,
        onProgress: (progress) {
          if (progress == 50) throw StateError('Simulated admin interruption');
        },
      ),
      throwsStateError,
    );
    expect(await adminPartial.length(), 1024 * 1024);
    final adminResumeProgress = <int>[];
    await remoteAdmin.downloadMediaToFile(
      mediaId: uploadedMediaId,
      chunkCount: uploadedMediaMessage['chunk_count'] as int,
      expectedSize: uploadedMediaMessage['media_size'] as int,
      outputPath: adminDownload.path,
      onProgress: adminResumeProgress.add,
    );
    expect(adminResumeProgress, contains(50));
    expect(await adminDownload.readAsBytes(), uploadBytes);
    addTearDown(() async {
      if (await adminDownload.exists()) await adminDownload.delete();
      if (await adminPartial.exists()) await adminPartial.delete();
    });
    await remoteAdmin.deleteMessages('phone-one', [
      'admin-message-id',
      'admin-pending-video',
      uploadedMediaMessage['id'] as String,
    ]);
    expect(
      restartedController
          .messagesFor('phone-one', includeExpired: true)
          .any((message) => message['id'] == 'admin-message-id'),
      isFalse,
    );
    expect(restartedController.mediaForMessage(uploadedMediaMessage), isNull);
    expect(
      restartedController.isAdminUploadCancelled(
        'phone-one',
        'admin-pending-video',
      ),
      isTrue,
    );
    expect(
      restartedController
          .messagesFor('phone-one', includeExpired: true)
          .any((message) => message['id'] == 'admin-pending-video'),
      isFalse,
    );
    final remainingAfterDelete = await remoteAdmin.messages('phone-one');
    expect(
      remainingAfterDelete.any(
        (message) => message['id'] == 'admin-message-id',
      ),
      isFalse,
    );
    await expectLater(
      restartedApi.deleteMessages(
        clientId: 'phone-one',
        token: 'invalid-token',
        messageIds: ['client-media-message-id'],
      ),
      throwsA(isA<HttpException>()),
    );
    await restartedApi.deleteMessages(
      clientId: 'phone-one',
      token: clientToken,
      messageIds: ['client-media-message-id'],
    );
    expect(
      restartedController
          .messagesFor('phone-one', includeExpired: true)
          .any((message) => message['id'] == 'client-media-message-id'),
      isFalse,
    );
    expect(
      remainingAfterDelete.any(
        (message) => message['media_id'] == uploadedMediaId,
      ),
      isFalse,
    );
    expect(
      remainingAfterDelete.any(
        (message) => message['body'] == 'client message without IP approval',
      ),
      isTrue,
    );

    final reinstalledBeforeConflict = await validate(
      'new-install-client-id',
      'client-code-one',
      deviceIdentity: 'stable-device-hash-one',
    );
    expect(reinstalledBeforeConflict['valid'], isTrue);
    expect(reinstalledBeforeConflict['client_id'], 'phone-one');
    expect(
      restartedController.messagesFor('phone-one', includeExpired: true),
      isNotEmpty,
    );

    final reused = await validate('phone-three', 'client-code-one');
    expect(reused['valid'], isFalse);
    expect(reused['error'], 'invite_already_assigned');

    final owner = restartedController.registeredClients.singleWhere(
      (client) => client['client_id'] == 'phone-one',
    );
    expect(owner['revoked'], isTrue);
    expect(
      restartedController.inviteCodes.singleWhere(
        (entry) => entry['code'] == 'client-code-one',
      )['status'],
      '已失效',
    );
    final ownerStillAuthorized = await validate(
      'phone-one',
      'client-code-one',
      token: clientToken,
    );
    expect(ownerStillAuthorized['valid'], isFalse);
    expect(ownerStillAuthorized['error'], 'invite_invalidated');

    final ownerTokenRequest = await client.getUrl(
      Uri.https('127.0.0.1:$activePort', '/messages'),
    );
    ownerTokenRequest.headers.set('X-Client-Id', 'phone-one');
    ownerTokenRequest.headers.set('X-Client-Token', clientToken);
    final ownerTokenResponse = await ownerTokenRequest.close();
    expect(ownerTokenResponse.statusCode, HttpStatus.forbidden);

    await restartedController.changeClientInviteCode(
      'phone-one',
      'client-code-two',
    );
    final revoked = await validate(
      'phone-one',
      'client-code-one',
      token: clientToken,
    );
    expect(revoked['valid'], isFalse);
    final staleTokenRequest = await client.getUrl(
      Uri.https('127.0.0.1:$activePort', '/messages'),
    );
    staleTokenRequest.headers.set('X-Client-Id', 'phone-one');
    staleTokenRequest.headers.set('X-Client-Token', clientToken);
    final staleTokenResponse = await staleTokenRequest.close();
    expect(staleTokenResponse.statusCode, HttpStatus.forbidden);

    final renewed = await validate(
      'phone-one',
      'client-code-two',
      token: clientToken,
    );
    expect(renewed['valid'], isTrue);
    expect(renewed['token'], isNot(clientToken));
    final reinstalled = await validate(
      'new-install-client-id',
      'client-code-two',
      deviceIdentity: 'stable-device-hash-one',
    );
    expect(reinstalled['valid'], isTrue);
    expect(reinstalled['client_id'], 'phone-one');
    expect(
      restartedController.messagesFor('phone-one', includeExpired: true),
      isNotEmpty,
    );

    await restartedController.revokeInviteCode('client-code-two');
    expect(
      restartedController.registeredClients.singleWhere(
        (client) => client['client_id'] == 'phone-one',
      )['revoked'],
      isTrue,
    );
    expect(
      restartedController
          .messagesFor('phone-one', includeExpired: true)
          .any((message) => message['body'] == 'encrypted server reply'),
      isFalse,
    );
  });

  test('legacy identity fields are ignored and never stored', () async {
    final store = _MemoryStore();
    final identity = await loadOrCreateServerTlsIdentity(store);
    final controller = InviteHostController(store);
    await controller.addInviteCodes('legacy-client-code');
    final portProbe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = portProbe.port;
    await portProbe.close();
    await controller.start(
      port: port,
      code: 'admin-password-123',
      certificate: identity.certificate,
      privateKey: identity.privateKey,
      certificateFingerprint: identity.fingerprint,
      bindAddress: InternetAddress.loopbackIPv4,
    );
    addTearDown(() async {
      await controller.stop();
      controller.dispose();
    });

    final client = createPinnedHttpClient(identity.fingerprint);
    addTearDown(() => client.close(force: true));

    Future<Map<String, dynamic>> validate(
      String clientId,
      String code,
      String identityNumber,
    ) async {
      final request = await client.postUrl(
        Uri.https('127.0.0.1:$port', '/validate'),
      );
      request.headers.contentType = ContentType.json;
      final body = jsonEncode({
        'code': code,
        'client_id': clientId,
        'client_name': clientId,
        'identity_number': identityNumber,
        'token': '',
      });
      request.contentLength = utf8.encode(body).length;
      request.write(body);
      final response = await request.close();
      return Map<String, dynamic>.from(
        jsonDecode(await utf8.decoder.bind(response).join()) as Map,
      );
    }

    final result = await validate(
      'legacy-phone',
      'legacy-client-code',
      'not-a-valid-id',
    );
    expect(result['valid'], isTrue);
    expect(
      controller.registeredClients
          .singleWhere((client) => client['client_id'] == 'legacy-phone')
          .containsKey('identity_number'),
      isFalse,
    );
    expect(
      controller.inviteCodes.single.containsKey('identity_number'),
      isFalse,
    );
  });

  test('messages sort chronologically with a stable id tie-breaker', () {
    final messages = [
      {'id': 'later', 'created_at': '2026-11-12T10:01:00Z'},
      {'id': 'same-b', 'created_at': '2026-11-12T10:00:00Z'},
      {'id': 'earlier', 'created_at': '2026-11-12T09:59:00Z'},
      {'id': 'same-a', 'created_at': '2026-11-12T10:00:00Z'},
    ]..sort(compareDirectMessages);

    expect(messages.map((message) => message['id']), [
      'earlier',
      'same-a',
      'same-b',
      'later',
    ]);
  });

  test('direct messages are visible for one hour only', () {
    final now = DateTime.utc(2026, 11, 12, 12);
    expect(
      isDirectMessageVisible({
        'created_at': now
            .subtract(const Duration(minutes: 59))
            .toIso8601String(),
      }, now: now),
      isTrue,
    );
    expect(
      isDirectMessageVisible({
        'created_at': now.subtract(const Duration(hours: 1)).toIso8601String(),
      }, now: now),
      isFalse,
    );
    expect(
      isDirectMessageVisible({
        'created_at': now.add(const Duration(seconds: 1)).toIso8601String(),
      }, now: now),
      isFalse,
    );
  });

  test('daily invite encryption protects and restores payloads', () {
    final cipher = DailyInviteCipher('a-long-daily-invite-code');
    const plaintext = 'private text and attachment data';
    final encrypted = cipher.encrypt(plaintext);

    expect(encrypted, isNot(contains(plaintext)));
    expect(cipher.decrypt(encrypted), plaintext);
    expect(
      () => DailyInviteCipher('a-different-daily-code').decrypt(encrypted),
      throwsFormatException,
    );
  });
}
