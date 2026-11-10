/// Yunque de cambios 1.31 · RONDA 3 · M6 (superficies RPC):
/// contratos de fuente de las correcciones de la ronda.
///
/// - M6-2: estado_cuenta pinta primero con lo local (el Plus
///   entra como «sin verificar») y la RPC enriquece detrás:
///   ninguna espera de red antes del primer setState.
/// - M6-3: control de acceso restaura la foto persistida de
///   la caché de accesos y pinta con ella antes de la carga
///   de red; la caché expone la restauración sin red.
/// - M6-4: la subpantalla Auditoría distingue fallo de vacío
///   (bandera _falloCarga + EstadoError con reintento).
/// - M6-5: el editor de plan nutricional bloquea edición y
///   guardado cuando la carga falló (_falloCarga), en vez de
///   dejar un editor vacío guardable encima del plan real.
/// - M6-7: respuesta malformada ≠ vacío/éxito en tres
///   servicios: actividad y cierres lanzan StateError ante
///   no-List, y purgarVencidos devuelve ok:false ante
///   no-Map (su llamador enseña error, no «completada»).
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _src(String ruta) => File(ruta).readAsStringSync();

void main() {
  test('M6-2: estado_cuenta pinta local antes de la RPC del Plus', () {
    final s = _src('lib/ui/estado_cuenta.dart');
    // El primer pintado ocurre sin esperar la RPC: existe un
    // setState con _cargando = false ANTES de la llamada a
    // estadoPlusResidualCliente en el fuente.
    final iPintado = s.indexOf('_cargando = false');
    final iRpc = s.indexOf('cliente_plus_residual_staff');
    expect(iPintado, greaterThanOrEqualTo(0));
    expect(iRpc, greaterThan(iPintado),
        reason: 'la RPC del Plus debe ir DESPUÉS del primer pintado');
    expect(s, contains('sin verificar'));
  });

  test('M6-3: control de acceso pinta con la foto persistida', () {
    final s = _src('lib/ui/control_acceso.dart');
    expect(s, contains('restaurarPersistidoSiFalta'));
    expect(s, contains('_genCarga'));
    final cache = _src('lib/acceso_app_cache.dart');
    expect(cache, contains('Future<void> restaurarPersistidoSiFalta()'));
    // La restauración pública no dispara red: solo delega en
    // la lectura del persistido.
    final i = cache.indexOf('restaurarPersistidoSiFalta() async');
    final tramo = cache.substring(i, i + 400);
    expect(tramo, contains('_restaurarPersistido()'));
    expect(tramo, isNot(contains('.rpc(')));
  });

  test('M6-4: la Auditoría de accesos distingue fallo de vacío', () {
    final s = _src('lib/ui/control_acceso.dart');
    expect(s, contains('bool _falloCarga = false'));
    expect(s, contains('_falloCarga && _items.isEmpty'));
    expect(s, contains('No se pudo cargar la auditoría'));
  });

  test('M6-5: el editor de plan no guarda sobre una carga fallida', () {
    final s = _src('lib/ui/editor_plan_nutricional.dart');
    expect(s, contains('bool _falloCarga = false'));
    // El botón de guardar desaparece con fallo de carga.
    expect(s, contains('puedeEditar && !_cargando && !_falloCarga'));
    // Y el cuerpo enseña el error con reintento.
    expect(s, contains('No se pudo cargar el plan'));
    expect(s, contains('onReintentar: _cargar'));
  });

  test('M6-7a: actividad del cliente lanza ante respuesta no-List', () {
    final s = _src('lib/actividad_cliente.dart');
    expect(s, contains("throw StateError("));
    expect(s, contains('respuesta no es una lista'));
  });

  test('M6-7b: cierres del servidor lanzan ante respuesta no-List', () {
    final s = _src('lib/turno_service.dart');
    expect(s, contains("throw StateError("));
    expect(s, contains('respuesta no es una lista'));
  });

  test('M6-7c: purgarVencidos no finge éxito ante respuesta no-Map', () {
    final s = _src('lib/invitados.dart');
    final i = s.indexOf('purgarVencidos(');
    final tramo = s.substring(i, i + 1200);
    expect(tramo, contains('return (ok: false, purgados: 0);'));
    expect(tramo, isNot(contains('return (ok: true, purgados: 0);')));
    final ui = _src('lib/ui/invitados.dart');
    expect(ui, contains('No se pudo confirmar la limpieza'));
  });
}
