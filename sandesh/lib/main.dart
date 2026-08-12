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
import 'services/supabase_broadcast_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart' hide Message;
import 'services/update_service.dart';
import 'services/update_preferences.dart';
import 'screens/update_screen.dart';
import 'widgets/update_dialog.dart';

final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
    FlutterLocalNotificationsPlugin();

@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();

  final data = message.data;
  // Call signals — do NOT save to DB.
  if (data['type'] == 'call' || data['msg_type'] == 'call_invite') return;

  // NOTE: We do NOT show a local notification here because the FCM payload
  // already includes a `notification` block that Android displays automatically
  // when the app is killed/background. Showing another one here would cause
  // duplicate notifications.

  // ── Save the message to the local DB so it appears when the app opens ──
  // FIX: also save message_type (FCM sends it as msg_type) so the bubble
  // renders correctly (image / video / document) when the chat opens.
  if (data['id'] != null && data['id']!.isNotEmpty) {
    try {
      await LocalDbService().database; // ensure DB is open

      // FCM sends the type as 'msg_type'; fall back to 'text' if absent
      final rawType = data['msg_type'] ?? data['message_type'] ?? 'text';
      // Ignore call-signal types — they should never be stored
      if (rawType == 'call_invite' ||
          rawType == 'call_accepted' ||
          rawType == 'call_rejected' ||
          rawType == 'call_ended') {
        return;
      }

      final msg = Message(
        id: data['id']!,
        senderUsername: data['sender_username'] ?? '',
        receiverUsername: data['receiver_username'] ?? '',
        text: data['text'],
        mediaUrl: data['media_url'],
        fileName: data['file_name'],
        messageType: MessageTypeX.fromString(rawType),
        isMe: false,
        timestamp: int.tryParse(data['timestamp'] ?? '') ??
            DateTime.now().millisecondsSinceEpoch,
      );
      await LocalDbService().insertMessage(msg);
    } catch (e) {
      debugPrint('Background handler DB error: $e');
    }
  }
}

final ValueNotifier<ThemeMode> themeNotifier = ValueNotifier(ThemeMode.light);

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  final prefs = await SharedPreferences.getInstance();
  final isDark = prefs.getBool('isDarkMode') ?? false;
  themeNotifier.value = isDark ? ThemeMode.dark : ThemeMode.light;

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

  // ── Eager FCM token sync — runs at every cold start so the token is always
  //    fresh in Supabase before any peer tries to send a message. This is the
  //    critical fix for the "no notification when app is killed" bug.
  _eagerSyncFcmToken();

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

