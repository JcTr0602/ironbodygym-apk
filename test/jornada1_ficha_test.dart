// JORNADA 1 · S14 — Buscar un cliente, abrir su ficha,
// cambiarle la foto y editar un dato.
//
// Padrón sembrado a escala (80 clientes). Buscar → ficha en
// 2 interacciones. Editar el teléfono EN SITIO (diálogo,
// no formulario completo): se teclea con prefijo 53 y la
// app lo guarda normalizado a 8 dígitos en el espejo y en
// la op. La foto: doble toque deliberado sobre «Cambiar
// foto» — la guarda G-1 de la 1.34 deja UN solo diálogo —
// y el cambio completo por galería simulada + editor real
// deja la foto en fotos_cola y puesta en la ficha.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:ironbody_gym/ui/buscar.dart';
import 'package:ironbody_gym/ui/ficha.dart';

import 'jornada_ayudas.dart';

/// Espera en TIEMPO REAL (pauta de la suite del editor): el
/// editor prepara la foto en un isolate y eso no avanza con
/// los frames falsos de pump.
Future<void> _esperaReal(
    WidgetTester tester, bool Function() cond) async {
  for (var i = 0; i < 240; i++) {
    if (cond()) return;
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(cond(), isTrue,
      reason: 'la condición no se cumplió en tiempo real');
}

late Directory _docs;
late File _fotoVieja;
late File _fotoGaleria;

Future<void> _sembrarPadron() async {
  final hasta = isoHabana(ahoraHabana().add(const Duration(days: 30)))
      .substring(0, 10);
  for (var i = 0; i < 80; i++) {
    await LocalDb.instance.upsertMirror('clientes', 1000 + i, {
      'id': 1000 + i,
      'nombre': 'Cliente Relleno $i',
      'estado': 'activo',
      'pagado_hasta': hasta,
    }, 1);
  }
  await LocalDb.instance.upsertMirror('clientes', 20, {
    'id': 20,
    'nombre': 'Buscar Jornada Pérez',
    'estado': 'activo',
    'pagado_hasta': hasta,
    'telefono': '58112233',
    'carnet': '900115',
    'sexo': 'M',
    // Foto actual en local: la ficha la enseña sin sync.
    'foto_local': _fotoVieja.path,
  }, 1);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await jornadaSetUpAll();
    await jornadaCargarRoboto();
    _docs = await Directory(
            p.join(Directory.systemTemp.path, 'jornada1_s14_docs'))
        .create(recursive: true);
    _fotoVieja = File(p.join(_docs.path, 'foto_vieja.jpg'));
    await File('assets/logo.jpg').copy(_fotoVieja.path);
    _fotoGaleria = File(p.join(_docs.path, 'foto_galeria.jpg'));
    await File('assets/logo.jpg').copy(_fotoGaleria.path);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (call) async => _docs.path);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/image_picker'),
            (call) async {
      if (call.method == 'pickImage') return _fotoGaleria.path;
      return null;
    });
  });

  tearDownAll(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/image_picker'),
            null);
  });

  group('Jornada S14 · ficha del cliente', () {
    testWidgets(
        'buscar → ficha en 2 toques y editar el teléfono en '
        'sitio: queda normalizado a 8 dígitos', (tester) async {
      await jornadaPreparar(tester);
      await jornadaSesionDueno(tester);
      await _sembrarPadron();
      jornadaViewport(tester);
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(fontFamily: 'Roboto'),
        home: const BuscarScreen(),
      ));
      await tester.pumpAndSettle();
      final toques = ContadorToques();

      await toques.campo(
          tester, find.byType(TextField).first, 'Jornada Pérez');
      await tester.pumpAndSettle();
      await jornadaEsperar(tester, find.text('Buscar Jornada Pérez'));
      await toques.tap(tester, find.text('Buscar Jornada Pérez'));
      await tester.pumpAndSettle();
      await jornadaEsperar(tester, find.text('Editar'));
      expect(toques.n, 2,
          reason: 'buscador (campo) + fila = 2 interacciones '
              'hasta la ficha (objetivo del guión: ≤3)');

      // Editar en sitio: el botón Editar de la ficha abre un
      // DIÁLOGO con los datos, no un formulario completo.
      final toquesEdicion = ContadorToques();
      await toquesEdicion.scrollHasta(tester, find.text('Editar'));
      await toquesEdicion.tap(tester, find.text('Editar'));
      await tester.pumpAndSettle();
      await jornadaEsperar(
          tester, find.text('Teléfono (8 dígitos)'));
      final campoTel = find.ancestor(
          of: find.text('Teléfono (8 dígitos)'),
          matching: find.byType(TextField));
      await toquesEdicion.campo(tester, campoTel, '5358998877');
      await toquesEdicion.tap(tester, find.text('Guardar'));
      await jornadaDrenar(tester, vueltas: 8);

      final ops = await jornadaOpsTodas('editar_cliente');
      expect(ops, hasLength(1));
      final payload = jornadaPayloadDe(ops.single);
      expect(payload['telefono'], '58998877',
          reason: 'el prefijo 53 se cae: quedan los 8 '
              'dígitos limpios en la op');
      final espejo = (await LocalDb.instance.allMirror('clientes'))
          .firstWhere((c) => c['id'] == 20);
      expect(espejo['telefono'], '58998877',
          reason: 'y en el espejo local al momento');
      expect(espejo['nombre'], 'Buscar Jornada Pérez',
          reason: 'ningún otro campo cambió');
      expect(toquesEdicion.n, 4,
          reason: 'desplazar + Editar + campo + Guardar '
              '(el tecleo no cuenta)');
      // La ficha sigue abierta y muestra el dato nuevo en
      // «Información personal». 1.34 Campo 2 (B-1): esa
      // tarjeta bajó tras Membresía e Historial en la
      // jerarquía nueva — el dato está, un desplazamiento
      // más abajo (la comprobación de visibilidad se
      // desplaza hasta él en vez de exigirlo en el primer
      // pantallazo; el flujo de edición no cambia).
      await tester.scrollUntilVisible(
          find.textContaining('58998877'), 200,
          scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      expect(find.textContaining('58998877'), findsWidgets);
      await jornadaCerrarCascara(tester);
    });

    testWidgets(
        'G-1: doble toque en Cambiar foto abre UN diálogo; '
        'el cambio por galería deja la foto en cola y puesta',
        (tester) async {
      await jornadaPreparar(tester);
      await jornadaSesionDueno(tester);
      await _sembrarPadron();
      // Superficie de campo de la suite del editor (como en
      // S2): 1080×2340 @3 = 360×780 lógicos.
      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 3.0;
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(fontFamily: 'Roboto'),
        home: const FichaScreen(clienteId: 20),
      ));
      await tester.pumpAndSettle();
      // La foto local se verifica con E/S real (File.exists):
      // en la zona falsa del test hay que darle tiempo real
      // para que la cabecera la pinte (en el teléfono es al
      // momento).
      await _esperaReal(
          tester, () => find.text('Cambiar foto').evaluate().isNotEmpty);
      final toques = ContadorToques();

      // Doble toque deliberado, sin asentar entre toques:
      // el segundo cae sobre la guarda G-1.
      await toques.tap(tester, find.text('Cambiar foto'));
      await toques.tap(tester, find.text('Cambiar foto'));
      // Sin pumpAndSettle: el botón enseña el indicador de
      // apertura de G-1 (animación continua) mientras el
      // diálogo nace.
      await jornadaEsperar(tester, find.text('Foto del cliente'));
      expect(find.text('Foto del cliente'), findsOneWidget,
          reason: 'un solo diálogo de foto pese al doble '
              'toque (guarda G-1 de la 1.34)');
      expect(find.text('Elegir de la galería'), findsOneWidget);

      await toques.tap(tester, find.text('Elegir de la galería'));
      await _esperaReal(
          tester,
          () =>
              find.text('Ajusta la foto').evaluate().isNotEmpty &&
              tester
                      .widget<ElevatedButton>(
                          find.widgetWithText(ElevatedButton, 'Usar foto'))
                      .onPressed !=
                  null);
      await toques.tap(tester, find.text('Usar foto'));
      await jornadaDrenar(tester, vueltas: 10);

      // La señal de cierre del flujo es su aviso: se
      // espera en tiempo real (el encolado genera las
      // variantes con E/S e isolates reales; sondear la BD
      // mientras la transacción vive la contiende).
      await _esperaReal(
          tester,
          () => find
              .textContaining('Foto actualizada')
              .evaluate()
              .isNotEmpty);
      final db = await LocalDb.instance.db;
      final cola = await db.query('fotos_cola',
          where: 'cliente_id = ?', whereArgs: [20]);
      expect(cola, isNotEmpty,
          reason: 'la foto nueva entró en la cola de fotos');
      expect(cola.last['estado'], 'pendiente');
      final espejo = (await LocalDb.instance.allMirror('clientes'))
          .firstWhere((c) => c['id'] == 20);
      expect(espejo['foto_local'], isNot(equals(_fotoVieja.path)),
          reason: 'la ficha ya trabaja con la foto nueva '
              'desde local, sin esperar a la sync');
      expect(find.text('Cambiar foto'), findsOneWidget,
          reason: 'la cabecera sigue anclada en su sitio '
              'tras el flujo');
      expect(toques.n, 4,
          reason: 'Cambiar foto ×2 (el doble toque) + galería '
              '+ Usar foto = 4 toques');
      await jornadaCerrarCascara(tester);
    });
  });
}
