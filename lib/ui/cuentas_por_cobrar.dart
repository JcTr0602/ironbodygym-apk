/// Fiados por cobrar — fiados de suplementos pendientes (v1.3.7, Fase B §6.2).
///
/// Lista las ventas con `es_fiado=1` del espejo, con total por cobrar.
/// Al cobrar un fiado se encola la op `saldar_fiado_suplemento` (el
/// servidor lo marca como saldado; el pull lo saca de la lista).
/// Regla de negocio: el fiado NO suma al "Total cobrado" de actividad
/// hasta que se salda.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../auth.dart';
import '../localdb.dart';
import '../sync.dart';
import '../tiempo.dart';
import 'componentes.dart';
import 'diseno.dart';
import 'widgets.dart';

/// Totales de fiados separados por moneda (Argón #9, ALTO). El _total()
/// viejo sumaba cant*precio mezclando CUP con USD y la pantalla
/// etiquetaba todo como USD (un fiado de 3000 CUP se mostraba como
/// 3000.00 USD). La moneda ausente es CUP, igual que en
/// HistorialVentasScreen._totales(). PURO.
({double cup, double usd}) totalesFiados(
    List<Map<String, dynamic>> fiados) {
  var cup = 0.0;
  var usd = 0.0;
  for (final v in fiados) {
    final cant = (v['cantidad'] as num?)?.toInt() ?? 0;
    final precio = (v['precio'] as num?)?.toDouble() ?? 0;
    final total = cant * precio;
    if ((v['moneda'] as String?) == 'USD') {
      usd += total;
    } else {
      cup += total;
    }
  }
  return (cup: cup, usd: usd);
}

class CuentasPorCobrarScreen extends StatefulWidget {
  const CuentasPorCobrarScreen({super.key});

  @override
  State<CuentasPorCobrarScreen> createState() =>
      _CuentasPorCobrarScreenState();
}

/// 1.15 V2: payload de la op `saldar_fiado_suplemento`.
/// El método viaja explícito (el servidor ya lo lee como
/// `p.metodo or row.metodo or "efectivo"`); el monto y la moneda
/// viajan para que el pendiente CUP de la app pueda valorar la
/// op encolada sin leer el espejo (montoEfectivoOp es síncrona).
Map<String, dynamic> payloadSaldarFiado({
  required dynamic ventaId,
  required String fecha,
  required String metodo,
  required double monto,
  required String moneda,
}) =>
    {
      'venta_id': ventaId,
      'fecha': fecha,
      'metodo': metodo,
      'monto': monto,
      'moneda': moneda,
    };

