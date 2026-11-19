import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rendezvous_app/main.dart';
import 'package:rendezvous_app/widgets/persons_bottom_sheet.dart';

class _OfflineTiles extends TileProvider {
  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) =>
      MemoryImage(TileProvider.transparentImage);
}

void main() {
  testWidgets('Map opens the participant manager', (tester) async {
    await tester.pumpWidget(MyApp(tileProvider: _OfflineTiles()));
    expect(find.byType(FlutterMap), findsOneWidget);
    expect(find.byType(PersonsBottomSheet), findsNothing);
    await tester.tap(find.text('Add People'));
    await tester.pumpAndSettle();
    expect(find.byType(PersonsBottomSheet), findsOneWidget);
  });
}
