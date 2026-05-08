import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'screens/home_screen.dart';

final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
    FlutterLocalNotificationsPlugin();

// const AndroidNotificationChannel _channel = AndroidNotificationChannel(
//   'security_channel',
//   'Security Alerts',
//   description: 'ESP32 security system alerts',
//   importance: Importance.max,
// );

@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
  showLocalNotification(
    message.notification?.title ?? 'Alert',
    message.notification?.body ?? '',
  );
}

void showLocalNotification(String title, String body) {
  flutterLocalNotificationsPlugin.show(
    0,
    title,
    body,
    const NotificationDetails(
      android: AndroidNotificationDetails(
        'security_channel',
        'Security Alerts',
        channelDescription: 'ESP32 security system alerts',
        importance: Importance.max,
        priority: Priority.high,
        playSound: true,
        enableVibration: true,
        icon: '@mipmap/ic_launcher',
      ),
    ),
  );
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();

  FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);

  const AndroidInitializationSettings androidSettings =
      AndroidInitializationSettings('@mipmap/ic_launcher');

  await flutterLocalNotificationsPlugin.initialize(
    const InitializationSettings(android: androidSettings),
  );

  

  runApp(const ChorAscheApp());
}

class ChorAscheApp extends StatelessWidget {
  const ChorAscheApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Chor Asche',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1A1A2E),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}