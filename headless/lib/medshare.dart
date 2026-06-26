import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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

// Where the per-atSign Hive store lives. The console tools default to a
// relative 'storage' dir; the Flutter app passes an absolute app-data path
// so it doesn't depend on the working directory.
String storageBase = 'storage';

Future<void> withClient(
    String atSign, Future<void> Function(AtClient) body) async {
  AtSignLogger.root_level = 'warning';
  final preference = AtOnboardingPreference()
    ..namespace = namespace
    ..rootDomain = rootDomain
    ..atKeysFilePath = keysFor(atSign)
    ..hiveStoragePath = '$storageBase/$atSign/hive'
    ..commitLogPath = '$storageBase/$atSign/commitLog'
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
// An optional ttl makes the grant auto-expire (the time-limited view).
AtKey scanKey({Duration? ttl}) => AtKey()
  ..key = 'scanref'
  ..namespace = namespace
  ..sharedBy = patient
  ..sharedWith = specialist
  ..metadata = (Metadata()
    ..ttr = -1
    ..ccd = true
    ..ttl = ttl?.inMilliseconds);

// ---- High-level operations used by both the console tools and the app. ----

// Patient shares the scan image with the specialist, optionally time-limited.
// The image bytes are carried inline as base64 in the shared key's value.
Future<void> patientShareImage(Uint8List bytes, {Duration? ttl}) async {
  await withClient(patient, (client) async {
    await client.put(scanKey(ttl: ttl), base64Encode(bytes));
  });
}

// What the specialist sees on a fetch: the image bytes plus the grant's
// expiry (if time-limited). A dark view has bytes == null.
class ScanView {
  final Uint8List? bytes;
  final DateTime? expiresAt;
  const ScanView(this.bytes, this.expiresAt);

  bool get isDark => bytes == null;
}

// Specialist reads the scan. Returns the image bytes while the grant is
// active, or a dark view once it has been revoked or has expired.
Future<ScanView> specialistReadImage() async {
  ScanView out = const ScanView(null, null);
  await withClient(specialist, (client) async {
    try {
      final result = await client.get(
        scanKey(),
        getRequestOptions: GetRequestOptions()..bypassCache = true,
      );
      final value = result.value;
      if (value is String && value.isNotEmpty) {
        out = ScanView(base64Decode(value), result.metadata?.expiresAt);
      }
    } on AtKeyNotFoundException {
      out = const ScanView(null, null);
    }
  });
  return out;
}

// Patient revokes the grant: deleting the shared key cascade-deletes the
// specialist's cached copy.
Future<void> patientRevoke() async {
  await withClient(patient, (client) async {
    await client.delete(scanKey());
  });
}
