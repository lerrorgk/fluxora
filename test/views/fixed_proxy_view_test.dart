import 'dart:async';

import 'package:fluxora/common/common.dart';
import 'package:fluxora/manager/fixed_proxy_routes.dart';
import 'package:fluxora/models/fixed_proxy_route.dart';
import 'package:fluxora/models/models.dart';
import 'package:fluxora/services/fixed_route_probe.dart';
import 'package:fluxora/state.dart';
import 'package:fluxora/views/proxies/fixed_proxy_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const front = (source: 'subscription', node: 'Tokyo 01');
const exit = (source: '', node: 'exit-42');

class _Store extends FixedProxyRoutes {
  @override
  final routes = <FixedProxyRoute>[
    const FixedProxyRoute(20001, [front, exit], name: 'Work browser'),
    const FixedProxyRoute(20002, [front], name: 'Downloads', enabled: false),
  ];
  @override
  Future<void> load() async {}
  @override
  Future<Map<FixedHop, Map>> catalog({Set<String>? sources}) async => {
    front: {'name': 'Tokyo 01'},
    exit: {'name': 'Tokyo residential'},
  };
  @override
  Future<void> change({int? previousPort, FixedProxyRoute? route}) async {
    routes.removeWhere((r) => r.port == previousPort);
    if (route != null) routes.add(route);
    notifyListeners();
  }
}

class _Probe extends FixedRouteProbe {
  _Probe(super.port);
  final done = Completer<FixedRouteReport>();
  @override
  Future<FixedRouteReport> run(
    String url, {
    void Function(FixedRouteReport)? onLatency,
  }) async {
    onLatency?.call(FixedRouteReport(time: DateTime.now(), latencyMs: 47));
    return done.future;
  }
}

void main() {
  late _Store store;
  late _Probe probe;
  setUp(() {
    store = _Store();
    globalState.config = Config(themeProps: defaultThemeProps);
    globalState.startTime = DateTime.now().subtract(const Duration(minutes: 1));
    globalState.appState = AppState(
      viewSize: const Size(820, 850),
      brightness: Brightness.light,
      runTime: 60000,
      requests: FixedList(10),
      version: 1,
      logs: FixedList(10),
      traffics: FixedList(10),
      totalTraffic: Traffic(),
      systemUiOverlayStyle: const SystemUiOverlayStyle(),
    );
  });
  Future<void> open(
    WidgetTester tester, {
    Size size = const Size(820, 850),
  }) async {
    probe = _Probe(20001);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: FixedProxyView(store: store, createProbe: (_) => probe),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'a narrow card shows latency first, then saves the verified exit',
    (tester) async {
      await open(tester, size: const Size(360, 820));
      await tester.tap(find.text('Check all'));
      await tester.pump();
      expect(find.text('47 ms'), findsOneWidget);
      expect(find.text('Looking up exit'), findsOneWidget);
      final time = DateTime.now();
      probe.done.complete(
        FixedRouteReport(
          time: time,
          latencyMs: 47,
          exit: PublicIpInfo(
            ip: '203.0.113.18',
            source: 'test',
            version: IpVersion.v4,
            country: 'Japan',
            timestamp: time,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('203.0.113.18'), findsOneWidget);
      expect(find.text('Reachable'), findsOneWidget);
      expect(store.lastCheck(20002), isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'editing a route preserves its port, accepts a name and reorders hops',
    (tester) async {
      await open(tester);
      await tester.tap(find.byTooltip('Port actions').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Edit port'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField).first, 'Research');
      await tester.tap(find.byTooltip('Hop actions').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Move up'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save port'));
      await tester.pumpAndSettle();
      final updated = store.routes.singleWhere((r) => r.port == 20001);
      expect(updated.name, 'Research');
      expect(updated.hops, [exit, front]);
      expect(tester.takeException(), isNull);
    },
  );
}
