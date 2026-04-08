import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../blocs/location/location_bloc.dart';
import '../blocs/location/location_event.dart';
import '../blocs/location/location_state.dart';
import '../blocs/optimization/optimization_bloc.dart';
import '../blocs/optimization/optimization_event.dart';
import '../blocs/optimization/optimization_state.dart';
import '../models/place_suggestion.dart';
import '../models/user_location.dart';
import '../repositories/geocoding_repository.dart';
import 'person_search_field.dart';

class PersonsBottomSheet extends StatefulWidget {
  const PersonsBottomSheet({super.key});

  @override
  State<PersonsBottomSheet> createState() => _PersonsBottomSheetState();
}

class _PersonsBottomSheetState extends State<PersonsBottomSheet> {
  // How many "pending" empty search cards are showing
  int _pendingCount = 0;
  final _sheetController = DraggableScrollableController();

  @override
  void dispose() {
    _sheetController.dispose();
    super.dispose();
  }

  void _addPending() {
    setState(() => _pendingCount++);
    // Expand sheet to near full so keyboard doesn't hide content
    Future.delayed(const Duration(milliseconds: 100), () {
      if (_sheetController.isAttached) {
        _sheetController.animateTo(
          0.92,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _removePending() => setState(() {
        if (_pendingCount > 0) _pendingCount--;
      });

  String _modeName(TravelMode mode) {
    switch (mode) {
      case TravelMode.driving:
        return 'Drive';
      case TravelMode.twoWheeler:
        return 'Two-Wheeler';
      case TravelMode.walking:
        return 'Walk';
    }
  }

  IconData _modeIcon(TravelMode mode) {
    switch (mode) {
      case TravelMode.driving:
        return Icons.directions_car;
      case TravelMode.twoWheeler:
        return Icons.two_wheeler;
      case TravelMode.walking:
        return Icons.directions_walk;
    }
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      controller: _sheetController,
      initialChildSize: 0.6,
      minChildSize: 0.4,
      maxChildSize: 0.92,
      expand: false,
      builder: (context, scrollController) {
        return Container(
          decoration: const BoxDecoration(
            color: Color(0xFFF5F5F5),
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: Column(
            children: [
              // Drag handle
              Container(
                margin: const EdgeInsets.only(top: 12, bottom: 8),
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey.shade400,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),

              // Header
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                child: Row(
                  children: [
                    const Text(
                      'People',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const Spacer(),
                    BlocBuilder<LocationBloc, LocationState>(
                      builder: (context, state) {
                        if (state.users.isEmpty && _pendingCount == 0) {
                          return const SizedBox.shrink();
                        }
                        return TextButton.icon(
                          onPressed: () {
                            context
                                .read<LocationBloc>()
                                .add(ClearAllLocations());
                            setState(() => _pendingCount = 0);
                          },
                          icon: const Icon(Icons.clear_all,
                              size: 16, color: Colors.red),
                          label: const Text('Clear all',
                              style: TextStyle(color: Colors.red)),
                        );
                      },
                    ),
                  ],
                ),
              ),

              const Divider(height: 1),

              // Person list
              Expanded(
                child: BlocBuilder<LocationBloc, LocationState>(
                  builder: (context, state) {
                    final totalItems =
                        state.users.length + _pendingCount;

                    return ListView(
                      controller: scrollController,
                      padding: const EdgeInsets.all(16),
                      children: [
                        if (totalItems == 0)
                          const Padding(
                            padding: EdgeInsets.symmetric(vertical: 24),
                            child: Center(
                              child: Text(
                                'No people added yet.\nTap "+ Add Person" to start.',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                    color: Colors.grey, fontSize: 14),
                              ),
                            ),
                          ),

                        // Confirmed person cards
                        ...state.users.asMap().entries.map((entry) {
                          final index = entry.key;
                          final user = entry.value;
                          return _ConfirmedPersonCard(
                            user: user,
                            index: index,
                            modeIcon: _modeIcon,
                            modeName: _modeName,
                          );
                        }),

                        // Pending search cards
                        ...List.generate(_pendingCount, (i) {
                          final pendingIndex =
                              state.users.length + i;
                          return _PendingPersonCard(
                            index: pendingIndex,
                            onLocationSelected: () => _removePending(),
                            onCancel: _removePending,
                          );
                        }),

                        const SizedBox(height: 12),

                        // Primary: Add Person button
                        FilledButton.icon(
                          onPressed: _addPending,
                          icon: const Icon(Icons.person_add, size: 18),
                          label: const Text('Add Person'),
                          style: FilledButton.styleFrom(
                            backgroundColor: Colors.deepPurple.shade50,
                            foregroundColor: Colors.deepPurple,
                            minimumSize: const Size.fromHeight(44),
                            elevation: 0,
                          ),
                        ),

                        const SizedBox(height: 8),

                        // Secondary: tap map
                        OutlinedButton.icon(
                          onPressed: () {
                            Navigator.pop(context);
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text(
                                    'Tap the map to drop a pin'),
                                duration: Duration(seconds: 2),
                              ),
                            );
                          },
                          icon: const Icon(Icons.add_location_alt,
                              size: 18),
                          label: const Text('Drop pin on map'),
                          style: OutlinedButton.styleFrom(
                            minimumSize: const Size.fromHeight(44),
                          ),
                        ),

                        const SizedBox(height: 24),
                      ],
                    );
                  },
                ),
              ),

              // Find meeting point button
              BlocBuilder<LocationBloc, LocationState>(
                builder: (context, locState) {
                  return BlocBuilder<OptimizationBloc, OptimizationState>(
                    builder: (context, optState) {
                      final canRun = locState.users.length >= 2;
                      final isRunning = optState is OptimizationRunning;

                      return Padding(
                        padding: EdgeInsets.fromLTRB(
                            16,
                            8,
                            16,
                            MediaQuery.of(context).padding.bottom + 16),
                        child: FilledButton.icon(
                          onPressed: canRun && !isRunning
                              ? () {
                                  Navigator.pop(context);
                                  context.read<OptimizationBloc>().add(
                                      RunOptimization(locState.users));
                                }
                              : null,
                          icon: isRunning
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    color: Colors.white,
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.search),
                          label: Text(
                            isRunning
                                ? 'Optimizing...'
                                : canRun
                                    ? 'Find Meeting Point'
                                    : 'Add at least 2 people',
                          ),
                          style: FilledButton.styleFrom(
                            backgroundColor: Colors.deepPurple,
                            minimumSize: const Size.fromHeight(50),
                          ),
                        ),
                      );
                    },
                  );
                },
              ),
            ],
          ),
        );
      },
    );
  }
}

// ── CONFIRMED PERSON CARD ────────────────────────────────────────────────────

class _ConfirmedPersonCard extends StatelessWidget {
  final UserLocation user;
  final int index;
  final IconData Function(TravelMode) modeIcon;
  final String Function(TravelMode) modeName;

