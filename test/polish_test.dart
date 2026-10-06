import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:connections_board/main.dart';

void main() {
  testWidgets('Empty state hint shows with zero notes', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const ConnectionsBoardApp());
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('empty_state_hint')),
      findsOneWidget,
    );
    expect(find.text('Tap + to add your first note'), findsOneWidget);
  });

  testWidgets('Empty note shows Tap to write placeholder', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const ConnectionsBoardApp());
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.add));
    await tester.pump();

    expect(find.byKey(const ValueKey('note_card_0')), findsOneWidget);
    expect(find.text('Tap to write'), findsOneWidget);
    expect(find.byKey(const ValueKey('empty_state_hint')), findsNothing);
  });

  testWidgets('Tapping unfocused note brings to front without editor', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const ConnectionsBoardApp());
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.add));
    await tester.pump();
    await tester.tap(find.byIcon(Icons.add));
    await tester.pump();

    expect(find.byKey(const ValueKey('note_card_0')), findsOneWidget);
    expect(find.byKey(const ValueKey('note_card_1')), findsOneWidget);
    expect(find.byType(NoteEditorPage), findsNothing);

    // Tap the preview body of the first note (not the drag handle).
    // Must not open the editor, unlike long-press.
    await tester.tap(find.byKey(const ValueKey('note_card_0')));
    await tester.pump();

    expect(find.byType(NoteEditorPage), findsNothing);
    expect(find.byKey(const ValueKey('note_card_0')), findsOneWidget);
    expect(find.byKey(const ValueKey('note_card_1')), findsOneWidget);

    // Long-press still opens the editor.
    await tester.longPress(find.byKey(const ValueKey('note_card_0')));
    await tester.pumpAndSettle();
    expect(find.byType(NoteEditorPage), findsOneWidget);
  });

  test('deleteNoteAttachmentFiles removes audio and photo files', () async {
    final Directory tmp =
        await Directory.systemTemp.createTemp('polish_delete_unit');
    final File audio = File('${tmp.path}/clip.m4a');
    final File photo = File('${tmp.path}/pic.jpg');
    await audio.writeAsBytes([0, 1, 2, 3]);
    await photo.writeAsBytes([0, 1, 2, 3]);

    await deleteNoteAttachmentFiles([audio.path, photo.path]);

    expect(await audio.exists(), isFalse);
    expect(await photo.exists(), isFalse);
    await tmp.delete(recursive: true);
  });

  testWidgets('Deleting a note removes it and its attachments', (
    WidgetTester tester,
  ) async {
    // Missing paths: no Image.file decoding, so no widget-test hang.
    // Real file deletion is covered by the unit test above.
    const String fakeAudio = '/tmp/polish_delete_missing_clip.m4a';
    const String missingPhoto = '/tmp/polish_delete_missing_pic.jpg';

    SharedPreferences.setMockInitialValues({
      'connections_board_notes': jsonEncode([
        {
          'id': 0,
          'dx': 10.0,
          'dy': 10.0,
          'text': 'bye',
          'color': 0xFFFFF9C4,
          'audioPath': fakeAudio,
          'photoPath': missingPhoto,
        },
      ]),
    });

    await tester.pumpWidget(const ConnectionsBoardApp());
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('note_card_0')), findsOneWidget);

    await tester.longPress(find.byKey(const ValueKey('note_card_0')));
    await tester.pumpAndSettle();
    expect(find.byType(NoteEditorPage), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('delete_note_button')));
    await tester.pumpAndSettle();
    expect(find.text('Delete note?'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('confirm_delete_button')));
    await tester.pumpAndSettle();

    expect(find.byType(NoteEditorPage), findsNothing);
    expect(find.byKey(const ValueKey('note_card_0')), findsNothing);
    expect(
      find.byKey(const ValueKey('empty_state_hint')),
      findsOneWidget,
    );
  });

  testWidgets('Delete cancel keeps the note', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const ConnectionsBoardApp());
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.add));
    await tester.pump();
    await tester.longPress(find.byKey(const ValueKey('note_card_0')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('delete_note_button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('cancel_delete_button')));
    await tester.pumpAndSettle();

    expect(find.byType(NoteEditorPage), findsOneWidget);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('note_card_0')), findsOneWidget);
  });
}
