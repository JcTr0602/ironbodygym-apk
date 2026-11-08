/// Estado de la solicitud de adelanto para el entrenador (19/25).
/// Cubre solicitudesConPendientes (PURO): el espejo manda y las
/// ops `solicitar_adelanto` en 'pendiente' aparecen como
/// 'por_enviar' sin duplicar nada.
///
/// 1.30 (Oleada 2): el contrato se amplió — entran los TRES
/// estados vivos ('pendiente', 'enviada', 'error') con
/// deduplicación exacta por op_uuid y el fallback MEDIA-02.
/// El test que fijaba «enviada no entra» codificaba el defecto
/// (la petición en vuelo desaparecía de «mías») y se actualizó
/// con este motivo; la cobertura completa de la oleada vive en
/// gestion130_oleada2_adelantos_test.dart.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/bloque3.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  SolicitudAdelanto espejo({
    required String id,
    required String estado,
    double monto = 1000,
    String? opUuid,
  }) =>
      SolicitudAdelanto(
          id: id, monto: monto, motivo: 'personal', estado: estado,
          opUuid: opUuid,
          creadoEn: '2026-10-30T10:00:00-04:00');

  Map<String, dynamic> op({
    required String uuid,
    required String estado,
    String tipo = 'solicitar_adelanto',
    Object? payload,
  }) =>
      {
        'op_uuid': uuid,
        'tipo': tipo,
        'estado': estado,
        'creada_ts': '2026-10-30T12:00:00-04:00',
        'payload': jsonEncode(payload ??
            {'monto': 2000, 'motivo': 'emergencia'}),
      };

  test('op pendiente aparece como por_enviar junto al espejo', () {
    final out = solicitudesConPendientes(
      espejo: [espejo(id: 's1', estado: 'pendiente')],
      opsPendientes: [op(uuid: 'u1', estado: 'pendiente')],
    );
    expect(out.length, 2);
    final porEnviar =
        out.where((s) => s.estado == 'por_enviar').toList();
    expect(porEnviar.length, 1);
    expect(porEnviar.first.monto, 2000);
    expect(porEnviar.first.motivo, 'emergencia');
    expect(porEnviar.first.id, 'op:u1');
  });

  test('enviada y error entran; aplicada y otros tipos no', () {
    // 1.30 (Oleada 2): antes este test exigía que la 'enviada'
    // NO entrara — eso era el defecto (la petición en vuelo
    // desaparecía de «mías» hasta el pull). Ahora entran los
    // tres estados vivos; 'aplicada' ya no está en la cola de
    // lectura y otros tipos nunca son adelantos.
    final out = solicitudesConPendientes(
      espejo: [],
      opsPendientes: [
        op(uuid: 'u1', estado: 'enviada'),
        op(uuid: 'u2', estado: 'aplicada'),
        op(uuid: 'u3', estado: 'pendiente', tipo: 'pago_mensual'),
        op(uuid: 'u4', estado: 'error'),
      ],
    );
    expect(out.length, 2);
    expect(out.map((s) => s.id), containsAll(['op:u1', 'op:u4']));
  });

  test('payload malformado o sin monto se ignora', () {
    final out = solicitudesConPendientes(
      espejo: [],
      opsPendientes: [
        op(uuid: 'u1', estado: 'pendiente', payload: {'monto': 0}),
        op(uuid: 'u2', estado: 'pendiente', payload: {'motivo': ''}),
        {
          'op_uuid': 'u3',
          'tipo': 'solicitar_adelanto',
          'estado': 'pendiente',
          'payload': 'no-json',
        },
      ],
    );
    expect(out, isEmpty);
  });

  test('ordena por fecha descendente', () {
    final out = solicitudesConPendientes(
      espejo: [espejo(id: 's1', estado: 'pendiente')],
      opsPendientes: [op(uuid: 'u1', estado: 'pendiente')],
    );
    expect(out.first.estado, 'por_enviar');
    expect(out.last.id, 's1');
  });
}
