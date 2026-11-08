/// Tests de la fundación de diseño de la 1.29 (OG-0):
/// D-01 (sobreMarca), D-02 (roles *Texto), D-03 (*Fondo +
/// AvisoEstado), D-05 (tintes del Panel + contador), D-06
/// (BadgeEstado por roles), D-10 (iconos propios), D-11
/// (categórica de trabajo), D-18 (sombra deprecada sin
/// llamadores) y D-20 (roles en alto contraste y con
/// letra grande).
///
/// Las cuentas de contraste son las del estudio de diseño
/// (§4.1/§4.3) convertidas en aserciones: si un valor se
/// mueve, el test rompe ANTES de que el ojo lo note.
library;

import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/componentes.dart';
import 'package:ironbody_gym/ui/diseno.dart';
import 'package:ironbody_gym/ui/iconos_propios.dart';
import 'package:ironbody_gym/ui/panel_modulos.dart';

// ---------------------------------------------------------------------------
// Contraste WCAG (misma cuenta que verificó el estudio)
// ---------------------------------------------------------------------------

double _luminancia(Color c) {
  double canal(double v) {
    final s = v / 255.0;
    return s <= 0.04045
        ? s / 12.92
        : math.pow((s + 0.055) / 1.055, 2.4).toDouble();
  }

  return 0.2126 * canal(c.r * 255) +
      0.7152 * canal(c.g * 255) +
      0.0722 * canal(c.b * 255);
}

double _contraste(Color a, Color b) {
  final la = _luminancia(a);
  final lb = _luminancia(b);
  final mayor = math.max(la, lb);
  final menor = math.min(la, lb);
  return (mayor + 0.05) / (menor + 0.05);
}

const _superficiesOscuro = [
  AppColores.fondoOscuro,
  AppColores.superficieOscuro,
  AppColores.superficieElevadaOscuro,
];
const _superficiesClaro = [
  Colors.white,
  AppColores.fondoClaro,
  AppColores.superficieHundidaClaro,
];

// 1.29 (Oleada 5, D-23): sin ítems, sin badges — la
// foto vacía de siempre, con la firma nueva.
List<DatoModuloPanel> _modulos() => modulosPanel(
      items: const {},
      pendCajaTotal: 0,
      cajaHoyTotal: 0,
      clientesActivos: 0,
      stockCritico: 0,
      pendientesSubir: 0,
    );

