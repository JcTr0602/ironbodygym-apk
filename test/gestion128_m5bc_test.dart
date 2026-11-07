/// 1.28 M5-BC (Bloques B y C del estudio M5):
///
/// - C1 ★: los 6 módulos estrenan los NOMBRES CORTOS
///   definitivos, cada contador SIGUE en su módulo (el
///   de Clientes suma solicitudes + reportes + vales de
///   Premios, B2) y la línea bajo el título es el estado
///   vivo, no el resumen estático.
/// - B1: la foto de cifras del Panel se codifica y se
///   decodifica sin perder nada, degrada a null sin
///   reventar y su clave es por usuario.
/// - B2: la atención enseña «N vales por aprobar» sin
///   entrar a Premios, y la bandeja sin cargar se
///   declara (gravedad 0), nunca un falso vacío.
/// - B3: la pausa con fecha de un recordatorio — la
///   regla pura (último día inclusive, reactivación
///   sola al día siguiente) y la fusión que no deja que
///   un pull sin la columna borre la pausa local;
///   migración v66 con la columna en el esquema.
/// - B4: conteos de Comunidad y buscador sin acentos.
/// - B5/C5: «novedades de mi versión» (instalada +
///   anterior) y la vitrina de tarjetas que las pinta.
/// - B6: la reconciliación de marcas de Premios en lote
///   (rechazada libera; el resto sigue oculto) y los
///   estados de ops en UNA consulta.
/// - C4: nombre e icono de cada logro en todas partes;
///   el sello con «@mes» se nombra por la base.
/// - C6: el formato de la cuenta atrás del PIN.
/// - C3: los esqueletos nuevos pintan sin reventar.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:ironbody_gym/comunidad_panel.dart';
import 'package:ironbody_gym/invitados.dart' as invitados_svc;
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/novedades.dart';
import 'package:ironbody_gym/plus_reportes.dart';
import 'package:ironbody_gym/premios_panel.dart';
import 'package:ironbody_gym/recordatorios.dart';
import 'package:ironbody_gym/ui/logros_premio_ui.dart';
import 'package:ironbody_gym/ui/panel_cache.dart';
import 'package:ironbody_gym/ui/panel_dueno_atencion.dart';
import 'package:ironbody_gym/ui/panel_dueno_swr.dart';
import 'package:ironbody_gym/ui/panel_modulos.dart';
import 'package:ironbody_gym/ui/pin_lock.dart';
import 'package:ironbody_gym/ui/skeleton.dart';

FotoAtencion _foto({int vales = 0, bool valesSinCargar = false}) {
  final sol = BandejaSwr<invitados_svc.InvitadoResumen>()
    ..exito(const [], DateTime(2026, 11, 7, 8));
  final rep = BandejaSwr<ReportePlus>()
    ..exito(const [], DateTime(2026, 11, 7, 8));
  return FotoAtencion(
    solicitudes: sol,
    reportes: rep,
    reservasSolicitadas: const [],
    nombreSupl: const {},
    pendienteEntrenadores: const [],
    sinReporteAyer: const [],
    sinReporteHoy: const [],
    incidenciasPend: 0,
    syncError: null,
    stockCritico: const [],
    valesPorAprobar: vales,
    valesSinCargar: valesSinCargar,
  );
}

List<DatoModuloPanel> _modulos({
  int pendCaja = 0,
  double pendCajaTotal = 0,
  double cajaHoyTotal = 0,
  int solicitudes = 0,
  int reportes = 0,
  int vales = 0,
  int clientesActivos = 0,
  int sinReporteHoy = 0,
  int sinReporteAyer = 0,
  int reservas = 0,
  int stockCritico = 0,
  int preciosSinFijar = 0,
  int incidencias = 0,
  int pendientesSubir = 0,
}) =>
    modulosPanel(
      pendCaja: pendCaja,
      pendCajaTotal: pendCajaTotal,
      cajaHoyTotal: cajaHoyTotal,
      solicitudes: solicitudes,
      reportes: reportes,
      valesPorAprobar: vales,
      clientesActivos: clientesActivos,
      sinReporteHoy: sinReporteHoy,
      sinReporteAyer: sinReporteAyer,
      reservas: reservas,
      stockCritico: stockCritico,
      preciosSinFijar: preciosSinFijar,
      incidencias: incidencias,
      pendientesSubir: pendientesSubir,
    );

