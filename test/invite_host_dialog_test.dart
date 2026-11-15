import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:consent_chat/invite_host.dart';
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
    values[key] = value;
  }
}

void main() {
  testWidgets('server management buttons open their dialogs', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final cache = _MemoryStore();
    cache.values['remote-admin-code'] = 'admin-password-123';
    await tester.pumpWidget(
      InviteHostApp(
        cache: cache,
        bindAddress: InternetAddress.loopbackIPv4,
      ),
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField).first).controller!.text,
      'admin-password-123',
    );

    final port = await tester.runAsync(() async {
      final portProbe =
          await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = portProbe.port;
      await portProbe.close();
      return port;
    });
    await tester.enterText(find.byType(TextField).at(0), 'admin-password-123');
    await tester.enterText(find.byType(TextField).at(1), port!.toString());
    await tester.tap(find.text('启动 HTTPS 服务器'));
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(seconds: 1)));
    await tester.pumpAndSettle();
    expect(cache.value('direct-host-admin-code'), 'admin-password-123');

    for (final label in ['邀请码管理', '客户端管理', '客户端聊天']) {
      await tester.tap(find.text(label).first);
      await tester.pumpAndSettle();
      expect(find.text(label), findsNWidgets(2));
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
    }

    await tester.tap(find.text('邀请码管理'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('批量添加邀请码'));
    await tester.pumpAndSettle();
    final bulkInput = find.byWidgetPredicate(
      (widget) =>
          widget is TextField && widget.decoration?.hintText == '每行一个邀请码',
    );
    await tester.enterText(bulkInput, 'optional-demo-code');
    tester.testTextInput.hide();
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加邀请码'));
    await tester.pumpAndSettle();
    expect(find.text('optional-demo-code'), findsOneWidget);

    final searchInput = find.byWidgetPredicate(
      (widget) =>
          widget is TextField &&
          widget.decoration?.labelText == '搜索邀请码、姓名、手机名称或 IP',
    );
    await tester.enterText(searchInput, 'missing');
    await tester.pumpAndSettle();
    expect(find.text('没有符合条件的邀请码。'), findsOneWidget);
    await tester.enterText(searchInput, 'optional-demo-code');
    await tester.pumpAndSettle();
    tester.testTextInput.hide();
    await tester.pumpAndSettle();
    await tester.drag(find.byType(AlertDialog).last, const Offset(0, -180));
    await tester.pumpAndSettle();
    final inviteTile = find.ancestor(
      of: find.text('optional-demo-code').last,
      matching: find.byType(ListTile),
    );
    await tester.ensureVisible(inviteTile);
    await tester.pumpAndSettle();
    await tester.tap(inviteTile);
    await tester.pumpAndSettle();
    expect(find.text('邀请码信息'), findsOneWidget);
    expect(find.text('手机名称'), findsOneWidget);
    expect(find.text('身份证号'), findsNothing);
    await tester.tap(find.text('关闭').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('关闭').last);
    await tester.pumpAndSettle();

    await tester.tap(find.text('停止服务器'));
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField).first).controller!.text,
      'admin-password-123',
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await tester.pumpWidget(
      InviteHostApp(
        cache: cache,
        bindAddress: InternetAddress.loopbackIPv4,
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField).first).controller!.text,
      'admin-password-123',
    );
  });
}
