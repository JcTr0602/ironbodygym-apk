// JORNADA 1.35 — las novedades de la versión ejecutadas paso a
// paso sobre pantallas reales, con el arnés de la Jornada
// (jornada_ayudas.dart): sesiones falsas de dueño/entrenador,
// viewport de teléfono real 420×800, Roboto real, contador de
// toques de la casa.
//
// Lo que este archivo añade a la Jornada 1 (jornada1_*):
//  (a) CONVERTIR UN INVITADO SIN CONEXIÓN, camino entero de
//      pantalla: detalle en caché de solo lectura → diálogo
//      «Convertir sin conexión» → InscribirScreen en modo
//      conversión → la op nace con la marca nacidaOffline y
//      el registro local la conserva (el BLOQUEANTE C10-01
//      del Yunque de Cambios, aquí por la vía de la UI).
//  (b) PUERTA ÚNICA DE ACTIVIDAD (CAMPO-16 + DESB-1): en la
//      cáscara real, con el turno abierto y la tarjeta
//      «Mi Turno Hoy» pintada, NO existe ningún enlace
//      «Ver actividad reciente»; la única puerta es el botón
//      de la cabecera junto a la lupa, y abre la
//      ActividadScreen de siempre.
//  (c) EL CENTRO DE SYNC DICE LA VERDAD (SYNC-12/S-01): con
//      la bajada fallida PERSISTIDA (semáforo wm_err_), el
//      Centro nombra el fallo y JAMÁS pinta «Todo al día».
//  (d) CLIENTE PROTEGIDO (C-1/C-4 del Yunque Exhaustivo, en
//      la costura del Directorio): el entrenador NO lo
//      encuentra ni por su teléfono ni por su carnet; por
//      nombre aparece solo con foto y nombre (el teléfono
//      no se pinta en ninguna parte); el dueño sí lo
//      encuentra por teléfono.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/invitados.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/sync.dart';
import 'package:ironbody_gym/ui/actividad.dart';
import 'package:ironbody_gym/ui/buscar.dart';
import 'package:ironbody_gym/ui/centro_sync.dart';
import 'package:ironbody_gym/ui/componentes.dart';
import 'package:ironbody_gym/ui/inscribir.dart';
import 'package:ironbody_gym/ui/invitados.dart' as ui_inv;

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

