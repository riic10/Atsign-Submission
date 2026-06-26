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

// The recipient the patient shares with. Mutable so the app can target a
// different atSign at runtime. Note: the specialist pane must authenticate as
// this atSign to read, so its .atKeys must exist locally — otherwise the read
// fails and the view stays dark.
String specialist = '@stellar7gf02_np';

// Point sharing at a different specialist. Drops any open specialist session
// so the next read re-authenticates under the new identity.
Future<void> setSpecialist(String atSign) async {
  final trimmed = atSign.trim();
  final normalized = trimmed.startsWith('@') ? trimmed : '@$trimmed';
  if (normalized == specialist) return;
  await closeSpecialist();
  specialist = normalized;
}

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

AtOnboardingPreference _preferenceFor(String atSign) => AtOnboardingPreference()
  ..namespace = namespace
  ..rootDomain = rootDomain
  ..atKeysFilePath = keysFor(atSign)
  ..hiveStoragePath = '$storageBase/$atSign/hive'
  ..commitLogPath = '$storageBase/$atSign/commitLog'
  ..isLocalStoreRequired = true;

Future<void> withClient(
    String atSign, Future<void> Function(AtClient) body) async {
  AtSignLogger.root_level = 'warning';
  final onboarding = AtOnboardingServiceImpl(atSign, _preferenceFor(atSign));
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
    await Future<void>.delayed(const Duration(milliseconds: 400));
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

// A long-lived specialist session. Polling re-reads through this one
// authenticated client instead of re-onboarding on every fetch.
AtOnboardingService? _specialistSession;

Future<AtClient> _specialistClient() async {
  var session = _specialistSession;
  if (session == null) {
    AtSignLogger.root_level = 'warning';
    session = AtOnboardingServiceImpl(specialist, _preferenceFor(specialist));
    await session.authenticate();
    _specialistSession = session;
  }
  return session.atClient!;
}

// Closes the specialist session (call when the reader is done polling).
Future<void> closeSpecialist() async {
  await _specialistSession?.close();
  _specialistSession = null;
}

// Specialist reads the scan. Returns the image bytes while the grant is
// active, or a dark view for any failure: revoked/expired key, a value that
// isn't decodable, or a transient network error. The reader's contract is
// simply "can I see the scan right now or not", so every failure is dark.
Future<ScanView> specialistReadImage() async {
  try {
    final client = await _specialistClient();
    final result = await client.get(
      scanKey(),
      getRequestOptions: GetRequestOptions()..bypassCache = true,
    );
    final value = result.value;
    if (value is String && value.isNotEmpty) {
      return ScanView(base64Decode(value), result.metadata?.expiresAt);
    }
  } catch (_) {
    // Fall through to a dark view.
  }
  return const ScanView(null, null);
}

// Patient revokes the grant: deleting the shared key cascade-deletes the
// specialist's cached copy.
Future<void> patientRevoke() async {
  await withClient(patient, (client) async {
    await client.delete(scanKey());
  });
}
