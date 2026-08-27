import 'dart:convert';

import 'package:path/path.dart' as path_util;

import '../ssh/ssh_connection.dart';

/// Loads the project instructions visible to a server Agent turn.
///
/// The lookup follows Codex's server-side convention: find the nearest `.git`
/// ancestor, then read one preferred instruction file per directory from that
/// root through the selected working directory. Without a project marker only
/// the selected directory is considered.
class RemoteProjectInstructions {
  const RemoteProjectInstructions();

  static const maxBytes = 32 * 1024;
  static const _filenames = ['AGENTS.override.md', 'AGENTS.md'];

  Future<String?> load(
    SshConnection connection,
    String? workingDirectory,
  ) async {
    final cwd = _normalizeDirectory(workingDirectory);
    if (cwd == null) return null;

    final listings = <String, List<SshDirectoryEntry>>{};
    final ancestors = <String>[];
    var current = cwd;
    String? projectRoot;
    while (true) {
      List<SshDirectoryEntry> entries;
      try {
        entries = await connection.listDirectory(current);
      } catch (_) {
        // Instructions are optional context. If an ancestor is not readable,
        // retain any listing already obtained and use the selected directory.
        break;
      }
      listings[current] = entries;
      ancestors.add(current);
      if (entries.any((entry) => entry.name == '.git')) {
        projectRoot = current;
        break;
      }
      if (current == '/') break;
      final parent = path_util.posix.dirname(current);
      if (parent == current) break;
      current = parent;
    }

    final directories = projectRoot == null
        ? <String>[cwd]
        : ancestors.reversed.toList(growable: false);
    var remaining = maxBytes;
    final documents = <String>[];
    for (final directory in directories) {
      if (remaining == 0) break;
      final entries = listings[directory];
      if (entries == null) continue;
      final instruction = _findInstruction(entries);
      if (instruction == null) continue;
      try {
        final chunk = await connection.readFileChunk(
          instruction.path,
          offset: 0,
          length: remaining,
        );
        final bytes = utf8.encode(chunk.content);
        var end = bytes.length;
        if (end > remaining) {
          end = remaining;
          while (end > 0) {
            try {
              utf8.decode(bytes.sublist(0, end));
              break;
            } on FormatException {
              end--;
            }
          }
        }
        final text = utf8.decode(bytes.sublist(0, end));
        if (text.trim().isEmpty) continue;
        documents.add(text);
        remaining -= end;
      } catch (_) {
        // A file may disappear between the directory listing and the read.
        // Do not make an otherwise usable server turn fail for optional docs.
      }
    }
    if (documents.isEmpty) return null;
    return documents.join('\n\n');
  }

  static SshDirectoryEntry? _findInstruction(List<SshDirectoryEntry> entries) {
    for (final filename in _filenames) {
      for (final entry in entries) {
        if (!entry.isDirectory && entry.name == filename) return entry;
      }
    }
    return null;
  }

  static String? _normalizeDirectory(String? value) {
    final trimmed = value?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;
    if (!path_util.posix.isAbsolute(trimmed)) return null;
    final normalized = path_util.posix.normalize(trimmed);
    return normalized.isEmpty ? '/' : normalized;
  }
}
