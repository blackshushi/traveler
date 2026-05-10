import 'dart:convert';
import 'dart:math';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:gal/gal.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import 'clipboard_writer.dart';

void main() {
  runApp(const TravelerApp());
}

final _idRandom = Random();
final _dayFormatter = DateFormat('EEE, d MMM yyyy');
final _shortDayFormatter = DateFormat('d MMM');
final _timeFormatter = DateFormat('HH:mm');
final _moneyFormatter = NumberFormat('#,##0.00');

const _supportedCurrencies = [
  TravelCurrency('MYR', 'Malaysian ringgit', 1.0000),
  TravelCurrency('CNY', 'Chinese yuan', 0.5765),
  TravelCurrency('JPY', 'Japanese yen', 0.0250),
  TravelCurrency('SGD', 'Singapore dollar', 3.0927),
  TravelCurrency('THB', 'Thai baht', 0.1217),
  TravelCurrency('KRW', 'South Korean won', 0.0027),
  TravelCurrency('HKD', 'Hong Kong dollar', 0.5009),
  TravelCurrency('IDR', 'Indonesian rupiah', 0.0002),
  TravelCurrency('PHP', 'Philippine peso', 0.0648),
  TravelCurrency('USD', 'US dollar', 3.9210),
  TravelCurrency('EUR', 'Euro', 4.6115),
  TravelCurrency('GBP', 'British pound', 5.3367),
  TravelCurrency('AUD', 'Australian dollar', 2.8362),
  TravelCurrency('CAD', 'Canadian dollar', 2.8709),
  TravelCurrency('NZD', 'New Zealand dollar', 2.3367),
  TravelCurrency('CHF', 'Swiss franc', 5.0365),
  TravelCurrency('INR', 'Indian rupee', 0.0415),
];

typedef AttachmentAction =
    Future<void> Function(TravelEvent? event, TravelAttachment attachment);

typedef AttachmentPickAction =
    Future<TravelAttachment?> Function(TravelEvent? event);

typedef AttachmentMemberAction =
    Future<void> Function(
      TravelEvent? event,
      TravelAttachment attachment,
      Set<String> memberIds,
    );

enum EventAction { plan, experience, expense, files, delete }

enum EventFormMode { plan, experience, expense }

enum ExpenseInputMode { total, perPerson }

enum AttachmentKind { file, photo }

String _newId(String prefix) {
  final timestamp = DateTime.now().microsecondsSinceEpoch;
  final suffix = _idRandom.nextInt(999999).toString().padLeft(6, '0');
  return '${prefix}_${timestamp}_$suffix';
}

class TravelCurrency {
  const TravelCurrency(this.code, this.name, this.fallbackRateToMyr);

  final String code;
  final String name;
  final double fallbackRateToMyr;

  String get label => '$code - $name';
}

TravelCurrency _currencyForCode(String code) {
  final normalized = code.trim().toUpperCase();
  for (final currency in _supportedCurrencies) {
    if (currency.code == normalized) {
      return currency;
    }
  }

  return _supportedCurrencies.first;
}

Future<double?> _fetchRateToMyr(String code) async {
  final normalized = code.trim().toUpperCase();
  if (normalized == 'MYR') {
    return 1;
  }

  final uri = Uri.https('api.frankfurter.dev', '/v1/latest', {
    'from': normalized,
    'to': 'MYR',
  });

  try {
    final response = await http.get(uri).timeout(const Duration(seconds: 8));
    if (response.statusCode != 200) {
      return null;
    }

    final decoded = jsonDecode(response.body);
    if (decoded is Map) {
      final rates = decoded['rates'];
      if (rates is Map && rates['MYR'] is num) {
        return (rates['MYR'] as num).toDouble();
      }
    }
  } on Object {
    return null;
  }

  return null;
}

String _guessMimeType(String? extension) {
  switch (extension?.toLowerCase()) {
    case 'pdf':
      return 'application/pdf';
    case 'jpg':
    case 'jpeg':
      return 'image/jpeg';
    case 'png':
      return 'image/png';
    case 'txt':
      return 'text/plain';
    default:
      return 'application/octet-stream';
  }
}

int _minutesBetween(TimeOfDay start, TimeOfDay end) {
  final startMinutes = start.hour * 60 + start.minute;
  final endMinutes = end.hour * 60 + end.minute;
  final difference = endMinutes - startMinutes;
  return difference <= 0 ? 1 : difference;
}

String _attachmentKindName(AttachmentKind kind) {
  return switch (kind) {
    AttachmentKind.file => 'File',
    AttachmentKind.photo => 'Photo',
  };
}

Uint8List? _attachmentBytes(TravelAttachment attachment) {
  final bytesBase64 = attachment.bytesBase64;
  if (bytesBase64 == null || bytesBase64.isEmpty) {
    return null;
  }

  try {
    return base64Decode(bytesBase64);
  } on Object {
    return null;
  }
}

String _formatMoney(String code, double amount) {
  return '${_currencyForCode(code).code} ${_moneyFormatter.format(amount)}';
}

double _rateToMyrForCurrency(TravelTrip trip, String code) {
  final currency = _currencyForCode(code);
  if (currency.code == _currencyForCode(trip.targetCurrency).code) {
    return trip.exchangeRateToMyr;
  }

  return currency.fallbackRateToMyr;
}

double _expenseAmountInMyr(TravelTrip trip, TravelEvent event) {
  return event.expenseAmount *
      _rateToMyrForCurrency(trip, event.expenseCurrencyCode);
}

double _expenseAmountInTripCurrency(TravelTrip trip, TravelEvent event) {
  final targetRate = max(trip.exchangeRateToMyr, 0.000001);
  return _expenseAmountInMyr(trip, event) / targetRate;
}

List<String> _memberTagLabelsForIds(TravelTrip trip, Iterable<String> ids) {
  final selectedIds = ids.toSet();
  if (trip.members.isNotEmpty &&
      trip.members.every((member) => selectedIds.contains(member.id))) {
    return const ['All'];
  }

  return [
    for (final member in trip.members)
      if (selectedIds.contains(member.id)) member.name,
  ];
}

List<TravelTrip> _sortTripsByTime(List<TravelTrip> trips) {
  final sorted = [...trips];
  sorted.sort((a, b) {
    final aDate = a.startDate ?? a.endDate;
    final bDate = b.startDate ?? b.endDate;
    if (aDate == null && bDate == null) {
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    }
    if (aDate == null) {
      return 1;
    }
    if (bDate == null) {
      return -1;
    }

    final dateOrder = aDate.compareTo(bDate);
    if (dateOrder != 0) {
      return dateOrder;
    }
    return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  });

  return sorted;
}

String _shareDivider([int length = 42]) {
  return '-' * length;
}

String _buildTripShareText(TravelTrip trip) {
  final members = trip.members.isEmpty
      ? 'No members'
      : trip.members.map((member) => member.name).join(', ');
  final buffer = StringBuffer()
    ..writeln(_shareDivider(48))
    ..writeln(trip.name.toUpperCase())
    ..writeln('Dates: ${trip.dateRangeLabel}')
    ..writeln('Members: $members')
    ..writeln(_shareDivider(48));

  DateTime? currentDay;
  for (final event in trip.sortedEvents) {
    final eventDay = DateTime(
      event.startAt.year,
      event.startAt.month,
      event.startAt.day,
    );
    if (currentDay == null || !DateUtils.isSameDay(currentDay, eventDay)) {
      if (currentDay != null) {
        buffer.writeln();
      }
      buffer
        ..writeln()
        ..writeln(_dayFormatter.format(eventDay))
        ..writeln(_shareDivider(30));
      currentDay = eventDay;
    }

    buffer.writeln('${event.timeRangeLabel}  |  ${event.title}');
    if (event.planNotes.isNotEmpty) {
      buffer.writeln('Plan: ${event.planNotes}');
    }
    if (event.journal.isNotEmpty) {
      buffer.writeln('Experience: ${event.journal}');
    }
    if (event.feeling.isNotEmpty) {
      buffer.writeln('Feeling: ${event.feeling}');
    }
    if (event.expenseAmount > 0) {
      final members = _memberTagLabelsForIds(trip, event.expenseMemberIds);
      final perPerson = event.splitCount <= 1
          ? event.expenseAmount
          : event.expenseAmount / event.splitCount;
      buffer.writeln(
        [
          'Expense: ${_formatMoney(event.expenseCurrencyCode, event.expenseAmount)}',
          if (event.splitCount > 1)
            '${_formatMoney(event.expenseCurrencyCode, perPerson)} each',
          if (members.isNotEmpty) members.join(', '),
        ].join(' | '),
      );
    }
    buffer.writeln();
  }

  if (trip.events.isEmpty) {
    buffer.writeln('No plan yet.');
  }

  buffer.writeln(_shareDivider(48));
  return buffer.toString().trimRight();
}

class TravelerApp extends StatelessWidget {
  const TravelerApp({super.key});

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF176B6A);

    return MaterialApp(
      title: 'Traveler',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: seed,
          brightness: Brightness.light,
        ),
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFFF7F8F4),
        appBarTheme: const AppBarTheme(centerTitle: true),
        cardTheme: CardThemeData(
          elevation: 0,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
        inputDecorationTheme: const InputDecorationTheme(
          border: OutlineInputBorder(),
        ),
      ),
      home: const TravelerHomePage(repository: TripRepository()),
    );
  }
}

class TravelerHomePage extends StatefulWidget {
  const TravelerHomePage({super.key, required this.repository});

  final TripRepository repository;

  @override
  State<TravelerHomePage> createState() => _TravelerHomePageState();
}

class _TravelerHomePageState extends State<TravelerHomePage> {
  var _loading = true;
  var _trips = <TravelTrip>[];
  String? _selectedTripId;

  TravelTrip? get _selectedTrip {
    if (_selectedTripId == null) {
      return null;
    }

    for (final trip in _trips) {
      if (trip.id == _selectedTripId) {
        return trip;
      }
    }
    return null;
  }

  TravelTrip? get _firstTrip => _trips.isEmpty ? null : _trips.first;

  @override
  void initState() {
    super.initState();
    _loadTrips();
  }

  Future<void> _loadTrips() async {
    final trips = await widget.repository.loadTrips();
    if (!mounted) {
      return;
    }

    setState(() {
      _trips = _sortTripsByTime(trips);
      _selectedTripId = null;
      _loading = false;
    });
  }

  Future<void> _persistTrips(List<TravelTrip> trips) async {
    final sortedTrips = _sortTripsByTime(trips);
    setState(() {
      _trips = sortedTrips;
      if (_trips.isEmpty) {
        _selectedTripId = null;
      } else if (!_trips.any((trip) => trip.id == _selectedTripId)) {
        _selectedTripId = null;
      }
    });

    await widget.repository.saveTrips(sortedTrips);
  }

  Future<void> _upsertTrip(TravelTrip trip) async {
    final index = _trips.indexWhere((candidate) => candidate.id == trip.id);
    final next = [..._trips];

    if (index == -1) {
      next.insert(0, trip);
    } else {
      next[index] = trip;
    }

    setState(() => _selectedTripId = trip.id);
    await _persistTrips(next);
  }

  Future<void> _updateCurrentTrip(
    TravelTrip trip,
    TravelTrip Function(TravelTrip currentTrip) update,
  ) async {
    final index = _trips.indexWhere((candidate) => candidate.id == trip.id);
    if (index == -1) {
      return;
    }

    await _upsertTrip(update(_trips[index]));
  }

  Future<void> _deleteTrip(TravelTrip trip) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete trip'),
        content: Text('Delete ${trip.name}?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true) {
      return;
    }

