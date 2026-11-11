/// Gestión 1.29 · Oleada 5 (Home y Panel) + D-21 + D-23.
///
/// Contrato que se fija:
/// · D-04: el banner de sync resuelve gradiente y letra
///   por variante pura tokenizada (fuera los literales de
///   widgets.dart); sobre los dos ámbar la letra es
///   grafito y pasa AA en ambos extremos del gradiente.
/// · D-23: badge y franja «POR REVISAR» salen de la MISMA
///   derivación pura de ítems por módulo (badge ==
///   ítems.length por construcción, por fuente, 0/1/N;
///   hoy y ayer desagregados en Equipo).
/// · FA-04: el contador de tarifas por revisar del Panel
///   consume la misma fuente fusionada y el mismo
///   predicado que la pantalla de Tarifas.
/// · FB-12: el buzón de Home suma TRES fuentes locales
///   (reservas, adelantos, rellenos) con texto por partes.
/// · FB-15: el buscador encuentra el compositor por
///   «anuncio» y el centro por «avisos», sin ambigüedad.
/// · D-21/D-14: cabecera premium (wordmark, logo en
///   tarjeta, botón de sync vivo) y glifo canónico de
///   «añadir persona» en Home.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/sync.dart';
import 'package:ironbody_gym/tarifa_especial.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:ironbody_gym/ui/ajustes.dart';
import 'package:ironbody_gym/ui/buzon_dueno.dart';
import 'package:ironbody_gym/ui/cola.dart';
import 'package:ironbody_gym/ui/diseno.dart';
import 'package:ironbody_gym/ui/home.dart';
import 'package:ironbody_gym/ui/incidencias_sync.dart';
import 'package:ironbody_gym/ui/inscribir.dart';
import 'package:ironbody_gym/ui/panel_buscador.dart';
import 'package:ironbody_gym/ui/panel_modulos.dart';
import 'package:ironbody_gym/ui/panel_por_revisar.dart';
import 'package:ironbody_gym/ui/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// Contraste WCAG (la misma cuenta del test de fundación).
double _luminancia(Color c) {
  double f(double v) =>
      v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * f(c.r) + 0.7152 * f(c.g) + 0.0722 * f(c.b);
}

