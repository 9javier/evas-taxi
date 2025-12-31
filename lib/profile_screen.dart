import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'local_db.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _phoneController = TextEditingController();
  String? _avatarUrl;
  bool _loading = false;
  // --- Nuevo: vehículos ---
  Map<String, Map<String, dynamic>> _vehicles = {}; // key: plate, value: data
  String? _activePlate;

  @override
  void initState() {
    super.initState();
    _loadDriver();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  void _signOut() async {
    await FirebaseAuth.instance.signOut();
    if (mounted) {
      // No navegamos manualmente aquí: el StreamBuilder en main.dart detectará el cambio
      // de estado de autenticación y redirigirá a la pantalla de login.
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Sesión cerrada.')));
    }
  }

  Future<void> _loadDriver() async {
    setState(() => _loading = true);
    try {
      final info = await getCurrentDriverInfo();
      if (info != null && mounted) {
        _nameController.text = (info['name'] ?? info['displayName'] ?? '') as String;
        _phoneController.text = (info['fullPhone'] ?? '') as String;
        // imageUrl viene desde Firebase (campo imageUrl). Guardamos para el header.
        final dynamic img = info['imageUrl'] ?? info['photoURL'] ?? info['avatar'];
        _avatarUrl = (img is String && img.isNotEmpty) ? img : null;
        // Parse vehículos
        final dynamic vehicles = info['vehicles'];
        if (vehicles is Map) {
          _vehicles = vehicles.map<String, Map<String, dynamic>>((key, value) {
            final mapValue = (value is Map<String, dynamic>) ? value : <String, dynamic>{};
            return MapEntry(key.toString(), mapValue);
          });
          // Encontrar activo
          _activePlate = _vehicles.entries
              .firstWhere((e) => (e.value['on'] == true), orElse: () => const MapEntry<String, Map<String, dynamic>>('', {}))
              .key;
          if (_activePlate != null && _activePlate!.isEmpty) {
            _activePlate = null;
          }
        } else {
          _vehicles = {};
          _activePlate = null;
        }
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _refreshFromServer() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    setState(() => _loading = true);
    try {
      // Borrar cache local para forzar consulta a Firestore
      try {
        await LocalDb.instance.clearDriver(user.uid);
      } catch (_) {}
      // Volver a cargar (ahora hará la consulta a Firestore y guardará en SQLite)
      final info = await getCurrentDriverInfo();
      if (info != null && mounted) {
        _nameController.text = (info['name'] ?? info['displayName'] ?? '') as String;
        _phoneController.text = (info['fullPhone'] ?? '') as String;
        final dynamic img = info['imageUrl'] ?? info['photoURL'] ?? info['avatar'];
        _avatarUrl = (img is String && img.isNotEmpty) ? img : null;
        // Parse vehículos
        final dynamic vehicles = info['vehicles'];
        if (vehicles is Map) {
          _vehicles = vehicles.map<String, Map<String, dynamic>>((key, value) {
            final mapValue = (value is Map<String, dynamic>) ? value : <String, dynamic>{};
            return MapEntry(key.toString(), mapValue);
          });
          _activePlate = _vehicles.entries
              .firstWhere((e) => (e.value['on'] == true), orElse: () => const MapEntry<String, Map<String, dynamic>>('', {}))
              .key;
          if (_activePlate != null && _activePlate!.isEmpty) {
            _activePlate = null;
          }
        } else {
          _vehicles = {};
          _activePlate = null;
        }
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Datos actualizados desde servidor.')));
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _setActiveVehicle(String? plate) async {
    if (plate == null) return;
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    setState(() => _loading = true);
    try {
      // Construir nuevo mapa vehicles con flags 'on'
      final Map<String, dynamic> updatedVehicles = {};
      for (final entry in _vehicles.entries) {
        final data = Map<String, dynamic>.from(entry.value);
        data['on'] = (entry.key == plate);
        updatedVehicles[entry.key] = data;
      }
      // Actualizar Firestore
      await FirebaseFirestore.instance.collection('drivers').doc(user.uid).update({'vehicles': updatedVehicles});
      // Actualizar estado local y caché
      _vehicles = updatedVehicles.map<String, Map<String, dynamic>>((k, v) => MapEntry(k, Map<String, dynamic>.from(v as Map)));
      _activePlate = plate;
      // Guardar driver actualizado en SQLite
      try {
        final doc = await FirebaseFirestore.instance.collection('drivers').doc(user.uid).get();
        final data = doc.data() ?? <String, dynamic>{};
        final result = {
          'uid': user.uid,
          'phone': user.phoneNumber,
          ...data,
        };
        await LocalDb.instance.saveDriver(result);
      } catch (_) {}
      if (mounted) {
        setState(() {});
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Vehículo activo actualizado.')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Error al actualizar el vehículo.')));
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            // Header con imagen de fondo, acciones y avatar
            _ProfileHeader(
              nameController: _nameController,
              onRefresh: _loading ? null : _refreshFromServer,
              rating: 4.89, // ejemplo
              trips: 3104,  // ejemplo
              years: 2.5,   // ejemplo
              avatarUrl: _avatarUrl, // sin imagen por defecto
            ),

            // Contenido scrollable del formulario
            Expanded(
              child: SingleChildScrollView(
                // Aumentar padding inferior para no chocar con el botón fijo abajo
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Información',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: _nameController,
                      enabled: false,
                      decoration: InputDecoration(
                        labelText: 'Nombre',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        prefixIcon: const Icon(Icons.person),
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: _phoneController,
                      enabled: false,
                      keyboardType: TextInputType.phone,
                      decoration: InputDecoration(
                        labelText: 'Teléfono',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        prefixIcon: const Icon(Icons.phone),
                      ),
                    ),
                    const SizedBox(height: 24),
                    // Select para que se seleccione el Veihículo del driver
                    // --- Nuevo Dropdown de vehículos ---
                    DropdownButtonFormField<String>(
                      value: _activePlate != null && _vehicles.containsKey(_activePlate) ? _activePlate : null,
                      isExpanded: true,
                      items: _vehicles.entries.map((e) {
                        final v = e.value;
                        final brand = (v['brand'] ?? '') as String;
                        final model = (v['model'] ?? '') as String;
                        final year = (v['anio'] ?? v['year'] ?? '');
                        final color = (v['color'] ?? '') as String;
                        final plate = (v['plate'] ?? e.key) as String;
                        final label = [brand, model].where((s) => s.toString().isNotEmpty).join(' ');
                        final subtitle = [year, plate, color].where((s) => s.toString().isNotEmpty).join(' • ');
                        return DropdownMenuItem<String>(
                          value: e.key,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(label.isNotEmpty ? label : plate, style: const TextStyle(fontWeight: FontWeight.w600)),
                              if (subtitle.isNotEmpty)
                                Text(subtitle, style: const TextStyle(color: Colors.black54, fontSize: 12)),
                            ],
                          ),
                        );
                      }).toList(),
                      selectedItemBuilder: (context) {
                        return _vehicles.entries.map((e) {
                          final v = e.value;
                          final brand = (v['brand'] ?? '') as String;
                          final model = (v['model'] ?? '') as String;
                          final plate = (v['plate'] ?? e.key) as String;
                          final subtitle = [(v['year'] ?? v['anio'] ?? ''), plate, (v['color'] ?? '')]
                              .where((s) => s.toString().isNotEmpty)
                              .join(' • ');
                          final label = [brand, model].where((s) => s.toString().isNotEmpty).join(' ');
                          return Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              label.isNotEmpty ? label +' ' +subtitle : plate,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 12),
                            ),
                          );
                        }).toList();
                      },
                      onChanged: _loading || _vehicles.isEmpty ? null : (val) => _setActiveVehicle(val),
                      decoration: InputDecoration(
                        labelText: 'Vehículo activo',
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                        prefixIcon: const Icon(Icons.directions_car),
                        contentPadding: const EdgeInsets.symmetric(vertical: 19, horizontal: 12),
                      ),
                      hint: const Text('Selecciona el vehículo a usar'),
                    ),
                    const SizedBox(height: 8),

                    // Puedes agregar más secciones aquí (auto, placas, etc.)
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
      // Botón inferior como bottomNavigationBar para evitar overflow
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              icon: const Icon(Icons.logout),
              label: const Text('Cerrar sesión'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red,
                foregroundColor: Colors.white,
                minimumSize: const Size.fromHeight(48),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              onPressed: _signOut,
            ),
          ),
        ),
      ),
    );
  }
}

