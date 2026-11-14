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
import '../negocio.dart' show fmtFecha, totalVentaRegistrado;
import '../sync.dart';
import '../tiempo.dart';
import 'app_bar.dart';
import 'componentes.dart';
import 'diseno.dart';
import 'widgets.dart';
import '../app_log.dart';

/// Totales de fiados separados por moneda (Argón #9, ALTO). El _total()
/// viejo sumaba cant*precio mezclando CUP con USD y la pantalla
/// etiquetaba todo como USD (un fiado de 3000 CUP se mostraba como
/// 3000.00 USD). La moneda ausente es CUP, igual que en
/// HistorialVentasScreen._totales(). PURO.
/// Yunque R5-M4-1: predicado de fiado pendiente con la forma
/// TOLERANTE canónica de negocio.dart (un flag vale si es 1 o
/// true). La copia local de la pantalla usaba el cast numérico
/// estricto: una venta cuyo `es_fiado` llegara como bool true
/// quedaba FUERA de «Por cobrar» mientras negocio la contaba
/// como fiado — la deuda desaparecía de la superficie de cobro.
bool esFiadoPendienteVenta(Map<String, dynamic> v) {
  final esFiado = v['es_fiado'] == 1 || v['es_fiado'] == true;
  if (!esFiado) return false;
  // Ya saldado (el servidor lo marca; tolerante si aún no llega).
  final saldado =
      v['fiado_saldado'] == 1 || v['fiado_saldado'] == true;
  return !saldado;
}

({double cup, double usd}) totalesFiados(
    List<Map<String, dynamic>> fiados) {
  var cup = 0.0;
  var usd = 0.0;
  for (final v in fiados) {
    // Yunque 1.34 (C4-3): el total REGISTRADO manda
    // (totalVentaRegistrado), no cantidad×precio.
    final total = totalVentaRegistrado(v);
    // D2-09: moneda normalizada (LocalDb.monedaDe) — 'usd' en
    // minúsculas antes caía en el cubo CUP.
    if (LocalDb.monedaDe(v) == 'USD') {
      usd += total;
    } else {
      cup += total;
    }
  }
  return (cup: cup, usd: usd);
}

class CuentasPorCobrarScreen extends StatefulWidget {
  /// 1.25 T74: dentro de «Por cobrar» va sin Scaffold
  /// propio ni su tarjeta de total (el héroe combinado
  /// lo pone la pantalla única); reporta sus totales
  /// con [onTotales].
  final bool incrustada;
  final ValueChanged<({double cup, double usd})>? onTotales;

  const CuentasPorCobrarScreen(
      {super.key, this.incrustada = false, this.onTotales});

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

/// Autoauditoría 1.22 #2 (D2-03): salda un fiado de forma
/// atómica y sin duplicar. Dentro de UNA transacción:
/// (1) re-verifica que NO exista ya una op viva
/// `saldar_fiado_suplemento` para la misma venta (la lista
/// filtra al cargar, pero entre la carga y el toque el espejo
/// pudo refrescarse o perderse la marca optimista: un doble
/// toque encolaba DOS cobros del mismo fiado y el segundo se
/// aplicaba contra una venta ya saldada); (2) encola la op;
/// (3) marca el espejo. Devuelve false si ya había un cobro
/// pendiente (nada escrito).
Future<bool> encolarSaldarFiado({
  required int ventaId,
  required String fecha,
  required String metodo,
  required double monto,
  required String moneda,
}) async {
  final db = LocalDb.instance;
  final conn = await db.db;
  return conn.transaction((txn) async {
    final vivas = await txn.query('ops_queue',
        columns: ['payload'],
        where: "tipo = 'saldar_fiado_suplemento' "
            "AND estado NOT IN ('aplicada', 'rechazada')");
    for (final o in vivas) {
      try {
        final p =
            jsonDecode(o['payload'] as String) as Map<String, dynamic>;
        if ((p['venta_id'] as num?)?.toInt() == ventaId) return false;
      } catch (_) {}
    }
    await db.queueOp(
      opUuid: const Uuid().v4(),
      tipo: 'saldar_fiado_suplemento',
      payload: payloadSaldarFiado(
        ventaId: ventaId,
        fecha: fecha,
        metodo: metodo,
        monto: monto,
        moneda: moneda,
      ),
      txn: txn,
    );
    await db.marcarFiadoSaldado(ventaId, fecha, txn: txn);
    return true;
  });
}

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

