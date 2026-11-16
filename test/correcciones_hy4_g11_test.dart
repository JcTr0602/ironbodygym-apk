/// Correcciones Hy4 — G#11: la foto de nómina construía el
/// mapa de personas de adelantos con un cast duro
/// `(m['telegram_id'] as num?)`: si el telegram_id de UNA
/// fila de usuarios_apk venía en TEXTO (forma documentada
/// en fixtures del repo), el cast lanzaba ANTES del
/// `int.tryParse` de respaldo y el try que envuelve el
/// bucle entero descartaba a esa persona Y A TODAS LAS
/// SIGUIENTES del mapa: sus adelantos desaparecían de la
/// foto de nómina.
///
/// Camino real: `fotoNominaMes` (la misma foto que pinta
/// la pantalla de Nómina) con usuarios_apk sembrado: la
/// primera fila trae el telegram_id en texto y Gabriel,
/// la segunda, debe conservar su adelanto en el libro.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/adelantos.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/nomina_foto.dart';
import 'package:ironbody_gym/tiempo.dart';

import 'jornada_ayudas.dart';

const _gabrielId = '00000000-0000-0000-0000-0000000000e7';

void main() {
  setUpAll(() async {
    await jornadaSetUpAll();
    await jornadaCargarRoboto();
  });

  testWidgets('G#11: un telegram_id en texto no expulsa '
      'a los siguientes del mapa de adelantos', (tester) async {
    await jornadaPreparar(tester);
    await jornadaSesionDueno(tester);

    // usuarios_apk: PRIMERO Duany con el telegram_id en
    // TEXTO (su clave sí resuelve: la fila llega al cast);
    // DESPUÉS Gabriel con el suyo numérico.
    await LocalDb.instance.setMeta(
        'usuarios_apk',
        jsonEncode([
          {
            'id': '00000000-0000-0000-0000-0000000000e8',
            'telegram_id': '969869611',
            'nombre': 'Duany',
            'username': 'duany',
          },
          {
            'id': _gabrielId,
            'telegram_id': 1403501391,
            'nombre': 'Gabriel',
            'username': 'gabriel',
          },
        ]));
    // Base de Gabriel: 4 clientes pagaron el mes (4×150).
    final hoy = hoyHabanaIso();
    for (var i = 0; i < 4; i++) {
      await LocalDb.instance.upsertMirror('pagos', 100 + i, {
        'id': 100 + i,
        'cliente_id': 20 + i,
        'fecha': hoy,
        'monto': 2000,
        'metodo': 'efectivo',
        'entrenador': 1403501391,
        'nombre_entrenador': 'Gabriel',
      }, 1);
    }
    await AdelantosService.instance.registrar(
      entrenadorId: _gabrielId,
      entrenadorNombre: 'Gabriel',
      entrenadorTelegramId: 1403501391,
      monto: 500,
      fecha: ahoraHabana(),
      metodo: 'efectivo',
      origen: 'caja_turno',
      descuentaA: 1403501391,
    );

    final pref = hoyHabanaIso().substring(0, 7);
    final foto = await fotoNominaMes(pref);
    final libro = foto.libroMes['gabriel'];
    expect(libro, isNotNull,
        reason: 'Gabriel no puede salir del mapa por la '
            'fila en texto que va delante de él');
    expect(libro!.adelantos, 500,
        reason: 'su adelanto sigue en la foto de nómina');
    expect(libro.bruto, 600);
    await jornadaCerrarCascara(tester);
  });
}
