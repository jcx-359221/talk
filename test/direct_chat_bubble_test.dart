import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:consent_chat/direct_chat.dart';

void main() {
  test('common attachments use specific MIME types', () {
    expect(directMimeTypeForFile('photo.png'), 'image/png');
    expect(directMimeTypeForFile('clip.mp4'), 'video/mp4');
    expect(directMimeTypeForFile('recording.m4a'), 'audio/mp4');
    expect(directMimeTypeForFile('manual.pdf'), 'application/pdf');
    expect(directMimeTypeForFile('notes.txt'), 'text/plain');
    expect(
      directMimeTypeForFile('report.docx'),
      'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    );
  });

  test('video downloads are queued one at a time', () async {
    final transfers = DirectAttachmentDownloads.instance;
    final firstStarted = Completer<void>();
    final releaseFirst = Completer<void>();
    final secondStarted = Completer<void>();
    final startOrder = <String>[];
    final first = transfers.download(
      key: 'queue-test-video-one',
      expectedSize: 1,
      sequential: true,
      download: (_, __) async {
        startOrder.add('first');
        firstStarted.complete();
        await releaseFirst.future;
        return 'first.mp4';
      },
    );
    await firstStarted.future;
    final second = transfers.download(
      key: 'queue-test-video-two',
      expectedSize: 1,
      sequential: true,
      download: (_, __) async {
        startOrder.add('second');
        secondStarted.complete();
        return 'second.mp4';
      },
    );
    await Future<void>.delayed(Duration.zero);
    expect(secondStarted.isCompleted, isFalse);
    expect(startOrder, ['first']);
    releaseFirst.complete();
    await Future.wait([first, second]);
    expect(startOrder, ['first', 'second']);
  });

  test('video uploads are queued one at a time', () async {
    final transfers = DirectVideoUploads.instance;
    final firstStarted = Completer<void>();
    final releaseFirst = Completer<void>();
    final secondStarted = Completer<void>();
    final startOrder = <String>[];
    final first = transfers.enqueue(() async {
      startOrder.add('first');
      firstStarted.complete();
      await releaseFirst.future;
      return 'first';
    });
    await firstStarted.future;
    final second = transfers.enqueue(() async {
      startOrder.add('second');
      secondStarted.complete();
      return 'second';
    });
    await Future<void>.delayed(Duration.zero);
    expect(secondStarted.isCompleted, isFalse);
    expect(startOrder, ['first']);
    releaseFirst.complete();
    await Future.wait([first, second]);
    expect(startOrder, ['first', 'second']);
  });

  test('client expires each local chat record from its own sent timestamp', () {
    final oldSentAt = DateTime.utc(2026, 11, 14, 10);
    final recentSentAt = oldSentAt.add(const Duration(minutes: 25));
    final oldMessage = {
      'created_at': oldSentAt.toIso8601String(),
      'media_id': 'old-media',
    };
    final recentMessage = {
      'created_at': recentSentAt.toIso8601String(),
      'media_id': 'recent-media',
    };
    final pendingMessage = {
      'created_at': oldSentAt.toIso8601String(),
      'media_id': 'pending-media',
      'pending': true,
    };

    expect(
      directMediaCleanupAt(oldMessage),
      oldSentAt.add(const Duration(minutes: 30)),
    );
    expect(
      directMediaCleanupAt(recentMessage),
      recentSentAt.add(const Duration(minutes: 30)),
    );
    expect(directMediaCleanupAt(pendingMessage), isNull);
    expect(
      directMediaCleanupAt({
        'created_at': oldSentAt.toIso8601String(),
      }),
      oldSentAt.add(const Duration(minutes: 30)),
    );
    expect(
      isDirectClientMessageVisible(
        {'created_at': oldSentAt.toIso8601String()},
        now: oldSentAt.add(const Duration(minutes: 29, seconds: 59)),
      ),
      isTrue,
    );
    expect(
      isDirectClientMessageVisible(
        {'created_at': oldSentAt.toIso8601String()},
        now: oldSentAt.add(const Duration(minutes: 30)),
      ),
      isFalse,
    );
  });

  test(
      'message snapshots ignore unfinished remote messages and preserve local media',
      () {
    final old = DateTime.now()
        .toUtc()
        .subtract(const Duration(minutes: 1))
        .toIso8601String();
    final finished = <String, dynamic>{
      'id': 'downloaded-video',
      'created_at': old,
      'sender': 'server',
      'body': '',
      'media_id': 'media-1',
      'mime_type': 'video/mp4',
      'media_path': r'C:\cache\video.mp4',
    };
    final merged = mergeDirectMessageSnapshots(
      localMessages: [finished],
      sentMessages: const [],
      receivedMessages: [
        {
          'id': 'downloaded-video',
          'created_at': old,
          'sender': 'server',
          'body': '',
          'media_id': 'media-1',
          'mime_type': 'video/mp4',
        },
        {
          'id': 'unfinished-server-video',
          'created_at': old,
          'sender': 'server',
          'body': '',
          'pending': true,
        },
      ],
      sendingMessageIds: const {},
    );

    expect(merged, hasLength(1));
    expect(merged.single['media_path'], r'C:\cache\video.mp4');
  });

  test('outgoing videos retain their original local playback path', () {
    final outgoing = <String, dynamic>{
      'sender': 'client',
      'mime_type': 'video/mp4',
      'source_file_path': r'C:\uploads\sent-video.mp4',
      'file_path': r'C:\encrypted\chunks',
      'encrypted_local': true,
    };
    final incoming = <String, dynamic>{
      'sender': 'server',
      'mime_type': 'video/mp4',
      'source_file_path': r'C:\uploads\other-video.mp4',
    };

    expect(directOutgoingVideoPath(outgoing), r'C:\uploads\sent-video.mp4');
    expect(directOutgoingVideoPath(incoming), isNull);
    expect(
      directOutgoingVideoPath({...outgoing, 'mime_type': 'image/jpeg'}),
      isNull,
    );
    final merged = mergeDirectMessageSnapshots(
      localMessages: [
        {
          ...outgoing,
          'id': 'outgoing-video',
          'created_at': DateTime.now()
              .toUtc()
              .subtract(const Duration(minutes: 1))
              .toIso8601String(),
          'pending': true,
        },
      ],
      sentMessages: [
        {
          'id': 'outgoing-video',
          'sender': 'client',
          'mime_type': 'video/mp4',
          'created_at': DateTime.now()
              .toUtc()
              .subtract(const Duration(minutes: 1))
              .toIso8601String(),
          'media_id': 'uploaded-video',
        },
      ],
      receivedMessages: const [],
      sendingMessageIds: const {},
    );
    expect(merged.single['source_file_path'], r'C:\uploads\sent-video.mp4');
  });

  test('media picker covers common video formats with video MIME types', () {
    for (final extension in [
      '3gp',
      'avi',
      'flv',
      'm4v',
      'mkv',
      'mov',
      'mp4',
      'mpeg',
      'mpg',
      'webm',
      'wmv',
    ]) {
      expect(
        directMimeTypeForFile('clip.$extension'),
        startsWith('video/'),
        reason: '$extension should be sent as video',
      );
      expect(directMediaFileExtensions, contains(extension));
    }
  });

  testWidgets('client message bubbles omit timestamps', (tester) async {
    final message = <String, dynamic>{
      'id': 'image-message',
      'created_at': DateTime.utc(2026, 11, 14).toIso8601String(),
      'sender': 'client',
      'body': '',
      'media_id': 'media-1',
      'mime_type': 'image/png',
      'file_name': 'private-photo-name.png',
      'media_size': 3456,
    };
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DirectMessageBubble(
            message: message,
            outgoing: false,
            showTimestamp: false,
            onOpenAttachment: () {},
          ),
        ),
      ),
    );
    expect(find.text('对方'), findsNothing);
    expect(find.byIcon(Icons.north_east), findsNothing);
    expect(find.byIcon(Icons.south_west), findsNothing);
    expect(find.byKey(const ValueKey('message-timestamp-image-message')),
        findsNothing);
    expect(find.byIcon(Icons.image_outlined), findsOneWidget);
    expect(find.text('private-photo-name.png'), findsNothing);
    expect(find.text('3.4 KB'), findsNothing);
    expect(find.byTooltip('下载并打开'), findsOneWidget);
  });

  testWidgets('message bubbles keep timestamps by default', (tester) async {
    final message = <String, dynamic>{
      'id': 'server-timestamp',
      'created_at': DateTime.utc(2026, 11, 14).toIso8601String(),
      'sender': 'server',
      'body': 'message',
    };
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DirectMessageBubble(
            message: message,
            outgoing: false,
            onOpenAttachment: () {},
          ),
        ),
      ),
    );

    expect(
      find.byKey(const ValueKey('message-timestamp-server-timestamp')),
      findsOneWidget,
    );
  });

  testWidgets('text messages do not show upload progress or status icons',
      (tester) async {
    final message = <String, dynamic>{
      'id': 'pending-text',
      'created_at': DateTime.now().toUtc().toIso8601String(),
      'sender': 'client',
      'body': 'plain text',
      'pending': true,
      'delivery_state': 'sending',
      'upload_progress': 68,
    };
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DirectMessageBubble(
            message: message,
            outgoing: true,
            onOpenAttachment: () {},
          ),
        ),
      ),
    );

    expect(find.text('plain text'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('68%'), findsNothing);
    expect(find.text('发送中'), findsNothing);
    expect(
      find.byWidgetPredicate(
        (widget) => widget is Image && widget.image is AssetImage,
      ),
      findsOneWidget,
    );
  });

  testWidgets('visual attachments show preview and download progress',
      (tester) async {
    final message = <String, dynamic>{
      'id': 'preview-image',
      'created_at': DateTime.utc(2026, 11, 14).toIso8601String(),
      'sender': 'server',
      'body': '',
      'media_id': 'media-preview',
      'mime_type': 'image/jpeg',
      'file_name': 'private-photo-name.jpg',
      'media_size': 3456,
      'preview_data':
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a0y8AAAAASUVORK5CYII=',
    };
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DirectMessageBubble(
            message: message,
            outgoing: false,
            onOpenAttachment: () {},
            downloading: true,
            downloadProgress: 42,
          ),
        ),
      ),
    );

    expect(
      find.byWidgetPredicate(
        (widget) => widget is Image && widget.image is MemoryImage,
      ),
      findsOneWidget,
    );
    expect(find.text('private-photo-name.jpg'), findsNothing);
    expect(find.text('42%'), findsOneWidget);
    expect(find.byTooltip('下载并打开'), findsNothing);
  });

  testWidgets('video messages use their thumbnail instead of the video file',
      (tester) async {
    final message = <String, dynamic>{
      'id': 'preview-video',
      'created_at': DateTime.utc(2026, 11, 14).toIso8601String(),
      'sender': 'server',
      'body': '',
      'media_id': 'media-video',
      'media_path': r'C:\videos\clip.mp4',
      'mime_type': 'video/mp4',
      'file_name': 'clip.mp4',
      'media_size': 3456,
      'preview_data':
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a0y8AAAAASUVORK5CYII=',
    };
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DirectMessageBubble(
            message: message,
            outgoing: false,
            onOpenAttachment: () {},
          ),
        ),
      ),
    );

    final image = tester.widget<Image>(
      find.byWidgetPredicate(
        (widget) => widget is Image && widget.image is MemoryImage,
      ),
    );
    expect(image.image, isA<MemoryImage>());
    expect(find.byIcon(Icons.play_arrow), findsOneWidget);
    expect(find.byTooltip('下载并打开'), findsNothing);
  });

  testWidgets('legacy image data is displayed directly', (tester) async {
    final message = <String, dynamic>{
      'id': 'legacy-image',
      'created_at': DateTime.utc(2026, 11, 14).toIso8601String(),
      'sender': 'server',
      'body': '',
      'mime_type': 'image/png',
      'media_data':
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a0y8AAAAASUVORK5CYII=',
    };
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DirectMessageBubble(
            message: message,
            outgoing: false,
            onOpenAttachment: () {},
          ),
        ),
      ),
    );

    expect(
      tester
          .widget<Image>(
            find.byWidgetPredicate(
              (widget) => widget is Image && widget.image is MemoryImage,
            ),
          )
          .image,
      isA<MemoryImage>(),
    );
    expect(find.byTooltip('下载并打开'), findsNothing);
  });

  testWidgets('chat refreshes reuse cached preview image providers',
      (tester) async {
    final message = <String, dynamic>{
      'id': 'cached-image',
      'created_at': DateTime.utc(2026, 11, 14).toIso8601String(),
      'sender': 'server',
      'body': '',
      'mime_type': 'image/png',
      'media_data':
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a0y8AAAAASUVORK5CYII=',
    };

    Widget buildPage() => MaterialApp(
          home: Scaffold(
            body: DirectMessageBubble(
              message: message,
              outgoing: false,
              onOpenAttachment: () {},
            ),
          ),
        );

    await tester.pumpWidget(buildPage());
    final firstImage = tester.widget<Image>(
      find.byWidgetPredicate(
        (widget) => widget is Image && widget.image is MemoryImage,
      ),
    );
    message['body'] = 'updated';
    await tester.pumpWidget(buildPage());
    final refreshedImage = tester.widget<Image>(
      find.byWidgetPredicate(
        (widget) => widget is Image && widget.image is MemoryImage,
      ),
    );

    expect(identical(firstImage.image, refreshedImage.image), isTrue);
  });

  test('attachment downloads are shared across chat windows', () async {
    final key = 'download-sharing-${DateTime.now().microsecondsSinceEpoch}';
    final directory = await Directory.systemTemp.createTemp();
    final output = File('${directory.path}\\attachment.bin');
    final completed = Completer<String>();
    var started = 0;
    var observedProgress = -1;

    Future<String> startDownload(ValueChanged<int> onProgress) =>
        DirectAttachmentDownloads.instance.download(
          key: key,
          expectedSize: 4,
          onProgress: onProgress,
          download: (progress, isCancelled) {
            started++;
            progress(35);
            return completed.future;
          },
        );

    try {
      final first = startDownload((_) {});
      final second = startDownload((progress) => observedProgress = progress);
      await Future<void>.delayed(Duration.zero);
      expect(started, 1);
      expect(observedProgress, 35);

      await output.writeAsBytes([1, 2, 3, 4]);
      completed.complete(output.path);
      expect(await first, output.path);
      expect(await second, output.path);
      expect(
        await DirectAttachmentDownloads.instance.download(
          key: key,
          expectedSize: 4,
          download: (_, __) async {
            started++;
            return output.path;
          },
        ),
        output.path,
      );
      expect(started, 1);
    } finally {
      await directory.delete(recursive: true);
    }
  });

  testWidgets('active downloads expose a cancel action', (tester) async {
    var cancelled = false;
    final message = <String, dynamic>{
      'id': 'download-to-cancel',
      'created_at': DateTime.utc(2026, 11, 14).toIso8601String(),
      'sender': 'client',
      'body': '',
      'media_id': 'media-cancel',
      'mime_type': 'application/pdf',
      'file_name': 'report.pdf',
      'media_size': 2048,
    };
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DirectMessageBubble(
            message: message,
            outgoing: false,
            downloading: true,
            downloadProgress: 42,
            onOpenAttachment: () {},
            onCancelDownload: () => cancelled = true,
          ),
        ),
      ),
    );

    expect(find.text('42%'), findsOneWidget);
    await tester.tap(find.byTooltip('取消下载'));
    expect(cancelled, isTrue);
  });

  testWidgets('attachment uploads show progress but sent messages do not',
      (tester) async {
    final message = <String, dynamic>{
      'id': 'outgoing-message',
      'created_at': DateTime.utc(2026, 11, 14).toIso8601String(),
      'sender': 'client',
      'body': 'hello',
      'file_name': 'voice.m4a',
      'mime_type': 'audio/mp4',
      'pending': true,
      'upload_progress': 42,
      'delivery_state': 'uploading',
    };
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DirectMessageBubble(
            message: message,
            outgoing: true,
            onOpenAttachment: () {},
          ),
        ),
      ),
    );
    expect(find.text('上传中 42%'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);

    message
      ..['pending'] = false
      ..['sent'] = true;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DirectMessageBubble(
            message: message,
            outgoing: true,
            onOpenAttachment: () {},
          ),
        ),
      ),
    );
    expect(find.text('已发送'), findsNothing);
    expect(find.text('上传中 42%'), findsNothing);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.byIcon(Icons.check_circle), findsNothing);
  });

  testWidgets('pending video upload displays a progress bar', (tester) async {
    final message = <String, dynamic>{
      'id': 'upload-to-cancel',
      'created_at': DateTime.utc(2026, 11, 14).toIso8601String(),
      'sender': 'client',
      'body': '',
      'file_name': 'video.mp4',
      'mime_type': 'video/mp4',
      'pending': true,
      'upload_progress': 25,
      'delivery_state': 'uploading',
    };
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DirectMessageBubble(
            message: message,
            outgoing: true,
            onOpenAttachment: () {},
          ),
        ),
      ),
    );

    expect(find.text('上传中 25%'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
  });

  testWidgets('each selected video displays its own upload progress',
      (tester) async {
    final messages = [
      for (var index = 0; index < 2; index++)
        <String, dynamic>{
          'id': 'video-$index',
          'created_at': DateTime.utc(2026, 11, 14).toIso8601String(),
          'sender': 'client',
          'body': '',
          'pending': true,
          'delivery_state': 'uploading',
          'upload_progress': index == 0 ? 25 : 70,
          'file_name': 'video-$index.mp4',
          'mime_type': 'video/mp4',
        },
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            children: [
              for (final message in messages)
                DirectMessageBubble(
                  message: message,
                  outgoing: true,
                  onOpenAttachment: () {},
                ),
            ],
          ),
        ),
      ),
    );

    expect(find.byType(LinearProgressIndicator), findsNWidgets(2));
    expect(find.text('上传中 25%'), findsOneWidget);
    expect(find.text('上传中 70%'), findsOneWidget);
  });

  testWidgets('attachment preparation shows progress before upload starts',
      (tester) async {
    final message = <String, dynamic>{
      'id': 'preparing-video',
      'created_at': DateTime.utc(2026, 11, 14).toIso8601String(),
      'sender': 'client',
      'body': '',
      'pending': true,
      'delivery_state': 'preparing',
      'prepare_progress': 35,
      'file_name': 'clip.mp4',
      'mime_type': 'video/mp4',
    };
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DirectMessageBubble(
            message: message,
            outgoing: true,
            onOpenAttachment: () {},
          ),
        ),
      ),
    );

    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.text('准备中 35%'), findsOneWidget);
  });

  testWidgets('queued attachment remains at zero progress', (tester) async {
    final message = <String, dynamic>{
      'id': 'queued-video',
      'created_at': DateTime.utc(2026, 11, 14).toIso8601String(),
      'sender': 'client',
      'body': '',
      'pending': true,
      'delivery_state': 'queued',
      'upload_progress': 0,
      'file_name': 'queued.mp4',
      'mime_type': 'video/mp4',
    };
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DirectMessageBubble(
            message: message,
            outgoing: true,
            onOpenAttachment: () {},
          ),
        ),
      ),
    );

    expect(find.text('排队中 0%'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(
      tester
          .widget<LinearProgressIndicator>(
            find.byType(LinearProgressIndicator),
          )
          .value,
      0,
    );
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('queued text messages stay quiet without progress UI',
      (tester) async {
    final message = <String, dynamic>{
      'id': 'queued-message',
      'created_at': DateTime.utc(2026, 11, 14).toIso8601String(),
      'sender': 'client',
      'body': 'offline message',
      'pending': true,
      'delivery_state': 'queued',
      'upload_progress': 0,
    };
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DirectMessageBubble(
            message: message,
            outgoing: true,
            onOpenAttachment: () {},
          ),
        ),
      ),
    );
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('已发送'), findsNothing);
  });

  testWidgets('failed attachments expose retry and keep their card visible',
      (tester) async {
    var retried = false;
    var cancelled = false;
    final message = <String, dynamic>{
      'id': 'failed-attachment',
      'created_at': DateTime.utc(2026, 11, 14).toIso8601String(),
      'sender': 'client',
      'file_name': 'large-video.mp4',
      'mime_type': 'video/mp4',
      'media_size': 2 * 1024 * 1024 * 1024,
      'file_path': r'C:\pending\large-video.mp4',
      'pending': true,
      'delivery_state': 'failed',
    };
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DirectMessageBubble(
            message: message,
            outgoing: true,
            onOpenAttachment: () {},
            onRetry: () => retried = true,
            onCancel: () => cancelled = true,
          ),
        ),
      ),
    );
    expect(find.textContaining('large-video.mp4'), findsOneWidget);
    expect(find.textContaining('2 GB'), findsOneWidget);
    expect(find.byIcon(Icons.close), findsOneWidget);
    await tester.tap(find.byTooltip('删除待发送附件'));
    expect(cancelled, isTrue);
    await tester.tap(find.text('重发'));
    expect(retried, isTrue);
  });

  testWidgets('audio attachments use the in-chat play action', (tester) async {
    var opened = false;
    final message = <String, dynamic>{
      'id': 'voice-message',
      'created_at': DateTime.utc(2026, 11, 14).toIso8601String(),
      'sender': 'client',
      'file_name': 'voice.m4a',
      'mime_type': 'audio/mp4',
      'media_size': 1024,
      'media_id': 'voice-media',
    };
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DirectMessageBubble(
            message: message,
            outgoing: true,
            onOpenAttachment: () => opened = true,
          ),
        ),
      ),
    );

    await tester.tap(find.byTooltip('播放语音'));
    expect(opened, isTrue);
  });
}
