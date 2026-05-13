import 'package:flutter_test/flutter_test.dart';
import 'package:sandesh/main.dart';

void main() {
  testWidgets('Sandesh app starts', (WidgetTester tester) async {
    await tester.pumpWidget(const SandeshApp());
    expect(find.text('Sandesh'), findsOneWidget);
  });
}
