import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'board_note.dart';

void main() {
  runApp(const ConnectionsBoardApp());
}

/// Deletes attachment files for a removed note. Extracted for unit testing
/// so real file deletion is verified without pumping images in widget tests.
Future<void> deleteNoteAttachmentFiles(List<String?> paths) async {
  for (final String? path in paths) {
    if (path == null || path.isEmpty) continue;
    try {
      final File file = File(path);
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }
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

  // In-memory floating notes (persisted to shared_preferences as JSON).
  final List<BoardNote> _notes = [];
  int _nextNoteId = 0;
  bool _notesLoaded = false;

  static const String _prefsKey = 'connections_board_notes';

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

  @override
  void initState() {
    super.initState();
    // Show board immediately, populate notes once loaded (no splash).
    unawaited(_loadNotes());
  }

  Future<void> _loadNotes() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final String? raw = prefs.getString(_prefsKey);
      if (raw == null || raw.isEmpty) {
        if (mounted) setState(() => _notesLoaded = true);
        return;
      }
      final List<dynamic> decoded = jsonDecode(raw) as List<dynamic>;
      final List<BoardNote> loaded = [];
      final Set<int> seenIds = {};
      for (final dynamic entry in decoded) {
        // Root cause: one corrupt entry aborted the whole load via outer
        // catch. Fix: skip bad entries individually.
        // Duplicate ids would also collide ValueKeys and misdirect
        // move/delete (indexWhere hits first). Skip dupes.
        try {
          BoardNote? note;
          if (entry is Map<String, dynamic>) {
            note = BoardNote.fromJson(entry);
          } else if (entry is Map) {
            note = BoardNote.fromJson(Map<String, dynamic>.from(entry));
          }
          if (note == null) continue;
          if (!seenIds.add(note.id)) continue;
          loaded.add(note);
        } catch (_) {
          continue;
        }
      }
      if (!mounted) return;
      setState(() {
        _notes
          ..clear()
          ..addAll(loaded);
        int maxId = -1;
        for (final BoardNote note in _notes) {
          if (note.id > maxId) maxId = note.id;
        }
        _nextNoteId = maxId + 1;
        _notesLoaded = true;
      });
    } catch (_) {
      // Corrupt/missing storage: keep board empty.
      if (mounted) setState(() => _notesLoaded = true);
    }
  }

  Future<void> _saveNotes() async {
    // Root cause: encoding after await could snapshot a stale list during
    // rapid moves. Fix: snapshot synchronously before any await.
    final String raw = jsonEncode(
      _notes.map((BoardNote note) => note.toJson()).toList(),
    );
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKey, raw);
    } catch (_) {
      // Storage unavailable (e.g. tests): ignore.
    }
  }

  void _addNote() {
    final Size size = MediaQuery.of(context).size;
    // Cascade so stacked notes stay reachable: exact overlap means only the
    // top note ever hit-tests. Offset wraps and clamps to viewport.
    final double step = (_notes.length * 28) % 140;
    final double maxX = (size.width - noteWidth).clamp(0.0, double.infinity);
    final double maxY = (size.height - noteHeight).clamp(0.0, double.infinity);
    final double dx = ((size.width - noteWidth) / 2 + step).clamp(0.0, maxX);
    final double dy = ((size.height - noteHeight) / 2 + step).clamp(0.0, maxY);
    setState(() {
      _notes.add(
        BoardNote(
          id: _nextNoteId++,
          position: Offset(dx, dy),
        ),
      );
    });
    unawaited(_saveNotes());
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
    unawaited(_saveNotes());
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
    // No save here: onPanUpdate fires per-pixel and would spam
    // SharedPreferences. Persist once on drag end.
  }

  void _finishDrag() {
    unawaited(_saveNotes());
  }

  Future<void> _openNoteEditor(BoardNote note) async {
    final NoteEditorResult? updated =
        await Navigator.of(context).push<NoteEditorResult>(
      MaterialPageRoute(
        builder: (_) => NoteEditorPage(
          initialText: note.text,
          noteId: note.id,
          initialAudioPath: note.audioPath,
          initialPhotoPath: note.photoPath,
        ),
      ),
    );
    if (!mounted) return;
    if (updated == null) return;
    if (updated.deleted) {
      await _deleteNote(note.id);
      return;
    }
    if (updated.text != note.text ||
        updated.audioPath != note.audioPath ||
        updated.photoPath != note.photoPath) {
      setState(() {
        note.text = updated.text;
        note.audioPath = updated.audioPath;
        note.photoPath = updated.photoPath;
      });
      unawaited(_saveNotes());
    }
  }

  Future<void> _deleteNote(int id) async {
    final int index = _notes.indexWhere((n) => n.id == id);
    if (index == -1) return;
    final BoardNote removed = _notes[index];
    setState(() {
      _notes.removeAt(index);
    });
    unawaited(_saveNotes());
    await deleteNoteAttachmentFiles([removed.audioPath, removed.photoPath]);
    // Best-effort cleanup of an interrupted recording tmp file.
    // Derive from the audio sibling dir first so tests without
    // path_provider still clean up; docs lookup has a timeout so a
    // missing plugin never hangs delete.
    final List<String> tmpCandidates = [];
    if (removed.audioPath != null && removed.audioPath!.isNotEmpty) {
      try {
        tmpCandidates.add(
          '${File(removed.audioPath!).parent.path}/note_${removed.id}_tmp.m4a',
        );
      } catch (_) {}
    }
    try {
      final Directory docs = await getApplicationDocumentsDirectory()
          .timeout(const Duration(seconds: 2));
      tmpCandidates.add('${docs.path}/note_${removed.id}_tmp.m4a');
    } catch (_) {}
    for (final String tmpPath in tmpCandidates.toSet()) {
      try {
        final File tmp = File(tmpPath);
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {}
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
                onDragEnd: () => _finishDrag(),
                onLongPress: () => _openNoteEditor(note),
                onTap: () => _bringToFront(note.id),
              ),
            ),

          // Empty-state hint instead of a blank board (only after load,
          // so saved notes don't flash a hint on startup).
          if (_notes.isEmpty && _notesLoaded)
            const Center(
              child: Text(
                'Tap + to add your first note',
                key: ValueKey('empty_state_hint'),
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 16, color: Colors.white70),
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
  final VoidCallback onDragEnd;
  final VoidCallback onLongPress;
  final VoidCallback onTap;

  const _NoteCard({
    super.key,
    required this.note,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
    required this.onLongPress,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final bool hasText = note.text.trim().isNotEmpty;
    final bool hasAttachments =
        note.audioPath != null || note.photoPath != null;
    final String previewText;
    final Color previewColor;
    if (hasText) {
      previewText = note.text;
      previewColor = Colors.black87;
    } else if (hasAttachments) {
      previewText = 'Note';
      previewColor = Colors.black45;
    } else {
      previewText = 'Tap to write';
      previewColor = Colors.black45;
    }
    final bool hasPhoto = note.photoPath != null;
    // Root cause of the audio/photo regression: the preview body used a
    // nested inner GestureDetector (tap/long-press) inside an outer pan
    // detector. Ancestor + descendant recognizers compete in the arena, so
    // on a real device the outer pan wins with any finger jitter during the
    // long-press timeout and the editor becomes unreachable. Since the card
    // is a read-only preview (inline TextField was removed for the editor),
    // losing the editor also meant tapping could never lead to typing.
    // Fix: no outer wrapper. Handle is pan-only (precise drag, no tap
    // competition eating ~20px slop); preview body owns pan + tap +
    // long-press in one detector so they share a single arena.
    return Container(
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
          // Drag handle: pan-only for pixel-exact drags (adding tap here
          // eats ~20px slop and regressed the drag test). Tap-to-front
          // lives on the preview body below, the larger target; dragging
          // via the handle already brings to front through onPanStart.
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanStart: (_) => onDragStart(),
            onPanUpdate: (details) => onDragUpdate(details.delta),
            onPanEnd: (_) => onDragEnd(),
            child: Container(
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
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.drag_handle,
                      size: 16, color: Colors.black54),
                  if (hasPhoto) ...[
                    const SizedBox(width: 4),
                    Icon(
                      Icons.photo,
                      key: ValueKey('photo_indicator_${note.id}'),
                      size: 14,
                      color: Colors.black54,
                    ),
                  ],
                ],
              ),
            ),
          ),
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanStart: (_) => onDragStart(),
              onPanUpdate: (details) => onDragUpdate(details.delta),
              onPanEnd: (_) => onDragEnd(),
              onTap: onTap,
              onLongPress: onLongPress,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Align(
                        alignment: Alignment.topLeft,
                        child: Text(
                          previewText,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 14,
                            color: previewColor,
                          ),
                        ),
                      ),
                    ),
                    if (hasPhoto) ...[
                      const SizedBox(width: 4),
                      _PhotoThumb(
                        path: note.photoPath!,
                        size: 36,
                        key: ValueKey('photo_thumb_card_${note.id}'),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PhotoThumb extends StatelessWidget {
  final String path;
  final double size;

  const _PhotoThumb({super.key, required this.path, required this.size});

  @override
  Widget build(BuildContext context) {
    final File file = File(path);
    if (!file.existsSync()) {
      return Icon(Icons.photo_outlined,
          size: size * 0.6, color: Colors.black45);
    }
    final int px = (size * 2).round();
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: Image.file(
        file,
        width: size,
        height: size,
        cacheWidth: px,
        cacheHeight: px,
        fit: BoxFit.cover,
        errorBuilder: (context, error, stackTrace) => const Icon(
          Icons.photo_outlined,
          size: 20,
          color: Colors.black45,
        ),
      ),
    );
  }
}

typedef PhotoPickerFn = Future<XFile?> Function(ImageSource source);

class NoteEditorResult {
  final String text;
  final String? audioPath;
  final String? photoPath;
  final bool deleted;

  const NoteEditorResult({
    required this.text,
    this.audioPath,
    this.photoPath,
    this.deleted = false,
  });
}

class NoteEditorPage extends StatefulWidget {
  final String initialText;
  final int noteId;
  final String? initialAudioPath;
  final String? initialPhotoPath;
  final PhotoPickerFn? photoPicker;

  const NoteEditorPage({
    super.key,
    required this.initialText,
    required this.noteId,
    this.initialAudioPath,
    this.initialPhotoPath,
    this.photoPicker,
  });

  @override
  State<NoteEditorPage> createState() => _NoteEditorPageState();
}

class _NoteEditorPageState extends State<NoteEditorPage> {
  late final TextEditingController _controller;
  late final AudioPlayer _player;
  AudioRecorder? _recorder;
  StreamSubscription<void>? _completeSub;

  String? _audioPath;
  String? _photoPath;
  String? _tmpPath;
  bool _isRecording = false;
  bool _isPlaying = false;
  bool _isPickingPhoto = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialText);
    _audioPath = widget.initialAudioPath;
    _photoPath = widget.initialPhotoPath;
    _player = AudioPlayer();
    _completeSub = _player.onPlayerComplete.listen((_) {
      if (mounted) setState(() => _isPlaying = false);
    });
    unawaited(_validateInitialPhoto());
  }

  Future<void> _validateInitialPhoto() async {
    final String? path = _photoPath;
    if (path == null) return;
    final bool exists = await File(path).exists();
    if (!exists && mounted) setState(() => _photoPath = null);
  }

  @override
  void dispose() {
    _completeSub?.cancel();
    // Best-effort discard of an in-progress recording so popping mid-record
    // neither leaks note_X_tmp.m4a nor races dispose() against cancel().
    final String? tmp = _tmpPath;
    if (_isRecording) {
      try {
        _recorder?.cancel();
      } catch (_) {}
      if (tmp != null && tmp.isNotEmpty) {
        try {
          File(tmp).delete().ignore();
        } catch (_) {}
      }
    }
    _recorder?.dispose();
    _player.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _popWithResult() {
    Navigator.of(context).pop(
      NoteEditorResult(
        text: _controller.text,
        audioPath: _audioPath,
        photoPath: _photoPath,
      ),
    );
  }

  Future<void> _toggleRecord() async {
    if (_isRecording) {
      await _stopRecording();
      return;
    }
    if (_isPlaying) {
      await _player.stop();
      if (mounted) setState(() => _isPlaying = false);
    }
    PermissionStatus status = await Permission.microphone.status;
    if (!status.isGranted) {
      status = await Permission.microphone.request();
    }
    if (!status.isGranted) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Microphone permission denied')),
      );
      return;
    }
    try {
      final Directory docs = await getApplicationDocumentsDirectory();
      final String tmpPath = '${docs.path}/note_${widget.noteId}_tmp.m4a';
      _tmpPath = tmpPath;
      _recorder ??= AudioRecorder();
      await _recorder!.start(const RecordConfig(), path: tmpPath);
      if (mounted) setState(() => _isRecording = true);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not start recording')),
      );
    }
  }

  Future<void> _stopRecording() async {
    try {
      final String? stoppedPath = await _recorder?.stop();
      final Directory docs = await getApplicationDocumentsDirectory();
      final String finalPath = '${docs.path}/note_${widget.noteId}.m4a';
      String? resolved = finalPath;
      if (stoppedPath != null && stoppedPath != finalPath) {
        // Promote tmp recording so abort (cancel) never deletes old clip.
        final File tmpFile = File(stoppedPath);
        if (await tmpFile.exists()) {
          if (await File(finalPath).exists()) {
            await File(finalPath).delete();
          }
          await tmpFile.rename(finalPath);
        } else {
          resolved = stoppedPath;
        }
      } else if (stoppedPath == null) {
        // Recorder produced nothing: keep previous clip, don't invent one.
        resolved = null;
      }
      // Guard against phantom paths: only publish if the file is really there.
      if (resolved != null && !await File(resolved).exists()) {
        resolved = null;
      }
      _tmpPath = null;
      if (mounted) {
        setState(() {
          _isRecording = false;
          // Keep old clip when stop yields nothing usable.
          if (resolved != null) _audioPath = resolved;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _isRecording = false);
    }
  }

  Future<void> _togglePlayback() async {
    final String? path = _audioPath;
    if (path == null) return;
    try {
      if (_isPlaying) {
        await _player.pause();
        if (mounted) setState(() => _isPlaying = false);
      } else {
        if (!await File(path).exists()) {
          if (mounted) {
            setState(() {
              _audioPath = null;
              _isPlaying = false;
            });
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Audio file not found')),
            );
          }
          return;
        }
        if (_player.state == PlayerState.paused) {
          await _player.resume();
        } else {
          await _player.play(DeviceFileSource(path));
        }
        if (mounted) setState(() => _isPlaying = true);
      }
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not play audio')),
      );
    }
  }

  Future<XFile?> _defaultPhotoPicker(ImageSource source) {
    return ImagePicker().pickImage(
      source: source,
      imageQuality: 85,
      maxWidth: 1600,
    );
  }

  void _showPhotoSourceSheet() {
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                key: const ValueKey('photo_source_camera'),
                leading: const Icon(Icons.camera_alt),
                title: const Text('Take photo'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  unawaited(_pickPhoto(ImageSource.camera));
                },
              ),
              ListTile(
                key: const ValueKey('photo_source_gallery'),
                leading: const Icon(Icons.photo_library),
                title: const Text('Choose from gallery'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  unawaited(_pickPhoto(ImageSource.gallery));
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _pickPhoto(ImageSource source) async {
    if (_isPickingPhoto) return;
    setState(() => _isPickingPhoto = true);
    try {
      final PhotoPickerFn picker = widget.photoPicker ?? _defaultPhotoPicker;
      final XFile? picked = await picker(source);
      if (!mounted) return;
      if (picked == null) return;
      final Directory docs = await getApplicationDocumentsDirectory();
      final String dest = '${docs.path}/note_${widget.noteId}.jpg';
      if (picked.path == dest) {
        if (mounted) setState(() => _photoPath = dest);
        return;
      }
      final String? old = _photoPath;
      await File(picked.path).copy(dest);
      if (old != null && old != dest) {
        try {
          final File oldFile = File(old);
          if (await oldFile.exists()) await oldFile.delete();
        } catch (_) {}
      }
      if (mounted) setState(() => _photoPath = dest);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not attach photo')),
      );
    } finally {
      if (mounted) setState(() => _isPickingPhoto = false);
    }
  }

  Future<void> _removePhoto() async {
    final String? path = _photoPath;
    if (path == null) return;
    try {
      final File file = File(path);
      if (await file.exists()) await file.delete();
    } catch (_) {}
    if (mounted) setState(() => _photoPath = null);
  }

  Future<void> _confirmDelete() async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Delete note?'),
          content: const Text(
            'This removes the note and its audio and photo files.',
          ),
          actions: [
            TextButton(
              key: const ValueKey('cancel_delete_button'),
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            TextButton(
              key: const ValueKey('confirm_delete_button'),
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Delete'),
            ),
          ],
        );
      },
    );
    if (confirmed != true || !mounted) return;
    // Best-effort media stop: never let a missing plugin hang delete.
    // Dispose() also cancels recording and releases the player.
    try {
      if (_isPlaying) {
        unawaited(_player.stop().timeout(const Duration(seconds: 2)));
      }
    } catch (_) {}
    if (_isRecording) {
      // Await (bounded) so dispose() below can't race an in-flight cancel.
      try {
        await (_recorder?.cancel() ?? Future.value())
            .timeout(const Duration(seconds: 2));
      } catch (_) {}
      _tmpPath = null;
      _isRecording = false;
    }
    if (!mounted) return;
    Navigator.of(context).pop(
      NoteEditorResult(
        text: _controller.text,
        audioPath: _audioPath,
        photoPath: _photoPath,
        deleted: true,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _popWithResult();
      },
      child: Scaffold(
        resizeToAvoidBottomInset: true,
        appBar: AppBar(
          leading: const BackButton(),
          actions: [
            IconButton(
              key: const ValueKey('delete_note_button'),
              icon: const Icon(Icons.delete_outline),
              tooltip: 'Delete note',
              onPressed: _confirmDelete,
            ),
          ],
        ),
        body: SafeArea(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              16.0,
              16.0,
              16.0,
              16.0 + MediaQuery.of(context).viewInsets.bottom,
            ),
            child: Column(
              children: [
                Expanded(
                  child: TextField(
                    key: const ValueKey('editor_text_field'),
                    controller: _controller,
                    autofocus: true,
                    maxLines: null,
                    expands: true,
                    keyboardType: TextInputType.multiline,
                    textAlignVertical: TextAlignVertical.top,
                    style:
                        const TextStyle(fontSize: 16, color: Colors.black87),
                    decoration: const InputDecoration(
                      border: InputBorder.none,
                      hintText: 'Note',
                      isDense: true,
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                // Attachments scroll instead of overflowing when the keyboard
                // + 120px photo + controls exceed a short viewport.
                Flexible(
                  flex: 0,
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _buildPhotoSection(),
                        const SizedBox(height: 12),
                        _buildAudioControls(),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPhotoSection() {
    final String? path = _photoPath;
    if (path == null) {
      return Center(
        child: OutlinedButton.icon(
          key: const ValueKey('attach_photo_button'),
          icon: const Icon(Icons.add_a_photo),
          label: Text(_isPickingPhoto ? 'Adding…' : 'Attach photo'),
          onPressed: _isPickingPhoto ? null : _showPhotoSourceSheet,
        ),
      );
    }
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ClipRRect(
            key: const ValueKey('photo_thumbnail'),
            borderRadius: BorderRadius.circular(8),
            child: Image.file(
              File(path),
              height: 120,
              cacheHeight: 240,
              fit: BoxFit.cover,
              errorBuilder: (context, error, stackTrace) => const Icon(
                Icons.broken_image_outlined,
                size: 48,
                color: Colors.black45,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              TextButton.icon(
                key: const ValueKey('photo_replace_button'),
                icon: const Icon(Icons.swap_horiz),
                label: const Text('Replace'),
                onPressed:
                    _isPickingPhoto ? null : _showPhotoSourceSheet,
              ),
              TextButton.icon(
                key: const ValueKey('photo_remove_button'),
                icon: const Icon(Icons.delete_outline),
                label: const Text('Remove'),
                onPressed: _removePhoto,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildAudioControls() {
    if (_isRecording) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconButton(
            key: const ValueKey('stop_button'),
            icon: const Icon(Icons.stop_circle, color: Colors.red, size: 36),
            tooltip: 'Stop recording',
            onPressed: _toggleRecord,
          ),
          const SizedBox(width: 8),
          const Text('Recording… tap to stop'),
        ],
      );
    }
    if (_audioPath != null) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconButton(
            key: const ValueKey('play_button'),
            icon: Icon(
              _isPlaying ? Icons.pause_circle : Icons.play_circle,
              size: 36,
            ),
            tooltip: _isPlaying ? 'Pause' : 'Play',
            onPressed: _togglePlayback,
          ),
          const SizedBox(width: 8),
          TextButton.icon(
            key: const ValueKey('rerecord_button'),
            icon: const Icon(Icons.mic),
            label: const Text('Re-record'),
            onPressed: _toggleRecord,
          ),
        ],
      );
    }
    return Center(
      child: ElevatedButton.icon(
        key: const ValueKey('record_button'),
        icon: const Icon(Icons.mic),
        label: const Text('Record audio'),
        onPressed: _toggleRecord,
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
