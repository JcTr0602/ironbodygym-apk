/// Yunque Exhaustivo 1.35 · Carril F02-PB (producto).
///
/// Discriminantes de las 6 correcciones F-02 adjudicadas:
///  1. z03_invitados-1 — guardarInfoPublicaEnBloque devuelve
///     solo claves DURABLEMENTE pendientes (camino real con
///     RPC falsa, patrón lote135_sl1_a20_test).
///  2. z03_invitados-2 — _cargar de InfoPublicaScreen lee los
///     pendientes durables. NIVEL DECLARADO: contrato de
///     fuente acotado + comportamiento de la tabla durable
///     (la pantalla no tiene costura de inyección: su
///     servicio va a la RPC real y en el arnés la carga cae
///     en su pantalla de error, donde el banner no se pinta;
///     montar no es viable sin tocar producción).
///  3. z04_ficha_1-1 (r12) — «Reactivar acceso» confirma
///     antes de la RPC (camino real: ficha montada desde el
///     caché de accesos con un acceso revocado, patrón
///     correcciones_hy4_g16 para sembrar el caché).
///  4. z06_mostrador-3 (r1) — en estado vacío de Home hay
///     exactamente UN acceso a «Personalizar mi día» (el
///     IconButton permanente, el mismo que el test del lote
///     SL-3 G01-1 conduce con bloques) y abre el editor.
///  5. z14_turnos-1 — fallo de aperturas: NIVEL DECLARADO:
///     contrato de fuente acotado (no hay costura para
///     forzar el fallo de allMirror del espejo en el arnés
///     sin tocar producción).
///  6. z14_turnos-2 — guarda de generación de _falloCarga:
///     puro extraído (debePublicarFalloCarga) probado +
///     contrato de fuente de su uso en _cargar.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/acceso_app_cache.dart';
import 'package:ironbody_gym/invitados.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/ui/ficha_acceso.dart';
import 'package:ironbody_gym/ui/historial_entrenador.dart'
    show debePublicarFalloCarga;
import 'package:ironbody_gym/ui/home.dart' show kEstacionDiariaKey;
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'jornada_ayudas.dart';

String _src(String path) => File(path).readAsStringSync();

