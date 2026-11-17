/// Yunque Exhaustivo 1.35 — carril S (superficies de sync):
/// correcciones S-01, S-02 y S-03 del clúster S.
///
/// S-01: la tarjeta en vivo del Centro ignoraba el error de
/// corrida PERSISTIDO (avisoSyncCorto): tras un reinicio con
/// el teléfono al día pintaba «Todo al día» en verde mientras
/// el banner decía «La bajada falló».
/// S-02: «Comprobar ahora» de Salud afirmaba la re-descarga
/// sin mirar el SyncResultado de la corrida.
/// S-03: cargarSaludSync leía 6 metas en un solo try: un
/// fallo componía «nunca» y hacía desaparecer Teléfonos.
///
/// Nota de discriminancia: los casos puros de S-01 usan el
/// parámetro nuevo `avisoPersistido` y los de S-03 los
/// campos/ayudas nuevos — sobre la base no COMPILAN (API
/// ausente), además de fallar por comportamiento donde la
/// API ya existía (el escenario S-01 sin el parámetro era
/// exactamente el «Todo al día» de ui135_ui19). El test de
/// widget de la tarjeta NO se incluye: la tarjeta lee
/// SyncEngine.currentStatus, cuya foto calcula enLinea con
/// una búsqueda DNS real — no determinista en el banco; la
/// costura de widget queda cubierta por los casos puros +
/// el contrato de fuente del llamador.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/salud_sync.dart';
import 'package:ironbody_gym/sync.dart';
import 'package:ironbody_gym/ui/centro_sync.dart';
import 'package:ironbody_gym/ui/componentes.dart';
import 'package:ironbody_gym/ui/salud_sync_screen.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _textoError = 'La última sincronización falló: toca '
    '«Sincronizar ahora»';

