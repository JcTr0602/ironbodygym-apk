// JORNADA 2 · 1.35 — segunda pasada sobre lo corregido por
// la Jornada 1: la banda offline de Invitados (commit
// 11fe23a: «solo lectura (conversión disponible)» en el
// detalle Y en la lista). La Jornada 1 afirmó el TEXTO de
// ambas bandas y ejecutó la conversión desde el DETALLE;
// esta pasada exige la COHERENCIA completa de la promesa:
//
//  (1) LISTA sin conexión: el chip de candidato — la vía de
//      un toque que la banda de la lista nombra — debe
//      PINTARSE sin conexión (las visitas son dato local:
//      tabla visitas_invitados + umbral en meta) y convertir
//      de punta a punta con la marca nacidaOffline.
//  (2) LISTA sin conexión, rama honesta: candidato SIN
//      detalle guardado → el chip avisa «sin datos
//      guardados» y no nace ninguna op.
//  (3) DETALLE sin conexión: la banda promete solo lectura
//      + conversión: el botón Convertir está y las demás
//      acciones mutantes NO se ofrecen (Registrar visita
//      fuera con su tarjeta visible).
//  (4) CONVERTIR DESDE EL ALTA: InscribirScreen en modo
//      conversión abierta directamente (la pantalla que
//      comparten el detalle, la lista y el alta): título,
//      prellenado y op con la marca, por la vía de la UI.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/invitados.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:ironbody_gym/ui/componentes.dart';
import 'package:ironbody_gym/ui/inscribir.dart';
import 'package:ironbody_gym/ui/invitados.dart' as ui_inv;
import 'package:ironbody_gym/visitas_invitados.dart';

import 'jornada_ayudas.dart';

Widget _host(Widget pantalla, String rotulo) {
  return MaterialApp(
    theme: ThemeData(fontFamily: 'Roboto'),
    home: Scaffold(
      body: Builder(
        builder: (context) => Center(
          child: TextButton(
            onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => pantalla)),
            child: Text(rotulo),
          ),
        ),
      ),
    ),
  );
}

void _sinRed() {
  ui_inv.servicioInvitadosParaTest = InvitadosService(
      rpc: (nombre, params) async =>
          throw const InvitadoError('RED', 'sin conexión'));
}

Future<void> _cacheDetalle(String id, String nombre) {
  return LocalDb.instance.guardarDetalleCacheInvitado(
      id,
      jsonEncode({
        'invitado': {
          'id': id,
          'nombre': nombre,
          'telefono': '51234567',
          'fecha_nac': '1990-05-20',
          'carnet': '90052012345',
          'estado': 'activo',
          'caducado': false,
        },
        'mediciones': [],
        'mediciones_sincronizadas': 0,
      }));
}

Future<void> _cacheLista(String id, String nombre) {
  return InvitadosService().guardarCacheInvitados(
    resumen: null,
    listaTodos: [
      InvitadoResumen(
        id: id,
        nombre: nombre,
        telefono: '51234567',
        estado: 'activo',
        diasRestantes: 20,
        tieneSolicitudPendiente: false,
        plusActivo: false,
        telefonoYaCliente: false,
      ),
    ],
  );
}

/// Candidato de verdad: umbral bajado a 2 y dos visitas
/// locales vinculadas por ID (el conteo de la lista es por
/// invitado_id, dato 100 % local).
Future<void> _hacerCandidato(String id, String nombre) async {
  await fijarUmbralVisitasInvitado(2);
  final ahora = ahoraUtcReal().toIso8601String();
  for (var i = 0; i < 2; i++) {
    await LocalDb.instance.registrarVisitaInvitado(
      clave: 'tel:51234567',
      invitadoId: id,
      nombre: nombre,
      tsIso: ahora,
    );
  }
}

/// El dedo espera a que el aviso flotante salga: el snack
/// de «sin conexión» de la lista queda SOBRE la barra
/// inferior de la inscripción y tapa el centro del botón
/// (sonda zz_sonda_j2_chip, corrida 2026-11-17: SnackBar
/// presente y su texto en la ruta de hit-test del botón).
/// Es el mismo fenómeno que la Jornada 1 adjudicó en S14
/// con el aviso «Cambios guardados»: arnés, no producto —
/// en el teléfono el aviso sale solo a los pocos segundos.
Future<void> _esperarSinSnack(WidgetTester tester) async {
  for (var i = 0; i < 40; i++) {
    if (find.byType(SnackBar).evaluate().isEmpty) return;
    await tester.pump(const Duration(milliseconds: 250));
  }
}

Future<void> _completarInscripcion(
    WidgetTester tester, ContadorToques toques) async {
  await _esperarSinSnack(tester);
  final guardar = find.descendant(
      of: find.byType(InscribirScreen),
      matching: find.widgetWithText(BotonPrimario, 'Convertir en cliente'));
  await toques.scrollHasta(tester, guardar);
  await tester.pumpAndSettle();
  await tester.ensureVisible(guardar);
  await tester.pumpAndSettle();
  await toques.tap(tester, guardar);
  await jornadaEsperar(tester, find.text('Confirmar'));
  await toques.tap(tester, find.text('Confirmar'));
  await jornadaDrenar(tester, vueltas: 10);
  await tester.pumpAndSettle();
  await tester.pump(const Duration(seconds: 31));
}

