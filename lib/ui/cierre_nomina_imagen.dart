/// 1.28 (M3-C3): la foto del cierre de nómina como imagen
/// con marca, para compartir. Es un resumen FIJO (fondo
/// oscuro de marca, se comparta en claro o en oscuro): la
/// cabecera lleva el logo y el wordmark de Iron Body, cada
/// entrenador su desglose y el total a pagar del mes. Los
/// números llegan YA calculados de la foto única de la
/// pantalla de Nómina (misma fuente que pinta la pantalla):
/// esta imagen no recalcula nada por su cuenta.
library;

import 'package:flutter/material.dart';

import '../negocio.dart' show fmtMonto;
import 'diseno.dart' show AppRadio;

/// Una fila de la foto: el desglose de un entrenador.
class FilaCierreNomina {
  const FilaCierreNomina({
    required this.nombre,
    required this.base,
    required this.bono,
    required this.comision,
    required this.adelantos,
    required this.deuda,
    required this.neto,
    required this.liquidada,
  });

  final String nombre;
  final double base;
  final double bono;
  final double comision;
  final double adelantos;
  final double deuda;
  final double neto;
  final bool liquidada;
}

/// Yunque R5-M8-2: el total «A PAGAR» de la imagen excluye
/// a los ya liquidados (su neto ya se pagó). PURO.
double totalAPagarCierre(List<FilaCierreNomina> filas) =>
    filas.fold<double>(0, (s, f) => s + (f.liquidada ? 0 : f.neto));

class ImagenCierreNomina extends StatelessWidget {
  const ImagenCierreNomina({
    super.key,
    required this.mesEtiqueta,
    required this.filas,
    required this.generadoEtiqueta,
  });

  /// 'Octubre de 2026'.
  final String mesEtiqueta;
  final List<FilaCierreNomina> filas;

  /// 'Generada el 31 de octubre de 2026'.
  final String generadoEtiqueta;

  static const _fondo = Color(0xFF1C1C1F);
  static const _naranja = Color(0xFFFF6B00);
  static const _textoSuave = Color(0xFFB9B9BE);

  @override
  Widget build(BuildContext context) {
    // Yunque R5-M8-2: «TOTAL A PAGAR» suma solo a quien NO
    // está liquidado (ya cobró: no es «a pagar»), el mismo
    // criterio que netoTotalDueno de la foto de nómina.
    final total = totalAPagarCierre(filas);
    return Container(
      width: 340,
      decoration: BoxDecoration(
        color: _fondo,
        borderRadius: BorderRadius.circular(AppRadio.lg),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Cabecera con la marca: logo + wordmark + mes.
          Container(
            padding: const EdgeInsets.all(16),
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [Color(0xFFFF6B00), Color(0xFF9A3E00)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius:
                  BorderRadius.vertical(top: Radius.circular(16)),
            ),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Image.asset(
                    'assets/logo.jpg',
                    width: 46,
                    height: 46,
                    fit: BoxFit.cover,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'IRON BODY GYM',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 17,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.6,
                        ),
                      ),
                      Text(
                        'Cierre de nómina · $mesEtiqueta',
                        style: const TextStyle(
                          color: Color(0xFFFFE3CC),
                          fontSize: 12.5,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < filas.length; i++) ...[
                  if (i > 0)
                    const Divider(color: Color(0xFF333338), height: 22),
                  _bloque(filas[i]),
                ],
                const Divider(color: Color(0xFF333338), height: 26),
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'TOTAL A PAGAR',
                        style: TextStyle(
                          color: _textoSuave,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.8,
                        ),
                      ),
                    ),
                    Text(
                      '${fmtMonto(total)} CUP',
                      style: const TextStyle(
                        color: _naranja,
                        fontSize: 21,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  generadoEtiqueta,
                  style: const TextStyle(
                      color: Color(0xFF7A7A80), fontSize: 11),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _bloque(FilaCierreNomina f) {
    final detalle = <String>[
      'Base ${fmtMonto(f.base)}',
      if (f.bono != 0) 'Bono ${fmtMonto(f.bono)}',
      if (f.comision != 0) 'Comisión ${fmtMonto(f.comision)}',
      if (f.adelantos != 0) 'Adelantos −${fmtMonto(f.adelantos)}',
      if (f.deuda != 0) 'Deuda −${fmtMonto(f.deuda)}',
    ].join(' · ');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                f.nombre,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            Text(
              f.liquidada ? '✓ Liquidada' : 'Sin liquidar',
              style: TextStyle(
                color: f.liquidada
                    ? const Color(0xFF4ADE80)
                    : const Color(0xFFFBBF24),
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        const SizedBox(height: 3),
        Text(
          detalle,
          style: const TextStyle(color: _textoSuave, fontSize: 12.5),
        ),
        const SizedBox(height: 5),
        Text(
          'Neto: ${fmtMonto(f.neto)} CUP',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 15,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}