// ------------------------
// Header personalizado
// ------------------------
class _ProfileHeader extends StatelessWidget {
  const _ProfileHeader({
    required this.nameController,
    required this.onRefresh,
    required this.rating,
    required this.trips,
    required this.years,
    required this.avatarUrl,
  });

  final TextEditingController nameController;
  final VoidCallback? onRefresh;
  final double rating;
  final int trips;
  final double years;
  final String? avatarUrl; // puede ser nulo

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Stack(
      children: [
        // Imagen de fondo
        SizedBox(
          height: 240,
          width: double.infinity,
          child: ClipRRect(
            borderRadius: const BorderRadius.only(
              bottomLeft: Radius.circular(24),
              bottomRight: Radius.circular(24),
            ),
            child: Stack(
              fit: StackFit.expand,
              children: [
                Image.asset('assets/fondo5.jpeg', fit: BoxFit.cover),
                // Degradado para mejor legibilidad
                Container(
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.transparent,
                        Color.fromARGB(160, 0, 0, 0),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),

        // Barra superior: hora/acciones simuladas -> botón refrescar
        Positioned(
          top: MediaQuery.of(context).padding.top + 8,
          right: 12,
          child: Row(
            children: [
              IconButton(
                tooltip: 'Refrescar desde servidor',
                onPressed: onRefresh,
                icon: Icon(Icons.refresh, color: Colors.blue[700], size: 50),

              )
            ],
          ),
        ),

        // Avatar centrado
        Positioned.fill(
          child: Align(
            alignment: const Alignment(0, 0.35),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.all(3),
                  decoration: BoxDecoration(
                    color: const Color.fromRGBO(255, 255, 255, 0.9),
                    shape: BoxShape.circle,
                    boxShadow: const [
                      BoxShadow(
                        color: Colors.black26,
                        blurRadius: 10,
                        offset: Offset(0, 4),
                      )
                    ],
                  ),
                  child: CircleAvatar(
                    radius: 42,
                    backgroundImage: avatarUrl != null ? NetworkImage(avatarUrl!) : null,
                    backgroundColor: Colors.grey[200],
                    // Si no hay imagen, mostramos iniciales o icono
                    child: avatarUrl == null
                        ? (() {
                            final name = nameController.text.trim();
                            if (name.isNotEmpty) {
                              final parts = name.split(RegExp(r'\s+'));
                              final initials = parts.map((p) => p.isNotEmpty ? p[0] : '').take(2).join().toUpperCase();
                              return Text(initials, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: Colors.black87));
                            }
                            return const Icon(Icons.person, size: 28, color: Colors.black45);
                          })()
                        : null,
                  ),
                ),
                const SizedBox(height: 12),
                // Nombre
                Text(
                  nameController.text.isNotEmpty ? nameController.text : 'Driver',
                  style: theme.textTheme.titleLarge?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    shadows: const [
                      Shadow(color: Colors.black38, blurRadius: 6),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                // Chip de rating
                _RatingChip(rating: rating),
              ],
            ),
          ),
        ),

        // Tarjeta de métricas (Trips / Years)
        Positioned(
          bottom: 0,
          left: 16,
          right: 16,
          child: _StatsCard(trips: trips, years: years),
        ),
      ],
    );
  }
}

// Chip de rating con ícono y estrella
class _RatingChip extends StatelessWidget {
  const _RatingChip({required this.rating});

