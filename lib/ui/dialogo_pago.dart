/// Diálogo unificado de pago (ficha del cliente y Agregar Pago).
///
/// Períodos: semana, quincena, meses y personalizado (días + monto
/// manuales). Siempre pide confirmación con resumen antes de registrar.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../localdb.dart';
import '../negocio.dart';

/// Selección de período hecha en el diálogo.
class PeriodoSel {
  final String periodo; // semanal | quincenal | mensual | personalizado
  final int meses;
  final int dias; // solo personalizado
  final double monto; // calculado o manual
  const PeriodoSel(
      {required this.periodo,
      this.meses = 1,
      this.dias = 0,
      required this.monto});
}

int _diasDe(PeriodoSel s) {
  switch (s.periodo) {
    case 'semanal':
      return 7;
    case 'quincenal':
      return 15;
    case 'personalizado':
      return s.dias;
    default:
      return 30 * s.meses;
  }
}

String _etiquetaPeriodo(PeriodoSel s) {
  switch (s.periodo) {
    case 'semanal':
      return 'Semana';
    case 'quincenal':
      return 'Quincena';
    case 'personalizado':
      return '${s.dias} días (personalizado)';
    default:
      return '${s.meses} mes${s.meses == 1 ? '' : 'es'}';
  }
}

/// Muestra el diálogo de pago para [cliente].
/// Devuelve el payload listo para encolar, o null si se canceló.
Future<Map<String, dynamic>?> pagoDialogo(
    BuildContext context, Map<String, dynamic> cliente) async {
  final aj = await LocalDb.instance.getAjustes();
  final mensual = (aj['mensualidad'] as num?)?.toDouble() ?? 2000;
  final transfer = (aj['transferencia'] as num?)?.toDouble() ?? 2500;
  final semanal = (aj['pago_semanal'] as num?)?.toDouble() ?? 600;
  final quincenal = (aj['pago_quincenal'] as num?)?.toDouble() ?? 1200;
  if (!context.mounted) return null;

  String periodo = 'mensual';
  int meses = 1;
  String metodo = 'efectivo';
  final diasCtrl = TextEditingController();
  final montoCtrl = TextEditingController();

  PeriodoSel actual() {
    double monto;
    int dias = 0;
    if (periodo == 'semanal') {
      monto = semanal;
    } else if (periodo == 'quincenal') {
      monto = quincenal;
    } else if (periodo == 'personalizado') {
      dias = int.tryParse(diasCtrl.text.trim()) ?? 0;
      monto = double.tryParse(
              montoCtrl.text.trim().replaceAll(',', '.')) ??
          0;
    } else {
      monto = (metodo == 'efectivo' ? mensual : transfer) * meses;
    }
    return PeriodoSel(
        periodo: periodo, meses: meses, dias: dias, monto: monto);
  }

  bool valido(PeriodoSel s) {
    if (s.periodo == 'personalizado') return s.dias > 0 && s.monto > 0;
    return true;
  }

  // Paso 1: período y método.
  final paso1 = await showDialog<PeriodoSel>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setS) {
        final s = actual();
        final nuevo = previewHastaDias(
            cliente['pagado_hasta'] as String?, _diasDe(s));
        return AlertDialog(
          title: Text('💰 Pago — ${cliente['nombre']}'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                    'Vence: ${fmtFecha(cliente['pagado_hasta'] as String?)}'),
                const SizedBox(height: 8),
                const Text('Período:'),
                DropdownButton<String>(
                  value: periodo == 'mensual' ? 'mensual:$meses' : periodo,
                  isExpanded: true,
                  items: [
                    DropdownMenuItem(
                        value: 'semanal',
                        child: Text(
                            'Semana (${fmtMonto(semanal)} CUP)')),
                    DropdownMenuItem(
                        value: 'quincenal',
                        child: Text(
                            'Quincena (${fmtMonto(quincenal)} CUP)')),
                    for (final m in [1, 2, 3, 6, 12])
                      DropdownMenuItem(
                          value: 'mensual:$m',
                          child: Text('$m mes${m == 1 ? '' : 'es'}')),
                    const DropdownMenuItem(
                        value: 'personalizado',
                        child: Text('Personalizado…')),
                  ],
                  onChanged: (v) => setS(() {
                    if (v == 'semanal' ||
                        v == 'quincenal' ||
                        v == 'personalizado') {
                      periodo = v!;
                    } else {
                      periodo = 'mensual';
                      meses = int.parse(v!.split(':')[1]);
                    }
                  }),
                ),
                if (periodo == 'personalizado') ...[
                  const SizedBox(height: 8),
                  TextField(
                    controller: diasCtrl,
                    keyboardType: TextInputType.number,
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly
                    ],
                    decoration: const InputDecoration(
                        labelText: 'Días',
                        border: OutlineInputBorder()),
                    onChanged: (_) => setS(() {}),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: montoCtrl,
                    keyboardType:
                        const TextInputType.numberWithOptions(
                            decimal: true),
                    decoration: const InputDecoration(
                        labelText: 'Monto (CUP)',
                        border: OutlineInputBorder()),
                    onChanged: (_) => setS(() {}),
                  ),
                ],
                const SizedBox(height: 8),
                const Text('Método:'),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    ChoiceChip(
                        label: const Text('💵 Efectivo'),
                        selected: metodo == 'efectivo',
                        onSelected: (_) =>
                            setS(() => metodo = 'efectivo')),
                    const SizedBox(width: 8),
                    ChoiceChip(
                        label: const Text('📱 Transfer.'),
                        selected: metodo == 'transferencia',
                        onSelected: (_) =>
                            setS(() => metodo = 'transferencia')),
                  ],
                ),
                const SizedBox(height: 12),
                Text('Período: ${_etiquetaPeriodo(s)}'),
                Text('Monto: ${fmtMonto(s.monto)} CUP',
                    style:
                        const TextStyle(fontWeight: FontWeight.bold)),
                Text('Nuevo vencimiento: ${fmtFecha(nuevo)}',
                    style:
                        const TextStyle(fontWeight: FontWeight.bold)),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancelar')),
            ElevatedButton(
                onPressed:
                    valido(s) ? () => Navigator.pop(ctx, s) : null,
                child: const Text('Continuar')),
          ],
        );
      },
    ),
  );
  if (paso1 == null || !context.mounted) return null;

  // Paso 2: confirmación con resumen.
  final s = paso1;
  final nuevo =
      previewHastaDias(cliente['pagado_hasta'] as String?, _diasDe(s));
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Confirmar pago'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Cliente: ${cliente['nombre']}'),
          Text('Período: ${_etiquetaPeriodo(s)}'),
          Text('Método: ${metodo == 'efectivo' ? '💵 Efectivo' : '📱 Transferencia'}'),
          Text('Monto: ${fmtMonto(s.monto)} CUP',
              style: const TextStyle(fontWeight: FontWeight.bold)),
          Text('Nuevo vencimiento: ${fmtFecha(nuevo)}',
              style: const TextStyle(fontWeight: FontWeight.bold)),
        ],
      ),
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
  if (ok != true) return null;

  return {
    'cliente_id': (cliente['id'] as int?) ?? 0,
    'periodo': s.periodo,
    'meses': s.meses,
    if (s.periodo == 'personalizado') 'dias': s.dias,
    if (s.periodo == 'personalizado') 'monto': s.monto,
    'metodo': metodo,
    'fecha': DateTime.now().toIso8601String().substring(0, 10),
  };
}
