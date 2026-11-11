/// Y-CAMPO 1.31.1 · Guión 1 — Cobro a cliente sin teléfono y
/// avisos de cumpleaños: la cola de WhatsApp no debe tener
/// destinatarios imposibles.
///
/// Pasos del guión (sobre las costuras reales, sin UI):
/// 1. Se cobra a un cliente SIN teléfono (la op pago_mensual
///    queda en la cola y el espejo pintado, como lo deja el
///    flujo de cobro) y el cliente además cumple años hoy.
/// 2. La bandeja del día (avisosWhatsappHoy) se arma: su
///    cumpleaños y su recibo aparecen, clasificados
///    «sin teléfono» (estadoAvisoLote / resumenLoteAvisos,
///    las funciones puras de bandeja_whatsapp.dart): NO se
///    puede construir un wa.me para él.
/// 3. Cliente migrado con el número SOLO en `movil` y el
///    carnet en `telefono` (el escenario FB-01 de la 1.29):
///    la bandeja lo alcanza por la regla única (H-CAMPO-1,
///    corregido en el Escalón 2 de la 1.32; la versión
///    original de este guión fijaba el defecto: la bandeja
///    copiaba el carnet crudo y lo dejaba «sin teléfono»).
/// 4. Se agrega el teléfono al primero por la costura exacta
///    de dialogo_telefono.dart (sanitizar → validar →
///    updateMirrorTelefono → queueOp editar_cliente): la
///    bandeja lo reclasifica a «pendiente» y el wa.me sale
///    con el 53.
/// 5. Un teléfono inválido no se guarda (la validación del
///    diálogo lo rechaza antes de tocar la BD).
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/negocio.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:ironbody_gym/ui/bandeja_whatsapp.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Future<void> _abrirDbVacia() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  SharedPreferences.setMockInitialValues({});
  final dir = await getDatabasesPath();
  final dbPath = p.join(dir, 'ironbody.db');
  try {
    await File(dbPath).delete();
  } catch (_) {}
  await LocalDb.resetParaTest();
  await LocalDb.instance.db;
}

