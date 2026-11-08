import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:rendezvous_app/models/user_location.dart';
import 'package:rendezvous_app/repositories/routing_repository.dart';

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
