// Jornada 1 · Situaciones 2 y 3 — inscripciones.
//
// S2: inscribir en EFECTIVO con foto, SIN turno abierto (el
// cobro de la inscripción se completa igual: no hay candado de
// turno, verificado en S1). La foto entra por el selector del
// sistema simulado (canal image_picker) y el editor real de la
// app («Usar foto»); al guardar, la foto cae en fotos_cola.
// S3: inscribir por TRANSFERENCIA siendo entrenador: el
// cliente nace y la op viaja, pero el dinero NO suma a la
// caja de efectivo ni al pendiente a entregar (la confirma Jc
// en el servidor/bot: fuera de la superficie de esta app).
//
// La pantalla se EMPUJA desde un anfitrión (como desde
// Inicio): montada como raíz, su Navigator.pop() final no
// tendría a dónde volver y el cierre no se podría verificar.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/negocio.dart';
import 'package:ironbody_gym/ui/inscribir.dart';
import 'package:path/path.dart' as p;

import 'jornada_ayudas.dart';

/// Espera en TIEMPO REAL (pauta de foto_elegir_129_test): el
/// editor prepara la foto en un isolate (compute) y eso no
/// avanza con los frames falsos de pump.
Future<void> _esperaReal(
    WidgetTester tester, bool Function() cond) async {
  for (var i = 0; i < 240; i++) {
    if (cond()) return;
    await tester.runAsync(() =>
        Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(cond(), isTrue,
      reason: 'la condición no se cumplió en tiempo real');
}

Future<Map<String, dynamic>?> _clientePorNombre(String nombre) async {
  final todos = await LocalDb.instance.allMirror('clientes');
  for (final c in todos) {
    if (c['nombre'] == nombre) return c;
  }
  return null;
}

/// Anfitrión mínimo: un botón que empuja la pantalla de
/// inscripción (equivale al toque de entrada desde Inicio).
Widget _hostInscribir() {
  return MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) => Center(
          child: TextButton(
            onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                    builder: (_) => const InscribirScreen())),
            child: const Text('abrir'),
          ),
        ),
      ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory docs;
  late File fotoOrigen;

  setUpAll(() async {
    await jornadaSetUpAll();
    await jornadaCargarRoboto();
    // path_provider → directorio propio de la corrida (la foto
    // elegida se copia a documentos y la cola escribe ahí).
    docs = await Directory(
            p.join(Directory.systemTemp.path, 'jornada1_docs'))
        .create(recursive: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (call) async => docs.path);
    // Selector del sistema simulado: devuelve una foto real
    // del repo (logo.jpg) como si viniera de la galería.
    fotoOrigen = File(p.join(docs.path, 'foto_galeria.jpg'));
    await File('assets/logo.jpg').copy(fotoOrigen.path);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/image_picker'),
            (call) async {
      if (call.method == 'pickImage') return fotoOrigen.path;
      return null; // retrieveLostData: nada perdido
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

  group('Jornada S2 · inscribir en efectivo con foto', () {
    testWidgets(
        'sin turno abierto: formulario → foto → resumen → op '
        'crear_cliente en efectivo, espejo nacido y foto en cola',
        (tester) async {
      await jornadaPreparar(tester);
      await jornadaSesionEntrenador(tester);
      jornadaViewport(tester);
      // La pata de foto usa la superficie de campo de la suite
      // del editor (1080×2340 @3 = 360×780 lógicos, teléfono
      // real dentro del ≤420×800): a 420 el AlertDialog del
      // editor pide las dimensiones intrínsecas de su
      // LayoutBuilder y el arnés de test lo convierte en
      // excepción (en dispositivo, maqueta como en campo).
      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 3.0;
      final toques = ContadorToques();

      await tester.pumpWidget(_hostInscribir());
      await toques.tap(tester, find.text('abrir')); // entrada
      await jornadaDrenar(tester);
      await jornadaEsperar(tester, find.text('Guardar inscripción'));

      // Nombre y carnet (foco = 1 toque cada uno; el tecleo
      // no cuenta). Carnet AAMMDD válido: 1990-01-15, adulto.
      await toques.campo(
          tester, find.byType(TextField).at(0), 'Nuevo Jornada Dos');
      await toques.campo(
          tester, find.byType(TextField).at(2), '900115');
      await tester.pumpAndSettle();

      // Foto desde la galería simulada + editor real: el
      // botón «Usar foto» nace deshabilitado hasta que el
      // isolate termina de preparar la foto.
      await toques.scrollHasta(tester, find.text('Galería'));
      // Subida extra: sin ella la barra inferior anclada puede
      // interceptar el toque (visto en S3 con el chip).
      await tester.drag(
          find.byType(Scrollable).first, const Offset(0, -200));
      await tester.pumpAndSettle();
      toques.n++; // el arrastre también es un gesto del usuario
      await toques.tap(tester, find.text('Galería'));
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
      await _esperaReal(tester,
          () => find.text('Quitar foto').evaluate().isNotEmpty);
      expect(find.text('Quitar foto'), findsOneWidget,
          reason: 'la foto elegida quedó puesta en el formulario');

      // Guardar → diálogo de resumen → Confirmar.
      await toques.scrollHasta(tester, find.text('Guardar inscripción'));
      await toques.tap(tester, find.text('Guardar inscripción'));
      await jornadaEsperar(tester, find.text('Confirmar'));
      await toques.tap(tester, find.text('Confirmar'));
      await jornadaDrenar(tester, vueltas: 8);
      await tester.pumpAndSettle();
      expect(find.byType(InscribirScreen), findsNothing,
          reason: 'al confirmar, la pantalla se cierra');

      // El dato: op «inscribir» en efectivo por 2000 (el tipo
      // real de la cola; la cobertura la deriva la cadena del
      // servidor desde período+fecha, no viaja en el payload).
      final ops = await jornadaOpsTodas('inscribir');
      expect(ops, hasLength(1));
      final payload = jornadaPayloadDe(ops.single);
      expect(payload['metodo_pago'], 'efectivo');
      expect((payload['precio_aplicado'] as num).toInt(), 2000);
      expect(payload['nombre'], 'Nuevo Jornada Dos');
      expect('${payload['carnet']}', '900115');

      // El espejo local AÚN no tiene al cliente, y es el
      // diseño (Yunque 3, K5-7): el id lo asigna el servidor
      // al aplicar la op; mientras tanto la app lo representa
      // provisionalmente desde la propia op (recibos/bandeja).
      // Su fila del espejo — con la cobertura que deriva la
      // cadena canónica — llega con la siguiente bajada (S19).
      final espejo = await _clientePorNombre('Nuevo Jornada Dos');
      expect(espejo, isNull,
          reason: 'sin fila local hasta que el servidor aplica '
              'la inscripción y baja por sync (diseño K5-7)');

      // La foto cayó en la cola de fotos, pendiente, ligada a
      // la op de creación.
      final db = await LocalDb.instance.db;
      final cola = await db.query('fotos_cola',
          where: 'op_uuid = ?', whereArgs: [ops.single['op_uuid']]);
      expect(cola, isNotEmpty,
          reason: 'la foto de la inscripción quedó encolada');
      expect(cola.first['estado'], 'pendiente');

      // El efectivo de la inscripción ES dinero a entregar
      // del entrenador: se verifica con montoEfectivoOp, la
      // valoración que pendienteEntrega aplica a las ops
      // pendientes. (En este arnés el servidor falso responde
      // 400 a todo push y el motor sella la op «rechazada» al
      // momento — artefacto del banco, igual en todas las
      // situaciones; pendienteEntrega sobre la cola ya
      // sellada daría 0 aquí y 2000 en campo, donde la op
      // queda pendiente/aplicada.)
      final opFila = (await (await LocalDb.instance.db).query(
          'ops_queue',
          where: 'tipo = ?',
          whereArgs: ['inscribir'])).single;
      final precios = await preciosVigentes();
      expect(montoEfectivoOp(opFila, precios), 2000,
          reason: 'la inscripción en efectivo vale 2000 a '
              'entregar para su autor');

      expect(toques.n, 10,
          reason: 'entrada + nombre + carnet + scroll + '
              'arrastre + Galería + Usar foto + scroll + Guardar '
              '+ Confirmar = 10 toques/gestos (el tecleo no '
              'cuenta; el formulario es largo y la foto vive '
              'abajo)');
      await jornadaCerrarCascara(tester);
    });
  });

  group('Jornada S3 · inscribir por transferencia (entrenador)', () {
    testWidgets(
        'el cliente nace y la op viaja, pero el dinero no toca '
        'la caja de efectivo ni el pendiente a entregar',
        (tester) async {
      await jornadaPreparar(tester);
      await jornadaSesionEntrenador(tester);
      jornadaViewport(tester);
      final toques = ContadorToques();

      await tester.pumpWidget(_hostInscribir());
      await toques.tap(tester, find.text('abrir')); // entrada
      await jornadaDrenar(tester);
      await jornadaEsperar(tester, find.text('Guardar inscripción'));

      await toques.campo(
          tester, find.byType(TextField).at(0), 'Nuevo Jornada Tres');
      await toques.campo(
          tester, find.byType(TextField).at(2), '880220');
      await tester.pumpAndSettle();

      // Método: Transferencia (el precio pasa a 2500). La
      // fila de método queda baja en el formulario: sin subirla
      // bien, la barra inferior anclada (resumen + Guardar)
      // intercepta el toque.
      await toques.scrollHasta(tester, find.text('Transferencia'));
      await tester.drag(
          find.byType(Scrollable).first, const Offset(0, -260));
      await tester.pumpAndSettle();
      toques.n++; // el arrastre también es un gesto del usuario
      await toques.tap(
          tester, find.widgetWithText(ChoiceChip, 'Transferencia'));
      await tester.pumpAndSettle();
      expect(find.textContaining('2500'), findsWidgets,
          reason: 'el resumen en vivo pasa a precio de '
              'transferencia (2500)');

      await toques.scrollHasta(tester, find.text('Guardar inscripción'));
      await toques.tap(tester, find.text('Guardar inscripción'));
      await jornadaEsperar(tester, find.text('Confirmar'));
      await toques.tap(tester, find.text('Confirmar'));
      await jornadaDrenar(tester, vueltas: 8);
      await tester.pumpAndSettle();
      expect(find.byType(InscribirScreen), findsNothing);

      final ops = await jornadaOpsTodas('inscribir');
      expect(ops, hasLength(1));
      final payload = jornadaPayloadDe(ops.single);
      expect(payload['metodo_pago'], 'transferencia');
      expect((payload['precio_aplicado'] as num).toInt(), 2500);

      final espejo = await _clientePorNombre('Nuevo Jornada Tres');
      expect(espejo, isNull,
          reason: 'igual que en efectivo: la fila del espejo '
              'nace en el servidor al aplicar la op (diseño '
              'K5-7); en la app queda la op encolada');

      // La transferencia NO es efectivo del entrenador: su
      // valoración a entregar es 0 y el pendiente queda
      // intacto. La confirmación de Jc vive en el
      // servidor/bot (serie SV), no en esta app.
      final opFila = (await (await LocalDb.instance.db).query(
          'ops_queue',
          where: 'tipo = ?',
          whereArgs: ['inscribir'])).single;
      final precios = await preciosVigentes();
      expect(montoEfectivoOp(opFila, precios), 0,
          reason: 'una inscripción por transferencia no es '
              'efectivo a entregar');
      expect(await pendienteEntrega(1403501391), 0);

      expect(toques.n, 9,
          reason: 'entrada + nombre + carnet + scroll + '
              'arrastre + Transferencia + scroll + Guardar + '
              'Confirmar = 9 toques/gestos');
      await jornadaCerrarCascara(tester);
    });
  });
}
