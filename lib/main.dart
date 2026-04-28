import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import 'app_state.dart';
import 'notification_center.dart';
import 'notification_guard.dart';
import 'welcome_screen.dart';
import 'travel_notification_handler.dart';

Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  // La Cloud Function ya guarda el mensaje en background_messages con acceso de admin.
  // No se necesita escribir a Firestore desde aquí.
  await Firebase.initializeApp();
}

bool travelDialogActive = false;
String? lastTravelIdHandled;


void handleTravelNotification(String travelId, BuildContext context, String? phoneNumber) {
  if (travelId.isEmpty) return;
  if (!NotificationGuard.tryAdd(travelId)) return;
  showTravelRequestDialog(context, travelId, phoneNumber);
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();

  // Inicializar el Foreground Service antes de runApp
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

  // Registrar handler para procesar notificaciones pendientes desde notification_center
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

  // Ejecutar la app dentro de RootApp que registra el listener de authStateChanges
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
    // Escuchar cambios de autenticación y navegar usando navigatorKey cuando sea necesario.
    _authSub = FirebaseAuth.instance.authStateChanges().listen((user) {
      // Intentar navegar, esperando brevemente si navigator aún no está listo
      Future<void> attemptNavigate() async {
        for (var i = 0; i < 10; i++) {
          final nav = navigatorKey.currentState;
          if (nav != null) {
            try {
              if (user == null) {
                nav.pushAndRemoveUntil(MaterialPageRoute(builder: (_) => const PhoneLoginScreen()), (r) => false);
              } else {
                nav.pushAndRemoveUntil(MaterialPageRoute(builder: (_) => WelcomeScreen(phoneNumber: user.phoneNumber ?? '')), (r) => false);
              }
            } catch (_) {}
            return;
          }
          // esperar 100ms antes de reintentar
          await Future.delayed(const Duration(milliseconds: 100));
        }
        // Si nunca llegó el navigator, no hacemos nada (stream seguirá activo)
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
  Widget build(BuildContext context) {
    return const MyApp();
  }
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return WithForegroundTask(
      child: MaterialApp(
      title: 'Login Teléfono',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
      ),
      navigatorKey: navigatorKey,
      // Verificar estado de autenticación al iniciar la app.
      // Si ya existe un usuario autenticado, navegamos directamente a MainTabsScreen
      // Esto evita que el usuario tenga que volver a ingresar el código SMS cada vez que
      // la app se reinicie.
      home: StreamBuilder<User?>(
        stream: FirebaseAuth.instance.authStateChanges(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Scaffold(body: Center(child: CircularProgressIndicator()));
          }
          final user = snapshot.data;
          if (user == null) {
            return const PhoneLoginScreen();
          }
          // Usuario autenticado: ir a la pantalla principal y pasar el número si está disponible
          // Mostrar pantalla de bienvenida antes de cargar las pestañas principales.
          return WelcomeScreen(phoneNumber: user.phoneNumber ?? '');
        },
      ),
    ), // WithForegroundTask
    );
  }
}

class PhoneLoginScreen extends StatefulWidget {
  const PhoneLoginScreen({super.key});

  @override
  State<PhoneLoginScreen> createState() => _PhoneLoginScreenState();
}

class _PhoneLoginScreenState extends State<PhoneLoginScreen> {
  final TextEditingController _phoneController = TextEditingController();
  final TextEditingController _smsController = TextEditingController();
  String? _verificationId;
  bool _codeSent = false;
  String _status = '';

  Future<void> _verifyPhone() async {
    setState(() {
      _status = 'Enviando código...';
    });
    await FirebaseAuth.instance.verifyPhoneNumber(
      phoneNumber: _phoneController.text.trim(),
      verificationCompleted: (PhoneAuthCredential credential) async {
        await FirebaseAuth.instance.signInWithCredential(credential);
        setState(() {
          _status = 'Autenticado automáticamente.';
        });
      },
      verificationFailed: (FirebaseAuthException e) {
        setState(() {
          _status = 'Error: ${e.message}';
        });
      },
      codeSent: (String verificationId, int? resendToken) {
        setState(() {
          _verificationId = verificationId;
          _codeSent = true;
          _status = 'Código enviado. Ingresa el SMS.';
        });
      },
      codeAutoRetrievalTimeout: (String verificationId) {
        setState(() {
          _verificationId = verificationId;
        });
      },
    );
  }