    await _persistTrips(
      _trips.where((candidate) => candidate.id != trip.id).toList(),
    );
  }

  Future<void> _showTripDialog({TravelTrip? trip}) async {
    final savedTrip = await showDialog<TravelTrip>(
      context: context,
      builder: (context) => TripFormDialog(trip: trip),
    );

    if (savedTrip != null) {
      await _upsertTrip(savedTrip);
    }
  }

  Future<void> _showMembersDialog(TravelTrip trip) async {
    final members = await showDialog<List<TravelMember>>(
      context: context,
      builder: (context) => MembersDialog(members: trip.members),
    );

    if (members == null) {
      return;
    }

    final memberIds = members.map((member) => member.id).toSet();
    List<TravelAttachment> cleanAttachments(
      List<TravelAttachment> attachments,
    ) {
      return attachments.map((attachment) {
        return attachment.copyWith(
          memberIds: attachment.memberIds.where(memberIds.contains).toList(),
        );
      }).toList();
    }

    final events = trip.events.map((event) {
      return event.copyWith(
        expenseMemberIds: event.expenseMemberIds
            .where(memberIds.contains)
            .toList(),
        attachments: cleanAttachments(event.attachments),
      );
    }).toList();

    await _upsertTrip(
      trip.copyWith(
        members: members,
        events: events,
        attachments: cleanAttachments(trip.attachments),
      ),
    );
  }

  Future<void> _showEventDialog(
    TravelTrip trip, {
    TravelEvent? event,
    EventFormMode mode = EventFormMode.plan,
  }) async {
    final savedEvent = await showDialog<TravelEvent>(
      context: context,
      builder: (context) =>
          EventFormDialog(trip: trip, event: event, mode: mode),
    );

    if (savedEvent == null) {
      return;
    }

    final eventIndex = trip.events.indexWhere(
      (candidate) => candidate.id == savedEvent.id,
    );
    final events = [...trip.events];

    if (eventIndex == -1) {
      events.add(savedEvent);
    } else {
      events[eventIndex] = savedEvent;
    }

    await _upsertTrip(trip.copyWith(events: events));
  }

  Future<void> _showEventActions(TravelTrip trip, TravelEvent event) async {
    final action = await showModalBottomSheet<EventAction>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => EventActionsSheet(event: event),
    );

    if (action == null || !mounted) {
      return;
    }

    switch (action) {
      case EventAction.plan:
        await _showEventDialog(trip, event: event);
      case EventAction.experience:
        await _showEventDialog(
          trip,
          event: event,
          mode: EventFormMode.experience,
        );
      case EventAction.expense:
        await _showEventDialog(trip, event: event, mode: EventFormMode.expense);
      case EventAction.files:
        await _showEventFiles(trip, event);
      case EventAction.delete:
        await _deleteEvent(trip, event);
    }
  }

  Future<void> _showEventFiles(TravelTrip trip, TravelEvent event) async {
    await showDialog<void>(
      context: context,
      builder: (context) => EventFilesDialog(
        trip: trip,
        event: event,
        onOpenAttachment: _openAttachment,
        onAttachFile: () => _pickAttachment(trip, event: event),
        onPickPhoto: (source) => _pickPhoto(trip, event, source),
        onRemoveAttachment: (attachment) =>
            _removeAttachment(trip, attachment, event),
        onUpdateAttachmentMembers: (attachment, memberIds) =>
            _updateAttachmentMembers(trip, event, attachment, memberIds),
      ),
    );
  }

  Future<void> _deleteEvent(TravelTrip trip, TravelEvent event) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete event'),
        content: Text('Delete ${event.title}?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true) {
      return;
    }

    await _upsertTrip(
      trip.copyWith(
        events: trip.events
            .where((candidate) => candidate.id != event.id)
            .toList(),
      ),
    );
  }

  Future<void> _showEventTitleDialog(TravelTrip trip, TravelEvent event) async {
    final titleController = TextEditingController(text: event.title);
    final formKey = GlobalKey<FormState>();

    final title = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Edit title'),
        content: Form(
          key: formKey,
          child: TextFormField(
            controller: titleController,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Event title',
              prefixIcon: Icon(Icons.event_outlined),
            ),
            textInputAction: TextInputAction.done,
            validator: _requiredValidator,
            onFieldSubmitted: (_) {
              if (formKey.currentState!.validate()) {
                Navigator.of(context).pop(titleController.text.trim());
              }
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              if (formKey.currentState!.validate()) {
                Navigator.of(context).pop(titleController.text.trim());
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );

    titleController.dispose();

    if (title == null || title == event.title) {
      return;
    }

    await _upsertTrip(
      trip.copyWith(
        events: trip.events.map((candidate) {
          if (candidate.id != event.id) {
            return candidate;
          }

          return candidate.copyWith(title: title);
        }).toList(),
      ),
    );
  }

  Future<TravelAttachment> _addAttachmentToEvent(
    TravelTrip trip,
    TravelEvent event,
    TravelAttachment attachment,
  ) async {
    await _updateCurrentTrip(trip, (currentTrip) {
      return currentTrip.copyWith(
        events: currentTrip.events.map((candidate) {
          if (candidate.id != event.id) {
            return candidate;
          }

          return candidate.copyWith(
            attachments: [...candidate.attachments, attachment],
          );
        }).toList(),
      );
    });

    return attachment;
  }

  Future<TravelAttachment?> _pickAttachment(
    TravelTrip trip, {
    TravelEvent? event,
  }) async {
    var targetEvent = event;
    if (targetEvent == null) {
      if (trip.events.isEmpty) {
        _showSnack('Create an event before attaching files.');
        return null;
      }

      targetEvent = await showDialog<TravelEvent>(
        context: context,
        builder: (context) => AttachmentTargetDialog(events: trip.sortedEvents),
      );

      if (targetEvent == null || !mounted) {
        return null;
      }
    }

    final result = await FilePicker.pickFiles(
      dialogTitle: 'Attach file to ${targetEvent.title}',
      allowMultiple: false,
      withData: kIsWeb,
    );

    if (result == null || result.files.isEmpty) {
      return null;
    }

    final file = result.files.single;
    final attachment = TravelAttachment(
      id: _newId('file'),
      name: file.name,
      path: file.path,
      bytesBase64: file.bytes == null ? null : base64Encode(file.bytes!),
      mimeType: file.extension == null ? null : _guessMimeType(file.extension),
      kind: AttachmentKind.file,
      sizeBytes: file.size,
      addedAt: DateTime.now(),
      memberIds: const [],
    );

    return _addAttachmentToEvent(trip, targetEvent, attachment);
  }

  Future<TravelAttachment?> _pickPhoto(
    TravelTrip trip,
    TravelEvent event,
    ImageSource source,
  ) async {
    try {
      final photo = await ImagePicker().pickImage(
        source: source,
        imageQuality: 86,
      );

      if (photo == null) {
        return null;
      }

      final bytes = await photo.readAsBytes();
      if (!kIsWeb && source == ImageSource.camera) {
        try {
          await Gal.putImage(photo.path, album: 'Traveler');
        } on Object {
          if (mounted) {
            _showSnack('Photo attached, but could not save to gallery.');
          }
        }
      }

      final attachment = TravelAttachment(
        id: _newId('photo'),
        name: photo.name,
        path: kIsWeb ? null : photo.path,
        bytesBase64: base64Encode(bytes),
        mimeType: photo.mimeType ?? _guessMimeType(photo.name.split('.').last),
        kind: AttachmentKind.photo,
        sizeBytes: bytes.length,
        addedAt: DateTime.now(),
        memberIds: const [],
      );

      return _addAttachmentToEvent(trip, event, attachment);
    } on Object {
      if (!mounted) {
        return null;
      }
      _showSnack('Could not add a photo on this device.');
      return null;
    }
  }

  Future<void> _removeAttachment(
    TravelTrip trip,
    TravelAttachment attachment,
    TravelEvent? event,
  ) async {
    if (event != null) {
      await _updateCurrentTrip(trip, (currentTrip) {
        return currentTrip.copyWith(
          events: currentTrip.events.map((candidate) {
            if (candidate.id != event.id) {
              return candidate;
            }

            return candidate.copyWith(
              attachments: candidate.attachments
                  .where((candidate) => candidate.id != attachment.id)
                  .toList(),
            );
          }).toList(),
        );
      });
      return;
    }

    await _updateCurrentTrip(
      trip,
      (currentTrip) => currentTrip.copyWith(
        attachments: currentTrip.attachments
            .where((candidate) => candidate.id != attachment.id)
            .toList(),
      ),
    );
  }

  Future<void> _updateAttachmentMembers(
    TravelTrip trip,
    TravelEvent? event,
    TravelAttachment attachment,
    Set<String> memberIds,
  ) async {
    final validMemberIds = trip.members.map((member) => member.id).toSet();
    final selectedMemberIds = memberIds.where(validMemberIds.contains).toList();

    List<TravelAttachment> updateAttachments(
      List<TravelAttachment> attachments,
    ) {
      return attachments.map((candidate) {
        if (candidate.id != attachment.id) {
          return candidate;
        }

        return candidate.copyWith(memberIds: selectedMemberIds);
      }).toList();
    }

    if (event != null) {
      await _updateCurrentTrip(trip, (currentTrip) {
        return currentTrip.copyWith(
          events: currentTrip.events.map((candidate) {
            if (candidate.id != event.id) {
              return candidate;
            }

            return candidate.copyWith(
              attachments: updateAttachments(candidate.attachments),
            );
          }).toList(),
        );
      });
      return;
    }

    await _updateCurrentTrip(
      trip,
      (currentTrip) => currentTrip.copyWith(
        attachments: updateAttachments(currentTrip.attachments),
      ),
    );
  }

  Future<void> _shareAttachment(TravelAttachment attachment) async {
    try {
      final bytes = _attachmentBytes(attachment);
      final path = attachment.path;
      if (bytes == null && (path == null || path.isEmpty)) {
        _showSnack('This attachment is not available to share.');
        return;
      }

      final file = bytes != null
          ? XFile.fromData(
              bytes,
              mimeType: attachment.mimeType,
              name: attachment.name,
              length: attachment.sizeBytes,
            )
          : XFile(
              path!,
              mimeType: attachment.mimeType,
              name: attachment.name,
              length: attachment.sizeBytes,
            );

      await SharePlus.instance.share(
        ShareParams(
          title: attachment.name,
          subject: attachment.name,
          files: [file],
          fileNameOverrides: [attachment.name],
          downloadFallbackEnabled: true,
        ),
      );
    } on Object {
      if (!mounted) {
        return;
      }

      _showSnack('Could not share ${attachment.name}.');
    }
  }

  Future<void> _openAttachment(TravelAttachment attachment) async {
    final bytesBase64 = attachment.bytesBase64;
    if (bytesBase64 != null && bytesBase64.isNotEmpty) {
      await showDialog<void>(
        context: context,
        builder: (context) => AttachmentPreviewDialog(
          attachment: attachment,
          onShare: () => _shareAttachment(attachment),
        ),
      );
      return;
    }

    final path = attachment.path;
    final uri = path == null || path.isEmpty ? null : Uri.file(path);

    if (uri == null) {
      _showSnack('This file cannot be opened from this preview.');
      return;
    }

    final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);

    if (!mounted) {
      return;
    }

    if (!launched) {
      _showSnack('Could not open ${attachment.name}.');
    }
  }

  Future<void> _shareTrip(TravelTrip trip) async {
    try {
      await copyTextToClipboard(_buildTripShareText(trip));
    } on Object {
      if (!mounted) {
        return;
      }

      _showSnack('Could not copy the trip plan. Please try again.');
      return;
    }

    if (!mounted) {
      return;
    }

    _showSnack('Trip plan copied. Paste it anywhere.');
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final isWide = MediaQuery.sizeOf(context).width >= 920;
    final selectedTrip = isWide ? _selectedTrip ?? _firstTrip : _selectedTrip;

    return Scaffold(
      appBar: AppBar(
        title: GestureDetector(
          onTap: selectedTrip == null
              ? null
              : () => setState(() => _selectedTripId = null),
          child: const Text('Traveler'),
        ),
        centerTitle: true,
        actions: selectedTrip == null || isWide
            ? [
                IconButton(
                  tooltip: 'New trip',
                  onPressed: () => _showTripDialog(),
                  icon: const Icon(Icons.add),
                ),
              ]
            : null,
      ),
      body: SafeArea(
        child: _trips.isEmpty
            ? EmptyTripsView(onCreate: () => _showTripDialog())
            : isWide
            ? Row(
                children: [
                  SizedBox(
                    width: 340,
                    child: TripListPane(
                      trips: _trips,
                      selectedTripId: selectedTrip?.id,
                      onSelect: (trip) {
                        setState(() => _selectedTripId = trip.id);
                      },
                      onEdit: (trip) => _showTripDialog(trip: trip),
                      onDelete: _deleteTrip,
                    ),
                  ),
                  const VerticalDivider(width: 1),
                  Expanded(
                    child: selectedTrip == null
                        ? const SizedBox.shrink()
                        : TripDetailView(
                            trip: selectedTrip,
                            onEditTrip: () {
                              _showTripDialog(trip: selectedTrip);
                            },
                            onManageMembers: () =>
                                _showMembersDialog(selectedTrip),
                            onDeleteTrip: () => _deleteTrip(selectedTrip),
                            onShareTrip: () => _shareTrip(selectedTrip),
                            onAddEvent: () => _showEventDialog(selectedTrip),
                            onEditEvent: (event) =>
                                _showEventDialog(selectedTrip, event: event),
                            onOpenEventActions: (event) =>
                                _showEventActions(selectedTrip, event),
                            onDeleteEvent: (event) =>
                                _deleteEvent(selectedTrip, event),
                            onRenameEvent: (event) =>
                                _showEventTitleDialog(selectedTrip, event),
                            onTripChanged: _upsertTrip,
                            onAddAttachment: (event) =>
                                _pickAttachment(selectedTrip, event: event),
                            onOpenAttachment: _openAttachment,
                            onRemoveAttachment: (event, attachment) =>
                                _removeAttachment(
                                  selectedTrip,
                                  attachment,
                                  event,
                                ),
                            onUpdateAttachmentMembers:
                                (event, attachment, memberIds) =>
                                    _updateAttachmentMembers(
                                      selectedTrip,
                                      event,
                                      attachment,
                                      memberIds,
                                    ),
                          ),
                  ),
                ],
              )
            : selectedTrip == null
            ? TripListPane(
                trips: _trips,
                selectedTripId: null,
                onSelect: (trip) {
                  setState(() => _selectedTripId = trip.id);
                },
                onEdit: (trip) => _showTripDialog(trip: trip),
                onDelete: _deleteTrip,
              )
            : TripDetailView(
                trip: selectedTrip,
                onEditTrip: () => _showTripDialog(trip: selectedTrip),
                onManageMembers: () => _showMembersDialog(selectedTrip),
                onDeleteTrip: () => _deleteTrip(selectedTrip),
                onShareTrip: () => _shareTrip(selectedTrip),
                onAddEvent: () => _showEventDialog(selectedTrip),
                onEditEvent: (event) =>
                    _showEventDialog(selectedTrip, event: event),
                onOpenEventActions: (event) =>
                    _showEventActions(selectedTrip, event),
                onDeleteEvent: (event) => _deleteEvent(selectedTrip, event),
                onRenameEvent: (event) =>
                    _showEventTitleDialog(selectedTrip, event),
                onTripChanged: _upsertTrip,
                onAddAttachment: (event) =>
                    _pickAttachment(selectedTrip, event: event),
                onOpenAttachment: _openAttachment,
                onRemoveAttachment: (event, attachment) =>
                    _removeAttachment(selectedTrip, attachment, event),
                onUpdateAttachmentMembers: (event, attachment, memberIds) =>
                    _updateAttachmentMembers(
                      selectedTrip,
                      event,
                      attachment,
                      memberIds,
                    ),
              ),
      ),
    );
  }
}

