import 'package:flutter/material.dart';

/// Max attachments per note (user choice: cap at 10 each).
const int kMaxPhotosPerNote = 10;
const int kMaxAudiosPerNote = 10;

/// In-memory model for a single floating note on the board.
///
/// Notes live *inside* folders ([folderId], null = Unfiled) and can carry
/// multiple colored tags ([tagIds]).
/// Media is stored as lists (cap 10 each). Single-path legacy getters are
/// kept for backward compatibility with old JSON + existing tests.
class BoardNote {
  final int id;
  Offset position;
  String text;
  Color color;
  List<String> photoPaths;
  List<String> audioPaths;
  String? folderId;
  List<String> tagIds;

  BoardNote({
    required this.id,
    required this.position,
    this.text = '',
    this.color = const Color(0xFFFFF9C4),
    List<String>? photoPaths,
    List<String>? audioPaths,
    // Legacy single-path compat (deprecated, maps to lists).
    String? photoPath,
    String? audioPath,
    this.folderId,
    List<String>? tagIds,
  })  : photoPaths = _capped(
          photoPaths ??
              (photoPath != null && photoPath.isNotEmpty ? [photoPath] : []),
          kMaxPhotosPerNote,
        ),
        audioPaths = _capped(
          audioPaths ??
              (audioPath != null && audioPath.isNotEmpty ? [audioPath] : []),
          kMaxAudiosPerNote,
        ),
        tagIds = tagIds ?? [];

  static List<String> _capped(List<String> input, int cap) {
    final List<String> out = [];
    for (final String p in input) {
      if (p.isEmpty) continue;
      if (!out.contains(p)) out.add(p);
      if (out.length >= cap) break;
    }
    return out;
  }

  // Legacy accessors (first item or null).
  String? get photoPath => photoPaths.isEmpty ? null : photoPaths.first;
  set photoPath(String? v) {
    if (v == null || v.isEmpty) {
      if (photoPaths.isNotEmpty) photoPaths.removeAt(0);
    } else {
      if (photoPaths.isEmpty) {
        photoPaths.add(v);
      } else {
        photoPaths[0] = v;
      }
    }
  }

  String? get audioPath => audioPaths.isEmpty ? null : audioPaths.first;
  set audioPath(String? v) {
    if (v == null || v.isEmpty) {
      if (audioPaths.isNotEmpty) audioPaths.removeAt(0);
    } else {
      if (audioPaths.isEmpty) {
        audioPaths.add(v);
      } else {
        audioPaths[0] = v;
      }
    }
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'dx': position.dx,
      'dy': position.dy,
      'text': text,
      'color': color.value,
      // New list fields.
      'photoPaths': photoPaths,
      'audioPaths': audioPaths,
      'folderId': folderId,
      'tagIds': tagIds,
      // Legacy single fields for old readers/tests.
      'audioPath': audioPath,
      'photoPath': photoPath,
    };
  }

  factory BoardNote.fromJson(Map<String, dynamic> json) {
    final int id = (json['id'] as num).toInt();
    final double dx = (json['dx'] as num?)?.toDouble() ?? 0.0;
    final double dy = (json['dy'] as num?)?.toDouble() ?? 0.0;
    final String text = json['text'] as String? ?? '';
    final int colorValue = (json['color'] as num?)?.toInt() ?? 0xFFFFF9C4;

    List<String> photos = [];
    final Object? rawPhotos = json['photoPaths'];
    if (rawPhotos is List) {
      for (final Object? e in rawPhotos) {
        if (e is String && e.isNotEmpty) photos.add(e);
      }
    }
    // Fallback to legacy single field.
    if (photos.isEmpty) {
      final Object? rawPhotoPath = json['photoPath'];
      if (rawPhotoPath is String && rawPhotoPath.isNotEmpty) {
        photos.add(rawPhotoPath);
      }
    }

    List<String> audios = [];
    final Object? rawAudios = json['audioPaths'];
    if (rawAudios is List) {
      for (final Object? e in rawAudios) {
        if (e is String && e.isNotEmpty) audios.add(e);
      }
    }
    if (audios.isEmpty) {
      final Object? rawAudioPath = json['audioPath'];
      if (rawAudioPath is String && rawAudioPath.isNotEmpty) {
        audios.add(rawAudioPath);
      }
    }

    String? folderId;
    final Object? rawFolder = json['folderId'];
    if (rawFolder is String && rawFolder.isNotEmpty) folderId = rawFolder;

    final List<String> tagIds = [];
    final Object? rawTags = json['tagIds'];
    if (rawTags is List) {
      for (final Object? e in rawTags) {
        if (e is String && e.isNotEmpty && !tagIds.contains(e)) tagIds.add(e);
      }
    } else if (json['tagId'] is String &&
        (json['tagId'] as String).isNotEmpty) {
      tagIds.add(json['tagId'] as String);
    }

    return BoardNote(
      id: id,
      position: Offset(dx, dy),
      text: text,
      color: Color(colorValue),
      photoPaths: _capped(photos, kMaxPhotosPerNote),
      audioPaths: _capped(audios, kMaxAudiosPerNote),
      folderId: folderId,
      tagIds: tagIds,
    );
  }
}

/// Project folder: container for notes. Notes live *inside* folders.
/// [tagIds] = multiple colored tags assigned to the folder itself.
class BoardFolder {
  final String id;
  String name;
  Color color;
  List<String> tagIds;

  BoardFolder({
    required this.id,
    required this.name,
    this.color = const Color(0xFF90CAF9),
    List<String>? tagIds,
  }) : tagIds = tagIds ?? [];

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'color': color.value,
        'tagIds': tagIds,
      };

  factory BoardFolder.fromJson(Map<String, dynamic> json) {
    final String id = json['id']?.toString() ?? '';
    if (id.isEmpty) throw const FormatException('missing folder id');
    final String name = (json['name'] as String?)?.trim().isEmpty == true
        ? 'Untitled'
        : ((json['name'] as String?) ?? 'Untitled');
    final int colorValue =
        (json['color'] as num?)?.toInt() ?? 0xFF90CAF9;
    final List<String> tagIds = [];
    final Object? raw = json['tagIds'];
    if (raw is List) {
      for (final Object? e in raw) {
        if (e is String && e.isNotEmpty && !tagIds.contains(e)) tagIds.add(e);
      }
    }
    return BoardFolder(
      id: id,
      name: name,
      color: Color(colorValue),
      tagIds: tagIds,
    );
  }
}

/// Named + colored tag, assignable to notes and folders (multiple each).
class BoardTag {
  final String id;
  String name;
  Color color;

  BoardTag({
    required this.id,
    required this.name,
    this.color = const Color(0xFFFFD54F),
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'color': color.value,
      };

  factory BoardTag.fromJson(Map<String, dynamic> json) {
    final String id = json['id']?.toString() ?? '';
    if (id.isEmpty) throw const FormatException('missing tag id');
    final String name = (json['name'] as String?)?.trim().isEmpty == true
        ? 'Untitled'
        : ((json['name'] as String?) ?? 'Untitled');
    final int colorValue =
        (json['color'] as num?)?.toInt() ?? 0xFFFFD54F;
    return BoardTag(id: id, name: name, color: Color(colorValue));
  }
}

/// Generates a unique-ish id for folders/tags.
String newBoardId(String prefix) =>
    '${prefix}_${DateTime.now().microsecondsSinceEpoch}_${(1000 + (DateTime.now().microsecond % 9000))}';