double _contraste(Color a, Color b) {
  final la = _luminancia(a);
  final lb = _luminancia(b);
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

void main() {
  // Supabase se inicializa UNA vez y fuera de FakeAsync
  // (setUpAll corre en zona real): si nace dentro de un
  // testWidgets, el timer periódico de auto-refresh de
  // gotrue queda como Timer falso pendiente y tumba el
  // test al verificar invariantes.
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    try {
      await Supabase.initialize(
          url: 'http://127.0.0.1:9', anonKey: 'dummy');
    } catch (_) {}
  });

  group('D-04 · variante del banner por foto del motor', () {
    test('las fases activas y el error mapean directo', () {
      expect(varianteBannerDe(const SyncStatus(phase: SyncPhase.uploading)),
          VarianteBanner.enviando);
      expect(
          varianteBannerDe(const SyncStatus(phase: SyncPhase.downloading)),
          VarianteBanner.descargando);
      expect(varianteBannerDe(const SyncStatus(phase: SyncPhase.photos)),
          VarianteBanner.fotos);
      expect(varianteBannerDe(const SyncStatus(phase: SyncPhase.error)),
          VarianteBanner.error);
    });

    test('el reposo se parte por sus tres dimensiones', () {
      expect(varianteBannerDe(const SyncStatus(enLinea: false)),
          VarianteBanner.sinConexion);
      expect(varianteBannerDe(const SyncStatus(pending: 3)),
          VarianteBanner.pendientes);
      expect(varianteBannerDe(const SyncStatus(hayNovedades: true)),
          VarianteBanner.novedades);
      expect(varianteBannerDe(const SyncStatus()),
          VarianteBanner.sinSincronizar);
      expect(
          varianteBannerDe(SyncStatus(lastOk: DateTime(2026, 11, 7))),
          VarianteBanner.alDia);
      // Prioridad del reposo: sin conexión manda sobre
      // pendientes, y pendientes sobre novedades.
      expect(
          varianteBannerDe(
              const SyncStatus(enLinea: false, pending: 2)),
          VarianteBanner.sinConexion);
      expect(
          varianteBannerDe(
              const SyncStatus(pending: 2, hayNovedades: true)),
          VarianteBanner.pendientes);
    });
  });

  // 1.30 (Oleada D2, UI130-07): el grupo D-04 fijaba los
  // gradientes del banner y su letra segura. UI130-07
  // RETIRA el gradiente (la auditoría: «un solo lenguaje,
  // silencioso por defecto»): el mapa variante → nivel y
  // el color de estado viven en el test de la oleada D2;
  // aquí queda lo que sobrevive de D-04: ningún literal
  // en widgets.dart y la letra segura donde el color
  // pleno sigue existiendo (AvisoEstado sobre *Fondo).
  group('D-04 · letra segura tras UI130-07 (sin gradientes)', () {
    test('widgets.dart no conserva ningún literal de color', () {
      final src = File('lib/ui/widgets.dart').readAsStringSync();
      expect(src.contains('Color(0x'), isFalse,
          reason: 'D-04/UI130-07: la fila neutra y la píldora '
              'viven de tokens de diseno.dart');
      expect(src.contains('coloresBanner'), isFalse,
          reason: 'UI130-07: el gradiente del banner se retiró');
    });

    test('el blanco sobre los fondos de AvisoEstado pasa AA '
        '(es la letra que queda sobre color pleno)', () {
      for (final fondo in [
        AppColores.errorFondo,
        AppColores.avisoFondo,
        AppColores.exitoFondo,
        AppColores.infoFondo,
      ]) {
        expect(_contraste(Colors.white, fondo),
            greaterThanOrEqualTo(4.5),
            reason: 'blanco sobre $fondo');
      }
    });

    testWidgets('el banner en reposo sin sincronizar pinta '
        'la fila NEUTRA: título en color de texto, sin '
        'gradiente (antes: blanco sobre gris)', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: SyncBanner()),
      ));
      await tester.pump();
      final titulo = tester.widget<Text>(find.text('Sin sincronizar'));
      expect(titulo.style?.color, isNot(Colors.white),
          reason: 'UI130-07: el texto va sobre la superficie, '
              'no sobre un gradiente');
      // Ningún contenedor del banner lleva gradiente.
      final conGradiente = find.byWidgetPredicate((w) =>
          w is Container &&
          w.decoration is BoxDecoration &&
          (w.decoration as BoxDecoration).gradient != null);
      expect(conGradiente, findsNothing);
    });
  });

  group('D-23 · derivación única de ítems por módulo', () {
    List<DatoModuloPanel> modulosDe(FotoPendientesModulos foto) =>
        modulosPanel(
          items: pendientesPorModulo(foto),
          pendCajaTotal: 0,
          cajaHoyTotal: 0,
          clientesActivos: 0,
          stockCritico: 0,
          pendientesSubir: 0,
        );

    test('foto vacía: seis listas vacías y ningún badge', () {
      final items = pendientesPorModulo(const FotoPendientesModulos());
      expect(items.keys, containsAll(ModuloPanel.values));
      for (final m in ModuloPanel.values) {
        expect(items[m], isEmpty, reason: '$m');
      }
      for (final d in modulosDe(const FotoPendientesModulos())) {
        expect(d.badge, isNull, reason: d.titulo);
      }
    });

    test('Equipo: hoy y ayer DESAGREGADOS — 1+1 = badge 2 '
        'y un ítem por día, con su entrenador', () {
      final foto = FotoPendientesModulos(
        sinReporteHoy: [(turno: 'mañana', entrenador: 'Gabriel')],
        sinReporteAyer: [(turno: 'tarde', entrenador: null)],
      );
      final items = pendientesPorModulo(foto)[ModuloPanel.equipo]!;
      expect(items, hasLength(2));
      expect(items[0].titulo, 'Turno de mañana sin reporte de caja');
      expect(items[0].detalle, 'Hoy · Gabriel');
      expect(items[0].destino, DestinoPorRevisar.cierreCaja);
      expect(items[1].titulo, 'Turno de tarde sin reporte de caja');
      // Sin asignación, el detalle es solo el día: nunca
      // un nombre inventado.
      expect(items[1].detalle, 'Ayer');
      final modulos = modulosDe(foto);
      expect(modulos[2].badge, items.length,
          reason: 'el badge ES la longitud de la franja');
      expect(modulos[2].badge, 2);
    });

    test('Control: un ítem por incidencia, con la '
        'redacción de la pantalla destino y antigüedad',
        () {
      final foto = FotoPendientesModulos(incidencias: inidencias3);
      final items = pendientesPorModulo(foto)[ModuloPanel.control]!;
      expect(items, hasLength(3));
      expect(items[0].titulo,
          'Operación rechazada: Pago de mensualidad');
      expect(items[0].detalle, contains('Cliente: Ana Pérez'));
      expect(items[0].detalle, contains('Teléfono de Duany'));
      expect(items[0].detalle, contains('hace'));
      expect(items[0].destino, DestinoPorRevisar.incidenciasSync);
      expect(modulosDe(foto)[5].badge, 3);
    });

    test('Caja, Clientes, Suplementos y Configuración: '
        'badge == ítems por fuente', () {
      final foto = FotoPendientesModulos(
        pendientesLiquidar: [
          (nombre: 'Duany', total: 1400),
          (nombre: 'Gabriel', total: 200),
        ],
        solicitudes: [
          (nombre: 'Invitado Uno', desde: null),
        ],
        reportes: [
          (nombre: 'Invitado Dos', monto: 1000, referencia: 'REF1'),
          (nombre: 'Invitado Tres', monto: 1000, referencia: ''),
        ],
        vales: [(nombre: 'Cliente Vale', dias: 7)],
        reservas: [
          (suplemento: 'C4', cliente: 'Ana Pérez', cantidad: 2),
          (suplemento: 'Proteína', cliente: 'Luis', cantidad: 1),
        ],
        preciosSinFijar: ['mensualidad', 'tasa_usd'],
      );
      final items = pendientesPorModulo(foto);
      final modulos = modulosDe(foto);
      // La igualdad compuerta, módulo a módulo.
      for (var i = 0; i < ModuloPanel.values.length; i++) {
        expect(modulos[i].badge ?? 0,
            items[ModuloPanel.values[i]]!.length,
            reason: ModuloPanel.values[i].name);
      }
      expect(items[ModuloPanel.caja]![0].titulo, 'Liquidar a Duany');
      expect(items[ModuloPanel.caja]![0].detalle,
          contains('1400 CUP por entregar'));
      final clientes = items[ModuloPanel.clientes]!;
      expect(clientes.map((i) => i.destino), [
        DestinoPorRevisar.solicitudesInvitados,
        DestinoPorRevisar.reportesPlus,
        DestinoPorRevisar.reportesPlus,
        DestinoPorRevisar.valesPremios,
      ]);
      expect(clientes[3].detalle, 'Premio de 7 días por aprobar');
      expect(modulos[1].estado, contains('1 vale por aprobar'));
      expect(items[ModuloPanel.suplementos]![0].detalle,
          'Ana Pérez · 2 uds');
      final config = items[ModuloPanel.configuracion]!;
      expect(config[0].detalle, 'Mensualidad en efectivo');
      expect(config[1].detalle, 'Tasa USD (CUP por 1 USD)');
    });
  });

  group('D-23 · franja «POR REVISAR» (widget)', () {
    testWidgets('sin ítems no pinta nada; con ítems, '
        'tocar uno entrega ESE ítem', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
            body: FranjaPorRevisar(items: [], onTapItem: _noop)),
      ));
      expect(find.text('POR REVISAR'), findsNothing);

      ItemPorRevisar? tocado;
      final items = pendientesPorModulo(FotoPendientesModulos(
          sinReporteHoy: [
            (turno: 'mañana', entrenador: 'Gabriel')
          ]))[ModuloPanel.equipo]!;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: FranjaPorRevisar(
              items: items, onTapItem: (i) => tocado = i),
        ),
      ));
      expect(find.text('POR REVISAR'), findsOneWidget);
      expect(find.text('Turno de mañana sin reporte de caja'),
          findsOneWidget);
      expect(find.text('Hoy · Gabriel'), findsOneWidget);
      await tester
          .tap(find.text('Turno de mañana sin reporte de caja'));
      expect(tocado, same(items.single));
    });

    testWidgets('el ítem de Control abre '
        'IncidenciasSyncScreen (la puerta nueva)', (tester) async {
      _mockAppLinks();
      await tester.runAsync(() async {
        await _bdVacia();
      });
      await _fijarSesionDueno(tester);
      final items = pendientesPorModulo(FotoPendientesModulos(
          incidencias: [
            (
              tipo: 'pago_mensual',
              cliente: 'Ana Pérez',
              dispositivo: null,
              creadaEn: ahoraHabana(),
            ),
          ]))[ModuloPanel.control]!;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(builder: (context) {
            return FranjaPorRevisar(
              items: items,
              // El mismo destino que resuelve admin.dart
              // para DestinoPorRevisar.incidenciasSync.
              onTapItem: (_) => Navigator.of(context).push(
                MaterialPageRoute(
                    builder: (_) => const IncidenciasSyncScreen()),
              ),
            );
          }),
        ),
      ));
      await tester.tap(find.textContaining('Operación rechazada'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(IncidenciasSyncScreen), findsOneWidget);
      // La carga de la pantalla destino es async real
      // (ffi): se deja completar en runAsync y se pinta.
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(seconds: 2));
      });
      await tester.pump();
      // La pantalla destino cargó su lista (vacía aquí):
      // es la de sync, no la de reportes.
      expect(find.text('Sin incidencias pendientes.'),
          findsOneWidget);
    });
  });

  group('FA-04 · un número, dos escaparates', () {
    test('la fusión espejo+local con el predicado T14: '
        'por vencer + vencida cuentan; la renovada en '
        'local sin bajar al espejo, no', () async {
      final db = await _bdVacia();
      final hoy = ahoraHabana();
      String iso(DateTime d) => d.toIso8601String().substring(0, 10);
      final en3 = iso(hoy.add(const Duration(days: 3)));
      final en20 = iso(hoy.add(const Duration(days: 20)));
      final ayer = iso(hoy.subtract(const Duration(days: 1)));
      final hace5 = iso(hoy.subtract(const Duration(days: 5)));
      final en30 = iso(hoy.add(const Duration(days: 30)));

      await _insertarEspejoTarifa(db,
          id: 'e1', clienteId: 11, hasta: en3, ts: '2026-11-01T10:00:00');
      await _insertarEspejoTarifa(db,
          id: 'e2', clienteId: 12, hasta: en20, ts: '2026-11-01T10:00:00');
      await _insertarEspejoTarifa(db,
          id: 'e3', clienteId: 13, hasta: ayer, ts: '2026-11-01T10:00:00');
      await _insertarEspejoTarifa(db,
          id: 'e4', clienteId: 14, hasta: hace5, ts: '2026-11-01T10:00:00');
      // e4 renovada SOLO en local (aún no bajó al espejo):
      // la fusión manda la fila local, más reciente.
      await db.insert('tarifa_especial', {
        'id': 'e4',
        'cliente_id': 14,
        'nombre': 'Renovada',
        'monto_efectivo': 1000,
        'monto_transferencia': null,
        'periodo': 'mensual',
        'vigente_desde': iso(hoy),
        'vigente_hasta': en30,
        'motivo': 'renovación',
        'otorgado_por': null,
        'activa': 1,
        'historial': '[]',
        'creada_ts': hoy.toIso8601String(),
        'actualizada_ts': hoy.toIso8601String(),
      });

      // La cifra del Panel (la función compartida)…
      expect(await contarTarifasPorRevisar(), 2);
      // …y la del aviso de la pantalla de Tarifas, con su
      // propia aritmética (vencidas + por vencer sobre
      // tarifasActivas): EL MISMO número.
      final hoyIso = hoyHabanaIso();
      final activas = await tarifasActivas();
      final deLaPantalla = activas
          .where((e) =>
              estadoRevisionTarifa(e, hoyIso) == 'vencida' ||
              estadoRevisionTarifa(e, hoyIso) == 'por_vencer')
          .length;
      expect(deLaPantalla, 2);
    });
  });

  group('FB-15 · buscador sin ambigüedad', () {
    List<String> idsDe(String consulta) =>
        buscarFuncionesPanel(consulta).map((f) => f.id).toList();

    test('«anuncio» ya no lleva a ninguna puerta (§15)', () {
      // 1.30 (§15, decisión de Jc 2026-11-08): la puerta
      // «Anuncios» del Panel se retiró — la tabla
      // cliente_anuncios nació vacía y el compositor
      // nunca se usó; la puerta viva de avisos es el
      // centro de avisos. La pantalla del compositor
      // queda en el árbol, sin puerta.
      expect(idsDe('anuncio'), isEmpty);
      expect(idsDe('publicar'), isNot(contains('anuncios')));
      expect(idsDe('pantalla principal'),
          isNot(contains('anuncios')));
    });

    test('«avisos» lleva al centro de avisos renombrado', () {
      final ids = idsDe('avisos');
      expect(ids, contains('avisos_clientes'));
      expect(ids, isNot(contains('anuncios')));
      final entrada = buscarFuncionesPanel('avisos')
          .firstWhere((f) => f.id == 'avisos_clientes');
      expect(entrada.titulo, 'Avisos al centro de avisos');
    });

    test('«incidencias» devuelve las dos, desambiguadas por título', () {
      final res = buscarFuncionesPanel('incidencias');
      final porId = {for (final f in res) f.id: f};
      expect(porId.keys, containsAll(['incidencias', 'incidencias_sync']));
      expect(porId['incidencias']!.titulo, 'Incidencias (reportes)');
      expect(porId['incidencias_sync']!.titulo, 'Incidencias de sync');
      // Los sinónimos de sync ya no cuelgan de los reportes.
      expect(idsDe('operaciones rechazadas'), ['incidencias_sync']);
      expect(idsDe('reportes de clientes'), contains('incidencias'));
      expect(idsDe('reportes de clientes'),
          isNot(contains('incidencias_sync')));
    });

    test('el resolvedor del Panel: incidencias_sync sí; '
        'anuncios ya no (§15)', () {
      final admin = File('lib/ui/admin.dart').readAsStringSync();
      // 1.30 (§15): la ruta «anuncios» se retiró del
      // Panel con la puerta (decisión de Jc).
      expect(admin, isNot(contains("case 'anuncios':")));
      expect(admin, isNot(contains('PanelAnunciosScreen')));
      // 1.32 (Oleada 2 F1, desviación 3): el resolvedor del
      // Panel DELEGA en el único, el de la Lupa — el caso
      // «incidencias_sync» vive ahora allí y el Panel lo
      // alcanza por la delegación.
      expect(admin, contains('abrirFuncionLupa'));
      final lupa =
          File('lib/ui/lupa_universal.dart').readAsStringSync();
      expect(lupa, contains("case 'incidencias_sync':"));
      expect(lupa, contains('const IncidenciasSyncScreen()'));
    });
  });

  group('FB-12 · buzón del dueño (tres fuentes, H-08)', () {
    test('cero en las tres: el aviso no existe', () {
      const b = ConteoBuzon();
      expect(b.hay, isFalse);
      expect(b.total, 0);
      expect(b.partes, isEmpty);
      expect(b.textoCompleto, '');
    });

    test('1 en cada fuente: singular y destino propio', () {
      const b = ConteoBuzon(reservas: 1, adelantos: 1, rellenos: 1);
      expect(b.hay, isTrue);
      expect(b.total, 3);
      expect(b.partes.map((p) => p.destino),
          [DestinoBuzon.reservas, DestinoBuzon.adelantos, DestinoBuzon.rellenos]);
      expect(b.partes.map((p) => p.texto), [
        '1 reserva por responder',
        '1 solicitud de adelanto',
        '1 solicitud de relleno',
      ]);
      expect(
          b.textoCompleto,
          '1 reserva por responder · 1 solicitud de adelanto · '
          '1 solicitud de relleno');
    });

    test('N en cada fuente: plural y suma de las tres', () {
      const b = ConteoBuzon(reservas: 2, adelantos: 1, rellenos: 3);
      expect(b.total, 6);
      expect(
          b.textoCompleto,
          '2 reservas por responder · 1 solicitud de adelanto · '
          '3 solicitudes de relleno');
      // Una fuente en cero no deja parte vacía ni separador colgando.
      const soloRellenos = ConteoBuzon(rellenos: 2);
      expect(soloRellenos.partes, hasLength(1));
      expect(soloRellenos.textoCompleto, '2 solicitudes de relleno');
      const soloAdelantos = ConteoBuzon(adelantos: 4);
      expect(soloAdelantos.textoCompleto, '4 solicitudes de adelanto');
    });
  });

  group('D-21/D-14 · el marco táctico (reescrito en la 1.32)', () {
    // La cabecera premium de la 1.29/1.30 (wordmark, logo en
    // tarjeta, campana, selector de niveles y dial FAB) se
    // jubiló con el rediseño «Mostrador Táctico»: la
    // cabecera persistente es CabeceraMarco (marco.dart) y
    // las acciones viven en el Dock. Los contratos de
    // D-21/D-14 que SOBREVIVEN se fijan aquí contra su
    // forma nueva; lo jubilado se afirma ausente.

    test('el marco no tiene literales de color', () {
      final marco = File('lib/ui/marco.dart').readAsStringSync();
      expect(marco.contains('Color(0x'), isFalse,
          reason: 'D-21: el marco vive de tokens (diseno.dart)');
      // Y la cabecera vieja ya no existe en Home.
      final home = File('lib/ui/home.dart').readAsStringSync();
      expect(home.contains('Widget _cabecera()'), isFalse);
      expect(home.contains('class _EntradaCabecera'), isFalse);
      expect(home.contains('class _BotonCabecera'), isFalse);
    });

    test('D-14: el glifo canónico manda y el Cobrar del Dock '
        'va en grafito sobre la marca', () {
      final marco = File('lib/ui/marco.dart').readAsStringSync();
      expect(marco.contains('person_add_alt_1_rounded'), isFalse);
      expect(marco.contains('Icons.person_add_rounded'), isTrue);
      // El heredero del «activo en grafito sobre naranja»:
      // el Cobrar del Dock — la única acción de marca —
      // lleva icono y etiqueta en grafito (sobreMarca).
      final desde = marco.indexOf('class DockMostrador');
      expect(desde, greaterThanOrEqualTo(0));
      final dock = marco.substring(desde);
      expect(dock, contains('AppColores.naranja'));
      expect(dock, contains('AppColores.sobreMarca'));
    });

    testWidgets('la cabecera del marco: la píldora lleva a '
        'la Cola y el perfil a Ajustes', (tester) async {
      _mockAppLinks();
      await tester.runAsync(() async {
        await _bdVacia();
      });
      tester.view.physicalSize = const Size(960, 1680);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(const MaterialApp(home: HomeScreen()));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(seconds: 11));
      }
      // Los diálogos de apertura (permisos/novedades)
      // interceptan los toques: se descartan como en el
      // arnés de home_scroll, sin hit-test.
      Future<void> descartarDialogos() async {
        for (var i = 0; i < 6; i++) {
          if (find.byType(AlertDialog).evaluate().isEmpty) break;
          Navigator.of(tester.element(find.byType(HomeScreen)))
              .popUntil((r) => r.isFirst);
          await tester.pump(const Duration(milliseconds: 400));
        }
      }

      // Tras un pop, la ruta Home vuelve con su
      // transición de entrada: se asienta a tramos
      // cortos y se descartan los diálogos tardíos.
      Future<void> volverAHome() async {
        for (var i = 0; i < 15; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        await descartarDialogos();
      }

      await descartarDialogos();

      // La cabecera vieja no vuelve: ni wordmark ni su
      // llave en el árbol.
      expect(
          find.byWidgetPredicate((w) =>
              w is RichText &&
              w.text.toPlainText() == 'IRON BODY GYM'),
          findsNothing);
      expect(find.byKey(const ValueKey('home-cabecera')),
          findsNothing);

      // La píldora de sync del marco: única señal y única
      // puerta a la Cola (contrato UI130-05, heredado).
      expect(find.byType(SyncPill), findsOneWidget);
      await tester
          .tap(find.byKey(const ValueKey('marco-pildora')));
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(ColaScreen), findsOneWidget);
      Navigator.of(tester.element(find.byType(ColaScreen))).pop();
      await volverAHome();
      expect(find.byType(ColaScreen), findsNothing);

      // El avatar abre el menú de perfil y «Mi perfil y
      // ajustes» lleva a Ajustes (la puerta que el
      // logo-tarjeta de la cabecera vieja abría).
      await tester.tap(find.byKey(const ValueKey('marco-perfil')));
      // El menú despliega con animación y su ruta ignora
      // toques hasta asentarse: se asienta a tramos.
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 300));
      }
      expect(find.text('Mi perfil y ajustes'), findsOneWidget);
      // El toque va a la FILA del ítem (su InkWell entero),
      // no al texto: el centro del texto cae sobre la
      // animación del menú en este arnés.
      await tester.tap(find.widgetWithText(
          PopupMenuItem<String>, 'Mi perfil y ajustes'));
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(AjustesScreen), findsOneWidget);

      // Cierre: desmontar Home y drenar la cadena del
      // motor (su temporizador de 5 s), como siempre.
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
    });

    testWidgets('el Dock sustituye al dial: sin FAB y su '
        '«Inscribir» navega', (tester) async {
      _mockAppLinks();
      await tester.runAsync(() async {
        await _bdVacia();
      });
      tester.view.physicalSize = const Size(960, 1680);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(const MaterialApp(home: HomeScreen()));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(seconds: 11));
      }
      for (var i = 0; i < 6; i++) {
        if (find.byType(AlertDialog).evaluate().isEmpty) break;
        Navigator.of(tester.element(find.byType(HomeScreen)))
            .popUntil((r) => r.isFirst);
        await tester.pump(const Duration(milliseconds: 400));
      }

      // El dial flotante se jubiló con el marco: ni un FAB
      // ni su tooltip en la cáscara (las ventas rápidas de
      // Servicios viven ahora en el Pilar Tienda).
      expect(find.byType(FloatingActionButton), findsNothing);
      expect(find.byTooltip('Acciones rápidas'), findsNothing);

      // El «Inscribir» del Dock — el único de la pantalla —
      // lleva el glifo canónico de D-14 y navega.
      final boton = find.byKey(const ValueKey('dock-inscribir'));
      expect(boton, findsOneWidget);
      expect(
          find.descendant(
              of: boton,
              matching: find.byIcon(Icons.person_add_rounded)),
          findsOneWidget);
      await tester.tap(boton);
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(InscribirScreen), findsOneWidget);

      // Cierre con el mismo drenaje de la cabecera.
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
    });
  });
}

