import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'app_state.dart';
import 'firebase_action_service.dart';
import 'local_db.dart';

// ── Paleta Dark Premium (alineada con travel_screen y notification handler) ─────
const Color _pgBg       = Color(0xFF1E1E26);
const Color _pgSurface  = Color(0xFF2A2A34);
const Color _pgAccent   = Color(0xFF6366F1);
const Color _pgGreen    = Color(0xFF6EE7B7);
const Color _pgRed      = Color(0xFFEF4444);
const Color _pgAmber    = Color(0xFFF59E0B);
const Color _pgTextMain = Colors.white;
const Color _pgTextMuted = Color(0xFFA0A0AB);
const Color _pgLine     = Color(0xFF3F3F46);

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  final TextEditingController _nameController  = TextEditingController();
  final TextEditingController _phoneController = TextEditingController();
  String? _avatarUrl;
  bool _loading = false;
  bool _releasing = false;
  Map<String, Map<String, dynamic>> _vehicles = {};
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

  // ── Lógica ────────────────────────────────────────────────────────────────────

  void _signOut() async {
    await FirebaseAuth.instance.signOut();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('You have been signed out.')),
      );
    }
  }

  Future<void> _showReleaseConfirmation() async {
    final confirmed = await showDialog<bool>(
      context: context,
      barrierColor: Colors.black54,
      builder: (ctx) => Dialog(
        backgroundColor: _pgSurface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 28, 24, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 56, height: 56,
                decoration: BoxDecoration(
                  color: _pgAmber.withOpacity(0.12),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.warning_amber_rounded, color: _pgAmber, size: 28),
              ),
              const SizedBox(height: 16),
              const Text(
                'Release Driver',
                style: TextStyle(color: _pgTextMain, fontSize: 17, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 10),
              const Text(
                'This will cancel all active and queued trips, reset your trip counter, and set your status to available.\n\nUse this only if the app is stuck or a trip cannot be closed normally.',
                textAlign: TextAlign.center,
                style: TextStyle(color: _pgTextMuted, fontSize: 13, height: 1.55),
              ),
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(
                    child: GestureDetector(
                      onTap: () => Navigator.of(ctx).pop(false),
                      child: Container(
                        height: 44,
                        decoration: BoxDecoration(
                          color: _pgBg,
                          borderRadius: BorderRadius.circular(11),
                        ),
                        child: const Center(
                          child: Text(
                            'Cancel',
                            style: TextStyle(color: _pgTextMuted, fontSize: 14, fontWeight: FontWeight.w600),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: GestureDetector(
                      onTap: () => Navigator.of(ctx).pop(true),
                      child: Container(
                        height: 44,
                        decoration: BoxDecoration(
                          color: _pgAmber.withOpacity(0.15),
                          borderRadius: BorderRadius.circular(11),
                          border: Border.all(color: _pgAmber.withOpacity(0.5), width: 1),
                        ),
                        child: const Center(
                          child: Text(
                            'Release',
                            style: TextStyle(color: _pgAmber, fontSize: 14, fontWeight: FontWeight.w700),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (confirmed == true) await _releaseDriver();
  }

  Future<void> _releaseDriver() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    setState(() => _releasing = true);
    try {
      final activeTravelId = activeTravelIdNotifier.value;
      final queuedTravelId = pendingTravelIdNotifier.value;
      final isInProgress   = driverOnTripNotifier.value;

      if (activeTravelId != null && activeTravelId.isNotEmpty) {
        if (isInProgress) {
          await FirebaseActionService.completeTravel(activeTravelId, user.uid);
        } else {
          await FirebaseActionService.cancellOperationTravelTask(activeTravelId);
        }
      }

      if (queuedTravelId != null && queuedTravelId.isNotEmpty) {
        await FirebaseActionService.cancellOperationTravelTask(queuedTravelId);
      }

      await FirebaseFirestore.instance
          .collection('drivers')
          .doc(user.uid)
          .update({
            'activeTripsCount': 0,
            'currentTravelId': FieldValue.delete(),
            'status': 'available',
          });

      activeTravelIdNotifier.value  = null;
      pendingTravelIdNotifier.value = null;
      driverOnTripNotifier.value    = false;
      driverReleasedNotifier.value  = true;

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Driver released. You are now available.'),
            backgroundColor: Color(0xFF1E1E26),
          ),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Release failed. Please try again.')),
        );
      }
    } finally {
      if (mounted) setState(() => _releasing = false);
    }
  }

  Future<void> _loadDriver() async {
    setState(() => _loading = true);
    try {
      final info = await getCurrentDriverInfo();
      if (info != null && mounted) {
        _nameController.text  = (info['name'] ?? info['displayName'] ?? '') as String;
        _phoneController.text = (info['fullPhone'] ?? '') as String;
        final dynamic img = info['imageUrl'] ?? info['photoURL'] ?? info['avatar'];
        _avatarUrl = (img is String && img.isNotEmpty) ? img : null;
        _parseVehicles(info['vehicles']);
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
      try { await LocalDb.instance.clearDriver(user.uid); } catch (_) {}
      final info = await getCurrentDriverInfo();
      if (info != null && mounted) {
        _nameController.text  = (info['name'] ?? info['displayName'] ?? '') as String;
        _phoneController.text = (info['fullPhone'] ?? '') as String;
        final dynamic img = info['imageUrl'] ?? info['photoURL'] ?? info['avatar'];
        _avatarUrl = (img is String && img.isNotEmpty) ? img : null;
        _parseVehicles(info['vehicles']);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Profile updated from server.')),
          );
        }
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _parseVehicles(dynamic raw) {
    if (raw is Map) {
      _vehicles = raw.map<String, Map<String, dynamic>>((key, value) {
        final v = (value is Map<String, dynamic>) ? value : <String, dynamic>{};
        return MapEntry(key.toString(), v);
      });
      _activePlate = _vehicles.entries
          .firstWhere(
            (e) => e.value['on'] == true,
            orElse: () => const MapEntry<String, Map<String, dynamic>>('', {}),
          )
          .key;
      if (_activePlate != null && _activePlate!.isEmpty) _activePlate = null;
    } else {
      _vehicles   = {};
      _activePlate = null;
    }
  }

  Future<void> _setActiveVehicle(String plate) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    setState(() => _loading = true);
    try {
      // Actualizar flags 'on' en el mapa local
      final Map<String, dynamic> updated = {};
      for (final entry in _vehicles.entries) {
        final data = Map<String, dynamic>.from(entry.value);
        data['on'] = (entry.key == plate);
        updated[entry.key] = data;
      }
      await FirebaseFirestore.instance
          .collection('drivers')
          .doc(user.uid)
          .update({'vehicles': updated});

      _vehicles    = updated.map<String, Map<String, dynamic>>((k, v) => MapEntry(k, Map<String, dynamic>.from(v as Map)));
      _activePlate = plate;

      // Actualizar el label del tab de viaje
      final v = _vehicles[plate];
      if (v != null) {
        final model       = v['model']?.toString()         ?? '';
        final vehiclePlate = v['plate']?.toString()        ?? plate;
        final parts = [model, vehiclePlate].where((s) => s.isNotEmpty);
        activeVehicleLabelNotifier.value = parts.isNotEmpty ? parts.join(' · ') : '';
      }

      // Persistir en caché local
      try {
        final doc  = await FirebaseFirestore.instance.collection('drivers').doc(user.uid).get();
        final data = doc.data() ?? <String, dynamic>{};
        await LocalDb.instance.saveDriver({'uid': user.uid, 'phone': user.phoneNumber, ...data});
      } catch (_) {}

      if (mounted) {
        setState(() {});
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Active vehicle updated.')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to update vehicle. Please try again.')),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  // ── Build ──────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _pgBg,
      body: Column(
        children: [
          _buildHeader(),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator(color: _pgAccent, strokeWidth: 2))
                : SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(16, 20, 16, 100),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _sectionLabel('Personal Info'),
                        const SizedBox(height: 10),
                        _buildInfoCard(),
                        const SizedBox(height: 28),
                        _sectionLabel('My Vehicle'),
                        const SizedBox(height: 10),
                        ..._buildVehicleCards(),
                        if (_vehicles.isEmpty) _buildEmptyVehicles(),
                      ],
                    ),
                  ),
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Emergency release button
              GestureDetector(
                onTap: (_loading || _releasing) ? null : _showReleaseConfirmation,
                child: Container(
                  height: 44,
                  decoration: BoxDecoration(
                    color: _pgSurface,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: _pgAmber.withOpacity(0.25), width: 1),
                  ),
                  child: _releasing
                      ? const Center(
                          child: SizedBox(
                            width: 18, height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2, color: _pgAmber),
                          ),
                        )
                      : Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.warning_amber_rounded, color: _pgAmber.withOpacity(0.7), size: 16),
                            const SizedBox(width: 7),
                            Text(
                              'Emergency Release',
                              style: TextStyle(
                                color: _pgAmber.withOpacity(0.7),
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                letterSpacing: 0.2,
                              ),
                            ),
                          ],
                        ),
                ),
              ),
              const SizedBox(height: 8),
              // Sign out button
              GestureDetector(
                onTap: _signOut,
                child: Container(
                  height: 50,
                  decoration: BoxDecoration(
                    color: _pgSurface,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: _pgRed.withOpacity(0.4), width: 1),
                  ),
                  child: const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.logout_rounded, color: _pgRed, size: 18),
                      SizedBox(width: 8),
                      Text(
                        'Sign Out',
                        style: TextStyle(color: _pgRed, fontSize: 14, fontWeight: FontWeight.w600, letterSpacing: 0.3),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Header ─────────────────────────────────────────────────────────────────────

  Widget _buildHeader() {
    final topPad  = MediaQuery.of(context).padding.top;
    final name    = _nameController.text.trim();
    final phone   = _phoneController.text.trim();

    // Avatar con iniciales y color determinístico
    final initials = name.isNotEmpty
        ? name.split(RegExp(r'\s+')).map((p) => p.isNotEmpty ? p[0] : '').take(2).join().toUpperCase()
        : '?';
    final hue      = name.isNotEmpty ? (name.codeUnits.fold(0, (a, b) => a + b) % 360).toDouble() : 220.0;
    final avatarBg = HSVColor.fromAHSV(1.0, hue, 0.45, 0.60).toColor();

    return Container(
      padding: EdgeInsets.fromLTRB(20, topPad + 14, 20, 24),
      decoration: const BoxDecoration(
        color: _pgSurface,
        borderRadius: BorderRadius.vertical(bottom: Radius.circular(28)),
        boxShadow: [BoxShadow(color: Colors.black38, blurRadius: 18, offset: Offset(0, 5))],
      ),
      child: Column(
        children: [
          // Barra superior: título + botón refresh
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const Text(
                'Profile',
                style: TextStyle(color: _pgTextMain, fontSize: 17, fontWeight: FontWeight.w700),
              ),
              const Spacer(),
              GestureDetector(
                onTap: _loading ? null : _refreshFromServer,
                child: Container(
                  width: 36, height: 36,
                  decoration: BoxDecoration(color: _pgBg, shape: BoxShape.circle),
                  child: _loading
                      ? const Padding(
                          padding: EdgeInsets.all(10),
                          child: CircularProgressIndicator(strokeWidth: 2, color: _pgAccent),
                        )
                      : const Icon(Icons.refresh_rounded, color: _pgTextMuted, size: 18),
                ),
              ),
            ],
          ),
          const SizedBox(height: 22),

          // Avatar con ring de acento
          Stack(
            alignment: Alignment.center,
            children: [
              Container(
                width: 88, height: 88,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: _pgAccent, width: 2.5),
                ),
              ),
              CircleAvatar(
                radius: 40,
                backgroundImage: _avatarUrl != null ? NetworkImage(_avatarUrl!) : null,
                backgroundColor: avatarBg,
                child: _avatarUrl == null
                    ? Text(
                        initials,
                        style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700, color: Colors.white),
                      )
                    : null,
              ),
            ],
          ),
          const SizedBox(height: 14),

          // Nombre del driver
          Text(
            name.isNotEmpty ? name : 'Driver',
            style: const TextStyle(color: _pgTextMain, fontSize: 20, fontWeight: FontWeight.w700),
            textAlign: TextAlign.center,
          ),

          // Teléfono
          if (phone.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(phone, style: const TextStyle(color: _pgTextMuted, fontSize: 13)),
          ],
          const SizedBox(height: 20),

          // Fila de estadísticas
          Container(
            padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
            decoration: BoxDecoration(
              color: _pgBg,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _statCell('4.89', 'Rating',  Icons.star_rounded,     _pgAmber),
                _statDivider(),
                _statCell('3,104', 'Trips',  Icons.route_rounded,    _pgAccent),
                _statDivider(),
                _statCell('2.5 yrs', 'Active', Icons.verified_rounded, _pgGreen),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _statCell(String value, String label, IconData icon, Color color) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 15, color: color),
        const SizedBox(height: 5),
        Text(value, style: const TextStyle(color: _pgTextMain, fontSize: 15, fontWeight: FontWeight.w700)),
        const SizedBox(height: 2),
        Text(label, style: const TextStyle(color: _pgTextMuted, fontSize: 10, letterSpacing: 0.2)),
      ],
    );
  }

  Widget _statDivider() => Container(width: 1, height: 34, color: _pgLine);

  // ── Sección: etiqueta ──────────────────────────────────────────────────────────

  Widget _sectionLabel(String text) {
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Text(
        text.toUpperCase(),
        style: const TextStyle(
          color: _pgTextMuted,
          fontSize: 11,
          fontWeight: FontWeight.w600,
          letterSpacing: 1.3,
        ),
      ),
    );
  }

  // ── Sección: Info personal ─────────────────────────────────────────────────────

  Widget _buildInfoCard() {
    final name  = _nameController.text.trim();
    final phone = _phoneController.text.trim();
    return Container(
      decoration: BoxDecoration(
        color: _pgSurface,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          _infoRow(Icons.person_outline_rounded, 'Full Name',  name.isNotEmpty  ? name  : '—', isFirst: true),
          Divider(color: _pgLine, height: 1, indent: 54),
          _infoRow(Icons.phone_outlined,          'Phone',     phone.isNotEmpty ? phone : '—'),
        ],
      ),
    );
  }

  Widget _infoRow(IconData icon, String label, String value, {bool isFirst = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
      child: Row(
        children: [
          Container(
            width: 34, height: 34,
            decoration: BoxDecoration(color: _pgBg, borderRadius: BorderRadius.circular(9)),
            child: Icon(icon, color: _pgAccent, size: 16),
          ),
          const SizedBox(width: 14),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(label, style: const TextStyle(color: _pgTextMuted, fontSize: 11)),
              const SizedBox(height: 2),
              Text(value, style: const TextStyle(color: _pgTextMain, fontSize: 14, fontWeight: FontWeight.w500)),
            ],
          ),
        ],
      ),
    );
  }

  // ── Sección: Vehículos ─────────────────────────────────────────────────────────

  List<Widget> _buildVehicleCards() {
    return _vehicles.entries.map((entry) {
      final v        = entry.value;
      final isActive = entry.key == _activePlate;
      final brand    = (v['brand'] ?? '') as String;
      final model    = (v['model'] ?? '') as String;
      final year     = (v['anio'] ?? v['year'] ?? '').toString();
      final color    = (v['color'] ?? '') as String;
      final plate    = (v['plate'] ?? entry.key) as String;
      final title    = [brand, model].where((s) => s.isNotEmpty).join(' ');
      final subtitle = [year, color].where((s) => s.isNotEmpty).join(' · ');

      return Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: GestureDetector(
          onTap: (_loading || isActive) ? null : () => _setActiveVehicle(entry.key),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              color: isActive ? _pgAccent.withOpacity(0.08) : _pgSurface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: isActive ? _pgAccent.withOpacity(0.55) : _pgLine.withOpacity(0.5),
                width: isActive ? 1.5 : 1,
              ),
            ),
            child: Row(
              children: [
                // Icono de taxi
                Container(
                  width: 42, height: 42,
                  decoration: BoxDecoration(
                    color: isActive ? _pgAccent.withOpacity(0.15) : _pgBg,
                    borderRadius: BorderRadius.circular(11),
                  ),
                  child: Icon(
                    Icons.local_taxi_rounded,
                    color: isActive ? _pgAccent : _pgTextMuted,
                    size: 21,
                  ),
                ),
                const SizedBox(width: 14),

                // Texto del vehículo
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title.isNotEmpty ? title : plate,
                        style: TextStyle(
                          color: isActive ? _pgTextMain : _pgTextMuted,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (subtitle.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(subtitle, style: const TextStyle(color: _pgTextMuted, fontSize: 12)),
                      ],
                      const SizedBox(height: 6),
                      // Badge de placa
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: _pgBg,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          plate,
                          style: TextStyle(
                            color: isActive ? _pgAccent : _pgTextMuted,
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 1.5,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),

                // Indicador activo / inactivo
                if (isActive)
                  const Icon(Icons.check_circle_rounded, color: _pgAccent, size: 22)
                else
                  Container(
                    width: 20, height: 20,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: _pgLine, width: 1.5),
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
    }).toList();
  }

  Widget _buildEmptyVehicles() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(color: _pgSurface, borderRadius: BorderRadius.circular(16)),
      child: const Row(
        children: [
          Icon(Icons.directions_car_outlined, color: _pgTextMuted, size: 20),
          SizedBox(width: 12),
          Text('No vehicles registered', style: TextStyle(color: _pgTextMuted, fontSize: 14)),
        ],
      ),
    );
  }
}

// ── getCurrentDriverInfo ──────────────────────────────────────────────────────────

Future<Map<String, dynamic>?> getCurrentDriverInfo() async {
  final user = FirebaseAuth.instance.currentUser;
  if (user == null) return null;

  // Intentar leer de la base de datos local primero
  try {
    final cached = await LocalDb.instance.getDriver(user.uid);
    if (cached != null) {
      return {
        'uid':      user.uid,
        'phone':    user.phoneNumber,
        'vehicles': cached['vehicles'],
        ...cached,
      };
    }
  } catch (e) {
    // Ignorar error de caché y proceder a Firestore
  }

  // Si no hay caché, consultar Firestore y guardar en SQLite
  try {
    final doc  = await FirebaseFirestore.instance.collection('drivers').doc(user.uid).get();
    final data = doc.data() ?? <String, dynamic>{};
    final result = {
      'uid':      user.uid,
      'phone':    user.phoneNumber,
      'vehicles': data['vehicles'],
      ...data,
    };
    try { await LocalDb.instance.saveDriver(result); } catch (e) {}
    return result;
  } catch (e) {
    return null;
  }
}
