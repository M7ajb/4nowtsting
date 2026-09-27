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
}
