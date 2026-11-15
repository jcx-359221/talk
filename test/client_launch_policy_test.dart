import 'package:flutter_test/flutter_test.dart';

import 'package:consent_chat/client_apk_builder.dart';
import 'package:consent_chat/client_launch_policy.dart';

void main() {
  group('client launch policy', () {
    test('device-specific build rejects a different device before time checks',
        () {
      expect(
        clientLaunchPolicyError(
          deviceIdentity: 'different',
          expectedDeviceIdentity: 'expected',
          trialBuild: true,
          trialDate: 'invalid',
          networkTimeMillis: null,
        ),
        contains('指定设备'),
      );
    });

    test('trial build accepts the configured date using UTC+8 network time',
        () {
      final networkTime = DateTime.utc(2026, 11, 13, 16).millisecondsSinceEpoch;
      expect(
        clientLaunchPolicyError(
          deviceIdentity: null,
          expectedDeviceIdentity: null,
          trialBuild: true,
          trialDate: '2026-11-14',
          networkTimeMillis: networkTime,
        ),
        isNull,
      );
    });

    test('trial build rejects a different date and unavailable network time',
        () {
      final networkTime = DateTime.utc(2026, 11, 14, 16).millisecondsSinceEpoch;
      expect(
        clientLaunchPolicyError(
          deviceIdentity: null,
          expectedDeviceIdentity: null,
          trialBuild: true,
          trialDate: '2026-11-14',
          networkTimeMillis: networkTime,
        ),
        contains('仅限 2026-11-14'),
      );
      expect(
        clientLaunchPolicyError(
          deviceIdentity: null,
          expectedDeviceIdentity: null,
          trialBuild: true,
          trialDate: '2026-11-14',
          networkTimeMillis: null,
        ),
        contains('系统网络时间'),
      );
    });

    test('rejects invalid compiled trial dates', () {
      expect(
        clientLaunchPolicyError(
          deviceIdentity: null,
          expectedDeviceIdentity: null,
          trialBuild: true,
          trialDate: '2026-02-30',
          networkTimeMillis: 1,
        ),
        contains('日期配置无效'),
      );
    });

    test('unrestricted build remains allowed', () {
      expect(
        clientLaunchPolicyError(
          deviceIdentity: null,
          expectedDeviceIdentity: null,
          trialBuild: false,
          trialDate: '',
          networkTimeMillis: null,
        ),
        isNull,
      );
    });
  });

  test('APK name is prefixed and unsafe path characters are replaced', () {
    expect(clientApkFileName('phone_01'), 'chat_client_phone_01.apk');
    expect(clientApkFileName('phone/01'), 'chat_client_phone_01.apk');
    expect(
      clientApkFileName('手机'),
      'chat_client_手机.apk',
    );
    expect(() => clientApkFileName(' . '), throwsArgumentError);
  });
}