/// Eagerly sync the FCM token to Supabase at every cold start.
/// This runs fire-and-forget (not awaited) so it never delays app launch.
/// It is the critical fix for messages not being delivered when the app was
/// killed: FCM tokens rotate silently, so we must refresh on every start.
Future<void> _eagerSyncFcmToken() async {
  try {
    final supabase = Supabase.instance.client;
    final authUser = supabase.auth.currentUser;
    if (authUser == null) return; // Not logged in — nothing to sync

    // Retry up to 5 times with 2s gaps (FCM token is often null on cold start)
    const maxAttempts = 5;
    for (int attempt = 1; attempt <= maxAttempts; attempt++) {
      final token = await FirebaseMessaging.instance.getToken();
      if (token != null && token.isNotEmpty) {
        await supabase
            .from('profiles')
            .update({'fcm_token': token})
            .eq('id', authUser.id);
        debugPrint('[main] Eager FCM token synced on attempt $attempt');
        return;
      }
      if (attempt < maxAttempts) {
        await Future.delayed(const Duration(seconds: 2));
      }
    }
    debugPrint('[main] Eager FCM token sync: token still null after $maxAttempts attempts');
  } catch (e) {
    debugPrint('[main] Eager FCM token sync error: $e');
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

  // CRITICAL FIX: Ensure SupabaseBroadcastService is FULLY initialized before
  // opening ChatScreen. Without this, messages sent from the notification-opened
  // ChatScreen won't be delivered because the Realtime channel isn't connected.
  // We must await initialize() so the service is ready before navigating.
  final sbs = SupabaseBroadcastService();
  sbs.initialize(myUsername);
  CallService().initialize(myUsername);

  // Subscribe to the room for this specific sender so outgoing messages
  // from ChatScreen can be received by User 1 via the Realtime channel.
  sbs.subscribeToRoom(sender);

  // Also subscribe to all other contact rooms so we don't miss other messages
  // while this chat is open (runs fire-and-forget, no need to await).
  sbs.subscribeToAllContactRooms();

  // WhatsApp-style: look up the saved contact name from the phone contacts
  // so the chat header shows "Mom" instead of "+919876543210"
  final displayName = await LocalDbService().getContactDisplayName(sender);

  navigatorKey.currentState?.push(
    MaterialPageRoute<void>(
      builder: (_) => ChatScreen(
        myUsername: myUsername,
        receiverUsername: sender,
        receiverDisplayName: displayName,
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

    // ── Self-update check (fire-and-forget, respects 6-hour cache) ──
    _initUpdateCheck();

    // ── Request permissions safely after UI is rendering ──
    _requestPermissions();
  }

  Future<void> _requestPermissions() async {
    final notifStatus = await Permission.notification.status;
    if (!notifStatus.isGranted) {
      await Permission.notification.request();
    }
    await FirebaseMessaging.instance.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );
  }

  /// Check for app updates after a delay (avoids splash screen interference).
  Future<void> _initUpdateCheck() async {
    // Delay to avoid interfering with splash screen navigation
    await Future.delayed(const Duration(seconds: 5));
    if (!mounted) return;

    try {
      final result = await UpdateService().checkForUpdate();
      if (result != UpdateCheckResult.updateAvailable) return;
      if (!mounted) return;

      final update = UpdateService().availableUpdate;
      if (update == null) return;

      final prefs = UpdatePreferences();
      final autoUpdate = await prefs.autoUpdateEnabled;

      if (autoUpdate) {
        // Auto-update: download and install in background
        UpdateService().performAutoUpdate();
      } else {
        // Manual mode: show dialog if not previously dismissed for this version
        final dismissed = await prefs.dismissedVersionCode;
        if (dismissed == update.versionCode) return;
        if (!mounted) return;

        showDialog(
          context: navigatorKey.currentContext ?? context,
          builder: (_) => UpdateAvailableDialog(
            updateInfo: update,
            onUpdate: () {
              Navigator.pop(navigatorKey.currentContext ?? context);
              navigatorKey.currentState?.push(
                MaterialPageRoute(builder: (_) => const UpdateScreen()),
              );
            },
            onLater: () {
              prefs.setDismissedVersion(update.versionCode);
              Navigator.pop(navigatorKey.currentContext ?? context);
            },
          ),
        );
      }
    } catch (e) {
      debugPrint('[main] Update check error: $e');
    }
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
        final supabase = Supabase.instance.client;
        final authUser = supabase.auth.currentUser;
        if (authUser != null) {
          await supabase
              .from('profiles')
              .update({'fcm_token': token})
              .eq('id', authUser.id);
          debugPrint('FCM token refreshed and saved (by auth ID)');
        }
      } catch (e) {
        debugPrint('Token refresh save failed: $e');
      }
    });
  }

  void _routeFromFcm(RemoteMessage message) {
    final data = message.data;
    // Use unawaited — we fire the async routing task without blocking the
    // FCM handler (which is sync). The routing itself is fully awaited internally.
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
    // Presence is now handled by SupabaseBroadcastService
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeNotifier,
      builder: (context, currentMode, _) {
        return MaterialApp(
          title: 'Sandesh',
          debugShowCheckedModeBanner: false,
          navigatorKey: navigatorKey,
          theme: AppTheme.lightTheme,
          darkTheme: AppTheme.darkTheme,
          themeMode: currentMode,
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
      },
    );
  }
}
