/// v1.3.6 (ítem 1B): Arqueo de caja — liquidación del pendiente a entregar.
///
/// Solo dueño. El monto esperado se calcula SOLO sobre espejos confirmados
/// (invariante 2 de Argón: ignora ops_queue). Cada liquidación guarda
/// monto_esperado vs monto_entregado; si es parcial, el resto queda como
/// saldo de arrastre sin partir ops.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../auth.dart';
import '../negocio.dart';
import '../sync.dart';
import 'componentes.dart';
import 'diseno.dart';
import 'widgets.dart';

class ArqueoScreen extends StatefulWidget {
  const ArqueoScreen({super.key});

  @override
  State<ArqueoScreen> createState() => _ArqueoScreenState();
}

class _ArqueoScreenState extends State<ArqueoScreen> {
  bool _cargando = true;
  List<Map<String, dynamic>> _entrenadores = [];

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    setState(() => _cargando = true);
    try {
      final lista = await entrenadoresConPendiente();
      if (mounted) {
        setState(() {
          _entrenadores = lista;
          _cargando = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _cargando = false);
    }
  }

  Future<void> _sincronizar() async {
    await SyncEngine.instance.sincronizarScope('arqueo');
    await _cargar();
  }

  @override
  Widget build(BuildContext context) {
    if (!AuthService().isOwner) {
      return Scaffold(
        appBar: AppBar(title: const Text('Arqueo de caja')),
        body: const Center(
            child: Text('Solo el dueño puede ver el arqueo de caja.')),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('Arqueo de caja'),
        actions: [
          IconButton(
            tooltip: 'Sincronizar arqueo',
            icon: const Icon(Icons.sync),
            onPressed: _sincronizar,
          ),
        ],
      ),
      body: Column(
        children: [
          const SyncBanner(),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _cargar,
              child: _cargando
                  ? const Center(child: CircularProgressIndicator())
                  : _entrenadores.isEmpty
                      ? ListView(
                          children: [
                            Padding(
                              padding: const EdgeInsets.all(32),
                              child: Column(
                                children: [
                                  const Icon(Icons.check_circle_outline,
                                      size: 56, color: Colors.green),
                                  const SizedBox(height: 12),
                                  const Text('Nada pendiente. Todo cuadrado.',
                                      style: AppTexto.subtitulo),
                                  const SizedBox(height: 8),
                                  Text(
                                    'El esperado se calcula solo sobre datos '
                                    'confirmados por el servidor.',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                        color: AppColores.textoSecundario(
                                            context)),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.all(16),
                          itemCount: _entrenadores.length,
                          itemBuilder: (_, i) {
                            final e = _entrenadores[i];
                            final cup = (e['cup'] as num).toDouble();
                            final usd = (e['usd'] as num).toDouble();
                            return Padding(
                              padding:
                                  const EdgeInsets.only(bottom: AppEspacio.sm),
                              child: Tarjeta(
                                onTap: () async {
                                  await Navigator.of(context).push(
                                    MaterialPageRoute(
                                      builder: (_) => _DetalleArqueoScreen(
                                        telegramId: e['telegram_id'] as int,
                                        nombre: '${e['nombre']}',
                                      ),
                                    ),
                                  );
                                  _cargar();
                                },
                                child: Row(
                                  children: [
                                    const Icon(Icons.person,
                                        color: AppColores.naranja, size: 28),
                                    const SizedBox(width: AppEspacio.sm),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text('${e['nombre']}',
                                              style: AppTexto.subtitulo),
                                          if (cup > 0)
                                            Text(
                                                '${fmtMonto(cup)} CUP pendientes',
                                                style: const TextStyle(
                                                    fontWeight:
                                                        FontWeight.w600)),
                                          if (usd > 0)
                                            Text(
                                                '${fmtMonto(usd)} USD pendientes',
                                                style: const TextStyle(
                                                    fontWeight:
                                                        FontWeight.w600)),
                                        ],
                                      ),
                                    ),
                                    const Icon(Icons.chevron_right),
                                  ],
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

/// Detalle de un entrenador: esperado confirmado, historial y formulario
/// de liquidación.
class _DetalleArqueoScreen extends StatefulWidget {
  final int telegramId;
  final String nombre;

  const _DetalleArqueoScreen(
      {required this.telegramId, required this.nombre});

  @override
  State<_DetalleArqueoScreen> createState() => _DetalleArqueoScreenState();
}

class _DetalleArqueoScreenState extends State<_DetalleArqueoScreen> {
  bool _cargando = true;
  bool _liquidando = false;
  double _cup = 0;
  double _usd = 0;
  String _moneda = 'CUP';
  List<Map<String, dynamic>> _historial = [];
  final _entregadoCtrl = TextEditingController();
  final _notaCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  @override
  void dispose() {
    _entregadoCtrl.dispose();
    _notaCtrl.dispose();
    super.dispose();
  }

  double get _esperado => _moneda == 'USD' ? _usd : _cup;

  Future<void> _cargar() async {
    setState(() => _cargando = true);
    try {
      final pend = await pendienteArqueo(widget.telegramId);
      final hist = await liquidacionesDeEntrenador(widget.telegramId);
      if (mounted) {
        setState(() {
          _cup = pend.cup;
          _usd = pend.usd;
          _historial = hist;
          _cargando = false;
          if (_moneda == 'USD' && _usd <= 0) _moneda = 'CUP';
          _entregadoCtrl.text = _esperado > 0
              ? _esperado.toStringAsFixed(
                  _esperado == _esperado.roundToDouble() ? 0 : 2)
              : '';
        });
      }
    } catch (_) {
      if (mounted) setState(() => _cargando = false);
    }
  }

  Future<void> _liquidar() async {
    final entregado =
        double.tryParse(_entregadoCtrl.text.replaceAll(',', '.'));
    if (entregado == null || entregado < 0) {
      _aviso('Escribe un monto válido.');
      return;
    }
    final esperado = _esperado;
    if (entregado - esperado > 0.01) {
      _aviso('Lo entregado no puede superar lo esperado '
          '(${fmtMonto(esperado)} $_moneda).');
      return;
    }
    if (esperado <= 0) {
      _aviso('No hay pendiente confirmado en $_moneda.');
      return;
    }
    final opIds =
        await idsPendienteArqueo(widget.telegramId, moneda: _moneda);
    final totalIds = opIds.values.fold<int>(0, (s, l) => s + l.length);
    if (totalIds == 0) {
      _aviso('No hay operaciones confirmadas para liquidar.');
      return;
    }
    final parcial = entregado < esperado - 0.01;
    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Confirmar liquidación'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Entrenador: ${widget.nombre}'),
            const SizedBox(height: 8),
            Text('Esperado: ${fmtMonto(esperado)} $_moneda'),
            Text('Entregado: ${fmtMonto(entregado)} $_moneda'),
            if (parcial) ...[
              const SizedBox(height: 8),
              Text(
                'Parcial: quedan ${fmtMonto(esperado - entregado)} '
                '$_moneda como saldo de arrastre.',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ],
            const SizedBox(height: 8),
            Text('$totalIds operación(es) incluida(s).',
                style: TextStyle(
                    color: AppColores.textoSecundario(context),
                    fontSize: 12)),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Liquidar'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _liquidando = true);
    try {
      await crearLiquidacion(
        entrenadorTelegramId: widget.telegramId,
        entrenadorNombre: widget.nombre,
        montoEsperado: esperado,
        montoEntregado: entregado,
        opIds: opIds,
        moneda: _moneda,
        nota: _notaCtrl.text.trim().isEmpty
            ? null
            : _notaCtrl.text.trim(),
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(parcial
                  ? 'Liquidación parcial registrada. Arrastre: '
                      '${fmtMonto(esperado - entregado)} $_moneda.'
                  : 'Liquidación registrada. Se sincronizará en breve.')),
        );
        _notaCtrl.clear();
        await _cargar();
      }
    } catch (e) {
      _aviso('No se pudo liquidar: $e');
    } finally {
      if (mounted) setState(() => _liquidando = false);
    }
  }

  void _aviso(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Arqueo · ${widget.nombre}')),
      body: Column(
        children: [
          const SyncBanner(),
          Expanded(
            child: _cargando
                ? const Center(child: CircularProgressIndicator())
                : ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      // Selector de moneda (solo si hay USD).
                      if (_usd > 0)
                        Padding(
                          padding:
                              const EdgeInsets.only(bottom: AppEspacio.sm),
                          child: SegmentedButton<String>(
                            segments: const [
                              ButtonSegment(
                                  value: 'CUP', label: Text('CUP')),
                              ButtonSegment(
                                  value: 'USD', label: Text('USD')),
                            ],
                            selected: {_moneda},
                            onSelectionChanged: (s) {
                              setState(() {
                                _moneda = s.first;
                                _entregadoCtrl.text = _esperado > 0
                                    ? _esperado.toStringAsFixed(
                                        _esperado ==
                                                _esperado.roundToDouble()
                                            ? 0
                                            : 2)
                                    : '';
                              });
                            },
                          ),
                        ),
                      Tarjeta(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('Pendiente confirmado',
                                style: AppTexto.subtitulo),
                            const SizedBox(height: 4),
                            Text(
                              '${fmtMonto(_esperado)} $_moneda',
                              style: AppTexto.displayPequeno.copyWith(
                                  color: AppColores.naranja),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Calculado solo sobre datos confirmados por '
                              'el servidor (sin operaciones en cola).',
                              style: TextStyle(
                                  fontSize: 12,
                                  color: AppColores.textoSecundario(
                                      context)),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: AppEspacio.md),
                      const Text('Nueva liquidación', style: AppTexto.subtitulo),
                      const SizedBox(height: AppEspacio.sm),
                      TextField(
                        controller: _entregadoCtrl,
                        keyboardType:
                            const TextInputType.numberWithOptions(
                                decimal: true),
                        inputFormatters: [
                          FilteringTextInputFormatter.allow(
                              RegExp(r'[0-9.,]')),
                        ],
                        decoration: InputDecoration(
                          labelText: 'Monto entregado ($_moneda)',
                          border: const OutlineInputBorder(),
                          suffixText: _moneda,
                        ),
                      ),
                      const SizedBox(height: AppEspacio.sm),
                      TextField(
                        controller: _notaCtrl,
                        decoration: const InputDecoration(
                          labelText: 'Nota (opcional)',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: AppEspacio.md),
                      BotonPrimario(
                        texto: 'Liquidar',
                        icono: Icons.point_of_sale,
                        cargando: _liquidando,
                        onPressed: _liquidando ? null : _liquidar,
                      ),
                      const SizedBox(height: AppEspacio.lg),
                      const Text('Historial', style: AppTexto.subtitulo),
                      const SizedBox(height: AppEspacio.sm),
                      if (_historial.isEmpty)
                        Text('Sin liquidaciones registradas.',
                            style: TextStyle(
                                color:
                                    AppColores.textoSecundario(context))),
                      for (final h in _historial)
                        Padding(
                          padding: const EdgeInsets.only(
                              bottom: AppEspacio.sm),
                          child: Tarjeta(
                            child: Column(
                              crossAxisAlignment:
                                  CrossAxisAlignment.start,
                              children: [
                                Row(
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceBetween,
                                  children: [
                                    Text(
                                      '${fmtMonto(h['monto_entregado'])} '
                                      '${h['moneda'] ?? 'CUP'}',
                                      style: const TextStyle(
                                          fontWeight: FontWeight.w700),
                                    ),
                                    Container(
                                      padding:
                                          const EdgeInsets.symmetric(
                                              horizontal: 8, vertical: 2),
                                      decoration: BoxDecoration(
                                        color: (h['estado'] == 'parcial'
                                                ? AppColores.alerta
                                                : Colors.green)
                                            .withValues(alpha: 0.15),
                                        borderRadius:
                                            BorderRadius.circular(10),
                                      ),
                                      child: Text(
                                        h['estado'] == 'parcial'
                                            ? 'Parcial'
                                            : 'Liquidado',
                                        style: const TextStyle(
                                            fontSize: 11,
                                            fontWeight: FontWeight.w600),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  'Esperado: ${fmtMonto(h['monto_esperado'])}'
                                  '${(h['saldo_arrastre'] as num? ?? 0) > 0 ? ' · Arrastre: ${fmtMonto(h['saldo_arrastre'])}' : ''}',
                                  style: TextStyle(
                                      fontSize: 12,
                                      color: AppColores.textoSecundario(
                                          context)),
                                ),
                                Text(
                                  '${h['creada_en'] ?? ''} · por ${h['creada_por'] ?? ''}',
                                  style: TextStyle(
                                      fontSize: 12,
                                      color: AppColores.textoSecundario(
                                          context)),
                                ),
                                if ((h['nota'] as String?)?.isNotEmpty ==
                                    true)
                                  Text('${h['nota']}',
                                      style:
                                          const TextStyle(fontSize: 12)),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}
