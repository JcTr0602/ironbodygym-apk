/// SL-3 · G01-2 — la atención del dueño no se apaga en
/// silencio si fallan sus consultas.
///
/// Re-ubicación por nombre contra ead3d63: el bloque del
/// Panel (panel_dueno_atencion.dart) YA declara «sin cargar»
/// vía BandejaSwr cuando su consulta falla. El tragado vivo
/// está en la señal de la Home (home.dart,
/// _cargarAtencionDueno): las dos mismas consultas
/// (solicitudes de inscripción de invitados y reportes App
/// Plus) iban con `catch (_) {}` dejando el conteo en 0, y
/// como la señal solo se pinta con total > 0, el fallo era
/// invisible — el cero se afirmaba sin lectura buena.
///
/// Corregido: SenalAtencion lleva el «sin verificar» POR
/// consulta; el cero solo se afirma con lectura buena, y la
/// Home pinta el aviso (key home-atencion-sin-verificar).
///
/// Camino real del widget: sesión de dueño contra el
/// servidor muerto del arnés (127.0.0.1:9) — ambas RPC
/// lanzan — y la cáscara debe nombrar el «sin verificar».
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/home.dart';

import 'jornada_ayudas.dart';

void main() {
  group('SenalAtencion · sin verificar por consulta', () {
    test('lectura buena en cero: se afirma el cero, sin aviso', () {
      const s = SenalAtencion();
      expect(s.total, 0);
      expect(s.sinVerificar, isFalse);
      expect(s.textoSinVerificar, isEmpty);
    });

    test('una consulta fallida marca SOLO su «sin verificar»', () {
      const s = SenalAtencion(solicitudesSinVerificar: true);
      expect(s.sinVerificar, isTrue);
      expect(s.textoSinVerificar, contains('inscripciones'));
      expect(s.textoSinVerificar, isNot(contains('Plus')));
    });

    test('ambas fallidas: el texto nombra las dos', () {
      const s = SenalAtencion(
          solicitudesSinVerificar: true, reportesSinVerificar: true);
      expect(s.textoSinVerificar, contains('inscripciones'));
      expect(s.textoSinVerificar, contains('Plus'));
    });

    test('el fallo no inventa conteo: el total sigue siendo '
        'el de las lecturas buenas', () {
      const s = SenalAtencion(
          solicitudes: 2,
          solicitudesSinVerificar: false,
          reportesSinVerificar: true);
      expect(s.total, 2);
      expect(s.sinVerificar, isTrue);
    });
  });

  group('Home del dueño con las consultas lanzando', () {
    TestWidgetsFlutterBinding.ensureInitialized();

    setUpAll(() async {
      await jornadaSetUpAll();
      await jornadaCargarRoboto();
    });

    testWidgets('la cáscara pinta «sin verificar», no un cero '
        'en silencio', (tester) async {
      await jornadaPreparar(tester);
      await jornadaSesionDueno(tester);
      await jornadaMontarHome(tester);
      // El segundo pase (RPC contra el servidor muerto) debe
      // haber resuelto ya con el drenaje de montar la Home;
      // un drenaje extra por si la RPC tarda en fallar.
      await jornadaDrenar(tester, vueltas: 8, ms: 120);
      expect(
          find.byKey(const ValueKey('home-atencion-sin-verificar')),
          findsOneWidget,
          reason: 'G01-2: con las consultas de atención '
              'fallidas, la Home dice «sin verificar» en vez '
              'de apagar la señal en cero');
      expect(find.textContaining('sin verificar'), findsWidgets);
      await jornadaCerrarCascara(tester);
    });
  });
}
