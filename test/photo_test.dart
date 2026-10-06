import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:connections_board/board_note.dart';
import 'package:connections_board/main.dart';

void main() {
  test('BoardNote photoPath persists through toJson/fromJson', () {
    final BoardNote note = BoardNote(
      id: 7,
      position: const Offset(10, 20),
      text: 'hi',
      photoPath: '/tmp/note_7.jpg',
    );
    final Map<String, dynamic> json = note.toJson();
    expect(json['photoPath'], '/tmp/note_7.jpg');

    final String raw = jsonEncode([json]);
    final List<dynamic> decoded = jsonDecode(raw) as List<dynamic>;
    final BoardNote loaded = BoardNote.fromJson(
      Map<String, dynamic>.from(decoded.first as Map),
    );
    expect(loaded.photoPath, '/tmp/note_7.jpg');
    expect(loaded.text, 'hi');
  });

  test('BoardNote fromJson is backward compatible without photoPath', () {
    final BoardNote loaded = BoardNote.fromJson({
      'id': 1,
      'dx': 0.0,
      'dy': 0.0,
      'text': 'old',
      'color': 0xFFFFF9C4,
    });
    expect(loaded.photoPath, isNull);
  });

  test('BoardNote fromJson ignores non-string photoPath', () {
    final BoardNote loaded = BoardNote.fromJson({
      'id': 2,
      'dx': 0.0,
      'dy': 0.0,
      'text': 'x',
      'color': 0xFFFFF9C4,
      'photoPath': 123,
    });
    expect(loaded.photoPath, isNull);
  });

  testWidgets('Note editor shows attach button when no photo', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: NoteEditorPage(initialText: 'hi', noteId: 1),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('attach_photo_button')), findsOneWidget);
    expect(find.byKey(const ValueKey('photo_thumbnail')), findsNothing);
    // Audio still present.
    expect(find.byKey(const ValueKey('record_button')), findsOneWidget);
  });

  testWidgets('Note editor shows thumbnail when initialPhotoPath set', (
    WidgetTester tester,
  ) async {
    // Use a missing file: editor shows Image.file with errorBuilder fallback,
    // but the thumbnail key is still present. Avoids pumpAndSettle hang that
    // real Image.file decoding causes in widget tests.
    const String fakePath = '/tmp/photo_test_missing_thumb.jpg';

    await tester.pumpWidget(
      const MaterialApp(
        home: NoteEditorPage(
          initialText: 'hi',
          noteId: 2,
          initialPhotoPath: fakePath,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byKey(const ValueKey('photo_thumbnail')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('photo_replace_button')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('photo_remove_button')), findsOneWidget);
  });

  testWidgets('Attach flow calls mocked picker (cancel keeps button)', (
    WidgetTester tester,
  ) async {
    bool pickerCalled = false;
    Future<XFile?> mockPicker(ImageSource source) async {
      pickerCalled = true;
      return null; // User cancelled.
    }

    await tester.pumpWidget(
      MaterialApp(
        home: NoteEditorPage(
          initialText: 'hi',
          noteId: 3,
          photoPicker: mockPicker,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('attach_photo_button')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('photo_source_gallery')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('photo_source_gallery')));
    await tester.pumpAndSettle();

    expect(pickerCalled, isTrue);
    expect(find.byKey(const ValueKey('attach_photo_button')), findsOneWidget);
  });

  testWidgets('Card preview shows photo indicator when note has photo', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'connections_board_notes': jsonEncode([
        {
          'id': 0,
          'dx': 10.0,
          'dy': 10.0,
          'text': 'with photo',
          'color': 0xFFFFF9C4,
          'audioPath': null,
          'photoPath': '/tmp/note_0.jpg',
        },
      ]),
    });

    await tester.pumpWidget(const ConnectionsBoardApp());
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('note_card_0')), findsOneWidget);
    expect(find.byKey(const ValueKey('photo_indicator_0')), findsOneWidget);
  });
}
