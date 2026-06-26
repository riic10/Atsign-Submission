import 'dart:io';

import 'package:at_client/at_client.dart';
import 'package:headless/medshare.dart';

Future<void> main() async {
  await withClient(specialist, (client) async {
    try {
      final result = await client.get(
        scanKey(),
        getRequestOptions: GetRequestOptions()..bypassCache = true,
      );
      print('specialist read "scanref" : "${result.value}"');
    } catch (e) {
      print('specialist read is DARK (no access): ${e.runtimeType}');
    }
  });
  print('Done.');
  exit(0);
}
