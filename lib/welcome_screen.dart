import 'package:flutter/material.dart';
import 'dart:ui' as ui;
import 'package:flutter/services.dart' show rootBundle;
import 'package:firebase_messaging/firebase_messaging.dart';

import 'main_tabs_screen.dart';
import 'travel_notification_handler.dart';
import 'notification_guard.dart';
import 'notification_center.dart';
import 'permission_helper.dart';

class WelcomeScreen extends StatefulWidget {
  final String phoneNumber;
  const WelcomeScreen({Key? key, this.phoneNumber = ''}) : super(key: key);

  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen> {
  bool _ready = false;
  bool _error = false;
  String _status = 'Initializing...';

  // Solo manejamos getInitialMessage aquí (app terminada).
  // Los listeners onMessage y onMessageOpenedApp viven en main.dart para evitar duplicados.

  @override
  void initState() {
    super.initState();
    // Registrar listeners de notificaciones
    _setupNotificationListeners();
    // Ejecutar la inicialización después del primer frame para poder mostrar diálogos
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initialize();
      // Intentar procesar cualquier notificación pendiente que se haya encolado
      tryHandlePendingNotifications();
    });
  }

  void _setupNotificationListeners() {
    // Solo manejar el caso en que la app fue terminada y el usuario toca la notificación.
    // onMessage y onMessageOpenedApp ya están registrados en main.dart.
    FirebaseMessaging.instance.getInitialMessage().then((RemoteMessage? message) {
      if (message == null) return;
      try {
        final data = message.data;
        final type = data['type'] ?? '';
        if (type == 'NEW_TRAVEL') {
          final travelId = (data['travelId'] ?? data['travelID'] ?? data['travelid'])?.toString() ?? '';
          if (travelId.isEmpty) return;
          if (!NotificationGuard.tryAdd(travelId)) return;
          // Pequeña demora para asegurar que el contexto está listo
          Future.delayed(const Duration(milliseconds: 300), () {
            if (!mounted) return;
            showTravelRequestDialog(context, travelId, (data['phone'] ?? data['phoneNumber'])?.toString());
          });
        }
      } catch (_) {}
    });
  }

  @override
  void dispose() {
    super.dispose();
  }

  Future<void> _initialize() async {
    setState(() {
      _ready = false;
      _error = false;
      _status = 'Loading resources and settings...';
    });

    try {
      // Verificar internet y luego permisos de ubicación.
      // El delay evita el crash nativo de iOS cuando requestPermission() intenta
      // presentar un UIAlertController mientras la animación de navegación aún corre.
      await checkInternetAndShow(context);
      if (!mounted) return;
      await Future.delayed(const Duration(milliseconds: 600));
      if (!mounted) return;
      await checkAndRequestLocationPermission(context);
      if (!mounted) return;

      final tasks = <Future<void>>[];

      tasks.add(_precacheAssetImage('assets/car.jpg'));
      tasks.add(_warmupBitmapDescriptor('assets/passenger.png'));
      tasks.add(_warmupBitmapDescriptor('assets/arrow.png'));
      // Pequeño delay para suavizar la transición
      tasks.add(Future.delayed(const Duration(milliseconds: 1200)));

      await Future.wait(tasks);

      if (!mounted) return;
      setState(() {
        _ready = true;
        _status = 'Ready';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = true;
        _status = 'Error during initialization';
      });
    }
  }

  Future<void> _precacheAssetImage(String path) async {
    try {
      final image = Image.asset(path);
      await precacheImage(image.image, context);
    } catch (_) {
      // No fallar si el asset no existe; sólo optimización
    }
  }

  Future<void> _warmupBitmapDescriptor(String asset) async {
    try {
      final data = await rootBundle.load(asset);
      final bytes = data.buffer.asUint8List();
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      try {
        frame.image.dispose();
      } catch (_) {}
    } catch (_) {
      // Ignorar errores de warmup
    }
  }

  void _onContinue() {
    Navigator.of(context).pushReplacement(MaterialPageRoute(
      builder: (context) => MainTabsScreen(phoneNumber: widget.phoneNumber),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24.0),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 600, maxHeight: 600),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: Image.asset(
                          'assets/logo1.jpeg',
                          width: 240,
                          height: 240,
                          fit: BoxFit.contain,
                          // Mostrar un icono si por alguna razón el asset no se carga
                          errorBuilder: (context, error, stackTrace) {
                            return Container(
                              width: 240,
                              height: 240,
                              color: Colors.grey.shade200,
                              alignment: Alignment.center,
                              child: const Icon(Icons.broken_image, size: 72, color: Colors.grey),
                            );
                          },
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),
                    Text('Welcome', style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    Text(
                      widget.phoneNumber.isNotEmpty ? 'Signed in as ${widget.phoneNumber}' : 'Signed in',
                      style: theme.textTheme.bodyMedium,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 18),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        if (!_ready && !_error) const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                        const SizedBox(width: 12),
                        Text('Ready!', style: theme.textTheme.bodySmall),
                      ],
                    ),
                    const SizedBox(height: 12),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 18.0),
              child: SizedBox(
                width: double.infinity,
                height: 52,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)), backgroundColor: Colors.blue[600]),
                  onPressed: _ready ? _onContinue : null,
                  child: Text(_ready ? 'Continue' : 'Loading...', style: TextStyle(color: Colors.white, fontSize: 18.0, fontWeight: FontWeight.bold),),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
