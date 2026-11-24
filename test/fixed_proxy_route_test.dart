import 'dart:convert';
import 'dart:io';

import 'package:fluxora/manager/chain_proxy_manager.dart';
import 'package:fluxora/manager/fixed_proxy_routes.dart';
import 'package:fluxora/models/chain_proxy.dart';
import 'package:fluxora/models/clash_config.dart';
import 'package:fluxora/models/config.dart';
import 'package:fluxora/models/fixed_proxy_route.dart';
import 'package:fluxora/models/profile.dart';
import 'package:fluxora/state.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
// ignore: depend_on_referenced_packages
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class _FakePathProviderPlatform extends Fake
    with MockPlatformInterfaceMixin
    implements PathProviderPlatform {
  _FakePathProviderPlatform(this.dir);
  final Directory dir;
  @override
  Future<String?> getTemporaryPath() async => dir.path;
  @override
  Future<String?> getApplicationSupportPath() async => dir.path;
  @override
  Future<String?> getLibraryPath() async => dir.path;
  @override
  Future<String?> getApplicationDocumentsPath() async => dir.path;
  @override
  Future<String?> getExternalStoragePath() async => dir.path;
  @override
  Future<List<String>?> getExternalCachePaths() async => [dir.path];
  @override
  Future<List<String>?> getExternalStoragePaths({
    StorageDirectory? type,
  }) async => [dir.path];
  @override
  Future<String?> getDownloadsPath() async => dir.path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory sandbox;
  setUpAll(() {
    sandbox = Directory.systemTemp.createTempSync('fluxora_fixed_route_test_');
    PathProviderPlatform.instance = _FakePathProviderPlatform(sandbox);
  });
  tearDownAll(() async {
    try {
      await sandbox.delete(recursive: true);
    } catch (_) {}
  });
  const front = (source: 'sub-A', node: 'Tokyo');
  const exit = (source: '', node: 'residential');
  final nodes = {
    front: {
      'name': 'Tokyo',
      'type': 'http',
      'server': 'front',
      'dialer-proxy': 'DIRECT',
    },
    exit: {
      'name': 'exit',
      'type': 'socks5',
      'server': 'exit',
      'dialer-proxy': 'GLOBAL',
    },
  };

  test(
    'legacy ports stay enabled and disabled ports do not create listeners',
    () {
      final legacy = FixedProxyRoute.fromJson({
        'port': 23001,
        'hops': [
          {'source': 'sub-A', 'node': 'Tokyo'},
        ],
      });
      expect(legacy.name, isEmpty);
      expect(legacy.enabled, isTrue);
      final disabled = FixedProxyRoute(
        legacy.port,
        legacy.hops,
        name: 'Browser',
        enabled: false,
      );
      final restored = FixedProxyRoute.fromJson(disabled.toJson());
      final raw = <String, dynamic>{};
      expect(restored.name, 'Browser');
      expect(restored.enabled, isFalse);
      expect(restored.attach(raw, {}), isNull);
      expect(raw, isEmpty);
    },
  );

  test(
    'each listener fixes its own exit and ordered hops across a save/load',
    () {
      final config = <String, dynamic>{
        'rules': ['MATCH,main'],
      };
      for (final route in [
        const FixedProxyRoute(25001, [front]),
        const FixedProxyRoute(25002, [front, exit]),
      ]) {
        final restored = FixedProxyRoute.fromJson(
          jsonDecode(jsonEncode(route.toJson())),
        );
        expect(restored.attach(config, nodes), isNull);
      }
      final proxies = config['proxies'] as List;
      final listeners = config['listeners'] as List;
      expect(proxies[0]['dialer-proxy'], isNull);
      expect(proxies[1]['dialer-proxy'], isNull);
      expect(proxies[2]['dialer-proxy'], proxies[1]['name']);
      expect(proxies.every((p) => p['fluxora-private'] == true), isTrue);
      expect(listeners[0]['proxy'], proxies[0]['name']);
      expect(listeners[1]['proxy'], proxies[2]['name']);
      expect(listeners.every((l) => l['listen'] == '127.0.0.1'), isTrue);
      expect(nodes[front]!['dialer-proxy'], 'DIRECT');
      expect(nodes[exit]!['dialer-proxy'], 'GLOBAL');
      expect(config['rules'], ['MATCH,main']);
    },
  );

  test('pins the first node’s subscription dialers ahead of explicit hops', () {
    const bridge = (source: 'sub-A', node: 'bridge');
    const entry = (source: 'sub-A', node: 'entry');
    final catalog = {
      ...nodes,
      front: {...nodes[front]!, 'dialer-proxy': 'bridge'},
      bridge: {'name': 'bridge', 'server': 'bridge-a', 'dialer-proxy': 'entry'},
      entry: {'name': 'entry', 'server': 'entry-a'},
      (source: 'sub-B', node: 'bridge'): {
        'name': 'bridge',
        'server': 'bridge-b',
      },
      exit: {...nodes[exit]!, 'dialer-proxy': 'overridden-by-explicit-hop'},
    };
    final config = <String, dynamic>{};
    expect(
      const FixedProxyRoute(25001, [front, exit]).attach(config, catalog),
      isNull,
    );
    final copies = (config['proxies'] as List).cast<Map>();
    expect(copies.map((p) => p['server']), [
      'entry-a',
      'bridge-a',
      'front',
      'exit',
    ]);
    expect(copies.every((p) => p['fluxora-private'] == true), isTrue);
    expect(copies.first['dialer-proxy'], isNull);
    for (var i = 1; i < copies.length; i++) {
      expect(copies[i]['dialer-proxy'], copies[i - 1]['name']);
    }
    expect((config['listeners'] as List).single['proxy'], copies.last['name']);
    expect(catalog[front]!['dialer-proxy'], 'bridge');
  });

  test('missing and circular subscription dialers leave no partial route', () {
    const gateway = (source: 'sub-A', node: 'bridge');
    final catalog = {
      ...nodes,
      front: {...nodes[front]!, 'dialer-proxy': 'bridge'},
      (source: 'sub-B', node: 'bridge'): {'name': 'bridge'},
    };
    const route = FixedProxyRoute(25001, [front]);
    final config = <String, dynamic>{};
    expect(route.attach(config, catalog), contains('bridge'));
    expect(config, isEmpty);
    catalog[gateway] = {'name': 'bridge', 'dialer-proxy': 'Tokyo'};
    expect(route.attach(config, catalog), contains('Circular'));
    expect(config, isEmpty);
    catalog[front] = {...nodes[front]!, 'dialer-proxy': 'GLOBAL'};
    expect(route.attach(config, catalog), contains('GLOBAL'));
    expect(config, isEmpty);
  });

  test(
    'missing or same-name node from a different source cannot partially attach',
    () {
      final config = <String, dynamic>{};
      const missing = (source: 'sub-B', node: 'Tokyo');
      expect(
        const FixedProxyRoute(25001, [front, missing]).attach(config, nodes),
        isNotNull,
      );
      expect(config, isEmpty);
    },
  );

  test('reserved ports and colliding names leave the config untouched', () {
    for (final config in <Map<String, dynamic>>[
      {
        'dns': {'listen': '127.0.0.1:25001'},
      },
      {
        'tunnels': [
          {'address': '127.0.0.1:25001', 'target': '1.1.1.1:53'},
        ],
      },
      {
        'tunnels': ['tcp/udp,127.0.0.1:25001,1.1.1.1:53,DIRECT'],
      },
      {
        'listeners': [
          {'port': '25000-25005,26000'},
        ],
      },
      {'mixed-port': 25001},
      {
        'proxy-groups': [
          {'name': 'fluxora-fixed-25001-hop-1'},
        ],
      },
    ]) {
      final before = jsonEncode(config);
      expect(
        const FixedProxyRoute(25001, [front]).attach(config, nodes),
        isNotNull,
      );
      expect(jsonEncode(config), before);
    }
  });

  test(
    'stopped preview rejects DNS/controller ports, snippet errors and clears stale issues',
    () async {
      globalState.startTime = null;
      globalState.config = Config(
        themeProps: defaultThemeProps,
        patchClashConfig: const ClashConfig(
          dns: Dns(enable: true, listen: '0.0.0.0:10053'),
        ),
      );
      const landing = LandingProxy(
        id: 'test-landing',
        name: 'Landing',
        server: '127.0.0.1',
        port: 1080,
      );
      await chainProxyManager.updateConfig(
        (c) => c.copyWith(landingProxies: [landing]),
        reloadCore: false,
      );
      const hop = (source: '', node: 'test-landing');
      final manager = FixedProxyRoutes(validateSnippet: (_) async => '');

      await expectLater(
        manager.change(route: const FixedProxyRoute(10053, [hop])),
        throwsA(isA<StateError>()),
      );
      await expectLater(
        manager.change(route: const FixedProxyRoute(9090, [hop])),
        throwsA(isA<StateError>()),
      );

      final sock = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final freePort = sock.port;
      await sock.close();

      final rejecting = FixedProxyRoutes(
        validateSnippet: (_) async => 'proxy 0: invalid uuid',
      );
      await expectLater(
        rejecting.change(route: FixedProxyRoute(freePort, [hop])),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('invalid uuid'),
          ),
        ),
      );

      manager.issues[freePort] = 'Node unavailable: stale';
      await manager.change(route: FixedProxyRoute(freePort, [hop]));
      expect(manager.issueFor(freePort), isNull);
      expect(manager.usesSource('sub-A'), isFalse);

      await manager.change(
        previousPort: freePort,
        route: FixedProxyRoute(freePort, [const (source: 'sub-A', node: 'X')], enabled: false),
      );
      expect(manager.usesSource('sub-A'), isFalse);
      await manager.change(previousPort: freePort);
    },
  );

  test(
    'catalog normalizes fingerprint/short-id and includes peers WireGuard and inline providers',
    () async {
      globalState.config = Config(
        themeProps: defaultThemeProps,
        profiles: [Profile(id: 'sub-1', autoUpdateDuration: Duration.zero)],
      );
      final manager = FixedProxyRoutes(
        readProfile: (_) async => {
          'global-client-fingerprint': 'chrome',
          'proxies': [
            {
              'name': 'vless-reality',
              'type': 'vless',
              'server': 'example.com',
              'port': 443,
              'tls': true,
              'reality-opts': {'short-id': 123456},
            },
            {
              'name': 'wg-peers',
              'type': 'wireguard',
              'peers': [
                {'server': '198.51.100.1', 'port': 51820},
              ],
            },
          ],
          'proxy-providers': {
            'inline-set': {
              'type': 'inline',
              'override': {'additional-prefix': '[P] '},
              'payload': [
                {
                  'name': 'trojan-1',
                  'type': 'trojan',
                  'server': 'provider.example',
                  'port': 443,
                },
              ],
            },
          },
        },
      );
      final nodes = await manager.catalog(sources: {'sub-1'});
      final vless = nodes[(source: 'sub-1', node: 'vless-reality')]!;
      expect(vless['client-fingerprint'], 'chrome');
      expect((vless['reality-opts'] as Map)['short-id'], '123456');
      expect(nodes[(source: 'sub-1', node: 'wg-peers')], isNotNull);
      final trojan = nodes[(source: 'sub-1', node: '[P] trojan-1')]!;
      expect(trojan['client-fingerprint'], 'chrome');
    },
  );
}
