import 'dart:async';
import 'dart:io';

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

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Point the atSign Hive stores at a stable app-data location instead of
  // the process working directory.
  final dir = await getApplicationSupportDirectory();
  medshare.storageBase = '${dir.path}${Platform.pathSeparator}storage';
  runApp(const MedShareApp());
}

class MedShareApp extends StatelessWidget {
  const MedShareApp({super.key});

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
      home: const HomePage(),
    );
  }
}

enum Role { patient, specialist }

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
  _Referral('Avery Lin', 'avery.lin', 'Knee MRI', 'Expired 2h ago',
      _RefStatus.expired, Color(0xFF6E8BFF)),
  _Referral('Sam Okafor', 'sam.okafor', 'Dental panoramic',
      'Awaiting the patient’s grant', _RefStatus.pending, Color(0xFFE89A5B)),
  _Referral('Priya Nair', 'priya.nair', 'Chest CT', 'Revoked yesterday',
      _RefStatus.revoked, Color(0xFFB58BFF)),
];

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  static const _pollInterval = Duration(seconds: 3);

  Role _role = Role.patient;
  bool _busy = false;

  // Patient state: whether a grant is currently outstanding, and when it ends.
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

  // Poll only while the specialist pane is visible.
  void _syncPolling() {
    final shouldPoll = _role == Role.specialist;
    if (shouldPoll && _pollTimer == null) {
      _pollTimer = Timer.periodic(_pollInterval, (_) => _fetchView());
      _fetchView();
    } else if (!shouldPoll && _pollTimer != null) {
      _pollTimer!.cancel();
      _pollTimer = null;
    }
  }

  void _setRole(Role r) {
    setState(() => _role = r);
    _syncPolling();
  }

  Future<void> _grant(Duration ttl, String specialistHandle) async {
    setState(() => _busy = true);
    try {
      await medshare.setSpecialist(specialistHandle);
      final data = await rootBundle.load('assets/scan.jpg');
      await medshare.patientShareImage(data.buffer.asUint8List(), ttl: ttl);
      if (!mounted) return;
      setState(() {
        _patientShared = true;
        _grantExpiry = DateTime.now().add(ttl);
        // The recipient changed; let the specialist pane re-read fresh.
        _view = null;
        _hasFetched = false;
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
                    Expanded(
                      child: _role == Role.patient
                          ? _patientBody()
                          : _specialistBody(),
                    ),
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
          _toggleBtn('Patient', Role.patient),
          const SizedBox(width: 4),
          _toggleBtn('Specialist', Role.specialist),
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
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: active ? _ink : _muted)),
        ),
      ),
    );
  }

  // ---- Patient ----

  Widget _patientBody() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 4, 18, 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _sectionLabel('Your scan'),
          const SizedBox(height: 12),
          _scanCard(
            image: Image.asset('assets/scan.jpg', fit: BoxFit.contain),
            tag: 'Locked to you',
            metaTitle: 'Chest X-ray',
            metaSub: 'Jun 26, 2026',
          ),
          const SizedBox(height: 16),
          _patientShared ? _activeStatus() : _idleStatus(),
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

  Widget _idleStatus() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _line),
      ),
      child: const Row(
        children: [
          Icon(Icons.lock_outline, size: 20, color: _muted),
          SizedBox(width: 11),
          Flexible(
            child: Text('Not shared with anyone',
                style: TextStyle(fontSize: 14, color: _muted)),
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
          _referralHeader('Jordan Mei', _patientHandle, 'Chest X-ray', _brand,
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
          _referralHeader('Jordan Mei', _patientHandle, 'Chest X-ray',
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