/// Tres incidencias de ejemplo para la derivación.
final inidencias3 = [
  (
    tipo: 'pago_mensual',
    cliente: 'Ana Pérez',
    dispositivo: 'Teléfono de Duany',
    creadaEn: ahoraHabana().subtract(const Duration(hours: 2)),
  ),
  (
    tipo: 'pago_mensual',
    cliente: null,
    dispositivo: 'Teléfono de Gabriel',
    creadaEn: ahoraHabana().subtract(const Duration(hours: 5)),
  ),
  (
    tipo: 'inscribir',
    cliente: 'Luis',
    dispositivo: null,
    creadaEn: ahoraHabana().subtract(const Duration(days: 1)),
  ),
];

void _noop(ItemPorRevisar _) {}

/// app_links (deep links de Supabase Auth): sin mock, la
/// activación de su canal de eventos lanza
/// MissingPluginException y tumba el test que esté
/// corriendo (la pauta de suplementos_rediseno_test).
void _mockAppLinks() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockStreamHandler(
          const EventChannel('com.llfbandit.app_links/events'),
          MockStreamHandler.inline(onListen: (args, events) {}));
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
          const MethodChannel('com.llfbandit.app_links/messages'),
          (call) async => null);
}

/// BD FFI vacía (la pauta de los tests de la oleada 4:
/// factory sin isolate para que el ciclo de carga no se
/// bloquee con FakeAsync).
Future<Database> _bdVacia() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfiNoIsolate;
  SharedPreferences.setMockInitialValues({});
  final dir = await getDatabasesPath();
  try {
    await File(p.join(dir, 'ironbody.db')).delete();
  } catch (_) {}
  await LocalDb.resetParaTest();
  return LocalDb.instance.db;
}

