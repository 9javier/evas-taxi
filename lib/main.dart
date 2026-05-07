import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'app_state.dart';
import 'login_screen.dart';
import 'notification_center.dart';
import 'notification_guard.dart';
import 'welcome_screen.dart';
import 'travel_notification_handler.dart';

const AndroidNotificationChannel _travelChannel = AndroidNotificationChannel(
  'new_travel_channel',
  'Nuevos viajes',
  description: 'Alertas de nuevas solicitudes de viaje',
  importance: Importance.max,
  playSound: true,
  enableVibration: true,
);

@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  // Sin-op intencional: FCM ya presenta la notificación del sistema.
}

void handleTravelNotification(String travelId, BuildContext context, String? phoneNumber) {
  if (travelId.isEmpty) return;
  if (!NotificationGuard.tryAdd(travelId)) return;
  showTravelRequestDialog(context, travelId, phoneNumber);
}

// Variable global de diagnóstico — visible en pantalla si algo falla al arrancar.
String debugLog = "Iniciando...";

Future<void> main() async {
  // Capturar errores no controlados del framework Flutter.
  FlutterError.onError = (details) {
    debugLog += "\n❌ Error Flutter: ${details.exception}";
  };

  // Mostrar pantalla de carga inmediatamente para confirmar que el app arranca.
  runApp(MaterialApp(
    debugShowCheckedModeBanner: false,
    home: Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: const [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text("Cargando Eva's Taxi..."),
          ],
        ),
      ),
    ),
  ));

  try {
    debugLog += "\n1. Asegurando bindings...";
    WidgetsFlutterBinding.ensureInitialized();

    debugLog += "\n2. Inicializando Firebase...";
    await Firebase.initializeApp();

    debugLog += "\n3. Firebase OK. Configurando ForegroundTask...";
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

    debugLog += "\n4. Configurando notificaciones locales...";
    final localNotif = FlutterLocalNotificationsPlugin();
    await localNotif.initialize(
      const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        iOS: DarwinInitializationSettings(),
      ),
    );
    await localNotif
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(_travelChannel);

    debugLog += "\n5. Configurando FCM...";
    FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);

    await FirebaseMessaging.instance.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );

    await FirebaseMessaging.instance.setForegroundNotificationPresentationOptions(
      alert: false,
      badge: false,
      sound: false,
    );

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
      } else if (type == 'CHAT') {
        chatNewMessageNotifier.value = true;
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
      } else if (type == 'CHAT') {
        chatNewMessageNotifier.value = true;
      }
    });

    debugLog += "\n6. Lanzando app principal...";
    runApp(const RootApp());

  } catch (e, stack) {
    debugLog += "\n🔥 ERROR CRÍTICO: $e";
    runApp(MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: Colors.white,
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Text(
              "LOG DE ERROR:\n$debugLog\n\nSTACK:\n$stack",
              style: const TextStyle(color: Colors.red, fontSize: 12),
            ),
          ),
        ),
      ),
    ));
  }
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
      if (skipAuthNavigation) return;
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
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF6366F1)),
        ),
        navigatorKey: navigatorKey,
        home: StreamBuilder<User?>(
          stream: FirebaseAuth.instance.authStateChanges(),
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const _SplashScreen();
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

class _SplashScreen extends StatelessWidget {
  const _SplashScreen();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: const [
          Image(
            image: AssetImage('assets/splash.png'),
            fit: BoxFit.cover,
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: EdgeInsets.only(bottom: 52),
              child: CircularProgressIndicator(
                color: Colors.white,
                strokeWidth: 2.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
