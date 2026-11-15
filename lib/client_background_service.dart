import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:vibration/vibration.dart';

import 'app_config.dart';
import 'app_log.dart';
import 'direct_chat.dart';

const _sessionStorageKey = 'consent_chat_background_session';
const _lastAlertStorageKey = 'consent_chat_background_last_alert';
const _blacklistStorageKey = 'consent_chat_background_blacklisted';
const _serviceChannelId = 'client_background_service';
const _alertChannelId = 'client_vibration_alerts';
const _serviceNotificationId = 81720;
const _alertNotificationId = 81721;

final _notifications = FlutterLocalNotificationsPlugin();
final _secureStorage = FlutterSecureStorage();

Future<void> initializeClientBackgroundService() async {
  if (!Platform.isAndroid) return;
  final initializationSettings = InitializationSettings(
    android: AndroidInitializationSettings('@mipmap/ic_launcher'),
  );
  await _notifications.initialize(initializationSettings);
  final androidNotifications =
      _notifications.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
  await androidNotifications?.createNotificationChannel(
    AndroidNotificationChannel(
      _serviceChannelId,
      '客户端后台连接',
      description: '保持聊天客户端连接并接收重要提醒。',
      importance: Importance.low,
      playSound: false,
      enableVibration: false,
    ),
  );
  await androidNotifications?.createNotificationChannel(
    AndroidNotificationChannel(
      _alertChannelId,
      '聊天震动提醒',
      description: '收到管理端发送的震动提醒时通知客户端。',
      importance: Importance.high,
      playSound: true,
      enableVibration: true,
      vibrationPattern: Int64List.fromList([0, 500, 250, 500]),
    ),
  );
  await FlutterBackgroundService().configure(
    androidConfiguration: AndroidConfiguration(
      onStart: clientBackgroundOnStart,
      autoStart: false,
      autoStartOnBoot: true,
      isForegroundMode: true,
      notificationChannelId: _serviceChannelId,
      foregroundServiceNotificationId: _serviceNotificationId,
      initialNotificationTitle: '聊天客户端后台连接',
      initialNotificationContent: '正在准备聊天连接…',
      foregroundServiceTypes: const [AndroidForegroundType.dataSync],
    ),
    iosConfiguration: IosConfiguration(autoStart: false),
  );
}

Future<void> startClientBackgroundService({
  required String clientId,
  required String inviteCode,
  required String token,
  required String certificateFingerprint,
}) async {
  if (!Platform.isAndroid) return;
  final notificationPermission = await _notifications
      .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>()
      ?.requestNotificationsPermission();
  if (notificationPermission == false) {
    AppLogger.log('client.notification_permission_denied', level: 'warning');
  }
  await _secureStorage.delete(key: _blacklistStorageKey);
  await _secureStorage.write(
    key: _sessionStorageKey,
    value: jsonEncode({
      'server_url': serverBaseUrl,
      'client_id': clientId,
      'invite_code': inviteCode,
      'token': token,
      'certificate_fingerprint': certificateFingerprint,
    }),
  );
  final service = FlutterBackgroundService();
  if (!await service.isRunning()) {
    await service.startService();
  }
  service.invoke('appState', {'foreground': true});
  AppLogger.log('client.background_service_started');
}

Future<void> stopClientBackgroundService() async {
  if (!Platform.isAndroid) return;
  FlutterBackgroundService().invoke('stop');
  await _secureStorage.delete(key: _sessionStorageKey);
  await _secureStorage.delete(key: _lastAlertStorageKey);
  AppLogger.log('client.background_service_stopped');
}

Future<void> markClientBackgroundServiceBlocked() async {
  if (!Platform.isAndroid) return;
  await _secureStorage.write(key: _blacklistStorageKey, value: 'true');
}

void setClientAppForeground(bool foreground) {
  if (Platform.isAndroid) {
    FlutterBackgroundService().invoke('appState', {'foreground': foreground});
  }
}

@pragma('vm:entry-point')
void clientBackgroundOnStart(ServiceInstance service) async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppLogger.initialize('client-mobile');
  if (service is AndroidServiceInstance) {
    await service.setAsForegroundService();
    await service.setForegroundNotificationInfo(
      title: '聊天客户端后台连接',
      content: '正在保持聊天连接并接收提醒。',
    );
  }

  var appForeground = false;
  var polling = false;
  var lastAlertId = await _secureStorage.read(key: _lastAlertStorageKey);
  service.on('appState').listen((event) {
    appForeground = event?['foreground'] == true;
  });
  service.on('stop').listen((_) {
    service.stopSelf();
  });

  Future<void> checkMessages() async {
    if (polling) return;
    polling = true;
    DirectChatApi? api;
    try {
      if (await _secureStorage.read(key: _blacklistStorageKey) == 'true') {
        service.stopSelf();
        return;
      }
      final encodedSession = await _secureStorage.read(key: _sessionStorageKey);
      if (encodedSession == null) {
        service.stopSelf();
        return;
      }
      final session = jsonDecode(encodedSession);
      if (session is! Map ||
          session['client_id'] is! String ||
          session['invite_code'] is! String ||
          session['token'] is! String ||
          session['certificate_fingerprint'] is! String) {
        throw const FormatException('Background client session is invalid.');
      }
      api = DirectChatApi(
        Uri.parse(session['server_url'] as String),
        messageCode: session['invite_code'] as String,
        certificateFingerprint: session['certificate_fingerprint'] as String,
      );
      final messages = await api.messages(
        clientId: session['client_id'] as String,
        token: session['token'] as String,
      );
      for (final message in messages) {
        final id = message['id']?.toString();
        if (message['type'] != 'vibration_alert' ||
            id == null ||
            id == lastAlertId) {
          continue;
        }
        lastAlertId = id;
        await _secureStorage.write(key: _lastAlertStorageKey, value: id);
        if (!appForeground) {
          await Vibration.vibrate(pattern: [0, 500, 250, 500]);
          await _notifications.show(
            _alertNotificationId,
            '聊天震动提醒',
            '管理端向你发送了震动提醒。',
            NotificationDetails(
              android: AndroidNotificationDetails(
                _alertChannelId,
                '聊天震动提醒',
                channelDescription: '收到管理端发送的震动提醒时通知客户端。',
                importance: Importance.high,
                priority: Priority.high,
                enableVibration: true,
                vibrationPattern: Int64List.fromList([0, 500, 250, 500]),
              ),
            ),
          );
        }
      }
    } catch (error, stackTrace) {
      AppLogger.log(
        'client.background_poll_failed',
        level: 'error',
        error: error,
        stackTrace: stackTrace,
      );
    } finally {
      api?.close();
      polling = false;
    }
  }

  await checkMessages();
  Timer.periodic(const Duration(seconds: 15), (_) {
    unawaited(checkMessages());
  });
}
