import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:google_fonts/google_fonts.dart';
import '../main.dart';
import 'events_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final DatabaseReference _db = FirebaseDatabase.instance.ref();
  int  _triggeredSensor  = 0;
  bool _armed            = false;
  bool _triggered        = false;
  bool _activeSiren      = false;
  bool _esp32Online      = false;
  bool _loading          = true;
  int  _lastHeartbeatValue = 0;

  @override
  void initState() {
    super.initState();
    _setupFCM();
    _listenToFirebase();
    _startHeartbeatChecker();
  }

  Future<void> _setupFCM() async {
    FirebaseMessaging messaging = FirebaseMessaging.instance;

    await messaging.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );

    String? token = await messaging.getToken();
    if (token != null) {
      await _db.child('fcm_token').set(token);
      debugPrint('FCM token written: ${token.substring(0, 20)}...');
    }

    FirebaseMessaging.onMessage.listen((RemoteMessage message) {
      showLocalNotification(
        message.notification?.title ?? 'Alert',
        message.notification?.body ?? '',
      );
    });

    messaging.onTokenRefresh.listen((newToken) {
      _db.child('fcm_token').set(newToken);
    });
  }

  void _startHeartbeatChecker() {
    // Actively checks every 5s if the last heartbeat is stale
    // This catches ESP32 going offline even when Firebase stops pushing updates
    Stream.periodic(const Duration(seconds: 5)).listen((_) {
      if (!mounted) return;
      if (_lastHeartbeatValue == 0) {
        if (_esp32Online) setState(() => _esp32Online = false);
        return;
      }
      final now        = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final secondsAgo = now - _lastHeartbeatValue;
      final isOnline   = secondsAgo < 20;
      if (isOnline != _esp32Online) {
        setState(() => _esp32Online = isOnline);
      }
    });
  }

  void _listenToFirebase() {
    // Listen to alarm state
    _db.child('alarm').onValue.listen((event) {
      if (!mounted) return;
      final data = event.snapshot.value as Map<dynamic, dynamic>?;
      if (data != null) {
        setState(() {
          _armed           = data['armed']             == true;
          _triggered       = data['triggered']         == true;
          _activeSiren     = data['active_siren']      == true;
          _triggeredSensor = (data['triggered_sensor'] as int?) ?? 0;
          _loading         = false;
        });
      }
    });

    // Listen to heartbeat from Firebase
    // Store the value locally so the periodic checker can evaluate it
    _db.child('heartbeat').onValue.listen((event) {
      if (!mounted) return;
      final lastBeat = event.snapshot.value as int?;

      if (lastBeat == null || lastBeat == 0) {
        _lastHeartbeatValue = 0;
        setState(() => _esp32Online = false);
        return;
      }

      _lastHeartbeatValue = lastBeat;
      final now        = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final secondsAgo = now - lastBeat;
      setState(() => _esp32Online = secondsAgo < 20);
    });

    // Initial loading timeout
    Future.delayed(const Duration(seconds: 5), () {
      if (_loading && mounted) setState(() => _loading = false);
    });
  }

  Future<void> _toggleArmed() async {
    await _db.child('alarm/armed').set(!_armed);
  }

  String get _statusLabel {
    if (!_esp32Online) return 'OFFLINE';
    if (_activeSiren)  return 'ALARM!';
    if (_triggered)    return 'TRIGGERED';
    if (_armed)        return 'ARMED';
    return 'DISARMED';
  }

  Color get _statusColor {
    if (!_esp32Online) return Colors.grey;
    if (_activeSiren)  return Colors.red;
    if (_triggered)    return Colors.orange;
    if (_armed)        return const Color(0xFF00E676);
    return Colors.blueGrey;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F0F1A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0F0F1A),
        title: Text(
          'Chor Asche',
          style: GoogleFonts.orbitron(
            color: Colors.white,
            fontWeight: FontWeight.bold,
            fontSize: 20,
          ),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Row(
              children: [
                Container(
                  width:  10,
                  height: 10,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _esp32Online
                        ? const Color(0xFF00E676)
                        : Colors.grey,
                    boxShadow: _esp32Online
                        ? [
                            BoxShadow(
                              color: const Color(0xFF00E676)
                                  .withValues(alpha: 0.6),
                              blurRadius:   8,
                              spreadRadius: 2,
                            )
                          ]
                        : null,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  _esp32Online ? 'Online' : 'Offline',
                  style: TextStyle(
                    color: _esp32Online
                        ? const Color(0xFF00E676)
                        : Colors.grey,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.history, color: Colors.white),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const EventsScreen()),
            ),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                children: [
                  const SizedBox(height: 20),

                  // ── Status ring ──────────────────────────
                  _StatusRing(
                    label:   _statusLabel,
                    color:   _statusColor,
                    pulsing: _activeSiren,
                  ).animate().fadeIn(duration: 600.ms).scale(),

                  const SizedBox(height: 48),

                  // ── Arm / Disarm button ──────────────────
                  GestureDetector(
                    onTap: _esp32Online ? _toggleArmed : null,
                    child: Container(
                      width:  180,
                      height: 180,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: const Color(0xFF1A1A2E),
                        border: Border.all(
                          color: _statusColor,
                          width: 3,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color:        _statusColor.withValues(alpha: 0.3),
                            blurRadius:   30,
                            spreadRadius: 5,
                          ),
                        ],
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            _armed ? Icons.lock : Icons.lock_open,
                            color: _statusColor,
                            size:  56,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            _armed ? 'TAP TO\nDISARM' : 'TAP TO\nARM',
                            textAlign: TextAlign.center,
                            style: GoogleFonts.orbitron(
                              color:       _statusColor,
                              fontSize:    13,
                              fontWeight:  FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ).animate().fadeIn(delay: 200.ms, duration: 600.ms),

                  const SizedBox(height: 48),

                  // ── Sensor status cards ──────────────────
                  Row(
                    children: [
                      Expanded(
                        child: _SensorCard(
                          label:  'Sensor 2',
                          pin:    'GPIO 34',
                          active: _triggered && _triggeredSensor == 1,
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: _SensorCard(
                          label:  'Sensor 1',
                          pin:    'GPIO 35',
                          active: _triggered && _triggeredSensor == 2,
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 24),

                  // ── View event log ───────────────────────
                  TextButton.icon(
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => const EventsScreen()),
                    ),
                    icon: const Icon(Icons.history, color: Colors.white54),
                    label: Text(
                      'View alarm history',
                      style: GoogleFonts.orbitron(
                        color:    Colors.white54,
                        fontSize: 13,
                      ),
                    ),
                  ).animate().fadeIn(delay: 600.ms, duration: 600.ms),
                ],
              ),
            ),
    );
  }
}

