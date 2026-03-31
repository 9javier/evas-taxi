import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import 'firebase_action_service.dart';
import 'app_state.dart';

// Estados compartidos para controlar el diálogo de viaje
bool travelDialogActive = false;
String? lastTravelIdHandled;

Future<void> playAlertSound() async {
  final player = AudioPlayer();
  try {
    await player.setVolume(1.0);
    await player.play(AssetSource('sound1.mp3'));
  } catch (_) {
    // Ignorar errores
  }
}

Future<void> _handleSlideAccept(BuildContext context, String travelId) async {
  lastTravelIdHandled = travelId;

  final user = FirebaseAuth.instance.currentUser;
  if (user == null) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No estás autenticado.')));
    }
    return;
  }

  try {
    final accepted = await FirebaseActionService.acceptTravel(travelId, user.uid);
    if (accepted) {
      final prev = activeTravelIdNotifier.value;
      activeTravelIdNotifier.value = travelId;
      if (prev == travelId) {
        activeTravelIdNotifier.value = null;
        Future.microtask(() => activeTravelIdNotifier.value = travelId);
      }
      tabsIndexNotifier.value = 0;
    } else {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No se pudo aceptar el viaje. Intenta de nuevo.')));
      }
    }
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Error al aceptar el viaje.')));
    }
  }
}

// Envia la notificaciòn al pasajero de que el chofer ha llegado
Future<void> notifyDriverArrived() async {
  final travelId = activeTravelIdNotifier.value;
  final user = FirebaseAuth.instance.currentUser;
  if (travelId == null || user == null) return;

  try {
    await FirebaseActionService.notifyDriverArrived(travelId, user.uid);
  } catch (_) {
    // Ignorar errores
  }
}

Future<void> showTravelRequestDialog(BuildContext context, String travelId, String? phoneNumber) async {
  // Verificar existencia en Firestore antes de mostrar
  DocumentSnapshot<Map<String, dynamic>>? travelDoc;
  try {
    travelDoc = await FirebaseFirestore.instance.collection('requestTravel').doc(travelId).get();
    if (!travelDoc.exists) return;
  } catch (_) {
    return;
  }

  final data = travelDoc.data() ?? {};

  LatLng? parseCoord(dynamic v) {
    if (v == null) return null;
    if (v is GeoPoint) return LatLng(v.latitude, v.longitude);
    if (v is Map) {
      final lat = v['lat'] ?? v['latitude'] ?? v['latitud'];
      final lng = v['lng'] ?? v['longitude'] ?? v['lngitud'];
      final latD = lat is num ? lat.toDouble() : (lat is String ? double.tryParse(lat) : null);
      final lngD = lng is num ? lng.toDouble() : (lng is String ? double.tryParse(lng) : null);
      if (latD != null && lngD != null) return LatLng(latD, lngD);
    }
    if (v is List && v.length >= 2) {
      final lat = v[0];
      final lng = v[1];
      final latD = lat is num ? lat.toDouble() : (lat is String ? double.tryParse(lat) : null);
      final lngD = lng is num ? lng.toDouble() : (lng is String ? double.tryParse(lng) : null);
      if (latD != null && lngD != null) return LatLng(latD, lngD);
    }
    return null;
  }

  // Obtener descripción de origen y destino
  String originDesc = '';
  String destinoDesc = '';
  if (data.containsKey('description') && data['description'] is Map) {
    final desc = data['description'] as Map;
    originDesc = desc['origin']?.toString() ?? desc['pickup']?.toString() ?? '';
    destinoDesc = desc['destination']?.toString() ?? desc['destino']?.toString() ?? '';
  }
  if (originDesc.isEmpty) {
    originDesc = data['originDesc']?.toString() ?? data['pickupDesc']?.toString() ?? 'Origen no especificado';
  }
  if (destinoDesc.isEmpty) {
    destinoDesc = data['destinoDesc']?.toString() ?? data['destinationDesc']?.toString() ?? 'Destino no especificado';
  }

  final LatLng? originLatLng = parseCoord(data['origin'] ?? data['origen'] ?? data['pickup']);
  final LatLng? destLatLng = parseCoord(data['destino'] ?? data['destination'] ?? data['dest'] ?? data['to']);

  if (travelDialogActive) return;
  if (lastTravelIdHandled == travelId) return;
  travelDialogActive = true;

  await playAlertSound();

  if (!context.mounted) {
    travelDialogActive = false;
    return;
  }

  showDialog(
    context: context,
    barrierDismissible: false,
    builder: (context) {
      return Dialog(
        insetPadding: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: SizedBox(
          width: MediaQuery.of(context).size.width,
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  height: 40,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      const Text(
                        'Nueva solicitud de Viaje',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                        textAlign: TextAlign.center,
                      ),
                      Positioned(
                        right: 0,
                        child: IconButton(
                          icon: const Icon(Icons.close, color: Colors.red),
                          tooltip: 'Cerrar',
                          onPressed: () {
                            travelDialogActive = false;
                            if (Navigator.of(context).canPop()) Navigator.of(context).pop();
                          },
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints.tightFor(width: 32, height: 32),
                          iconSize: 22,
                          splashRadius: 18,
                          visualDensity: VisualDensity.compact,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                if (originDesc.isNotEmpty) const SizedBox(height: 8),
                if (originDesc.isNotEmpty) Text('Origen: $originDesc', style: const TextStyle(fontSize: 12)),
                if (destinoDesc.isNotEmpty) const SizedBox(height: 8),
                if (destinoDesc.isNotEmpty) Text(('Destino: $destinoDesc'), style: const TextStyle(fontSize: 12)),
                const SizedBox(height: 12),
                SizedBox(
                  height: 200,
                  child: originLatLng != null || destLatLng != null
                      ? MapPreview(origin: originLatLng, destination: destLatLng)
                      : Center(child: Text('No hay coordenadas disponibles', style: TextStyle(color: Colors.grey[700]))),
                ),
                const SizedBox(height: 32),
                CustomSlideAction(
                  text: 'Desliza para aceptar',
                  textStyle: const TextStyle(fontSize: 18, color: Colors.white),
                  outerColor: Colors.green,
                  innerColor: Colors.white,
                  height: 60,
                  sliderButtonIcon: const Icon(Icons.arrow_forward, color: Colors.green),
                  onSubmit: () async => await _handleSlideAccept(context, travelId),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

// Custom slide action (copiado desde main.dart)
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

// MapPreview (copiado desde main.dart)
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
