import 'dart:convert';
import 'dart:io';

import 'package:fluxora/common/proxy_ownership.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proxy/windows_proxy.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('proxy');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  test(
    'interrupted retarget recovers each unchanged LAN and RAS route from disk',
    () async {
      final original = <String, List<Object>>{
        '': [1, '', '', ''],
        'work': [12, '', 'corp', 'https://corp/pac'],
        'mobile': [3, 'mobile.proxy:8000', '', ''],
        'external': [3, 'other:8080', '', ''],
      };
      final live = Map.of(original);
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'ReadWindowsProxies') return live;
        if (call.method == 'ForgetWindowsProxyClaims') return null;
        expect(call.method, 'WriteWindowsProxy');
        final args = call.arguments as Map;
        final name = args['name'] as String;
        expect(live[name], args['expected']);
        live[name] = List<Object>.from(args['value'] as List);
        return true;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final first = await WindowsProxyConnections.prepare(
        7890,
        '<local>',
        null,
      );
      expect(await WindowsProxyConnections.apply(first), isTrue);
      final pending = await WindowsProxyConnections.prepare(
        7891,
        '<local>',
        first,
      );
      // Only the default LAN and mobile writes landed before the process died.
      live[''] = [3, '127.0.0.1:7891', '<local>', ''];
      live['mobile'] = [3, '127.0.0.1:7891', 'new bypass', ''];
      live['external'] = [3, 'user-changed:8765', '', ''];

      final dir = await Directory.systemTemp.createTemp('wininet-recovery-');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/ownership.json');
      ProxyOwnership.statePathForTest = file.path;
      ProxyOwnership.readForTest = () => const ProxySnapshot();
      addTearDown(() {
        ProxyOwnership.readForTest = null;
        ProxyOwnership.statePathForTest = null;
      });
      await file.writeAsString(
        jsonEncode(
          ProxyOwnershipState(
            pending: true,
            snapshot: const ProxySnapshot(),
            connections: pending,
          ).toJson(),
        ),
      );
      expect(
        await ProxyOwnership.reconcileOnStart(),
        ProxyReleaseOutcome.restored,
      );
      expect(await file.exists(), isFalse);
      expect(live[''], original['']);
      expect(live['work'], original['work']);
      expect(live['mobile'], [3, 'mobile.proxy:8000', 'new bypass', '']);
      expect(live['external'], [3, 'user-changed:8765', '', '']);
    },
  );
}
