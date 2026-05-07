import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:audioplayers/audioplayers.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart' as svg;
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
  } catch (_) {}
}

Future<void> _handleSlideAccept(BuildContext context, String travelId) async {
  lastTravelIdHandled = travelId;

  final user = FirebaseAuth.instance.currentUser;
  if (user == null) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('You are not authenticated.')));
    }
    return;
  }

  try {
    final accepted = await FirebaseActionService.acceptTravel(travelId, driverDocId ?? user.uid);
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
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not accept the trip. Please try again.')));
      }
    }
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('An error occurred while accepting the trip.')));
    }
  }
}

/// Pone el viaje en cola cuando el driver ya tiene uno activo.
/// Usa acceptTravel con queueMode=true: mueve requestTravel → travels con status 'queued'
/// e incrementa activeTripsCount, igual que una aceptación normal pero sin iniciar el viaje.
Future<void> _handleSlideQueue(BuildContext context, String travelId) async {
  lastTravelIdHandled = travelId;

  final user = FirebaseAuth.instance.currentUser;
  if (user == null) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('You are not authenticated.')));
    }
    return;
  }

  try {
    final accepted = await FirebaseActionService.acceptTravel(travelId, driverDocId ?? user.uid, queueMode: true);
    if (accepted) {
      pendingTravelIdNotifier.value = travelId;
      tabsIndexNotifier.value = 0;
    } else {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('This trip is no longer available or could not be queued.')));
      }
    }
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('An error occurred while queueing the trip.')));
    }
  }
}

Future<void> notifyDriverArrived() async {
  final travelId = activeTravelIdNotifier.value;
  final user = FirebaseAuth.instance.currentUser;
  if (travelId == null || user == null) return;
  try {
    await FirebaseActionService.notifyDriverArrived(travelId, driverDocId ?? user.uid);
  } catch (_) {}
}

