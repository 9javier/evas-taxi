import 'dart:async';

import 'package:flutter/material.dart';
import 'dart:ui' as ui;
import 'package:flutter/services.dart' show rootBundle;
import 'package:geolocator/geolocator.dart';

import 'main_tabs_screen.dart';

class WelcomeScreen extends StatefulWidget {
  final String phoneNumber;
  const WelcomeScreen({Key? key, this.phoneNumber = ''}) : super(key: key);

  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen> {
  bool _ready = false;
  bool _error = false;
  String _status = 'Inicializando...';
  bool _permissionDenied = false;
  bool _permissionPermanentlyDenied = false;

  @override
  void initState() {
    super.initState();
    // Ejecutar la inicialización después del primer frame para poder mostrar diálogos
    WidgetsBinding.instance.addPostFrameCallback((_) => _initialize());
  }

  Future<void> _initialize() async {
    setState(() {
      _ready = false;
      _error = false;
      _status = 'Cargando recursos y configuraciones...';
    });

    try {
      // Primero solicitar/confirmar permisos de ubicación
      await _ensureLocationPermission();

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
        _status = 'Listo';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = true;
        _status = 'Error durante la inicialización';
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

  Future<void> _ensureLocationPermission() async {
    try {
      setState(() => _status = 'Comprobando permiso de ubicación...');

      // Si el servicio de ubicación del dispositivo está deshabilitado, avisar y abrir ajustes del sistema
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        if (!mounted) return;
        final open = await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (context) {
            return AlertDialog(
              title: const Text('Servicio de ubicación desactivado'),
              content: const Text('El servicio de ubicación del dispositivo está desactivado. ¿Quieres abrir la configuración para activarlo?'),
              actions: [
                TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancelar')),
                TextButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Abrir ajustes')),
              ],
            );
          },
        );
        if (open == true) {
          await Geolocator.openLocationSettings();
          await Future.delayed(const Duration(milliseconds: 600));
          serviceEnabled = await Geolocator.isLocationServiceEnabled();
        }
      }

      // Comprobar permiso actual
      LocationPermission permission = await Geolocator.checkPermission();

      if (permission == LocationPermission.denied) {
        if (!mounted) return;
        // Mostrar diálogo propio antes de la petición del sistema para mejorar la UX
        final allow = await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (context) {
            return AlertDialog(
              title: const Text('Permiso de ubicación'),
              content: const Text('La aplicación necesita acceder a tu ubicación para mostrar viajes y mapas correctamente. ¿Deseas permitirlo?'),
              actions: [
                TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('No')),
                TextButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Sí')),
              ],
            );
          },
        );

        if (allow == true) {
          // Llamada al permiso del sistema
          permission = await Geolocator.requestPermission();
        }
      }

      if (permission == LocationPermission.deniedForever) {
        if (!mounted) return;
        setState(() => _status = 'Permiso denegado permanentemente');
        // Dialogo para abrir ajustes de la app
        await showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (context) {
            return AlertDialog(
              title: const Text('Permiso denegado permanentemente'),
              content: const Text('El permiso de ubicación fue denegado permanentemente. Abre los ajustes de la aplicación para activarlo.'),
              actions: [
                TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cerrar')),
                TextButton(onPressed: () async { Navigator.of(context).pop(); await Geolocator.openAppSettings(); }, child: const Text('Abrir ajustes')),
              ],
            );
          },
        );
        await Future.delayed(const Duration(milliseconds: 600));
      }

      // Actualizar banderas de estado para mostrar botones si es necesario
      if (!mounted) return;
      final finalPerm = await Geolocator.checkPermission();
      if (finalPerm == LocationPermission.always || finalPerm == LocationPermission.whileInUse) {
        setState(() {
          _status = 'Permiso de ubicación concedido';
          _permissionDenied = false;
          _permissionPermanentlyDenied = false;
        });
      } else if (finalPerm == LocationPermission.deniedForever) {
        setState(() {
          _status = 'Permiso denegado permanentemente';
          _permissionDenied = false;
          _permissionPermanentlyDenied = true;
        });
      } else {
        setState(() {
          _status = 'Permiso de ubicación no concedido';
          _permissionDenied = true;
          _permissionPermanentlyDenied = false;
        });
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _status = 'Error comprobando permisos');
    }
  }

  Future<void> _requestPermissionFromUser() async {
    try {
      setState(() => _status = 'Solicitando permiso...');
      final permission = await Geolocator.requestPermission();
      if (!mounted) return;
      if (permission == LocationPermission.always || permission == LocationPermission.whileInUse) {
        setState(() {
          _status = 'Permiso concedido';
          _permissionDenied = false;
          _permissionPermanentlyDenied = false;
        });
      } else if (permission == LocationPermission.deniedForever) {
        setState(() {
          _status = 'Permiso denegado permanentemente';
          _permissionDenied = false;
          _permissionPermanentlyDenied = true;
        });
      } else {
        setState(() {
          _status = 'Permiso denegado';
          _permissionDenied = true;
          _permissionPermanentlyDenied = false;
        });
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _status = 'Error al solicitar permiso');
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
                      widget.phoneNumber.isNotEmpty ? 'Has iniciado sesión como ${widget.phoneNumber}' : 'Has iniciado sesión',
                      style: theme.textTheme.bodyMedium,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 18),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        if (!_ready && !_error) const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                        const SizedBox(width: 12),
                        Text('¡Ready!', style: theme.textTheme.bodySmall),
                      ],
                    ),
                    const SizedBox(height: 12),
                    if (_permissionDenied)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8.0),
                        child: ElevatedButton(
                          onPressed: _requestPermissionFromUser,
                          child: const Text('Permitir ubicación'),
                        ),
                      ),
                    if (_permissionPermanentlyDenied)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8.0),
                        child: ElevatedButton(
                          onPressed: () async {
                            await Geolocator.openAppSettings();
                          },
                          child: const Text('Abrir ajustes'),
                        ),
                      ),
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
                  child: Text(_ready ? 'Continuar' : 'Cargando...', style: TextStyle(color: Colors.white, fontSize: 18.0, fontWeight: FontWeight.bold),),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
