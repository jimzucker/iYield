import 'package:flutter_test/flutter_test.dart';

import 'package:iyield/main.dart';

void main() {
  testWidgets('iYield app renders the main screen', (WidgetTester tester) async {
    await tester.pumpWidget(const IYieldApp());
    await tester.pump();

    expect(find.text('iYield'), findsWidgets);
    expect(find.text('Ticker'), findsOneWidget);
    expect(find.text('Calculate'), findsOneWidget);
  });
}
