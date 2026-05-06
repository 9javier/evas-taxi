import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:http/http.dart' as http;
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_svg/flutter_svg.dart' as svg;
import 'app_state.dart';
import 'config.dart';
import 'driver_location_service.dart';
import 'firebase_action_service.dart';
import 'travel_notification_handler.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:url_launcher/url_launcher.dart';
import 'chat_service.dart';

// ── Paleta Dark Premium (alineada con el popup de solicitud de viaje) ────────
const Color _tsCardBg    = Color(0xFF1E1E26);
const Color _tsSurface   = Color(0xFF2A2A34);
const Color _tsAccent    = Color(0xFF6366F1);
const Color _tsOriginDot = Color(0xFF6EE7B7);
const Color _tsDestDot   = Color(0xFFEF4444);
const Color _tsRouteLine = Color(0xFF3F3F46);
const Color _tsTextMain  = Colors.white;
const Color _tsTextMuted = Color(0xFFA0A0AB);
const Color _tsHandle    = Color(0xFF3F3F46);

// Estilo de mapa limpio (constante a nivel de archivo) — usado por GoogleMap.style
const String _cleanMapStyle = '''[
  {"featureType":"poi","elementType":"all","stylers":[{"visibility":"off"}]},
  {"featureType":"transit","elementType":"all","stylers":[{"visibility":"off"}]},
  {"featureType":"administrative","elementType":"labels","stylers":[{"visibility":"off"}]},
  {"featureType":"road","elementType":"labels.icon","stylers":[{"visibility":"off"}]},
  {"featureType":"landscape","elementType":"all","stylers":[{"visibility":"simplified"}]},
  {"featureType":"water","elementType":"geometry","stylers":[{"color":"#a2daf2"}]},
  {"featureType":"poi.business","elementType":"all","stylers":[{"visibility":"off"}]},
  {"featureType":"poi.attraction","elementType":"all","stylers":[{"visibility":"off"}]},
  {"featureType":"poi.park","elementType":"all","stylers":[{"visibility":"off"}]},
  {"featureType":"road","elementType":"geometry.fill","stylers":[{"color":"#ffffff"}]},
  {"featureType":"road","elementType":"geometry.stroke","stylers":[{"color":"#d6d6d6"}]}
]''';

class TravelScreen extends StatefulWidget {
  final String? travelId;
  final String? phoneNumber;

  const TravelScreen({super.key, this.travelId, this.phoneNumber});

  @override
  State<TravelScreen> createState() => _TravelScreenState();
}

class _TravelScreenState extends State<TravelScreen> with SingleTickerProviderStateMixin {
  String? _driverId;
  final _driverLocationService = DriverLocationService();
  StreamSubscription<Position>? _positionSubscription;
  StreamSubscription<DocumentSnapshot>? _onlineStatusSub;
  bool? _isOnline;
  DateTime? _lastRouteUpdatedAt;
  DateTime? _lastCameraUpdatedAt;
  Position? _currentPosition;
  GoogleMapController? _mapController;
  bool _loadingLocation = true;
  String? _locationError;

  final Set<Marker> _markers = {};
  final Set<Polyline> _polylines = {};
  LatLng? _destinationLatLng;
  LatLng? _passengerLatLng;
  String _passengerName = 'Pasajero';
  String _passengerPhone = '';
  BitmapDescriptor? _passengerIcon;
  BitmapDescriptor? _driverIcon;
  BitmapDescriptor? _destinationIcon;
  // Control de visibilidad del marcador del pasajero
  bool _showPassengerMarker = true;
  // Animación suave del marcador del conductor
  late AnimationController _markerController;
  LatLng? _markerAnimStart;
  LatLng? _markerAnimEnd;
  double _currentBearing = 0.0;
  LatLng _driverLatLng = const LatLng(33.7490, -84.3880);
  LatLng? _dropoffLatLng;
  String? _passengerAddress;
  String? _destinationAddress;

  bool _sheetExpanded = false;
  final Map<String, DateTime> _lastLoadedAt = {};
  bool _loadingTravelData = false;
  // Última posición en la que se solicitó una ruta nueva (para throttle por distancia)
  Position? _lastRoutePosition;
  // Timer de rescate: a los 10 s busca notificaciones pendientes si aún no hay viaje
  Timer? _pendingCheckTimer;

  bool _navigating = false;
  // Indica si el conductor ya recogió al pasajero (true solo después de pulsar "Recoger al Pasajero").
  bool _passengerPickedUp = false;
  // Flags para enviar cada notificación de proximidad una sola vez por viaje.
  bool _notifiedDriverNear = false;
  bool _notifiedDriverArrived = false;
  // Evita ejecuciones concurrentes del chequeo de proximidad.
  bool _checkingProximity = false;
  // Evita recentrar el mapa más de una vez al abrir la pantalla
  bool _mapCenteredInitially = false;
  // Evita múltiples restauraciones simultáneas
  bool _restoring = false;
  EdgeInsets _mapPadding = EdgeInsets.zero; // nuevo padding dinámico del mapa

  // Control de interacción manual del driver con el mapa:
  // cuando el driver hace zoom/pan, pausamos el seguimiento automático de cámara.
  bool _userPanningMap = false;
  DateTime? _lastUserInteractionAt;
  bool _programmaticCameraMove = false;
  static const int _userInteractionPauseSecs = 12;
  bool _refreshing = false; // bloquea doble-tap en botón refresh
  bool _hasNewChatMessage = false;

  // Nombre del pasajero del viaje en cola (se carga cuando pendingTravelIdNotifier cambia)
  String _pendingPassengerName = '';

  // Vehículo activo del conductor
  String? _activeVehicleBrand;
  String? _activeVehicleModel;
  String? _activeVehiclePlate;

  @override
  void initState() {
    super.initState();
    _loadMarkerIcons();
    _getCurrentLocation();
    // Eliminado listener de pestañas para evitar restauraciones repetidas y loops de recarga.
    // tabsIndexNotifier.addListener(_onTabChanged);
    if (widget.travelId != null && widget.travelId!.isNotEmpty) {
      _loadTravelData(widget.travelId!);
    }
    // activeTravelIdNotifier.addListener(_onActiveTravelIdChanged); // eliminado para evitar doble carga y loops
    // Sincronizar el estado local _navigating con el notifier global para evitar
    // que re-renderizados muestren el botón incorrectamente.
    // Inicializar con el valor actual para evitar que el botón aparezca tras
    // reconstrucciones si ya estamos en viaje.
    //_navigating = driverOnTripNotifier.value;
    driverOnTripNotifier.addListener(_onDriverOnTripChanged);
    pendingTravelIdNotifier.addListener(_onPendingTravelChanged);
    passengerCanceledNotifier.addListener(_onPassengerCanceled);
    driverReleasedNotifier.addListener(_onDriverReleased);
    chatNewMessageNotifier.addListener(_onChatNewMessage);
    // Cargar nombre del viaje en cola si ya existe al iniciar
    if (pendingTravelIdNotifier.value != null && pendingTravelIdNotifier.value!.isNotEmpty) {
      _loadPendingTravelName(pendingTravelIdNotifier.value!);
    }

    // Inicializar controlador de animación para el marcador del conductor
    _markerController = AnimationController(vsync: this, duration: const Duration(milliseconds: 600))
      ..addListener(() {
        if (_markerAnimStart != null && _markerAnimEnd != null) {
          final t = _markerController.value;
          final lat = _lerpDouble(_markerAnimStart!.latitude, _markerAnimEnd!.latitude, t);
          final lng = _lerpDouble(_markerAnimStart!.longitude, _markerAnimEnd!.longitude, t);
          _driverLatLng = LatLng(lat, lng);
          _updateDriverMarker();
        }
      })
      ..addStatusListener((status) {
        if (status == AnimationStatus.completed || status == AnimationStatus.dismissed) {
          if (_markerAnimEnd != null) _driverLatLng = _markerAnimEnd!;
          _markerAnimStart = null;
          _markerAnimEnd = null;
          _updateDriverMarker();
        }
      });

    // Iniciar el servicio de ubicación usando el ID real del documento del conductor.
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      debugPrint('DriverLocationService no iniciado: usuario no autenticado.');
    } else if (driverDocId != null) {
      // ID ya resuelto en esta sesión (login reciente o _refreshFcmToken ya corrió).
      _driverId = driverDocId;
      _driverLocationService.start(driverId: _driverId!, distanceFilter: 20, minIntervalSeconds: 10);
      _loadActiveVehicle();
      _subscribeOnlineStatus();
    } else {
      // App reiniciada sin pasar por login — resolver el ID por query antes de iniciar.
      _resolveDriverIdAndStart(user);
    }

    // A los 10 s, si aún no hay viaje activo, buscar notificaciones pendientes no mostradas.
    _pendingCheckTimer = Timer(const Duration(seconds: 10), _claimPendingBackgroundMessage);

