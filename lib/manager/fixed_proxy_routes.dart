import 'dart:io';

import 'package:fluxora/common/common.dart';
import 'package:fluxora/manager/chain_proxy_manager.dart';
import 'package:fluxora/models/chain_proxy.dart';
import 'package:fluxora/models/fixed_proxy_route.dart';
import 'package:fluxora/services/atomic_config_storage.dart';
import 'package:fluxora/state.dart';
import 'package:path/path.dart' as p;
import 'package:synchronized/synchronized.dart';

class FixedProxyRoutes {
  final _lock = Lock();
  final _routes = <FixedProxyRoute>[];
  List<FixedProxyRoute> get routes => List.unmodifiable(_routes);
  final issues = <int, String>{};
  bool _loaded = false;

  Future<AtomicConfigStorage> _storage() async => AtomicConfigStorage(
    p.join(await appPath.homeDirPath, 'fixed_proxy_routes.json'),
  );

  Future<void> load() => _lock.synchronized(() async {
    if (_loaded) return;
    final storage = await _storage();
    final data = await storage.load();
    if (data != null) {
      if (data['version'] != 1) {
        throw const FormatException('Unsupported fixed proxy configuration');
      }
      final routes = (data['routes'] as List)
          .map((json) => FixedProxyRoute.fromJson(json as Map<String, dynamic>))
          .toList();
      if (routes.map((r) => r.port).toSet().length != routes.length) {
        throw const FormatException('Duplicate fixed proxy port');
      }
      _routes.addAll(routes);
    } else if (await File(storage.filePath).exists()) {
      throw const FormatException('Cannot read fixed proxy configuration');
    }
    _loaded = true;
  });

  /// Store references only. Credentials are resolved from their original
  /// subscription or the landing library each time a core config is built.
  Future<Map<FixedHop, Map>> catalog({Set<String>? sources}) async {
    final nodes = <FixedHop, Map>{};
    for (final profile in globalState.config.profiles) {
      if (sources != null && !sources.contains(profile.id)) continue;
      try {
        final raw = await globalState.getProfileConfig(profile.id);
        for (final proxy in (raw['proxies'] as List? ?? []).whereType<Map>()) {
          final name = proxy['name'];
          final type = proxy['type'];
          if (name is String &&
              type is String &&
              proxy['server'] != null &&
              ChainProxyConfig.isSelectableProxy(name: name, type: type)) {
            nodes[(source: profile.id, node: name)] = proxy;
          }
        }
      } catch (e) {
        commonPrint.log(
          'Fixed proxy: could not read subscription ${profile.id}: $e',
        );
      }
    }
    for (final landing in chainProxyManager.config.landingProxies) {
      nodes[(source: '', node: landing.id)] = landing.toMihomoProxyMap('');
    }
    return nodes;
  }

  Future<void> apply(Map<String, dynamic> config) async {
    final snapshot = routes;
    issues.clear();
    if (snapshot.isEmpty) return;
    final nodes = await catalog(
      sources: {
        for (final route in snapshot)
          for (final hop in route.hops) hop.source,
      },
    );
    for (final route in snapshot) {
      final issue = route.attach(config, nodes);
      if (issue != null) {
        issues[route.port] = issue;
        commonPrint.log('Fixed proxy ${route.port}: $issue');
      }
    }
  }

  Future<void> change({int? previousPort, FixedProxyRoute? route}) async {
    await load();
    await _lock.synchronized(() async {
      final next = [..._routes]..removeWhere((r) => r.port == previousPort);
      if (route != null) {
        if (next.any((r) => r.port == route.port)) {
          throw StateError('Port ${route.port} is already assigned');
        }
        final nodes = await catalog(
          sources: route.hops.map((h) => h.source).toSet(),
        );
        final preview = Map<String, dynamic>.from(
          globalState.config.patchClashConfig.toJson(),
        );
        final issue = route.attach(preview, nodes);
        if (issue != null) throw StateError(issue);
        if (route.port != previousPort || !globalState.isStart) {
          final socket = await ServerSocket.bind(
            InternetAddress.loopbackIPv4,
            route.port,
          );
          try {
            if ((preview['listeners'] as List).last['udp'] == true) {
              final udp = await RawDatagramSocket.bind(
                InternetAddress.loopbackIPv4,
                route.port,
              );
              udp.close();
            }
          } finally {
            await socket.close();
          }
        }
        next.add(route);
      }
      next.sort((a, b) => a.port.compareTo(b.port));
      final previous = routes;
      _routes
        ..clear()
        ..addAll(next);
      final running = globalState.isStart;
      try {
        if (running) {
          await globalState.appController.applyProfile(silence: true);
          final issue = issues[route?.port];
          if (issue != null) throw StateError(issue);
        }
        final storage = await _storage();
        await storage.save({
          'version': 1,
          'routes': [for (final r in next) r.toJson()],
        });
      } catch (error) {
        _routes
          ..clear()
          ..addAll(previous);
        if (running) {
          try {
            await globalState.appController.applyProfile(silence: true);
          } catch (restoreError) {
            throw StateError(
              'Could not apply fixed ports: $error. Could not restore previous configuration: $restoreError',
            );
          }
        }
        rethrow;
      }
    });
  }
}

final fixedProxyRoutes = FixedProxyRoutes();
