import 'dart:io';

import 'package:at_client/at_client.dart';
import 'package:headless/medshare.dart';

Future<void> main() async {
  await withClient(patient, (client) async {
    final ok = await client.put(scanKey(), 'scan-blob-v1');
    print('[patient] put=$ok');
  });

  await withClient(patient, (client) async {
    final inSync = await client.syncService.isInSync();
    print('[patient] isInSync=$inSync');
    final keys = await client.getAtKeys(regex: 'scanref');
    print('[patient] keys matching scanref: $keys');
  });

  await withClient(specialist, (client) async {
    final keys = await client.getAtKeys(regex: 'scanref');
    print('[specialist] keys matching scanref: $keys');
    try {
      final v = await client.get(scanKey(),
          getRequestOptions: GetRequestOptions()..bypassCache = true);
      print('[specialist] bypass get = "${v.value}"');
    } catch (e) {
      print('[specialist] bypass get FAILED: ${e.runtimeType} $e');
    }
    try {
      final v2 = await client.get(scanKey());
      print('[specialist] local  get = "${v2.value}"');
    } catch (e) {
      print('[specialist] local  get FAILED: ${e.runtimeType} $e');
    }
  });

  exit(0);
}
