import 'dart:async';

import 'package:fluxora/common/tokens/fluxora_colors.dart';
import 'package:fluxora/manager/fixed_proxy_routes.dart';
import 'package:fluxora/models/fixed_proxy_route.dart';
import 'package:fluxora/providers/providers.dart';
import 'package:fluxora/services/fixed_route_probe.dart';
import 'package:fluxora/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

part 'fixed_route_card.dart';
part 'fixed_route_editor.dart';

typedef _NodeLabel = ({String name, String source});
String _text(BuildContext c, String zh, String en) =>
    Localizations.localeOf(c).languageCode == 'zh' ? zh : en;
String _routeName(BuildContext c, FixedProxyRoute r) =>
    r.name.trim().isEmpty ? _text(c, '入口 ${r.port}', 'Port ${r.port}') : r.name;
const _mono = TextStyle(
  fontFamily: 'JetBrainsMono',
  fontFeatures: [FontFeature.tabularFigures()],
);

class FixedProxyView extends ConsumerStatefulWidget {
  const FixedProxyView({
    super.key,
    this.store,
    this.createProbe = FixedRouteProbe.new,
  });
  final FixedProxyRoutes? store;
  final FixedRouteProbe Function(int) createProbe;
  static String title(BuildContext c) => _text(c, '独立代理', 'Fixed proxies');
  @override
  ConsumerState<FixedProxyView> createState() => _FixedProxyViewState();
}

class _FixedProxyViewState extends ConsumerState<FixedProxyView> {
  late final store = widget.store ?? fixedProxyRoutes;
  Map<FixedHop, _NodeLabel> labels = {};
  final progress = <int, FixedRouteReport>{};
  final active = <int, FixedRouteProbe>{};
  final signatures = <int, int?>{};
  bool busy = true;
  bool batch = false;
  int generation = 0;
  String query = '';
  String? error;

  @override
  void initState() {
    super.initState();
    store.addListener(_changed);
    _load();
  }