  const _ConfirmedPersonCard({
    required this.user,
    required this.index,
    required this.modeIcon,
    required this.modeName,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.circle, color: user.color, size: 12),
                const SizedBox(width: 8),
                Text(
                  'Person ${index + 1}',
                  style: const TextStyle(
                      fontWeight: FontWeight.w600, fontSize: 14),
                ),
                const Spacer(),
                DropdownButton<TravelMode>(
                  value: user.travelMode,
                  underline: const SizedBox.shrink(),
                  isDense: true,
                  style: const TextStyle(
                      fontSize: 12, color: Colors.black87),
                  items: TravelMode.values.map((mode) {
                    return DropdownMenuItem(
                      value: mode,
                      child: Row(children: [
                        Icon(modeIcon(mode), size: 14),
                        const SizedBox(width: 4),
                        Text(modeName(mode)),
                      ]),
                    );
                  }).toList(),
                  onChanged: (mode) {
                    if (mode != null) {
                      context
                          .read<LocationBloc>()
                          .add(UpdateTravelMode(user.id, mode));
                    }
                  },
                ),
                const SizedBox(width: 4),
                IconButton(
                  icon: const Icon(Icons.close,
                      size: 18, color: Colors.red),
                  onPressed: () => context
                      .read<LocationBloc>()
                      .add(RemoveUserLocation(user.id)),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
              ],
            ),
            const SizedBox(height: 10),
            PersonSearchField(user: user, index: index),
            if (user.address.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  'Pinned: '
                  '${user.position.latitude.toStringAsFixed(4)}, '
                  '${user.position.longitude.toStringAsFixed(4)}',
                  style:
                      const TextStyle(fontSize: 11, color: Colors.grey),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ── PENDING PERSON CARD ──────────────────────────────────────────────────────

class _PendingPersonCard extends StatefulWidget {
  final int index;
  final VoidCallback onLocationSelected;
  final VoidCallback onCancel;

  const _PendingPersonCard({
    required this.index,
    required this.onLocationSelected,
    required this.onCancel,
  });

  @override
  State<_PendingPersonCard> createState() => _PendingPersonCardState();
}

class _PendingPersonCardState extends State<_PendingPersonCard> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  final _geocoding = GeocodingRepository();
  List<PlaceSuggestion> _suggestions = [];
  bool _loading = false;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    // Auto-focus when card appears
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    if (value.length < 3) {
      setState(() => _suggestions = []);
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 400), () async {
      setState(() => _loading = true);
      final results = await _geocoding.search(value);
      if (mounted) {
        setState(() {
          _suggestions = results;
          _loading = false;
        });
      }
    });
  }

