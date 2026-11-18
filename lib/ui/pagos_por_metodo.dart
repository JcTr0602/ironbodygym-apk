// lib/ui/pagos_por_metodo.dart
// v1.3.9 Sprint 3 (#6): desglose de pagos por método.
// SegmentedButton: Hoy | Mes Actual | Mes Anterior
import 'package:flutter/material.dart';
import '../auth.dart';
import '../estadisticas_servicios.dart' show esCasaTolerante;
import '../negocio.dart';
import '../localdb.dart';
import '../tiempo.dart';
import '../errores_sync.dart' show mensajeErrorAmable;
import 'app_bar.dart';
import 'componentes.dart';
import 'diseno.dart';

/// Totales USD de suplementos por método en un rango (PURO, sin mezclar
/// con CUP): solo las ventas de suplementos en USD; transferencia
/// aparte, el resto a efectivo. Las al fiado sin saldar ya vienen
/// filtradas por ventasSuplementosUsd. Los pagos, diarios y servicios
/// son solo CUP, así que no aportan USD.
({double efectivo, double transferencia}) totalesUsdPorMetodo({
  required List<Map<String, dynamic>> ventasUsd,
  required String desde,
  required String hasta,
}) {
  var efectivo = 0.0;
  var transferencia = 0.0;
  for (final v in ventasUsd) {
    final f = '${v['fecha'] ?? ''}';
    if (f.length < 10) continue;
    final dia = f.substring(0, 10);
    if (dia.compareTo(desde) < 0 || dia.compareTo(hasta) > 0) continue;
    final monto = totalVentaUsd(v);
    if ('${v['metodo'] ?? ''}'.toLowerCase().contains('transfer')) {
      transferencia += monto;
    } else {
      efectivo += monto;
    }
  }
  return (efectivo: efectivo, transferencia: transferencia);
}

class PagosPorMetodo extends StatefulWidget {
  const PagosPorMetodo({super.key});

  @override
  State<PagosPorMetodo> createState() =>
      _PagosPorMetodoState();
}

