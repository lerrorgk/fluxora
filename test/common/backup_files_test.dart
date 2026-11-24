import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:fluxora/common/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('legacy profiles-only restore ignores Android app selection', () {
    final selection = {
      'enable': true,
      'acceptList': ['com.example.reader'],
    };
    for (final key in ['accessControl', 'accessControlProps']) {
      final config = {
        'vpnProps': {key: selection},
      };
      expect(legacyBackupAccessControl(config, restoreAll: false), isNull);
      expect(legacyBackupAccessControl(config, restoreAll: true), selection);
    }
    expect(legacyBackupAccessControl({}, restoreAll: true), isNull);
  });
  test(
    'a failed file replacement rolls back previously installed files',
    () async {
      final home = await Directory.systemTemp.createTemp(
        'fluxora_restore_test_',
      );
      addTearDown(() => home.delete(recursive: true));
      final kept = File(p.join(home.path, 'original'))
        ..writeAsStringSync('old');
      await Directory(p.join(home.path, 'occupied')).create();
      await expectLater(
        restoreBackupFiles([
          ArchiveFile.string('original', 'new'),
          ArchiveFile.string('occupied', 'cannot replace a directory'),
        ], home.path),
        throwsA(isA<FileSystemException>()),
      );
      expect(await kept.readAsString(), 'old');
    },
  );

  test(
    'full backup restores routing and scripts, profile restore filters them',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'fluxora_backup_test_',
      );
      addTearDown(() => temp.delete(recursive: true));
      final source = Directory(p.join(temp.path, 'source'))..createSync();
      final contents = {
        'profiles/a.yaml': 'proxies: []',
        'profiles/providers/a/rules/local.json': '[]',
        'manual_proxies_a.json': '[]',
        'scripts/selected.js': 'function main(config) { return config; }',
        'fixed_proxy_routes.json': '{"version":1,"routes":[]}',
        'profile_chains.json': '{"a":{"profileId":"a"}}',
        'warp_config.json': '{}',
        'profiles/deleted.yaml': 'discard',
        'scripts/deleted.js': 'discard',
        'manual_proxies_deleted.json': '[]',
        'helper_auth.key': 'discard',
      };
      for (final entry in contents.entries) {
        final file = File(p.join(source.path, entry.key));
        await file.parent.create(recursive: true);
        await file.writeAsString(entry.value);
      }
      final manifest = FluxoraBackupFiles({'a'}, {'selected'});
      final bytes = await manifest.encode(source.path, '{"profiles":[]}', {
        'chain_fallback_pool.json': {'candidates': []},
      });
      final archive = ZipDecoder().decodeBytes(bytes);
      expect(archive.find('profiles/deleted.yaml'), isNull);
      expect(archive.find('helper_auth.key'), isNull);
      expect(archive.find('scripts/deleted.js'), isNull);
      expect(archive.find('manual_proxies_deleted.json'), isNull);
      expect(
        jsonDecode(
          utf8.decode(archive.find('chain_fallback_pool.json')!.content),
        ),
        {'candidates': []},
      );
      for (final all in [false, true]) {
        final target = Directory(p.join(temp.path, 'restore-$all'))
          ..createSync();
        await restoreBackupFiles(
          archive.files.where((file) => manifest.includes(file.name, all: all)),
          target.path,
        );
        for (final name in [
          'profiles/a.yaml',
          'profiles/providers/a/rules/local.json',
          'manual_proxies_a.json',
        ]) {
          expect(
            await File(p.join(target.path, name)).readAsString(),
            contents[name],
          );
        }
        for (final name in [
          'scripts/selected.js',
          'fixed_proxy_routes.json',
          'profile_chains.json',
          'warp_config.json',
        ]) {
          final restored = File(p.join(target.path, name));
          expect(await restored.exists(), all);
          if (all) expect(await restored.readAsString(), contents[name]);
        }
      }
    },
  );
}
