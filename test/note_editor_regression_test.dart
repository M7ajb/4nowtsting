import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:connections_board/main.dart';

/// Regression coverage for the audio/photo-attachment regression:
/// nested GestureDetectors (outer pan + inner tap/long-press) let the outer
/// pan win on real-device finger jitter, so long-press never opened the
/// full-screen editor. Since the card is a read-only preview, losing the
/// editor also meant tapping could never lead to typing.
void main() {
  testWidgets('Long-press preview body opens editor', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const ConnectionsBoardApp());
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.add));
    await tester.pump();

    expect(find.byKey(const ValueKey('note_card_0')), findsOneWidget);
    expect(find.byType(NoteEditorPage), findsNothing);

    // Long-press on the card body.
    await tester.longPress(find.byKey(const ValueKey('note_card_0')));
    await tester.pumpAndSettle();

    expect(find.byType(NoteEditorPage), findsOneWidget);
  });

  testWidgets('Long-press on drag handle stays on board (drag-only)', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const ConnectionsBoardApp());
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.add));
    await tester.pump();

    // Handle is pan-only by design so drags stay pixel-exact (adding
    // tap/long-press there eats ~20px slop). Editor opens from preview body.
    await tester.longPress(find.byKey(const ValueKey('note_handle_0')));
    await tester.pumpAndSettle();

    expect(find.byType(NoteEditorPage), findsNothing);
  });

  testWidgets('Text entry inside editor updates card preview', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const ConnectionsBoardApp());
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.add));
    await tester.pump();

    await tester.longPress(find.byKey(const ValueKey('note_card_0')));
    await tester.pumpAndSettle();

    expect(find.byType(NoteEditorPage), findsOneWidget);
    final Finder editorField = find.byKey(
      const ValueKey('editor_text_field'),
    );
    expect(editorField, findsOneWidget);

    // Audio + photo affordances must stay intact in the editor.
    expect(find.byKey(const ValueKey('record_button')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('attach_photo_button')),
      findsOneWidget,
    );

    const String typed = 'regression hello';
    await tester.enterText(editorField, typed);
    await tester.pump();

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();

    expect(find.byType(NoteEditorPage), findsNothing);
    expect(find.byKey(const ValueKey('note_card_0')), findsOneWidget);
    expect(find.text(typed), findsOneWidget);
  });

  testWidgets('Drag via handle still moves note', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const ConnectionsBoardApp());
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.add));
    await tester.pump();

    final Finder note = find.byKey(const ValueKey('note_card_0'));
    final Finder handle = find.byKey(const ValueKey('note_handle_0'));
    final Offset before = tester.getTopLeft(note);
    await tester.drag(handle, const Offset(40, 30));
    await tester.pump();

    final Offset after = tester.getTopLeft(note);
    expect(after.dx, before.dx + 40);
    expect(after.dy, before.dy + 30);
  });
}
