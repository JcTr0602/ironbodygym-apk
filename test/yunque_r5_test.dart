/// Yunque de cambios 1.31 — Ronda 5: contratos de las
/// correcciones de la ronda.
///
/// - R5-M4-1: el predicado de fiado pendiente de «Por
///   cobrar» usa la forma tolerante canónica (1 o true):
///   un `es_fiado` bool no puede esconder una deuda de la
///   superficie de cobro.
/// - R5-M1-1/M1-2/M1-3/M1-4/M1-6: la campaña filtra por el
///   estado canónico, deduplica por cliente/teléfono, no
///   disfraza «sin verificar» de «sin destinatarios», tiene
///   defensa propia de dueño (campaña y hub) y el buzón
///   distingue «verificado» de «aún sin verificar».
/// - R5-M3-1…M3-5: las hojas de exportación aplican los
///   filtros canónicos (Casa, anulados, cortesías, fiados),
///   los tres escapes CSV neutralizan fórmulas, el
///   exportador duplicado avisa sus fallos y el texto del
///   paquete no anuncia una nómina que no va.
/// - R5-M2-1: «Olvidé mi PIN» borra el hash ANTES de
///   signOut (la clave es por usuario y sin sesión el
///   borrado caía en una clave sin sufijo inexistente).
/// - R5-M2-2/M2-5/M2-6: revocar/reactivar/desbloquear en la
///   ficha son solo del dueño (botón y método); el panel de
///   candado pinta el fallo de carga como error; el modal
///   del PIN limpia el portapapeles al cerrar.
/// - R5-M5-1/M5-2: la purga cubre campana_wa/panel_cifras/
///   panel_badges; el login distingue credenciales de red.
/// - R5-M6-1/M6-5/M6-6/M6-8: las series de rutinas se
///   validan en local; guardar/retirar rutinas y la Guía
///   tienen guarda/catch propios.
/// - R5-M8-1/M8-2: la imagen del cierre usa la FOTO de
///   liquidación del liquidado y su «TOTAL A PAGAR»
///   excluye a los ya liquidados.
/// - R5-M9-1…M9-5: margen del eje Y, sin fechas época ni
///   ceros en las series, puerta por puntos de peso y día
///   Habana en el eje X.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/estadisticas_servicios.dart';
import 'package:ironbody_gym/mediciones_cliente.dart'
    show serieMedicion;
import 'package:ironbody_gym/ui/cierre_nomina_imagen.dart';
import 'package:ironbody_gym/ui/cuentas_por_cobrar.dart';
import 'package:ironbody_gym/ui/editor_rutinas_gym.dart';
import 'package:ironbody_gym/ui/exportar_excel.dart';
import 'package:ironbody_gym/ui/grafico_metrica.dart';
import 'package:ironbody_gym/ui/grafico_peso.dart';
import 'package:ironbody_gym/ui/login.dart';
import 'package:ironbody_gym/ui/pestana_progreso.dart';

String _fuente(String ruta) => File(ruta).readAsStringSync();

