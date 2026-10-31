/// Primitiva segura de bajada completa (21/25). Cubre el
/// resultado PURO: `resumenBajadaCompleta` no promete de más
/// (purga diferida con cola, tablas que reintentan solas, ciclo
/// en curso) y `tablasEspejo` cubre los espejos que baja el pull.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/sync.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('completa sin pendientes ni tablas pendientes', () {
    const r = BajadaCompletaResultado(
      bajados: 42,
      pendientesAntes: 0,
      corrio: true,
      tablasPendientes: [],
    );
    expect(r.purgaDiferida, isFalse);
    final lineas = resumenBajadaCompleta(r);
    expect(lineas.join(' '), contains('42 fila(s)'));
    expect(lineas.join(' '), contains('reconstruidos por completo'));
    expect(lineas.join(' '), isNot(contains('quedó para el próximo')));
  });

  test('con pendientes: purga diferida y nada prometido', () {
    const r = BajadaCompletaResultado(
      bajados: 10,
      pendientesAntes: 3,
      corrio: true,
      tablasPendientes: [],
    );
    expect(r.purgaDiferida, isTrue);
    final texto = resumenBajadaCompleta(r).join(' ');
    expect(texto, contains('quedó para el próximo ciclo'));
    expect(texto, contains('Nada se borró'));
    expect(texto, isNot(contains('reconstruidos por completo')));
  });

  test('tablas pendientes se nombran', () {
    const r = BajadaCompletaResultado(
      bajados: 0,
      pendientesAntes: 0,
      corrio: true,
      tablasPendientes: ['clientes', 'pagos'],
    );
    final texto = resumenBajadaCompleta(r).join(' ');
    expect(texto, contains('clientes, pagos'));
    expect(texto, contains('reintentarán solas'));
  });

  test('ciclo en curso no inventa un resultado', () {
    const r = BajadaCompletaResultado(
      bajados: 0,
      pendientesAntes: 0,
      corrio: false,
      tablasPendientes: [],
    );
    final lineas = resumenBajadaCompleta(r);
    expect(lineas.length, 1);
    expect(lineas.first, contains('próximo ciclo completo'));
  });

  test('tablasEspejo: la lista canónica no está vacía ni duplicada', () {
    const t = SyncEngine.tablasEspejo;
    expect(t.length, greaterThan(20));
    expect(t.toSet().length, t.length);
    for (final clave in [
      'clientes',
      'pagos',
      'suplementos',
      'servicio_ventas',
      'gympedia_solicitudes',
      'permisos_bandeja',
      'espejo_gympedia_borradores',
    ]) {
      expect(t, contains(clave));
    }
  });
}
