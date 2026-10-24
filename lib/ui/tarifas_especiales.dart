/// Pantalla D1 (todas las tarifas) y modal D6 (tarifas especiales).
///
/// Bloque 2 NÚCLEO, 1.10.0, Argón AMARILLO ajustes 1 y 3.
///
/// - D1: precios estándar + especiales activas, en un solo sitio.
/// - D6: otorgar / editar / revocar. El formulario pre-carga el valor
///   que ya tenía el otro método (ajuste 1): lo que se ve es lo que
///   queda; vaciar un método lo deja en null para ese método.
/// - Multi-cliente (Administración): el selector es solo visual; al
///   guardar se crea UNA fila por cliente (ajuste 1). Si algún método
///   pasaría de tener valor a null para algún cliente, se pide
///   confirmación listando los afectados.
library;

import 'package:flutter/material.dart';

import '../auth.dart';
import '../localdb.dart';
import '../negocio.dart';
import '../tarifa_especial.dart';
import '../tiempo.dart';
import 'componentes.dart';
import 'diseno.dart';

/// D1: todas las tarifas en una pantalla (estándar + especiales).
class TarifasScreen extends StatefulWidget {
  const TarifasScreen({super.key});
  @override
  State<TarifasScreen> createState() => _TarifasScreenState();
}

class _TarifasScreenState extends State<TarifasScreen> {
  var _cargando = true;
  Map<String, double> _precios = {};
  List<Map<String, dynamic>> _especiales = [];
  Map<int, String> _nombres = {};

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    final precios = await preciosVigentes();
    final especiales = await tarifasActivas();
    final clientes = await LocalDb.instance.allMirror('clientes');
    final nombres = <int, String>{};
    for (final c in clientes) {
      final id = (c['id'] as num?)?.toInt();
      if (id != null) nombres[id] = '${c['nombre'] ?? 'Cliente $id'}';
    }
    if (!mounted) return;
    setState(() {
      _precios = precios;
      _especiales = especiales;
      _nombres = nombres;
      _cargando = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Tarifas')),
      body: _cargando
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _cargar,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  const Text('Precios estándar', style: AppTexto.titulo),
                  const SizedBox(height: 8),
                  _filaPrecio('Mensualidad en efectivo',
                      _precios['mensual'] ?? 2000),
                  _filaPrecio('Mensualidad por transferencia',
                      _precios['transfer'] ?? 2500),
                  _filaPrecio('Mensualidad menores',
                      _precios['menores'] ?? 1500),
                  _filaPrecio(
                      'Semana', _precios['semanal'] ?? 600),
                  _filaPrecio(
                      'Quincena', _precios['quincenal'] ?? 1200),
                  _filaPrecio(
                      'Pago diario', _precios['diario'] ?? 200),
                  const SizedBox(height: 8),
                  const Text(
                    'La Cuenta a la Casa es precio 0 y va por encima '
                    'de todo. Una tarifa especial vigente gana a '
                    'menores y a la Oferta; un método en vacío cae al '
                    'siguiente escalón, nunca directo al estándar.',
                    style: AppTexto.secundario,
                  ),
                  const SizedBox(height: 24),
                  Row(
                    children: [
                      const Expanded(
                          child: Text('Tarifas especiales activas',
                              style: AppTexto.titulo)),
                      if (AuthService().isOwner)
                        FilledButton.icon(
                          onPressed: () async {
                            await mostrarModalTarifaEspecial(context);
                            _cargar();
                          },
                          icon: const Icon(Icons.add, size: 18),
                          label: const Text('Nueva'),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  if (_especiales.isEmpty)
                    const Text('Ninguna tarifa especial activa.',
                        style: AppTexto.secundario),
                  for (final e in _especiales)
                    Card(
                      child: ListTile(
                        leading: const Icon(Icons.local_offer,
                            color: AppColores.naranja),
                        title: Text(_nombres[
                                (e['cliente_id'] as num?)?.toInt()] ??
                            'Cliente ${e['cliente_id']}'),
                        subtitle: Text(
                            '${e['nombre'] ?? ''} · ${e['periodo'] ?? 'mensual'}\n'
                            'Efectivo: ${_montoTexto((e['monto_efectivo'] as num?)?.toDouble())} · '
                            'Transferencia: ${_montoTexto((e['monto_transferencia'] as num?)?.toDouble())}'
                            '${(e['vigente_hasta'] as String?) != null ? '\nHasta: ${e['vigente_hasta']}' : ''}'),
                        isThreeLine: true,
                        onTap: AuthService().isOwner
                            ? () async {
                                await mostrarModalTarifaEspecial(
                                  context,
                                  clienteId:
                                      (e['cliente_id'] as num?)?.toInt(),
                                  clienteNombre: _nombres[
                                      (e['cliente_id'] as num?)?.toInt()],
                                );
                                _cargar();
                              }
                            : null,
                      ),
                    ),
                ],
              ),
            ),
    );
  }

