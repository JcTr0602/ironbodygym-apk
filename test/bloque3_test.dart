/// Tests del Bloque 3 (v1.12.0, Invitados + Entrenadores).
///
/// Puros: 3 estados B3/B4, C2 (3 días), E3 (6 horas), C6 (umbral 5),
/// buscador/orden/letras (A), destino F3 (etiqueta).
/// Con BD (sqflite_ffi, patrón migracion_v42_test): E2 libera lo
/// retenido, F4 sin doble PopUp, B4 registro de bajas, E4 lote
/// persistido, D5 caché de detalle, F3 sin contaminar adelantos,
/// espejo optimista conserva sync_seq.
///
/// NOTA: resolver() y mias() tocan AuthService (sesión Supabase) y
/// no se prueban aquí sin sesión; el payload de resolver con
/// destino se verifica en el test de contrato del servicio (la
/// op encolada) solo donde no hace falta sesión — pedir() no usa
/// sesión (la identidad la pone el servidor).
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/bloque3.dart';
import 'package:ironbody_gym/invitados.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

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

InvitadoResumen _inv(String id, String nombre,
    {bool convertido = false,
    int diasRestantes = 10,
    DateTime? caducaEn,
    bool plusActivo = false,
    int? plusDiasRestantes,
    String telefono = '53280834'}) {
  return InvitadoResumen(
    id: id,
    nombre: nombre,
    telefono: telefono,
    estado: convertido ? 'convertido' : 'activo',
    diasRestantes: diasRestantes,
    caducaEn: caducaEn,
    plusActivo: plusActivo,
    plusDiasRestantes: plusDiasRestantes,
  );
}