void main() {
  group('S-01 · resumenMostradorSync con avisoPersistido', () {
    test('aviso + teléfono al día: texto de error, no '
        '«Todo al día»', () {
      expect(
          resumenMostradorSync(
              corriendo: false,
              pendientes: 0,
              enLinea: true,
              hayError: false,
              hayNovedades: false,
              avisoPersistido: true),
          _textoError);
    });

    test('aviso + hayNovedades null: manda el error '
        'conocido, no «Sin verificar»', () {
      expect(
          resumenMostradorSync(
              corriendo: false,
              pendientes: 0,
              enLinea: true,
              hayError: false,
              hayNovedades: null,
              avisoPersistido: true),
          _textoError);
    });

    test('aviso + pendientes > 0: mandan los pendientes',
        () {
      expect(
          resumenMostradorSync(
              corriendo: false,
              pendientes: 2,
              enLinea: true,
              hayError: false,
              hayNovedades: false,
              avisoPersistido: true),
          'Faltan 2 por subir');
    });

    test('aviso + novedades: mandan las novedades', () {
      expect(
          resumenMostradorSync(
              corriendo: false,
              pendientes: 0,
              enLinea: true,
              hayError: false,
              hayNovedades: true,
              avisoPersistido: true),
          contains('novedades por bajar'));
    });

    test('aviso + sin conexión: manda la falta de '
        'conexión', () {
      expect(
          resumenMostradorSync(
              corriendo: false,
              pendientes: 0,
              enLinea: false,
              hayError: false,
              hayNovedades: false,
              avisoPersistido: true),
          contains('Sin conexión'));
    });

    test('sin aviso, el «al día» y el «sin verificar» de '
        'siempre no cambian', () {
      expect(
          resumenMostradorSync(
              corriendo: false,
              pendientes: 0,
              enLinea: true,
              hayError: false,
              hayNovedades: false),
          'Todo al día');
      expect(
          resumenMostradorSync(
              corriendo: false,
              pendientes: 0,
              enLinea: true,
              hayError: false,
              hayNovedades: null),
          contains('Sin verificar'));
    });

    test('contrato de fuente: la tarjeta pasa el aviso '
        'persistido y lo pinta como error solo cuando '
        'su rama manda', () {
      final src =
          File('lib/ui/centro_sync.dart').readAsStringSync();
      expect(src,
          contains('avisoPersistido: st.avisoSyncCorto != null'));
      expect(src, contains('avisoPersistidoManda'));
      expect(src, contains('st.hayNovedades != true'),
          reason: 'con novedades por bajar manda la rama '
              'de novedades, no el error persistido');
    });
  });

  group('S-02 · mensajeComprobacionSalud', () {
    test('divergentes con corrida corrida y sin error: '
        'sí se afirma la re-descarga, con éxito', () {
      final v = mensajeComprobacionSalud(
        divergentes: 3,
        redescarga: const SyncResultado(corrio: true),
      );
      expect(v.texto, 'Se re-descargaron 3 tablas desfasadas');
      expect(v.significado, SignificadoChip.exito);
    });

    test('divergentes pero la corrida NO corrió: no se '
        'afirma la re-descarga ni hay chip de éxito', () {
      final v = mensajeComprobacionSalud(
        divergentes: 3,
        redescarga: const SyncResultado.noCorrio(
            SyncMotivoNoCorrio.enCurso),
      );
      expect(v.texto, contains('Hay 3 tablas desfasadas'));
      expect(v.texto, contains('no se completó'));
      expect(v.texto, isNot(contains('Se re-descargaron')));
      expect(v.significado, isNot(SignificadoChip.exito));
    });

    test('divergentes pero la corrida falló: mensaje '
        'honesto, sin éxito', () {
      final v = mensajeComprobacionSalud(
        divergentes: 1,
        redescarga: const SyncResultado(
            corrio: true, error: 'La bajada falló'),
      );
      expect(v.texto, contains('Hay 1 tabla desfasada'));
      expect(v.texto, contains('no se completó'));
      expect(v.significado, isNot(SignificadoChip.exito));
    });

    test('divergentes y la corrida lanzó (resultado '
        'null): tampoco se afirma', () {
      final v = mensajeComprobacionSalud(divergentes: 2);
      expect(v.texto, contains('no se completó'));
      expect(v.significado, isNot(SignificadoChip.exito));
    });

    test('sin divergentes y comprobación fallida: los '
        'veredictos de siempre no cambian', () {
      final ok = mensajeComprobacionSalud(divergentes: 0);
      expect(ok.texto, contains('todo coincide'));
      expect(ok.significado, SignificadoChip.exito);
      final mal = mensajeComprobacionSalud(divergentes: -1);
      expect(mal.texto, contains('no pudo completarse'));
      expect(mal.significado, SignificadoChip.error);
    });

    test('contrato de fuente: la pantalla captura el '
        'SyncResultado y compone con la pura', () {
      final src = File('lib/ui/salud_sync_screen.dart')
          .readAsStringSync();
      expect(src, contains('mensajeComprobacionSalud('));
      expect(src,
          contains('redescarga = await SyncEngine.instance.run'));
    });
  });

  group('S-03 · presentación pura de Salud', () {
    test('fecha sin leer: «sin verificar», no «nunca»',
        () {
      expect(textoFechaSaludSync(null, sinLeer: true),
          'sin verificar');
      expect(
          textoFechaSaludSync(
              DateTime.utc(2026, 11, 10, 15, 0),
              sinLeer: true),
          'sin verificar',
          reason: 'ni siquiera con una fecha presente se '
              'afirma si la lectura falló');
    });

    test('fecha leída: ausente es «nunca» y presente se '
        'formatea', () {
      expect(textoFechaSaludSync(null), 'nunca');
      final conFecha =
          textoFechaSaludSync(DateTime.utc(2026, 11, 10, 15, 30));
      expect(conFecha, isNot('nunca'));
      expect(conFecha, isNot('sin verificar'));
      expect(conFecha, contains('2026'));
    });

    test('la sección Teléfonos no desaparece por un '
        'fallo de lectura', () {
      expect(
          mostrarSeccionTelefonosSalud(
              cantidadTelefonos: 0, telefonosSinLeer: true),
          isTrue);
      expect(
          mostrarSeccionTelefonosSalud(
              cantidadTelefonos: 0, telefonosSinLeer: false),
          isFalse,
          reason: 'leída y vacía, la sección sigue sin '
              'mostrarse: no es un cero disfrazado');
      expect(
          mostrarSeccionTelefonosSalud(
              cantidadTelefonos: 2, telefonosSinLeer: false),
          isTrue);
    });
  });

  group('S-03 · cargarSaludSync con Teléfonos ilegible', () {
    const dbTest = 'test_yunque_exh_s.db';

    setUpAll(() {
      TestWidgetsFlutterBinding.ensureInitialized();
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      SharedPreferences.setMockInitialValues({});
      LocalDb.nombreArchivoDbForzado = dbTest;
    });

    tearDownAll(() async {
      await LocalDb.resetParaTest(borrarArchivo: false);
      LocalDb.nombreArchivoDbForzado = null;
      final dir = await getDatabasesPath();
      for (final suf in ['', '-wal', '-shm']) {
        try {
          await File(p.join(dir, '$dbTest$suf')).delete();
        } catch (_) {}
      }
    });

    test('si evaluar los teléfonos lanza, la foto lo '
        'marca y el resto de la salud sigue leyéndose',
        () async {
      await LocalDb.resetParaTest(borrarArchivo: false);
      final dir = await getDatabasesPath();
      for (final suf in ['', '-wal', '-shm']) {
        try {
          await File(p.join(dir, '$dbTest$suf')).delete();
        } catch (_) {}
      }
      final db = await LocalDb.instance.db;
      // La lectura de teléfonos parte de ultimo_sync:
      // sin esa tabla, evaluarTelefonosSync lanza.
      await db.execute('DROP TABLE IF EXISTS ultimo_sync');
      final datos = await cargarSaludSync();
      expect(datos.telefonosSinLeer, isTrue,
          reason: 'la lista vacía por FALLO debe venir '
              'marcada: en la base era [] indistinguible '
              'de una lista leída y vacía');
      expect(datos.telefonos, isEmpty);
      expect(
          mostrarSeccionTelefonosSalud(
              cantidadTelefonos: datos.telefonos.length,
              telefonosSinLeer: datos.telefonosSinLeer),
          isTrue,
          reason: 'la sección se pinta como no verificada '
              'en vez de desaparecer');
      // El fallo de Teléfonos no arrastra a las demás
      // lecturas: las metas del manifiesto sí se leyeron.
      expect(datos.manifiestoSinLeer, isFalse);
      expect(datos.tablas, isNotEmpty);
    });
  });
}
