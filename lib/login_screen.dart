import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_state.dart';
import 'otp_screen.dart';
import 'welcome_screen.dart';

// Modelo de país para el selector
class _Country {
  final String flag;
  final String name;
  final String dialCode;
  const _Country(this.flag, this.name, this.dialCode);
}

class DriverLoginScreen extends StatefulWidget {
  const DriverLoginScreen({super.key});

  @override
  State<DriverLoginScreen> createState() => _DriverLoginScreenState();
}

class _DriverLoginScreenState extends State<DriverLoginScreen> {
  // Dark Premium palette — alineada con el resto de la app del conductor
  static const _kBg      = Color(0xFF0D0D14);
  static const _kSurface = Color(0xFF1A1A24);
  static const _kCard    = Color(0xFF22222E);
  static const _kAccent  = Color(0xFF6366F1);
  static const _kText    = Color(0xFFEEEEF2);
  static const _kHint    = Color(0xFF8080A0);
  static const _kDivider = Color(0xFF2C2C3C);
  static const _kError   = Color(0xFFEF5350);
  static const _kErrorBg = Color(0xFF2D1515);

  static const _countries = [
    _Country('🇺🇸', 'United States', '+1'),
    _Country('🇨🇦', 'Canada', '+1'),
    _Country('🇲🇽', 'Mexico', '+52'),
  ];

  _Country _selected = _countries[0];
  final _formKey = GlobalKey<FormState>();
  final _phoneCtrl = TextEditingController();
  bool _loading = false;
  String _error = '';

  @override
  void dispose() {
    _phoneCtrl.dispose();
    super.dispose();
  }

  // ── Selector de país ──────────────────────────────────────────────────────

  Future<void> _pickCountry() async {
    final picked = await showModalBottomSheet<_Country>(
      context: context,
      backgroundColor: _kSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => _CountrySheet(countries: _countries, selected: _selected),
    );
    if (picked != null) {
      setState(() {
        _selected = picked;
        _phoneCtrl.clear();
        _error = '';
      });
    }
  }

  // ── Envío de OTP ──────────────────────────────────────────────────────────