void main() {
  setUpAll(() async {
    await jornadaSetUpAll();
    await jornadaCargarRoboto();
  });

  tearDown(() {
    ui_inv.servicioInvitadosParaTest = null;
  });

  // ──────────────────────────────────────────────────────
  // (1) La lista sin conexión: el chip de candidato se
  // pinta (visitas locales) y convierte de punta a punta.
  // ──────────────────────────────────────────────────────
  testWidgets(
      'J2 · lista sin conexión: el chip de candidato '
      'convierte con la marca nacidaOffline',
      (tester) async {
    final toques = ContadorToques();
    await jornadaPreparar(tester);
    await jornadaSesionDueno(tester);
    _sinRed();
    await _cacheLista('inv-j2', 'Invitado Chip');
    await _cacheDetalle('inv-j2', 'Invitado Chip');
    await _hacerCandidato('inv-j2', 'Invitado Chip');
    jornadaViewport(tester);
    await tester
        .pumpWidget(_host(const ui_inv.InvitadosScreen(), 'abrir'));
    await tester.tap(find.text('abrir'));
    await jornadaDrenar(tester);
    await jornadaEsperar(tester, find.text('Invitado Chip'));
    // La banda de la lista, como la dejó la Jornada 1.
    expect(find.textContaining('conversión disponible'),
        findsWidgets,
        reason: 'la banda offline de la lista nombra la '
            'conversión disponible');
    expect(find.textContaining('sin acciones'), findsNothing);
    // EL CHIP: la vía que la banda promete desde ESTA
    // pantalla. Las visitas son locales: el chip no puede
    // depender de que la lista fresca haya cargado.
    final chip = find.text('⭐ Candidato a cliente · Convertir');
    await jornadaEsperar(tester, chip);
    expect(chip, findsOneWidget,
        reason: 'sin conexión, el candidato de la lista '
            'cacheada enseña su chip de conversión (las '
            'visitas viven en este teléfono)');
    await toques.tap(tester, chip);
    // El mismo flujo del detalle: diálogo offline →
    // inscripción en modo conversión → confirmar.
    await jornadaEsperar(tester, find.text('Convertir sin conexión'));
    await toques.tap(
        tester,
        find.descendant(
            of: find.byType(Dialog),
            matching: find.text('Convertir')));
    await jornadaEsperar(
        tester, find.text('Convertir invitado en cliente'));
    await _completarInscripcion(tester, toques);
    // EL DATO CAYÓ, con la marca de nacimiento offline.
    final ops = await jornadaOpsTodas('inscribir');
    expect(ops, hasLength(1),
        reason: 'una sola inscripción encolada desde el '
            'chip (toques del flujo: ${toques.n})');
    final payload = jornadaPayloadDe(ops.single);
    expect(payload['invitado_id'], 'inv-j2');
    expect(payload['conversion_uuid'], isNotEmpty);
    expect(payload['conversion_nacida_offline'], isTrue,
        reason: 'la conversión del chip también nace '
            'marcada: al confirmar, el servidor se prepara '
            'primero y se adopta su uuid');
    final registro =
        await ConversionInvitadoStore().leer('inv-j2');
    expect(registro, isNotNull);
    expect(registro!.nacidaOffline, isTrue);
    expect(registro.estado, EstadoConversion.opEncolada);
    await jornadaCerrarCascara(tester);
  });

  // ──────────────────────────────────────────────────────
  // (2) Rama honesta: candidato SIN detalle guardado.
  // ──────────────────────────────────────────────────────
  testWidgets(
      'J2 · lista sin conexión: candidato sin detalle '
      'guardado avisa y no encola nada', (tester) async {
    final toques = ContadorToques();
    await jornadaPreparar(tester);
    await jornadaSesionDueno(tester);
    _sinRed();
    await _cacheLista('inv-j2b', 'Invitado Sin Cache');
    await _hacerCandidato('inv-j2b', 'Invitado Sin Cache');
    // SIN _cacheDetalle: el teléfono nunca abrió su ficha
    // con red; no hay datos que convertir y no se inventan.
    jornadaViewport(tester);
    await tester
        .pumpWidget(_host(const ui_inv.InvitadosScreen(), 'abrir'));
    await tester.tap(find.text('abrir'));
    await jornadaDrenar(tester);
    await jornadaEsperar(tester, find.text('Invitado Sin Cache'));
    final chip = find.text('⭐ Candidato a cliente · Convertir');
    await jornadaEsperar(tester, chip);
    expect(chip, findsOneWidget);
    await toques.tap(tester, chip);
    await jornadaDrenar(tester, vueltas: 8);
    expect(find.textContaining('sin datos guardados'),
        findsWidgets,
        reason: 'sin detalle guardado, el chip lo dice en '
            'voz alta en vez de abrir una conversión vacía');
    expect(find.text('Convertir sin conexión'), findsNothing,
        reason: 'el diálogo de conversión no se abre sin '
            'datos del invitado');
    final ops = await jornadaOpsTodas('inscribir');
    expect(ops, isEmpty,
        reason: 'ninguna op nace de un invitado sin datos');
    final registro =
        await ConversionInvitadoStore().leer('inv-j2b');
    expect(registro, isNull,
        reason: 'ni registro de conversión queda');
    await jornadaCerrarCascara(tester);
  });

  // ──────────────────────────────────────────────────────
  // (3) Detalle sin conexión: solo lectura + conversión,
  // sin medias tintas.
  // ──────────────────────────────────────────────────────
  testWidgets(
      'J2 · detalle sin conexión: Convertir está y las '
      'demás acciones mutantes no se ofrecen',
      (tester) async {
    final toques = ContadorToques();
    await jornadaPreparar(tester);
    await jornadaSesionDueno(tester);
    _sinRed();
    await _cacheDetalle('inv-j2d', 'Invitado Detalle');
    jornadaViewport(tester);
    await tester.pumpWidget(_host(
        const ui_inv.InvitadoDetalleScreen(invitadoId: 'inv-j2d'),
        'abrir'));
    await toques.tap(tester, find.text('abrir'));
    await jornadaDrenar(tester);
    await jornadaEsperar(tester, find.text('Invitado Detalle'));
    expect(find.textContaining('conversión disponible'),
        findsWidgets,
        reason: 'la banda del detalle nombra la excepción');
    expect(find.textContaining('sin acciones'), findsNothing);
    // La tarjeta de visitas SÍ se lee (solo lectura de
    // verdad: el dato local se enseña)…
    await toques.scrollHasta(tester, find.text('Visitas'));
    expect(find.text('Visitas'), findsWidgets);
    // …pero su acción mutante no se ofrece sin conexión.
    expect(find.text('Registrar visita'), findsNothing,
        reason: 'en solo lectura no se registra visita: '
            'la banda no promete de menos, tampoco de más');
    // Y la acción prometida está, alcanzable como siempre.
    final botonConvertir = find.descendant(
        of: find.byType(ui_inv.InvitadoDetalleScreen),
        matching:
            find.widgetWithText(BotonPrimario, 'Convertir en cliente'));
    await toques.scrollHasta(tester, botonConvertir);
    expect(botonConvertir, findsOneWidget,
        reason: 'el botón de convertir vive en el detalle '
            'en caché: es la acción que la banda nombra');
    await jornadaCerrarCascara(tester);
  });

  // ──────────────────────────────────────────────────────
  // (4) Convertir desde el alta: la pantalla compartida.
  // ──────────────────────────────────────────────────────
  testWidgets(
      'J2 · InscribirScreen en modo conversión, abierta '
      'directo: prellenada y la op nace marcada',
      (tester) async {
    final toques = ContadorToques();
    await jornadaPreparar(tester);
    await jornadaSesionDueno(tester);
    // La preparación local real (la misma que hacen el
    // detalle y la lista sin conexión).
    final svc = InvitadosService(
        rpc: (nombre, params) async =>
            throw const InvitadoError('RED', 'sin conexión'));
    final datos = await svc.prepararConversionLocal(
        const InvitadoDetalle(
      id: 'inv-j2a',
      nombre: 'Invitado Alta',
      telefono: '51234567',
      estado: 'activo',
      fechaNac: '1990-05-20',
      carnet: '90052012345',
    ));
    expect(datos.nacidaOffline, isTrue);
    jornadaViewport(tester);
    await tester.pumpWidget(
        _host(InscribirScreen(conversion: datos), 'abrir'));
    await toques.tap(tester, find.text('abrir'));
    await jornadaDrenar(tester);
    await jornadaEsperar(
        tester, find.text('Convertir invitado en cliente'));
    expect(find.text('Invitado Alta'), findsWidgets,
        reason: 'el alta de conversión nace prellenada con '
            'los datos del invitado');
    await _completarInscripcion(tester, toques);
    final ops = await jornadaOpsTodas('inscribir');
    expect(ops, hasLength(1));
    final payload = jornadaPayloadDe(ops.single);
    expect(payload['invitado_id'], 'inv-j2a');
    expect(payload['conversion_uuid'], datos.conversionUuid,
        reason: 'la op lleva el uuid preparado en local');
    expect(payload['conversion_nacida_offline'], isTrue);
    final registro =
        await ConversionInvitadoStore().leer('inv-j2a');
    expect(registro, isNotNull);
    expect(registro!.nacidaOffline, isTrue);
    expect(registro.estado, EstadoConversion.opEncolada);
    await jornadaCerrarCascara(tester);
  });
}
