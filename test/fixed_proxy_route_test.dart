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
