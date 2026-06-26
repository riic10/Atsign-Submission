import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:medshare_app/main.dart';

void main() {
  testWidgets('patient pane and role toggle render', (tester) async {
    // The app runs in a tall desktop window; size the test surface to match
    // so the phone panel lays out as it does at runtime.
    tester.view.physicalSize = const Size(880, 1840);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const MedShareApp());
    // Single frame only: the specialist pane runs a 1Hz countdown ticker and
    // network polling, so pumpAndSettle would never settle.
    await tester.pump();

    // Defaults to the patient pane in its idle state.
    expect(find.text('Grant specialist access'), findsOneWidget);
    expect(find.text('Not shared with anyone'), findsOneWidget);

    // Both roles are offered by the toggle.
    expect(find.text('Patient'), findsOneWidget);
    expect(find.text('Specialist'), findsOneWidget);
  });
}
