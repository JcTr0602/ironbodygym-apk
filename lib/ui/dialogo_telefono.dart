// lib/ui/dialogo_telefono.dart
// 1.25 T122 (F6-16): el diálogo «Agregar teléfono» vivía
// copiado en bandeja_whatsapp.dart y cumpleanos.dart (mismo
// título, misma validación, mismo guardado): toda corrección
// había que hacerla dos veces. Aquí vive UNA sola vez.
//
// Comportamiento (el de la copia más cuidada, la de la
// bandeja): valida con validarTelefono (8 dígitos limpios,
// empieza con 5 o 6), actualiza el espejo local, encola la
// op editar_cliente y dispara el push. Devuelve true solo
// si el teléfono quedó guardado.
//
// [soloDueno]: la bandeja exige dueño para agregar
// teléfonos (Ronda 17 M7-H3); Cumpleaños no lo exigía y su
// comportamiento no cambia.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../auth.dart';
import '../localdb.dart';
import '../negocio.dart' show validarTelefono;
import '../sync.dart';
import 'componentes.dart';

Future<String?> dialogoAgregarTelefono(
  BuildContext context, {
  required int clienteId,
  bool soloDueno = false,
}) async {
  if (soloDueno && !AuthService().isOwner) return null;
  if (clienteId <= 0) return null;
  final ctrl = TextEditingController();
  try {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Agregar teléfono'),
        content: TextField(
          controller: ctrl,
          keyboardType: TextInputType.phone,
          maxLength: 8,
          decoration: const InputDecoration(
            hintText: 'Ej. 58191577',
            helperText: '8 dígitos, empieza con 5 o 6',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          BotonPrimario(
            texto: 'Guardar',
            onPressed: () => Navigator.pop(ctx, true),
            expandido: false,
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return null;
    final tel = ctrl.text.trim();
    if (!validarTelefono(tel)) {
      if (context.mounted) {
        mostrarSnack(context,
            'Teléfono inválido: 8 dígitos, empieza con 5 o 6.',
            significado: SignificadoChip.alerta);
      }
      return null;
    }
    await LocalDb.instance.updateMirrorTelefono(clienteId, tel);
    // Encolar la edición para el servidor.
    await LocalDb.instance.queueOp(
      opUuid: const Uuid().v4(),
      tipo: 'editar_cliente',
      payload: {'cliente_id': clienteId, 'telefono': tel},
    );
    unawaited(SyncEngine.instance.push());
    if (context.mounted) {
      mostrarSnack(context, 'Teléfono guardado.',
          significado: SignificadoChip.exito);
    }
    return tel;
  } finally {
    // El controlador del diálogo se libera siempre (antes
    // quedaba vivo en cada apertura).
    ctrl.dispose();
  }
}
