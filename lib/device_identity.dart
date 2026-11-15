import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';

import 'app_log.dart';
import 'secure_cache.dart';

const _deviceIdentityChannel = MethodChannel('consent_chat/device_identity');
const _uuid = Uuid();

Future<String> persistentDeviceIdentity(SecureCache cache) async {
  if (Platform.isAndroid) {
    try {
      final androidId =
          await _deviceIdentityChannel.invokeMethod<String>('androidId');
      if (androidId != null && androidId.isNotEmpty) {
        return sha256
            .convert(utf8.encode('consent-chat-device-v1:$androidId'))
            .toString();
      }
      throw StateError('Android did not provide a stable device identity.');
    } on PlatformException catch (error, stackTrace) {
      AppLogger.log(
        'client.device_identity_read_failed',
        level: 'warning',
        error: error,
        stackTrace: stackTrace,
      );
      throw StateError('Unable to read the Android device identity: $error');
    } on MissingPluginException catch (error, stackTrace) {
      AppLogger.log(
        'client.device_identity_channel_missing',
        level: 'warning',
        error: error,
        stackTrace: stackTrace,
      );
      throw StateError('The Android device identity service is unavailable.');
    }
  }
  final cached = cache.text('direct-persistent-device-identity');
  if (cached != null && cached.isNotEmpty) return cached;
  final generated = _uuid.v4();
  await cache.putText('direct-persistent-device-identity', generated);
  return generated;
}
