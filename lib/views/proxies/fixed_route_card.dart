part of 'fixed_proxy_view.dart';

enum _RouteAction { edit, http, socks, delete }

class _RouteCard extends StatelessWidget {
  const _RouteCard({
    required this.route,
    required this.labels,
    this.pinnedDialers = const [],
    required this.report,
    required this.checking,
    required this.issue,
    required this.busy,
    required this.onToggle,
    required this.onEdit,
    required this.onDelete,
    required this.onCopy,
    this.onRetry,
    required this.onCheck,
  });
  final FixedProxyRoute route;
  final Map<FixedHop, _NodeLabel> labels;
  final List<FixedHop> pinnedDialers;
  final FixedRouteReport? report;
  final bool checking, busy;
  final String? issue;
  final ValueChanged<bool> onToggle;
  final VoidCallback onEdit, onDelete;
  final ValueChanged<String> onCopy;
  final VoidCallback? onRetry;
  final VoidCallback? onCheck;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final c = t.colorScheme;
    String zh(String cn, String en) => _text(context, cn, en);
    final address = '127.0.0.1:${route.port}';
    final result = report;
    final hasLatency = result?.latencyMs != null;
    final hasIp = result?.exit != null;
    final colors = FluxoraColorSet.of(t.brightness);
    final (status, ink) = switch ((
      route.enabled,
      issue,
      checking,
      result,
      hasLatency,
      hasIp,
    )) {
      (false, _, _, _, _, _) => (zh('已停用', 'Disabled'), c.onSurfaceVariant),
      (_, != null, _, _, _, _) => (zh('入口不可用', 'Unavailable'), c.error),
      (_, _, true, null, _, _) => (
        zh('正在测试延迟', 'Measuring latency'),
        c.primary,
      ),
      (_, _, true, _, _, _) => (zh('正在查询出口', 'Looking up exit'), c.primary),
      (_, _, _, null, _, _) => (zh('待检测', 'Unchecked'), c.onSurfaceVariant),
      (_, _, _, _, true, true) => (zh('链路可用', 'Reachable'), colors.success),
      (_, _, _, _, false, false) => (zh('检测失败', 'Check failed'), c.error),
      _ => (zh('部分成功', 'Partial result'), colors.warning),
    };
    String reason(RouteProbeError e) => switch (e) {
      RouteProbeError.timeout => zh('请求超时', 'Timed out'),
      RouteProbeError.connection => zh('连接失败', 'Connection failed'),
      RouteProbeError.http => zh('服务响应异常', 'HTTP error'),
      RouteProbeError.invalidUrl => zh('测试网址无效', 'Invalid test URL'),
      RouteProbeError.invalidResponse => zh('响应无效', 'Invalid response'),
    };
    final titleStyle = t.textTheme.titleMedium?.copyWith(
      fontWeight: FontWeight.w700,
    );
    final nodes = <Widget>[];
    final chain = [
      for (final h in pinnedDialers) (hop: h, pinned: true),
      for (final h in route.hops) (hop: h, pinned: false),
    ];
    for (var i = 0; i < chain.length; i++) {
      final item = chain[i];
      final h = item.hop, label = labels[h];
      final isExit = route.enabled && i == chain.length - 1;
      nodes.add(
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (i > 0)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: Icon(
                  Icons.arrow_forward_rounded,
                  size: 14,
                  color: c.outline,
                ),
              ),
            Flexible(
              child: Tooltip(
                message: item.pinned
                    ? zh(
                        '订阅内置前置 · ${label?.source ?? h.node}',
                        'Subscription dialer · ${label?.source ?? h.node}',
                      )
                    : (label?.source ?? h.node),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: isExit
                        ? c.secondaryContainer
                        : item.pinned
                        ? c.surfaceContainer
                        : c.surfaceContainerHigh,
                    border: item.pinned
                        ? Border.all(
                            color: c.outlineVariant.withValues(alpha: .8),
                          )
                        : null,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    label?.name ?? h.node,
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                    style: t.textTheme.labelMedium?.copyWith(
                      color: isExit
                          ? c.onSecondaryContainer
                          : c.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    }
    final exit = result?.exit;
    final location = [
      exit?.country ?? exit?.countryCode,
      exit?.city,
    ].whereType<String>().where((s) => s.isNotEmpty).join(' · ');
    final diagnosticTime = result == null
        ? ''
        : MaterialLocalizations.of(
            context,
          ).formatTimeOfDay(TimeOfDay.fromDateTime(result.time));
    return Material(
      color: c.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: c.outlineVariant.withValues(alpha: .8)),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: route.enabled
                        ? c.primaryContainer
                        : c.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(11),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(10),
                    child: Icon(
                      chain.length > 1
                          ? Icons.alt_route_rounded
                          : Icons.lan_outlined,
                      size: 21,
                      color: route.enabled
                          ? c.onPrimaryContainer
                          : c.onSurfaceVariant,
                    ),
                  ),
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _routeName(context, route),
                        style: titleStyle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Tooltip(
                        message: zh('复制地址', 'Copy address'),
                        child: InkWell(
                          onTap: () => onCopy(address),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 3),
                            child: Wrap(
                              spacing: 5,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                Text(
                                  address,
                                  style: _mono.copyWith(
                                    fontSize: 12,
                                    color: c.onSurfaceVariant,
                                  ),
                                ),
                                Icon(
                                  Icons.copy_rounded,
                                  size: 13,
                                  color: c.outline,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Tooltip(
                  message: route.enabled
                      ? zh('停用入口', 'Disable port')
                      : zh('启用入口', 'Enable port'),
                  child: Switch.adaptive(
                    value: route.enabled,
                    onChanged: busy ? null : onToggle,
                  ),
                ),
                PopupMenuButton<_RouteAction>(
                  tooltip: zh('入口操作', 'Port actions'),
                  enabled: !busy,
                  onSelected: (a) {
                    switch (a) {
                      case _RouteAction.edit:
                        onEdit();
                      case _RouteAction.http:
                        onCopy('http://$address');
                      case _RouteAction.socks:
                        onCopy('socks5://$address');
                      case _RouteAction.delete:
                        onDelete();
                    }
                  },
                  itemBuilder: (_) => [
                    PopupMenuItem(
                      value: _RouteAction.edit,
                      child: Text(zh('编辑入口', 'Edit port')),
                    ),
                    PopupMenuItem(
                      value: _RouteAction.http,
                      child: Text(zh('复制 HTTP 地址', 'Copy HTTP URL')),
                    ),
                    PopupMenuItem(
                      value: _RouteAction.socks,
                      child: Text(zh('复制 SOCKS5 地址', 'Copy SOCKS5 URL')),
                    ),
                    const PopupMenuDivider(),
                    PopupMenuItem(
                      value: _RouteAction.delete,
                      child: Text(
                        zh('删除入口', 'Delete port'),
                        style: TextStyle(color: c.error),
                      ),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(spacing: 6, runSpacing: 5, children: nodes),
            if (issue != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(issue!, style: TextStyle(color: c.error)),
              ),
            if (route.enabled) ...[
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 13,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: c.surfaceContainer,
                  borderRadius: BorderRadius.circular(11),
                ),
                child: LayoutBuilder(
                  builder: (_, b) {
                    final delay = _Metric(
                      icon: Icons.speed_rounded,
                      label: zh('响应延迟', 'Latency'),
                      value: hasLatency ? '${result!.latencyMs} ms' : '—',
                      detail: result?.latencyError == null
                          ? null
                          : reason(result!.latencyError!),
                      error: result?.latencyError != null,
                    );
                    final ip = _Metric(
                      icon: Icons.public_rounded,
                      label: zh('出口 IP', 'Exit IP'),
                      value: exit?.ip ?? '—',
                      detail: result?.exitError != null
                          ? reason(result!.exitError!)
                          : location,
                      error: result?.exitError != null,
                    );
                    if (b.maxWidth < 315) {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [delay, const SizedBox(height: 10), ip],
                      );
                    }
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(flex: 2, child: delay),
                        const SizedBox(width: 12),
                        Expanded(flex: 3, child: ip),
                      ],
                    );
                  },
                ),
              ),
            ],
            const SizedBox(height: 6),
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 10,
              children: [
                Wrap(
                  spacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    if (checking)
                      SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: ink,
                        ),
                      )
                    else
                      Icon(Icons.circle, size: 7, color: ink),
                    Text(
                      status,
                      style: t.textTheme.labelMedium?.copyWith(
                        color: ink,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (result != null && !checking)
                      Text(
                        diagnosticTime,
                        style: t.textTheme.labelSmall?.copyWith(
                          color: c.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
                if (route.enabled && issue != null)
                  TextButton.icon(
                    onPressed: onRetry,
                    icon: const Icon(Icons.refresh_rounded, size: 17),
                    label: Text(zh('重试绑定', 'Retry')),
                  )
                else if (route.enabled)
                  TextButton.icon(
                    onPressed: onCheck,
                    icon: Icon(
                      checking
                          ? Icons.stop_rounded
                          : Icons.network_check_rounded,
                      size: 17,
                    ),
                    label: Text(
                      checking ? zh('停止', 'Stop') : zh('检测链路', 'Check route'),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({
    required this.icon,
    required this.label,
    required this.value,
    this.detail,
    this.error = false,
  });
  final IconData icon;
  final String label, value;
  final String? detail;
  final bool error;
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context), c = t.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: c.onSurfaceVariant),
            const SizedBox(width: 5),
            Flexible(
              child: Text(
                label,
                style: t.textTheme.labelMedium?.copyWith(
                  color: c.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 3),
        SelectableText(
          value,
          style: _mono.copyWith(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        if (detail?.isNotEmpty == true)
          Text(
            detail!,
            style: t.textTheme.bodySmall?.copyWith(
              color: error ? c.error : c.onSurfaceVariant,
            ),
          ),
      ],
    );
  }
}
