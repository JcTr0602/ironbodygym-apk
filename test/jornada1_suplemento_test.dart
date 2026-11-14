// Jornada 1 · Situación 10 — vender un suplemento con
// comprobante.
//
// La venta de suplemento NO tiene adjunto de foto en la app:
// su «comprobante» es el recibo en pantalla (vista previa
// ANTES de confirmar y recibo tras vender). La foto del
// comprobante de una transferencia vive en el flujo de COBRO
// (Paso 1 del diálogo de pago → cola `comprobantes_pago` vía
// preview_cobro): la segunda parte de esta batería la ejerce
// ahí, que es donde la app la ofrece, verificando que entra
// en su cola sin bloquear el cobro (red muerta del arnés).
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/negocio.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:ironbody_gym/ui/dialogo_pago.dart';
import 'package:ironbody_gym/ui/preview_cobro.dart';
import 'package:ironbody_gym/ui/suplementos.dart';
import 'package:path/path.dart' as p;

import 'jornada_ayudas.dart';

Widget _hostSuplementos() {
  return MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) => Center(
          child: TextButton(
            onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                    builder: (_) => const SuplementosScreen())),
            child: const Text('abrir'),
          ),
        ),
      ),
    ),
  );
}

/// Host del flujo de cobro completo (diálogo → preview →
/// recibo), patrón de la batería de cobros.
Widget _hostCobro(int id, String nombre) {
  return MaterialApp(
    home: Builder(
      builder: (ctx) => Scaffold(
        body: Center(
          child: ElevatedButton(
            onPressed: () async {
              final payload = await pagoDialogo(ctx, {
                'id': id,
                'nombre': nombre,
                'estado': 'activo',
                'pagado_hasta': null,
              });
              if (payload == null || !ctx.mounted) return;
              await cobrarConPreviewYRecibo(
                context: ctx,
                nombreCliente: nombre,
                payload: payload,
              );
            },
            child: const Text('cobrar'),
          ),
        ),
      ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await jornadaSetUpAll();
    await jornadaCargarRoboto();
    final docs = await Directory(
            p.join(Directory.systemTemp.path, 'jornada1_docs'))
        .create(recursive: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (call) async => docs.path);
    final fotoOrigen = File(p.join(docs.path, 'foto_galeria.jpg'));
    if (!fotoOrigen.existsSync()) {
      await File('assets/logo.jpg').copy(fotoOrigen.path);
    }
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/image_picker'),
            (call) async {
      if (call.method == 'pickImage') return fotoOrigen.path;
      return null;
    });
  });

  group('Jornada S10 · suplemento con comprobante', () {
    testWidgets(
        'venta completa en efectivo: stock −1, op venta_suplemento '
        'y recibo tras vender', (tester) async {
      await jornadaPreparar(tester);
      await jornadaSesionEntrenador(tester);
      await tester.runAsync(() async {
        final ahora = ahoraHabana();
        final db = await LocalDb.instance.db;
        await db.insert('turnos', {
          'turno_id': 'turno-jornada-s10',
          'fecha_turno': hoyHabanaIso(),
          'turno': ahora.hour >= 12 ? 'tarde' : 'mañana',
          'hora_apertura': isoHabana(ahora),
          'hora_cierre': null,
          'telegram_id': 1403501391,
          'estado': 'abierto_local',
          'cubre_a': null,
        });
        // Producto SIN foto real (imagen genérica) y stock 4.
        await LocalDb.instance.upsertMirror('suplementos', 5, {
          'id': 5,
          'nombre': 'Proteína Jornada',
          'precio': 2500,
          'precio_oficial': 2500,
          'stock': 4,
          'moneda': 'CUP',
          'activo': 1,
        }, 1);
        await LocalDb.instance.upsertMirror('clientes', 20, {
          'id': 20,
          'nombre': 'Cliente Normal',
          'estado': 'activo',
          // Con teléfono: el recibo tras vender ofrece su
          // salida por WhatsApp (sin teléfono no hay botón).
          'telefono': '58112233',
        }, 1);
        // La tasa de valoración que Jc mantiene en ajustes:
        // sin ella la venta pide la tasa antes de confirmar.
        await LocalDb.instance.setAjustes({'tasa_usd': 250});
      });
      jornadaViewport(tester);
      final toques = ContadorToques();

      await tester.pumpWidget(_hostSuplementos());
      await toques.tap(tester, find.text('abrir')); // entrada
      await jornadaDrenar(tester, vueltas: 6);
      await jornadaEsperar(tester, find.text('Proteína Jornada'));
      await toques.tap(tester, find.text('Proteína Jornada'));
      await jornadaDrenar(tester, vueltas: 6);
      // Detalle → venta completa (la rápida de 1 unidad es
      // otro camino; el guión pide la venta con su flujo).
      await jornadaEsperar(
          tester, find.text('Registrar venta completa'));
      await toques.tap(tester, find.text('Registrar venta completa'));
      await jornadaDrenar(tester, vueltas: 6);
      await jornadaEsperar(tester, find.text('Confirmar venta'));
      // Comprador: por defecto «Cliente del gym» y es
      // obligatorio elegirlo (la venta lo exige con aviso si
      // falta, no en silencio).
      await toques.tap(tester,
          find.text('Cliente del gym — toca para seleccionar'));
      await jornadaDrenar(tester, vueltas: 6);
      await jornadaEsperar(tester, find.text('Cliente Normal'));
      await toques.tap(tester, find.text('Cliente Normal'));
      await jornadaDrenar(tester, vueltas: 4);
      // Confirmar en el formulario → VISTA PREVIA del
      // comprobante (la venta aún no existe) → Confirmar.
      await toques.tap(tester, find.text('Confirmar venta').first);
      await jornadaDrenar(tester, vueltas: 6);
      await jornadaEsperar(tester,
          find.textContaining('Revisa el comprobante'));
      await toques.tap(tester, find.text('Confirmar venta').last);
      await jornadaDrenar(tester, vueltas: 8);

      final ops = await jornadaOpsTodas('venta_suplemento');
      expect(ops, hasLength(1));
      final payload = jornadaPayloadDe(ops.single);
      expect(payload['suplemento_id'], 5);
      expect(payload['cantidad'], 1);
      expect((payload['precio'] as num).toInt(), 2500);
      expect(payload['moneda'], 'CUP');
      // Stock local descontado al momento (escritura atómica
      // stock + op).
      final sup = (await LocalDb.instance.allMirror('suplementos'))
          .firstWhere((s) => s['id'] == 5);
      expect(sup['stock'], 3);
      // El ingreso en efectivo es dinero a entregar (2500).
      final precios = await preciosVigentes();
      expect(montoEfectivoOp(ops.single, precios), 2500);
      // Tras vender, el recibo se muestra (comprobante en
      // pantalla con su salida por WhatsApp).
      await tester.scrollUntilVisible(
          find.text('Enviar por WhatsApp'), 200,
          scrollable: find.byType(Scrollable).last);
      await tester.pumpAndSettle();
      expect(find.text('Enviar por WhatsApp'), findsOneWidget,
          reason: 'el recibo tras vender ofrece su salida por '
              'WhatsApp (bajo el pliegue de la página)');

      expect(toques.n, 7,
          reason: 'entrada + producto + venta completa + '
              'comprador (abrir + elegir) + Confirmar '
              '(formulario) + Confirmar (vista previa del '
              'comprobante) = 7 toques');
      // Salida como usuario: atrás hasta el anfitrión.
      Navigator.of(tester.element(find.text('¡Venta registrada!')))
          .pop();
      await jornadaDrenar(tester, vueltas: 4);
      await jornadaCerrarCascara(tester);
    });

    testWidgets(
        'comprobante FOTO de una transferencia: se adjunta en '
        'el cobro y entra en su cola sin bloquear la venta',
        (tester) async {
      await jornadaPreparar(tester);
      await jornadaSesionEntrenador(tester);
      await tester.runAsync(() async {
        await LocalDb.instance.upsertMirror('clientes', 30, {
          'id': 30,
          'nombre': 'Cliente Comprobante',
          'estado': 'activo',
          'pagado_hasta': null,
        }, 1);
      });
      jornadaViewport(tester);
      final toques = ContadorToques();

      await tester.pumpWidget(_hostCobro(30, 'Cliente Comprobante'));
      await toques.tap(tester, find.text('cobrar'));
      await tester.pumpAndSettle();
      // La opción de adjunto solo existe en transferencia.
      await jornadaEsperar(tester, find.text('Transferencia'));
      await toques.tap(tester, find.text('Transferencia'));
      await tester.pumpAndSettle();
      await jornadaEsperar(
          tester, find.text('Adjuntar foto del comprobante'));
      await toques.tap(
          tester, find.text('Adjuntar foto del comprobante'));
      await jornadaEsperar(
          tester, find.text('Elegir de la galería'));
      await toques.tap(tester, find.text('Elegir de la galería'));
      await jornadaDrenar(tester, vueltas: 6);
      await jornadaEsperar(tester, find.text('Comprobante adjunto'));
      // Continuar → preview → Confirmar → recibo.
      await toques.tap(tester, find.text('Continuar'));
      await tester.pumpAndSettle();
      // «Revisar cobro» es el título de la vista previa.
      await jornadaEsperar(tester, find.text('Revisar cobro'));
      await jornadaEsperar(tester, find.text('Confirmar cobro'));
      await toques.tap(tester, find.text('Confirmar cobro'));
      await jornadaDrenar(tester, vueltas: 8);
      // El flujo vuelve al anfitrión: cobro completado.
      await jornadaEsperar(tester, find.text('cobrar'));

      // La venta se registró (op de pago) pese a la red muerta…
      final ops = await jornadaOpsTodas('pago_mensual');
      expect(ops, hasLength(1));
      expect(jornadaPayloadDe(ops.single)['metodo'],
          'transferencia');
      // …y el comprobante quedó en SU cola, pendiente de
      // subida, con su archivo guardado.
      final db = await LocalDb.instance.db;
      final cola = await db.query('comprobantes_pago');
      expect(cola, hasLength(1),
          reason: 'el comprobante entró en la cola de '
              'comprobantes');
      expect(cola.single['estado'], 'pendiente');
      final ruta = '${cola.single['ruta_local']}';
      expect(File(ruta).existsSync(), isTrue,
          reason: 'el archivo del comprobante quedó guardado '
              'en documentos ($ruta)');

      expect(toques.n, 6,
          reason: 'abrir + Transferencia + Adjuntar + galería '
              '+ Continuar + Confirmar cobro = 6 toques (el '
              'adjunto añade 2 al cobro por transferencia '
              'simple de S5, que eran 5 con su Entendido)');
      await jornadaCerrarCascara(tester);
    });
  });
}
