/// Detalle del pendiente a entregar de un entrenador (v1.0.16).
///
/// Desde "Pendiente por entrenador" en Administración: al tocar un
/// entrenador se ve cada movimiento pendiente (cliente, monto, fecha,
/// tipo) y se puede abrir la ficha del cliente para verificar.
library;

import 'package:flutter/material.dart';

import '../auth.dart';
import '../negocio.dart';
import 'app_bar.dart';
import 'componentes.dart';
import 'diseno.dart';
import 'ficha.dart';
import 'skeleton.dart';
import 'widgets.dart';
import '../app_log.dart';

class DetallePendienteScreen extends StatefulWidget {
  final int trainerId;
  final String nombre;
  const DetallePendienteScreen(
      {super.key, required this.trainerId, required this.nombre});

  @override
  State<DetallePendienteScreen> createState() =>
      _DetallePendienteScreenState();
}

class _DetallePendienteScreenState extends State<DetallePendienteScreen> {
  bool _cargando = true;
  bool _restringido = false;
  // 1.36 H-B2 (136-674): el fallo de carga se declara.
  bool _errorCarga = false;
  List<Map<String, dynamic>> _items = [];
  double _adelantos = 0;
  // 1.22 T-01: la cabecera sale de la función CANÓNICA
  // (pendienteEntrega/pendienteEntregaUsd), no de sumar los
  // ítems: la suma de ítems ignora los adelantos de gaveta, el
  // libro C1 y el arrastre de parciales, y la cabecera decía
  // 2000 donde Mi Turno y el Arqueo decían 1500/2700 para el
  // mismo bolsillo.
  double _totalCup = 0;
  double _totalUsd = 0;

