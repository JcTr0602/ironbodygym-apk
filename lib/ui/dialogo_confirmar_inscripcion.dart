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

  /// Alto ÚNICO de cabecera con y sin foto (1.36 H-B3 136-713:
  /// antes la foto sumaba padding+borde ≈84 px frente a 72 del
  /// check y el contenido saltaba según hubiera foto).
  static const double _altoCabecera = 78;

  /// Círculo con check (fallback sin foto). 1.36 H-B3
  /// (136-713): el color sigue al modo — dorado en Cuenta a la
  /// Casa, naranja en la inscripción normal (antes el fallback
  /// era siempre naranja aunque el anillo pidiera dorado).
  Widget _iconoCheck() {
    return Container(
      width: _altoCabecera,
      height: _altoCabecera,
      decoration: BoxDecoration(
        color: esCasa ? AppColores.casaIcono : AppColores.naranja,
        shape: BoxShape.circle,
      ),
      child: Icon(Icons.check_rounded,
          color: esCasa ? Colors.white : AppColores.sobreMarca, size: 40),
    );
  }

  /// Cabecera: foto del cliente o check si no hay foto / falla.
  /// 1.25 T64: entra con la micro-animación de escala del
  /// recibo (celebración contenida) y la foto lleva el
  /// ANILLO del color del estado: dorado en Cuenta a la
  /// Casa, naranja en la inscripción normal.
  Widget _cabecera(BuildContext context) {
    final colorAnillo =
        esCasa ? AppColores.casaIcono : AppColores.naranja;
    final hayFoto = fotoPath != null && fotoPath!.isNotEmpty;
    Widget interior;
    if (!hayFoto) {
      interior = _iconoCheck();
    } else {
      interior = Container(
        width: _altoCabecera,
        height: _altoCabecera,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: colorAnillo, width: 3),
        ),
        child: ClipOval(
          child: Image.file(
            File(fotoPath!),
            width: _altoCabecera,
            height: _altoCabecera,
            fit: BoxFit.cover,
            // Argón: decodificar solo miniatura ligera (la foto de cámara
            // tiene resolución nativa de varios MB).
            cacheWidth: 216,
            errorBuilder: (_, __, ___) => _iconoCheck(),
          ),
        ),
      );
    }
    // 1.36 H-B3 (136-713): semántica en foto/check y sin doble
    // escala — con «Reducir movimiento» no hay tween (la
    // entrada de showDialog ya anima la aparición).
    final conSemantica = Semantics(
      image: hayFoto,
      label: hayFoto ? 'Foto de $nombre' : 'Inscripción lista para confirmar',
      child: interior,
    );
    if (MediaQuery.of(context).disableAnimations) return conSemantica;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.85, end: 1.0),
      duration: AppMovimiento.larga,
      curve: AppMovimiento.curvaPop,
      builder: (context, escala, hijo) =>
          Transform.scale(scale: escala, child: hijo),
      child: conSemantica,
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
  /// Etiqueta legible del método (1.36 H-B3 136-713): el
  /// código crudo no se pinta; un código desconocido se
  /// presenta capitalizado y vacío = sin fila.
  static String etiquetaMetodoInscripcion(String metodo) {
    switch (metodo.trim().toLowerCase()) {
      case 'efectivo':
        return 'Efectivo';
      case 'transferencia':
        return 'Transferencia';
      case '':
        return '';
      default:
        final m = metodo.trim();
        return m[0].toUpperCase() + m.substring(1);
    }
  }

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
          etiquetaMetodoInscripcion(metodoPago),
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
            _cabecera(context),
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
              // 1.36 H-B3 (136-713): filas y pastillas SIN
              // dato no se pintan (fuera «Válido hasta » vacío,
              // icono de método sin texto, desglose en blanco).
              if (desgloseTxt != null && desgloseTxt!.trim().isNotEmpty)
                Text(
                  desgloseTxt!,
                  style: AppTexto.secundario,
                ),
              // F1-77: método con icono y nombre completo.
              if (metodoPago.trim().isNotEmpty) _filaMetodo(),
            ],
            const SizedBox(height: AppEspacio.md),
            Divider(color: AppColores.borde(context), height: 1),
            const SizedBox(height: AppEspacio.sm),
            _filaDato(context, Icons.person_rounded, 'Nombre', nombre),
            if (!esCasa && periodoEtiqueta.trim().isNotEmpty)
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
            // 1.36 H-B3 (136-713): sin fecha no hay pastilla.
            if (!esCasa && validoHastaTxt.trim().isNotEmpty)
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
            // Sobre la marca manda el token (el blanco da
            // 2,75:1 sobre el naranja; sobreMarca 6,32:1).
            foregroundColor: AppColores.sobreMarca,
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
