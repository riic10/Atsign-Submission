import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:headless/medshare.dart' as medshare;
import 'package:path_provider/path_provider.dart';

// --- ScanShare dark theme tokens ---
const _bg = Color(0xFF070D10); // app background
const _panel = Color(0xFF0C1418); // phone panel
const _surface = Color(0xFF15232B); // cards
const _ink = Color(0xFFEEF3F5); // primary text
const _muted = Color(0xFF8A9AA2); // secondary text
const _line = Color(0xFF223039); // borders
const _brand = Color(0xFF16A6B3);
const _good = Color(0xFF2BB37C);
const _goodBg = Color(0x1F2BB37C);
const _goodInk = Color(0xFF6FD3A6);
const _danger = Color(0xFFE0694F);
const _darkBg = Color(0xFF0C1418); // scan area / dark card

File? _configFile;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Point the atSign Hive stores at a stable app-data location instead of
  // the process working directory.
  final dir = await getApplicationSupportDirectory();
  final sep = Platform.pathSeparator;
  medshare.storageBase = '${dir.path}${sep}storage';
  _configFile = File('${dir.path}${sep}config.json');
  final configured = await _loadConfig();
  runApp(MedShareApp(configured: configured));
}

// Reads saved atSigns and applies them. Returns true if a config was loaded.
Future<bool> _loadConfig() async {
  try {
    if (!await _configFile!.exists()) return false;
    final json = jsonDecode(await _configFile!.readAsString());
    await medshare.configure(
      clinicAt: json['clinic'] as String,
      patientAt: json['patient'] as String,
      specialistAt: json['specialist'] as String,
    );
    return true;
  } catch (_) {
    return false;
  }
}

Future<void> _saveConfig() async {
  await _configFile!.writeAsString(jsonEncode({
    'clinic': medshare.clinic,
    'patient': medshare.patient,
    'specialist': medshare.specialist,
  }));
}

class MedShareApp extends StatelessWidget {
  final bool configured;
  const MedShareApp({super.key, required this.configured});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ScanShare',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: _bg,
        colorScheme: ColorScheme.fromSeed(
          seedColor: _brand,
          brightness: Brightness.dark,
        ),
      ),
      home: Gate(initiallyConfigured: configured),
    );
  }
}

// Shows the setup screen until atSigns are configured, then the app. The gear
// in the app header returns here to reconfigure.
class Gate extends StatefulWidget {
  final bool initiallyConfigured;
  const Gate({super.key, required this.initiallyConfigured});

  @override
  State<Gate> createState() => _GateState();
}

class _GateState extends State<Gate> {
  late bool _configured = widget.initiallyConfigured;

  @override
  Widget build(BuildContext context) {
    if (!_configured) {
      return SetupScreen(onSaved: () => setState(() => _configured = true));
    }
    return HomePage(
      key: ValueKey(medshare.clinic + medshare.patient + medshare.specialist),
      onSettings: () => setState(() => _configured = false),
    );
  }
}

enum Role { clinic, patient, specialist, audit }

enum _RefStatus { active, revoked, expired, pending }

// A sample referral shown alongside the real, live grant so the specialist's
// inbox reads like a working caseload rather than a single patient.
class _Referral {
  final String name, handle, scan, note;
  final _RefStatus status;
  final Color color;
  const _Referral(
      this.name, this.handle, this.scan, this.note, this.status, this.color);
}

const _mockReferrals = <_Referral>[
  _Referral('Hailey Fu', 'haileyfu', 'Knee MRI', 'Expired 2h ago',
      _RefStatus.expired, Color(0xFF6E8BFF)),
  _Referral('Michelle Ho', 'michelleho', 'Dental panoramic',
      'Awaiting the patient’s grant', _RefStatus.pending, Color(0xFFE89A5B)),
  _Referral('Rainie Fu', 'rainiefu', 'Chest CT', 'Revoked yesterday',
      _RefStatus.revoked, Color(0xFFB58BFF)),
];

class HomePage extends StatefulWidget {
  final VoidCallback onSettings;
  const HomePage({super.key, required this.onSettings});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  static const _pollInterval = Duration(seconds: 3);

  Role _role = Role.clinic;
  bool _busy = false;