  Future<void> _sendOtp() async {
    if (!_formKey.currentState!.validate()) return;
    final rawDigits = _phoneCtrl.text.trim().replaceAll(RegExp(r'\D'), '');
    if (rawDigits.length != 10) {
      setState(() => _error = 'Enter a valid 10-digit number');
      return;
    }
    setState(() { _loading = true; _error = ''; });
    final fullPhone = '${_selected.dialCode}$rawDigits';

    await FirebaseAuth.instance.verifyPhoneNumber(
      phoneNumber: fullPhone,
      timeout: const Duration(seconds: 60),
      verificationCompleted: (PhoneAuthCredential cred) async {
        // Auto-verificación en Android — aplicar el mismo chequeo de conductor.
        skipAuthNavigation = true;
        try {
          final uc = await FirebaseAuth.instance.signInWithCredential(cred);
          if (uc.user == null || !mounted) { skipAuthNavigation = false; return; }

          final query = await FirebaseFirestore.instance
              .collection('drivers')
              .where('fullphone', isEqualTo: fullPhone)
              .limit(1)
              .get();

          if (query.docs.isEmpty) {
            await FirebaseAuth.instance.signOut();
            skipAuthNavigation = false;
            if (!mounted) return;
            setState(() {
              _loading = false;
              _error = 'No driver found with this number. Please contact the administrator.';
            });
            return;
          }

          driverDocId = query.docs.first.id;
          try {
            final fcmToken = await FirebaseMessaging.instance.getToken();
            if (fcmToken != null) {
              await query.docs.first.reference.update({'fcmToken': fcmToken});
            }
          } catch (_) {}
          skipAuthNavigation = false;
          if (!mounted) return;
          Navigator.of(context).pushAndRemoveUntil(
            MaterialPageRoute(builder: (_) => WelcomeScreen(phoneNumber: uc.user!.phoneNumber ?? '')),
            (route) => false,
          );
        } catch (_) {
          skipAuthNavigation = false;
        }
      },
      verificationFailed: (FirebaseAuthException e) {
        if (!mounted) return;
        setState(() { _loading = false; _error = _mapError(e.code); });
      },
      codeSent: (String verificationId, int? resendToken) {
        if (!mounted) return;
        setState(() => _loading = false);
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => DriverOtpScreen(
              verificationId: verificationId,
              phoneNumber: fullPhone,
              resendToken: resendToken,
            ),
          ),
        );
      },
      codeAutoRetrievalTimeout: (_) {},
    );
  }

  // ── Mapeo de errores ──────────────────────────────────────────────────────

  String _mapError(String code) {
    switch (code) {
      case 'invalid-phone-number':   return 'Invalid phone number';
      case 'too-many-requests':      return 'Too many attempts. Try again later';
      case 'quota-exceeded':         return 'SMS quota exceeded. Try again later';
      case 'network-request-failed': return 'No connection. Check your internet';
      default:                       return 'Error sending code. Try again';
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _kBg,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const SizedBox(height: 40),
              _buildHero(),
              const SizedBox(height: 48),
              _buildCard(),
              if (_error.isNotEmpty) ...[
                const SizedBox(height: 12),
                _buildErrorBanner(),
              ],
              const SizedBox(height: 36),
              _buildFooter(),
            ],
          ),
        ),
      ),
    );
  }

  // ── Hero ──────────────────────────────────────────────────────────────────

  Widget _buildHero() {
    return Column(
      children: [
        // Icono con glow indigo
        Container(
          width: 96,
          height: 96,
          decoration: BoxDecoration(
            color: _kSurface,
            shape: BoxShape.circle,
            border: Border.all(color: _kAccent.withValues(alpha: 0.4), width: 1.5),
            boxShadow: [
              BoxShadow(
                color: _kAccent.withValues(alpha: 0.22),
                blurRadius: 36,
                spreadRadius: 6,
              ),
            ],
          ),
          child: const Icon(Icons.local_taxi_rounded, color: _kAccent, size: 46),
        ),
        const SizedBox(height: 22),
        const Text(
          "EVA'S TAXI",
          style: TextStyle(
            color: _kAccent,
            fontSize: 28,
            fontWeight: FontWeight.w800,
            letterSpacing: 4.5,
          ),
        ),
        const SizedBox(height: 5),
        const Text(
          'Driver App',
          style: TextStyle(
            color: _kText,
            fontSize: 12,
            fontWeight: FontWeight.w500,
            letterSpacing: 2.5,
          ),
        ),
        const SizedBox(height: 14),
        // Badge Atlanta
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          decoration: BoxDecoration(
            color: _kSurface,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: _kDivider),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: const [
              Icon(Icons.location_city_rounded, color: _kHint, size: 13),
              SizedBox(width: 6),
              Text(
                'Atlanta, Georgia · USA',
                style: TextStyle(color: _kHint, fontSize: 11, letterSpacing: 0.6),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ── Card de login ─────────────────────────────────────────────────────────

  Widget _buildCard() {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: _kSurface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: _kDivider, width: 0.5),
      ),
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Welcome, driver',
              style: TextStyle(color: _kText, fontSize: 20, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            const Text(
              'Enter your phone number to receive\na verification code via SMS',
              style: TextStyle(color: _kHint, fontSize: 13, height: 1.45),
            ),
            const SizedBox(height: 24),
            _buildPhoneRow(),
            const SizedBox(height: 20),
            _buildSendButton(),
          ],
        ),
      ),
    );
  }

  Widget _buildPhoneRow() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Selector de país
        GestureDetector(
          onTap: _pickCountry,
          child: Container(
            height: 55,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: _kCard,
              borderRadius: const BorderRadius.horizontal(left: Radius.circular(12)),
              border: Border.all(color: _kDivider, width: 0.5),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(_selected.flag, style: const TextStyle(fontSize: 20)),
                const SizedBox(width: 5),
                Text(
                  _selected.dialCode,
                  style: const TextStyle(color: _kText, fontSize: 14, fontWeight: FontWeight.w600),
                ),
                const SizedBox(width: 4),
                const Icon(Icons.expand_more_rounded, color: _kHint, size: 18),
              ],
            ),
          ),
        ),
        // Campo de número
        Expanded(
          child: TextFormField(
            controller: _phoneCtrl,
            keyboardType: TextInputType.phone,
            maxLength: 10,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            style: const TextStyle(color: _kText, fontSize: 16),
            decoration: InputDecoration(
              hintText: '(555) 000-0000',
              hintStyle: const TextStyle(color: _kHint),
              counterText: '',
              filled: true,
              fillColor: _kCard,
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
              border: OutlineInputBorder(
                borderRadius: const BorderRadius.horizontal(right: Radius.circular(12)),
                borderSide: BorderSide(color: _kDivider, width: 0.5),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: const BorderRadius.horizontal(right: Radius.circular(12)),
                borderSide: BorderSide(color: _kDivider, width: 0.5),
              ),
              focusedBorder: const OutlineInputBorder(
                borderRadius: BorderRadius.horizontal(right: Radius.circular(12)),
                borderSide: BorderSide(color: _kAccent, width: 1.5),
              ),
              errorBorder: const OutlineInputBorder(
                borderRadius: BorderRadius.horizontal(right: Radius.circular(12)),
                borderSide: BorderSide(color: _kError, width: 1),
              ),
              focusedErrorBorder: const OutlineInputBorder(
                borderRadius: BorderRadius.horizontal(right: Radius.circular(12)),
                borderSide: BorderSide(color: _kError, width: 1.5),
              ),
            ),
            validator: (v) {
              if (v == null || v.trim().isEmpty) return 'Enter your number';
              if (v.trim().length < 10) return 'Incomplete number (10 digits)';
              return null;
            },
          ),
        ),
      ],
    );
  }

  Widget _buildSendButton() {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton(
        onPressed: _loading ? null : _sendOtp,
        style: ElevatedButton.styleFrom(
          backgroundColor: _kAccent,
          foregroundColor: const Color(0xFF0D0D14),
          disabledBackgroundColor: _kAccent.withValues(alpha: 0.35),
          padding: const EdgeInsets.symmetric(vertical: 16),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          elevation: 0,
        ),
        child: _loading
            ? const SizedBox(
                height: 20,
                width: 20,
                child: CircularProgressIndicator(color: Color(0xFF0D0D14), strokeWidth: 2.5),
              )
            : const Text(
                'Send code',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
              ),
      ),
    );
  }

  Widget _buildErrorBanner() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: _kErrorBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _kError.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline_rounded, color: _kError, size: 16),
          const SizedBox(width: 8),
          Expanded(
            child: Text(_error, style: const TextStyle(color: _kError, fontSize: 13)),
          ),
        ],
      ),
    );
  }

  Widget _buildFooter() {
    return const Text(
      'By continuing, you accept our Terms of Service\nand Privacy Policy',
      textAlign: TextAlign.center,
      style: TextStyle(color: _kHint, fontSize: 11, height: 1.6),
    );
  }
}

