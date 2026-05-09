import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import '../main.dart';
import 'events_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with SingleTickerProviderStateMixin {
  final DatabaseReference _db = FirebaseDatabase.instance.ref();

  bool _armed            = false;
  bool _triggered        = false;
  bool _activeSiren      = false;
  bool _esp32Online      = false;
  bool _loading          = true;
  int  _lastHeartbeatValue = 0;
  int  _triggeredSensor  = 0;

  late AnimationController _pulseController;
  late Animation<double>   _pulseAnimation;

  // ── Derived state ──────────────────────────────────────
  String get _statusLabel {
    if (!_esp32Online) return 'OFFLINE';
    if (_activeSiren)  return 'ALERT!';
    if (_armed)        return 'ARMED';
    return 'READY';
  }

  Color get _ringColor {
    if (!_esp32Online) return const Color(0xFF888888);
    if (_activeSiren)  return const Color(0xFFE53935);
    if (_armed)        return const Color(0xFF43A047);
    return const Color(0xFFFB8C00);
  }

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    _pulseAnimation = Tween<double>(begin: 1.0, end: 1.06).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
    _setupFCM();
    _listenToFirebase();
    _startHeartbeatChecker();
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  void _updatePulse() {
    if (_activeSiren) {
      _pulseController.repeat(reverse: true);
    } else {
      _pulseController.stop();
      _pulseController.reset();
    }
  }

  Future<void> _setupFCM() async {
    FirebaseMessaging messaging = FirebaseMessaging.instance;
    await messaging.requestPermission(alert: true, badge: true, sound: true);
    String? token = await messaging.getToken();
    if (token != null) {
      await _db.child('fcm_token').set(token);
    }
    FirebaseMessaging.onMessage.listen((RemoteMessage message) {
      showLocalNotification(
        message.notification?.title ?? 'Alert',
        message.notification?.body ?? '',
      );
    });
    messaging.onTokenRefresh.listen((t) => _db.child('fcm_token').set(t));
  }

  void _startHeartbeatChecker() {
    Stream.periodic(const Duration(seconds: 5)).listen((_) {
      if (!mounted) return;
      if (_lastHeartbeatValue == 0) {
        if (_esp32Online) setState(() => _esp32Online = false);
        return;
      }
      final now        = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final secondsAgo = now - _lastHeartbeatValue;
      final isOnline   = secondsAgo < 20;
      if (isOnline != _esp32Online) setState(() => _esp32Online = isOnline);
    });
  }

  void _listenToFirebase() {
    _db.child('alarm').onValue.listen((event) {
      if (!mounted) return;
      final data = event.snapshot.value as Map<dynamic, dynamic>?;
      if (data != null) {
        final newSiren = data['active_siren'] == true;
        setState(() {
          _armed           = data['armed']             == true;
          _triggered       = data['triggered']         == true;
          _activeSiren     = newSiren;
          _triggeredSensor = (data['triggered_sensor'] as int?) ?? 0;
          _loading         = false;
        });
        _updatePulse();
      }
    });

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

    Future.delayed(const Duration(seconds: 5), () {
      if (_loading && mounted) setState(() => _loading = false);
    });
  }

  Future<void> _toggleArmed() async {
    if (!_esp32Online) return;
    await _db.child('alarm/armed').set(!_armed);
  }

  // ── Drawer ─────────────────────────────────────────────
  Widget _buildDrawer() {
    return Drawer(
      backgroundColor: const Color(0xFF1C1C1C),
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Divider(color: Color(0xFF2C2C2C)),
            _drawerItem(Icons.home_outlined, 'Home', () => Navigator.pop(context)),
            _drawerItem(Icons.history_outlined, 'Alarm history', () {
              Navigator.pop(context);
              Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const EventsScreen()));
            }),
            const Spacer(),
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'Chor Asche v1.0',
                style: TextStyle(color: Color(0xFF555555), fontSize: 12),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _drawerItem(IconData icon, String label, VoidCallback onTap) {
    return ListTile(
      leading: Icon(icon, color: const Color(0xFFAAAAAA), size: 22),
      title: Text(
        label,
        style: const TextStyle(color: Color(0xFFCCCCCC), fontSize: 15),
      ),
      onTap: onTap,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      drawer: _buildDrawer(),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: Color(0xFFFB8C00)))
          : Builder(
              builder: (context) => SafeArea(
                child: Column(
                  children: [
                    // ── Top bar ────────────────────────────
                    Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 20, vertical: 12),
                      child: Row(
                        children: [
                          // Hamburger
                          GestureDetector(
                            onTap: () => Scaffold.of(context).openDrawer(),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                _menuLine(18),
                                const SizedBox(height: 5),
                                _menuLine(14),
                                const SizedBox(height: 5),
                                _menuLine(18),
                              ],
                            ),
                          ),
                          const SizedBox(width: 16),
                          // Logo
                          // Logo
                          Padding(
                            padding: const EdgeInsets.only(top: 23),
                            child: Image.asset(
                              'assets/images/logo final-transparent-wht.png',
                              height: 40,
                            ),
                          ),
                          const Spacer(),
                          // Online indicator
                          Row(
                            children: [
                              Container(
                                width:  8,
                                height: 8,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: _esp32Online
                                      ? const Color(0xFF43A047)
                                      : const Color(0xFF888888),
                                ),
                              ),
                              const SizedBox(width: 6),
                              Text(
                                _esp32Online ? 'online' : 'offline',
                                style: TextStyle(
                                  color: _esp32Online
                                      ? const Color(0xFF43A047)
                                      : const Color(0xFF888888),
                                  fontSize: 13,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),

                    const Spacer(),

                    // ── Status ring ────────────────────────
                    AnimatedBuilder(
                      animation: _pulseAnimation,
                      builder: (_, __) => Transform.scale(
                        scale: _activeSiren ? _pulseAnimation.value : 1.0,
                        child: _StatusRing(
                          label: _statusLabel,
                          color: _ringColor,
                        ),
                      ),
                    ),

                    const SizedBox(height: 48),

                    // ── Arm / Disarm button ────────────────
                    GestureDetector(
                      onTap: _toggleArmed,
                      child: Container(
                        width:  120,
                        height: 120,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: const Color(0xFF1E1E1E),
                          border: Border.all(
                            color: const Color(0xFF2C2C2C),
                            width: 1.5,
                          ),
                        ),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              _armed ? Icons.lock_open_rounded
                                     : Icons.lock_rounded,
                              color: _armed
                                  ? _ringColor
                                  : const Color(0xFFCCCCCC),
                              size: 36,
                            ),
                            const SizedBox(height: 8),
                            Text(
                              _armed ? 'TAP TO DISARM' : 'TAP TO ARM',
                              style: const TextStyle(
                                color:    Color(0xFF888888),
                                fontSize: 10,
                                letterSpacing: 1.2,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),

                    const Spacer(),

                    // ── Sensor cards ───────────────────────
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: Row(
                        children: [
                          Expanded(
                            child: _SensorCard(
                              label:   'Sensor 1',
                              pin:     'GPIO 34',
                              active:  _triggered && _triggeredSensor == 1,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: _SensorCard(
                              label:  'Sensor 2',
                              pin:    'GPIO 35',
                              active: _triggered && _triggeredSensor == 2,
                            ),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 16),

                    // ── View alarm records button ──────────
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: GestureDetector(
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) => const EventsScreen()),
                        ),
                        child: Container(
                          width:   double.infinity,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          decoration: BoxDecoration(
                            color:        const Color(0xFF1E1E1E),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: const Color(0xFF2C2C2C),
                              width: 1,
                            ),
                          ),
                          child: const Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.remove_red_eye_outlined,
                                  color: Color(0xFF888888), size: 16),
                              SizedBox(width: 8),
                              Text(
                                'View alarm records',
                                style: TextStyle(
                                  color:    Color(0xFF888888),
                                  fontSize: 13,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),

                    const SizedBox(height: 32),
                  ],
                ),
              ),
            ),
    );
  }

  Widget _menuLine(double width) => Container(
        width:  width,
        height: 2,
        decoration: BoxDecoration(
          color:        const Color(0xFFCCCCCC),
          borderRadius: BorderRadius.circular(2),
        ),
      );
}

