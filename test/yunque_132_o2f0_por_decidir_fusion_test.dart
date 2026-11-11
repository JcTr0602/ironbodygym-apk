/// 1.32 (Oleada 2, Fase 0): la fusión POR FUENTE de la
/// foto de «Por Decidir» — refinamiento del Defecto 1 de
/// la Oleada 1 que exige el veredicto de g132dis_.
///
/// La regla: cada fuente conserva SU último valor
/// verificado en la foto persistida hasta que ESA fuente
/// vuelva a verificar. Un éxito parcial (1 de 4) actualiza
/// esa 1 y jamás machaca las otras 3 con null/0; y con 0
/// verificadas la foto no se renueva NI en valores NI en
/// hora (una hora fresca sobre una foto vieja fingiría
/// una verificación que no ocurrió).
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/por_decidir.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _kFoto = 'pordecidir_foto_remota_v1';

Widget _envolver(BandejaPorDecidir b) => MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: b)),
    );

BandejaPorDecidir _bandeja({
  required Future<ConteosRemotosPorDecidir> Function() remotas,
}) {
  return BandejaPorDecidir(
    incidencias: 0,
    rellenos: 0,
    adelantos: 0,
    onIr: (_) {},
    cargarRemotas: remotas,
    cargarCongelaciones: () async => (ok: true, pendientes: 0),
    cargarArqueos: () async => const [],
  );
}

/// Siembra una foto previa con hora CONOCIDA (2026-11-01
/// 08:00 habanera) escribiendo el JSON tal como lo lee
/// leerFotoPorDecidir.
Future<void> _sembrarFotoPrevia() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(
    _kFoto,
    jsonEncode({
      'v': 3,
      'p': 2,
      'c': 1,
      's': 4,
      'ts': '2026-11-01T08:00:00.000-05:00',
    }),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('fusionarFotoPorDecidir (puro)', () {
    test('1 de 4 verifica: actualiza la suya y conserva las otras 3',
        () {
      final f = fusionarFotoPorDecidir(
        const ConteosRemotosPorDecidir(
            vales: 3, plus: 2, comunidad: 1, solicitudes: 4),
        const ConteosRemotosPorDecidir(vales: 9),
      );
      expect(f.verificadoAhora, isTrue);
      expect(f.conteos.vales, 9);
      expect(f.conteos.plus, 2);
      expect(f.conteos.comunidad, 1);
      expect(f.conteos.solicitudes, 4);
    });

    test('0 de 4 verifican: la foto queda intacta y NO hay renovación',
        () {
      const previa = ConteosRemotosPorDecidir(
          vales: 3, plus: 2, comunidad: 1, solicitudes: 4);
      final f =
          fusionarFotoPorDecidir(previa, const ConteosRemotosPorDecidir());
      expect(f.verificadoAhora, isFalse);
      expect(f.conteos.vales, previa.vales);
      expect(f.conteos.plus, previa.plus);
      expect(f.conteos.comunidad, previa.comunidad);
      expect(f.conteos.solicitudes, previa.solicitudes);
    });

    test('sin foto previa, lo verificado nace y lo demás queda null',
        () {
      final f = fusionarFotoPorDecidir(
          null, const ConteosRemotosPorDecidir(plus: 0));
      expect(f.verificadoAhora, isTrue);
      expect(f.conteos.plus, 0);
      expect(f.conteos.vales, isNull);
      expect(f.conteos.comunidad, isNull);
      expect(f.conteos.solicitudes, isNull);
    });

    test('sin foto previa y nada verificado: todo null, sin renovación',
        () {
      final f =
          fusionarFotoPorDecidir(null, const ConteosRemotosPorDecidir());
      expect(f.verificadoAhora, isFalse);
      expect(f.conteos.todasVerificadas, isFalse);
      expect(f.conteos.sumaVerificada, 0);
    });
  });

  group('BandejaPorDecidir con foto previa (widget)', () {
    testWidgets(
        'éxito parcial: la persistida fusiona por fuente y la UI '
        'suma foto + fresco sin afirmar ceros ajenos', (tester) async {
      await _sembrarFotoPrevia();
      await tester.pumpWidget(_envolver(_bandeja(
        remotas: () async => const ConteosRemotosPorDecidir(vales: 9),
      )));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // La foto persistida: vales nuevo (9) y las otras 3
      // con SU último verificado (2, 1, 4) — nada a null/0.
      final foto = await leerFotoPorDecidir();
      expect(foto, isNotNull);
      expect(foto!.conteos.vales, 9);
      expect(foto.conteos.plus, 2);
      expect(foto.conteos.comunidad, 1);
      expect(foto.conteos.solicitudes, 4);

      // La UI: el titular suma lo efectivo (9+2+1+4) y no
      // dice «Todo al día» (no todo verificó ahora).
      expect(find.text('16 decisiones pendientes'), findsOneWidget);
      expect(find.textContaining('Todo al día'), findsNothing);
      // Las no verificadas se presentan como foto, no como 0.
      expect(find.text('2 · foto'), findsOneWidget);
      expect(find.text('1 · foto'), findsOneWidget);
      expect(find.text('4 · foto'), findsOneWidget);
    });

    testWidgets(
        'todo cae: la foto persistida no se toca NI en valores NI en hora',
        (tester) async {
      await _sembrarFotoPrevia();
      final prefs = await SharedPreferences.getInstance();
      final antes = prefs.getString(_kFoto);
      await tester.pumpWidget(_envolver(_bandeja(
        remotas: () async => const ConteosRemotosPorDecidir(),
      )));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // Ni un solo reguardado: el JSON persistido es el
      // mismo, con su hora vieja intacta (el instante es
      // el sembrado, se compare en la zona que se compare).
      expect(prefs.getString(_kFoto), antes);
      final foto = await leerFotoPorDecidir();
      expect(foto!.conteos.vales, 3);
      final instanteSembrado =
          DateTime.parse('2026-11-01T08:00:00.000-05:00');
      expect(
          foto.hora.isAtSameMomentAs(instanteSembrado), isTrue);
      // Y la UI lo dice con la hora de ESA foto, no con la
      // de ahora: el pie reza «última foto de las HH:MM»
      // con la hora local de la foto leída.
      final hhmm =
          '${foto.hora.hour.toString().padLeft(2, '0')}:'
          '${foto.hora.minute.toString().padLeft(2, '0')}';
      expect(find.textContaining('última foto de las $hhmm'),
          findsOneWidget);
      expect(find.textContaining('Todo al día'), findsNothing);
    });
  });
}
