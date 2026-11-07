/// 💸 Vencidos por cobrar: clientes vencidos ordenados por monto
/// adeudado (mayor primero). El dinero dormido, visible.
library;

import 'package:flutter/material.dart';

import '../cliente_protegido.dart';
import '../negocio.dart';
import '../precio_cobro.dart';
import '../tiempo.dart';
import 'app_bar.dart';
import 'buscar.dart';
import 'componentes.dart';
import 'diseno.dart';
import 'ficha.dart';
import 'widgets.dart';

class CuentasCobrarScreen extends StatefulWidget {
  /// 1.25 T74: dentro de «Por cobrar» va sin Scaffold
  /// propio y sin su héroe (el combinado lo pone la
  /// pantalla única); reporta su total con [onTotalCup].
  final bool incrustada;
  final ValueChanged<double>? onTotalCup;

  const CuentasCobrarScreen(
      {super.key, this.incrustada = false, this.onTotalCup});

  @override
  State<CuentasCobrarScreen> createState() =>
      _CuentasCobrarScreenState();
}

class _CuentasCobrarScreenState
    extends State<CuentasCobrarScreen> {
  bool _cargando = true;
  List<Map<String, dynamic>> _cuentas = [];
  double _total = 0;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    setState(() => _cargando = true);
    final hoy = ahoraHabana();
    final todos = <Map<String, dynamic>>[
      ...await atrasados(masDe30: false),
      ...await atrasados(masDe30: true),
    ]
        // P2#5: los protegidos no aparecen para un no-dueño.
        .where((c) => !esVistaProtegida(c))
        .toList();
    final res = <Map<String, dynamic>>[];
    double total = 0;
    // v1.3.2 (Argón #16): tarifa vigente una sola vez (fuera del loop).
    final pr = await preciosVigentes();
    for (final c in todos) {
      final ph = '${c['pagado_hasta'] ?? ''}';
      int dias = 0;
      if (ph.length >= 10) {
        final f = DateTime.tryParse(ph.substring(0, 10));
        if (f != null) {
          dias = hoy
              .difference(
                  DateTime(f.year, f.month, f.day))
              .inDays;
          if (dias < 0) dias = 0;
        }
      }
      // P2#5: precioCobroParaCliente respeta tarifas especiales
      // (el esMenor?menores:mensual viejo las ignoraba). Casa ya
      // queda fuera en atrasados(); si aun así llegara, su precio
      // es 0 y no infla el total.
      final precio = await precioCobroParaCliente(
        cliente: c,
        periodo: 'mensual',
        metodo: 'efectivo',
        precios: pr,
      );
      final monto = precio.monto;
      total += monto;
      res.add({
        'cliente_id': (c['id'] as num?)?.toInt(),
        'nombre': '${c['nombre'] ?? '—'}',
        'dias': dias,
        'monto': monto,
        'pagado_hasta': ph.length >= 10
            ? ph.substring(0, 10)
            : ph,
        'foto_storage': c['foto_storage'] as String?,
      });
    }
    // Mayor monto primero: el dinero más gordo arriba.
    res.sort((a, b) =>
        (b['monto'] as double).compareTo(a['monto'] as double));
    if (mounted) {
      setState(() {
        _cuentas = res;
        _total = total;
        _cargando = false;
      });
      widget.onTotalCup?.call(total);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cuerpo = _cargando
          ? const EstadoCargando(texto: 'Cargando cuentas por cobrar…')
          : RefreshIndicator(
              onRefresh: _cargar,
              child: ListView(
                padding:
                    const EdgeInsets.all(AppEspacio.lg),
                children: [
                  if (!widget.incrustada) ...[
                    const SyncBanner(alcance: 'pagos'),
                    const SizedBox(height: AppEspacio.sm),
                  ],
                  // Hero: tarjeta carbón con el total
                  // (texto claro legible en ambos temas).
                  // 1.25 T74: incrustada no lo pinta — el
                  // total combinado es el héroe de la
                  // pantalla única.
                  if (!widget.incrustada)
                  Tarjeta(
                    color: AppColores.carbon,
                    child: Column(
                      children: [
                        Text(
                          'Dinero dormido en vencidos',
                          style: AppTexto.secundario.copyWith(
                              color: Colors.white70),
                        ),
                        Text(
                          '${fmtMonto(_total)} CUP',
                          style: AppTexto.display.copyWith(
                              color: AppColores.naranja),
                        ),
                        Text(
                          '${_cuentas.length} clientes vencidos',
                          style: AppTexto.minuscula.copyWith(
                              color: Colors.white70),
                        ),
                        // 1.25 T28: la regla, dicha: cada
                        // monto es UNA mensualidad (la tarifa
                        // del cliente), no su deuda acumulada
                        // — uno de hace 60 días no «debe» el
                        // doble en esta pantalla.
                        Text(
                          'Una mensualidad por cliente '
                          '(su tarifa), no la deuda acumulada',
                          textAlign: TextAlign.center,
                          style: AppTexto.minuscula.copyWith(
                              color: Colors.white70),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: AppEspacio.md),
                  if (_cuentas.isEmpty)
                    const EstadoVacio(
                      icono: Icons.check_circle_rounded,
                      titulo: 'Sin vencidos por cobrar',
                      subtitulo:
                          'Todos los clientes activos están al día.',
                    )
                  else
                    // 1.25 T28: agrupado por antigüedad con
                    // subtotal por grupo (antes una sola
                    // lista por monto: el de 5 días y el de
                    // 60 se veían iguales).
                    for (final grupo in _gruposAntiguedad()) ...[
                      Padding(
                        padding: const EdgeInsets.only(
                            top: AppEspacio.sm,
                            bottom: AppEspacio.xs),
                        child: Row(
                          mainAxisAlignment:
                              MainAxisAlignment.spaceBetween,
                          children: [
                            Text(grupo.$1,
                                style: AppTexto.subtitulo),
                            Text(
                              '${fmtMonto(grupo.$3)} CUP',
                              style:
                                  AppTexto.secundario.copyWith(
                                      fontWeight:
                                          FontWeight.bold),
                            ),
                          ],
                        ),
                      ),
                      for (final c in grupo.$2)
                      Padding(
                        padding: const EdgeInsets.only(
                            bottom: AppEspacio.sm),
                        child: Tarjeta(
                          padding: EdgeInsets.zero,
                          // 1.29 (D-13): la fila es LA fila única
                          // de la casa (FilaCliente), como en
                          // Buscar y Listas — foto, nombre,
                          // insignia con palabra, barra de
                          // antigüedad y el importe tabular con
                          // su palabra. Antes esta pantalla
                          // componía la suya con ListTile y un
                          // avatar propio con los días dentro.
                          child: FilaCliente(
                            cliente: {
                              'id': c['cliente_id'],
                              'nombre': c['nombre'],
                              'pagado_hasta':
                                  (c['pagado_hasta'] as String)
                                          .isEmpty
                                      ? null
                                      : c['pagado_hasta'],
                              'foto_storage': c['foto_storage'],
                            },
                            diasAtraso: (c['dias'] as int) > 0
                                ? c['dias'] as int
                                : null,
                            importeTexto:
                                '${fmtMonto(c['monto'])} CUP',
                            importeEtiqueta: 'tarifa mensual',
                            // P2#5: tocar abre la ficha (desde
                            // donde se cobra).
                            onTap: () {
                              final cid = c['cliente_id'] as int?;
                              if (cid == null || cid == 0) return;
                              Navigator.of(context).push(
                                  RutaIron(
                                      builder: (_) => FichaScreen(
                                          clienteId: cid)));
                            },
                          ),
                        ),
                      ),
                    ],
                ],
              ),
            );
    // 1.25 T74: incrustada, el cuerpo va pelado dentro de
    // la pestaña de «Por cobrar».
    if (widget.incrustada) return cuerpo;
    return Scaffold(
      appBar: appBarIron(
        context,
        'Vencidos por cobrar',
        acciones: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _cargar,
          ),
        ],
      ),
      body: cuerpo,
    );
  }

  /// 1.25 T28: grupos por antigüedad del vencimiento, con
  /// subtotal (cada monto sigue siendo UNA mensualidad).
  /// Dentro de cada grupo se conserva el orden por monto
  /// descendente de _cargar.
  List<(String, List<Map<String, dynamic>>, double)>
      _gruposAntiguedad() {
    bool sinFecha(Map<String, dynamic> c) =>
        (c['pagado_hasta'] as String).isEmpty;
    final bandas =
        <(String, bool Function(Map<String, dynamic>))>[
      (
        'De 1 a 30 días',
        (c) => !sinFecha(c) && (c['dias'] as int) <= 30
      ),
      (
        'Más de 30 días',
        (c) => !sinFecha(c) && (c['dias'] as int) > 30
      ),
      ('Sin fecha de vencimiento', sinFecha),
    ];
    final res = <(String, List<Map<String, dynamic>>, double)>[];
    for (final (titulo, test) in bandas) {
      final filas = _cuentas.where(test).toList();
      if (filas.isEmpty) continue;
      final subtotal = filas.fold<double>(
          0, (s, c) => s + ((c['monto'] as num?)?.toDouble() ?? 0));
      res.add((titulo, filas, subtotal));
    }
    return res;
  }
}
