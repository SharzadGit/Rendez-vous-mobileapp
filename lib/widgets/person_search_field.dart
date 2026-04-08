import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../blocs/location/location_bloc.dart';
import '../blocs/location/location_event.dart';
import '../models/place_suggestion.dart';
import '../models/user_location.dart';
import '../repositories/geocoding_repository.dart';

class PersonSearchField extends StatefulWidget {
  final UserLocation user;
  final int index;

  const PersonSearchField({
    super.key,
    required this.user,
    required this.index,
  });

  @override
  State<PersonSearchField> createState() => _PersonSearchFieldState();
}

class _PersonSearchFieldState extends State<PersonSearchField> {
  final _controller = TextEditingController();
  final _geocoding = GeocodingRepository();
  final _focusNode = FocusNode();

  List<PlaceSuggestion> _suggestions = [];
  bool _loading = false;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    // Show existing address if set
    if (widget.user.address.isNotEmpty) {
      _controller.text = widget.user.address;
    }
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
    _controller.text = suggestion.shortName;
    _focusNode.unfocus();
    setState(() => _suggestions = []);
    context.read<LocationBloc>().add(
          UpdateUserAddress(
            widget.user.id,
            suggestion.position,
            suggestion.shortName,
          ),
        );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _controller,
          focusNode: _focusNode,
          onChanged: _onChanged,
          decoration: InputDecoration(
            hintText: 'Search location...',
            prefixIcon: Icon(
              Icons.person_pin_circle,
              color: widget.user.color,
            ),
            suffixIcon: _loading
                ? const Padding(
                    padding: EdgeInsets.all(12),
                    child: SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : _controller.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear, size: 18),
                        onPressed: () {
                          _controller.clear();
                          setState(() => _suggestions = []);
                        },
                      )
                    : null,
            isDense: true,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
            ),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 10,
            ),
          ),
        ),
        if (_suggestions.isNotEmpty)
          Container(
            margin: const EdgeInsets.only(top: 2),
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
                  title: Text(
                    s.shortName,
                    style: const TextStyle(fontSize: 13),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    s.displayName,
                    style: const TextStyle(fontSize: 11, color: Colors.grey),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onTap: () => _onSelect(s),
                );
              },
            ),
          ),
      ],
    );
  }
}