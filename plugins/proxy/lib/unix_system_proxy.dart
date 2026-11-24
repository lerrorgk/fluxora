import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show mapEquals;
import 'package:flutter/services.dart';

typedef ProxyCommand = Future<ProcessResult> Function(String, List<String>);
typedef _Values = Map<String, String>;

/// An ownership record per desktop (or per network service on macOS).
/// Persist it before writing so a partial change can also be undone.
class UnixSystemProxy {
  UnixSystemProxy(this.record, {required this.backend, ProxyCommand? run})
      : run = run ??
            ((exe, args) =>
                Process.run(exe, args, environment: {'LC_ALL': 'C'}));

  final File record;
  final String backend;
  final ProxyCommand run;
  static const _mac = MethodChannel('fluxora/system-proxy');
  static const _schema = 'org.gnome.system.proxy';

  static const _linuxTypes = ['http', 'https', 'socks'];
  String? _kdeVersion;

  Future<String> _command(String exe, List<String> args) async {
    final result = await run(exe, args);
    if (result.exitCode != 0) {
      throw ProcessException(
          exe, args, result.stderr.toString(), result.exitCode);
    }
    return result.stdout.toString().trim();
  }

  Future<String> _kdeTool(String name) async {
    if (_kdeVersion == null) {
      try {
        await _command('kreadconfig6', ['--version']);
        _kdeVersion = '6';
      } on ProcessException {
        _kdeVersion = '5';
      }
    }
    return '$name$_kdeVersion';
  }

  Future<List<String>> _groups() async {
    if (backend != 'macos') return [backend];
    return await _mac.invokeListMethod<String>('services') ?? [];
  }

  static String _quote(String s) =>
      "'${s.replaceAll(r'\', r'\\').replaceAll("'", r"\'")}'";

  _Values _target(int port, List<String> bypass) {
    const host = '127.0.0.1';
    if (backend == 'macos') {
      return {
        'ExceptionsList': jsonEncode(bypass),
        for (final type in ['HTTP', 'HTTPS', 'SOCKS']) ...{
          '${type}Enable': '1',
          '${type}Proxy': jsonEncode(host),
          '${type}Port': '$port',
        },
        'ProxyAutoConfigEnable': '0',
        'ProxyAutoDiscoveryEnable': '0',
      };
    }
    if (backend == 'kde') {
      return {
        'NoProxyFor': bypass.join(','),
        for (final type in _linuxTypes)
          '${type}Proxy': '${type == 'socks' ? 'socks' : 'http'}://$host:$port',
        'ProxyType': '1',
      };
    }
    return {
      'ignore-hosts':
          bypass.isEmpty ? '@as []' : '[${bypass.map(_quote).join(', ')}]',
      for (final type in _linuxTypes) ...{
        '$type.host': _quote(host),
        '$type.port': '$port',
      },
      'mode': "'manual'",
    };
  }

  static const _kdeArgs = ['--file', 'kioslaverc', '--group', 'Proxy Settings'];
  static const _missing = '__FLUXORA_ABSENT_PROXY_SETTING__';

  Future<_Values> _read(String group) async {
    final keys = _target(1, []).keys.toList();
    if (backend == 'macos') {
      final values = await _mac.invokeMapMethod<String, dynamic>(
          'read', {'service': group, 'keys': keys});
      if (values == null) {
        throw StateError('Could not read proxy settings for $group');
      }
      return {for (final key in keys) key: jsonEncode(values[key])};
    }
    final values = <String, String>{};
    for (final key in keys) {
      if (backend == 'kde') {
        values[key] = await _command(await _kdeTool('kreadconfig'),
            [..._kdeArgs, '--key', key, '--default', _missing]);
      } else {
        final parts = key.split('.');
        final schema = parts.length == 1 ? _schema : '$_schema.${parts.first}';
        values[key] = await _command('gsettings', ['get', schema, parts.last]);
      }
    }
    return values;
  }

