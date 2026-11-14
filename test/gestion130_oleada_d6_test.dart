/// Gestión 1.30 · Oleada D6 — UI130-20 (Buscar y
/// Vencimientos), UI130-21 (Ayuda buscable), UI130-22
/// (esqueletos con forma, ilustraciones de vacíos,
/// semántica y tacto), UI130-10 (EncabezadoSeccion
/// único), UI130-28 (foto en la bandeja), UI130-32
/// (barrido de movimiento y cascadas) y GEN-06 (el
/// distintivo de Control suma los cambios por subir).
///
/// Contrato que se fija:
/// - 10: un solo encabezado con tres variantes; la de
///   sección NO añade acolchado horizontal (fuera el
///   doble sangrado) y el ritmo es 24 antes / 8
///   después; la de panel absorbe el _tituloSeccion
///   privado de admin (fuente).
/// - 20: Buscar pierde el héroe carbón («en esta
///   vista» no existe) y gana la franja de una línea;
///   su menú «Más acciones» conserva ordenar ×4;
///   Vencimientos funde su «Ordenar:» en un menú
///   (fuente) y su banner es compacto (fuente).
/// - 21: Ayuda filtra en vivo por título y cuerpo sin
///   acentos, cuenta los resultados, auto-expande las
///   coincidencias y un tema sin coincidencias no
///   aparece; sin resultados hay EstadoVacio.
/// - 22: los esqueletos nuevos pintan; EstadoVacio con
///   ilustración pinta la imagen y sin marco ocupa
///   menos que con marco; los 12 assets existen y
///   están en el pubspec; los objetivos táctiles y las
///   etiquetas Semantics están en la fuente.
/// - 28: negocio.dart lleva foto_storage en los 6
///   avisos (4 del padrón + 2 recibos) y la bandeja
///   pinta el avatar con foto (fuente); sin foto, el
///   avatar cae a iniciales.
/// - 32: curvaPop es el token easeOutBack de siempre;
///   los pops y el anillo usan los tokens (fuente);
///   Panel y catálogo adoptan la cascada (fuente);
///   el total de Nómina nace animado (fuente).
/// - GEN-06: con cambiosPorSubir > 0 la derivación
///   suma UN ítem a Control con destino a la Cola; el
///   distintivo de Control es incidencias + cambios;
///   la línea de estado conserva su prioridad
///   (incidencias primero); admin alimenta la foto con
///   el conteo que ya cargaba (fuente).
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/ayuda.dart';
import 'package:ironbody_gym/ui/componentes.dart';
import 'package:ironbody_gym/ui/diseno.dart';
import 'package:ironbody_gym/ui/panel_modulos.dart';
import 'package:ironbody_gym/ui/panel_por_revisar.dart';
import 'package:ironbody_gym/ui/skeleton.dart';

Future<void> _pintar(
  WidgetTester tester,
  Widget hijo, {
  Size tamano = const Size(420, 640),
}) async {
  tester.view.physicalSize = tamano;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTema.claro(),
      home: Scaffold(body: hijo),
    ),
  );
  await tester.pump();
}

String _fuente(String ruta) => File(ruta).readAsStringSync();

