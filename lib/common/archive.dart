import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart';

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

Map<String, dynamic>? legacyBackupAccessControl(
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
  FluxoraBackupFiles(this.profileIds, this.scriptIds);

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
) async {
  final canonicalHome = canonicalize(homeDirPath);
  final homeDirectory = await Directory(homeDirPath).create(recursive: true);
  final home = await homeDirectory.resolveSymbolicLinks();
  final staging = await homeDirectory.createTemp('.fluxora-restore-');
  final pending = <({File target, File next, File? previous})>[];
  final targets = <String>{};
  var installed = 0;
  var keepRecoveryFiles = false;
  try {
    for (final profile in profiles) {
      final name = profile.name.replaceAll('\\', '/');
      if (!profile.isFile || name.endsWith('/')) continue;
      final path = canonicalize(join(homeDirPath, name));
      if (!isWithin(canonicalHome, path)) continue;
      if (!targets.add(path)) {
        throw FormatException('Duplicate backup file: $name');
      }
      final target = File(path);
      var ancestor = target.parent;
      while (!await ancestor.exists()) {
        ancestor = ancestor.parent;
      }
      final parent = await ancestor.resolveSymbolicLinks();
      if (!equals(parent, home) && !isWithin(home, parent)) continue;
      await target.parent.create(recursive: true);
      final index = pending.length;
      final next = File(join(staging.path, '$index.next'));
      await next.writeAsBytes(profile.content, flush: true);
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
