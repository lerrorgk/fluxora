import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart';
import 'package:synchronized/synchronized.dart';

import 'data_path.dart';

final profileFilesLock = Lock(reentrant: true);

extension ArchiveExt on Archive {
  Future<void> addDirectoryToArchive(String dirPath, String parentPath) async {
    final dir = Directory(dirPath);
    final entities = await dir.list(recursive: false).toList();
    for (final entity in entities) {
      final relativePath = relative(
        entity.path,
        from: parentPath,
      ).replaceAll('\\', '/');
      if (entity is File) {
        final data = await entity.readAsBytes();
        final archiveFile = ArchiveFile(relativePath, data.length, data);
        addFile(archiveFile);
      } else if (entity is Directory) {
        await addDirectoryToArchive(entity.path, parentPath);
      }
    }
  }

  void add<T>(String name, T raw) {
    final data = json.encode(raw);
    addFile(ArchiveFile(name, data.length, utf8.encode(data)));
  }
}

Map<String, dynamic>? backupAccessControl(
  Map<String, dynamic> config, {
  required bool restoreAll,
}) {
  if (!restoreAll) return null;
  final vpn = config['vpnProps'];
  final nested = vpn is Map
      ? vpn['accessControl'] ?? vpn['accessControlProps']
      : null;
  final control = nested ?? config['accessControl'];
  return control is Map ? Map<String, dynamic>.from(control) : null;
}

const routingBackupFiles = {
  'fixed_proxy_routes.json',
  'chain_proxies.json',
  'chain_fallback_pool.json',
  'profile_chains.json',
  'warp_config.json',
};

/// Files owned by the selected subscriptions, and optionally the app settings.
class FluxoraBackupFiles {
  FluxoraBackupFiles(this.profileIds, this.scriptIds) {
    for (final id in profileIds) {
      checkedDataPathSegment(id);
    }
  }

  final Set<String> profileIds;
  final Set<String> scriptIds;

  bool includes(String name, {required bool all}) {
    final parts = name.split('/');
    if (parts.any(
      (p) =>
          p.isEmpty ||
          p == '.' ||
          p == '..' ||
          p.contains('\\') ||
          p.contains(':'),
    )) {
      return false;
    }
    if (parts.first == 'profiles') {
      if (parts.length == 2) {
        final ext = posix.extension(parts.last);
        return (ext == '.yaml' || ext == '.yml') &&
            profileIds.contains(posix.basenameWithoutExtension(parts.last));
      }
      return parts.length >= 4 &&
          parts[1] == 'providers' &&
          profileIds.contains(parts[2]);
    }
    if (parts.length == 1 &&
        name.startsWith('manual_proxies_') &&
        name.endsWith('.json')) {
      return profileIds.contains(
        name.substring('manual_proxies_'.length, name.length - '.json'.length),
      );
    }
    if (!all) return false;
    if (routingBackupFiles.contains(name)) return true;
    return parts.length == 2 &&
        parts.first == 'scripts' &&
        parts.last.endsWith('.js') &&
        scriptIds.contains(posix.basenameWithoutExtension(parts.last));
  }

  Iterable<ArchiveFile> entriesForRestore(
    Archive archive, {
    required bool all,
    required bool overwrite,
  }) sync* {
    final missing = {
      if (overwrite)
        for (final id in profileIds) 'manual_proxies_$id.json',
    };
    var hasFixedRoutes = false;
    for (final entry in archive.files) {
      final name = entry.name.replaceAll('\\', '/');
      if (!entry.isFile || !includes(name, all: all)) continue;
      missing.remove(name);
      if (name == 'fixed_proxy_routes.json') hasFixedRoutes = true;
      yield entry;
    }
    // Older snapshots omit the sidecar for a profile with no manual nodes.
    for (final name in missing) {
      yield ArchiveFile.string(name, '[]');
    }
    // Older full backups predate fixed_proxy_routes.json; overwrite clears
    // local routes so stale references to replaced profiles are not retained.
    if (all && overwrite && !hasFixedRoutes) {
      yield ArchiveFile.string(
        'fixed_proxy_routes.json',
        '{"version":1,"routes":[]}',
      );
    }
  }

