// 1.35 (SP-10): «Sincronizar ahora» significa lo mismo
// en la Cola y en el Centro de sincronización.
//
// En la base, el botón del Centro corría
// SyncEngine.instance.run() SIN forzar (respetaba el
// backoff: podía no hacer nada) y en silencio, mientras
// el de la Cola forzaba y enseñaba el resumen del
// desenlace. Este contrato fija en la fuente que ambas
// superficies llaman al motor con forzar: true y que el
// Centro enseña el resumen (resumenCorto del resultado).
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('SP-10: el Centro sincroniza forzado y con resumen', () {
    final centro = File('lib/ui/centro_sync.dart').readAsStringSync();
    expect(centro.contains('run(forzar: true)'), isTrue,
        reason: 'el «Sincronizar ahora» del Centro debe '
            'forzar igual que el de la Cola');
    expect(centro.contains('instance.run()'), isFalse,
        reason: 'no debe quedar ninguna llamada al motor '
            'sin forzar en el Centro');
    expect(centro.contains('resumenCorto'), isTrue,
        reason: 'el Centro enseña el mismo veredicto de '
            'desenlace que la Cola');
    expect(centro.contains('_mostrarResumenSync'), isTrue);
  });

  test('SP-10: la Cola sigue forzando (la referencia)', () {
    final cola = File('lib/ui/cola.dart').readAsStringSync();
    expect(cola.contains('forzar: true'), isTrue);
  });
}
