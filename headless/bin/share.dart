import 'dart:io';

import 'package:headless/medshare.dart';

Future<void> main() async {
  await withClient(patient, (client) async {
    final ok = await client.put(scanKey(), 'scan-blob-v1');
    print('patient shared "scanref" with $specialist : put=$ok');
  });
  print('Done.');
  exit(0);
}
