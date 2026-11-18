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
  String? _error;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  /// 1.36 H-B1 (136-321): la validación vive DENTRO del
  /// diálogo — si el número no vale, el error se pinta
  /// junto al campo y lo tecleado NO se pierde (antes el
  /// diálogo cerraba primero y el aviso caía fuera, en la
  /// pantalla de fondo, con el texto ya descartado).
  void _guardar() {
    final tel = sanitizarTelefono(_ctrl.text) ?? '';
    if (!validarTelefono(tel)) {
      setState(() => _error =
          'Teléfono inválido: 8 dígitos, empieza con 5 o 6.');
      return;
    }
    Navigator.pop(context, _ctrl.text);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Agregar teléfono'),
      content: TextField(
        controller: _ctrl,
        autofocus: true,
        keyboardType: TextInputType.phone,
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _guardar(),
        // Yunque 2.34 (D-6): SIN maxLength — con 8, pegar
        // «5358191577» se truncaba a «53581915» ANTES de
        // sanitizar y se guardaba un número equivocado pero
        // «válido». Quien juzga es sanitizarTelefono al
        // guardar (dialogoAgregarTelefono), que acepta el
        // prefijo 53 y los espacios.
        decoration: InputDecoration(
          labelText: 'Teléfono',
          hintText: 'Ej. 58191577',
          helperText: '8 dígitos, empieza con 5 o 6',
          errorText: _error,
        ),
        onChanged: (_) {
          if (_error != null) setState(() => _error = null);
        },
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        BotonPrimario(
          texto: 'Guardar',
          onPressed: _guardar,
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
    // limpia solo para comprobar. La regla de la casa se
    // aplica aquí, al guardar. (Yunque 2.34, D-6: el campo ya
    // no trunca a 8 — truncaba el pegado con prefijo 53 a un
    // número distinto pero válido.)
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