// ── Status ring ────────────────────────────────────────────
class _StatusRing extends StatelessWidget {
  final String label;
  final Color  color;

  const _StatusRing({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width:  180,
      height: 180,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: const Color(0xFF1A1A1A),
        border: Border.all(color: color, width: 5),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Text(
            'STATUS',
            style: TextStyle(
              color:         Color(0xFF888888),
              fontSize:      11,
              letterSpacing: 2,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            label,
            style: TextStyle(
              color:         color,
              fontSize:      22,
              fontWeight:    FontWeight.w600,
              letterSpacing: 1,
            ),
          ),
        ],
      ),
    );
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
    final Color dotColor = active
        ? const Color(0xFFE53935)
        : const Color(0xFF444444);
    final Color textColor = active
        ? const Color(0xFFE53935)
        : const Color(0xFF888888);

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color:        const Color(0xFF1E1E1E),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: active
              ? const Color(0xFFE53935).withValues(alpha: 0.4)
              : const Color(0xFF2C2C2C),
          width: 1,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Status dot
          Padding(
            padding: const EdgeInsets.only(top: 3),
            child: Container(
              width:  9,
              height: 9,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: dotColor,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: const TextStyle(
                  color:      Color(0xFFCCCCCC),
                  fontSize:   13,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                pin,
                style: const TextStyle(
                  color:    Color(0xFF555555),
                  fontSize: 11,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                active ? 'TRIGGERED' : 'CLEAR',
                style: TextStyle(
                  color:         textColor,
                  fontSize:      11,
                  fontWeight:    FontWeight.w500,
                  letterSpacing: 0.5,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}