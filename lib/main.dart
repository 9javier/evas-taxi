import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'app_state.dart';
import 'login_screen.dart';
import 'notification_center.dart';
import 'notification_guard.dart';
import 'welcome_screen.dart';
import 'travel_notification_handler.dart';

Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  // La Cloud Function ya guarda el mensaje en background_messages con acceso de admin.
  // No se necesita escribir a Firestore desde aquí.
  await Firebase.initializeApp();
}

void handleTravelNotification(String travelId, BuildContext context, String? phoneNumber) {
  if (travelId.isEmpty) return;
  if (!NotificationGuard.tryAdd(travelId)) return;
  showTravelRequestDialog(context, travelId, phoneNumber);
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();

  FlutterForegroundTask.init(
    androidNotificationOptions: AndroidNotificationOptions(
      channelId: 'eva_taxi_gps',
      channelName: "Eva's Taxi GPS",
      channelDescription: 'GPS activo mientras hay un viaje en curso.',
      onlyAlertOnce: true,
      showWhen: false,
    ),
    iosNotificationOptions: const IOSNotificationOptions(
      showNotification: false,
    ),
    foregroundTaskOptions: ForegroundTaskOptions(
      eventAction: ForegroundTaskEventAction.nothing(),
      autoRunOnBoot: false,
    ),
  );

  FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
  await FirebaseMessaging.instance.requestPermission();

  registerPendingHandler(handleTravelNotification);

  FirebaseMessaging.onMessage.listen((RemoteMessage message) {
    final data = message.data;
    final type = data['type'] ?? '';
    if (type == 'NEW_TRAVEL') {
      final travelId = (data['travelId'] ?? data['travelID'] ?? data['travelid'])?.toString() ?? '';
      final ctx = navigatorKey.currentContext;
      if (ctx != null) {
        handleTravelNotification(travelId, ctx, null);
      } else {
        addPendingNotification(travelId, null);
      }
    } else if (type == 'CANCELED_PASSENGER') {
      final travelId = (data['travelId'] ?? data['travelID'] ?? data['travelid'])?.toString() ?? '';
      playAlertSound();
      passengerCanceledNotifier.value = travelId;
    }
  });

  FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
    final data = message.data;
    final type = data['type'] ?? '';
    if (type == 'NEW_TRAVEL') {
      final travelId = (data['travelId'] ?? data['travelID'] ?? data['travelid'])?.toString() ?? '';
      final ctx = navigatorKey.currentContext;
      if (ctx != null) {
        handleTravelNotification(travelId, ctx, null);
      } else {
        addPendingNotification(travelId, null);
      }
    } else if (type == 'CANCELED_PASSENGER') {
      final travelId = (data['travelId'] ?? data['travelID'] ?? data['travelid'])?.toString() ?? '';
      playAlertSound();
      passengerCanceledNotifier.value = travelId;
    }
  });

  runApp(const RootApp());
}

class RootApp extends StatefulWidget {
  const RootApp({Key? key}) : super(key: key);

  @override
  State<RootApp> createState() => _RootAppState();
}

class _RootAppState extends State<RootApp> {
  late final StreamSubscription<User?> _authSub;

  @override
  void initState() {
    super.initState();
    _authSub = FirebaseAuth.instance.authStateChanges().listen((user) {
      Future<void> attemptNavigate() async {
        for (var i = 0; i < 10; i++) {
          final nav = navigatorKey.currentState;
          if (nav != null) {
            try {
              if (user == null) {
                nav.pushAndRemoveUntil(
                  MaterialPageRoute(builder: (_) => const DriverLoginScreen()),
                  (r) => false,
                );
              } else {
                nav.pushAndRemoveUntil(
                  MaterialPageRoute(builder: (_) => WelcomeScreen(phoneNumber: user.phoneNumber ?? '')),
                  (r) => false,
                );
              }
            } catch (_) {}
            return;
          }
          await Future.delayed(const Duration(milliseconds: 100));
        }
      }
      attemptNavigate();
    });
  }

  @override
  void dispose() {
    _authSub.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const MyApp();
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return WithForegroundTask(
      child: MaterialApp(
        title: "Eva's Taxi — Driver",
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF6366F1)),
        ),
        navigatorKey: navigatorKey,
        home: StreamBuilder<User?>(
          stream: FirebaseAuth.instance.authStateChanges(),
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Scaffold(
                backgroundColor: Color(0xFF0D0D14),
                body: Center(child: CircularProgressIndicator(color: Color(0xFF6366F1))),
              );
            }
            final user = snapshot.data;
            if (user == null) return const DriverLoginScreen();
            return WelcomeScreen(phoneNumber: user.phoneNumber ?? '');
          },
        ),
      ),
    );
  }
}
