import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter_animate/flutter_animate.dart';

class EventsScreen extends StatefulWidget {
  const EventsScreen({super.key});

  @override
  State<EventsScreen> createState() => _EventsScreenState();
}

class _EventsScreenState extends State<EventsScreen> {
  final DatabaseReference _db = FirebaseDatabase.instance.ref('events');
  List<Map<String, dynamic>> _events = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadEvents();
  }

  void _loadEvents() {
    _db.orderByKey().limitToLast(50).onValue.listen((event) {
      if (!mounted) return;
      final data = event.snapshot.value as Map<dynamic, dynamic>?;
      if (data != null) {
        final list = data.entries.map((e) {
          final val = e.value as Map<dynamic, dynamic>;
          return {
            'message':   val['message']   ?? '',
            'timestamp': val['timestamp'] ?? 0,
          };
        }).toList();

        // Sort newest first
        list.sort((a, b) =>
            (b['timestamp'] as int).compareTo(a['timestamp'] as int));

        setState(() {
          _events  = list.cast<Map<String, dynamic>>();
          _loading = false;
        });
      } else {
        setState(() => _loading = false);
      }
    });
  }

  String _formatTimestamp(int seconds) {
    final dt = DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
    return '${dt.day}/${dt.month}/${dt.year}  '
        '${dt.hour.toString().padLeft(2, '0')}:'
        '${dt.minute.toString().padLeft(2, '0')}:'
        '${dt.second.toString().padLeft(2, '0')}';
  }

  Color _eventColor(String message) {
    if (message.contains('ALARM'))   return Colors.red;
    if (message.contains('Motion'))  return Colors.orange;
    if (message.contains('armed'))   return const Color(0xFF00E676);
    if (message.contains('disarm'))  return Colors.blueGrey;
    return Colors.white54;
  }

  IconData _eventIcon(String message) {
    if (message.contains('ALARM'))   return Icons.warning_rounded;
    if (message.contains('Motion'))  return Icons.directions_run;
    if (message.contains('armed'))   return Icons.lock;
    if (message.contains('disarm'))  return Icons.lock_open;
    return Icons.info_outline;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F0F1A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0F0F1A),
        title: Text(
          'Alarm History',
          style: GoogleFonts.orbitron(
            color: Colors.white,
            fontWeight: FontWeight.bold,
          ),
        ),
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _events.isEmpty
              ? Center(
                  child: Text(
                    'No events yet',
                    style: GoogleFonts.orbitron(color: Colors.white38),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: _events.length,
                  itemBuilder: (context, index) {
                    final event   = _events[index];
                    final message = event['message'] as String;
                    final color   = _eventColor(message);
                    final icon    = _eventIcon(message);

                    return Container(
                      margin: const EdgeInsets.only(bottom: 12),
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1A1A2E),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: color.withOpacity(0.3)),
                      ),
                      child: Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: color.withOpacity(0.15),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Icon(icon, color: color, size: 20),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  message,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 13,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  _formatTimestamp(event['timestamp'] as int),
                                  style: const TextStyle(
                                    color: Colors.white38,
                                    fontSize: 11,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ).animate().fadeIn(
                          delay: Duration(milliseconds: index * 50),
                          duration: 400.ms,
                        );
                  },
                ),
    );
  }
}