import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:rendezvous_app/models/user_location.dart';
import 'package:rendezvous_app/blocs/location/location_bloc.dart';
import 'package:rendezvous_app/blocs/location/location_event.dart';
import 'package:rendezvous_app/repositories/routing_repository.dart';
import 'package:rendezvous_app/services/weiszfeld_service.dart';
import 'package:rendezvous_app/services/isochrone_service.dart';

void main() {
  const candidate = LatLng(12, 77);
  const alice = UserLocation(
    id: 'alice',
    position: LatLng(13, 78),
    color: Colors.red,
    travelMode: TravelMode.driving,
  );
  const bob = UserLocation(
    id: 'bob',
    position: LatLng(14, 79),
    color: Colors.blue,
    travelMode: TravelMode.driving,
  );

  // Sources are rows; destinations are columns: [meeting, alice, bob].
  // In particular, alice -> meeting is 101, but meeting -> alice is 901.
  const matrix = [
    [0, 901, 902],
    [101, 0, 303],
    [202.5, 404, 0],
  ];

  for (final users in [
    [alice, bob],
    [bob, alice],
  ]) {
    test(
      'returns origin-to-meeting seconds in order ${users.map((u) => u.id)}',
      () async {
        final client = MockClient((request) async {
          expect(request.method, 'POST');
          expect(
            request.url.toString(),
            'https://api.openrouteservice.org/v2/matrix/driving-car',
          );
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          final locations = body['locations'] as List;
          expect(locations, [
            [77.0, 12.0],
            for (final user in users)
              [user.position.longitude, user.position.latitude],
          ]);
          expect(body['metrics'], ['duration']);
          // With no subsets, ORS returns the full matrix in location order.
          expect(body.containsKey('sources'), isFalse);
          expect(body.containsKey('destinations'), isFalse);
          final indices = [
            0,
            for (final user in users) user.id == 'alice' ? 1 : 2,
          ];
          return http.Response(
            jsonEncode({
              'durations': [
                for (final source in indices)
                  [
                    for (final destination in indices)
                      matrix[source][destination],
                  ],
              ],
            }),
            200,
          );
        });
        addTearDown(client.close);

        final times = await RoutingRepository(
          client: client,
        ).getTravelTimes(users: users, candidate: candidate);

        expect(times, [
          for (final user in users) user.id == 'alice' ? 101.0 : 202.5,
        ]);
      },
    );
  }

  test('preserves unreachable-origin fallback and participant order', () async {
    final client = MockClient(
      (_) async => http.Response(
        jsonEncode({
          'durations': [
            [0, 901, 902],
            [null, 0, 303],
            [202.5, 404, 0],
          ],
        }),
        200,
      ),
    );
    addTearDown(client.close);

    expect(
      await RoutingRepository(
        client: client,
      ).getTravelTimes(users: [alice, bob], candidate: candidate),
      [999999.0, 202.5],
    );
  });

  test(
    'location state preserves selected modes without changing prior inputs',
    () async {
      final bloc = LocationBloc();
      addTearDown(bloc.close);
      final added = bloc.stream.first;
      bloc.add(const AddUserLocation(LatLng(13, 78)));
      final initial = await added;
      expect(initial.users.single.travelMode, TravelMode.driving);
      for (final mode in [
        TravelMode.cycling,
        TravelMode.walking,
        TravelMode.driving,
      ]) {
        final updated = bloc.stream.first;
        bloc.add(UpdateTravelMode(initial.users.single.id, mode));
        expect((await updated).users.single.travelMode, mode);
      }
      expect(initial.users.single.travelMode, TravelMode.driving);
    },
  );

  test(
    'research modes have explicit ORS profiles; motorcycle is unsupported',
    () {
      expect(TravelMode.supported, [
        TravelMode.driving,
        TravelMode.cycling,
        TravelMode.walking,
      ]);
      expect(TravelMode.driving.orsProfile, 'driving-car');
      expect(TravelMode.cycling.orsProfile, 'cycling-regular');
      expect(TravelMode.walking.orsProfile, 'foot-walking');
      expect(() => TravelMode.twoWheeler.orsProfile, throwsUnsupportedError);
    },
  );

  for (final entry in {
    TravelMode.driving: 'driving-car',
    TravelMode.cycling: 'cycling-regular',
    TravelMode.walking: 'foot-walking',
  }.entries) {
    test('requests ${entry.value} from participant to meeting', () async {
      var requests = 0;
      final client = MockClient((request) async {
        requests++;
        expect(request.url.path, '/v2/matrix/${entry.value}');
        expect(jsonDecode(request.body)['locations'], [
          [77, 12],
          [78, 13],
        ]);
        return http.Response(
          jsonEncode({
            'durations': [
              [0, 901],
              [101, 0],
            ],
          }),
          200,
        );
      });
      addTearDown(client.close);
      expect(
        await RoutingRepository(client: client).getTravelTimes(
          users: [alice.copyWith(travelMode: entry.key)],
          candidate: candidate,
        ),
        [101.0],
      );
      expect(requests, 1);
    });
  }

  test('rejects legacy motorcycle mode before any network request', () async {
    final client = MockClient((_) async {
      fail('Unsupported modes must be validated before any HTTP request');
    });
    addTearDown(client.close);
    await expectLater(
      RoutingRepository(client: client).getTravelTimes(
        users: [
          alice,
          bob.copyWith(travelMode: TravelMode.twoWheeler),
        ],
        candidate: candidate,
      ),
      throwsUnsupportedError,
    );
  });

  final mixedUsers = [
    alice.copyWith(travelMode: TravelMode.walking),
    bob.copyWith(travelMode: TravelMode.cycling),
    alice.copyWith(position: const LatLng(15, 80)),
    bob.copyWith(
      position: const LatLng(16, 81),
      travelMode: TravelMode.walking,
    ),
  ];

  test(
    'groups mixed profiles and restores interleaved participant order',
    () async {
      final paths = <String>[];
      final client = mixedModeClient(paths);
      addTearDown(client.close);
      expect(
        await RoutingRepository(
          client: client,
        ).getTravelTimes(users: mixedUsers, candidate: candidate),
        [101.0, 202.0, 303.0, 404.0],
      );
      expect(paths, ['foot-walking', 'cycling-regular', 'driving-car']);
    },
  );

  for (final method in ['Weiszfeld', 'Isochrone']) {
    testWidgets('$method uses the same profiles at every evaluation', (
      tester,
    ) async {
      final paths = <String>[];
      final client = mixedModeClient(paths);
      addTearDown(client.close);
      final repo = RoutingRepository(client: client);
      final future = method == 'Weiszfeld'
          ? WeiszfeldService(repo).optimize(users: mixedUsers)
          : IsochroneService(repo).optimize(users: mixedUsers);
      var completed = false;
      future.then((_) => completed = true);
      // Advance the services' existing throttling delays without real waiting.
      for (var i = 0; i < 100 && !completed; i++) {
        await tester.pump(const Duration(seconds: 1));
      }
      expect(completed, isTrue);
      final result = await future;
      expect(result.travelTimes, [101.0, 202.0, 303.0, 404.0]);
      expect(paths.length, greaterThan(3));
      expect(paths.length % 3, 0);
      for (var i = 0; i < paths.length; i += 3) {
        expect(paths.sublist(i, i + 3), [
          'foot-walking',
          'cycling-regular',
          'driving-car',
        ]);
      }
    });
  }

  test('empty participants do not make a request', () async {
    final client = MockClient((_) async {
      fail('No matrix request should be made');
    });
    addTearDown(client.close);

    expect(
      await RoutingRepository(
        client: client,
      ).getTravelTimes(users: [], candidate: candidate),
      isEmpty,
    );
  });

  test('preserves API error reporting', () async {
    final client = MockClient((_) async => http.Response('unavailable', 503));
    addTearDown(client.close);

    await expectLater(
      RoutingRepository(
        client: client,
      ).getTravelTimes(users: [alice], candidate: candidate),
      throwsA(
        isA<Exception>().having(
          (error) => error.toString(),
          'message',
          contains('ORS API error 503: unavailable'),
        ),
      ),
    );
  });
}

// Model ORS's asymmetric full matrix for each profile group. Rows are sources;
// column zero is the meeting destination. Reverse times are deliberately 900.
MockClient mixedModeClient(List<String> paths) {
  const profiles = {
    78: 'foot-walking',
    79: 'cycling-regular',
    80: 'driving-car',
    81: 'foot-walking',
  };
  const seconds = {78: 101, 79: 202, 80: 303, 81: 404};
  return MockClient((request) async {
    expectSync(request.method, 'POST');
    final profile = request.url.pathSegments.last;
    paths.add(profile);
    final body = jsonDecode(request.body) as Map<String, dynamic>;
    expectSync(body['metrics'], ['duration']);
    final locations = body['locations'] as List;
    final origins = locations
        .skip(1)
        .map((p) => (p[0] as num).toInt())
        .toList();
    expectSync(
      origins,
      profiles.entries
          .where((e) => e.value == profile)
          .map((e) => e.key)
          .toList(),
    );
    return http.Response(
      jsonEncode({
        'durations': [
          [0, for (final _ in origins) 900],
          for (final origin in origins)
            [seconds[origin], for (final _ in origins) 0],
        ],
      }),
      200,
    );
  });
}
