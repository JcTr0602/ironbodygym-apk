/// 1.20 (decisión de Jc, 2026-11-01): todo mensaje que la app
/// compone para WhatsApp cierra con la línea que aclara que lo
/// envía el sistema de gestión automático, no una persona.
///
/// Se verifica sobre la bandeja real (`avisosWhatsappHoy`): un
/// cliente por sección (vencido, vence hoy, por vencer, cumpleaños
/// y recibo de pago de hoy) y la constante compartida con el texto
/// exacto aprobado por Jc.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/negocio.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _cierre =
    '🤖 _Mensaje automático de nuestro sistema de gestión; '
    'no lo envía una persona. Si vas a responder, escríbenos '
    'al 58191577._';

Future<Database> _abrirDbVacia() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  SharedPreferences.setMockInitialValues({});
  final dir = await getDatabasesPath();
  final dbPath = p.join(dir, 'ironbody.db');
  try {
    await File(dbPath).delete();
  } catch (_) {}
  await LocalDb.resetParaTest();
  return await LocalDb.instance.db;
}

int _seq = 9200;

Future<void> _espejo(
    Database db, String tabla, int id, Map<String, dynamic> data,
    {Map<String, Object?>? cols}) async {
  await db.insert(tabla, {
    'id': id,
    'data': jsonEncode(data),
    'sync_seq': _seq++,
    if (cols != null) ...cols,
  });
}

String _iso(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

void main() {
  test('la constante lleva el texto aprobado', () {
    expect(lineaMensajeAutomatico, '\n\n$_cierre');
  });

  test('los 5 mensajes de la bandeja cierran con la línea automática',
      () async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
      url: 'http://127.0.0.1:9',
      anonKey: 'dummy',
    );
    final db = await _abrirDbVacia();
    final hoy = hoyHabanaIso();
    final hoyDt = DateTime.parse(hoy);

    Future<void> cliente(int id, String nombre, String ph,
        {String? carnet}) async {
      await _espejo(db, 'clientes', id, {
        'id': id,
        'nombre': nombre,
        'telefono': '5819000$id',
        'estado': 'activo',
        'pagado_hasta': ph,
        if (carnet != null) 'carnet': carnet,
      });
    }

    await cliente(
        11, 'Vencido Uno', _iso(hoyDt.subtract(const Duration(days: 5))));
    await cliente(12, 'Vence Hoy', hoy);
    await cliente(
        13, 'Por Vencer', _iso(hoyDt.add(const Duration(days: 2))));
    // Cumple hoy (carnet AAMMDD con el MMDD de hoy) y está al día.
    final carnetHoy = '90'
        '${hoyDt.month.toString().padLeft(2, '0')}'
        '${hoyDt.day.toString().padLeft(2, '0')}';
    await cliente(
        14, 'Cumple Hoy', _iso(hoyDt.add(const Duration(days: 30))),
        carnet: carnetHoy);
    // Recibo: pago de hoy del cliente al día.
    await _espejo(db, 'pagos', 21, {
      'id': 21,
      'cliente_id': 14,
      'fecha': hoy,
      'monto': 2000,
      'metodo': 'efectivo',
      'registrado_por': 'Jc',
    }, cols: {
      'fecha': hoy
    });

    final avisos = await avisosWhatsappHoy();
    final porTipo = <String, Map<String, dynamic>>{
      for (final a in avisos) '${a['tipo']}': a,
    };
    for (final tipo
        in ['vencido', 'vence_hoy', 'por_vencer', 'cumple', 'recibo']) {
      expect(porTipo.containsKey(tipo), isTrue,
          reason: 'falta el aviso de tipo $tipo');
      final mensaje = '${porTipo[tipo]!['mensaje']}';
      expect(mensaje.endsWith(_cierre), isTrue,
          reason: 'el mensaje de $tipo no cierra con la línea: $mensaje');
    }
  });

  test('cumple con el mes YA regalado: la bandeja anuncia el '
      'regalo con las dos fechas (corrección de campo 1.21)',
      () async {
    final db = await _abrirDbVacia();
    final hoy = hoyHabanaIso();
    final hoyDt = DateTime.parse(hoy);
    final carnetHoy = '95'
        '${hoyDt.month.toString().padLeft(2, '0')}'
        '${hoyDt.day.toString().padLeft(2, '0')}';
    await _espejo(db, 'clientes', 31, {
      'id': 31,
      'nombre': 'Regalado Hoy',
      'telefono': '58190031',
      'estado': 'activo',
      'pagado_hasta': _iso(hoyDt.add(const Duration(days: 55))),
      'carnet': carnetHoy,
    });
    // El regalo de este año ya se aplicó (meta que guardan la
    // ficha y la pantalla de Cumpleaños al regalar).
    await LocalDb.instance.setMeta(
      'regalo_cumple_31_${hoyDt.year}',
      jsonEncode({
        'anterior': _iso(hoyDt.add(const Duration(days: 25))),
        'nuevo': _iso(hoyDt.add(const Duration(days: 55))),
      }),
    );
    final avisos = await avisosWhatsappHoy();
    final cumple =
        avisos.firstWhere((a) => a['tipo'] == 'cumple');
    final mensaje = '${cumple['mensaje']}';
    expect(mensaje, contains('Te hemos regalado 1 mensualidad'));
    expect(mensaje, contains('Vencía el:'));
    expect(mensaje, contains('Nuevo vencimiento:'));
    expect(mensaje.endsWith(_cierre), isTrue);
    expect('${cumple['detalle']}', contains('Mes regalado'));
    // Y el lector compartido devuelve el regalo guardado.
    final regalo = await regaloCumpleDelAnio(31);
    expect(regalo, isNotNull);
    expect(regalo!['nuevo'],
        _iso(hoyDt.add(const Duration(days: 55))));
    expect(await regaloCumpleDelAnio(32), isNull);
  });

  test('W8: el recibo reenviable de un pago trae método, fecha y cierre',
      () {
    final t = textoReciboPago(
      nombre: 'Ana Prueba',
      monto: 2500,
      metodo: 'transferencia',
      fechaIso: '2026-10-15',
      cobradoPor: 'Gabriel',
    );
    expect(t, contains('Cliente: Ana Prueba'));
    expect(t, contains('Monto: 2500 CUP'));
    expect(t, contains('Método: Transferencia'));
    expect(t, contains('Fecha: 15/10/2026'));
    expect(t, contains('Cobrado por: Gabriel'));
    expect(t.endsWith(_cierre), isTrue);
  });
}
