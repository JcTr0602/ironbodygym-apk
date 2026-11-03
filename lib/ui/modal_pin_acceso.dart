/// Modal seguro para mostrar el PIN de acceso a la App de Clientes.
/// v1.3.9 (F1, ajuste de Argón): helper compartido entre ficha.dart,
/// ficha_acceso.dart y el menú ⋮ de Control de Acceso (vía
/// acciones_acceso.dart). El modal NO se cierra solo: tiene Copiar PIN,
/// Enviar por WhatsApp y cierre explícito "Ya lo envié (Cerrar)".
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../negocio.dart' show normalizarTelefonoWaMe;
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
    builder: (ctx) => AlertDialog(
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
            final mensaje =
                'Hola $nombre, tu acceso a Iron Body App:\n'
                'Teléfono: $tel8\n'
                'PIN: $pin\n'
                'Descarga la app y entra con estos datos.';
            final url = Uri.parse(
                'https://wa.me/$telWa?text=${Uri.encodeComponent(mensaje)}');
            launchUrl(url,
                mode: LaunchMode.externalApplication);
            // El modal NO se cierra (regla de Argón).
          },
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('Ya lo envié (Cerrar)'),
        ),
      ],
    ),
  );
}
