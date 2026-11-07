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
  // (M2-A A7) re-chequeo DECISIVO justo antes de encolar: el
  // chequeo de arriba leyó la foto en caché al ABRIR; si el
  // permiso se revocó con el diálogo abierto, el «Gasto
  // guardado» era falso (el servidor rebotaba la op en
  // silencio). Aquí se corta con el motivo en claro.
  if (!AuthService().isOwner &&
      !PermisosEntrenador().canRegistrarGastos) {
    mostrarSnack(
        context,
        'Tu permiso para registrar gastos cambió mientras '
        'escribías: el gasto NO se guardó.',
        significado: SignificadoChip.error);
    return false;
  }
  final hoy = ahoraHabana();
  final fecha = '${hoy.year.toString().padLeft(4, '0')}-'
      '${hoy.month.toString().padLeft(2, '0')}-'
      '${hoy.day.toString().padLeft(2, '0')}';
  // (M2-A A7) el encolado también puede fallar: nada de
  // silencio — sin op en cola no hay gasto, y el snack de
  // éxito de abajo sería mentira.
  try {
    await LocalDb.instance.queueOp(
      opUuid: const Uuid().v4(),
      tipo: 'gasto',
      payload: {
        'fecha': fecha,
        'concepto': datos.concepto,
        'monto': datos.monto,
      },
    );
  } catch (e) {
    if (context.mounted) {
      mostrarSnack(context, 'No se pudo guardar el gasto: $e',
          significado: SignificadoChip.error);
    }
    return false;
  }
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

  // Delta Argón 1.27 (#2): un doble toque en
  // «Guardar» no debe disparar dos Navigator.pop: el
  // segundo cerraría la pantalla que abrió el
  // diálogo. La bandera se toma síncrona al entrar
  // (antes de cualquier rebuild) y el botón queda
  // deshabilitado tras el primer toque válido.
  bool _guardando = false;

  @override
  void dispose() {
    _conceptoCtrl.dispose();
    _montoCtrl.dispose();
    super.dispose();
  }

  Future<void> _guardar() async {
    if (_guardando) return;
    final concepto = _conceptoCtrl.text.trim();
    final crudo = _montoCtrl.text.trim();
    // (M2-A A7) captura estricta: solo dígitos con UN
    // separador decimal. El tryParse de antes aceptaba la
    // notación científica ('1e5' = 100000) y dejaba pasar
    // formatos que nadie escribió a propósito.
    if (concepto.isEmpty ||
        !RegExp(r'^\d+([.,]\d+)?$').hasMatch(crudo)) {
      mostrarSnack(context, 'Concepto o monto inválidos',
          significado: SignificadoChip.alerta);
      return;
    }
    var monto = double.tryParse(crudo.replaceAll(',', '.'));
    // Clase N-2 (1.22 #2): NaN/Infinity pasaban el <= 0 y
    // el payload reventaba al codificarse a JSON.
    if (monto == null || !monto.isFinite || monto <= 0) {
      mostrarSnack(context, 'Concepto o monto inválidos',
          significado: SignificadoChip.alerta);
      return;
    }
    setState(() => _guardando = true);
    // (M2-A A7) separador de miles ambiguo: «1.500» puede ser
    // 1.50 o 1500 — el parse crudo lo dejaba en 1.5 SIN AVISO
    // y un gasto de 1500 CUP quedaba registrado como 1.50.
    // Se pregunta, con las dos lecturas en claro.
    if (RegExp(r'^\d{1,3}[.,]\d{3}$').hasMatch(crudo)) {
      final comoMiles =
          double.parse(crudo.replaceAll(RegExp(r'[.,]'), ''));
      final comoDecimal = monto;
      final elegido = await showDialog<double>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('¿Cuánto es?'),
          content: Text('Escribiste «$crudo». Eso puede ser '
              '${comoDecimal.toStringAsFixed(2)} CUP o '
              '${comoMiles.toStringAsFixed(0)} CUP. '
              'Elige el monto correcto:'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, comoDecimal),
              child: Text('${comoDecimal.toStringAsFixed(2)} CUP'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, comoMiles),
              child: Text(
                  '${comoMiles.toStringAsFixed(0)} CUP'),
            ),
          ],
        ),
      );
      if (elegido == null || !mounted) {
        setState(() => _guardando = false);
        return;
      }
      monto = elegido;
    }
    // Redondeo a centavos y tope de cordura (un gasto del gym
    // no pasa de decenas de millones; más que eso es un error
    // de captura, no un gasto).
    monto = (monto * 100).round() / 100;
    if (monto <= 0 || monto > 99999999) {
      mostrarSnack(
          context,
          monto <= 0
              ? 'Concepto o monto inválidos'
              : 'Ese monto es demasiado grande para un gasto: '
                  'revisa si sobra algún cero.',
          significado: SignificadoChip.alerta);
      setState(() => _guardando = false);
      return;
    }
    if (!mounted) return;
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
        // (M2-A A7) Cancelar también respeta la guarda: con
        // el guardado en vuelo, un Cancelar cerraba el
        // diálogo y el pop del guardado caía sobre la
        // pantalla de abajo.
        TextButton(
            onPressed: _guardando
                ? null
                : () => Navigator.pop(context),
            child: const Text('Cancelar')),
        ElevatedButton(
          onPressed: _guardando ? null : _guardar,
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
