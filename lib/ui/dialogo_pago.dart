/// Diálogo unificado de pago (ficha del cliente y Agregar Pago).
///
/// Períodos: semana, quincena, meses y personalizado (días + monto
/// manuales). Siempre pide confirmación con resumen antes de registrar.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../localdb.dart';
import '../negocio.dart';
import '../tipos_pago.dart';
import 'diseno.dart';

/// Selección de período hecha en el diálogo.
class PeriodoSel {
  final String periodo; // semanal | quincenal | mensual | personalizado
  final int meses;
  final int dias; // solo personalizado
  final double monto; // calculado o manual
  // v1.0.16: id del tipo de pago dinámico elegido (si aplica)
  final String? tipoId;
  const PeriodoSel(
      {required this.periodo,
      this.meses = 1,
      this.dias = 0,
      required this.monto,
      this.tipoId});
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
  final transfer = (aj['transferencia'] as num?)?.toDouble() ?? 2500;
  if (!context.mounted) return null;

  // v1.0.16: tipos dinámicos; menores ven precio reducido automáticamente
  final menor = esMenor(cliente['carnet'] as String?);
  final tipos = await getTiposPago(paraMenor: menor);
  if (!context.mounted) return null;
  if (tipos.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('No hay tipos de pago configurados')));
    return null;
  }

  // Tipo inicial: 'mensual' (o 'menores' si es menor)
  TipoPago tipoSel =
      tipos.firstWhere((t) => t.id == (menor ? 'menores' : 'mensual'),
          orElse: () => tipos.first);
  int meses = 1;
  String metodo = 'efectivo';
  final diasCtrl = TextEditingController();
  final montoCtrl = TextEditingController();
  DateTime fechaPago = DateTime.now(); // v1.1: permite elegir fecha del pago

  /// Mapea el tipo elegido al período del motor del servidor.
  /// Los 4 fijos usan su período nativo; los personalizados van como
  /// 'personalizado' (días + monto), sin cambios en el servidor.
  PeriodoSel actual() {
    double monto;
    String periodo;
    int dias = 0;
    final id = tipoSel.id;
    if (id == 'personalizado') {
      periodo = 'personalizado';
      dias = int.tryParse(diasCtrl.text.trim()) ?? 0;
      monto = double.tryParse(
              montoCtrl.text.trim().replaceAll(',', '.')) ??
          0;
    } else if (id == 'semanal') {
      periodo = 'semanal';
      monto = tipoSel.monto;
    } else if (id == 'quincenal') {
      periodo = 'quincenal';
      monto = tipoSel.monto;
    } else if (id == 'mensual' || id == 'menores') {
      periodo = 'mensual';
      // transferencia solo afecta al mensual normal
      final unit = (metodo == 'transferencia' && id == 'mensual')
          ? transfer
          : tipoSel.monto;
      monto = unit * meses;
    } else {
      // Tipo personalizado de Jc -> motor 'personalizado'
      periodo = 'personalizado';
      dias = tipoSel.dias;
      monto = tipoSel.monto;
    }
    return PeriodoSel(
        periodo: periodo,
        meses: meses,
        dias: dias,
        monto: monto,
        tipoId: id == 'personalizado' ? null : id);
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
          title: Text('Pago — ${cliente['nombre']}'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                    'Vence: ${fmtFecha(cliente['pagado_hasta'] as String?)}'),
                // v1.0.14: aviso de precio reducido para menores
                if (menor)
                  Container(
                    margin:
                        const EdgeInsets.only(top: 8, bottom: 4),
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: AppColores.info
                          .withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(
                          AppRadio.md),
                      border: Border.all(
                          color: AppColores.info
                              .withValues(alpha: 0.4)),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.child_care,
                            color: AppColores.info),
                        const SizedBox(
                            width: AppEspacio.sm),
                        Expanded(
                          child: Text(
                            'Menor de 18: precio especial '
                            '${fmtMonto(tipos.firstWhere((t) => t.id == 'menores', orElse: () => tipos.first).monto)} CUP/mes.',
                            style: const TextStyle(
                                fontSize: 13),
                          ),
                        ),
                      ],
                    ),
                  ),
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
                        color: AppColores.exito
                            .withValues(alpha: 0.08),
                        borderRadius:
                            BorderRadius.circular(
                                AppRadio.md),
                        border: Border.all(
                            color: AppColores.exito
                                .withValues(alpha: 0.4)),
                      ),
                      child: Row(
                        children: [
                          const Icon(
                              Icons.check_circle,
                              color:
                                  AppColores.exito),
                          const SizedBox(
                              width: AppEspacio.sm),
                          Expanded(
                            child: Text(
                              'Tiene $diasRest día(s) vigentes. '
                              'No se pierden: el nuevo período '
                              'empieza al vencer.',
                              style: const TextStyle(
                                  fontSize: 13),
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
                  value: tipoSel.id,
                  isExpanded: true,
                  items: [
                    for (final t in tipos)
                      DropdownMenuItem(
                          value: t.id,
                          child: Text(
                              '${t.nombre} (${fmtMonto(t.monto)} CUP)')),
                    const DropdownMenuItem(
                        value: 'personalizado',
                        child: Text('Personalizado…')),
                  ],
                  onChanged: (v) => setS(() {
                    if (v == 'personalizado') {
                      tipoSel = const TipoPago(
                          id: 'personalizado',
                          nombre: 'Personalizado',
                          monto: 0,
                          dias: 0);
                    } else {
                      tipoSel = tipos
                          .firstWhere((t) => t.id == v);
                    }
                  }),
                ),
                // Selector de meses para mensual/menores
                if (tipoSel.id == 'mensual' ||
                    tipoSel.id == 'menores') ...[
                  const SizedBox(height: 8),
                  const Text('Meses:'),
                  DropdownButton<int>(
                    value: meses,
                    isExpanded: true,
                    items: [
                      for (final m in [1, 2, 3, 6, 12])
                        DropdownMenuItem(
                            value: m,
                            child: Text(
                                '$m mes${m == 1 ? '' : 'es'}')),
                    ],
                    onChanged: (v) =>
                        setS(() => meses = v ?? 1),
                  ),
                ],
                if (tipoSel.id == 'personalizado') ...[
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
                        label: const Text('Efectivo'),
                        avatar: const Icon(Icons.payments,
                            size: 18),
                        selected: metodo == 'efectivo',
                        onSelected: (_) =>
                            setS(() => metodo = 'efectivo')),
                    const SizedBox(width: 8),
                    ChoiceChip(
                        label: const Text('Transfer.'),
                        avatar: const Icon(
                            Icons.smartphone,
                            size: 18),
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
          Text('Método: ${metodo == 'efectivo' ? 'Efectivo' : 'Transferencia'}'),
          // v1.0.15: monto prominente en la confirmación de cobro.
          const SizedBox(height: 8),
          Center(
            child: Text('${fmtMonto(s.monto)} CUP',
                style: const TextStyle(
                    fontSize: 34,
                    fontWeight: FontWeight.bold,
                    color: AppColores.naranja)),
          ),
          const SizedBox(height: 8),
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