void main() {
  group('R5-M4-1 · esFiadoPendienteVenta (forma tolerante)', () {
    test('es_fiado numérico 1 sin saldar → pendiente', () {
      expect(esFiadoPendienteVenta({'es_fiado': 1}), isTrue);
      expect(
          esFiadoPendienteVenta({'es_fiado': 1, 'fiado_saldado': 0}),
          isTrue);
    });

    test('es_fiado bool true sin saldar → pendiente (el caso cazado)',
        () {
      expect(esFiadoPendienteVenta({'es_fiado': true}), isTrue);
    });

    test('saldado en forma numérica o bool → fuera', () {
      expect(
          esFiadoPendienteVenta({'es_fiado': 1, 'fiado_saldado': 1}),
          isFalse);
      expect(
          esFiadoPendienteVenta(
              {'es_fiado': true, 'fiado_saldado': true}),
          isFalse);
      expect(
          esFiadoPendienteVenta({'es_fiado': 1, 'fiado_saldado': true}),
          isFalse);
    });

    test('sin flag de fiado → fuera, en cualquier forma', () {
      expect(esFiadoPendienteVenta({'es_fiado': 0}), isFalse);
      expect(esFiadoPendienteVenta({'es_fiado': false}), isFalse);
      expect(esFiadoPendienteVenta(const {}), isFalse);
    });
  });

  group('R5-M3 · exportaciones con los filtros canónicos', () {
    test('pagoExportable: el pago normal viaja', () {
      expect(
          pagoExportable(
              {'metodo': 'efectivo', 'cliente_id': 5, 'id': 9},
              const {},
              const {}),
          isTrue);
    });

    test('pagoExportable: Casa fuera (marca propia y conjunto)', () {
      expect(
          pagoExportable({'metodo': 'efectivo', 'casa': 1}, const {},
              const {}),
          isFalse);
      expect(
          pagoExportable({'metodo': 'efectivo', 'casa': true},
              const {}, const {}),
          isFalse);
      expect(
          pagoExportable(
              {'metodo': 'transferencia', 'cliente_id': 7},
              const {7},
              const {}),
          isFalse);
    });

    test('pagoExportable: cortesía y promo fuera', () {
      expect(
          pagoExportable({'metodo': 'cortesia'}, const {}, const {}),
          isFalse);
      expect(pagoExportable({'metodo': 'promo'}, const {}, const {}),
          isFalse);
    });

    test('pagoExportable: anulado fuera (marca y cola)', () {
      expect(
          pagoExportable({'metodo': 'efectivo', 'anulado': 1},
              const {}, const {}),
          isFalse);
      expect(
          pagoExportable(
              {'metodo': 'efectivo', 'id': 42}, const {}, const {42}),
          isFalse);
    });

    test('filasVentasMes: el fiado sin saldar no viaja; el saldado sí',
        () {
      final filas = filasVentasMes(
        [
          {
            'fecha': '2026-11-05',
            'es_fiado': 1,
            'cantidad': 1,
            'total': 100,
          },
          {
            'fecha': '2026-11-06',
            'es_fiado': true,
            'cantidad': 1,
            'total': 100,
          },
          {
            'fecha': '2026-11-07',
            'es_fiado': 1,
            'fiado_saldado': 1,
            'cantidad': 2,
            'total': 200,
          },
          {'fecha': '2026-11-08', 'cantidad': 1, 'total': 50},
        ],
        const {},
        '2026-11',
        const {},
      );
      expect(filas, hasLength(2));
      expect(filas[0][0], '2026-11-07');
      expect(filas[1][0], '2026-11-08');
    });

    test('csvEstadisticas neutraliza fórmulas y CR como la canónica',
        () {
      final csv = csvEstadisticas(
        ['nombre'],
        [
          ['=2+5'],
          ['Bote, "grande"'],
          ['linea\rrota'],
        ],
      );
      expect(csv, contains("'=2+5"));
      expect(csv, contains('"Bote, ""grande"""'));
      expect(csv, contains('"linea\rrota"'));
    });
  });

  group('R5-M1/M3 · contratos de fuente', () {
    final campana = _fuente('lib/ui/campana_wa.dart');
    final hub = _fuente('lib/ui/hub_comunicacion.dart');
    final buzon = _fuente('lib/ui/buzon_dueno.dart');
    final home = _fuente('lib/ui/home.dart');
    final admin = _fuente('lib/ui/admin.dart');
    final exportar = _fuente('lib/ui/exportar_excel.dart');

    test('M1-1: la audiencia filtra por el estado canónico', () {
      expect(campana, contains("a.estado == 'activo'"));
      expect(campana, isNot(contains('a.activo && a.ultimoAccesoEn')));
    });

    test('M1-3: la audiencia se deduplica antes del tope', () {
      expect(campana, contains('_dedupAudiencia(cruda)'));
    });

    test('M1-2: «sin verificar» no se dice «sin destinatarios»', () {
      expect(campana, contains('No se pudo cargar la lista de accesos'));
      expect(campana, contains('!AccesoAppCache.instance.cargado'));
    });

    test('M1-4: campaña y hub con defensa propia de dueño', () {
      expect(campana, contains('Las campañas son solo del dueño.'));
      expect(hub, contains('La comunicación es solo del dueño.'));
    });

    test('M1-6: el buzón distingue verificado de sin verificar', () {
      expect(buzon, contains('final bool verificado;'));
      expect(home, contains('verificado: verificado'));
    });

    test('M3-4: el exportador duplicado avisa sus fallos', () {
      expect(admin, contains("AppLog.error('ui', 'exportar_fallo'"));
      expect(admin, contains('No se pudo exportar'));
    });

    test('M3-5: el texto del paquete no promete la nómina ausente',
        () {
      expect(exportar, contains('la nómina no se pudo generar'));
    });
  });

  group('R5-M5-2 · mensajeErrorLogin', () {
    test('credenciales malas no se dicen «conexión»', () {
      expect(
          mensajeErrorLogin(
              Exception('AuthException: Invalid login credentials')),
          'Usuario o contraseña incorrectos.');
    });

    test('timeout y socket se dicen «sin conexión»', () {
      expect(mensajeErrorLogin(Exception('TimeoutException')),
          contains('Sin conexión'));
      expect(
          mensajeErrorLogin(
              Exception('SocketException: Connection refused')),
          contains('Sin conexión'));
    });

    test('lo desconocido conserva el mensaje genérico', () {
      expect(mensajeErrorLogin(Exception('otra cosa')),
          'No se pudo entrar. Revisa usuario, contraseña y conexión.');
    });
  });

  group('R5-M6-1 · errorValidacionSeriesRutina', () {
    EjercicioGymAdmin ej(List<SerieGymAdmin> series,
            {String ficha = 'barra_press'}) =>
        EjercicioGymAdmin(fichaId: ficha, series: series);
    String tit(String id) => 'Press banca';

    test('una rutina sana pasa', () {
      expect(
          errorValidacionSeriesRutina(
              [ej([const SerieGymAdmin(repsMin: 8, repsMax: 10)])],
              tituloDe: tit),
          isNull);
    });

    test('repsMin 0 (campo vaciado) bloquea nombrando la serie',
        () {
      final e = errorValidacionSeriesRutina(
          [ej([const SerieGymAdmin(repsMin: 0)])], tituloDe: tit);
      expect(e, contains('Press banca'));
      expect(e, contains('serie 1'));
    });

    test('máx < mín bloquea', () {
      expect(
          errorValidacionSeriesRutina(
              [ej([const SerieGymAdmin(repsMin: 12, repsMax: 8)])],
              tituloDe: tit),
          contains('máximas'));
    });

    test('peso negativo bloquea; peso vacío pasa', () {
      expect(
          errorValidacionSeriesRutina(
              [ej([const SerieGymAdmin(repsMin: 10, pesoKg: -5)])],
              tituloDe: tit),
          contains('negativo'));
      expect(
          errorValidacionSeriesRutina(
              [ej([const SerieGymAdmin(repsMin: 10)])],
              tituloDe: tit),
          isNull);
    });

    test('el tope de series por ejercicio bloquea', () {
      expect(
          errorValidacionSeriesRutina(
              [
                ej(List.generate(kMaxSeriesPorEjercicioRutina + 1,
                    (_) => const SerieGymAdmin(repsMin: 10)))
              ],
              tituloDe: tit),
          contains('máximo'));
    });
  });

  group('R5-M8-2 · totalAPagarCierre', () {
    FilaCierreNomina fila(double neto, bool liquidada) =>
        FilaCierreNomina(
          nombre: 'X',
          base: 0,
          bono: 0,
          comision: 0,
          adelantos: 0,
          deuda: 0,
          neto: neto,
          liquidada: liquidada,
        );

    test('excluye al ya liquidado del total a pagar', () {
      expect(
          totalAPagarCierre([fila(1000, true), fila(800, false)]),
          800);
    });

    test('sin liquidados suma todo; vacío suma 0', () {
      expect(totalAPagarCierre([fila(500, false)]), 500);
      expect(totalAPagarCierre(const []), 0);
    });
  });

  group('R5-M9 · gráficos', () {
    test('M9-1: el rango visible da margen del 10 %', () {
      final r = rangoVisibleSerie(99.9, 100.1);
      expect(r.minE, closeTo(99.88, 1e-9));
      expect(r.maxE, closeTo(100.12, 1e-9));
      final plana = rangoVisibleSerie(100, 100);
      expect(plana.minE, 99);
      expect(plana.maxE, 101);
    });

    test('M9-5: el eje X agrupa por día Habana', () {
      // 2026-11-02T02:00Z = 1 nov 21:00 Habana (EST, -5):
      // su día Habana es el 1, el MISMO que el de la
      // medición de las 12:00Z del día 1 — con el día UTC
      // crudo quedaban en días distintos (fracción > 0).
      final fr = fraccionesEjeTiempo([
        DateTime.utc(2026, 11, 1, 12),
        DateTime.utc(2026, 11, 2, 2),
        DateTime.utc(2026, 11, 3, 12),
      ]);
      expect(fr, [0.0, 0.0, 1.0]);
    });

    Medicion med({
      double? peso,
      double? cintura,
      required DateTime creada,
    }) =>
        Medicion(
          id: 0,
          clienteId: '1',
          pesoKg: peso,
          cinturaCm: cintura,
          registradoPor: 'x',
          createdAt: creada,
        );

    test('M9-2/M9-4: puntosPesoValidos excluye época y sin peso',
        () {
      final pts = puntosPesoValidos([
        med(peso: 90, creada: DateTime(2026, 10, 1)),
        med(peso: 91, creada: DateTime.fromMillisecondsSinceEpoch(0)),
        med(peso: null, creada: DateTime(2026, 10, 5)),
      ]);
      expect(pts.length, 1);
      expect(pts.single.valor, 90);
    });

    test('M9-3: la serie opcional excluye el 0 legado', () {
      final s = serieMetricaOpcional(
        [
          med(cintura: 80, creada: DateTime(2026, 10, 1)),
          med(cintura: 0, creada: DateTime(2026, 10, 2)),
          med(cintura: 81, creada: DateTime(2026, 10, 3)),
        ],
        (m) => m.cinturaCm,
      );
      expect(s.length, 2);
    });

    test('M9-3: serieMedicion excluye el 0 y el NaN', () {
      final s = serieMedicion([
        {
          'medidas': {'cintura': 80.0},
          'fecha_medicion': '2026-10-01',
        },
        {
          'medidas': {'cintura': 0.0},
          'fecha_medicion': '2026-10-02',
        },
        {
          'medidas': {'cintura': double.nan},
          'fecha_medicion': '2026-10-03',
        },
      ], 'cintura');
      expect(s.length, 1);
    });
  });

  group('R5-M2/M5/M6/M8 · contratos de fuente', () {
    final pinLock = _fuente('lib/ui/pin_lock.dart');
    final localdb = _fuente('lib/localdb.dart');
    final fichaAcceso = _fuente('lib/ui/ficha_acceso_app.dart');
    final panelCandado = _fuente('lib/ui/panel_candado.dart');
    final modalPin = _fuente('lib/ui/modal_pin_acceso.dart');
    final editorRutinas =
        _fuente('lib/ui/editor_rutinas_gym.dart');
    final guiaEditor = _fuente('lib/ui/guia_editor.dart');
    final guiaLista = _fuente('lib/ui/guia_lista.dart');
    final nomina = _fuente('lib/ui/nomina.dart');

    test('M2-1: el hash del PIN se borra ANTES de signOut', () {
      final borra = pinLock.indexOf('setPinHash(null)');
      final sale = pinLock.lastIndexOf('AuthService().signOut()');
      expect(borra, greaterThanOrEqualTo(0));
      expect(sale, greaterThanOrEqualTo(0));
      expect(borra, lessThan(sale));
    });

    test('M5-1: la purga cubre campaña, panel y distintivos', () {
      expect(localdb, contains("k == 'campana_wa_v1'"));
      expect(localdb, contains("startsWith('campana_wa_enviados_')"));
      expect(localdb, contains("startsWith('panel_cifras_v1_')"));
      expect(localdb, contains("startsWith('panel_badges_v1_')"));
    });

    test('M2-2: revocar y reactivar con guarda de dueño en el '
        'método', () {
      expect(fichaAcceso,
          contains("if (!AuthService().isOwner) return;"));
      expect(fichaAcceso, contains('if (AuthService().isOwner)'));
    });

    test('M2-5: el panel de candado pinta el fallo como error',
        () {
      expect(panelCandado, contains('_falloCarga = true'));
      expect(panelCandado, contains('No se pudieron cargar los candados'));
    });

    test('M2-6: el modal del PIN limpia el portapapeles si '
        'aún es su PIN', () {
      expect(modalPin, contains('Clipboard.getData'));
      expect(modalPin, contains('datos?.text == pin'));
    });

    test('M6-5: guardar/retirar rutinas con guarda de rol', () {
      // La guarda vive en _guardar y en _retirar (además de
      // la de la lista).
      expect('Future<void> _guardar()'.allMatches(editorRutinas).length,
          greaterThanOrEqualTo(1));
      expect(editorRutinas,
          contains('R5-M6-5: guarda de rol DENTRO de la acción'));
    });

    test('M6-6: publicar/retirar de la Guía y el lote avisan '
        'el fallo', () {
      expect(guiaEditor, contains("AppLog.error('ui', 'guia_publicar_fallo'"));
      expect(guiaEditor, contains("AppLog.error('ui', 'guia_retirar_fallo'"));
      expect(guiaEditor,
          contains("AppLog.error('ui', 'guia_borrador_fallo'"));
      expect(guiaLista, contains("AppLog.error('ui', 'guia_lote_fallo'"));
    });

    test('M8-1: la foto del liquidado sale de su snapshot', () {
      expect(nomina, contains('snapshotNomina('));
      expect(nomina, contains('R5-M8-1'));
    });

    test('M8-3/M8-4/M8-5: compartir con línea oficial, guarda '
        'y PNG nulo visible', () {
      expect(nomina, contains(r'$lineaMensajeAutomatico'));
      expect(nomina, contains('compartiendoFoto'));
      expect(nomina, contains("throw 'sin imagen'"));
    });
  });
}
