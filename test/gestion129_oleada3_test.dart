/// Gestión 1.29 · Oleada 3 (clientes y ficha): batería de la oleada.
///
/// Cubre, contra el código vivo:
/// - FB-01 (D-B1-02): el teléfono EFECTIVO (movil primero) es
///   la única regla — puros de negocio, `coincideBusquedaListas`
///   y la línea de contacto de la fila (el carnet ya no se
///   pinta como teléfono).
/// - FB-02 (D-B1-01): `conteosDeBuscar` cuenta sobre la BASE
///   de la búsqueda, no sobre la lista filtrada.
/// - FB-07: `sanitizarTelefono` (pegado «+53 …» → 8 dígitos
///   limpios) y el flujo de Inscribir guardando el limpio.
/// - FB-03 (D-B1-04): el historial de la ficha declara su
///   muestra y «Ver pagos anteriores» la amplía de verdad.
/// - FB-04 (D-B1-03): «qué le falta» solo afirma la foto
///   VERIFICADA — con foto en el servidor sin descargar no
///   hay «Sin foto»; sin foto en ningún sitio, sí.
/// - FB-05 (D-B1-05): Invitados pinta la lista sin esperar al
///   conteo de reportes Plus; la insignia llega después.
/// - FB-06 (D-B1-06): la especial vencida se marca «VENCIDA»
///   en la ficha y Tarifas dice «ya no se aplica».
/// - D-B1-08: medidas — el campo no parseable se NOMBRA.
/// - D-B1-09: «Regenerar PIN»/«Revocar» respetan su bandera
///   de vuelo (un solo diálogo con doble toque).
/// - D-13: la fila única con importe tabular sirve en las 4
///   listas; «por cobrar» la usa con su importe.
/// - D-15: la cabecera de la ficha — insignia de Casa con los
///   roles de la fundación, legible en claro y en oscuro.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/acceso_app_cache.dart';
import 'package:ironbody_gym/invitados.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/mediciones_cliente.dart';
import 'package:ironbody_gym/negocio.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:ironbody_gym/ui/buscar.dart';
import 'package:ironbody_gym/ui/componentes.dart';
import 'package:ironbody_gym/ui/cuentas_cobrar.dart';
import 'package:ironbody_gym/ui/diseno.dart';
import 'package:ironbody_gym/ui/ficha.dart';
import 'package:ironbody_gym/ui/ficha_acceso_app.dart';
import 'package:ironbody_gym/ui/ficha_que_falta.dart';
import 'package:ironbody_gym/ui/ficha_secciones.dart';
import 'package:ironbody_gym/ui/inscribir.dart';
import 'package:ironbody_gym/ui/invitados.dart' as ui_inv;
import 'package:ironbody_gym/ui/listas.dart';
import 'package:ironbody_gym/ui/medidas_cliente.dart';
import 'package:ironbody_gym/ui/tarifas_especiales.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// ----------------------------------------------------------------
// Arnés común (patrón de la casa: FFI + sesión de mentira)
// ----------------------------------------------------------------

String _jwtFalso(String email, int telegramId) {
  String b64(Map<String, dynamic> m) =>
      base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');
  final header = b64({'alg': 'HS256', 'typ': 'JWT'});
  final payload = b64({
    'sub': '00000000-0000-0000-0000-0000000000ee',
    'aud': 'authenticated',
    'exp': 4102444800,
    'iat': 1700000000,
    'email': email,
    'role': 'authenticated',
    'app_metadata': {'telegram_id': telegramId, 'provider': 'email'},
  });
  return '$header.$payload.firma-de-mentira';
}

Future<void> _fijarSesion(String email, int telegramId) async {
  final sesion = jsonEncode({
    'access_token': _jwtFalso(email, telegramId),
    'token_type': 'bearer',
    'expires_in': 3600,
    'refresh_token': 'refresh-de-mentira',
    'user': {
      'id': '00000000-0000-0000-0000-0000000000ee',
      'aud': 'authenticated',
      'email': email,
      'app_metadata': {'telegram_id': telegramId, 'provider': 'email'},
      'user_metadata': <String, dynamic>{},
      'created_at': '2024-01-01T00:00:00.000Z',
    },
  });
  await Supabase.instance.client.auth.setInitialSession(sesion);
}

Future<void> _bdVacia() async {
  final dir = await getDatabasesPath();
  try {
    await File(p.join(dir, 'ironbody.db')).delete();
  } catch (_) {}
  await LocalDb.resetParaTest();
  await LocalDb.instance.db;
}

