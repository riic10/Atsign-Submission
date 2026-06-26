import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:at_client/at_client.dart';
import 'package:at_onboarding_cli/at_onboarding_cli.dart';
import 'package:at_utils/at_logger.dart';
import 'package:crypto/crypto.dart';

const namespace = 'medshare';
const rootDomain = 'root.atsign.org';

// The three atSigns in the chain. These default to the demo identities but are
// mutable so each user can point the app at their own onboarded atSigns. Each
// atSign's .atKeys must be present locally for the app to authenticate as it.
String clinic = '@radium1if01_np';
String patient = '@stellar7gf01_np';
String specialist = '@stellar7gf02_np';

String _normalize(String atSign) {
  final t = atSign.trim();
  return t.startsWith('@') ? t : '@$t';
}

// Apply a user-supplied set of atSigns (e.g. from the setup screen).
Future<void> configure({
  required String clinicAt,
  required String patientAt,
  required String specialistAt,
}) async {
  clinic = _normalize(clinicAt);
  patient = _normalize(patientAt);
  await setSpecialist(specialistAt);
}

// True if an atSign has its .atKeys file onboarded locally.
bool hasKeys(String atSign) {
  final s = atSign.trim();
  if (s.isEmpty) return false;
  return File(keysFor(_normalize(s))).existsSync();
}

// Point sharing at a different specialist. Drops any open specialist session
// so the next read re-authenticates under the new identity.
Future<void> setSpecialist(String atSign) async {
  final normalized = _normalize(atSign);
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

// The clinic->patient delivery. ttr caches it at the patient so they hold the
// scan and can re-share it onward. This is the design's "hand over the scan"
// edge, made real.
AtKey deliveryKey() => AtKey()
  ..key = 'scan'
  ..namespace = namespace
  ..sharedBy = clinic
  ..sharedWith = patient
  ..metadata = (Metadata()..ttr = -1);

// ---- High-level operations used by both the console tools and the app. ----

// Clinic locks the scan to the patient and delivers it.
Future<void> clinicDeliverScan(Uint8List bytes) async {
  await withClient(clinic, (client) async {
    await client.put(deliveryKey(), base64Encode(bytes));
  });
}

// Patient receives the scan the clinic delivered, or null if none yet.
Future<Uint8List?> patientReceiveScan() async {
  Uint8List? out;
  await withClient(patient, (client) async {
    try {
      final result = await client.get(
        deliveryKey(),
        getRequestOptions: GetRequestOptions()..bypassCache = true,
      );
      final value = result.value;
      if (value is String && value.isNotEmpty) out = base64Decode(value);
    } catch (_) {
      out = null;
    }
  });
  return out;
}

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

// ---- Audit log (design's Audit Log node) ----
//
// A tamper-evident, append-only record of every grant, view, and withdrawal.
// Each entry is chained to the previous one's hash, so any edit or deletion
// breaks the chain (verify() detects it). Single-writer for the demo, but each
// entry is stamped with the identity of whoever caused the event.
class AuditEntry {
  final int seq;
  final DateTime time;
  final String actor; // atSign that caused the event
  final String action;
  final String detail;
  final String prevHash;
  final String hash;
  const AuditEntry(this.seq, this.time, this.actor, this.action, this.detail,
      this.prevHash, this.hash);
}

class AuditLog {
  final List<AuditEntry> entries = [];

  String _hashOf(int seq, DateTime time, String actor, String action,
      String detail, String prev) {
    final payload =
        '$seq|${time.toIso8601String()}|$actor|$action|$detail|$prev';
    return sha256.convert(utf8.encode(payload)).toString();
  }

  AuditEntry append(String actor, String action, [String detail = '']) {
    final seq = entries.length;
    final time = DateTime.now();
    final prev = entries.isEmpty ? 'GENESIS' : entries.last.hash;
    final hash = _hashOf(seq, time, actor, action, detail, prev);
    final entry = AuditEntry(seq, time, actor, action, detail, prev, hash);
    entries.add(entry);
    return entry;
  }

  // Recompute the whole chain; any altered or removed entry breaks it.
  bool verify() {
    var prev = 'GENESIS';
    for (final e in entries) {
      if (e.prevHash != prev) return false;
      if (_hashOf(e.seq, e.time, e.actor, e.action, e.detail, prev) != e.hash) {
        return false;
      }
      prev = e.hash;
    }
    return true;
  }
}
