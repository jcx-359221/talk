import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:consent_chat/app_log.dart';

void main() {
  test('purging client logs keeps server and unrelated files', () async {
    final directory = Directory('test/.client-log-purge-test');
    await directory.create(recursive: true);
    final clientLog = File(
      '${directory.path}${Platform.pathSeparator}'
      'client-mobile-2026-11-14.log',
    );
    final rotatedClientLog = File(
      '${directory.path}${Platform.pathSeparator}'
      'client-mobile-2026-11-13.log.1',
    );
    final serverLog = File(
      '${directory.path}${Platform.pathSeparator}'
      'server-mobile-2026-11-14.log',
    );
    final unrelatedFile = File(
      '${directory.path}${Platform.pathSeparator}notes.txt',
    );
    await clientLog.writeAsString('client');
    await rotatedClientLog.writeAsString('rotated client');
    await serverLog.writeAsString('server');
    await unrelatedFile.writeAsString('unrelated');

    try {
      await purgeClientLogsInDirectory(directory);

      expect(await clientLog.exists(), isFalse);
      expect(await rotatedClientLog.exists(), isFalse);
      expect(await serverLog.exists(), isTrue);
      expect(await unrelatedFile.exists(), isTrue);
    } finally {
      if (await directory.exists()) await directory.delete(recursive: true);
    }
  });
}
