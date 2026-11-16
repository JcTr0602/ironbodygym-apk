/// SL-X2 · G08-7 + familia G12-7 (residual) + familia BG-01
/// (residual) — traductores y parseos que no deben pintar
/// claves crudas ni lanzar por una forma inesperada.
///
/// G08-7: _etiquetaEstado de auditoria.dart devolvía
/// `enviada` / `necesita_revision` CRUDOS en su rama por
/// defecto, teniendo el traductor de la casa en cola.dart
/// (etiquetaEstadoOp). Corregido: la rama por defecto pasa
/// por el traductor; lo desconocido se lee «Estado
/// registrado». El traductor de la pantalla queda expuesto
/// como etiquetaEstadoAuditoria para fijarlo aquí.
///
/// G12-7 (residual): tituloActividadCliente devolvía la
/// clave transformada en su rama por defecto (plus_quitar →
/// «plus quitar»). Corregido: mapa de claves conocidas que
/// faltaban (familia plus_*) y defecto «Acción registrada»,
/// como el traductor de SL-1. La familia vale_ conserva su
/// prefijo legible con el detalle traducido.
///
/// BG-01 (residual): los parseos de invitados.dart con el
/// patrón `(j['x'] as List?)` lanzan TypeError si el dato
/// no es List. Corregido: guardas de tipo reales, como hizo
/// SL-1 en plus_reportes.dart.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/actividad_cliente.dart';
import 'package:ironbody_gym/invitados.dart';
import 'package:ironbody_gym/ui/auditoria.dart';

ActividadCliente _fila(String accion) => ActividadCliente(
      fuente: 'auditoria',
      idOrigen: 1,
      actor: null,
      accion: accion,
      detalle: const {},
      creadoEn: DateTime.utc(2026, 11, 16),
    );

void main() {
  group('G08-7 · etiqueta de estado de Auditoría', () {
    test('necesita_revision y enviada se traducen, no van crudos',
        () {
      expect(etiquetaEstadoAuditoria('necesita_revision'),
          'Requiere revisión');
      expect(etiquetaEstadoAuditoria('enviada'),
          'Confirmación pendiente');
    });

    test('las conocidas de la pantalla conservan su texto', () {
      expect(etiquetaEstadoAuditoria('aplicada'), 'Sincronizada');
      expect(etiquetaEstadoAuditoria('pendiente'),
          'Pendiente de sync');
      expect(etiquetaEstadoAuditoria('rechazada'),
          'Rechazada por el servidor');
      expect(etiquetaEstadoAuditoria('error'), 'Error al subir');
    });

    test('lo desconocido se lee «Estado registrado»', () {
      expect(etiquetaEstadoAuditoria('estado_futuro_x'),
          'Estado registrado');
    });
  });

  group('G12-7 · tituloActividadCliente', () {
    test('plus_quitar se lee en humano, nunca la clave', () {
      final t = tituloActividadCliente(_fila('plus_quitar'));
      expect(t, isNot(contains('plus')));
      expect(t.toLowerCase(), contains('plus'),
          reason: 'el texto humano puede nombrar el Plus; lo '
              'que no puede es ser la clave con guiones fuera');
      expect(t, 'Plus retirado');
    });

    test('una clave inventada cae a «Acción registrada»', () {
      expect(tituloActividadCliente(_fila('accion_nueva_2099')),
          'Acción registrada');
    });

    test('las conocidas previas conservan su texto', () {
      expect(tituloActividadCliente(_fila('revocar')),
          'Acceso revocado');
      expect(tituloActividadCliente(_fila('sesion_subida')),
          'Sesión de entreno subida');
    });

    test('la familia vale_ no escupe la clave cruda', () {
      final t = tituloActividadCliente(_fila('vale_canjeado'));
      expect(t, isNot('vale canjeado'));
      expect(t, startsWith('Vale de premio'));
    });
  });

  group('BG-01 · parseos de invitados con formas no-List', () {
    test('PlusDetalle.fromJson con historial no-List no lanza',
        () {
      final d = PlusDetalle.fromJson({
        'estado': 'activo',
        'activo': true,
        'historial': 'no-es-una-lista',
      });
      expect(d.historial, isEmpty);
      expect(d.estado, 'activo');
    });

    test('PlusDetalle.fromJson con historial numérico no lanza',
        () {
      final d = PlusDetalle.fromJson({'historial': 42});
      expect(d.historial, isEmpty);
    });

    test('ResultadoLote.fromJson con items no-List no lanza',
        () {
      final r = ResultadoLote.fromJson({
        'accion': 'quitar_plus',
        'aplicados': 1,
        'items': {'id': 'x'},
      });
      expect(r.items, isEmpty);
      expect(r.aplicados, 1);
    });

    test('InvitadoDetalle.fromJson con mediciones y staff '
        'no-List no lanza', () {
      final d = InvitadoDetalle.fromJson({
        'invitado': {
          'id': 'inv-1',
          'nombre': 'Invitado Uno',
          'telefono': '58112233',
          'estado': 'activo',
        },
        'mediciones': 'no-es-una-lista',
        'staff_acciones': 7,
      });
      expect(d.mediciones, isEmpty);
      expect(d.staffAcciones, isEmpty);
      expect(d.nombre, 'Invitado Uno');
    });

    test('las formas List correctas siguen parseando', () {
      final d = PlusDetalle.fromJson({
        'estado': 'activo',
        'historial': [
          {'accion': 'plus_cortesia'},
        ],
      });
      expect(d.historial.length, 1);
    });
  });
}
