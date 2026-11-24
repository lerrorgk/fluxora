import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fluxora/models/public_ip_info.dart';
import 'package:fluxora/services/public_ip_service.dart';

enum RouteProbeError { timeout, connection, http, invalidResponse, invalidUrl }

class FixedRouteReport {
  const FixedRouteReport({
    required this.time,
    this.latencyMs,
    this.exit,
    this.latencyError,
    this.exitError,
  });
  final DateTime time;
  final int? latencyMs;
  final PublicIpInfo? exit;
  final RouteProbeError? latencyError;
  final RouteProbeError? exitError;
}

/// Each request uses a new connection through the one specified mixed listener.
/// A cancelled request or a failed local proxy never retries directly.
class FixedRouteProbe {
  FixedRouteProbe(
    this.port, {
    this.timeout = const Duration(seconds: 5),
    List<Uri>? exitSources,
    this.credentials,
  }) : exitSources =
           exitSources ??
           [
             Uri.https('get.geojs.io', '/v1/ip/geo.json'),
             Uri.https('api.ip.sb', '/cdn-cgi/trace'),
           ] {
    RangeError.checkValueInInterval(port, 1, 65535, 'port');
  }

  final int port;
  final Duration timeout;
  final List<Uri> exitSources;
  final ({String username, String password})? credentials;
  final _clients = <HttpClient>{};
  bool _cancelled = false;

  void cancel() {
    _cancelled = true;
    for (final client in _clients) {
      client.close(force: true);
    }
  }

  Future<T> _get<T>(
    Uri uri,
    FutureOr<T> Function(HttpClientResponse) read,
  ) async {
    if (_cancelled) throw const SocketException('cancelled');
    if (!{'http', 'https'}.contains(uri.scheme) || uri.host.isEmpty) {
      throw RouteProbeError.invalidUrl;
    }
    final client = HttpClient()
      ..connectionTimeout = timeout
      ..findProxy = (_) => 'PROXY 127.0.0.1:$port';
    if (credentials case final creds?) {
      final basic = HttpClientBasicCredentials(creds.username, creds.password);
      var challenged = false;
      client.addProxyCredentials('127.0.0.1', port, '', basic);
      client.authenticateProxy = (host, p, scheme, realm) async {
        if (challenged) return false;
        challenged = true;
        client.addProxyCredentials(host, p, realm ?? '', basic);
        return true;
      };
    }
    _clients.add(client);
    try {
      return await (() async {
        final request = await client.getUrl(uri);
        request.followRedirects = false;
        final response = await request.close();
        if (response.statusCode < 200 || response.statusCode >= 300) {
          throw RouteProbeError.http;
        }
        return await read(response);
      })().timeout(timeout);
    } finally {
      client.close(force: true);
      _clients.remove(client);
    }
  }

  static RouteProbeError _failure(Object e) => switch (e) {
    TimeoutException() => RouteProbeError.timeout,
    RouteProbeError error => error,
    FormatException() => RouteProbeError.invalidResponse,
    _ => RouteProbeError.connection,
  };

  Future<FixedRouteReport> run(
    String testUrl, {
    void Function(FixedRouteReport)? onLatency,
  }) async {
    int? latency;
    PublicIpInfo? exit;
    RouteProbeError? latencyError;
    RouteProbeError? exitError;
    final watch = Stopwatch()..start();
    try {
      final url = Uri.tryParse(testUrl.trim());
      if (url == null) throw RouteProbeError.invalidUrl;
      latency = await _get(url, (_) => watch.elapsedMilliseconds);
    } catch (e) {
      latencyError = _failure(e);
    }
    if (!_cancelled) {
      onLatency?.call(
        FixedRouteReport(
          time: DateTime.now(),
          latencyMs: latency,
          latencyError: latencyError,
        ),
      );
    }
    for (final url in exitSources) {
      if (_cancelled) break;
      try {
        exit = await _get(url, (response) async {
          final bytes = <int>[];
          await for (final chunk in response) {
            if (bytes.length + chunk.length > 65536) {
              throw RouteProbeError.invalidResponse;
            }
            bytes.addAll(chunk);
          }
          final info = publicIpService.parseResponse(
            utf8.decode(bytes),
            url.toString(),
          );
          if (info == null || InternetAddress.tryParse(info.ip) == null) {
            throw RouteProbeError.invalidResponse;
          }
          return info;
        });
        exitError = null;
        break;
      } catch (e) {
        exitError = _failure(e);
      }
    }
    return FixedRouteReport(
      time: DateTime.now(),
      latencyMs: latency,
      exit: exit,
      latencyError: latencyError,
      exitError: exitError,
    );
  }
}
