import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxora/clash/core.dart';
import 'package:fluxora/clash/interface.dart';
import 'package:fluxora/common/common.dart';
import 'package:fluxora/controller.dart';
import 'package:fluxora/enum/enum.dart';
import 'package:fluxora/models/models.dart';
import 'package:fluxora/providers/providers.dart';
import 'package:fluxora/state.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
// ignore: depend_on_referenced_packages
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class _Paths extends Fake
    with MockPlatformInterfaceMixin
    implements PathProviderPlatform {
  @override
  Future<String> getTemporaryPath() async => Directory.systemTemp.path;
  @override
  Future<String> getDownloadsPath() async => Directory.systemTemp.path;
}

class _Validator extends Fake implements ClashHandlerInterface {
  @override
  String validateConfig(String data, {String? ageSecretKey}) =>
      data.contains('rules:') && !data.contains('unsupported-type')
      ? ''
      : 'invalid configuration';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const oldYaml = "rules: ['MATCH,DIRECT']\n";
  const newYaml = "rules: ['MATCH,REJECT']\n";
  final lastSuccess = DateTime.utc(2025, 1, 1);
  late Profile profile;
  late AppController controller;
  late StreamIterator<HttpRequest> requests;
  late File file;

  Future<HttpRequest> nextRequest() async {
    expect(
      await requests.moveNext().timeout(const Duration(seconds: 5)),
      isTrue,
    );
    return requests.current;
  }

  void refreshTest(String name, Future<void> Function() exercise) {
    testWidgets(name, (tester) async {
      PathProviderPlatform.instance = _Paths();
      final original = clashCore.clashInterface;
      clashCore.clashInterface = _Validator();
      addTearDown(() => clashCore.clashInterface = original);
      final server = (await tester.runAsync(
        () => HttpServer.bind(InternetAddress.loopbackIPv4, 0),
      ))!;
      requests = StreamIterator(server);
      addTearDown(() => server.close(force: true));
      addTearDown(requests.cancel);
      profile = Profile(
        id: 'subscription-refresh',
        url: 'http://127.0.0.1:${server.port}/old',
        autoUpdateDuration: const Duration(minutes: 30),
        lastUpdateDate: lastSuccess,
        label: 'original',
      );
      globalState.config = Config(
        themeProps: const ThemeProps(),
        patchClashConfig: const ClashConfig(globalUa: 'test'),
        profiles: [profile],
      );
      await tester.pumpWidget(
        ProviderScope(
          child: Consumer(
            builder: (context, ref, _) {
              ref.watch(profilesProvider);
              controller = AppController(context, ref);
              return const SizedBox();
            },
          ),
        ),
      );
      await tester.runAsync(
        () => HttpOverrides.runWithHttpOverrides(() async {
          file = await profile.getFile();
          await file.writeAsString(oldYaml);
          await exercise();
        }, FluxoraHttpOverrides()),
      );
    });
  }

  refreshTest(
    'a maintenance response preserves the file and last success',
    () async {
      final refresh = controller.autoUpdateProfiles();
      final request = await nextRequest();
      request.response.write('<html>Maintenance</html>');
      await request.response.close();
      await refresh;
      expect(await file.readAsString(), oldYaml);
      expect(controller.ref.read(profilesProvider).single, profile);
    },
  );

  refreshTest(
    'manual node changes commit only after both files are ready',
    () async {
      final store = File(await appPath.getManualProxiesPath(profile.id));
      await ManualProxyHelper.addOrUpdateProxiesToProfile(profile, [
        {'name': 'valid', 'type': 'direct'},
      ]);
      final validYaml = await file.readAsString();
      final validStore = await store.readAsString();
      expect(validYaml, contains('valid'));
      expect(validStore, contains('valid'));
      await expectLater(
        ManualProxyHelper.addOrUpdateProxiesToProfile(profile, [
          {'name': 'mistyped', 'type': 'unsupported-type'},
        ]),
        throwsA('invalid configuration'),
      );
      expect(await file.readAsString(), validYaml);
      expect(await store.readAsString(), validStore);
      await store.delete();
      final occupied = await Directory(store.path).create();
      try {
        await expectLater(
          ManualProxyHelper.addOrUpdateProxiesToProfile(profile, [
            {'name': 'other', 'type': 'direct'},
          ]),
          throwsA(isA<FileSystemException>()),
        );
        expect(await file.readAsString(), validYaml);
      } finally {
        await occupied.delete();
      }
    },
  );

  refreshTest(
    'deleting a subscription discards its pending download',
    () async {
      final cache = Directory(await appPath.getProvidersDirPath(profile.id));
      await cache.create(recursive: true);
      await File('${cache.path}/test.yaml').writeAsString('cache');
      final refresh = controller.updateProfile(profile);
      final request = await nextRequest();
      final waitingRefresh = controller.updateProfile(profile);
      await controller.deleteProfile(profile.id);
      request.response.write(newYaml);
      await request.response.close();
      await Future.wait([refresh, waitingRefresh]);
      expect(await file.exists(), isFalse);
      expect(await cache.exists(), isFalse);
      expect(controller.ref.read(profilesProvider), isEmpty);
    },
  );

