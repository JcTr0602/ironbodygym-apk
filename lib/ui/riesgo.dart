/// Clientes en riesgo (solo dueño): inactivos que antes pagaban
/// puntual, para recuperarlos.
///
/// Criterio: estado='inactivo', al menos 3 pagos históricos y último
/// pago hace más de 60 días. Muestra nombre, último pago y total
/// pagado históricamente.
library;

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../auth.dart';
import '../cliente_protegido.dart';
import '../localdb.dart';
import '../negocio.dart';
import '../tiempo.dart';
import 'app_bar.dart';
import 'componentes.dart';
import 'ficha.dart';
import 'diseno.dart';
import 'widgets.dart';
import '../app_log.dart';

class RiesgoScreen extends StatefulWidget {
  const RiesgoScreen({super.key});

  @override
  State<RiesgoScreen> createState() => _RiesgoScreenState();
}

class _RiesgoScreenState extends State<RiesgoScreen> {
  List<Map<String, dynamic>> _riesgo = [];
  // (1.36 H-B4 136-889) búsqueda y orden de la lista.
  String _busqueda = '';
  bool _ordenPorDias = false;

  List<Map<String, dynamic>> get _visibles {
    final q = _busqueda.trim().toLowerCase();
    final base = q.isEmpty
        ? [..._riesgo]
        : _riesgo
            .where((r) =>
                '${r['nombre']}'.toLowerCase().contains(q) ||
                '${r['telefono']}'.contains(q))
            .toList();
    if (_ordenPorDias) {
      base.sort((a, b) =>
          (b['hace_dias'] as int).compareTo(a['hace_dias'] as int));
    }
    return base;
  }
  bool _cargando = true;
  // (136-802) triestado de carga con EstadoError y reintento.
  String? _errorCarga;

  @override
  void initState() {
    super.initState();
    // (1.36 H-B4 136-888) sin dueño ni se carga: la bandera
    // baja para que el build pinte su guarda, no un spinner.
    if (AuthService().isOwner) {
      _cargar();
    } else {
      _cargando = false;
    }
  }

  Future<void> _cargar() async {
    // (Yunque R2-X1) red de seguridad: la bandera baja
    // SIEMPRE (y el fallo queda en bitácora), también si una lectura local lanza a mitad
    // (spinner eterno: la clase de la ficha 2026-11-02).
    try {
      await _cargarDatos();
    } catch (e) {
      // El error NO se traga: queda en bitácora
      // (la clase nació de fallos mudos).
      AppLog.error('ui', 'carga_fallo', d: '$e');
      if (mounted) setState(() => _errorCarga = '$e');
    } finally {
      if (mounted && _cargando) {
        setState(() => _cargando = false);
      }
    }
  }

  Future<void> _cargarDatos() async {
    setState(() => _cargando = true);
    final datos = await _clientesEnRiesgo();
    if (mounted) {
      setState(() {
        _riesgo = datos;
        _errorCarga = null;
        _cargando = false;
      });
    }
  }

  /// Inactivos con 3+ pagos cuyo último pago fue hace más de 60 días.
  Future<List<Map<String, dynamic>>> _clientesEnRiesgo() async {
    final clientes = await LocalDb.instance.allMirror('clientes');
    final hoy = ahoraHabana();
    final res = <Map<String, dynamic>>[];
    for (final c in clientes) {
      if (c['estado'] != 'inactivo') continue;
      // P2#8-parte: la cabecera dice solo dueño; fuera protegidos
      // para un no-dueño.
      if (esVistaProtegida(c)) continue;
      final cid = c['id'] as int?;
      if (cid == null) continue;
      // v1.3.4 (ítem 2): columna `cliente_id` indexada en vez de
      // allMirror + filtro en Dart.
      final hp = await LocalDb.instance.pagosPorCliente(cid);
      if (hp.length < 3) continue;
      hp.sort(
          (a, b) => '${b['fecha']}'.compareTo('${a['fecha']}'));
      final ultimoStr = '${hp.first['fecha'] ?? ''}';
      if (ultimoStr.length < 10) continue;
      final fUlt =
          DateTime.tryParse(ultimoStr.substring(0, 10));
      if (fUlt == null) continue;
      final haceDias = hoy.difference(fUlt).inDays;
      if (haceDias <= 60) continue;
      final total = hp.fold<double>(
          0, (t, p) => t + ((p['monto'] as num?)?.toDouble() ?? 0));
      // 1.25 T39: la fila conserva el id y el teléfono wa.me
      // (antes se leían del espejo y se tiraban: la lista de
      // trabajo no dejaba trabajar — ni ficha, ni escribir).
      var wa = normalizarTelefonoWaMe('${c['movil'] ?? ''}');
      if (wa.isEmpty) {
        wa = normalizarTelefonoWaMe('${c['telefono'] ?? ''}');
      }
      res.add({
        'id': cid,
        'wa': wa,
        // (1.36 H-B4 136-889) la búsqueda también es por teléfono.
        'telefono': '${c['telefono'] ?? ''} ${c['movil'] ?? ''}',
        'nombre': '${c['nombre'] ?? '—'}',
        'ultimo_pago': ultimoStr.substring(0, 10),
        'hace_dias': haceDias,
        'n_pagos': hp.length,
        'total': total,
      });
    }
    // Los que más pagaron primero (más valiosos de recuperar).
    res.sort((a, b) =>
        (b['total'] as double).compareTo(a['total'] as double));
    return res;
  }

