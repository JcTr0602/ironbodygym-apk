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
  DateTime fechaPago = DateTime.now(); // v1.1: permite elegir fecha del pago

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
        final fpIso = '${fechaPago.year.toString().padLeft(4, '0')}-'
            '${fechaPago.month.toString().padLeft(2, '0')}-'
            '${fechaPago.day.toString().padLeft(2, '0')}';
        final nuevo = previewHastaDias(
            cliente['pagado_hasta'] as String?, _diasDe(s),
            fechaPago: fpIso);
        return AlertDialog(
          title: Text('💰 Pago — ${cliente['nombre']}'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                    'Vence: ${fmtFecha(cliente['pagado_hasta'] as String?)}'),
                // v1.0.14: aviso claro si paga por adelantado
                Builder(builder: (_) {
                  final ph =
                      cliente['pagado_hasta'] as String?;
                  if (ph != null && ph.compareTo(fpIso) > 0) {
                    final diasRest = DateTime.parse(ph)
                        .difference(DateTime.parse(fpIso))
                        .inDays;
                    return Container(
                      margin: const EdgeInsets.only(
                          top: 8, bottom: 4),
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.green.shade50,
                        borderRadius:
                            BorderRadius.circular(8),
                        border: Border.all(
                            color: Colors.green.shade200),
                      ),
                      child: Row(
                        children: [
                          const Text('✅ ',
                              style:
                                  TextStyle(fontSize: 16)),
                          Expanded(
                            child: Text(
                              'Tiene $diasRest día(s) vigentes. '
                              'No se pierden: el nuevo período '
                              'empieza al vencer.',
                              style: TextStyle(
                                  fontSize: 13,
                                  color:
                                      Colors.green.shade900),
                            ),
                          ),
                        ],
                      ),
                    );
                  }
                  return const SizedBox.shrink();
                }),
                const SizedBox(height: 8),
                // Selector de fecha del pago (v1.1)
                InkWell(
                  onTap: () async {
                    final picked = await showDatePicker(
                      context: ctx,
                      initialDate: fechaPago,
                      firstDate: DateTime(2020),
                      lastDate: DateTime.now(),
                      helpText: 'Fecha del pago',
                    );
                    if (picked != null) {
                      setS(() => fechaPago = picked);
                    }
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.grey.shade400),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.calendar_today, size: 18),
                        const SizedBox(width: 8),
                        Text(
                          'Pagado el: ${fechaPago.day.toString().padLeft(2, '0')}/'
                          '${fechaPago.month.toString().padLeft(2, '0')}/'
                          '${fechaPago.year}',
                          style: const TextStyle(fontSize: 15),
                        ),
                        const Spacer(),
                        const Icon(Icons.edit, size: 16, color: Colors.grey),
                      ],
                    ),
                  ),
                ),
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
  final fpIso2 = '${fechaPago.year.toString().padLeft(4, '0')}-'
      '${fechaPago.month.toString().padLeft(2, '0')}-'
      '${fechaPago.day.toString().padLeft(2, '0')}';
  final nuevo = previewHastaDias(
      cliente['pagado_hasta'] as String?, _diasDe(s),
      fechaPago: fpIso2);
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
    // Monto calculado y vencimiento previsto: los usa la pantalla de
    // confirmación. El servidor los ignora (recalcula él mismo).
    'monto': s.monto,
    'pagado_hasta': nuevo,
    'metodo': metodo,
    'fecha': '${fechaPago.year.toString().padLeft(4, '0')}-'
        '${fechaPago.month.toString().padLeft(2, '0')}-'
        '${fechaPago.day.toString().padLeft(2, '0')}',
  };
}