String _iso(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(url: 'http://127.0.0.1:9', anonKey: 'dummy');
  });

  test('G1: sin teléfono → «sin teléfono»; con teléfono '
      'agregado → enviable; el migrado solo-movil entra '
      'por su `movil`', () async {
    await _abrirDbVacia();
    final hoy = hoyHabanaIso();
    final hoyDt = DateTime.parse(hoy);
    final carnetCumpleHoy = '90'
        '${hoyDt.month.toString().padLeft(2, '0')}'
        '${hoyDt.day.toString().padLeft(2, '0')}';
    final hastaPrevio = _iso(hoyDt.subtract(const Duration(days: 2)));
    final hastaNuevo = _iso(hoyDt.add(const Duration(days: 28)));

    // --- Paso 0: el padrón del guión ---
    // 701: sin teléfono, cumple hoy, se le cobra hoy.
    await LocalDb.instance.upsertMirror('clientes', 701, {
      'id': 701,
      'nombre': 'Sin Telefono',
      'estado': 'activo',
      'pagado_hasta': hastaPrevio,
      'carnet': carnetCumpleHoy,
    }, 1);
    // 702: control con teléfono, vence hoy.
    await LocalDb.instance.upsertMirror('clientes', 702, {
      'id': 702,
      'nombre': 'Con Telefono',
      'telefono': '58191577',
      'estado': 'activo',
      'pagado_hasta': hoy,
    }, 2);
    // 703: migrado — el celular vive en `movil`; `telefono`
    // trae el carnet (escenario FB-01 de la 1.29). Vence hoy.
    await LocalDb.instance.upsertMirror('clientes', 703, {
      'id': 703,
      'nombre': 'Migrado Movil',
      'telefono': '20510010345',
      'movil': '58191579',
      'estado': 'activo',
      'pagado_hasta': hoy,
    }, 3);

    // --- Paso 1: el cobro offline a 701, como lo deja el
    // flujo de cobro (op en cola + espejo + procedencia) ---
    await LocalDb.instance.queueOp(
      opUuid: 'op-g1-cobro',
      tipo: 'pago_mensual',
      payload: {
        'cliente_id': 701,
        'monto': 2000,
        'metodo': 'efectivo',
        'fecha': hoy,
        'pagado_hasta': hastaNuevo,
        'pagado_hasta_anterior': hastaPrevio,
      },
    );
    await LocalDb.instance.updateMirrorPagadoHasta(701, hastaNuevo);
    await LocalDb.instance.registrarProcedenciaPago(701, 'op-g1-cobro');

    // --- Paso 2: la bandeja del día ---
    final avisos = await avisosWhatsappHoy();
    Map<String, dynamic> avisoDe(String tipo, int cid) =>
        avisos.firstWhere(
            (a) => a['tipo'] == tipo && a['cliente_id'] == cid,
            orElse: () => throw StateError('sin aviso $tipo/$cid'));
    final cumple701 = avisoDe('cumple', 701);
    final recibo701 = avisoDe('recibo', 701);
    final vence702 = avisoDe('vence_hoy', 702);
    final vence703 = avisoDe('vence_hoy', 703);

    // El operador SÍ ve al cliente en la bandeja (cumpleaños
    // y recibo del cobro de hoy), pero clasificado imposible.
    expect(cumple701['telefono'], '');
    expect(recibo701['telefono'], '');
    expect(estadoAvisoLote(cumple701, {}), EstadoAvisoLote.sinTelefono);
    expect(estadoAvisoLote(recibo701, {}), EstadoAvisoLote.sinTelefono);
    final grupos = resumenLoteAvisos(avisos, {});
    expect(
        grupos[EstadoAvisoLote.sinTelefono]!
            .where((a) => a['cliente_id'] == 701)
            .length,
        2,
        reason: 'cumpleaños + recibo del sin-teléfono van a '
            'la sección «Sin teléfono», no a la de envío');
    // El control con teléfono sí es enviable.
    expect(estadoAvisoLote(vence702, {}), EstadoAvisoLote.pendiente);
    expect(normalizarTelefonoWaMe('${vence702['telefono']}'),
        '5358191577');

    // --- Paso 3: el migrado solo-movil. Hallazgo H-CAMPO-1
    // en la ejecución original: la bandeja leía `telefono`
    // (el carnet) y lo clasificaba sin teléfono aunque su
    // ficha SÍ muestra número válido vía la regla única.
    // Corregido en el Escalón 2 de la 1.32: la bandeja pasa
    // por telefonoEfectivoWa y el migrado es alcanzable. ---
    final fila703 = (await LocalDb.instance
            .mirrorPorIds('clientes', [703]))
        .single;
    expect(telefonoEfectivoWa(fila703), '5358191579',
        reason: 'la regla única de la casa encuentra el '
            'número del migrado en `movil`');
    expect(vence703['telefono'], '5358191579',
        reason: 'la bandeja trae el teléfono efectivo (el de '
            '`movil`), no el campo telefono crudo (el carnet)');
    expect(estadoAvisoLote(vence703, {}), EstadoAvisoLote.pendiente,
        reason: 'el migrado ya es alcanzable desde la '
            'bandeja: pendiente de envío, no «sin teléfono»');

    // --- Paso 4: agregar el teléfono a 701 por la costura
    // exacta de dialogo_telefono.dart ---
    final telSucio = '+53 5819 1501';
    final tel = sanitizarTelefono(telSucio);
    expect(tel, '58191501');
    expect(validarTelefono(tel!), isTrue);
    await LocalDb.instance.updateMirrorTelefono(701, tel);
    await LocalDb.instance.queueOp(
      opUuid: 'op-g1-tel',
      tipo: 'editar_cliente',
      payload: {'cliente_id': 701, 'telefono': tel},
    );
    final espejo701 = (await LocalDb.instance
            .mirrorPorIds('clientes', [701]))
        .single;
    expect(espejo701['telefono'], '58191501',
        reason: 'en el espejo viven los 8 dígitos limpios');
    final opTel = await LocalDb.instance.opEnCola('op-g1-tel');
    expect(opTel, isNotNull);
    expect(opTel!['tipo'], 'editar_cliente');

    // La bandeja reclasifica: ya es enviable y el wa.me
    // sale completo con el 53. (Desde la corrección de
    // H-CAMPO-1 la bandeja expone el teléfono EFECTIVO
    // completo —con 53—, no los 8 dígitos crudos del espejo.)
    final avisos2 = await avisosWhatsappHoy();
    final cumple701b = avisos2.firstWhere(
        (a) => a['tipo'] == 'cumple' && a['cliente_id'] == 701);
    expect(cumple701b['telefono'], '5358191501');
    expect(
        estadoAvisoLote(cumple701b, {}), EstadoAvisoLote.pendiente);
    expect(normalizarTelefonoWaMe('${cumple701b['telefono']}'),
        '5358191501');

    // --- Paso 5: un teléfono inválido no pasa la validación
    // del diálogo (no se escribe nada) ---
    expect(sanitizarTelefono('123'), isNull);
    expect(sanitizarTelefono('48191501'), isNull,
        reason: 'debe empezar con 5 o 6');
    expect(validarTelefono(''), isFalse);
    await LocalDb.resetParaTest();
  });
}