  final _audit = medshare.AuditLog();

  // Clinic state.
  bool _clinicDelivered = false;

  // Patient state: the scan received from the clinic, plus whether it's
  // currently shared onward and when that grant ends.
  Uint8List? _patientScan;
  bool _receiving = false; // guards overlapping clinic-delivery reads
  bool _patientShared = false;
  DateTime? _grantExpiry;

  // Specialist state.
  medshare.ScanView? _view;
  bool _hasFetched = false;
  bool _everLit = false; // has the live grant ever rendered (revoked vs awaiting)
  bool _fetching = false; // guards overlapping network reads
  Timer? _pollTimer; // re-fetches the scan on an interval
  Timer? _ticker; // 1Hz repaint so the countdown ticks down

  String get _specialistHandle => medshare.specialist.replaceFirst('@', '');
  String get _patientHandle => medshare.patient.replaceFirst('@', '');
  String get _clinicHandle => medshare.clinic.replaceFirst('@', '');

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      final exp = _grantExpiry;
      if (exp == null) return; // nothing counting down
      if (DateTime.now().isAfter(exp)) {
        // Grant has run out: the patient view falls back to idle. The
        // specialist view goes dark via the poll's real read failing.
        setState(() {
          _grantExpiry = null;
          _patientShared = false;
          _audit.append(
              medshare.patient, 'Grant expired', 'for @$_specialistHandle');
        });
      } else {
        setState(() {});
      }
    });
    _syncPolling();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _ticker?.cancel();
    medshare.closeSpecialist();
    super.dispose();
  }

  // Each pane polls its upstream: the specialist re-reads the patient's grant;
  // the patient waits for the clinic's delivery (only until it arrives).
  void _syncPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
    if (_role == Role.specialist) {
      _pollTimer = Timer.periodic(_pollInterval, (_) => _fetchView());
      _fetchView();
    } else if (_role == Role.patient && _patientScan == null) {
      _pollTimer = Timer.periodic(_pollInterval, (_) => _receiveScan());
      _receiveScan();
    }
  }

  void _setRole(Role r) {
    setState(() => _role = r);
    _syncPolling();
  }

  // Clinic locks the scan and delivers it to the patient.
  Future<void> _deliver() async {
    setState(() => _busy = true);
    try {
      final data = await rootBundle.load('assets/scan.jpg');
      await medshare.clinicDeliverScan(data.buffer.asUint8List());
      if (!mounted) return;
      setState(() {
        _clinicDelivered = true;
        _audit.append(medshare.clinic, 'Delivered locked scan',
            'to @$_patientHandle');
      });
    } catch (e) {
      _toast('Could not deliver: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // Patient picks up the scan the clinic delivered. Polls until it arrives.
  Future<void> _receiveScan() async {
    if (_patientScan != null || _busy || _receiving) return;
    _receiving = true;
    try {
      final bytes = await medshare.patientReceiveScan();
      if (!mounted || bytes == null) return;
      setState(() => _patientScan = bytes);
      _pollTimer?.cancel(); // got it; stop waiting
      _pollTimer = null;
    } finally {
      _receiving = false;
    }
  }

  Future<void> _grant(Duration ttl, String specialistHandle) async {
    final scan = _patientScan;
    if (scan == null) return;
    setState(() => _busy = true);
    try {
      await medshare.setSpecialist(specialistHandle);
      await medshare.patientShareImage(scan, ttl: ttl);
      if (!mounted) return;
      setState(() {
        _patientShared = true;
        _grantExpiry = DateTime.now().add(ttl);
        // The recipient changed; let the specialist pane re-read fresh.
        _view = null;
        _hasFetched = false;
        _audit.append(medshare.patient, 'Granted time-limited view',
            'to @$_specialistHandle · ${_ttlLabel(ttl)}');
      });
    } catch (e) {
      _toast('Could not share: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _revoke() async {
    setState(() => _busy = true);
    try {
      await medshare.patientRevoke();
      if (!mounted) return;
      setState(() {
        _patientShared = false;
        _grantExpiry = null;
        _audit.append(
            medshare.patient, 'Revoked access', 'from @$_specialistHandle');
      });
    } catch (e) {
      _toast('Could not revoke: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // Quiet fetch used by the auto-refresh poll. Does not touch _busy.
  Future<void> _fetchView() async {
    if (_fetching) return;
    _fetching = true;
    try {
      final view = await medshare.specialistReadImage();
      if (!mounted) return;
      setState(() {
        _hasFetched = true;
        // Each read decodes a fresh Uint8List; swapping _view every poll would
        // give Image.memory a new provider and reload (a visible flash). While
        // the grant stays lit it's the same scan, so only swap on a transition.
        final wasLit = _view != null && !_view!.isDark;
        final nowLit = !view.isDark;
        if (nowLit) _everLit = true;
        if (nowLit && !wasLit) {
          _audit.append(medshare.specialist, 'Opened scan',
              "@$_patientHandle's Chest X-ray");
        }
        if (_view == null || nowLit != wasLit) _view = view;
        if (view.isDark) _grantExpiry = null;
      });
    } finally {
      _fetching = false;
    }
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  int? get _secondsLeft {
    final e = _grantExpiry;
    if (e == null) return null;
    final s = e.difference(DateTime.now()).inSeconds;
    return s < 0 ? 0 : s;
  }

  String _fmt(int total) =>
      '${total ~/ 60}:${(total % 60).toString().padLeft(2, '0')}';

  String _ttlLabel(Duration d) {
    if (d.inSeconds < 60) return '${d.inSeconds}s';
    if (d.inMinutes < 60) return '${d.inMinutes} min';
    return '${d.inHours} hr';
  }

  Future<void> _openGrantSheet() async {
    final result = await showModalBottomSheet<(Duration, String)>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _GrantSheet(specialistHandle: _specialistHandle),
    );
    if (result != null) await _grant(result.$1, result.$2);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: LayoutBuilder(
        builder: (context, c) {
          final h = (c.maxHeight - 48).clamp(0.0, 880.0);
          return Center(
            child: SizedBox(
              width: 400,
              height: h,
              child: Container(
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  color: _panel,
                  borderRadius: BorderRadius.circular(28),
                  border: Border.all(color: const Color(0xFF1A2730)),
                  boxShadow: const [
                    BoxShadow(
                        color: Color(0x66000000),
                        blurRadius: 30,
                        offset: Offset(0, 10)),
                  ],
                ),
                child: Column(
                  children: [
                    _header(),
                    if (_busy) const LinearProgressIndicator(minHeight: 2),
                    Expanded(child: _bodyForRole()),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _header() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 24,
                height: 24,
                decoration: BoxDecoration(
                  color: _brand,
                  borderRadius: BorderRadius.circular(7),
                ),
                child: const Icon(Icons.shield, size: 14, color: Colors.white),
              ),
              const SizedBox(width: 9),
              const Text('ScanShare',
                  style: TextStyle(
                      fontSize: 19,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.2,
                      color: _ink)),
              const Spacer(),
              IconButton(
                onPressed: _busy ? null : widget.onSettings,
                icon: const Icon(Icons.settings_outlined,
                    size: 20, color: _muted),
                tooltip: 'Change atSigns',
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
          const SizedBox(height: 12),
          _toggle(),
        ],
      ),
    );
  }

  Widget _toggle() {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: const Color(0xFF18262E),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          _toggleBtn('Clinic', Role.clinic),
          const SizedBox(width: 4),
          _toggleBtn('Patient', Role.patient),
          const SizedBox(width: 4),
          _toggleBtn('Specialist', Role.specialist),
          const SizedBox(width: 4),
          _toggleBtn('Audit', Role.audit),
        ],
      ),
    );
  }

  Widget _toggleBtn(String label, Role role) {
    final active = _role == role;
    return Expanded(
      child: GestureDetector(
        onTap: _busy ? null : () => _setRole(role),
        child: Container(
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(vertical: 9),
          decoration: BoxDecoration(
            color: active ? const Color(0xFF2A3A43) : Colors.transparent,
            borderRadius: BorderRadius.circular(9),
          ),
          child: Text(label,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: active ? _ink : _muted)),
        ),
      ),
    );
  }

  Widget _bodyForRole() {
    switch (_role) {
      case Role.clinic:
        return _clinicBody();
      case Role.patient:
        return _patientBody();
      case Role.specialist:
        return _specialistBody();
      case Role.audit:
        return _auditBody();
    }
  }

  // ---- Clinic ----

  Widget _clinicBody() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 4, 18, 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _sectionLabel('Imaging source'),
          const SizedBox(height: 12),
          _scanCard(
            image: Image.asset('assets/scan.jpg', fit: BoxFit.contain),
            tag: 'New scan',
            metaTitle: 'Chest X-ray',
            metaSub: 'Captured · Jun 26, 2026',
          ),
          const SizedBox(height: 16),
          if (_clinicDelivered)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              decoration: BoxDecoration(
                color: _goodBg,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: _good.withValues(alpha: 0.4)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.check, size: 20, color: _good),
                  const SizedBox(width: 11),
                  Expanded(
                    child: Text('Delivered to @$_patientHandle',
                        style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: _goodInk)),
                  ),
                ],
              ),
            )
          else
            _idleRow(Icons.lock_outline, 'Scan locked to the patient'),
          const Spacer(),
          _button(_clinicDelivered ? 'Send again' : 'Send scan to patient',
              _brand, Icons.send, _busy ? null : _deliver),
        ],
      ),
    );
  }

  // ---- Patient ----

  Widget _patientBody() {
    final scan = _patientScan;
    if (scan == null) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(18, 4, 18, 22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _sectionLabel('Your scan'),
            const SizedBox(height: 12),
            _scanCard(
              image: const Center(
                child: Icon(Icons.hourglass_empty,
                    size: 40, color: Color(0xFF3A4A52)),
              ),
              metaTitle: 'No scan yet',
              metaSub: 'Waiting for your clinic to send it',
            ),
            const SizedBox(height: 16),
            _idleRow(Icons.cloud_download_outlined,
                'Waiting for the clinic to deliver…'),
            const Spacer(),
            _button('Grant specialist access', _brand, null, null),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 4, 18, 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _sectionLabel('Your scan'),
          const SizedBox(height: 12),
          _scanCard(
            image: Image.memory(scan, fit: BoxFit.contain, gaplessPlayback: true),
            tag: 'Locked to you',
            metaTitle: 'Chest X-ray',
            metaSub: 'Received from @$_clinicHandle',
          ),
          const SizedBox(height: 16),
          _patientShared
              ? _activeStatus()
              : _idleRow(Icons.lock_outline, 'Not shared with anyone'),
          const Spacer(),
          if (_patientShared)
            _button('Revoke access now', _danger, Icons.block,
                _busy ? null : _revoke)
          else
            _button('Grant specialist access', _brand, null,
                _busy ? null : _openGrantSheet),
          if (_patientShared) ...[
            const SizedBox(height: 12),
            const Text(
              "Revoking deletes the specialist's copy — their view goes dark immediately.",
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12.5, color: _muted, height: 1.5),
            ),
          ],
        ],
      ),
    );
  }

  Widget _idleRow(IconData icon, String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _line),
      ),
      child: Row(
        children: [
          Icon(icon, size: 20, color: _muted),
          const SizedBox(width: 11),
          Flexible(
            child: Text(text,
                style: const TextStyle(fontSize: 14, color: _muted)),
          ),
        ],
      ),
    );
  }

  Widget _activeStatus() {
    final left = _secondsLeft;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: _goodBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _good.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          const Icon(Icons.check, size: 20, color: _good),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Shared with @$_specialistHandle',
                    style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: _goodInk)),
                const Text('Specialist can view now',
                    style: TextStyle(fontSize: 12.5, color: Color(0xFF8FB8A6))),
              ],
            ),
          ),
          if (left != null)
            Text(_fmt(left),
                style: const TextStyle(
                    fontSize: 15, fontWeight: FontWeight.w700, color: _goodInk)),
        ],
      ),
    );
  }

  // ---- Specialist ----

  Widget _specialistBody() {
    if (!_hasFetched) return _specialistLoading();
    return _referralList();
  }

  Widget _specialistLoading() {
    return const Padding(
      padding: EdgeInsets.all(32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
              width: 26,
              height: 26,
              child: CircularProgressIndicator(strokeWidth: 2.4)),
          SizedBox(height: 16),
          Text('Loading referrals…',
              style: TextStyle(fontSize: 14, color: _muted)),
        ],
      ),
    );
  }

  // A referral inbox: the live grant from the real patient sits on top, with
  // sample referrals from other patients underneath for context.
  Widget _referralList() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 4, 18, 22),
      children: [
        _sectionLabel('Incoming referrals'),
        const SizedBox(height: 12),
        _liveReferralCard(),
        const SizedBox(height: 10),
        for (final r in _mockReferrals) ...[
          _mockReferralCard(r),
          const SizedBox(height: 10),
        ],
      ],
    );
  }

  Widget _liveReferralCard() {
    final lit = _view != null && !_view!.isDark;
    return lit ? _liveCardLit() : _liveCardDark(revoked: _everLit);
  }

  Widget _liveCardLit() {
    final left = _secondsLeft;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: _brand.withValues(alpha: 0.55), width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _referralHeader('Jimmy Fang', 'jimmyfang', 'Chest X-ray', _brand,
              _statusChip(_RefStatus.active, seconds: left)),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: AspectRatio(
              aspectRatio: 320 / 180,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Container(color: _darkBg),
                  Image.memory(_view!.bytes!,
                      fit: BoxFit.contain, gaplessPlayback: true),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          const Row(
            children: [
              Icon(Icons.visibility_outlined, size: 15, color: _muted),
              SizedBox(width: 6),
              Flexible(
                child: Text('Read-only · no copy saved · expires automatically',
                    style: TextStyle(fontSize: 12, color: _muted)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _liveCardDark({required bool revoked}) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _darkBg,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
            color: revoked
                ? _danger.withValues(alpha: 0.35)
                : const Color(0xFF1A2730)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _referralHeader('Jimmy Fang', 'jimmyfang', 'Chest X-ray',
              const Color(0xFF7F939B),
              _statusChip(revoked ? _RefStatus.revoked : _RefStatus.pending),
              dark: true),
          const SizedBox(height: 18),
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: const Color(0x0FFFFFFF),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: const Color(0x1AFFFFFF)),
            ),
            child: const Icon(Icons.lock_outline,
                size: 26, color: Color(0xFF9FB0B7)),
          ),
          const SizedBox(height: 14),
        ],
      ),
    );
  }

  Widget _mockReferralCard(_Referral r) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: _line),
      ),
      child: Row(
        children: [
          _avatar(r.name, r.color),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(r.name,
                    style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: _ink)),
                Text('@${r.handle} · ${r.scan}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12.5, color: _muted)),
                const SizedBox(height: 2),
                Text(r.note,
                    style:
                        const TextStyle(fontSize: 11, color: Color(0xFF6E808A))),
              ],
            ),
          ),
          const SizedBox(width: 8),
          _statusChip(r.status),
        ],
      ),
    );
  }

  Widget _referralHeader(
      String name, String handle, String scan, Color color, Widget chip,
      {bool dark = false}) {
    return Row(
      children: [
        _avatar(name, color, dark: dark),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(name,
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w700, color: _ink)),
              Text('@$handle · $scan',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12.5, color: _muted)),
            ],
          ),
        ),
        const SizedBox(width: 8),
        chip,
      ],
    );
  }

  Widget _avatar(String name, Color color, {bool dark = false}) {
    return Container(
      width: 40,
      height: 40,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: dark ? const Color(0xFF22323A) : color.withValues(alpha: 0.20),
        shape: BoxShape.circle,
      ),
      child: Text(_initials(name),
          style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: dark ? const Color(0xFFCDD8DC) : color)),
    );
  }

  String _initials(String name) {
    final parts = name.trim().split(RegExp(r'\s+'));
    final letters = parts.take(2).map((p) => p[0].toUpperCase()).join();
    return letters.isEmpty ? '?' : letters;
  }

  Widget _statusChip(_RefStatus status, {int? seconds}) {
    final Color bg, fg;
    final String text;
    switch (status) {
      case _RefStatus.active:
        bg = _goodBg;
        fg = _goodInk;
        text = seconds != null ? '● ${_fmt(seconds)}' : '● Active';
      case _RefStatus.revoked:
        bg = const Color(0x29C2402C);
        fg = const Color(0xFFE89580);
        text = 'Revoked';
      case _RefStatus.expired:
        bg = const Color(0x14FFFFFF);
        fg = _muted;
        text = 'Expired';
      case _RefStatus.pending:
        bg = const Color(0x26C98A1A);
        fg = const Color(0xFFE0B872);
        text = 'Pending';
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration:
          BoxDecoration(color: bg, borderRadius: BorderRadius.circular(999)),
      child: Text(text,
          style:
              TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: fg)),
    );
  }

  // ---- Audit (read-only auditor view of the chained log) ----

  Widget _auditBody() {
    final entries = _audit.entries;
    final verified = _audit.verify();
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 4, 18, 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _sectionLabel('Audit log'),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: entries.isEmpty ? _surface : _goodBg,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                  color: entries.isEmpty
                      ? _line
                      : _good.withValues(alpha: 0.4)),
            ),
            child: Row(
              children: [
                Icon(
                    entries.isEmpty
                        ? Icons.shield_outlined
                        : (verified ? Icons.verified_user : Icons.gpp_bad),
                    size: 18,
                    color: entries.isEmpty
                        ? _muted
                        : (verified ? _good : _danger)),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    entries.isEmpty
                        ? 'No events yet'
                        : (verified
                            ? 'Chain verified · ${entries.length} event${entries.length == 1 ? '' : 's'}'
                            : 'Chain broken — tampering detected'),
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: entries.isEmpty
                            ? _muted
                            : (verified ? _goodInk : _danger)),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: entries.isEmpty
                ? const Center(
                    child: Text(
                        'Grants, views and revocations will appear here.',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 12.5, color: _muted)),
                  )
                : ListView.separated(
                    itemCount: entries.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (_, i) =>
                        _auditTile(entries[entries.length - 1 - i]),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _auditTile(medshare.AuditEntry e) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(_auditIcon(e.action), size: 18, color: _brand),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(e.action,
                        style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: _ink)),
                    if (e.detail.isNotEmpty)
                      Text(e.detail,
                          style:
                              const TextStyle(fontSize: 12.5, color: _muted)),
                  ],
                ),
              ),
              Text(_clock(e.time),
                  style: const TextStyle(fontSize: 12, color: _muted)),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Text('@${e.actor.replaceFirst('@', '')}',
                  style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF6E808A))),
              const Spacer(),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: _darkBg,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: _line),
                ),
                child: Text('#${e.seq} · ${e.hash.substring(0, 10)}',
                    style: const TextStyle(
                        fontSize: 10.5, color: Color(0xFF7FA6AE))),
              ),
            ],
          ),
        ],
      ),
    );
  }

  IconData _auditIcon(String action) {
    if (action.startsWith('Delivered')) return Icons.send;
    if (action.startsWith('Granted')) return Icons.lock_open;
    if (action.startsWith('Opened')) return Icons.visibility;
    if (action.startsWith('Revoked')) return Icons.block;
    return Icons.timer_off;
  }

  String _clock(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';

  // ---- Shared building blocks ----

  Widget _sectionLabel(String t) => Text(
        t.toUpperCase(),
        style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.5,
            color: _muted),
      );

  Widget _tagChip(String text) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(
          color: const Color(0xEB0C1418),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: const Color(0x33FFFFFF)),
        ),
        child: Text(text,
            style: const TextStyle(
                fontSize: 11, fontWeight: FontWeight.w700, color: _ink)),
      );

  Widget _scanCard({
    required Widget image,
    double aspectRatio = 320 / 180,
    String? tag,
    String? metaTitle,
    String? metaSub,
    EdgeInsets pad = const EdgeInsets.all(16),
  }) {
    return Container(
      padding: pad,
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: _line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: AspectRatio(
              aspectRatio: aspectRatio,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Container(color: _darkBg),
                  image,
                  if (tag != null)
                    Positioned(left: 12, top: 12, child: _tagChip(tag)),
                ],
              ),
            ),
          ),
          if (metaTitle != null) ...[
            const SizedBox(height: 12),
            Text(metaTitle,
                style: const TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w700, color: _ink)),
            if (metaSub != null)
              Text(metaSub,
                  style: const TextStyle(fontSize: 13, color: _muted)),
          ],
        ],
      ),
    );
  }

  Widget _button(String label, Color bg, IconData? icon, VoidCallback? onTap) {
    return SizedBox(
      height: 52,
      child: FilledButton(
        style: FilledButton.styleFrom(
          backgroundColor: bg,
          foregroundColor: Colors.white,
          disabledBackgroundColor: bg.withValues(alpha: 0.4),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
        onPressed: onTap,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[Icon(icon, size: 18), const SizedBox(width: 8)],
            Flexible(
              child: Text(label,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w700)),
            ),
          ],
        ),
      ),
    );
  }
}

