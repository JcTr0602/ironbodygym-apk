/// H-C3 (1.36) — contratos de las funciones puras nuevas o
/// corregidas del rango 982–1081 (cruce Hy4, filas PARCIALES:
/// solo la parte confirmada).
/// Fuente: cola-123/hy4_ui_135_08/cruce/ENRUTADOS.md
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:ironbody_gym/actividad_cliente.dart';
import 'package:ironbody_gym/bloque2_resto.dart';
import 'package:ironbody_gym/bloque3.dart';
import 'package:ironbody_gym/negocio.dart';
import 'package:ironbody_gym/notificaciones_recordatorios.dart';
import 'package:ironbody_gym/recordatorios.dart';
import 'package:ironbody_gym/ui/auditoria.dart';
import 'package:ironbody_gym/ui/exportar_excel.dart';
import 'package:ironbody_gym/ui/transferencia.dart';

ActividadCliente _act(Map<String, dynamic> detalle, {String? actor}) =>
    ActividadCliente(
      fuente: 'rpc',
      idOrigen: 1,
      actor: actor,
      accion: 'sesion',
      detalle: detalle,
      creadoEn: DateTime.utc(2026, 11, 18),
    );

RecordatorioDebido _debido(String tipo, {String titulo = 'Libre'}) =>
    RecordatorioDebido(
      recordatorioId: 'r1',
      titulo: titulo,
      tipo: tipo,
      alcance: 'todos',
      targetKey: 'k',
      yaDisparado: false,
      puedoDisparar: true,
      fechaHabana: '2026-11-18',
    );

