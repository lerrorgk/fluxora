import 'dart:io';

import 'package:path/path.dart' as p;

final _invalidFilenameCharacters = RegExp(r'[<>:"/\\|?*\x00-\x1f]');
final _windowsDeviceName = RegExp(
  r'^(con|prn|aux|nul|conin\$|conout\$|com[1-9¹²³]|lpt[1-9¹²³]) *(\.|$)',
  caseSensitive: false,
);

/// IDs and filenames in a backup must be usable as single path components
/// on every supported platform, including after Windows name normalization.
String checkedDataPathSegment(String value) {
  if (value.trim().isEmpty ||
      value.endsWith('.') ||
      value.endsWith(' ') ||
      _invalidFilenameCharacters.hasMatch(value) ||
      _windowsDeviceName.hasMatch(value)) {
    throw const FormatException('Invalid filename in application data');
  }
  return value;
}

/// The data root may be chosen by the user. Below it, app-owned paths must
/// not be redirected by a link, including a dangling link at the destination.
Future<String> checkedDataPath(String home, List<String> segments) async {
  final root = p.normalize(p.absolute(home));
  var path = root;
  for (final segment in segments) {
    path = p.join(path, checkedDataPathSegment(segment));
    if (await FileSystemEntity.type(path, followLinks: false) ==
        FileSystemEntityType.link) {
      throw FileSystemException('Linked application data path', path);
    }
  }
  if (!p.isWithin(root, path)) {
    throw const FormatException('Expected a path inside the data directory');
  }
  return path;
}