void main() {
  group('D-01 · sobreMarca (GD-01: 2,75 → 6,32)', () {
    test('las cuentas del defecto y del arreglo', () {
      // El defecto: blanco sobre la marca.
      expect(_contraste(Colors.white, AppColores.naranja),
          inInclusiveRange(2.70, 2.80));
      expect(_contraste(Colors.white, AppColores.naranja),
          lessThan(3.0),
          reason: 'el blanco fallaba AA hasta en texto grande');
      // El arreglo: grafito sobre la marca y sobre los dos
      // extremos del gradiente primario.
      expect(_contraste(AppColores.sobreMarca, AppColores.naranja),
          inInclusiveRange(6.27, 6.37));
      expect(
          _contraste(AppColores.sobreMarca, AppColores.naranjaOscuro),
          greaterThanOrEqualTo(4.9),
          reason: 'extremo oscuro del gradiente: 4,98');
      expect(
          _contraste(
              AppColores.sobreMarca, const Color(0xFFF59E0B)),
          greaterThanOrEqualTo(8.0),
          reason: 'extremo ámbar del gradiente: 8,09');
    });

    testWidgets('el tema resuelve grafito en botón elevado, '
        'relleno, FAB y onPrimary, en ambos temas', (tester) async {
      for (final tema in [AppTema.claro(), AppTema.oscuro()]) {
        late ThemeData capturado;
        await tester.pumpWidget(MaterialApp(
          theme: tema,
          home: Builder(builder: (context) {
            capturado = Theme.of(context);
            return const SizedBox.shrink();
          }),
        ));
        // Deja terminar la animación de AnimatedTheme: la
        // lectura debe ser el tema destino, no un fotograma
        // intermedio entre claro y oscuro.
        await tester.pump(const Duration(milliseconds: 300));
        expect(
            capturado.elevatedButtonTheme.style?.foregroundColor
                ?.resolve(<WidgetState>{}),
            AppColores.sobreMarca);
        expect(
            capturado.filledButtonTheme.style?.foregroundColor
                ?.resolve(<WidgetState>{}),
            AppColores.sobreMarca);
        expect(capturado.floatingActionButtonTheme.foregroundColor,
            AppColores.sobreMarca);
        expect(capturado.colorScheme.onPrimary, AppColores.sobreMarca);
      }
    });

    testWidgets('BotonPrimario pinta su contenido en grafito '
        'sobre el gradiente, en ambos temas', (tester) async {
      for (final tema in [AppTema.claro(), AppTema.oscuro()]) {
        await tester.pumpWidget(MaterialApp(
          theme: tema,
          home: Scaffold(
            body: BotonPrimario(
              texto: 'Cobrar',
              icono: Icons.payments_rounded,
              onPressed: () {},
            ),
          ),
        ));
        await tester.pump(const Duration(milliseconds: 300));
        // El contenido no lleva color propio: el efectivo
        // viene del IconTheme/DefaultTextStyle que el botón
        // resuelve desde su foregroundColor.
        final elementoIcono =
            tester.element(find.byIcon(Icons.payments_rounded));
        expect(IconTheme.of(elementoIcono).color,
            AppColores.sobreMarca);
        final elemento = tester.element(find.text('Cobrar'));
        expect(DefaultTextStyle.of(elemento).style.color,
            AppColores.sobreMarca);
      }
    });
  });

  group('D-02 · roles *Texto (tabla §4.1 como aserción)', () {
    test('tema oscuro: los 4 roles ≥ 4,5 en fondo/superficie/elevada',
        () {
      for (final rol in [
        AppColores.exitoTextoOscuro,
        AppColores.alertaTextoOscuro,
        AppColores.errorTextoOscuro,
        AppColores.infoTextoOscuro,
      ]) {
        for (final superficie in _superficiesOscuro) {
          expect(_contraste(rol, superficie),
              greaterThanOrEqualTo(4.5),
              reason: '$rol sobre $superficie');
        }
      }
    });

    test('tema claro: los 4 roles ≥ 4,5 en blanca/fondo y el '
        'límite declarado de la hundida', () {
      for (final rol in [
        AppColores.exitoTextoClaro,
        AppColores.alertaTextoClaro,
        AppColores.errorTextoClaro,
        AppColores.infoTextoClaro,
      ]) {
        for (final superficie in [Colors.white, AppColores.fondoClaro]) {
          expect(_contraste(rol, superficie),
              greaterThanOrEqualTo(4.5),
              reason: '$rol sobre $superficie');
        }
      }
      // Hundida (#F0F0F0): todos ≥ 4,5 salvo el único límite
      // declarado del estudio — exitoTexto claro da 4,40 y la
      // hundida no aloja texto de estado.
      for (final rol in [
        AppColores.alertaTextoClaro,
        AppColores.errorTextoClaro,
        AppColores.infoTextoClaro,
      ]) {
        expect(
            _contraste(rol, AppColores.superficieHundidaClaro),
            greaterThanOrEqualTo(4.5),
            reason: '$rol sobre hundida');
      }
      expect(
          _contraste(AppColores.exitoTextoClaro,
              AppColores.superficieHundidaClaro),
          inInclusiveRange(4.35, 4.45),
          reason: 'límite declarado: 4,40');
    });

    testWidgets('los helpers resuelven el valor del tema',
        (tester) async {
      // Theme directo, sin MaterialApp: MaterialApp anima el
      // tema (AnimatedTheme) y tras un pump el brillo leído
      // puede ser aún el anterior (trampa documentada en
      // chip_semantico_test).
      final resueltos = <Brightness, List<Color>>{};
      for (final tema in [AppTema.claro(), AppTema.oscuro()]) {
        await tester.pumpWidget(Directionality(
          textDirection: TextDirection.ltr,
          child: Theme(
            data: tema,
            child: Builder(builder: (context) {
              resueltos[tema.brightness] = [
                AppColores.exitoTexto(context),
                AppColores.alertaTexto(context),
                AppColores.errorTexto(context),
                AppColores.infoTexto(context),
              ];
              return const SizedBox.shrink();
            }),
          ),
        ));
      }
      expect(resueltos[Brightness.light], [
        AppColores.exitoTextoClaro,
        AppColores.alertaTextoClaro,
        AppColores.errorTextoClaro,
        AppColores.infoTextoClaro,
      ]);
      expect(resueltos[Brightness.dark], [
        AppColores.exitoTextoOscuro,
        AppColores.alertaTextoOscuro,
        AppColores.errorTextoOscuro,
        AppColores.infoTextoOscuro,
      ]);
    });
  });

  group('D-20 · roles en alto contraste y con letra grande', () {
    testWidgets('alto contraste: los roles valen lo mismo y '
        'pasan AA sobre blanco/negro puros', (tester) async {
      for (final tema in [
        AppTema.claroAltoContraste(),
        AppTema.oscuroAltoContraste(),
      ]) {
        late List<Color> roles;
        // Theme directo (sin la animación de AnimatedTheme).
        await tester.pumpWidget(Directionality(
          textDirection: TextDirection.ltr,
          child: Theme(
            data: tema,
            child: Builder(builder: (context) {
              roles = [
                AppColores.exitoTexto(context),
                AppColores.alertaTexto(context),
                AppColores.errorTexto(context),
                AppColores.infoTexto(context),
              ];
              return const SizedBox.shrink();
            }),
          ),
        ));
        final puro = tema.brightness == Brightness.dark
            ? Colors.black
            : Colors.white;
        for (final rol in roles) {
          expect(_contraste(rol, puro), greaterThanOrEqualTo(4.5),
              reason: '$rol sobre $puro en alto contraste');
        }
      }
    });

    testWidgets('BadgeEstado y AvisoEstado no explotan con el '
        'factor de letra 1,30 en alto contraste', (tester) async {
      for (final tema in [
        AppTema.claroAltoContraste(),
        AppTema.oscuroAltoContraste(),
      ]) {
        await tester.pumpWidget(MaterialApp(
          theme: tema,
          builder: (context, hijo) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(1.3)),
            child: hijo!,
          ),
          home: const Scaffold(
            body: Column(
              children: [
                BadgeEstado(
                    estado: EstadoMembresia.porVencer,
                    texto: 'VENCE EN 5 DÍAS'),
                AvisoEstado(
                    tipo: TipoAviso.error,
                    texto: 'La sincronización falló'),
              ],
            ),
          ),
        ));
        await tester.pump();
        expect(tester.takeException(), isNull);
      }
    });
  });

  group('D-03 · fondos sólidos *Fondo y AvisoEstado', () {
    test('blanco literal sobre los 4 fondos ≥ 6,5', () {
      for (final fondo in [
        AppColores.exitoFondo,
        AppColores.avisoFondo,
        AppColores.errorFondo,
        AppColores.infoFondo,
      ]) {
        expect(_contraste(Colors.white, fondo),
            greaterThanOrEqualTo(6.5),
            reason: 'blanco sobre $fondo');
      }
    });

    testWidgets('AvisoEstado pinta fondo sólido, icono canónico '
        'y texto blanco, en ambos temas', (tester) async {
      const esperado = {
        TipoAviso.exito: (
          AppColores.exitoFondo,
          Icons.check_circle_rounded
        ),
        TipoAviso.aviso: (
          AppColores.avisoFondo,
          Icons.warning_amber_rounded
        ),
        TipoAviso.error: (
          AppColores.errorFondo,
          Icons.error_outline_rounded
        ),
        TipoAviso.info: (AppColores.infoFondo, Icons.info_rounded),
      };
      for (final tema in [AppTema.claro(), AppTema.oscuro()]) {
        await tester.pumpWidget(MaterialApp(
          theme: tema,
          home: Scaffold(
            body: Column(
              children: [
                for (final tipo in TipoAviso.values)
                  AvisoEstado(tipo: tipo, texto: 'Aviso ${tipo.name}'),
              ],
            ),
          ),
        ));
        for (final e in esperado.entries) {
          final texto = find.text('Aviso ${e.key.name}');
          final contenedor = tester.widget<Container>(find
              .ancestor(of: texto, matching: find.byType(Container))
              .first);
          expect((contenedor.decoration as BoxDecoration).color,
              e.value.$1,
              reason: '${e.key} pinta su fondo sólido');
          expect(tester.widget<Text>(texto).style?.color, Colors.white,
              reason: 'el texto sobre *Fondo es Colors.white literal');
          expect(find.byIcon(e.value.$2), findsOneWidget,
              reason: 'icono canónico de ${e.key}');
        }
      }
    });
  });

  group('D-05 · tintes del Panel tokenizados y contador legible',
      () {
    test('los 6 módulos consumen los tokens modulo* y Caja ya '
        'no es el verde de estado (P-07)', () {
      final modulos = _modulos();
      expect(modulos.map((m) => m.tinte).toList(), [
        AppColores.moduloCaja,
        AppColores.moduloClientes,
        AppColores.moduloEquipo,
        AppColores.moduloSuplementos,
        AppColores.moduloConfiguracion,
        AppColores.moduloControl,
      ]);
      expect(AppColores.moduloCaja, const Color(0xFFD9A441));
      expect(AppColores.moduloCaja, isNot(AppColores.exito),
          reason: 'el verde queda reservado a «al día»/éxito');
    });

    test('panel_modulos.dart no contiene ningún Color(0x literal',
        () {
      final fuente =
          File('lib/ui/panel_modulos.dart').readAsStringSync();
      expect(fuente.contains('Color(0x'), isFalse);
    });

    testWidgets('BadgeModuloPanel: cifra blanca sobre errorFondo',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: AppTema.claro(),
        home: const Scaffold(body: BadgeModuloPanel(valor: 3)),
      ));
      final contenedor = tester.widget<Container>(find
          .ancestor(of: find.text('3'), matching: find.byType(Container))
          .first);
      expect((contenedor.decoration as BoxDecoration).color,
          AppColores.errorFondo);
      expect(tester.widget<Text>(find.text('3')).style?.color,
          Colors.white);
      expect(_contraste(Colors.white, AppColores.errorFondo),
          greaterThanOrEqualTo(6.5),
          reason: 'antes: blanco sobre error brillante = 3,76');
    });
  });

  group('D-06 · BadgeEstado consume los roles (fuera _aclarar)',
      () {
    const textos = {
      EstadoMembresia.alDia: 'AL DÍA',
      EstadoMembresia.porVencer: 'VENCE EN 5 DÍAS',
      EstadoMembresia.vencido: 'VENCIDO 2 DÍAS',
      EstadoMembresia.sinPagos: 'SIN PAGOS',
      EstadoMembresia.congelado: 'CONGELADO',
    };
    const esperadoClaro = {
      EstadoMembresia.alDia: AppColores.exitoTextoClaro,
      EstadoMembresia.porVencer: AppColores.alertaTextoClaro,
      EstadoMembresia.vencido: AppColores.errorTextoClaro,
      EstadoMembresia.sinPagos: AppColores.textoSecundarioClaro,
      EstadoMembresia.congelado: AppColores.infoTextoClaro,
    };
    const esperadoOscuro = {
      EstadoMembresia.alDia: AppColores.exitoTextoOscuro,
      EstadoMembresia.porVencer: AppColores.alertaTextoOscuro,
      EstadoMembresia.vencido: AppColores.errorTextoOscuro,
      EstadoMembresia.sinPagos: AppColores.textoSecundarioOscuro,
      EstadoMembresia.congelado: AppColores.infoTextoOscuro,
    };

    Future<void> verificar(WidgetTester tester, ThemeData tema,
        Map<EstadoMembresia, Color> esperado) async {
      await tester.pumpWidget(MaterialApp(
        theme: tema,
        home: Scaffold(
          body: Column(
            children: [
              for (final e in textos.entries)
                BadgeEstado(estado: e.key, texto: e.value),
            ],
          ),
        ),
      ));
      for (final e in textos.entries) {
        final badge = find.ancestor(
            of: find.text(e.value), matching: find.byType(BadgeEstado));
        final icono = tester.widget<Icon>(
            find.descendant(of: badge, matching: find.byType(Icon)));
        final texto = tester.widget<Text>(find.text(e.value));
        expect(icono.color, esperado[e.key], reason: '${e.key} icono');
        expect(texto.style?.color, esperado[e.key],
            reason: '${e.key} texto');
      }
    }

    testWidgets('en claro: porVencer ya no es el #D97706 de 3,19 '
        'y congelado ya no es el azul brillante', (tester) async {
      await verificar(tester, AppTema.claro(), esperadoClaro);
      expect(esperadoClaro[EstadoMembresia.porVencer],
          isNot(AppColores.alertaOscuro));
      expect(esperadoClaro[EstadoMembresia.congelado],
          isNot(AppColores.info));
    });

    testWidgets('en oscuro: el frente es el rol EXACTO, sin el '
        'lerp de _aclarar', (tester) async {
      await verificar(tester, AppTema.oscuro(), esperadoOscuro);
    });
  });

  group('D-11 · categórica de trabajo', () {
    test('valores oscuros ≥ 3,0 sobre la superficie y variantes '
        'claras ≥ 3,0 sobre blanco', () {
      for (final c in [
        AppColores.entrenador2,
        AppColores.entrenador3,
        AppColores.entrenador4,
        AppColores.metodoEfectivo,
        AppColores.metodoTransferencia,
      ]) {
        expect(_contraste(c, AppColores.superficieOscuro),
            greaterThanOrEqualTo(3.0),
            reason: '$c sobre superficie oscura');
      }
      for (final c in [
        AppColores.entrenador2Claro,
        AppColores.entrenador3Claro,
        AppColores.entrenador4Claro,
        AppColores.metodoEfectivoClaro,
        AppColores.metodoTransferenciaClaro,
        // El dueño en claro es naranjaTexto (su variante legible).
        AppColores.naranjaTexto,
      ]) {
        expect(_contraste(c, Colors.white),
            greaterThanOrEqualTo(3.0),
            reason: '$c sobre blanco');
      }
      expect(_contraste(AppColores.naranja, AppColores.superficieOscuro),
          greaterThanOrEqualTo(3.0),
          reason: 'el dueño en oscuro es la marca');
    });

    testWidgets('colorEntrenador asigna por POSICIÓN y resuelve '
        'por tema; método igual', (tester) async {
      final resueltos = <Brightness, List<Color>>{};
      for (final tema in [AppTema.claro(), AppTema.oscuro()]) {
        // Theme directo (sin la animación de AnimatedTheme).
        await tester.pumpWidget(Directionality(
          textDirection: TextDirection.ltr,
          child: Theme(
            data: tema,
            child: Builder(builder: (context) {
              resueltos[tema.brightness] = [
                AppColores.colorEntrenador(context, 0),
                AppColores.colorEntrenador(context, 1),
                AppColores.colorEntrenador(context, 2),
                AppColores.colorEntrenador(context, 3),
                AppColores.colorEfectivo(context),
                AppColores.colorTransferencia(context),
              ];
              return const SizedBox.shrink();
            }),
          ),
        ));
      }
      expect(resueltos[Brightness.light], [
        AppColores.naranjaTexto,
        AppColores.entrenador2Claro,
        AppColores.entrenador3Claro,
        AppColores.entrenador4Claro,
        AppColores.metodoEfectivoClaro,
        AppColores.metodoTransferenciaClaro,
      ]);
      expect(resueltos[Brightness.dark], [
        AppColores.naranja,
        AppColores.entrenador2,
        AppColores.entrenador3,
        AppColores.entrenador4,
        AppColores.metodoEfectivo,
        AppColores.metodoTransferencia,
      ]);
    });
  });

  group('D-10 · iconos propios Pomo y Dosis', () {
    testWidgets('pintan a 22, 24 y 48 px sin excepciones',
        (tester) async {
      for (final tamano in [22.0, 24.0, 48.0]) {
        await tester.pumpWidget(MaterialApp(
          home: Scaffold(
            body: Row(
              children: [
                IconoPomo(tamano: tamano, color: AppColores.naranja),
                IconoDosis(tamano: tamano, color: AppColores.naranja),
              ],
            ),
          ),
        ));
        await tester.pump();
        expect(tester.takeException(), isNull,
            reason: 'a $tamano px');
        expect(tester.getSize(find.byType(IconoPomo)),
            Size.square(tamano));
        expect(tester.getSize(find.byType(IconoDosis)),
            Size.square(tamano));
        // Solo los CustomPaint de la fila (la app trae los
        // suyos por dentro).
        expect(
            find.descendant(
                of: find.byType(Row),
                matching: find.byType(CustomPaint)),
            findsNWidgets(2));
      }
    });
  });

  group('D-18 · un solo lenguaje de elevación', () {
    test('la clase de sombras deprecada no tiene llamadores: '
        'solo vive su definición en diseno.dart', () {
      final conReferencia = <String>[];
      for (final entidad
          in Directory('lib').listSync(recursive: true)) {
        if (entidad is File && entidad.path.endsWith('.dart')) {
          if (entidad.readAsStringSync().contains('AppSombra')) {
            conReferencia.add(entidad.path.replaceAll('\\', '/'));
          }
        }
      }
      expect(conReferencia, ['lib/ui/diseno.dart']);
      final diseno = File('lib/ui/diseno.dart').readAsStringSync();
      expect(diseno.contains('@Deprecated'), isTrue,
          reason: 'la definición queda marcada como deprecada');
    });
  });
}
