import 'dart:io';

import 'package:fluxora/common/common.dart';
import 'package:fluxora/controller.dart';
import 'package:fluxora/models/models.dart';
import 'package:fluxora/providers/app.dart';
import 'package:fluxora/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() {
    globalState.appState = AppState(
      viewSize: const Size(800, 600),
      brightness: Brightness.light,
      requests: FixedList(10),
      version: 1,
      logs: FixedList(10),
      traffics: FixedList(10),
      totalTraffic: Traffic(),
      systemUiOverlayStyle: const SystemUiOverlayStyle(),
    );
  });

  Future<AppController> mountController(WidgetTester tester) async {
    late AppController controller;
    await tester.pumpWidget(
      ProviderScope(
        child: Consumer(
          builder: (context, ref, _) {
            controller = AppController(context, ref);
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    return controller;
  }

  testWidgets('刷新期间保留已有地址，完成后结果可供首页读取', (tester) async {
    final controller = await mountController(tester);
    globalState.appState = globalState.appState.copyWith(
      localIp: '192.168.1.2',
    );
    final container = ProviderScope.containerOf(controller.context);
    final subscription = container.listen(localIpProvider, (_, _) {});
    addTearDown(subscription.close);

    await tester.runAsync(() async {
      final refresh = controller.updateLocalIp();
      expect(container.read(localIpProvider), '192.168.1.2');
      await refresh;
      expect(container.read(localIpProvider), isNotNull);
      expect(container.read(localIpProvider), globalState.appState.localIp);
    });
  });

  testWidgets('查询过程中卸载页面，完成后仍保存结果且不访问已释放的 ref', (tester) async {
    final controller = await mountController(tester);
    await tester.runAsync(() async {
      final refresh = controller.updateLocalIp();
      await tester.pumpWidget(const SizedBox.shrink());
      await refresh;
    });
    expect(globalState.appState.localIp, isNotNull);
    expect(tester.takeException(), isNull);
  });

  test('启动时主动查询内网地址，不等待网络变化事件或内核初始化', () {
    final application = File('lib/application.dart').readAsStringSync();
    final startup = application.substring(
      application.indexOf('void initState()'),
      application.indexOf('bool get _isForeground'),
    );
    expect(startup, contains('appController.updateLocalIp()'));
    expect(
      startup.indexOf('appController.updateLocalIp()'),
      lessThan(startup.indexOf('_initApp()')),
    );
  });
}
