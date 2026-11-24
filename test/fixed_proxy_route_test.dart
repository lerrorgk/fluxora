import 'dart:convert';

import 'package:fluxora/models/fixed_proxy_route.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const front = (source: 'sub-A', node: 'Tokyo');
  const exit = (source: '', node: 'residential');
  final nodes = {
    front: {
      'name': 'Tokyo',
      'type': 'http',
      'server': 'front',
      'dialer-proxy': 'GLOBAL',
    },
    exit: {'name': 'exit', 'type': 'socks5', 'server': 'exit'},
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
      expect(nodes[front]!['dialer-proxy'], 'GLOBAL');
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
}
