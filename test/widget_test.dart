import 'package:flutter_test/flutter_test.dart';

import 'package:embedded_flutter/main.dart';

void main() {
  testWidgets('Home screen renders', (WidgetTester tester) async {
    await tester.pumpWidget(const PlaudDemoApp());

    // Intro copy and primary action are visible. (On non-iOS test hosts the
    // native SDK is unavailable, so the screen also shows an error banner —
    // that's expected and not asserted here.)
    expect(find.text('Connect. Record. Transcribe.'), findsOneWidget);
    expect(find.text('Init & scan'), findsOneWidget);
  });
}