class _CuentasPorCobrarScreenState
    extends State<CuentasPorCobrarScreen> {
  List<Map<String, dynamic>> _fiados = [];
  Map<int, Map<String, dynamic>> _productos = {};
  Map<int, String> _clientes = {};
  bool _cargando = true;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  bool _esFiadoPendiente(Map<String, dynamic> v) {
    final esFiado = (v['es_fiado'] as num?)?.toInt() == 1;
    if (!esFiado) return false;
    // Ya saldado (el servidor lo marca; tolerante si aún no llega).
    final saldado = (v['fiado_saldado'] as num?)?.toInt() == 1;
    return !saldado;
  }

  Future<void> _cargar() async {
    setState(() => _cargando = true);
    final todas =
        await LocalDb.instance.allMirror('ventas_suplementos');
    final tid = AuthService().telegramId;
    final esDueno = AuthService().isOwner;
    var fiados = todas.where(_esFiadoPendiente).toList();
    if (!esDueno && tid != null) {
      fiados = fiados
          .where((v) => (v['registrado_por'] as num?)?.toInt() == tid)
          .toList();
    }
    fiados.sort((a, b) =>
        '${a['fecha'] ?? ''}'.compareTo('${b['fecha'] ?? ''}'));

    // Argón #9 (MEDIO): un fiado cobrado offline (op
    // saldar_fiado_suplemento en cola) no debe reaparecer si el
    // espejo se refresca antes de que suba la cola o si la marca
    // optimista se perdió: se excluye todo fiado con cobro
    // pendiente en ops_queue (solo ops vivas: aplicada ya está en
    // el espejo y rechazada no se aplicará).
    final dbOps = await LocalDb.instance.db;
    final opsSaldar = await dbOps.query('ops_queue',
        columns: ['payload'],
        where: "tipo = 'saldar_fiado_suplemento' "
            "AND estado NOT IN ('aplicada', 'rechazada')");
    final cobradosPendientes = <int>{};
    for (final o in opsSaldar) {
      try {
        final p =
            jsonDecode(o['payload'] as String) as Map<String, dynamic>;
        final vid = (p['venta_id'] as num?)?.toInt();
        if (vid != null) cobradosPendientes.add(vid);
      } catch (_) {}
    }
    if (cobradosPendientes.isNotEmpty) {
      fiados = fiados
          .where((v) =>
              !cobradosPendientes.contains((v['id'] as num?)?.toInt()))
          .toList();
    }

    final prods = await LocalDb.instance.allMirror('suplementos');
    final mapaProd = <int, Map<String, dynamic>>{};
    for (final p in prods) {
      final id = (p['id'] as num?)?.toInt();
      if (id != null) mapaProd[id] = p;
    }
    final clientes = await LocalDb.instance.allMirror('clientes');
    final mapaCli = <int, String>{};
    for (final c in clientes) {
      final id = (c['id'] as num?)?.toInt();
      if (id != null) mapaCli[id] = '${c['nombre'] ?? 'Cliente $id'}';
    }
    if (!mounted) return;
    setState(() {
      _fiados = fiados;
      _productos = mapaProd;
      _clientes = mapaCli;
      _cargando = false;
    });
  }

  String _textoTotal() {
    final t = totalesFiados(_fiados);
    final partes = <String>[];
    if (t.cup != 0) partes.add('${t.cup.toStringAsFixed(2)} CUP');
    if (t.usd != 0) partes.add('${t.usd.toStringAsFixed(2)} USD');
    return partes.isEmpty ? '0.00 CUP' : partes.join(' · ');
  }

  Future<void> _saldar(Map<String, dynamic> v) async {
    final prodId = (v['suplemento_id'] as num?)?.toInt();
    final prod = prodId != null ? _productos[prodId] : null;
    final nombreProd = prod != null
        ? '${prod['nombre'] ?? 'Suplemento'}'
        : 'Suplemento';
    final cliId = (v['fiado_cliente_id'] as num?)?.toInt() ??
        (v['cliente_id'] as num?)?.toInt();
    final nombreCli =
        cliId != null ? (_clientes[cliId] ?? 'Cliente $cliId') : '—';
    final cant = (v['cantidad'] as num?)?.toInt() ?? 0;
    final precio = (v['precio'] as num?)?.toDouble() ?? 0;
    final total = cant * precio;
    final moneda = '${v['moneda'] ?? 'CUP'}';
    // Argón #9 (MEDIO): el cast directo v['id'] as int reventaba
    // con TypeError DESPUÉS de encolar la op si el id no era int.
    // Se valida antes de encolar.
    final ventaId = (v['id'] as num?)?.toInt();
    if (ventaId == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('No se puede cobrar: venta sin identificador')));
      return;
    }

    // 1.15 V2: selector de método de cobro. Solo el efectivo
    // suma al pendiente CUP (la transferencia va directo a la
    // cuenta del dueño); el método viaja en el payload.
    var metodo = 'efectivo';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => DialogoApp(
          titulo: 'Cobrar fiado',
          iconoTitulo: Icons.payments_outlined,
          contenido: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('$nombreProd × $cant\n'
                  'Cliente: $nombreCli\n'
                  'Total a cobrar: ${total.toStringAsFixed(2)} $moneda\n\n'
                  'Se registrará como cobro normal y se saldará la deuda.'),
              const SizedBox(height: 12),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(
                      value: 'efectivo', label: Text('Efectivo')),
                  ButtonSegment(
                      value: 'transferencia',
                      label: Text('Transferencia')),
                ],
                selected: {metodo},
                onSelectionChanged: (s) =>
                    setD(() => metodo = s.first),
              ),
            ],
          ),
          acciones: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColores.naranja,
                foregroundColor: Colors.white,
              ),
              child: const Text('Cobrar'),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return;
    final fechaCobro = hoyHabanaIso();
    await LocalDb.instance.queueOp(
      opUuid: const Uuid().v4(),
      tipo: 'saldar_fiado_suplemento',
      payload: payloadSaldarFiado(
        ventaId: ventaId,
        fecha: fechaCobro,
        metodo: metodo,
        monto: total,
        moneda: moneda,
      ),
    );
    // Optimista: actualiza el espejo local (el pull lo confirma).
    await LocalDb.instance.marcarFiadoSaldado(ventaId, fechaCobro);
    if (mounted) {
      setState(() {
        _fiados.remove(v);
      });
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Fiado cobrado (se sincronizará)')));
    }
    unawaited(SyncEngine.instance.push());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Fiados por cobrar')),
      body: Column(
        children: [
          const SyncBanner(compact: true),
          _tarjetaTotal(),
          Expanded(child: _cuerpo()),
        ],
      ),
    );
  }

  Widget _tarjetaTotal() {
    return Padding(
      padding: const EdgeInsets.all(AppEspacio.md),
      child: Tarjeta(
        child: Row(
          children: [
            IconoModuloBadge.naranja(
                Icons.account_balance_wallet_outlined),
            const SizedBox(width: AppEspacio.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${_fiados.length} fiado(s) pendiente(s)',
                      style: AppTexto.subtitulo),
                  Text(
                      'Total por cobrar: ${_textoTotal()}',
                      style: AppTexto.cuerpo.copyWith(
                          fontWeight: FontWeight.bold,
                          color: AppColores.naranja)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _cuerpo() {
    if (_cargando) {
      return const EstadoCargando(texto: 'Cargando fiados por cobrar…');
    }
    if (_fiados.isEmpty) {
      return const Center(
          child: Text('Sin fiados pendientes',
              style: AppTexto.secundario));
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(
          horizontal: AppEspacio.md),
      itemCount: _fiados.length,
      itemBuilder: (ctx, i) {
        final v = _fiados[i];
        final prodId =
            (v['suplemento_id'] as num?)?.toInt();
        final prod =
            prodId != null ? _productos[prodId] : null;
        final nombreProd = prod != null
            ? '${prod['nombre'] ?? 'Suplemento'}'
            : 'Suplemento';
        final cliId =
            (v['fiado_cliente_id'] as num?)?.toInt() ??
                (v['cliente_id'] as num?)?.toInt();
        final nombreCli = cliId != null
            ? (_clientes[cliId] ?? 'Cliente $cliId')
            : '—';
        final cant = (v['cantidad'] as num?)?.toInt() ?? 0;
        final precio = (v['precio'] as num?)?.toDouble() ?? 0;
        final moneda = '${v['moneda'] ?? 'CUP'}';
        final fecha = '${v['fecha'] ?? ''}';
        return Tarjeta(
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: IconoModuloBadge.naranja(
                Icons.person_outline),
            title: Text('$nombreProd × $cant',
                style: AppTexto.cuerpo
                    .copyWith(fontWeight: FontWeight.w600)),
            subtitle: Text(
                '$nombreCli\n$fecha',
                style: AppTexto.secundario),
            isThreeLine: true,
            trailing: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                    '${(cant * precio).toStringAsFixed(2)} $moneda',
                    style: AppTexto.cuerpo.copyWith(
                        fontWeight: FontWeight.bold,
                        color: AppColores.naranja)),
                TextButton(
                  onPressed: () => _saldar(v),
                  child: const Text('Cobrar'),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
