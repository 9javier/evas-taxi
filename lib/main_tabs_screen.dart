import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'travel_screen.dart';
import 'profile_screen.dart';
import 'app_state.dart';

const Color _onTripAccent = Colors.orange; // color principal cuando está en viaje

class MainTabsScreen extends StatefulWidget {
  final String phoneNumber;
  final int initialTabIndex;
  const MainTabsScreen({super.key, required this.phoneNumber, this.initialTabIndex = 0});

  @override
  State<MainTabsScreen> createState() => _MainTabsScreenState();
}

class _MainTabsScreenState extends State<MainTabsScreen> {
  bool _restored = false; // evita loops de restauración

  @override
  void initState() {
    super.initState();
    tabsIndexNotifier.value = widget.initialTabIndex;
    _restoreActiveTravelIfAny();
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
          debugPrint('[restore] Viaje en cola restaurado: ${queuedQ.docs.first.id}');
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