  Future<void> _load() async {
    try {
      await store.load();
      final catalog = await store.catalog();
      if (!mounted) return;
      final sources = {
        for (final p in globalState.config.profiles) p.id: p.label ?? p.id,
      };
      labels = {
        for (final e in catalog.entries)
          e.key: (
            name: e.value['name']?.toString() ?? e.key.node,
            source: e.key.source.isEmpty
                ? _text(context, '落地节点', 'Landing nodes')
                : sources[e.key.source] ?? e.key.source,
          ),
      };
      error = null;
    } catch (e) {
      error = e.toString();
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  void _changed() {
    for (final port in active.keys.toList()) {
      if (!store.routes.any((r) => r.port == port && r.enabled) ||
          store.pathSignature(port) != signatures[port] ||
          store.issues.containsKey(port)) {
        _forget(port);
      }
    }
    if (mounted) setState(() {});
  }

  void _forget(int port) {
    active.remove(port)?.cancel();
    progress.remove(port);
    signatures.remove(port);
  }

  void _cancel() {
    generation++;
    batch = false;
    for (final probe in active.values) {
      probe.cancel();
    }
    active.clear();
    signatures.clear();
    progress.clear();
  }

  @override
  void dispose() {
    store.removeListener(_changed);
    _cancel();
    super.dispose();
  }

  Future<void> _change(int? previous, FixedProxyRoute? route) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
      _cancel();
    });
    try {
      await store.change(previousPort: previous, route: route);
    } catch (e) {
      error = e.toString();
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _edit([FixedProxyRoute? original]) async {
    var port = 20001;
    final used = store.routes.map((r) => r.port).toSet();
    while (used.contains(port) && port < 65535) {
      port++;
    }
    final r = await showDialog<FixedProxyRoute>(
      context: context,
      builder: (_) => _RouteEditor(
        original: original,
        labels: labels,
        suggested: port,
        used: used,
      ),
    );
    if (r != null && mounted) await _change(original?.port, r);
  }

  Future<void> _remove(FixedProxyRoute route) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(_text(c, '删除这个入口？', 'Delete this port?')),
        content: Text('${_routeName(c, route)} · 127.0.0.1:${route.port}'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: Text(MaterialLocalizations.of(c).cancelButtonLabel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: Text(_text(c, '删除入口', 'Delete port')),
          ),
        ],
      ),
    );
    if (ok == true && mounted) await _change(route.port, null);
  }

  Future<void> _copy(String value) async {
    try {
      await Clipboard.setData(ClipboardData(text: value));
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text(_text(context, '已复制 $value', 'Copied $value')),
              duration: const Duration(seconds: 2),
            ),
          );
      }
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    }
  }

  Future<void> _check(int port) async {
    if (!mounted ||
        busy ||
        active.containsKey(port) ||
        store.issues.containsKey(port) ||
        !globalState.isStart ||
        !store.routes.any((r) => r.port == port && r.enabled)) {
      return;
    }
    final probe = widget.createProbe(port);
    final session = globalState.startTime;
    final url = globalState.config.appSetting.testUrl.trim();
    setState(() {
      progress.remove(port);
      active[port] = probe;
      signatures[port] = store.pathSignature(port);
    });
    try {
      final result = await probe.run(
        url.isEmpty ? 'https://www.gstatic.com/generate_204' : url,
        onLatency: (partial) {
          if (mounted && identical(active[port], probe)) {
            setState(() => progress[port] = partial);
          }
        },
      );
      if (mounted &&
          identical(active[port], probe) &&
          globalState.isStart &&
          session == globalState.startTime) {
        store.recordCheck(port, result);
      }
    } finally {
      if (mounted && identical(active[port], probe)) {
        setState(() => _forget(port));
      }
    }
  }

  Future<void> _checkAll() async {
    if (batch || busy) return;
    final ports = store.routes
        .where((r) => r.enabled && !store.issues.containsKey(r.port))
        .map((r) => r.port)
        .toList();
    final pass = ++generation;
    setState(() => batch = true);
    var next = 0;
    Future<void> worker() async {
      while (mounted && generation == pass && next < ports.length) {
        await _check(ports[next++]);
      }
    }

    try {
      await Future.wait([worker(), worker()]);
    } finally {
      if (mounted && generation == pass) setState(() => batch = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final running = ref.watch(runTimeProvider.select((v) => v != null));
    ref.listen(runTimeProvider.select((v) => v != null), (before, after) {
      if (!after) {
        setState(() {
          _cancel();
        });
      }
    });
    final routes = store.routes;
    final enabled = routes.where((r) => r.enabled).length;
    final filtered = routes
        .where(
          (r) => [
            _routeName(context, r),
            r.port.toString(),
            for (final h in r.hops) labels[h]?.name ?? h.node,
          ].join(' ').toLowerCase().contains(query),
        )
        .toList();
    final c = Theme.of(context).colorScheme;
    String zh(String cn, String en) => _text(context, cn, en);
    final addButton = FilledButton.icon(
      onPressed: busy ? null : () => _edit(),
      icon: const Icon(Icons.add, size: 18),
      label: Text(zh('新建入口', 'New port')),
    );
    return LayoutBuilder(
      builder: (context, box) {
        final pad = box.maxWidth >= 620 ? 24.0 : 14.0;
        return Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 900),
            child: ListView(
              padding: EdgeInsets.fromLTRB(pad, 12, pad, 32),
              children: [
                Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  runSpacing: 10,
                  spacing: 12,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          zh('代理入口', 'Proxy ports'),
                          style: Theme.of(context).textTheme.headlineSmall
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          zh(
                            '共 ${routes.length} 个 · 已启用 $enabled 个',
                            '${routes.length} total · $enabled enabled',
                          ),
                          style: TextStyle(color: c.onSurfaceVariant),
                        ),
                      ],
                    ),
                    addButton,
                  ],
                ),
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(error!, style: TextStyle(color: c.error)),
                  ),
                if (busy)
                  const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: LinearProgressIndicator(),
                  ),
                if (routes.isNotEmpty) ...[
                  const SizedBox(height: 18),
                  LayoutBuilder(
                    builder: (_, b) {
                      final search = TextField(
                        onChanged: (v) =>
                            setState(() => query = v.trim().toLowerCase()),
                        decoration: InputDecoration(
                          isDense: true,
                          filled: true,
                          fillColor: c.surfaceContainerLow,
                          hintText: zh('搜索入口、端口或节点', 'Search ports or nodes'),
                          prefixIcon: const Icon(Icons.search, size: 20),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(color: c.outlineVariant),
                          ),
                        ),
                      );
                      final button = OutlinedButton.icon(
                        onPressed: batch
                            ? () => setState(_cancel)
                            : !running ||
                                  busy ||
                                  enabled == 0 ||
                                  active.isNotEmpty
                            ? null
                            : _checkAll,
                        icon: Icon(
                          batch
                              ? Icons.stop_rounded
                              : Icons.network_check_rounded,
                          size: 18,
                        ),
                        label: Text(
                          batch
                              ? zh('停止检测', 'Stop checks')
                              : zh('检测全部', 'Check all'),
                        ),
                      );
                      if (b.maxWidth < 360) {
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [search, const SizedBox(height: 6), button],
                        );
                      }
                      return Row(
                        children: [
                          Expanded(child: search),
                          const SizedBox(width: 10),
                          button,
                        ],
                      );
                    },
                  ),
                  if (!running)
                    Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: Text(
                        zh(
                          '启动代理内核后可以检测链路。',
                          'Start the proxy core to check these routes.',
                        ),
                        style: TextStyle(color: c.onSurfaceVariant),
                      ),
                    ),
                  const SizedBox(height: 14),
                ],
                if (!busy && routes.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 46),
                    child: Column(
                      children: [
                        Icon(
                          Icons.alt_route_rounded,
                          size: 38,
                          color: c.primary,
                        ),
                        const SizedBox(height: 14),
                        Text(
                          zh('为应用分配一个固定端口', 'Give an app a fixed port'),
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 6),
                        Text(
                          zh(
                            '选择节点或多跳链，然后把端口填入应用的代理设置。',
                            'Choose a route, then use its local address in your app.',
                          ),
                          textAlign: TextAlign.center,
                          style: TextStyle(color: c.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                if (routes.isNotEmpty && filtered.isEmpty)
                  Text(zh('没有匹配的入口', 'No matching ports')),
                for (final r in filtered)
                  Padding(
                    key: ValueKey(r.port),
                    padding: const EdgeInsets.only(bottom: 12),
                    child: _RouteCard(
                      route: r,
                      labels: labels,
                      report: active.containsKey(r.port)
                          ? progress[r.port]
                          : store.lastCheck(r.port),
                      checking: active.containsKey(r.port),
                      issue: store.issues[r.port],
                      busy: busy,
                      onToggle: (v) => _change(r.port, r.withEnabled(v)),
                      onEdit: () => _edit(r),
                      onDelete: () => _remove(r),
                      onCopy: _copy,
                      onCheck:
                          !running ||
                              busy ||
                              !r.enabled ||
                              store.issues.containsKey(r.port) ||
                              batch
                          ? null
                          : active.containsKey(r.port)
                          ? () => setState(() {
                              _forget(r.port);
                            })
                          : () => _check(r.port),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
