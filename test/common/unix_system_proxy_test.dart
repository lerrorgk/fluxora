import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxora/common/network_matcher.dart';
import 'package:proxy/unix_system_proxy.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late File record;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('fluxora-proxy-test-');
    record = File('${dir.path}/ownership.json');
  });
  tearDown(() => dir.delete(recursive: true));

  test(
    'removing the last pause rule resumes even without network addresses',
    () {
      expect(
        NetworkMatcher.shouldPause('192.168.1.0/24', ['192.168.1.3'], []),
        isTrue,
      );
      expect(NetworkMatcher.shouldPause('192.168.1.0/24', [], []), isNull);
      expect(NetworkMatcher.shouldPause('', [], []), isFalse);
    },
  );

  test(
    'GNOME restores the original settings across a port change and preserves an external takeover',
    () async {
      final entries = <String, String>{
        'org.gnome.system.proxy.mode': "'auto'",
        'org.gnome.system.proxy.ignore-hosts': "['corp']",
        for (final type in ['http', 'https', 'socks']) ...{
          'org.gnome.system.proxy.$type.host': "'corp'",
          'org.gnome.system.proxy.$type.port': '3128',
        },
      };
      final original = Map.of(entries);
      Future<ProcessResult> run(String exe, List<String> args) async {
        expect(exe, 'gsettings');
        final key = '${args[1]}.${args[2]}';
        if (args.first == 'set') entries[key] = args.last;
        return ProcessResult(1, 0, entries[key]!, '');
      }

      final proxy = UnixSystemProxy(record, backend: 'gnome', run: run);
      expect(await proxy.release(), isTrue);
      expect(await proxy.apply(7900, ['local']), isTrue);
      expect(await proxy.apply(7901, []), isTrue);
      expect(entries['org.gnome.system.proxy.http.port'], '7901');
      expect(await proxy.release(), isTrue);
      expect(entries, original);

      expect(await proxy.apply(7900, []), isTrue);
      entries['org.gnome.system.proxy.http.host'] = "'other'";
      final external = Map.of(entries);
      expect(await proxy.release(), isTrue);
      expect(entries, external);
    },
  );

  test(
    'macOS restores the original PAC and missing manual settings per service',
    () async {
      const channel = MethodChannel('fluxora/system-proxy');
      final settings = <String, dynamic>{
        'ProxyAutoConfigEnable': 1,
        'ExceptionsList': ['intranet'],
      };
      final initial = Map.of(settings);
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'services') return ['wifi'];
        final args = call.arguments as Map;
        expect(args['service'], 'wifi');
        if (call.method == 'read') return Map.of(settings);
        expect(call.method, 'write');
        for (final e in (args['values'] as Map).entries) {
          if (e.value == null) {
            settings.remove(e.key);
          } else {
            settings[e.key as String] = e.value;
          }
        }
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final proxy = UnixSystemProxy(record, backend: 'macos');
      expect(await proxy.apply(7890, ['localhost']), isTrue);
      expect(settings['HTTPPort'], 7890);
      expect(settings['ProxyAutoConfigEnable'], 0);
      expect(await UnixSystemProxy(record, backend: 'macos').release(), isTrue);
      expect(settings, initial);
    },
  );
}
