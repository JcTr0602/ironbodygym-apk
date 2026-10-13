// Prueba de migración v18 → v19.
// Uso: dart test/migracion_v19_test.dart
import 'dart:io';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<void> main() async {
  sqfliteFfiInit();
  final dbPath = '/tmp/test_mig_v19.db';
  final f = File(dbPath);
  if (await f.exists()) await f.delete();

  // 1. Crear BD en v18 (simula instalación vieja)
  var db = await databaseFactoryFfi.openDatabase(
    dbPath,
    options: OpenDatabaseOptions(version: 18, onCreate: (db, v) async {
      // Esquema mínimo v18
      await db.execute('''
        CREATE TABLE incidencias_local (
          id TEXT PRIMARY KEY, tipo TEXT NOT NULL,
          entidad TEXT, entidad_id INTEGER, descripcion TEXT NOT NULL,
          detalle TEXT, estado TEXT NOT NULL DEFAULT 'pendiente',
          creada_por TEXT NOT NULL, creada_en TEXT NOT NULL,
          resuelta_por TEXT, resuelta_en TEXT, nota_resolucion TEXT,
          version INTEGER NOT NULL DEFAULT 1,
          sincronizada INTEGER NOT NULL DEFAULT 0,
          visibilidad TEXT NOT NULL DEFAULT 'compartida')
      ''');
      await db.execute('''
        CREATE TABLE incidencias_mirror (
          id TEXT PRIMARY KEY, tipo TEXT NOT NULL,
          entidad TEXT, entidad_id INTEGER, descripcion TEXT NOT NULL,
          detalle TEXT, estado TEXT NOT NULL,
          creada_por TEXT NOT NULL, creada_en TEXT,
          resuelta_por TEXT, resuelta_en TEXT, nota_resolucion TEXT,
          version INTEGER NOT NULL DEFAULT 1, actualizada_en TEXT,
          sync_seq INTEGER NOT NULL,
          visibilidad TEXT NOT NULL DEFAULT 'compartida')
      ''');
      // Datos de prueba
      await db.insert('incidencias_local', {
        'id': 'test-001',
        'tipo': 'sync',
        'descripcion': 'Incidencia vieja sin tipo_id',
        'estado': 'pendiente',
        'creada_por': 'Gabriel',
        'creada_en': '2026-10-01T10:00:00',
      });
    }),
  );
  await db.close();

  print('BD v18 creada con 1 incidencia de prueba');

  // 2. Abrir con el código real (debe migrar a v19)
  // NOTA: esto requiere importar localdb.dart, que necesita Flutter.
  // Por eso esta prueba es manual: instalar la APK en un teléfono
  // con datos v18 y verificar.

  print('');
  print('PRUEBA MANUAL:');
  print('1. Instala la v1.3.0 sobre una v1.2.9 con incidencias');
  print('2. Verifica que la app abre sin errores');
  print('3. Ve a Incidencias → debe mostrar los 4 tipos del seed');
  print('4. Las incidencias viejas deben aparecer con tipo "General"');
  print('5. Crea una incidencia nueva y verifica que sincroniza');

  await f.delete();
}
