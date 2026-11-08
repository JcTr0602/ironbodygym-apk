/// Gestión 1.29 · Oleada propia D-22 — Editor de rutinas
/// del gym rehecho portando el editor de Clientes post-O2.
///
/// Contrato que se fija:
/// · La carga del catálogo es honesta: error propio con
///   reintento (nunca spinner eterno) y vacío SOLO cuando
///   la lectura OK devuelve cero, dicho como catálogo
///   vacío en el teléfono (nunca culpa del buscador).
/// · El selector busca por título + equipo + sinónimos +
///   músculo (sin acentos), filtra por grupo con chips,
///   conserva el orden de toque y distingue «catálogo
///   vacío» de «ninguna ficha coincide».
/// · Las series se ven sin expandir, con campos directos;
///   el tipo de serie lleva nombre completo y hoja
///   explicada; el descanso vacío significa «el de la
///   ficha» (el hint «Global si vacío» no existe: no hay
///   campo global en el formato ni en el formulario).
/// · Quitar un ejercicio ofrece «Deshacer»; reordenar es
///   por arrastre; los totales vivos usan la fórmula
///   portada (reps × 4 s, descanso efectivo).
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/editor_rutinas_gym.dart';

const _press = FichaCatalogo(
  id: 'banco-plano_press-banca-plano',
  titulo: 'Press banca plano',
  slug: 'press-banca-plano',
  equipoNombre: 'Banco plano',
  musculos: ['Pectoral mayor', 'Tríceps'],
  grupo: 'pecho',
  sinonimos: ['banca plana', 'press de pecho'],
  descansoSeg: 120,
);
const _sentadilla = FichaCatalogo(
  id: 'barra-recta_sentadilla',
  titulo: 'Sentadilla con barra',
  slug: 'sentadilla',
  equipoNombre: 'Barra recta',
  musculos: ['Cuádriceps', 'Glúteos'],
  grupo: 'piernas',
  descansoSeg: 180,
);
const _jalon = FichaCatalogo(
  id: 'polea_jalon-al-pecho',
  titulo: 'Jalón al pecho',
  slug: 'jalon-al-pecho',
  equipoNombre: 'Polea',
  musculos: ['Dorsal ancho'],
  grupo: 'espalda',
  sinonimos: ['jalón en polea'],
  descansoSeg: 90,
);
const _catalogo = [_press, _sentadilla, _jalon];

RutinaGymAdmin _rutinaDos() => RutinaGymAdmin(
      id: 7,
      nombre: 'Día A',
      fichaIds: [_press.id, _sentadilla.id],
      ejercicios: [
        EjercicioGymAdmin(fichaId: _press.id, series: const [
          SerieGymAdmin(repsMin: 10),
          SerieGymAdmin(repsMin: 10),
        ]),
        EjercicioGymAdmin(fichaId: _sentadilla.id, series: const [
          SerieGymAdmin(repsMin: 5),
        ]),
      ],
    );

