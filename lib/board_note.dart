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

  BoardNote({
    required this.id,
    required this.position,
    this.text = '',
    this.color = const Color(0xFFFFF9C4),
  });
}
