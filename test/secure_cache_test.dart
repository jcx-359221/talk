import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:consent_chat/secure_cache.dart';

void main() {
  test('chat purge removes pending and downloaded attachments only', () async {
    final root = Directory('test/.chat-purge-test');
    final support = Directory('${root.path}${Platform.pathSeparator}support');
    final temporary = Directory('${root.path}${Platform.pathSeparator}temp');
    final pending = Directory(
      '${support.path}${Platform.pathSeparator}pending-attachments'
      '${Platform.pathSeparator}message-1',
    );
    final downloaded = File(
      '${temporary.path}${Platform.pathSeparator}media-1_photo.jpg',
    );
    final unrelated = File(
      '${temporary.path}${Platform.pathSeparator}unrelated.txt',
    );
    final selectedSource = File(
      '${root.path}${Platform.pathSeparator}selected_photo.jpg',
    );

    await root.create(recursive: true);
    await pending.create(recursive: true);
    await temporary.create(recursive: true);
    await downloaded.writeAsString('downloaded');
    await unrelated.writeAsString('unrelated');
    await selectedSource.writeAsString('user-owned source');

    try {
      await purgeClientChatFiles(
        messages: [
          {
            'id': 'message-1',
            'media_id': 'media-1',
            'media_path': downloaded.path,
            'file_path': selectedSource.path,
          },
        ],
        supportDirectory: support,
        temporaryDirectory: temporary,
      );

      expect(await pending.exists(), isFalse);
      expect(await downloaded.exists(), isFalse);
      expect(await unrelated.exists(), isTrue);
      expect(await selectedSource.exists(), isTrue);
    } finally {
      if (await root.exists()) await root.delete(recursive: true);
    }
  });
}