void main() {
  // ---------------------------------------------------------------
  // B3/B4: 3 estados (puros)
  // ---------------------------------------------------------------
  test('B3/B4: conversión en curso gana sobre cualquier otro estado',
      () {
    final r = resolverEstadoConvertido(
      conversionEnCurso: true,
      filaCliente: {'id': 7, 'estado': 'eliminado'},
      enRegistroEliminados: true,
      fechaRegistroEliminados: '2026-10-20T10:00:00-04:00',
    );
    expect(r.estado, EstadoConvertido.enCurso);
  });

  test('B3/B4: shell eliminado + fecha → eliminado con fecha', () {
    final r = resolverEstadoConvertido(
      conversionEnCurso: false,
      filaCliente: {'id': 7, 'estado': 'eliminado'},
      enRegistroEliminados: true,
      fechaRegistroEliminados: '2026-10-20T10:00:00-04:00',
    );
    expect(r.estado, EstadoConvertido.eliminado);
    expect(r.eliminadoEn, '2026-10-20T10:00:00-04:00');
  });

  test('B3/B4: sin fila y sin registro NUNCA es eliminado', () {
    final r = resolverEstadoConvertido(
      conversionEnCurso: false,
      filaCliente: null,
      enRegistroEliminados: false,
      fechaRegistroEliminados: null,
    );
    expect(r.estado, EstadoConvertido.sincronizandoFicha);
    expect(r.estado, isNot(EstadoConvertido.eliminado),
        reason: 'el retraso del espejo no puede pintar «eliminado»');
  });

  test('B3/B4: registro de baja sin fila → eliminado', () {
    final r = resolverEstadoConvertido(
      conversionEnCurso: false,
      filaCliente: null,
      enRegistroEliminados: true,
      fechaRegistroEliminados: '2026-10-21T09:00:00-04:00',
    );
    expect(r.estado, EstadoConvertido.eliminado);
  });

  test('B3/B4: fila activa → activo', () {
    final r = resolverEstadoConvertido(
      conversionEnCurso: false,
      filaCliente: {'id': 7, 'estado': 'activo'},
      enRegistroEliminados: false,
      fechaRegistroEliminados: null,
    );
    expect(r.estado, EstadoConvertido.activo);
  });

  // ---------------------------------------------------------------
  // C2 / E3 / C6: umbrales fijos de Jc
  // ---------------------------------------------------------------
  test('C2: Plus por vencer pronto a 3 días, no a 4', () {
    expect(_inv('a', 'Ana', plusActivo: true, plusDiasRestantes: 3)
        .plusPorVencerPronto, isTrue);
    expect(_inv('b', 'Bea', plusActivo: true, plusDiasRestantes: 4)
        .plusPorVencerPronto, isFalse);
    expect(_inv('c', 'Cid', plusActivo: false, plusDiasRestantes: 1)
        .plusPorVencerPronto, isFalse);
  });

  test('E3: 6 horas dispara el aviso, 5h59 no', () {
    final ahora = ahoraHabana();
    expect(
        horasSinSubirDesde(
            isoHabana(ahora.subtract(const Duration(hours: 6))), ahora),
        greaterThanOrEqualTo(6.0));
    expect(
        horasSinSubirDesde(
            isoHabana(ahora.subtract(const Duration(hours: 5, minutes: 59))),
            ahora),
        lessThan(6.0));
    expect(horasSinSubirDesde(null, ahora), isNull);
    expect(horasSinSubirDesde('no-fecha', ahora), isNull);
  });

  test('C6: aviso de lote por debajo de 5, en 5 exacto no', () {
    expect(avisoLotePorAgotarse(4), isTrue);
    expect(avisoLotePorAgotarse(0), isTrue);
    expect(avisoLotePorAgotarse(5), isFalse);
    expect(avisoLotePorAgotarse(8), isFalse);
  });

  // ---------------------------------------------------------------
  // A: buscador / orden / letras (puros)
  // ---------------------------------------------------------------
  test('A: buscador por nombre y por teléfono (53 tolerado)', () {
    final lista = [
      _inv('1', 'Ana Barbara', telefono: '53280834'),
      _inv('2', 'Carlos Ruiz', telefono: '58191577'),
    ];
    expect(filtrarInvitadosBusqueda(lista, 'ana').length, 1);
    expect(filtrarInvitadosBusqueda(lista, 'ANA').length, 1);
    // El usuario teclea con prefijo 53: igual encuentra los 8 dígitos.
    expect(filtrarInvitadosBusqueda(lista, '5353280834').length, 1);
    expect(filtrarInvitadosBusqueda(lista, '2808').length, 1);
    expect(filtrarInvitadosBusqueda(lista, '').length, 2);
  });

  test('A: orden caduca pone convertidos al final', () {
    final lista = [
      _inv('c', 'Convertido', convertido: true, diasRestantes: 0),
      _inv('b', 'Bea', diasRestantes: 10,
          caducaEn: DateTime(2026, 11, 5)),
      _inv('a', 'Ana', diasRestantes: 2,
          caducaEn: DateTime(2026, 10, 26)),
    ];
    final ordenada = ordenarInvitados(lista, 'caduca');
    expect(ordenada.map((e) => e.id).toList(), ['a', 'b', 'c']);
    final porNombre = ordenarInvitados(lista, 'nombre');
    expect(porNombre.map((e) => e.nombre).toList(),
        ['Ana', 'Bea', 'Convertido']);
  });

  test('A: letras apuntan al primer índice de cada letra', () {
    final lista = [
      _inv('1', 'Ana'),
      _inv('2', 'Alberto'),
      _inv('3', 'Carlos'),
    ];
    final letras = letrasInvitados(lista);
    expect(letras['A'], 0);
    expect(letras['C'], 2);
    expect(letras.containsKey('B'), isFalse);
  });

  // ---------------------------------------------------------------
  // F3 destino (puro)
  // ---------------------------------------------------------------
  test('F3: etiqueta de destino de la resolución', () {
    SolicitudAdelanto desde(String? destino) =>
        SolicitudAdelanto.fromMirror({
          'id': 's1',
          'monto': 1000,
          'motivo': 'x',
          'estado': 'aprobado',
          if (destino != null) 'destino_resolucion': destino,
        });
    expect(desde('nomina').destinoEtiqueta, 'Nómina');
    expect(desde('pendiente').destinoEtiqueta, 'Pendiente a entregar');
    expect(desde(null).destinoEtiqueta, isNull);
  });

  // ---------------------------------------------------------------
  // BD: E2 / F4 / B4 / E4 / D5 / F3 / optimista
  // ---------------------------------------------------------------
  test('E2: liberar lo retenido lo hace elegible para subir',
      () async {
    await _abrirDbVacia();
    final db = LocalDb.instance;
    final futuro =
        isoHabana(ahoraHabana().add(const Duration(hours: 1)));
    await db.queueOp(
      opUuid: 'op-retenida-1',
      tipo: 'solicitar_adelanto',
      payload: {'monto': 100, 'motivo': 't'},
      retenerHastaIso: futuro,
    );
    expect(await db.countOpsRetenidas(), 1);
    expect(await db.liberarOpsRetenidas(), 1);
    expect(await db.countOpsRetenidas(), 0);
    // Una op sin retención nunca cuenta como retenida.
    await db.queueOp(
      opUuid: 'op-normal-1',
      tipo: 'solicitar_adelanto',
      payload: {'monto': 100, 'motivo': 't'},
    );
    expect(await db.countOpsRetenidas(), 0);
  });

  test('F4: visto en SQLite sobrevive (segundo insert es no-op)',
      () async {
    await _abrirDbVacia();
    final db = LocalDb.instance;
    await db.marcarAvisoVisto('aviso-1');
    await db.marcarAvisoVisto('aviso-1');
    await db.marcarAvisoVisto('aviso-2', descartado: true);
    final vistos = await db.avisosVistosIds();
    expect(vistos, containsAll(['aviso-1', 'aviso-2']));
    expect(vistos.length, 2);
  });

  test('B4: registro de baja guarda fecha y no la reescribe',
      () async {
    await _abrirDbVacia();
    final db = LocalDb.instance;
    await db.registrarClienteEliminadoVisto(42);
    final primera = (await db.fechasClientesEliminados())[42];
    expect(primera, isNotNull);
    await db.registrarClienteEliminadoVisto(42);
    expect((await db.fechasClientesEliminados())[42], primera);
    expect((await db.fechasClientesEliminados()).length, 1);
  });

  test('E4: resultado del lote persiste antes de pintarse',
      () async {
    await _abrirDbVacia();
    final db = LocalDb.instance;
    await db.guardarResultadoLote(
      loteId: 'lote-uuid-1',
      accion: 'vida_extender',
      resultadoJson: '{"aplicados":2,"fallidos":0}',
    );
    final leido = await db.leerResultadoLote('lote-uuid-1');
    expect(leido, isNotNull);
    expect(leido!['accion'], 'vida_extender');
    expect(leido['resultado_json'], '{"aplicados":2,"fallidos":0}');
    expect(await db.leerResultadoLote('lote-inexistente'), isNull);
  });

  test('D5: caché de detalle con marca de frescura', () async {
    await _abrirDbVacia();
    final db = LocalDb.instance;
    await db.guardarDetalleCacheInvitado(
        'inv-1', '{"id":"inv-1","nombre":"Ana"}');
    final leido = await db.leerDetalleCacheInvitado('inv-1');
    expect(leido, isNotNull);
    expect(leido!.json, '{"id":"inv-1","nombre":"Ana"}');
    expect(leido.cachedAt, isNotNull);
    expect(await db.leerDetalleCacheInvitado('inv-2'), isNull);
  });

  test('F3: pedir adelanto NO contamina adelantos', () async {
    await _abrirDbVacia();
    final db = LocalDb.instance;
    final svc = SolicitudesAdelantoService.instance;
    await svc.pedir(monto: 500, motivo: 'prueba');
    final ops = await db.pendingOps();
    final pedidas = [
      for (final o in ops)
        if (o['tipo'] == 'solicitar_adelanto') o,
    ];
    expect(pedidas.length, 1);
    final payload =
        jsonDecode(pedidas.first['payload'] as String) as Map;
    expect(payload['monto'], 500);
    expect(payload['motivo'], 'prueba');
    // La solicitud pendiente NO aparece en la tabla adelantos:
    // NominaCalc no la descuenta.
    expect(await db.allMirror('adelantos'), isEmpty);
    await expectLater(
        svc.pedir(monto: 0, motivo: 'x'), throwsException);
    await expectLater(
        svc.pedir(monto: 500.5, motivo: 'x'), throwsException);
    await expectLater(
        svc.pedir(monto: 500, motivo: '  '), throwsException);
  });

  test('optimista: actualizar espejo conserva sync_seq', () async {
    await _abrirDbVacia();
    final db = LocalDb.instance;
    await db.upsertMirrorTexto(
        'solicitudes_adelanto', 's1', {'estado': 'pendiente'}, 7);
    await db.actualizarMirrorTextoOptimista(
        'solicitudes_adelanto', 's1', {'estado': 'aprobado'});
    final filas = await db.allMirror('solicitudes_adelanto');
    expect(filas.length, 1);
    expect(filas.first['estado'], 'aprobado');
    final d = await db.db;
    final raw = await d.query('solicitudes_adelanto',
        columns: ['sync_seq'], where: 'id=?', whereArgs: ['s1']);
    expect(raw.first['sync_seq'], 7);
  });
}
