import 'package:flutter/material.dart';

import '../negocio.dart';
import '../tiempo.dart';
import 'componentes.dart';

/// 1.36 H-C2 (136-714, pura): el «hace X min» del aviso —
/// todo sello se normaliza a pared Habana con
/// `aHabana(creada.toUtc())` (un ISO sin offset parsea en
/// la zona del teléfono y la diferencia salía corrida) y
/// la antigüedad se acota a 0: nunca «hace -3 min»; lo
/// muy reciente es «hace un momento».
String haceTextoDuplicado(DateTime? creada, DateTime ahora) {
  if (creada == null) return '';
  final creadaHab = aHabana(creada.toUtc());
  final mins = ahora.difference(creadaHab).inMinutes;
  if (mins <= 0) return ' (hace un momento)';
  return ' (hace $mins min)';
}

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
  // 1.36 H-C2 (136-714): normalización y clamp en el
  // helper puro haceTextoDuplicado.
  final haceTxt = haceTextoDuplicado(creada, ahoraHabana());
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
