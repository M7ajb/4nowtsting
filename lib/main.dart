import 'package:flutter/material.dart';

import 'board_note.dart';

void main() {
  runApp(const ConnectionsBoardApp());
}

class ConnectionsBoardApp extends StatelessWidget {
  const ConnectionsBoardApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Connections Board',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.deepPurple,
          brightness: Brightness.light,
        ),
      ),
      home: const ConnectionsBoardScreen(),
    );
  }
}

class ConnectionsBoardScreen extends StatefulWidget {
  const ConnectionsBoardScreen({super.key});

  @override
  State<ConnectionsBoardScreen> createState() => _ConnectionsBoardScreenState();
}

class _ConnectionsBoardScreenState extends State<ConnectionsBoardScreen> {
  // Default background color for the board canvas
  Color _boardColor = const Color(0xFF1E1E2C);

  // In-memory floating notes (no persistence yet).
  final List<BoardNote> _notes = [];
  int _nextNoteId = 0;

  static const double noteWidth = 160;
  static const double noteHeight = 120;

  // Preset colors for quick selection in the color picker
  static const List<Color> _presetColors = [
    Color(0xFF1E1E2C), // Dark Slate
    Color(0xFF121212), // Dark Charcoal
    Color(0xFF2C3E50), // Midnight Blue
    Color(0xFF1A365D), // Deep Navy
    Color(0xFF1C3A27), // Forest Green
    Color(0xFF3B1F2B), // Deep Wine
    Color(0xFF2D2039), // Dark Purple
    Color(0xFF4A3E3D), // Warm Taupe
    Color(0xFFF5F5F7), // Soft Light
    Color(0xFFE2E8F0), // Cool Grey
    Color(0xFFFEF3C7), // Warm Cream
    Color(0xFFDCFCE7), // Mint Green
    Color(0xFFE0F2FE), // Sky Blue
    Color(0xFFFCE7F3), // Pastel Pink
    Color(0xFFF3E8FF), // Soft Lavender
    Color(0xFFFFFFFF), // Pure White
  ];

  void _openColorPicker() {
    showDialog(
      context: context,
      builder: (context) {
        return _ColorPickerDialog(
          currentColor: _boardColor,
          presetColors: _presetColors,
          onColorSelected: (newColor) {
            setState(() {
              _boardColor = newColor;
            });
          },
        );
      },
    );
  }

  void _addNote() {
    final Size size = MediaQuery.of(context).size;
    final double dx = (size.width - noteWidth) / 2;
    final double dy = (size.height - noteHeight) / 2;
    setState(() {
      _notes.add(
        BoardNote(
          id: _nextNoteId++,
          position: Offset(dx.clamp(0.0, double.infinity), dy.clamp(0.0, double.infinity)),
        ),
      );
    });
  }

  void _bringToFront(int id) {
    final int index = _notes.indexWhere((n) => n.id == id);
    // Root cause fix for drag cancellation: skip rebuild when already front.
    // Reordering during onPanStart disposes the active pan recognizer.
    if (index == -1 || index == _notes.length - 1) return;
    setState(() {
      final BoardNote note = _notes.removeAt(index);
      _notes.add(note);
    });
  }

  void _moveNote(int id, Offset delta, Size viewport) {
    setState(() {
      final int index = _notes.indexWhere((n) => n.id == id);
      if (index == -1) return;
      final BoardNote note = _notes[index];
      final double maxX = (viewport.width - noteWidth).clamp(0.0, double.infinity);
      final double maxY = (viewport.height - noteHeight).clamp(0.0, double.infinity);
      final double nx = (note.position.dx + delta.dx).clamp(0.0, maxX);
      final double ny = (note.position.dy + delta.dy).clamp(0.0, maxY);
      note.position = Offset(nx, ny);
    });
  }

