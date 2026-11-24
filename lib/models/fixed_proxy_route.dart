/// A hop is identified within its subscription. Saved landing nodes use an
/// empty source and their persistent ID rather than their editable display name.
typedef FixedHop = ({String source, String node});

class FixedProxyRoute {
  const FixedProxyRoute(
    this.port,
    this.hops, {
    this.name = '',
    this.enabled = true,
  });
  final String name;
  final bool enabled;

  FixedProxyRoute withEnabled(bool value) =>
      FixedProxyRoute(port, hops, name: name, enabled: value);
  final int port;
  final List<FixedHop> hops;

  factory FixedProxyRoute.fromJson(Map<String, dynamic> json) =>
      FixedProxyRoute(
        json['port'] as int,
        [
          for (final hop in json['hops'] as List)
            (source: hop['source'] as String, node: hop['node'] as String),
        ],
        name: json['name'] as String? ?? '',
        enabled: json['enabled'] as bool? ?? true,
      );

  Map<String, dynamic> toJson() => {
    'port': port,
    'name': name,
    'enabled': enabled,
    'hops': [
      for (final hop in hops) {'source': hop.source, 'node': hop.node},
    ],
  };

  String get listener => 'fluxora-fixed-$port';

  /// Upstream subscription dialer hops required by the first explicit hop,
  /// ordered from outermost entry to immediate dialer.
  ({List<FixedHop> dialers, String? error}) resolveDialers(
    Map<FixedHop, Map> nodes,
  ) {
    if (hops.isEmpty) return (dialers: const [], error: 'Invalid route');
    final dialers = <FixedHop>{};
    var entry = hops.first;
    while (entry.source.isNotEmpty) {
      final raw = nodes[entry]?['dialer-proxy'];
      final dialer = raw?.toString().trim() ?? '';
      if (dialer.isEmpty || dialer == 'DIRECT') {
        break;
      }
      final upstream = (source: entry.source, node: dialer);
      if (!nodes.containsKey(upstream)) {
        return (
          dialers: const [],
          error:
              'Dialer "$dialer" for "${entry.node}" is not a node in its subscription',
        );
      }
      if (upstream == hops.first || !dialers.add(upstream)) {
        return (
          dialers: const [],
          error: 'Circular dialer dependency: $dialer',
        );
      }
      entry = upstream;
    }
    return (dialers: dialers.toList().reversed.toList(), error: null);
  }

  /// Add the whole route or none of it. Missing hops never fall through to
  /// the main selector. Original proxy objects are left untouched.
  String? attach(Map<String, dynamic> config, Map<FixedHop, Map> nodes) {
    if (!enabled) return null;
    if (port < 1 || port > 65535 || hops.isEmpty) return 'Invalid route';
    final listeners = (config['listeners'] as List?) ?? const [];
    final tunnels = (config['tunnels'] as List?) ?? const [];
    final occupied = [
      for (final key in [
        'port',
        'mixed-port',
        'socks-port',
        'redir-port',
        'tproxy-port',
      ])
        config[key],
      for (final key in ['external-controller', 'external-controller-tls'])
        config[key]?.toString().split(':').last,
      if (config['dns'] is Map && config['dns']['enable'] != false)
        config['dns']['listen']?.toString().split(':').last,
      for (final inbound in listeners.whereType<Map>()) inbound['port'],
      for (final tunnel in tunnels) _tunnelPort(tunnel),
    ];
    if (occupied.any(_includesPort)) return 'Port $port is already in use';
    if (listeners.whereType<Map>().any((l) => l['name'] == listener)) {
      return 'Listener name already in use: $listener';
    }
    final proxies = (config['proxies'] as List?) ?? const [];
    final names = {
      for (final p in [
        ...proxies,
        ...?config['proxy-groups'] as List?,
      ].whereType<Map>())
        p['name'],
    };
    // The first subscription node may itself need a specific upstream to
    // reach its server. Pin those nodes from the same subscription as well.
    // Later explicit hops use the preceding hop chosen in the route editor.
    final resolved = resolveDialers(nodes);
    if (resolved.error != null) return resolved.error;
    final copies = <Map<String, dynamic>>[];
    for (final hop in [...resolved.dialers, ...hops]) {
      final node = nodes[hop];
      if (node == null) return 'Node unavailable: ${hop.node}';
      final name = '$listener-hop-${copies.length + 1}';
      if (names.contains(name)) return 'Proxy name already in use: $name';
      final copy = Map<String, dynamic>.from(node)
        ..remove('dialer-proxy')
        ..['name'] = name
        ..['fluxora-private'] = true;
      if (copies.isNotEmpty) copy['dialer-proxy'] = copies.last['name'];
      copies.add(copy);
    }
    config['proxies'] = [...proxies, ...copies];
    config['listeners'] = [
      ...listeners,
      {
        'name': listener,
        'type': 'mixed',
        'listen': '127.0.0.1',
        'port': port,
        'proxy': copies.last['name'],
        'udp': copies.every((p) => p['udp'] != false),
      },
    ];
    return null;
  }

  Object? _tunnelPort(Object? tunnel) {
    if (tunnel is Map) {
      return tunnel['address']?.toString().split(':').last;
    }
    if (tunnel is String) {
      final parts = tunnel.split(',');
      if (parts.length >= 2) {
        return parts[1].trim().split(':').last;
      }
    }
    return null;
  }

  bool _includesPort(Object? value) {
    for (final item in '$value'.split(',')) {
      final bounds = item.trim().split('-');
      final first = int.tryParse(bounds.first);
      final last = int.tryParse(bounds.last);
      if (first != null && last != null && port >= first && port <= last) {
        return true;
      }
    }
    return false;
  }
}
