import 'dart:io';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

enum _PermissionIssue { denied, deniedForever, serviceDisabled }

// Verifica y solicita permiso de ubicación.
// Retorna true si fue otorgado. Si no, muestra diálogo explicativo y retorna false.
Future<bool> checkAndRequestLocationPermission(BuildContext context) async {
  final bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
  if (!serviceEnabled) {
    if (context.mounted) {
      await _showLocationDialog(context, _PermissionIssue.serviceDisabled);
    }
    return false;
  }

  LocationPermission permission = await Geolocator.checkPermission();

  if (permission == LocationPermission.deniedForever) {
    if (context.mounted) {
      await _showLocationDialog(context, _PermissionIssue.deniedForever);
    }
    return false;
  }

  if (permission == LocationPermission.denied) {
    permission = await Geolocator.requestPermission();
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      if (context.mounted) {
        await _showLocationDialog(
          context,
          permission == LocationPermission.deniedForever
              ? _PermissionIssue.deniedForever
              : _PermissionIssue.denied,
        );
      }
      return false;
    }
  }

  return permission == LocationPermission.always ||
      permission == LocationPermission.whileInUse;
}

// Verifica si hay conexión a internet.
// Retorna true si hay conexión. Si no, muestra diálogo y retorna false.
Future<bool> checkInternetAndShow(BuildContext context) async {
  bool connected = false;
  try {
    final result = await InternetAddress.lookup('google.com')
        .timeout(const Duration(seconds: 5));
    connected = result.isNotEmpty && result.first.rawAddress.isNotEmpty;
  } catch (_) {
    connected = false;
  }

  if (!connected && context.mounted) {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _AppDialog(
        icon: Icons.wifi_off_rounded,
        title: 'No Internet Connection',
        body:
            "Eva's Taxi requires an active internet connection to receive trip requests and update your position.\n\nPlease check your Wi-Fi or mobile data and try again.",
        buttonLabel: 'Dismiss',
        onPrimary: () {},
      ),
    );
  }

  return connected;
}

Future<void> _showLocationDialog(
    BuildContext context, _PermissionIssue issue) {
  final bool isServiceOff = issue == _PermissionIssue.serviceDisabled;
  final bool isDeniedForever = issue == _PermissionIssue.deniedForever;

  final String title =
      isServiceOff ? 'Location Services Disabled' : 'Location Access Required';

  final String body = isServiceOff
      ? "Your device's GPS is currently turned off.\n\nEva's Taxi needs location services to track your position and manage trips correctly. Please enable GPS in your device settings."
      : isDeniedForever
          ? "Eva's Taxi needs access to your location to function correctly.\n\nLocation permission was permanently denied. Please enable it manually in the app settings to continue."
          : "Eva's Taxi needs access to your location to show your position on the map and manage assigned trips.\n\nPlease enable location permission in the app settings to continue.";

  final String buttonLabel =
      isServiceOff ? 'Open Location Settings' : 'Open App Settings';

  final VoidCallback onPrimary = isServiceOff
      ? () => Geolocator.openLocationSettings()
      : () => Geolocator.openAppSettings();

  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _AppDialog(
      icon: Icons.location_on_rounded,
      title: title,
      body: body,
      buttonLabel: buttonLabel,
      onPrimary: onPrimary,
    ),
  );
}

class _AppDialog extends StatelessWidget {
  final IconData icon;
  final String title;
  final String body;
  final String buttonLabel;
  final VoidCallback onPrimary;

  const _AppDialog({
    required this.icon,
    required this.title,
    required this.body,
    required this.buttonLabel,
    required this.onPrimary,
  });

  @override
  Widget build(BuildContext context) {
    const Color accent = Color(0xFFF0D02B);
    const Color bg = Color(0xFF1E1E1E);

    return Dialog(
      backgroundColor: bg,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 32, 24, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: accent.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: accent, size: 36),
            ),
            const SizedBox(height: 20),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.2,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              body,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 14,
                height: 1.55,
              ),
            ),
            const SizedBox(height: 28),
            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton(
                onPressed: () {
                  Navigator.of(context).pop();
                  onPrimary();
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: accent,
                  foregroundColor: bg,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: Text(
                  buttonLabel,
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 15,
                  ),
                ),
              ),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text(
                'Not Now',
                style: TextStyle(color: Colors.white38, fontSize: 14),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
