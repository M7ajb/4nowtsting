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
  // Default background color for the board canvas (session-only by design).
  Color _boardColor = const Color(0xFF1E1E2C);

  // In-memory floating notes (persisted to shared_preferences as JSON).
  final List<BoardNote> _notes = [];
  int _nextNoteId = 0;
  bool _notesLoaded = false;

  // Project folders (notes live inside folders) + colored tags.
  final List<BoardFolder> _folders = [];
  final List<BoardTag> _tags = [];

  // Active view: null = All folders, '__unfiled__' = Unfiled, else folder id.
  static const String unfiledSentinel = '__unfiled__';
  String? _activeFolderId;
  final Set<String> _activeTagIds = {};
  String _searchQuery = '';

  static const String _prefsKey = 'connections_board_notes';
  static const String _foldersPrefsKey = 'connections_board_folders';
  static const String _tagsPrefsKey = 'connections_board_tags';

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
        return _BoardManagementDialog(
          currentColor: _boardColor,
          presetColors: _presetColors,
          folders: _folders,
          tags: _tags,
          notes: _notes,
          onColorSelected: (newColor) {
            setState(() {
              _boardColor = newColor;
            });
          },
          onFoldersChanged: (next) {
            setState(() {
              _folders
                ..clear()
                ..addAll(next);
              // If active folder was deleted elsewhere, fall back to All.
              if (_activeFolderId != null &&
                  _activeFolderId != unfiledSentinel &&
                  _folders.every((f) => f.id != _activeFolderId)) {
                _activeFolderId = null;
              }
            });
            unawaited(_saveFolders());
            unawaited(_saveNotes());
          },
          onTagsChanged: (next) {
            setState(() {
              final Set<String> valid = next.map((t) => t.id).toSet();
              _tags
                ..clear()
                ..addAll(next);
              _activeTagIds.removeWhere((id) => !valid.contains(id));
              for (final BoardNote n in _notes) {
                n.tagIds.removeWhere((id) => !valid.contains(id));
              }
              for (final BoardFolder f in _folders) {
                f.tagIds.removeWhere((id) => !valid.contains(id));
              }
            });
            unawaited(_saveTags());
            unawaited(_saveNotes());
            unawaited(_saveFolders());
          },
          onDeleteFolder: (folder) => _confirmDeleteFolder(folder),
        );
      },
    );
  }

  BoardFolder? _folderById(String? id) {
    if (id == null) return null;
    for (final BoardFolder f in _folders) {
      if (f.id == id) return f;
    }
    return null;
  }

  List<BoardNote> get _visibleNotes {
    final String q = _searchQuery.trim().toLowerCase();
    return _notes.where((BoardNote n) {
      if (_activeFolderId == unfiledSentinel) {
        if (n.folderId != null) return false;
      } else if (_activeFolderId != null) {
        if (n.folderId != _activeFolderId) return false;
      }
      if (_activeTagIds.isNotEmpty) {
        if (!_activeTagIds.every((id) => n.tagIds.contains(id))) return false;
      }
      if (q.isNotEmpty) {
        if (!n.text.toLowerCase().contains(q)) return false;
      }
      return true;
    }).toList();
  }

  @override
  void initState() {
    super.initState();
    // Show board immediately, populate notes once loaded (no splash).
    unawaited(_loadAll());
  }

  Future<void> _loadAll() async {
    await _loadNotes();
    await _loadFolders();
    await _loadTags();
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

  Future<void> _loadFolders() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final String? raw = prefs.getString(_foldersPrefsKey);
      if (raw == null || raw.isEmpty) {
        if (mounted) setState(() {});
        return;
      }
      final List<dynamic> decoded = jsonDecode(raw) as List<dynamic>;
      final List<BoardFolder> loaded = [];
      final Set<String> seen = {};
      for (final dynamic entry in decoded) {
        try {
          BoardFolder? folder;
          if (entry is Map<String, dynamic>) {
            folder = BoardFolder.fromJson(entry);
          } else if (entry is Map) {
            folder = BoardFolder.fromJson(Map<String, dynamic>.from(entry));
          }
          if (folder == null) continue;
          if (!seen.add(folder.id)) continue;
          if (folder.name.trim().isEmpty) continue;
          loaded.add(folder);
        } catch (_) {
          continue;
        }
      }
      if (!mounted) return;
      setState(() {
        _folders
          ..clear()
          ..addAll(loaded);
      });
    } catch (_) {}
  }

  Future<void> _saveFolders() async {
    final String raw = jsonEncode(
      _folders.map((BoardFolder f) => f.toJson()).toList(),
    );
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setString(_foldersPrefsKey, raw);
    } catch (_) {}
  }

  Future<void> _loadTags() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final String? raw = prefs.getString(_tagsPrefsKey);
      if (raw == null || raw.isEmpty) {
        if (mounted) setState(() {});
        return;
      }
      final List<dynamic> decoded = jsonDecode(raw) as List<dynamic>;
      final List<BoardTag> loaded = [];
      final Set<String> seen = {};
      for (final dynamic entry in decoded) {
        try {
          BoardTag? tag;
          if (entry is Map<String, dynamic>) {
            tag = BoardTag.fromJson(entry);
          } else if (entry is Map) {
            tag = BoardTag.fromJson(Map<String, dynamic>.from(entry));
          }
          if (tag == null) continue;
          if (!seen.add(tag.id)) continue;
          loaded.add(tag);
        } catch (_) {
          continue;
        }
      }
      if (!mounted) return;
      setState(() {
        _tags
          ..clear()
          ..addAll(loaded);
      });
    } catch (_) {}
  }

  Future<void> _saveTags() async {
    final String raw = jsonEncode(
      _tags.map((BoardTag t) => t.toJson()).toList(),
    );
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setString(_tagsPrefsKey, raw);
    } catch (_) {}
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
    // New notes go to Unfiled when viewing All/Unfiled, else current folder.
    String? targetFolder;
    if (_activeFolderId != null && _activeFolderId != unfiledSentinel) {
      targetFolder = _folderById(_activeFolderId) != null ? _activeFolderId : null;
    }
    setState(() {
      _notes.add(
        BoardNote(
          id: _nextNoteId++,
          position: Offset(dx, dy),
          folderId: targetFolder,
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
          initialAudioPaths: note.audioPaths,
          initialPhotoPaths: note.photoPaths,
          initialFolderId: note.folderId,
          initialTagIds: note.tagIds,
          allFolders: _folders,
          allTags: _tags,
        ),
      ),
    );
    if (!mounted) return;
    if (updated == null) return;
    if (updated.deleted) {
      await _deleteNote(note.id);
      return;
    }
    // Merge tags created inside the editor.
    bool tagsChanged = false;
    for (final BoardTag t in updated.newTags) {
      if (_tags.every((e) => e.id != t.id)) {
        _tags.add(t);
        tagsChanged = true;
      }
    }
    if (tagsChanged) unawaited(_saveTags());
    final bool mediaChanged = !_listEquals(updated.audioPaths, note.audioPaths) ||
        !_listEquals(updated.photoPaths, note.photoPaths);
    if (updated.text != note.text ||
        mediaChanged ||
        updated.folderId != note.folderId ||
        !_listEquals(updated.tagIds, note.tagIds)) {
      setState(() {
        note.text = updated.text;
        note.audioPaths = List<String>.from(updated.audioPaths);
        note.photoPaths = List<String>.from(updated.photoPaths);
        note.folderId = updated.folderId;
        note.tagIds = List<String>.from(updated.tagIds);
      });
      unawaited(_saveNotes());
    }
  }

  bool _listEquals(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  Future<void> _deleteNote(int id) async {
    final int index = _notes.indexWhere((n) => n.id == id);
    if (index == -1) return;
    final BoardNote removed = _notes[index];
    setState(() {
      _notes.removeAt(index);
    });
    unawaited(_saveNotes());
    await deleteNoteAttachmentFiles([
      ...removed.audioPaths,
      ...removed.photoPaths,
    ]);
    // Best-effort cleanup of an interrupted recording tmp file.
    // Derive from the audio sibling dir first so tests without
    // path_provider still clean up; docs lookup has a timeout so a
    // missing plugin never hangs delete.
    final List<String> tmpCandidates = [];
    for (final String p in [...removed.audioPaths, ...removed.photoPaths]) {
      if (p.isEmpty) continue;
      try {
        tmpCandidates.add(
          '${File(p).parent.path}/note_${removed.id}_tmp.m4a',
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

  /// Folder delete with per-note picker: checkboxes + [All] option.
  /// Choice: Move selected to Unfiled, or Delete selected.
  Future<void> _confirmDeleteFolder(BoardFolder folder) async {
    final List<BoardNote> inside =
        _notes.where((n) => n.folderId == folder.id).toList();
    if (inside.isEmpty) {
      final bool? confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text('Delete folder "${folder.name}"?'),
          content: const Text('The folder is empty. Delete it?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            TextButton(
              key: const ValueKey('confirm_delete_folder_button'),
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Delete'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
      setState(() {
        _folders.removeWhere((f) => f.id == folder.id);
        if (_activeFolderId == folder.id) _activeFolderId = null;
      });
      unawaited(_saveFolders());
      return;
    }
    final Set<int> selected = {};
    bool selectAll = false;
    final String? action = await showDialog<String>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (stfContext, stfSetState) {
            return AlertDialog(
              key: const ValueKey('delete_folder_picker'),
              title: Text('Delete folder "${folder.name}"?'),
              content: SizedBox(
                width: 320,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'What should happen to its notes?',
                      style: TextStyle(fontSize: 13),
                    ),
                    CheckboxListTile(
                      key: const ValueKey('folder_delete_select_all'),
                      value: selectAll,
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: const Text('All'),
                      onChanged: (v) {
                        stfSetState(() {
                          selectAll = v == true;
                          selected.clear();
                          if (selectAll) {
                            selected.addAll(inside.map((n) => n.id));
                          }
                        });
                      },
                    ),
                    const Divider(height: 8),
                    Flexible(
                      child: SingleChildScrollView(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            for (final BoardNote n in inside)
                              CheckboxListTile(
                                key: ValueKey('folder_delete_note_${n.id}'),
                                value: selected.contains(n.id),
                                dense: true,
                                contentPadding: EdgeInsets.zero,
                                title: Text(
                                  n.text.trim().isEmpty
                                      ? 'Note ${n.id}'
                                      : (n.text.trim().length > 32
                                          ? '${n.text.trim().substring(0, 32)}…'
                                          : n.text.trim()),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                onChanged: (v) {
                                  stfSetState(() {
                                    if (v == true) {
                                      selected.add(n.id);
                                    } else {
                                      selected.remove(n.id);
                                      selectAll = false;
                                    }
                                    if (selected.length == inside.length) {
                                      selectAll = true;
                                    }
                                  });
                                },
                              ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(null),
                  child: const Text('Cancel'),
                ),
                TextButton(
                  key: const ValueKey('folder_delete_move_button'),
                  onPressed: () => Navigator.of(dialogContext).pop('move'),
                  child: const Text('Move selected to Unfiled'),
                ),
                TextButton(
                  key: const ValueKey('folder_delete_notes_button'),
                  onPressed: () => Navigator.of(dialogContext).pop('delete'),
                  child: const Text(
                    'Delete folder + selected',
                    style: TextStyle(color: Colors.red),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
    if (action == null || !mounted) return;
    final List<BoardNote> targets =
        inside.where((n) => selected.contains(n.id)).toList();
    if (action == 'move') {
      setState(() {
        // If All/any selected: move those; unselected stay? Folder is
        // deleted so unselected must also go somewhere -> Unfiled.
        for (final BoardNote n in inside) {
          n.folderId = null;
        }
        _folders.removeWhere((f) => f.id == folder.id);
        if (_activeFolderId == folder.id) _activeFolderId = null;
      });
      unawaited(_saveNotes());
      unawaited(_saveFolders());
    } else if (action == 'delete') {
      final List<String> filesToDelete = [];
      setState(() {
        for (final BoardNote n in targets) {
          filesToDelete.addAll(n.audioPaths);
          filesToDelete.addAll(n.photoPaths);
          _notes.removeWhere((e) => e.id == n.id);
        }
        // Notes not selected move to Unfiled since their folder is gone.
        for (final BoardNote n in _notes) {
          if (n.folderId == folder.id) n.folderId = null;
        }
        _folders.removeWhere((f) => f.id == folder.id);
        if (_activeFolderId == folder.id) _activeFolderId = null;
      });
      unawaited(_saveNotes());
      unawaited(_saveFolders());
      await deleteNoteAttachmentFiles(filesToDelete);
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
    final List<BoardNote> visible = _visibleNotes;
    final String folderLabel;
    if (_activeFolderId == null) {
      folderLabel = 'All folders';
    } else if (_activeFolderId == unfiledSentinel) {
      folderLabel = 'Unfiled';
    } else {
      folderLabel = _folderById(_activeFolderId)?.name ?? 'All folders';
    }

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
          for (final BoardNote note in visible)
            Positioned(
              left: note.position.dx,
              top: note.position.dy,
              child: _NoteCard(
                key: ValueKey('note_card_${note.id}'),
                note: note,
                folders: _folders,
                tags: _tags,
                onDragStart: () => _bringToFront(note.id),
                onDragUpdate: (delta) => _moveNote(note.id, delta, viewport),
                onDragEnd: () => _finishDrag(),
                onLongPress: () => _openNoteEditor(note),
                onTap: () => _bringToFront(note.id),
              ),
            ),

          // Empty-state hint instead of a blank board (only after load,
          // so saved notes don't flash a hint on startup).
          if (visible.isEmpty && _notesLoaded)
            Center(
              child: Text(
                _notes.isEmpty
                    ? 'Tap + to add your first note'
                    : 'No notes here',
                key: const ValueKey('empty_state_hint'),
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 16, color: Colors.white70),
              ),
            ),

          // Folder switcher fixed in the top-left corner.
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Align(
                alignment: Alignment.topLeft,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Material(
                      color: Colors.transparent,
                      child: InkWell(
                        key: const ValueKey('folder_switcher_button'),
                        onTap: () async {
                          final String? picked =
                              await showMenu<String>(
                            context: context,
                            position: const RelativeRect.fromLTRB(16, 70, 200, 200),
                            items: [
                              const PopupMenuItem(
                                key: ValueKey('folder_option_all'),
                                value: '__all__',
                                child: Text('All folders'),
                              ),
                              const PopupMenuItem(
                                key: ValueKey('folder_option_unfiled'),
                                value: unfiledSentinel,
                                child: Text('Unfiled'),
                              ),
                              for (final BoardFolder f in _folders)
                                PopupMenuItem(
                                  key: ValueKey('folder_option_${f.id}'),
                                  value: f.id,
                                  child: Row(
                                    children: [
                                      Container(
                                        width: 12,
                                        height: 12,
                                        decoration: BoxDecoration(
                                          color: f.color,
                                          shape: BoxShape.circle,
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(child: Text(f.name)),
                                      Text(
                                        '${_notes.where((n) => n.folderId == f.id).length}',
                                        style: const TextStyle(
                                            fontSize: 12, color: Colors.grey),
                                      ),
                                    ],
                                  ),
                                ),
                            ],
                          );
                          if (picked == null || !mounted) return;
                          setState(() {
                            if (picked == '__all__') {
                              _activeFolderId = null;
                            } else {
                              _activeFolderId = picked;
                            }
                          });
                        },
                        borderRadius: BorderRadius.circular(20),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 8),
                          decoration: BoxDecoration(
                            color: buttonBgColor,
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                              color: buttonFgColor.withOpacity(0.3),
                              width: 1.5,
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.folder_outlined,
                                  size: 18, color: buttonFgColor),
                              const SizedBox(width: 6),
                              Text(
                                folderLabel,
                                key: const ValueKey('folder_switcher_label'),
                                style: TextStyle(
                                  color: buttonFgColor,
                                  fontWeight: FontWeight.w600,
                                  fontSize: 13,
                                ),
                              ),
                              Icon(Icons.arrow_drop_down,
                                  color: buttonFgColor),
                            ],
                          ),
                        ),
                      ),
                    ),
                    if (_tags.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      SizedBox(
                        width: viewport.width * 0.62,
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            children: [
                              for (final BoardTag t in _tags)
                                Padding(
                                  padding: const EdgeInsets.only(right: 6),
                                  child: FilterChip(
                                    key: ValueKey('filter_tag_${t.id}'),
                                    label: Text(t.name,
                                        style: const TextStyle(fontSize: 12)),
                                    selected:
                                        _activeTagIds.contains(t.id),
                                    avatar: Container(
                                      width: 12,
                                      height: 12,
                                      decoration: BoxDecoration(
                                        color: t.color,
                                        shape: BoxShape.circle,
                                      ),
                                    ),
                                    onSelected: (v) {
                                      setState(() {
                                        if (v) {
                                          _activeTagIds.add(t.id);
                                        } else {
                                          _activeTagIds.remove(t.id);
                                        }
                                      });
                                    },
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
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
  final List<BoardFolder> folders;
  final List<BoardTag> tags;
  final VoidCallback onDragStart;
  final ValueChanged<Offset> onDragUpdate;
  final VoidCallback onDragEnd;
  final VoidCallback onLongPress;
  final VoidCallback onTap;

  const _NoteCard({
    super.key,
    required this.note,
    this.folders = const [],
    this.tags = const [],
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
        note.audioPaths.isNotEmpty || note.photoPaths.isNotEmpty;
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
    final bool hasPhoto = note.photoPaths.isNotEmpty;
    final bool hasAudio = note.audioPaths.isNotEmpty;
    BoardFolder? folder;
    for (final BoardFolder f in folders) {
      if (f.id == note.folderId) {
        folder = f;
        break;
      }
    }
    final List<BoardTag> noteTags = [];
    for (final String id in note.tagIds) {
      for (final BoardTag t in tags) {
        if (t.id == id) {
          noteTags.add(t);
          break;
        }
      }
    }
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
                color: folder != null
                    ? folder.color.withOpacity(0.45)
                    : Colors.black.withOpacity(0.08),
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
                    if (note.photoPaths.length > 1)
                      Text(
                        '×${note.photoPaths.length}',
                        style: const TextStyle(
                            fontSize: 10, color: Colors.black54),
                      ),
                  ],
                  if (hasAudio) ...[
                    const SizedBox(width: 4),
                    Icon(
                      Icons.mic,
                      key: ValueKey('audio_indicator_${note.id}'),
                      size: 14,
                      color: Colors.black54,
                    ),
                    if (note.audioPaths.length > 1)
                      Text(
                        '×${note.audioPaths.length}',
                        style: const TextStyle(
                            fontSize: 10, color: Colors.black54),
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
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
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
                              path: note.photoPaths.first,
                              size: 36,
                              key: ValueKey('photo_thumb_card_${note.id}'),
                            ),
                          ],
                        ],
                      ),
                    ),
                    if (noteTags.isNotEmpty || folder != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Row(
                          children: [
                            if (folder != null)
                              Container(
                                key: ValueKey('folder_badge_${note.id}'),
                                margin: const EdgeInsets.only(right: 4),
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: folder.color,
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Text(
                                  folder.name.length > 10
                                      ? '${folder.name.substring(0, 10)}…'
                                      : folder.name,
                                  style: const TextStyle(
                                      fontSize: 9, color: Colors.black87),
                                ),
                              ),
                            for (int i = 0;
                                i < noteTags.length && i < 2;
                                i++)
                              Container(
                                key: ValueKey(
                                    'tag_badge_${note.id}_${noteTags[i].id}'),
                                margin: const EdgeInsets.only(right: 3),
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 5, vertical: 2),
                                decoration: BoxDecoration(
                                  color: noteTags[i].color.withOpacity(0.85),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Text(
                                  noteTags[i].name.length > 8
                                      ? '${noteTags[i].name.substring(0, 8)}…'
                                      : noteTags[i].name,
                                  style: const TextStyle(
                                      fontSize: 9, color: Colors.black87),
                                ),
                              ),
                            if (noteTags.length > 2)
                              Text(
                                '+${noteTags.length - 2}',
                                style: const TextStyle(
                                    fontSize: 9, color: Colors.black54),
                              ),
                          ],
                        ),
                      ),
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
  final List<String> audioPaths;
  final List<String> photoPaths;
  final String? folderId;
  final List<String> tagIds;
  final List<BoardTag> newTags;
  final bool deleted;

  NoteEditorResult({
    required this.text,
    List<String>? audioPaths,
    List<String>? photoPaths,
    // Legacy single-path compat.
    String? audioPath,
    String? photoPath,
    this.folderId,
    List<String>? tagIds,
    List<BoardTag>? newTags,
    this.deleted = false,
  })  : audioPaths = audioPaths ??
            (audioPath != null && audioPath.isNotEmpty ? [audioPath] : []),
        photoPaths = photoPaths ??
            (photoPath != null && photoPath.isNotEmpty ? [photoPath] : []),
        tagIds = tagIds ?? [],
        newTags = newTags ?? [];

  String? get audioPath => audioPaths.isEmpty ? null : audioPaths.first;
  String? get photoPath => photoPaths.isEmpty ? null : photoPaths.first;
}

class NoteEditorPage extends StatefulWidget {
  final String initialText;
  final int noteId;
  final List<String>? initialAudioPaths;
  final List<String>? initialPhotoPaths;
  final String? initialAudioPath;
  final String? initialPhotoPath;
  final String? initialFolderId;
  final List<String>? initialTagIds;
  final List<BoardFolder>? allFolders;
  final List<BoardTag>? allTags;
  final PhotoPickerFn? photoPicker;

  const NoteEditorPage({
    super.key,
    required this.initialText,
    required this.noteId,
    this.initialAudioPaths,
    this.initialPhotoPaths,
    this.initialAudioPath,
    this.initialPhotoPath,
    this.initialFolderId,
    this.initialTagIds,
    this.allFolders,
    this.allTags,
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

  List<String> _audioPaths = [];
  List<String> _photoPaths = [];
  String? _folderId;
  List<String> _tagIds = [];
  List<BoardTag> _localTags = [];
  final List<BoardTag> _createdTags = [];
  final TextEditingController _newTagController = TextEditingController();
  Color _newTagColor = const Color(0xFFFFD54F);
  bool _showTagInput = false;
  String? _tmpPath;
  bool _isRecording = false;
  String? _playingPath;
  bool _isPickingPhoto = false;

  bool get _isPlaying => _playingPath != null;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialText);
    final List<String> audios = [];
    if (widget.initialAudioPaths != null) audios.addAll(widget.initialAudioPaths!);
    if (widget.initialAudioPath != null &&
        widget.initialAudioPath!.isNotEmpty &&
        !audios.contains(widget.initialAudioPath)) {
      audios.add(widget.initialAudioPath!);
    }
    final List<String> photos = [];
    if (widget.initialPhotoPaths != null) photos.addAll(widget.initialPhotoPaths!);
    if (widget.initialPhotoPath != null &&
        widget.initialPhotoPath!.isNotEmpty &&
        !photos.contains(widget.initialPhotoPath)) {
      photos.add(widget.initialPhotoPath!);
    }
    _audioPaths = audios.take(kMaxAudiosPerNote).toList();
    _photoPaths = photos.take(kMaxPhotosPerNote).toList();
    _folderId = widget.initialFolderId;
    _tagIds = List<String>.from(widget.initialTagIds ?? []);
    _localTags = List<BoardTag>.from(widget.allTags ?? []);
    _player = AudioPlayer();
    _completeSub = _player.onPlayerComplete.listen((_) {
      if (mounted) setState(() => _playingPath = null);
    });
    unawaited(_validateInitialMedia());
  }

  Future<void> _validateInitialMedia() async {
    final List<String> validPhotos = [];
    for (final String p in _photoPaths) {
      if (await File(p).exists()) validPhotos.add(p);
    }
    final List<String> validAudios = [];
    for (final String p in _audioPaths) {
      if (await File(p).exists()) validAudios.add(p);
    }
    if (!mounted) return;
    if (validPhotos.length != _photoPaths.length ||
        validAudios.length != _audioPaths.length) {
      setState(() {
        _photoPaths = validPhotos;
        _audioPaths = validAudios;
      });
    }
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
    _newTagController.dispose();
    super.dispose();
  }

  void _popWithResult() {
    Navigator.of(context).pop(
      NoteEditorResult(
        text: _controller.text,
        audioPaths: List<String>.from(_audioPaths),
        photoPaths: List<String>.from(_photoPaths),
        folderId: _folderId,
        tagIds: List<String>.from(_tagIds),
        newTags: List<BoardTag>.from(_createdTags),
      ),
    );
  }

  Future<void> _toggleRecord() async {
    if (_isRecording) {
      await _stopRecording();
      return;
    }
    if (_audioPaths.length >= kMaxAudiosPerNote) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Max 10 audio clips per note')),
      );
      return;
    }
    if (_isPlaying) {
      await _player.stop();
      if (mounted) setState(() => _playingPath = null);
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
      final String tmpPath =
          '${docs.path}/note_${widget.noteId}_tmp_${DateTime.now().microsecondsSinceEpoch}.m4a';
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
      String? resolved;
      if (stoppedPath != null && await File(stoppedPath).exists()) {
        final String finalPath =
            '${docs.path}/note_${widget.noteId}_aud_${DateTime.now().microsecondsSinceEpoch}.m4a';
        await File(stoppedPath).rename(finalPath);
        resolved = finalPath;
      }
      // Guard against phantom paths: only publish if the file is really there.
      if (resolved != null && !await File(resolved).exists()) {
        resolved = null;
      }
      _tmpPath = null;
      if (mounted) {
        setState(() {
          _isRecording = false;
          if (resolved != null &&
              _audioPaths.length < kMaxAudiosPerNote) {
            _audioPaths.add(resolved);
          }
        });
      }
    } catch (_) {
      if (mounted) setState(() => _isRecording = false);
    }
  }

  Future<void> _togglePlayback(String path) async {
    try {
      if (_playingPath == path) {
        await _player.pause();
        if (mounted) setState(() => _playingPath = null);
      } else {
        if (!await File(path).exists()) {
          if (mounted) {
            setState(() {
              _audioPaths.remove(path);
              if (_playingPath == path) _playingPath = null;
            });
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Audio file not found')),
            );
          }
          return;
        }
        await _player.stop();
        await _player.play(DeviceFileSource(path));
        if (mounted) setState(() => _playingPath = path);
      }
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not play audio')),
      );
    }
  }

  Future<void> _removeAudio(String path) async {
    try {
      if (_playingPath == path) await _player.stop();
    } catch (_) {}
    try {
      final File file = File(path);
      if (await file.exists()) await file.delete();
    } catch (_) {}
    if (mounted) {
      setState(() {
        _audioPaths.remove(path);
        if (_playingPath == path) _playingPath = null;
      });
    }
  }

  Future<XFile?> _defaultPhotoPicker(ImageSource source) {
    return ImagePicker().pickImage(
      source: source,
      imageQuality: 85,
      maxWidth: 1600,
    );
  }

  void _showPhotoSourceSheet({int? replaceIndex}) {
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
                  unawaited(_pickPhoto(ImageSource.camera,
                      replaceIndex: replaceIndex));
                },
              ),
              ListTile(
                key: const ValueKey('photo_source_gallery'),
                leading: const Icon(Icons.photo_library),
                title: const Text('Choose from gallery'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  unawaited(_pickPhoto(ImageSource.gallery,
                      replaceIndex: replaceIndex));
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _pickPhoto(ImageSource source, {int? replaceIndex}) async {
    if (_isPickingPhoto) return;
    if (replaceIndex == null && _photoPaths.length >= kMaxPhotosPerNote) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Max 10 photos per note')),
      );
      return;
    }
    setState(() => _isPickingPhoto = true);
    try {
      final PhotoPickerFn picker = widget.photoPicker ?? _defaultPhotoPicker;
      final XFile? picked = await picker(source);
      if (!mounted) return;
      if (picked == null) return;
      final Directory docs = await getApplicationDocumentsDirectory();
      final String dest =
          '${docs.path}/note_${widget.noteId}_img_${DateTime.now().microsecondsSinceEpoch}.jpg';
      if (picked.path == dest) {
        if (mounted) {
          setState(() {
            if (replaceIndex != null &&
                replaceIndex >= 0 &&
                replaceIndex < _photoPaths.length) {
              _photoPaths[replaceIndex] = dest;
            } else if (_photoPaths.length < kMaxPhotosPerNote) {
              _photoPaths.add(dest);
            }
          });
        }
        return;
      }
      await File(picked.path).copy(dest);
      if (replaceIndex != null &&
          replaceIndex >= 0 &&
          replaceIndex < _photoPaths.length) {
        final String old = _photoPaths[replaceIndex];
        try {
          final File oldFile = File(old);
          if (old != dest && await oldFile.exists()) await oldFile.delete();
        } catch (_) {}
        if (mounted) setState(() => _photoPaths[replaceIndex] = dest);
      } else {
        if (mounted) {
          setState(() {
            if (_photoPaths.length < kMaxPhotosPerNote) _photoPaths.add(dest);
          });
        }
      }
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not attach photo')),
      );
    } finally {
      if (mounted) setState(() => _isPickingPhoto = false);
    }
  }

  Future<void> _removePhotoAt(int index) async {
    if (index < 0 || index >= _photoPaths.length) return;
    final String path = _photoPaths[index];
    try {
      final File file = File(path);
      if (await file.exists()) await file.delete();
    } catch (_) {}
    if (mounted) setState(() => _photoPaths.removeAt(index));
  }

  Future<void> _removePhoto() async {
    if (_photoPaths.isEmpty) return;
    await _removePhotoAt(0);
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
        audioPaths: List<String>.from(_audioPaths),
        photoPaths: List<String>.from(_photoPaths),
        folderId: _folderId,
        tagIds: List<String>.from(_tagIds),
        newTags: List<BoardTag>.from(_createdTags),
        deleted: true,
      ),
    );
  }

  void _createTagFromInput() {
    final String name = _newTagController.text.trim();
    if (name.isEmpty) return;
    final String id = newBoardId('tag');
    final BoardTag tag = BoardTag(id: id, name: name, color: _newTagColor);
    setState(() {
      _localTags.add(tag);
      _createdTags.add(tag);
      _tagIds.add(id);
      _newTagController.clear();
      _showTagInput = false;
    });
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
                _buildFolderPicker(),
                _buildTagEditor(),
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
                // + photos + controls exceed a short viewport.
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

  Widget _buildFolderPicker() {
    final List<BoardFolder> folders = widget.allFolders ?? [];
    return Row(
      children: [
        const Icon(Icons.folder_outlined, size: 18, color: Colors.black54),
        const SizedBox(width: 8),
        Expanded(
          child: DropdownButton<String?>(
            key: const ValueKey('folder_dropdown'),
            value: folders.any((f) => f.id == _folderId) ? _folderId : null,
            hint: const Text('Unfiled'),
            isExpanded: true,
            items: [
              const DropdownMenuItem<String?>(
                value: null,
                child: Text('Unfiled'),
              ),
              for (final BoardFolder f in folders)
                DropdownMenuItem<String?>(
                  value: f.id,
                  child: Row(
                    children: [
                      Container(
                        width: 12,
                        height: 12,
                        decoration: BoxDecoration(
                          color: f.color,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(child: Text(f.name)),
                    ],
                  ),
                ),
            ],
            onChanged: (v) => setState(() => _folderId = v),
          ),
        ),
      ],
    );
  }

  Widget _buildTagEditor() {
    // Hidden tag input by default so the editor keeps a single TextField
    // (existing tests + autofocus behavior). Tap "Add tag" to reveal it.
    final List<Widget> children = [];
    if (_localTags.isNotEmpty) {
      children.add(
        Wrap(
          spacing: 6,
          runSpacing: 4,
          children: [
            for (final BoardTag t in _localTags)
              FilterChip(
                key: ValueKey('tag_chip_${t.id}'),
                label: Text(t.name, style: const TextStyle(fontSize: 12)),
                selected: _tagIds.contains(t.id),
                avatar: Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    color: t.color,
                    shape: BoxShape.circle,
                  ),
                ),
                onSelected: (v) {
                  setState(() {
                    if (v) {
                      if (!_tagIds.contains(t.id)) _tagIds.add(t.id);
                    } else {
                      _tagIds.remove(t.id);
                    }
                  });
                },
              ),
          ],
        ),
      );
    }
    if (_showTagInput) {
      children.add(
        Row(
          children: [
            Expanded(
              child: TextField(
                key: const ValueKey('new_tag_field'),
                controller: _newTagController,
                decoration: const InputDecoration(
                  hintText: 'New tag name',
                  isDense: true,
                ),
                onSubmitted: (_) => _createTagFromInput(),
              ),
            ),
            IconButton(
              key: const ValueKey('add_tag_button'),
              icon: const Icon(Icons.check),
              tooltip: 'Create tag',
              onPressed: _createTagFromInput,
            ),
            IconButton(
              icon: const Icon(Icons.close),
              tooltip: 'Cancel',
              onPressed: () => setState(() {
                _showTagInput = false;
                _newTagController.clear();
              }),
            ),
          ],
        ),
      );
    } else {
      children.add(
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: const ValueKey('add_tag_button'),
            icon: const Icon(Icons.label_outline, size: 16),
            label: Text(_localTags.isEmpty ? 'Add tag' : 'New tag'),
            onPressed: () => setState(() => _showTagInput = true),
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: children,
      ),
    );
  }

  Widget _buildPhotoSection() {
    if (_photoPaths.isEmpty) {
      return Center(
        child: OutlinedButton.icon(
          key: const ValueKey('attach_photo_button'),
          icon: const Icon(Icons.add_a_photo),
          label: Text(_isPickingPhoto ? 'Adding…' : 'Attach photo'),
          onPressed: _isPickingPhoto ? null : () => _showPhotoSourceSheet(),
        ),
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          alignment: WrapAlignment.center,
          children: [
            for (int i = 0; i < _photoPaths.length; i++)
              Stack(
                children: [
                  ClipRRect(
                    key: i == 0
                        ? const ValueKey('photo_thumbnail')
                        : ValueKey('photo_thumbnail_$i'),
                    borderRadius: BorderRadius.circular(8),
                    child: Image.file(
                      File(_photoPaths[i]),
                      height: 80,
                      width: 80,
                      cacheHeight: 160,
                      cacheWidth: 160,
                      fit: BoxFit.cover,
                      errorBuilder: (context, error, stackTrace) => const Icon(
                        Icons.broken_image_outlined,
                        size: 40,
                        color: Colors.black45,
                      ),
                    ),
                  ),
                  Positioned(
                    top: 0,
                    right: 0,
                    child: InkWell(
                      key: i == 0
                          ? const ValueKey('photo_remove_button')
                          : ValueKey('photo_remove_button_$i'),
                      onTap: () => _removePhotoAt(i),
                      child: Container(
                        padding: const EdgeInsets.all(2),
                        decoration: const BoxDecoration(
                          color: Colors.black54,
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.close,
                            size: 14, color: Colors.white),
                      ),
                    ),
                  ),
                  Positioned(
                    bottom: 0,
                    left: 0,
                    child: InkWell(
                      key: i == 0
                          ? const ValueKey('photo_replace_button')
                          : ValueKey('photo_replace_button_$i'),
                      onTap: () =>
                          _showPhotoSourceSheet(replaceIndex: i),
                      child: Container(
                        padding: const EdgeInsets.all(2),
                        decoration: const BoxDecoration(
                          color: Colors.black54,
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.swap_horiz,
                            size: 14, color: Colors.white),
                      ),
                    ),
                  ),
                ],
              ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          '${_photoPaths.length}/$kMaxPhotosPerNote photos',
          style: const TextStyle(fontSize: 12, color: Colors.black54),
        ),
        OutlinedButton.icon(
          key: const ValueKey('attach_photo_button'),
          icon: const Icon(Icons.add_a_photo),
          label: Text(_isPickingPhoto
              ? 'Adding…'
              : _photoPaths.length >= kMaxPhotosPerNote
                  ? 'Max photos reached'
                  : 'Add photo'),
          onPressed: (_isPickingPhoto ||
                  _photoPaths.length >= kMaxPhotosPerNote)
              ? null
              : () => _showPhotoSourceSheet(),
        ),
      ],
    );
  }

  Widget _buildAudioControls() {
    final List<Widget> rows = [];
    if (_isRecording) {
      rows.add(
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton(
              key: const ValueKey('stop_button'),
              icon:
                  const Icon(Icons.stop_circle, color: Colors.red, size: 36),
              tooltip: 'Stop recording',
              onPressed: _toggleRecord,
            ),
            const SizedBox(width: 8),
            const Text('Recording… tap to stop'),
          ],
        ),
      );
    }
    for (int i = 0; i < _audioPaths.length; i++) {
      final String path = _audioPaths[i];
      final bool playing = _playingPath == path;
      rows.add(
        Row(
          key: ValueKey('audio_row_$i'),
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton(
              key: i == 0
                  ? const ValueKey('play_button')
                  : ValueKey('play_button_$i'),
              icon: Icon(
                playing ? Icons.pause_circle : Icons.play_circle,
                size: 32,
              ),
              tooltip: playing ? 'Pause' : 'Play clip ${i + 1}',
              onPressed: () => _togglePlayback(path),
            ),
            Expanded(
              child: Text(
                'Clip ${i + 1}',
                style: const TextStyle(fontSize: 13),
              ),
            ),
            IconButton(
              key: i == 0
                  ? const ValueKey('audio_remove_button')
                  : ValueKey('audio_remove_button_$i'),
              icon: const Icon(Icons.delete_outline, size: 20),
              tooltip: 'Remove clip ${i + 1}',
              onPressed: () => _removeAudio(path),
            ),
          ],
        ),
      );
    }
    rows.add(
      Center(
        child: ElevatedButton.icon(
          key: const ValueKey('record_button'),
          icon: const Icon(Icons.mic),
          label: Text(_audioPaths.isEmpty
              ? 'Record audio'
              : 'Record audio (${_audioPaths.length}/$kMaxAudiosPerNote)'),
          onPressed: (_isRecording ||
                  _audioPaths.length >= kMaxAudiosPerNote)
              ? null
              : _toggleRecord,
        ),
      ),
    );
    if (rows.length == 1) return rows.first;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (int i = 0; i < rows.length; i++) ...[
          rows[i],
          if (i != rows.length - 1) const SizedBox(height: 4),
        ],
      ],
    );
  }
}

class _BoardManagementDialog extends StatefulWidget {
  final Color currentColor;
  final List<Color> presetColors;
  final List<BoardFolder> folders;
  final List<BoardTag> tags;
  final List<BoardNote> notes;
  final ValueChanged<Color> onColorSelected;
  final ValueChanged<List<BoardFolder>> onFoldersChanged;
  final ValueChanged<List<BoardTag>> onTagsChanged;
  final Future<void> Function(BoardFolder) onDeleteFolder;

  const _BoardManagementDialog({
    required this.currentColor,
    required this.presetColors,
    required this.folders,
    required this.tags,
    required this.notes,
    required this.onColorSelected,
    required this.onFoldersChanged,
    required this.onTagsChanged,
    required this.onDeleteFolder,
  });

  @override
  State<_BoardManagementDialog> createState() => _BoardManagementDialogState();
}

class _BoardManagementDialogState extends State<_BoardManagementDialog> {
  late Color _selectedColor;
  late double _red;
  late double _green;
  late double _blue;
  late List<BoardFolder> _folders;
  late List<BoardTag> _tags;
  final TextEditingController _folderController = TextEditingController();
  final TextEditingController _tagController = TextEditingController();
  Color _newFolderColor = const Color(0xFF90CAF9);
  Color _newTagColor = const Color(0xFFFFD54F);

  @override
  void initState() {
    super.initState();
    _selectedColor = widget.currentColor;
    _red = widget.currentColor.red.toDouble();
    _green = widget.currentColor.green.toDouble();
    _blue = widget.currentColor.blue.toDouble();
    _folders = widget.folders
        .map((f) => BoardFolder(
            id: f.id, name: f.name, color: f.color, tagIds: List.from(f.tagIds)))
        .toList();
    _tags = widget.tags
        .map((t) => BoardTag(id: t.id, name: t.name, color: t.color))
        .toList();
  }

  @override
  void dispose() {
    _folderController.dispose();
    _tagController.dispose();
    super.dispose();
  }

  void _emitFolders() {
    widget.onFoldersChanged(
      _folders
          .map((f) => BoardFolder(
              id: f.id,
              name: f.name,
              color: f.color,
              tagIds: List<String>.from(f.tagIds)))
          .toList(),
    );
  }

  void _emitTags() {
    widget.onTagsChanged(
      _tags.map((t) => BoardTag(id: t.id, name: t.name, color: t.color)).toList(),
    );
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

  Future<Color?> _pickColor(Color initial) async {
    Color temp = initial;
    return showDialog<Color>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Pick color'),
        content: SingleChildScrollView(
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final Color c in widget.presetColors)
                GestureDetector(
                  onTap: () => Navigator.of(ctx).pop(c),
                  child: Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: c,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: temp.value == c.value
                            ? Colors.blueAccent
                            : Colors.grey.shade400,
                        width: temp.value == c.value ? 3 : 1,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(null),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: AlertDialog(
        title: const Text('Board setup'),
        content: SizedBox(
          width: 360,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const TabBar(
                tabs: [
                  Tab(key: ValueKey('tab_board'), text: 'Board Color'),
                  Tab(key: ValueKey('tab_folders'), text: 'Folders'),
                  Tab(key: ValueKey('tab_tags'), text: 'Tags'),
                ],
              ),
              const SizedBox(height: 8),
              Flexible(
                child: SizedBox(
                  height: 380,
                  child: TabBarView(
                    children: [
                      _buildBoardTab(),
                      _buildFoldersTab(),
                      _buildTagsTab(),
                    ],
                  ),
                ),
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
      ),
    );
  }

  Widget _buildBoardTab() {
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.color_lens, size: 20),
              const SizedBox(width: 8),
              const Text('Background',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              const Spacer(),
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: _selectedColor,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.grey.shade400, width: 2),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          const Text('Presets',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
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
                      color: isSelected
                          ? Colors.blueAccent
                          : Colors.grey.shade400,
                      width: isSelected ? 3.0 : 1.0,
                    ),
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
          const SizedBox(height: 16),
          const Divider(),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Custom RGB',
                  style:
                      TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
              Text(_toHex(_selectedColor),
                  style: TextStyle(
                      fontFamily: 'monospace',
                      fontWeight: FontWeight.w600,
                      color: Colors.grey.shade700)),
            ],
          ),
          Row(
            children: [
              const SizedBox(
                  width: 18,
                  child: Text('R',
                      style: TextStyle(
                          fontWeight: FontWeight.bold, color: Colors.red))),
              Expanded(
                child: Slider(
                    value: _red,
                    min: 0,
                    max: 255,
                    activeColor: Colors.red,
                    onChanged: (v) {
                      _red = v;
                      _updateFromSliders();
                    }),
              ),
              SizedBox(
                  width: 32,
                  child: Text(_red.round().toString(),
                      textAlign: TextAlign.right)),
            ],
          ),
          Row(
            children: [
              const SizedBox(
                  width: 18,
                  child: Text('G',
                      style: TextStyle(
                          fontWeight: FontWeight.bold, color: Colors.green))),
              Expanded(
                child: Slider(
                    value: _green,
                    min: 0,
                    max: 255,
                    activeColor: Colors.green,
                    onChanged: (v) {
                      _green = v;
                      _updateFromSliders();
                    }),
              ),
              SizedBox(
                  width: 32,
                  child: Text(_green.round().toString(),
                      textAlign: TextAlign.right)),
            ],
          ),
          Row(
            children: [
              const SizedBox(
                  width: 18,
                  child: Text('B',
                      style: TextStyle(
                          fontWeight: FontWeight.bold, color: Colors.blue))),
              Expanded(
                child: Slider(
                    value: _blue,
                    min: 0,
                    max: 255,
                    activeColor: Colors.blue,
                    onChanged: (v) {
                      _blue = v;
                      _updateFromSliders();
                    }),
              ),
              SizedBox(
                  width: 32,
                  child: Text(_blue.round().toString(),
                      textAlign: TextAlign.right)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildFoldersTab() {
    return Column(
      children: [
        Expanded(
          child: _folders.isEmpty
              ? const Center(child: Text('No folders yet'))
              : ListView.builder(
                  itemCount: _folders.length,
                  itemBuilder: (context, i) {
                    final BoardFolder f = _folders[i];
                    final int count = widget.notes
                        .where((n) => n.folderId == f.id)
                        .length;
                    return Card(
                      key: ValueKey('folder_row_${f.id}'),
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                InkWell(
                                  key: ValueKey('folder_color_${f.id}'),
                                  onTap: () async {
                                    final Color? picked =
                                        await _pickColor(f.color);
                                    if (picked == null) return;
                                    setState(() => f.color = picked);
                                    _emitFolders();
                                  },
                                  child: Container(
                                    width: 24,
                                    height: 24,
                                    decoration: BoxDecoration(
                                      color: f.color,
                                      shape: BoxShape.circle,
                                      border: Border.all(
                                          color: Colors.grey.shade400),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: TextFormField(
                                    key: ValueKey('folder_name_${f.id}'),
                                    initialValue: f.name,
                                    decoration: const InputDecoration(
                                        isDense: true,
                                        border: InputBorder.none),
                                    onChanged: (v) {
                                      f.name = v.trim().isEmpty ? f.name : v;
                                    },
                                    onFieldSubmitted: (_) => _emitFolders(),
                                  ),
                                ),
                                Text('$count',
                                    style: const TextStyle(
                                        fontSize: 12, color: Colors.grey)),
                                IconButton(
                                  key: ValueKey('folder_delete_${f.id}'),
                                  icon: const Icon(Icons.delete_outline,
                                      size: 20),
                                  tooltip: 'Delete folder',
                                  onPressed: () async {
                                    await widget.onDeleteFolder(
                                      BoardFolder(
                                          id: f.id,
                                          name: f.name,
                                          color: f.color,
                                          tagIds:
                                              List<String>.from(f.tagIds)),
                                    );
                                    // Re-sync: parent mutated its list.
                                    setState(() {
                                      _folders = widget.folders
                                          .map((e) => BoardFolder(
                                              id: e.id,
                                              name: e.name,
                                              color: e.color,
                                              tagIds:
                                                  List<String>.from(e.tagIds)))
                                          .toList();
                                    });
                                  },
                                ),
                              ],
                            ),
                            if (_tags.isNotEmpty)
                              Wrap(
                                spacing: 4,
                                children: [
                                  for (final BoardTag t in _tags)
                                    FilterChip(
                                      key: ValueKey(
                                          'folder_${f.id}_tag_${t.id}'),
                                      label: Text(t.name,
                                          style: const TextStyle(
                                              fontSize: 11)),
                                      selected: f.tagIds.contains(t.id),
                                      visualDensity:
                                          VisualDensity.compact,
                                      onSelected: (v) {
                                        setState(() {
                                          if (v) {
                                            if (!f.tagIds
                                                .contains(t.id)) {
                                              f.tagIds.add(t.id);
                                            }
                                          } else {
                                            f.tagIds.remove(t.id);
                                          }
                                        });
                                        _emitFolders();
                                      },
                                    ),
                                ],
                              ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
        const Divider(height: 8),
        Row(
          children: [
            Expanded(
              child: TextField(
                key: const ValueKey('folder_name_field'),
                controller: _folderController,
                decoration: const InputDecoration(
                    hintText: 'New folder name', isDense: true),
                onSubmitted: (_) => _addFolder(),
              ),
            ),
            IconButton(
              key: const ValueKey('add_folder_button'),
              icon: const Icon(Icons.add),
              tooltip: 'Add folder',
              onPressed: _addFolder,
            ),
          ],
        ),
      ],
    );
  }

  void _addFolder() {
    final String name = _folderController.text.trim();
    if (name.isEmpty) return;
    setState(() {
      _folders.add(BoardFolder(
          id: newBoardId('folder'),
          name: name,
          color: _newFolderColor));
      _folderController.clear();
    });
    _emitFolders();
  }

  Widget _buildTagsTab() {
    return Column(
      children: [
        Expanded(
          child: _tags.isEmpty
              ? const Center(child: Text('No tags yet'))
              : ListView.builder(
                  itemCount: _tags.length,
                  itemBuilder: (context, i) {
                    final BoardTag t = _tags[i];
                    final int usage = widget.notes
                            .where((n) => n.tagIds.contains(t.id))
                            .length +
                        _folders
                            .where((f) => f.tagIds.contains(t.id))
                            .length;
                    return ListTile(
                      key: ValueKey('tag_row_${t.id}'),
                      dense: true,
                      leading: InkWell(
                        key: ValueKey('tag_color_${t.id}'),
                        onTap: () async {
                          final Color? picked = await _pickColor(t.color);
                          if (picked == null) return;
                          setState(() => t.color = picked);
                          _emitTags();
                        },
                        child: Container(
                          width: 24,
                          height: 24,
                          decoration: BoxDecoration(
                            color: t.color,
                            shape: BoxShape.circle,
                            border:
                                Border.all(color: Colors.grey.shade400),
                          ),
                        ),
                      ),
                      title: TextFormField(
                        key: ValueKey('tag_name_${t.id}'),
                        initialValue: t.name,
                        decoration:
                            const InputDecoration(isDense: true, border: InputBorder.none),
                        onChanged: (v) {
                          if (v.trim().isNotEmpty) t.name = v;
                        },
                        onFieldSubmitted: (_) => _emitTags(),
                      ),
                      subtitle: Text('Used $usage×'),
                      trailing: IconButton(
                        key: ValueKey('tag_delete_${t.id}'),
                        icon:
                            const Icon(Icons.delete_outline, size: 20),
                        onPressed: () {
                          setState(() {
                            _tags.removeAt(i);
                            for (final BoardFolder f in _folders) {
                              f.tagIds.remove(t.id);
                            }
                          });
                          _emitTags();
                          _emitFolders();
                        },
                      ),
                    );
                  },
                ),
        ),
        const Divider(height: 8),
        Row(
          children: [
            Expanded(
              child: TextField(
                key: const ValueKey('tag_name_field'),
                controller: _tagController,
                decoration: const InputDecoration(
                    hintText: 'New tag name', isDense: true),
                onSubmitted: (_) => _addTag(),
              ),
            ),
            IconButton(
              key: const ValueKey('add_tag_button'),
              icon: const Icon(Icons.add),
              tooltip: 'Add tag',
              onPressed: _addTag,
            ),
          ],
        ),
      ],
    );
  }

  void _addTag() {
    final String name = _tagController.text.trim();
    if (name.isEmpty) return;
    setState(() {
      _tags.add(BoardTag(
          id: newBoardId('tag'), name: name, color: _newTagColor));
      _tagController.clear();
    });
    _emitTags();
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
