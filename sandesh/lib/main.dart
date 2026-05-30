import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:phone_form_field/phone_form_field.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'services/local_db_service.dart';
import 'models/message_model.dart' hide MessageType;
import 'theme/app_theme.dart';
import 'screens/splash_screen.dart';
import 'screens/chat_screen.dart';
import 'screens/incoming_call_screen.dart';
import 'navigation/navigator_key.dart';
import 'services/call_service.dart';
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
  // Call signals — do NOT save to DB, do not show notification.
  if (data['type'] == 'call' || data['msg_type'] == 'call_invite') return;

  // ── Step 1: Show a local notification (app is killed/background) ──────────
  // Android does NOT auto-display a notification when the app is killed unless
  // the FCM payload contains a server-side `notification` block. Since this app
  // uses data-only payloads, we must show the notification ourselves here.
  final sender = data['sender_username'] ?? 'New message';
  final text   = data['text'];
  final title  = sender;
  final body   = (text != null && text.isNotEmpty) ? text : 'Sent an attachment';

  try {
    final plugin = FlutterLocalNotificationsPlugin();

    // Initialise the plugin in this background isolate
    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    await plugin.initialize(
      settings: const InitializationSettings(android: androidInit),
    );

    // Ensure the notification channel exists (safe to call multiple times)
    await plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(const AndroidNotificationChannel(
          'messages_channel',
          'Messages Notifications',
          description: 'This channel is used for chat message notifications.',
          importance: Importance.max,
        ));

    await plugin.show(
      id: DateTime.now().millisecondsSinceEpoch.remainder(1 << 31),
      title: title,
      body: body,
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          'messages_channel',
          'Messages',
          importance: Importance.max,
          priority: Priority.high,
          showWhen: true,
        ),
      ),
      payload: jsonEncode({
        'type': 'message',
        'sender_username': sender,
      }),
    );
  } catch (e) {
    debugPrint('Background notification error: $e');
  }

  // ── Step 2: Save the message to the local DB ───────────────────────────────
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

  // Initialize Local Notifications. The onDidReceiveNotificationResponse callback
  // routes the user to the right chat / call screen when they tap a notification
  // that was shown by the app (foreground or via background-handler).
  const AndroidInitializationSettings initializationSettingsAndroid =
      AndroidInitializationSettings('@mipmap/ic_launcher');
  const InitializationSettings initializationSettings = InitializationSettings(
    android: initializationSettingsAndroid,
  );
  await flutterLocalNotificationsPlugin.initialize(
    settings: initializationSettings,
    onDidReceiveNotificationResponse: _onLocalNotificationTap,
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
  // Firebase's own request — works on both iOS and Android 13+
  await FirebaseMessaging.instance.requestPermission(
    alert: true,
    badge: true,
    sound: true,
  );

  runApp(const SandeshApp());
}

// Routes a local-notification tap to the correct screen.
Future<void> _onLocalNotificationTap(NotificationResponse response) async {
  final payload = response.payload;
  if (payload == null || payload.isEmpty) return;
  try {
    final data = jsonDecode(payload) as Map<String, dynamic>;
    await _routeFromNotificationData(data.map((k, v) => MapEntry(k, v.toString())));
  } catch (e) {
    debugPrint('Local notification payload parse error: $e');
  }
}

// Single routing function used by FCM open handlers and local notification taps.
// Decides whether the data represents a call invite or a normal chat message.
Future<void> _routeFromNotificationData(Map<String, String> data) async {
  final type = data['type'] ?? '';
  final messageType = data['msg_type'] ?? data['message_type'] ?? '';

  // ── Incoming call invite ───────────────────────────────────────────────────
  if (type == 'call' || messageType == 'call_invite') {
    final event = CallEvent(
      type: 'call_invite',
      callerUsername:
          data['callerUsername'] ?? data['sender_username'] ?? '',
      receiverUsername:
          data['receiverUsername'] ?? data['receiver_username'] ?? '',
      channelName: data['channelName'] ?? '',
      callType: data['callType'] ?? 'audio',
    );
    if (event.channelName.isEmpty || event.callerUsername.isEmpty) return;
    // Route through CallService so dedup logic guards against duplicate
    // IncomingCallScreens (FCM tap + Realtime catch-up).
    CallService().notifyIncomingFromFcm(event);
    return;
  }

  // ── Chat message — open the conversation with the sender ──────────────────
  final sender = data['sender_username'] ?? '';
  if (sender.isEmpty) return;
  final prefs = await SharedPreferences.getInstance();
  final myUsername = prefs.getString('username') ?? '';
  if (myUsername.isEmpty) return;
  navigatorKey.currentState?.push(
    MaterialPageRoute<void>(
      builder: (_) => ChatScreen(
        myUsername: myUsername,
        receiverUsername: sender,
      ),
    ),
  );
}