  Widget _filaPrecio(String etiqueta, double monto) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Row(
          children: [
            Expanded(child: Text(etiqueta, style: AppTexto.cuerpo)),
            Text('${fmtMonto(monto)} CUP', style: AppTexto.cuerpo),
          ],
        ),
      );

  String _montoTexto(double? m) =>
      m == null ? 'sin especial' : '${fmtMonto(m)} CUP';
}

/// Modal D6: otorgar / editar / revocar una tarifa especial.
///
/// - Con [clienteId]: modo un cliente (desde la ficha). Pre-carga la
///   fila activa del periodo elegido (ambos métodos).
/// - Sin [clienteId]: modo multi (desde TarifasScreen). Primero se
///   eligen los clientes; al guardar, una fila por cliente.
Future<void> mostrarModalTarifaEspecial(
  BuildContext context, {
  int? clienteId,
  String? clienteNombre,
}) async {
  if (!AuthService().isOwner) return;
  if (clienteId == null) {
    final ids = await _elegirClientes(context);
    if (ids == null || ids.isEmpty || !context.mounted) return;
    await _formularioTarifa(context, clienteIds: ids);
    return;
  }
  await _formularioTarifa(context,
      clienteIds: [clienteId], clienteNombre: clienteNombre);
}

Future<List<int>?> _elegirClientes(BuildContext context) async {
  final todos = await listaClientes('');
  final filtro = TextEditingController();
  final elegidos = <int>{};
  return showDialog<List<int>>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setS) {
        final q = filtro.text.trim().toLowerCase();
        final visibles = q.isEmpty
            ? todos
            : todos
                .where((c) =>
                    '${c['nombre'] ?? ''}'.toLowerCase().contains(q))
                .toList();
        return DialogoApp(
          titulo: 'Elegir clientes',
          iconoTitulo: Icons.group,
          contenido: SizedBox(
            width: double.maxFinite,
            height: 420,
            child: Column(
              children: [
                TextField(
                  controller: filtro,
                  decoration: const InputDecoration(
                      hintText: 'Filtrar por nombre',
                      border: OutlineInputBorder()),
                  onChanged: (_) => setS(() {}),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: ListView(
                    children: [
                      for (final c in visibles)
                        CheckboxListTile(
                          dense: true,
                          title: Text('${c['nombre'] ?? ''}'),
                          value: elegidos
                              .contains((c['id'] as num?)?.toInt()),
                          onChanged: (v) => setS(() {
                            final id = (c['id'] as num?)?.toInt();
                            if (id == null) return;
                            if (v == true) {
                              elegidos.add(id);
                            } else {
                              elegidos.remove(id);
                            }
                          }),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          acciones: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, null),
                child: const Text('Cancelar')),
            FilledButton(
                onPressed: elegidos.isEmpty
                    ? null
                    : () => Navigator.pop(ctx, elegidos.toList()),
                child: Text('Continuar (${elegidos.length})')),
          ],
        );
      },
    ),
  );
}

Future<void> _formularioTarifa(
  BuildContext context, {
  required List<int> clienteIds,
  String? clienteNombre,
}) async {
  final esMulti = clienteIds.length > 1;
  final nombreCtrl = TextEditingController();
  final efectivoCtrl = TextEditingController();
  final transferCtrl = TextEditingController();
  final desdeCtrl = TextEditingController(text: hoyHabanaIso());
  final hastaCtrl = TextEditingController();
  final motivoCtrl = TextEditingController();
  var periodo = 'mensual';
  Map<String, dynamic>? activaPrevia;

  Future<void> cargarPrevia() async {
    // Solo en modo un cliente: pre-carga AMBOS métodos de la fila
    // activa de ese periodo (ajuste 1).
    if (esMulti) return;
    final previa =
        await tarifaActivaPara(clienteIds.first, periodo);
    activaPrevia = previa;
    if (previa != null) {
      nombreCtrl.text = '${previa['nombre'] ?? ''}';
      final ef = (previa['monto_efectivo'] as num?)?.toDouble();
      final tr = (previa['monto_transferencia'] as num?)?.toDouble();
      efectivoCtrl.text = ef == null ? '' : _num(ef);
      transferCtrl.text = tr == null ? '' : _num(tr);
      desdeCtrl.text = '${previa['vigente_desde'] ?? hoyHabanaIso()}';
      hastaCtrl.text = '${previa['vigente_hasta'] ?? ''}';
      motivoCtrl.text = '${previa['motivo'] ?? ''}';
    }
  }

  await cargarPrevia();
  if (!context.mounted) return;

  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setS) => DialogoApp(
        titulo: activaPrevia != null
            ? 'Editar tarifa especial'
            : 'Nueva tarifa especial',
        iconoTitulo: Icons.local_offer,
        contenido: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (esMulti)
                const Text(
                  'Se creará UNA fila por cliente. Lo que dejes vacío '
                  'quedará sin especial para ese método en todos los '
                  'clientes elegidos.',
                  style: AppTexto.secundario,
                ),
              if (!esMulti && clienteNombre != null)
                Text('Cliente: $clienteNombre',
                    style: AppTexto.cuerpo),
              const SizedBox(height: 8),
              TextField(
                  controller: nombreCtrl,
                  decoration: const InputDecoration(
                      labelText: 'Nombre (ej: Kevin 1000)',
                      border: OutlineInputBorder())),
              const SizedBox(height: 8),
              TextField(
                  controller: efectivoCtrl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                      labelText: 'Monto en efectivo (vacío = sin especial)',
                      border: OutlineInputBorder())),
              const SizedBox(height: 8),
              TextField(
                  controller: transferCtrl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                      labelText:
                          'Monto por transferencia (vacío = sin especial)',
                      border: OutlineInputBorder())),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                value: periodo,
                decoration: const InputDecoration(
                    labelText: 'Periodo',
                    border: OutlineInputBorder()),
                items: const [
                  DropdownMenuItem(
                      value: 'mensual', child: Text('Mensual')),
                  DropdownMenuItem(
                      value: 'semanal', child: Text('Semanal')),
                  DropdownMenuItem(
                      value: 'quincenal', child: Text('Quincenal')),
                ],
                onChanged: (v) async {
                  if (v == null) return;
                  setS(() => periodo = v);
                  await cargarPrevia();
                  setS(() {});
                },
              ),
              const SizedBox(height: 8),
              TextField(
                  controller: desdeCtrl,
                  decoration: const InputDecoration(
                      labelText: 'Vigente desde (AAAA-MM-DD)',
                      border: OutlineInputBorder())),
              const SizedBox(height: 8),
              TextField(
                  controller: hastaCtrl,
                  decoration: const InputDecoration(
                      labelText: 'Vigente hasta (vacío = sin fin)',
                      border: OutlineInputBorder())),
              const SizedBox(height: 8),
              TextField(
                  controller: motivoCtrl,
                  decoration: const InputDecoration(
                      labelText: 'Motivo (obligatorio, interno: '
                          'nunca sale en mensajes)',
                      border: OutlineInputBorder())),
            ],
          ),
        ),
        acciones: [
          if (activaPrevia != null && !esMulti)
            TextButton(
                onPressed: () async {
                  final motivo = await _pedirMotivo(context);
                  if (motivo == null || !context.mounted) return;
                  await revocarTarifaEspecial(
                      id: '${activaPrevia!['id']}', motivo: motivo);
                  // Cerrar SIN guardar: false hace que el código de
                  // abajo retorne sin otorgar nada nuevo.
                  if (ctx.mounted) Navigator.pop(ctx, false);
                },
                child: const Text('Revocar',
                    style: TextStyle(color: Colors.red))),
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Guardar')),
        ],
      ),
    ),
  );
  if (ok != true || !context.mounted) return;

  // Validación (no bloquea con diálogos crípticos: un aviso claro).
  String? error;
  final ef = _parseMonto(efectivoCtrl.text);
  final tr = _parseMonto(transferCtrl.text);
  if (nombreCtrl.text.trim().isEmpty) {
    error = 'Falta el nombre de la tarifa.';
  } else if (ef == null && tr == null) {
    error = 'Pon al menos un monto (efectivo o transferencia).';
  } else if ((ef != null && ef <= 0) || (tr != null && tr <= 0)) {
    error = 'Los montos deben ser mayores que 0.';
  } else if (motivoCtrl.text.trim().isEmpty) {
    error = 'Falta el motivo (es obligatorio y queda en el historial).';
  } else if (DateTime.tryParse(desdeCtrl.text.trim()) == null) {
    error = 'Vigente desde no es una fecha válida (AAAA-MM-DD).';
  } else if (hastaCtrl.text.trim().isNotEmpty &&
      DateTime.tryParse(hastaCtrl.text.trim()) == null) {
    error = 'Vigente hasta no es una fecha válida (AAAA-MM-DD).';
  } else if (hastaCtrl.text.trim().isNotEmpty &&
      hastaCtrl.text.trim().compareTo(desdeCtrl.text.trim()) < 0) {
    error = 'Vigente hasta no puede ser antes que vigente desde.';
  }
  if (error != null) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(error)));
    return;
  }

  // Multi: si algún método pasaría de tener valor a null para algún
  // cliente, confirmar listando los afectados (ajuste 1).
  if (esMulti) {
    final afectados = <String>[];
    for (final cid in clienteIds) {
      final prev = await tarifaActivaPara(cid, periodo);
      if (prev == null) continue;
      if (ef == null && prev['monto_efectivo'] != null) {
        afectados.add('Cliente $cid: efectivo quedará sin especial');
      }
      if (tr == null && prev['monto_transferencia'] != null) {
        afectados
            .add('Cliente $cid: transferencia quedará sin especial');
      }
    }
    if (afectados.isNotEmpty && context.mounted) {
      final conf = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('¿Quitar esas especiales?'),
          content: Text(afectados.join('\n')),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancelar')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Sí, guardar así')),
          ],
        ),
      );
      if (conf != true) return;
    }
  }

  await otorgarTarifaEspecialMulti(
    clienteIds: clienteIds,
    nombre: nombreCtrl.text.trim(),
    montoEfectivo: ef,
    montoTransferencia: tr,
    periodo: periodo,
    vigenteDesde: desdeCtrl.text.trim(),
    vigenteHasta:
        hastaCtrl.text.trim().isEmpty ? null : hastaCtrl.text.trim(),
    motivo: motivoCtrl.text.trim(),
    otorgadoPor: AuthService().telegramId,
  );
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Tarifa especial guardada')));
}

Future<String?> _pedirMotivo(BuildContext context) async {
  final ctrl = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (ctx) => DialogoApp(
      titulo: 'Motivo de la revocación',
      iconoTitulo: Icons.cancel,
      contenido: TextField(
          controller: ctrl,
          decoration: const InputDecoration(
              hintText: 'Ej: terminó el pacto',
              border: OutlineInputBorder())),
      acciones: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, null),
            child: const Text('Cancelar')),
        FilledButton(
            onPressed: () => Navigator.pop(
                ctx, ctrl.text.trim().isEmpty ? null : ctrl.text.trim()),
            child: const Text('Revocar')),
      ],
    ),
  );
}

double? _parseMonto(String raw) {
  final t = raw.trim().replaceAll(',', '.');
  if (t.isEmpty) return null;
  return double.tryParse(t);
}

String _num(double v) =>
    v == v.roundToDouble() ? '${v.toInt()}' : '$v';
