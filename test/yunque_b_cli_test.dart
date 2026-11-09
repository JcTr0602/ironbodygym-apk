/// Yunque B · CLI-08/09/10/11 (Gestión 1.31):
/// - CLI-09/10: el payload de inscripcion_venta_suplemento
///   es la frontera: el teléfono viaja sanitizado a sus 8
///   dígitos y el carnet solo dígitos, aunque la pantalla
///   entregue el texto crudo («5819 1577», «950220 12345»).
/// - CLI-11: updateMirrorTelefono normaliza en la propia
///   frontera de almacenamiento (dígitos, sin prefijo 53).
/// - CLI-08: venceEnVentana cuenta días en UTC — en el
///   borde del cambio de hora de marzo (día de 23 h en La
///   Habana), la resta de medianoches locales daba 0 días
///   para «mañana» y el recordatorio disparaba mal.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/bloque2_resto.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/ui/venta_suplemento_inscripcion.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

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

Map<String, dynamic> _payload({String? telefono, String? carnet}) {
  return payloadInscripcionVentaSuplemento(
    nombre: 'Cliente Prueba',
    telefono: telefono,
    carnet: carnet,
    suplementoId: 7,
    cantidad: 1,
    precio: 600,
    moneda: 'CUP',
    precioOficial: 600,
    fecha: '2026-11-09',
    metodoPago: 'efectivo',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('YB-CLI-09: el teléfono crudo viaja limpio en el payload',
      () {
    final p1 = _payload(telefono: '5819 1577');
    expect((p1['cliente'] as Map)['telefono'], '58191577');
    final p2 = _payload(telefono: '+53 5819 1577');
    expect((p2['cliente'] as Map)['telefono'], '58191577');
    final p3 = _payload(telefono: '58191577');
    expect((p3['cliente'] as Map)['telefono'], '58191577');
    // Sin teléfono no se inventa la clave.
    final p4 = _payload();
    expect((p4['cliente'] as Map).containsKey('telefono'), isFalse);
  });

  test('YB-CLI-10: el carnet crudo viaja solo dígitos', () {
    final p1 = _payload(carnet: '950220 12345');
    expect((p1['cliente'] as Map)['carnet'], '95022012345');
    final p2 = _payload(carnet: '950220');
    expect((p2['cliente'] as Map)['carnet'], '950220');
  });

  test('YB-CLI-08: venceEnVentana en el borde del cambio de hora',
      () {
    // 2026-03-08 → 2026-03-09 en La Habana es un día de
    // 23 h: con medianoches locales la resta daba 0 días.
    expect(venceEnVentana('2026-03-09', '2026-03-08', 0), isFalse,
        reason: 'mañana NO vence «hoy» (ventana 0)');
    expect(venceEnVentana('2026-03-09', '2026-03-08', 1), isTrue);
    expect(venceEnVentana('2026-03-08', '2026-03-08', 0), isTrue);
    expect(venceEnVentana('2026-03-07', '2026-03-08', 7), isFalse,
        reason: 'lo ya vencido no está en ventana');
    expect(venceEnVentana(null, '2026-03-08', 7), isFalse);
  });

  test('YB-CLI-11: updateMirrorTelefono guarda 8 dígitos limpios',
      () async {
    final db = await _abrirDbVacia();
    await db.insert('clientes', {
      'id': 42,
      'data': jsonEncode({'id': 42, 'nombre': 'X', 'telefono': ''}),
      'sync_seq': 1,
    });
    await LocalDb.instance.updateMirrorTelefono(42, '5819 1577');
    var filas = await db.query('clientes', where: 'id=?', whereArgs: [42]);
    var data = jsonDecode(filas.single['data'] as String) as Map;
    expect(data['telefono'], '58191577');
    await LocalDb.instance.updateMirrorTelefono(42, '+53 5234 5678');
    filas = await db.query('clientes', where: 'id=?', whereArgs: [42]);
    data = jsonDecode(filas.single['data'] as String) as Map;
    expect(data['telefono'], '52345678',
        reason: 'el prefijo 53 nunca se almacena');
  });
}
