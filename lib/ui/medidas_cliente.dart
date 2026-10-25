/// v1.13.0 (Bloque 4, D4): sección «Medidas» de la ficha del cliente.
///
/// Filas INMUTABLES (nunca se editan: una corrección es una fila
/// nueva). El registro viaja por la op `registrar_medicion_cliente`
/// (CHECK 80, otra vía) y baja por el espejo `cliente_mediciones`.
/// La lectura combina espejo + ops pendientes del propio teléfono.
/// Gate: permiso `can_record_measurements` (el dueño siempre puede).
/// Si el permiso se revoca con la op en cola, el servidor la rechaza
/// de forma NO bloqueante (nunca atasca la cola).
library;

import 'package:flutter/material.dart';

import '../auth.dart';
import '../mediciones_cliente.dart';
import '../permisos_entrenador.dart';
import 'componentes.dart';
import 'diseno.dart';

class TarjetaMedidas extends StatefulWidget {
  final int clienteId;
  const TarjetaMedidas({super.key, required this.clienteId});

  @override
  State<TarjetaMedidas> createState() => _TarjetaMedidasState();
}

class _TarjetaMedidasState extends State<TarjetaMedidas> {
  List<Map<String, dynamic>> _medidas = [];
  bool _cargando = true;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    final m = await medicionesClienteLocal(widget.clienteId);
    if (mounted) {
      setState(() {
        _medidas = m;
        _cargando = false;
      });
    }
  }

  bool get _puedeRegistrar =>
      AuthService().isOwner ||
      PermisosEntrenador().canRecordMeasurements;

  Future<void> _registrar() async {
    final ctrls = <String, TextEditingController>{
      for (final k in kMetricasMedicion.keys) k: TextEditingController(),
    };
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => DialogoApp(
        titulo: 'Registrar medida',
        iconoTitulo: Icons.straighten,
        contenido: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Escribe al menos una medida. Las filas no se editan: '
              'si te equivocas, registra otra fila corregida.',
              style: AppTexto.secundario,
            ),
            const SizedBox(height: 8),
            for (final e in kMetricasMedicion.entries)
              TextField(
                controller: ctrls[e.key],
                keyboardType: const TextInputType.numberWithOptions(
                    decimal: true),
                decoration: InputDecoration(
                    labelText:
                        '${e.key.replaceAll('_', ' ')} (${e.value.unidad})'),
              ),
          ],
        ),
        acciones: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Registrar'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final medidas = <String, double>{};
    for (final e in ctrls.entries) {
      final txt = e.value.text.trim().replaceAll(',', '.');
      if (txt.isEmpty) continue;
      final v = double.tryParse(txt);
      if (v != null) medidas[e.key] = v;
    }
    for (final c in ctrls.values) {
      c.dispose();
    }
    try {
      await registrarMedicionCliente(
          clienteId: widget.clienteId, medidas: medidas);
      await _cargar();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Medida registrada.')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
                e.toString().replaceFirst('Exception: ', ''))));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Tarjeta(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text('Medidas', style: AppTexto.titulo),
              ),
              if (_puedeRegistrar)
                TextButton.icon(
                  onPressed: _registrar,
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Registrar medida'),
                ),
            ],
          ),
          if (_cargando)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else if (_medidas.isEmpty)
            const Text('Sin medidas registradas todavía.',
                style: AppTexto.secundario)
          else
            for (final m in _medidas) ...[
              const Divider(height: 16),
              Row(
                children: [
                  Expanded(
                    child: Text('${m['fecha_medicion']}',
                        style: AppTexto.cuerpo.copyWith(
                            fontWeight: FontWeight.w600)),
                  ),
                  if (m['espejado'] != true)
                    const Text('por sincronizar',
                        style: AppTexto.secundario),
                ],
              ),
              const SizedBox(height: 2),
              Text(
                (m['medidas'] as Map<String, dynamic>).entries.map((e) {
                  final spec = kMetricasMedicion[e.key];
                  final unidad = spec?.unidad ?? '';
                  return '${e.key.replaceAll('_', ' ')}: ${e.value} $unidad';
                }).join(' · '),
                style: AppTexto.cuerpo,
              ),
            ],
        ],
      ),
    );
  }
}