  Future<void> _signInWithSms() async {
    if (_verificationId != null) {
      try {
        final credential = PhoneAuthProvider.credential(
          verificationId: _verificationId!,
          smsCode: _smsController.text.trim(),
        );
        UserCredential userCredential = await FirebaseAuth.instance.signInWithCredential(credential);
        final user = userCredential.user;
        if (user != null) {
          final userDoc = FirebaseFirestore.instance.collection('drivers').doc(user.uid);
          final docSnapshot = await userDoc.get();
          if (!docSnapshot.exists) {
            await userDoc.set({
              'phone': user.phoneNumber,
              'createdAt': FieldValue.serverTimestamp(),
            });
          }
          final fcmToken = await FirebaseMessaging.instance.getToken();
          if (fcmToken != null) {
            await userDoc.update({'fcmToken': fcmToken});
          }
          setState(() {
            _status = '¡Login exitoso!';
          });
          // Navegar a la pantalla de bienvenida que luego dirigirá a las pestañas.
          Navigator.of(context).pushReplacement(
            MaterialPageRoute(
              builder: (context) => WelcomeScreen(phoneNumber: user.phoneNumber ?? ''),
            ),
          );
        }
      } catch (e) {
        setState(() {
          _status = 'Código incorrecto.';
        });
      }
    }
  }

  @override
  void initState() {
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // Permitir que el fondo se muestre detrás de la AppBar
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text('Login por Teléfono'),
      ),
      body: Container(
        // Asegurar que el Container ocupe toda la pantalla
        constraints: const BoxConstraints.expand(),
        // Fondo con la imagen proporcionada (assets/fondo.jpeg)
        decoration: const BoxDecoration(
          image: DecorationImage(
            image: AssetImage('assets/fondo3.jpeg'),
            fit: BoxFit.cover,
          ),
        ),
        // Centrar verticalmente el contenido visible dentro de SafeArea.
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.all(30.0),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    TextField(
                      controller: _phoneController,
                      keyboardType: TextInputType.phone,
                      decoration: const InputDecoration(
                        labelText: 'Número de teléfono (+52...)',
                        filled: true,
                        fillColor: Colors.white70,
                      ),
                    ),
                    if (_codeSent) const SizedBox(height: 12),
                    if (_codeSent)
                      TextField(
                        controller: _smsController,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: 'Código SMS',
                          filled: true,
                          fillColor: Colors.white70,
                        ),
                      ),
                    if (_codeSent)
                      TextButton(
                        onPressed: () {
                          setState(() {
                            _codeSent = false;
                            _smsController.clear();
                            _verificationId = null;
                            _status = '';
                          });
                        },
                        child: const Text('Cancelar', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18.0),),
                      ),
                    const SizedBox(height: 16),
                    ElevatedButton(
                      onPressed: _codeSent ? _signInWithSms : _verifyPhone,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.blue[600],
                      ),
                      child: Text(_codeSent ? 'Verificar código' : 'Enviar código', style: TextStyle(color: Colors.white, fontSize: 18.0, fontWeight: FontWeight.bold))
                    ),
                    const SizedBox(height: 16),
                    Text(_status, style: const TextStyle(color: Colors.red)),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// Custom slide action simple y robusto
class CustomSlideAction extends StatefulWidget {
  final Future<void> Function()? onSubmit;
  final String text;
  final TextStyle? textStyle;
  final Color outerColor;
  final Color innerColor;
  final double height;
  final Widget? sliderButtonIcon;

  const CustomSlideAction({
    Key? key,
    this.onSubmit,
    this.text = 'Desliza para aceptar',
    this.textStyle,
    this.outerColor = Colors.green,
    this.innerColor = Colors.white,
    this.height = 60,
    this.sliderButtonIcon,
  }) : super(key: key);

  @override
  State<CustomSlideAction> createState() => _CustomSlideActionState();
}

