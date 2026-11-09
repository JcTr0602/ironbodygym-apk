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
  // 1.25 T117 (F1-78): modo Cuenta a la Casa — el mismo diálogo
  // con «Sin cobro · Sin vencimiento» en vez del bloque de pago.
  final bool esCasa;
  final String sexo;
  // 1.25 T117 (F1-80): desglose del monto («3 × 2 000 CUP») y
  // línea «Desde hoy, …» junto a la vigencia.
  final String? desgloseTxt;
  final String? desdeTxt;

  const DialogoConfirmarInscripcion({
    super.key,
    required this.nombre,
    this.periodoEtiqueta = '',
    this.montoTxt = '',
    this.metodoPago = '',
    this.validoHastaTxt = '',
    this.telefono = '',
    this.carnet = '',
    this.fotoPath,
    this.esCasa = false,
    this.sexo = '',
    this.desgloseTxt,
    this.desdeTxt,
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
      child: const Icon(Icons.check_rounded, color: Colors.white, size: 40),
    );
  }

  /// Cabecera: foto del cliente o check naranja si no hay foto / falla.
  /// 1.25 T64: entra con la micro-animación de escala del
  /// recibo (celebración contenida) y la foto lleva el
  /// ANILLO del color del estado: dorado en Cuenta a la
  /// Casa, naranja en la inscripción normal.
  Widget _cabecera() {
    final colorAnillo =
        esCasa ? AppColores.casaIcono : AppColores.naranja;
    Widget interior;
    if (fotoPath == null || fotoPath!.isEmpty) {
      interior = _iconoCheckNaranja();
    } else {
      interior = Container(
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: colorAnillo, width: 3),
        ),
        child: ClipOval(
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
        ),
      );
    }
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.6, end: 1.0),
      duration: AppMovimiento.larga,
      curve: AppMovimiento.curvaPop,
      builder: (context, escala, hijo) =>
          Transform.scale(scale: escala, child: hijo),
      child: interior,
    );
  }

  /// Fila de dato con micro-etiqueta (1.25 T117 F1-79): la
  /// etiqueta dice qué es el valor; antes la fila era solo un
  /// icono y había que adivinarlo.
  Widget _filaDato(
      BuildContext context, IconData icono, String etiqueta, String valor) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppEspacio.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icono,
              size: 22, color: AppColores.textoSecundario(context)),
          const SizedBox(width: AppEspacio.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(etiqueta, style: AppTexto.metadato),
                Text(valor, style: AppTexto.cuerpo),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 1.25 T117 (F1-77): el método con su icono y su nombre
  /// completo, con jerarquía propia (antes iba como un
  /// paréntesis en crudo bajo el monto: «(efectivo)»).
  Widget _filaMetodo() {
    final esTransf = metodoPago == 'transferencia';
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(
            esTransf
                ? Icons.smartphone_rounded
                : Icons.payments_rounded,
            size: 18,
            color: AppColores.naranja),
        const SizedBox(width: AppEspacio.xs),
        Text(
          esTransf
              ? 'Transferencia'
              : metodoPago == 'efectivo'
                  ? 'Efectivo'
                  : metodoPago,
          style: AppTexto.cuerpo,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadio.xl),
      ),
      title: Text(
          esCasa
              ? 'Confirmar Cuenta a la Casa'
              : 'Confirmar inscripción',
          style: AppTexto.titulo, textAlign: TextAlign.center),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _cabecera(),
            const SizedBox(height: AppEspacio.md),
            if (esCasa) ...[
              // F1-78: la Casa no cobra: su «monto» es la propia
              // condición, en su color dorado de siempre.
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppEspacio.md,
                  vertical: AppEspacio.sm,
                ),
                decoration: BoxDecoration(
                  color: AppColores.casaFondo,
                  borderRadius:
                      BorderRadius.circular(AppRadio.lg),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.home_rounded,
                        size: 20, color: AppColores.casaIcono),
                    const SizedBox(width: AppEspacio.sm),
                    Text(
                      'Sin cobro · Sin vencimiento',
                      style: AppTexto.cuerpo.copyWith(
                        color: AppColores.casaTexto,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ] else ...[
              // Monto protagonista.
              Text(
                montoTxt,
                textAlign: TextAlign.center,
                style: AppTexto.display.copyWith(
                  color: AppColores.naranja,
                ),
              ),
              // F1-80: el desglose del monto, si lo hay.
              if (desgloseTxt != null)
                Text(
                  desgloseTxt!,
                  style: AppTexto.secundario,
                ),
              // F1-77: método con icono y nombre completo.
              _filaMetodo(),
            ],
            const SizedBox(height: AppEspacio.md),
            Divider(color: AppColores.borde(context), height: 1),
            const SizedBox(height: AppEspacio.sm),
            _filaDato(context, Icons.person_rounded, 'Nombre', nombre),
            if (!esCasa)
              _filaDato(context, Icons.calendar_month_rounded,
                  'Período', periodoEtiqueta),
            if (carnet.isNotEmpty)
              _filaDato(context, Icons.badge_rounded, 'Carnet', carnet),
            if (telefono.isNotEmpty)
              _filaDato(context, Icons.phone_rounded, 'Teléfono',
                  formatoTelefonoPresentacion(telefono)),
            if (esCasa && sexo.isNotEmpty)
              _filaDato(context, Icons.person_rounded, 'Sexo', sexo),
            // Vigencia como pastilla (la Casa no tiene).
            if (!esCasa)
            Padding(
              padding:
                  const EdgeInsets.symmetric(vertical: AppEspacio.sm),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.check_circle_rounded,
                      size: 22,
                      color: AppColores.textoSecundario(context)),
                  const SizedBox(width: AppEspacio.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Vigencia', style: AppTexto.metadato),
                        const SizedBox(height: 2),
                        Row(
                          children: [
                            // F1-80: la pastilla va en Flexible:
                            // con letra grande ya no desborda.
                            Flexible(
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: AppEspacio.md,
                                  vertical: AppEspacio.xs,
                                ),
                                decoration: BoxDecoration(
                                  color: AppColores.exito
                                      .withValues(alpha: 0.15),
                                  borderRadius: BorderRadius.circular(
                                      AppRadio.lg),
                                ),
                                child: Text(
                                  'Válido hasta $validoHastaTxt',
                                  style: AppTexto.cuerpo.copyWith(
                                    color: AppColores.exito,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                        // F1-80: desde cuándo corre la vigencia.
                        if (desdeTxt != null) ...[
                          const SizedBox(height: 2),
                          Text(desdeTxt!,
                              style: AppTexto.secundario),
                        ],
                      ],
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
    String periodoEtiqueta = '',
    String montoTxt = '',
    String metodoPago = '',
    String validoHastaTxt = '',
    String telefono = '',
    String carnet = '',
    String? fotoPath,
    bool esCasa = false,
    String sexo = '',
    String? desgloseTxt,
    String? desdeTxt,
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
        esCasa: esCasa,
        sexo: sexo,
        desgloseTxt: desgloseTxt,
        desdeTxt: desdeTxt,
      ),
    );
    return ok == true;
  }
}
