/// Cuentas por cobrar — fiados de suplementos pendientes (v1.3.7, Fase B §6.2).
///
/// Lista las ventas con `es_fiado=1` del espejo, con total por cobrar.
/// Al cobrar un fiado se encola la op `saldar_fiado_suplemento` (el
/// servidor lo marca como saldado; el pull lo saca de la lista).
/// Regla de negocio: el fiado NO suma al "Total cobrado" de actividad
/// hasta que se salda.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../auth.dart';
import '../localdb.dart';
import '../sync.dart';
import '../tiempo.dart';
import 'componentes.dart';
import 'diseno.dart';
import 'widgets.dart';

class CuentasPorCobrarScreen extends StatefulWidget {
  const CuentasPorCobrarScreen({super.key});

  @override
  State<CuentasPorCobrarScreen> createState() =>
      _CuentasPorCobrarScreenState();
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

  double _total() {
    var t = 0.0;
    for (final v in _fiados) {
      final cant = (v['cantidad'] as num?)?.toInt() ?? 0;
      final precio = (v['precio'] as num?)?.toDouble() ?? 0;
      t += cant * precio;
    }
    return t;
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

    final ok = await DialogoApp.confirmar(
      context,
      titulo: 'Cobrar fiado',
      icono: Icons.payments_outlined,
      mensaje: '$nombreProd × $cant\n'
          'Cliente: $nombreCli\n'
          'Total a cobrar: ${total.toStringAsFixed(2)} USD\n\n'
          'Se registrará como cobro normal y se saldará la deuda.',
      aceptar: 'Cobrar',
    );
    if (!ok) return;
    await LocalDb.instance.queueOp(
      opUuid: const Uuid().v4(),
      tipo: 'saldar_fiado_suplemento',
      payload: {
        'venta_id': v['id'],
        'fecha': hoyHabanaIso(),
      },
    );
    // Optimista: lo saca de la lista ya (el pull lo confirma).
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
      appBar: AppBar(title: const Text('Cuentas por cobrar')),
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
                      'Total por cobrar: ${_total().toStringAsFixed(2)} USD',
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
      return const Center(child: CircularProgressIndicator());
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
                    '${(cant * precio).toStringAsFixed(2)} USD',
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
