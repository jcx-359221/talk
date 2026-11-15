import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'app_log.dart';
import 'app_config.dart';
import 'client_background_service.dart';
import 'client_launch_policy.dart';
import 'invite_gate.dart';
import 'secure_cache.dart';
import 'server_tls.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppLogger.initialize('client-mobile');
  final previousFlutterErrorHandler = FlutterError.onError;
  FlutterError.onError = (details) {
    AppLogger.log(
      'flutter.framework_error',
      level: 'error',
      error: details.exception,
      stackTrace: details.stack,
    );
    previousFlutterErrorHandler?.call(details);
  };
  PlatformDispatcher.instance.onError = (error, stackTrace) {
    AppLogger.log(
      'flutter.unhandled_error',
      level: 'error',
      error: error,
      stackTrace: stackTrace,
    );
    return false;
  };
  late final SecureCache cache;
  try {
    cache = await SecureCache.open();
  } catch (error, stackTrace) {
    AppLogger.log(
      'app.initialization_failed',
      level: 'error',
      error: error,
      stackTrace: stackTrace,
    );
    rethrow;
  }
  final clientBlacklisted = cache.text(clientBlacklistCacheKey) == 'true';
  var startupBlockReason = clientBlacklisted
      ? '此设备已被拉黑，应用已锁定。'
      : await clientStartupBlockReason(cache);
  if (startupBlockReason == null) {
    await initializeClientBackgroundService();
  } else {
    if (clientBlacklisted) {
      try {
        await cache.purgeClientChatData(
          cache.text('direct-client-id') ?? '',
        );
      } catch (error, stackTrace) {
        AppLogger.log(
          'client.blocked_startup_cache_purge_failed',
          level: 'error',
          error: error,
          stackTrace: stackTrace,
        );
        startupBlockReason = '$startupBlockReason 本地授权数据清理未能完成。';
      }
      try {
        await clearServerCertificatePin(Uri.parse(serverBaseUrl), cache);
      } catch (error, stackTrace) {
        AppLogger.log(
          'client.blocked_startup_server_pin_clear_failed',
          level: 'error',
          error: error,
          stackTrace: stackTrace,
        );
        startupBlockReason = '$startupBlockReason 本地服务器记录清理未能完成。';
      }
    }
    try {
      await markClientBackgroundServiceBlocked();
      await stopClientBackgroundService();
    } catch (error, stackTrace) {
      AppLogger.log(
        'client.blocked_startup_service_stop_failed',
        level: 'error',
        error: error,
        stackTrace: stackTrace,
      );
      startupBlockReason = '$startupBlockReason 后台连接停止失败，请手动停止应用。';
    }
  }
  runApp(InviteGateApp(
    serverUri: Uri.parse(serverBaseUrl),
    cache: cache,
    startupBlockReason: startupBlockReason,
  ));
}