    // Suscribirse localmente para actualizar el marcador del conductor y recálculo de ruta mínimo cada 12s
    try {
      _positionSubscription = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: 10),
      ).listen((pos) async {
        _currentPosition = pos;
        _driverLatLng = LatLng(pos.latitude, pos.longitude);

        // Animar el marcador del conductor hacia la nueva posición (suavizado)
        _moveDriverMarkerTo(LatLng(pos.latitude, pos.longitude));

        if (mounted) setState(() {});
        // Si todavía no centramos el mapa y tenemos posición, centrarla (primera vez)
        if (!_mapCenteredInitially && _mapController != null) {
          try {
            _mapController!.animateCamera(CameraUpdate.newLatLngZoom(LatLng(pos.latitude, pos.longitude), 16));
            _mapCenteredInitially = true;
          } catch (_) {}
        }

        // Durante la navegación, seguir al conductor con una cámara tipo 'GPS' (throttle cada ~1s).
        // Si el driver está explorando el mapa manualmente, pausar el seguimiento automático.
        if (_navigating && (_dropoffLatLng != null || _destinationLatLng != null) && !_isUserInteracting()) {
          final nowCam = DateTime.now();
          if (_lastCameraUpdatedAt == null || nowCam.difference(_lastCameraUpdatedAt!).inMilliseconds >= 900) {
            _lastCameraUpdatedAt = nowCam;
            try {
              final target = _dropoffLatLng ?? _destinationLatLng ?? _passengerLatLng;
              if (target != null && _mapController != null) {
                final bearing = _computeBearing(_driverLatLng, target);
                // Zoom fijo para experiencia tipo GPS
                const double zoom = 20.2;
                final camera = CameraPosition(target: _driverLatLng, zoom: zoom, tilt: 20.0, bearing: bearing);
                _programmaticCameraMove = true;
                await _mapController!.animateCamera(CameraUpdate.newCameraPosition(camera));
                Future.delayed(const Duration(milliseconds: 250), () => _programmaticCameraMove = false);
              }
            } catch (e) {
              debugPrint('Error actualizando cámara en navegación: $e');
            }
          }
        }

        // Recalcular ruta si: pasaron ≥30 s (refresh forzado), o ≥12 s Y el driver se movió ≥30 m.
        // Esto evita llamadas innecesarias a la API de Directions cuando el conductor está parado.
        final now = DateTime.now();
        final _secsSinceRoute = _lastRouteUpdatedAt == null ? 999 : now.difference(_lastRouteUpdatedAt!).inSeconds;
        final _distSinceRoute = _lastRoutePosition == null
            ? double.infinity
            : Geolocator.distanceBetween(_lastRoutePosition!.latitude, _lastRoutePosition!.longitude, pos.latitude, pos.longitude);
        if (_secsSinceRoute >= 30 || (_secsSinceRoute >= 12 && _distSinceRoute >= 30)) {
          _lastRouteUpdatedAt = now;
          _lastRoutePosition = pos;
          try {
            if (_passengerPickedUp) {
              // Solo cuando el pasajero fue recogido trazamos hacia el dropoff/destination
              await _prepareRouteOnMap(_driverLatLng, _dropoffLatLng ?? _destinationLatLng ?? _passengerLatLng);
            } else {
              // Antes de recoger: mantener la ruta desde driver -> pickup
              await _prepareRouteOnMap(_driverLatLng, _activeRouteTarget());
            }
          } catch (_) {}
        }

        // Revisar proximidad y notificar al pasajero si aún no lo hemos hecho
        try {
          await _checkProximityAndNotify();
        } catch (e) {
          debugPrint('Error checkProximityAndNotify: $e');
        }
      });
    } catch (e) {
      debugPrint('No se pudo suscribir al stream de ubicación: $e');
    }
  }

  @override
  void didUpdateWidget(covariant TravelScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldId = oldWidget.travelId;
    final newId = widget.travelId;
    if (newId != null && newId.isNotEmpty && newId != oldId) {
      // Throttle: si se cargó hace <3s no recargar para evitar loop
      final last = _lastLoadedAt[newId];
      if (last != null && DateTime.now().difference(last).inSeconds < 3) return;
      _lastLoadedAt[newId] = DateTime.now();
      _loadTravelData(newId);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Eliminamos la restauración automática para evitar que cada reconstrucción vuelva a cargar viaje y ruta.
    // Future.microtask(() => _checkActiveTripAndRestore());
  }

  @override
  void dispose() {
    // activeTravelIdNotifier.removeListener(_onActiveTravelIdChanged); // eliminado
    driverOnTripNotifier.removeListener(_onDriverOnTripChanged);
    pendingTravelIdNotifier.removeListener(_onPendingTravelChanged);
    passengerCanceledNotifier.removeListener(_onPassengerCanceled);
    driverReleasedNotifier.removeListener(_onDriverReleased);
    chatNewMessageNotifier.removeListener(_onChatNewMessage);
    tabsIndexNotifier.removeListener(_onTabChanged);
    _pendingCheckTimer?.cancel();
    _onlineStatusSub?.cancel();
    // Detener servicio de ubicación al cerrar la pantalla
    _driverLocationService.stop();
    _positionSubscription?.cancel();
    _mapController?.dispose();
    _markerController.dispose();
    super.dispose();
  }

  // Helper seguro para evitar setState después de dispose
  void _safeSetState(VoidCallback fn) {
    if (!mounted) return;
    setState(fn);
  }

  /// Devuelve true si el driver está explorando el mapa manualmente y no debe
  /// interrumpirse con movimientos automáticos de cámara.
  bool _isUserInteracting() {
    if (!_userPanningMap) return false;
    if (_lastUserInteractionAt == null) return false;
    if (DateTime.now().difference(_lastUserInteractionAt!).inSeconds >= _userInteractionPauseSecs) {
      _userPanningMap = false;
      return false;
    }
    return true;
  }

  Future<void> _startNavigation() async {
    // LLamar al servicio de firebase que notifica al pasajero que el conductor inició la navegación
    if (!mounted) return; // evitar continuar si ya se desmontó
    // Si no tenemos coordenadas de destino, hacer una lectura puntual a Firestore
    // solo para obtener las coordenadas — sin setState ni redibujado de ruta.
    if (_dropoffLatLng == null) {
      final travelId = (widget.travelId ?? activeTravelIdNotifier.value ?? '').toString();
      if (travelId.isNotEmpty) {
        try {
          final doc = await FirebaseFirestore.instance.collection('travels').doc(travelId).get();
          if (doc.exists) {
            final data = doc.data() ?? {};
            LatLng? parsed = _tryParseDestFromData(data);
            if (parsed != null) {
              _dropoffLatLng = parsed;
              _destinationLatLng = parsed;
            }
          }
        } catch (e) {
          debugPrint('_startNavigation: error leyendo destino desde Firestore: $e');
        }
      }
    }

    // El objetivo al iniciar el modo 'Recoger al Pasajero' debe ser el destino final
    // del pasajero (dropoff/destination). Si no existe, usar la ubicación del pasajero.
    final target = _dropoffLatLng ?? _destinationLatLng ?? _passengerLatLng;
    if (target == null) return;

    // Actualizar viaje_status a in_progress via Cloud Function (Admin SDK, sin restricciones de permisos).
    try {
      final travelId = (widget.travelId ?? activeTravelIdNotifier.value).toString();
      if (travelId.isNotEmpty && travelId != 'null') {
        await FirebaseActionService.updateTravelStatus(travelId, 'in_progress');
      }
    } catch (e) {
      debugPrint('Error actualizando viaje_status a in_progress: $e');
    }

    // Leer ubicación actual del driver desde Firestore para centrar la cámara.
    try {
      if (_driverId != null && _driverId!.isNotEmpty) {
        final doc = await FirebaseFirestore.instance.collection('drivers').doc(_driverId).get();
        if (doc.exists) {
          final data = doc.data();
          LatLng? docLatLng;
          if (data != null) {
            // Posibles formatos: GeoPoint en campo 'location', o fields 'lat'/'lng', 'latitude'/'longitude'
            if (data['location'] is GeoPoint) {
              final gp = data['location'] as GeoPoint;
              docLatLng = LatLng(gp.latitude, gp.longitude);
            } else {
              final lat = _toDouble(data['lat'] ?? data['latitude'] ?? data['latitud'] ?? data['origin_lat']);
              final lng = _toDouble(data['lng'] ?? data['longitude'] ?? data['lngitud'] ?? data['origin_lng']);
              if (lat != null && lng != null) docLatLng = LatLng(lat, lng);
            }
          }

          // Si no hay coords en Firestore, fallback a la ubicación actual del dispositivo
          if (docLatLng == null && _currentPosition != null) {
            docLatLng = LatLng(_currentPosition!.latitude, _currentPosition!.longitude);
          }

          if (docLatLng != null) {
            setState(() {
              _driverLatLng = docLatLng!;
            });
            _updateDriverMarker();
            try {
              await _mapController?.animateCamera(CameraUpdate.newLatLngZoom(_driverLatLng, 16));
            } catch (_) {}
          }
        }
      }
    } catch (e) {
      debugPrint('Error leyendo ubicación del driver desde Firestore: $e');
    }

    _safeSetState(() => _navigating = true);
    // Marcar que el conductor inicia la navegación y que el pasajero fue recogido
    // Esto hace que _activeRouteTarget() y las actualizaciones de ruta prioricen el dropoff.
    _safeSetState(() {
      _navigating = true;
      _passengerPickedUp = true;
      _showPassengerMarker = false;
    });
    _markers.removeWhere((m) => m.markerId.value == 'passenger');
    driverOnTripNotifier.value = true;

    // Preparar ruta inicial en el mapa (usar _driverLatLng actualizado si fue posible)
    try {
      final bounds = await _prepareRouteOnMap(_driverLatLng, target);
      // Ajustar cámara a una vista GPS centrada en el driver si hay bounds
      if (bounds != null) {
        await _focusCameraForRoute(_driverLatLng, target, bounds, gpsMode: true);
      }
    } catch (e) {
      debugPrint('Error preparando ruta al iniciar navegación: $e');
    }
  }

  /// Ajusta la cámara; en gpsMode centra en el driver con vista tipo GPS.
  Future<void> _focusCameraForRoute(LatLng origin, LatLng dest, LatLngBounds bounds, {bool gpsMode = false}) async {
    if (_mapController == null || !mounted) return;
    _programmaticCameraMove = true;
    try {
      await _updateMapPadding();

      if (gpsMode) {
        final bearing = _computeBearing(origin, dest);
        const double zoom = 17.5;
        const double tilt = 50.0;
        final camera = CameraPosition(target: origin, zoom: zoom, tilt: tilt, bearing: bearing);
        await Future.delayed(const Duration(milliseconds: 80));
        await _mapController!.animateCamera(CameraUpdate.newCameraPosition(camera));
        return;
      }

      // Modo normal: encuadrar toda la ruta (mejor para vista previa)
      await _mapController!.animateCamera(CameraUpdate.newLatLngBounds(bounds, 60));

      // Para distancias cortas, una vista inmersiva opcional centrada en el centro de bounds
      final dist = Geolocator.distanceBetween(origin.latitude, origin.longitude, dest.latitude, dest.longitude);
      if (dist < 1800) {
        final bearing = _computeBearing(origin, dest);
        final center = LatLng(
          (bounds.northeast.latitude + bounds.southwest.latitude) / 2,
          (bounds.northeast.longitude + bounds.southwest.longitude) / 2,
        );
        double zoom;
        try {
          zoom = await _mapController!.getZoomLevel();
        } catch (_) {
          if (dist > 1500) zoom = 14.0;
          else if (dist > 800) zoom = 15.0;
          else if (dist > 400) zoom = 16.0;
          else if (dist > 200) zoom = 16.8;
          else zoom = 17.5;
        }
        if (dist < 350) zoom = (zoom + 0.8).clamp(16.0, 19.0);
        await Future.delayed(const Duration(milliseconds: 140));
        await _mapController!.animateCamera(
          CameraUpdate.newCameraPosition(
            CameraPosition(target: center, zoom: zoom, bearing: bearing, tilt: 20.0),
          ),
        );
      }
    } catch (e) {
      debugPrint('Error _focusCameraForRoute: $e');
      try {
        await _mapController!.animateCamera(CameraUpdate.newLatLngBounds(bounds, 30));
      } catch (_) {}
    } finally {
      Future.delayed(const Duration(milliseconds: 250), () => _programmaticCameraMove = false);
    }
  }

  Future<void> _loadMarkerIcons() async {
    try {
      final double dpr = ui.PlatformDispatcher.instance.views.first.devicePixelRatio;
      final int baseSize = (56 * (dpr.clamp(1.0, 3.0)) * 0.7 * 0.7).round();
      final int driverSize = (baseSize * 0.75).round().clamp(12, baseSize);
      try {
        final passengerBytes = await _getBytesFromAsset('assets/passenger.png', baseSize);
        if (!mounted) return;
        if (passengerBytes != null) {
          final passengerBd = BitmapDescriptor.bytes(passengerBytes);
          _safeSetState(() => _passengerIcon = passengerBd);
          _updatePassengerMarker();
        }
      } catch (e) {
        debugPrint('asset passenger falló al generar bytes: $e');
      }
      try {
        final driverBytes = await _getBytesFromAsset('assets/arrow.png', driverSize);
        if (!mounted) return;
        if (driverBytes != null) {
          final driverBd = BitmapDescriptor.bytes(driverBytes);
          _safeSetState(() => _driverIcon = driverBd);
        }
      } catch (e) {
        debugPrint('asset driver falló al generar bytes: $e');
        try {
          final fallback = await _getBytesFromAsset('assets/arrow.png', baseSize);
          if (!mounted) return;
          if (fallback != null) _safeSetState(() => _driverIcon = BitmapDescriptor.bytes(fallback));
        } catch (_) {}
      }
      try {
        final int destSize = (baseSize * 0.45).round().clamp(20, 48);
        final destBytes = await _getBytesFromAsset('assets/destino.svg', destSize);
        if (!mounted) return;
        if (destBytes != null) _safeSetState(() => _destinationIcon = BitmapDescriptor.bytes(destBytes));
      } catch (e) {
        debugPrint('asset destino.svg falló: $e');
      }
    } catch (e) {
      debugPrint('Error cargando iconos: $e');
    }
  }

  void _updatePassengerMarker() {
    if (_passengerLatLng == null) return;
    if (!_showPassengerMarker) return; // no dibujar si está oculto
    final icon = _passengerIcon ?? BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure);
    _markers.removeWhere((m) => m.markerId.value == 'passenger');
    _markers.add(Marker(
      markerId: const MarkerId('passenger'),
      position: _passengerLatLng!,
      infoWindow: const InfoWindow(title: 'Pickup'),
      icon: icon,
    ));
    if (mounted) setState(() {}); // protegido
  }

  Future<Uint8List?> _getBytesFromAsset(String path, int width) async {
    try {
      // Si el asset es SVG, renderizarlo a PNG usando flutter_svg
      if (path.toLowerCase().endsWith('.svg')) {
        try {
          // Render the SVG offscreen by inserting an invisible SvgPicture into the Overlay
          final devicePixelRatio = ui.PlatformDispatcher.instance.views.first.devicePixelRatio;
          final GlobalKey repaintKey = GlobalKey();

          final overlay = OverlayEntry(builder: (context) {
            return Positioned(
              left: -9999,
              top: -9999,
              width: width.toDouble(),
              height: width.toDouble(),
              child: RepaintBoundary(
                key: repaintKey,
                child: SizedBox(
                  width: width.toDouble(),
                  height: width.toDouble(),
                  child: svg.SvgPicture.asset(
                    path,
                    width: width.toDouble(),
                    height: width.toDouble(),
                    fit: BoxFit.contain,
                  ),
                ),
              ),
            );
          });

          Overlay.of(context).insert(overlay);
          // Wait a frame to allow the widget to be laid out and painted
          await Future.delayed(const Duration(milliseconds: 50));

          final boundary = repaintKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
          if (boundary == null) {
            overlay.remove();
            return null;
          }
          final ui.Image image = await boundary.toImage(pixelRatio: devicePixelRatio);
          final ByteData? byteData = await image.toByteData(format: ui.ImageByteFormat.png);
          final bytes = byteData?.buffer.asUint8List();
          overlay.remove();
          try { image.dispose(); } catch (_) {}
          return bytes;
        } catch (e) {
          debugPrint('Error renderizando SVG en _getBytesFromAsset: $e');
          return null;
        }
      }

      final data = await DefaultAssetBundle.of(context).load(path);
      final codec = await ui.instantiateImageCodec(data.buffer.asUint8List(), targetWidth: width);
      final frame = await codec.getNextFrame();
      final byteData = await frame.image.toByteData(format: ui.ImageByteFormat.png);
      return byteData?.buffer.asUint8List();
    } catch (e) {
      debugPrint('Error _getBytesFromAsset: $e');
      return null;
    }
  }

  double _lerpDouble(double a, double b, double t) => a + (b - a) * t;

  void _updateDriverMarker() {
    // Asegurar que siempre existe el marcador del driver con icono y rotación
    _markers.removeWhere((m) => m.markerId.value == 'driver');
    final icon = _driverIcon ?? BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed);
    _markers.add(Marker(
      markerId: const MarkerId('driver'),
      position: _driverLatLng,
      infoWindow: const InfoWindow(title: 'Tú'),
      icon: icon,
      rotation: _currentBearing,
      anchor: const Offset(0.5, 0.5),
      flat: true,
    ));
    if (mounted) setState(() {});
  }

  /// Mueve suavemente el marcador del conductor hacia [newPos].
  void _moveDriverMarkerTo(LatLng newPos) {
    // Si no hay posición previa (valor inicial), colocar inmediatamente
    if (!_markers.any((m) => m.markerId.value == 'driver')) {
      _driverLatLng = newPos;
      _currentBearing = 0.0;
      _updateDriverMarker();
      return;
    }

    // Preparar animación
    _markerAnimStart = _driverLatLng;
    _markerAnimEnd = newPos;
    _currentBearing = _computeBearing(_markerAnimStart!, _markerAnimEnd!);

    // Duración proporcional a la distancia (clamped)
    final dist = Geolocator.distanceBetween(_markerAnimStart!.latitude, _markerAnimStart!.longitude, _markerAnimEnd!.latitude, _markerAnimEnd!.longitude);
    final ms = (300 + (dist * 2)).clamp(300, 1800).toInt();
    _markerController.duration = Duration(milliseconds: ms);
    _markerController.forward(from: 0.0);
  }

  double _computeBearing(LatLng from, LatLng to) {
    final lat1 = _degToRad(from.latitude);
    final lat2 = _degToRad(to.latitude);
    final dLon = _degToRad(to.longitude - from.longitude);
    final y = math.sin(dLon) * math.cos(lat2);
    final x = math.cos(lat1) * math.sin(lat2) - math.sin(lat1) * math.cos(lat2) * math.cos(dLon);
    final brng = math.atan2(y, x);
    return (_radToDeg(brng) + 360) % 360;
  }

  double _degToRad(double deg) => deg * (math.pi / 180.0);
  double _radToDeg(double rad) => rad * (180.0 / math.pi);

  void _onDriverOnTripChanged() {
    debugPrint('driverOnTripNotifier changed -> ${driverOnTripNotifier.value}');
    if (mounted) setState(() => _navigating = driverOnTripNotifier.value);
  }

  void _onDriverReleased() {
    if (!driverReleasedNotifier.value) return;
    driverReleasedNotifier.value = false; // consumir la señal antes de actuar
    _endTrip();
  }

  void _onPendingTravelChanged() {
    final id = pendingTravelIdNotifier.value;
    if (id != null && id.isNotEmpty) {
      // Forzar reconstrucción inmediata para que el chip aparezca antes de que termine el fetch del nombre.
      _safeSetState(() {});
      _loadPendingTravelName(id);
    } else {
      _safeSetState(() => _pendingPassengerName = '');
    }
  }

  void _onPassengerCanceled() {
    final canceledId = passengerCanceledNotifier.value;
    if (canceledId == null) return;
    passengerCanceledNotifier.value = null;
    _showPassengerCanceledDialog();
    _endTrip();
  }

  void _onChatNewMessage() {
    if (!chatNewMessageNotifier.value) return;
    chatNewMessageNotifier.value = false;
    _safeSetState(() => _hasNewChatMessage = true);
  }

  Future<void> _showPassengerCanceledDialog() async {
    if (!mounted) return;
    await showDialog(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.black.withOpacity(0.6),
      builder: (ctx) => Dialog(
        backgroundColor: const Color(0xFF1E1E26),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 28, 24, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 60,
                height: 60,
                decoration: BoxDecoration(
                  color: const Color(0xFFEF4444).withOpacity(0.12),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.cancel_outlined, color: Color(0xFFEF4444), size: 32),
              ),
              const SizedBox(height: 16),
              const Text(
                'Viaje cancelado',
                style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 10),
              const Text(
                'Lo lamentamos, el pasajero canceló el viaje.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Color(0xFFA0A0AB), fontSize: 14, height: 1.4),
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF6366F1),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('OK', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _loadPendingTravelName(String travelId) async {
    try {
      // El viaje en cola puede estar en requestTravel (status: queued) antes de promoverse
      DocumentSnapshot<Map<String, dynamic>> doc =
          await FirebaseFirestore.instance.collection('travels').doc(travelId).get();
      if (!doc.exists) {
        doc = await FirebaseFirestore.instance.collection('requestTravel').doc(travelId).get();
      }
      if (!doc.exists || !mounted) return;
      final data = doc.data() ?? {};
      final userId = data['userId']?.toString() ?? '';
      if (userId.isNotEmpty) {
        final userDoc = await FirebaseFirestore.instance.collection('users').doc(userId).get();
        if (userDoc.exists && mounted) {
          final ud = userDoc.data() ?? {};
          final name = (ud['name'] ?? ud['nombre'] ?? ud['displayName'] ?? '').toString().trim();
          if (name.isNotEmpty) {
            _safeSetState(() => _pendingPassengerName = name);
            return;
          }
        }
      }
      _safeSetState(() => _pendingPassengerName = '');
    } catch (_) {}
  }

  void _onTabChanged() {
    // Desactivado para evitar loops de recarga al cambiar de pestañas.
    // if (tabsIndexNotifier.value == 0) {
    //   _checkActiveTripAndRestore();
    // }
  }

  /// Si existe un viaje activo y el driver está en viaje, restaurar estado y dibujar ruta.
  Future<void> _checkActiveTripAndRestore() async {
    if (_restoring) return;
    _restoring = true;
    try {
      String? travelId = widget.travelId ?? activeTravelIdNotifier.value;
      String? remoteStatus; // estado del viaje leído remotamente
      if (!driverOnTripNotifier.value) {
        if (travelId == null || travelId.isEmpty) {
          if (_driverId != null && _driverId!.isNotEmpty) {
            try {
              QuerySnapshot<Map<String, dynamic>> q = await FirebaseFirestore.instance
                  .collection('travels')
                  .where('driverId', isEqualTo: _driverId)
                  .where('viaje_status', whereIn: ['accepted', 'driver_near', 'driver_arrived', 'in_progress'])
                  .limit(1)
                  .get();
              if (q.docs.isEmpty) {
                q = await FirebaseFirestore.instance
                    .collection('travels')
                    .where('driver_id', isEqualTo: _driverId)
                    .where('viaje_status', whereIn: ['accepted', 'driver_near', 'driver_arrived', 'in_progress'])
                    .limit(1)
                    .get();
              }
              if (q.docs.isNotEmpty) {
                final d = q.docs.first;
                travelId = d.id;
                remoteStatus = (d.data()['viaje_status'] ?? '').toString();
                if (activeTravelIdNotifier.value != travelId) {
                  activeTravelIdNotifier.value = travelId;
                }
                // in_progress: pasajero ya recogido, conductor en ruta al destino
                driverOnTripNotifier.value = remoteStatus == 'in_progress';
              }
            } catch (e) {
              debugPrint('Error buscando viaje activo en Firestore: $e');
            }
          }
        } else {
          try {
            final snap = await FirebaseFirestore.instance.collection('travels').doc(travelId).get();
            if (!snap.exists) {
              final alt = await FirebaseFirestore.instance.collection('requestTravel').doc(travelId).get();
              if (alt.exists) remoteStatus = (alt.data()?['viaje_status'] ?? '').toString();
            } else {
              remoteStatus = (snap.data()?['viaje_status'] ?? '').toString();
            }
          } catch (e) {
            debugPrint('Error leyendo estado del viaje para travelId=$travelId: $e');
          }
        }
      }
      if (travelId == null || travelId.isEmpty) return;
      try { await _loadTravelData(travelId); } catch (e) { debugPrint('Error cargando datos del viaje en restore: $e'); }
      // in_progress: pasajero ya a bordo, conductor en ruta al destino
      final isInProgress = (remoteStatus == 'in_progress');
      const endStatuses = {
        'completed','complete','finished','ended','finalized','cancelled','canceled','rejected','declined','close'
      };
      if (isInProgress) {
        if (mounted) {
          _safeSetState(() {
            _navigating = true;
            _passengerPickedUp = true;
            _sheetExpanded = true;
            _showPassengerMarker = false;
          });
          _markers.removeWhere((m) => m.markerId.value == 'passenger');
        }
        if (!driverOnTripNotifier.value) driverOnTripNotifier.value = true;
      } else if (remoteStatus != null && endStatuses.contains(remoteStatus.toLowerCase())) {
        if (mounted) {
          _safeSetState(() {
            _navigating = false;
            _passengerPickedUp = false;
            _sheetExpanded = false;
          });
        }
        if (driverOnTripNotifier.value) driverOnTripNotifier.value = false; // paréntesis corregidos
      } else {
        // Estados como 'in_progress', 'accepted', 'assigned': mantener _passengerPickedUp = false
        // y driverOnTripNotifier=false para mostrar botón "Recoger al Pasajero" y ruta hacia pickup.
      }
    } finally {
      _restoring = false;
    }
  }

  Future<DocumentSnapshot<Map<String, dynamic>>?> getTravel(travelId) async {
    DocumentSnapshot<Map<String, dynamic>> doc = await FirebaseFirestore.instance.collection('travels').doc(travelId).get();
    if (!doc.exists) {
      return null;
    }
    final data = doc.data() ?? {};
    print('Travel data: $data');
    return doc;
  }

  Future<void> _loadTravelData(String travelId) async {
    if (!mounted) return;
    if (_loadingTravelData) return;
    _loadingTravelData = true;
    // Resetear flags de notificación y throttle de ruta para el nuevo viaje
    _notifiedDriverNear = false;
    _notifiedDriverArrived = false;
    _checkingProximity = false;
    _lastRoutePosition = null;
    try {
      DocumentSnapshot<Map<String, dynamic>> doc = await FirebaseFirestore.instance.collection('travels').doc(travelId).get();
      if (!mounted) return;
      if (!doc.exists) {
        doc = await FirebaseFirestore.instance.collection('requestTravel').doc(travelId).get();
        if (!mounted) return;
        if (!doc.exists) return;
      }
      final data = doc.data() ?? {};

      // Cargar nombre del pasajero desde users/{userId}
      final userId = data['userId']?.toString() ?? '';
      if (userId.isNotEmpty) {
        try {
          final userDoc = await FirebaseFirestore.instance.collection('users').doc(userId).get();
          if (userDoc.exists) {
            final ud = userDoc.data() ?? {};
            final name = (ud['name'] ?? ud['nombre'] ?? ud['displayName'] ?? '').toString().trim();
            final phone = (ud['phone'] ?? '').toString().trim();
            if (mounted) _safeSetState(() {
              if (name.isNotEmpty) _passengerName = name;
              _passengerPhone = phone;
            });
          }
        } catch (_) {}
      }

      try {
        final String viajeStatus = (data['viaje_status'] ?? '').toString();
        // in_progress: pasajero ya recogido, conductor en ruta al destino
        final bool passengerOnBoard = viajeStatus == 'in_progress';
        const endStatuses = {
          'completed','complete','finished','ended','finalized','cancelled','canceled','rejected','declined','close'
        };
        if (passengerOnBoard) {
          _safeSetState(() {
            _navigating = true;
            _passengerPickedUp = true;
            _showPassengerMarker = false;
          });
          _markers.removeWhere((m) => m.markerId.value == 'passenger');
          if (!driverOnTripNotifier.value) driverOnTripNotifier.value = true;
        } else if (viajeStatus.isNotEmpty && endStatuses.contains(viajeStatus.toLowerCase())) {
          if (driverOnTripNotifier.value) driverOnTripNotifier.value = false;
          _safeSetState(() {
            _navigating = false;
            _passengerPickedUp = false;
          });
        } else {
          // Estados previos (accepted, driver_near, driver_arrived): mostrar botón "INICIAR VIAJE"
          _safeSetState(() {
            _passengerPickedUp = false;
            _navigating = false;
          });
          if (driverOnTripNotifier.value) driverOnTripNotifier.value = false;
        }
      } catch (_) {}
      LatLng? tryParse(dynamic m) {
        if (m == null) return null;
        if (m is GeoPoint) return LatLng(m.latitude, m.longitude);
        if (m is Map) {
          final lat = _toDouble(m['lat'] ?? m['latitude'] ?? m['latitud']);
          final lng = _toDouble(m['lng'] ?? m['longitude'] ?? m['lngitud']);
          if (lat != null && lng != null) return LatLng(lat, lng);
        }
        if (m is List && m.length >= 2) {
          final lat = _toDouble(m[0]);
          final lng = _toDouble(m[1]);
          if (lat != null && lng != null) return LatLng(lat, lng);
        }
        return null;
      }
      // Destino debe de ser
      //lat 24.0065756
      //lng -104.6267383
      LatLng? origin;
      LatLng? dest;
      origin = tryParse(data['origin']) ?? tryParse(data['origen']) ?? tryParse(data['pickup']) ?? tryParse(data['from']);
      dest = tryParse(data['destino']) ?? tryParse(data['destination']) ?? tryParse(data['dest']) ?? tryParse(data['to']);
      origin ??= _tryParseFromKeys(data, ['originLat', 'originLatitude', 'pickupLat', 'fromLat', 'o_lat']);
      dest ??= _tryParseFromKeys(data, ['destLat', 'destinationLat', 'toLat', 'd_lat']);

      if (origin == null && data.containsKey('origin_lat') && data.containsKey('origin_lng')) {
        final lat = _toDouble(data['origin_lat']);
        final lng = _toDouble(data['origin_lng']);
        if (lat != null && lng != null) origin = LatLng(lat, lng);
      }
      if (dest == null && data.containsKey('dest_lat') && data.containsKey('dest_lng')) {
        final lat = _toDouble(data['dest_lat']);
        final lng = _toDouble(data['dest_lng']);
        if (lat != null && lng != null) dest = LatLng(lat, lng);
      }
      // Intentar flat fields adicionales para lat/lng del destino
      if (dest == null) {
        final lat = _toDouble(data['destination_lat'] ?? data['dropoff_lat'] ?? data['dest_latitude'] ?? data['destino_lat'] ?? data['destLat'] ?? data['dropoffLat']);
        final lng = _toDouble(data['destination_lng'] ?? data['dropoff_lng'] ?? data['dest_longitude'] ?? data['destino_lng'] ?? data['destLng'] ?? data['dropoffLng']);
        if (lat != null && lng != null) dest = LatLng(lat, lng);
      }

      _safeSetState(() {
        _passengerLatLng = origin;
        _destinationLatLng = dest ?? origin;
        _dropoffLatLng = dest;
        // Intentar extraer from data['description'] which may contain nested origin/destination
        String? extractFromDescription(String key) {
          final desc = data['description'];
          if (desc is Map) {
            final val = desc[key];
            if (val == null) return null;
            if (val is String) return val;
            if (val is Map) {
              // Buscar campos comunes dentro del objeto origin/destination
              return (val['address'] ?? val['address_name'] ?? val['name'] ?? val['description'] ?? val['formatted_address'] ?? val['place'] )?.toString();
            }
            return val.toString();
          }
          return null;
        }

        _passengerAddress = extractFromDescription('origin') ??
            (data['origin_address'] ?? data['pickupAddress'] ?? data['pickup_address'] ?? data['origin_name'] ?? data['passenger_address'])?.toString();

        _destinationAddress = extractFromDescription('destination') ??
            (data['destinationAddress'] ?? data['destinoDireccion'] ?? data['destination_address'] ?? data['destAddress'] ?? data['destino'])?.toString();
      });

      if (_destinationLatLng != null) {
        // Debug: imprimir coordenadas cargadas para verificar parsing
        debugPrint('Travel loaded: origin=$_passengerLatLng dest=$_destinationLatLng dropoff=$_dropoffLatLng');

        // Al cargar el viaje, por defecto mostramos la ruta desde la posición del conductor
        // hasta el punto de pickup (passenger). Si no existe pickup, usar destination/dropoff.
        try {
          final initialTarget = _passengerLatLng ?? _dropoffLatLng ?? _destinationLatLng;
          if (initialTarget != null) {
            final bounds = await _prepareRouteOnMap(_driverLatLng, initialTarget);
            if (bounds != null && !_mapCenteredInitially) {
              await _focusCameraForRoute(_driverLatLng, initialTarget, bounds);
              _mapCenteredInitially = true;
            }
          }
        } catch (e) {
          debugPrint('Error preparando ruta al cargar viaje: $e');
        }
      }
      _safeSetState(() => _sheetExpanded = true);
      _lastLoadedAt[travelId] = DateTime.now();
    } catch (e) {
      debugPrint('Error _loadTravelData: $e');
    } finally {
      _loadingTravelData = false;
    }
  }

  /// Parsea las coordenadas del destino desde un documento de Firestore.
  /// Centraliza la lógica de búsqueda de campos para reutilizarla sin efectos secundarios.
  LatLng? _tryParseDestFromData(Map<String, dynamic> data) {
    LatLng? tryParse(dynamic m) {
      if (m == null) return null;
      if (m is GeoPoint) return LatLng(m.latitude, m.longitude);
      if (m is Map) {
        final lat = _toDouble(m['lat'] ?? m['latitude'] ?? m['latitud']);
        final lng = _toDouble(m['lng'] ?? m['longitude'] ?? m['lngitud']);
        if (lat != null && lng != null) return LatLng(lat, lng);
      }
      if (m is List && m.length >= 2) {
        final lat = _toDouble(m[0]);
        final lng = _toDouble(m[1]);
        if (lat != null && lng != null) return LatLng(lat, lng);
      }
      return null;
    }

    LatLng? dest = tryParse(data['destino']) ?? tryParse(data['destination']) ?? tryParse(data['dest']) ?? tryParse(data['to']);
    dest ??= _tryParseFromKeys(data, ['destLat', 'destinationLat', 'toLat', 'd_lat']);

    if (dest == null && data.containsKey('dest_lat') && data.containsKey('dest_lng')) {
      final lat = _toDouble(data['dest_lat']);
      final lng = _toDouble(data['dest_lng']);
      if (lat != null && lng != null) dest = LatLng(lat, lng);
    }
    if (dest == null) {
      final lat = _toDouble(data['destination_lat'] ?? data['dropoff_lat'] ?? data['dest_latitude'] ?? data['destino_lat'] ?? data['destLat'] ?? data['dropoffLat']);
      final lng = _toDouble(data['destination_lng'] ?? data['dropoff_lng'] ?? data['dest_longitude'] ?? data['destino_lng'] ?? data['destLng'] ?? data['dropoffLng']);
      if (lat != null && lng != null) dest = LatLng(lat, lng);
    }
    return dest;
  }

  double? _toDouble(dynamic v) {
    if (v == null) return null;
    if (v is double) return v;
    if (v is int) return v.toDouble();
    if (v is String) return double.tryParse(v);
    return null;
  }

  LatLng? _tryParseFromKeys(Map<String, dynamic> data, List<String> keys) {
    for (final k in keys) {
      if (data.containsKey(k)) {
        final val = data[k];
        if (val is Map) {
          final lat = _toDouble(val['lat'] ?? val['latitude']);
          final lng = _toDouble(val['lng'] ?? val['longitude']);
          if (lat != null && lng != null) return LatLng(lat, lng);
        }
      }
    }
    return null;
  }

  Future<List<LatLng>> _getRoutePoints(LatLng origin, LatLng dest) async {
    final apiKey = Config.googleMapsApiKey;
    final url =
        'https://maps.googleapis.com/maps/api/directions/json?origin=${origin.latitude},${origin.longitude}&destination=${dest.latitude},${dest.longitude}&mode=driving&key=$apiKey';
    final response = await http.get(Uri.parse(url));
    if (response.statusCode == 200) {
      final data = json.decode(response.body);
      if (data['routes'] != null && data['routes'].isNotEmpty) {
        final polyline = data['routes'][0]['overview_polyline']['points'];
        return _decodePolyline(polyline);
      }
    }
    return [origin, dest];
  }

  List<LatLng> _decodePolyline(String polyline) {
    List<LatLng> points = [];
    int index = 0, len = polyline.length;
    int lat = 0, lng = 0;
    while (index < len) {
      int b, shift = 0, result = 0;
      do {
        b = polyline.codeUnitAt(index++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);
      int dlat = ((result & 1) != 0 ? ~(result >> 1) : (result >> 1));
      lat += dlat;
      shift = 0;
      result = 0;
      do {
        b = polyline.codeUnitAt(index++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);
      int dlng = ((result & 1) != 0 ? ~(result >> 1) : (result >> 1));
      lng += dlng;
      points.add(LatLng(lat / 1E5, lng / 1E5));
    }
    return points;
  }

  Future<LatLngBounds?> _prepareRouteOnMap(LatLng? driverLocation, LatLng? dest) async {
    if (!mounted) return null;
    // No limpiar marcadores globalmente en cada llamada, solo actualizar/añadir necesarios.
    _polylines.clear();
    // Si el 'dest' que nos pasan es igual a la ubicación del pasajero pero tenemos
    // un dropoff explícito, preferir el dropoff solo si ya se recogió al pasajero.
    if (_passengerPickedUp && dest != null && _dropoffLatLng != null && _passengerLatLng != null) {
      bool equalsPassenger(LatLng a, LatLng b) => _latLngEquals(a, b);
      if (equalsPassenger(dest, _passengerLatLng!)) {
        debugPrint('prepareRouteOnMap: passenger picked up -> switching dest to dropoff=$_dropoffLatLng');
        dest = _dropoffLatLng;
      }
    }

    debugPrint('Preparing route: driverLocation=$driverLocation dest=$dest passenger=$_passengerLatLng dropoff=$_dropoffLatLng passengerPickedUp=$_passengerPickedUp');

    if (driverLocation != null) {
      _markers.removeWhere((m) => m.markerId.value == 'driver');
      _markers.add(Marker(
        markerId: const MarkerId('driver'),
        position: driverLocation,
        infoWindow: const InfoWindow(title: 'Tú'),
        icon: _driverIcon ?? BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed),
      ));
    }
    if (_passengerLatLng != null && _showPassengerMarker) {
      _markers.removeWhere((m) => m.markerId.value == 'passenger');
      _markers.add(Marker(
        markerId: const MarkerId('passenger'),
        position: _passengerLatLng!,
        infoWindow: const InfoWindow(title: 'Pickup'),
        icon: _passengerIcon ?? BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure),
      ));
    } else {
      // Si está oculto, asegurar que no quede en el set
      _markers.removeWhere((m) => m.markerId.value == 'passenger');
    }
    if (_dropoffLatLng != null) {
      _markers.removeWhere((m) => m.markerId.value == 'dropoff');
      _markers.add(Marker(
        markerId: const MarkerId('dropoff'),
        position: _dropoffLatLng!,
        infoWindow: const InfoWindow(title: 'Destino final'),
        icon: _destinationIcon ?? BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed),
      ));
    }

    if (driverLocation != null && dest != null) {
      final routePoints = await _getRoutePoints(driverLocation, dest);
      _polylines.clear();
      _polylines.add(Polyline(
        polylineId: const PolylineId('route'),
        color: Colors.blue,
        width: 7,
        points: routePoints,
      ));
      // Forzar render inmediato de la polyline
      if (mounted) setState(() {});
      final bounds = _getBounds(routePoints);
      // Durante navegación GPS la cámara la controla el stream de posición.
      // Si el driver está explorando el mapa manualmente tampoco interrumpir.
      if (_mapController != null && bounds != null && !_navigating && !_isUserInteracting()) {
        _programmaticCameraMove = true;
        try {
          await _mapController!.animateCamera(CameraUpdate.newLatLngBounds(bounds, 70));
        } catch (_) {
          Future.delayed(const Duration(milliseconds: 300), () async {
            try {
              await _mapController?.animateCamera(CameraUpdate.newLatLngBounds(bounds, 70));
            } catch (_) {}
          });
        }
        Future.delayed(const Duration(milliseconds: 250), () => _programmaticCameraMove = false);
      }
      // Devolver bounds para que el caller pueda ajustar la cámara a un estilo GPS
      return _getBounds(_polylines.isNotEmpty ? _polylines.first.points : []);
    } else if (driverLocation != null) {
      if (_mapController != null) {
        _mapController!.animateCamera(CameraUpdate.newLatLngZoom(driverLocation, 16));
      }
      return null;
    } else if (dest != null) {
      if (_mapController != null) {
        _mapController!.animateCamera(CameraUpdate.newLatLngZoom(dest, 17));
      }
    }
    _updatePassengerMarker();
    return null;
  }

  LatLngBounds? _getBounds(List<LatLng> points) {
    if (points.isEmpty) return null;
    double minLat = points.first.latitude, maxLat = points.first.latitude;
    double minLng = points.first.longitude, maxLng = points.first.longitude;
    for (final p in points) {
      if (p.latitude < minLat) minLat = p.latitude;
      if (p.latitude > maxLat) maxLat = p.latitude;
      if (p.longitude < minLng) minLng = p.longitude;
      if (p.longitude > maxLng) maxLng = p.longitude;
    }
    return LatLngBounds(
      southwest: LatLng(minLat, minLng),
      northeast: LatLng(maxLat, maxLng),
    );
  }

  // Comparación aproximada de dos LatLng para evitar depender de igualdad exacta
  bool _latLngEquals(LatLng a, LatLng b, {double eps = 1e-6}) {
    return (a.latitude - b.latitude).abs() <= eps && (a.longitude - b.longitude).abs() <= eps;
  }

  // Devuelve el objetivo actual para trazar la ruta:
  // - Antes de iniciar navegación: el pickup (ubicación del pasajero)
  // - Durante navegación: el dropoff/destination (si existe), o destination como fallback
  LatLng? _activeRouteTarget() {
    // Solo trazamos hacia el dropoff cuando el pasajero ya fue recogido.
    if (_passengerPickedUp) return _dropoffLatLng ?? _destinationLatLng;
    // Antes de recoger: siempre mostrar ruta hacia el pickup (si existe). Si no, usar destination como fallback.
    return _passengerLatLng ?? _destinationLatLng;
  }

  @override
  Widget build(BuildContext context) {
    if (_loadingLocation) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_locationError != null) {
      return Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(_locationError!, style: const TextStyle(color: Colors.red), textAlign: TextAlign.center),
            const SizedBox(height: 16),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 12,
              runSpacing: 12,
              children: [
                ElevatedButton.icon(
                  onPressed: _openLocationSettings,
                  icon: const Icon(Icons.location_on),
                  label: const Text('Enable Location'),
                ),
                ElevatedButton.icon(
                  onPressed: _openAppSettings,
                  icon: const Icon(Icons.settings),
                  label: const Text('Open Settings'),
                ),
                OutlinedButton.icon(
                  onPressed: _getCurrentLocation,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Retry'),
                ),
              ],
            ),
          ],
        ),
      );
    }
    if (_currentPosition == null) {
      return const Center(child: Text('Could not retrieve location'));
    }

    final bottomOffset = MediaQuery.of(context).padding.bottom + 5.0;
    // Altura del panel: responsiva cuando está expandido (porcentaje del alto de pantalla)
    final screenHeight = MediaQuery.of(context).size.height;
    // Incrementar la altura expandida un 10% sobre el valor base (0.36)
    final baseExpanded = screenHeight * 0.36;
    final expandedHeight = (baseExpanded * 1.10).clamp(260.0, screenHeight * 0.8);
    final sheetHeight = _sheetExpanded ? expandedHeight : 68.0;

    return Stack(
      children: [
        GoogleMap(
          // aplicar estilo limpio aquí
          style: _cleanMapStyle,
          padding: _mapPadding, // aplicar padding dinámico
          initialCameraPosition: CameraPosition(
            target: LatLng(_currentPosition!.latitude, _currentPosition!.longitude),
            zoom: 16,
          ),
          myLocationEnabled: true,
          myLocationButtonEnabled: true,
          markers: _markers,
          polylines: _polylines,
          onCameraMoveStarted: () {
            // Si el movimiento no fue iniciado por código, el driver está explorando el mapa.
            // Pausar seguimiento automático por _userInteractionPauseSecs segundos.
            if (!_programmaticCameraMove) {
              _userPanningMap = true;
              _lastUserInteractionAt = DateTime.now();
            }
          },
          onMapCreated: (controller) async {
            _mapController = controller;
            await _updateMapPadding();
            // Evitar múltiple lógica compleja aquí, sólo centrar una vez en la ubicación actual.
            if (_currentPosition != null && !_mapCenteredInitially) {
              try {
                await _mapController!.moveCamera(CameraUpdate.newLatLngZoom(LatLng(_currentPosition!.latitude, _currentPosition!.longitude), 16));
                _mapCenteredIniciallyFlagSetter();
              } catch (_) {}
            }
          },
        ),
        // Overlay superior — pill oscuro con distancia al pasajero / destino
        if ((_passengerLatLng != null || _destinationLatLng != null) && _currentPosition != null)
          Positioned(
            top: MediaQuery.of(context).padding.top + 12,
            left: 56, // deja espacio para el botón refresh a la derecha
            right: 56,
            child: Center(child: _buildDistancePill()),
          ),

        // Indicador online/offline — esquina superior izquierda
        Positioned(
          top: MediaQuery.of(context).padding.top + 10,
          left: 14,
          child: _buildOnlineStatusBadge(),
        ),

        // Chip de viaje en cola — debajo del pill de distancia
        if (pendingTravelIdNotifier.value != null && pendingTravelIdNotifier.value!.isNotEmpty)
          Positioned(
            top: MediaQuery.of(context).padding.top + 62,
            left: 0,
            right: 0,
            child: Center(child: _buildQueuedTripChip()),
          ),

        // Botón de refresh — esquina superior derecha
        Positioned(
          top: MediaQuery.of(context).padding.top + 8,
          right: 10,
          child: GestureDetector(
            onTap: _refresh,
            child: Container(
              width: 42, height: 42,
              decoration: BoxDecoration(
                color: _tsCardBg,
                shape: BoxShape.circle,
                boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.35), blurRadius: 10, offset: const Offset(0, 2))],
              ),
              child: _refreshing
                  ? const Padding(
                      padding: EdgeInsets.all(11),
                      child: CircularProgressIndicator(strokeWidth: 2.2, color: _tsOriginDot),
                    )
                  : const Icon(Icons.refresh_rounded, color: Colors.white, size: 20),
            ),
          ),
        ),

        Positioned(
           left: 0,
           right: 0,
            bottom: bottomOffset,
            child: AnimatedContainer(
             duration: const Duration(milliseconds: 250),
             height: sheetHeight,
             curve: Curves.easeOut,
             child: GestureDetector(
               onVerticalDragUpdate: (details) {
                 if (details.delta.dy < -6) {
                   setState(() => _sheetExpanded = true);
                   _updateMapPadding();
                 } else if (details.delta.dy > 6) {
                   setState(() => _sheetExpanded = false);
                   _updateMapPadding();
                 }
               },
              child: Container(
                decoration: BoxDecoration(
                  color: _tsCardBg,
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
                  boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.45), blurRadius: 24, offset: const Offset(0, -4))],
                ),
                child: ClipRRect(
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
                  child: SizedBox(
                    height: sheetHeight,
                    child: _buildPersistentSheetContent(),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Future hidePassengerMarker() async {
    /** Eliminar icono de pasajero en el mapa
     * para que solo muestre la ruta y la posición del conductor.
     * **/
    _showPassengerMarker = false;
    _markers.removeWhere((m) => m.markerId.value == 'passenger');
    if (mounted) setState(() {});
  }
  Future<void> _updateMapPadding() async {
    if (_mapController == null || !mounted) return;
    try {
      final media = MediaQuery.of(context);
      final screenHeight = media.size.height;
      final baseExpanded = screenHeight * 0.36;
      final expandedHeight = (baseExpanded * 1.10).clamp(260.0, screenHeight * 0.8);
      final currentPanelHeight = _sheetExpanded ? expandedHeight : 68.0;
      final bottomPadding = (currentPanelHeight + media.padding.bottom + 12).round().toDouble();
      setState(() {
        _mapPadding = EdgeInsets.fromLTRB(12, 12, 12, bottomPadding);
      });
    } catch (e) {
      debugPrint('updateMapPadding fallback: $e');
    }
  }

  Widget _buildPersistentSheetContent() {
    final hasTravel = _destinationLatLng != null || _passengerLatLng != null;
    final passengerText = _passengerAddress ??
        (_passengerLatLng != null
            ? '${_passengerLatLng!.latitude.toStringAsFixed(5)}, ${_passengerLatLng!.longitude.toStringAsFixed(5)}'
            : 'Origin not specified');
    final destinationText = _destinationAddress ??
        (_dropoffLatLng != null
            ? '${_dropoffLatLng!.latitude.toStringAsFixed(5)}, ${_dropoffLatLng!.longitude.toStringAsFixed(5)}'
            : 'Destination not specified');

    // Etiqueta y color del estado del viaje
    String statusLabel;
    Color statusColor;
    if (_navigating && _passengerPickedUp) {
      statusLabel = 'Trip in progress';
      statusColor = _tsAccent;
    } else if (_notifiedDriverArrived) {
      statusLabel = 'You have arrived';
      statusColor = _tsOriginDot;
    } else if (_notifiedDriverNear) {
      statusLabel = 'Near the passenger';
      statusColor = const Color(0xFFF59E0B);
    } else if (hasTravel) {
      statusLabel = 'On the way';
      statusColor = _tsTextMuted;
    } else {
      statusLabel = '';
      statusColor = _tsTextMuted;
    }

    return SingleChildScrollView(
      physics: _sheetExpanded ? const BouncingScrollPhysics() : const NeverScrollableScrollPhysics(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Handle ─────────────────────────────────────────────────────────
          const SizedBox(height: 12),
          Center(
            child: Container(
              width: 40, height: 4,
              decoration: BoxDecoration(color: _tsHandle, borderRadius: BorderRadius.circular(2)),
            ),
          ),
          const SizedBox(height: 16),

          if (!hasTravel) ...[
            // ── Sin viaje ───────────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  Container(
                    width: 40, height: 40,
                    decoration: BoxDecoration(color: _tsSurface, shape: BoxShape.circle),
                    child: const Icon(Icons.hourglass_empty_rounded, color: _tsTextMuted, size: 20),
                  ),
                  const SizedBox(width: 14),
                  const Text('No active trip', style: TextStyle(color: _tsTextMuted, fontSize: 16, fontWeight: FontWeight.w500)),
                ],
              ),
            ),
            const SizedBox(height: 16),
          ] else ...[
            // ── Header: avatar + nombre + estado ────────────────────────────
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  _buildPassengerAvatar(),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _passengerName,
                          style: const TextStyle(color: _tsTextMain, fontSize: 18, fontWeight: FontWeight.w700),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 5),
                        if (statusLabel.isNotEmpty)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                            decoration: BoxDecoration(
                              color: statusColor.withOpacity(0.15),
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(color: statusColor.withOpacity(0.4), width: 1),
                            ),
                            child: Text(statusLabel, style: TextStyle(color: statusColor, fontSize: 11, fontWeight: FontWeight.w600)),
                          ),
                      ],
                    ),
                  ),
                  // Botón de teléfono
                  if (_passengerPhone.isNotEmpty) ...[
                    GestureDetector(
                      onTap: _showPhoneOptions,
                      child: Container(
                        width: 34,
                        height: 34,
                        decoration: const BoxDecoration(
                          color: _tsSurface,
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.phone_outlined,
                          size: 18,
                          color: _tsTextMuted,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],
                  // Botón de chat
                  GestureDetector(
                    onTap: _showChatBottomSheet,
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Container(
                          width: 34,
                          height: 34,
                          decoration: BoxDecoration(
                            color: _tsSurface,
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.chat_bubble_outline_rounded,
                            size: 18,
                            color: _tsTextMuted,
                          ),
                        ),
                        if (_hasNewChatMessage)
                          Positioned(
                            top: -2,
                            right: -2,
                            child: Container(
                              width: 10,
                              height: 10,
                              decoration: const BoxDecoration(
                                color: Color(0xFFEF4444),
                                shape: BoxShape.circle,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  // Botón expandir / colapsar
                  GestureDetector(
                    onTap: hideOrExpand,
                    child: Container(
                      width: 34, height: 34,
                      decoration: BoxDecoration(color: _tsSurface, shape: BoxShape.circle),
                      child: Icon(
                        _sheetExpanded ? Icons.keyboard_arrow_down_rounded : Icons.keyboard_arrow_up_rounded,
                        size: 20, color: _tsTextMuted,
                      ),
                    ),
                  ),
                ],
              ),
            ),

            if (_sheetExpanded) ...[
              const SizedBox(height: 16),

              // ── Tarjeta de ruta ──────────────────────────────────────────
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  decoration: BoxDecoration(
                    color: _tsSurface,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: IntrinsicHeight(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // Línea visual origen → destino
                        Column(
                          mainAxisSize: MainAxisSize.max,
                          children: [
                            Container(width: 10, height: 10, decoration: const BoxDecoration(color: _tsOriginDot, shape: BoxShape.circle)),
                            Expanded(child: Center(child: Container(width: 2, color: _tsRouteLine))),
                            Container(width: 10, height: 10, decoration: BoxDecoration(color: _tsDestDot, borderRadius: BorderRadius.circular(2))),
                          ],
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(passengerText,
                                  style: const TextStyle(color: _tsTextMain, fontSize: 13, fontWeight: FontWeight.w500),
                                  maxLines: 2, overflow: TextOverflow.ellipsis),
                              const SizedBox(height: 14),
                              Text(destinationText,
                                  style: const TextStyle(color: _tsTextMuted, fontSize: 13),
                                  maxLines: 2, overflow: TextOverflow.ellipsis),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 10),

              // ── Chip de distancia inline ─────────────────────────────────
              if (_currentPosition != null)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: _buildInlineDistanceChip(),
                ),
              const SizedBox(height: 12),

              // ── Botón INICIAR VIAJE (solo si no se ha recogido) ──────────
              if (!_passengerPickedUp)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: _buildStartTripButton(),
                ),

              // ── Slide para terminar viaje ────────────────────────────────
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
                child: ValueListenableBuilder<bool>(
                  valueListenable: driverOnTripNotifier,
                  builder: (context, _, __) => CustomSlideAction(
                    text: 'Slide to end trip',
                    textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Colors.white, letterSpacing: 0.3),
                    outerColor: _tsDestDot,
                    innerColor: Colors.white,
                    height: 62,
                    sliderButtonIcon: const Icon(Icons.check_rounded, color: _tsDestDot),
                    onSubmit: () async {
                      final travelId = widget.travelId ?? '';
                      final driverId = _driverId ?? '';
                      if (travelId.isEmpty || driverId.isEmpty) {
                        _endTrip();
                        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Trip ended (local)')));
                        return;
                      }
                      // Consultar el status actual antes de decidir qué API usar
                      String currentStatus = '';
                      try {
                        final snap = await FirebaseFirestore.instance.collection('travels').doc(travelId).get();
                        currentStatus = (snap.data()?['viaje_status'] ?? '').toString();
                      } catch (_) {}
                      bool ok;
                      if (currentStatus == 'in_progress') {
                        ok = await FirebaseActionService.completeTravel(travelId, driverId);
                      } else {
                        ok = await FirebaseActionService.cancellOperationTravelTask(travelId, flagIsPassenger: false);
                      }
                      _endTrip();
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                          content: Text(ok ? 'Trip completed' : 'Trip ended locally (backend notification failed)'),
                        ));
                      }
                    },
                  ),
                ),
              ),
              const SizedBox(height: 16),
            ] else ...[
              // Collapsed: pequeño espaciado inferior
              const SizedBox(height: 16),
            ],
          ],
        ],
      ),
    );
  }

  void hideOrExpand() {
    setState(() => _sheetExpanded = !_sheetExpanded);
    hidePassengerMarker();
    _updateMapPadding();
  }

  void _showPhoneOptions() {
    final phone = _passengerPhone;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: _tsCardBg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 36, height: 4,
                  decoration: BoxDecoration(color: _tsSurface, borderRadius: BorderRadius.circular(2)),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                phone,
                style: const TextStyle(color: _tsTextMain, fontSize: 18, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 4),
              Text(
                _passengerName,
                style: const TextStyle(color: _tsTextMuted, fontSize: 13),
              ),
              const SizedBox(height: 20),
              _phoneOption(
                icon: Icons.call_rounded,
                label: 'Call passenger',
                color: const Color(0xFF4CAF50),
                onTap: () async {
                  Navigator.pop(context);
                  final uri = Uri(scheme: 'tel', path: phone);
                  if (await canLaunchUrl(uri)) await launchUrl(uri);
                },
              ),
              const SizedBox(height: 10),
              _phoneOption(
                icon: Icons.copy_rounded,
                label: 'Copy number',
                color: _tsAccent,
                onTap: () {
                  Navigator.pop(context);
                  Clipboard.setData(ClipboardData(text: phone));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Number copied'),
                      duration: Duration(seconds: 2),
                    ),
                  );
                },
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  Widget _phoneOption({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: _tsSurface,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Container(
              width: 36, height: 36,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: color, size: 18),
            ),
            const SizedBox(width: 14),
            Text(label, style: const TextStyle(color: _tsTextMain, fontSize: 15, fontWeight: FontWeight.w500)),
          ],
        ),
      ),
    );
  }

  void _showChatBottomSheet() {
    final travelId = widget.travelId ?? activeTravelIdNotifier.value ?? '';
    final driverId = _driverId ?? '';
    if (travelId.isEmpty || driverId.isEmpty) return;
    setState(() => _hasNewChatMessage = false);
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => SizedBox(
        height: MediaQuery.of(context).size.height * 0.75,
        child: _DriverChatSheet(travelId: travelId, currentUserId: driverId),
      ),
    );
  }

  /// Retorna true si la ubicación actual del conductor está a <= [thresholdMeters] del pasajero.
  bool _isNearPassenger({double thresholdMeters = 50}) {
    if (_passengerLatLng == null) return false;
    if (_currentPosition == null) return false; // no tenemos ubicación real todavía
    final dist = Geolocator.distanceBetween(
      _currentPosition!.latitude,
      _currentPosition!.longitude,
      _passengerLatLng!.latitude,
      _passengerLatLng!.longitude,
    );
    return dist <= thresholdMeters;
  }

  void _endTrip() {
    final queuedId = pendingTravelIdNotifier.value;

    _safeSetState(() {
      _passengerLatLng = null;
      _destinationLatLng = null;
      _dropoffLatLng = null;
      _passengerPickedUp = false;
      _passengerName = 'Passenger'; // reset name for the next trip
      _passengerPhone = '';
      _pendingPassengerName = '';
      _notifiedDriverNear = false;
      _notifiedDriverArrived = false;
      _checkingProximity = false;
      _markers.removeWhere((m) => m.markerId.value != 'driver');
      _polylines.clear();
      _sheetExpanded = false;
      _navigating = false;
    });
    if (driverOnTripNotifier.value) driverOnTripNotifier.value = false;
    activeTravelIdNotifier.value = null;

    // Si hay un viaje en cola, iniciarlo automáticamente
    if (queuedId != null && queuedId.isNotEmpty) {
      pendingTravelIdNotifier.value = null;
      _startQueuedTrip(queuedId);
    } else {
      // Sin viaje en cola: el driver quedó libre — resetear el contador en Firestore
      if (_driverId != null && _driverId!.isNotEmpty) {
        FirebaseFirestore.instance
            .collection('drivers')
            .doc(_driverId)
            .update({'activeTripsCount': 0})
            .catchError((e) => debugPrint('Error reseteando activeTripsCount: $e'));
      }
    }
  }

  Future<void> _startQueuedTrip(String queuedId) async {
    if (!mounted) return;

    // Capturar navigator antes del primer await para evitar usar context después de gaps asíncronos
    final nav = Navigator.of(context);

    // Mostrar popup informativo que se auto-descarta
    showDialog(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.black54,
      builder: (_) => const _StartingQueuedTripDialog(),
    );

    try {
      // El viaje ya está en travels con status 'queued' (lo puso ahí acceptTravel con queueMode:true).
      // La CF promoteQueuedTravel lo promueve a 'accepted' y actualiza currentTravelId del driver.
      // activeTripsCount ya fue decrementado por completeTravel al terminar el 1er viaje.
      final driverId = _driverId ?? '';
      if (driverId.isNotEmpty) {
        final ok = await FirebaseActionService.promoteQueuedTravel(queuedId, driverId);
        if (!ok) debugPrint('[startQueuedTrip] promoteQueuedTravel falló para $queuedId');
      }
    } catch (e) {
      debugPrint('Error promoviendo viaje en cola: $e');
    }

    await Future.delayed(const Duration(milliseconds: 1600));
    if (mounted && nav.canPop()) nav.pop();

    // Cargar el viaje como el nuevo viaje activo
    activeTravelIdNotifier.value = queuedId;
    _loadingTravelData = false;
    _notifiedDriverNear = false;
    _notifiedDriverArrived = false;
    _mapCenteredInitially = false;
    await _loadTravelData(queuedId);
  }

  /// Método unificado de proximidad.
  /// Garantiza que:
  ///  1. "driver_near"   se envía UNA sola vez cuando dist ≤ 300 m.
  ///  2. "driver_arrived" se envía UNA sola vez cuando dist ≤ 40 m.
  ///  3. "near" siempre se envía ANTES que "arrived".
  ///  4. No hay ejecuciones concurrentes (lock local).
  Future<void> _checkProximityAndNotify() async {
    // Precondiciones rápidas (sin I/O)
    if (_checkingProximity) return;
    if (_passengerPickedUp) return; // ya recogió al pasajero, no notificar
    if (_notifiedDriverArrived) return; // ya se enviaron ambas
    if (_passengerLatLng == null || _currentPosition == null) return;

    final travelId = widget.travelId ?? activeTravelIdNotifier.value ?? '';
    final driverId = _driverId ?? '';
    if (travelId.isEmpty || driverId.isEmpty) return;

    final dist = Geolocator.distanceBetween(
      _currentPosition!.latitude,
      _currentPosition!.longitude,
      _passengerLatLng!.latitude,
      _passengerLatLng!.longitude,
    );

    // Aún lejos de ambos umbrales → nada que hacer
    if (dist > 300) return;

    // — Bloquear para evitar concurrencia —
    _checkingProximity = true;
    try {
      // ── Paso 1: Notificar "cerca" (≤ 300 m) ──
      if (!_notifiedDriverNear && dist <= 300) {
        final ok = await FirebaseActionService.notifyDriverNear(travelId, driverId);
        if (ok) {
          _notifiedDriverNear = true;
          debugPrint('✔ notifyDriverNear enviado (dist=${dist.round()} m)');
        } else {
          debugPrint('✖ notifyDriverNear falló para travel=$travelId');
        }
      }

      // ── Paso 2: Notificar "llegó" (≤ 30 m) — solo si "near" ya fue enviado ──
      if (!_notifiedDriverArrived && _notifiedDriverNear && dist <= 30) {
        final ok = await FirebaseActionService.notifyDriverArrived(travelId, driverId);
        if (ok) {
          _notifiedDriverArrived = true;
          debugPrint('✔ notifyDriverArrived enviado (dist=${dist.round()} m)');
        } else {
          debugPrint('✖ notifyDriverArrived falló para travel=$travelId');
        }
      }
    } catch (e) {
      debugPrint('Error en _checkProximityAndNotify: $e');
    } finally {
      _checkingProximity = false;
    }
  }

  /// Se ejecuta una sola vez, 10 s después de entrar a TravelScreen.
  /// Solo actúa si no hay ningún viaje activo ni cargado en pantalla.
  /// Llama a la Cloud Function para rescatar notificaciones pendientes no mostradas.
  Future<void> _claimPendingBackgroundMessage() async {
    // Condiciones de salida: ya hay viaje activo o cargado
    if (!mounted) return;
    final hasActiveTravel = (activeTravelIdNotifier.value?.isNotEmpty ?? false) ||
        (widget.travelId?.isNotEmpty ?? false);
    final hasTravelData = _passengerLatLng != null || _destinationLatLng != null;
    if (hasActiveTravel || hasTravelData) return;
    if (travelDialogActive) return;
    if (_driverId == null || _driverId!.isEmpty) return;

    // Capturar contexto antes del await para evitar uso tras async gap
    final ctx = context;
    try {
      final travelId = await FirebaseActionService.claimPendingBackgroundMessage(_driverId!);
      if (travelId == null || travelId.isEmpty) return;
      if (!mounted) return;
      debugPrint('[PendingCheck] Notificación rescatada → travelId=$travelId');
      showTravelRequestDialog(ctx, travelId, null);
    } catch (e) {
      debugPrint('[PendingCheck] Error: $e');
    }
  }

  double _cameraZoomForDistance(double distMeters) {
    // Mapear distancia a un nivel de zoom razonable (aproximado)
    if (distMeters > 20000) return 11.5;
    if (distMeters > 8000) return 12.5;
    if (distMeters > 3000) return 13.5;
    if (distMeters > 1500) return 14.5;
    if (distMeters > 800) return 15.5;
    if (distMeters > 300) return 16.5;
    return 17.5;
  }

  /// Resuelve el ID real del documento del driver consultando Firestore por fullphone,
  /// luego inicia el servicio de ubicación con el ID correcto.
  Future<void> _resolveDriverIdAndStart(User user) async {
    final phone = user.phoneNumber ?? '';
    if (phone.isNotEmpty) {
      try {
        final q = await FirebaseFirestore.instance
            .collection('drivers')
            .where('fullphone', isEqualTo: phone)
            .limit(1)
            .get();
        if (q.docs.isNotEmpty) {
          driverDocId = q.docs.first.id;
          _driverId = driverDocId;
        }
      } catch (e) {
        debugPrint('Error resolviendo driverDocId: $e');
      }
    }
    _driverId ??= user.uid; // fallback: si la query falla, usar uid y arriesgarse
    if (mounted) {
      _driverLocationService.start(driverId: _driverId!, distanceFilter: 20, minIntervalSeconds: 10);
      _loadActiveVehicle();
      _subscribeOnlineStatus();
    }
  }

  void _subscribeOnlineStatus() {
    if (_driverId == null || _driverId!.isEmpty) return;
    _onlineStatusSub?.cancel();
    _onlineStatusSub = FirebaseFirestore.instance
        .collection('drivers')
        .doc(_driverId)
        .snapshots()
        .listen((snap) {
      if (!mounted) return;
      final online = snap.data()?['isOnline'] as bool?;
      if (online != _isOnline) {
        _safeSetState(() => _isOnline = online);
      }
    });
  }

  /// Intenta obtener la ubicación actual del dispositivo, solicitando permisos si es necesario.
  Future<void> _getCurrentLocation() async {
    if (!mounted) return;
    _safeSetState(() {
      _loadingLocation = true;
      _locationError = null;
    });
    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!mounted) return;
      if (!serviceEnabled) {
        _safeSetState(() {
          _locationError = 'Location services are disabled. Please enable location.';
          _loadingLocation = false;
        });
        return;
      }
      LocationPermission permission = await Geolocator.checkPermission();
      if (!mounted) return;
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (!mounted) return;
      }
      if (permission == LocationPermission.denied) {
        _safeSetState(() {
          _locationError = 'Location permission denied. Please enable it in settings.';
          _loadingLocation = false;
        });
        return;
      }
      if (permission == LocationPermission.deniedForever) {
        _safeSetState(() {
          _locationError = 'Location permission permanently denied. Open the app settings to enable it.';
          _loadingLocation = false;
        });
        return;
      }
      final pos = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high);
      if (!mounted) return;
      _currentPosition = pos;
      _driverLatLng = LatLng(pos.latitude, pos.longitude);
      _updateDriverMarker();
      if (_mapController != null && !_mapCenteredInitially) {
        try {
          await _mapController!.animateCamera(CameraUpdate.newLatLngZoom(_driverLatLng, 16));
          if (!mounted) return;
          _mapCenteredIniciallyFlagSetter();
        } catch (_) {}
      }
      _safeSetState(() {
        _loadingLocation = false;
        _locationError = null;
      });
      final travelId = widget.travelId ?? activeTravelIdNotifier.value;
      if (travelId != null && travelId.isNotEmpty) {
        // Hay un travelId conocido: cargar o restaurar según estado
        if (driverOnTripNotifier.value) {
          await _checkActiveTripAndRestore();
        } else {
          await _loadTravelData(travelId);
        }
      } else {
        // Sin travelId conocido: buscar en Firestore por si hay viaje activo.
        // Cubre el caso de inicio en frío o reinstalación.
        await _checkActiveTripAndRestore();
      }
    } catch (e) {
      debugPrint('_getCurrentLocation error: $e');
      if (!mounted) return;
      _safeSetState(() {
        _loadingLocation = false;
        _locationError = 'Error retrieving location: $e';
      });
    }
  }

  /// Abre ajustes de ubicación del sistema si es posible.
  Future<void> _openLocationSettings() async {
    try {
      final opened = await Geolocator.openLocationSettings();
      if (!opened && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not open location settings')));
      }
    } catch (e) {
      debugPrint('_openLocationSettings error: $e');
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Error opening location settings')));
    }
  }

  /// Abre los ajustes de la app para que el usuario cambie permisos.
  Future<void> _openAppSettings() async {
    try {
      final opened = await Geolocator.openAppSettings();
      if (!opened && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not open app settings')));
      }
    } catch (e) {
      debugPrint('_openAppSettings error: $e');
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Error opening app settings')));
    }
  }

  // Helper para evitar conflictos de nombre con _mapCenteredInitially en varios lugares
  void _mapCenteredIniciallyFlagSetter() {
    _mapCenteredInitially = true;
  }

  // ── Refresh manual ────────────────────────────────────────────────────────

  /// Fuerza una restauración completa del viaje activo desde Firestore.
  /// El driver puede usar esto si algo se desfasó visualmente.
  Future<void> _refresh() async {
    if (_refreshing) return;
    _safeSetState(() => _refreshing = true);
    try {
      // 1. Buscar viaje activo en Firestore (siempre, aunque no haya travelId local)
      _restoring = false; // resetear flag para que _checkActiveTripAndRestore() pueda correr
      await _checkActiveTripAndRestore();

      // 2. Si ahora tenemos un travelId, forzar recarga de datos
      final travelId = widget.travelId ?? activeTravelIdNotifier.value;
      if (travelId != null && travelId.isNotEmpty) {
        _loadingTravelData = false; // resetear throttle
        await _loadTravelData(travelId);
      }

      // 3. Actualizar la ubicación del driver
      if (_currentPosition != null) {
        _driverLatLng = LatLng(_currentPosition!.latitude, _currentPosition!.longitude);
        _updateDriverMarker();
      }

      // 4. Redibujar ruta si hay destino
      final target = _activeRouteTarget();
      if (target != null) {
        await _prepareRouteOnMap(_driverLatLng, target);
      }

      // 5. Safety net: si isOnline quedó en false por algún fallo, corregirlo
      await _ensureOnline();
    } catch (e) {
      debugPrint('_refresh error: $e');
    } finally {
      if (mounted) _safeSetState(() => _refreshing = false);
    }
  }

  /// Verifica si isOnline está en false y lo corrige a true.
  /// Se llama desde _refresh() como safety net ante fallos del sistema de presencia.
  Future<void> _ensureOnline() async {
    final docId = _driverId ?? driverDocId;
    if (docId == null) return;
    try {
      final snap = await FirebaseFirestore.instance
          .collection('drivers')
          .doc(docId)
          .get();
      if (snap.data()?['isOnline'] == false) {
        await FirebaseFirestore.instance
            .collection('drivers')
            .doc(docId)
            .update({'isOnline': true});
        debugPrint('[Presence] isOnline corregido a true vía refresh');
      }
    } catch (e) {
      debugPrint('[Presence] _ensureOnline error: $e');
    }
  }

  // ── Helpers de UI ─────────────────────────────────────────────────────────

  /// Avatar del pasajero con iniciales y color determinístico.
  Widget _buildPassengerAvatar({double radius = 22}) {
    final name = _passengerName.trim().isNotEmpty ? _passengerName : 'P';
    final initials = name.split(' ').map((w) => w.isNotEmpty ? w[0] : '').take(2).join().toUpperCase();
    final hue = (name.codeUnits.fold(0, (a, b) => a + b) % 360).toDouble();
    final avatarBg = HSVColor.fromAHSV(1.0, hue, 0.55, 0.72).toColor();
    return CircleAvatar(
      radius: radius,
      backgroundColor: avatarBg,
      child: Text(initials, style: TextStyle(fontSize: radius * 0.72, fontWeight: FontWeight.bold, color: Colors.white)),
    );
  }

  /// Chip ámbar que indica que hay un 2do viaje esperando en cola.
  /// Carga el vehículo activo (on: true) del documento del driver en Firestore.
  Future<void> _loadActiveVehicle() async {
    if (_driverId == null || _driverId!.isEmpty) return;
    try {
      final doc = await FirebaseFirestore.instance.collection('drivers').doc(_driverId).get();
      if (!doc.exists || doc.data() == null) return;
      final vehicles = doc.data()!['vehicles'];
      if (vehicles is Map) {
        vehicles.forEach((key, value) {
          if (value is Map && value['on'] == true) {
            final model = value['model']?.toString() ?? '';
            final plate = value['plate']?.toString() ?? '';
            _safeSetState(() {
              _activeVehicleBrand = value['brand']?.toString();
              _activeVehicleModel = model;
              _activeVehiclePlate = plate;
            });
            // Actualizar label global para el tab de viaje
            final parts = [model, plate].where((s) => s.isNotEmpty);
            activeVehicleLabelNotifier.value = parts.isNotEmpty ? parts.join(' · ') : '';
          }
        });
      }
    } catch (e) {
      debugPrint('Error cargando vehículo activo: $e');
    }
  }

  Widget _buildQueuedTripChip() {
    final name = _pendingPassengerName.isNotEmpty ? ' · $_pendingPassengerName' : '';
    return GestureDetector(
      onTap: _showQueuedTripSheet,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0xFFF59E0B),
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(color: const Color(0xFFF59E0B).withOpacity(0.4), blurRadius: 10, offset: const Offset(0, 3)),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.schedule_rounded, color: Colors.black87, size: 14),
            const SizedBox(width: 6),
            Text(
              'Queued Trip$name',
              style: const TextStyle(color: Colors.black87, fontSize: 12, fontWeight: FontWeight.w700),
            ),
            const SizedBox(width: 4),
            const Icon(Icons.chevron_right_rounded, color: Colors.black54, size: 16),
          ],
        ),
      ),
    );
  }

  /// Muestra un sheet con la info mínima del viaje en cola.
  void _showQueuedTripSheet() {
    final id = pendingTravelIdNotifier.value;
    if (id == null || id.isEmpty) return;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => _QueuedTripInfoSheet(travelId: id),
    );
  }

  /// Pill oscuro que flota sobre el mapa con la distancia actual.
  Widget _buildDistancePill() {
    if (_currentPosition == null) return const SizedBox.shrink();
    const double mpm = 1609.344;   // meters per mile
    const double mft = 0.3048;     // meters per foot
    String fmt(double m) {
      if (m >= mpm) {
        final mi = m / mpm;
        return '${mi < 10 ? mi.toStringAsFixed(1) : mi.toStringAsFixed(0)} mi';
      }
      return '${(m / mft).round()} ft';
    }

    String label;
    IconData icon;
    Color dotColor;

    if (!_passengerPickedUp) {
      if (_passengerLatLng == null) return const SizedBox.shrink();
      final d = Geolocator.distanceBetween(
        _currentPosition!.latitude, _currentPosition!.longitude,
        _passengerLatLng!.latitude, _passengerLatLng!.longitude,
      );
      label = 'To passenger   ${fmt(d)}';
      icon = Icons.person_pin_circle_rounded;
      dotColor = _tsOriginDot;
    } else {
      final target = _destinationLatLng ?? _dropoffLatLng;
      if (target == null) return const SizedBox.shrink();
      final d = Geolocator.distanceBetween(
        _currentPosition!.latitude, _currentPosition!.longitude,
        target.latitude, target.longitude,
      );
      label = 'To destination   ${fmt(d)}';
      icon = Icons.flag_rounded;
      dotColor = _tsDestDot;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: _tsCardBg,
        borderRadius: BorderRadius.circular(28),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.4), blurRadius: 14, offset: const Offset(0, 3))],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: dotColor),
          const SizedBox(width: 8),
          Text(label, style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  /// Indicador circular de estado online/offline del conductor.
  Widget _buildOnlineStatusBadge() {
    final online = _isOnline ?? false;
    final color = online ? const Color(0xFF22C55E) : const Color(0xFFEF4444);
    final label = online ? 'Available' : 'Offline';
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 14,
          height: 14,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            boxShadow: [BoxShadow(color: color.withOpacity(0.5), blurRadius: 6, spreadRadius: 1)],
          ),
        ),
        const SizedBox(height: 3),
        Text(label, style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w600)),
      ],
    );
  }

  /// Chip de distancia dentro del panel inferior (más detallado que el pill).
  Widget _buildInlineDistanceChip() {
    if (_currentPosition == null) return const SizedBox.shrink();
    const double mpm = 1609.344;   // meters per mile
    const double mft = 0.3048;     // meters per foot
    String fmt(double m) {
      if (m >= mpm) {
        final mi = m / mpm;
        return '${mi < 10 ? mi.toStringAsFixed(1) : mi.toStringAsFixed(0)} mi';
      }
      return '${(m / mft).round()} ft';
    }

    double? dist;
    IconData icon;
    Color dotColor;
    String prefix;

    if (!_passengerPickedUp && _passengerLatLng != null) {
      dist = Geolocator.distanceBetween(
        _currentPosition!.latitude, _currentPosition!.longitude,
        _passengerLatLng!.latitude, _passengerLatLng!.longitude,
      );
      icon = Icons.person_pin_circle_rounded;
      dotColor = _tsOriginDot;
      prefix = 'To passenger';
    } else if (_passengerPickedUp) {
      final target = _destinationLatLng ?? _dropoffLatLng;
      if (target != null) {
        dist = Geolocator.distanceBetween(
          _currentPosition!.latitude, _currentPosition!.longitude,
          target.latitude, target.longitude,
        );
      }
      icon = Icons.flag_rounded;
      dotColor = _tsDestDot;
      prefix = 'To destination';
    } else {
      return const SizedBox.shrink();
    }
    if (dist == null) return const SizedBox.shrink();

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(color: _tsSurface, borderRadius: BorderRadius.circular(12)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: dotColor),
          const SizedBox(width: 8),
          Text('$prefix  ', style: const TextStyle(color: _tsTextMuted, fontSize: 12)),
          Text(fmt(dist), style: const TextStyle(color: _tsTextMain, fontSize: 14, fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }

  /// Botón "INICIAR VIAJE": activado solo cuando el driver está a ≤ 30 m del pasajero.
  Widget _buildStartTripButton() {
    final near = _isNearPassenger(thresholdMeters: 30);
    return GestureDetector(
      onTap: near ? () {
        setState(() {
          _passengerPickedUp = true;
          _showPassengerMarker = false;
          _markers.removeWhere((m) => m.markerId.value == 'passenger');
        });
        driverOnTripNotifier.value = true;
        hidePassengerMarker();
        _startNavigation();
      } : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        height: 56,
        decoration: BoxDecoration(
          color: near ? _tsOriginDot : _tsSurface,
          borderRadius: BorderRadius.circular(16),
          boxShadow: near ? [BoxShadow(color: _tsOriginDot.withOpacity(0.35), blurRadius: 12, offset: const Offset(0, 4))] : [],
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.play_arrow_rounded, color: near ? _tsCardBg : _tsTextMuted, size: 22),
            const SizedBox(width: 8),
            Text(
              near ? 'START TRIP' : 'START TRIP  —  get closer to the passenger',
              style: TextStyle(fontSize: near ? 15 : 12, fontWeight: FontWeight.w700, color: near ? _tsCardBg : _tsTextMuted, letterSpacing: 0.4),
            ),
          ],
        ),
      ),
    );
  }

}

