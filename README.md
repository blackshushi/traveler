# Traveler

Traveler is a personal Flutter travel companion for Android and iOS. It keeps trips isolated so each destination has its own activities, journal, expenses, currency converter, and attachments. You can plan ahead or start recording a trip as it happens.

## Features

- Create separate trips with destination, dates, target currency, and MYR exchange rate.
- Add an activity or a standalone expense from the trip timeline; no itinerary is required first.
- Keep long activity, journal, and expense lists compact, then expand an item when its details are needed.
- Add activities with date, time, duration, location, notes, and flexible timing.
- Record experience notes, feelings, expenses, and split counts per event.
- Convert between the trip currency and MYR using a per-trip saved rate.
- Attach local files such as tickets, documents, and plans for quick access.

## Local Setup

Flutter was installed locally at:

```powershell
C:\Users\Alex\tools\flutter\bin\flutter.bat
```

Install dependencies:

```powershell
& "$env:USERPROFILE\tools\flutter\bin\flutter.bat" pub get
```

Run the app:

```powershell
& "$env:USERPROFILE\tools\flutter\bin\flutter.bat" run
```

Build a debug APK:

```powershell
$env:GRADLE_USER_HOME = "$env:USERPROFILE\.gradle-traveler"
& "$env:USERPROFILE\tools\flutter\bin\flutter.bat" build apk --debug
```

The separate `GRADLE_USER_HOME` avoids the stale proxy settings currently present in the user-level Gradle config.
