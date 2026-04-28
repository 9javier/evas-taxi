import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'welcome_screen.dart';

class DriverOtpScreen extends StatefulWidget {
  final String verificationId;
  final String phoneNumber;
  final int? resendToken;

  const DriverOtpScreen({
    super.key,
    required this.verificationId,
    required this.phoneNumber,
    this.resendToken,
  });

  @override
  State<DriverOtpScreen> createState() => _DriverOtpScreenState();
}

class _DriverOtpScreenState extends State<DriverOtpScreen> {
  // Dark Premium palette — misma que el login y el resto de la app
  static const _kBg      = Color(0xFF0D0D14);
  static const _kSurface = Color(0xFF1A1A24);
  static const _kCard    = Color(0xFF22222E);
  static const _kAccent  = Color(0xFF6366F1);
  static const _kText    = Color(0xFFEEEEF2);
  static const _kHint    = Color(0xFF8080A0);
  static const _kDivider = Color(0xFF2C2C3C);
  static const _kError   = Color(0xFFEF5350);
  static const _kErrorBg = Color(0xFF2D1515);

  late String _verificationId;
  int? _resendToken;

  final List<TextEditingController> _boxes = List.generate(6, (_) => TextEditingController());
  final List<FocusNode> _nodes = List.generate(6, (_) => FocusNode());

  bool _loading = false;
  bool _autoVerifying = false;
  String _error = '';
  int _resendSeconds = 60;
  Timer? _resendTimer;

  @override
  void initState() {
    super.initState();
    _verificationId = widget.verificationId;
    _resendToken    = widget.resendToken;
    _startResendTimer();
    WidgetsBinding.instance.addPostFrameCallback((_) => _nodes[0].requestFocus());
  }

  @override
  void dispose() {
    _resendTimer?.cancel();
    for (final c in _boxes) { c.dispose(); }
    for (final f in _nodes) { f.dispose(); }
    super.dispose();
  }

  // ── Timer de reenvío ───────────────────────────────────────────────────────

