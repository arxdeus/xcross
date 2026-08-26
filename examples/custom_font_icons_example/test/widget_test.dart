import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_vector_icons/flutter_vector_icons.dart';
import 'package:xcross_test/main.dart';

void main() {
  testWidgets('shows custom font text and package icons', (tester) async {
    await tester.pumpWidget(const MyApp());

    final text = tester.widget<Text>(find.text('Custom font text'));
    expect(text.style?.fontFamily, 'Lato');
    expect(find.byIcon(MaterialCommunityIcons.auto_fix), findsOneWidget);
    expect(find.byIcon(MaterialCommunityIcons.incognito), findsOneWidget);
  });
}