  final double rating;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        boxShadow: const [
          BoxShadow(color: Colors.black12, blurRadius: 8, offset: Offset(0, 3)),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.person, size: 16, color: Colors.green),
          const SizedBox(width: 6),
          Text(
            rating.toStringAsFixed(2),
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(width: 4),
          const Icon(Icons.star, size: 16, color: Colors.amber),
        ],
      ),
    );
  }
}

// Tarjeta de métricas inferior
class _StatsCard extends StatelessWidget {
  const _StatsCard({required this.trips, required this.years});

  final int trips;
  final double years;

  @override
  Widget build(BuildContext context) {

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        boxShadow: const [
          BoxShadow(color: Colors.black12, blurRadius: 10, offset: Offset(0, 6)),
        ],
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          _Metric(
            title: 'Trips',
            value: trips.toString(),
          ),
          Container(
            width: 1,
            height: 32,
            color: Colors.grey[300],
          ),
          _Metric(
            title: 'Years',
            value: years.toString(),
          ),
        ],
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.title, required this.value});

  final String title;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          value,
          style: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          title,
          style: theme.textTheme.bodyMedium?.copyWith(color: Colors.grey[700]),
        ),
      ],
    );
  }
}



Future<Map<String, dynamic>?> getCurrentDriverInfo() async {
  final user = FirebaseAuth.instance.currentUser;
  if (user == null) return null;

  // Intentar leer de la base de datos local primero
  try {
    final cached = await LocalDb.instance.getDriver(user.uid);
    if (cached != null) {
      // Aseguramos que uid y phone estén presentes
      return {
        'uid': user.uid,
        'phone': user.phoneNumber,
        'vehicles': cached['vehicles'],
        ...cached,
      };
    }
  } catch (e) {
    // Ignorar error de caché y proceder a consultar Firestore
  }

  // Si no hay caché, consultar Firestore y guardar el resultado en SQLite
  try {
    final doc = await FirebaseFirestore.instance.collection('drivers').doc(user.uid).get();
    final data = doc.data() ?? <String, dynamic>{};
    final result = {
      'uid': user.uid,
      'phone': user.phoneNumber,
      'vehicles': data['vehicles'],
      ...data,
    };
    // Guardar en caché local (no bloqueante)
    try {
      await LocalDb.instance.saveDriver(result);
    } catch (e) {
      // Si falla el guardado local, no impedimos devolver la información
    }
    return result;
  } catch (e) {
    // Manejo mínimo: devolver null en error (puedes cambiar para lanzar)
    return null;
  }
}
