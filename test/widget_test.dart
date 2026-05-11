import 'dart:ui';

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

  testWidgets('lays out a trip detail on a compact phone', (tester) async {
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    await binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => binding.setSurfaceSize(null));

    SharedPreferences.setMockInitialValues({
      'traveler_trips_v1': '''
[
  {
    "id": "trip-phone",
    "name": "Compact Phone Trip",
    "country": "Malaysia",
    "targetCurrency": "CNY",
    "exchangeRateToMyr": 0.5765,
    "startDate": "2026-05-25T00:00:00.000",
    "endDate": "2026-06-01T00:00:00.000",
    "members": [
      {"id": "dad", "name": "dad"},
      {"id": "shushi", "name": "shushi"},
      {"id": "darry", "name": "darry"},
      {"id": "chloe", "name": "chloe"},
      {"id": "mom", "name": "mom"}
    ],
    "attachments": [],
    "events": [
      {
        "id": "event-flight",
        "title": "Fly to Xiamen",
        "location": "Kuala Lumpur International Airport",
        "startAt": "2026-05-25T08:00:00.000",
        "durationMinutes": 240,
        "planNotes": "fly from kl to xiamen",
        "journal": "Boarding was smooth and the airport transfer was easy.",
        "feeling": "Happy",
        "expenseAmount": 5000,
        "expenseCurrencyCode": "CNY",
        "splitCount": 5,
        "isFlexible": false,
        "attachments": [],
        "expenseMemberIds": ["dad", "shushi", "darry", "chloe", "mom"]
      },
      {
        "id": "event-breakfast",
        "title": "Breakfast",
        "location": "",
        "startAt": "2026-05-26T09:00:00.000",
        "durationMinutes": 60,
        "planNotes": "Try the local breakfast spot nearby.",
        "journal": "yummy",
        "feeling": "nice",
        "expenseAmount": 200,
        "expenseCurrencyCode": "CNY",
        "splitCount": 3,
        "isFlexible": false,
        "attachments": [],
        "expenseMemberIds": ["shushi", "darry", "chloe"]
      }
    ]
  }
]
''',
    });

    await tester.pumpWidget(const TravelerApp());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.text('Compact Phone Trip'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.text('Compact Phone Trip'), findsOneWidget);
    expect(find.textContaining('CNY 5,000.00'), findsWidgets);
  });
}