void main() {
  group('136-985 textoAvisoRecordatorio: título nativo FIJO por tipo', () {
    test('cumpleaños no usa el título libre de la config', () {
      final t = textoAvisoRecordatorio(_debido('cumpleanos', titulo: 'X'));
      expect(t.titulo, 'Cumpleaños hoy');
    });
    test('vencimiento y genérico', () {
      expect(textoAvisoRecordatorio(_debido('vencimiento')).titulo,
          'Vencimiento próximo');
      expect(textoAvisoRecordatorio(_debido('otro')).titulo, 'Recordatorio');
    });
  });

  group('136-1002 detalleActividadCliente', () {
    test('una sola línea de Fecha, con prioridad de fecha_sesion', () {
      final s = detalleActividadCliente(_act({
        'fecha_sesion': '2026-11-17',
        'fecha': '2026-11-18',
      }));
      expect('Fecha:'.allMatches(s).length, 1);
      expect(s, contains('Fecha: 2026-11-17'));
    });
    test('entrenador por nombre; solo id → se omite', () {
      expect(
          detalleActividadCliente(_act({'entrenador_nombre': 'Duany'})),
          contains('Entrenador: Duany'));
      expect(detalleActividadCliente(_act({'entrenador_id': 42})),
          isNot(contains('Entrenador')));
    });
  });

  group('136-1020 alcance de auditoría con comparación normalizada', () {
    test('actor propio con espacios/mayúsculas NO salta a Todo', () {
      final r = alcanceAlElegirActor(
        alcance: FiltroAuditoria.soloMias,
        actorElegido: ' duany ',
        miActor: 'Duany',
      );
      expect(r, FiltroAuditoria.soloMias);
    });
    test('actor ajeno con Solo mías → Todo', () {
      final r = alcanceAlElegirActor(
        alcance: FiltroAuditoria.soloMias,
        actorElegido: 'Gabriel',
        miActor: 'Duany',
      );
      expect(r, FiltroAuditoria.todo);
    });
    test('alcance inverso: actor propio normalizado se conserva', () {
      final r = alcanceAlElegirAlcance(
        nuevoAlcance: FiltroAuditoria.soloMias,
        actorElegido: 'DUANY',
        miActor: 'duany',
      );
      expect(r.actor, 'DUANY');
      final r2 = alcanceAlElegirAlcance(
        nuevoAlcance: FiltroAuditoria.soloMias,
        actorElegido: 'Gabriel',
        miActor: 'Duany',
      );
      expect(r2.actor, isNull);
    });
  });

  group('136-1037 csvDeExportacion: neutraliza fórmulas, no números', () {
    test('número negativo pasa tal cual; fórmula de texto se neutraliza', () {
      final csv = csvDeExportacion(['a'], [
        ['-50'],
        ['=SUMA(A1:A2)'],
        ['texto,con coma'],
      ]);
      final lineas = csv.trim().split('\n');
      expect(lineas[1], '-50');
      expect(lineas[2], "'=SUMA(A1:A2)");
      expect(lineas[3], '"texto,con coma"');
    });
  });

  group('136-1045 textoFechaEnvio valida antes de recortar', () {
    test('iso válido → dd/MM hh:mm', () {
      expect(textoFechaEnvio('2026-11-18T09:05:00'), '18/11 09:05');
    });
    test('no parseable vuelve tal cual (sin fecha inventada)', () {
      expect(textoFechaEnvio('no-es-una-fecha-larga'), 'no-es-una-fecha-larga');
      expect(textoFechaEnvio('2026-11'), '2026-11');
    });
  });

  group('136-1048 textoComprobanteCompra con fecha inválida → «—»', () {
    test('fecha corta no revienta y cae a —', () {
      final s = textoComprobanteCompra(
        nombreProducto: 'Proteína',
        cantidad: 1,
        precio: 100,
        moneda: 'CUP',
        total: 100,
        nombreComprador: 'Ana',
        fechaIso: '2026',
      );
      expect(s, contains('—'));
    });
  });

  group('136-1057 textos de vale y recibo', () {
    test('vale aprobado: singular «1 día»', () {
      final s = mensajeWaValeAprobado(
          nombre: 'Ana', premioDias: 1, nuevoHastaIso: null);
      expect(s, contains('premio de 1 día'));
      expect(s, isNot(contains('1 días')));
    });
    test('vale rechazado sin motivo: no pinta «Motivo:»', () {
      final s = mensajeWaValeRechazado(nombre: 'Ana', motivo: '  ');
      expect(s, isNot(contains('Motivo:')));
      final s2 = mensajeWaValeRechazado(nombre: 'Ana', motivo: 'Sin pago');
      expect(s2, contains('Motivo: Sin pago'));
    });
    test('recibo con método desconocido → «Otros», no «Efectivo»', () {
      final s = textoReciboPago(
        nombre: 'Ana',
        monto: 2000,
        metodo: 'tarjeta',
        fechaIso: '2026-11-18',
        cobradoPor: 'Duany',
      );
      expect(s, contains('Método: Otros'));
      expect(s, isNot(contains('Método: Efectivo')));
    });
  });

  group('136-1065 fechaAltaCliente: creado manda, día Habana', () {
    test('creado con hora UTC de madrugada → día Habana anterior', () {
      // 2026-11-18T02:00Z = 2026-11-17 21:00 en La Habana.
      expect(fechaAltaCliente({'creado': '2026-11-18T02:00:00Z'}),
          '2026-11-17');
    });
    test('respaldo en fecha_inscripcion; sin datos → vacío', () {
      expect(fechaAltaCliente({'fecha_inscripcion': '2026-11-05'}),
          '2026-11-05');
      expect(fechaAltaCliente({}), '');
    });
  });

  group('136-1071 compararDiarios: desempates estables', () {
    test('mismo nombre: manda la hora; a igual hora, el op_uuid', () {
      final a = {
        'registrado_por_nombre': 'Duany',
        'hora': '09:00',
        'op_uuid': 'b',
      };
      final b = {
        'registrado_por_nombre': 'Duany',
        'hora': '08:00',
        'op_uuid': 'a',
      };
      expect(compararDiarios(a, b), greaterThan(0));
      expect(compararDiarios(b, a), lessThan(0));
      final c = {...a, 'hora': '08:00', 'op_uuid': 'c'};
      expect(compararDiarios(b, c), lessThan(0));
    });
  });

  group('136-1076 puedeDispararMasivo con log local de hoy', () {
    test('log local de hoy bloquea aunque el sincronizado no lo diga', () {
      expect(
          puedeDispararMasivo(
            esTelefonoDueno: true,
            disparadoEnFechaHabana: null,
            hoyHabana: '2026-11-18',
            logLocalHoy: true,
          ),
          isFalse);
      expect(
          puedeDispararMasivo(
            esTelefonoDueno: true,
            disparadoEnFechaHabana: null,
            hoyHabana: '2026-11-18',
          ),
          isTrue);
    });
  });

  group('136-1078 etiquetaEstadoSolicitud', () {
    test('códigos internos → etiquetas legibles', () {
      expect(etiquetaEstadoSolicitud('por_enviar'), 'Por enviar');
      expect(etiquetaEstadoSolicitud('atendida'), 'Atendida');
      expect(etiquetaEstadoSolicitud('desconocido'), 'Pendiente');
    });
  });
}