// Bottom sheet for choosing the specialist and the grant duration.
class _GrantSheet extends StatefulWidget {
  final String specialistHandle;
  const _GrantSheet({required this.specialistHandle});

  @override
  State<_GrantSheet> createState() => _GrantSheetState();
}

class _GrantSheetState extends State<_GrantSheet> {
  static const _options = <String, Duration>{
    '30 sec': Duration(seconds: 30),
    '1 min': Duration(minutes: 1),
    '5 min': Duration(minutes: 5),
    '1 hr': Duration(hours: 1),
  };
  String _sel = '30 sec';
  late final TextEditingController _handle =
      TextEditingController(text: widget.specialistHandle);

  @override
  void dispose() {
    _handle.dispose();
    super.dispose();
  }

  void _submit() {
    final handle = _handle.text.trim();
    if (handle.isEmpty) return;
    Navigator.pop(context, (_options[_sel]!, handle));
  }

  @override
  Widget build(BuildContext context) {
    final keys = _options.keys.toList();
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        decoration: const BoxDecoration(
          color: _surface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
        ),
        padding: const EdgeInsets.fromLTRB(18, 14, 18, 26),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: const Color(0xFF2E3E47),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),
            const Text('SHARE WITH A SPECIALIST',
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.5,
                    color: _muted)),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
              decoration: BoxDecoration(
                border: Border.all(color: _line),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  const Text('@',
                      style: TextStyle(
                          fontWeight: FontWeight.w800,
                          color: _brand,
                          fontSize: 15)),
                  const SizedBox(width: 9),
                  Expanded(
                    child: TextField(
                      controller: _handle,
                      autofocus: true,
                      cursorColor: _brand,
                      onSubmitted: (_) => _submit(),
                      textInputAction: TextInputAction.done,
                      style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: _ink),
                      decoration: const InputDecoration(
                        border: InputBorder.none,
                        isCollapsed: true,
                        contentPadding: EdgeInsets.symmetric(vertical: 13),
                        hintText: 'specialist',
                        hintStyle: TextStyle(color: _muted),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            const Text('ACCESS EXPIRES AFTER',
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.5,
                    color: _muted)),
            const SizedBox(height: 8),
            Row(
              children: [
                for (var i = 0; i < keys.length; i++)
                  Expanded(
                    child: Padding(
                      padding:
                          EdgeInsets.only(right: i == keys.length - 1 ? 0 : 8),
                      child: GestureDetector(
                        onTap: () => setState(() => _sel = keys[i]),
                        child: Container(
                          alignment: Alignment.center,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          decoration: BoxDecoration(
                            color: _sel == keys[i]
                                ? _brand.withValues(alpha: 0.16)
                                : Colors.transparent,
                            border: Border.all(
                                color: _sel == keys[i] ? _brand : _line,
                                width: 1.5),
                            borderRadius: BorderRadius.circular(11),
                          ),
                          child: Text(keys[i],
                              style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                  color: _sel == keys[i] ? _brand : _muted)),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            SizedBox(
              height: 52,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: _brand,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                ),
                onPressed: _submit,
                child: const Text('Grant access',
                    style:
                        TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// First-run / settings screen: each user enters the three atSigns of their own
// chain. Each must be onboarded (its .atKeys present) to authenticate.
class SetupScreen extends StatefulWidget {
  final VoidCallback onSaved;
  const SetupScreen({super.key, required this.onSaved});

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  late final _clinic =
      TextEditingController(text: medshare.clinic.replaceFirst('@', ''));
  late final _patient =
      TextEditingController(text: medshare.patient.replaceFirst('@', ''));
  late final _specialist =
      TextEditingController(text: medshare.specialist.replaceFirst('@', ''));
  bool _saving = false;

  @override
  void dispose() {
    _clinic.dispose();
    _patient.dispose();
    _specialist.dispose();
    super.dispose();
  }

  bool get _ready =>
      _clinic.text.trim().isNotEmpty &&
      _patient.text.trim().isNotEmpty &&
      _specialist.text.trim().isNotEmpty;

  Future<void> _save() async {
    if (!_ready || _saving) return;
    setState(() => _saving = true);
    try {
      await medshare.configure(
        clinicAt: _clinic.text,
        patientAt: _patient.text,
        specialistAt: _specialist.text,
      );
      await _saveConfig();
      widget.onSaved();
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Container(
              padding: const EdgeInsets.all(22),
              decoration: BoxDecoration(
                color: _panel,
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: const Color(0xFF1A2730)),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 24,
                        height: 24,
                        decoration: BoxDecoration(
                          color: _brand,
                          borderRadius: BorderRadius.circular(7),
                        ),
                        child: const Icon(Icons.shield,
                            size: 14, color: Colors.white),
                      ),
                      const SizedBox(width: 9),
                      const Text('ScanShare',
                          style: TextStyle(
                              fontSize: 19,
                              fontWeight: FontWeight.w700,
                              color: _ink)),
                    ],
                  ),
                  const SizedBox(height: 18),
                  const Text('Set up the chain',
                      style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                          color: _ink)),
                  const SizedBox(height: 6),
                  const Text(
                    'Enter the three atSigns to use. Each must already be '
                    'onboarded on this machine (its .atKeys file in '
                    '~/.atsign/keys/).',
                    style: TextStyle(fontSize: 13, color: _muted, height: 1.5),
                  ),
                  const SizedBox(height: 18),
                  _field('Clinic / imaging source', _clinic),
                  const SizedBox(height: 14),
                  _field('Patient', _patient),
                  const SizedBox(height: 14),
                  _field('Specialist', _specialist),
                  const SizedBox(height: 22),
                  SizedBox(
                    height: 52,
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: _brand,
                        foregroundColor: Colors.white,
                        disabledBackgroundColor: _brand.withValues(alpha: 0.4),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14)),
                      ),
                      onPressed: _ready && !_saving ? _save : null,
                      child: Text(_saving ? 'Saving…' : 'Continue',
                          style: const TextStyle(
                              fontSize: 15, fontWeight: FontWeight.w700)),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _field(String label, TextEditingController controller) {
    final value = controller.text.trim();
    final hasKeys = value.isNotEmpty && medshare.hasKeys(value);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(label.toUpperCase(),
            style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.5,
                color: _muted)),
        const SizedBox(height: 6),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
          decoration: BoxDecoration(
            color: _surface,
            border: Border.all(color: _line),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              const Text('@',
                  style: TextStyle(
                      fontWeight: FontWeight.w800,
                      color: _brand,
                      fontSize: 15)),
              const SizedBox(width: 9),
              Expanded(
                child: TextField(
                  controller: controller,
                  cursorColor: _brand,
                  onChanged: (_) => setState(() {}),
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w600, color: _ink),
                  decoration: const InputDecoration(
                    border: InputBorder.none,
                    isCollapsed: true,
                    contentPadding: EdgeInsets.symmetric(vertical: 14),
                    hintText: 'youratsign',
                    hintStyle: TextStyle(color: _muted),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 5),
        Row(
          children: [
            Icon(
                value.isEmpty
                    ? Icons.remove
                    : (hasKeys ? Icons.check_circle : Icons.error_outline),
                size: 14,
                color: value.isEmpty
                    ? _muted
                    : (hasKeys ? _good : const Color(0xFFE0B872))),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                value.isEmpty
                    ? 'Enter an atSign'
                    : (hasKeys
                        ? 'Keys found in ~/.atsign/keys/'
                        : 'No .atKeys for this atSign yet'),
                style: TextStyle(
                    fontSize: 11.5,
                    color: value.isEmpty
                        ? _muted
                        : (hasKeys ? _goodInk : const Color(0xFFE0B872))),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
