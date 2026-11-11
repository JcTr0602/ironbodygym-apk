/// Y-CAMPO 1.31.1 · Guión 4 — El buscador con tildes y
/// doble espacio sobre el padrón grande.
///
/// Se siembran 600 clientes por el camino real del pull
/// (upsertMirror, que mantiene clientes_fts) y se busca
/// como busca el mostrador: sin tildes, con la tilde y el
/// doble espacio del que teclea rápido, y por prefijo de
/// teléfono. Se miden los tiempos de la primera búsqueda
/// (índice recién poblado) contra las siguientes (espejo
/// caliente) y se registran como evidencia.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/negocio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
  });

  setUp(() async {
    await LocalDb.resetParaTest();
  });

  test('G4: tildes, doble espacio y prefijo de teléfono '
      'sobre 600 clientes', () async {
    const nombres = [
      'Carlos', 'Miguel', 'Alejandro', 'Yunior', 'Ernesto',
      'Frank', 'Yosvani', 'Lazaro', 'Osmani', 'Reinier',
      'Darien', 'Yoel', 'Maikel', 'Roberto', 'Jorge',
      'Luis', 'Pedro', 'Juan', 'Manuel', 'Rafael',
    ];
    const apellidos = [
      'Perez Garcia', 'Rodriguez Lopez', 'Gonzalez Diaz',
      'Hernandez Ruiz', 'Martinez Sosa', 'Fernandez Mora',
      'Alvarez Pena', 'Torres Vega', 'Ramirez Leon',
      'Cruz Batista', 'Ortiz Campos', 'Nunez Herrera',
      'Santos Rojas', 'Medina Fuentes', 'Vargas Soto',
      'Castillo Ramos', 'Delgado Pino', 'Morales Gil',
      'Reyes Acosta', 'Suarez Lima', 'Ponce Herrera',
      'Luna Cardenas', 'Mesa Duarte', 'Paz Iglesias',
      'Soto Cabrera', 'Vega Miranda', 'Rios Santana',
      'Arias Beltran', 'Cordero Mesa', 'Pino Salas',
    ];
    var seq = 0;
    for (final n in nombres) {
      for (final a in apellidos) {
        seq++;
        final id = 3000 + seq;
        // 60 clientes comparten el prefijo 5819 (como en un
        // padrón real, donde los prefijos se repiten).
        final tel =
            seq <= 60 ? '5819${1000 + seq}' : '59${100000 + seq}';
        await LocalDb.instance.upsertMirror('clientes', id, {
          'id': id,
          'nombre': '$n $a',
          'estado': 'activo',
          'telefono': tel,
          'pagado_hasta': '2026-12-01',
        }, seq);
      }
    }
    expect(seq, 600);
    // El cliente del guión: tildes y eñe, teléfono 5819.
    await LocalDb.instance.upsertMirror('clientes', 2001, {
      'id': 2001,
      'nombre': 'José Ángel Ñúñez',
      'estado': 'activo',
      'telefono': '58191111',
      'pagado_hasta': '2026-12-01',
    }, 9999);

    List<int> idsDe(List<Map<String, dynamic>> r) =>
        [for (final c in r) c['id'] as int];

    // Primera búsqueda (índice recién poblado) vs caliente.
    final sw = Stopwatch()..start();
    final r1 = await buscarClientes('jose');
    sw.stop();
    final frioMs = sw.elapsedMilliseconds;
    expect(idsDe(r1), contains(2001),
        reason: 'sin tilde encuentra al de la tilde');
    final calientes = <int>[];
    for (var i = 0; i < 5; i++) {
      final s2 = Stopwatch()..start();
      final r = await buscarClientes('jose');
      s2.stop();
      calientes.add(s2.elapsedMilliseconds);
      expect(idsDe(r), contains(2001));
    }
    // ignore: avoid_print
    print('G4 tiempos «jose»: frío ${frioMs}ms · '
        'calientes $calientes ms');

    // Con tilde y DOBLE espacio, como teclea el mostrador.
    final r2 = await buscarClientes('josé  ángel');
    expect(idsDe(r2), contains(2001),
        reason: 'la tilde y el doble espacio no rompen la '
            'búsqueda');

    // Por prefijo de teléfono: hay 61 coincidencias reales
    // (60 sembrados + el del guión). La vía FTS cortaba en
    // LIMIT 50 ORDER BY rank y 11 clientes quedaban fuera
    // sin señal (hallazgo H-CAMPO-2 de este guión). Desde la
    // 1.32 (Escalón 1) la vía de teléfono corta en 200
    // (LocalDb.limiteBusquedaTelefono) y las 61 vuelven,
    // con el cliente del guión dentro.
    final db = await LocalDb.instance.db;
    final coincidencias = await db.rawQuery(
        'SELECT id FROM clientes_fts WHERE clientes_fts '
        'MATCH ?',
        ['telefonos:"5819"*']);
    expect(coincidencias.length, 61,
        reason: 'el índice SÍ contiene las 61 coincidencias');
    expect(
        coincidencias.map((r) => r['id']), contains(2001));
    final r3 = await buscarClientes('5819');
    expect(r3.length, 61,
        reason: 'corregido en la 1.32: la vía de teléfono '
            'devuelve las 61 coincidencias (tope 200), sin el '
            'corte silencioso a 50 de H-CAMPO-2');
    expect(idsDe(r3), contains(2001),
        reason: 'el cliente del guión vuelve a ser visible '
            'por el prefijo corto');
    // ignore: avoid_print
    print('G4 prefijo «5819»: 61 coincidencias en el índice, '
        '${r3.length} devueltas; 2001 '
        '${idsDe(r3).contains(2001) ? "dentro" : "FUERA"}');
    final r3b = await buscarClientes('581911');
    expect(idsDe(r3b), contains(2001),
        reason: 'con más dígitos también aparece (el prefijo '
            'largo sigue funcionando tras la corrección)');
    final s3 = Stopwatch()..start();
    await buscarClientes('5819');
    s3.stop();
    // ignore: avoid_print
    print('G4 tiempo «5819» caliente: ${s3.elapsedMilliseconds}ms '
        '(${r3.length} resultados)');

    // Sonda de typo (observacional: se registra el resultado
    // real, no se fuerza expectativa).
    final r4 = await buscarClientes('jsoe angel');
    // ignore: avoid_print
    print('G4 typo «jsoe angel»: '
        '${idsDe(r4).contains(2001) ? "encuentra" : "NO encuentra"} '
        'a 2001 (resultados: ${r4.length})');

    await LocalDb.resetParaTest();
  });
}
