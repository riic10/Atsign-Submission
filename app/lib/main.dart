import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:headless/medshare.dart' as medshare;
import 'package:path_provider/path_provider.dart';

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
      title: 'MedShare',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.teal,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

enum Role { patient, specialist }

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  static const _pollInterval = Duration(seconds: 3);

  Role _role = Role.patient;
  bool _busy = false;
  String _status = '';

  // Specialist view state.
  medshare.ScanView? _view;
  // Absolute deadline of the active time-limited grant, captured at share
  // time. The platform recomputes expiresAt on every read (always ~full ttl),
  // so it can't drive a countdown; this local anchor can. Go-dark still comes
  // from the real platform read failing, not this timer.
  DateTime? _grantExpiry;
  bool _hasFetched = false;
  bool _fetching = false; // guards overlapping network reads
  bool _autoRefresh = true;
  Timer? _pollTimer; // re-fetches the scan on an interval
  Timer? _ticker; // 1Hz repaint so the countdown ticks down

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    _syncPolling();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _ticker?.cancel();
    super.dispose();
  }

  // Poll only while the specialist pane is visible with auto-refresh on.
  void _syncPolling() {
    final shouldPoll = _role == Role.specialist && _autoRefresh;
    if (shouldPoll && _pollTimer == null) {
      _pollTimer = Timer.periodic(_pollInterval, (_) => _fetchView());
      _fetchView();
    } else if (!shouldPoll && _pollTimer != null) {
      _pollTimer!.cancel();
      _pollTimer = null;
    }
  }

  Future<void> _run(String label, Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _status = '$label…';
    });
    try {
      await action();
      setState(() => _status = '$label ✓');
    } catch (e) {
      setState(() => _status = '$label failed: $e');
    } finally {
      setState(() => _busy = false);
    }
  }

  Future<void> _share({Duration? ttl}) async {
    await _run(ttl == null ? 'Share scan' : 'Share (${ttl.inSeconds}s)',
        () async {
      final data = await rootBundle.load('assets/scan.jpg');
      final bytes = data.buffer.asUint8List();
      await medshare.patientShareImage(bytes, ttl: ttl);
      // Anchor the countdown once the share has landed.
      _grantExpiry = ttl == null ? null : DateTime.now().add(ttl);
    });
  }

  Future<void> _revoke() async {
    await _run('Revoke', () async {
      await medshare.patientRevoke();
      _grantExpiry = null;
    });
  }

  // Quiet fetch used by both the manual button and the auto-refresh poll.
  // Does not touch _busy, so the periodic poll doesn't flicker the UI.
  Future<void> _fetchView() async {
    if (_fetching) return;
    _fetching = true;
    try {
      final view = await medshare.specialistReadImage();
      if (!mounted) return;
      setState(() {
        _hasFetched = true;
        // Each read decodes a fresh Uint8List, so swapping _view every poll
        // gives Image.memory a new provider and it reloads (a visible flash).
        // While the grant stays lit it's the same scan, so keep the existing
        // image stable and only swap _view on a lit<->dark transition.
        final wasLit = _view != null && !_view!.isDark;
        final nowLit = !view.isDark;
        if (_view == null || nowLit != wasLit) {
          _view = view;
        }
        if (view.isDark) _grantExpiry = null;
      });
    } finally {
      _fetching = false;
    }
  }

  int? get _secondsLeft {
    final expiry = _grantExpiry;
    if (expiry == null) return null;
    final s = expiry.difference(DateTime.now()).inSeconds;
    return s < 0 ? 0 : s;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('MedShare — patient-controlled scan sharing'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(56),
          child: Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: SegmentedButton<Role>(
              segments: const [
                ButtonSegment(
                    value: Role.patient,
                    label: Text('Patient'),
                    icon: Icon(Icons.person)),
                ButtonSegment(
                    value: Role.specialist,
                    label: Text('Specialist'),
                    icon: Icon(Icons.medical_services)),
              ],
              selected: {_role},
              onSelectionChanged: _busy
                  ? null
                  : (s) => setState(() {
                        _role = s.first;
                        _syncPolling();
                      }),
            ),
          ),
        ),
      ),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child:
                  _role == Role.patient ? _patientPane() : _specialistPane(),
            ),
            const SizedBox(height: 12),
            if (_busy) const LinearProgressIndicator(),
            const SizedBox(height: 8),
            Text(_status, style: Theme.of(context).textTheme.bodyMedium),
          ],
        ),
      ),
    );
  }

  Widget _patientPane() {
    return Column(
      children: [
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Image.asset('assets/scan.jpg', fit: BoxFit.contain),
          ),
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          alignment: WrapAlignment.center,
          children: [
            FilledButton.icon(
              onPressed: _busy ? null : () => _share(),
              icon: const Icon(Icons.share),
              label: const Text('Share with specialist'),
            ),
            FilledButton.tonalIcon(
              onPressed: _busy
                  ? null
                  : () => _share(ttl: const Duration(seconds: 30)),
              icon: const Icon(Icons.timer),
              label: const Text('Share for 30s'),
            ),
            OutlinedButton.icon(
              onPressed: _busy ? null : _revoke,
              icon: const Icon(Icons.block),
              label: const Text('Revoke'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _specialistPane() {
    final Widget viewer;
    if (!_hasFetched) {
      viewer = _placeholder(Icons.lock_clock, 'Requesting the scan…');
    } else if (_view == null || _view!.isDark) {
      viewer = _placeholder(
          Icons.visibility_off, 'View is DARK — no active grant');
    } else {
      viewer = ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Image.memory(_view!.bytes!,
            fit: BoxFit.contain, gaplessPlayback: true),
      );
    }

    final left = _secondsLeft;
    final showCountdown = _view != null && !_view!.isDark && left != null;

    return Column(
      children: [
        if (showCountdown)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Chip(
              avatar: Icon(Icons.timer,
                  color: left <= 5 ? Colors.redAccent : Colors.tealAccent),
              label: Text('Access expires in ${left}s'),
            ),
          ),
        Expanded(child: viewer),
        const SizedBox(height: 16),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            FilledButton.icon(
              onPressed: _fetching ? null : _fetchView,
              icon: const Icon(Icons.refresh),
              label: const Text('Fetch now'),
            ),
            const SizedBox(width: 20),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Switch(
                  value: _autoRefresh,
                  onChanged: (v) => setState(() {
                    _autoRefresh = v;
                    _syncPolling();
                  }),
                ),
                const Text('Auto-refresh'),
              ],
            ),
          ],
        ),
      ],
    );
  }

  Widget _placeholder(IconData icon, String text) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white24),
      ),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 64, color: Colors.white38),
            const SizedBox(height: 12),
            Text(text, style: const TextStyle(color: Colors.white54)),
          ],
        ),
      ),
    );
  }
}