String _jwtFalso(String email, int telegramId) {
  String b64(Map<String, dynamic> m) =>
      base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');
  final header = b64({'alg': 'HS256', 'typ': 'JWT'});
  final payload = b64({
    'sub': '00000000-0000-0000-0000-0000000000dd',
    'aud': 'authenticated',
    'exp': 4102444800,
    'iat': 1700000000,
    'email': email,
    'role': 'authenticated',
    'app_metadata': {'telegram_id': telegramId, 'provider': 'email'},
  });
  return '$header.$payload.firma-de-mentira';
}

/// Sesión del dueño (alias «jc» de AppConfig) para las
/// pantallas con candado de dueño. La sesión se fija
/// dentro de runAsync (la pauta de panel_permisos_129:
/// bajo FakeAsync a secas, setInitialSession no
/// completa y el test se cuelga).
Future<void> _fijarSesionDueno(WidgetTester tester) async {
  // Supabase ya viene inicializado del setUpAll.
  final sesion = jsonEncode({
    'access_token': _jwtFalso('jc@ironbody.local', 735772141),
    'token_type': 'bearer',
    'expires_in': 3600,
    'refresh_token': 'refresh-de-mentira',
    'user': {
      'id': '00000000-0000-0000-0000-0000000000dd',
      'aud': 'authenticated',
      'email': 'jc@ironbody.local',
      'app_metadata': {'telegram_id': 735772141, 'provider': 'email'},
      'user_metadata': <String, dynamic>{},
      'created_at': '2024-01-01T00:00:00.000Z',
    },
  });
  await tester.runAsync(() async {
    await Supabase.instance.client.auth.setInitialSession(sesion);
  });
}

Future<void> _insertarEspejoTarifa(
  Database db, {
  required String id,
  required int clienteId,
  required String? hasta,
  required String ts,
}) async {
  await db.execute(
      'CREATE TABLE IF NOT EXISTS espejo_tarifas_especiales '
      '(id TEXT PRIMARY KEY, data TEXT NOT NULL, sync_seq INTEGER NOT NULL)');
  await db.insert('espejo_tarifas_especiales', {
    'id': id,
    'data': jsonEncode({
      'cliente_id': clienteId,
      'nombre': 'Espejo $id',
      'periodo': 'mensual',
      'monto_efectivo': 1000,
      'monto_transferencia': null,
      'vigente_desde': '2026-10-24',
      'vigente_hasta': hasta,
      'motivo': 'otorgada en otro teléfono',
      'otorgado_por': null,
      'activa': 1,
      'historial': '[]',
      'creada_ts': '2026-10-24T10:00:00-04:00',
      'actualizada_ts': ts,
    }),
    'sync_seq': 1,
  });
}