class EmptyTripsView extends StatelessWidget {
  const EmptyTripsView({super.key, required this.onCreate});

  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.explore_outlined, size: 72, color: colors.primary),
              const SizedBox(height: 20),
              Text(
                'Create your first trip',
                style: Theme.of(context).textTheme.headlineSmall,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: onCreate,
                icon: const Icon(Icons.add),
                label: const Text('New trip'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class AppScrollbar extends StatefulWidget {
  const AppScrollbar({super.key, required this.builder});

  final Widget Function(ScrollController controller) builder;

  @override
  State<AppScrollbar> createState() => _AppScrollbarState();
}

class _AppScrollbarState extends State<AppScrollbar> {
  final _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scrollbar(
      controller: _controller,
      thumbVisibility: true,
      interactive: true,
      child: widget.builder(_controller),
    );
  }
}

class ResponsiveFieldRow extends StatelessWidget {
  const ResponsiveFieldRow({
    super.key,
    required this.children,
    this.breakpoint = 520,
    this.spacing = 12,
  });

  final List<Widget> children;
  final double breakpoint;
  final double spacing;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < breakpoint) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var index = 0; index < children.length; index++) ...[
                children[index],
                if (index != children.length - 1) SizedBox(height: spacing),
              ],
            ],
          );
        }

        return Row(
          children: [
            for (var index = 0; index < children.length; index++) ...[
              Expanded(child: children[index]),
              if (index != children.length - 1) SizedBox(width: spacing),
            ],
          ],
        );
      },
    );
  }
}

class TripListPane extends StatelessWidget {
  const TripListPane({
    super.key,
    required this.trips,
    required this.selectedTripId,
    required this.onSelect,
    required this.onEdit,
    required this.onDelete,
  });

  final List<TravelTrip> trips;
  final String? selectedTripId;
  final ValueChanged<TravelTrip> onSelect;
  final ValueChanged<TravelTrip> onEdit;
  final ValueChanged<TravelTrip> onDelete;

  @override
  Widget build(BuildContext context) {
    return AppScrollbar(
      builder: (controller) => ListView.separated(
        controller: controller,
        padding: const EdgeInsets.fromLTRB(12, 16, 16, 16),
        itemCount: trips.length,
        separatorBuilder: (context, index) => const SizedBox(height: 8),
        itemBuilder: (context, index) {
          final trip = trips[index];
          final selected = trip.id == selectedTripId;
          final colors = Theme.of(context).colorScheme;

          return Card(
            clipBehavior: Clip.antiAlias,
            color: selected ? colors.primaryContainer : colors.surface,
            child: ListTile(
              selected: selected,
              onTap: () => onSelect(trip),
              onLongPress: () => onEdit(trip),
              leading: CircleAvatar(
                backgroundColor: selected
                    ? colors.primary
                    : const Color(0xFFE76F51),
                foregroundColor: Colors.white,
                child: Text(
                  trip.name.trim().isEmpty
                      ? '?'
                      : trip.name.trim().characters.first.toUpperCase(),
                ),
              ),
              title: Text(
                trip.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                [
                  trip.dateRangeLabel,
                  if (trip.country.isNotEmpty) trip.country,
                  trip.targetCurrency,
                  '${trip.events.length} events',
                ].join(' - '),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: IconButton(
                tooltip: 'Delete trip',
                onPressed: () => onDelete(trip),
                icon: const Icon(Icons.delete_outline),
              ),
            ),
          );
        },
      ),
    );
  }
}

class TripDetailView extends StatefulWidget {
  const TripDetailView({
    super.key,
    required this.trip,
    required this.onEditTrip,
    required this.onManageMembers,
    required this.onDeleteTrip,
    required this.onShareTrip,
    required this.onAddEvent,
    required this.onEditEvent,
    required this.onOpenEventActions,
    required this.onDeleteEvent,
    required this.onRenameEvent,
    required this.onTripChanged,
    required this.onAddAttachment,
    required this.onOpenAttachment,
    required this.onRemoveAttachment,
    required this.onUpdateAttachmentMembers,
  });

  final TravelTrip trip;
  final VoidCallback onEditTrip;
  final VoidCallback onManageMembers;
  final VoidCallback onDeleteTrip;
  final VoidCallback onShareTrip;
  final VoidCallback onAddEvent;
  final ValueChanged<TravelEvent> onEditEvent;
  final ValueChanged<TravelEvent> onOpenEventActions;
  final ValueChanged<TravelEvent> onDeleteEvent;
  final ValueChanged<TravelEvent> onRenameEvent;
  final ValueChanged<TravelTrip> onTripChanged;
  final AttachmentPickAction onAddAttachment;
  final ValueChanged<TravelAttachment> onOpenAttachment;
  final AttachmentAction onRemoveAttachment;
  final AttachmentMemberAction onUpdateAttachmentMembers;

