import 'package:flutter/services.dart';

/// WinINET keeps a separate set of flags, PAC and proxy values for LAN and
/// every RAS connection. The empty connection name denotes the default LAN.
typedef WinInetSettings = ({
  int flags,
  String server,
  String bypass,
  String pac
});

extension on WinInetSettings {
  bool sameRoute(WinInetSettings other) =>
      flags == other.flags && server == other.server && pac == other.pac;

  List<Object> encode() => [flags, server, bypass, pac];
}

WinInetSettings _decode(Object? value) {
  final fields = value as List;
  final flags = fields[0] as int;
  if (flags < 0 || flags > 0x7fffffff) {
    throw const FormatException('Invalid WinINET flags');
  }
  return (
    flags: flags,
    server: fields[1] as String,
    bypass: fields[2] as String,
    pac: fields[3] as String
  );
}

class WindowsProxyClaim {
  const WindowsProxyClaim(this.original, this.previous, this.target,
      {this.relinquished = false});
  final WinInetSettings original;
  final WinInetSettings previous;
  final WinInetSettings target;
  final bool relinquished;

  List<Object> encode() =>
      [original.encode(), previous.encode(), target.encode(), relinquished];

  factory WindowsProxyClaim.decode(Object? value) {
    final fields = value as List;
    return WindowsProxyClaim(
        _decode(fields[0]), _decode(fields[1]), _decode(fields[2]),
        relinquished: fields[3] as bool);
  }
}

class WindowsProxyConnections {
  static const _channel = MethodChannel('proxy');

  static Future<Map<String, WinInetSettings>> _read({bool defaultOnly = false}) async {
    final values =
        await _channel.invokeMapMethod<String, dynamic>('ReadWindowsProxies', defaultOnly);
    if (values == null || !values.containsKey('')) {
      throw StateError('Could not read WinINET connection settings');
    }
    return values.map((name, settings) => MapEntry(name, _decode(settings)));
  }

  static Future<bool?> defaultUsesPort(int port) async {
    try {
      final current = (await _read(defaultOnly: true))['']!;
      // WinINET can retain an unused PAC URL. Only enabled proxy flags
      // determine whether automatic routing competes with the manual proxy.
      const manual = 0x2, autoUrl = 0x4, autoDetect = 0x8;
      return (current.flags & (manual | autoUrl | autoDetect)) == manual &&
          current.server == '127.0.0.1:$port';
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  static Future<Map<String, WindowsProxyClaim>> prepare(
    int port,
    String bypass,
    Map<String, WindowsProxyClaim>? existing, {
    bool allowRetakeover = false,
  }) async {
    final settings = await _read();
    final claims = <String, WindowsProxyClaim>{};
    for (final entry in settings.entries) {
      final current = entry.value;
      var old = existing?[entry.key];
      if (old != null && (old.relinquished || !current.sameRoute(old.target))) {
        if (entry.key.isEmpty && allowRetakeover) {
          old = null;
        } else {
          if (entry.key.isEmpty) throw StateError('The Windows proxy changed');
          // Remember the previous owner so a later retarget also leaves this
          // independently modified connection alone.
          claims[entry.key] = WindowsProxyClaim(
              old.original, old.previous, old.target,
              relinquished: true);
          continue;
        }
      }
      claims[entry.key] = WindowsProxyClaim(
        old?.original ?? current,
        current,
        (flags: 3, server: '127.0.0.1:$port', bypass: bypass, pac: current.pac),
      );
    }
    return claims;
  }

  static Future<bool> _write(String name, WinInetSettings expected,
          WinInetSettings value, WinInetSettings? original) async =>
      await _channel.invokeMethod<bool>('WriteWindowsProxy', {
        'name': name,
        'expected': expected.encode(),
        'value': value.encode(),
        if (original != null) 'original': original.encode(),
      }) ??
      false;

  static Future<bool> apply(Map<String, WindowsProxyClaim> claims) async {
    for (final entry in claims.entries) {
      final claim = entry.value;
      if (claim.relinquished) continue;
      if (!await _write(
          entry.key, claim.previous, claim.target, claim.original)) {
        return false;
      }
    }
    return true;
  }

  /// With a pending journal the previous target may still own a connection
  /// that the interrupted port change had not yet reached.
  static Future<bool> restore(Map<String, WindowsProxyClaim> claims,
      {required bool pending,
      bool rollback = false,
      Map<String, WindowsProxyClaim>? existing}) async {
    final settings = await _read();
    var restored = true;
    for (final entry in claims.entries) {
      final current = settings[entry.key];
      if (current == null) continue; // RAS entry removed since takeover.
      final claim = entry.value;
      if (claim.relinquished) continue;
      final matched = current.sameRoute(claim.target)
          ? claim.target
          : pending && current.sameRoute(claim.previous)
              ? claim.previous
              : null;
      if (matched == null) continue;
      final saved = rollback ? claim.previous : claim.original;
      final value = (
        flags: saved.flags,
        server: saved.server,
        pac: saved.pac,
        bypass: current.bypass == matched.bypass ? saved.bypass : current.bypass
      );
      final prior = existing?[entry.key];
      if (!await _write(
          entry.key, current, value, rollback ? prior?.original : null)) {
        restored = false;
      }
    }
    if (restored && !rollback) {
      await _channel.invokeMethod<void>('ForgetWindowsProxyClaims');
    }
    return restored;
  }
}
