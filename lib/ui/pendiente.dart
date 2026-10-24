/// 💰 Pendiente a entregar / 📥 Pendiente a recoger.
///
/// Entrenadores: ven su propio efectivo pendiente de entregar al dueño.
/// Dueño (v1.0.15): ve el desglose por entrenador (nombre, cantidad de
/// pagos, total) y confirma el recibido de cada uno individualmente.
/// La confirmación encola la op `confirmar_entrega` y se aplica al
/// sincronizar; el espejo local se actualiza en el siguiente pull.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../auth.dart';
import '../localdb.dart';
import '../negocio.dart';
import '../models/pendiente.dart';
import 'package:flutter/services.dart';
import '../sync.dart';
import 'componentes.dart';
import 'diseno.dart';
import 'widgets.dart';

class PendienteScreen extends StatefulWidget {
  const PendienteScreen({super.key});
  @override
  State<PendienteScreen> createState() => _PendienteScreenState();
}

class _PendienteScreenState extends State<PendienteScreen> {
  // Vista entrenador: su propio pendiente.
  List<Map<String, dynamic>> _mens = [];
  List<Map<String, dynamic>> _diarios = [];
  List<Map<String, dynamic>> _servicios = [];
  // v1.3.0 (Pendiente v2): agrupado Entrenador > Días.
  List<EntrenadorPendiente> _entrenadores = [];
  List<Map<String, dynamic>> _crudos = [];
  // Gemini: totales USD separados (no mezclar con CUP).
  double _totalUsd = 0;
  // v1.3.4 (C2d): detalle de ventas de suplementos indexado por id,
  // para el badge de "precio modificado" en el arqueo de caja.
  Map<int, Map<String, dynamic>> _detalleVentasSup = {};
  bool _cargando = true;
  bool _confirmando = false;
  late final bool _esDueno;

  @override
  void initState() {
    super.initState();
    _esDueno = AuthService().isOwner;
    _cargar();
  }

  Future<void> _cargar() async {
    final auth = AuthService();
    if (_esDueno) {
      // El dueño no se cuenta a sí mismo en lo pendiente a recoger.
      final crudos = await pagosPendientesDetalle(
          excluirTid: auth.telegramId);
      // Gemini: USD separado del CUP.
      final usd = await pendienteRecogerUsd(
          excluirTelegramId: auth.telegramId);
      // v1.3.4 (C2d): espejo de ventas para el badge de precio modificado.
      final ventasSup =
          await LocalDb.instance.allMirror('ventas_suplementos');
      if (mounted) {
        setState(() {
          _crudos = crudos;
          _entrenadores = procesarPendientes(crudos);
          _totalUsd = usd;
          _detalleVentasSup = {
            for (final v in ventasSup)
              (v['id'] as num).toInt(): v
          };
          _cargando = false;
        });
      }
    } else {
      final tid = auth.telegramId;
      final (m, d, s) = await detallePendiente(tid);
      // Gemini: USD separado del CUP.
      final usd = await pendienteEntregaUsd(tid);
      if (mounted) {
        setState(() {
          _mens = m;
          _diarios = d;
          _servicios = s;
          _totalUsd = usd;
          _cargando = false;
        });
      }
    }
  }

  double get _totalEntrenador {
    double t = 0;
    for (final p in _mens) {
      t += (p['monto'] as num?)?.toDouble() ?? 0;
    }
    for (final d in _diarios) {
      t += (d['total'] as num?)?.toDouble() ?? 0;
    }
    for (final s in _servicios) {
      t += ((s['precio_unitario'] as num?)?.toDouble() ?? 0) *
          ((s['cantidad'] as num?)?.toDouble() ?? 0);
    }
    return t;
  }

  double get _totalDueno {
    double t = 0;
    for (final e in _entrenadores) {
      t += e.totalPorMoneda('CUP');
    }
    return t;
  }