  Future<void> _openNoteEditor(BoardNote note) async {
    final String? updated = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => NoteEditorPage(initialText: note.text),
      ),
    );
    if (!mounted) return;
    if (updated != null && updated != note.text) {
      setState(() {
        note.text = updated;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // Calculate contrast color for the top-right button icon border/shadow
    final double luminance = _boardColor.computeLuminance();
    final bool isDark = luminance < 0.5;
    final Color buttonFgColor = isDark ? Colors.white : Colors.black87;
    final Color buttonBgColor = isDark
        ? Colors.black.withOpacity(0.4)
        : Colors.white.withOpacity(0.8);
    final Size viewport = MediaQuery.of(context).size;

    return Scaffold(
      body: Stack(
        children: [
          // Full-screen canvas with animated background color transition
          AnimatedContainer(
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOutCubic,
            width: double.infinity,
            height: double.infinity,
            color: _boardColor,
          ),

          // Floating notes (painted in list order, last on top).
          for (final BoardNote note in _notes)
            Positioned(
              left: note.position.dx,
              top: note.position.dy,
              child: _NoteCard(
                key: ValueKey('note_card_${note.id}'),
                note: note,
                onDragStart: () => _bringToFront(note.id),
                onDragUpdate: (delta) => _moveNote(note.id, delta, viewport),
                onLongPress: () => _openNoteEditor(note),
              ),
            ),

          // Small color-picker button fixed in the top-right corner
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Align(
                alignment: Alignment.topRight,
                child: Material(
                color: Colors.transparent,
                child: Tooltip(
                  message: 'Change Board Background Color',
                  child: InkWell(
                    onTap: _openColorPicker,
                    borderRadius: BorderRadius.circular(24),
                    child: Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: buttonBgColor,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: buttonFgColor.withOpacity(0.3),
                          width: 1.5,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.2),
                            blurRadius: 8,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          Icon(
                            Icons.palette_outlined,
                            size: 22,
                            color: buttonFgColor,
                          ),
                          // Small indicator dot showing current color preview
                          Positioned(
                            bottom: 6,
                            right: 6,
                            child: Container(
                              width: 10,
                              height: 10,
                              decoration: BoxDecoration(
                                color: _boardColor,
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: buttonFgColor,
                                  width: 1.5,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          ),
          // Add-note button fixed in the bottom-right corner.
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Align(
                alignment: Alignment.bottomRight,
                child: Material(
                  color: Colors.transparent,
                  child: Tooltip(
                    message: 'Add note',
                    child: InkWell(
                      onTap: _addNote,
                      borderRadius: BorderRadius.circular(28),
                      child: Container(
                        width: 56,
                        height: 56,
                        decoration: BoxDecoration(
                          color: buttonBgColor,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: buttonFgColor.withOpacity(0.3),
                            width: 1.5,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.2),
                              blurRadius: 8,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        child: Icon(
                          Icons.add,
                          size: 28,
                          color: buttonFgColor,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _NoteCard extends StatelessWidget {
  final BoardNote note;
  final VoidCallback onDragStart;
  final ValueChanged<Offset> onDragUpdate;
  final VoidCallback onLongPress;

  const _NoteCard({
    super.key,
    required this.note,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final bool isEmpty = note.text.isEmpty;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanStart: (_) => onDragStart(),
      onPanUpdate: (details) => onDragUpdate(details.delta),
      child: Container(
        width: _ConnectionsBoardScreenState.noteWidth,
        height: _ConnectionsBoardScreenState.noteHeight,
        decoration: BoxDecoration(
          color: note.color,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.black.withOpacity(0.15)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.25),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Column(
          children: [
            // Drag handle: guaranteed pan area so dragging works.
            // Whole card remains wrapped in the outer pan
            // GestureDetector, so edge drags work too.
            // Long-press is isolated to the preview body so handle
            // drags never compete with the long-press recognizer.
            Container(
              key: ValueKey('note_handle_${note.id}'),
              height: 24,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.08),
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(12),
                  topRight: Radius.circular(12),
                ),
              ),
              child: const Icon(Icons.drag_handle, size: 16, color: Colors.black54),
            ),
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onLongPress: onLongPress,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
                  child: Align(
                    alignment: Alignment.topLeft,
                    child: Text(
                      isEmpty ? 'Note' : note.text,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        color: isEmpty ? Colors.black45 : Colors.black87,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class NoteEditorPage extends StatefulWidget {
  final String initialText;

  const NoteEditorPage({super.key, required this.initialText});

  @override
  State<NoteEditorPage> createState() => _NoteEditorPageState();
}

class _NoteEditorPageState extends State<NoteEditorPage> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialText);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        Navigator.of(context).pop(_controller.text);
      },
      child: Scaffold(
        appBar: AppBar(
          leading: const BackButton(),
        ),
        body: Padding(
          padding: const EdgeInsets.all(16.0),
          child: TextField(
            controller: _controller,
            autofocus: true,
            maxLines: null,
            expands: true,
            keyboardType: TextInputType.multiline,
            textAlignVertical: TextAlignVertical.top,
            style: const TextStyle(fontSize: 16, color: Colors.black87),
            decoration: const InputDecoration(
              border: InputBorder.none,
              hintText: 'Note',
              isDense: true,
              contentPadding: EdgeInsets.zero,
            ),
          ),
        ),
      ),
    );
  }
}

class _ColorPickerDialog extends StatefulWidget {
  final Color currentColor;
  final List<Color> presetColors;
  final ValueChanged<Color> onColorSelected;

  const _ColorPickerDialog({
    required this.currentColor,
    required this.presetColors,
    required this.onColorSelected,
  });

  @override
  State<_ColorPickerDialog> createState() => _ColorPickerDialogState();
}

class _ColorPickerDialogState extends State<_ColorPickerDialog> {
  late Color _selectedColor;
  late double _red;
  late double _green;
  late double _blue;

  @override
  void initState() {
    super.initState();
    _selectedColor = widget.currentColor;
    _red = widget.currentColor.red.toDouble();
    _green = widget.currentColor.green.toDouble();
    _blue = widget.currentColor.blue.toDouble();
  }

  void _updateFromSliders() {
    setState(() {
      _selectedColor = Color.fromRGBO(
        _red.round(),
        _green.round(),
        _blue.round(),
        1.0,
      );
    });
  }

  void _selectPreset(Color color) {
    setState(() {
      _selectedColor = color;
      _red = color.red.toDouble();
      _green = color.green.toDouble();
      _blue = color.blue.toDouble();
    });
  }

  String _toHex(Color color) {
    return '#${color.value.toRadixString(16).padLeft(8, '0').substring(2).toUpperCase()}';
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Row(
        children: [
          const Icon(Icons.color_lens, size: 24),
          const SizedBox(width: 10),
          const Text('Board Color'),
          const Spacer(),
          // Current color preview badge
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: _selectedColor,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.grey.shade400, width: 2),
            ),
          ),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Presets',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: widget.presetColors.map((color) {
                final isSelected = _selectedColor.value == color.value;
                return GestureDetector(
                  onTap: () => _selectPreset(color),
                  child: Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: isSelected ? Colors.blueAccent : Colors.grey.shade400,
                        width: isSelected ? 3.0 : 1.0,
                      ),
                      boxShadow: isSelected
                          ? [
                              BoxShadow(
                                color: Colors.blueAccent.withOpacity(0.4),
                                blurRadius: 6,
                                spreadRadius: 1,
                              )
                            ]
                          : null,
                    ),
                    child: isSelected
                        ? Icon(
                            Icons.check,
                            size: 20,
                            color: color.computeLuminance() > 0.5
                                ? Colors.black
                                : Colors.white,
                          )
                        : null,
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 20),
            const Divider(),
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Custom RGB',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                ),
                Text(
                  _toHex(_selectedColor),
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.w600,
                    color: Colors.grey.shade700,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            // Red Slider
            Row(
              children: [
                const SizedBox(
                  width: 18,
                  child: Text('R', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.red)),
                ),
                Expanded(
                  child: Slider(
                    value: _red,
                    min: 0,
                    max: 255,
                    activeColor: Colors.red,
                    onChanged: (val) {
                      _red = val;
                      _updateFromSliders();
                    },
                  ),
                ),
                SizedBox(
                  width: 32,
                  child: Text(_red.round().toString(), textAlign: TextAlign.right),
                ),
              ],
            ),
            // Green Slider
            Row(
              children: [
                const SizedBox(
                  width: 18,
                  child: Text('G', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.green)),
                ),
                Expanded(
                  child: Slider(
                    value: _green,
                    min: 0,
                    max: 255,
                    activeColor: Colors.green,
                    onChanged: (val) {
                      _green = val;
                      _updateFromSliders();
                    },
                  ),
                ),
                SizedBox(
                  width: 32,
                  child: Text(_green.round().toString(), textAlign: TextAlign.right),
                ),
              ],
            ),
            // Blue Slider
            Row(
              children: [
                const SizedBox(
                  width: 18,
                  child: Text('B', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.blue)),
                ),
                Expanded(
                  child: Slider(
                    value: _blue,
                    min: 0,
                    max: 255,
                    activeColor: Colors.blue,
                    onChanged: (val) {
                      _blue = val;
                      _updateFromSliders();
                    },
                  ),
                ),
                SizedBox(
                  width: 32,
                  child: Text(_blue.round().toString(), textAlign: TextAlign.right),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: () {
            widget.onColorSelected(_selectedColor);
            Navigator.of(context).pop();
          },
          child: const Text('Apply'),
        ),
      ],
    );
  }
}
