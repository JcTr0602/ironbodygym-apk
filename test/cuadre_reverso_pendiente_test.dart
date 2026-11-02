/// Lag del reverso pendiente (§14, 1.20): un reverso de venta
/// de servicio ENCOLADO (aún no aplicado ni espejado) no
/// neteaba en el cuadre del día — la venta original seguía
/// contando entera hasta sincronizar. El cuadre ahora suma la
/// fila sintética que el servidor creará (cantidad negativa,
/// roles del reverso) y el neto se ve al momento.
///
/// Patrón de BD: igual que cuadre_reverso_test.dart. Sin sesión
/// de Supabase real, AuthService().isOwner es false: el actor
/// de las ops encoladas se trata como entrenador.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/servicios.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

const duany = 969869611;
// La op encolada nace con creada_ts de HOY (hora Habana): las
// fechas del test se derivan del reloj, no van clavadas.
final hoy = isoHabana(ahoraHabana()).substring(0, 10);
final ayer = isoHabana(ahoraHabana().subtract(
    const Duration(days: 1))).substring(0, 10);

Future<void> _sembrar(Map<String, dynamic> fila) =>
    LocalDb.instance.upsertMirror(
        'servicio_ventas', fila['id'] as int, fila, 1);

Map<String, dynamic> _venta({
  required int id,
  required String fecha,
  int cantidad = 1,
  double precio = 600,
  int entregado = 0,
  String metodo = 'efectivo',
  int? reversoDe,
  String? opUuid,
}) =>
    {
      'id': id,
      'fecha': fecha,
      'tipo': 'dosis_sin_agua',
      'cantidad': cantidad,
      'precio_unitario': precio,
      'comision_unitaria': 50,
      'comision_monto': 50.0,
      'metodo': metodo,
      'casa': 0,
      'entregado': entregado,
      'vendedor_id': duany,
      'responsable_efectivo_id': duany,
      'comision_entrenador_id': duany,
      'registrado_por': duany,
      'reverso_de': reversoDe,
      'op_uuid': opUuid,
    };

// La op se inserta cruda (patrón cola_desglose_test): queueOp
// derivaría telegram_id de la sesión y en tests quedaría NULL;
// aquí el actor importa (es el responsable del reverso cuando
// la venta ya estaba entregada).
Future<void> _reversoPendiente(int ventaId, {String? uuid}) async {
  final db = await LocalDb.instance.db;
  await db.insert('ops_queue', {
    'op_uuid': uuid ?? const Uuid().v4(),
    'tipo': 'revertir_venta_servicio',
    'payload': jsonEncode({'venta_id': ventaId, 'motivo': 'error'}),
    'estado': 'pendiente',
    'creada_ts': isoHabana(ahoraHabana()),
    'telegram_id': duany,
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
        url: 'http://127.0.0.1:9', anonKey: 'dummy');
  });

  setUp(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final dir = await getDatabasesPath();
    final dbPath = p.join(dir, 'ironbody.db');
    try {
      await File(dbPath).delete();
    } catch (_) {}
    try {
      await File('$dbPath-wal').delete();
    } catch (_) {}
    try {
      await File('$dbPath-shm').delete();
    } catch (_) {}
    await LocalDb.resetParaTest();
    await LocalDb.instance.db; // dispara onCreate
  });

  test('venta de hoy + reverso pendiente: el cuadre netea ya',
      () async {
    await _sembrar(_venta(id: 10, fecha: hoy, cantidad: 2));
    await _reversoPendiente(10);
    final c = await cuadreServiciosDia(duany, hoy);
    expect(c['dosis_sin_agua'], 0);
    expect(c['efectivo'], 0.0);
    expect(c['comision'], 0.0);
    final g = await cuadreServiciosDiaGym(hoy);
    expect(g['dosis_sin_agua'], 0);
    expect(g['efectivo'], 0.0);
  });

  test('sin reverso pendiente la venta cuenta entera', () async {
    await _sembrar(_venta(id: 11, fecha: hoy, cantidad: 2));
    final c = await cuadreServiciosDia(duany, hoy);
    expect(c['dosis_sin_agua'], 2);
    expect(c['efectivo'], 1200.0);
    expect(c['comision'], 50.0);
  });

  test('venta entregada revertida por el entrenador: devuelve '
      'de su gaveta (efectivo netea)', () async {
    await _sembrar(_venta(id: 12, fecha: hoy, entregado: 1));
    await _reversoPendiente(12);
    final c = await cuadreServiciosDia(duany, hoy);
    expect(c['dosis_sin_agua'], 0);
    expect(c['efectivo'], 0.0);
  });

  test('venta de ayer + reverso pendiente hoy: netea hoy y no '
      'toca el cuadre de ayer', () async {
    await _sembrar(_venta(id: 13, fecha: ayer));
    await _reversoPendiente(13);
    final gHoy = await cuadreServiciosDiaGym(hoy);
    expect(gHoy['dosis_sin_agua'], -1);
    expect(gHoy['efectivo'], -600.0);
    final gAyer = await cuadreServiciosDiaGym(ayer);
    expect(gAyer['dosis_sin_agua'], 1);
    expect(gAyer['efectivo'], 600.0);
  });

  test('reverso ya espejado + op aun en cola: no resta dos '
      'veces', () async {
    const uuidRev = 'uuid-reverso-ya-espejado';
    await _sembrar(_venta(id: 14, fecha: hoy));
    await _sembrar(_venta(
        id: 15,
        fecha: hoy,
        cantidad: -1,
        reversoDe: 14,
        opUuid: uuidRev));
    await _reversoPendiente(14, uuid: uuidRev);
    final g = await cuadreServiciosDiaGym(hoy);
    expect(g['dosis_sin_agua'], 0);
    expect(g['efectivo'], 0.0);
  });

  test('dos reversos pendientes de la misma venta netean una '
      'sola vez', () async {
    await _sembrar(_venta(id: 16, fecha: hoy));
    await _reversoPendiente(16);
    await _reversoPendiente(16);
    final g = await cuadreServiciosDiaGym(hoy);
    expect(g['dosis_sin_agua'], 0);
    expect(g['efectivo'], 0.0);
  });
}
