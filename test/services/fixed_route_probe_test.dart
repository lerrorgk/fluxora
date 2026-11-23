import 'dart:async';
import 'dart:io';

import 'package:fluxora/services/fixed_route_probe.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late HttpServer proxy;
  final latency = Uri.parse('http://latency.invalid/check');
  final lookup = Uri.parse('http://exit.invalid/ip');

  setUp(() async {
    proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  });
  tearDown(() => proxy.close(force: true));
  FixedRouteProbe probe() => FixedRouteProbe(
    proxy.port,
    timeout: const Duration(seconds: 2),
    exitSources: [lookup],
  );

  test('both requests reach the selected proxy and report its exit', () async {
    final hosts = <String>[];
    proxy.listen((r) async {
      hosts.add(r.uri.host);
      if (r.uri.host == latency.host) {
        await Future<void>.delayed(const Duration(milliseconds: 35));
        r.response.statusCode = 204;
      } else {
        r.response.write(
          '{"ip":"203.0.113.6","country":"Japan","city":"Tokyo"}',
        );
      }
      await r.response.close();
    });
    final result = await probe().run(latency.toString());
    expect(hosts, [latency.host, lookup.host]);
    expect(result.latencyMs, greaterThanOrEqualTo(30));
    expect(result.exit?.ip, '203.0.113.6');
    expect(result.exit?.city, 'Tokyo');
    expect(result.exitError, isNull);
  });

  test(
    'malformed exit cannot erase successful latency or masquerade as an IP',
    () async {
      proxy.listen((r) async {
        if (r.uri.host == lookup.host) {
          r.response.write('{"ip":"999.999.999.999"}');
        }
        await r.response.close();
      });
      final result = await probe().run(latency.toString());
      expect(result.latencyMs, isNotNull);
      expect(result.exit, isNull);
      expect(result.exitError, RouteProbeError.invalidResponse);
    },
  );

  test(
    'a failed latency target can still return a working IPv6 exit',
    () async {
      proxy.listen((r) async {
        if (r.uri.host == latency.host) {
          r.response.statusCode = 503;
        } else {
          r.response.write('ip=2001:db8::5\nloc=DE\n');
        }
        await r.response.close();
      });
      final result = await probe().run(latency.toString());
      expect(result.latencyMs, isNull);
      expect(result.latencyError, RouteProbeError.http);
      expect(result.exit?.ip, '2001:db8::5');
    },
  );

  test(
    'an unavailable proxy cannot fall back to a reachable local origin',
    () async {
      final port = proxy.port;
      await proxy.close(force: true);
      final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => origin.close(force: true));
      var requests = 0;
      origin.listen((r) {
        requests++;
        r.response.close();
      });
      final url = Uri.parse('http://127.0.0.1:${origin.port}/');
      final result = await FixedRouteProbe(
        port,
        exitSources: [url],
      ).run(url.toString());
      expect(requests, 0);
      expect(result.latencyError, RouteProbeError.connection);
      expect(result.exit, isNull);
    },
  );

  test(
    'cancelling closes the current connection and skips the exit lookup',
    () async {
      final started = Completer<void>();
      final hosts = <String>[];
      proxy.listen((r) {
        hosts.add(r.uri.host);
        if (!started.isCompleted) started.complete();
      });
      final p = probe();
      final pending = p.run(latency.toString());
      await started.future;
      p.cancel();
      await pending.timeout(const Duration(seconds: 2));
      expect(hosts, [latency.host]);
    },
  );
}
