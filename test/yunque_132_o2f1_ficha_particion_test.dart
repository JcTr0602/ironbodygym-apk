/// 1.32 (Oleada 2, Fase 1 — desviación 2 de Argón): la
/// partición de la ficha en 3 pestañas tras la corrección.
///
/// Se prueba el clasificador puro de secciones
/// (pestanaDeSeccionFicha, el mismo que usa el build para
/// repartir) sobre las piezas de la desviación:
/// - La galería de Fotos de Progreso (G-23,
///   SeccionFotosProgresoNube) va a «Progreso y Marcas» (1):
///   es sección propia tras las medidas en _seccionesCrudas.
/// - La Foto Personal (avatar) se queda en «Pagos y Notas»
///   (0), junto a «Información personal».
/// - G-17 (Notas) vive en «Pagos y Notas» (0): la fila Notas
///   es parte de la tarjeta «Información personal», que el
///   clasificador manda a la 0.
/// - Vecinos intactos: TarjetaMedidas → 1, la tarjeta de
///   «Marcas en la app» → 1, SeccionAccesoAppFicha → 2.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/componentes.dart';
import 'package:ironbody_gym/ui/ficha.dart';
import 'package:ironbody_gym/ui/ficha_acceso_app.dart';
import 'package:ironbody_gym/ui/foto_personal_ficha.dart';
import 'package:ironbody_gym/ui/fotos_progreso_nube_ficha.dart';
import 'package:ironbody_gym/ui/medidas_cliente.dart';

void main() {
  group('partición de la ficha (Oleada 2 F1)', () {
    test('G-23: la galería de progreso va a Progreso y Marcas',
        () {
      expect(
          pestanaDeSeccionFicha(
              const SeccionFotosProgresoNube(clienteId: 7)),
          1);
    });

    test('la foto personal se queda en Pagos y Notas', () {
      expect(
          pestanaDeSeccionFicha(
              const SeccionFotoPersonal(clienteId: 7)),
          0);
    });

    test('G-17: la tarjeta «Información personal» (con su '
        'fila Notas) va a Pagos y Notas', () {
      const tarjeta = Tarjeta(
        child: Column(
          children: [
            Text('Información personal'),
            Row(children: [Text('Notas'), Text('Toca para agregar…')]),
          ],
        ),
      );
      expect(pestanaDeSeccionFicha(tarjeta), 0);
    });

    test('vecinos: medidas y marcas a Progreso; acceso a App',
        () {
      expect(
          pestanaDeSeccionFicha(const TarjetaMedidas(clienteId: 7)),
          1);
      const marcas = Tarjeta(
        child: Column(children: [Text('Marcas en la app')]),
      );
      expect(pestanaDeSeccionFicha(marcas), 1);
      expect(
          pestanaDeSeccionFicha(const SeccionAccesoAppFicha(
              clienteId: 7,
              nombreCliente: 'X',
              telefonoEfectivoWa: '')),
          2);
    });
  });
}