  void _startResendTimer() {
    _resendSeconds = 60;
    _resendTimer?.cancel();
    _resendTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) { t.cancel(); return; }
      if (_resendSeconds <= 0) { t.cancel(); return; }
      setState(() => _resendSeconds--);
    });
  }

  // ── OTP actual ────────────────────────────────────────────────────────────

  String get _otp => _boxes.map((c) => c.text).join();

  // ── Verificación ──────────────────────────────────────────────────────────

  Future<void> _verifyOtp() async {
    if (_loading || _autoVerifying) return;
    final otp = _otp;
    if (otp.length < 6) {
      setState(() => _error = 'Ingresa los 6 dígitos del código');
      return;
    }
    setState(() { _loading = true; _error = ''; });
    try {
      final credential = PhoneAuthProvider.credential(
        verificationId: _verificationId,
        smsCode: otp,
      );
      final uc = await FirebaseAuth.instance.signInWithCredential(credential);
      if (uc.user == null) throw Exception('user null after signIn');
      if (mounted) await _afterSignIn(uc.user!);
    } on FirebaseAuthException catch (e) {
      if (!mounted) return;
      setState(() { _loading = false; _error = _mapError(e.code); });
      for (final c in _boxes) { c.clear(); }
      _nodes[0].requestFocus();
    } catch (_) {
      if (!mounted) return;
      setState(() { _loading = false; _error = 'Error inesperado. Intenta de nuevo'; });
    }
  }

  // ── Post sign-in: crear/actualizar doc del driver ─────────────────────────

  Future<void> _afterSignIn(User user) async {
    final driverRef = FirebaseFirestore.instance.collection('drivers').doc(user.uid);
    final snap = await driverRef.get();
    if (!snap.exists) {
      await driverRef.set({
        'phone': user.phoneNumber,
        'createdAt': FieldValue.serverTimestamp(),
        'isOnline': false,
        'activeTripsCount': 0,
      });
    }
    final fcmToken = await FirebaseMessaging.instance.getToken();
    if (fcmToken != null) await driverRef.update({'fcmToken': fcmToken});
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => WelcomeScreen(phoneNumber: user.phoneNumber ?? '')),
      (route) => false,
    );
  }

  // ── Reenvío de código ─────────────────────────────────────────────────────

  Future<void> _resendOtp() async {
    if (_resendSeconds > 0 || _loading) return;
    setState(() { _loading = true; _error = ''; });
    await FirebaseAuth.instance.verifyPhoneNumber(
      phoneNumber: widget.phoneNumber,
      forceResendingToken: _resendToken,
      timeout: const Duration(seconds: 60),
      verificationCompleted: (_) {},
      verificationFailed: (e) {
        if (!mounted) return;
        setState(() { _loading = false; _error = 'Error al reenviar el código. Intenta de nuevo'; });
      },
      codeSent: (String verificationId, int? resendToken) {
        if (!mounted) return;
        _verificationId = verificationId;
        _resendToken = resendToken;
        for (final c in _boxes) { c.clear(); }
        setState(() => _loading = false);
        _startResendTimer();
        _nodes[0].requestFocus();
      },
      codeAutoRetrievalTimeout: (_) {},
    );
  }

  String _mapError(String code) {
    switch (code) {
      case 'invalid-verification-code': return 'Código incorrecto. Revísalo e intenta de nuevo';
      case 'session-expired':           return 'Código expirado. Solicita uno nuevo';
      case 'too-many-requests':         return 'Demasiados intentos. Espera un momento';
      default:                          return 'Error de verificación. Intenta de nuevo';
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _kBg,
      appBar: _buildAppBar(),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              _buildHeader(),
              const SizedBox(height: 40),
              _buildOtpBoxes(),
              const SizedBox(height: 28),
              if (_error.isNotEmpty) ...[
                _buildErrorBanner(),
                const SizedBox(height: 20),
              ],
              _buildVerifyButton(),
              const SizedBox(height: 28),
              _buildResendRow(),
            ],
          ),
        ),
      ),
    );
  }

  PreferredSizeWidget _buildAppBar() {
    return AppBar(
      backgroundColor: _kSurface,
      elevation: 0,
      leading: IconButton(
        icon: const Icon(Icons.arrow_back_ios_new_rounded, color: _kText, size: 18),
        onPressed: () => Navigator.pop(context),
      ),
      title: const Text(
        'Verificación SMS',
        style: TextStyle(color: _kText, fontSize: 16, fontWeight: FontWeight.w600),
      ),
      centerTitle: true,
      bottom: PreferredSize(
        preferredSize: const Size.fromHeight(0.5),
        child: Container(height: 0.5, color: _kDivider),
      ),
    );
  }

  Widget _buildHeader() {
    return Column(
      children: [
        Container(
          width: 72,
          height: 72,
          decoration: BoxDecoration(
            color: _kSurface,
            shape: BoxShape.circle,
            border: Border.all(color: _kAccent.withValues(alpha: 0.35), width: 1.5),
            boxShadow: [
              BoxShadow(
                color: _kAccent.withValues(alpha: 0.14),
                blurRadius: 24,
                spreadRadius: 3,
              ),
            ],
          ),
          child: const Icon(Icons.sms_rounded, color: _kAccent, size: 34),
        ),
        const SizedBox(height: 20),
        const Text(
          'Código enviado',
          style: TextStyle(color: _kText, fontSize: 22, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 10),
        RichText(
          textAlign: TextAlign.center,
          text: TextSpan(
            style: const TextStyle(color: _kHint, fontSize: 13, height: 1.5),
            children: [
              const TextSpan(text: 'Ingresa el código de 6 dígitos enviado a\n'),
              TextSpan(
                text: widget.phoneNumber,
                style: const TextStyle(color: _kAccent, fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildOtpBoxes() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(6, (i) {
        return Container(
          width: 44,
          height: 70,
          margin: const EdgeInsets.symmetric(horizontal: 4),
          child: TextField(
            controller: _boxes[i],
            focusNode: _nodes[i],
            keyboardType: TextInputType.number,
            textAlign: TextAlign.center,
            maxLength: 1,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            style: const TextStyle(
              color: _kText,
              fontSize: 24,
              fontWeight: FontWeight.w700,
            ),
            decoration: InputDecoration(
              counterText: '',
              filled: true,
              fillColor: _kCard,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: _kDivider),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: _kDivider),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: _kAccent, width: 2),
              ),
            ),
            onChanged: (value) {
              if (value.length == 1 && i < 5) _nodes[i + 1].requestFocus();
              if (value.isEmpty && i > 0)      _nodes[i - 1].requestFocus();
              // Auto-verificar al completar los 6 dígitos
              if (_otp.length == 6 && !_autoVerifying) {
                _autoVerifying = true;
                _verifyOtp().whenComplete(() => _autoVerifying = false);
              }
            },
          ),
        );
      }),
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

  Widget _buildVerifyButton() {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton(
        onPressed: _loading ? null : _verifyOtp,
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
                'Verificar código',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
              ),
      ),
    );
  }

  Widget _buildResendRow() {
    return GestureDetector(
      onTap: _resendSeconds == 0 ? _resendOtp : null,
      child: RichText(
        text: TextSpan(
          children: [
            const TextSpan(
              text: '¿No recibiste el código?  ',
              style: TextStyle(color: _kHint, fontSize: 13),
            ),
            if (_resendSeconds > 0)
              TextSpan(
                text: 'Reenviar en ${_resendSeconds}s',
                style: const TextStyle(color: _kHint, fontSize: 13),
              )
            else
              const TextSpan(
                text: 'Reenviar ahora',
                style: TextStyle(color: _kAccent, fontSize: 13, fontWeight: FontWeight.w600),
              ),
          ],
        ),
      ),
    );
  }
}
