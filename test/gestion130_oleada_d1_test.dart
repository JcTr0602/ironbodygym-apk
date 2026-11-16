/// Gestión 1.30 · Oleada D1 — Fundación y contraste
/// (plan §6.1: UI130-08, 09, 01, 02, 03, 04, COMP-A, 32,
/// 29 y portadas GymPedia ALTA-02).
///
/// - 08: la Tarjeta tocable pinta su ripple SOBRE el color
///   (Material propio + InkWell interior), no detrás.
/// - 09: geometría única de chips (AppRadio.chip circular;
///   tag = md solo para metadato).
/// - 01: frentes sobre gradientes — FAB en sobreMarca,
///   «Lo Nuevo» en carbón, candado del PIN en
///   carbonProfundo con icono naranja (fuente).
/// - 02: ContadorUrgente único sobre errorFondo (6,54),
///   mínimo 20×20; Home lo usa en sus dos sitios (fuente).
/// - 03: la marca como texto va por textoNaranja en los
///   sitios migrados (fuente) y el precio separa cifra
///   protagonista de moneda-metadato.
/// - 04: textoSecundarioClaro #6B6B6B ≥ 4,5 en sus tres
///   pares reales (fondo, superficie, hundida).
/// - COMP-A: las fábricas de IconoModuloBadge pintan con
///   los tokens de valor exacto.
/// - 32: tokens AppMovimiento como fuente única de la
///   ruta y del contador; MontoAnimado y la cascada
///   respetan «reducir movimiento»; la cascada NO
///   re-anima las celdas recicladas (BAJA-02).
/// - 29: la pantalla del PIN lleva el arte del rayo de
///   fondo y su lógica queda intacta (fuente + activo).
/// - Portadas: mapa categoría→activo puro, cabecera con
///   portada / plana / caída sin icono roto.
library;

import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/componentes.dart';
import 'package:ironbody_gym/ui/diseno.dart';
import 'package:ironbody_gym/ui/gympedia.dart';

double _luminancia(Color c) {
  double canal(double v) =>
      v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * canal(c.r) + 0.7152 * canal(c.g) + 0.0722 * canal(c.b);
}

double _contraste(Color a, Color b) {
  final la = _luminancia(a);
  final lb = _luminancia(b);
  final (mayor, menor) = la >= lb ? (la, lb) : (lb, la);
  return (mayor + 0.05) / (menor + 0.05);
}

Widget _envolver(Widget hijo, {bool oscuro = false, bool reducir = false}) {
  return MaterialApp(
    theme: oscuro ? AppTema.oscuro() : AppTema.claro(),
    home: MediaQuery(
      data: MediaQueryData(disableAnimations: reducir),
      child: Scaffold(body: Center(child: hijo)),
    ),
  );
}