/// Superficie alta de teléfono (1080×2400): con la de
/// defecto (800×600) la segunda tarjeta de la rutina ni
/// se construye (la lista es perezosa) y los toques a la
/// zona baja caen fuera del área visible.
void _pantallaAlta(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  tearDown(() => cargarCatalogoRutinasParaTest = null);

  group('D-22 puros · descanso de ficha y duración', () {
    test('segundosDescansoFicha interpreta las formas de la casa', () {
      expect(segundosDescansoFicha('2 min'), 120);
      expect(segundosDescansoFicha('2–3 min'), 180);
      expect(segundosDescansoFicha('60-90 s'), 90);
      expect(segundosDescansoFicha('90 segundos'), 90);
      expect(segundosDescansoFicha('1:30'), 90);
      expect(segundosDescansoFicha('15 min'), 600,
          reason: 'tope de cordura de 10 min');
      expect(segundosDescansoFicha(''), isNull);
      expect(segundosDescansoFicha(null), isNull);
      expect(segundosDescansoFicha('sin datos'), isNull);
    });

    test('textoDuracionSeg formatea m:ss', () {
      expect(textoDuracionSeg(90), '1:30');
      expect(textoDuracionSeg(60), '1:00');
      expect(textoDuracionSeg(45), '0:45');
    });
  });

  group('D-22 puros · búsqueda y grupos del selector', () {
    test('sinAcentosBusqueda quita acentos y baja a minúsculas', () {
      expect(sinAcentosBusqueda('Jalón Al Pecho'), 'jalon al pecho');
      expect(sinAcentosBusqueda('Tríceps'), 'triceps');
    });

    test('la búsqueda encuentra por título, equipo, sinónimo y músculo',
        () {
      expect(fichaCoincideConBusqueda(_press, 'press'), isTrue);
      expect(fichaCoincideConBusqueda(_press, 'banco plano'), isTrue,
          reason: 'por equipo');
      expect(fichaCoincideConBusqueda(_press, 'banca plana'), isTrue,
          reason: 'por sinónimo');
      expect(fichaCoincideConBusqueda(_press, 'pectoral'), isTrue,
          reason: 'por músculo principal');
      expect(fichaCoincideConBusqueda(_press, 'triceps'), isTrue,
          reason: 'por músculo secundario y sin acento en la consulta');
      expect(fichaCoincideConBusqueda(_jalon, 'jalon'), isTrue,
          reason: 'sin acento encuentra el título acentuado');
      expect(fichaCoincideConBusqueda(_press, 'remo'), isFalse);
      expect(fichaCoincideConBusqueda(_press, ''), isTrue);
      expect(fichaCoincideConBusqueda(_press, '  '), isTrue);
    });

    test('gruposDelCatalogo sale en orden fijo y solo con presentes',
        () {
      final grupos = gruposDelCatalogo(_catalogo);
      expect(grupos.map((g) => g.$1), ['pecho', 'espalda', 'piernas']);
      expect(gruposDelCatalogo(const []), isEmpty);
    });
  });

  group('D-22 puros · tipos de serie con nombre completo', () {
    test('los 4 tipos del formato, con nombre y explicación', () {
      expect(tiposSerieAdmin.map((t) => t.valor),
          ['normal', 'calentamiento', 'fallo', 'drop']);
      expect(tiposSerieAdmin.map((t) => t.nombre),
          ['Normal', 'Calentamiento', 'Al fallo', 'Descendente']);
      for (final t in tiposSerieAdmin) {
        expect(t.explicacion, isNotEmpty);
      }
      expect(tipoSerieAdminDe('drop').nombre, 'Descendente');
      expect(tipoSerieAdminDe('otra-cosa').valor, 'normal',
          reason: 'un valor desconocido cae a Normal');
    });
  });

  group('D-22 puros · totales vivos', () {
    test('fórmula portada: reps × 4 s y descanso efectivo', () {
      final totales = totalesRutinaAdmin([
        EjercicioGymAdmin(
            fichaId: 'a',
            descansoSeg: 90,
            series: const [
              SerieGymAdmin(repsMin: 10),
              SerieGymAdmin(repsMin: 10),
              SerieGymAdmin(repsMin: 10),
            ]),
        EjercicioGymAdmin(fichaId: 'b', series: const [
          SerieGymAdmin(repsMin: 8),
          SerieGymAdmin(repsMin: 8),
        ]),
      ], {
        'a': 30,
        'b': 120,
      });
      // a: 3×40 + 90×2 = 300 · b: 2×32 + 120×1 = 184 → 484 s ≈ 8 min.
      expect(totales.ejercicios, 2);
      expect(totales.series, 5);
      expect(totales.minutos, 8);
      expect(totales.texto, '2 ejercicios · 5 series · ≈ 8 min');
    });

    test('sin descanso fijado ni de ficha: 60 s por defecto', () {
      final totales = totalesRutinaAdmin([
        EjercicioGymAdmin(fichaId: 'x', series: const [
          SerieGymAdmin(repsMin: 10),
          SerieGymAdmin(repsMin: 10),
        ]),
      ], const {});
      // 2×40 + 60 = 140 s ≈ 2 min.
      expect(totales.minutos, 2);
    });

    test('el rango de reps usa repsMax como objetivo', () {
      final totales = totalesRutinaAdmin([
        EjercicioGymAdmin(fichaId: 'x', descansoSeg: 0, series: const [
          SerieGymAdmin(repsMin: 6, repsMax: 8),
        ]),
      ], const {});
      // 8×4 = 32 s → 1 min (mínimo con series).
      expect(totales.minutos, 1);
    });

    test('rutina vacía: ceros', () {
      final totales = totalesRutinaAdmin(const [], const {});
      expect(totales.ejercicios, 0);
      expect(totales.series, 0);
      expect(totales.minutos, 0);
    });
  });

  group('D-22 puros · el espejo llena la ficha entera', () {
    test('fichasCatalogoDesdeEspejo trae equipo, músculos, grupo, '
        'sinónimos, descanso e imagen', () {
      final cat = fichasCatalogoDesdeEspejo([
        {
          'id': 'press-banca-plano',
          'equipoId': 'banco-plano',
          'equipoNombre': 'Banco plano',
          'titulo': 'Press banca plano',
          'sinonimos': ['banca plana'],
          'musculosPrincipales': ['Pectoral mayor'],
          'musculosSecundarios': ['Tríceps'],
          'siluetaId': 'pecho',
          'dosificacion': {'descanso': '2 min'},
          'tiene_imagen': 1,
          'imagen_rev': 3,
        },
      ]);
      final f = cat.single;
      expect(f.id, 'banco-plano_press-banca-plano');
      expect(f.slug, 'press-banca-plano');
      expect(f.equipoNombre, 'Banco plano');
      expect(f.musculos, ['Pectoral mayor', 'Tríceps']);
      expect(f.musculoPrincipal, 'Pectoral mayor');
      expect(f.grupo, 'pecho');
      expect(f.sinonimos, ['banca plana']);
      expect(f.descansoSeg, 120);
      expect(f.tieneImagen, isTrue);
      expect(f.imagenRev, 3);
    });

    test('una fila mínima (la de los tests de colisión) da defaults '
        'seguros', () {
      final cat = fichasCatalogoDesdeEspejo([
        {'id': 'remo', 'equipoId': 'barra-recta', 'titulo': 'Remo'},
      ]);
      final f = cat.single;
      expect(f.equipoNombre, '');
      expect(f.musculos, isEmpty);
      expect(f.grupo, '');
      expect(f.sinonimos, isEmpty);
      expect(f.descansoSeg, isNull);
      expect(f.tieneImagen, isFalse);
    });
  });

  group('D-22 fuente · invariantes del archivo', () {
    final fuente =
        File('lib/ui/editor_rutinas_gym.dart').readAsStringSync();

    test('el hint «Global si vacío» no existe (no hay campo global)',
        () {
      expect(fuente, isNot(contains('Global si vacío')));
    });

    test('ningún literal de color de Clientes aterrizó en Gestión',
        () {
      expect(fuente, isNot(contains('FF6B00')));
      expect(fuente, isNot(contains('brandOrange')));
    });
  });

  group('D-22 widgets · selector', () {
    testWidgets('busca sin acentos y filtra por grupo con chips',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: SelectorFichasScreen(
            catalogo: _catalogo, seleccionInicial: []),
      ));
      await tester.pump();
      expect(find.text('Press banca plano'), findsOneWidget);
      expect(find.text('Jalón al pecho'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'jalon');
      await tester.pump();
      expect(find.text('Jalón al pecho'), findsOneWidget);
      expect(find.text('Press banca plano'), findsNothing);

      await tester.enterText(find.byType(TextField), '');
      await tester.pump();
      await tester.tap(find.text('Pecho'));
      await tester.pump();
      expect(find.text('Press banca plano'), findsOneWidget);
      expect(find.text('Sentadilla con barra'), findsNothing);
    });

    testWidgets('catálogo vacío se dice como catálogo vacío, no como '
        'búsqueda sin resultados', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: SelectorFichasScreen(catalogo: [], seleccionInicial: []),
      ));
      await tester.pump();
      expect(find.text('El catálogo está vacío'), findsOneWidget);
      expect(find.text('Ninguna ficha coincide'), findsNothing);
    });

    testWidgets('sin coincidencias se dice sin coincidencias',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: SelectorFichasScreen(
            catalogo: _catalogo, seleccionInicial: []),
      ));
      await tester.pump();
      await tester.enterText(find.byType(TextField), 'zzzz');
      await tester.pump();
      expect(find.text('Ninguna ficha coincide'), findsOneWidget);
      expect(find.text('El catálogo está vacío'), findsNothing);
    });

    testWidgets('la selección conserva el orden de toque y Listo lo '
        'devuelve', (tester) async {
      List<String>? resultado;
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (ctx) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () async {
                  resultado = await Navigator.push<List<String>>(
                    ctx,
                    MaterialPageRoute(
                      builder: (_) => const SelectorFichasScreen(
                          catalogo: _catalogo, seleccionInicial: []),
                    ),
                  );
                },
                child: const Text('Abrir'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('Abrir'));
      await tester.pumpAndSettle();
      // Primero la sentadilla, después el press: ese orden manda.
      await tester.tap(find.text('Sentadilla con barra'));
      await tester.pump();
      await tester.tap(find.text('Press banca plano'));
      await tester.pump();
      expect(find.text('Listo (2)'), findsOneWidget);
      await tester.tap(find.text('Listo (2)'));
      await tester.pumpAndSettle();
      expect(resultado, [_sentadilla.id, _press.id]);
    });
  });

  group('D-22 widgets · formulario', () {
    testWidgets('catálogo vacío: aviso honesto y elegir deshabilitado',
        (tester) async {
      cargarCatalogoRutinasParaTest = () async => const [];
      await tester
          .pumpWidget(const MaterialApp(home: FormularioRutinaScreen()));
      await tester.pump();
      await tester.pump();
      expect(
          find.textContaining(
              'El catálogo de GymPedia está vacío en este teléfono'),
          findsOneWidget);
      expect(find.text('Cargando GymPedia…'), findsNothing);
      final boton = tester.widget<OutlinedButton>(
          find.widgetWithText(OutlinedButton, 'Elegir fichas de GymPedia'));
      expect(boton.onPressed, isNull,
          reason: 'sin catálogo no se puede elegir: el botón no finge');
    });

    testWidgets('la carga que falla da error propio y el reintento '
        'recupera', (tester) async {
      var intentos = 0;
      cargarCatalogoRutinasParaTest = () async {
        intentos++;
        if (intentos == 1) throw StateError('BD bloqueada');
        return _catalogo;
      };
      await tester
          .pumpWidget(const MaterialApp(home: FormularioRutinaScreen()));
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('No se pudo leer el catálogo'),
          findsOneWidget);
      expect(find.text('Cargando GymPedia…'), findsNothing,
          reason: 'nunca spinner eterno');

      await tester.tap(find.text('Reintentar'));
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('No se pudo leer el catálogo'),
          findsNothing);
      final boton = tester.widget<OutlinedButton>(
          find.widgetWithText(OutlinedButton, 'Elegir fichas de GymPedia'));
      expect(boton.onPressed, isNotNull);
    });

    testWidgets('elegir fichas monta la tarjeta con las series a la '
        'vista, totales vivos y el chip de descanso de la ficha',
        (tester) async {
      cargarCatalogoRutinasParaTest = () async => _catalogo;
      await tester
          .pumpWidget(const MaterialApp(home: FormularioRutinaScreen()));
      await tester.pump();
      await tester.pump();
      await tester.tap(find.text('Elegir fichas de GymPedia'));
      await tester.pumpAndSettle();
      expect(find.byType(SelectorFichasScreen), findsOneWidget);
      await tester.tap(find.text('Press banca plano'));
      await tester.pump();
      await tester.tap(find.text('Listo (1)'));
      await tester.pumpAndSettle();

      expect(find.text('Press banca plano'), findsOneWidget);
      expect(find.text('1 ejercicio · 3 series · ≈ 6 min'),
          findsOneWidget);
      // Sin expandir nada: las 3 series ya enseñan sus campos
      // (2 del formulario + 3 series × peso/min/max = 11).
      expect(find.byType(TextField), findsNWidgets(11));
      expect(find.text('Normal'), findsNWidgets(3));
      // El descanso vacío se enseña como lo que es: el de la ficha.
      expect(find.text('2:00 · ficha'), findsOneWidget);
      // El hint muerto no existe en todo el árbol.
      expect(find.textContaining('Global si vacío'), findsNothing);
    });

    testWidgets('el tipo de serie se cambia en su hoja explicada, con '
        'nombre completo', (tester) async {
      _pantallaAlta(tester);
      cargarCatalogoRutinasParaTest = () async => _catalogo;
      await tester.pumpWidget(MaterialApp(
          home: FormularioRutinaScreen(rutina: _rutinaDos())));
      await tester.pump();
      await tester.pump();

      await tester.tap(find.text('Normal').first);
      await tester.pumpAndSettle();
      expect(find.text('Tipo de serie'), findsOneWidget);
      expect(find.text('Descendente'), findsNWidgets(2),
          reason: 'en la hoja, cada tipo se nombra dos veces: '
              'la pastilla y el nombre de su fila');
      expect(
          find.text(
              'Prepara el músculo. No cuenta como serie válida.'),
          findsOneWidget);
      await tester.tap(find.text('Al fallo').first);
      await tester.pumpAndSettle();
      expect(find.text('Tipo de serie'), findsNothing,
          reason: 'la hoja se cerró al elegir');
      expect(find.text('Al fallo'), findsOneWidget,
          reason: 'la pastilla de la serie 1 ya dice el nombre completo');
      expect(find.text('Normal'), findsNWidgets(2),
          reason: 'solo cambió la serie tocada (quedan las otras dos)');
    });

    testWidgets('quitar un ejercicio ofrece Deshacer y deshacer lo '
        'devuelve con sus series', (tester) async {
      _pantallaAlta(tester);
      cargarCatalogoRutinasParaTest = () async => _catalogo;
      await tester.pumpWidget(MaterialApp(
          home: FormularioRutinaScreen(rutina: _rutinaDos())));
      await tester.pump();
      await tester.pump();
      expect(find.text('2 ejercicios · 3 series · ≈ 4 min'),
          findsOneWidget);

      await tester.tap(find.byTooltip('Quitar ejercicio').first);
      // pumpAndSettle: la barra termina de entrar antes de
      // tocar su acción (con un solo pump la acción aún
      // está fuera de pantalla y el toque se pierde).
      await tester.pumpAndSettle();
      expect(find.text('Press banca plano'), findsNothing);
      expect(find.text('1 ejercicio · 1 serie · ≈ 1 min'),
          findsOneWidget,
          reason: 'los totales se recalculan al quitar');
      expect(find.textContaining('Se quitó Press banca plano'),
          findsOneWidget);
      expect(find.text('Deshacer'), findsOneWidget);

      await tester.tap(find.text('Deshacer'));
      await tester.pump();
      expect(find.text('Press banca plano'), findsOneWidget);
      expect(find.text('2 ejercicios · 3 series · ≈ 4 min'),
          findsOneWidget);
      // Drena la barra para no dejar temporizadores vivos.
      await tester.pump(const Duration(seconds: 6));
    });

    testWidgets('reordenar por el asa cambia el orden de la rutina',
        (tester) async {
      _pantallaAlta(tester);
      cargarCatalogoRutinasParaTest = () async => _catalogo;
      await tester.pumpWidget(MaterialApp(
          home: FormularioRutinaScreen(rutina: _rutinaDos())));
      await tester.pump();
      await tester.pump();
      final antesPress =
          tester.getTopLeft(find.text('Press banca plano')).dy;
      final antesSentadilla =
          tester.getTopLeft(find.text('Sentadilla con barra')).dy;
      expect(antesPress, lessThan(antesSentadilla));

      final asa = find.byIcon(Icons.drag_handle_rounded).first;
      final gesto =
          await tester.startGesture(tester.getCenter(asa));
      await tester.pump();
      for (var i = 0; i < 8; i++) {
        await gesto.moveBy(const Offset(0, 70));
        await tester.pump(const Duration(milliseconds: 50));
      }
      await gesto.up();
      await tester.pumpAndSettle();

      final despuesPress =
          tester.getTopLeft(find.text('Press banca plano')).dy;
      final despuesSentadilla =
          tester.getTopLeft(find.text('Sentadilla con barra')).dy;
      expect(despuesSentadilla, lessThan(despuesPress),
          reason: 'la sentadilla subió al primer puesto');
    });
  });
}
