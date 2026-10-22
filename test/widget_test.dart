import 'package:flutter_test/flutter_test.dart';

import 'package:lg_ac_remote/main.dart';

void main() {
  testWidgets('LG AC remote app renders', (WidgetTester tester) async {
    await tester.pumpWidget(const LgAcRemoteApp());
    await tester.pumpAndSettle();
    expect(find.text('LG K05NSA'), findsOneWidget);
    expect(find.text('ON'), findsOneWidget);
    expect(find.text('OFF'), findsOneWidget);
  });
}
