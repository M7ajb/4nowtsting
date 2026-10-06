import 'package:flutter/material.dart';

/// In-memory model for a single floating note on the board.
///
/// Kept in its own file so persistence (e.g. toMap/fromMap) and
/// connector lines (e.g. linked note ids) can be added later
/// without touching the board UI.
class BoardNote {
  final int id;
  Offset position;
  String text;
  Color color;
  String? audioPath;
  String? photoPath;

  BoardNote({
    required this.id,
    required this.position,
    this.text = '',
    this.color = const Color(0xFFFFF9C4),
    this.audioPath,
    this.photoPath,
  });

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'dx': position.dx,
      'dy': position.dy,
      'text': text,
      'color': color.value,
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
    final Object? rawAudioPath = json['audioPath'];
    final String? audioPath = rawAudioPath is String ? rawAudioPath : null;
    final Object? rawPhotoPath = json['photoPath'];
    final String? photoPath = rawPhotoPath is String ? rawPhotoPath : null;
    return BoardNote(
      id: id,
      position: Offset(dx, dy),
      text: text,
      color: Color(colorValue),
      audioPath: audioPath,
      photoPath: photoPath,
    );
  }
}
