import 'dart:io';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';

import 'package:fluxora/clash/clash.dart';
import 'package:fluxora/common/common.dart';
import 'package:fluxora/manager/chain_proxy_manager.dart';
import 'package:fluxora/models/chain_proxy.dart';
import 'package:fluxora/models/fixed_proxy_route.dart';
import 'package:fluxora/services/atomic_config_storage.dart';
import 'package:fluxora/state.dart';
import 'package:fluxora/services/fixed_route_probe.dart';
import 'package:path/path.dart' as p;
import 'package:synchronized/synchronized.dart';

class FixedProxyRoutes extends ChangeNotifier {
  FixedProxyRoutes({Future<Map<String, String>> Function()? readBindings})
      : _readBindings = readBindings ?? (() => clashCore.clashInterface.getFixedListenerStatus());

  final Future<Map<String, String>> Function() _readBindings;
  final _lock = Lock();
  final _bindingLock = Lock();
  final _routes = <FixedProxyRoute>[];
  List<FixedProxyRoute> get routes => List.unmodifiable(_routes);
  final issues = <int, String>{};
  Map<String, String> _bindings = {};
  DateTime? _bindingSession;
  int _bindingRequest = 0;
  bool _loaded = false;
  final _reports =
      <int, ({DateTime? session, int? path, FixedRouteReport result})>{};

  FixedRouteReport? lastCheck(int port) {
    final entry = _reports[port];
    if (entry == null ||
        !globalState.isStart ||
        entry.session != globalState.startTime ||
        entry.path != _paths[port] ||
        issueFor(port) != null) {
      return null;
    }
    return entry.result;
  }

  void recordCheck(int port, FixedRouteReport result) {
    _reports[port] = (
      session: globalState.startTime,
      path: _paths[port],
      result: result,
    );
  }

  Map<int, int> _paths = {};
  int? pathSignature(int port) => _paths[port];

  String? issueFor(int port) {
    if (issues.containsKey(port)) return issues[port];
    if (!globalState.isStart) return null;
    final status = _bindingSession == globalState.startTime
        ? _bindings['fluxora-fixed-$port']
        : null;
    if (status == '') return null;
    return status ?? 'Listener binding could not be confirmed';
  }

  Future<void> refreshBindings() => _bindingLock.synchronized(() async {
    final request = _bindingRequest;
    final session = globalState.startTime;
    if (session == null || !routes.any((r) => r.enabled)) return;
    Map<String, String> status = {};
    try {
      status = await _readBindings();
    } catch (e) {
      commonPrint.log('Fixed proxy listener status unavailable: $e');
    }
    if (request != _bindingRequest || session != globalState.startTime) return;
    if (_bindingSession == session && mapEquals(_bindings, status)) return;
    _bindings = status;
    _bindingSession = session;
    _reports.removeWhere((port, _) => issueFor(port) != null);
    notifyListeners();
  });

  Future<AtomicConfigStorage> _storage() async => AtomicConfigStorage(
    p.join(await appPath.homeDirPath, 'fixed_proxy_routes.json'),
  );

  Future<void> load() => _lock.synchronized(() async {
    if (!_loaded) await _readRoutes();
  });

  Future<void> reload() => _lock.synchronized(() async {
    await _readRoutes();
    ++_bindingRequest;
    _bindingSession = null;
    _bindings.clear();
    _paths.clear();
    issues.clear();
    _reports.clear();
    notifyListeners();
  });

  Future<void> _readRoutes() async {
    final storage = await _storage();
    final data = await storage.load();
    List<FixedProxyRoute> routes = [];
    if (data != null) {
      if (data['version'] != 1) {
        throw const FormatException('Unsupported fixed proxy configuration');
      }
      routes = (data['routes'] as List)
          .map((json) => FixedProxyRoute.fromJson(json as Map<String, dynamic>))
          .toList();
      if (routes.map((r) => r.port).toSet().length != routes.length) {
        throw const FormatException('Duplicate fixed proxy port');
      }
    } else if (await File(storage.filePath).exists()) {
      throw const FormatException('Cannot read fixed proxy configuration');
    }
    _routes
      ..clear()
      ..addAll(routes);
    _loaded = true;
  }

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
    final enabled = routes.where((r) => r.enabled).toList();
    final nodes = enabled.isEmpty
        ? <FixedHop, Map>{}
        : await catalog(
            sources: {
              for (final route in enabled)
                for (final hop in route.hops) hop.source,
            },
          );
    final nextIssues = <int, String>{};
    final paths = <int, int>{};
    for (final route in enabled) {
      final issue = route.attach(config, nodes);
      if (issue == null) {
        paths[route.port] = const DeepCollectionEquality().hash([
          for (final hop in route.hops) [hop, nodes[hop]],
        ]);
      } else {
        nextIssues[route.port] = issue;
        commonPrint.log('Fixed proxy ${route.port}: $issue');
      }
    }
    if (!mapEquals(issues, nextIssues) || !mapEquals(_paths, paths)) {
      issues
        ..clear()
        ..addAll(nextIssues);
      _reports.removeWhere(
        (port, check) => !paths.containsKey(port) || paths[port] != check.path,
      );
      _paths = paths;
      notifyListeners();
    }
  }

  Future<void> change({int? previousPort, FixedProxyRoute? route}) async {
    await load();
    await _lock.synchronized(() async {
      final old = _routes.firstWhereOrNull((r) => r.port == previousPort);
      final samePath =
          old != null &&
          route != null &&
          old.port == route.port &&
          const ListEquality<FixedHop>().equals(old.hops, route.hops);
      final reload =
          !(samePath && old.enabled == route.enabled) &&
          (old?.enabled == true || route?.enabled == true);
      final next = [..._routes]..removeWhere((r) => r.port == previousPort);
      if (route != null) {
        if (next.any((r) => r.port == route.port)) {
          throw StateError('Port ${route.port} is already assigned');
        }
        if (route.port < 1 || route.port > 65535 || route.hops.isEmpty) {
          throw const FormatException('Invalid port or empty route');
        }
        if (route.enabled && reload) {
          final nodes = await catalog(
            sources: route.hops.map((h) => h.source).toSet(),
          );
          final preview = Map<String, dynamic>.from(
            globalState.config.patchClashConfig.toJson(),
          );
          final issue = route.attach(preview, nodes);
          if (issue != null) throw StateError(issue);
          if (route.port != previousPort ||
              old?.enabled != true ||
              !globalState.isStart) {
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
        }
        next.add(route);
      }
      next.sort((a, b) => a.port.compareTo(b.port));
      final previous = routes;
      _routes
        ..clear()
        ..addAll(next);
      final running = reload && globalState.isStart;
      try {
        if (running) {
          await globalState.appController.applyProfile(silence: true);
          if (route != null && route.enabled) {
            final issue = issueFor(route.port);
            if (issue != null) throw StateError(issue);
          }
        }
        final storage = await _storage();
        await storage.save({
          'version': 1,
          'routes': [for (final r in next) r.toJson()],
        });
        if (reload) {
          _reports.remove(previousPort);
          _reports.remove(route?.port);
        }
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
      } finally {
        notifyListeners();
      }
    });
  }
}

final fixedProxyRoutes = FixedProxyRoutes();
