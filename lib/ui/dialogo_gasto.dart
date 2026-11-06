import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../auth.dart';
import '../localdb.dart';
import '../permisos_entrenador.dart';
import '../sync.dart';
import '../tiempo.dart';
import 'componentes.dart';
import 'diseno.dart';

/// 1.27: flujo ÚNICO de registrar un gasto (op sync
/// 'gasto'), compartido por el Panel del dueño
/// (AdminScreen) y la pantalla de Gastos del entrenador
/// con el permiso can_registrar_gastos. Antes el flujo
/// vivía solo dentro de AdminScreen con guarda de
/// dueño: el permiso existía en la lista y el servidor
/// lo verificaba (permisos_ops: 'gasto' →
/// can_registrar_gastos), pero ningún entrenador podía
/// llegar a él — permiso sin efecto real.
///
/// Devuelve true si el gasto quedó encolado.
Future<bool> agregarGastoFlow(BuildContext context) async {
  // H-02 (Argón 1.27): guarda de permiso DENTRO del
  // flujo compartido, antes de abrir el diálogo. Las
  // pantallas que lo llaman pueden quedar abiertas en
  // segundo plano con el permiso ya revocado: sin esta
  // guarda, el entrenador seguía registrando y veía el
  // falso «Gasto guardado (se sincronizará)» mientras
  // el servidor rebotaba la op. El servidor sigue
  // siendo el cinturón final (permisos_ops).
  if (!AuthService().isOwner &&
      !PermisosEntrenador().canRegistrarGastos) {
    mostrarSnack(
        context,
        'No tienes permiso para registrar gastos. Pídeselo a Jc.',
        significado: SignificadoChip.error);
    return false;
  }
  final datos = await showDialog<({String concepto, double monto})>(
    context: context,
    builder: (_) => const DialogoAgregarGasto(),
  );
  if (datos == null || !context.mounted) return false;
  final hoy = ahoraHabana();
  final fecha = '${hoy.year.toString().padLeft(4, '0')}-'
      '${hoy.month.toString().padLeft(2, '0')}-'
      '${hoy.day.toString().padLeft(2, '0')}';
  await LocalDb.instance.queueOp(
    opUuid: const Uuid().v4(),
    tipo: 'gasto',
    payload: {
      'fecha': fecha,
      'concepto': datos.concepto,
      'monto': datos.monto,
    },
  );
  if (!context.mounted) return true;
  mostrarSnack(context, 'Gasto guardado (se sincronizará)',
      significado: SignificadoChip.exito);
  SyncEngine.instance.push();
  return true;
}

/// Diálogo de captura del gasto. StatefulWidget propio
/// con dispose de controladores en State.dispose()
/// (regla de la casa para diálogos con
/// TextEditingController).
class DialogoAgregarGasto extends StatefulWidget {
  const DialogoAgregarGasto({super.key});

  @override
  State<DialogoAgregarGasto> createState() =>
      _DialogoAgregarGastoState();
}

class _DialogoAgregarGastoState extends State<DialogoAgregarGasto> {
  final _conceptoCtrl = TextEditingController();
  final _montoCtrl = TextEditingController();

  @override
  void dispose() {
    _conceptoCtrl.dispose();
    _montoCtrl.dispose();
    super.dispose();
  }

  void _guardar() {
    final concepto = _conceptoCtrl.text.trim();
    final monto =
        double.tryParse(_montoCtrl.text.trim().replaceAll(',', '.'));
    // Clase N-2 (1.22 #2): NaN/Infinity pasaban el <= 0 y
    // el payload reventaba al codificarse a JSON.
    if (concepto.isEmpty ||
        monto == null ||
        !monto.isFinite ||
        monto <= 0) {
      mostrarSnack(context, 'Concepto o monto inválidos',
          significado: SignificadoChip.alerta);
      return;
    }
    Navigator.pop(context, (concepto: concepto, monto: monto));
  }

  @override
  Widget build(BuildContext context) {
    return DialogoApp(
      titulo: 'Agregar gasto',
      iconoTitulo: Icons.receipt_long_rounded,
      contenido: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CampoTexto(
              controller: _conceptoCtrl,
              etiqueta: 'Concepto (ej: pago de la luz)'),
          const SizedBox(height: 8),
          CampoTexto(
              controller: _montoCtrl,
              etiqueta: 'Monto (CUP)',
              teclado:
                  const TextInputType.numberWithOptions(decimal: true)),
        ],
      ),
      acciones: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar')),
        ElevatedButton(
          onPressed: _guardar,
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColores.naranja,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadio.md),
            ),
          ),
          child: const Text('Guardar'),
        ),
      ],
    );
  }
}
