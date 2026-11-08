/// Gestión 1.28 — Oleada M1-BC (Bloques B y C del estudio
/// M1: mejoras de funcionamiento y acabado premium).
/// Tests por ítem:
///
/// - B1: el manifiesto cubre TODAS las tablas que baja el
///   pull (paridad con supTablas leída de la fuente) +
///   incidencias_mirror histórica = 40 entradas (41 desde
///   la 1.29 Oleada 4: + solicitudes_relleno de FB-09).
/// - B2: decisión de modo del chequeo (pura) y filtro por
///   diferencia (puro).
/// - B3: el batching adaptativo SIGUE cableado (fuente):
///   _loteAdaptativo manda en _uploadOps y la escalera de
///   páginas en el pull (verificado ya implementado desde
///   la 1.3.4; el gzip de subida quedó descartado con
///   prueba de humo y su nota vive en el código).
/// - B4: clasificador de hallazgos del Reparar guiado
///   (puro): lo automático vs lo del dueño.
/// - B5: la foto única — campos nuevos del SyncStatus y
///   fotoEstado con frescura (segunda llamada inmediata =
///   la MISMA foto, sin recalcular).
/// - B6: copia automática — cuándo toca (puro) y rotación
///   (pura).
/// - C1: el banner reserva la franja inferior fija (38) y
///   su altura no depende del ancho (título a 1 línea).
/// - C2: ventana del resumen protagonista (pura, 30 s).
/// - C3: semáforo de tablas (puro).
/// - C5: explicacionOp (pura): motivo y acción en llano
///   por estado, sin texto técnico crudo.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/copia_automatica.dart';
import 'package:ironbody_gym/errores_sync.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/reparar_sync.dart';
import 'package:ironbody_gym/salud_sync.dart';
import 'package:ironbody_gym/sync.dart';
import 'package:ironbody_gym/ui/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  group('B1 · manifiesto completo', () {
    test('son 41 entradas: las 40 del pull + incidencias_mirror', () {
      // 1.29 (Oleada 4, FB-09): el pull suma solicitudes_relleno
      // (39 → 40) y el manifiesto la vigila como a las demás.
      expect(SyncEngine.tablasManifiesto.length, 41);
      expect(SyncEngine.tablasManifiesto['sync_incidencias'],
          'incidencias_mirror');
      expect(SyncEngine.tablasManifiesto['sync_solicitudes_relleno'],
          'solicitudes_relleno');
    });

    test('toda tabla que baja el pull está vigilada', () {
      final vigiladas = SyncEngine.tablasManifiesto.values.toSet();
      for (final t in SyncEngine.tablasEspejo) {
        expect(vigiladas, contains(t),
            reason: '$t baja en el pull pero el manifiesto no la '
                'vigila: divergiría en silencio (caso Duany)');
      }
    });

    test('paridad con supTablas leída de la fuente', () {
      final fuente = File('lib/sync.dart').readAsStringSync();
      final i = fuente.indexOf('const supTablas = {');
      expect(i, isNonNegative, reason: 'supTablas no encontrada');
      final j = fuente.indexOf('};', i);
      final bloque = fuente.substring(i, j);
      final pares = RegExp(r"'([a-z_0-9]+)':\s*'([a-z_0-9]+)'")
          .allMatches(bloque)
          .map((m) => (m.group(1)!, m.group(2)!))
          .toList();
      expect(pares.length, SyncEngine.tablasEspejo.length,
          reason: 'supTablas y tablasEspejo deben coincidir');
      for (final (local, sup) in pares) {
        expect(SyncEngine.tablasManifiesto[sup], local,
            reason: 'el manifiesto debe mapear $sup → $local '
                '(el inverso exacto de supTablas)');
      }
      expect(SyncEngine.tablasManifiesto.length, pares.length + 1,
          reason: 'solo una entrada extra: incidencias_mirror');
    });

    test('las prohibidas del entrenador están vigiladas (dueño) '
        'y el skip por rol tiene con qué saltarlas', () {
      final vigiladas = SyncEngine.tablasManifiesto.values.toSet();
      for (final t in LocalDb.tablasProhibidasEntrenador) {
        expect(vigiladas, contains(t),
            reason: '$t es prohibida del entrenador pero el '
                'dueño sí debe vigilarla en el manifiesto');
      }
    });
  });

  group('B2 · chequeo por diferencia', () {
    test('decidirModoChequeoManifiesto: la matriz de modos', () {
      // Sin seq previa → completa (primera vez).
      expect(
          decidirModoChequeoManifiesto(
              forzarCompleto: false,
              haySeqPrevia: false,
              completaVencida: false,
              completaDebida: false),
          ModoChequeoManifiesto.completo);
      // Todo en orden → rápida.
      expect(
          decidirModoChequeoManifiesto(
              forzarCompleto: false,
              haySeqPrevia: true,
              completaVencida: false,
              completaDebida: false),
          ModoChequeoManifiesto.rapido);
      // Forzada → completa.
      expect(
          decidirModoChequeoManifiesto(
              forzarCompleto: true,
              haySeqPrevia: true,
              completaVencida: false,
              completaDebida: false),
          ModoChequeoManifiesto.completo);
      // Semanal vencida → completa.
      expect(
          decidirModoChequeoManifiesto(
              forzarCompleto: false,
              haySeqPrevia: true,
              completaVencida: true,
              completaDebida: false),
          ModoChequeoManifiesto.completo);
      // Debida por una rápida anterior → completa.
      expect(
          decidirModoChequeoManifiesto(
              forzarCompleto: false,
              haySeqPrevia: true,
              completaVencida: false,
              completaDebida: true),
          ModoChequeoManifiesto.completo);
      expect(SyncEngine.diasEntreManifiestosCompletos, 7);
    });

    test('esperadosDesdeSeq conserva solo lo posterior', () {
      final e = {'a': 5, 'b': 10, 'c': 11, 'd': 0};
      expect(esperadosDesdeSeq(e, 10), {'c': 11});
      expect(esperadosDesdeSeq(e, 0), {'a': 5, 'b': 10, 'c': 11});
      expect(esperadosDesdeSeq(e, 99), isEmpty);
      expect(esperadosDesdeSeq(const {}, 3), isEmpty);
    });
  });

  group('B3 · batching adaptativo (ya vivo desde la 1.3.4)', () {
    test('el lote adaptativo manda en la subida y la escalera '
        'en la bajada (fuente)', () {
      final fuente = File('lib/sync.dart').readAsStringSync();
      expect(fuente, contains('_loteAdaptativo.tam'),
          reason: '_uploadOps debe leer el tamaño del lote '
              'adaptativo en cada lote');
      expect(fuente, contains('EscaleraPaginas()'),
          reason: 'el pull debe usar la escalera de páginas');
      expect(fuente, contains('gzip en subida DESCARTADO'),
          reason: 'la nota de la prueba de humo del gzip '
              '(HTTP 400 de Supabase) debe seguir documentada');
    });
  });

  group('B4 · Reparar guiado (clasificador puro)', () {
    test('foto vacía: sin hallazgos y contadores a cero', () {
      const f = FotoAtascos();
      expect(clasificarHallazgos(f), isEmpty);
      expect(f.reparablesAuto, 0);
      expect(f.deDueno, 0);
    });

    test('rechazadas y revisión son del dueño, nunca auto', () {
      const f = FotoAtascos(opsRechazadas: 2, opsRevision: 1);
      final hs = clasificarHallazgos(f);
      expect(hs.length, 2);
      expect(hs.every((h) => h.clase == ClaseHallazgo.dueno), isTrue);
      expect(f.deDueno, 3);
      expect(f.reparablesAuto, 0);
    });

    test('error, enviadas y pendientes se reparan solas', () {
      const f =
          FotoAtascos(opsError: 3, opsEnviadas: 1, opsPendientes: 2);
      final hs = clasificarHallazgos(f);
      expect(hs.length, 3);
      expect(hs.every((h) => h.clase == ClaseHallazgo.auto), isTrue);
      expect(f.reparablesAuto, 6);
    });

    test('espejo vacío sospechoso entra como auto con el '
        'testigo en el detalle', () {
      const f = FotoAtascos(espejoVacioSospechoso: true, clientesPrevios: 137);
      final hs = clasificarHallazgos(f);
      expect(hs.single.clase, ClaseHallazgo.auto);
      expect(hs.single.detalle, contains('137'));
      expect(f.reparablesAuto, 1);
    });

    test('tablas desfasadas y sin verificar se reparan solas', () {
      const f = FotoAtascos(
          tablasPorRedescargar: 2,
          manifiestoSinVerificar: ['pagos', 'gastos']);
      final hs = clasificarHallazgos(f);
      expect(hs.length, 2);
      expect(hs.every((h) => h.clase == ClaseHallazgo.auto), isTrue);
    });
  });

  group('B5 · foto única del estado', () {
    test('SyncStatus por defecto: foto sin sellar', () {
      const s = SyncStatus();
      expect(s.calculadoEn, isNull);
      expect(s.watermarkMinimo, 0);
      expect(s.serverSeq, 0);
    });

    test('fotoEstado sella la foto y la segunda llamada '
        'inmediata devuelve LA MISMA (frescura)', () async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      SharedPreferences.setMockInitialValues({});
      final dir = await getDatabasesPath();
      try {
        await File(p.join(dir, 'ironbody.db')).delete();
      } catch (_) {}
      await LocalDb.resetParaTest();
      await LocalDb.instance.db;

      final f1 = await SyncEngine.instance.fotoEstado();
      expect(f1.calculadoEn, isNotNull,
          reason: 'la foto debe nacer sellada con su instante');
      final f2 = await SyncEngine.instance.fotoEstado();
      expect(identical(f1, f2), isTrue,
          reason: 'con <3 s la foto vigente se reutiliza: un '
              'solo cálculo compartido por todas las pantallas');
    }, timeout: const Timeout(Duration(seconds: 60)));
  });

  group('B6 · copia automática', () {
    final base = DateTime(2026, 11, 6, 10, 0);

    test('copiaAutoToca: nunca, 6 días no, 7 días sí', () {
      expect(copiaAutoToca(ultima: null, ahora: base), isTrue);
      expect(
          copiaAutoToca(
              ultima: base.subtract(const Duration(days: 6, hours: 23)),
              ahora: base),
          isFalse);
      expect(
          copiaAutoToca(
              ultima: base.subtract(const Duration(days: 7)),
              ahora: base),
          isTrue);
      expect(
          copiaAutoToca(
              ultima: base.subtract(const Duration(days: 30)),
              ahora: base),
          isTrue);
    });

    test('copiasAutoParaBorrar: rota conservando las recientes', () {
      expect(copiasAutoParaBorrar(const []), isEmpty);
      const cuatro = [
        'ironbody-auto-20261001-080000.db',
        'ironbody-auto-20261008-080000.db',
        'ironbody-auto-20261015-080000.db',
        'ironbody-auto-20261022-080000.db',
      ];
      expect(copiasAutoParaBorrar(cuatro), isEmpty);
      final seis = [
        'ironbody-auto-20261105-080000.db',
        'ironbody-auto-20261001-080000.db',
        'ironbody-auto-20261029-080000.db',
        'ironbody-auto-20261008-080000.db',
        'ironbody-auto-20261022-080000.db',
        'ironbody-auto-20261015-080000.db',
      ];
      expect(
          copiasAutoParaBorrar(seis),
          [
            'ironbody-auto-20261001-080000.db',
            'ironbody-auto-20261008-080000.db',
          ],
          reason: 'se borran las más viejas (el nombre ordena '
              'por fecha), se conservan las 4 recientes');
    });
  });

  group('C2 · resumen protagonista del banner', () {
    final ahora = DateTime(2026, 11, 6, 12, 0, 0);

    test('ventana de 30 s en hora de la foto', () {
      expect(
          resumenBannerProtagonista(
              resumen: 'Sin cambios',
              resumenHora: ahora.subtract(const Duration(seconds: 10)),
              ahora: ahora),
          isTrue);
      expect(
          resumenBannerProtagonista(
              resumen: '↑ 2 enviados · ↓ 3 nuevos',
              resumenHora: ahora.subtract(const Duration(seconds: 29)),
              ahora: ahora),
          isTrue);
      expect(
          resumenBannerProtagonista(
              resumen: 'Sin cambios',
              resumenHora: ahora.subtract(const Duration(seconds: 31)),
              ahora: ahora),
          isFalse);
      expect(
          resumenBannerProtagonista(
              resumen: null, resumenHora: ahora, ahora: ahora),
          isFalse);
      expect(
          resumenBannerProtagonista(
              resumen: 'Sin cambios', resumenHora: null, ahora: ahora),
          isFalse);
      expect(
          resumenBannerProtagonista(
              resumen: 'Sin cambios',
              resumenHora: ahora.add(const Duration(seconds: 5)),
              ahora: ahora),
          isFalse,
          reason: 'una hora en el futuro no es «recién hecho»');
    });
  });

  group('C3 · semáforo de tablas', () {
    SemaforoTabla base({
      bool hayError = false,
      int corruptas = 0,
      bool divergente = false,
      bool ausente = false,
      bool sinPermiso = false,
      bool sinVerificar = false,
      int watermark = 100,
      int serverSeq = 100,
      int filas = 10,
    }) =>
        semaforoTabla(
          hayError: hayError,
          corruptas: corruptas,
          divergente: divergente,
          ausente: ausente,
          sinPermiso: sinPermiso,
          sinVerificar: sinVerificar,
          watermark: watermark,
          serverSeq: serverSeq,
          filas: filas,
        );

    test('verde: coinciden filas y watermark', () {
      expect(base(), SemaforoTabla.verde);
    });

    test('rojo: error, corruptas o divergencia (gana al ámbar)', () {
      expect(base(hayError: true), SemaforoTabla.rojo);
      expect(base(corruptas: 2), SemaforoTabla.rojo);
      expect(base(divergente: true), SemaforoTabla.rojo);
      expect(base(divergente: true, ausente: true), SemaforoTabla.rojo);
    });

    test('ámbar: ausente, sin permiso, sin verificar o '
        'watermark por debajo', () {
      expect(base(ausente: true), SemaforoTabla.ambar);
      expect(base(sinPermiso: true), SemaforoTabla.ambar);
      expect(base(sinVerificar: true), SemaforoTabla.ambar);
      expect(base(watermark: 90), SemaforoTabla.ambar);
    });

    test('gris: vacía y nunca bajó', () {
      expect(base(filas: 0, watermark: 0, serverSeq: 0),
          SemaforoTabla.gris);
    });
  });

  group('C5 · explicacionOp', () {
    test('pendiente y enviada: espera explicada', () {
      expect(explicacionOp(estado: 'pendiente').motivo,
          contains('no se ha enviado'));
      expect(explicacionOp(estado: 'enviada').motivo,
          contains('no la confirma'));
      expect(explicacionOp(estado: 'enviada').accion,
          contains('próxima sincronización'));
    });

    test('error: traduce sin volcar el texto técnico', () {
      final e = explicacionOp(
          estado: 'error',
          error: 'SocketException: Connection refused');
      expect(e.motivo, isNot(contains('SocketException')));
      expect(e.motivo, isNotEmpty);
    });

    test('rechazada: los tres motivos conocidos', () {
      expect(
          explicacionOp(
                  estado: 'rechazada',
                  error: 'cliente no existe en el servidor')
              .motivo,
          contains('ya no existe'));
      expect(
          explicacionOp(estado: 'rechazada', error: 'HTTP 400: datos')
              .motivo,
          contains('datos inválidos'));
      expect(
          explicacionOp(estado: 'rechazada', error: 'HTTP 409')
              .motivo,
          contains('duplicada'));
    });

    test('rechazada: el motivo de negocio del servidor se '
        'conserva tal cual', () {
      final e = explicacionOp(
          estado: 'rechazada',
          error: 'El pomo del entrenador no tiene dosis');
      expect(e.motivo, 'El pomo del entrenador no tiene dosis');
      expect(e.accion, contains('descartarla'));
    });

    test('necesita_revision: la acción es del dueño', () {
      final e = explicacionOp(
          estado: 'necesita_revision', error: 'Monto fuera de rango');
      expect(e.motivo, 'Monto fuera de rango');
      expect(e.accion, contains('dueño'));
    });

    test('rechazada con basura técnica: genérico en llano, '
        'nunca el crudo', () {
      final e = explicacionOp(
          estado: 'rechazada',
          error: 'TimeoutException after 0:00:30.000000');
      expect(e.motivo, isNot(contains('TimeoutException')));
      expect(e.motivo, contains('rechazó'));
    });
  });

  group('C1 · banner de altura fija', () {
    testWidgets('la franja inferior existe y mide 38; la '
        'altura total no cambia con el ancho', (tester) async {
      Future<double> alturaConAncho(double ancho) async {
        tester.view.physicalSize = Size(ancho, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(const MaterialApp(
          home: Scaffold(body: SyncBanner()),
        ));
        await tester.pump();
        final franja = find.byKey(const Key('sync_banner_franja'));
        expect(franja, findsOneWidget,
            reason: 'la franja fija debe existir en reposo');
        expect(tester.getSize(franja).height, 38);
        return tester.getSize(find.byType(SyncBanner)).height;
      }

      final h1 = await alturaConAncho(400);
      final h2 = await alturaConAncho(280);
      expect(h1, h2,
          reason: 'con el título a 1 línea y los huecos '
              'reservados, el banner mide lo mismo a cualquier '
              'ancho: la pantalla de debajo no salta');
    });
  });
}