  Future<void> _write(String group, _Values from, _Values to) async {
    if (mapEquals(from, to)) return;
    if (backend == 'macos') {
      await _mac.invokeMethod<void>('write', {
        'service': group,
        'expected': from.map((k, v) => MapEntry(k, jsonDecode(v))),
        'values': to.map((k, v) => MapEntry(k, jsonDecode(v))),
      });
      return;
    }
    for (final key in _target(1, []).keys) {
      final value = to[key]!;
      if (from[key] == value) continue;
      if (backend == 'kde') {
        await _command(await _kdeTool('kwriteconfig'), [
          ..._kdeArgs,
          '--key',
          key,
          if (value == _missing) '--delete' else value
        ]);
      } else {
        final parts = key.split('.');
        final schema = parts.length == 1 ? _schema : '$_schema.${parts.first}';
        await _command('gsettings', ['set', schema, parts.last, value]);
      }
    }
    if (backend == 'kde') {
      await _command('dbus-send', [
        '--type=method_call',
        '--dest=org.kde.KIO',
        '/KIO/kioslave',
        'org.kde.KIO.kioslave.reparseConfiguration'
      ]);
    }
  }

  Future<Map<String, dynamic>> _load() async => await record.exists()
      ? jsonDecode(await record.readAsString()) as Map<String, dynamic>
      : {};

  Future<void> _save(Map<String, dynamic> claims) async {
    if (claims.isEmpty) {
      if (await record.exists()) await record.delete();
    } else {
      await record.parent.create(recursive: true);
      final stage = File('${record.path}.tmp');
      await stage.writeAsString(jsonEncode(claims), flush: true);
      await stage.rename(record.path);
    }
  }

  Future<bool> apply(int port, List<String> bypass) async {
    final claims = await _load();
    final target = _target(port, bypass);
    final groups = await _groups();
    if (groups.isEmpty) return false;
    for (final group in groups) {
      final current = await _read(group);
      final old = claims[group] as Map?;
      if (old != null &&
          !mapEquals(current, _Values.from(old['applied'] as Map))) {
        return false;
      }
      claims[group] = {
        'before': old?['before'] ?? current,
        'applied': target,
        'from': current
      };
    }
    await _save(claims);
    try {
      for (final group in groups) {
        final current = await _read(group);
        if (!mapEquals(current, _Values.from(claims[group]['from'] as Map))) {
          throw StateError('System proxy changed during apply');
        }
        await _write(group, current, target);
        if (!mapEquals(await _read(group), target)) {
          throw StateError('Proxy update did not land for $group');
        }
      }
      for (final group in groups) {
        (claims[group] as Map).remove('from');
      }
      await _save(claims);
      return true;
    } catch (_) {
      await release();
      rethrow;
    }
  }

  Future<bool> release() async {
    final claims = await _load();
    if (claims.isEmpty) return true;
    final available = await _groups();
    for (final group in claims.keys.toList()) {
      if (!available.contains(group)) continue;
      final entry = claims[group] as Map;
      final before = _Values.from(entry['before'] as Map);
      final applied = _Values.from(entry['applied'] as Map);
      final previous = entry['from'] as Map?;
      final current = await _read(group);
      final bypassKey = switch (backend) {
        'macos' => 'ExceptionsList',
        'kde' => 'NoProxyFor',
        _ => 'ignore-hosts'
      };
      final external = current.keys.any((k) =>
          k != bypassKey &&
          current[k] != applied[k] &&
          current[k] != previous?[k]);
      if (!external) {
        if (current[bypassKey] != applied[bypassKey]) {
          before[bypassKey] = current[bypassKey]!;
        }
        await _write(group, current, before);
        if (!mapEquals(await _read(group), before)) return false;
      }
      claims.remove(group);
      await _save(claims);
    }
    return claims.isEmpty;
  }
}