  @override
  Widget build(BuildContext context) {
    // P2#8-parte: guarda de dueño en build (la cabecera promete
    // "solo dueño" pero no había guarda).
    if (!AuthService().isOwner) {
      return Scaffold(
          appBar: appBarIron(context, 'Clientes en riesgo'),
          body: const Center(
              child: Text('Solo el dueño ve esta pantalla.')));
    }
    return Scaffold(
      appBar: appBarIron(
        context,
        'Clientes en riesgo',
        acciones: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            // (1.36 H-B4 136-891) tooltip del refresco.
            tooltip: 'Actualizar',
            onPressed: _cargar,
          ),
        ],
      ),
      body: _cargando
          ? const EstadoCargando(texto: 'Cargando clientes en riesgo…')
          : _errorCarga != null
              ? EstadoError(
                  titulo: 'No se pudieron cargar los clientes en riesgo',
                  detalle: _errorCarga,
                  onReintentar: () {
                    setState(() {
                      _errorCarga = null;
                      _cargando = true;
                    });
                    _cargar();
                  },
                )
              : Column(
              children: [
                const SyncBanner(),
                // (1.36 H-B4 136-889) buscar y ordenar.
                if (_riesgo.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(AppEspacio.md,
                        AppEspacio.sm, AppEspacio.md, 0),
                    child: Row(
                      children: [
                        Expanded(
                          child: CampoTexto(
                            etiqueta: 'Buscar por nombre o teléfono',
                            icono: Icons.search_rounded,
                            onChanged: (v) =>
                                setState(() => _busqueda = v),
                          ),
                        ),
                        const SizedBox(width: AppEspacio.sm),
                        ChoiceChip(
                          label: const Text('Por días'),
                          selected: _ordenPorDias,
                          onSelected: (v) =>
                              setState(() => _ordenPorDias = v),
                        ),
                        ChoiceChip(
                          label: const Text('Por total'),
                          selected: !_ordenPorDias,
                          onSelected: (v) =>
                              setState(() => _ordenPorDias = !v),
                        ),
                      ],
                    ),
                  ),
                Expanded(
                  child: _riesgo.isEmpty
                      ? const EstadoVacio(
                          icono: Icons.person_off_rounded,
                          titulo: 'No hay clientes en riesgo',
                          subtitulo: 'Se muestran aquí los inactivos '
                              'con 3+ pagos cuyo último pago fue hace '
                              'más de 60 días.',
                        )
                      : RefrescoIron(
                          onRefresh: _cargar,
                          child: ListView.builder(
                            padding: const EdgeInsets.symmetric(
                                horizontal: AppEspacio.md,
                                vertical: AppEspacio.sm),
                            itemCount: _visibles.length,
                            itemBuilder: (ctx, i) {
                              final r = _visibles[i];
                              return Padding(
                                padding: const EdgeInsets.only(
                                    bottom: AppEspacio.sm),
                                child: Tarjeta(
                                  padding: EdgeInsets.zero,
                                  child: ListTile(
                                    leading: const CircleAvatar(
                                      backgroundColor:
                                          AppColores.naranja,
                                      child: Icon(
                                          Icons.warning_amber_rounded,
                                          color: Colors.white,
                                          size: 22),
                                    ),
                                    // 1.25 T39: tocar abre la
                                    // ficha (desde ahí se cobra
                                    // y se escribe); el botón
                                    // wa.me va directo a
                                    // recuperar al cliente.
                                    onTap: () {
                                      final cid = r['id'] as int?;
                                      if (cid == null) return;
                                      Navigator.of(context).push(
                                          RutaIron(
                                              builder: (_) =>
                                                  FichaScreen(
                                                      clienteId:
                                                          cid)));
                                    },
                                    trailing:
                                        (r['wa'] as String? ?? '')
                                                .isEmpty
                                            ? null
                                            : IconButton(
                                                icon: const Icon(
                                                    Icons
                                                        .chat_rounded),
                                                tooltip:
                                                    'Escribir por WhatsApp',
                                                onPressed: () async {
                                                  final url = Uri.parse(
                                                      'https://wa.me/${r['wa']}');
                                                  await launchUrl(url,
                                                      mode: LaunchMode
                                                          .externalApplication);
                                                },
                                              ),
                                    title: Text(
                                      '${r['nombre']}',
                                      style: AppTexto.subtitulo,
                                    ),
                                    subtitle: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment
                                              .start,
                                      children: [
                                        Text(
                                            'Último pago: ${fmtFecha(r['ultimo_pago'] as String?)} '
                                            '(hace ${r['hace_dias']} días)'),
                                        Text(
                                            'Total histórico: ${fmtMonto(r['total'])} CUP '
                                            '(${r['n_pagos']} pagos)'),
                                      ],
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                ),
              ],
            ),
    );
  }
}
