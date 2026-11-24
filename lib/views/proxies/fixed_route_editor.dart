part of 'fixed_proxy_view.dart';

class _RouteEditor extends StatefulWidget {
  const _RouteEditor({
    required this.original,
    required this.labels,
    required this.catalogNodes,
    required this.suggested,
    required this.used,
    required this.onSave,
  });
  final FixedProxyRoute? original;
  final Map<FixedHop, _NodeLabel> labels;
  final Map<FixedHop, Map> catalogNodes;
  final int suggested;
  final Set<int> used;
  final Future<void> Function(FixedProxyRoute route) onSave;
  @override
  State<_RouteEditor> createState() => _RouteEditorState();
}

class _RouteEditorState extends State<_RouteEditor> {
  late final name = TextEditingController(text: widget.original?.name);
  late final port = TextEditingController(
    text: (widget.original?.port ?? widget.suggested).toString(),
  );
  late final hops = [...?widget.original?.hops];
  late bool enabled = widget.original?.enabled ?? true;
  final form = GlobalKey<FormState>();
  bool saving = false;
  String? saveError;

  @override
  void dispose() {
    name.dispose();
    port.dispose();
    super.dispose();
  }

  Future<void> choose([int? index]) async {
    if (saving) return;
    final h = await showDialog<FixedHop>(
      context: context,
      builder: (_) => _NodePicker(labels: widget.labels),
    );
    if (!mounted || h == null) return;
    setState(() {
      saveError = null;
      if (index == null) {
        hops.add(h);
      } else {
        hops[index] = h;
      }
    });
  }

  void move(int from, int to) => setState(() {
    saveError = null;
    final h = hops.removeAt(from);
    hops.insert(to, h);
  });