  /// v1.3.0 (Pendiente v2): confirma por lista de IDs (día o todo).
  /// Optimistic UI: actualiza al instante, persiste en background.
  Future<void> _confirmarPorIds(PendienteDia dia, String nombre,
      String etiqueta, String trainerTelegramId) async {
    // Fix #15 (Sol): el día ya viene separado por moneda (ver
    // procesarPendientes), pero mostramos la moneda real por seguridad.
    final moneda = dia.pagos.isEmpty
        ? 'CUP'
        : dia.pagos.first.moneda;
    final total = dia.totalPorMoneda(moneda);
    // Verificación: todos los pagos del día deben ser de la misma moneda.
    final mixto =
        dia.pagos.any((p) => p.moneda != moneda);
    // Argón B2: si es mixto, mostrar ambos totales.
    final totalCup = dia.totalPorMoneda('CUP');
    final totalUsd = dia.totalPorMoneda('USD');
    final textoMontos = mixto
        ? '${fmtMonto(totalCup)} CUP + ${fmtMonto(totalUsd)} USD'
        : '${fmtMonto(total)} $moneda';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Confirmar recibido de $nombre'),
        content: Text(
            '¿Confirmas que recibiste $textoMontos de $nombre?\n\n'
            '$etiqueta'
            '${mixto ? '\n\n⚠️ Este grupo mezcla monedas.' : ''}'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Confirmar')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    if (_confirmando) return;
    // Gemini: UIDs compuestos para evitar colisión de IDs.
    final uids = dia.pagos.map((p) => p.uid).toSet();
    // Optimistic UI: quitar de la lista al instante.
    final crudosAnteriores =
        List<Map<String, dynamic>>.from(_crudos);
    setState(() {
      _crudos.removeWhere((p) {
        final tipo = '${p['tipo']}';
        final id = p['id'] as int? ?? -1;
        return uids.contains('${tipo}_$id');
      });
      _entrenadores = procesarPendientes(_crudos);
      // Argón B2: recalcular _totalUsd en el setState optimista.
      _totalUsd = _entrenadores.fold(
          0.0, (acc, e) => acc + e.totalPorMoneda('USD'));
      _confirmando = true;
    });
    try {
      // Gemini: solo el guardado local va en el try.
      await confirmarEntregaPorIds(
        mensualIds: dia.mensualIds,
        diarioIds: dia.diarioIds,
        // v1.3.1 (Alto #1): incluir ventas de suplementos o reaparecen.
        suplementoIds: dia.suplementoIds,
        // Ítem 10: y las de servicios, con los ids que se ven.
        servicioIds: dia.servicioIds,
        entrenadorNombre: nombre,
        trainerTelegramId: int.tryParse(trainerTelegramId),
      );
    } catch (e) {
      if (mounted) {
        setState(() {
          _crudos = crudosAnteriores;
          _entrenadores = procesarPendientes(_crudos);
          _totalUsd = _entrenadores.fold(
              0.0, (acc, e) => acc + e.totalPorMoneda('USD'));
        });
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
                content: Text(
                    'Error al guardar, intenta de nuevo')));
      }
      return;
    } finally {
      if (mounted) setState(() => _confirmando = false);
    }
    // Gemini: push fuera del try — si falla por red, queda en cola
    // y NO revierte la UI (ya está guardado localmente).
    unawaited(SyncEngine.instance.push());
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Recibido de $nombre confirmado '
            '(se aplicará al sincronizar)')));
    // Gemini: NO llamar _cargar() aquí — el estado optimista ya está
    // actualizado. Recargar ahora haría reaparecer los pagos porque
    // el mirror aún no se actualizó (el push va en background).
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
          title: Text(
              _esDueno ? 'Pendiente a recoger' : 'Pendiente a entregar')),
      body: Column(
        children: [
          const SyncBanner(),
          if (!_cargando) _tarjetaTotal(),
          Expanded(
            child: _cargando
                ? const Center(child: CircularProgressIndicator())
                : RefreshIndicator(
                    onRefresh: _cargar,
                    child: _esDueno
                        ? _listaDueno()
                        : _listaEntrenador(),
                  ),
          ),
        ],
      ),
    );
  }

  /// v1.2.1: rediseñada al estilo oscuro/naranja de la app
  /// (antes fondo beige que no combinaba).
  /// Gemini: muestra CUP y USD por separado (no mezclar monedas).
  Widget _tarjetaTotal() {
    final total = _esDueno ? _totalDueno : _totalEntrenador;
    final hayPendiente = total > 0 || _totalUsd > 0;
    final subtitulo = _esDueno
        ? (hayPendiente
            ? 'por recoger de los entrenadores'
            : 'al día, nada que recoger')
        : (hayPendiente
            ? 'por entregar al dueño'
            : 'al día, nada pendiente');
    final colorAcento =
        hayPendiente ? AppColores.naranja : AppColores.exito;
    // Gemini: montos por moneda, sin mezclar.
    final montos = <String>[];
    if (total > 0) montos.add('${fmtMonto(total)} CUP');
    if (_totalUsd > 0) montos.add('${_totalUsd.toStringAsFixed(2)} USD');
    final textoMonto =
        montos.isEmpty ? '0 CUP' : montos.join(' · ');
    return Padding(
      padding: const EdgeInsets.all(AppEspacio.md),
      child: Tarjeta(
        padding: const EdgeInsets.all(AppEspacio.lg),
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  hayPendiente
                      ? Icons.account_balance_wallet_outlined
                      : Icons.check_circle_outline,
                  color: colorAcento,
                  size: 28,
                ),
                const SizedBox(width: AppEspacio.sm),
                Flexible(
                  child: Text(textoMonto,
                      textAlign: TextAlign.center,
                      style: AppTexto.display.copyWith(
                        color: colorAcento,
                        fontWeight: FontWeight.bold,
                      )),
                ),
              ],
            ),
            const SizedBox(height: AppEspacio.xs),
            Text(subtitulo,
                style: AppTexto.secundario.copyWith(
                    color:
                        AppColores.textoSecundario(context))),
          ],
        ),
      ),
    );
  }

  /// Vista entrenador: sin cambios (su propio pendiente).
  Widget _listaEntrenador() {
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      children: [
        if (_mens.isNotEmpty) ...[
          const Text('Mensualidades en efectivo:',
              style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          for (final p in _mens)
            ListTile(
              dense: true,
              leading: const Text(''),
              title:
                  Text('${fmtMonto(p['monto'])} CUP — ${p['metodo']}'),
              subtitle: Text(
                  '${fmtFecha(p['fecha'] as String?)} · ${p['meses'] ?? 1} mes(es)'),
            ),
          const SizedBox(height: 12),
        ],
        if (_diarios.isNotEmpty) ...[
          const Text('Pagos diarios:',
              style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          for (final d in _diarios)
            ListTile(
              dense: true,
              leading: const Text(''),
              title: Text('${fmtMonto(d['total'])} CUP'),
              subtitle: Text(
                  '${fmtFecha(d['fecha'] as String?)} · ${d['turno'] ?? ''} x${d['cantidad'] ?? '?'}'),
            ),
        ],
        if (_servicios.isNotEmpty) ...[
          const Text('Servicios (dosis y agua):',
              style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          for (final s in _servicios)
            ListTile(
              dense: true,
              leading: const Icon(Icons.bolt,
                  color: AppColores.naranja, size: 18),
              title: Text(
                  '${fmtMonto(((s['precio_unitario'] as num?)?.toDouble() ?? 0) * ((s['cantidad'] as num?)?.toDouble() ?? 0))} CUP — '
                  '${switch ('${s['tipo']}') {
                    'dosis_con_agua' => 'Combo',
                    'agua_suelta' => 'Pomo de agua',
                    _ => 'Ración',
                  }}'),
              subtitle: Text(
                  '${fmtFecha(s['fecha'] as String?)}'
                  '${'${s['cliente_nombre'] ?? ''}'.isNotEmpty ? ' · ${s['cliente_nombre']}' : ''}'),
            ),
        ],
        if (_mens.isEmpty && _diarios.isEmpty && _servicios.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 32),
            child: Text(
                'Sin pagos pendientes de entrega.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey)),
          ),
      ],
    );
  }

  /// v1.3.0 (Pendiente v2): Entrenador > Días.
  Widget _listaDueno() {
    if (_entrenadores.isEmpty) {
      return ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: const [
          Padding(
            padding: EdgeInsets.only(top: 32),
            child: Text(
                'Nada pendiente de recoger.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey)),
          ),
        ],
      );
    }
    return ListView.builder(
      padding:
          const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      itemCount: _entrenadores.length,
      itemBuilder: (ctx, i) =>
          _EntrenadorCard(
        entrenador: _entrenadores[i],
        confirmando: _confirmando,
        // v1.3.4 (C2d): detalle de ventas para el badge de precio.
        detalleVentas: _detalleVentasSup,
        onConfirmarDia: (dia) => _confirmarPorIds(
          dia,
          _entrenadores[i].nombre,
          'Se marcarán como entregados los ${dia.pagos.length} '
          'pagos del ${dia.etiquetaFecha.toLowerCase()}.',
          _entrenadores[i].trainerTelegramId,
        ),
        onConfirmarTodo: () {
          // Combinar todos los días en un pseudo-día.
          final todos = _entrenadores[i].dias
              .expand((d) => d.pagos)
              .toList();
          final pseudo = PendienteDia(
              fecha: DateTime.now(), pagos: todos);
          _confirmarPorIds(
            pseudo,
            _entrenadores[i].nombre,
            'Se marcarán como entregados todos sus pagos pendientes.',
            _entrenadores[i].trainerTelegramId,
          );
        },
        onWhatsApp: () =>
            _copiarCuadre(_entrenadores[i]),
      ),
    );
  }

  /// Copia el texto de cuadre al portapapeles (Gemini #5).
  Future<void> _copiarCuadre(
      EntrenadorPendiente ent) async {
    final totalCup = ent.totalPorMoneda('CUP');
    final totalUsd = ent.totalPorMoneda('USD');
    final buf = StringBuffer();
    buf.writeln(
        '${ent.nombre}, pendiente a entregar:');
    for (final dia in ent.dias) {
      // Argón B2: usar moneda real del día.
      final m = dia.pagos.isEmpty
          ? 'CUP'
          : dia.pagos.first.moneda;
      buf.writeln(
          '• ${dia.etiquetaFecha}: '
          '${fmtMonto(dia.totalPorMoneda(m))} $m '
          '(${dia.pagos.length} pagos)');
    }
    buf.write('Total: ${fmtMonto(totalCup)} CUP');
    if (totalUsd > 0) {
      buf.write(' + ${fmtMonto(totalUsd)} USD');
    }
    await Clipboard.setData(
        ClipboardData(text: buf.toString()));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text(
                'Texto copiado, pégalo en WhatsApp')));
  }
}

