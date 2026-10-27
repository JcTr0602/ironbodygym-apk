// lib/ui/guia.dart
// Biblioteca (v47) — SOLO DUEÑO. Cáscara con 2 pestañas: GymPedia
// (existente, embebida) y Guía (nueva). La compuerta filtra en
// lectura: un no-dueño ve el texto de bloqueo, nunca el contenido.
import 'package:flutter/material.dart';

import '../auth.dart';
import 'guia_lista.dart';
import 'gympedia.dart';

class BibliotecaScreen extends StatelessWidget {
  const BibliotecaScreen({super.key});

  @override
  Widget build(BuildContext context) {
    if (!AuthService().isOwner) {
      return Scaffold(
        appBar: AppBar(title: const Text('Biblioteca')),
        body: const Center(
            child: Text('Solo el dueño administra la Biblioteca.')),
      );
    }
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Biblioteca'),
          bottom: const TabBar(
            tabs: [
              Tab(text: 'GymPedia'),
              Tab(text: 'Guía'),
            ],
          ),
        ),
        body: const TabBarView(
          children: [
            GympediaScreen(embebida: true),
            GuiaScreen(),
          ],
        ),
      ),
    );
  }
}