  Future<void> save() async {
    if (saving || !form.currentState!.validate()) return;
    setState(() {
      saving = true;
      saveError = null;
    });
    final candidate = FixedProxyRoute(
      int.parse(port.text),
      List.of(hops),
      name: name.text.trim(),
      enabled: enabled,
    );
    try {
      await widget.onSave(candidate);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() {
          saving = false;
          saveError = e.toString().replaceFirst(
            RegExp(r'^(Bad state|FormatException):\s*'),
            '',
          );
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context), c = t.colorScheme;
    String zh(String a, String b) => _text(context, a, b);
    final title = widget.original == null
        ? zh('新建代理入口', 'New proxy port')
        : zh('编辑代理入口', 'Edit proxy port');
    final nameField = TextFormField(
      controller: name,
      maxLength: 48,
      decoration: InputDecoration(
        labelText: zh('入口名称', 'Port name'),
        hintText: zh('例如：工作浏览器', 'e.g. Work browser'),
        counterText: '',
        border: const OutlineInputBorder(),
      ),
    );
    final portField = TextFormField(
      controller: port,
      keyboardType: TextInputType.number,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      decoration: InputDecoration(
        labelText: zh('本地端口', 'Local port'),
        border: const OutlineInputBorder(),
      ),
      validator: (s) {
        final v = int.tryParse(s ?? '');
        if (v == null || v < 1 || v > 65535) return '1–65535';
        if (v != widget.original?.port && widget.used.contains(v)) {
          return zh('端口已分配', 'Port assigned');
        }
        return null;
      },
    );
    final dialerInfo = hops.isEmpty
        ? null
        : FixedProxyRoute(1, hops).resolveDialers(widget.catalogNodes);
    return AlertDialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
      scrollable: true,
      title: Text(title),
      content: SizedBox(
        width: 490,
        child: Form(
          key: form,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (saving)
                const Padding(
                  padding: EdgeInsets.only(bottom: 10),
                  child: LinearProgressIndicator(),
                ),
              if (saveError != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Text(saveError!, style: TextStyle(color: c.error)),
                ),
              const SizedBox(height: 6),
              MediaQuery.sizeOf(context).width < 420
                  ? Column(
                      children: [
                        nameField,
                        const SizedBox(height: 12),
                        portField,
                      ],
                    )
                  : Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(flex: 2, child: nameField),
                        const SizedBox(width: 12),
                        Expanded(child: portField),
                      ],
                    ),
              const SizedBox(height: 18),
              Text(
                zh('代理链路', 'Route'),
                style: t.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                zh(
                  '按流量经过的顺序排列，最后一跳是出口。',
                  'Traffic follows this order. The last hop is the exit.',
                ),
                style: t.textTheme.bodySmall?.copyWith(
                  color: c.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 10),
              if (dialerInfo != null && dialerInfo.dialers.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    zh(
                      '将自动前置订阅跳板：${dialerInfo.dialers.map((h) => widget.labels[h]?.name ?? h.node).join(' → ')}',
                      'Auto-pinned subscription dialer: ${dialerInfo.dialers.map((h) => widget.labels[h]?.name ?? h.node).join(' → ')}',
                    ),
                    style: t.textTheme.bodySmall?.copyWith(color: c.primary),
                  ),
                ),
              if (enabled && dialerInfo?.error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    dialerInfo!.error!,
                    style: t.textTheme.bodySmall?.copyWith(color: c.error),
                  ),
                ),
              for (var i = 0; i < hops.length; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Material(
                    color: c.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(10),
                    child: Row(
                      children: [
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: Text(
                            '${i + 1}',
                            style: _mono.copyWith(color: c.primary),
                          ),
                        ),
                        Expanded(
                          child: InkWell(
                            onTap: () => choose(i),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 10),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    widget.labels[hops[i]]?.name ??
                                        hops[i].node,
                                    style: t.textTheme.titleSmall,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  Text(
                                    widget.labels[hops[i]]?.source ??
                                        zh('节点已失效', 'Node unavailable'),
                                    style: t.textTheme.bodySmall?.copyWith(
                                      color: c.onSurfaceVariant,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                        PopupMenuButton<String>(
                          tooltip: zh('调整这一跳', 'Hop actions'),
                          onSelected: (a) {
                            switch (a) {
                              case 'up':
                                move(i, i - 1);
                              case 'down':
                                move(i, i + 1);
                              case 'replace':
                                choose(i);
                              case 'remove':
                                setState(() => hops.removeAt(i));
                            }
                          },
                          itemBuilder: (_) => [
                            PopupMenuItem(
                              value: 'up',
                              enabled: i > 0,
                              child: Text(zh('上移', 'Move up')),
                            ),
                            PopupMenuItem(
                              value: 'down',
                              enabled: i < hops.length - 1,
                              child: Text(zh('下移', 'Move down')),
                            ),
                            PopupMenuItem(
                              value: 'replace',
                              child: Text(zh('更换节点', 'Replace node')),
                            ),
                            PopupMenuItem(
                              value: 'remove',
                              child: Text(zh('移除这一跳', 'Remove hop')),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              OutlinedButton.icon(
                onPressed: () => choose(),
                icon: const Icon(Icons.add_link_rounded),
                label: Text(
                  hops.isEmpty
                      ? zh('选择首个节点', 'Choose first node')
                      : zh('添加下一跳', 'Add next hop'),
                ),
              ),
              const Divider(height: 26),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(zh('启用入口', 'Enable port')),
                subtitle: const Text('HTTP / SOCKS5 · 127.0.0.1'),
                value: enabled,
                onChanged: saving
                    ? null
                    : (v) => setState(() {
                        saveError = null;
                        enabled = v;
                      }),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: saving ? null : () => Navigator.pop(context),
          child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
        ),
        FilledButton(
          onPressed:
              saving ||
                  hops.isEmpty ||
                  enabled && hops.any((h) => !widget.labels.containsKey(h))
              ? null
              : save,
          child: Text(zh('保存入口', 'Save port')),
        ),
      ],
    );
  }
}

class _NodePicker extends StatefulWidget {
  const _NodePicker({required this.labels});
  final Map<FixedHop, _NodeLabel> labels;
  @override
  State<_NodePicker> createState() => _NodePickerState();
}

class _NodePickerState extends State<_NodePicker> {
  String query = '';
  @override
  Widget build(BuildContext context) {
    final matches = widget.labels.entries
        .where(
          (e) =>
              '${e.value.source} ${e.value.name}'.toLowerCase().contains(query),
        )
        .toList();
    final c = Theme.of(context).colorScheme;
    return AlertDialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
      title: Text(_text(context, '选择节点', 'Choose node')),
      content: SizedBox(
        width: 440,
        height: 360,
        child: Column(
          children: [
            TextField(
              autofocus: true,
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search_rounded),
                labelText: _text(
                  context,
                  '搜索订阅或节点',
                  'Search subscriptions or nodes',
                ),
                border: const OutlineInputBorder(),
              ),
              onChanged: (s) => setState(() => query = s.trim().toLowerCase()),
            ),
            const SizedBox(height: 8),
            if (matches.isEmpty)
              Expanded(
                child: Center(
                  child: Text(_text(context, '没有匹配的节点', 'No matching nodes')),
                ),
              )
            else
              Expanded(
                child: ListView.builder(
                  itemCount: matches.length,
                  itemBuilder: (_, i) {
                    final e = matches[i];
                    return ListTile(
                      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                      leading: Icon(
                        e.key.source.isEmpty
                            ? Icons.location_on_outlined
                            : Icons.dns_outlined,
                        color: c.primary,
                      ),
                      title: Text(
                        e.value.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(e.value.source),
                      onTap: () => Navigator.pop(context, e.key),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
        ),
      ],
    );
  }
}
