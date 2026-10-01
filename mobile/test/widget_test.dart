// Smoke test: the app boots to the login screen when no session is stored.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:light_skate_mobile/main.dart';

void main() {
  testWidgets('shows the login screen on a fresh install', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const LightSkateApp());
    await tester.pumpAndSettle();

    expect(find.text('Light Skate'), findsWidgets);
    expect(find.widgetWithText(ElevatedButton, 'Sign in'), findsOneWidget);
  });
}
