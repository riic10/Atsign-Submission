import 'package:flutter_test/flutter_test.dart';

import 'package:medshare_app/main.dart';

void main() {
  testWidgets('patient pane and role toggle render', (tester) async {
    await tester.pumpWidget(const MedShareApp());
    // Single frame only: the specialist pane runs a 1Hz countdown ticker and
    // network polling, so pumpAndSettle would never settle.
    await tester.pump();

    // Defaults to the patient pane with its share controls.
    expect(find.text('Share with specialist'), findsOneWidget);
    expect(find.text('Revoke'), findsOneWidget);

    // Both roles are offered by the toggle.
    expect(find.text('Patient'), findsOneWidget);
    expect(find.text('Specialist'), findsOneWidget);
  });
}
