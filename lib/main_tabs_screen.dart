import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'travel_screen.dart';
import 'profile_screen.dart';
import 'app_state.dart';
import 'notification_center.dart';
import 'notification_guard.dart';
import 'travel_notification_handler.dart';
import 'driver_presence_service.dart';

const Color _onTripAccent = Colors.orange; // color principal cuando está en viaje

class MainTabsScreen extends StatefulWidget {
  final String phoneNumber;
  final int initialTabIndex;
  const MainTabsScreen({super.key, required this.phoneNumber, this.initialTabIndex = 0});

  @override
  State<MainTabsScreen> createState() => _MainTabsScreenState();
}

class _MainTabsScreenState extends State<MainTabsScreen> with WidgetsBindingObserver {
  bool _restored = false; // evita loops de restauración

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    tabsIndexNotifier.value = widget.initialTabIndex;
    _restoreActiveTravelIfAny();
    _refreshFcmToken();
  }

  /// Refresca el FCM token en Firestore cada vez que la app inicia.
  /// Esto es crítico después de reinstalar la app, ya que Firebase genera un token nuevo.
  Future<void> _refreshFcmToken() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    try {
      final token = await FirebaseMessaging.instance.getToken();
      if (token == null) return;

      // Resolver el ID real del documento si la app arrancó ya autenticada (sin pasar por login).
      if (driverDocId == null) {
        final phone = user.phoneNumber ?? '';
        if (phone.isNotEmpty) {
          final q = await FirebaseFirestore.instance
              .collection('drivers')
              .where('fullphone', isEqualTo: phone)
              .limit(1)
              .get();
          if (q.docs.isNotEmpty) driverDocId = q.docs.first.id;
        }
      }

      if (driverDocId == null) return;

      await FirebaseFirestore.instance
          .collection('drivers')
          .doc(driverDocId)
          .update({'fcmToken': token});
      // Iniciar presencia RTDB una vez que driverDocId está confirmado
      await DriverPresenceService.instance.start(driverDocId!);
    } catch (_) {}
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    DriverPresenceService.instance.stop(); // fire-and-forget: RTDB también lo maneja con onDisconnect
    super.dispose();
  }

  /// Se dispara cuando la app vuelve al foreground desde background.
  /// Verifica si hay una solicitud de viaje pendiente que no fue mostrada.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Re-establecer presencia RTDB al volver del fondo.
      // En iOS el WebSocket de RTDB cae al bloquear la pantalla; esto lo restaura
      // en cuanto el driver desbloquea, cancelando la actualización offline pendiente.
      if (driverDocId != null) {
        DriverPresenceService.instance.start(driverDocId!);
      }
      // 1. Procesar notificaciones que quedaron en la cola en memoria
      tryHandlePendingNotifications();
      // 2. Consultar Firestore por solicitudes pendientes asignadas a este driver
      _checkForPendingTripRequest();
    }
  }

  // ── Paleta Dark Premium ────────────────────────────────────────────────────
  static const _navBg       = Color(0xFF22222E); // gris-azulado medio — ni blanco ni negro
  static const _navSelected = Color(0xFF6366F1); // índigo — igual que el popup y el sheet
  static const _navMuted    = Color(0xFF5B5B70); // gris-morado apagado
  static const _navSeparator = Color(0xFF2E2E3E); // línea separadora sutil

  Widget _buildBottomNav({
    required int selectedIndex,
    required bool onTrip,
    required void Function(int) onTap,
  }) {
    // Colores según modo viaje activo
    final bg       = onTrip ? _onTripAccent       : _navBg;
    final selected = onTrip ? Colors.white         : _navSelected;
    final muted    = onTrip ? Colors.white70       : _navMuted;
    final topBorder = onTrip
        ? BorderSide.none
        : const BorderSide(color: _navSeparator, width: 1);

    return ValueListenableBuilder<String>(
      valueListenable: activeVehicleLabelNotifier,
      builder: (context, vehicleLabel, _) {
        final tripLabel = vehicleLabel.isNotEmpty ? vehicleLabel : 'Trip';
        return Container(
          decoration: BoxDecoration(
            color: bg,
            border: Border(top: topBorder),
          ),
          child: BottomNavigationBar(
            currentIndex: selectedIndex,
            onTap: onTap,
            backgroundColor: Colors.transparent,
            elevation: 0,
            selectedItemColor: selected,
            unselectedItemColor: muted,
            type: BottomNavigationBarType.fixed,
            selectedFontSize: 10,
            unselectedFontSize: 10,
            selectedLabelStyle: const TextStyle(fontWeight: FontWeight.w600, letterSpacing: 0.2),
            unselectedLabelStyle: const TextStyle(fontWeight: FontWeight.w400),
            items: [
              BottomNavigationBarItem(
                icon: const Icon(Icons.directions_car_rounded),
                activeIcon: const Icon(Icons.directions_car_rounded),
                label: tripLabel,
              ),
              const BottomNavigationBarItem(
                icon: Icon(Icons.person_outline_rounded),
                activeIcon: Icon(Icons.person_rounded),
                label: 'Profile',
              ),
            ],
          ),
        );
      },
    );
  }

  /// Al volver al foreground, busca en `background_messages` si llegó alguna
  /// notificación NEW_TRAVEL mientras la app estaba en background que el driver
  /// no haya visto todavía (processed == false). Si encuentra una, levanta el popup.
  ///
  /// La Cloud Function incluye en el payload FCM un campo `driverIds` (array de UIDs)
  /// con los drivers a los que se les envió la solicitud. Usamos arrayContains para
  /// filtrar solo mensajes dirigidos a este driver.
  Future<void> _checkForPendingTripRequest() async {
    // Pausa breve para que la UI termine de renderizarse
    await Future.delayed(const Duration(milliseconds: 700));
    if (!mounted) return;

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    if (travelDialogActive) return;

    try {
      final driverId = user.uid;
      final cutoff = Timestamp.fromDate(DateTime.now().subtract(const Duration(minutes: 10)));

      // Dos filtros de igualdad no requieren índice compuesto.
      // Ordenamiento y filtro de tiempo se aplican en código.
      final q = await FirebaseFirestore.instance
          .collection('background_messages')
          .where('driverId', isEqualTo: driverId)
          .where('processed', isEqualTo: false)
          .limit(10)
          .get();

      // Ordenar por receivedAt descendente en código (evita índice compuesto)
      final sorted = q.docs.toList()
        ..sort((a, b) {
          final aTs = a.data()['receivedAt'];
          final bTs = b.data()['receivedAt'];
          if (aTs is Timestamp && bTs is Timestamp) return bTs.compareTo(aTs);
          return 0;
        });

      for (final doc in sorted) {
        // Ignorar mensajes de más de 10 minutos (filtro en código, no en query)
        final receivedAt = doc.data()['receivedAt'];
        if (receivedAt is Timestamp && receivedAt.toDate().isBefore(cutoff.toDate())) continue;

        final raw = doc.data()['data'];
        if (raw is! Map) continue;

        final type     = raw['type']?.toString() ?? '';
        final travelId = (raw['travelId'] ?? raw['travelID'] ?? raw['travelid'])?.toString() ?? '';

        if (type != 'NEW_TRAVEL' || travelId.isEmpty) continue;

        // NotificationGuard previene duplicados si el driver también tapea la notificación
        if (!NotificationGuard.tryAdd(travelId)) continue;

        final freshCtx = navigatorKey.currentContext;
        if (freshCtx == null || !freshCtx.mounted) continue;

        // Marcar como procesado solo cuando todos los guards pasan y el dialog se va a mostrar
        await doc.reference.update({'processed': true});

        showTravelRequestDialog(freshCtx, travelId, null);
        return; // mostrar de a uno por vez
      }
    } catch (_) {}
  }

  Future<void> _restoreActiveTravelIfAny() async {
    if (_restored) return;
    _restored = true;
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return; // no autenticado
    // Si ya hay travelId activo o estamos en viaje, no restaurar
    if ((activeTravelIdNotifier.value != null && activeTravelIdNotifier.value!.isNotEmpty) || driverOnTripNotifier.value) return;
    try {
      final driverId = user.uid;
      // Buscar viajes en proceso: accepted, driver_near, driver_arrived, in_progress
      final q = await FirebaseFirestore.instance
          .collection('travels')
          .where('driverId', isEqualTo: driverId)
          .where('viaje_status', whereIn: ['accepted', 'driver_near', 'driver_arrived', 'in_progress'])
          .limit(1)
          .get();
      DocumentSnapshot<Map<String, dynamic>>? doc;
      if (q.docs.isNotEmpty) {
        doc = q.docs.first;
      } else {
        // Intentar con campo alterno 'driver_id' si el esquema varía
        final qAlt = await FirebaseFirestore.instance
            .collection('travels')
            .where('driver_id', isEqualTo: driverId)
            .where('viaje_status', whereIn: ['accepted', 'driver_near', 'driver_arrived', 'in_progress'])
            .limit(1)
            .get();
        if (qAlt.docs.isNotEmpty) doc = qAlt.docs.first;
      }
      if (doc == null) return;
      final viajeStatus = (doc.data()?['viaje_status'] ?? '').toString();
      final travelId = doc.id;
      activeTravelIdNotifier.value = travelId;
      // in_progress: el pasajero ya fue recogido, conductor en ruta al destino
      if (viajeStatus == 'in_progress') {
        driverOnTripNotifier.value = true;
      }
      tabsIndexNotifier.value = 0; // asegurar pestaña Travel

      // Buscar también viaje en cola (queued) para este driver
      try {
        final queuedQ = await FirebaseFirestore.instance
            .collection('travels')
            .where('driverId', isEqualTo: driverId)
            .where('viaje_status', isEqualTo: 'queued')
            .limit(1)
            .get();
        if (queuedQ.docs.isNotEmpty &&
            (pendingTravelIdNotifier.value == null || pendingTravelIdNotifier.value!.isEmpty)) {
          pendingTravelIdNotifier.value = queuedQ.docs.first.id;
        }
      } catch (_) {}
    } catch (e) {
      // silencioso
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: tabsIndexNotifier,
      builder: (context, selectedIndex, _) {
        return ValueListenableBuilder<bool>(
          valueListenable: driverOnTripNotifier,
          builder: (context, onTrip, __) {
            // Contenedor con borde y sombra tenue cuando el driver está en viaje
            final decoration = onTrip
                ? BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: _onTripAccent.withAlpha(242), width: 4),
                    boxShadow: [
                      BoxShadow(color: _onTripAccent.withAlpha(31), blurRadius: 20, spreadRadius: 2),
                    ],
                  )
                : null;

            return Container(
              margin: onTrip ? const EdgeInsets.all(6) : EdgeInsets.zero,
              decoration: decoration,
              child: Scaffold(
                body: ValueListenableBuilder<String?>(
                  valueListenable: activeTravelIdNotifier,
                  builder: (context, activeTravelId, __) {
                    // IndexedStack mantiene ambas pantallas vivas en memoria.
                    // TravelScreen nunca se destruye al cambiar de pestaña,
                    // por lo que el estado del viaje persiste.
                    return IndexedStack(
                      index: selectedIndex,
                      children: [
                        TravelScreen(travelId: activeTravelId, phoneNumber: widget.phoneNumber),
                        ProfileScreen(),
                      ],
                    );
                  },
                ),
                bottomNavigationBar: _buildBottomNav(
                  selectedIndex: selectedIndex,
                  onTrip: onTrip,
                  onTap: (index) {
                    tabsIndexNotifier.value = index;
                    // NO limpiar activeTravelIdNotifier aquí.
                    // TravelScreen solo lo limpia cuando el viaje termina realmente (_endTrip).
                  },
                ),
              ),
            );
          },
        );
      },
    );
  }
}
