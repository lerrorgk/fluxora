import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxora/models/core.dart';
import 'package:fluxora/plugins/vpn.dart';

void main() {
  const setup = SetupParams(
    selectedMap: {'Group': 'Chosen'},
    testUrl: 'https://example.test',
  );
  test(
    'the background notification resets the live core and keeps the selection',
    () async {
      final actions = <String>[];
      await Vpn.resetHeadlessCore(setup, (request) async {
        final action = jsonDecode(request) as Map;
        final method = action['method'] as String;
        actions.add(method);
        if (method == 'setupConfig') {
          expect(jsonDecode(action['data'] as String)['selected-map'], {
            'Group': 'Chosen',
          });
        }
        return jsonEncode({
          'code': 0,
          'data': method == 'setupConfig' ? '' : true,
        });
      });
      expect(actions, [
        'closeConnections',
        'flushFakeIP',
        'flushDnsCache',
        'setupConfig',
      ]);
    },
  );

  test('the background reset propagates an invalid running configuration', () {
    return expectLater(
      Vpn.resetHeadlessCore(setup, (request) async {
        final reload = jsonDecode(request)['method'] == 'setupConfig';
        return jsonEncode({
          'code': 0,
          'data': reload ? 'invalid config' : true,
        });
      }),
      throwsStateError,
    );
  });
}
