import 'package:flutter/material.dart';

class HomeScreen extends StatelessWidget {
  final String phoneNumber;
  const HomeScreen({super.key, required this.phoneNumber});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Bienvenido Chofer')),
      body: Center(
        child: Text(
          '¡Bienvenido, chofer!\nTu número: $phoneNumber',
          style: const TextStyle(fontSize: 20),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}

