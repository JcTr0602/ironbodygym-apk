// 1.35 (SP-02): contrato de códigos de error de corrida.
//
// En la 1.34 el código `presupuesto_agotado` nació con su
// frase humana y su persistencia en el motor, pero sin
// registrarse en codigosErrorSyncConocidos: detalle() lo
// trataba como «mensaje humano legado» y el panel pintaba el
// código crudo en la banda de error. Sin un contrato, el
// próximo código nuevo repetirá el bug.
//
// El contrato recorre TODOS los códigos que el motor puede
// persistir en `last_sync_error`:
//  - los literales `codigo: '...'` de lib/sync.dart (los
//    desenlaces que fija el motor), y
//  - los literales `codigo: '...'` de lib/errores_sync.dart
//    (las salidas del clasificador traducirErrorSync),
// y exige para cada uno:
//  1. que esté registrado en codigosErrorSyncConocidos
//     (esCodigoErrorSync), y
//  2. que tenga frase: completa propia o causa corta real
//     (el texto compuesto no puede caer en el genérico
//     «hubo un problema al sincronizar»; única excepción:
//     'desconocido', cuyo significado ES ese).
// Y a la inversa: ningún código registrado puede quedar sin
// frase.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/errores_sync.dart';

Set<String> _codigosLiterales(String ruta) {
  final src = File(ruta).readAsStringSync();
  return RegExp(r"codigo: '([a-z_]+)'")
      .allMatches(src)
      .map((m) => m.group(1)!)
      .toSet();
}

bool _tieneFrase(String codigo) {
  if (codigoErrorSyncConFraseCompleta(codigo)) return true;
  final texto = textoErrorCorridaPersistido(codigo: codigo, pierna: 'ciclo');
  return !texto.contains('hubo un problema al sincronizar');
}

void main() {
  test('SP-02: todo código persistible está registrado y tiene frase',
      () {
    final delMotor = _codigosLiterales('lib/sync.dart');
    final delClasificador = _codigosLiterales('lib/errores_sync.dart');
    // Sanidad del propio contrato: el inventario no es vacío
    // y contiene los desenlaces conocidos del motor.
    expect(delMotor, containsAll(<String>{
      'sesion_invalida',
      'espejo_vacio',
      'tabla_caida',
      'descarga_incidencias',
      'bajada_incompleta',
      'subida_incompleta',
      'servidor_no_responde',
      'presupuesto_agotado',
    }));
    expect(delClasificador, isNotEmpty);

    for (final codigo in {...delMotor, ...delClasificador}) {
      expect(esCodigoErrorSync(codigo), isTrue,
          reason: 'el código $codigo se puede persistir pero no '
              'está en codigosErrorSyncConocidos: la pantalla lo '
              'pintaría crudo');
      if (codigo == 'desconocido') continue;
      expect(_tieneFrase(codigo), isTrue,
          reason: 'el código $codigo no tiene frase completa ni '
              'causa corta: se pintaría el genérico');
    }
  });

  test('SP-02: ningún código registrado queda sin frase', () {
    for (final codigo in codigosErrorSyncConocidos) {
      if (codigo == 'desconocido') continue;
      expect(_tieneFrase(codigo), isTrue,
          reason: 'el código registrado $codigo no tiene frase');
    }
  });

  test('SP-02: presupuesto_agotado compone su frase humana', () {
    expect(esCodigoErrorSync('presupuesto_agotado'), isTrue);
    final texto =
        textoErrorCorridaPersistido(codigo: 'presupuesto_agotado', pierna: 'ciclo');
    expect(texto, contains('presupuesto de tiempo y red'));
    expect(texto, isNot(contains('presupuesto_agotado')));
  });
}