// ── Bottom sheet del selector de país ────────────────────────────────────────

class _CountrySheet extends StatelessWidget {
  final List<_Country> countries;
  final _Country selected;

  const _CountrySheet({required this.countries, required this.selected});

  static const _kSurface = Color(0xFF1A1A24);
  static const _kCard    = Color(0xFF22222E);
  static const _kAccent  = Color(0xFF6366F1);
  static const _kText    = Color(0xFFEEEEF2);
  static const _kHint    = Color(0xFF8080A0);
  static const _kDivider = Color(0xFF2C2C3C);

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Handle bar
            Container(
              width: 36, height: 4,
              decoration: BoxDecoration(color: _kDivider, borderRadius: BorderRadius.circular(2)),
            ),
            const SizedBox(height: 20),
            const Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Select your country',
                style: TextStyle(color: _kText, fontSize: 16, fontWeight: FontWeight.w700),
              ),
            ),
            const SizedBox(height: 14),
            ...countries.map((c) => _buildOption(context, c)),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Widget _buildOption(BuildContext context, _Country c) {
    final isSelected = c.dialCode == selected.dialCode && c.flag == selected.flag;
    return GestureDetector(
      onTap: () => Navigator.of(context).pop(c),
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: isSelected ? _kAccent.withValues(alpha: 0.1) : _kCard,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected ? _kAccent.withValues(alpha: 0.5) : _kDivider,
            width: isSelected ? 1.5 : 0.5,
          ),
        ),
        child: Row(
          children: [
            Text(c.flag, style: const TextStyle(fontSize: 22)),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                c.name,
                style: TextStyle(
                  color: isSelected ? _kAccent : _kText,
                  fontSize: 15,
                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
            Text(
              c.dialCode,
              style: TextStyle(
                color: isSelected ? _kAccent : _kHint,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (isSelected) ...[
              const SizedBox(width: 10),
              const Icon(Icons.check_circle_rounded, color: _kAccent, size: 18),
            ],
          ],
        ),
      ),
    );
  }
}