void main() {
  setUpAll(() async {
    await jornadaSetUpAll();
    await jornadaCargarRoboto();
  });

  tearDown(() {
    ui_inv.servicioInvitadosParaTest = null;
  });

  // ──────────────────────────────────────────────────────────
  // (a) Convertir un invitado SIN conexión, por la pantalla.
  // ──────────────────────────────────────────────────────────
  testWidgets(
      'J135 · convertir invitado sin conexión: detalle en '
      'caché → diálogo → inscripción → op con nacidaOffline',
      (tester) async {
    final toques = ContadorToques();
    await jornadaPreparar(tester);
    await jornadaSesionDueno(tester);
    // Sin red de verdad: TODA RPC del servicio de invitados
    // falla, como en el gym cuando se cae la conexión.
    ui_inv.servicioInvitadosParaTest = InvitadosService(
        rpc: (nombre, params) async =>
            throw const InvitadoError('RED', 'sin conexión'));
    // El detalle cacheado (lo que un teléfono real tendría
    // por haberlo abierto antes con red).
    await LocalDb.instance.guardarDetalleCacheInvitado(
        'inv-j135',
        jsonEncode({
          'invitado': {
            'id': 'inv-j135',
            'nombre': 'Invitado Jornada',
            'telefono': '51234567',
            'fecha_nac': '1990-05-20',
            'carnet': '90052012345',
            'estado': 'activo',
            'caducado': false,
          },
          'mediciones': [],
          'mediciones_sincronizadas': 0,
        }));
    jornadaViewport(tester);
    await tester.pumpWidget(_host(
        const ui_inv.InvitadoDetalleScreen(invitadoId: 'inv-j135'),
        'abrir'));
    await toques.tap(tester, find.text('abrir'));
    await jornadaDrenar(tester);
    // El detalle pinta desde la caché, marcado sin conexión.
    await jornadaEsperar(tester, find.text('Invitado Jornada'));
    expect(find.textContaining('Sin conexión'), findsWidgets,
        reason: 'el detalle nace de la caché y lo declara');
    // HALLAZGO Jornada 1.35 (corregido en este carril): la
    // banda del detalle decía «solo lectura (sin acciones)»
    // — falso desde el campo nº 14: ESTA pantalla convierte
    // sin conexión, como este mismo test demuestra abajo.
    // La banda debe nombrar la excepción, no negarla.
    expect(find.textContaining('conversión disponible'),
        findsWidgets,
        reason: 'la banda offline nombra la única acción '
            'que sí vive sin conexión: convertir');
    expect(find.textContaining('sin acciones'), findsNothing,
        reason: 'ningún «sin acciones» sobre una pantalla '
            'que convierte');
    // Convertir: el botón de la tarjeta de conversión.
    // Jornada 1.35 (adjudicación del rojo): el detalle se
    // reconstruye mientras sus secciones cargan (visitas,
    // verificación en fondo) y la tarjeta baja en el
    // desplazamiento; el toque lanzado sobre el árbol aún
    // en movimiento caía fuera de la pantalla (aviso de
    // hit-test: centro en y=977 con viewport de 800). Se
    // deja asentar la pantalla y se asegura la visibilidad
    // antes de tocar — como el dedo, que toca lo que ve
    // quieto (sonda zz_sonda_conv, corrida 2026-11-17: con
    // el asentado, el diálogo abre por el camino real).
    final botonConvertir = find.descendant(
        of: find.byType(ui_inv.InvitadoDetalleScreen),
        matching: find.widgetWithText(BotonPrimario, 'Convertir en cliente'));
    await toques.scrollHasta(tester, botonConvertir);
    await tester.pumpAndSettle();
    await tester.ensureVisible(botonConvertir);
    await tester.pumpAndSettle();
    await toques.tap(tester, botonConvertir);
    // El diálogo nombra la situación real: sin conexión.
    await jornadaEsperar(tester, find.text('Convertir sin conexión'));
    await toques.tap(
        tester,
        find.descendant(
            of: find.byType(Dialog),
            matching: find.text('Convertir')));
    // La inscripción se abre pre-llenada, en modo conversión.
    await jornadaEsperar(tester, find.text('Convertir invitado en cliente'));
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
    // EL DATO CAYÓ: una sola op de inscripción, con la
    // conversión identificada y la marca de nacimiento
    // offline intacta (C10-01 por el camino de la UI).
    final ops = await jornadaOpsTodas('inscribir');
    expect(ops, hasLength(1),
        reason: 'una sola inscripción encolada (toques del '
            'flujo: ${toques.n})');
    final payload = jornadaPayloadDe(ops.single);
    expect(payload['invitado_id'], 'inv-j135');
    expect(payload['conversion_uuid'], isNotEmpty);
    expect(payload['conversion_nacida_offline'], isTrue,
        reason: 'la op declara su nacimiento sin conexión: '
            'al confirmar, la verificación preparará primero '
            'en el servidor y adoptará su uuid');
    // El registro local conserva la marca tras encolar.
    final registro =
        await ConversionInvitadoStore().leer('inv-j135');
    expect(registro, isNotNull);
    expect(registro!.nacidaOffline, isTrue,
        reason: 'la marca sobrevive al encolado también en '
            'el registro (la batería de campo 14 sembraba el '
            'registro a mano y no veía esta pérdida)');
    expect(registro.estado, EstadoConversion.opEncolada);
    // El cliente NO nace en el espejo local: lo crea el
    // servidor al aplicarse la op y baja con la confirmación
    // (es el diseño de la conversión — el propio diálogo lo
    // dice: «el acceso a su app se crea cuando haya
    // conexión»; un cliente fantasma local duplicaría al
    // confirmar). Lo que este teléfono guarda es la op y el
    // registro, ya afirmados arriba.
    final clientes = await LocalDb.instance.allMirror('clientes');
    expect(
        clientes.where((c) => c['nombre'] == 'Invitado Jornada'),
        isEmpty,
        reason: 'sin cliente fantasma en el espejo: nace en '
            'el servidor al confirmarse la conversión');
    await jornadaCerrarCascara(tester);
  });

  // ──────────────────────────────────────────────────────────
  // (a2) La banda offline de la LISTA de invitados: la misma
  // verdad que la del detalle (hallazgo del banner).
  // ──────────────────────────────────────────────────────────
  testWidgets(
      'J135 · lista de invitados sin conexión: la banda '
      'también nombra la conversión disponible',
      (tester) async {
    await jornadaPreparar(tester);
    await jornadaSesionDueno(tester);
    ui_inv.servicioInvitadosParaTest = InvitadosService(
        rpc: (nombre, params) async =>
            throw const InvitadoError('RED', 'sin conexión'));
    // La lista cacheada que un teléfono real tendría por
    // haber abierto la bandeja antes con red.
    await InvitadosService().guardarCacheInvitados(
      resumen: null,
      listaTodos: const [
        InvitadoResumen(
          id: 'inv-j135',
          nombre: 'Invitado Jornada',
          telefono: '51234567',
          estado: 'activo',
          diasRestantes: 20,
          tieneSolicitudPendiente: false,
          plusActivo: false,
          telefonoYaCliente: false,
        ),
      ],
    );
    jornadaViewport(tester);
    await tester.pumpWidget(_host(
        const ui_inv.InvitadosScreen(), 'abrir'));
    await tester.tap(find.text('abrir'));
    await jornadaDrenar(tester);
    await jornadaEsperar(tester, find.text('Invitado Jornada'));
    expect(find.textContaining('conversión disponible'),
        findsWidgets,
        reason: 'la banda offline de la lista nombra la '
            'conversión, que desde la lista también se puede '
            'sin conexión (chip de candidato o su detalle)');
    expect(find.textContaining('sin acciones'), findsNothing);
    await jornadaCerrarCascara(tester);
  });

  // ──────────────────────────────────────────────────────────
  // (b) Puerta única de Actividad en la cáscara real.
  // ──────────────────────────────────────────────────────────
  testWidgets(
      'J135 · puerta única de Actividad: sin enlaces en las '
      'tarjetas y el botón de cabecera abre la Actividad',
      (tester) async {
    final toques = ContadorToques();
    await jornadaPreparar(tester);
    await jornadaSesionEntrenador(tester);
    await jornadaMontarHome(tester);
    // Con el turno abierto, la tarjeta «Mi Turno Hoy» del
    // entrenador está pintada (era una de las dos tarjetas
    // que llevaban el enlace retirado por DESB-1).
    if (find.text('Abrir turno').evaluate().isNotEmpty) {
      await toques.tap(tester, find.text('Abrir turno'));
      await jornadaDrenar(tester, vueltas: 8);
    }
    expect(find.textContaining('Mi Turno'), findsWidgets,
        reason: 'la tarjeta del turno está en pantalla: el '
            'negativo de abajo se afirma sobre la superficie '
            'que llevaba el enlace');
    expect(find.textContaining('Ver actividad reciente'),
        findsNothing,
        reason: 'DESB-1 (decisión de Jc): los enlaces de '
            'las tarjetas se retiraron; la puerta es única');
    // La única puerta: el botón de la cabecera, junto a la
    // lupa, y abre la ActividadScreen de siempre.
    final puerta =
        find.byKey(const ValueKey('marco-actividad'));
    expect(puerta, findsOneWidget);
    expect(find.byKey(const ValueKey('marco-lupa')),
        findsOneWidget,
        reason: 'la lupa sigue a su lado, intacta');
    await toques.tap(tester, puerta);
    await jornadaDrenar(tester, vueltas: 6);
    expect(find.byType(ActividadScreen), findsOneWidget,
        reason: 'la puerta única abre la pantalla de '
            'actividad de siempre');
    await jornadaCerrarCascara(tester);
  });

  // ──────────────────────────────────────────────────────────
  // (c) El Centro de Sync con la bajada fallida persistida.
  // ──────────────────────────────────────────────────────────
  testWidgets(
      'J135 · Centro de Sync: con la bajada fallida '
      'persistida, nombra el fallo y nunca dice «Todo al día»',
      (tester) async {
    await jornadaPreparar(tester);
    await jornadaSesionDueno(tester);
    // El semáforo de bajada que una corrida mala dejó
    // persistido (sobrevive al reinicio de la app).
    await LocalDb.instance.setMeta('wm_err_clientes', 'timeout');
    // La foto única se refresca como la app la refresca
    // (SyncEngine.fotoEstado: la piden la píldora y el
    // motor; la tarjeta del Centro lee currentStatus y el
    // stream de esa misma foto). Sin este paso la pantalla
    // nace con la foto por defecto — «Sin verificar», que
    // tampoco miente, pero no es el estado que Jc ve al
    // abrir el Centro con la app viva. fotoEstado mira la
    // línea con DNS real: va en runAsync, y el veredicto
    // exigible se deriva de la foto obtenida (con línea,
    // manda el error persistido; sin línea, manda la falta
    // de conexión — ambos nombran el problema).
    final foto = (await tester
        .runAsync(() => SyncEngine.instance.fotoEstado()))!;
    expect(foto.avisoSyncCorto, isNotNull,
        reason: 'la foto única recoge el semáforo de '
            'bajada persistido (avisoSyncCorto)');
    jornadaViewport(tester);
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(fontFamily: 'Roboto'),
      home: const CentroSyncScreen(),
    ));
    if (foto.enLinea == false) {
      await jornadaEsperar(
          tester, find.textContaining('Sin conexión'),
          intentos: 90);
    } else {
      await jornadaEsperar(
          tester, find.textContaining('falló'), intentos: 90);
      expect(find.textContaining('falló'), findsWidgets,
          reason: 'el Centro nombra el fallo de la bajada '
              '(aviso persistido de la foto única)');
    }
    expect(find.text('Todo al día'), findsNothing,
        reason: 'SYNC-12/S-01: con la bajada fallida '
            'persistida, ningún «Todo al día» verde puede '
            'nacer sobre ella');
    await jornadaCerrarCascara(tester);
  });

  // ──────────────────────────────────────────────────────────
  // (d) Protegido en el Directorio: ni por teléfono.
  // ──────────────────────────────────────────────────────────
  group('J135 · cliente protegido en el Directorio', () {
    Future<void> sembrar() async {
      final db = LocalDb.instance;
      await db.upsertMirror('clientes', 1, {
        'id': 1,
        'nombre': 'Ana Protegida',
        'estado': 'activo',
        'carnet': '90010112345',
        'telefono': '55112233',
        'protegido': 1,
        'pagado_hasta': '2027-01-01',
      }, 101);
      await db.upsertMirror('clientes', 2, {
        'id': 2,
        'nombre': 'Luis Normal',
        'estado': 'activo',
        'carnet': '88020254321',
        'telefono': '55443322',
        'protegido': 0,
        'pagado_hasta': '2027-01-01',
      }, 102);
    }

    Future<void> buscar(WidgetTester tester, ContadorToques toques,
        String q) async {
      await toques.campo(tester, find.byType(TextField).first, q);
      await jornadaDrenar(tester, vueltas: 8);
      await tester.pumpAndSettle();
    }

    testWidgets(
        'el ENTRENADOR no lo encuentra ni por teléfono ni '
        'por carnet; por nombre sale sin enseñar el teléfono',
        (tester) async {
      final toques = ContadorToques();
      await jornadaPreparar(tester);
      await jornadaSesionEntrenador(tester);
      await sembrar();
      jornadaViewport(tester);
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(fontFamily: 'Roboto'),
        home: const BuscarScreen(),
      ));
      await jornadaEsperar(tester, find.text('Luis Normal'));
      // Por su teléfono exacto: no aparece (ni ella ni, por
      // ese número, nadie).
      await buscar(tester, toques, '55112233');
      expect(find.text('Ana Protegida'), findsNothing,
          reason: 'teclear el número de un protegido no '
              'puede confirmar a quién pertenece (C-1)');
      expect(find.text('Luis Normal'), findsNothing);
      // Control: el teléfono del cliente normal SÍ lo trae.
      await buscar(tester, toques, '55443322');
      expect(find.text('Luis Normal'), findsOneWidget);
      // Por su carnet completo: tampoco.
      await buscar(tester, toques, '90010112345');
      expect(find.text('Ana Protegida'), findsNothing,
          reason: 'el carnet es el otro identificador '
              'invisible: la vía exacta también filtra (C-4)');
      // Por nombre aparece (diseño del Directorio), pero su
      // teléfono no se pinta en ninguna parte.
      await buscar(tester, toques, 'Ana');
      expect(find.text('Ana Protegida'), findsOneWidget);
      expect(find.textContaining('55112233'), findsNothing,
          reason: 'la fila protegida enseña foto y nombre, '
              'nunca el teléfono');
      expect(find.textContaining('55 11 22 33'), findsNothing);
      await jornadaCerrarCascara(tester);
    });

    testWidgets('el DUEÑO sí lo encuentra por teléfono',
        (tester) async {
      final toques = ContadorToques();
      await jornadaPreparar(tester);
      await jornadaSesionDueno(tester);
      await sembrar();
      jornadaViewport(tester);
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(fontFamily: 'Roboto'),
        home: const BuscarScreen(),
      ));
      await jornadaEsperar(tester, find.text('Luis Normal'));
      await buscar(tester, toques, '55112233');
      expect(find.text('Ana Protegida'), findsOneWidget,
          reason: 'la protección es contra el no-dueño: '
              'Jc encuentra a todos como siempre');
      await jornadaCerrarCascara(tester);
    });
  });
}
