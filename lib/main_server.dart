import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'app_log.dart';
import 'invite_host.dart';
import 'remote_admin.dart';
import 'secure_cache.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppLogger.initialize(
    Platform.isWindows ? 'windows-server' : 'server-mobile',
  );
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
  runApp(
    Platform.isWindows
        ? InviteHostApp(
            cache: cache,
            autoStartServer: Platform.executableArguments.contains(
              '--start-server',
            ),
          )
        : RemoteAdminApp(cache: cache),
  );
}
