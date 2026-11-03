/// 1.22 (campo): el botón Recargar de Servicios infería el
/// éxito comparando ultimo_pull_ts y anunciaba «Sin
/// conexión» incluso cuando el ciclo no corrió (lock
/// ocupado). El motor ahora devuelve el resultado
/// detallado; sin sesión el motivo es sinSesion y
/// sincronizarScope (bool) sigue valiendo false.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/sync.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(url: 'http://127.0.0.1:9', anonKey: 'dummy');
    await LocalDb.resetParaTest();
  });

  test('sin sesión: detallado dice no corrió, motivo sinSesion',
      () async {
    final r =
        await SyncEngine.instance.sincronizarScopeDetallado('servicios');
    expect(r.corrio, isFalse);
    expect(r.error, isFalse);
    expect(r.bajados, 0);
    expect(r.motivo, SyncMotivoNoCorrio.sinSesion);
  });

  test('el atajo bool (GY-06) equivale a corrio && !error', () async {
    expect(await SyncEngine.instance.sincronizarScope('servicios'),
        isFalse);
  });

  test('scope vacío: no corrió y sin motivo', () async {
    final r = await SyncEngine.instance
        .sincronizarScopeDetallado('scope_que_no_existe');
    expect(r.corrio, isFalse);
    expect(r.motivo, isNull);
  });
}