  bool _esFiadoPendiente(Map<String, dynamic> v) =>
      esFiadoPendienteVenta(v);

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
    } finally {
      if (mounted && _cargando) {
        setState(() => _cargando = false);
      }
    }
  }

  Future<void> _cargarDatos() async {
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
    widget.onTotales?.call(totalesFiados(fiados));
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
    // Yunque 1.34 (C4-3): se salda por el total REGISTRADO.
    final total = totalVentaRegistrado(v);
    final moneda = '${v['moneda'] ?? 'CUP'}';
    // Argón #9 (MEDIO): el cast directo v['id'] as int reventaba
    // con TypeError DESPUÉS de encolar la op si el id no era int.
    // Se valida antes de encolar.
    final ventaId = (v['id'] as num?)?.toInt();
    if (ventaId == null) {
      mostrarSnack(context, 'No se puede cobrar: venta sin identificador', significado: SignificadoChip.alerta);
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
          iconoTitulo: Icons.payments_rounded,
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
    // D2-03: op + marca optimista en una transacción y con
    // re-chequeo de duplicado dentro (ver encolarSaldarFiado).
    final encolado = await encolarSaldarFiado(
      ventaId: ventaId,
      fecha: fechaCobro,
      metodo: metodo,
      monto: total,
      moneda: moneda,
    );
    if (!encolado) {
      if (mounted) {
        mostrarSnack(context,
            'Este fiado ya tiene un cobro pendiente de sincronizar',
            significado: SignificadoChip.alerta);
        _cargar();
      }
      return;
    }
    if (mounted) {
      setState(() {
        _fiados.remove(v);
      });
      // 1.25 T74: el héroe combinado se entera al momento.
      widget.onTotales?.call(totalesFiados(_fiados));
      mostrarSnack(context, 'Fiado cobrado (se sincronizará)', significado: SignificadoChip.exito);
    }
    unawaited(SyncEngine.instance.push());
  }

  @override
  Widget build(BuildContext context) {
    // 1.25 T74: incrustada, solo la lista dentro de la
    // pestaña de «Por cobrar».
    if (widget.incrustada) return _cuerpo();
    return Scaffold(
      appBar: appBarIron(context, 'Fiados por cobrar'),
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
                Icons.account_balance_wallet_rounded),
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

  /// 1.25 T118 (F2-18): chip «hace N días» de un fiado;
  /// ámbar desde 15 días y rojo desde 30 (la lista ya ordena
  /// del más viejo al más nuevo: el chip dice la urgencia).
  Widget _chipAntiguedadFiado(String fechaIso) {
    if (fechaIso.length < 10) return const SizedBox.shrink();
    final f = DateTime.tryParse(fechaIso.substring(0, 10));
    if (f == null) return const SizedBox.shrink();
    final hoy = ahoraHabana();
    final dias = DateTime.utc(hoy.year, hoy.month, hoy.day)
        .difference(DateTime.utc(f.year, f.month, f.day))
        .inDays;
    if (dias <= 0) return const SizedBox.shrink();
    final color = dias >= 30
        ? AppColores.error
        : dias >= 15
            ? AppColores.alertaOscuro
            : AppColores.textoSecundario(context);
    return Padding(
      padding: const EdgeInsets.only(top: 3),
      child: Container(
        padding: const EdgeInsets.symmetric(
            horizontal: AppEspacio.sm, vertical: 2),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(AppRadio.sm),
        ),
        child: Text(
          'hace $dias día${dias == 1 ? '' : 's'}',
          style: AppTexto.minuscula
              .copyWith(color: color, fontWeight: FontWeight.w700),
        ),
      ),
    );
  }

  Widget _cuerpo() {
    if (_cargando) {
      return const EstadoCargando(texto: 'Cargando fiados por cobrar…');
    }
    if (_fiados.isEmpty) {
      // 1.25 T118 (F2-18): vacío del sistema (antes un texto
      // suelto centrado).
      return const EstadoVacio(
        icono: Icons.receipt_long_rounded,
        titulo: 'Sin fiados pendientes',
        subtitulo: 'Nadie debe suplementos ahora mismo.',
      );
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
        final moneda = '${v['moneda'] ?? 'CUP'}';
        final fecha = '${v['fecha'] ?? ''}';
        return Tarjeta(
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: IconoModuloBadge.naranja(
                Icons.person_outline_rounded),
            title: Text('$nombreProd × $cant',
                style: AppTexto.cuerpo
                    .copyWith(fontWeight: FontWeight.w600)),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(nombreCli, style: AppTexto.secundario),
                Text(fmtFecha(fecha), style: AppTexto.secundario),
                // F2-18: antigüedad del fiado con semáforo —
                // la fecha ya estaba y no se usaba.
                _chipAntiguedadFiado(fecha),
              ],
            ),
            isThreeLine: true,
            trailing: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                    '${totalVentaRegistrado(v).toStringAsFixed(2)} $moneda',
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
