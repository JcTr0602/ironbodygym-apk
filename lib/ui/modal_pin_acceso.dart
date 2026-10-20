/// Modal seguro para mostrar el PIN de acceso a la App de Clientes.
/// v1.3.9 (F1, ajuste de Argón): helper compartido entre ficha.dart,
/// ficha_acceso.dart y el menú ⋮ de Control de Acceso (vía
/// acciones_acceso.dart). El modal NO se cierra solo: tiene Copiar PIN,
/// Enviar por WhatsApp y cierre explícito "Ya lo envié (Cerrar)".
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import 'diseno.dart';

/// Sanitiza el teléfono para wa.me (regla de Argón):
/// - Limpia no-numéricos.
/// - 8 dígitos → antepone 53.
/// - 10 dígitos empezando con 53 → tal cual.
/// - Otro caso → null (teléfono inválido para WhatsApp).
String? sanitizarParaWaMe(String telefono) {
  final limpio = telefono.replaceAll(RegExp(r'[^0-9]'), '');
  if (limpio.length == 8) return '53$limpio';
  if (limpio.length == 10 && limpio.startsWith('53')) return limpio;
  return null;
}

/// Muestra el modal del PIN. barrierDismissible: false.
void mostrarModalPin(
    BuildContext context, String pin, String telefono, String nombre) {
  final telWa = sanitizarParaWaMe(telefono);
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
                style: const TextStyle(
                    fontSize: 36,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 8,
                    color: AppColores.naranja)),
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
          icon: const Icon(Icons.copy, size: 18),
          label: const Text('Copiar PIN'),
          onPressed: () {
            Clipboard.setData(ClipboardData(text: pin));
            ScaffoldMessenger.of(ctx).showSnackBar(
                const SnackBar(
                    content: Text('PIN copiado')));
          },
        ),
        // Botón WhatsApp siempre visible (Argón): si el teléfono es
        // inválido, muestra alerta en vez de ocultar el botón.
        TextButton.icon(
          icon: const Icon(Icons.chat, size: 18),
          label: const Text('WhatsApp'),
          onPressed: () {
            if (telWa == null) {
              ScaffoldMessenger.of(ctx).showSnackBar(
                  SnackBar(
                      content: Text(
                          'Teléfono inválido para WhatsApp ("$telefono"). Usa Copiar PIN.')));
              return;
            }
            final mensaje =
                'Hola $nombre, tu acceso a Iron Body App:\n'
                'Teléfono: $telefono\n'
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
