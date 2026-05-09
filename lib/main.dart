import 'dart:convert';
import 'dart:math';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

void main() {
  runApp(const TravelerApp());
}

final _idRandom = Random();
final _dayFormatter = DateFormat('EEE, d MMM yyyy');
final _shortDayFormatter = DateFormat('d MMM');
final _timeFormatter = DateFormat('HH:mm');
final _moneyFormatter = NumberFormat('#,##0.00');

String _newId(String prefix) {
  final timestamp = DateTime.now().microsecondsSinceEpoch;
  final suffix = _idRandom.nextInt(999999).toString().padLeft(6, '0');
  return '${prefix}_${timestamp}_$suffix';
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
        appBarTheme: const AppBarTheme(centerTitle: false),
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
    for (final trip in _trips) {
      if (trip.id == _selectedTripId) {
        return trip;
      }
    }
    return _trips.isEmpty ? null : _trips.first;
  }

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
      _trips = trips;
      _selectedTripId = trips.isEmpty ? null : trips.first.id;
      _loading = false;
    });
  }

  Future<void> _persistTrips(List<TravelTrip> trips) async {
    setState(() {
      _trips = trips;
      if (_trips.isEmpty) {
        _selectedTripId = null;
      } else if (!_trips.any((trip) => trip.id == _selectedTripId)) {
        _selectedTripId = _trips.first.id;
      }
    });

    await widget.repository.saveTrips(trips);
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

  Future<void> _showEventDialog(TravelTrip trip, {TravelEvent? event}) async {
    final savedEvent = await showDialog<TravelEvent>(
      context: context,
      builder: (context) => EventFormDialog(trip: trip, event: event),
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

  Future<void> _deleteEvent(TravelTrip trip, TravelEvent event) async {
    await _upsertTrip(
      trip.copyWith(
        events: trip.events
            .where((candidate) => candidate.id != event.id)
            .toList(),
      ),
    );
  }

  Future<void> _pickAttachment(TravelTrip trip) async {
    final result = await FilePicker.pickFiles(
      dialogTitle: 'Attach travel file',
      allowMultiple: false,
      withData: false,
    );

    if (result == null || result.files.isEmpty) {
      return;
    }

    final file = result.files.single;
    final attachment = TravelAttachment(
      id: _newId('file'),
      name: file.name,
      path: file.path,
      sizeBytes: file.size,
      addedAt: DateTime.now(),
    );

    await _upsertTrip(
      trip.copyWith(attachments: [...trip.attachments, attachment]),
    );
  }

  Future<void> _removeAttachment(
    TravelTrip trip,
    TravelAttachment attachment,
  ) async {
    await _upsertTrip(
      trip.copyWith(
        attachments: trip.attachments
            .where((candidate) => candidate.id != attachment.id)
            .toList(),
      ),
    );
  }

  Future<void> _openAttachment(TravelAttachment attachment) async {
    final path = attachment.path;
    if (path == null || path.isEmpty) {
      _showSnack('This file has no local path to open.');
      return;
    }

    final launched = await launchUrl(
      Uri.file(path),
      mode: LaunchMode.externalApplication,
    );

    if (!mounted) {
      return;
    }

    if (!launched) {
      _showSnack('Could not open ${attachment.name}.');
    }
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

    final selectedTrip = _selectedTrip;
    final isWide = MediaQuery.sizeOf(context).width >= 920;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Traveler'),
        actions: [
          IconButton(
            tooltip: 'New trip',
            onPressed: () => _showTripDialog(),
            icon: const Icon(Icons.add_location_alt_outlined),
          ),
        ],
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
                      onCreate: () => _showTripDialog(),
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
                            onDeleteTrip: () => _deleteTrip(selectedTrip),
                            onAddEvent: () => _showEventDialog(selectedTrip),
                            onEditEvent: (event) =>
                                _showEventDialog(selectedTrip, event: event),
                            onDeleteEvent: (event) =>
                                _deleteEvent(selectedTrip, event),
                            onTripChanged: _upsertTrip,
                            onAddAttachment: () {
                              _pickAttachment(selectedTrip);
                            },
                            onOpenAttachment: _openAttachment,
                            onRemoveAttachment: (attachment) {
                              _removeAttachment(selectedTrip, attachment);
                            },
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
                onCreate: () => _showTripDialog(),
              )
            : TripDetailView(
                trip: selectedTrip,
                compact: true,
                onBack: () => setState(() => _selectedTripId = null),
                onEditTrip: () => _showTripDialog(trip: selectedTrip),
                onDeleteTrip: () => _deleteTrip(selectedTrip),
                onAddEvent: () => _showEventDialog(selectedTrip),
                onEditEvent: (event) =>
                    _showEventDialog(selectedTrip, event: event),
                onDeleteEvent: (event) => _deleteEvent(selectedTrip, event),
                onTripChanged: _upsertTrip,
                onAddAttachment: () => _pickAttachment(selectedTrip),
                onOpenAttachment: _openAttachment,
                onRemoveAttachment: (attachment) {
                  _removeAttachment(selectedTrip, attachment);
                },
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

class TripListPane extends StatelessWidget {
  const TripListPane({
    super.key,
    required this.trips,
    required this.selectedTripId,
    required this.onSelect,
    required this.onCreate,
  });

  final List<TravelTrip> trips;
  final String? selectedTripId;
  final ValueChanged<TravelTrip> onSelect;
  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Trips',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              IconButton.filledTonal(
                tooltip: 'New trip',
                onPressed: onCreate,
                icon: const Icon(Icons.add),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
            itemCount: trips.length,
            separatorBuilder: (context, index) => const SizedBox(height: 8),
            itemBuilder: (context, index) {
              final trip = trips[index];
              final selected = trip.id == selectedTripId;

              return Card(
                color: selected
                    ? Theme.of(context).colorScheme.primaryContainer
                    : Theme.of(context).colorScheme.surface,
                child: ListTile(
                  selected: selected,
                  onTap: () => onSelect(trip),
                  leading: CircleAvatar(
                    backgroundColor: selected
                        ? Theme.of(context).colorScheme.primary
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
                      if (trip.country.isNotEmpty) trip.country,
                      trip.targetCurrency,
                      '${trip.events.length} events',
                    ].join(' • '),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: const Icon(Icons.chevron_right),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class TripDetailView extends StatelessWidget {
  const TripDetailView({
    super.key,
    required this.trip,
    required this.onEditTrip,
    required this.onDeleteTrip,
    required this.onAddEvent,
    required this.onEditEvent,
    required this.onDeleteEvent,
    required this.onTripChanged,
    required this.onAddAttachment,
    required this.onOpenAttachment,
    required this.onRemoveAttachment,
    this.compact = false,
    this.onBack,
  });

  final TravelTrip trip;
  final bool compact;
  final VoidCallback? onBack;
  final VoidCallback onEditTrip;
  final VoidCallback onDeleteTrip;
  final VoidCallback onAddEvent;
  final ValueChanged<TravelEvent> onEditEvent;
  final ValueChanged<TravelEvent> onDeleteEvent;
  final ValueChanged<TravelTrip> onTripChanged;
  final VoidCallback onAddAttachment;
  final ValueChanged<TravelAttachment> onOpenAttachment;
  final ValueChanged<TravelAttachment> onRemoveAttachment;

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 4,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TripHeader(
            trip: trip,
            compact: compact,
            onBack: onBack,
            onEdit: onEditTrip,
            onDelete: onDeleteTrip,
          ),
          const TabBar(
            tabs: [
              Tab(icon: Icon(Icons.route_outlined), text: 'Plan'),
              Tab(icon: Icon(Icons.edit_note_outlined), text: 'Journal'),
              Tab(icon: Icon(Icons.currency_exchange), text: 'Currency'),
              Tab(icon: Icon(Icons.folder_open_outlined), text: 'Files'),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [
                PlanTab(
                  trip: trip,
                  onAddEvent: onAddEvent,
                  onEditEvent: onEditEvent,
                  onDeleteEvent: onDeleteEvent,
                ),
                JournalTab(trip: trip, onEditEvent: onEditEvent),
                CurrencyTab(trip: trip, onTripChanged: onTripChanged),
                FilesTab(
                  trip: trip,
                  onAddAttachment: onAddAttachment,
                  onOpenAttachment: onOpenAttachment,
                  onRemoveAttachment: onRemoveAttachment,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class TripHeader extends StatelessWidget {
  const TripHeader({
    super.key,
    required this.trip,
    required this.compact,
    required this.onEdit,
    required this.onDelete,
    this.onBack,
  });

  final TravelTrip trip;
  final bool compact;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback? onBack;

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
          if (compact)
            IconButton(
              tooltip: 'Trips',
              onPressed: onBack,
              icon: const Icon(Icons.arrow_back),
            )
          else
            const SizedBox(width: 8),
          Expanded(
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
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    TripMetaChip(
                      icon: Icons.place_outlined,
                      label: trip.country.isEmpty ? 'No country' : trip.country,
                    ),
                    TripMetaChip(
                      icon: Icons.calendar_today_outlined,
                      label: range,
                    ),
                    TripMetaChip(
                      icon: Icons.payments_outlined,
                      label: '${trip.targetCurrency} to MYR',
                    ),
                  ],
                ),
              ],
            ),
          ),
          PopupMenuButton<String>(
            tooltip: 'Trip actions',
            onSelected: (value) {
              if (value == 'edit') {
                onEdit();
              } else if (value == 'delete') {
                onDelete();
              }
            },
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: 'edit',
                child: ListTile(
                  leading: Icon(Icons.edit_outlined),
                  title: Text('Edit trip'),
                ),
              ),
              PopupMenuItem(
                value: 'delete',
                child: ListTile(
                  leading: Icon(Icons.delete_outline),
                  title: Text('Delete trip'),
                ),
              ),
            ],
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
    required this.onDeleteEvent,
  });

  final TravelTrip trip;
  final VoidCallback onAddEvent;
  final ValueChanged<TravelEvent> onEditEvent;
  final ValueChanged<TravelEvent> onDeleteEvent;

  @override
  Widget build(BuildContext context) {
    final events = trip.sortedEvents;

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
          ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 88),
            itemCount: events.length,
            itemBuilder: (context, index) {
              final event = events[index];
              return TimelineEventCard(
                trip: trip,
                event: event,
                isFirst: index == 0,
                isLast: index == events.length - 1,
                onEdit: () => onEditEvent(event),
                onDelete: () => onDeleteEvent(event),
              );
            },
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

class TimelineEventCard extends StatelessWidget {
  const TimelineEventCard({
    super.key,
    required this.trip,
    required this.event,
    required this.isFirst,
    required this.isLast,
    required this.onEdit,
    required this.onDelete,
  });

  final TravelTrip trip;
  final TravelEvent event;
  final bool isFirst;
  final bool isLast;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

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
                              Text(
                                event.title,
                                style: theme.textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                '${_dayFormatter.format(event.startAt)} • ${event.durationMinutes} min',
                                style: theme.textTheme.bodySmall,
                              ),
                            ],
                          ),
                        ),
                        PopupMenuButton<String>(
                          tooltip: 'Event actions',
                          onSelected: (value) {
                            if (value == 'edit') {
                              onEdit();
                            } else if (value == 'delete') {
                              onDelete();
                            }
                          },
                          itemBuilder: (context) => const [
                            PopupMenuItem(
                              value: 'edit',
                              child: ListTile(
                                leading: Icon(Icons.edit_outlined),
                                title: Text('Edit'),
                              ),
                            ),
                            PopupMenuItem(
                              value: 'delete',
                              child: ListTile(
                                leading: Icon(Icons.delete_outline),
                                title: Text('Delete'),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                    if (event.location.isNotEmpty) ...[
                      const SizedBox(height: 8),
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
                              '${trip.targetCurrency} ${_moneyFormatter.format(event.expenseAmount)}',
                            ),
                            visualDensity: VisualDensity.compact,
                          ),
                        if (event.feeling.isNotEmpty)
                          Chip(
                            avatar: const Icon(Icons.favorite_border, size: 18),
                            label: Text(event.feeling),
                            visualDensity: VisualDensity.compact,
                          ),
                      ],
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

class JournalTab extends StatelessWidget {
  const JournalTab({super.key, required this.trip, required this.onEditEvent});

  final TravelTrip trip;
  final ValueChanged<TravelEvent> onEditEvent;

  @override
  Widget build(BuildContext context) {
    final events = trip.sortedEvents;

    if (events.isEmpty) {
      return const EmptyTabView(
        icon: Icons.edit_note_outlined,
        title: 'No entries yet',
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      children: [
        ExpenseSummaryCard(trip: trip),
        const SizedBox(height: 12),
        for (final event in events)
          JournalEventCard(
            trip: trip,
            event: event,
            onTap: () => onEditEvent(event),
          ),
      ],
    );
  }
}

class ExpenseSummaryCard extends StatelessWidget {
  const ExpenseSummaryCard({super.key, required this.trip});

  final TravelTrip trip;

  @override
  Widget build(BuildContext context) {
    final totalTarget = trip.totalExpense;
    final totalMyr = totalTarget * trip.exchangeRateToMyr;

    return Card(
      color: const Color(0xFFFFF4E8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            const Icon(Icons.account_balance_wallet_outlined),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Expenses',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${trip.targetCurrency} ${_moneyFormatter.format(totalTarget)}',
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
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
    final perPerson = event.splitCount <= 1
        ? event.expenseAmount
        : event.expenseAmount / event.splitCount;

    return Card(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      event.title,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Text(_shortDayFormatter.format(event.startAt)),
                ],
              ),
              if (event.journal.isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(event.journal),
              ],
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  if (event.feeling.isNotEmpty)
                    Chip(
                      avatar: const Icon(Icons.favorite_border, size: 18),
                      label: Text(event.feeling),
                      visualDensity: VisualDensity.compact,
                    ),
                  if (event.expenseAmount > 0)
                    Chip(
                      avatar: const Icon(Icons.payments_outlined, size: 18),
                      label: Text(
                        '${trip.targetCurrency} ${_moneyFormatter.format(event.expenseAmount)}',
                      ),
                      visualDensity: VisualDensity.compact,
                    ),
                  if (event.splitCount > 1)
                    Chip(
                      avatar: const Icon(Icons.group_outlined, size: 18),
                      label: Text(
                        '${trip.targetCurrency} ${_moneyFormatter.format(perPerson)} each',
                      ),
                      visualDensity: VisualDensity.compact,
                    ),
                ],
              ),
            ],
          ),
        ),
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
  var _fromTarget = true;

  @override
  void initState() {
    super.initState();
    _amountController = TextEditingController(text: '100');
    _rateController = TextEditingController(
      text: widget.trip.exchangeRateToMyr.toStringAsFixed(4),
    );
  }

  @override
  void didUpdateWidget(covariant CurrencyTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.trip.id != widget.trip.id ||
        oldWidget.trip.exchangeRateToMyr != widget.trip.exchangeRateToMyr) {
      _rateController.text = widget.trip.exchangeRateToMyr.toStringAsFixed(4);
    }
  }

  @override
  void dispose() {
    _amountController.dispose();
    _rateController.dispose();
    super.dispose();
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
    final fromCode = _fromTarget ? widget.trip.targetCurrency : 'MYR';
    final toCode = _fromTarget ? 'MYR' : widget.trip.targetCurrency;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
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
                SegmentedButton<bool>(
                  segments: [
                    ButtonSegment(
                      value: true,
                      icon: const Icon(Icons.arrow_forward),
                      label: Text('${widget.trip.targetCurrency} to MYR'),
                    ),
                    ButtonSegment(
                      value: false,
                      icon: const Icon(Icons.arrow_back),
                      label: Text('MYR to ${widget.trip.targetCurrency}'),
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
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _rateController,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: InputDecoration(
                    labelText: '1 ${widget.trip.targetCurrency} in MYR',
                    prefixIcon: const Icon(Icons.tune_outlined),
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: () {
                    final parsed = double.tryParse(_rateController.text.trim());
                    if (parsed == null || parsed <= 0) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Enter a valid rate.')),
                      );
                      return;
                    }

                    widget.onTripChanged(
                      widget.trip.copyWith(exchangeRateToMyr: parsed),
                    );
                  },
                  icon: const Icon(Icons.save_outlined),
                  label: const Text('Save rate'),
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
    );
  }
}

class FilesTab extends StatelessWidget {
  const FilesTab({
    super.key,
    required this.trip,
    required this.onAddAttachment,
    required this.onOpenAttachment,
    required this.onRemoveAttachment,
  });

  final TravelTrip trip;
  final VoidCallback onAddAttachment;
  final ValueChanged<TravelAttachment> onOpenAttachment;
  final ValueChanged<TravelAttachment> onRemoveAttachment;

  @override
  Widget build(BuildContext context) {
    if (trip.attachments.isEmpty) {
      return EmptyTabView(
        icon: Icons.folder_open_outlined,
        title: 'No files yet',
        actionLabel: 'Attach file',
        onAction: onAddAttachment,
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      itemCount: trip.attachments.length + 1,
      separatorBuilder: (context, index) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        if (index == 0) {
          return Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
              onPressed: onAddAttachment,
              icon: const Icon(Icons.attach_file),
              label: const Text('Attach file'),
            ),
          );
        }

        final attachment = trip.attachments[index - 1];
        return Card(
          child: ListTile(
            leading: const Icon(Icons.insert_drive_file_outlined),
            title: Text(
              attachment.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              [
                _formatBytes(attachment.sizeBytes),
                _shortDayFormatter.format(attachment.addedAt),
              ].join(' • '),
            ),
            onTap: () => onOpenAttachment(attachment),
            trailing: IconButton(
              tooltip: 'Remove file',
              onPressed: () => onRemoveAttachment(attachment),
              icon: const Icon(Icons.delete_outline),
            ),
          ),
        );
      },
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
  late final TextEditingController _currencyController;
  late final TextEditingController _rateController;
  DateTime? _startDate;
  DateTime? _endDate;

  @override
  void initState() {
    super.initState();
    final trip = widget.trip;
    _nameController = TextEditingController(text: trip?.name ?? '');
    _countryController = TextEditingController(text: trip?.country ?? '');
    _currencyController = TextEditingController(
      text: trip?.targetCurrency ?? 'CNY',
    );
    _rateController = TextEditingController(
      text: (trip?.exchangeRateToMyr ?? 0.66).toStringAsFixed(4),
    );
    _startDate = trip?.startDate;
    _endDate = trip?.endDate;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _countryController.dispose();
    _currencyController.dispose();
    _rateController.dispose();
    super.dispose();
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
      targetCurrency: _currencyController.text.trim().toUpperCase(),
      exchangeRateToMyr: double.parse(_rateController.text.trim()),
      startDate: _startDate,
      endDate: _endDate,
      events: existing?.events ?? const [],
      attachments: existing?.attachments ?? const [],
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
          child: SingleChildScrollView(
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
                Row(
                  children: [
                    Expanded(
                      child: TextFormField(
                        controller: _currencyController,
                        decoration: const InputDecoration(
                          labelText: 'Currency',
                          prefixIcon: Icon(Icons.payments_outlined),
                        ),
                        textCapitalization: TextCapitalization.characters,
                        validator: _requiredValidator,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextFormField(
                        controller: _rateController,
                        decoration: const InputDecoration(
                          labelText: 'Rate to MYR',
                          prefixIcon: Icon(Icons.currency_exchange),
                        ),
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        validator: _positiveNumberValidator,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: DatePickButton(
                        label: 'Start',
                        value: _startDate,
                        onTap: () => _pickDate(isStart: true),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: DatePickButton(
                        label: 'End',
                        value: _endDate,
                        onTap: () => _pickDate(isStart: false),
                      ),
                    ),
                  ],
                ),
              ],
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
  const EventFormDialog({super.key, required this.trip, this.event});

  final TravelTrip trip;
  final TravelEvent? event;

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
  late bool _isFlexible;

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
    _splitController = TextEditingController(
      text: (event?.splitCount ?? 1).toString(),
    );
    _date = DateTime(startAt.year, startAt.month, startAt.day);
    _time = TimeOfDay.fromDateTime(startAt);
    _isFlexible = event?.isFlexible ?? false;
  }

  @override
  void dispose() {
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

    setState(() => _time = selected);
  }

  void _save() {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    final expense = _expenseController.text.trim().isEmpty
        ? 0.0
        : double.parse(_expenseController.text.trim());
    final split = int.tryParse(_splitController.text.trim()) ?? 1;
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
        durationMinutes: int.parse(_durationController.text.trim()),
        planNotes: _planController.text.trim(),
        journal: _journalController.text.trim(),
        feeling: _feelingController.text.trim(),
        expenseAmount: expense,
        splitCount: max(1, split),
        isFlexible: _isFlexible,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.event == null ? 'New event' : 'Edit event'),
      content: SizedBox(
        width: min(MediaQuery.sizeOf(context).width - 48, 640),
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
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
                Row(
                  children: [
                    Expanded(
                      child: DatePickButton(
                        label: 'Date',
                        value: _date,
                        onTap: _pickDate,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _pickTime,
                        icon: const Icon(Icons.schedule),
                        label: Text(_time.format(context)),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _durationController,
                  decoration: const InputDecoration(
                    labelText: 'Duration minutes',
                    prefixIcon: Icon(Icons.timer_outlined),
                  ),
                  keyboardType: TextInputType.number,
                  validator: _positiveIntegerValidator,
                ),
                const SizedBox(height: 12),
                CheckboxListTile(
                  value: _isFlexible,
                  onChanged: (value) {
                    setState(() => _isFlexible = value ?? false);
                  },
                  title: const Text('Flexible timing'),
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
                const SizedBox(height: 12),
                TextFormField(
                  controller: _journalController,
                  decoration: const InputDecoration(
                    labelText: 'Experience',
                    prefixIcon: Icon(Icons.edit_note_outlined),
                  ),
                  minLines: 3,
                  maxLines: 5,
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
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextFormField(
                        controller: _expenseController,
                        decoration: InputDecoration(
                          labelText: 'Expense ${widget.trip.targetCurrency}',
                          prefixIcon: const Icon(Icons.receipt_long_outlined),
                        ),
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        validator: _optionalPositiveNumberValidator,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextFormField(
                        controller: _splitController,
                        decoration: const InputDecoration(
                          labelText: 'Split count',
                          prefixIcon: Icon(Icons.group_outlined),
                        ),
                        keyboardType: TextInputType.number,
                        validator: _positiveIntegerValidator,
                      ),
                    ),
                  ],
                ),
              ],
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
  });

  factory TravelTrip.fromJson(Map<String, Object?> json) {
    return TravelTrip(
      id: json['id'] as String? ?? _newId('trip'),
      name: json['name'] as String? ?? 'Untitled trip',
      country: json['country'] as String? ?? '',
      targetCurrency: json['targetCurrency'] as String? ?? 'CNY',
      exchangeRateToMyr:
          (json['exchangeRateToMyr'] as num?)?.toDouble() ?? 0.66,
      startDate: _parseOptionalDate(json['startDate']),
      endDate: _parseOptionalDate(json['endDate']),
      events: (json['events'] as List? ?? const [])
          .whereType<Map<String, Object?>>()
          .map(TravelEvent.fromJson)
          .toList(),
      attachments: (json['attachments'] as List? ?? const [])
          .whereType<Map<String, Object?>>()
          .map(TravelAttachment.fromJson)
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

  List<TravelEvent> get sortedEvents {
    final sorted = [...events];
    sorted.sort((a, b) => a.startAt.compareTo(b.startAt));
    return sorted;
  }

  double get totalExpense {
    return events.fold<double>(
      0,
      (total, event) => total + event.expenseAmount,
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
    };
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
    required this.splitCount,
    required this.isFlexible,
  });

  factory TravelEvent.fromJson(Map<String, Object?> json) {
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
      splitCount: (json['splitCount'] as num?)?.toInt() ?? 1,
      isFlexible: json['isFlexible'] as bool? ?? false,
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
  final int splitCount;
  final bool isFlexible;

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
      'splitCount': splitCount,
      'isFlexible': isFlexible,
    };
  }
}

class TravelAttachment {
  const TravelAttachment({
    required this.id,
    required this.name,
    required this.path,
    required this.sizeBytes,
    required this.addedAt,
  });

  factory TravelAttachment.fromJson(Map<String, Object?> json) {
    return TravelAttachment(
      id: json['id'] as String? ?? _newId('file'),
      name: json['name'] as String? ?? 'Attachment',
      path: json['path'] as String?,
      sizeBytes: (json['sizeBytes'] as num?)?.toInt() ?? 0,
      addedAt:
          DateTime.tryParse(json['addedAt'] as String? ?? '') ?? DateTime.now(),
    );
  }

  final String id;
  final String name;
  final String? path;
  final int sizeBytes;
  final DateTime addedAt;

  Map<String, Object?> toJson() {
    return {
      'id': id,
      'name': name,
      'path': path,
      'sizeBytes': sizeBytes,
      'addedAt': addedAt.toIso8601String(),
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