void main() {
  group('C1 ★ — nombres cortos del Panel', () {
    test('los 6 títulos son los cortos, en su orden', () {
      expect(
        _modulos().map((d) => d.titulo).toList(),
        [
          'Caja y dinero',
          'Clientes e invitados',
          'Equipo y turnos',
          'Suplementos y contenido',
          'Configuración y datos',
          'Control y sistema',
        ],
      );
      // Ningún título viejo sobrevive.
      for (final d in _modulos()) {
        expect(d.titulo, isNot(contains('Cobros y Nómina')));
        expect(d.titulo, isNot(contains('Invitados y Comunicación')));
        expect(d.titulo, isNot(contains('Turnos y Permisos')));
        expect(d.titulo, isNot(contains('Dosis y App Plus')));
        expect(d.titulo, isNot(contains('Tarifas y Configuración')));
        expect(d.titulo, isNot(contains('Auditoría y Sistema')));
      }
    });

    test('cada contador sigue en SU módulo', () {
      final m = _modulos(
        pendCaja: 2,
        solicitudes: 1,
        reportes: 2,
        vales: 3,
        sinReporteHoy: 1,
        sinReporteAyer: 2,
        reservas: 4,
        preciosSinFijar: 5,
        incidencias: 6,
      );
      expect(m[0].badge, 2, reason: 'Caja: entrenadores por liquidar');
      expect(m[1].badge, 6,
          reason: 'Clientes: solicitudes + reportes + vales (B2)');
      expect(m[2].badge, 3, reason: 'Equipo: cierres hoy + ayer');
      expect(m[3].badge, 4, reason: 'Suplementos: reservas');
      expect(m[4].badge, 5, reason: 'Configuración: precios sin fijar');
      expect(m[5].badge, 6, reason: 'Control: incidencias');
    });

    test('sin pendientes no hay badge y el estado dice «al día»',
        () {
      final m = _modulos(clientesActivos: 42, cajaHoyTotal: 1500);
      for (final d in m) {
        expect(d.badge, isNull, reason: d.titulo);
      }
      expect(m[0].estado, contains('1500'));
      expect(m[1].estado, contains('42 clientes activos'));
      expect(m[2].estado, contains('al día'));
      expect(m[5].estado, 'Sistema al día');
    });

    test('el estado de Clientes nombra los vales por aprobar', () {
      final m = _modulos(clientesActivos: 10, vales: 1);
      expect(m[1].estado, contains('1 vale por aprobar'));
      final m2 = _modulos(clientesActivos: 10, vales: 3);
      expect(m2[1].estado, contains('3 vales por aprobar'));
    });

    testWidgets('las 6 filas pintan título, estado y su badge',
        (tester) async {
      final datos = _modulos(
        pendCaja: 2,
        vales: 3,
        reservas: 4,
        clientesActivos: 25,
        cajaHoyTotal: 800,
      );
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ListView(
            children: [
              for (final d in datos)
                FilaModuloPanel(dato: d, onTap: () {}),
            ],
          ),
        ),
      ));
      for (final d in datos) {
        expect(find.text(d.titulo), findsOneWidget, reason: d.titulo);
        expect(find.text(d.estado), findsOneWidget, reason: d.estado);
      }
      // Los badges pintan donde toca.
      expect(find.text('2'), findsOneWidget);
      expect(find.text('3'), findsOneWidget);
      expect(find.text('4'), findsOneWidget);
    });
  });

  group('B1 — foto de cifras del Panel', () {
    test('ida y vuelta sin perder nada', () {
      final foto = FotoPanelCache(
        DateTime(2026, 11, 7, 8, 30),
        {'ingresos': 12500.0, 'pagosMes': 40, 'nombreSupl': {'3': 'C4'}},
      );
      final vuelta = FotoPanelCache.decodificar(foto.codificar());
      expect(vuelta, isNotNull);
      expect(vuelta!.hora, foto.hora);
      expect(vuelta.cifras['ingresos'], 12500.0);
      expect(vuelta.cifras['pagosMes'], 40);
    });

    test('lo degradado es null, nunca una excepción', () {
      expect(FotoPanelCache.decodificar(null), isNull);
      expect(FotoPanelCache.decodificar(''), isNull);
      expect(FotoPanelCache.decodificar('no-es-json'), isNull);
      expect(FotoPanelCache.decodificar('{"hora": 5}'), isNull);
      expect(FotoPanelCache.decodificar('[1,2]'), isNull);
    });

    test('la clave es por usuario', () {
      expect(claveCachePanel(735772141),
          isNot(claveCachePanel(999)));
      expect(claveCachePanel(null), claveCachePanel(0));
    });

    test('las lecturas de cifras degradan sin reventar', () {
      final m = <String, dynamic>{'a': 'texto', 'b': 7, 'c': 2.5};
      expect(cifraEntera(m, 'a', 3), 3);
      expect(cifraEntera(m, 'b'), 7);
      expect(cifraDoble(m, 'c'), 2.5);
      expect(cifraDoble(m, 'zz'), 0);
      expect(cifraLista(m, 'b'), isEmpty);
      expect(cifraMapa(m, 'b'), isEmpty);
    });
  });

  group('B2 — vales visibles sin entrar a Premios', () {
    test('la fila de atención llega con su conteo', () {
      final filas = pendientesAtencion(_foto(vales: 2));
      final fila = filas
          .where((d) => d.destino == DestinoAtencion.premios)
          .toList();
      expect(fila, hasLength(1));
      expect(fila.single.titulo, '2 vales por aprobar');
      expect(fila.single.gravedad, 1);
      expect(
          pendientesAtencion(_foto(vales: 1)).single.titulo,
          '1 vale por aprobar');
    });

    test('sin vales y sin error, ninguna fila de Premios', () {
      final filas = pendientesAtencion(_foto());
      expect(
          filas.where((d) =>
              d.destino == DestinoAtencion.premios ||
              d.destino == DestinoAtencion.reintentarVales),
          isEmpty);
    });

    test('la bandeja sin cargar se declara en gravedad 0', () {
      final filas = pendientesAtencion(_foto(valesSinCargar: true));
      final fila = filas.singleWhere(
          (d) => d.destino == DestinoAtencion.reintentarVales);
      expect(fila.gravedad, 0);
      expect(fila.titulo, 'Vales de Premios sin cargar');
    });
  });

  group('B6 — Premios en lote', () {
    test('la reconciliación de marcas conserva la regla', () {
      final rec = reconciliarMarcasVales(
        valeIds: [1, 2, 3, 4],
        marcas: {
          'premio_vale_resuelto_1': 'op-a',
          'premio_vale_resuelto_2': 'op-b',
          'premio_vale_resuelto_3': 'op-c',
          'premio_vale_resuelto_99': 'op-z',
        },
        estados: {'op-a': 'aplicada', 'op-b': 'rechazada'},
      );
      // op-c sin estado (purgada): sigue oculto (conservador).
      expect(rec.ocultos, {1, 3});
      expect(rec.marcasABorrar, [2]);
    });

    test('sin marcas no hay ocultos', () {
      final rec = reconciliarMarcasVales(
          valeIds: [1], marcas: const {}, estados: const {});
      expect(rec.ocultos, isEmpty);
      expect(rec.marcasABorrar, isEmpty);
    });
  });

  group('C4 — Premios con nombre y medalla', () {
    test('cada logro del catálogo tiene nombre humano', () {
      for (final id in ordenCatalogoLogros) {
        expect(tituloLogroPremio(id), isNot(id),
            reason: 'sin nombre: $id');
      }
      expect(tituloLogroPremio('dueno_tarde'), 'Dueño de la tarde');
      expect(tituloLogroPremio('club100_muerto'),
          'Club 100 · Peso muerto');
      expect(tituloLogroPremio('manual'), 'Vale manual');
      // Un logro futuro desconocido se enseña crudo, no vacío.
      expect(tituloLogroPremio('logro_futuro'), 'logro_futuro');
    });

    test('el sello con «@mes» se nombra por la base', () {
      expect(tituloLogroPremio('reto_del_mes@2026-11'),
          'Reto del mes');
      expect(iconoLogroPremio('reto_del_mes@2026-11'),
          Icons.flag_rounded);
    });

    test('iconos por familia', () {
      expect(iconoLogroPremio('constancia_real'),
          Icons.local_fire_department_rounded);
      expect(iconoLogroPremio('club100_press'),
          Icons.emoji_events_rounded);
      expect(iconoLogroPremio('secreto_alba'),
          Icons.visibility_off_rounded);
      expect(iconoLogroPremio('manual'),
          Icons.card_giftcard_rounded);
    });

    test('los recientes leen el logro si la RPC lo trae', () {
      final b = parseBandejaPremios({
        'vales': [],
        'recientes': [
          {
            'id': 9,
            'cliente_id': 3,
            'nombre': 'Ana',
            'premio_dias': 15,
            'estado': 'canjeado',
            'resuelto_en': '2026-11-05',
            'logro_id': 'dueno_tarde',
          },
          {
            'id': 10,
            'cliente_id': 4,
            'nombre': 'Luis',
            'premio_dias': 15,
            'estado': 'rechazado',
            'resuelto_en': '2026-11-05',
          },
        ],
      });
      expect(b.recientes[0].logroId, 'dueno_tarde');
      expect(b.recientes[1].logroId, '');
    });
  });

  group('B3 — pausa con fecha de recordatorios', () {
    test('la regla pura: último día inclusive, sola se reactiva',
        () {
      final cfg = {'activa': 1, 'pausada_hasta': '2026-11-08'};
      expect(recordatorioEnPausaConFecha(cfg, '2026-11-07'), isTrue);
      expect(recordatorioEnPausaConFecha(cfg, '2026-11-08'), isTrue,
          reason: 'el último día también es pausa');
      expect(recordatorioEnPausaConFecha(cfg, '2026-11-09'), isFalse,
          reason: 'al día siguiente ya dispara');
    });

    test('sin pausa o pausado sin fecha no entra aquí', () {
      expect(
          recordatorioEnPausaConFecha(
              {'activa': 1}, '2026-11-07'),
          isFalse);
      expect(
          recordatorioEnPausaConFecha(
              {'activa': 0, 'pausada_hasta': '2026-11-08'},
              '2026-11-07'),
          isFalse);
    });

    test('la fusión no deja que un pull sin la columna borre '
        'la pausa local', () {
      Map<String, dynamic> fila(String ts) => {
            'id': 'r1',
            'titulo': 'Vencimientos',
            'tipo': 'vencimiento',
            'alcance': 'todos',
            'activa': 1,
            'actualizada_ts': ts,
          };
      final local = <String, dynamic>{
        ...fila('2026-11-07T10:00:00'),
        'pausada_hasta': '2026-11-09',
      };
      // Espejo SIN la clave (el servidor aún no la publica).
      final espejoSin = <String, dynamic>{
        ...fila('2026-11-07T10:00:00'),
      };
      final out1 =
          LocalDb.fusionarRecordatorios([local], [espejoSin]);
      expect(out1.single['pausada_hasta'], '2026-11-09',
          reason: 'sin clave en el espejo manda la local');
      // Espejo CON la clave en null: manda el espejo
      // (la pausa se quitó en otro teléfono).
      final espejoCon = <String, dynamic>{
        ...fila('2026-11-07T10:00:00'),
        'pausada_hasta': null,
      };
      final out2 =
          LocalDb.fusionarRecordatorios([local], [espejoCon]);
      expect(out2.single['pausada_hasta'], isNull);
    });
  });

  group('B4 — Comunidad lista para crecer', () {
    PerfilComunidadAdmin p(String nombre,
            {bool visible = true, bool oculto = false}) =>
        PerfilComunidadAdmin(
          clienteId: nombre.length,
          nombre: nombre,
          visible: visible,
          ocultoAdmin: oculto,
          mostrarMarcas: false,
          mostrarActividad: false,
          mostrarRutina: false,
          mostrarConstancia: false,
        );

    test('los conteos de cabecera', () {
      final c = conteosComunidad([
        p('Ana'),
        p('Beto', oculto: true),
        p('Cora', visible: false),
        p('Dario'),
      ]);
      expect(c.conVitrina, 3);
      expect(c.visibles, 2);
      expect(c.ocultosPorTi, 1);
    });

    test('el buscador ignora acentos y mayúsculas', () {
      final lista = [p('José Pérez'), p('María'), p('Josefa')];
      expect(
          filtrarPerfilesComunidad(lista, 'jose')
              .map((e) => e.nombre),
          ['José Pérez', 'Josefa']);
      expect(filtrarPerfilesComunidad(lista, ''), lista);
      expect(filtrarPerfilesComunidad(lista, 'xyz'), isEmpty);
    });
  });

  group('B5/C5 — novedades de mi versión, en vitrina', () {
    test('instalada + la anterior inmediata', () {
      final mias = novedadesDeMiVersion('1.27.0');
      expect(mias.map((n) => n.version).toList(),
          ['1.27.0', '1.26.1']);
    });

    test('la última de la lista va sola; una desconocida '
        'toma las dos más recientes que no la superen', () {
      expect(novedadesDeMiVersion('1.0.1'), hasLength(1));
      final raras = novedadesDeMiVersion('9.9.9');
      expect(raras.first.version, novedades.first.version);
      expect(raras, hasLength(2));
    });

    testWidgets('la vitrina pinta tarjetas con su sello', (tester) async {
      // Superficie alta: las dos tarjetas caben y el
      // ListView perezoso las construye.
      tester.view.physicalSize = const Size(1200, 3200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: DialogoNovedades(
              lista: novedadesDeMiVersion('1.27.0')),
        ),
      ));
      expect(find.text('Versión 1.27.0'), findsOneWidget);
      expect(find.text('Versión 1.26.1'), findsOneWidget);
      // La instalada (1.27.0+88 en AppConfig) lleva «Nuevo».
      expect(find.text('Nuevo'), findsOneWidget);
      expect(find.byIcon(Icons.check_circle_rounded),
          findsWidgets);
    });
  });

  group('C6 — cuenta atrás honesta del PIN', () {
    test('formato M:SS y H:MM:SS, redondeando hacia arriba', () {
      expect(formatoCuentaAtrasPin(Duration.zero), '0:00');
      expect(
          formatoCuentaAtrasPin(const Duration(milliseconds: 400)),
          '0:01');
      expect(formatoCuentaAtrasPin(const Duration(seconds: 65)),
          '1:05');
      expect(
          formatoCuentaAtrasPin(
              const Duration(minutes: 9, seconds: 59)),
          '9:59');
      expect(formatoCuentaAtrasPin(const Duration(minutes: 61)),
          '1:01:00');
    });
  });

  group('C3 — esqueletos con la forma real', () {
    testWidgets('Panel, Bandeja y Detalle pintan', (tester) async {
      await tester.pumpWidget(const MaterialApp(
          home: Scaffold(body: SkeletonPanel())));
      expect(find.byType(SkeletonPanel), findsOneWidget);
      await tester.pumpWidget(const MaterialApp(
          home: Scaffold(body: SkeletonPremiosBandeja())));
      expect(find.byType(SkeletonPremiosBandeja), findsOneWidget);
      await tester.pumpWidget(const MaterialApp(
          home: Scaffold(body: SkeletonPremiosDetalle())));
      expect(find.byType(SkeletonPremiosDetalle), findsOneWidget);
    });
  });

  group('BD — migración v66 y estados en lote', () {
    setUpAll(() async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      SharedPreferences.setMockInitialValues({});
      await LocalDb.resetParaTest();
    });

    test('el esquema nuevo trae pausada_hasta y la versión es 67',
        () async {
      final db = await LocalDb.instance.db;
      expect(await db.getVersion(), LocalDb.versionActual);
      // 67 desde la corrección A5-D1 (reset del watermark de
      // espejo_recordatorio_config para que pausada_hasta
      // baje por el pull).
      expect(LocalDb.versionActual, 67);
      final cols = await db
          .rawQuery("PRAGMA table_info(recordatorio_config)");
      expect(cols.map((c) => c['name']),
          contains('pausada_hasta'));
    });

    test('estadosOps lee muchas ops en una sola llamada', () async {
      await LocalDb.instance.queueOp(
          opUuid: 'm5bc-op-1',
          tipo: 'registrar_gasto',
          payload: const {});
      await LocalDb.instance.queueOp(
          opUuid: 'm5bc-op-2',
          tipo: 'registrar_gasto',
          payload: const {});
      final estados = await LocalDb.instance
          .estadosOps(['m5bc-op-1', 'm5bc-op-2', 'm5bc-ausente']);
      expect(estados.keys, containsAll(['m5bc-op-1', 'm5bc-op-2']));
      expect(estados.containsKey('m5bc-ausente'), isFalse,
          reason: 'la ausente no entra: el llamador la lee null');
      expect(await LocalDb.instance.estadosOps(const []), isEmpty);
    });
  });
}