// ── Dialog que aparece al iniciar automáticamente el viaje en cola ────────────
class _StartingQueuedTripDialog extends StatelessWidget {
  const _StartingQueuedTripDialog();

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF1E1E26),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(color: Color(0xFF6366F1), strokeWidth: 2.5),
            const SizedBox(height: 20),
            const Text(
              'Starting queued\ntrip...',
              style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600, height: 1.4),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

// ── Sheet con info mínima del viaje en cola (al tocar el chip) ────────────────
class _QueuedTripInfoSheet extends StatefulWidget {
  final String travelId;
  const _QueuedTripInfoSheet({required this.travelId});

  @override
  State<_QueuedTripInfoSheet> createState() => _QueuedTripInfoSheetState();
}

class _QueuedTripInfoSheetState extends State<_QueuedTripInfoSheet> {
  static const _bg      = Color(0xFF1E1E26);
  static const _surface = Color(0xFF2A2A34);
  static const _amber   = Color(0xFFF59E0B);
  static const _green   = Color(0xFF6EE7B7);
  static const _red     = Color(0xFFEF4444);
  static const _muted   = Color(0xFFA0A0AB);
  static const _line    = Color(0xFF3F3F46);

  bool _loading = true;
  String _passengerName = '';
  String _origin = '';
  String _destination = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      // El viaje en cola puede estar en requestTravel antes de promoverse a travels
      DocumentSnapshot<Map<String, dynamic>> doc =
          await FirebaseFirestore.instance.collection('travels').doc(widget.travelId).get();
      if (!doc.exists) {
        doc = await FirebaseFirestore.instance.collection('requestTravel').doc(widget.travelId).get();
      }
      if (!doc.exists || !mounted) { setState(() => _loading = false); return; }
      final data = doc.data() ?? {};