  Future<List<int>> encode(
    String home,
    String configJson,
    Map<String, Object?> routingDefaults,
  ) async {
    final temp = await Directory.systemTemp.createTemp('fluxora_backup_');
    try {
      final file = File(join(temp.path, 'backup.zip'));
      final encoder = ZipFileEncoder()..create(file.path);
      try {
        encoder.addArchiveFile(
          ArchiveFile.string(
            '.fluxora_marker',
            jsonEncode({'app': 'Fluxora', 'version': '2.0'}),
          ),
        );
        encoder.addArchiveFile(ArchiveFile.string('config.json', configJson));
        final found = <String>{};
        Future<void> add(File entry) async {
          final name = relative(entry.path, from: home).replaceAll('\\', '/');
          if (!includes(name, all: true)) return;
          await encoder.addFile(entry, name);
          found.add(name);
        }

        await for (final entry in Directory(home).list(followLinks: false)) {
          if (entry is File) {
            await add(entry);
          } else if (entry is Directory &&
              {'profiles', 'scripts'}.contains(basename(entry.path))) {
            await for (final child in entry.list(
              recursive: true,
              followLinks: false,
            )) {
              if (child is File) await add(child);
            }
          }
        }
        for (final entry in routingDefaults.entries) {
          if (!found.contains(entry.key) &&
              routingBackupFiles.contains(entry.key)) {
            encoder.addArchiveFile(
              ArchiveFile.string(entry.key, jsonEncode(entry.value)),
            );
          }
        }
      } finally {
        await encoder.close();
      }
      return await file.readAsBytes();
    } finally {
      await temp.delete(recursive: true);
    }
  }
}

Future<void> restoreBackupFiles(
  Iterable<ArchiveFile> profiles,
  String homeDirPath,
) => profileFilesLock.synchronized(
  () => replaceDataFiles(
    homeDirPath,
    profiles.where((entry) => entry.isFile && !entry.name.endsWith('/')).map((
      entry,
    ) {
      var name = entry.name.replaceAll('\\', '/');
      if (posix.dirname(name) == 'profiles' &&
          posix.extension(name) == '.yml') {
        name = posix.setExtension(name, '.yaml');
      }
      return MapEntry(name, entry.content);
    }),
  ),
);

/// Stage all related files before replacing any of them, and restore the
/// original contents if a later replacement fails.
Future<void> replaceDataFiles(
  String homeDirPath,
  Iterable<MapEntry<String, List<int>>> files,
) async {
  final homeDirectory = await Directory(homeDirPath).create(recursive: true);
  final staging = await homeDirectory.createTemp('.fluxora-restore-');
  final pending = <({File target, File next, File? previous})>[];
  final targets = <String>{};
  var installed = 0;
  var keepRecoveryFiles = false;
  try {
    for (final file in files) {
      final name = file.key;
      final path = await checkedDataPath(homeDirPath, name.split('/'));
      if (!targets.add(canonicalize(path))) {
        throw FormatException('Duplicate backup file: $name');
      }
      final target = File(path);
      await target.parent.create(recursive: true);
      final index = pending.length;
      final next = File(join(staging.path, '$index.next'));
      await next.writeAsBytes(file.value, flush: true);
      final previous = await target.exists()
          ? await target.copy(join(staging.path, '$index.previous'))
          : null;
      pending.add((target: target, next: next, previous: previous));
    }
    for (final item in pending) {
      await item.next.rename(item.target.path);
      installed++;
    }
  } catch (_) {
    // Restore files that were already replaced if any later installation fails.
    try {
      for (final item in pending.take(installed).toList().reversed) {
        final previous = item.previous;
        if (previous == null) {
          await item.target.delete();
        } else {
          await previous.rename(item.target.path);
        }
      }
    } catch (rollbackError) {
      keepRecoveryFiles = true;
      throw FileSystemException(
        'Could not roll back backup restore: $rollbackError',
        staging.path,
      );
    }
    rethrow;
  } finally {
    if (!keepRecoveryFiles) await staging.delete(recursive: true);
  }
}
