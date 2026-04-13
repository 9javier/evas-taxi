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
                    if (selectedIndex == 0) {
                      // Pasar el travelId activo (puede ser null)
                      return TravelScreen(travelId: activeTravelId, phoneNumber: widget.phoneNumber);
                    }
                    return ProfileScreen();
                  },
                ),
                bottomNavigationBar: BottomNavigationBar(
                  currentIndex: selectedIndex,
                  onTap: (index) {
                    // Bloquear navegar fuera de Travel si hay un viaje activo (aceptado/asignado) o en progreso
                    /*final activeTravelId = activeTravelIdNotifier.value;
                    final hasActiveTravel = (activeTravelId != null && activeTravelId.isNotEmpty) || onTrip;
                    if (index != 0 && hasActiveTravel) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('No puedes salir mientras el viaje está activo.')),
                      );
                      return; // mantener pestaña actualdd
                    }*/

                    tabsIndexNotifier.value = index;
                    // Si se cambia manualmente de pestaña, limpiar travel activo solo si no estamos en viaje
                    if (index != 0 && !onTrip) activeTravelIdNotifier.value = null;
                  },
                  backgroundColor: onTrip ? _onTripAccent : null,
                  selectedItemColor: onTrip ? Colors.white : null,
                  unselectedItemColor: onTrip ? Colors.white70 : null,
                  items: [
                    BottomNavigationBarItem(
                      icon: Icon(Icons.directions_car, color: onTrip ? Colors.white : null),
                      label: 'Travel',
                    ),
                    BottomNavigationBarItem(
                      icon: Icon(Icons.person, color: onTrip ? Colors.white : null),
                      label: 'Profile',
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}
