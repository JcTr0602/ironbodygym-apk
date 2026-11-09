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
import '../negocio.dart'
    show validarTelefono, sanitizarTelefono, antesEdicionCliente;
import '../sync.dart';
import 'componentes.dart';

/// El diálogo en sí, con su controlador en un State
/// propio (patrón de la casa): el dispose vive en
/// State.dispose(). La versión anterior lo liberaba en
/// un finally tras `await showDialog`, cuando la
/// animación de cierre aún mantiene el TextField
/// montado: «used after being disposed» (Argón 1.25
/// MEDIA, reintroducido al extraer el componente).
/// Devuelve el texto tecleado o null al cancelar.
class _DialogoTelefono extends StatefulWidget {
  const _DialogoTelefono();

  @override
  State<_DialogoTelefono> createState() =>
      _DialogoTelefonoState();
}

class _DialogoTelefonoState extends State<_DialogoTelefono> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Agregar teléfono'),
      content: TextField(
        controller: _ctrl,
        keyboardType: TextInputType.phone,
        maxLength: 8,
        decoration: const InputDecoration(
          hintText: 'Ej. 58191577',
          helperText: '8 dígitos, empieza con 5 o 6',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        BotonPrimario(
          texto: 'Guardar',
          onPressed: () => Navigator.pop(context, _ctrl.text),
          expandido: false,
        ),
      ],
    );
  }
}

Future<String?> dialogoAgregarTelefono(
  BuildContext context, {
  required int clienteId,
  bool soloDueno = false,
}) async {
  if (soloDueno && !AuthService().isOwner) return null;
  if (clienteId <= 0) return null;
  final crudo = await showDialog<String>(
    context: context,
    builder: (_) => const _DialogoTelefono(),
  );
  if (crudo == null || !context.mounted) return null;
  {
    // Yunque B (YB-CLI-11): se guarda el teléfono SANITIZADO
    // (8 dígitos limpios), no el texto crudo — la validación
    // limpia solo para comprobar. Hoy lo único que impedía
    // un teléfono sucio era el maxLength del campo; la regla
    // de la casa se aplica aquí, al guardar.
    final tel = sanitizarTelefono(crudo) ?? '';
    if (!validarTelefono(tel)) {
      if (context.mounted) {
        mostrarSnack(context,
            'Teléfono inválido: 8 dígitos, empieza con 5 o 6.',
            significado: SignificadoChip.alerta);
      }
      return null;
    }
    // 1.25 Panel 9: la fila previa aporta el «antes» del
    // registro (aquí normalmente no hay teléfono: queda
    // registrado como agregado, no como cambio).
    final previas =
        await LocalDb.instance.mirrorPorIds('clientes', [clienteId]);
    final payloadTel = <String, dynamic>{
      'cliente_id': clienteId,
      'telefono': tel,
    };
    final antesTel = antesEdicionCliente(
        previas.isEmpty ? null : previas.first, payloadTel);
    if (antesTel.isNotEmpty) payloadTel['antes'] = antesTel;
    await LocalDb.instance.updateMirrorTelefono(clienteId, tel);
    // Encolar la edición para el servidor.
    await LocalDb.instance.queueOp(
      opUuid: const Uuid().v4(),
      tipo: 'editar_cliente',
      payload: payloadTel,
    );
    unawaited(SyncEngine.instance.push());
    if (context.mounted) {
      mostrarSnack(context, 'Teléfono guardado.',
          significado: SignificadoChip.exito);
    }
    return tel;
  }
}