      // Nombre del pasajero
      final userId = data['userId']?.toString() ?? '';
      if (userId.isNotEmpty) {
        final ud = await FirebaseFirestore.instance.collection('users').doc(userId).get();
        if (ud.exists) {
          final udata = ud.data() ?? {};
          _passengerName = (udata['name'] ?? udata['nombre'] ?? udata['displayName'] ?? '').toString().trim();
        }
      }
      if (_passengerName.isEmpty) _passengerName = 'Passenger';

      // Direcciones
      _origin = data['origin_address']?.toString() ?? '';
      _destination = data['destination']?.toString() ?? '';

      if (_origin.isEmpty && data['description'] is Map) {
        _origin = (data['description'] as Map)['origin']?.toString() ?? '';
      }
      if (_destination.isEmpty && data['description'] is Map) {
        _destination = (data['description'] as Map)['destination']?.toString() ?? '';
      }
      if (_origin.isEmpty) _origin = 'Origin not specified';
      if (_destination.isEmpty) _destination = 'Destination not specified';
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: _bg,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Handle
              Center(
                child: Container(
                  width: 40, height: 4,
                  decoration: BoxDecoration(color: _line, borderRadius: BorderRadius.circular(2)),
                ),
              ),
              const SizedBox(height: 16),

              // Encabezado con badge
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: _amber.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: _amber.withOpacity(0.4)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: const [
                        Icon(Icons.schedule_rounded, size: 13, color: _amber),
                        SizedBox(width: 5),
                        Text('Queued Trip', style: TextStyle(color: _amber, fontSize: 12, fontWeight: FontWeight.w700)),
                      ],
                    ),
                  ),
                  const Spacer(),
                  const Text(
                    'Starts once the current trip ends',
                    style: TextStyle(color: _muted, fontSize: 11),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              if (_loading)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 20),
                  child: CircularProgressIndicator(color: _amber, strokeWidth: 2),
                )
              else ...[
                // Nombre pasajero
                Row(
                  children: [
                    CircleAvatar(
                      radius: 20,
                      backgroundColor: _surface,
                      child: Text(
                        _passengerName.isNotEmpty ? _passengerName[0].toUpperCase() : 'P',
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      _passengerName,
                      style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w700),
                    ),
                  ],
                ),
                const SizedBox(height: 14),

                // Tarjeta de ruta
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  decoration: BoxDecoration(color: _surface, borderRadius: BorderRadius.circular(14)),
                  child: IntrinsicHeight(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Column(
                          mainAxisSize: MainAxisSize.max,
                          children: [
                            Container(width: 9, height: 9, decoration: const BoxDecoration(color: _green, shape: BoxShape.circle)),
                            Expanded(child: Center(child: Container(width: 2, color: _line))),
                            Container(width: 9, height: 9, decoration: BoxDecoration(color: _red, borderRadius: BorderRadius.circular(2))),
                          ],
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(_origin, style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w500), maxLines: 2, overflow: TextOverflow.ellipsis),
                              const SizedBox(height: 12),
                              Text(_destination, style: const TextStyle(color: _muted, fontSize: 13), maxLines: 2, overflow: TextOverflow.ellipsis),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// Implementación local de CustomSlideAction (swipe to confirm) para terminar viaje
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
    this.text = 'Slide',
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
      setState(() {
        _submitted = true;
        _loading = true; // mostrar spinner mientras se ejecuta onSubmit
      });
      try {
        await widget.onSubmit?.call();
        if (mounted) await Future.delayed(const Duration(milliseconds: 300));
        // leave it slid and show check
      } catch (_) {
        if (mounted) {
          _animateTo(0);
          setState(() {
            _submitted = false;
            _locked = false;
            _loading = false;
          });
        }
      }
      // Si llegó hasta aquí y no hubo excepción, mantener el check y detener el loading
      if (mounted) setState(() => _loading = false);
    } else {
      _animateTo(0);
      setState(() => _submitted = false);
    }
  }

  bool _loading = false; // indica que la acción está en progreso

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final totalWidth = constraints.maxWidth;
      final sliderSize = widget.height - 16;
      _maxDx = (totalWidth - sliderSize - 16).clamp(0.0, double.infinity);
      return Container(
        height: widget.height,
        decoration: BoxDecoration(
            color: widget.outerColor, borderRadius: BorderRadius.circular(52)),
        child: Stack(
          alignment: Alignment.centerLeft,
          children: [
            Center(
              child: Opacity(
                opacity: _submitted || _loading ? 0.0 : 1.0,
                child: Text(widget.text, style: widget.textStyle ??
                    const TextStyle(color: Colors.white, fontSize: 18)),
              ),
            ),
            Positioned(
              left: 8 + _dx,
              child: GestureDetector(
                onHorizontalDragUpdate: (details) {
                  // bloquear interacción si ya está en progreso
                  if (_locked || _submitted || _loading) return;
                  setState(() {
                    _dx = (_dx + details.delta.dx).clamp(0.0, _maxDx);
                  });
                },
                onHorizontalDragEnd: (_) async {
                  if (_loading) return;
                  await _onPanEnd();
                },
                child: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(color: widget.innerColor,
                      borderRadius: BorderRadius.circular(52)),
                  child: SizedBox(
                    height: sliderSize,
                    width: sliderSize,
                    child: Center(
                      child: _loading
                          ? SizedBox(width: sliderSize * 0.6,
                          height: sliderSize * 0.6,
                          child: const CircularProgressIndicator(
                              strokeWidth: 2))
                          : (_submitted ? Icon(
                          Icons.check, color: widget.outerColor) : (widget
                          .sliderButtonIcon ??
                          Icon(Icons.arrow_forward, color: widget.outerColor))),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    }
    );
  }
}

// ── Driver Chat Sheet ──────────────────────────────────────────────────────

class _DriverChatSheet extends StatefulWidget {
  final String travelId;
  final String currentUserId;

  const _DriverChatSheet(
      {required this.travelId, required this.currentUserId});

  @override
  State<_DriverChatSheet> createState() => _DriverChatSheetState();
}

class _DriverChatSheetState extends State<_DriverChatSheet> {
  final _textController = TextEditingController();
  bool _sending = false;

  static const Color _bg             = Color(0xFF1E1E26);
  static const Color _surface        = Color(0xFF2A2A34);
  static const Color _accent         = Color(0xFF6366F1);
  static const Color _receivedBubble = Color(0xFF1E3A54); // azul navy para mensajes del pasajero
  static const Color _textMain       = Colors.white;
  static const Color _textMuted      = Color(0xFFA0A0AB);
  static const Color _divider        = Color(0xFF3F3F46);

  static const List<String> _quickReplies = [
    "On my way",
    "I've arrived",
    "Be right there",
    "Ok",
    "Wait a moment",
  ];

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  Future<void> _send(String text) async {
    if (text.trim().isEmpty || _sending) return;
    setState(() => _sending = true);
    _textController.clear();
    try {
      debugPrint('[Chat] Enviando → travelId=${widget.travelId} uid=${widget.currentUserId} text="$text"');
      await ChatService.sendMessage(widget.travelId, text);
      debugPrint('[Chat] Enviado OK');
    } catch (e, st) {
      debugPrint('[Chat] ERROR al enviar: $e\n$st');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not send message: $e'),
            backgroundColor: const Color(0xFFEF4444),
          ),
        );
        _textController.text = text;
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: _bg,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        children: [
          // Handle
          Padding(
            padding: const EdgeInsets.only(top: 10, bottom: 4),
            child: Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: _divider,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          // Encabezado
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 8, 20, 10),
            child: Row(
              children: [
                Icon(Icons.chat_bubble_outline_rounded,
                    color: _accent, size: 18),
                SizedBox(width: 8),
                Text(
                  'Trip Chat',
                  style: TextStyle(
                    color: _textMain,
                    fontWeight: FontWeight.w700,
                    fontSize: 16,
                  ),
                ),
              ],
            ),
          ),
          Container(height: 1, color: _divider),
          // Lista de mensajes
          Expanded(
            child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: ChatService.messagesStream(widget.travelId),
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  debugPrint('[Chat] StreamBuilder error: ${snapshot.error}');
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        'Could not load messages.\n${snapshot.error}',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            color: Color(0xFFEF4444),
                            fontSize: 12,
                            height: 1.6),
                      ),
                    ),
                  );
                }
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation<Color>(_accent),
                    ),
                  );
                }
                final docs = snapshot.data?.docs ?? [];
                if (docs.isEmpty) {
                  return const Center(
                    child: Text(
                      'No messages yet.\nSend a message to your passenger.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          color: _textMuted, fontSize: 14, height: 1.7),
                    ),
                  );
                }
                return ListView.builder(
                  reverse: true,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 12),
                  itemCount: docs.length,
                  itemBuilder: (context, index) {
                    final msg        = docs[index].data();
                    final senderType = msg['senderType'] as int?;
                    // senderType 2 = driver (yo), 1 = pasajero
                    // Fallback a senderId si el campo aún no está escrito
                    final isMe = senderType != null
                        ? senderType == 2
                        : msg['senderId'] == widget.currentUserId;
                    return _buildBubble(
                        msg['text'] as String? ?? '', isMe);
                  },
                );
              },
            ),
          ),
          // Respuestas rápidas
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Row(
              children: _quickReplies
                  .map((r) => Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: GestureDetector(
                          onTap: () => _send(r),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 14, vertical: 7),
                            decoration: BoxDecoration(
                              color: _surface,
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(
                                  color: _accent.withValues(alpha: 0.35)),
                            ),
                            child: Text(
                              r,
                              style: const TextStyle(
                                color: _accent,
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ),
                      ))
                  .toList(),
            ),
          ),
          // Input
          Padding(
            padding: EdgeInsets.only(
              left: 16,
              right: 16,
              bottom: MediaQuery.of(context).viewInsets.bottom + 12,
              top: 6,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      color: _surface,
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(color: _divider),
                    ),
                    child: TextField(
                      controller: _textController,
                      style: const TextStyle(
                          color: _textMain, fontSize: 14),
                      maxLines: null,
                      keyboardType: TextInputType.multiline,
                      textInputAction: TextInputAction.send,
                      onSubmitted: _send,
                      decoration: const InputDecoration(
                        hintText: 'Message...',
                        hintStyle: TextStyle(color: _textMuted),
                        border: InputBorder.none,
                        contentPadding: EdgeInsets.symmetric(
                            horizontal: 16, vertical: 10),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: () => _send(_textController.text),
                  child: Container(
                    width: 44,
                    height: 44,
                    decoration: const BoxDecoration(
                      color: _accent,
                      shape: BoxShape.circle,
                    ),
                    child: _sending
                        ? const Padding(
                            padding: EdgeInsets.all(12),
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor: AlwaysStoppedAnimation<Color>(
                                  Colors.white),
                            ),
                          )
                        : const Icon(Icons.send_rounded,
                            color: Colors.white, size: 20),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBubble(String text, bool isMe) {
    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Column(
        crossAxisAlignment:
            isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 4, right: 4, bottom: 2),
            child: Text(
              isMe ? 'You' : 'Passenger',
              style: TextStyle(
                color: isMe
                    ? _accent.withValues(alpha: 0.7)
                    : _textMuted,
                fontSize: 10,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.4,
              ),
            ),
          ),
          Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * 0.72),
            decoration: BoxDecoration(
              color: isMe ? _accent : _receivedBubble,
              borderRadius: BorderRadius.only(
                topLeft: const Radius.circular(16),
                topRight: const Radius.circular(16),
                bottomLeft: Radius.circular(isMe ? 16 : 4),
                bottomRight: Radius.circular(isMe ? 4 : 16),
              ),
              border: isMe
                  ? null
                  : Border.all(color: const Color(0xFF2A5080), width: 0.8),
            ),
            child: Text(
              text,
              style: TextStyle(
                color: isMe ? Colors.white : _textMain,
                fontSize: 14,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
