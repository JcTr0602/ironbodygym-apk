// JORNADA 1 · S15 — Bandeja de WhatsApp de Hoy.
//
// Superficie TEST (el salto real a WhatsApp es del banco):
// el canal de url_launcher se simula para capturar el
// enlace wa.me y para forzar el fallo de apertura.
// - Vencido con teléfono: la tarjeta abre un editor con el
//   mensaje ya compuesto (cierre automático de la casa);
//   al confirmar, el enlace sale a wa.me/53… y NADA se
//   marca hasta que, al volver, el dueño confirma con
//   «Sí, enviado» — la marca cae en SQLite.
// - Si WhatsApp no se puede abrir: aviso en claro y el
//   aviso NO se marca.
// - Cliente sin teléfono: no contactable (no hay botón de
//   envío para él), no un fallo.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:ironbody_gym/ui/bandeja_whatsapp.dart';

import 'jornada_ayudas.dart';

bool _lanzarOk = true;
final _urlsLanzadas = <String>[];

Future<void> _sembrarAvisos() async {
  final hoy = ahoraHabana();
  final ayer =
      isoHabana(hoy.subtract(const Duration(days: 1))).substring(0, 10);
  final futuro =
      isoHabana(hoy.add(const Duration(days: 30))).substring(0, 10);
  await LocalDb.instance.upsertMirror('clientes', 31, {
    'id': 31,
    'nombre': 'Vencido Jornada',
    'estado': 'activo',
    'pagado_hasta': ayer,
    'telefono': '58112233',
    'carnet': '900520',
    'sexo': 'M',
  }, 1);
  await LocalDb.instance.upsertMirror('clientes', 32, {
    'id': 32,
    'nombre': 'Cumple Jornada',
    'estado': 'activo',
    'pagado_hasta': futuro,
    'telefono': '58334455',
    // Cumple HOY: el carnet AAMMDD termina en el mes/día
    // de hoy, sea cual sea la fecha de la corrida.
    'carnet': '85'
        '${hoy.month.toString().padLeft(2, '0')}'
        '${hoy.day.toString().padLeft(2, '0')}',
    'sexo': 'F',
  }, 1);
  await LocalDb.instance.upsertMirror('clientes', 33, {
    'id': 33,
    'nombre': 'Sin Telefono Jornada',
    'estado': 'activo',
    'pagado_hasta': ayer,
    'carnet': '880310',
    'sexo': 'M',
  }, 1);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await jornadaSetUpAll();
    await jornadaCargarRoboto();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/url_launcher'),
            (call) async {
      if (call.method == 'launch') {
        if (!_lanzarOk) {
          throw PlatformException(
              code: 'unavailable', message: 'sin app');
        }
        _urlsLanzadas.add('${call.arguments['url']}');
        return true;
      }
      if (call.method == 'canLaunch') return _lanzarOk;
      return null;
    });
  });

  tearDownAll(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/url_launcher'),
            null);
  });

  group('Jornada S15 · bandeja WhatsApp', () {
    testWidgets(
        'vencido: editor con el mensaje compuesto, enlace '
        'wa.me/53… y marca SOLO al confirmar al volver',
        (tester) async {
      _lanzarOk = true;
      _urlsLanzadas.clear();
      await jornadaPreparar(tester);
      await jornadaSesionDueno(tester);
      await _sembrarAvisos();
      jornadaViewport(tester);
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(fontFamily: 'Roboto'),
        home: const BandejaWhatsappScreen(),
      ));
      await tester.pumpAndSettle();
      await jornadaEsperar(tester, find.text('Vencido Jornada'));
      final toques = ContadorToques();
      await toques.tap(tester, find.byIcon(Icons.chat_rounded).first);
      await tester.pumpAndSettle();
      // El editor previo: el texto ya viene compuesto con
      // el cierre automático de la casa.
      await jornadaEsperar(
          tester, find.text('Mensaje para Vencido Jornada'));
      final campo = tester.widget<TextField>(find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(TextField)));
      expect(campo.controller!.text,
          contains('Mensaje automático de nuestro sistema de gestión'));
      expect(campo.controller!.text, contains('58191577'));
      await toques.tap(
          tester,
          find.descendant(
              of: find.byType(AlertDialog),
              matching: find.text('Abrir WhatsApp')));
      await jornadaDrenar(tester, vueltas: 6);

      expect(_urlsLanzadas, hasLength(1));
      final url = Uri.parse(_urlsLanzadas.single);
      expect(url.host, 'wa.me');
      expect(url.path, '/5358112233',
          reason: 'el prefijo 53 se arma SOLO en el enlace');
      expect(url.queryParameters['text'],
          contains('Tu mensualidad está vencida'));
      // Sin marcar todavía: abrir WhatsApp no es enviar.
      expect(await LocalDb.instance.avisosWaContactados(hoyHabanaIso()),
          isEmpty);

      // Volver a la app: pregunta, y con el «Sí, enviado»
      // la marca cae en SQLite.
      tester.binding
          .handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding
          .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      await jornadaEsperar(tester, find.text('Sí, enviado'));
      await toques.tap(tester, find.text('Sí, enviado'));
      await jornadaDrenar(tester, vueltas: 6);
      expect(await LocalDb.instance.avisosWaContactados(hoyHabanaIso()),
          contains('vencido_31'));
      // El teléfono guardado del cliente NO cambió: sigue
      // en 8 dígitos (el 53 vive solo en el enlace).
      final espejo = (await LocalDb.instance.allMirror('clientes'))
          .firstWhere((c) => c['id'] == 31);
      expect(espejo['telefono'], '58112233');
      expect(toques.n, 3,
          reason: 'botón verde de la tarjeta + Abrir '
              'WhatsApp (editor) + Sí, enviado al volver = 3; '
              'hasta WhatsApp con el texto listo son 2');
      // La simulación de «volver» encendió el auto-refresco
      // de sesión de Supabase (temporizador periódico): se
      // apaga volviendo a pausa, como hace el sistema.
      tester.binding
          .handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding
          .handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding
          .handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await jornadaCerrarCascara(tester);
    });

    testWidgets(
        'si WhatsApp no se puede abrir: aviso en claro y '
        'el aviso NO se marca', (tester) async {
      _lanzarOk = false;
      _urlsLanzadas.clear();
      await jornadaPreparar(tester);
      await jornadaSesionDueno(tester);
      await _sembrarAvisos();
      jornadaViewport(tester);
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(fontFamily: 'Roboto'),
        home: const BandejaWhatsappScreen(),
      ));
      await tester.pumpAndSettle();
      await jornadaEsperar(tester, find.text('Vencido Jornada'));
      final toques = ContadorToques();
      await toques.tap(tester, find.byIcon(Icons.chat_rounded).first);
      await tester.pumpAndSettle();
      await jornadaEsperar(
          tester, find.text('Mensaje para Vencido Jornada'));
      await toques.tap(
          tester,
          find.descendant(
              of: find.byType(AlertDialog),
              matching: find.text('Abrir WhatsApp')));
      await jornadaDrenar(tester, vueltas: 6);
      expect(find.textContaining('No se pudo abrir WhatsApp'),
          findsWidgets);
      expect(await LocalDb.instance.avisosWaContactados(hoyHabanaIso()),
          isEmpty,
          reason: 'sin apertura no hay marca: el aviso '
              'sigue pendiente, no se pierde');
      await jornadaCerrarCascara(tester);
    });

    testWidgets(
        'sin teléfono = no contactable (no un fallo) y el '
        'cumpleaños sale con su mensaje', (tester) async {
      _lanzarOk = true;
      _urlsLanzadas.clear();
      await jornadaPreparar(tester);
      await jornadaSesionDueno(tester);
      await _sembrarAvisos();
      jornadaViewport(tester);
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(fontFamily: 'Roboto'),
        home: const BandejaWhatsappScreen(),
      ));
      await tester.pumpAndSettle();
      await jornadaEsperar(tester, find.text('Sin Telefono Jornada'));
      // Su tarjeta existe y la bandeja lo trata como no
      // contactable: su botón verde está DESHABILITADO
      // («Sin teléfono registrado · toca para agregar»),
      // mientras los de Vencido y Cumple sí responden.
      expect(find.byIcon(Icons.chat_rounded), findsNWidgets(3));
      final botones = find
          .ancestor(
              of: find.byIcon(Icons.chat_rounded),
              matching: find.byType(InkWell))
          .evaluate()
          .map((e) => (e.widget as InkWell).onTap != null)
          .toList();
      expect(botones, [true, false, true],
          reason: 'orden de la bandeja: Vencido (sí), Sin '
              'Telefono (no), Cumple (sí)');
      expect(find.textContaining('Sin teléfono registrado'),
          findsOneWidget);
      expect(find.text('Cumple Jornada'), findsWidgets);
      await jornadaCerrarCascara(tester);
    });
  });
}
