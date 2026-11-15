import 'dart:io';

import 'package:flutter/services.dart';

import 'app_log.dart';
import 'device_identity.dart';
import 'secure_cache.dart';

const clientTrialBuild = bool.fromEnvironment('CLIENT_TRIAL');
const clientTrialDate = String.fromEnvironment('CLIENT_TRIAL_DATE');
const requiredClientDeviceIdentity =
    String.fromEnvironment('CLIENT_EXPECTED_DEVICE_IDENTITY');
const clientBlacklistCacheKey = 'direct-client-blacklisted';

const _systemTimeChannel = MethodChannel('consent_chat/device_identity');

String? clientLaunchPolicyError({
  required String? deviceIdentity,
  required String? expectedDeviceIdentity,
  required bool trialBuild,
  required String trialDate,
  required int? networkTimeMillis,
}) {
  final expectedIdentity = expectedDeviceIdentity?.trim().toLowerCase() ?? '';
  if (expectedIdentity.isNotEmpty &&
      deviceIdentity?.trim().toLowerCase() != expectedIdentity) {
    return '此客户端安装包仅适用于指定设备，应用已锁定。';
  }

  if (!trialBuild) return null;

  final dateMatch = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(trialDate);
  if (dateMatch == null) {
    return '试用版日期配置无效，应用无法启动。';
  }
  final year = int.parse(dateMatch.group(1)!);
  final month = int.parse(dateMatch.group(2)!);
  final day = int.parse(dateMatch.group(3)!);
  final configuredDate = DateTime.utc(year, month, day);
  if (configuredDate.year != year ||
      configuredDate.month != month ||
      configuredDate.day != day) {
    return '试用版日期配置无效，应用无法启动。';
  }
  if (networkTimeMillis == null || networkTimeMillis <= 0) {
    return '无法获取 Android 系统网络时间，试用版不能启动。';
  }

  final chinaTime = DateTime.fromMillisecondsSinceEpoch(
    networkTimeMillis,
    isUtc: true,
  ).add(const Duration(hours: 8));
  final currentDate = '${chinaTime.year.toString().padLeft(4, '0')}-'
      '${chinaTime.month.toString().padLeft(2, '0')}-'
      '${chinaTime.day.toString().padLeft(2, '0')}';
  if (currentDate != trialDate) {
    return '此试用版仅限 $trialDate（北京时间）启动。';
  }
  return null;
}

Future<String?> clientStartupBlockReason(SecureCache cache) async {
  String? deviceIdentity;
  if (requiredClientDeviceIdentity.isNotEmpty) {
    try {
      deviceIdentity = await persistentDeviceIdentity(cache);
    } catch (error, stackTrace) {
      AppLogger.log(
        'client.device_binding_check_failed',
        level: 'error',
        error: error,
        stackTrace: stackTrace,
      );
      return '无法读取设备标识，应用已锁定。';
    }
  }

  int? networkTimeMillis;
  if (clientTrialBuild) {
    if (!Platform.isAndroid) {
      return '试用版仅支持 Android 13 及以上设备启动。';
    }
    try {
      networkTimeMillis =
          await _systemTimeChannel.invokeMethod<int>('networkTimeMillis');
    } on PlatformException catch (error, stackTrace) {
      AppLogger.log(
        'client.network_time_unavailable',
        level: 'warning',
        error: error,
        stackTrace: stackTrace,
      );
    } on MissingPluginException catch (error, stackTrace) {
      AppLogger.log(
        'client.network_time_channel_missing',
        level: 'error',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  return clientLaunchPolicyError(
    deviceIdentity: deviceIdentity,
    expectedDeviceIdentity: requiredClientDeviceIdentity,
    trialBuild: clientTrialBuild,
    trialDate: clientTrialDate,
    networkTimeMillis: networkTimeMillis,
  );
}
