/// Diálogo de confirmación de inscripción (rediseño v1.3.5).
///
/// Aprobado por Jc 2026-10-16, luz verde de Argón con defensas:
/// - Widget dedicado (no extiende DialogoApp) para compartir diseño entre
///   los flujos de inscripción sin duplicar estructura.
/// - Foto con cacheWidth obligatorio (picos de RAM) + errorBuilder con
///   fallback al check naranja.
/// - Teléfono formateado solo si son exactamente 8 dígitos.
library;

import 'dart:io';

import 'package:flutter/material.dart';

import 'diseno.dart';

/// Formatea un teléfono de 8 dígitos como "5 816 1619" para presentación.
/// Si no son exactamente 8 dígitos, devuelve el texto tal cual.
String formatoTelefonoPresentacion(String tel) {
  final limpio = tel.replaceAll(RegExp(r'[^0-9]'), '');
  if (!RegExp(r'^\d{8}$').hasMatch(limpio)) return tel;
  return '${limpio.substring(0, 1)} ${limpio.substring(1, 4)} '
      '${limpio.substring(4)}';
}

class DialogoConfirmarInscripcion extends StatelessWidget {
  final String nombre;
  final String periodoEtiqueta;
  final String montoTxt;
  final String metodoPago;
  final String validoHastaTxt;
  final String telefono;
  final String carnet;
  final String? fotoPath;

  const DialogoConfirmarInscripcion({
    super.key,
    required this.nombre,
    required this.periodoEtiqueta,
    required this.montoTxt,
    required this.metodoPago,
    required this.validoHastaTxt,
    this.telefono = '',
    this.carnet = '',
    this.fotoPath,
  });

  /// Círculo naranja con check blanco (fallback sin foto).
  Widget _iconoCheckNaranja() {
    return Container(
      width: 72,
      height: 72,
      decoration: const BoxDecoration(
        color: AppColores.naranja,
        shape: BoxShape.circle,
      ),
      child: const Icon(Icons.check, color: Colors.white, size: 40),
    );
  }

  /// Cabecera: foto del cliente o check naranja si no hay foto / falla.
  Widget _cabecera() {
    if (fotoPath == null || fotoPath!.isEmpty) return _iconoCheckNaranja();
    return ClipOval(
      child: Image.file(
        File(fotoPath!),
        width: 72,
        height: 72,
        fit: BoxFit.cover,
        // Argón: decodificar solo miniatura ligera (la foto de cámara
        // tiene resolución nativa de varios MB).
        cacheWidth: 216,
        errorBuilder: (_, __, ___) => _iconoCheckNaranja(),
      ),
    );
  }

  Widget _filaDato(BuildContext context, IconData icono, String valor) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppEspacio.sm),
      child: Row(
        children: [
          Icon(icono,
              size: 22, color: AppColores.textoSecundario(context)),
          const SizedBox(width: AppEspacio.md),
          Expanded(
            child: Text(valor, style: AppTexto.cuerpo),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadio.xl),
      ),
      title: const Text('Confirmar inscripción',
          style: AppTexto.titulo, textAlign: TextAlign.center),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _cabecera(),
            const SizedBox(height: AppEspacio.md),
            // Monto protagonista.
            Text(
              montoTxt,
              textAlign: TextAlign.center,
              style: AppTexto.titulo.copyWith(
                color: AppColores.naranja,
                fontSize: 32,
                fontWeight: FontWeight.bold,
              ),
            ),
            Text(
              '($metodoPago)',
              style: AppTexto.secundario,
            ),
            const SizedBox(height: AppEspacio.md),
            Divider(color: AppColores.borde(context), height: 1),
            const SizedBox(height: AppEspacio.sm),
            _filaDato(context, Icons.person, nombre),
            _filaDato(context, Icons.calendar_month, periodoEtiqueta),
            if (carnet.isNotEmpty)
              _filaDato(context, Icons.badge, carnet),
            if (telefono.isNotEmpty)
              _filaDato(context, Icons.phone,
                  formatoTelefonoPresentacion(telefono)),
            // Vigencia como pastilla.
            Padding(
              padding:
                  const EdgeInsets.symmetric(vertical: AppEspacio.sm),
              child: Row(
                children: [
                  Icon(Icons.check_circle,
                      size: 22,
                      color: AppColores.textoSecundario(context)),
                  const SizedBox(width: AppEspacio.md),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppEspacio.md,
                      vertical: AppEspacio.xs,
                    ),
                    decoration: BoxDecoration(
                      color: AppColores.exito.withValues(alpha: 0.15),
                      borderRadius:
                          BorderRadius.circular(AppRadio.lg),
                    ),
                    child: Text(
                      'Válido hasta $validoHastaTxt',
                      style: AppTexto.cuerpo.copyWith(
                        color: AppColores.exito,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancelar'),
        ),
        ElevatedButton(
          onPressed: () => Navigator.pop(context, true),
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColores.naranja,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadio.md),
            ),
          ),
          child: const Text('Confirmar'),
        ),
      ],
      actionsPadding: const EdgeInsets.fromLTRB(
          AppEspacio.lg, 0, AppEspacio.lg, AppEspacio.lg),
    );
  }

  /// Muestra el diálogo y devuelve true si el usuario confirmó.
  static Future<bool> mostrar(
    BuildContext context, {
    required String nombre,
    required String periodoEtiqueta,
    required String montoTxt,
    required String metodoPago,
    required String validoHastaTxt,
    String telefono = '',
    String carnet = '',
    String? fotoPath,
  }) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => DialogoConfirmarInscripcion(
        nombre: nombre,
        periodoEtiqueta: periodoEtiqueta,
        montoTxt: montoTxt,
        metodoPago: metodoPago,
        validoHastaTxt: validoHastaTxt,
        telefono: telefono,
        carnet: carnet,
        fotoPath: fotoPath,
      ),
    );
    return ok == true;
  }
}
