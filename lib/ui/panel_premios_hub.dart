import 'dart:async';

import 'package:flutter/material.dart';

import '../auth.dart';
import 'app_bar.dart';
import 'diseno.dart';
import 'panel_premios.dart';
import 'panel_premios_catalogo.dart';
import 'panel_premios_clientes.dart';

/// Premios (1.27): el hub de Premios del Panel, con
/// pestañas. La Bandeja es la pantalla de la 1.26
/// (embebida, sin su AppBar); el Catálogo (S2/G2) deja
/// editar meta/premio/interruptor de cada logro sin
/// tocar SQL; Clientes (S3/G3) da el detalle por
/// cliente con conceder vale, anular y reiniciar.
///
/// 1.28 (M5-B2): la pestaña «Bandeja» enseña el CONTEO
/// de vales por aprobar sin entrar: el hub lo consulta
/// al abrir y lo refresca con el aviso entre pestañas
/// (aprobar/rechazar en la bandeja y conceder en
/// «Clientes» lo disparan). Si no se puede saber (sin
/// conexión), la pastilla no aparece: nada de ceros
/// mentirosos.
class PremiosHubScreen extends StatefulWidget {
  const PremiosHubScreen({super.key});

  @override
  State<PremiosHubScreen> createState() => _PremiosHubScreenState();
}

class _PremiosHubScreenState extends State<PremiosHubScreen> {
  int? _porAprobar;

  /// Corrección A3-D3 (auditorías 1.28): generación del
  /// conteo, el mismo patrón que el Panel en admin.dart —
  /// sin ella, un reconteo lento podía aterrizar DESPUÉS
  /// de uno nuevo y la pastilla enseñaba el conteo viejo
  /// (con un vale de más) hasta el próximo aviso.
  int _conteoGen = 0;

  @override
  void initState() {
    super.initState();
    premiosAvisosExternos.addListener(_recargarConteo);
    unawaited(_recargarConteo());
  }

  @override
  void dispose() {
    premiosAvisosExternos.removeListener(_recargarConteo);
    super.dispose();
  }

  Future<void> _recargarConteo() async {
    final gen = ++_conteoGen;
    final n = await contarValesPorAprobar();
    if (!mounted || gen != _conteoGen) return;
    setState(() => _porAprobar = n);
  }

  @override
  Widget build(BuildContext context) {
    if (!AuthService().isOwner) {
      return Scaffold(
        appBar: appBarIron(context, 'Premios'),
        body: const Center(
            child: Text('Solo el dueño administra los premios.')),
      );
    }
    final pendientes = _porAprobar ?? 0;
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: appBarIron(
          context,
          'Premios',
          bottom: TabBar(
            tabs: [
              Tab(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('Bandeja'),
                    if (pendientes > 0) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 7, vertical: 1),
                        decoration: BoxDecoration(
                          color: AppColores.naranja,
                          borderRadius:
                              BorderRadius.circular(AppRadio.circular),
                        ),
                        child: Text(
                          '$pendientes',
                          style: AppTexto.metadato.copyWith(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const Tab(text: 'Catálogo'),
              const Tab(text: 'Clientes'),
            ],
          ),
        ),
        body: const TabBarView(
          children: [
            PremiosPanelScreen(embebida: true),
            PremiosCatalogoTab(),
            PremiosClientesTab(),
          ],
        ),
      ),
    );
  }
}