class _CustomSlideActionState extends State<CustomSlideAction> with SingleTickerProviderStateMixin {
  double _dx = 0.0;
  double _maxDx = 1.0;
  bool _submitted = false;
  bool _locked = false;
  late AnimationController _animController;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(vsync: this, duration: const Duration(milliseconds: 300));
  }

  @override
  void dispose() {
    _animController.dispose();
    super.dispose();
  }

  void _animateTo(double target) {
    final start = _dx;
    _animController.reset();
    final animation = Tween<double>(begin: start, end: target).animate(CurvedAnimation(parent: _animController, curve: Curves.easeOut));
    animation.addListener(() {
      if (mounted) setState(() => _dx = animation.value);
    });
    _animController.forward();
  }

  Future<void> _onPanEnd() async {
    if (_maxDx <= 0) return;
    final progress = _dx / _maxDx;
    if (progress >= 0.8 && widget.onSubmit != null && !_submitted && !_locked) {
      _locked = true;
      _animateTo(_maxDx);
      setState(() => _submitted = true);
      try {
        await widget.onSubmit?.call();
        if (mounted) await Future.delayed(const Duration(milliseconds: 300));
        if (mounted && Navigator.of(context).canPop()) Navigator.of(context).pop();
        travelDialogActive = false;
      } catch (_) {
        if (mounted) {
          _animateTo(0);
          setState(() {
            _submitted = false;
            _locked = false;
          });
        }
      }
    } else {
      _animateTo(0);
      setState(() => _submitted = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final totalWidth = constraints.maxWidth;
      final sliderSize = widget.height - 16;
      _maxDx = (totalWidth - sliderSize - 16).clamp(0.0, double.infinity);
      return Container(
        height: widget.height,
        decoration: BoxDecoration(color: widget.outerColor, borderRadius: BorderRadius.circular(52)),
        child: Stack(
          alignment: Alignment.centerLeft,
          children: [
            Center(
              child: Opacity(
                opacity: _submitted ? 0.0 : 1.0,
                child: Text(widget.text, style: widget.textStyle ?? const TextStyle(color: Colors.white, fontSize: 18)),
              ),
            ),
            Positioned(
              left: 8 + _dx,
              child: GestureDetector(
                onHorizontalDragUpdate: (details) {
                  if (_locked || _submitted) return;
                  setState(() {
                    _dx = (_dx + details.delta.dx).clamp(0.0, _maxDx);
                  });
                },
                onHorizontalDragEnd: (_) async => await _onPanEnd(),
                child: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(color: widget.innerColor, borderRadius: BorderRadius.circular(52)),
                  child: SizedBox(
                    height: sliderSize,
                    width: sliderSize,
                    child: Center(
                      child: _submitted ? Icon(Icons.check, color: widget.outerColor) : (widget.sliderButtonIcon ?? Icon(Icons.arrow_forward, color: widget.outerColor)),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    });
  }
}

// Widget local para mostrar el mapa en el diálogo
class MapPreview extends StatefulWidget {
  final LatLng? origin;
  final LatLng? destination;
  const MapPreview({Key? key, this.origin, this.destination}) : super(key: key);

  @override
  State<MapPreview> createState() => _MapPreviewState();
}

class _MapPreviewState extends State<MapPreview> {
  GoogleMapController? _controller;
  final Set<Marker> _markers = {};
  final Set<Polyline> _polylines = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _setup());
  }

  void _setup() async {
    _markers.clear();
    if (widget.origin != null) {
      _markers.add(Marker(markerId: const MarkerId('origin'), position: widget.origin!, infoWindow: const InfoWindow(title: 'Origen')));
    }
    if (widget.destination != null) {
      _markers.add(Marker(markerId: const MarkerId('destination'), position: widget.destination!, infoWindow: const InfoWindow(title: 'Destino')));
    }
    _polylines.clear();
    if (widget.origin != null && widget.destination != null) {
      _polylines.add(Polyline(polylineId: const PolylineId('route'), color: Colors.blue, width: 5, points: [widget.origin!, widget.destination!]));
      // Ajustar cámara
      final south = LatLng(
        widget.origin!.latitude < widget.destination!.latitude ? widget.origin!.latitude : widget.destination!.latitude,
        widget.origin!.longitude < widget.destination!.longitude ? widget.origin!.longitude : widget.destination!.longitude,
      );
      final north = LatLng(
        widget.origin!.latitude > widget.destination!.latitude ? widget.origin!.latitude : widget.destination!.latitude,
        widget.origin!.longitude > widget.destination!.longitude ? widget.origin!.longitude : widget.destination!.longitude,
      );
      final bounds = LatLngBounds(southwest: south, northeast: north);
      await Future.delayed(const Duration(milliseconds: 200));
      try {
        await _controller?.animateCamera(CameraUpdate.newLatLngBounds(bounds, 40));
      } catch (_) {}
    } else if (widget.origin != null) {
      await Future.delayed(const Duration(milliseconds: 100));
      _controller?.animateCamera(CameraUpdate.newLatLngZoom(widget.origin!, 15));
    } else if (widget.destination != null) {
      await Future.delayed(const Duration(milliseconds: 100));
      _controller?.animateCamera(CameraUpdate.newLatLngZoom(widget.destination!, 15));
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final initial = widget.origin ?? widget.destination ?? const LatLng(0, 0);
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: GoogleMap(
        initialCameraPosition: CameraPosition(target: initial, zoom: 12),
        markers: _markers,
        polylines: _polylines,
        myLocationEnabled: false,
        zoomControlsEnabled: false,
        liteModeEnabled: false,
        onMapCreated: (c) {
          _controller = c;
          _setup();
        },
      ),
    );
  }
}
