import 'dart:async';
import 'dart:io';

import 'package:at_client/at_client.dart';
import 'package:at_onboarding_cli/at_onboarding_cli.dart';
import 'package:at_utils/at_logger.dart';

const namespace = 'medshare';
const rootDomain = 'root.atsign.org';
const patient = '@stellar7gf01_np';
const specialist = '@stellar7gf02_np';

String keysFor(String atSign) {
  final home =
      Platform.environment['USERPROFILE'] ?? Platform.environment['HOME']!;
  return [home, '.atsign', 'keys', '${atSign}_key.atKeys']
      .join(Platform.pathSeparator);
}

Future<void> withClient(
    String atSign, Future<void> Function(AtClient) body) async {
  AtSignLogger.root_level = 'warning';
  final preference = AtOnboardingPreference()
    ..namespace = namespace
    ..rootDomain = rootDomain
    ..atKeysFilePath = keysFor(atSign)
    ..hiveStoragePath = 'storage/$atSign/hive'
    ..commitLogPath = 'storage/$atSign/commitLog'
    ..isLocalStoreRequired = true;
  final onboarding = AtOnboardingServiceImpl(atSign, preference);
  await onboarding.authenticate();
  try {
    final client = onboarding.atClient!;
    await body(client);
    // put/delete write locally and sync to the server asynchronously.
    // Wait for the client->server push queue to drain before exiting,
    // or the recipient's network read won't see the change.
    await drainPush(client);
  } finally {
    await onboarding.close();
  }
}

Future<void> drainPush(AtClient client,
    {Duration timeout = const Duration(seconds: 30)}) async {
  final deadline = DateTime.now().add(timeout);
  while (true) {
    client.syncService.sync();
    if (await client.getLocalSecondary()!.syncQueueSize == 0) return;
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('push queue did not drain within $timeout');
    }
    await Future.delayed(const Duration(milliseconds: 400));
  }
}

// The patient->specialist grant. ttr enables caching at the recipient;
// ccd makes deletion cascade to that cached copy (the revocation mechanism).
AtKey scanKey() => AtKey()
  ..key = 'scanref'
  ..namespace = namespace
  ..sharedBy = patient
  ..sharedWith = specialist
  ..metadata = (Metadata()
    ..ttr = -1
    ..ccd = true);