  @override
  State<TripDetailView> createState() => _TripDetailViewState();
}

class _TripDetailViewState extends State<TripDetailView>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  var _headerExpanded = true;
  var _lastTabIndex = 0;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
    _tabController.addListener(_handleTabChanged);
  }

  @override
  void didUpdateWidget(covariant TripDetailView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.trip.id != widget.trip.id) {
      _headerExpanded = true;
      _tabController.index = 0;
      _lastTabIndex = 0;
    }
  }

  @override
  void dispose() {
    _tabController.removeListener(_handleTabChanged);
    _tabController.dispose();
    super.dispose();
  }

  void _handleTabChanged() {
    if (_tabController.index == _lastTabIndex) {
      return;
    }

    _lastTabIndex = _tabController.index;
    _collapseHeader();
  }

  void _collapseHeader() {
    if (_headerExpanded) {
      setState(() => _headerExpanded = false);
    }
  }

  void _handleHeaderTap() {
    if (_headerExpanded) {
      widget.onEditTrip();
      return;
    }

    setState(() => _headerExpanded = true);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TripHeader(
          trip: widget.trip,
          expanded: _headerExpanded,
          onTitleTap: _handleHeaderTap,
          onManageMembers: widget.onManageMembers,
          onDelete: widget.onDeleteTrip,
          onShare: widget.onShareTrip,
        ),
        TabBar(
          controller: _tabController,
          onTap: (_) => _collapseHeader(),
          tabs: const [
            Tab(icon: Icon(Icons.edit_note_outlined), text: 'Journal'),
            Tab(icon: Icon(Icons.route_outlined), text: 'Plan'),
            Tab(icon: Icon(Icons.currency_exchange), text: 'Currency'),
            Tab(icon: Icon(Icons.folder_open_outlined), text: 'Files'),
          ],
        ),
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: [
              JournalTab(
                trip: widget.trip,
                onOpenEventActions: widget.onOpenEventActions,
              ),
              PlanTab(
                trip: widget.trip,
                onAddEvent: widget.onAddEvent,
                onEditEvent: widget.onEditEvent,
                onOpenEventActions: widget.onOpenEventActions,
                onDeleteEvent: widget.onDeleteEvent,
                onRenameEvent: widget.onRenameEvent,
              ),
              CurrencyTab(
                trip: widget.trip,
                onTripChanged: widget.onTripChanged,
              ),
              FilesTab(
                trip: widget.trip,
                onAddAttachment: widget.onAddAttachment,
                onOpenAttachment: widget.onOpenAttachment,
                onRemoveAttachment: widget.onRemoveAttachment,
                onUpdateAttachmentMembers: widget.onUpdateAttachmentMembers,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class TripHeader extends StatelessWidget {
  const TripHeader({
    super.key,
    required this.trip,
    required this.expanded,
    required this.onTitleTap,
    required this.onManageMembers,
    required this.onDelete,
    required this.onShare,
  });

  final TravelTrip trip;
  final bool expanded;
  final VoidCallback onTitleTap;
  final VoidCallback onManageMembers;
  final VoidCallback onDelete;
  final VoidCallback onShare;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final range = trip.dateRangeLabel;

    return Container(
      color: theme.colorScheme.surface,
      padding: const EdgeInsets.fromLTRB(8, 12, 16, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const SizedBox(width: 8),
          Expanded(
            child: InkWell(
              onTap: onTitleTap,
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      trip.name,
                      style: theme.textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (expanded) ...[
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 8,
                        runSpacing: 6,
                        children: [
                          TripMetaChip(
                            icon: Icons.place_outlined,
                            label: trip.country.isEmpty
                                ? 'No country'
                                : trip.country,
                          ),
                          TripMetaChip(
                            icon: Icons.calendar_today_outlined,
                            label: range,
                          ),
                          TripMetaChip(
                            icon: Icons.group_outlined,
                            label: '${trip.members.length} members',
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          IconButton(
            tooltip: 'Trip members',
            onPressed: onManageMembers,
            icon: const Icon(Icons.group_outlined),
          ),
          IconButton(
            tooltip: 'Share plan',
            onPressed: onShare,
            icon: const Icon(Icons.ios_share_outlined),
          ),
          IconButton(
            tooltip: 'Delete trip',
            onPressed: onDelete,
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
    );
  }
}

class TripMetaChip extends StatelessWidget {
  const TripMetaChip({super.key, required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Chip(
      avatar: Icon(icon, size: 18),
      label: Text(label),
      visualDensity: VisualDensity.compact,
    );
  }
}

class PlanTab extends StatelessWidget {
  const PlanTab({
    super.key,
    required this.trip,
    required this.onAddEvent,
    required this.onEditEvent,
    required this.onOpenEventActions,
    required this.onDeleteEvent,
    required this.onRenameEvent,
  });

  final TravelTrip trip;
  final VoidCallback onAddEvent;
  final ValueChanged<TravelEvent> onEditEvent;
  final ValueChanged<TravelEvent> onOpenEventActions;
  final ValueChanged<TravelEvent> onDeleteEvent;
  final ValueChanged<TravelEvent> onRenameEvent;

  @override
  Widget build(BuildContext context) {
    final events = trip.sortedEvents;
    final children = <Widget>[];
    DateTime? currentDay;

    for (var index = 0; index < events.length; index++) {
      final event = events[index];
      final day = DateTime(
        event.startAt.year,
        event.startAt.month,
        event.startAt.day,
      );
      if (currentDay == null || !DateUtils.isSameDay(currentDay, day)) {
        children.add(DaySeparator(date: day));
        currentDay = day;
      }

      children.add(
        TimelineEventCard(
          trip: trip,
          event: event,
          isFirst: index == 0,
          isLast: index == events.length - 1,
          onOpenActions: () => onOpenEventActions(event),
          onEdit: () => onEditEvent(event),
          onDelete: () => onDeleteEvent(event),
          onRename: () => onRenameEvent(event),
        ),
      );
    }

    return Stack(
      children: [
        if (events.isEmpty)
          EmptyTabView(
            icon: Icons.route_outlined,
            title: 'No plan yet',
            actionLabel: 'Add event',
            onAction: onAddEvent,
          )
        else
          AppScrollbar(
            builder: (controller) => ListView(
              controller: controller,
              padding: const EdgeInsets.fromLTRB(16, 16, 20, 88),
              children: children,
            ),
          ),
        Positioned(
          right: 16,
          bottom: 16,
          child: FloatingActionButton.extended(
            onPressed: onAddEvent,
            icon: const Icon(Icons.add),
            label: const Text('Event'),
          ),
        ),
      ],
    );
  }
}

class DaySeparator extends StatelessWidget {
  const DaySeparator({super.key, required this.date});

  final DateTime date;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 4, 0, 12),
      child: Row(
        children: [
          const Expanded(child: Divider()),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(
              _dayFormatter.format(date),
              style: theme.textTheme.labelLarge?.copyWith(
                fontWeight: FontWeight.w700,
                color: theme.colorScheme.primary,
              ),
            ),
          ),
          const Expanded(child: Divider()),
        ],
      ),
    );
  }
}

class TimelineEventCard extends StatelessWidget {
  const TimelineEventCard({
    super.key,
    required this.trip,
    required this.event,
    required this.isFirst,
    required this.isLast,
    required this.onOpenActions,
    required this.onEdit,
    required this.onDelete,
    required this.onRename,
  });

  final TravelTrip trip;
  final TravelEvent event;
  final bool isFirst;
  final bool isLast;
  final VoidCallback onOpenActions;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onRename;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 74,
            child: Column(
              children: [
                Expanded(
                  child: Container(
                    width: 2,
                    color: isFirst ? Colors.transparent : colors.outlineVariant,
                  ),
                ),
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: colors.primary,
                    shape: BoxShape.circle,
                  ),
                  child: Center(
                    child: Text(
                      _timeFormatter.format(event.startAt),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: colors.onPrimary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: Container(
                    width: 2,
                    color: isLast ? Colors.transparent : colors.outlineVariant,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: Card(
              margin: const EdgeInsets.only(bottom: 12),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Flexible(
                                    child: TextButton(
                                      onPressed: onRename,
                                      style: TextButton.styleFrom(
                                        alignment: Alignment.centerLeft,
                                        foregroundColor: colors.onSurface,
                                        padding: EdgeInsets.zero,
                                        minimumSize: Size.zero,
                                        tapTargetSize:
                                            MaterialTapTargetSize.shrinkWrap,
                                      ),
                                      child: Text(
                                        event.title,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: theme.textTheme.titleMedium
                                            ?.copyWith(
                                              fontWeight: FontWeight.w700,
                                            ),
                                      ),
                                    ),
                                  ),
                                  IconButton(
                                    tooltip: 'Edit title',
                                    onPressed: onRename,
                                    visualDensity: VisualDensity.compact,
                                    icon: const Icon(
                                      Icons.edit_outlined,
                                      size: 18,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 4),
                              InkWell(
                                onTap: onOpenActions,
                                onLongPress: onEdit,
                                borderRadius: BorderRadius.circular(6),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 2,
                                  ),
                                  child: Text(
                                    '${_dayFormatter.format(event.startAt)} - ${event.timeRangeLabel}',
                                    style: theme.textTheme.bodySmall,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          tooltip: 'Delete event',
                          onPressed: onDelete,
                          icon: const Icon(Icons.delete_outline),
                        ),
                      ],
                    ),
                    InkWell(
                      onTap: onOpenActions,
                      onLongPress: onEdit,
                      borderRadius: BorderRadius.circular(8),
                      child: Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (event.location.isNotEmpty) ...[
                              IconLine(
                                icon: Icons.place_outlined,
                                text: event.location,
                              ),
                            ],
                            if (event.planNotes.isNotEmpty) ...[
                              const SizedBox(height: 12),
                              Text(event.planNotes),
                            ],
                            const SizedBox(height: 12),
                            Wrap(
                              spacing: 8,
                              runSpacing: 6,
                              children: [
                                if (event.isFlexible)
                                  const Chip(
                                    avatar: Icon(Icons.bolt_outlined, size: 18),
                                    label: Text('Flexible'),
                                    visualDensity: VisualDensity.compact,
                                  ),
                                if (event.expenseAmount > 0)
                                  Chip(
                                    avatar: const Icon(
                                      Icons.receipt_long_outlined,
                                      size: 18,
                                    ),
                                    label: Text(
                                      _formatMoney(
                                        event.expenseCurrencyCode,
                                        event.expenseAmount,
                                      ),
                                    ),
                                    visualDensity: VisualDensity.compact,
                                  ),
                                if (event.feeling.isNotEmpty)
                                  Chip(
                                    avatar: const Icon(
                                      Icons.favorite_border,
                                      size: 18,
                                    ),
                                    label: Text(event.feeling),
                                    visualDensity: VisualDensity.compact,
                                  ),
                                if (event.attachments.isNotEmpty)
                                  Chip(
                                    avatar: const Icon(
                                      Icons.attach_file,
                                      size: 18,
                                    ),
                                    label: Text(
                                      '${event.attachments.length} files',
                                    ),
                                    visualDensity: VisualDensity.compact,
                                  ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class EventActionsSheet extends StatelessWidget {
  const EventActionsSheet({super.key, required this.event});

  final TravelEvent event;

  @override
  Widget build(BuildContext context) {
    final maxHeight = MediaQuery.sizeOf(context).height * 0.75;

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: AppScrollbar(
          builder: (controller) => SingleChildScrollView(
            controller: controller,
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  event.title,
                  style: Theme.of(context).textTheme.titleLarge,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 12),
                ActionTile(
                  icon: Icons.route_outlined,
                  title: 'Plan details',
                  subtitle: 'Time, duration, and notes',
                  onTap: () => Navigator.of(context).pop(EventAction.plan),
                ),
                ActionTile(
                  icon: Icons.edit_note_outlined,
                  title: 'Experience',
                  subtitle: 'Journal notes and feeling',
                  onTap: () =>
                      Navigator.of(context).pop(EventAction.experience),
                ),
                ActionTile(
                  icon: Icons.receipt_long_outlined,
                  title: 'Expense',
                  subtitle: 'Amount, currency, and split count',
                  onTap: () => Navigator.of(context).pop(EventAction.expense),
                ),
                ActionTile(
                  icon: Icons.folder_open_outlined,
                  title: 'Files and photos',
                  subtitle: 'View, add, or remove event files',
                  onTap: () => Navigator.of(context).pop(EventAction.files),
                ),
                const Divider(),
                ActionTile(
                  icon: Icons.delete_outline,
                  title: 'Delete event',
                  subtitle: 'Remove this item from the trip',
                  onTap: () => Navigator.of(context).pop(EventAction.delete),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class ActionTile extends StatelessWidget {
  const ActionTile({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon),
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis),
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
    );
  }
}

class JournalTab extends StatelessWidget {
  const JournalTab({
    super.key,
    required this.trip,
    required this.onOpenEventActions,
  });

  final TravelTrip trip;
  final ValueChanged<TravelEvent> onOpenEventActions;

  @override
  Widget build(BuildContext context) {
    final events = trip.sortedEvents;

    if (events.isEmpty) {
      return const EmptyTabView(
        icon: Icons.edit_note_outlined,
        title: 'No entries yet',
      );
    }

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => FocusScope.of(context).unfocus(),
      child: AppScrollbar(
        builder: (controller) => ListView(
          controller: controller,
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: const EdgeInsets.fromLTRB(16, 16, 20, 24),
          children: [
            ExpenseSummaryCard(trip: trip),
            const SizedBox(height: 12),
            for (final event in events)
              JournalEventCard(
                trip: trip,
                event: event,
                onTap: () => onOpenEventActions(event),
              ),
          ],
        ),
      ),
    );
  }
}

class ExpenseSummaryCard extends StatelessWidget {
  const ExpenseSummaryCard({super.key, required this.trip});

  final TravelTrip trip;

  @override
  Widget build(BuildContext context) {
    final totalTarget = trip.totalExpenseInTripCurrency;
    final totalMyr = trip.totalExpenseInMyr;

    return Card(
      color: const Color(0xFFFFF4E8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Wrap(
          spacing: 12,
          runSpacing: 10,
          crossAxisAlignment: WrapCrossAlignment.center,
          alignment: WrapAlignment.spaceBetween,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.account_balance_wallet_outlined),
                const SizedBox(width: 12),
                Flexible(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Expenses',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _formatMoney(trip.targetCurrency, totalTarget),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.headlineSmall
                            ?.copyWith(fontWeight: FontWeight.w800),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            Text(
              'MYR ${_moneyFormatter.format(totalMyr)}',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ],
        ),
      ),
    );
  }
}

class JournalEventCard extends StatelessWidget {
  const JournalEventCard({
    super.key,
    required this.trip,
    required this.event,
    required this.onTap,
  });

  final TravelTrip trip;
  final TravelEvent event;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    return Card(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 82,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _shortDayFormatter.format(event.startAt),
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      event.timeRangeLabel,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Text(
                            event.title,
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (event.feeling.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(left: 8),
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: colors.primaryContainer,
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 5,
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      Icons.favorite_border,
                                      size: 16,
                                      color: colors.onPrimaryContainer,
                                    ),
                                    const SizedBox(width: 4),
                                    Text(
                                      event.feeling,
                                      style: theme.textTheme.labelMedium
                                          ?.copyWith(
                                            color: colors.onPrimaryContainer,
                                          ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                    if (event.journal.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(
                        event.journal,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: colors.onSurfaceVariant,
                          height: 1.25,
                        ),
                      ),
                    ],
                    if (event.location.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      IconLine(
                        icon: Icons.place_outlined,
                        text: event.location,
                      ),
                    ],
                    if (event.expenseAmount > 0) ...[
                      const SizedBox(height: 12),
                      JournalBillPanel(trip: trip, event: event),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class JournalBillPanel extends StatelessWidget {
  const JournalBillPanel({super.key, required this.trip, required this.event});

  final TravelTrip trip;
  final TravelEvent event;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final perPerson = event.splitCount <= 1
        ? event.expenseAmount
        : event.expenseAmount / event.splitCount;
    final splitLabels = _memberTagLabelsForIds(trip, event.expenseMemberIds);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF7ED),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colors.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Align(
            alignment: Alignment.centerRight,
            child: Text(
              _formatMoney(event.expenseCurrencyCode, event.expenseAmount),
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          if (event.splitCount > 1 || splitLabels.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (event.splitCount > 1)
                  _JournalBillPill(
                    icon: Icons.group_outlined,
                    text:
                        '${_formatMoney(event.expenseCurrencyCode, perPerson)} each',
                  ),
                for (final label in splitLabels)
                  _JournalBillPill(
                    icon: label == 'All'
                        ? Icons.groups_outlined
                        : Icons.person_outline,
                    text: label,
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _JournalBillPill extends StatelessWidget {
  const _JournalBillPill({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: colors.outlineVariant),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: colors.primary),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelMedium,
            ),
          ),
        ],
      ),
    );
  }
}

class CurrencyTab extends StatefulWidget {
  const CurrencyTab({
    super.key,
    required this.trip,
    required this.onTripChanged,
  });

  final TravelTrip trip;
  final ValueChanged<TravelTrip> onTripChanged;

  @override
  State<CurrencyTab> createState() => _CurrencyTabState();
}

class _CurrencyTabState extends State<CurrencyTab> {
  late final TextEditingController _amountController;
  late final TextEditingController _rateController;
  late String _selectedCurrency;
  var _fromTarget = true;
  var _loadingRate = false;

  @override
  void initState() {
    super.initState();
    _selectedCurrency = _currencyForCode(widget.trip.targetCurrency).code;
    _amountController = TextEditingController(text: '100');
    _rateController = TextEditingController(
      text: widget.trip.exchangeRateToMyr.toStringAsFixed(4),
    );
  }

  @override
  void didUpdateWidget(covariant CurrencyTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.trip.id != widget.trip.id ||
        oldWidget.trip.targetCurrency != widget.trip.targetCurrency ||
        oldWidget.trip.exchangeRateToMyr != widget.trip.exchangeRateToMyr) {
      _selectedCurrency = _currencyForCode(widget.trip.targetCurrency).code;
      _rateController.text = widget.trip.exchangeRateToMyr.toStringAsFixed(4);
    }
  }

  @override
  void dispose() {
    _amountController.dispose();
    _rateController.dispose();
    super.dispose();
  }

  Future<void> _selectCurrency(String code) async {
    final currency = _currencyForCode(code);
    setState(() {
      _selectedCurrency = currency.code;
      _fromTarget = true;
      _rateController.text = currency.fallbackRateToMyr.toStringAsFixed(4);
    });

    widget.onTripChanged(
      widget.trip.copyWith(
        targetCurrency: currency.code,
        exchangeRateToMyr: currency.fallbackRateToMyr,
      ),
    );

    await _refreshRate(saveAfterRefresh: true);
  }

  Future<void> _refreshRate({bool saveAfterRefresh = false}) async {
    setState(() => _loadingRate = true);
    final rate = await _fetchRateToMyr(_selectedCurrency);
    if (!mounted) {
      return;
    }

    setState(() {
      _loadingRate = false;
      if (rate != null) {
        _rateController.text = rate.toStringAsFixed(4);
      }
    });

    if (rate != null && saveAfterRefresh) {
      widget.onTripChanged(
        widget.trip.copyWith(
          targetCurrency: _selectedCurrency,
          exchangeRateToMyr: rate,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final amount = double.tryParse(_amountController.text.trim()) ?? 0;
    final rate =
        double.tryParse(_rateController.text.trim()) ??
        widget.trip.exchangeRateToMyr;
    final converted = _fromTarget
        ? amount * rate
        : rate == 0
        ? 0
        : amount / rate;
    final fromCode = _fromTarget ? _selectedCurrency : 'MYR';
    final toCode = _fromTarget ? 'MYR' : _selectedCurrency;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => FocusScope.of(context).unfocus(),
      child: AppScrollbar(
        builder: (controller) => ListView(
          controller: controller,
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: const EdgeInsets.fromLTRB(16, 16, 20, 24),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Converter',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 16),
                    DropdownButtonFormField<String>(
                      key: ValueKey('converter_$_selectedCurrency'),
                      initialValue: _selectedCurrency,
                      decoration: const InputDecoration(
                        labelText: 'Trip currency',
                        prefixIcon: Icon(Icons.payments_outlined),
                      ),
                      items: [
                        for (final currency in _supportedCurrencies)
                          DropdownMenuItem(
                            value: currency.code,
                            child: Text(currency.label),
                          ),
                      ],
                      onChanged: (value) {
                        if (value != null) {
                          _selectCurrency(value);
                        }
                      },
                    ),
                    const SizedBox(height: 16),
                    SegmentedButton<bool>(
                      segments: [
                        ButtonSegment(
                          value: true,
                          icon: const Icon(Icons.arrow_forward),
                          label: Text('$_selectedCurrency to MYR'),
                        ),
                        ButtonSegment(
                          value: false,
                          icon: const Icon(Icons.arrow_back),
                          label: Text('MYR to $_selectedCurrency'),
                        ),
                      ],
                      selected: {_fromTarget},
                      onSelectionChanged: (value) {
                        setState(() => _fromTarget = value.first);
                      },
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: _amountController,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: InputDecoration(
                        labelText: 'Amount in $fromCode',
                        prefixIcon: const Icon(Icons.calculate_outlined),
                      ),
                      onTapOutside: (_) => FocusScope.of(context).unfocus(),
                      onChanged: (_) => setState(() {}),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _rateController,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: InputDecoration(
                        labelText: '1 $_selectedCurrency in MYR',
                        prefixIcon: _loadingRate
                            ? const Padding(
                                padding: EdgeInsets.all(12),
                                child: SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                ),
                              )
                            : const Icon(Icons.tune_outlined),
                      ),
                      onTapOutside: (_) => FocusScope.of(context).unfocus(),
                      onChanged: (_) => setState(() {}),
                    ),
                    const SizedBox(height: 16),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        FilledButton.icon(
                          onPressed: () {
                            final parsed = double.tryParse(
                              _rateController.text.trim(),
                            );
                            if (parsed == null || parsed <= 0) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('Enter a valid rate.'),
                                ),
                              );
                              return;
                            }

                            widget.onTripChanged(
                              widget.trip.copyWith(
                                targetCurrency: _selectedCurrency,
                                exchangeRateToMyr: parsed,
                              ),
                            );
                          },
                          icon: const Icon(Icons.save_outlined),
                          label: const Text('Save rate'),
                        ),
                        FilledButton.tonalIcon(
                          onPressed: _loadingRate ? null : _refreshRate,
                          icon: const Icon(Icons.sync),
                          label: const Text('Refresh'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            Card(
              color: const Color(0xFFEAF6F2),
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '$fromCode ${_moneyFormatter.format(amount)}',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '$toCode ${_moneyFormatter.format(converted)}',
                      style: Theme.of(context).textTheme.displaySmall?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class FilesTab extends StatefulWidget {
  const FilesTab({
    super.key,
    required this.trip,
    required this.onAddAttachment,
    required this.onOpenAttachment,
    required this.onRemoveAttachment,
    required this.onUpdateAttachmentMembers,
  });

  final TravelTrip trip;
  final AttachmentPickAction onAddAttachment;
  final ValueChanged<TravelAttachment> onOpenAttachment;
  final AttachmentAction onRemoveAttachment;
  final AttachmentMemberAction onUpdateAttachmentMembers;

  @override
  State<FilesTab> createState() => _FilesTabState();
}

class _FilesTabState extends State<FilesTab> {
  String? _selectedMemberId;

  Future<void> _editPinnedMembers(AttachmentListItem item) async {
    final memberIds = await showDialog<Set<String>>(
      context: context,
      builder: (context) => AttachmentMembersDialog(
        attachment: item.attachment,
        members: widget.trip.members,
      ),
    );

    if (memberIds == null) {
      return;
    }

    await widget.onUpdateAttachmentMembers(
      item.event,
      item.attachment,
      memberIds,
    );
  }

  @override
  Widget build(BuildContext context) {
    final activeMemberId =
        widget.trip.members.any((member) => member.id == _selectedMemberId)
        ? _selectedMemberId
        : null;
    final allItems = [
      for (final attachment in widget.trip.attachments)
        AttachmentListItem(event: null, attachment: attachment),
      for (final event in widget.trip.sortedEvents)
        for (final attachment in event.attachments)
          AttachmentListItem(event: event, attachment: attachment),
    ];
    final items = activeMemberId == null
        ? allItems
        : allItems
              .where(
                (item) => item.attachment.memberIds.contains(activeMemberId),
              )
              .toList();

    if (allItems.isEmpty) {
      return EmptyTabView(
        icon: Icons.folder_open_outlined,
        title: widget.trip.events.isEmpty ? 'No events yet' : 'No files yet',
        actionLabel: widget.trip.events.isEmpty ? null : 'Add',
        onAction: widget.trip.events.isEmpty
            ? null
            : () => widget.onAddAttachment(null),
      );
    }

    return AppScrollbar(
      builder: (controller) => ListView(
        controller: controller,
        padding: const EdgeInsets.fromLTRB(16, 16, 20, 24),
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              FilledButton.icon(
                onPressed: () => widget.onAddAttachment(null),
                icon: const Icon(Icons.add),
                label: const Text('Add'),
              ),
              if (widget.trip.members.isNotEmpty)
                ChoiceChip(
                  label: const Text('All'),
                  selected: activeMemberId == null,
                  onSelected: (_) => setState(() => _selectedMemberId = null),
                ),
              for (final member in widget.trip.members)
                ChoiceChip(
                  avatar: const Icon(Icons.person_outline, size: 18),
                  label: Text(member.name),
                  selected: activeMemberId == member.id,
                  onSelected: (_) =>
                      setState(() => _selectedMemberId = member.id),
                ),
            ],
          ),
          const SizedBox(height: 12),
          if (items.isEmpty)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  activeMemberId == null
                      ? 'No files yet'
                      : 'No files pinned to this traveler',
                ),
              ),
            )
          else
            for (final item in items) ...[
              _AttachmentCard(
                trip: widget.trip,
                item: item,
                onOpenAttachment: widget.onOpenAttachment,
                onRemoveAttachment: widget.onRemoveAttachment,
                onEditPinnedMembers: _editPinnedMembers,
              ),
              const SizedBox(height: 8),
            ],
        ],
      ),
    );
  }
}

class _AttachmentCard extends StatelessWidget {
  const _AttachmentCard({
    required this.trip,
    required this.item,
    required this.onOpenAttachment,
    required this.onRemoveAttachment,
    required this.onEditPinnedMembers,
  });

  final TravelTrip trip;
  final AttachmentListItem item;
  final ValueChanged<TravelAttachment> onOpenAttachment;
  final AttachmentAction onRemoveAttachment;
  final ValueChanged<AttachmentListItem> onEditPinnedMembers;

  @override
  Widget build(BuildContext context) {
    final attachment = item.attachment;

    return Card(
      child: ListTile(
        leading: AttachmentThumbnail(attachment: attachment, size: 56),
        title: Text(
          attachment.name,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              [
                item.event?.title ?? 'Trip file',
                _formatBytes(attachment.sizeBytes),
                _shortDayFormatter.format(attachment.addedAt),
              ].join(' - '),
            ),
            MemberTagWrap(trip: trip, memberIds: attachment.memberIds),
          ],
        ),
        onTap: () => onOpenAttachment(attachment),
        trailing: SizedBox(
          width: 96,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              IconButton(
                tooltip: 'Pin members',
                onPressed: () => onEditPinnedMembers(item),
                icon: const Icon(Icons.person_pin_outlined),
              ),
              IconButton(
                tooltip: 'Remove file',
                onPressed: () => onRemoveAttachment(item.event, attachment),
                icon: const Icon(Icons.delete_outline),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class AttachmentListTile extends StatelessWidget {
  const AttachmentListTile({
    super.key,
    required this.trip,
    required this.attachment,
    required this.onOpen,
    required this.onEditPinnedMembers,
    required this.onRemove,
  });

  final TravelTrip trip;
  final TravelAttachment attachment;
  final VoidCallback onOpen;
  final VoidCallback onEditPinnedMembers;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: AttachmentThumbnail(attachment: attachment, size: 48),
      title: Text(
        attachment.name,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${_attachmentKindName(attachment.kind)} - ${_formatBytes(attachment.sizeBytes)}',
          ),
          MemberTagWrap(trip: trip, memberIds: attachment.memberIds),
        ],
      ),
      onTap: onOpen,
      trailing: SizedBox(
        width: 96,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            IconButton(
              tooltip: 'Pin members',
              onPressed: onEditPinnedMembers,
              icon: const Icon(Icons.person_pin_outlined),
            ),
            IconButton(
              tooltip: 'Remove',
              onPressed: onRemove,
              icon: const Icon(Icons.delete_outline),
            ),
          ],
        ),
      ),
    );
  }
}

class PhotoAttachmentCard extends StatelessWidget {
  const PhotoAttachmentCard({
    super.key,
    required this.trip,
    required this.attachment,
    required this.onOpen,
    required this.onEditPinnedMembers,
    required this.onRemove,
  });

  final TravelTrip trip;
  final TravelAttachment attachment;
  final VoidCallback onOpen;
  final VoidCallback onEditPinnedMembers;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onOpen,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: AttachmentThumbnail(
                attachment: attachment,
                size: double.infinity,
                borderRadius: BorderRadius.zero,
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 6, 4),
              child: Text(
                attachment.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelLarge,
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 4, 6),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _formatBytes(attachment.sizeBytes),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Pin members',
                    visualDensity: VisualDensity.compact,
                    onPressed: onEditPinnedMembers,
                    icon: const Icon(Icons.person_pin_outlined, size: 20),
                  ),
                  IconButton(
                    tooltip: 'Remove',
                    visualDensity: VisualDensity.compact,
                    onPressed: onRemove,
                    icon: const Icon(Icons.delete_outline, size: 20),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class AttachmentThumbnail extends StatelessWidget {
  const AttachmentThumbnail({
    super.key,
    required this.attachment,
    required this.size,
    this.borderRadius,
  });

  final TravelAttachment attachment;
  final double size;
  final BorderRadius? borderRadius;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final bytes = attachment.kind == AttachmentKind.photo
        ? _attachmentBytes(attachment)
        : null;
    final radius = borderRadius ?? BorderRadius.circular(8);
    final icon = attachment.kind == AttachmentKind.photo
        ? Icons.image_outlined
        : Icons.insert_drive_file_outlined;

    return ClipRRect(
      borderRadius: radius,
      child: SizedBox(
        width: size,
        height: size,
        child: bytes == null
            ? ColoredBox(
                color: colors.surfaceContainerHighest,
                child: Icon(icon, color: colors.onSurfaceVariant),
              )
            : Image.memory(bytes, fit: BoxFit.cover),
      ),
    );
  }
}

class AttachmentListItem {
  const AttachmentListItem({required this.event, required this.attachment});

  final TravelEvent? event;
  final TravelAttachment attachment;
}

class AttachmentTargetDialog extends StatelessWidget {
  const AttachmentTargetDialog({super.key, required this.events});

  final List<TravelEvent> events;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Attach to event'),
      content: SizedBox(
        width: min(MediaQuery.sizeOf(context).width - 48, 420),
        child: AppScrollbar(
          builder: (controller) => ListView.separated(
            controller: controller,
            shrinkWrap: true,
            itemCount: events.length,
            separatorBuilder: (context, index) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final event = events[index];
              return ListTile(
                leading: const Icon(Icons.event_outlined),
                title: Text(event.title),
                subtitle: Text(_dayFormatter.format(event.startAt)),
                onTap: () => Navigator.of(context).pop(event),
              );
            },
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}

class AttachmentMembersDialog extends StatefulWidget {
  const AttachmentMembersDialog({
    super.key,
    required this.attachment,
    required this.members,
  });

  final TravelAttachment attachment;
  final List<TravelMember> members;

  @override
  State<AttachmentMembersDialog> createState() =>
      _AttachmentMembersDialogState();
}

class _AttachmentMembersDialogState extends State<AttachmentMembersDialog> {
  late Set<String> _selectedMemberIds;

  @override
  void initState() {
    super.initState();
    final validMemberIds = widget.members.map((member) => member.id).toSet();
    _selectedMemberIds = widget.attachment.memberIds
        .where(validMemberIds.contains)
        .toSet();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Pin to travelers'),
      content: SizedBox(
        width: min(MediaQuery.sizeOf(context).width - 48, 420),
        child: widget.members.isEmpty
            ? const Text('Add travelers before pinning files.')
            : Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final member in widget.members)
                    FilterChip(
                      avatar: const Icon(Icons.person_outline, size: 18),
                      label: Text(member.name),
                      selected: _selectedMemberIds.contains(member.id),
                      onSelected: (selected) {
                        setState(() {
                          if (selected) {
                            _selectedMemberIds.add(member.id);
                          } else {
                            _selectedMemberIds.remove(member.id);
                          }
                        });
                      },
                    ),
                ],
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(<String>{}),
          child: const Text('Clear'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_selectedMemberIds),
          child: const Text('Save'),
        ),
      ],
    );
  }
}

class MemberTagWrap extends StatelessWidget {
  const MemberTagWrap({super.key, required this.trip, required this.memberIds});

  final TravelTrip trip;
  final Iterable<String> memberIds;

  @override
  Widget build(BuildContext context) {
    final labels = _memberTagLabelsForIds(trip, memberIds);
    if (labels.isEmpty) {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Wrap(
        spacing: 6,
        runSpacing: 4,
        children: [
          for (final label in labels)
            Chip(
              avatar: Icon(
                label == 'All' ? Icons.groups_outlined : Icons.person_outline,
                size: 16,
              ),
              label: Text(label),
              visualDensity: VisualDensity.compact,
            ),
        ],
      ),
    );
  }
}

class EventFilesDialog extends StatefulWidget {
  const EventFilesDialog({
    super.key,
    required this.trip,
    required this.event,
    required this.onOpenAttachment,
    required this.onAttachFile,
    required this.onPickPhoto,
    required this.onRemoveAttachment,
    required this.onUpdateAttachmentMembers,
  });

  final TravelTrip trip;
  final TravelEvent event;
  final ValueChanged<TravelAttachment> onOpenAttachment;
  final Future<TravelAttachment?> Function() onAttachFile;
  final Future<TravelAttachment?> Function(ImageSource source) onPickPhoto;
  final Future<void> Function(TravelAttachment attachment) onRemoveAttachment;
  final Future<void> Function(
    TravelAttachment attachment,
    Set<String> memberIds,
  )
  onUpdateAttachmentMembers;

  @override
  State<EventFilesDialog> createState() => _EventFilesDialogState();
}

class _EventFilesDialogState extends State<EventFilesDialog>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  late List<TravelAttachment> _attachments;

  @override
  void initState() {
    super.initState();
    _attachments = [...widget.event.attachments];
    _tabController = TabController(length: 2, vsync: this);
    _tabController.addListener(() {
      if (mounted) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  List<TravelAttachment> get _files => [
    for (final attachment in _attachments)
      if (attachment.kind == AttachmentKind.file) attachment,
  ];

  List<TravelAttachment> get _photos => [
    for (final attachment in _attachments)
      if (attachment.kind == AttachmentKind.photo) attachment,
  ];

  Future<void> _editPinnedMembers(
    BuildContext context,
    TravelAttachment attachment,
  ) async {
    final memberIds = await showDialog<Set<String>>(
      context: context,
      builder: (context) => AttachmentMembersDialog(
        attachment: attachment,
        members: widget.trip.members,
      ),
    );

    if (memberIds == null) {
      return;
    }

    await widget.onUpdateAttachmentMembers(attachment, memberIds);
    if (!mounted) {
      return;
    }

    setState(() {
      _attachments = _attachments.map((candidate) {
        if (candidate.id != attachment.id) {
          return candidate;
        }

        return candidate.copyWith(memberIds: memberIds.toList());
      }).toList();
    });
  }

  Future<void> _addFile() async {
    final attachment = await widget.onAttachFile();
    if (attachment == null || !mounted) {
      return;
    }

    setState(() => _attachments = [..._attachments, attachment]);
  }

  Future<void> _addPhoto() async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.photo_library_outlined),
                title: const Text('Gallery'),
                onTap: () => Navigator.of(context).pop(ImageSource.gallery),
              ),
              ListTile(
                leading: const Icon(Icons.photo_camera_outlined),
                title: const Text('Camera'),
                onTap: () => Navigator.of(context).pop(ImageSource.camera),
              ),
            ],
          ),
        ),
      ),
    );

    if (source == null) {
      return;
    }

    final attachment = await widget.onPickPhoto(source);
    if (attachment == null || !mounted) {
      return;
    }

    setState(() => _attachments = [..._attachments, attachment]);
  }

  Future<void> _removeAttachment(TravelAttachment attachment) async {
    await widget.onRemoveAttachment(attachment);
    if (!mounted) {
      return;
    }

    setState(() {
      _attachments = _attachments
          .where((candidate) => candidate.id != attachment.id)
          .toList();
    });
  }

  Future<void> _handleAdd() {
    return _tabController.index == 0 ? _addFile() : _addPhoto();
  }

  @override
  Widget build(BuildContext context) {
    final selectedIsFiles = _tabController.index == 0;

    return AlertDialog(
      title: Text('${widget.event.title} files'),
      content: SizedBox(
        width: min(MediaQuery.sizeOf(context).width - 48, 560),
        height: min(MediaQuery.sizeOf(context).height * 0.58, 460),
        child: Column(
          children: [
            TabBar(
              controller: _tabController,
              tabs: const [
                Tab(icon: Icon(Icons.attach_file), text: 'Files'),
                Tab(icon: Icon(Icons.photo_library_outlined), text: 'Photos'),
              ],
            ),
            const SizedBox(height: 12),
            Expanded(
              child: TabBarView(
                controller: _tabController,
                children: [
                  _files.isEmpty
                      ? const Center(child: Text('No files yet'))
                      : AppScrollbar(
                          builder: (controller) => ListView.separated(
                            controller: controller,
                            itemCount: _files.length,
                            separatorBuilder: (context, index) =>
                                const Divider(height: 1),
                            itemBuilder: (context, index) {
                              final attachment = _files[index];
                              return AttachmentListTile(
                                trip: widget.trip,
                                attachment: attachment,
                                onOpen: () =>
                                    widget.onOpenAttachment(attachment),
                                onEditPinnedMembers: () =>
                                    _editPinnedMembers(context, attachment),
                                onRemove: () => _removeAttachment(attachment),
                              );
                            },
                          ),
                        ),
                  _photos.isEmpty
                      ? const Center(child: Text('No photos yet'))
                      : AppScrollbar(
                          builder: (controller) => GridView.builder(
                            controller: controller,
                            gridDelegate:
                                const SliverGridDelegateWithMaxCrossAxisExtent(
                                  maxCrossAxisExtent: 180,
                                  mainAxisSpacing: 10,
                                  crossAxisSpacing: 10,
                                  childAspectRatio: 0.78,
                                ),
                            itemCount: _photos.length,
                            itemBuilder: (context, index) {
                              final attachment = _photos[index];
                              return PhotoAttachmentCard(
                                trip: widget.trip,
                                attachment: attachment,
                                onOpen: () =>
                                    widget.onOpenAttachment(attachment),
                                onEditPinnedMembers: () =>
                                    _editPinnedMembers(context, attachment),
                                onRemove: () => _removeAttachment(attachment),
                              );
                            },
                          ),
                        ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
        FilledButton.icon(
          onPressed: _handleAdd,
          icon: Icon(
            selectedIsFiles ? Icons.attach_file : Icons.add_photo_alternate,
          ),
          label: const Text('Add'),
        ),
      ],
    );
  }
}

class AttachmentPreviewDialog extends StatelessWidget {
  const AttachmentPreviewDialog({
    super.key,
    required this.attachment,
    required this.onShare,
  });

  final TravelAttachment attachment;
  final Future<void> Function() onShare;

  @override
  Widget build(BuildContext context) {
    final bytes = _attachmentBytes(attachment);
    final mimeType = attachment.mimeType ?? 'application/octet-stream';
    final isImage = bytes != null && mimeType.startsWith('image/');
    final isText = bytes != null && mimeType.startsWith('text/');

    return AlertDialog(
      title: Text(
        attachment.name,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      content: SizedBox(
        width: min(MediaQuery.sizeOf(context).width - 48, 560),
        child: isImage
            ? ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.memory(bytes, fit: BoxFit.contain),
              )
            : isText
            ? ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 360),
                child: AppScrollbar(
                  builder: (controller) => SingleChildScrollView(
                    controller: controller,
                    child: Text(utf8.decode(bytes, allowMalformed: true)),
                  ),
                ),
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_attachmentKindName(attachment.kind)),
                  const SizedBox(height: 8),
                  Text(_formatBytes(attachment.sizeBytes)),
                  const SizedBox(height: 8),
                  Text(mimeType),
                ],
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
        FilledButton.icon(
          onPressed: () async {
            await onShare();
          },
          icon: const Icon(Icons.ios_share_outlined),
          label: const Text('Share'),
        ),
      ],
    );
  }
}

class MembersDialog extends StatefulWidget {
  const MembersDialog({super.key, required this.members});

  final List<TravelMember> members;

  @override
  State<MembersDialog> createState() => _MembersDialogState();
}

class _MembersDialogState extends State<MembersDialog> {
  late final TextEditingController _memberController;
  late List<TravelMember> _members;

  @override
  void initState() {
    super.initState();
    _memberController = TextEditingController();
    _members = [...widget.members];
  }

  @override
  void dispose() {
    _memberController.dispose();
    super.dispose();
  }

  void _addMember() {
    final name = _memberController.text.trim();
    if (name.isEmpty) {
      return;
    }

    setState(() {
      _members = [..._members, TravelMember(id: _newId('member'), name: name)];
      _memberController.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Trip members'),
      content: SizedBox(
        width: min(MediaQuery.sizeOf(context).width - 48, 460),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _memberController,
                    decoration: const InputDecoration(
                      labelText: 'Member name',
                      prefixIcon: Icon(Icons.person_add_outlined),
                    ),
                    onSubmitted: (_) => _addMember(),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filledTonal(
                  tooltip: 'Add member',
                  onPressed: _addMember,
                  icon: const Icon(Icons.add),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (_members.isEmpty)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text('No members yet'),
              )
            else
              Flexible(
                child: AppScrollbar(
                  builder: (controller) => ListView.separated(
                    controller: controller,
                    shrinkWrap: true,
                    itemCount: _members.length,
                    separatorBuilder: (context, index) =>
                        const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final member = _members[index];
                      return ListTile(
                        leading: const Icon(Icons.person_outline),
                        title: Text(member.name),
                        trailing: IconButton(
                          tooltip: 'Remove member',
                          onPressed: () {
                            setState(() {
                              _members = [
                                ..._members.take(index),
                                ..._members.skip(index + 1),
                              ];
                            });
                          },
                          icon: const Icon(Icons.delete_outline),
                        ),
                      );
                    },
                  ),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_members),
          child: const Text('Save'),
        ),
      ],
    );
  }
}

class EmptyTabView extends StatelessWidget {
  const EmptyTabView({
    super.key,
    required this.icon,
    required this.title,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56, color: colors.primary),
            const SizedBox(height: 16),
            Text(
              title,
              style: Theme.of(context).textTheme.titleLarge,
              textAlign: TextAlign.center,
            ),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: onAction,
                icon: const Icon(Icons.add),
                label: Text(actionLabel!),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class IconLine extends StatelessWidget {
  const IconLine({super.key, required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18),
        const SizedBox(width: 8),
        Expanded(child: Text(text)),
      ],
    );
  }
}

class TripFormDialog extends StatefulWidget {
  const TripFormDialog({super.key, this.trip});

  final TravelTrip? trip;

  @override
  State<TripFormDialog> createState() => _TripFormDialogState();
}

class _TripFormDialogState extends State<TripFormDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController;
  late final TextEditingController _countryController;
  late final TextEditingController _rateController;
  late String _selectedCurrency;
  var _loadingRate = false;
  DateTime? _startDate;
  DateTime? _endDate;

  @override
  void initState() {
    super.initState();
    final trip = widget.trip;
    _nameController = TextEditingController(text: trip?.name ?? '');
    _countryController = TextEditingController(text: trip?.country ?? '');
    _selectedCurrency = _currencyForCode(trip?.targetCurrency ?? 'CNY').code;
    _rateController = TextEditingController(
      text:
          (trip?.exchangeRateToMyr ??
                  _currencyForCode(_selectedCurrency).fallbackRateToMyr)
              .toStringAsFixed(4),
    );
    _startDate = trip?.startDate;
    _endDate = trip?.endDate;

    if (trip == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _refreshRate(_selectedCurrency);
      });
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _countryController.dispose();
    _rateController.dispose();
    super.dispose();
  }

  Future<void> _refreshRate(String code) async {
    setState(() => _loadingRate = true);
    final rate = await _fetchRateToMyr(code);
    if (!mounted || code != _selectedCurrency) {
      return;
    }

    setState(() {
      _loadingRate = false;
      if (rate != null) {
        _rateController.text = rate.toStringAsFixed(4);
      }
    });
  }

  void _selectCurrency(String code) {
    final currency = _currencyForCode(code);
    setState(() {
      _selectedCurrency = currency.code;
      _rateController.text = currency.fallbackRateToMyr.toStringAsFixed(4);
    });
    _refreshRate(currency.code);
  }

  Future<void> _pickDate({required bool isStart}) async {
    final initial = isStart
        ? _startDate ?? DateTime.now()
        : _endDate ?? _startDate ?? DateTime.now();
    final selected = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );

    if (selected == null || !mounted) {
      return;
    }

    setState(() {
      if (isStart) {
        _startDate = selected;
        if (_endDate != null && _endDate!.isBefore(selected)) {
          _endDate = selected;
        }
      } else {
        _endDate = selected;
      }
    });
  }

  void _save() {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    final existing = widget.trip;
    final trip = TravelTrip(
      id: existing?.id ?? _newId('trip'),
      name: _nameController.text.trim(),
      country: _countryController.text.trim(),
      targetCurrency: _selectedCurrency,
      exchangeRateToMyr: double.parse(_rateController.text.trim()),
      startDate: _startDate,
      endDate: _endDate,
      events: existing?.events ?? const [],
      attachments: existing?.attachments ?? const [],
      members: existing?.members ?? const [],
    );

    Navigator.of(context).pop(trip);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.trip == null ? 'New trip' : 'Edit trip'),
      content: SizedBox(
        width: min(MediaQuery.sizeOf(context).width - 48, 520),
        child: Form(
          key: _formKey,
          child: AppScrollbar(
            builder: (controller) => SingleChildScrollView(
              controller: controller,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextFormField(
                    controller: _nameController,
                    decoration: const InputDecoration(
                      labelText: 'Trip name',
                      prefixIcon: Icon(Icons.title),
                    ),
                    textInputAction: TextInputAction.next,
                    validator: _requiredValidator,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _countryController,
                    decoration: const InputDecoration(
                      labelText: 'Country',
                      prefixIcon: Icon(Icons.place_outlined),
                    ),
                    textInputAction: TextInputAction.next,
                  ),
                  const SizedBox(height: 12),
                  ResponsiveFieldRow(
                    children: [
                      DropdownButtonFormField<String>(
                        key: ValueKey('trip_$_selectedCurrency'),
                        initialValue: _selectedCurrency,
                        decoration: const InputDecoration(
                          labelText: 'Currency',
                          prefixIcon: Icon(Icons.payments_outlined),
                        ),
                        items: [
                          for (final currency in _supportedCurrencies)
                            DropdownMenuItem(
                              value: currency.code,
                              child: Text(currency.label),
                            ),
                        ],
                        onChanged: (value) {
                          if (value != null) {
                            _selectCurrency(value);
                          }
                        },
                      ),
                      TextFormField(
                        controller: _rateController,
                        decoration: InputDecoration(
                          labelText: 'Rate to MYR',
                          prefixIcon: _loadingRate
                              ? const Padding(
                                  padding: EdgeInsets.all(12),
                                  child: SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  ),
                                )
                              : const Icon(Icons.currency_exchange),
                        ),
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        validator: _positiveNumberValidator,
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  ResponsiveFieldRow(
                    children: [
                      DatePickButton(
                        label: 'Start',
                        value: _startDate,
                        onTap: () => _pickDate(isStart: true),
                      ),
                      DatePickButton(
                        label: 'End',
                        value: _endDate,
                        onTap: () => _pickDate(isStart: false),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}

class EventFormDialog extends StatefulWidget {
  const EventFormDialog({
    super.key,
    required this.trip,
    required this.mode,
    this.event,
  });

  final TravelTrip trip;
  final TravelEvent? event;
  final EventFormMode mode;

  @override
  State<EventFormDialog> createState() => _EventFormDialogState();
}

class _EventFormDialogState extends State<EventFormDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _titleController;
  late final TextEditingController _locationController;
  late final TextEditingController _durationController;
  late final TextEditingController _planController;
  late final TextEditingController _journalController;
  late final TextEditingController _feelingController;
  late final TextEditingController _expenseController;
  late final TextEditingController _splitController;
  late DateTime _date;
  late TimeOfDay _time;
  late TimeOfDay _endTime;
  late bool _isFlexible;
  var _expenseInputMode = ExpenseInputMode.total;
  late String _selectedExpenseCurrency;
  late Set<String> _selectedExpenseMemberIds;

  @override
  void initState() {
    super.initState();
    final event = widget.event;
    final startAt = event?.startAt ?? widget.trip.startDate ?? DateTime.now();
    _titleController = TextEditingController(text: event?.title ?? '');
    _locationController = TextEditingController(text: event?.location ?? '');
    _durationController = TextEditingController(
      text: (event?.durationMinutes ?? 60).toString(),
    );
    _planController = TextEditingController(text: event?.planNotes ?? '');
    _journalController = TextEditingController(text: event?.journal ?? '');
    _feelingController = TextEditingController(text: event?.feeling ?? '');
    _expenseController = TextEditingController(
      text: event == null || event.expenseAmount == 0
          ? ''
          : event.expenseAmount.toStringAsFixed(2),
    );
    _expenseController.addListener(_handleExpenseAmountChanged);
    _splitController = TextEditingController(
      text: (event?.splitCount ?? 1).toString(),
    );
    _date = DateTime(startAt.year, startAt.month, startAt.day);
    _time = TimeOfDay.fromDateTime(startAt);
    _endTime = TimeOfDay.fromDateTime(
      startAt.add(Duration(minutes: event?.durationMinutes ?? 60)),
    );
    _isFlexible = event?.isFlexible ?? false;
    _selectedExpenseCurrency = _currencyForCode(
      event?.expenseCurrencyCode ?? widget.trip.targetCurrency,
    ).code;
    _selectedExpenseMemberIds = {...?event?.expenseMemberIds};
  }

  @override
  void dispose() {
    _expenseController.removeListener(_handleExpenseAmountChanged);
    _titleController.dispose();
    _locationController.dispose();
    _durationController.dispose();
    _planController.dispose();
    _journalController.dispose();
    _feelingController.dispose();
    _expenseController.dispose();
    _splitController.dispose();
    super.dispose();
  }

  void _handleExpenseAmountChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _pickDate() async {
    final selected = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );

    if (selected == null || !mounted) {
      return;
    }

    setState(() => _date = selected);
  }

  Future<void> _pickTime() async {
    final selected = await showTimePicker(context: context, initialTime: _time);

    if (selected == null || !mounted) {
      return;
    }

    setState(() {
      _time = selected;
      if (!_isFlexible && _minutesBetween(_time, _endTime) <= 1) {
        _endTime = TimeOfDay(hour: (_time.hour + 1) % 24, minute: _time.minute);
      }
    });
  }

  Future<void> _pickEndTime() async {
    final selected = await showTimePicker(
      context: context,
      initialTime: _endTime,
    );

    if (selected == null || !mounted) {
      return;
    }

    setState(() => _endTime = selected);
  }

  void _save() {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    final enteredExpense = _expenseController.text.trim().isEmpty
        ? 0.0
        : double.parse(_expenseController.text.trim());
    final selectedSplit = _selectedExpenseMemberIds.length;
    final split = selectedSplit == 0
        ? int.tryParse(_splitController.text.trim()) ?? 1
        : selectedSplit;
    final expense = _expenseInputMode == ExpenseInputMode.perPerson
        ? enteredExpense * max(1, split)
        : enteredExpense;
    final duration = _isFlexible ? 0 : _minutesBetween(_time, _endTime);
    final startAt = DateTime(
      _date.year,
      _date.month,
      _date.day,
      _time.hour,
      _time.minute,
    );

    Navigator.of(context).pop(
      TravelEvent(
        id: widget.event?.id ?? _newId('event'),
        title: _titleController.text.trim(),
        location: _locationController.text.trim(),
        startAt: startAt,
        durationMinutes: duration,
        planNotes: _planController.text.trim(),
        journal: _journalController.text.trim(),
        feeling: _feelingController.text.trim(),
        expenseAmount: expense,
        expenseCurrencyCode: _selectedExpenseCurrency,
        splitCount: max(1, split),
        isFlexible: _isFlexible,
        attachments: widget.event?.attachments ?? const [],
        expenseMemberIds: _selectedExpenseMemberIds.toList(),
      ),
    );
  }

  String _convertedExpensePreview() {
    final amount = double.tryParse(_expenseController.text.trim()) ?? 0;
    if (amount <= 0) {
      return 'Enter an amount to preview conversion';
    }

    final fromCode = _currencyForCode(_selectedExpenseCurrency).code;
    final tripCurrency = _currencyForCode(widget.trip.targetCurrency).code;
    if (fromCode == 'MYR') {
      final converted = amount / max(widget.trip.exchangeRateToMyr, 0.000001);
      return 'Approx. ${_formatMoney(tripCurrency, converted)}';
    }

    final converted = amount * _rateToMyrForCurrency(widget.trip, fromCode);
    return 'Approx. ${_formatMoney('MYR', converted)}';
  }

  @override
  Widget build(BuildContext context) {
    final isPlanMode = widget.mode == EventFormMode.plan;
    final isExperienceMode = widget.mode == EventFormMode.experience;
    final isExpenseMode = widget.mode == EventFormMode.expense;
    final title = widget.event == null
        ? 'New event'
        : switch (widget.mode) {
            EventFormMode.plan => 'Plan details',
            EventFormMode.experience => 'Experience',
            EventFormMode.expense => 'Expense',
          };

    return AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: min(MediaQuery.sizeOf(context).width - 48, 640),
        child: Form(
          key: _formKey,
          child: AppScrollbar(
            builder: (controller) => SingleChildScrollView(
              controller: controller,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (isPlanMode) ...[
                    TextFormField(
                      controller: _titleController,
                      decoration: const InputDecoration(
                        labelText: 'Event title',
                        prefixIcon: Icon(Icons.event_outlined),
                      ),
                      textInputAction: TextInputAction.next,
                      validator: _requiredValidator,
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _locationController,
                      decoration: const InputDecoration(
                        labelText: 'Location',
                        prefixIcon: Icon(Icons.place_outlined),
                      ),
                      textInputAction: TextInputAction.next,
                    ),
                    const SizedBox(height: 12),
                    ResponsiveFieldRow(
                      children: [
                        DatePickButton(
                          label: 'Date',
                          value: _date,
                          onTap: _pickDate,
                        ),
                        OutlinedButton.icon(
                          onPressed: _pickTime,
                          icon: const Icon(Icons.schedule),
                          label: Text('From ${_time.format(context)}'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _isFlexible ? null : _pickEndTime,
                            icon: const Icon(Icons.timer_outlined),
                            label: Text(
                              _isFlexible
                                  ? 'End flexible'
                                  : 'To ${_endTime.format(context)}',
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    CheckboxListTile(
                      value: _isFlexible,
                      onChanged: (value) {
                        setState(() => _isFlexible = value ?? false);
                      },
                      title: const Text('Flexible timing'),
                      subtitle: const Text(
                        'End time is disabled when flexible',
                      ),
                      controlAffinity: ListTileControlAffinity.leading,
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _planController,
                      decoration: const InputDecoration(
                        labelText: 'Plan',
                        prefixIcon: Icon(Icons.subject_outlined),
                      ),
                      minLines: 3,
                      maxLines: 5,
                    ),
                  ],
                  if (isExperienceMode) ...[
                    TextFormField(
                      controller: _journalController,
                      decoration: const InputDecoration(
                        labelText: 'Experience',
                        prefixIcon: Icon(Icons.edit_note_outlined),
                      ),
                      minLines: 4,
                      maxLines: 7,
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _feelingController,
                      decoration: const InputDecoration(
                        labelText: 'Feeling',
                        prefixIcon: Icon(Icons.favorite_border),
                      ),
                      textInputAction: TextInputAction.next,
                    ),
                  ],
                  if (isExpenseMode) ...[
                    SegmentedButton<ExpenseInputMode>(
                      segments: const [
                        ButtonSegment(
                          value: ExpenseInputMode.total,
                          icon: Icon(Icons.payments_outlined),
                          label: Text('Total'),
                        ),
                        ButtonSegment(
                          value: ExpenseInputMode.perPerson,
                          icon: Icon(Icons.person_outline),
                          label: Text('Per pax'),
                        ),
                      ],
                      selected: {_expenseInputMode},
                      onSelectionChanged: (value) {
                        setState(() => _expenseInputMode = value.first);
                      },
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      initialValue: _selectedExpenseCurrency,
                      decoration: const InputDecoration(
                        labelText: 'Expense currency',
                        prefixIcon: Icon(Icons.payments_outlined),
                      ),
                      items: [
                        for (final currency in _supportedCurrencies)
                          DropdownMenuItem(
                            value: currency.code,
                            child: Text(currency.label),
                          ),
                      ],
                      onChanged: (value) {
                        if (value != null) {
                          setState(() => _selectedExpenseCurrency = value);
                        }
                      },
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _expenseController,
                      decoration: InputDecoration(
                        labelText:
                            '${_expenseInputMode == ExpenseInputMode.total ? 'Total' : 'Per pax'} $_selectedExpenseCurrency',
                        prefixIcon: const Icon(Icons.receipt_long_outlined),
                      ),
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      validator: _optionalPositiveNumberValidator,
                    ),
                    const SizedBox(height: 12),
                    InputDecorator(
                      decoration: InputDecoration(
                        labelText:
                            'Converted ${_expenseInputMode == ExpenseInputMode.perPerson ? 'per pax' : 'total'}',
                        prefixIcon: const Icon(Icons.currency_exchange),
                        border: const OutlineInputBorder(),
                      ),
                      child: Text(_convertedExpensePreview()),
                    ),
                    const SizedBox(height: 12),
                    if (widget.trip.members.isNotEmpty) ...[
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          'Split with',
                          style: Theme.of(context).textTheme.labelLarge,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final member in widget.trip.members)
                              FilterChip(
                                label: Text(member.name),
                                selected: _selectedExpenseMemberIds.contains(
                                  member.id,
                                ),
                                onSelected: (selected) {
                                  setState(() {
                                    if (selected) {
                                      _selectedExpenseMemberIds.add(member.id);
                                    } else {
                                      _selectedExpenseMemberIds.remove(
                                        member.id,
                                      );
                                    }
                                    _splitController.text = max(
                                      1,
                                      _selectedExpenseMemberIds.length,
                                    ).toString();
                                  });
                                },
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                    ],
                    TextFormField(
                      controller: _splitController,
                      decoration: const InputDecoration(
                        labelText: 'Split count',
                        prefixIcon: Icon(Icons.group_outlined),
                      ),
                      enabled: _selectedExpenseMemberIds.isEmpty,
                      keyboardType: TextInputType.number,
                      validator: _positiveIntegerValidator,
                    ),
                  ],
                  if (!isPlanMode && widget.event != null) ...[
                    const SizedBox(height: 12),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        widget.event!.title,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}

class DatePickButton extends StatelessWidget {
  const DatePickButton({
    super.key,
    required this.label,
    required this.value,
    required this.onTap,
  });

  final String label;
  final DateTime? value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: onTap,
      icon: const Icon(Icons.calendar_today_outlined),
      label: Text(
        value == null ? label : '$label ${_shortDayFormatter.format(value!)}',
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

class TripRepository {
  const TripRepository();

  static const _storageKey = 'traveler_trips_v1';

  Future<List<TravelTrip>> loadTrips() async {
    final preferences = await SharedPreferences.getInstance();
    final raw = preferences.getString(_storageKey);

    if (raw == null || raw.isEmpty) {
      return [];
    }

    final decoded = jsonDecode(raw);
    if (decoded is! List) {
      return [];
    }

    return decoded
        .whereType<Map<String, Object?>>()
        .map(TravelTrip.fromJson)
        .toList();
  }

  Future<void> saveTrips(List<TravelTrip> trips) async {
    final preferences = await SharedPreferences.getInstance();
    final encoded = jsonEncode(trips.map((trip) => trip.toJson()).toList());
    await preferences.setString(_storageKey, encoded);
  }
}

class TravelTrip {
  const TravelTrip({
    required this.id,
    required this.name,
    required this.country,
    required this.targetCurrency,
    required this.exchangeRateToMyr,
    required this.startDate,
    required this.endDate,
    required this.events,
    required this.attachments,
    required this.members,
  });

  factory TravelTrip.fromJson(Map<String, Object?> json) {
    final targetCurrency = json['targetCurrency'] as String? ?? 'CNY';

    return TravelTrip(
      id: json['id'] as String? ?? _newId('trip'),
      name: json['name'] as String? ?? 'Untitled trip',
      country: json['country'] as String? ?? '',
      targetCurrency: targetCurrency,
      exchangeRateToMyr:
          (json['exchangeRateToMyr'] as num?)?.toDouble() ??
          _currencyForCode(targetCurrency).fallbackRateToMyr,
      startDate: _parseOptionalDate(json['startDate']),
      endDate: _parseOptionalDate(json['endDate']),
      events: (json['events'] as List? ?? const [])
          .whereType<Map<String, Object?>>()
          .map(
            (event) => TravelEvent.fromJson(
              event,
              fallbackExpenseCurrencyCode: targetCurrency,
            ),
          )
          .toList(),
      attachments: (json['attachments'] as List? ?? const [])
          .whereType<Map<String, Object?>>()
          .map(TravelAttachment.fromJson)
          .toList(),
      members: (json['members'] as List? ?? const [])
          .whereType<Map<String, Object?>>()
          .map(TravelMember.fromJson)
          .toList(),
    );
  }

  final String id;
  final String name;
  final String country;
  final String targetCurrency;
  final double exchangeRateToMyr;
  final DateTime? startDate;
  final DateTime? endDate;
  final List<TravelEvent> events;
  final List<TravelAttachment> attachments;
  final List<TravelMember> members;

  List<TravelEvent> get sortedEvents {
    final sorted = [...events];
    sorted.sort((a, b) => a.startAt.compareTo(b.startAt));
    return sorted;
  }

  double get totalExpenseInTripCurrency {
    return events.fold<double>(
      0,
      (total, event) => total + _expenseAmountInTripCurrency(this, event),
    );
  }

  double get totalExpenseInMyr {
    return events.fold<double>(
      0,
      (total, event) => total + _expenseAmountInMyr(this, event),
    );
  }

  String get dateRangeLabel {
    if (startDate == null && endDate == null) {
      return 'No dates';
    }

    if (startDate != null && endDate != null) {
      return '${_shortDayFormatter.format(startDate!)} - ${_shortDayFormatter.format(endDate!)}';
    }

    return _shortDayFormatter.format(startDate ?? endDate!);
  }

  TravelTrip copyWith({
    String? name,
    String? country,
    String? targetCurrency,
    double? exchangeRateToMyr,
    DateTime? startDate,
    DateTime? endDate,
    List<TravelEvent>? events,
    List<TravelAttachment>? attachments,
    List<TravelMember>? members,
  }) {
    return TravelTrip(
      id: id,
      name: name ?? this.name,
      country: country ?? this.country,
      targetCurrency: targetCurrency ?? this.targetCurrency,
      exchangeRateToMyr: exchangeRateToMyr ?? this.exchangeRateToMyr,
      startDate: startDate ?? this.startDate,
      endDate: endDate ?? this.endDate,
      events: events ?? this.events,
      attachments: attachments ?? this.attachments,
      members: members ?? this.members,
    );
  }

  Map<String, Object?> toJson() {
    return {
      'id': id,
      'name': name,
      'country': country,
      'targetCurrency': targetCurrency,
      'exchangeRateToMyr': exchangeRateToMyr,
      'startDate': startDate?.toIso8601String(),
      'endDate': endDate?.toIso8601String(),
      'events': events.map((event) => event.toJson()).toList(),
      'attachments': attachments
          .map((attachment) => attachment.toJson())
          .toList(),
      'members': members.map((member) => member.toJson()).toList(),
    };
  }
}

class TravelMember {
  const TravelMember({required this.id, required this.name});

  factory TravelMember.fromJson(Map<String, Object?> json) {
    return TravelMember(
      id: json['id'] as String? ?? _newId('member'),
      name: json['name'] as String? ?? 'Member',
    );
  }

  final String id;
  final String name;

  Map<String, Object?> toJson() {
    return {'id': id, 'name': name};
  }
}

class TravelEvent {
  const TravelEvent({
    required this.id,
    required this.title,
    required this.location,
    required this.startAt,
    required this.durationMinutes,
    required this.planNotes,
    required this.journal,
    required this.feeling,
    required this.expenseAmount,
    required this.expenseCurrencyCode,
    required this.splitCount,
    required this.isFlexible,
    required this.attachments,
    required this.expenseMemberIds,
  });

  factory TravelEvent.fromJson(
    Map<String, Object?> json, {
    String fallbackExpenseCurrencyCode = 'CNY',
  }) {
    return TravelEvent(
      id: json['id'] as String? ?? _newId('event'),
      title: json['title'] as String? ?? 'Untitled event',
      location: json['location'] as String? ?? '',
      startAt:
          DateTime.tryParse(json['startAt'] as String? ?? '') ?? DateTime.now(),
      durationMinutes: (json['durationMinutes'] as num?)?.toInt() ?? 60,
      planNotes: json['planNotes'] as String? ?? '',
      journal: json['journal'] as String? ?? '',
      feeling: json['feeling'] as String? ?? '',
      expenseAmount: (json['expenseAmount'] as num?)?.toDouble() ?? 0,
      expenseCurrencyCode: _currencyForCode(
        json['expenseCurrencyCode'] as String? ?? fallbackExpenseCurrencyCode,
      ).code,
      splitCount: (json['splitCount'] as num?)?.toInt() ?? 1,
      isFlexible: json['isFlexible'] as bool? ?? false,
      attachments: (json['attachments'] as List? ?? const [])
          .whereType<Map<String, Object?>>()
          .map(TravelAttachment.fromJson)
          .toList(),
      expenseMemberIds: (json['expenseMemberIds'] as List? ?? const [])
          .whereType<String>()
          .toList(),
    );
  }

  final String id;
  final String title;
  final String location;
  final DateTime startAt;
  final int durationMinutes;
  final String planNotes;
  final String journal;
  final String feeling;
  final double expenseAmount;
  final String expenseCurrencyCode;
  final int splitCount;
  final bool isFlexible;
  final List<TravelAttachment> attachments;
  final List<String> expenseMemberIds;

  String get timeRangeLabel {
    final start = _timeFormatter.format(startAt);
    if (isFlexible) {
      return '$start - flexible';
    }

    final end = startAt.add(Duration(minutes: durationMinutes));
    return '$start - ${_timeFormatter.format(end)}';
  }

  TravelEvent copyWith({
    String? title,
    String? location,
    DateTime? startAt,
    int? durationMinutes,
    String? planNotes,
    String? journal,
    String? feeling,
    double? expenseAmount,
    String? expenseCurrencyCode,
    int? splitCount,
    bool? isFlexible,
    List<TravelAttachment>? attachments,
    List<String>? expenseMemberIds,
  }) {
    return TravelEvent(
      id: id,
      title: title ?? this.title,
      location: location ?? this.location,
      startAt: startAt ?? this.startAt,
      durationMinutes: durationMinutes ?? this.durationMinutes,
      planNotes: planNotes ?? this.planNotes,
      journal: journal ?? this.journal,
      feeling: feeling ?? this.feeling,
      expenseAmount: expenseAmount ?? this.expenseAmount,
      expenseCurrencyCode: expenseCurrencyCode ?? this.expenseCurrencyCode,
      splitCount: splitCount ?? this.splitCount,
      isFlexible: isFlexible ?? this.isFlexible,
      attachments: attachments ?? this.attachments,
      expenseMemberIds: expenseMemberIds ?? this.expenseMemberIds,
    );
  }

  Map<String, Object?> toJson() {
    return {
      'id': id,
      'title': title,
      'location': location,
      'startAt': startAt.toIso8601String(),
      'durationMinutes': durationMinutes,
      'planNotes': planNotes,
      'journal': journal,
      'feeling': feeling,
      'expenseAmount': expenseAmount,
      'expenseCurrencyCode': expenseCurrencyCode,
      'splitCount': splitCount,
      'isFlexible': isFlexible,
      'attachments': attachments
          .map((attachment) => attachment.toJson())
          .toList(),
      'expenseMemberIds': expenseMemberIds,
    };
  }
}

class TravelAttachment {
  const TravelAttachment({
    required this.id,
    required this.name,
    required this.path,
    required this.bytesBase64,
    required this.mimeType,
    required this.kind,
    required this.sizeBytes,
    required this.addedAt,
    required this.memberIds,
  });

  factory TravelAttachment.fromJson(Map<String, Object?> json) {
    return TravelAttachment(
      id: json['id'] as String? ?? _newId('file'),
      name: json['name'] as String? ?? 'Attachment',
      path: json['path'] as String?,
      bytesBase64: json['bytesBase64'] as String?,
      mimeType: json['mimeType'] as String?,
      kind: AttachmentKind.values.firstWhere(
        (kind) => kind.name == (json['kind'] as String? ?? 'file'),
        orElse: () => AttachmentKind.file,
      ),
      sizeBytes: (json['sizeBytes'] as num?)?.toInt() ?? 0,
      addedAt:
          DateTime.tryParse(json['addedAt'] as String? ?? '') ?? DateTime.now(),
      memberIds: (json['memberIds'] as List? ?? const [])
          .whereType<String>()
          .toList(),
    );
  }

  final String id;
  final String name;
  final String? path;
  final String? bytesBase64;
  final String? mimeType;
  final AttachmentKind kind;
  final int sizeBytes;
  final DateTime addedAt;
  final List<String> memberIds;

  TravelAttachment copyWith({List<String>? memberIds}) {
    return TravelAttachment(
      id: id,
      name: name,
      path: path,
      bytesBase64: bytesBase64,
      mimeType: mimeType,
      kind: kind,
      sizeBytes: sizeBytes,
      addedAt: addedAt,
      memberIds: memberIds ?? this.memberIds,
    );
  }

  Map<String, Object?> toJson() {
    return {
      'id': id,
      'name': name,
      'path': path,
      'bytesBase64': bytesBase64,
      'mimeType': mimeType,
      'kind': kind.name,
      'sizeBytes': sizeBytes,
      'addedAt': addedAt.toIso8601String(),
      'memberIds': memberIds,
    };
  }
}

DateTime? _parseOptionalDate(Object? value) {
  if (value is! String || value.isEmpty) {
    return null;
  }

  return DateTime.tryParse(value);
}

String? _requiredValidator(String? value) {
  if (value == null || value.trim().isEmpty) {
    return 'Required';
  }

  return null;
}

String? _positiveNumberValidator(String? value) {
  final parsed = double.tryParse(value?.trim() ?? '');
  if (parsed == null || parsed <= 0) {
    return 'Enter a positive number';
  }

  return null;
}

String? _optionalPositiveNumberValidator(String? value) {
  final text = value?.trim() ?? '';
  if (text.isEmpty) {
    return null;
  }

  return _positiveNumberValidator(text);
}

String? _positiveIntegerValidator(String? value) {
  final parsed = int.tryParse(value?.trim() ?? '');
  if (parsed == null || parsed <= 0) {
    return 'Enter a positive number';
  }

  return null;
}

String _formatBytes(int size) {
  if (size <= 0) {
    return 'Unknown size';
  }

  const units = ['B', 'KB', 'MB', 'GB'];
  var value = size.toDouble();
  var index = 0;

  while (value >= 1024 && index < units.length - 1) {
    value /= 1024;
    index++;
  }

  return '${_moneyFormatter.format(value)} ${units[index]}';
}