  void _onSelect(PlaceSuggestion suggestion) {
    _focusNode.unfocus();
    // Add to BLoC
    context.read<LocationBloc>().add(
          AddUserLocation(
            suggestion.position,
            address: suggestion.shortName,
          ),
        );
    // Remove this pending card
    widget.onLocationSelected();
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.deepPurple.shade200, width: 1.5),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.circle,
                    color: Colors.grey.shade400, size: 12),
                const SizedBox(width: 8),
                Text(
                  'Person ${widget.index + 1}',
                  style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                      color: Colors.grey),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.close,
                      size: 18, color: Colors.red),
                  onPressed: widget.onCancel,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
              ],
            ),
            const SizedBox(height: 10),

            // Suggestions dropdown — above the field so keyboard doesn't hide them
            if (_suggestions.isNotEmpty)
              Container(
                margin: const EdgeInsets.only(bottom: 8), // Added bottom margin for spacing
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(8),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.1),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: ListView.separated(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: _suggestions.length,
                  separatorBuilder: (_, __) =>
                      const Divider(height: 1, indent: 16),
                  itemBuilder: (context, i) {
                    final s = _suggestions[i];
                    return ListTile(
                      dense: true,
                      leading: const Icon(Icons.location_on,
                          size: 18, color: Colors.deepPurple),
                      title: Text(s.shortName,
                          style: const TextStyle(fontSize: 13),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                      subtitle: Text(s.displayName,
                          style: const TextStyle(
                              fontSize: 11, color: Colors.grey),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                      onTap: () => _onSelect(s),
                    );
                  },
                ),
              ),

            // Search field
            TextField(
              controller: _controller,
              focusNode: _focusNode,
              onChanged: _onChanged,
              decoration: InputDecoration(
                hintText: 'Search location (e.g. RNSIT, Koramangala)...',
                prefixIcon: const Icon(Icons.search,
                    color: Colors.deepPurple),
                suffixIcon: _loading
                    ? const Padding(
                        padding: EdgeInsets.all(12),
                        child: SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                              strokeWidth: 2),
                        ),
                      )
                    : _controller.text.isNotEmpty
                        ? IconButton(
                            icon:
                                const Icon(Icons.clear, size: 18),
                            onPressed: () {
                              _controller.clear();
                              setState(() => _suggestions = []);
                            },
                          )
                        : null,
                isDense: true,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(
                      color: Colors.deepPurple.shade300),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(
                      color: Colors.deepPurple, width: 2),
                ),
                contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 10),
              ),
            ),
          ],
        ),
      ),
    );
  }
}