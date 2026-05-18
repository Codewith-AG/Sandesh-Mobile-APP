import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:phone_form_field/phone_form_field.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'services/local_db_service.dart';
import 'models/message_model.dart';
import 'theme/app_theme.dart';
import 'screens/splash_screen.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart' hide Message;

final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
    FlutterLocalNotificationsPlugin();

@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  // MUST be the very first call in a background isolate —
  // path_provider (used by SQLite) requires Flutter bindings to be ready.
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();

  final data = message.data;
  // The notification is already shown by the OS via the `notification` object
  // in the FCM payload. Here we just save the message to the local DB.
  if (data['id'] != null && data['id']!.isNotEmpty) {
    try {
      await LocalDbService().database; // ensure DB is open
      final msg = Message(
        id: data['id']!,
        senderUsername: data['sender_username'] ?? '',
        receiverUsername: data['receiver_username'] ?? '',
        text: data['text'],
        isMe: false,
        timestamp: int.tryParse(data['timestamp'] ?? '') ??
            DateTime.now().millisecondsSinceEpoch,
      );
      await LocalDbService().insertMessage(msg);
    } catch (e) {
      // DB errors in background must never crash the handler
      debugPrint('Background handler DB error: $e');
    }
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize Firebase and setup background handler
  await Firebase.initializeApp();
  FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);

  // Load environment variables
  await dotenv.load(fileName: ".env");

  // Initialize Supabase
  await Supabase.initialize(
    url: dotenv.env['SUPABASE_URL']!,
    anonKey: dotenv.env['SUPABASE_ANON_KEY']!,
  );

  // Initialize Local SQLite Database
  await LocalDbService().database;

  // Initialize Local Notifications
  const AndroidInitializationSettings initializationSettingsAndroid =
      AndroidInitializationSettings('@mipmap/ic_launcher');
  const InitializationSettings initializationSettings = InitializationSettings(
    android: initializationSettingsAndroid,
  );
  await flutterLocalNotificationsPlugin.initialize(
    settings: initializationSettings,
  );

  await flutterLocalNotificationsPlugin
      .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(const AndroidNotificationChannel(
        'messages_channel',
        'Messages Notifications',
        description: 'This channel is used for chat message notifications.',
        importance: Importance.max,
      ));

  // Request notification permission on Android 13+ (API 33+)
  // On older Android versions this is a no-op — permission is granted by default.
  final notifStatus = await Permission.notification.status;
  if (!notifStatus.isGranted) {
    await Permission.notification.request();
  }

  runApp(const SandeshApp());
}

class SandeshApp extends StatelessWidget {
  const SandeshApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Sandesh',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme,
      localizationsDelegates: [
        ...PhoneFieldLocalization.delegates,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [
        Locale('en'),
      ],
      home: const SplashScreen(),
    );
  }
}
