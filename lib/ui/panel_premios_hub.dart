import 'package:flutter/material.dart';

import '../auth.dart';
import 'app_bar.dart';
import 'panel_premios.dart';
import 'panel_premios_catalogo.dart';

/// Premios (1.27): el hub de Premios del Panel, con
/// pestañas. La Bandeja es la pantalla de la 1.26
/// (embebida, sin su AppBar); el Catálogo (S2/G2) deja
/// editar meta/premio/interruptor de cada logro sin
/// tocar SQL. La pestaña Clientes (G3) llega con su
/// pieza (S3/S4).
class PremiosHubScreen extends StatelessWidget {
  const PremiosHubScreen({super.key});

  @override
  Widget build(BuildContext context) {
    if (!AuthService().isOwner) {
      return Scaffold(
        appBar: appBarIron(context, 'Premios'),
        body: const Center(
            child: Text('Solo el dueño administra los premios.')),
      );
    }
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: appBarIron(
          context,
          'Premios',
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Bandeja'),
              Tab(text: 'Catálogo'),
            ],
          ),
        ),
        body: const TabBarView(
          children: [
            PremiosPanelScreen(embebida: true),
            PremiosCatalogoTab(),
          ],
        ),
      ),
    );
  }
}