void main() {
  group('D6 · UI130-10 EncabezadoSeccion único', () {
    testWidgets('la variante sección no añade acolchado: '
        'el título alinea con el contenido', (tester) async {
      await _pintar(
        tester,
        ListView(
          padding: const EdgeInsets.all(AppEspacio.lg),
          children: const [
            EncabezadoSeccion(titulo: 'Sección X'),
            Tarjeta(child: Text('contenido')),
          ],
        ),
      );
      final titulo =
          tester.getTopLeft(find.text('Sección X'));
      final tarjeta = tester.getTopLeft(find.byType(Tarjeta));
      expect(titulo.dx, tarjeta.dx,
          reason: 'sin doble sangrado: título y tarjeta '
              'arrancan en el mismo x');
    });

    testWidgets('la variante página trae su acolchado (16)',
        (tester) async {
      await _pintar(
        tester,
        const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            EncabezadoSeccion(
                titulo: 'Página X',
                variante: VarianteEncabezado.pagina),
          ],
        ),
      );
      expect(tester.getTopLeft(find.text('Página X')).dx,
          AppEspacio.lg);
    });

    testWidgets('el ritmo vertical es 24 antes y 8 después',
        (tester) async {
      await _pintar(
        tester,
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(height: 10, color: Colors.red),
            const EncabezadoSeccion(titulo: 'Ritmo'),
            Container(height: 10, color: Colors.blue),
          ],
        ),
      );
      final titulo = tester.getRect(find.text('Ritmo'));
      final antes = tester.getRect(find.byType(Container).first);
      final despues =
          tester.getRect(find.byType(Container).last);
      expect(titulo.top - antes.bottom, 24);
      expect(despues.top - titulo.bottom, 8);
    });

    testWidgets('golden: variante sección', (tester) async {
      await _pintar(
        tester,
        const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            EncabezadoSeccion(
                titulo: 'Ingresos',
                accionTexto: 'Ver todo'),
          ],
        ),
        tamano: const Size(420, 120),
      );
      await expectLater(
        find.byType(EncabezadoSeccion),
        matchesGoldenFile('goldens/d6_encabezado_seccion.png'),
      );
    });

    testWidgets('golden: variante página', (tester) async {
      await _pintar(
        tester,
        const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            EncabezadoSeccion(
                titulo: 'Identificación',
                variante: VarianteEncabezado.pagina),
          ],
        ),
        tamano: const Size(420, 120),
      );
      await expectLater(
        find.byType(EncabezadoSeccion),
        matchesGoldenFile('goldens/d6_encabezado_pagina.png'),
      );
    });

    testWidgets('golden: variante panel con aviso y derecha',
        (tester) async {
      await _pintar(
        tester,
        const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            EncabezadoSeccion(
                titulo: 'Necesita tu atención',
                variante: VarianteEncabezado.panel,
                aviso: true,
                derecha: 'hace 2 h'),
          ],
        ),
        tamano: const Size(420, 120),
      );
      expect(find.byIcon(Icons.warning_amber_rounded),
          findsOneWidget);
      expect(find.text('hace 2 h'), findsOneWidget);
      await expectLater(
        find.byType(EncabezadoSeccion),
        matchesGoldenFile('goldens/d6_encabezado_panel.png'),
      );
    });

    test('admin ya no tiene su encabezado privado (fuente)',
        () {
      final admin = _fuente('lib/ui/admin.dart');
      expect(admin, isNot(contains('_tituloSeccion(')));
      expect(admin, contains('VarianteEncabezado.panel'));
    });
  });

  group('D6 · UI130-20 Buscar y Vencimientos (fuente)', () {
    test('Buscar: franja de una línea, menú «más» con los '
        '4 órdenes y fuera el héroe', () {
      final b = _fuente('lib/ui/buscar.dart');
      expect(b, contains('FranjaResumenLista('));
      expect(b, contains("tooltip: 'Más acciones'"));
      expect(b, contains("value: 'orden:nombre'"));
      expect(b, contains("value: 'orden:venceAntes'"));
      expect(b, contains("value: 'orden:vencidosPrimero'"));
      expect(b, contains("value: 'orden:recientes'"));
      expect(b, isNot(contains('en esta vista')));
      expect(b, isNot(contains('gradienteCarbon')));
    });

    test('Vencimientos: banner compacto y orden en menú',
        () {
      final l = _fuente('lib/ui/listas.dart');
      expect(l, contains('SyncBanner(compact: true)'));
      expect(l, isNot(contains("Text('Ordenar: '")));
      expect(l, contains('CheckedPopupMenuItem'));
      expect(l, isNot(contains('DropdownButton<String>')));
    });
  });

  group('D6 · UI130-21 Ayuda buscable', () {
    testWidgets('filtra por título y cuerpo, cuenta y '
        'auto-expande; sin acentos también encuentra',
        (tester) async {
      tester.view.physicalSize = const Size(420, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTema.claro(),
          home: const AyudaScreen(),
        ),
      );
      await tester.pump();
      // Cierre §17 (×30): la aserción ListTile-sobre-
      // DecoratedBox de Tarjeta+ExpansionTile quedó
      // CORREGIDA en la raíz (Tarjeta sin onTap da ahora un
      // Material transparente propio a su contenido). Este
      // test ya no drena nada: afirma que no salta ninguna
      // excepción al pintar ni al buscar.
      void sinAserciones() {
        expect(tester.takeException(), isNull,
            reason: 'la aserción «ListTile background color» '
                'no debe volver');
      }

      sinAserciones();
      // Los 5 temas viven en la fila fija de chips.
      for (final tema in [
        'Tu trabajo diario',
        'Dinero',
        'Gestión',
        'La app',
        'Si algo falla',
      ]) {
        expect(find.widgetWithText(ActionChip, tema),
            findsOneWidget,
            reason: tema);
      }
      await tester.enterText(
          find.byType(TextField), 'renovación rápida');
      await tester.pump(const Duration(milliseconds: 350));
      sinAserciones();
      expect(find.text('Cobrar una mensualidad'),
          findsOneWidget);
      expect(find.text('1 resultado'), findsOneWidget);
      // El cuerpo de la coincidencia está en el árbol
      // (nace expandida al buscar).
      expect(find.textContaining('Renovación rápida'),
          findsOneWidget);
      // Lo que no coincide no aparece.
      expect(find.text('Inscribir un cliente'), findsNothing);
      // Sin acentos: «sincronizacion» encuentra
      // «Sincronización».
      await tester.enterText(
          find.byType(TextField), 'sincronizacion');
      await tester.pump(const Duration(milliseconds: 350));
      sinAserciones();
      expect(find.text('Sincronización'), findsOneWidget);
      // Sin resultados: el vacío de la casa.
      await tester.enterText(find.byType(TextField), 'zzzqq');
      await tester.pump(const Duration(milliseconds: 350));
      sinAserciones();
      expect(find.text('Sin resultados'), findsOneWidget);
    });

    test('la expansión al buscar está en la construcción '
        '(fuente)', () {
      final a = _fuente('lib/ui/ayuda.dart');
      expect(a, contains('initiallyExpanded: expandida'));
      expect(a, contains('expandida: buscando'));
      expect(a, contains('_temasAyuda'));
    });
  });

  group('D6 · UI130-22 esqueletos, ilustraciones y tacto',
      () {
    testWidgets('los esqueletos con forma pintan',
        (tester) async {
      await _pintar(tester, const SkeletonAjustes());
      expect(find.byType(SkeletonLinea), findsWidgets);
      await _pintar(tester, const SkeletonFicha());
      expect(find.byType(SkeletonTarjeta), findsWidgets);
    });

    testWidgets('EstadoVacio con ilustración pinta la '
        'imagen; sin marco ocupa menos que con marco',
        (tester) async {
      await _pintar(
        tester,
        const EstadoVacio(
          ilustracion: 'assets/vacio_lupa.webp',
          icono: Icons.search_off_rounded,
          titulo: 'Sin resultados',
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(Image), findsOneWidget);
      final conMarco =
          tester.getSize(find.byType(EstadoVacio)).height;
      await _pintar(
        tester,
        const EstadoVacio(
          sinMarco: true,
          ilustracion: 'assets/vacio_lupa.webp',
          icono: Icons.search_off_rounded,
          titulo: 'Sin resultados',
        ),
      );
      final sinMarco =
          tester.getSize(find.byType(EstadoVacio)).height;
      expect(sinMarco, lessThan(conMarco));
    });

    test('los 12 assets de la lámina existen y están en '
        'el pubspec', () {
      // 1.34 (carril arte): 9 de las 12 ilustraciones van
      // en WebP con alfa real; pomo, pastel y megafono
      // quedan en JPG (escenas con mueble, cabos del
      // carril — ver test/arte_134_contrato_test.dart).
      const enWebp = [
        'papelera', 'caja', 'escudo', 'sobre', 'lupa',
        'recepcion', 'reloj', 'calendario', 'cable',
      ];
      const enJpg = ['pomo', 'pastel', 'megafono'];
      final pubspec = _fuente('pubspec.yaml');
      for (final n in enWebp) {
        expect(File('assets/vacio_$n.webp').existsSync(),
            isTrue,
            reason: n);
        expect(pubspec, contains('assets/vacio_$n.webp'),
            reason: n);
      }
      for (final n in enJpg) {
        expect(File('assets/vacio_$n.jpg').existsSync(),
            isTrue,
            reason: n);
        expect(pubspec, contains('assets/vacio_$n.jpg'),
            reason: n);
      }
    });

    test('objetivos táctiles y semántica (fuente)', () {
      final dash = _fuente('lib/ui/dashboard.dart');
      expect(dash, contains("label: 'Ingresos del"));
      expect(dash, contains("'\$etiqueta: \$conteo'"));
      final ins = _fuente('lib/ui/inscribir.dart');
      expect(ins, contains('BoxConstraints(minHeight: 48)'));
      expect(ins, contains('Ir al paso'));
      final serv = _fuente('lib/ui/servicios.dart');
      expect(serv, contains('minimumSize: const Size(0, 48)'));
      expect(serv, isNot(contains('MaterialTapTargetSize.shrinkWrap')));
    });

    test('los swaps de carga usan los esqueletos (fuente)',
        () {
      expect(_fuente('lib/ui/servicios_admin.dart'),
          contains('SkeletonAjustes(grupos: 4)'));
      expect(_fuente('lib/ui/cierre_mes.dart'),
          contains('SkeletonLista()'));
      expect(_fuente('lib/ui/ficha.dart'),
          contains('SkeletonFicha()'));
    });
  });

  group('D6 · UI130-28 foto en la bandeja', () {
    test('negocio lleva foto_storage en los 6 avisos y '
        'la bandeja pinta el avatar (fuente)', () {
      final n = _fuente('lib/negocio.dart');
      expect(
          "'foto_storage': c['foto_storage']"
              .allMatches(n)
              .length,
          4);
      expect(
          "'foto_storage': c?['foto_storage']"
              .allMatches(n)
              .length,
          2);
      expect(_fuente('lib/ui/bandeja_whatsapp.dart'),
          contains('AvatarClienteConFoto('));
    });

    testWidgets('sin foto, el avatar cae a iniciales',
        (tester) async {
      await _pintar(
        tester,
        const AvatarClienteConFoto(
            nombre: 'Ana Paz', fotoStorage: null),
      );
      expect(find.byType(AvatarCliente), findsOneWidget);
      expect(find.text('AP'), findsOneWidget);
    });
  });

  group('D6 · UI130-32 movimiento y cascadas', () {
    test('curvaPop es el easeOutBack de siempre', () {
      expect(AppMovimiento.curvaPop, Curves.easeOutBack);
      expect(AppMovimiento.larga,
          const Duration(milliseconds: 300));
      expect(AppMovimiento.media,
          const Duration(milliseconds: 220));
    });

    test('pops, anillo, cascadas y total de Nómina '
        '(fuente)', () {
      expect(_fuente('lib/ui/confirmacion_cobro.dart'),
          contains('AppMovimiento.curvaPop'));
      expect(
          _fuente('lib/ui/dialogo_confirmar_inscripcion.dart'),
          contains('AppMovimiento.curvaPop'));
      expect(_fuente('lib/ui/ficha_secciones.dart'),
          contains('duration: AppMovimiento.larga'));
      expect(_fuente('lib/ui/admin.dart'),
          contains('EntradaCascada('));
      expect(_fuente('lib/ui/suplementos.dart'),
          contains('ItemCascada('));
      expect(_fuente('lib/ui/nomina.dart'),
          contains('valorAnimado: base'));
    });

    testWidgets('FranjaResumenLista pinta principal y '
        'secundario', (tester) async {
      await _pintar(
        tester,
        const Column(
          children: [
            FranjaResumenLista(
                principal: '128 clientes',
                secundario: 'Actualizado hace 5 min'),
          ],
        ),
      );
      expect(find.text('128 clientes'), findsOneWidget);
      expect(find.text('Actualizado hace 5 min'),
          findsOneWidget);
    });
  });

  group('D6 · GEN-06 cambios por subir en Control', () {
    test('con cambios > 0 nace UN ítem a la Cola; con 0, '
        'ninguno', () {
      final items = pendientesPorModulo(
          const FotoPendientesModulos(cambiosPorSubir: 3));
      final control = items[ModuloPanel.control]!;
      expect(control, hasLength(1));
      expect(control.single.destino,
          DestinoPorRevisar.colaSincronizacion);
      expect(control.single.titulo, 'Cambios por subir');
      expect(control.single.detalle,
          '3 cambios esperando conexión');
      final uno = pendientesPorModulo(
          const FotoPendientesModulos(cambiosPorSubir: 1));
      expect(uno[ModuloPanel.control]!.single.detalle,
          '1 cambio esperando conexión');
      final cero = pendientesPorModulo(
          const FotoPendientesModulos());
      expect(cero[ModuloPanel.control], isEmpty);
    });

    // El llamante real (admin) pasa el MISMO conteo a
    // la foto (cambiosPorSubir, que arma el ítem) y a
    // modulosPanel (pendientesSubir, que suma el
    // distintivo): el arnés lo refleja tal cual.
    List<DatoModuloPanel> modulosDe(FotoPendientesModulos f,
            {int pendientesSubir = 0}) =>
        modulosPanel(
          items: pendientesPorModulo(f),
          pendCajaTotal: 0,
          cajaHoyTotal: 0,
          clientesActivos: 0,
          stockCritico: 0,
          pendientesSubir: pendientesSubir,
        );

    test('el distintivo de Control suma incidencias + '
        'cambios; la línea conserva su prioridad', () {
      const inc = (
        tipo: 'pago_mensual',
        cliente: 'Ana',
        dispositivo: null,
        creadaEn: null
      );
      final ambos = modulosDe(
          const FotoPendientesModulos(
              cambiosPorSubir: 3, incidencias: [inc, inc]),
          pendientesSubir: 3);
      expect(ambos[5].badge, 5,
          reason: '2 incidencias + 3 cambios');
      expect(ambos[5].estado,
          '2 incidencias por revisar');
      final soloCambios = modulosDe(
          const FotoPendientesModulos(cambiosPorSubir: 4),
          pendientesSubir: 4);
      expect(soloCambios[5].badge, 4);
      expect(soloCambios[5].estado, '4 cambios por subir');
      final nada = modulosDe(const FotoPendientesModulos());
      expect(nada[5].badge, isNull);
      expect(nada[5].estado, 'Sistema al día');
    });

    test('admin alimenta la foto con el conteo que ya '
        'cargaba y resuelve el destino (fuente)', () {
      final admin = _fuente('lib/ui/admin.dart');
      expect(admin, contains('cambiosPorSubir: _pendientesSubir'));
      expect(admin,
          contains('DestinoPorRevisar.colaSincronizacion'));
      expect(admin, contains('const ColaScreen()'));
    });
  });
}
