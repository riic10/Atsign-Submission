import 'dart:io';

import 'package:headless/medshare.dart';

Future<void> main() async {
  await withClient(patient, (client) async {
    final ok = await client.delete(scanKey());
    print('patient revoked "scanref" : delete=$ok');
  });
  print('Done.');
  exit(0);
}
