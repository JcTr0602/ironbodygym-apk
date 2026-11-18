/// Modal seguro para mostrar el PIN de acceso a la App de Clientes.
/// v1.3.9 (F1, ajuste de Argón): helper compartido entre ficha.dart,
/// ficha_acceso.dart y el menú ⋮ de Control de Acceso (vía
/// acciones_acceso.dart). El modal NO se cierra solo: tiene Copiar PIN,
/// Enviar por WhatsApp y cierre explícito "Ya lo envié (Cerrar)".
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../negocio.dart' show normalizarTelefonoWaMe, mensajePinAcceso;
import 'diseno.dart';
import 'componentes.dart';

/// Muestra el modal del PIN. barrierDismissible: false.
/// 1.23 AT-01 (auditoría total de Argón): el teléfono se
/// normaliza con la función ÚNICA del proyecto
/// (normalizarTelefonoWaMe: exige móvil cubano 5/6, '' si no
/// vale) — el sanitizador propio que vivía aquí era laxo (no
/// exigía 5/6) y el mensaje imprimía el teléfono CRUDO, con el
/// prefijo o los separadores que trajera la ficha.
void mostrarModalPin(
    BuildContext context, String pin, String telefono, String nombre) {
  final telWa = normalizarTelefonoWaMe(telefono);
  // Los 8 dígitos limpios que el cliente teclea en la app.
  final tel8 = telWa.length >= 8
      ? telWa.substring(telWa.length - 8)
      : telefono.replaceAll(RegExp(r'[^0-9]'), '');
  showDialog(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => _ModalPin(pin: pin, telWa: telWa, tel8: tel8, telefono: telefono, nombre: nombre),
  );
}

/// 1.36 H-B1 (136-443): el modal solo se cierra por sus
/// botones — el atrás del sistema no lo despacha
/// (PopScope con canPop falso hasta que el botón de
/// cierre lo permite explícitamente).
class _ModalPin extends StatefulWidget {
  final String pin;
  final String telWa;
  final String tel8;
  final String telefono;
  final String nombre;

  const _ModalPin({
    required this.pin,
    required this.telWa,
    required this.tel8,
    required this.telefono,
    required this.nombre,
  });

  @override
  State<_ModalPin> createState() => _ModalPinState();
}

class _ModalPinState extends State<_ModalPin> {
  bool _cierrePermitido = false;

  @override
  Widget build(BuildContext context) {
    final pin = widget.pin;
    final telWa = widget.telWa;
    final tel8 = widget.tel8;
    final telefono = widget.telefono;
    final nombre = widget.nombre;
    final ctx = context;
    return PopScope(
      canPop: _cierrePermitido,
      child: AlertDialog(
      title: const Text('PIN de acceso'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Cliente: $nombre',
              style: AppTexto.cuerpo),
          const SizedBox(height: AppEspacio.sm),
          Center(
            child: Text(pin,
                style: AppTexto.display.copyWith(
                    letterSpacing: 8, color: AppColores.naranja)),
          ),
          const SizedBox(height: AppEspacio.sm),
          const Text(
            'Envía o copia este PIN ahora; por seguridad no se volverá a mostrar al cerrar.',
            style: AppTexto.secundario,
          ),
        ],
      ),
      actions: [
        TextButton.icon(
          icon: const Icon(Icons.copy_rounded, size: 18),
          label: const Text('Copiar PIN'),
          onPressed: () {
            Clipboard.setData(ClipboardData(text: pin));
            mostrarSnack(ctx, 'PIN copiado');
          },
        ),
        // Botón WhatsApp siempre visible (Argón): si el teléfono es
        // inválido, muestra alerta en vez de ocultar el botón.
        TextButton.icon(
          icon: const Icon(Icons.chat_rounded, size: 18),
          label: const Text('WhatsApp'),
          onPressed: () {
            if (telWa.isEmpty) {
              mostrarSnack(ctx, 'Teléfono inválido para WhatsApp ("$telefono"). Usa Copiar PIN.', significado: SignificadoChip.alerta);
              return;
            }
            final mensaje = mensajePinAcceso(
                nombre: nombre, telefono8: tel8, pin: pin);
            final url = Uri.parse(
                'https://wa.me/$telWa?text=${Uri.encodeComponent(mensaje)}');
            launchUrl(url,
                mode: LaunchMode.externalApplication);
            // El modal NO se cierra (regla de Argón).
          },
        ),
        FilledButton(
          onPressed: () async {
            // Yunque R5-M2-6: el PIN copiado no queda en el
            // portapapeles del sistema tras cerrar el modal
            // (pegable en cualquier app). Solo se limpia si
            // aún contiene ESTE PIN: si el usuario copió otra
            // cosa después, eso no se toca.
            try {
              final datos = await Clipboard.getData('text/plain');
              if (datos?.text == pin) {
                await Clipboard.setData(
                    const ClipboardData(text: ''));
              }
            } catch (_) {}
            if (ctx.mounted) {
              // 136-443: el botón autoriza el cierre y el
              // PopScope lo deja pasar en el siguiente frame.
              setState(() => _cierrePermitido = true);
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (ctx.mounted) Navigator.of(ctx).pop();
              });
            }
          },
          child: const Text('Ya lo envié (Cerrar)'),
        ),
      ],
      ),
    );
  }
}
