import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:traveler/main.dart';

void main() {
  testWidgets('shows an empty trip dashboard', (tester) async {
    SharedPreferences.setMockInitialValues({});

    await tester.pumpWidget(const TravelerApp());
    await tester.pumpAndSettle();

    expect(find.text('Traveler'), findsOneWidget);
    expect(find.text('Create your first trip'), findsOneWidget);
    expect(find.text('New trip'), findsWidgets);
  });
}
