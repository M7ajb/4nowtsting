import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:connections_board/main.dart';

void main() {
  testWidgets('Board renders with color picker button', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const ConnectionsBoardApp());

    expect(find.byType(ConnectionsBoardScreen), findsOneWidget);
    expect(find.byIcon(Icons.palette_outlined), findsOneWidget);
  });

  testWidgets('Tapping palette button opens color picker dialog', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const ConnectionsBoardApp());

    await tester.tap(find.byIcon(Icons.palette_outlined));
    await tester.pumpAndSettle();

    expect(find.text('Board Color'), findsOneWidget);
    expect(find.text('Presets'), findsOneWidget);
    expect(find.text('Apply'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);
  });

  testWidgets('Tapping add button creates a note card with editable text', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const ConnectionsBoardApp());

    expect(find.byKey(const ValueKey('note_card_0')), findsNothing);

    await tester.tap(find.byIcon(Icons.add));
    await tester.pump();

    expect(find.byKey(const ValueKey('note_card_0')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('note_card_0')),
        matching: find.byType(TextField),
      ),
      findsOneWidget,
    );

    await tester.tap(find.byIcon(Icons.add));
    await tester.pump();

    expect(find.byKey(const ValueKey('note_card_0')), findsOneWidget);
    expect(find.byKey(const ValueKey('note_card_1')), findsOneWidget);
  });

  testWidgets('Dragging a note moves it and keeps it within bounds', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const ConnectionsBoardApp());

    await tester.tap(find.byIcon(Icons.add));
    await tester.pump();

    final Finder note = find.byKey(const ValueKey('note_card_0'));
    // Drag via the handle header so the pan GestureDetector wins over
    // the inner editable TextField (center hits TextField selection).
    final Finder handle = find.byKey(const ValueKey('note_handle_0'));
    expect(note, findsOneWidget);
    expect(handle, findsOneWidget);

    final Offset before = tester.getTopLeft(note);
    await tester.drag(handle, const Offset(60, 40));
    await tester.pump();

    final Offset after = tester.getTopLeft(note);
    expect(after.dx, before.dx + 60);
    expect(after.dy, before.dy + 40);

    // Drag far off-screen; note must stay within screen bounds.
    final Size screen = tester.getSize(find.byType(ConnectionsBoardScreen));
    await tester.drag(handle, const Offset(-5000, -5000));
    await tester.pump();

    final Offset clamped = tester.getTopLeft(note);
    expect(clamped.dx, greaterThanOrEqualTo(0));
    expect(clamped.dy, greaterThanOrEqualTo(0));
    expect(clamped.dx, lessThanOrEqualTo(screen.width));
    expect(clamped.dy, lessThanOrEqualTo(screen.height));
  });
}
