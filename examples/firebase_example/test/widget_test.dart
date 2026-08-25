import 'package:firebase_example/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows Firebase actions', (tester) async {
    await tester.pumpWidget(const FirebaseExampleApp());

    expect(find.text('Firebase + xcross'), findsOneWidget);
    expect(find.text('Firebase anonymous sign-in'), findsOneWidget);
    expect(find.text('Write Firestore document'), findsOneWidget);
    expect(find.text('Request messaging permission'), findsOneWidget);
  });
}