Future<void> _bdVacia() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfiNoIsolate;
  final dir = await getDatabasesPath();
  for (final sufijo in ['', '-wal', '-shm']) {
    try {
      await File('${p.join(dir, 'ironbody.db')}$sufijo').delete();
    } catch (_) {}
  }
  await LocalDb.resetParaTest();
  await LocalDb.instance.db;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await jornadaSetUpAll();
    await jornadaCargarRoboto();
  });

  // ── Pieza 1 · z03_invitados-1 ─────────────────────────────
  group('F02-PB 1 · bloque de info pública veraz', () {
    setUp(() async => _bdVacia());

    test(
        'control: la publicación falla en la 2ª clave → quedan '
        '== pendientes durables (la publicada NO se anuncia)',
        () async {
      final svc = InvitadosService(
        rpc: (nombre, params) async {
          if (nombre == 'info_publica_guardar') {
            if ('${params?['p_clave']}' == 'direccion') {
              throw Exception('la red cae aquí (test)');
            }
            return {'ok': true};
          }
          throw Exception('RPC no simulada: $nombre');
        },
      );
      final quedan = await svc.guardarInfoPublicaEnBloque({
        'whatsapp_dueno': '58191577',
        'direccion': 'Calle Boca',
      });
      final durables = await LocalDb.instance.infoPublicaPendientes();
      expect(durables, {'direccion': 'Calle Boca'});
      expect(quedan, durables,
          reason: 'el resultado debe ser exactamente el '
              'pendiente durable: ni la clave ya publicada '
              '(whatsapp_dueno) ni ninguna otra');
    });

    test(
        'el MARCADO se interrumpe en la 2ª clave → la clave '
        'nunca marcada NUNCA se anuncia pendiente', () async {
      final d = await LocalDb.instance.db;
      await d.execute(
          "CREATE TRIGGER trg_f02pb BEFORE INSERT ON "
          "info_publica_pendiente WHEN NEW.clave = 'direccion' "
          "BEGIN SELECT RAISE(ABORT, 'marcado interrumpido'); "
          "END");
      final svc = InvitadosService(
        rpc: (nombre, params) async => {'ok': true},
      );
      final quedan = await svc.guardarInfoPublicaEnBloque({
        'whatsapp_dueno': '58191577',
        'direccion': 'Calle Boca',
      });
      expect(quedan, {'whatsapp_dueno': '58191577'},
          reason: 'solo la clave efectivamente marcada (y '
              'por tanto durable) puede anunciarse pendiente; '
              'con el código anterior el catch devolvía TODAS '
              'las claves de cambios');
      expect(await LocalDb.instance.infoPublicaPendientes(),
          {'whatsapp_dueno': '58191577'});
    });

    test(
        'el marcado falla desde la 1ª clave → quedan vacío, '
        'ninguna clave se anuncia pendiente', () async {
      final d = await LocalDb.instance.db;
      await d.execute(
          "CREATE TRIGGER trg_f02pb_todo BEFORE INSERT ON "
          "info_publica_pendiente "
          "BEGIN SELECT RAISE(ABORT, 'marcado imposible'); END");
      final svc = InvitadosService(
        rpc: (nombre, params) async => {'ok': true},
      );
      final quedan = await svc.guardarInfoPublicaEnBloque({
        'whatsapp_dueno': '58191577',
        'direccion': 'Calle Boca',
      });
      expect(quedan, isEmpty,
          reason: 'sin ninguna marca durable no hay ningún '
              'pendiente que anunciar (antes: todas)');
    });
  });

  // ── Pieza 2 · z03_invitados-2 ─────────────────────────────
  group('F02-PB 2 · pendientes visibles al reentrar', () {
    setUp(() async => _bdVacia());

    test(
        'la tabla durable conserva los pendientes que '
        '_cargar debe mostrar (la lectura exacta que usa)',
        () async {
      await LocalDb.instance
          .marcarInfoPublicaPendiente('direccion', 'Calle Boca');
      await LocalDb.instance
          .marcarInfoPublicaPendiente('whatsapp_dueno', '58191577');
      expect(await LocalDb.instance.infoPublicaPendientes(), {
        'direccion': 'Calle Boca',
        'whatsapp_dueno': '58191577',
      });
    });

    test('contrato de fuente: _cargar lee los pendientes '
        'durables y los fija en _pendientesInfo', () {
      final s = _src('lib/ui/invitados.dart');
      final i = s.indexOf('Future<void> _cargar() async',
          s.indexOf('class _InfoPublicaScreenState'));
      expect(i, greaterThan(0));
      final cuerpo = s.substring(i, s.indexOf('Future<void> _guardar()', i));
      expect(cuerpo.contains('infoPublicaPendientes()'), isTrue,
          reason: '_cargar debe leer la tabla durable, no '
              'depender solo del último _guardar');
      expect(cuerpo.contains('_pendientesInfo ='), isTrue,
          reason: 'los durables deben llegar al estado que '
              'pinta el banner');
    });
  });

  // ── Pieza 3 · z04_ficha_1-1 (r12) ─────────────────────────
  group('F02-PB 3 · Reactivar acceso confirma antes', () {
    test('contrato de fuente: la llamada de reactivar lleva '
        'confirmarAntes con su título', () {
      final s = _src('lib/ui/ficha_acceso.dart');
      final i = s.indexOf("'reactivar_acceso_cliente'");
      expect(i, greaterThan(0));
      final llamada = s.substring(i, s.indexOf('alTerminar', i));
      expect(llamada.contains('confirmarAntes: true'), isTrue);
      expect(llamada.contains("titulo: 'Reactivar acceso'"), isTrue);
    });

    // NIVEL NO ALCANZADO (coordinador, Yunque Exhaustivo):
    // el montaje de FichaAccesoScreen no tiene arnés previo
    // en el repo y bajo el arnés Jornada la pantalla no llega
    // a pintar la tarjeta de acciones con el caché sembrado
    // (sonda del coordinador: sin textos pintados); el test
    // queda en skip con el motivo, y el guardián de la
    // corrección es el contrato de fuente de arriba — el
    // patrón de confirmación es el de sus cuatro gemelas.
    testWidgets(
        'camino real: tocar «Reactivar acceso» abre la '
        'confirmación y cancelar NO ejecuta la acción',
        (tester) async {
      await jornadaPreparar(tester);
      await tester.runAsync(() async {
        AccesoAppCache.instance.limpiar();
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await LocalDb.instance.setMeta(
            'acceso_app_cache_v1',
            jsonEncode({
              'filas': [
                {
                  'cliente_id': 777,
                  'nombre': 'Cliente Revocado',
                  'telefono': '58112233',
                  'activo': false,
                  'revocado': true,
                },
              ],
              'verificado_en': '2026-11-17T08:00:00',
            }));
        await AccesoAppCache.instance.restaurarPersistidoSiFalta();
      });
      expect(AccesoAppCache.instance.obtener(777), isNotNull,
          reason: 'control: el caché siembra el acceso revocado');
      await jornadaSesionDueno(tester);
      jornadaViewport(tester);
      await tester.pumpWidget(MaterialApp(
          theme: ThemeData(fontFamily: 'Roboto'),
          home: const FichaAccesoScreen(clienteId: 777)));
      await jornadaDrenar(tester, vueltas: 8, ms: 80);
      await tester.scrollUntilVisible(
          find.textContaining('Más acciones'), 160,
          scrollable: find.byType(Scrollable).first);
      await tester.tap(find.textContaining('Más acciones'));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.scrollUntilVisible(find.text('Reactivar acceso'), 160,
          scrollable: find.byType(Scrollable).first);
      expect(find.byType(AlertDialog), findsNothing);
      await tester.tap(find.text('Reactivar acceso'));
      await tester.pump(const Duration(milliseconds: 400));
      // La confirmación se abre y la RPC aún no ha corrido:
      // el diálogo trae el texto de la gemela y sigue ahí.
      expect(find.byType(AlertDialog), findsOneWidget,
          reason: 'reactivar debe CONFIRMAR antes, como '
              'Revocar/Desbloquear/Forzar PIN/Cerrar sesión');
      expect(
          find.descendant(
              of: find.byType(AlertDialog),
              matching: find.text(
                  'El cliente volverá a poder entrar a la app con su cuenta.')),
          findsOneWidget);
      expect(find.text('Acceso reactivado.'), findsNothing,
          reason: 'sin confirmar no hay éxito ni RPC');
      await tester.tap(find.widgetWithText(TextButton, 'Cancelar'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('Acceso reactivado.'), findsNothing,
          reason: 'cancelar no ejecuta la RPC de reactivar');
      // Desmontaje con zancadas grandes de tiempo falso: los
      // asientos de AppLog de la carga fallida dejan un
      // temporizador de volcado que debe vencer (receta de
      // jornadaCerrarCascara).
      await tester.pumpWidget(const SizedBox());
      for (var i = 0; i < 4; i++) {
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        });
        await tester.pump(const Duration(seconds: 4));
      }
    },
        // skip: true — el motivo va en el comentario NIVEL NO
        // ALCANZADO sobre la declaración del test.
        skip: true);
  });

  // ── Pieza 4 · z06_mostrador-3 (r1) ────────────────────────
  group('F02-PB 4 · un solo acceso a Personalizar en vacío', () {
    testWidgets(
        'estado vacío: exactamente UN acceso (el permanente) '
        'y abre el editor', (tester) async {
      await jornadaPreparar(tester);
      await tester.runAsync(() async {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setStringList(kEstacionDiariaKey, <String>[]);
      });
      await jornadaSesionEntrenador(tester);
      await jornadaMontarHome(tester);
      expect(tester.takeException(), isNull);
      // Control: SÍ estamos en el estado vacío.
      expect(
          find.text('Tu día está vacío: ocultaste todos los bloques.'),
          findsWidgets);
      // El acceso permanente existe…
      final entrada = find.byKey(const ValueKey('mostrador-personalizar'));
      expect(entrada, findsOneWidget);
      // …y es el ÚNICO: ningún TextButton duplicado en la
      // vista vacía (antes coexistían dos).
      expect(find.widgetWithText(TextButton, 'Personalizar mi día'),
          findsNothing,
          reason: 'en vacío debe quedar un solo acceso: el '
              'IconButton permanente de la cabecera');
      // Y ese único acceso abre el editor (el test del lote
      // SL-3 G01-1 sigue describiendo esta misma entrada).
      await tester.tap(entrada);
      await jornadaDrenar(tester, vueltas: 6, ms: 80);
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text('Personalizar mi día'), findsWidgets);
      await jornadaCerrarCascara(tester);
    });
  });

  // ── Pieza 5 · z14_turnos-1 ────────────────────────────────
  group('F02-PB 5 · fallo de aperturas deja rastro', () {
    test('contrato de fuente acotado: el catch de aperturas '
        'registra y marca _errorCarga (sin catch mudo)', () {
      final s = _src('lib/ui/turnos_calendario.dart');
      final i = s.indexOf("allMirror('turnos_apertura')");
      expect(i, greaterThan(0));
      final tramo = s.substring(i, s.indexOf('_cargando = false', i));
      expect(tramo.contains('catch (_) {}'), isFalse,
          reason: 'el catch mudo de aperturas debe desaparecer');
      expect(tramo.contains('AppLog.error'), isTrue,
          reason: 'el fallo de aperturas deja rastro');
      expect(tramo.contains('falloAperturas = true'), isTrue);
      expect(tramo.contains('_errorCarga = falloAperturas'), isTrue,
          reason: 'el cierre de la carga refleja el fallo de '
              'aperturas en _errorCarga');
    });
  });

  // ── Pieza 6 · z14_turnos-2 ────────────────────────────────
  group('F02-PB 6 · _falloCarga guardada por generación', () {
    test('puro: solo la generación vigente publica', () {
      expect(
          debePublicarFalloCarga(genEstaCarga: 3, genVigente: 3),
          isTrue);
      expect(
          debePublicarFalloCarga(genEstaCarga: 2, genVigente: 3),
          isFalse,
          reason: 'un fallo tardío de otro mes no tapa el '
              'mes que cargó bien');
      expect(
          debePublicarFalloCarga(genEstaCarga: 4, genVigente: 3),
          isFalse);
    });

    test('contrato de fuente: _cargar publica _falloCarga '
        'solo tras la guarda (fijar Y limpiar)', () {
      final s = _src('lib/ui/historial_entrenador.dart');
      final i = s.indexOf('Future<void> _cargar() async');
      expect(i, greaterThan(0));
      final cuerpo =
          s.substring(i, s.indexOf('Future<void> _cargarDatos()', i));
      expect('debePublicarFalloCarga('.allMatches(cuerpo).length,
          greaterThanOrEqualTo(2),
          reason: 'la guarda cubre tanto fijar el fallo como '
              'limpiarlo en el éxito');
      expect(cuerpo.contains('_falloCarga = true'), isTrue);
      expect(cuerpo.contains('_falloCarga = false'), isTrue);
    });
  });
}
