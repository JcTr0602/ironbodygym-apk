/// Gestión 1.28 — Oleada M4-BC (Bloques B y C del estudio
/// M4: Clientes, ficha y acceso).
///
/// - B3: deltasUltimaMedicion y serieMedicion (puros) —
///   la evolución de medidas de la ficha.
/// - B4: pendientesDeFicha (puro) — «qué le falta» a un
///   cliente; el acceso no verificado NO se afirma.
/// - C5: agruparFotosPorMes (puro) — la galería de fotos
///   en la nube agrupa por mes, reciente primero, y las
///   sin fecha van al final.
/// - C2/C3 + ítem fijo: la ficha SIGUE perezosa tras los
///   ítems C (secciones fuera de pantalla no se
///   construyen) y la sección «Qué le falta» aparece con
///   sus chips para un cliente sin foto ni mediciones.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/mediciones_cliente.dart';
import 'package:ironbody_gym/ui/ficha.dart';
import 'package:ironbody_gym/ui/ficha_que_falta.dart';
import 'package:ironbody_gym/ui/fotos_progreso_nube_ficha.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  group('B4 — pendientesDeFicha (puro)', () {
    final hoy = DateTime(2026, 11, 7);

    test('cliente completo no tiene pendientes', () {
      expect(
        pendientesDeFicha(
          tieneFoto: true,
          telefonoValido: true,
          tieneAccesoApp: true,
          ultimaMedicionEn: DateTime(2026, 11, 1),
          hoy: hoy,
        ),
        isEmpty,
      );
    });

    test('sin foto, teléfono inválido y nunca medido', () {
      expect(
        pendientesDeFicha(
          tieneFoto: false,
          telefonoValido: false,
          tieneAccesoApp: null,
          ultimaMedicionEn: null,
          hoy: hoy,
        ),
        [
          PendienteFicha.sinFoto,
          PendienteFicha.telefonoInvalido,
          PendienteFicha.sinMedicionReciente,
        ],
      );
    });

    test('el acceso SOLO se afirma verificado en falso', () {
      // No verificado (null): el pendiente no aparece.
      expect(
        pendientesDeFicha(
          tieneFoto: true,
          telefonoValido: true,
          tieneAccesoApp: null,
          ultimaMedicionEn: hoy,
          hoy: hoy,
        ),
        isEmpty,
      );
      // Verificado sin acceso: aparece.
      expect(
        pendientesDeFicha(
          tieneFoto: true,
          telefonoValido: true,
          tieneAccesoApp: false,
          ultimaMedicionEn: hoy,
          hoy: hoy,
        ),
        [PendienteFicha.sinAccesoApp],
      );
    });

    test('la ventana de medición son 60 días de calendario', () {
      // 60 días exactos: aún no es pendiente.
      expect(
        pendientesDeFicha(
          tieneFoto: true,
          telefonoValido: true,
          tieneAccesoApp: true,
          ultimaMedicionEn: DateTime(2026, 9, 8),
          hoy: hoy,
        ),
        isEmpty,
      );
      // 61 días: pendiente.
      expect(
        pendientesDeFicha(
          tieneFoto: true,
          telefonoValido: true,
          tieneAccesoApp: true,
          ultimaMedicionEn: DateTime(2026, 9, 7),
          hoy: hoy,
        ),
        [PendienteFicha.sinMedicionReciente],
      );
    });
  });

  group('B3 — deltas y serie de mediciones (puros)', () {
    final mediciones = <Map<String, dynamic>>[
      {
        'fecha_medicion': '2026-11-01',
        'medidas': {'peso_kg': 82.5, 'cintura_cm': 90},
      },
      {
        'fecha_medicion': '2026-10-01',
        'medidas': {'peso_kg': 85.0, 'brazo_cm': 38},
      },
      {
        'fecha_medicion': '2026-09-01',
        'medidas': {'peso_kg': 86.0, 'cintura_cm': 95},
      },
    ];

    test('delta contra la anterior que trae ESA métrica', () {
      final d = deltasUltimaMedicion(mediciones);
      // peso: contra la fila de octubre (la inmediata).
      expect(d['peso_kg'], closeTo(-2.5, 1e-9));
      // cintura: octubre no la trae; contra septiembre.
      expect(d['cintura_cm'], closeTo(-5.0, 1e-9));
      // brazo no está en la última: no entra.
      expect(d.containsKey('brazo_cm'), isFalse);
    });

    test('sin anterior comparable no hay delta', () {
      expect(deltasUltimaMedicion([mediciones.first]), isEmpty);
      expect(deltasUltimaMedicion(const []), isEmpty);
    });

    test('la serie sale cronológica y solo con su métrica', () {
      final s = serieMedicion(mediciones, 'peso_kg');
      expect(s.map((e) => e.valor).toList(), [86.0, 85.0, 82.5]);
      final c = serieMedicion(mediciones, 'cintura_cm');
      expect(c.map((e) => e.valor).toList(), [95.0, 90.0]);
    });

    test('la serie ignora fechas que no parsean', () {
      final sucias = <Map<String, dynamic>>[
        {
          'fecha_medicion': 'no-es-fecha',
          'medidas': {'peso_kg': 80},
        },
        ...mediciones,
      ];
      expect(serieMedicion(sucias, 'peso_kg').length, 3);
    });
  });

  group('C5 — agruparFotosPorMes (puro)', () {
    test('agrupa por mes, reciente primero, sin fecha al final',
        () {
      final grupos = agruparFotosPorMes([
        {'id': 'a', 'fecha': '2026-10-03'},
        {'id': 'b', 'fecha': '2026-11-01'},
        {'id': 'c', 'fecha': '2026-10-20'},
        {'id': 'd', 'fecha': ''},
        {'id': 'e'},
      ]);
      expect(grupos.length, 3);
      expect(grupos[0].titulo, 'Noviembre 2026 · 1 foto');
      expect(grupos[0].fotos.single['id'], 'b');
      expect(grupos[1].titulo, 'Octubre 2026 · 2 fotos');
      // Dentro del mes se conserva el orden de llegada.
      expect(grupos[1].fotos.map((f) => f['id']).toList(),
          ['a', 'c']);
      expect(grupos[2].titulo, 'Sin fecha · 2 fotos');
    });

    test('lista vacía no produce grupos', () {
      expect(agruparFotosPorMes(const []), isEmpty);
    });
  });

  group('C2/C3 — la ficha sigue perezosa (widget)', () {
    setUpAll(() async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      SharedPreferences.setMockInitialValues({});
      await Supabase.initialize(
          url: 'http://127.0.0.1:9', anonKey: 'dummy');
    });

    setUp(() async {
      final dir = await getDatabasesPath();
      try {
        await File(p.join(dir, 'ironbody.db')).delete();
      } catch (_) {}
      await LocalDb.resetParaTest();
      await LocalDb.instance.db;
    });

    testWidgets(
        'secciones fuera de pantalla sin construir y la '
        'sección «Qué le falta» con sus chips', (tester) async {
      await tester.runAsync(() async {
        await LocalDb.instance.upsertMirror('clientes', 78, {
          'id': 78,
          'nombre': 'Cliente Oleada BC',
          'telefono': '58112233',
          'sexo': 'M',
          // Yunque 3.34 (K4-6): fuera 'fecha_nacimiento' —
          // la fila no la trae; el nacimiento se deriva del
          // carnet (lib/negocio.dart:4058). Inerte aquí:
          // las aserciones son de construcción perezosa.
          'pagado_hasta': '2027-01-01',
          'estado': 'activo',
        }, 1);
      });
      tester.view.physicalSize = const Size(500, 700);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
          const MaterialApp(home: FichaScreen(clienteId: 78)));
      await tester.pump(const Duration(milliseconds: 100));
      // Drenaje alternando bucle real y pump, como el
      // arnés de M4-A (los futuros de sqflite_ffi no
      // completan solo con pumps).
      for (var i = 0; i < 20; i++) {
        await tester.runAsync(() async {
          await Future<void>.delayed(
              const Duration(milliseconds: 250));
        });
        await tester.pump(const Duration(milliseconds: 60));
        if (find.text('Cliente Oleada BC').evaluate().isNotEmpty) {
          break;
        }
      }
      expect(find.text('Cliente Oleada BC'), findsWidgets);
      // Ítem fijo intacto tras C2/C3: el Historial (pagos)
      // está fuera de pantalla y NO se ha construido.
      expect(find.text('Historial'), findsNothing,
          reason: 'con ListView.builder la sección de pagos '
              'no se construye hasta hacer scroll');
      // B4: sin foto y sin mediciones, la sección de
      // pendientes aparece con sus dos chips (el teléfono
      // es válido y el acceso no se evalúa sin dueño).
      await tester.scrollUntilVisible(find.text('Qué le falta'), 250,
          scrollable: find.byType(Scrollable).first);
      await tester.pump();
      expect(find.text('Qué le falta'), findsOneWidget);
      expect(find.text('Sin foto'), findsOneWidget);
      expect(find.text('Sin mediciones'), findsOneWidget);
      expect(find.text('Sin acceso a la app'), findsNothing);
      // Drenaje final (temporizadores de timeout de RPC y
      // animaciones de entrada escalonadas).
      for (var i = 0; i < 4; i++) {
        await tester.runAsync(() async {
          await Future<void>.delayed(
              const Duration(milliseconds: 250));
        });
        await tester.pump(const Duration(milliseconds: 60));
      }
      await tester.pump(const Duration(seconds: 12));
    });
  });
}
