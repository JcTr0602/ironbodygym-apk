/// UI136-13 (adjudicación ARGON-136-UI, nota aparte): la
/// foto de cierre de nómina rotulaba con el mes del RELOJ
/// aunque los datos eran los del mes CARGADO — el comentario
/// del código afirmaba lo contrario de lo que el código
/// hacía. La pantalla abierta antes de la medianoche del
/// cambio de mes y la foto generada después salía con los
/// datos del mes saliente rotulados con el entrante.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('UI136-13 · la foto usa el mes cargado, no el reloj', () {
    final s = File('lib/ui/nomina.dart').readAsStringSync();
    // El campo existe y _cargarDatos lo fija con SU pref.
    expect(s.contains('String _prefCargado'), isTrue);
    final iCarga = s.indexOf('Future<void> _cargarDatos(');
    final carga = s.substring(iCarga, iCarga + 600);
    expect(carga.contains('_prefCargado = pref;'), isTrue);
    // _mostrarFotoCierre consume el campo, con el reloj
    // solo de reserva si aún no cargó nada.
    final iFoto = s.indexOf('Future<void> _mostrarFotoCierre(');
    final foto = s.substring(iFoto, iFoto + 3400);
    expect(foto.contains('_prefCargado.isNotEmpty'), isTrue);
    expect(
        RegExp(r'snapshotNomina\(\s*prefFoto').hasMatch(foto), isTrue,
        reason: 'la foto y su snapshot comparten el mes');
    // Los otros dos usos del reloj (líneas de guardado)
    // NO son la foto: quedan fuera de esta fila.
  });
}