Future<void> showTravelRequestDialog(BuildContext context, String travelId, String? phoneNumber) async {
  // Buscar el documento: primero en 'travels', luego en 'requestTravel' como fallback
  DocumentSnapshot<Map<String, dynamic>>? travelDoc;
  try {
    travelDoc = await FirebaseFirestore.instance.collection('travels').doc(travelId).get();
    if (!travelDoc.exists) {
      travelDoc = await FirebaseFirestore.instance.collection('requestTravel').doc(travelId).get();
      if (!travelDoc.exists) return;
    }
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

  // Direcciones: el schema real usa 'origin_address' y 'destination' como strings directos.
  // 'destino' y 'origin' son los objetos de coordenadas.
  String originDesc = data['origin_address']?.toString() ?? '';
  String destinoDesc = data['destination']?.toString() ?? '';

  // Fallbacks para otros esquemas
  if (originDesc.isEmpty && data.containsKey('description') && data['description'] is Map) {
    final desc = data['description'] as Map;
    originDesc = desc['origin']?.toString() ?? desc['pickup']?.toString() ?? '';
  }
  if (destinoDesc.isEmpty && data.containsKey('description') && data['description'] is Map) {
    final desc = data['description'] as Map;
    destinoDesc = desc['destination']?.toString() ?? desc['destino']?.toString() ?? '';
  }
  if (originDesc.isEmpty) originDesc = data['originDesc']?.toString() ?? data['pickupDesc']?.toString() ?? 'Origin not specified';
  if (destinoDesc.isEmpty) destinoDesc = data['destinoDesc']?.toString() ?? data['destinationDesc']?.toString() ?? 'Destination not specified';

  // Coordenadas: 'origin' y 'destino' son los campos con lat/lng en el schema real
  final LatLng? originLatLng = parseCoord(data['origin'] ?? data['origen'] ?? data['pickup']);
  final LatLng? destLatLng = parseCoord(data['destino'] ?? data['destination_coords'] ?? data['dest'] ?? data['to']);

  // Nombre del pasajero: buscar en 'users/{userId}'
  String passengerName = 'Pasajero';
  final userId = data['userId']?.toString() ?? '';
  if (userId.isNotEmpty) {
    try {
      final userDoc = await FirebaseFirestore.instance.collection('users').doc(userId).get();
      if (userDoc.exists) {
        final userData = userDoc.data() ?? {};
        passengerName = userData['name']?.toString().trim() ??
            userData['nombre']?.toString().trim() ??
            userData['displayName']?.toString().trim() ??
            'Passenger';
        if (passengerName.isEmpty) passengerName = 'Passenger';
      }
    } catch (_) {
      // Silencioso: usar nombre default si falla el lookup
    }
  }

  // Bloquear si ya tiene un viaje en cola — el driver no puede tener más de 2
  if (pendingTravelIdNotifier.value != null && pendingTravelIdNotifier.value!.isNotEmpty) return;

  if (travelDialogActive) return;
  if (lastTravelIdHandled == travelId) return;
  travelDialogActive = true;

  // Determinar si el driver ya tiene un viaje activo (modo cola vs. modo normal)
  final bool isQueueMode = activeTravelIdNotifier.value != null && activeTravelIdNotifier.value!.isNotEmpty;

  await playAlertSound();

  if (!context.mounted) {
    travelDialogActive = false;
    return;
  }

  showDialog(
    context: context,
    barrierDismissible: false,
    barrierColor: Colors.black.withOpacity(0.6),
    builder: (context) => _TravelRequestSheet(
      travelId: travelId,
      passengerName: passengerName,
      originDesc: originDesc,
      destinoDesc: destinoDesc,
      originLatLng: originLatLng,
      destLatLng: destLatLng,
      isQueueMode: isQueueMode,
    ),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Widget del sheet de solicitud de viaje — tema Dark Premium
// ─────────────────────────────────────────────────────────────────────────────

class _TravelRequestSheet extends StatefulWidget {
  final String travelId;
  final String passengerName;
  final String originDesc;
  final String destinoDesc;
  final LatLng? originLatLng;
  final LatLng? destLatLng;
  // true cuando el driver ya tiene un viaje activo — se pondrá en cola, no iniciará ya
  final bool isQueueMode;

  const _TravelRequestSheet({
    required this.travelId,
    required this.passengerName,
    required this.originDesc,
    required this.destinoDesc,
    this.originLatLng,
    this.destLatLng,
    this.isQueueMode = false,
  });

  @override
  State<_TravelRequestSheet> createState() => _TravelRequestSheetState();
}

class _TravelRequestSheetState extends State<_TravelRequestSheet> with SingleTickerProviderStateMixin {
  static const int _timeoutSecs = 90; // 1 minuto 30 segundos

  // ── Paleta Dark Premium ─────────────────────────────────────────────────────
  static const _bg         = Color(0xFF1E1E26);
  static const _surface    = Color(0xFF2A2A34);
  static const _textMain   = Colors.white;
  static const _textMuted  = Color(0xFFA0A0AB);
  static const _accent     = Color(0xFF6366F1); // índigo
  static const _originDot  = Color(0xFF6EE7B7); // verde esmeralda claro
  static const _destDot    = Color(0xFFEF4444); // rojo
  static const _routeLine  = Color(0xFF3F3F46);
  static const _handle     = Color(0xFF3F3F46);
  static const double _cardRadius      = 16.0;
  static const double _sheetTopRadius  = 24.0;

  late AnimationController _countdownController;
  late Animation<double> _countdownAnim;
  int _secondsLeft = _timeoutSecs;
  Timer? _ticker;

  // ── Lifecycle ───────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _countdownController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: _timeoutSecs),
    );
    _countdownAnim = Tween<double>(begin: 1.0, end: 0.0).animate(
      CurvedAnimation(parent: _countdownController, curve: Curves.linear),
    );
    _countdownController.forward();

    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _secondsLeft--);
      if (_secondsLeft <= 0) _dismiss();
    });
  }

  @override
  void dispose() {
    _countdownController.dispose();
    _ticker?.cancel();
    super.dispose();
  }

  void _dismiss() {
    travelDialogActive = false;
    if (mounted && Navigator.of(context).canPop()) Navigator.of(context).pop();
  }

  // ── Widgets internos ────────────────────────────────────────────────────────

  Widget _buildAvatarSection() {
    final initials = widget.passengerName.trim().isNotEmpty
        ? widget.passengerName.trim().split(' ').map((w) => w.isNotEmpty ? w[0] : '').take(2).join().toUpperCase()
        : '?';

    // Color determinístico basado en el nombre
    final hue = (widget.passengerName.codeUnits.fold(0, (a, b) => a + b) % 360).toDouble();
    final avatarBg = HSVColor.fromAHSV(1.0, hue, 0.55, 0.72).toColor();

    // Color del ring según segundos restantes
    final ringColor = _secondsLeft > 8 ? _accent : _destDot;
    const numColor = Colors.white; // Dark Premium: texto blanco siempre

    return AnimatedBuilder(
      animation: _countdownAnim,
      builder: (_, __) => SizedBox(
        width: 88,
        height: 88,
        child: Stack(
          alignment: Alignment.center,
          children: [
            CustomPaint(
              size: const Size(88, 88),
              painter: _CountdownRingPainter(
                progress: _countdownAnim.value,
                trackColor: _routeLine,
                progressColor: ringColor,
                strokeWidth: 4.0,
              ),
            ),
            CircleAvatar(
              radius: 36,
              backgroundColor: avatarBg,
              child: Text(
                initials,
                style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.white),
              ),
            ),
            Positioned(
              bottom: 0,
              right: 0,
              child: Container(
                width: 26,
                height: 26,
                decoration: BoxDecoration(
                  color: ringColor,
                  shape: BoxShape.circle,
                  border: Border.all(color: _bg, width: 2),
                ),
                alignment: Alignment.center,
                child: Text(
                  '$_secondsLeft',
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: numColor),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRouteCard() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(_cardRadius),
      ),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Línea visual origen → destino: dot arriba, línea elástica, dot abajo
            Column(
              mainAxisSize: MainAxisSize.max,
              children: [
                Container(width: 10, height: 10, decoration: BoxDecoration(color: _originDot, shape: BoxShape.circle)),
                Expanded(child: Center(child: Container(width: 2, color: _routeLine))),
                Container(width: 10, height: 10, decoration: BoxDecoration(color: _destDot, borderRadius: BorderRadius.circular(2))),
              ],
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(widget.originDesc, style: const TextStyle(color: _textMain, fontSize: 13, fontWeight: FontWeight.w500), maxLines: 2, overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 14),
                  Text(widget.destinoDesc, style: const TextStyle(color: _textMuted, fontSize: 13), maxLines: 2, overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Build ───────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    // Material wrapper previene subrayados amarillos en texto fuera de Scaffold
    return Material(
      type: MaterialType.transparency,
      child: Align(
        alignment: Alignment.bottomCenter,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeInOut,
          width: double.infinity,
          decoration: BoxDecoration(
            color: _bg,
            borderRadius: BorderRadius.vertical(top: Radius.circular(_sheetTopRadius)),
            boxShadow: [BoxShadow(color: Colors.black.withAlpha(60), blurRadius: 24, offset: const Offset(0, -4))],
          ),
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Handle
                  Center(
                    child: Container(
                      width: 40, height: 4,
                      decoration: BoxDecoration(color: _handle, borderRadius: BorderRadius.circular(2)),
                    ),
                  ),
                  const SizedBox(height: 20),

                  // ── Pasajero ───────────────────────────────────────
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      _buildAvatarSection(),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Text(
                                  widget.isQueueMode ? 'QUEUED TRIP' : 'NEW RIDE REQUEST',
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w700,
                                    color: widget.isQueueMode ? const Color(0xFFF59E0B) : _accent,
                                    letterSpacing: 0.9,
                                  ),
                                ),
                                if (widget.isQueueMode) ...[
                                  const SizedBox(width: 6),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFFF59E0B).withOpacity(0.15),
                                      borderRadius: BorderRadius.circular(4),
                                      border: Border.all(color: const Color(0xFFF59E0B).withOpacity(0.4)),
                                    ),
                                    child: const Text(
                                      '2nd ride',
                                      style: TextStyle(fontSize: 9, color: Color(0xFFF59E0B), fontWeight: FontWeight.w600),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                            const SizedBox(height: 5),
                            Text(
                              widget.passengerName,
                              style: TextStyle(color: _textMain, fontSize: 20, fontWeight: FontWeight.w700),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 4),
                            Row(
                              children: [
                                Icon(Icons.person_outline_rounded, size: 13, color: _textMuted),
                                const SizedBox(width: 4),
                                Text('Passenger', style: TextStyle(fontSize: 12, color: _textMuted)),
                              ],
                            ),
                          ],
                        ),
                      ),
                      // Cerrar
                      GestureDetector(
                        onTap: _dismiss,
                        child: Container(
                          width: 32, height: 32,
                          decoration: BoxDecoration(color: _surface, shape: BoxShape.circle),
                          child: Icon(Icons.close, size: 16, color: _textMuted),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),

                  // ── Ruta ───────────────────────────────────────────
                  _buildRouteCard(),
                  const SizedBox(height: 12),

                  // ── Mapa ───────────────────────────────────────────
                  if (widget.originLatLng != null || widget.destLatLng != null)
                    ClipRRect(
                      borderRadius: BorderRadius.circular(_cardRadius),
                      child: SizedBox(
                        height: 158,
                        child: MapPreview(origin: widget.originLatLng, destination: widget.destLatLng),
                      ),
                    ),
                  const SizedBox(height: 16),

                  // ── Nota informativa en modo cola ──────────────────
                  if (widget.isQueueMode) ...[
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF59E0B).withOpacity(0.08),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: const Color(0xFFF59E0B).withOpacity(0.25)),
                      ),
                      child: Row(
                        children: const [
                          Icon(Icons.info_outline_rounded, size: 14, color: Color(0xFFF59E0B)),
                          SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Will start once your current trip is complete.',
                              style: TextStyle(fontSize: 12, color: Color(0xFFF59E0B)),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],

                  // ── Slide to accept / queue ────────────────────────
                  CustomSlideAction(
                    text: widget.isQueueMode ? 'Slide to queue' : 'Slide to accept',
                    textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: Colors.white, letterSpacing: 0.3),
                    outerColor: widget.isQueueMode ? const Color(0xFFF59E0B) : _accent,
                    innerColor: Colors.white,
                    height: 60,
                    sliderButtonIcon: Icon(
                      widget.isQueueMode ? Icons.schedule_rounded : Icons.arrow_forward_rounded,
                      color: widget.isQueueMode ? const Color(0xFFF59E0B) : _accent,
                    ),
                    onSubmit: () async => widget.isQueueMode
                        ? await _handleSlideQueue(context, widget.travelId)
                        : await _handleSlideAccept(context, widget.travelId),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Painter para el ring de countdown alrededor del avatar
// ─────────────────────────────────────────────────────────────────────────────

class _CountdownRingPainter extends CustomPainter {
  final double progress;      // 1.0 = lleno, 0.0 = vacío
  final Color trackColor;
  final Color progressColor;
  final double strokeWidth;

  const _CountdownRingPainter({
    required this.progress,
    required this.trackColor,
    required this.progressColor,
    required this.strokeWidth,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = (size.width - strokeWidth) / 2;

    // Track (fondo del ring)
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..color = trackColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth,
    );

    // Arco de progreso (empieza desde arriba, gira en sentido horario)
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -math.pi / 2,                // inicio: 12 en punto
      2 * math.pi * progress,      // ángulo barrido
      false,
      Paint()
        ..color = progressColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_CountdownRingPainter old) =>
      old.progress != progress || old.progressColor != progressColor;
}

// ─────────────────────────────────────────────────────────────────────────────
// CustomSlideAction
// ─────────────────────────────────────────────────────────────────────────────

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
    this.text = 'Slide to accept',
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
    final animation = Tween<double>(begin: start, end: target).animate(
      CurvedAnimation(parent: _animController, curve: Curves.easeOut),
    );
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
        decoration: BoxDecoration(
          color: widget.outerColor,
          borderRadius: BorderRadius.circular(52),
        ),
        child: Stack(
          alignment: Alignment.centerLeft,
          children: [
            Center(
              child: AnimatedOpacity(
                opacity: _submitted ? 0.0 : 1.0,
                duration: const Duration(milliseconds: 150),
                child: Text(
                  widget.text,
                  style: widget.textStyle ?? const TextStyle(color: Colors.white, fontSize: 16),
                ),
              ),
            ),
            Positioned(
              left: 8 + _dx,
              child: GestureDetector(
                onHorizontalDragUpdate: (details) {
                  if (_locked || _submitted) return;
                  setState(() => _dx = (_dx + details.delta.dx).clamp(0.0, _maxDx));
                },
                onHorizontalDragEnd: (_) async => await _onPanEnd(),
                child: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: widget.innerColor,
                    borderRadius: BorderRadius.circular(52),
                    boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.15), blurRadius: 8, offset: const Offset(0, 2))],
                  ),
                  child: SizedBox(
                    height: sliderSize,
                    width: sliderSize,
                    child: Center(
                      child: _submitted
                          ? Icon(Icons.check_rounded, color: widget.outerColor, size: 24)
                          : (widget.sliderButtonIcon ?? Icon(Icons.arrow_forward_rounded, color: widget.outerColor)),
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

// ─────────────────────────────────────────────────────────────────────────────
// MapPreview
// ─────────────────────────────────────────────────────────────────────────────

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
  BitmapDescriptor? _originIcon;
  BitmapDescriptor? _destinationIcon;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _setup());
  }

  Future<void> _loadIcons() async {
    final double dpr = ui.PlatformDispatcher.instance.views.first.devicePixelRatio;
    final int size = (56 * dpr.clamp(1.0, 3.0) * 0.7 * 0.7).round();

    // Cargar passenger.png para el origen
    try {
      final data = await rootBundle.load('assets/passenger.png');
      final codec = await ui.instantiateImageCodec(data.buffer.asUint8List(), targetWidth: size);
      final frame = await codec.getNextFrame();
      final byteData = await frame.image.toByteData(format: ui.ImageByteFormat.png);
      if (byteData != null && mounted) {
        _originIcon = BitmapDescriptor.bytes(byteData.buffer.asUint8List());
      }
    } catch (_) {}

    // Cargar destino.svg para el destino
    try {
      final int destSize = (size * 0.45).round().clamp(20, 48);
      final bytes = await _getSvgBytes('assets/destino.svg', destSize, dpr);
      if (bytes != null && mounted) {
        _destinationIcon = BitmapDescriptor.bytes(bytes);
      }
    } catch (_) {}
  }

  Future<Uint8List?> _getSvgBytes(String path, int size, double dpr) async {
    try {
      final GlobalKey repaintKey = GlobalKey();
      final overlay = OverlayEntry(builder: (context) {
        return Positioned(
          left: -9999,
          top: -9999,
          width: size.toDouble(),
          height: size.toDouble(),
          child: RepaintBoundary(
            key: repaintKey,
            child: SizedBox(
              width: size.toDouble(),
              height: size.toDouble(),
              child: svg.SvgPicture.asset(path, width: size.toDouble(), height: size.toDouble(), fit: BoxFit.contain),
            ),
          ),
        );
      });
      Overlay.of(context).insert(overlay);
      await Future.delayed(const Duration(milliseconds: 100));
      final boundary = repaintKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
      if (boundary == null) { overlay.remove(); return null; }
      final image = await boundary.toImage(pixelRatio: dpr);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      final bytes = byteData?.buffer.asUint8List();
      overlay.remove();
      try { image.dispose(); } catch (_) {}
      return bytes;
    } catch (_) {
      return null;
    }
  }

  void _setup() async {
    await _loadIcons();
    _markers.clear();
    if (widget.origin != null) {
      _markers.add(Marker(
        markerId: const MarkerId('origin'),
        position: widget.origin!,
        infoWindow: const InfoWindow(title: 'Pickup'),
        icon: _originIcon ?? BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen),
      ));
    }
    if (widget.destination != null) {
      _markers.add(Marker(
        markerId: const MarkerId('destination'),
        position: widget.destination!,
        infoWindow: const InfoWindow(title: 'Destination'),
        icon: _destinationIcon ?? BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed),
      ));
    }
    _polylines.clear();
    if (widget.origin != null && widget.destination != null) {
      _polylines.add(Polyline(
        polylineId: const PolylineId('route'),
        color: const Color(0xFF007AFF),
        width: 4,
        points: [widget.origin!, widget.destination!],
      ));
      final south = LatLng(
        math.min(widget.origin!.latitude, widget.destination!.latitude),
        math.min(widget.origin!.longitude, widget.destination!.longitude),
      );
      final north = LatLng(
        math.max(widget.origin!.latitude, widget.destination!.latitude),
        math.max(widget.origin!.longitude, widget.destination!.longitude),
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
    return GoogleMap(
      initialCameraPosition: CameraPosition(target: initial, zoom: 12),
      markers: _markers,
      polylines: _polylines,
      myLocationEnabled: false,
      zoomControlsEnabled: true,
      zoomGesturesEnabled: true,
      scrollGesturesEnabled: true,
      rotateGesturesEnabled: false,
      tiltGesturesEnabled: false,
      liteModeEnabled: false,
      onMapCreated: (c) {
        _controller = c;
        _setup();
      },
    );
  }
}