/// Tarjeta de entrenador con sus días (v1.3.0).
class _EntrenadorCard extends StatelessWidget {
  final EntrenadorPendiente entrenador;
  final bool confirmando;
  final void Function(PendienteDia dia) onConfirmarDia;
  final VoidCallback onConfirmarTodo;
  final VoidCallback onWhatsApp;
  // v1.3.4 (C2d): ventas de suplementos por id (badge precio modificado).
  final Map<int, Map<String, dynamic>> detalleVentas;

  const _EntrenadorCard({
    required this.entrenador,
    required this.confirmando,
    required this.onConfirmarDia,
    required this.onConfirmarTodo,
    required this.onWhatsApp,
    this.detalleVentas = const {},
  });

  @override
  Widget build(BuildContext context) {
    final nombre = entrenador.nombre;
    // Argón B2: mostrar CUP y USD.
    final totalCup = entrenador.totalPorMoneda('CUP');
    final totalUsd = entrenador.totalPorMoneda('USD');
    final totalTxt = totalUsd > 0
        ? '${fmtMonto(totalCup)} CUP + ${fmtMonto(totalUsd)} USD'
        : '${fmtMonto(totalCup)} CUP';
    final n = entrenador.totalPagos;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ExpansionTile(
        leading: CircleAvatar(
          backgroundColor: Colors.orange.shade100,
          child: Text(
            nombre.isNotEmpty
                ? nombre[0].toUpperCase()
                : '?',
            style: const TextStyle(
                fontWeight: FontWeight.bold,
                color: Colors.deepOrange),
          ),
        ),
        title: Row(
          children: [
            Flexible(
              child: Text(nombre,
                  style: const TextStyle(
                      fontWeight: FontWeight.bold)),
            ),
            if (entrenador.tieneRetraso) ...[
              const SizedBox(width: 6),
              const Icon(Icons.warning_amber_rounded,
                  color: Colors.amber, size: 18),
            ],
          ],
        ),
        subtitle:
            Text('$n pago${n == 1 ? '' : 's'} sin entregar'),
        trailing: Text(
          totalTxt,
          style: const TextStyle(
              fontWeight: FontWeight.bold,
              color: Colors.deepOrange,
              fontSize: 15),
        ),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(
                horizontal: 12, vertical: 4),
            child: Column(
              children: [
                for (final dia in entrenador.dias)
                  _DiaTile(
                    dia: dia,
                    detalleVentas: detalleVentas,
                    onConfirmar: confirmando
                        ? null
                        : () => onConfirmarDia(dia),
                  ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    icon: const Icon(Icons.check_circle_outline,
                        size: 18),
                    label: Text(
                        'Cobrar todo ($totalTxt)'),
                    onPressed: confirmando
                        ? null
                        : onConfirmarTodo,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green,
                      foregroundColor: Colors.white,
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.share, size: 16),
                    label:
                        const Text('Cuadre a WhatsApp'),
                    onPressed: onWhatsApp,
                  ),
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Tarjeta plana de un día (Gemini #4): sin acordeón doble.
class _DiaTile extends StatefulWidget {
  final PendienteDia dia;
  final VoidCallback? onConfirmar;
  // v1.3.4 (C2d): ventas de suplementos por id (badge precio modificado).
  final Map<int, Map<String, dynamic>> detalleVentas;

  const _DiaTile({
    required this.dia,
    this.onConfirmar,
    this.detalleVentas = const {},
  });

  @override
  State<_DiaTile> createState() => _DiaTileState();
}

class _DiaTileState extends State<_DiaTile> {
  bool _mostrarTodos = false;

  Color _badgeBg(int nivel) {
    if (nivel == 2) return Colors.red.shade100;
    if (nivel == 1) return Colors.amber.shade100;
    return Colors.grey.shade200;
  }

  Color _badgeFg(int nivel) {
    if (nivel == 2) return Colors.red.shade900;
    if (nivel == 1) return Colors.amber.shade900;
    return Colors.black87;
  }

  /// v1.3.4 (C2d): chip ámbar cuando una venta de suplemento se cobró a
  /// un precio distinto del oficial. Comparación en centavos enteros
  /// (candado a de auditoría). Muestra también la `nota_precio` si existe.
  Widget _chipPrecioModificado(PagoPendiente p) {
    if (p.tipo != 'suplemento') return const SizedBox.shrink();
    final v = widget.detalleVentas[p.id];
    if (v == null) return const SizedBox.shrink();
    // Priorizar centavos enteros (candado a); fallback a doubles.
    final oficialCent = (v['precio_oficial_centavos'] as num?)?.toInt() ??
        (((v['precio_oficial'] as num?)?.toDouble() ?? 0) * 100).round();
    final cobradoCent = (v['precio_venta_centavos'] as num?)?.toInt() ??
        (((v['precio'] as num?)?.toDouble() ?? 0) * 100).round();
    if (oficialCent == 0 || cobradoCent == 0) {
      return const SizedBox.shrink();
    }
    if (cobradoCent == oficialCent) {
      return const SizedBox.shrink();
    }
    final mon = '${v['moneda'] ?? p.moneda}';
    final nota = (v['nota_precio'] as String?)?.trim();
    return Padding(
      padding: const EdgeInsets.only(left: 20, top: 3, right: 4),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(
            horizontal: 8, vertical: 5),
        decoration: BoxDecoration(
          color: Colors.amber.shade100,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: Colors.amber.shade800),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '⚠️ Precio modificado '
              '(Oficial: ${(oficialCent / 100).toStringAsFixed(2)} $mon → '
              'Cobrado: ${(cobradoCent / 100).toStringAsFixed(2)} $mon)',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: Colors.amber.shade900,
              ),
            ),
            if (nota != null && nota.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  '📝 $nota',
                  style: const TextStyle(
                    fontSize: 11,
                    color: Colors.black87,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final dia = widget.dia;
    // Argón #15: usar la moneda real del día, no 'CUP' fijo.
    final monedaDia =
        dia.pagos.isEmpty ? 'CUP' : dia.pagos.first.moneda;
    final total = dia.totalPorMoneda(monedaDia);
    final visibles = (_mostrarTodos ||
            dia.pagos.length <= 3)
        ? dia.pagos
        : dia.pagos.take(3).toList();
    final icono = dia.nivelAlerta == 2
        ? '🔴 '
        : dia.nivelAlerta == 1
            ? '⚠️ '
            : '';

    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
            color: Colors.grey.shade300),
      ),
      // v1.3.2 (Argón): el fondo es claro fijo; blindar el color del texto
      // para que ningún Text herede el blanco del tema oscuro.
      child: DefaultTextStyle.merge(
        style: const TextStyle(color: Colors.black87),
        child: Column(
        crossAxisAlignment:
            CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color:
                      _badgeBg(dia.nivelAlerta),
                  borderRadius:
                      BorderRadius.circular(6),
                ),
                child: Text(
                  '$icono${dia.etiquetaFecha}',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: _badgeFg(
                        dia.nivelAlerta),
                  ),
                ),
              ),
              const Spacer(),
              Text(
                '${fmtMonto(total)} $monedaDia',
                style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                    color: Colors.black87),
              ),
              IconButton(
                visualDensity:
                    VisualDensity.compact,
                icon: const Icon(Icons.done_all,
                    color: Colors.teal, size: 20),
                tooltip: 'Cobrar este día',
                onPressed: widget.onConfirmar,
              ),
            ],
          ),
          const SizedBox(height: 4),
          for (final p in visibles)
            Padding(
              padding: const EdgeInsets.symmetric(
                  vertical: 2),
              child: Column(
                crossAxisAlignment:
                    CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        p.tipo == 'mensual'
                            ? Icons.calendar_month
                            : p.tipo == 'servicio'
                                ? Icons.bolt
                                : Icons.today,
                        size: 14,
                        color: Colors.grey.shade600,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          '${p.descripcion} (${p.tipo})',
                          style: const TextStyle(
                              fontSize: 12,
                              color: Colors.black54),
                          overflow:
                              TextOverflow.ellipsis,
                        ),
                      ),
                      Text(
                        '${fmtMonto(p.monto)} ${p.moneda}',
                        style: const TextStyle(
                            fontSize: 12,
                            fontWeight:
                                FontWeight.w600,
                            color: Colors.black87),
                      ),
                    ],
                  ),
                  // v1.3.4 (C2d): badge si se cobró distinto del oficial.
                  _chipPrecioModificado(p),
                ],
              ),
            ),
          if (dia.pagos.length > 3)
            InkWell(
              onTap: () => setState(
                  () => _mostrarTodos =
                      !_mostrarTodos),
              child: Padding(
                padding:
                    const EdgeInsets.only(top: 4),
                child: Text(
                  _mostrarTodos
                      ? 'Ocultar detalles'
                      : 'Ver ${dia.pagos.length - 3} pagos más...',
                  style: TextStyle(
                      color: Theme.of(context)
                          .primaryColor,
                      fontSize: 12,
                      fontWeight:
                          FontWeight.w500),
                ),
              ),
            ),
        ],
        ),
      ),
    );
  }
}
