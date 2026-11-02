import 'package:flutter/material.dart';

import '../negocio.dart';
import '../tiempo.dart';
import 'componentes.dart';

/// T16 (1.20): si en la cola hay una operación casi
/// idéntica de hace pocos minutos, avisa y pide confirmar
/// antes de registrar otra igual. Devuelve true si se
/// puede continuar (no hay parecida, o el usuario confirma
/// que es una operación distinta y legítima).
Future<bool> confirmarSiPareceDuplicado(
  BuildContext context, {
  required String tipo,
  required bool Function(Map<String, dynamic> payload) coincide,
  required String descripcion,
}) async {
  final op = await opRecienteParecida(tipo: tipo, coincide: coincide);
  if (op == null) return true;
  if (!context.mounted) return false;
  final creada = DateTime.tryParse('${op['creada_ts'] ?? ''}');
  // Misma normalización que el matcher (FIN-08 de Argón).
  final creadaHab =
      creada == null ? null : (creada.isUtc ? aHabana(creada) : creada);
  final haceTxt = creadaHab == null
      ? ''
      : ' (hace ${ahoraHabana().difference(creadaHab).inMinutes} min)';
  return DialogoApp.confirmar(
    context,
    titulo: '¿Operación duplicada?',
    mensaje: 'Hace pocos minutos se registró una operación '
        'muy parecida: $descripcion$haceTxt.\n\n'
        'Si fue un doble toque o un reintento, cancela. Si '
        'es una operación distinta y legítima, continúa.',
    aceptar: 'Continuar igual',
    cancelar: 'Cancelar',
    icono: Icons.warning_amber_rounded,
    peligro: true,
  );
}
