import 'dart:io';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';

import 'package:fluxora/clash/clash.dart';
import 'package:fluxora/common/common.dart';
import 'package:fluxora/manager/chain_proxy_manager.dart';
import 'package:fluxora/models/chain_proxy.dart';
import 'package:fluxora/models/clash_config.dart';
import 'package:fluxora/models/fixed_proxy_route.dart';
import 'package:fluxora/services/atomic_config_storage.dart';
import 'package:fluxora/state.dart';
import 'package:fluxora/services/fixed_route_probe.dart';
import 'package:path/path.dart' as p;
import 'package:synchronized/synchronized.dart';
import 'package:yaml/yaml.dart';

class FixedProxyRoutes extends ChangeNotifier {
  FixedProxyRoutes({
    Future<Map<String, String>> Function()? readBindings,
    Future<String> Function(String yaml)? validateSnippet,
    Future<Map<String, dynamic>> Function(String profileId)? readProfile,
  }) : _readBindings =
           readBindings ??
           (() => clashCore.clashInterface.getFixedListenerStatus()),
       _validateSnippet = validateSnippet,
       _readProfile = readProfile;

  final Future<Map<String, String>> Function() _readBindings;
  final Future<String> Function(String yaml)? _validateSnippet;
  final Future<Map<String, dynamic>> Function(String profileId)? _readProfile;
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

  bool usesSource(String profileId) =>
      profileId.isNotEmpty &&
      _routes.any((r) => r.enabled && r.hops.any((h) => h.source == profileId));

