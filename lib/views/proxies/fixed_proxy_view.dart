import 'package:fluxora/manager/fixed_proxy_routes.dart';
import 'package:fluxora/models/fixed_proxy_route.dart';
import 'package:fluxora/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

String _text(BuildContext context, String zh, String en) =>
    Localizations.localeOf(context).languageCode == 'zh' ? zh : en;

class FixedProxyView extends StatefulWidget {
  const FixedProxyView({super.key});
  static String title(BuildContext context) =>
      _text(context, '独立代理', 'Fixed proxies');
  @override
  State<FixedProxyView> createState() => _FixedProxyViewState();
}

class _FixedProxyViewState extends State<FixedProxyView> {
  Map<FixedHop, String> labels = {};
  bool busy = true;
  String? error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      await fixedProxyRoutes.load();
      final catalog = await fixedProxyRoutes.catalog();
      if (!mounted) return;
      final sources = {
        for (final p in globalState.config.profiles) p.id: p.label ?? p.id,
      };
      labels = {
        for (final e in catalog.entries)
          e.key:
              '${sources[e.key.source] ?? _text(context, '落地节点', 'Landing nodes')} / ${e.value['name']}',
      };
      error = null;
    } catch (e) {
      error = e.toString();
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _change(int? oldPort, FixedProxyRoute? route) async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await fixedProxyRoutes.change(previousPort: oldPort, route: route);
    } catch (e) {
      error = e.toString();
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _edit([FixedProxyRoute? old]) async {
    final route = await showDialog<FixedProxyRoute>(
      context: context,
      builder: (_) => _RouteEditor(original: old, labels: labels),
    );
    if (route != null && mounted) await _change(old?.port, route);
  }

  @override
  Widget build(BuildContext context) {
    final routes = fixedProxyRoutes.routes;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          _text(
            context,
            '将应用的 HTTP 或 SOCKS5 代理设为下面的本地端口。节点按从入口到出口的顺序连接。',
            'Point an app’s HTTP or SOCKS5 proxy at a local port below. Hops run in order from entry to exit.',
          ),
        ),
        if (busy) const LinearProgressIndicator(),
        if (error != null)
          Text(
            error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        for (final route in routes)
          ListTile(
            title: SelectableText('127.0.0.1:${route.port}'),
            subtitle: Text(
              [
                route.hops.map((h) => labels[h] ?? '${h.node} (?)').join(' → '),
                if (fixedProxyRoutes.issues[route.port] case final String issue)
                  issue,
              ].join('\n'),
            ),
            onTap: busy ? null : () => _edit(route),
            trailing: IconButton(
              tooltip: MaterialLocalizations.of(context).deleteButtonTooltip,
              icon: const Icon(Icons.delete_outline),
              onPressed: busy ? null : () => _change(route.port, null),
            ),
          ),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: FilledButton.icon(
            onPressed: busy ? null : () => _edit(),
            icon: const Icon(Icons.add),
            label: Text(_text(context, '添加端口', 'Add port')),
          ),
        ),
      ],
    );
  }
}

class _RouteEditor extends StatefulWidget {
  const _RouteEditor({required this.original, required this.labels});
  final FixedProxyRoute? original;
  final Map<FixedHop, String> labels;
  @override
  State<_RouteEditor> createState() => _RouteEditorState();
}

class _RouteEditorState extends State<_RouteEditor> {
  late final port = TextEditingController(
    text: widget.original?.port.toString() ?? '',
  );
  late final hops = [...?widget.original?.hops];
  final form = GlobalKey<FormState>();

  @override
  void dispose() {
    port.dispose();
    super.dispose();
  }

  Future<void> _choose([int? index]) async {
    var query = '';
    final selected = await showDialog<FixedHop>(
      context: context,
      builder: (dialog) => StatefulBuilder(
        builder: (_, update) {
          final matches = widget.labels.entries
              .where((e) => e.value.toLowerCase().contains(query))
              .toList();
          return AlertDialog(
            title: Text(_text(context, '选择节点', 'Choose node')),
            content: SizedBox(
              width: 380,
              height: 380,
              child: Column(
                children: [
                  TextField(
                    autofocus: true,
                    decoration: InputDecoration(
                      labelText: _text(
                        context,
                        '搜索订阅或节点',
                        'Search subscriptions or nodes',
                      ),
                    ),
                    onChanged: (v) =>
                        update(() => query = v.trim().toLowerCase()),
                  ),
                  if (matches.isEmpty)
                    Text(_text(context, '没有可选节点', 'No matching nodes')),
                  Expanded(
                    child: ListView.builder(
                      itemCount: matches.length,
                      itemBuilder: (_, i) => ListTile(
                        title: Text(matches[i].value),
                        onTap: () => Navigator.pop(dialog, matches[i].key),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
    if (selected == null || !mounted) return;
    setState(() {
      if (index == null) {
        hops.add(selected);
      } else {
        hops[index] = selected;
      }
    });
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(FixedProxyView.title(context)),
    content: SizedBox(
      width: 400,
      child: SingleChildScrollView(
        child: Form(
          key: form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: port,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: InputDecoration(
                  labelText: _text(context, '本地端口', 'Local port'),
                  prefixText: '127.0.0.1:',
                ),
                validator: (v) {
                  final value = int.tryParse(v ?? '');
                  if (value == null || value < 1 || value > 65535) {
                    return '1–65535';
                  }
                  if (widget.original?.port != value &&
                      fixedProxyRoutes.routes.any((r) => r.port == value)) {
                    return _text(context, '端口已分配', 'Port already assigned');
                  }
                  return null;
                },
              ),
              for (var i = 0; i < hops.length; i++)
                ListTile(
                  leading: Text('${i + 1}'),
                  title: Text(widget.labels[hops[i]] ?? '${hops[i].node} (?)'),
                  onTap: () => _choose(i),
                  trailing: IconButton(
                    icon: const Icon(Icons.remove_circle_outline),
                    tooltip: MaterialLocalizations.of(
                      context,
                    ).deleteButtonTooltip,
                    onPressed: () => setState(() => hops.removeAt(i)),
                  ),
                ),
              TextButton.icon(
                onPressed: () => _choose(),
                icon: const Icon(Icons.add_link),
                label: Text(_text(context, '添加一跳', 'Add hop')),
              ),
            ],
          ),
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
      ),
      FilledButton(
        onPressed:
            hops.isEmpty || hops.any((h) => !widget.labels.containsKey(h))
            ? null
            : () {
                if (form.currentState!.validate()) {
                  Navigator.pop(
                    context,
                    FixedProxyRoute(int.parse(port.text), hops),
                  );
                }
              },
        child: Text(_text(context, '保存', 'Save')),
      ),
    ],
  );
}