  for (final legacy in [false, true]) {
    refreshTest(
      'reject invalid IDs before applying a legacy=$legacy backup',
      () async {
        final config = globalState.config.copyWith(
          profiles: [
            profile,
            profile.copyWith(id: ''),
          ],
        );
        final archive = Archive();
        if (!legacy) archive.add(ArchiveFile.string('.fluxora_marker', '{}'));
        archive.add(ArchiveFile.string('config.json', jsonEncode(config)));
        archive.add(ArchiveFile.string('profiles/${profile.id}.yaml', newYaml));
        await expectLater(
          controller.recoveryData(
            ZipEncoder().encode(archive),
            RecoveryOption.onlyProfiles,
          ),
          throwsA(contains('Invalid filename')),
        );
        expect(await file.readAsString(), oldYaml);
        expect(controller.ref.read(profilesProvider), [profile]);
      },
    );
  }

  refreshTest(
    'full Android restore distinguishes missing and disabled app routing',
    () async {
      final previousPlatform = System.platformOverride;
      System.platformOverride = 'android';
      addTearDown(() => System.platformOverride = previousPlatform);
      SharedPreferences.setMockInitialValues({});
      const current = AccessControl(enable: true, rejectList: ['reader']);
      controller.ref
          .read(vpnSettingProvider.notifier)
          .updateState((state) => state.copyWith(accessControl: current));
      final raw =
          jsonDecode(jsonEncode(globalState.config)) as Map<String, dynamic>;
      final vpn = raw['vpnProps'] as Map<String, dynamic>;
      Future<void> restore() async {
        final archive = Archive()
          ..add(ArchiveFile.string('.fluxora_marker', '{}'))
          ..add(ArchiveFile.string('config.json', jsonEncode(raw)));
        await controller.recoveryData(
          ZipEncoder().encode(archive),
          RecoveryOption.all,
        );
      }

      vpn.remove('accessControl');
      await restore();
      expect(controller.ref.read(vpnSettingProvider).accessControl, current);
      vpn['accessControl'] = const AccessControl().toJson();
      await restore();
      expect(
        controller.ref.read(vpnSettingProvider).accessControl,
        const AccessControl(),
      );
    },
  );

  refreshTest(
    'forget an invalid legacy ID without touching other profiles',
    () async {
      controller.setProfiles([profile, profile.copyWith(id: '')]);
      final cache = Directory(await appPath.getProvidersDirPath(profile.id));
      await cache.create(recursive: true);
      await controller.deleteProfile('');
      expect(await cache.exists(), isTrue);
      expect(await file.readAsString(), oldYaml);
      expect(controller.ref.read(profilesProvider), [profile]);
    },
  );

  refreshTest(
    'a URL edit supersedes a slow refresh and keeps concurrent edits',
    () async {
      final first = controller.updateProfile(profile);
      final oldRequest = await nextRequest();
      final newUrl = profile.url.replaceFirst('/old', '/new');
      final second = controller.updateProfile(
        profile,
        edit: (latest) => latest.copyWith(url: newUrl),
      );
      final newRequest = await nextRequest();
      expect(newRequest.uri.path, '/new');
      controller.editProfile(
        profile.id,
        (p) => p.copyWith(
          label: 'new alias',
          portalUrl: 'https://user.example/',
          portalSource: ProfilePortalSource.manual,
        ),
      );
      newRequest.response.headers.set(
        'subscription-userinfo',
        'download=8;missing;total=20; upload=2;',
      );
      newRequest.response.headers.set(
        'profile-web-page-url',
        'https://vendor.example/',
      );
      newRequest.response.write(newYaml);
      await newRequest.response.close();
      await second;
      oldRequest.response.write(oldYaml);
      await oldRequest.response.close();
      await first;
      final saved = controller.ref.read(profilesProvider).single;
      expect(saved.url, newUrl);
      expect(saved.label, 'new alias');
      expect(saved.portalUrl, 'https://user.example/');
      expect(
        saved.subscriptionInfo,
        const SubscriptionInfo(download: 8, total: 20, upload: 2),
      );
      expect(saved.lastUpdateDate!.isAfter(lastSuccess), isTrue);
      expect(saved.isUpdating, isFalse);
      expect(await file.readAsString(), newYaml);
    },
  );

  test('a minute-based interval becomes due at the configured minute', () {
    final p = Profile.normal(url: 'https://example.invalid').copyWith(
      lastUpdateDate: lastSuccess,
      autoUpdateDuration: const Duration(minutes: 30),
    );
    final due = lastSuccess.add(const Duration(minutes: 30));
    expect(p.isUpdateDue(due.subtract(const Duration(seconds: 1))), isFalse);
    expect(p.isUpdateDue(due), isTrue);
    expect(p.copyWith(autoUpdate: false).isUpdateDue(due), isFalse);
    expect(p.copyWith(isUpdating: true).isUpdateDue(due), isFalse);
  });
}