  @override
  void initState() {
    super.initState();
    _cargar();
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
      if (mounted) setState(() => _errorCarga = true);
    } finally {
      if (mounted && _cargando) {
        setState(() => _cargando = false);
      }
    }
  }

  Future<void> _cargarDatos() async {
    // 1.22 T-10: un entrenador solo puede ver SU detalle; el
    // dueño ve el de cualquiera.
    final auth = AuthService();
    if (!auth.isOwner && auth.telegramId != widget.trainerId) {
      if (mounted) {
        setState(() {
          _restringido = true;
          _cargando = false;
        });
      }
      return;
    }
    final items = await detallePendienteEntrenador(widget.trainerId);
    final adelantos = await adelantosEnPendiente(widget.trainerId);
    final totalCup = await pendienteEntrega(widget.trainerId);
    final totalUsd = await pendienteEntregaUsd(widget.trainerId);
    if (mounted) {
      setState(() {
        _items = items;
        _adelantos = adelantos;
        _totalCup = totalCup;
        _totalUsd = totalUsd;
        _cargando = false;
        _errorCarga = false;
      });
    }
  }

  /// post-1.8.0 (ítem 10, Argón): resumen por categorías — los
  /// servicios se separan en raciones, combos y pomos de agua (no un
  /// solo saco), y al pie van los adelantos de gaveta si los hay.
  Widget _resumenCategorias(BuildContext context) {
    double suma(bool Function(Map<String, dynamic>) f) => _items
        .where(f)
        .fold(
            0.0,
            (s, e) =>
                s +
                ((e['tipo'] == 'pago' ? e['monto'] : e['total']) as num)
                    .toDouble() *
                    ((e['moneda'] as String? ?? 'CUP') == 'USD' ? 0 : 1));
    final filas = <(String, double)>[
      ('Mensualidades', suma((e) => e['tipo'] == 'pago')),
      ('Pagos diarios', suma((e) => e['tipo'] == 'diario')),
      ('Suplementos', suma((e) => e['tipo'] == 'suplemento')),
      (
        'Dosis',
        suma((e) =>
            e['tipo'] == 'servicio' && e['servicio_tipo'] == 'dosis_sin_agua')
      ),
      (
        'Dosis con agua',
        suma((e) =>
            e['tipo'] == 'servicio' && e['servicio_tipo'] == 'dosis_con_agua')
      ),
      (
        'Agua',
        suma((e) =>
            e['tipo'] == 'servicio' && e['servicio_tipo'] == 'agua_suelta')
      ),
    ]..removeWhere((f) => f.$2 == 0);
    // 1.25 T118 (F2-09): el desglose se muestra SIEMPRE que
    // haya algo que desglosar — antes desaparecía justo en el
    // caso simple (una sola categoría sin adelantos), que es
    // cuando más fácil era explicarlo. Solo se oculta si no
    // hay filas ni adelantos (nada que desglosar).
    if (filas.isEmpty && _adelantos <= 0) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppEspacio.lg, AppEspacio.xs, AppEspacio.lg, AppEspacio.xs),
      child: Tarjeta(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final f in filas)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    Text(f.$1),
                    const Spacer(),
                    Text('${fmtMonto(f.$2)} CUP',
                        style: const TextStyle(
                            fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
            if (_adelantos > 0) ...[
              const Divider(height: 14),
              Row(
                children: [
                  const Text('Menos adelantos de gaveta'),
                  const Spacer(),
                  Text('−${fmtMonto(_adelantos)} CUP',
                      style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: AppColores.error)),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_restringido) {
      return Scaffold(
        appBar: appBarIron(context, widget.nombre),
        // 136-674: restricción con el vacío de candado.
        body: const EstadoVacio(
          icono: Icons.lock_rounded,
          titulo: 'Solo puedes ver tu propio pendiente a entregar',
        ),
      );
    }
    // 1.22 T-01: totales canónicos (ver _totalCup en _cargar).
    final total = _totalCup;
    final totalUsd = _totalUsd;
    return Scaffold(
      appBar: appBarIron(context, widget.nombre),
      body: Column(
        children: [
          const SyncBanner(),
          if (!_cargando)
            // F2-09: cabecera héroe con la cifra autoritativa,
            // como la tarjeta total de pendiente.dart (antes
            // era una fila de texto suelta y las dos pantallas
            // del mismo dinero se veían distintas).
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  AppEspacio.lg, AppEspacio.md, AppEspacio.lg,
                  AppEspacio.xs),
              child: Tarjeta(
                padding: const EdgeInsets.all(AppEspacio.md),
                child: Column(
                  children: [
                    // 136-675: la cifra héroe cuenta hasta
                    // su valor.
                    MontoAnimado(
                      valor: total,
                      formato: (v) =>
                          '${fmtMonto(v)} CUP${totalUsd > 0 ? ' + ${fmtMonto(totalUsd)} USD' : ''}',
                      style: AppTexto.tituloPagina.copyWith(
                          color: AppColores.naranja),
                    ),
                    Text(
                        '${_items.length} movimiento${_items.length == 1 ? '' : 's'} '
                        'pendiente${_items.length == 1 ? '' : 's'}',
                        style: AppTexto.secundario),
                  ],
                ),
              ),
            ),
          if (!_cargando && _items.isNotEmpty) _resumenCategorias(context),
          Expanded(
            // 1.36 H-B2 (136-674/676): esqueleto al cargar,
            // error declarado y cruce entre estados.
            child: AnimatedSwitcher(
              duration: AppMovimiento.media,
              child: _cargando
                ? const Padding(
                    key: ValueKey('cargando'),
                    padding: EdgeInsets.all(AppEspacio.lg),
                    child: SkeletonLista(items: 4),
                  )
                : _errorCarga && _items.isEmpty
                    ? EstadoError(
                        key: const ValueKey('error'),
                        titulo: 'No se pudo cargar el pendiente',
                        onReintentar: _cargar,
                      )
                    : _items.isEmpty
                    ? const EstadoVacio(
                        icono: Icons.check_circle_rounded,
                        titulo: 'Nada pendiente',
                        subtitulo:
                            'Todo lo cobrado ya se entregó.',
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.all(AppEspacio.md),
                        itemCount: _items.length,
                        itemBuilder: (c, i) {
                          final it = _items[i];
                          if (it['tipo'] == 'suplemento') {
                            return Padding(
                              padding: const EdgeInsets.only(
                                  bottom: AppEspacio.sm),
                              child: Tarjeta(
                                padding: EdgeInsets.zero,
                                child: ListTile(
                                  leading: Icon(
                                      Icons.shopping_bag_rounded,
                                      color: AppColores.textoSecundario(context),
                                      size: 24),
                                  title: Text(
                                      '${it['suplemento_nombre']} x${it['cantidad']}'),
                                  subtitle: Text(
                                      '${fmtFecha(it['fecha'])}'
                                      '${(it['nota'] as String).isNotEmpty ? ' · ${it['nota']}' : ''}'),
                                  trailing: Text(
                                      '${fmtMonto((it['total'] as num).toDouble())} ${it['moneda']}',
                                      style: const TextStyle(
                                          fontWeight:
                                              FontWeight.bold)),
                                ),
                              ),
                            );
                          }
                          if (it['tipo'] == 'servicio') {
                            return Padding(
                              padding: const EdgeInsets.only(
                                  bottom: AppEspacio.sm),
                              child: Tarjeta(
                                padding: EdgeInsets.zero,
                                child: ListTile(
                                  leading: Icon(
                                      Icons.bolt_rounded,
                                      color: AppColores.textoSecundario(context),
                                      size: 24),
                                  title: Text(switch (
                                      '${it['servicio_tipo']}') {
                                    'dosis_con_agua' =>
                                      'Dosis con agua',
                                    'agua_suelta' => 'Agua',
                                    _ => 'Dosis',
                                  }),
                                  subtitle: Text(
                                      '${fmtFecha(it['fecha'])}'
                                      '${(it['cliente_nombre'] as String).isNotEmpty ? ' · ${it['cliente_nombre']}' : ''}'),
                                  trailing: Text(
                                      '${fmtMonto((it['total'] as num).toDouble())} CUP',
                                      style: const TextStyle(
                                          fontWeight:
                                              FontWeight.bold)),
                                ),
                              ),
                            );
                          }
                          if (it['tipo'] == 'diario') {
                            return Padding(
                              padding: const EdgeInsets.only(
                                  bottom: AppEspacio.sm),
                              child: Tarjeta(
                                padding: EdgeInsets.zero,
                                child: ListTile(
                                  title: Text(
                                      'Pago diario — ${it['turno']}'),
                                  subtitle: Text(
                                      '${fmtFecha(it['fecha'])} · '
                                      '${it['cantidad']} clientes'
                                      '${(it['nota'] as String).isNotEmpty ? ' · ${it['nota']}' : ''}'),
                                  trailing: Text(
                                      '${fmtMonto((it['total'] as num).toDouble())} CUP',
                                      style: const TextStyle(
                                          fontWeight:
                                              FontWeight.bold)),
                                ),
                              ),
                            );
                          }
                          final esInsc =
                              it['es_inscripcion'] == true;
                          return Padding(
                            padding:
                                const EdgeInsets.only(bottom: AppEspacio.sm),
                            child: Tarjeta(
                              padding: EdgeInsets.zero,
                              child: ListTile(
                                leading: Icon(
                                    esInsc
                                        ? Icons.person_add_rounded
                                        : Icons.payments_rounded,
                                    color: AppColores.textoSecundario(context),
                                    size: 24),
                                title: Text(
                                    '${it['cliente_nombre']}',
                                    style: const TextStyle(
                                        fontWeight:
                                            FontWeight.w500)),
                                subtitle: Text(
                                    '${esInsc ? 'Inscripción' : etiquetaPeriodo(it, detallado: true)} · '
                                    '${fmtFecha(it['fecha'])}'),
                                trailing: Text(
                                    '${fmtMonto((it['monto'] as num).toDouble())} CUP',
                                    style: const TextStyle(
                                        fontWeight:
                                            FontWeight.bold)),
                                onTap: () {
                                  final cid =
                                      it['cliente_id'] as int?;
                                  if (cid == null ||
                                      cid == 0) {
                                    return;
                                  }
                                  Navigator.of(context)
                                      .push(RutaIron(
                                          builder: (_) =>
                                              FichaScreen(
                                                  clienteId:
                                                      cid)));
                                },
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