class SandeshApp extends StatefulWidget {
  const SandeshApp({super.key});

  @override
  State<SandeshApp> createState() => _SandeshAppState();
}

class _SandeshAppState extends State<SandeshApp> with WidgetsBindingObserver {
  StreamSubscription<CallEvent>? _incomingCallSub;
  StreamSubscription<RemoteMessage>? _foregroundFcmSub;
  StreamSubscription<RemoteMessage>? _openedAppFcmSub;
  StreamSubscription<String>? _tokenRefreshSub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Set online on initial startup
    _updatePresence(true);
    // Listen for incoming calls from ANY screen — show IncomingCallScreen globally
    _incomingCallSub = CallService().incomingCallStream.listen((event) {
      if (CallService().isInCall) return;
      navigatorKey.currentState?.push(
        MaterialPageRoute<void>(
          builder: (_) => IncomingCallScreen(event: event),
        ),
      );
    });

    // ── FCM handlers ────────────────────────────────────────────────────────
    _initFcmHandlers();
  }

  Future<void> _initFcmHandlers() async {
    // Killed-app launch via notification tap — must wait until SplashScreen has
    // finished its pushReplacement to HomeScreen/LoginScreen (~2.5s + transition).
    // Otherwise SplashScreen's pushReplacement would pop our IncomingCallScreen
    // off the top of the stack.
    final initial = await FirebaseMessaging.instance.getInitialMessage();
    if (initial != null) {
      Future.delayed(const Duration(milliseconds: 3500), () {
        if (!mounted) return;
        _routeFromFcm(initial);
      });
    }

    // Background → notification tap brings app to foreground
    _openedAppFcmSub =
        FirebaseMessaging.onMessageOpenedApp.listen(_routeFromFcm);

    // Foreground push — Android does NOT show notifications automatically when
    // the app is in foreground, so handle these manually.
    _foregroundFcmSub = FirebaseMessaging.onMessage.listen(_handleForegroundFcm);

    // Token rotation — re-save when FCM rotates the token
    _tokenRefreshSub =
        FirebaseMessaging.instance.onTokenRefresh.listen((token) async {
      try {
        final prefs = await SharedPreferences.getInstance();
        final myUsername = prefs.getString('username');
        if (myUsername != null && myUsername.isNotEmpty) {
          await Supabase.instance.client
              .from('profiles')
              .update({'fcm_token': token})
              .eq('username', myUsername);
          debugPrint('FCM token refreshed and saved');
        }
      } catch (e) {
        debugPrint('Token refresh save failed: $e');
      }
    });
  }

  void _routeFromFcm(RemoteMessage message) {
    final data = message.data;
    _routeFromNotificationData(data.map((k, v) => MapEntry(k, v.toString())));
  }

  void _handleForegroundFcm(RemoteMessage message) {
    final data = message.data;

    // ── Call invite — let CallService dedup vs the Realtime path ──────────
    if (data['type'] == 'call' || data['msg_type'] == 'call_invite') {
      final event = CallEvent(
        type: 'call_invite',
        callerUsername:
            data['callerUsername'] ?? data['sender_username'] ?? '',
        receiverUsername:
            data['receiverUsername'] ?? data['receiver_username'] ?? '',
        channelName: data['channelName'] ?? '',
        callType: data['callType'] ?? 'audio',
      );
      if (event.channelName.isEmpty || event.callerUsername.isEmpty) return;
      CallService().notifyIncomingFromFcm(event);
      return;
    }

    // ── Chat message — when in foreground, Supabase Realtime is the primary
    //    delivery path. The realtime listener already shows a local
    //    notification when the user isn't on the sender's chat screen, so we
    //    skip showing a duplicate here to avoid two pop-ups for one message.
  }

  @override
  void dispose() {
    _incomingCallSub?.cancel();
    _foregroundFcmSub?.cancel();
    _openedAppFcmSub?.cancel();
    _tokenRefreshSub?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _updatePresence(true);
    } else if (state == AppLifecycleState.paused || state == AppLifecycleState.detached || state == AppLifecycleState.inactive) {
      _updatePresence(false);
    }
  }

  Future<void> _updatePresence(bool isOnline) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final username = prefs.getString('username');
      if (username != null && username.isNotEmpty) {
        await Supabase.instance.client.from('profiles').update({
          'is_online': isOnline,
          'last_seen': DateTime.now().toUtc().toIso8601String(),
        }).eq('username', username);
      }
    } catch (e) {
      debugPrint('Lifecycle presence update error: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Sandesh',
      debugShowCheckedModeBanner: false,
      navigatorKey: navigatorKey,
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