// ── Status ring ────────────────────────────────────────────
class _StatusRing extends StatelessWidget {
  final String label;
  final Color  color;
  final bool   pulsing;

  const _StatusRing({
    required this.label,
    required this.color,
    required this.pulsing,
  });

  @override
  Widget build(BuildContext context) {
    Widget ring = Container(
      width:  160,
      height: 160,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: color, width: 4),
        boxShadow: [
          BoxShadow(
            color:        color.withValues(alpha: 0.4),
            blurRadius:   24,
            spreadRadius: 4,
          ),
        ],
      ),
      child: Center(
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: GoogleFonts.orbitron(
            color:         color,
            fontSize:      18,
            fontWeight:    FontWeight.bold,
            letterSpacing: 2,
          ),
        ),
      ),
    );

    if (pulsing) {
      return ring
          .animate(onPlay: (c) => c.repeat())
          .scaleXY(begin: 1.0, end: 1.08, duration: 600.ms)
          .then()
          .scaleXY(begin: 1.08, end: 1.0, duration: 600.ms);
    }
    return ring;
  }
}

// ── Sensor card ────────────────────────────────────────────
class _SensorCard extends StatelessWidget {
  final String label;
  final String pin;
  final bool   active;

  const _SensorCard({
    required this.label,
    required this.pin,
    required this.active,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A2E),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: active ? Colors.orange : Colors.white12,
          width: 1.5,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width:  10,
                height: 10,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: active ? Colors.orange : Colors.white24,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                label,
                style: GoogleFonts.orbitron(
                  color:      Colors.white,
                  fontSize:   13,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            pin,
            style: const TextStyle(color: Colors.white38, fontSize: 11),
          ),
          const SizedBox(height: 4),
          Text(
            active ? 'MOTION' : 'CLEAR',
            style: TextStyle(
              color:      active ? Colors.orange : Colors.white38,
              fontSize:   11,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }
}