  Future<void> refreshBindings() => _bindingLock.synchronized(() async {
    final request = _bindingRequest;
    final session = globalState.startTime;
    if (session == null) return;
    if (!routes.any((r) => r.enabled)) {
      if (_bindings.isNotEmpty || _bindingSession != session) {
        _bindings = {};
        _bindingSession = session;
        notifyListeners();
      }
      return;
    }
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

  Future<void> retry(int port) async {
    await load();
    final route = _routes.firstWhereOrNull((r) => r.port == port && r.enabled);
    if (route == null) return;
    if (!globalState.isStart) {
      await change(previousPort: port, route: route);
      return;
    }
    await _lock.synchronized(() async {
      await globalState.appController.applyProfile(silence: true);
      await refreshBindings();
    });
  }

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

  static Object? _toPlainYaml(Object? value) {
    if (value is YamlMap) {
      return {
        for (final entry in value.entries)
          entry.key.toString(): _toPlainYaml(entry.value),
      };
    }
    if (value is YamlList) {
      return [for (final item in value) _toPlainYaml(item)];
    }
    return value;
  }

  static bool _isUsableCatalogProxy(Map proxy) {
    final name = proxy['name'];
    final type = proxy['type'];
    final hasEndpoint =
        proxy['server'] != null ||
        (proxy['peers'] is List && (proxy['peers'] as List).isNotEmpty);
    return name is String &&
        type is String &&
        hasEndpoint &&
        ChainProxyConfig.isSelectableProxy(name: name, type: type);
  }

  static Map<String, dynamic> _normalizeProxy(
    Map proxy,
    Object? globalFingerprint,
  ) {
    final map = Map<String, dynamic>.from(proxy);
    final type = map['type']?.toString().toLowerCase();
    final isTls = map['tls'] == true;
    final supportsFp =
        type == 'trojan' ||
        type == 'anytls' ||
        ((type == 'vmess' || type == 'vless') && isTls);
    if (supportsFp &&
        globalFingerprint != null &&
        map['client-fingerprint'] == null) {
      map['client-fingerprint'] = globalFingerprint;
    }
    final realityOpts = map['reality-opts'];
    if (realityOpts is Map) {
      final shortId = realityOpts['short-id'];
      if (shortId is int) {
        map['reality-opts'] = Map<String, dynamic>.from(realityOpts)
          ..['short-id'] = shortId.toString();
      }
    }
    return map;
  }

  Future<void> _collectProviderProxies(
    String profileId,
    Map raw,
    Object? globalFingerprint,
    Map<FixedHop, Map> nodes,
  ) async {
    final providers = raw['proxy-providers'];
    if (providers is! Map || providers.isEmpty) return;
    String? homeDir;
    for (final entry in providers.entries) {
      final provider = entry.value;
      if (provider is! Map) continue;
      final type = provider['type']?.toString().toLowerCase();
      final override = provider['override'];
      final prefix = override is Map
          ? override['additional-prefix']?.toString() ?? ''
          : '';
      final suffix = override is Map
          ? override['additional-suffix']?.toString() ?? ''
          : '';
      List? rawProxies;
      try {
        if (type == 'inline' && provider['payload'] is List) {
          rawProxies = provider['payload'] as List;
        } else {
          String? filePath;
          if (type == 'http' && provider['url'] is String) {
            final url = (provider['url'] as String).trim();
            if (url.isNotEmpty) {
              filePath = await appPath.getProvidersFilePath(
                profileId,
                'proxies',
                url,
              );
            }
          } else if (type == 'file' && provider['path'] is String) {
            final rawPath = (provider['path'] as String).trim();
            if (rawPath.isNotEmpty) {
              if (p.isAbsolute(rawPath)) {
                filePath = rawPath;
              } else {
                homeDir ??= await appPath.homeDirPath;
                filePath = p.join(homeDir, rawPath);
              }
            }
          }
          if (filePath != null) {
            final file = File(filePath);
            if (await file.exists()) {
              final loaded = _toPlainYaml(loadYaml(await file.readAsString()));
              if (loaded is Map && loaded['proxies'] is List) {
                rawProxies = loaded['proxies'] as List;
              }
            }
          }
        }
      } catch (e) {
        commonPrint.log(
          'Fixed proxy: could not read provider ${entry.key} in $profileId: $e',
        );
      }
      if (rawProxies == null) continue;
      for (final proxy in rawProxies.whereType<Map>()) {
        if (!_isUsableCatalogProxy(proxy)) continue;
        final normalized = _normalizeProxy(proxy, globalFingerprint);
        final name = '$prefix${normalized['name']}$suffix';
        normalized['name'] = name;
        nodes.putIfAbsent((source: profileId, node: name), () => normalized);
      }
    }
  }

  /// Store references only. Credentials are resolved from their original
  /// subscription or the landing library each time a core config is built.
  Future<Map<FixedHop, Map>> catalog({Set<String>? sources}) async {
    final nodes = <FixedHop, Map>{};
    for (final profile in globalState.config.profiles) {
      if (sources != null && !sources.contains(profile.id)) continue;
      try {
        final raw = await (_readProfile?.call(profile.id) ??
            globalState.getProfileConfig(profile.id));
        final globalFingerprint = raw['global-client-fingerprint'];
        for (final proxy in (raw['proxies'] as List? ?? []).whereType<Map>()) {
          if (_isUsableCatalogProxy(proxy)) {
            final normalized = _normalizeProxy(proxy, globalFingerprint);
            nodes[(source: profile.id, node: normalized['name'] as String)] =
                normalized;
          }
        }
        await _collectProviderProxies(
          profile.id,
          raw,
          globalFingerprint,
          nodes,
        );
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
      final proxyCount = (config['proxies'] as List?)?.length ?? 0;
      final issue = route.attach(config, nodes);
      if (issue == null) {
        paths[route.port] = const DeepCollectionEquality().hash([
          ...route.hops,
          ...(config['proxies'] as List).skip(proxyCount),
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

  Future<Map<String, dynamic>> _buildPreviewConfig() async {
    final patch = globalState.config.patchClashConfig;
    final preview = Map<String, dynamic>.from(patch.toJson());
    preview['dns'] = patch.dns.toJson();
    preview['tunnels'] = [for (final t in patch.tunnels) t.toClashJson()];
    if (globalState.hasAppController) {
      preview['mixed-port'] = globalState.appController.effectiveMixedPort;
    }
    final prefs = preferences.sharedPreferencesCompleter.isCompleted
        ? await preferences.sharedPreferencesCompleter.future
        : null;
    final forceLoopback = prefs?.getBool('force_loopback_controller') ?? true;
    preview['external-controller'] = resolveExternalControllerValue(
      configured: patch.externalController,
      forceLoopback: forceLoopback,
      sessionController: globalState.sessionExternalController,
      allowLan: patch.allowLan,
    );
    return preview;
  }

  Future<void> _validatePreviewRoute(Map<String, dynamic> preview) async {
    final validator =
        _validateSnippet ??
        (globalState.hasAppController &&
                clashCore.clashInterface.hasLiveProcess
            ? (String yaml) async => await clashCore.validateConfig(yaml)
            : null);
    if (validator == null) return;
    final copies = [
      for (final proxy in (preview['proxies'] as List? ?? const []).whereType<Map>())
        Map<String, dynamic>.from(proxy)..remove('fluxora-private'),
    ];
    final snippet = await encodeCompactYamlTask({
      'mode': 'rule',
      'proxies': copies,
      'listeners': preview['listeners'],
    });
    final message = await validator(snippet);
    if (message.isNotEmpty) {
      throw StateError(message);
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
      final hadIssue =
          old != null && old.enabled && issueFor(old.port) != null;
      final reload =
          (!(samePath && old.enabled == route.enabled) || hadIssue) &&
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
          final preview = await _buildPreviewConfig();
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
          if (!globalState.isStart) {
            await _validatePreviewRoute(preview);
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
        if (!running) {
          if (previousPort != null) {
            issues.remove(previousPort);
            _paths.remove(previousPort);
          }
          if (route != null) {
            issues.remove(route.port);
            if (!route.enabled) _paths.remove(route.port);
          }
        }
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