/// Drenaje realista para pantallas que leen la BD al abrir
/// (patrón de M4-BC / Oleada 2): los futuros de sqflite_ffi
/// no completan solo con pumps de la zona falsa.
Future<void> _drenar(WidgetTester tester,
    {int vueltas = 14, int ms = 120}) async {
  for (var i = 0; i < vueltas; i++) {
    await tester.runAsync(() async {
      await Future<void>.delayed(Duration(milliseconds: ms));
    });
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// Vacía los temporizadores de entrada de las secciones de
/// la ficha (225 ms) antes del desmontaje: si quedan vivos,
/// el test muere por «timer pending» aunque todo acierte.
Future<void> _vaciarTimers(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 500));
  await tester.pump();
}
/// Drena hasta que [buscado] aparece (la ficha tarda ~5 s
/// reales en salir de «cargando» con el servidor de mentira:
/// el banner de sync agota su primer intento). Patrón del
/// arnés de M4-BC: parar en cuanto el dato está pintado.
Future<void> _esperarVisible(WidgetTester tester, Finder buscado,
    {int vueltas = 30}) async {
  for (var i = 0; i < vueltas; i++) {
    if (buscado.evaluate().isNotEmpty) return;
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 250));
    });
    await tester.pump(const Duration(milliseconds: 60));
  }
}

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    // NoIsolate (patrón de banco_flujos/ajustes_127): los
    // futuros de BD completan con las bombas de la zona de
    // test; con la variante isolate, el push de sync que
    // disparan las ops encoladas nunca llega a soltar su
    // cerrojo y su latido de 60 s queda pendiente al cierre.
    databaseFactory = databaseFactoryFfiNoIsolate;
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(url: 'http://127.0.0.1:9', anonKey: 'dummy');
    // path_provider → un temporal (patrón de
    // argon_fotos_caza_test): la ficha con foto en el
    // servidor consulta la caché de fotos al abrir.
    final docs = await Directory.systemTemp.createTemp('oleada3_docs');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (call) async => docs.path);
    // app_links (patrón de banco_flujos/ajustes_127): sin
    // estos mocks, la escucha de deep links de Supabase Auth
    // tumba tests de pantallas completas en la suite.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(
            const EventChannel('com.llfbandit.app_links/events'),
            MockStreamHandler.inline(onListen: (_, __) {}));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('com.llfbandit.app_links/messages'),
            (call) async => null);
  });

  setUp(() async {
    await _bdVacia();
    AccesoAppCache.instance.limpiar();
    ui_inv.servicioInvitadosParaTest = null;
    ui_inv.conteoReportesPlusParaTest = null;
  });

  // --------------------------------------------------------------
  // FB-01 · teléfono efectivo (puros)
  // --------------------------------------------------------------
  group('FB-01 · teléfono efectivo único', () {
    test('migrado: manda movil y el carnet de telefono no cuenta', () {
      final c = <String, dynamic>{
        'movil': '58191577',
        'telefono': '90051512345', // el carnet, como vino en la migración
      };
      expect(telefonoEfectivoWa(c), '5358191577');
      expect(telefonoEfectivoLocal(c), '58191577');
    });

    test('sin movil válido manda telefono; sin ninguno, vacío', () {
      expect(
          telefonoEfectivoWa({'telefono': '52123456'}), '5352123456');
      expect(
          telefonoEfectivoWa({'movil': '123', 'telefono': '52123456'}),
          '5352123456');
      expect(telefonoEfectivoWa({'telefono': '90051512345'}), '');
      expect(telefonoEfectivoLocal({'telefono': '90051512345'}), '—');
      expect(telefonoEfectivoWa(const {}), '');
    });

    test('coincideBusquedaListas encuentra al migrado por su número', () {
      final c = <String, dynamic>{
        'nombre': 'Migrado Uno',
        'movil': '58191577',
        'telefono': '90051512345',
      };
      expect(coincideBusquedaListas(c, '5819'), isTrue);
      expect(coincideBusquedaListas(c, '+53 5819 1577'), isTrue);
      expect(coincideBusquedaListas(c, 'migrado'), isTrue);
      // Los dígitos del carnet NO lo «encuentran» como teléfono.
      expect(coincideBusquedaListas(c, '90051512345'), isFalse);
      expect(coincideBusquedaListas(c, '1512345'), isFalse);
    });

    testWidgets('la línea de contacto de la fila pinta el móvil, '
        'no la cola del carnet', (tester) async {
      final hoy = ahoraHabana();
      final hasta = DateTime(hoy.year, hoy.month, hoy.day + 30);
      final c = <String, dynamic>{
        'id': 41,
        'nombre': 'Migrado Uno',
        'movil': '58191577',
        'telefono': '90051512345',
        'carnet': '90051512345',
        'pagado_hasta':
            '${hasta.year}-${hasta.month.toString().padLeft(2, '0')}-${hasta.day.toString().padLeft(2, '0')}',
      };
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: FilaCliente(cliente: c, desambiguar: true)),
      ));
      await tester.pump();
      expect(find.text('📞 58191577'), findsOneWidget);
      expect(find.textContaining('1512345'), findsNothing);
    });
  });

  // --------------------------------------------------------------
  // FB-02 · conteos de Buscar sobre la base (puro)
  // --------------------------------------------------------------
  group('FB-02 · conteosDeBuscar sobre la base', () {
    String isoEn(int dias) {
      final hoy = ahoraHabana();
      final f = DateTime(hoy.year, hoy.month, hoy.day + dias);
      return '${f.year}-${f.month.toString().padLeft(2, '0')}-${f.day.toString().padLeft(2, '0')}';
    }

    test('cuenta la base entera aunque la lista visible sea un '
        'subconjunto filtrado', () async {
      // Sesión de entrenador (no dueño): el protegido cuenta
      // como protegido de verdad.
      await _fijarSesion('duany@ironbody.local', 969869611);
      final base = <Map<String, dynamic>>[
        {'id': 1, 'nombre': 'Al Día', 'pagado_hasta': isoEn(30), 'foto_storage': 'a.jpg'},
        {'id': 2, 'nombre': 'Por Vencer', 'pagado_hasta': isoEn(3), 'foto_storage': 'b.jpg'},
        {'id': 3, 'nombre': 'Vencido', 'pagado_hasta': isoEn(-5)},
        {'id': 4, 'nombre': 'Sin Fecha', 'pagado_hasta': null},
        {'id': 5, 'nombre': 'De La Casa', 'cuenta_casa': 1, 'pagado_hasta': isoEn(-90)},
        {'id': 6, 'nombre': 'Protegido', 'protegido': 1, 'pagado_hasta': isoEn(-5)},
      ];
      final conteos = conteosDeBuscar(base);
      expect(conteos['todos'], 6);
      expect(conteos['aldia'], 2,
          reason: 'al día (30 días) + la Casa, que nunca vence');
      expect(conteos['porvencer'], 1);
      expect(conteos['vencidos'], 2,
          reason: 'vencido + sin fecha; el protegido NO alimenta');
      expect(conteos['sinfoto'], 3,
          reason: 'vencido, sin fecha y la Casa; el protegido no');
    });

    test(
        'Yunque de cambios 1.31 (M1): el pausado en curso no '
        'cuenta como vencido; sin conjunto, no cambia', () async {
      await _fijarSesion('duany@ironbody.local', 969869611);
      final base = <Map<String, dynamic>>[
        {'id': 3, 'nombre': 'Pausado', 'pagado_hasta': isoEn(-5)},
        {'id': 4, 'nombre': 'Sin Fecha Pausado', 'pagado_hasta': null},
        {'id': 7, 'nombre': 'Vencido Real', 'pagado_hasta': isoEn(-2)},
      ];
      final conPausa = conteosDeBuscar(base, congelados: {3, 4});
      expect(conPausa['todos'], 3);
      expect(conPausa['vencidos'], 1,
          reason: 'solo el vencido real; los dos pausados fuera');
      expect(conPausa['sinfoto'], 3,
          reason: 'el pausado sigue contando en sin foto');
      final sinPausa = conteosDeBuscar(base);
      expect(sinPausa['vencidos'], 3);
    });

    test(
        'Yunque 1.34 (C5-1): el pausado en curso tampoco cuenta '
        'como POR VENCER (M1 solo había cerrado vencidos)', () async {
      await _fijarSesion('duany@ironbody.local', 969869611);
      final base = <Map<String, dynamic>>[
        {'id': 8, 'nombre': 'Pausado Por Vencer', 'pagado_hasta': isoEn(3)},
        {'id': 9, 'nombre': 'Por Vencer Real', 'pagado_hasta': isoEn(5)},
      ];
      final conPausa = conteosDeBuscar(base, congelados: {8});
      expect(conPausa['porvencer'], 1,
          reason: 'solo el por vencer real; la pausa en curso fuera');
      final sinPausa = conteosDeBuscar(base);
      expect(sinPausa['porvencer'], 2);
    });

    test(
        'Yunque de cambios 1.31 (M1): chipEstadoFila en pausa '
        'dice EN PAUSA y no vencido', () {
      final chip = chipEstadoFila(
          dias: -5, pagadoHasta: isoEn(-5), enPausa: true);
      expect(chip.texto, contains('EN PAUSA'));
      expect(chip.estado, EstadoMembresia.congelado);
      final sin = chipEstadoFila(dias: -5, pagadoHasta: isoEn(-5));
      // 1.36 (136-233): el chip compone dato-primero
      // («Hace 5 días · venció …»); este test fijaba el
      // «Venció» inicial de la composición anterior.
      expect(sin.texto, contains('Hace 5 días'));
      expect(sin.texto, contains('venció'));
    });
  });

  // --------------------------------------------------------------
  // FB-07 · sanitizarTelefono (puro)
  // --------------------------------------------------------------
  group('FB-07 · sanitizarTelefono', () {
    test('el pegado con prefijo y espacios guarda 8 dígitos', () {
      expect(sanitizarTelefono('+53 5819 1577'), '58191577');
      expect(sanitizarTelefono('5819 1577'), '58191577');
      expect(sanitizarTelefono('58191577'), '58191577');
      expect(sanitizarTelefono('+5358191577'), '58191577');
      expect(sanitizarTelefono('53 58191577'), '58191577');
    });

    test('lo que no es móvil cubano válido no sanitiza', () {
      expect(sanitizarTelefono('12345678'), isNull);
      expect(sanitizarTelefono('5819157'), isNull);
      expect(sanitizarTelefono('90051512345'), isNull,
          reason: 'el carnet no es un teléfono');
      expect(sanitizarTelefono(''), isNull);
    });
  });

  // --------------------------------------------------------------
  // D-13 · la fila única con importe
  // --------------------------------------------------------------
  group('D-13 · fila única de lista larga', () {
    Map<String, dynamic> clienteBase({int dias = 30}) {
      final hoy = ahoraHabana();
      final f = DateTime(hoy.year, hoy.month, hoy.day + dias);
      return {
        'id': 51,
        'nombre': 'Cliente Fila',
        'pagado_hasta':
            '${f.year}-${f.month.toString().padLeft(2, '0')}-${f.day.toString().padLeft(2, '0')}',
      };
    }

    testWidgets('el mismo cliente se pinta igual en modo lista '
        'y en modo cobrar (nombre + insignia con palabra)', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: FilaCliente(cliente: clienteBase())),
      ));
      await tester.pump();
      expect(find.text('Cliente Fila'), findsOneWidget);
      expect(find.textContaining('Al día'), findsOneWidget);

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: FilaCliente(
          cliente: clienteBase(dias: -10),
          diasAtraso: 10,
          importeTexto: '2000 CUP',
          importeEtiqueta: 'tarifa mensual',
        )),
      ));
      await tester.pump();
      expect(find.text('Cliente Fila'), findsOneWidget);
      // 1.36 (136-233): dato-primero — la insignia del
      // vencido abre con «Hace N días», no con «Venció».
      expect(find.textContaining('Hace 10 días'), findsOneWidget);
      expect(find.text('2000 CUP'), findsOneWidget);
      expect(find.text('tarifa mensual'), findsOneWidget);
      // El importe va en cifras tabulares (la columna no baila).
      final textoImporte = tester.widget<Text>(find.text('2000 CUP'));
      expect(
          textoImporte.style?.fontFeatures,
          contains(const FontFeature.tabularFigures()));
    });

    testWidgets('«Vencidos por cobrar» usa la fila única con '
        'su importe', (tester) async {
      await tester.runAsync(() async {
        final hoy = ahoraHabana();
        final f = DateTime(hoy.year, hoy.month, hoy.day - 10);
        await LocalDb.instance.upsertMirror('clientes', 52, {
          'id': 52,
          'nombre': 'Vencido Cobrar',
          'telefono': '58112233',
          'sexo': 'M',
          'pagado_hasta':
              '${f.year}-${f.month.toString().padLeft(2, '0')}-${f.day.toString().padLeft(2, '0')}',
          'estado': 'activo',
        }, 1);
      });
      await tester.pumpWidget(const MaterialApp(
          home: Scaffold(body: CuentasCobrarScreen(incrustada: true))));
      await _drenar(tester);
      expect(find.byType(FilaCliente), findsOneWidget);
      expect(find.text('Vencido Cobrar'), findsOneWidget);
      // El importe DE LA FILA (la pantalla también enseña el
      // total adeudado con la misma cifra: se acota a la fila).
      expect(
          find.descendant(
              of: find.byType(FilaCliente),
              matching: find.text('2000 CUP')),
          findsOneWidget,
          reason: 'una mensualidad estándar en efectivo');
      expect(find.text('tarifa mensual'), findsOneWidget);
    });
  });

  // --------------------------------------------------------------
  // D-15 · cabecera de la ficha
  // --------------------------------------------------------------
  group('D-15 · cabecera pulida', () {
    double contraste(Color frente, Color fondo) {
      double lum(Color c) {
        double canal(double v) => v <= 0.03928
            ? v / 12.92
            : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
        return 0.2126 * canal(c.r) +
            0.7152 * canal(c.g) +
            0.0722 * canal(c.b);
      }

      final l1 = lum(frente);
      final l2 = lum(fondo);
      final (mayor, menor) = l1 >= l2 ? (l1, l2) : (l2, l1);
      return (mayor + 0.05) / (menor + 0.05);
    }

    for (final oscuro in [false, true]) {
      testWidgets(
          'la insignia de Casa es legible en tema '
          '${oscuro ? 'oscuro' : 'claro'}', (tester) async {
        await tester.pumpWidget(MaterialApp(
          theme: ThemeData(
              brightness: oscuro ? Brightness.dark : Brightness.light),
          home: Scaffold(
            body: CabeceraFicha(
              nombre: 'Cliente Casa',
              foto: null,
              colorMarco: AppColores.alerta,
              esCasa: true,
              dias: null,
              heroTag: null,
              onFotoTap: null,
              onCambiarFoto: () {},
            ),
          ),
        ));
        await tester.pump();
        final texto = tester.widget<Text>(find.text('Cuenta a la Casa'));
        final tinta = texto.style?.color;
        expect(tinta, isNotNull);
        // La tinta ES el rol de la fundación para el tema.
        final ctx = tester.element(find.text('Cuenta a la Casa'));
        expect(tinta, AppColores.alertaTexto(ctx));
        // Y contra su fondo (tinte de la propia tinta sobre la
        // superficie) el contraste es de texto legible.
        final fondoEfectivo = Color.alphaBlend(
            tinta!.withValues(alpha: 0.13),
            AppColores.superficie(ctx));
        expect(contraste(tinta, fondoEfectivo),
            greaterThanOrEqualTo(4.0));
        // El botón de foto lleva el icono canónico D-07.
        expect(
            find.byIcon(Icons.photo_camera_rounded), findsOneWidget);
        expect(find.byIcon(Icons.camera_alt_rounded), findsNothing);
      });

      testWidgets(
          'la insignia de estado (vencido) es legible en tema '
          '${oscuro ? 'oscuro' : 'claro'}', (tester) async {
        await tester.pumpWidget(MaterialApp(
          theme: ThemeData(
              brightness: oscuro ? Brightness.dark : Brightness.light),
          home: Scaffold(
            body: CabeceraFicha(
              nombre: 'Cliente Vencido',
              foto: null,
              colorMarco: AppColores.error,
              esCasa: false,
              dias: -3,
              heroTag: null,
              onFotoTap: null,
              onCambiarFoto: () {},
            ),
          ),
        ));
        await tester.pump();
        final ctx = tester.element(find.textContaining('VENCIDO'));
        final texto =
            tester.widget<Text>(find.textContaining('VENCIDO'));
        expect(texto.style?.color, AppColores.errorTexto(ctx));
      });
    }
  });

  // --------------------------------------------------------------
  // FB-03 · historial con «ver más» (ficha, integración)
  // --------------------------------------------------------------
  group('FB-03 · historial de la ficha', () {
    String fechaMes(int mesesAtras) {
      final hoy = ahoraHabana();
      var y = hoy.year;
      var m = hoy.month - mesesAtras;
      while (m <= 0) {
        m += 12;
        y--;
      }
      return '${y.toString().padLeft(4, '0')}-'
          '${m.toString().padLeft(2, '0')}-01';
    }

    String tituloMes(int mesesAtras) {
      const meses = [
        '', 'Enero', 'Febrero', 'Marzo', 'Abril', 'Mayo', 'Junio',
        'Julio', 'Agosto', 'Septiembre', 'Octubre', 'Noviembre',
        'Diciembre',
      ];
      final hoy = ahoraHabana();
      var y = hoy.year;
      var m = hoy.month - mesesAtras;
      while (m <= 0) {
        m += 12;
        y--;
      }
      return '${meses[m]} $y';
    }

    testWidgets('14 pagos: se ven 10 con rótulo y «Ver pagos '
        'anteriores» trae los 14', (tester) async {
      await tester.runAsync(() async {
        await LocalDb.instance.upsertMirror('clientes', 61, {
          'id': 61,
          'nombre': 'Cliente Historial',
          'telefono': '58112233',
          'sexo': 'M',
          'pagado_hasta': fechaMes(0),
          'estado': 'activo',
        }, 1);
        for (var i = 0; i < 14; i++) {
          await LocalDb.instance.upsertMirror('pagos', 1000 + i, {
            'id': 1000 + i,
            'cliente_id': 61,
            'fecha': fechaMes(i),
            'metodo': 'efectivo',
            'monto': 2000,
            'periodo': 'mensual',
          }, 10 + i);
        }
      });
      tester.view.physicalSize = const Size(500, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
          const MaterialApp(home: FichaScreen(clienteId: 61)));
      await _esperarVisible(tester, find.text('Cliente Historial'));
      expect(find.text('Cliente Historial'), findsWidgets);
      // Hasta el historial (sección perezosa: hay que bajar).
      await tester.scrollUntilVisible(
          find.text('Ver pagos anteriores'), 300,
          scrollable: find.byType(Scrollable).first);
      await _drenar(tester, vueltas: 4);
      expect(
          find.text('Se muestran los últimos 10 pagos y las '
              'últimas 20 ventas de suplementos.'),
          findsOneWidget);
      // El mes más viejo (13 meses atrás) aún no existe.
      expect(find.text(tituloMes(13)), findsNothing);
      // «Ver pagos anteriores»: se dispara el callback REAL
      // del botón. Un tap sintético no es fiable aquí — la
      // ficha apila capas flotantes y scrolls anidados sobre
      // la tarjeta y el hit-test cae en ellos (verificado dos
      // veces); lo que se prueba es el efecto del callback.
      final boton = tester.widget<TextButton>(find.ancestor(
          of: find.text('Ver pagos anteriores'),
          matching: find.byType(TextButton)));
      expect(boton.onPressed, isNotNull);
      boton.onPressed!();
      await _drenar(tester);
      // El pie desaparece y el historial completo entra.
      expect(find.text('Ver pagos anteriores'), findsNothing);
      await tester.scrollUntilVisible(find.text(tituloMes(13)), 300,
          scrollable: find.byType(Scrollable).first);
      expect(find.text(tituloMes(13)), findsOneWidget);
      await _vaciarTimers(tester);
    });

    testWidgets('la tarjeta sin callback no pinta el pie',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: TarjetaHistorialFicha(
            entradas: const [],
            filtro: 'todo',
            onFiltro: (_) {},
            serviciosHist: const [],
            clienteId: 61,
            esAdmin: false,
            esOwner: false,
            onReenviarRecibo: (_) {},
            onVerComprobante: (_) {},
            onCorregirPago: (_) {},
            onConciliar: (_) {},
          ),
        ),
      ));
      await tester.pump();
      expect(find.text('Ver pagos anteriores'), findsNothing);
    });
  });

  // --------------------------------------------------------------
  // FB-04 · «qué le falta» con la foto verificada
  // --------------------------------------------------------------
  group('FB-04 · qué le falta y la foto', () {
    test('pendientesDeFicha: la foto no verificada no se afirma',
        () {
      final hoy = DateTime(2026, 11, 7);
      expect(
        pendientesDeFicha(
          tieneFoto: null,
          telefonoValido: true,
          tieneAccesoApp: true,
          ultimaMedicionEn: hoy,
          hoy: hoy,
        ),
        isEmpty,
      );
      expect(
        pendientesDeFicha(
          tieneFoto: false,
          telefonoValido: true,
          tieneAccesoApp: true,
          ultimaMedicionEn: hoy,
          hoy: hoy,
        ),
        [PendienteFicha.sinFoto],
      );
    });

    Future<void> abrirFicha(WidgetTester tester, int id,
        String nombre) async {
      tester.view.physicalSize = const Size(500, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
          MaterialApp(home: FichaScreen(clienteId: id)));
      await _esperarVisible(tester, find.text(nombre));
      await tester.scrollUntilVisible(find.text('Qué le falta'), 250,
          scrollable: find.byType(Scrollable).first);
      await _drenar(tester, vueltas: 4);
    }

    testWidgets('foto registrada en el servidor sin archivo '
        'local: NO sale «Sin foto»', (tester) async {
      await tester.runAsync(() async {
        await LocalDb.instance.upsertMirror('clientes', 62, {
          'id': 62,
          'nombre': 'Cliente Con Foto Nube',
          'telefono': '58112233',
          'sexo': 'F',
          'foto_storage': 'apk/62.jpg',
          'pagado_hasta': '2027-01-01',
          'estado': 'activo',
        }, 1);
      });
      await abrirFicha(tester, 62, 'Cliente Con Foto Nube');
      expect(find.text('Qué le falta'), findsOneWidget);
      expect(find.text('Sin foto'), findsNothing,
          reason: 'la foto existe en el servidor aunque este '
              'teléfono no la haya descargado');
      expect(find.text('Sin mediciones'), findsOneWidget);
      await _vaciarTimers(tester);
    });

    testWidgets('sin foto en ningún sitio: SÍ sale «Sin foto»',
        (tester) async {
      await tester.runAsync(() async {
        await LocalDb.instance.upsertMirror('clientes', 63, {
          'id': 63,
          'nombre': 'Cliente Sin Foto',
          'telefono': '58112233',
          'sexo': 'M',
          'pagado_hasta': '2027-01-01',
          'estado': 'activo',
        }, 1);
      });
      await abrirFicha(tester, 63, 'Cliente Sin Foto');
      expect(find.text('Sin foto'), findsOneWidget);
      await _vaciarTimers(tester);
    });
  });

  // --------------------------------------------------------------
  // FB-06 · tarifa especial vencida, verdad única
  // --------------------------------------------------------------
  group('FB-06 · tarifa especial vencida', () {
    Future<void> sembrarClienteYTarifa(
        int id, String vigenteHasta) async {
      await LocalDb.instance.upsertMirror('clientes', id, {
        'id': id,
        'nombre': 'Cliente Tarifa',
        'telefono': '58112233',
        'sexo': 'M',
        'pagado_hasta': '2027-01-01',
        'estado': 'activo',
      }, 1);
      final db = await LocalDb.instance.db;
      await db.insert('tarifa_especial', {
        'id': 't-$id',
        'cliente_id': id,
        'nombre': 'Especial test',
        'periodo': 'mensual',
        'monto_efectivo': 1500,
        'monto_transferencia': 1800,
        'vigente_desde': '2026-01-01',
        'vigente_hasta': vigenteHasta,
        'activa': 1,
        'creada_ts': '2026-01-01T10:00:00-04:00',
        'actualizada_ts': '2026-01-01T10:00:00-04:00',
      });
    }

    testWidgets('la ficha marca VENCIDA la especial caducada y '
        'no marca la vigente', (tester) async {
      tester.view.physicalSize = const Size(500, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.runAsync(() => sembrarClienteYTarifa(64, '2020-01-01'));
      await tester.pumpWidget(const MaterialApp(
          home: FichaScreen(key: ValueKey(64), clienteId: 64)));
      await _esperarVisible(tester, find.text('Cliente Tarifa'));
      await tester.scrollUntilVisible(find.text('Tarifa especial'), 250,
          scrollable: find.byType(Scrollable).first);
      await _drenar(tester, vueltas: 4);
      expect(find.textContaining('VENCIDA'), findsOneWidget);

      await tester.runAsync(() => sembrarClienteYTarifa(65, '2099-01-01'));
      await tester.pumpWidget(const MaterialApp(
          home: FichaScreen(key: ValueKey(65), clienteId: 65)));
      await _esperarVisible(tester, find.text('Cliente Tarifa'));
      await tester.scrollUntilVisible(find.text('Tarifa especial'), 250,
          scrollable: find.byType(Scrollable).first);
      await _drenar(tester, vueltas: 4);
      expect(find.textContaining('Tarifa especial'), findsOneWidget);
      expect(find.textContaining('VENCIDA'), findsNothing);
      await _vaciarTimers(tester);
    });

    testWidgets('Tarifas dice «ya no se aplica» de la vencida',
        (tester) async {
      await tester.runAsync(() => sembrarClienteYTarifa(66, '2020-01-01'));
      await tester.pumpWidget(
          const MaterialApp(home: TarifasScreen()));
      await _drenar(tester);
      expect(find.textContaining('ya no se aplica'), findsWidgets);
      expect(find.textContaining('Sigue aplicando'), findsNothing);
    });
  });

  // --------------------------------------------------------------
  // FB-05 · Invitados pinta primero
  // --------------------------------------------------------------
  group('FB-05 · Invitados pinta sin esperar al conteo Plus', () {
    testWidgets('con el conteo colgado la lista está pintada y '
        'usable; al responder, la insignia aparece', (tester) async {
      final completer = Completer<int>();
      ui_inv.conteoReportesPlusParaTest = () => completer.future;
      ui_inv.servicioInvitadosParaTest = InvitadosService(
        rpc: (nombre, params) async {
          if (nombre == 'invitados_listar') {
            return {
              'invitados': [
                {
                  'id': 'inv-1',
                  'nombre': 'Invitado Uno',
                  'telefono': '58112233',
                  'estado': 'activo',
                  'creado_en': '2026-11-01T10:00:00',
                  'caduca_en': '2026-12-01T10:00:00',
                  'dias_restantes': 24,
                },
              ],
            };
          }
          if (nombre == 'invitados_resumen') return null;
          throw Exception('RPC no simulada: $nombre');
        },
      );
      addTearDown(() {
        ui_inv.servicioInvitadosParaTest = null;
        ui_inv.conteoReportesPlusParaTest = null;
      });
      await tester.pumpWidget(
          const MaterialApp(home: ui_inv.InvitadosScreen()));
      await _drenar(tester);
      // La lista YA está pintada con el conteo aún colgado.
      expect(find.text('Invitado Uno'), findsOneWidget);
      expect(find.textContaining('Reportes Plus por atender'),
          findsNothing);
      // El conteo aterriza: la insignia aparece sola.
      completer.complete(2);
      await _drenar(tester, vueltas: 5);
      expect(find.text('Reportes Plus por atender (2)'),
          findsOneWidget);
    });
  });

  // --------------------------------------------------------------
  // D-B1-09 · banderas de vuelo en la sección Acceso App
  // --------------------------------------------------------------
  group('D-B1-09 · Regenerar/Revocar con bandera de vuelo', () {
    Future<void> sembrarAccesoActivo(WidgetTester tester) async {
      await tester.runAsync(() async {
        AccesoAppCache.instance.limpiar();
        await LocalDb.instance.setMeta(
          'acceso_app_cache_v1',
          jsonEncode({
            'verificado_en': '2026-11-07T10:00:00.000',
            'filas': <dynamic>[],
          }),
        );
        await AccesoAppCache.instance.cargar();
        AccesoAppCache.instance.actualizar(
          71,
          AccesoCliente(
            clienteId: 71,
            nombre: 'Cliente Siete',
            telefono: '58112233',
            activo: true,
            intentosFallidos: 0,
            bloqueadoHasta: null,
            estaBloqueado: false,
            ultimoAccesoEn: null,
            createdAt: null,
          ),
        );
      });
    }

    Widget seccion() => const MaterialApp(
          home: Scaffold(
            body: SeccionAccesoAppFicha(
              clienteId: 71,
              nombreCliente: 'Cliente Siete',
              telefonoEfectivoWa: '5358112233',
            ),
          ),
        );

    testWidgets('doble toque en Revocar: un solo diálogo y el '
        'botón queda deshabilitado en vuelo', (tester) async {
      // Yunque R5-M2-2: «Revocar» solo se pinta al DUEÑO: el
      // test monta la sección SIN sesión (isOwner=false) y
      // el botón ya no existe para él. La mecánica de la
      // bandera de vuelo se sigue probando con «Regenerar
      // PIN», que sí se pinta (su método no lleva la
      // guarda: crear/regenerar es del permiso de generar).
      // El contrato de la guarda vive en yunque_r5_test.
      await sembrarAccesoActivo(tester);
      await tester.pumpWidget(seccion());
      await tester.pump();
      expect(find.text('Regenerar PIN'), findsOneWidget);
      // R5-M2-2: sin sesión de dueño, «Revocar» ni se pinta.
      expect(find.text('Revocar'), findsNothing);
      final botonRegenerar =
          find.widgetWithText(OutlinedButton, 'Regenerar PIN');
      // Doble toque EN EL MISMO FRAME (gestos crudos, sin
      // bomba intermedia): las dos pulsaciones llegan al
      // botón antes de que el diálogo se pinte — la segunda
      // solo la puede parar la bandera de vuelo.
      final centro = tester.getCenter(botonRegenerar);
      final g1 = await tester.startGesture(centro);
      await g1.up();
      final g2 = await tester.startGesture(centro);
      await g2.up();
      await tester.pump();
      expect(find.byType(AlertDialog), findsOneWidget,
          reason: 'la bandera se levanta antes del diálogo');
      expect(find.text('Regenerar PIN'), findsWidgets);
      // En vuelo, el botón de la sección está deshabilitado.
      expect(
          tester.widget<OutlinedButton>(botonRegenerar).onPressed,
          isNull);
      // Cancelar baja la bandera: el botón revive.
      await tester.tap(find.widgetWithText(TextButton, 'Cancelar'));
      await tester.pump();
      expect(find.byType(AlertDialog), findsNothing);
      expect(
          tester.widget<OutlinedButton>(botonRegenerar).onPressed,
          isNotNull);
    });

    testWidgets('doble toque en Regenerar PIN: un solo diálogo',
        (tester) async {
      await sembrarAccesoActivo(tester);
      await tester.pumpWidget(seccion());
      await tester.pump();
      final botonRegenerar =
          find.widgetWithText(OutlinedButton, 'Regenerar PIN');
      // Doble toque en el mismo frame, como en Revocar.
      final centro = tester.getCenter(botonRegenerar);
      final g1 = await tester.startGesture(centro);
      await g1.up();
      final g2 = await tester.startGesture(centro);
      await g2.up();
      await tester.pump();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text('Regenerar PIN'), findsWidgets);
      await tester.tap(find.widgetWithText(TextButton, 'Cancelar'));
      await tester.pump();
      expect(find.byType(AlertDialog), findsNothing);
      expect(
          tester.widget<OutlinedButton>(botonRegenerar).onPressed,
          isNotNull);
    });
  });

  // --------------------------------------------------------------
  // D-B1-08 · medidas: el campo inválido se nombra
  // --------------------------------------------------------------
  group('D-B1-08 · medidas con campos no parseables', () {
    Future<void> abrirDialogo(WidgetTester tester) async {
      // Superficie alta: el diálogo trae los 7 campos de
      // métrica y en la superficie por defecto (800×600)
      // desborda, ensuciando el test con errores de layout.
      tester.view.physicalSize = const Size(500, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
            body: TarjetaMedidas(clienteId: 72, medidasIniciales: [])),
      ));
      await tester.pump();
      await tester.tap(find.text('Registrar medida'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Registrar medida'), findsWidgets);
    }

    /// Deja terminar el aviso y el push de sync encolado
    /// antes del desmontaje: el push sostiene un latido
    /// periódico de 60 s y un watchdog de 10 s mientras
    /// retiene el cerrojo. Sus pasos necesitan tiempo REAL
    /// (BD y red contra el servidor de mentira) y sus
    /// timeouts corren en tiempo FALSO: se intercalan pasos
    /// cortos de ambos hasta que el push falla del todo y
    /// suelta el cerrojo.
    Future<void> cerrarAviso(WidgetTester tester) async {
      for (var i = 0; i < 20; i++) {
        await tester.runAsync(() async {
          await Future<void>.delayed(
              const Duration(milliseconds: 250));
        });
        await tester.pump(const Duration(seconds: 1));
        await tester.pump();
      }
    }

    testWidgets('un inválido entre válidos: se guarda el válido '
        'y el aviso nombra el campo', (tester) async {
      await _fijarSesion('jc@ironbody.local', 735772141);
      await abrirDialogo(tester);
      final campos = find.byType(TextField);
      // Orden kMetricasMedicion: peso_kg, cintura_cm, …
      await tester.enterText(campos.at(0), '8O'); // O de letra
      await tester.enterText(campos.at(1), '90');
      await tester.tap(find.widgetWithText(FilledButton, 'Registrar'));
      await _drenar(tester, vueltas: 6);
      expect(find.textContaining('Peso no se guardó'), findsOneWidget);
      // La fila encolada es el hecho durable (la lectura
      // local espejo+pendientes compite con el push que el
      // propio registro dispara): cintura va, peso no.
      final filas = await tester.runAsync(() async {
        final db = await LocalDb.instance.db;
        return db.query('ops_queue',
            where: 'tipo = ?',
            whereArgs: ['registrar_medicion_cliente']);
      });
      expect(filas, hasLength(1));
      final payload = jsonDecode(filas!.single['payload'] as String)
          as Map<String, dynamic>;
      final medidas = payload['medidas'] as Map;
      expect(medidas['cintura_cm'], 90);
      expect(medidas.containsKey('peso_kg'), isFalse,
          reason: 'el peso inválido no se guardó en silencio: '
              'simplemente no va en la fila');
      await cerrarAviso(tester);
    });

    testWidgets('ninguno parsea: el aviso dice la verdad y '
        'nada se guarda', (tester) async {
      await _fijarSesion('jc@ironbody.local', 735772141);
      await abrirDialogo(tester);
      final campos = find.byType(TextField);
      await tester.enterText(campos.at(0), 'abc');
      await tester.tap(find.widgetWithText(FilledButton, 'Registrar'));
      await _drenar(tester, vueltas: 6);
      expect(find.text('Peso no se guardó: revisa el valor.'),
          findsOneWidget);
      final filas = await tester.runAsync(() async {
        final db = await LocalDb.instance.db;
        return db.query('ops_queue',
            where: 'tipo = ?',
            whereArgs: ['registrar_medicion_cliente']);
      });
      expect(filas, isEmpty,
          reason: 'ninguna op de medida se encoló');
      final guardadas = await tester.runAsync(
          () => medicionesClienteLocal(72));
      expect(guardadas, isEmpty);
      await cerrarAviso(tester);
    });
  });

  // --------------------------------------------------------------
  // FB-07 · Inscribir guarda el teléfono sanitizado (flujo)
  // --------------------------------------------------------------
  group('FB-07 · Inscribir con teléfono pegado', () {
    testWidgets('pegar «+53 5819 1577» guarda 58191577 en la op',
        (tester) async {
      // Permisos sembrados como en el arnés del banco (la
      // sesión de dueño ya viene del grupo de medidas).
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          'cache_permisos_entrenador_json@',
          jsonEncode({
            'can_cobrar_pagos': true,
            'can_inscribir_clientes': true,
            'can_editar_fichas': true,
          }));
      await prefs.setBool('cache_entrenador_activo@', true);
      await prefs.setBool('cache_entrenador_habilitado@', true);
      await tester.pumpWidget(
          const MaterialApp(home: InscribirScreen()));
      // Sin pumpAndSettle: en esta pantalla nunca se asienta
      // del todo (banner de sync + sesión) y el timeout salta
      // según la carga de la máquina. Se espera el formulario.
      await _esperarVisible(tester, find.byType(TextFormField));
      final campos = find.byType(TextFormField);
      // Orden del formulario: nombre, teléfono, carnet…
      await tester.ensureVisible(campos.at(0));
      await tester.enterText(campos.at(0), 'Cliente Pegado');
      await tester.ensureVisible(campos.at(1));
      await tester.enterText(campos.at(1), '+53 5819 1577');
      await tester.ensureVisible(campos.at(2));
      await tester.enterText(campos.at(2), '900515');
      // El cursor parpadeante: se quita el foco antes de
      // seguir (truco del banco).
      FocusManager.instance.primaryFocus?.unfocus();
      await _drenar(tester, vueltas: 3);
      await tester.ensureVisible(find.text('Guardar inscripción'));
      await tester.tap(find.text('Guardar inscripción'));
      await _esperarVisible(tester, find.text('Confirmar inscripción'));
      expect(find.text('Confirmar inscripción'), findsOneWidget);
      await tester.tap(find.text('Confirmar'));
      await _drenar(tester, vueltas: 8);
      // La op encolada es el hecho durable: pendingOps()
      // compite con el push que la inscripción dispara (la
      // op puede ya ir «enviada»); se lee la cola por tipo.
      final filas = await tester.runAsync(() async {
        final db = await LocalDb.instance.db;
        return db.query('ops_queue',
            where: 'tipo = ?', whereArgs: ['inscribir']);
      });
      expect(filas, hasLength(1));
      final payload = jsonDecode(filas!.single['payload'] as String)
          as Map<String, dynamic>;
      expect(payload['telefono'], '58191577',
          reason: 'el payload guarda los 8 dígitos limpios, '
              'sin el 53 ni espacios');
      // Que el aviso y el push encolado se resuelvan antes
      // del desmontaje (mismo vaciado intercalado que en
      // medidas: tiempo real para BD/red, falso para los
      // timeouts del motor).
      for (var i = 0; i < 20; i++) {
        await tester.runAsync(() async {
          await Future<void>.delayed(
              const Duration(milliseconds: 250));
        });
        await tester.pump(const Duration(seconds: 1));
        await tester.pump();
      }
    });
  });
}