class _PagosPorMetodoState
    extends State<PagosPorMetodo> {
  int _periodoIdx = 0; // 0=Hoy, 1=Mes, 2=Mes anterior
  bool _cargando = true;
  double _efectivo = 0;
  double _transferencia = 0;
  double _mixto = 0;
  double _efectivoUsd = 0;
  double _transferenciaUsd = 0;
  // 1.25 T118 (F2-08): operaciones por método (CUP): el monto
  // solo no distingue «muchos pagos chicos» de «pocos grandes».
  int _nEfectivo = 0;
  int _nTransferencia = 0;
  int _nMixto = 0;
  // 1.36 H-B2 (136-631): tras la primera carga, cambiar de
  // periodo conserva la lista (franja de progreso encima).
  bool _yaCargo = false;

  static const _periodos = [
    'hoy',
    'mes',
    'mes_anterior'
  ];

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    setState(() => _cargando = true);
    try {
      final periodo = _periodos[_periodoIdx];
      double efectivo = 0;
      double transferencia = 0;
      double mixto = 0;
      double efectivoUsd = 0;
      double transferenciaUsd = 0;
      int nEfectivo = 0;
      int nTransferencia = 0;
      int nMixto = 0;

      if (periodo == 'mes_anterior') {
        // Rango del mes anterior completo
        final hoy = ahoraHabana();
        final primerDiaMesActual =
            DateTime(hoy.year, hoy.month, 1);
        final ultimoDiaMesAnterior = primerDiaMesActual
            .subtract(const Duration(days: 1));
        final primerDiaMesAnterior = DateTime(
            ultimoDiaMesAnterior.year,
            ultimoDiaMesAnterior.month,
            1);
        String iso(DateTime d) =>
            '${d.year.toString().padLeft(4, '0')}-'
            '${d.month.toString().padLeft(2, '0')}-'
            '${d.day.toString().padLeft(2, '0')}';
        final desde = iso(primerDiaMesAnterior);
        final hasta = iso(ultimoDiaMesAnterior);

        // Argón P1#8: misma cobertura que pagosDelPeriodo (hoy/mes):
        // pagos + diarios + suplementos + servicios, con Casa fuera.
        final casas = await LocalDb.instance.idsCuentasCasa();
        // Argón 1.25 MEDIA: fuera también los anulados
        // en cola y, del CONTEO de operaciones, los
        // métodos sin cobro (cortesia/promo, monto 0):
        // inflaban el «N pagos» de la barra.
        final anuladosCola =
            await LocalDb.instance.pagosAnuladosEnCola();
        bool esCasa(Map<String, dynamic> p) {
          if (p['casa'] == 1 || p['casa'] == true) return true;
          final cid = p['cliente_id'];
          final n = cid is num
              ? cid.toInt()
              : int.tryParse('$cid');
          return n != null && casas.contains(n);
        }

        for (final p in await LocalDb.instance
            .mirrorPorFecha('pagos', 'fecha', desde, hasta)) {
          if (esCasa(p)) continue;
          if (esPagoAnulado(p, anuladosCola)) continue;
          final monto =
              (p['monto'] as num?)?.toDouble() ?? 0;
          final metodo =
              '${p['metodo'] ?? 'efectivo'}'.toLowerCase();
          if (metodo == 'cortesia' || metodo == 'promo') {
            continue;
          }
          // 1.36 H-B2 (136-629): solo cuentan operaciones
          // con monto > 0 (un registro en cero no es un
          // cobro), en las cuatro fuentes y ambos periodos.
          if (monto <= 0) continue;
          if (metodo.contains('transfer')) {
            transferencia += monto;
            nTransferencia++;
          } else if (metodo.contains('mixto')) {
            mixto += monto;
            nMixto++;
          } else {
            efectivo += monto;
            nEfectivo++;
          }
        }
        // Diarios (igual que pagosDelPeriodo: columna `total`).
        // Argón Dinero #6: con su método real, no todo a efectivo.
        for (final d in await LocalDb.instance
            .mirrorPorFecha('pagos_diarios', 'fecha', desde, hasta)) {
          // 136-629: diario en cero no cuenta como operación.
          final totalDiario = (d['total'] as num?)?.toDouble() ?? 0;
          if (totalDiario <= 0) continue;
          if (esPagoDiarioEfectivo(d)) {
            efectivo += totalDiario;
            nEfectivo++;
          } else {
            transferencia += totalDiario;
            nTransferencia++;
          }
        }
        // Suplementos en CUP, por su método real (#6).
        for (final v in await ventasSuplementosCup()) {
          // Yunque R4-M4-6: día de negocio Habana (no el
          // substring crudo del timestamp) y método por
          // contains('transfer'), como la vía hoy/mes —
          // la igualdad exacta mandaba una variante
          // («Transferencia») a efectivo SOLO en el mes
          // anterior, el término de la comparación.
          final dia = fechaNegocioHabana(v['fecha']);
          if (dia.isNotEmpty &&
              dia.compareTo(desde) >= 0 &&
              dia.compareTo(hasta) <= 0) {
            // 136-629: venta en cero no cuenta.
            final totalV = totalVentaCup(v);
            if (totalV <= 0) {
              // sin operación
            } else if ('${v['metodo'] ?? 'efectivo'}'
                .toLowerCase()
                .contains('transfer')) {
              transferencia += totalV;
              nTransferencia++;
            } else {
              efectivo += totalV;
              nEfectivo++;
            }
          }
        }
        // Servicios netos (sin reversos ni Casa; igual que
        // _servicioVentasNetas de negocio.dart).
        final ventasServ =
            await LocalDb.instance.allMirror('servicio_ventas');
        final reversadas = <int>{
          for (final v in ventasServ)
            if ((v['reverso_de'] as num?) != null)
              (v['reverso_de'] as num).toInt(),
        };
        for (final v in ventasServ) {
          if ((v['reverso_de'] as num?) != null) continue;
          final id = (v['id'] as num?)?.toInt();
          if (id != null && reversadas.contains(id)) continue;
          // Yunque R4-M4-6: Casa TOLERANTE (1/true/'1'), no
          // solo el cast numérico.
          if (esCasaTolerante(v['casa'])) continue;
          // Yunque R4-M4-6: día de negocio Habana y método
          // por contains('transfer'), como la vía hoy/mes.
          final dia = fechaNegocioHabana(v['fecha']);
          if (dia.isNotEmpty &&
              dia.compareTo(desde) >= 0 &&
              dia.compareTo(hasta) <= 0) {
            // Terra 1.18: separar por método; una dosis o agua
            // pagada por transferencia no es efectivo.
            final monto =
                ((v['precio_unitario'] as num?)?.toDouble() ?? 0) *
                    ((v['cantidad'] as num?)?.toInt() ?? 0);
            // 136-629: servicio en cero no cuenta.
            if (monto <= 0) continue;
            if ('${v['metodo'] ?? ''}'
                .toLowerCase()
                .contains('transfer')) {
              transferencia += monto;
              nTransferencia++;
            } else {
              efectivo += monto;
              nEfectivo++;
            }
          }
        }
        // USD (2/25): suplementos en USD por método, sin mezclar con CUP.
        final usdAnt = totalesUsdPorMetodo(
          ventasUsd: await ventasSuplementosUsd(),
          desde: desde,
          hasta: hasta,
        );
        efectivoUsd = usdAnt.efectivo;
        transferenciaUsd = usdAnt.transferencia;
      } else {
        final pagos =
            await pagosDelPeriodo(periodo);
        // USD (2/25): mismo rango que pagosDelPeriodo (hoy o mes).
        final hoyUsd = ahoraHabana();
        String isoUsd(DateTime d) =>
            '${d.year.toString().padLeft(4, '0')}-'
            '${d.month.toString().padLeft(2, '0')}-'
            '${d.day.toString().padLeft(2, '0')}';
        final desdeUsd = periodo == 'hoy'
            ? isoUsd(hoyUsd)
            : isoUsd(DateTime(hoyUsd.year, hoyUsd.month, 1));
        final hastaUsd = periodo == 'hoy'
            ? isoUsd(hoyUsd)
            : isoUsd(DateTime(hoyUsd.year, hoyUsd.month + 1, 0));
        final usdRango = totalesUsdPorMetodo(
          ventasUsd: await ventasSuplementosUsd(),
          desde: desdeUsd,
          hasta: hastaUsd,
        );
        efectivoUsd = usdRango.efectivo;
        transferenciaUsd = usdRango.transferencia;
        for (final p in pagos) {
          final monto =
              (p['monto'] as num?)?.toDouble() ??
                  0;
          final metodo =
              '${p['metodo'] ?? 'efectivo'}'
                  .toLowerCase();
          // Argón 1.25 MEDIA: cortesía/promo (monto 0)
          // no cuentan como operación de cobro.
          if (metodo == 'cortesia' || metodo == 'promo') {
            continue;
          }
          // 136-629: monto <= 0 tampoco (cualquier método).
          if (monto <= 0) continue;
          if (metodo.contains('transfer')) {
            transferencia += monto;
            nTransferencia++;
          } else if (metodo.contains('mixto')) {
            mixto += monto;
            nMixto++;
          } else {
            efectivo += monto;
            nEfectivo++;
          }
        }
      }

      if (mounted) {
        setState(() {
          _efectivo = efectivo;
          _transferencia = transferencia;
          _mixto = mixto;
          _efectivoUsd = efectivoUsd;
          _transferenciaUsd = transferenciaUsd;
          _nEfectivo = nEfectivo;
          _nTransferencia = nTransferencia;
          _nMixto = nMixto;
          _cargando = false;
          _yaCargo = true;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _cargando = false);
        // SL-5 G07-5: nada crudo a pantalla — el aviso usa
        // el mensaje amable de la casa, no la excepción.
        mostrarSnack(context, mensajeErrorAmable(e), significado: SignificadoChip.error);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // Argón P1#8: pantalla solo dueño.
    if (!AuthService().isOwner) {
      return Scaffold(
        appBar: appBarIron(context, 'Pagos por Método'),
        // 1.36 H-B2 (136-630): acceso no-dueño con el
        // componente de la casa e icono de bloqueo.
        body: const EstadoVacio(
          icono: Icons.lock_rounded,
          titulo: 'Solo el dueño',
          subtitulo:
              'Solo el dueño puede ver los pagos por método.',
        ),
      );
    }
    final total =
        _efectivo + _transferencia + _mixto;

    return Scaffold(
      appBar: appBarIron(context, 'Pagos por Método'),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(AppEspacio.lg),
            child: SegmentedButton<int>(
              // 1.36 H-B2 (136-630/631): sin check sobre la
              // etiqueta y rótulos «Mes actual»/«Mes anterior».
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(
                    value: 0,
                    label: Text('Hoy')),
                ButtonSegment(
                    value: 1,
                    label: Text('Mes actual')),
                ButtonSegment(
                    value: 2,
                    label: Text('Mes anterior')),
              ],
              selected: {_periodoIdx},
              onSelectionChanged: (s) {
                setState(
                    () => _periodoIdx = s.first);
                _cargar();
              },
            ),
          ),
          if (_cargando && !_yaCargo)
            const Expanded(
              child: EstadoCargando(texto: 'Cargando desglose…'),
            )
          // 1.36 H-B2 (136-630): periodo en cero → EstadoVacio
          // con el periodo nombrado, sin barras ni total en 0.
          else if (!_cargando &&
              total <= 0 &&
              _efectivoUsd + _transferenciaUsd <= 0)
            Expanded(
              child: EstadoVacio(
                icono: Icons.payments_rounded,
                titulo: [
                  'Sin cobros hoy',
                  'Sin cobros este mes',
                  'Sin cobros el mes anterior'
                ][_periodoIdx],
                subtitulo:
                    'Cuando haya cobros, el desglose por método '
                    'sale aquí.',
              ),
            )
          else
            Expanded(
              // 1.36 H-B2 (136-631): la lista (y su scroll) se
              // conserva al cambiar de periodo; la recarga se
              // anuncia con la franja superior.
              child: ListView(
                key: const PageStorageKey('pagos-por-metodo'),
                padding: const EdgeInsets.symmetric(
                    horizontal: AppEspacio.lg),
                children: [
                  if (_cargando)
                    const Padding(
                      padding: EdgeInsets.only(bottom: AppEspacio.sm),
                      child: LinearProgressIndicator(),
                    ),
                  // 136-630: MISMA regla de ocultación para
                  // todos los métodos: la barra en cero no se
                  // pinta (antes solo Mixto y Transf. USD se
                  // ocultaban; Efectivo/Transferencia salían
                  // en cero).
                  if (_efectivo > 0)
                    _buildBarra(
                      'Efectivo',
                      _efectivo,
                      total,
                      AppColores.metodoEfectivo,
                      Icons.money_rounded,
                      operaciones: _nEfectivo,
                    ),
                  if (_efectivo > 0 && _transferencia > 0)
                    const SizedBox(height: 12),
                  if (_transferencia > 0)
                    _buildBarra(
                      'Transferencia',
                      _transferencia,
                      total,
                      AppColores.metodoTransferencia,
                      Icons.credit_card_rounded,
                      operaciones: _nTransferencia,
                    ),
                  if (_mixto > 0) ...[
                    const SizedBox(height: 12),
                    _buildBarra(
                      'Mixto',
                      _mixto,
                      total,
                      AppColores.naranja,
                      Icons.swap_horiz_rounded,
                      operaciones: _nMixto,
                    ),
                  ],
                  const SizedBox(height: 24),
                  Tarjeta(
                    child: Row(
                      mainAxisAlignment:
                          MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'Total',
                          style: AppTexto.titulo,
                        ),
                        Text(
                          '${fmtMonto(total)} CUP',
                          style: AppTexto.tituloPagina.copyWith(color: AppColores.naranja, fontWeight: FontWeight.w700),
                        ),
                      ],
                    ),
                  ),
                  if (_efectivoUsd + _transferenciaUsd > 0) ...[
                    const SizedBox(height: 24),
                    Text(
                      'USD (solo suplementos)',
                      style: AppTexto.titulo.copyWith(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 12),
                    if (_efectivoUsd > 0)
                      _buildBarra(
                        'Efectivo USD',
                        _efectivoUsd,
                        _efectivoUsd + _transferenciaUsd,
                        AppColores.metodoEfectivo,
                        Icons.money_rounded,
                        moneda: 'USD',
                      ),
                    if (_efectivoUsd > 0 && _transferenciaUsd > 0)
                      const SizedBox(height: 12),
                    if (_transferenciaUsd > 0)
                      _buildBarra(
                        'Transferencia USD',
                        _transferenciaUsd,
                        _efectivoUsd + _transferenciaUsd,
                        AppColores.metodoTransferencia,
                        Icons.credit_card_rounded,
                        moneda: 'USD',
                      ),
                    const SizedBox(height: 12),
                    Tarjeta(
                      child: Row(
                        mainAxisAlignment:
                            MainAxisAlignment.spaceBetween,
                        children: [
                          const Text(
                            'Total USD',
                            style: AppTexto.titulo,
                          ),
                          Text(
                            '${fmtMonto(_efectivoUsd + _transferenciaUsd)} USD',
                            style: AppTexto.tituloPagina.copyWith(color: AppColores.naranja, fontWeight: FontWeight.w700),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildBarra(String titulo, double monto,
      double total, Color color, IconData icono,
      {String moneda = 'CUP', int? operaciones}) {
    final pct =
        total > 0 ? (monto / total * 100) : 0.0;
    // C1: Tarjeta del sistema (el Card crudo no adaptaba borde
    // ni sombra) y grises del sistema en la barra y el porcentaje.
    return Tarjeta(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icono, color: color, size: 20),
              const SizedBox(width: 8),
              Text(
                titulo,
                style: AppTexto.titulo.copyWith(fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              // 1.36 H-B2 (136-631): el monto cuenta hasta
              // su valor al cambiar de periodo.
              MontoAnimado(
                valor: monto,
                formato: (v) => '${fmtMonto(v)} $moneda',
                style: AppTexto.titulo.copyWith(color: color),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(AppRadio.sm),
            // 136-631: la barra crece hasta su fracción.
            child: TweenAnimationBuilder<double>(
              tween: Tween<double>(
                  begin: 0, end: total > 0 ? monto / total : 0),
              duration: AppMovimiento.resuelta(
                  context, AppMovimiento.media),
              builder: (context, fraccion, _) =>
                  LinearProgressIndicator(
                value: fraccion,
                minHeight: 12,
                backgroundColor:
                    AppColores.borde(context).withValues(alpha: 0.3),
                valueColor:
                    AlwaysStoppedAnimation<Color>(color),
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            // F2-08: el % y, si se conoce, cuántas operaciones
            // forman la cifra.
            operaciones == null
                ? '${pct.toStringAsFixed(1)}%'
                : '${pct.toStringAsFixed(1)}% · $operaciones '
                    'pago${operaciones == 1 ? '' : 's'}',
            style: AppTexto.metadato.copyWith(color: AppColores.textoSecundario(context)),
          ),
        ],
      ),
    );
  }
}
