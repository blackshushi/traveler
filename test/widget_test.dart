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

  testWidgets('keeps owing summary tied to direct expense payers', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'traveler_trips_v1': '''
[
  {
    "id": "trip-debts",
    "name": "Pairwise Debt Trip",
    "country": "Malaysia",
    "targetCurrency": "CNY",
    "exchangeRateToMyr": 1,
    "startDate": "2026-05-25T00:00:00.000",
    "endDate": "2026-05-26T00:00:00.000",
    "members": [
      {"id": "a", "name": "A"},
      {"id": "b", "name": "B"},
      {"id": "c", "name": "C"},
      {"id": "d", "name": "D"},
      {"id": "e", "name": "E"}
    ],
    "attachments": [],
    "events": [
      {
        "id": "a-paid-b",
        "title": "A paid for B",
        "location": "",
        "startAt": "2026-05-25T08:00:00.000",
        "durationMinutes": 60,
        "planNotes": "",
        "journal": "",
        "feeling": "",
        "expenseAmount": 200,
        "expenseCurrencyCode": "CNY",
        "splitCount": 2,
        "isFlexible": false,
        "attachments": [],
        "expenseMemberIds": ["a", "b"],
        "expenses": [
          {
            "id": "expense-a-b",
            "title": "A paid for B",
            "amount": 200,
            "currencyCode": "CNY",
            "splitCount": 2,
            "memberIds": ["a", "b"],
            "payerMemberIds": ["a"],
            "paidMemberIds": ["a"]
          }
        ]
      },
      {
        "id": "a-paid-c",
        "title": "A paid for C",
        "location": "",
        "startAt": "2026-05-25T10:00:00.000",
        "durationMinutes": 60,
        "planNotes": "",
        "journal": "",
        "feeling": "",
        "expenseAmount": 600,
        "expenseCurrencyCode": "CNY",
        "splitCount": 2,
        "isFlexible": false,
        "attachments": [],
        "expenseMemberIds": ["a", "c"],
        "expenses": [
          {
            "id": "expense-a-c",
            "title": "A paid for C",
            "amount": 600,
            "currencyCode": "CNY",
            "splitCount": 2,
            "memberIds": ["a", "c"],
            "payerMemberIds": ["a"],
            "paidMemberIds": ["a"]
          }
        ]
      },
      {
        "id": "b-paid-all",
        "title": "B paid group",
        "location": "",
        "startAt": "2026-05-25T12:00:00.000",
        "durationMinutes": 60,
        "planNotes": "",
        "journal": "",
        "feeling": "",
        "expenseAmount": 200,
        "expenseCurrencyCode": "CNY",
        "splitCount": 5,
        "isFlexible": false,
        "attachments": [],
        "expenseMemberIds": ["a", "b", "c", "d", "e"],
        "expenses": [
          {
            "id": "expense-b-all",
            "title": "B paid group",
            "amount": 200,
            "currencyCode": "CNY",
            "splitCount": 5,
            "memberIds": ["a", "b", "c", "d", "e"],
            "payerMemberIds": ["b"],
            "paidMemberIds": ["b"]
          }
        ]
      }
    ]
  }
]
''',
    });

    await tester.pumpWidget(const TravelerApp());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.text('Pairwise Debt Trip'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.text('Expenses').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.text('B owes A'), findsNothing);
    expect(find.text('Expand'), findsOneWidget);
    expect(find.text('5 members with open balances.'), findsOneWidget);
    expect(find.text('To receive CNY 360.00'), findsNothing);

    await tester.tap(find.text('Expand'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.text('Collapse'), findsOneWidget);
    expect(find.text('To receive'), findsWidgets);
    expect(find.text('To pay'), findsWidgets);
    expect(
      tester.getTopLeft(find.text('To receive').first).dy,
      lessThan(tester.getTopLeft(find.text('To pay').first).dy),
    );
    expect(find.text('To receive CNY 360.00'), findsOneWidget);
    expect(find.text('To pay CNY 340.00'), findsOneWidget);
    expect(find.text('+CNY 60.00'), findsNothing);
    expect(find.text('-CNY 60.00'), findsNothing);
    expect(find.text('CNY 60.00'), findsNWidgets(2));
    expect(find.text('CNY 300.00'), findsNWidgets(2));
  });
}
