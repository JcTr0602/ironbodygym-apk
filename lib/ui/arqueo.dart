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
import '../diferencias_caja.dart';
import '../negocio.dart';
import '../sync.dart';
import 'componentes.dart';
import 'diferencias_caja.dart';
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
  // T5 (1.20): expedientes de diferencia abiertos (badge de
  // la entrada a la bandeja).
  int _difAbiertas = 0;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    setState(() => _cargando = true);
    try {
      final lista = await entrenadoresConPendiente();
      var difAbiertas = _difAbiertas;
      try {
        difAbiertas =
            await DiferenciasCajaService.instance.conteoAbiertas();
      } catch (_) {}
      if (mounted) {
        setState(() {
          _entrenadores = lista;
          _difAbiertas = difAbiertas;
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
            icon: const Icon(Icons.sync_rounded),
            onPressed: _sincronizar,
          ),
        ],
      ),
      body: Column(
        children: [
          const SyncBanner(),
          // T5 (1.20): entrada a la bandeja de diferencias
          // de caja, con el conteo de expedientes abiertos.
          Padding(
            padding: const EdgeInsets.fromLTRB(AppEspacio.lg,
                AppEspacio.sm, AppEspacio.lg, 0),
            child: Tarjeta(
              onTap: () async {
                await Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const DiferenciasCajaScreen(),
                  ),
                );
                _cargar();
              },
              child: Row(
                children: [
                  Icon(Icons.folder_open_rounded,
                      color: AppColores.textoSecundario(context),
                      size: 28),
                  const SizedBox(width: AppEspacio.sm),
                  const Expanded(
                    child: Text('Diferencias de caja',
                        style: AppTexto.subtitulo),
                  ),
                  if (_difAbiertas > 0) ...[
                    ContadorBadge(numero: _difAbiertas),
                    const SizedBox(width: AppEspacio.sm),
                  ],
                  const Icon(Icons.chevron_right_rounded),
                ],
              ),
            ),
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _cargar,
              child: _cargando
                  ? const EstadoCargando(texto: 'Cargando arqueo…')
                  : _entrenadores.isEmpty
                      ? ListView(
                          children: [
                            Padding(
                              padding: const EdgeInsets.all(32),
                              child: Column(
                                children: [
                                  const Icon(Icons.check_circle_outline_rounded,
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
                                    Icon(Icons.person_rounded,
                                        color: AppColores.textoSecundario(context), size: 28),
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
                                    const Icon(Icons.chevron_right_rounded),
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
  // T5 (1.20): expedientes por liquidación (chip o botón
  // «Abrir expediente» en el historial).
  Map<String, Map<String, dynamic>> _expedientes = {};
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
      var exps = _expedientes;
      try {
        exps = await DiferenciasCajaService.instance
            .porLiquidacion();
      } catch (_) {}
      if (mounted) {
        setState(() {
          _cup = pend.cup;
          _usd = pend.usd;
          _historial = hist;
          _expedientes = exps;
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
    // Autoauditoría 1.22 #2 (clase N-2 fuera de nómina): NaN no
    // es < 0 ni supera lo esperado (toda comparación con NaN es
    // falsa) y se colaba como monto de liquidación válido.
    if (entregado == null || !entregado.isFinite || entregado < 0) {
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
    // 1.15-turnos (#8): el arrastre puro SÍ se puede liquidar: el
    // servidor permite op_ids vacío cuando hay arrastre pendiente.
    // Antes esta guarda atrapaba ese caso (esperado > 0 sin ops
    // nuevas). El servidor sigue siendo el backstop (rechaza el
    // vacío sin arrastre y con esperado > 0.01).
    final parcial = entregado < esperado - 0.01;
    if (!mounted) return;
    // T5 (1.20): la marca de expediente solo tiene sentido
    // con diferencia; el servidor la ignora sin diferencia.
    var abrirExp = false;
    final expCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setStateDialogo) => AlertDialog(
        title: const Text('Confirmar liquidación'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Entrenador: ${widget.nombre}'),
            const SizedBox(height: 8),
            Text('Esperado: ${fmtMonto(esperado)} $_moneda',
                style: AppTexto.secundario),
            Text('Entregado: ${fmtMonto(entregado)} $_moneda',
                style: AppTexto.cuerpo.copyWith(
                    fontWeight: FontWeight.w600,
                    fontFeatures: const [
                      FontFeature.tabularFigures()
                    ])),
            // C3 (estéticas 1.19): comparación visual en vez de
            // dos textos planos — barra de cuánto se entregó y
            // diferencia destacada (verde si cuadra, rojo si
            // falta; lo parcial queda como arrastre).
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: LinearProgressIndicator(
                value: esperado > 0
                    ? (entregado / esperado).clamp(0.0, 1.0)
                    : 0,
                minHeight: 8,
                backgroundColor:
                    AppColores.borde(context).withValues(alpha: 0.3),
                valueColor: AlwaysStoppedAnimation<Color>(
                    parcial ? AppColores.alerta : AppColores.exito),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              parcial
                  ? 'Faltan ${fmtMonto(esperado - entregado)} '
                      '$_moneda · quedan como saldo de arrastre.'
                  : 'Cuadra exacto.',
              style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: parcial
                      ? AppColores.error
                      : AppColores.exito),
            ),
            const SizedBox(height: 8),
            Text('$totalIds operación(es) incluida(s).',
                style: AppTexto.metadato.copyWith(color: AppColores.textoSecundario(context))),
            // T5 (1.20): abrir el expediente AQUÍ, en la
            // misma op, solo si la diferencia no es el
            // arrastre normal.
            if (parcial) ...[
              const SizedBox(height: AppEspacio.sm),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: abrirExp,
                onChanged: (v) =>
                    setStateDialogo(() => abrirExp = v ?? false),
                title: const Text(
                    'Abrir expediente por esta diferencia',
                    style: AppTexto.cuerpo),
                subtitle: const Text(
                    'Solo si NO es el arrastre normal: queda '
                    'registrada con causa y resolución.',
                    style: AppTexto.metadato),
              ),
              if (abrirExp)
                TextField(
                  controller: expCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Explicación (opcional)',
                    border: OutlineInputBorder(),
                  ),
                  maxLines: 2,
                ),
            ],
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
      ),
    );
    final quiereExpediente = ok == true && abrirExp;
    final explicacionExpediente = expCtrl.text;
    expCtrl.dispose();
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
        abrirExpediente: quiereExpediente,
        explicacionExpediente: explicacionExpediente,
      );
      if (mounted) {
        mostrarSnack(context, parcial
                  ? 'Liquidación parcial registrada. Arrastre: '
                      '${fmtMonto(esperado - entregado)} $_moneda.'
                  : 'Liquidación registrada. Se sincronizará en breve.', significado: SignificadoChip.exito);
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
    mostrarSnack(context, msg);
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
                ? const EstadoCargando(texto: 'Cargando arqueo…')
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
                              style: AppTexto.metadato.copyWith(color: AppColores.textoSecundario(
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
                        icono: Icons.point_of_sale_rounded,
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
                                            BorderRadius.circular(12),
                                      ),
                                      child: Text(
                                        h['estado'] == 'parcial'
                                            ? 'Parcial'
                                            : 'Liquidado',
                                        style: AppTexto.metadato.copyWith(fontWeight: FontWeight.w600),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  'Esperado: ${fmtMonto(h['monto_esperado'])}'
                                  '${(h['saldo_arrastre'] as num? ?? 0) > 0 ? ' · Arrastre: ${fmtMonto(h['saldo_arrastre'])}' : ''}',
                                  style: AppTexto.metadato.copyWith(color: AppColores.textoSecundario(
                                          context)),
                                ),
                                Text(
                                  '${h['creada_en'] ?? ''} · por ${h['creada_por'] ?? ''}',
                                  style: AppTexto.metadato.copyWith(color: AppColores.textoSecundario(
                                          context)),
                                ),
                                if ((h['nota'] as String?)?.isNotEmpty ==
                                    true)
                                  Text('${h['nota']}',
                                      style:
                                          AppTexto.metadato),
                                // T5 (1.20): el expediente de
                                // esta liquidación, o el botón
                                // para abrirlo si faltó dinero.
                                if (_expedientes['${h['id']}'] !=
                                    null) ...[
                                  const SizedBox(
                                      height: AppEspacio.sm),
                                  chipExpedienteDiferencia(
                                      _expedientes['${h['id']}']!),
                                ] else if (diferenciaDeLiquidacion(
                                        h) >
                                    0.01)
                                  Align(
                                    alignment: Alignment.centerRight,
                                    child: TextButton.icon(
                                      icon: const Icon(
                                          Icons.folder_open_rounded,
                                          size: 18),
                                      label: const Text(
                                          'Abrir expediente'),
                                      onPressed: () async {
                                        await DiferenciasCajaService
                                            .instance
                                            .abrir(
                                                liquidacionId:
                                                    '${h['id']}');
                                        if (!context.mounted) return;
                                        mostrarSnack(context,
                                            'Expediente abierto '
                                            '(se sincronizará)',
                                            significado:
                                                SignificadoChip.exito);
                                        _cargar();
                                      },
                                    ),
                                  ),
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
