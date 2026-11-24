import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:fluxora/common/archive.dart';
import 'package:fluxora/common/data_path.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('profile IDs must be portable path components', () {
    for (final id in ['17423', 'legacy-01_ab', '香港 A.2']) {
      expect(checkedDataPathSegment(id), id);
    }
    for (final id in [
      '',
      '.',
      '..',
      'dir/node',
      r'dir\node',
      'X:id',
      'CON',
      'name. ',
    ]) {
      expect(() => checkedDataPathSegment(id), throwsFormatException);
    }
  });
  test(
    'restore refuses a linked parent before installing other entries',
    () async {
      final home = await Directory.systemTemp.createTemp(
        'fluxora_restore_links_',
      );
      addTearDown(() => home.delete(recursive: true));
      final actual = await Directory(p.join(home.path, 'actual')).create();
      final linked = Link(p.join(home.path, 'profiles'));
      await linked.create(actual.path);
      final prior = await File(
        p.join(home.path, 'prior'),
      ).writeAsString('original');
      await expectLater(
        restoreBackupFiles([
          ArchiveFile.string('prior', 'changed'),
          ArchiveFile.string('profiles/sample.yaml', 'sample'),
        ], home.path),
        throwsA(isA<FileSystemException>()),
      );
      expect(await prior.readAsString(), 'original');
      expect(await actual.list().isEmpty, isTrue);
    },
  );
  test('legacy profiles-only restore ignores Android app selection', () {
    final selection = {
      'enable': true,
      'acceptList': ['com.example.reader'],
    };
    for (final key in ['accessControl', 'accessControlProps']) {
      final config = {
        'vpnProps': {key: selection},
      };
      expect(backupAccessControl(config, restoreAll: false), isNull);
      expect(backupAccessControl(config, restoreAll: true), selection);
    }
    expect(backupAccessControl({}, restoreAll: true), isNull);
    final empty = {'enable': false, 'acceptList': [], 'rejectList': []};
    expect(
      backupAccessControl({
        'vpnProps': {'accessControl': empty},
      }, restoreAll: true),
      empty,
    );
  });

  test(
    'restore canonicalizes profile filenames and clears absent manual nodes only on overwrite',
    () async {
      final home = await Directory.systemTemp.createTemp(
        'fluxora_restore_legacy_',
      );
      addTearDown(() => home.delete(recursive: true));
      final store = File(p.join(home.path, 'manual_proxies_a.json'));
      await store.writeAsString('[{"name":"later-node"}]');
      final snapshot = Archive()
        ..add(ArchiveFile.string('profiles/a.yml', 'original'));
      final manifest = FluxoraBackupFiles({'a'}, {});
      Future<void> restore(bool overwrite) => restoreBackupFiles(
        manifest.entriesForRestore(snapshot, all: false, overwrite: overwrite),
        home.path,
      );
      await restore(false);
      expect(await store.readAsString(), contains('later-node'));
      await restore(true);
      expect(await store.readAsString(), '[]');
      final canonical = File(p.join(home.path, 'profiles', 'a.yaml'));
      expect(await canonical.readAsString(), 'original');
      expect(
        await File(p.join(home.path, 'profiles', 'a.yml')).exists(),
        isFalse,
      );
      snapshot.add(ArchiveFile.string('profiles/a.yaml', 'conflicting'));
      await expectLater(restore(true), throwsFormatException);
      expect(await canonical.readAsString(), 'original');
    },
  );
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