void main() {
  group('D1 · UI130-08 Tarjeta tocable', () {
    testWidgets('el InkWell vive DENTRO del Material con el color '
        'de la tarjeta (el ripple ya no cae detrás)', (tester) async {
      var toques = 0;
      await tester.pumpWidget(_envolver(Tarjeta(
        onTap: () => toques++,
        child: const Text('Tócame'),
      )));
      final inkwell = find.byType(InkWell);
      expect(inkwell, findsOneWidget);
      // El Material dueño del color es ANCESTRO del InkWell:
      // la tinta se pinta sobre esa superficie.
      final material = find.ancestor(
          of: inkwell,
          matching: find.byWidgetPredicate((w) =>
              w is Material &&
              w.color == AppColores.superficie(tester.element(inkwell))));
      expect(material, findsOneWidget);
      await tester.tap(find.text('Tócame'));
      expect(toques, 1);
    });

    testWidgets('sin onTap no hay InkWell (la tarjeta muda no cambia)',
        (tester) async {
      await tester.pumpWidget(_envolver(const Tarjeta(child: Text('Quieta'))));
      expect(find.byType(InkWell), findsNothing);
    });

    testWidgets('golden: Tarjeta tocable', (tester) async {
      await tester.pumpWidget(_envolver(Tarjeta(
        onTap: () {},
        child: const Text('Tarjeta tocable D1'),
      )));
      await expectLater(find.byType(Tarjeta),
          matchesGoldenFile('goldens/tarjeta_tocable.png'));
    });
  });

  group('D1 · UI130-09 geometría de chips', () {
    test('el vocabulario: chip = circular, tag = md', () {
      expect(AppRadio.chip, AppRadio.circular);
      expect(AppRadio.tag, AppRadio.md);
    });

    testWidgets('ChipEstado pinta con radio circular', (tester) async {
      await tester.pumpWidget(_envolver(const ChipEstado.semantico(
          texto: 'Activo', significado: SignificadoChip.exito)));
      final cont = tester.widget<Container>(find
          .descendant(
              of: find.byType(ChipEstado), matching: find.byType(Container))
          .first);
      final deco = cont.decoration as BoxDecoration;
      expect(deco.borderRadius,
          BorderRadius.circular(AppRadio.chip));
    });

    // Actualizado en D5 (UI130-19) CON MOTIVO: la insignia artesanal
    // de la tarjeta de incidencia ya no existe — la tarjeta adopta la
    // anatomía común TarjetaDecision y su chip de estado es el
    // ChipEstado del kit, cuya geometría AppRadio.chip queda cubierta
    // por el test de widget hermano ('ChipEstado pinta con radio
    // circular'). El contrato nuevo: la fuente delega en ambos
    // componentes compartidos en vez de pintar su propia insignia.
    test('la tarjeta de incidencia delega en TarjetaDecision y '
        'ChipEstado (fuente)', () {
      final f = File('lib/ui/incidencias/widgets/tarjeta_incidencia.dart')
          .readAsStringSync();
      expect(f, contains('TarjetaDecision'));
      expect(f, contains('ChipEstado'));
    });
  });

  group('D1 · UI130-02 ContadorUrgente', () {
    testWidgets('mínimo 20x20, fondo errorFondo y tope 99+',
        (tester) async {
      await tester.pumpWidget(_envolver(const ContadorUrgente(numero: 150)));
      expect(find.text('99+'), findsOneWidget);
      final tam = tester.getSize(find.byType(ContadorUrgente));
      expect(tam.width, greaterThanOrEqualTo(20));
      expect(tam.height, greaterThanOrEqualTo(20));
      final cont = tester.widget<Container>(find
          .descendant(
              of: find.byType(ContadorUrgente),
              matching: find.byType(Container))
          .first);
      expect((cont.decoration as BoxDecoration).color,
          AppColores.errorFondo);
    });

    test('Home lo usa en sus dos sitios (fuente)', () {
      // 1.32 (pin E5): los dos sitios se jubilaron con la
      // Home clásica — el contador del segmento de niveles
      // (la navegación es hoy la BarraPilares) y la insignia
      // de la campana sobre la cabecera carbón (la cabecera
      // es la del marco: los pendientes los canta el pulso
      // de la píldora de sync, sin campana). El componente
      // ContadorUrgente queda sin consumidores en lib/ (su
      // garantía de forma la sigue fijando el widget test
      // de este grupo); el pin pasa a fijar la jubilación
      // para que nadie lo reenganche a la Home sin querer.
      final f = File('lib/ui/home.dart').readAsStringSync();
      expect(f, isNot(contains('ContadorUrgente(')),
          reason: 'la Home del Mostrador no usa el contador');
      expect(f, isNot(contains('conBorde: true')),
          reason: 'la campana de la cabecera carbón se jubiló');
    });
  });

  group('D1 · UI130-01 frentes sobre gradientes (fuente)', () {
    test('el glifo del dial va en sobreMarca', () {
      // 1.32 (pin E5): el FAB del dial se jubiló con la
      // Home clásica (como en los pines T8 de bloque5 y el
      // cabo FAB de la oleada9): home.dart ya no pinta
      // ningún frente sobre gradienteDial. La garantía de
      // fondo (todo glifo sobre la marca va en sobreMarca)
      // la hereda la acción primaria del Dock del marco
      // («Cobrar» sobre naranja pleno, icono en sobreMarca).
      final f = File('lib/ui/home.dart').readAsStringSync();
      expect(f, isNot(contains('gradient: AppColores.gradienteDial')),
          reason: 'el dial y su FAB salieron de la Home');
      final marco = File('lib/ui/marco.dart').readAsStringSync();
      expect(marco, contains('AppColores.sobreMarca'),
          reason: 'el glifo sobre la marca vive en el Dock');
    });

    test('«Lo Nuevo» de Ayuda: cabecera carbón, chip carbonProfundo, '
        'sin gradiente naranja', () {
      final f = File('lib/ui/ayuda.dart').readAsStringSync();
      expect(f, contains('AppColores.gradienteCarbon'));
      expect(f, contains('AppColores.carbonProfundo'));
      expect(f, isNot(contains('gradienteNaranja')));
    });

    test('el candado del PIN: círculo carbonProfundo, icono naranja, '
        'sin gradiente de marca', () {
      final f = File('lib/ui/pin_lock.dart').readAsStringSync();
      expect(f, contains('color: AppColores.carbonProfundo'));
      expect(f, contains('color: AppColores.naranja'),
          reason: 'el icono del candado va en naranja');
      expect(f, isNot(contains('naranjaOscuro')),
          reason: 'el gradiente naranja→naranjaOscuro del candado '
              'era el frente corregido por UI130-01');
    });
  });

  group('D1 · UI130-03 la marca como texto (fuente)', () {
    test('los sitios migrados piden textoNaranja', () {
      final sup = File('lib/ui/suplementos.dart').readAsStringSync();
      expect('AppColores.textoNaranja(context)'.allMatches(sup).length,
          greaterThanOrEqualTo(2),
          reason: 'los dos precios (mini-top y fila)');
      final gym = File('lib/ui/gympedia.dart').readAsStringSync();
      expect(gym, contains('AppColores.textoNaranja(context)'));
      expect(gym, isNot(contains('color: AppColores.naranja')),
          reason: 'en GymPedia la marca ya no colorea ningún texto');
      // 1.32 (pin E5): el chip de rol quedó anclado en el
      // marco (CabeceraMarco, key marco-rol) y la 1.33 lo
      // pasó a la marca. 1.35 (M-6): el chip como pieza
      // separada DESAPARECE — el rol vive en la cabecera
      // del menú del avatar (key marco-perfil) — y el pin
      // se re-ancla: la identidad es el avatar con nombre
      // y el marco sigue sin pintar nada en cobalto.
      final marco = File('lib/ui/marco.dart').readAsStringSync();
      expect(marco, contains("ValueKey('marco-perfil')"),
          reason: 'la identidad de la cabecera es el avatar '
              'con el menú que dice nombre y rol');
      expect(marco, isNot(contains("ValueKey('marco-rol')")),
          reason: 'M-6: fuera el chip de rol como pieza '
              'separada de la cabecera');
      expect(marco, isNot(contains('AppColores.cobaltoDe(context)')),
          reason: 'el marco ya no pinta nada en cobalto');
      final ins = File('lib/ui/inscribir.dart').readAsStringSync();
      expect(ins, contains('AppColores.textoNaranja(context)'),
          reason: 'la etiqueta del paso activo');
    });
  });

  group('D1 · UI130-04 secundario claro', () {
    test('el token es #6B6B6B y pasa AA en sus tres pares reales', () {
      expect(AppColores.textoSecundarioClaro,
          const Color(0xFF6B6B6B));
      for (final superficie in [
        AppColores.fondoClaro,
        AppColores.superficieClaro,
        AppColores.superficieHundidaClaro,
      ]) {
        expect(_contraste(AppColores.textoSecundarioClaro, superficie),
            greaterThanOrEqualTo(4.5),
            reason: 'secundario claro sobre $superficie');
      }
    });
  });

  group('D1 · COMP-A fábricas de badge', () {
    // Dos tests separados (árbol fresco por brillo): con un
    // solo árbol reutilizado, el cambio de tema se aplica
    // un frame después y la lectura sale con el brillo
    // anterior (la sonda lo probó: en árbol fresco, el
    // icono claro es bannerEnviandoB como manda el token).
    testWidgets('en oscuro pintan con los tokens de oscuro',
        (tester) async {
      await tester.pumpWidget(_envolver(
        Column(mainAxisSize: MainAxisSize.min, children: [
          IconoModuloBadge.naranja(Icons.bolt_rounded),
          IconoModuloBadge.verde(Icons.chat_rounded),
        ]),
        oscuro: true,
      ));
      final iconos = tester
          .widgetList<Icon>(find.byType(Icon))
          .map((i) => i.color)
          .toList();
      expect(iconos,
          [AppColores.naranjaTextoOscuro, AppColores.exitoIconoOscuro]);
    });

    testWidgets('en claro pintan con los tokens de claro',
        (tester) async {
      await tester.pumpWidget(_envolver(
        Column(mainAxisSize: MainAxisSize.min, children: [
          IconoModuloBadge.naranja(Icons.bolt_rounded),
          IconoModuloBadge.verde(Icons.chat_rounded),
        ]),
        oscuro: false,
      ));
      final iconos = tester
          .widgetList<Icon>(find.byType(Icon))
          .map((i) => i.color)
          .toList();
      expect(iconos,
          [AppColores.bannerEnviandoB, AppColores.exitoIconoClaro]);
    });
  });

  group('D1 · UI130-32 fundación de movimiento', () {
    test('los tokens fijan los ritmos de siempre', () {
      expect(AppMovimiento.media, const Duration(milliseconds: 220));
      expect(AppMovimiento.larga, const Duration(milliseconds: 300));
      expect(AppMovimiento.curva, Curves.easeOutCubic);
      expect(AppMovimiento.curvaReversa, Curves.easeInCubic);
    });

    test('la ruta y el contador consumen el token (fuente)', () {
      final d = File('lib/ui/diseno.dart').readAsStringSync();
      expect(d, contains('Duration get transitionDuration => AppMovimiento.media'));
      final c = File('lib/ui/componentes.dart').readAsStringSync();
      expect(c, contains('AppMovimiento.larga'));
      expect(c, isNot(contains('Duration(milliseconds: 300)')),
          reason: 'la duración del contador ya no es un literal');
    });

    testWidgets('MontoAnimado con «reducir movimiento» nace puesto',
        (tester) async {
      await tester.pumpWidget(_envolver(
        MontoAnimado(valor: 1234, formato: (v) => '${v.toInt()}'),
        reducir: true,
      ));
      expect(find.text('1234'), findsOneWidget);
    });

    testWidgets('la cascada anima al abrir y NO re-anima las celdas '
        'recicladas al volver del scroll (BAJA-02)', (tester) async {
      Widget lista() => _envolver(
            EntradaCascada(
              child: ListView.builder(
                itemCount: 30,
                itemBuilder: (_, i) => ItemCascada(
                  indice: i,
                  child: SizedBox(height: 50, child: Text('Fila $i')),
                ),
              ),
            ),
          );
      await tester.pumpWidget(lista());
      // Nada más abrir, el ítem escalonado aún no llegó:
      // su fundido está por debajo de 1. (Los finders se
      // acotan a la cascada: la transición de ruta también
      // es un FadeTransition y no debe contar.)
      final fundidos = find.descendant(
          of: find.byType(EntradaCascada),
          matching: find.byType(FadeTransition));
      final opacidad0 = tester
          .widgetList<FadeTransition>(fundidos)
          .map((f) => f.opacity.value)
          .toList();
      expect(opacidad0.any((o) => o < 1), isTrue,
          reason: 'la cascada anima en la primera pasada');
      // Se agota la ventana de entrada.
      await tester.pump(const Duration(seconds: 2));
      // Scroll hasta el fondo y de vuelta: las celdas
      // recicladas nacen puestas (sin fundido en curso).
      await tester.drag(find.byType(ListView), const Offset(0, -1400));
      await tester.pump();
      await tester.drag(find.byType(ListView), const Offset(0, 1400));
      await tester.pump();
      final opacidades = tester
          .widgetList<FadeTransition>(fundidos)
          .map((f) => f.opacity.value)
          .toList();
      expect(opacidades.every((o) => o == 1), isTrue,
          reason: 'ninguna celda reciclada vuelve a animar');
    });

    testWidgets('la cascada con «reducir movimiento» no anima',
        (tester) async {
      await tester.pumpWidget(_envolver(
        const EntradaCascada(
          child: ItemCascada(
              indice: 3, child: Text('Directo')),
        ),
        reducir: true,
      ));
      expect(find.text('Directo'), findsOneWidget);
      // Acotado a la cascada: la ruta de la app también
      // monta su FadeTransition y no es asunto de este test.
      expect(
          find.descendant(
              of: find.byType(EntradaCascada),
              matching: find.byType(FadeTransition)),
          findsNothing);
    });
  });

  group('D1 · UI130-29 PIN con arte (fuente y activos)', () {
    test('la pantalla monta el arte y conserva su lógica intacta', () {
      final f = File('lib/ui/pin_lock.dart').readAsStringSync();
      expect(f, contains("'assets/arte_marca_rayo.jpg'"));
      expect(f, contains('verificarPin'),
          reason: 'la verificación del PIN no se tocó');
      expect(f, contains('canPop: false'),
          reason: 'la compuerta de salida sigue cerrada');
      expect(File('assets/arte_marca_rayo.jpg').existsSync(), isTrue);
    });

    test('pubspec declara el arte y las 5 portadas', () {
      final p = File('pubspec.yaml').readAsStringSync();
      for (final a in [
        'assets/arte_marca_rayo.jpg',
        'assets/gympedia_entrenamiento.jpg',
        'assets/gympedia_nutricion.jpg',
        'assets/gympedia_suplementos.jpg',
        'assets/gympedia_descanso.jpg',
        'assets/gympedia_tecnica.jpg',
      ]) {
        expect(p, contains(a), reason: a);
        expect(File(a).existsSync(), isTrue, reason: a);
      }
    });
  });

  group('D1 · Portadas GymPedia (ALTA-02)', () {
    test('el mapa: 5 categorías con portada, 2 sin ella', () {
      expect(portadaGympediaDe('entrenamiento'),
          'assets/gympedia_entrenamiento.jpg');
      expect(portadaGympediaDe('nutricion'),
          'assets/gympedia_nutricion.jpg');
      expect(portadaGympediaDe('suplementos'),
          'assets/gympedia_suplementos.jpg');
      expect(portadaGympediaDe('descanso'),
          'assets/gympedia_descanso.jpg');
      expect(portadaGympediaDe('tecnica'),
          'assets/gympedia_tecnica.jpg');
      expect(portadaGympediaDe('empieza-aqui'), isNull);
      expect(portadaGympediaDe('mitos'), isNull);
    });

    testWidgets('con portada: banda con imagen y nombre',
        (tester) async {
      await tester.pumpWidget(
          _envolver(const CabeceraCategoriaGympedia(categoria: 'nutricion')));
      await tester.pump();
      expect(find.byType(Image), findsOneWidget);
      expect(find.text('Nutrición'), findsOneWidget);
    });

    testWidgets('sin portada: el título plano de siempre',
        (tester) async {
      await tester.pumpWidget(
          _envolver(const CabeceraCategoriaGympedia(categoria: 'mitos')));
      expect(find.byType(Image), findsNothing);
      expect(find.text('Mitos'), findsOneWidget);
    });

    testWidgets('activo caído: ni icono roto ni excepción, el nombre '
        'se sigue leyendo', (tester) async {
      await tester.pumpWidget(_envolver(const CabeceraCategoriaGympedia(
          categoria: 'nutricion',
          rutaPortada: 'assets/no_existe_esta.jpg')));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('Nutrición'), findsOneWidget);
    });
  });
}
