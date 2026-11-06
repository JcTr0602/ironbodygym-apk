import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/invitados.dart' as invitados_svc;
import 'package:ironbody_gym/plus_reportes.dart';
import 'package:ironbody_gym/ui/panel_dueno_atencion.dart';
import 'package:ironbody_gym/ui/panel_dueno_swr.dart';

/// 1.23 (B3 Paso 2): el bloque de atención del Panel del dueño
/// como función pura — orden canónico, textos y la regla de
/// «primario» se prueban sin montar la pantalla.
void main() {
  final sello = DateTime(2026, 11, 3, 9, 41);

  invitados_svc.InvitadoResumen inv(String nombre) =>
      invitados_svc.InvitadoResumen(
        id: 'i-$nombre',
        nombre: nombre,
        telefono: '55555555',
        estado: 'activo',
        solicitudDesde: DateTime(2026, 11, 3, 8, 0),
      );

  ReportePlus rep(String nombre) => ReportePlus(
        id: '1',
        invitadoId: 'i1',
        nombre: nombre,
        telefono: '55555555',
        monto: 1000,
        referencia: 'REF1',
        banco: 'BANDEC',
        movilOrigen: '55555555',
        creadoEn: DateTime(2026, 11, 3, 8, 0),
      );

  FotoAtencion foto({
    BandejaSwr<invitados_svc.InvitadoResumen>? solicitudes,
    BandejaSwr<ReportePlus>? reportes,
    List<Map<String, dynamic>> reservas = const [],
    Map<String, String> nombreSupl = const {},
    List<Map<String, dynamic>> pend = const [],
    List<String> ayer = const [],
    List<String> hoy = const [],
    int incidencias = 0,
    String? syncError,
    List<Map<String, dynamic>> stock = const [],
  }) {
    final sol = solicitudes ?? (BandejaSwr<invitados_svc.InvitadoResumen>()
      ..exito(const [], sello));
    final reps = reportes ?? (BandejaSwr<ReportePlus>()..exito(const [], sello));
    return FotoAtencion(
      solicitudes: sol,
      reportes: reps,
      reservasSolicitadas: reservas,
      nombreSupl: nombreSupl,
      pendienteEntrenadores: pend,
      sinReporteAyer: ayer,
      sinReporteHoy: hoy,
      incidenciasPend: incidencias,
      syncError: syncError,
      stockCritico: stock,
    );
  }

  test('foto vacía con éxitos sellados: sin filas (todo en orden)', () {
    expect(pendientesAtencion(foto()), isEmpty);
  });

  test('solicitudes con datos: primera fila, primario, singular', () {
    final sol = BandejaSwr<invitados_svc.InvitadoResumen>()
      ..exito([inv('Ana')], sello);
    final filas = pendientesAtencion(foto(solicitudes: sol));
    expect(filas, hasLength(1));
    expect(filas.single.destino, DestinoAtencion.solicitudes);
    expect(filas.single.primario, isTrue);
    expect(filas.single.titulo, '1 solicitud de inscripción por atender');
    expect(filas.single.detalle, startsWith('Ana'));
  });

  test('solicitudes: plural con 2', () {
    final sol = BandejaSwr<invitados_svc.InvitadoResumen>()
      ..exito([inv('Ana'), inv('Luis')], sello);
    final filas = pendientesAtencion(foto(solicitudes: sol));
    expect(filas.single.titulo, '2 solicitudes de inscripción por atender');
  });

  test('fallo sin caché: fila «sin cargar» con reintento, no vacío honesto',
      () {
    final sol = BandejaSwr<invitados_svc.InvitadoResumen>()..fallo();
    final filas = pendientesAtencion(foto(solicitudes: sol));
    expect(filas, hasLength(1));
    expect(filas.single.destino, DestinoAtencion.reintentarSolicitudes);
    expect(filas.single.titulo, 'Solicitudes de inscripción sin cargar');
    expect(filas.single.primario, isTrue);
  });

  test('vacío confirmado sin revalidar: fila suave con la nota de red', () {
    final sol = BandejaSwr<invitados_svc.InvitadoResumen>()
      ..exito(const [], sello)
      ..fallo();
    final filas = pendientesAtencion(foto(solicitudes: sol));
    expect(filas, hasLength(1));
    expect(filas.single.titulo, 'Solicitudes sin revalidar');
    expect(filas.single.detalle, contains('Sin red'));
    expect(filas.single.primario, isFalse);
  });

  test('reservas: primario solo si no hay solicitudes ni error ni carga',
      () {
    final filas = pendientesAtencion(foto(reservas: [
      {'suplemento_id': 5, 'cantidad': 2, 'expira_en': null},
    ], nombreSupl: {
      '5': 'Proteína X'
    }));
    expect(filas, hasLength(1));
    expect(filas.single.destino, DestinoAtencion.reservas);
    expect(filas.single.primario, isTrue);
    expect(filas.single.detalle, 'Proteína X ×2');
  });

  test('efectivo: detalle con 2 entrenadores y elipsis con 3', () {
    final dos = pendientesAtencion(foto(pend: [
      {'nombre': 'Duany', 'total': 500.0},
      {'nombre': 'Gabriel', 'total': 300.0},
    ]));
    expect(dos.single.destino, DestinoAtencion.arqueo);
    expect(dos.single.detalle, isNot(contains('…')));
    final tres = pendientesAtencion(foto(pend: [
      {'nombre': 'Duany', 'total': 500.0},
      {'nombre': 'Gabriel', 'total': 300.0},
      {'nombre': 'Otro', 'total': 100.0},
    ]));
    expect(tres.single.detalle, contains('· …'));
  });

  test('orden por gravedad completo con todo presente (1.25 T35)', () {
    final sol = BandejaSwr<invitados_svc.InvitadoResumen>()
      ..exito([inv('Ana')], sello);
    final reps = BandejaSwr<ReportePlus>()..exito([rep('Luis')], sello);
    final filas = pendientesAtencion(foto(
      solicitudes: sol,
      reportes: reps,
      reservas: [
        {'suplemento_id': 5, 'cantidad': 1, 'expira_en': null}
      ],
      pend: [
        {'nombre': 'Duany', 'total': 500.0}
      ],
      ayer: ['mañana'],
      hoy: ['tarde'],
      incidencias: 2,
      syncError: 'SocketException: sin red',
      stock: [
        {'nombre': 'Creatina', 'stock': 1}
      ],
    ));
    // 1.25 T35: los bloqueantes de sync (incidencias y error)
    // van PRIMERO; luego decisiones/dinero en su orden de
    // construcción; el stock (aviso) cierra. Antes este mismo
    // foto dejaba incidencias y error tras el pliegue de 5.
    expect(
      filas.map((f) => f.destino).toList(),
      [
        DestinoAtencion.incidencias,
        DestinoAtencion.diagnostico,
        DestinoAtencion.solicitudes,
        DestinoAtencion.reservas,
        DestinoAtencion.reportes,
        DestinoAtencion.arqueo,
        DestinoAtencion.cierre,
        DestinoAtencion.cierre,
        DestinoAtencion.suplementos,
      ],
    );
    // Con solicitudes presentes, la fila de reservas NO es primaria.
    expect(filas[3].primario, isFalse);
    // Un solo primario en toda la lista: el de solicitudes.
    expect(filas.where((f) => f.primario).length, 1);
    expect(filas[2].primario, isTrue);
    expect(filas[7].titulo, 'Sin reporte de caja');
    expect(filas[0].titulo, '2 incidencias de sync por revisar');
    expect(filas[0].gravedad, 0);
    expect(filas[8].gravedad, 2);
  });

  test('T35: sin cargar (bloqueante) salta delante de solicitudes', () {
    // No pueden coexistir en la misma bandeja SWR, pero sí un
    // «sin cargar» del Plus con solicitudes presentes: el
    // bloqueante manda y el primario queda en solicitudes
    // (la primera fila que lo merecía).
    final sol = BandejaSwr<invitados_svc.InvitadoResumen>()
      ..exito([inv('Ana')], sello);
    final reps = BandejaSwr<ReportePlus>()..fallo();
    final filas = pendientesAtencion(
        foto(solicitudes: sol, reportes: reps));
    expect(filas.first.destino, DestinoAtencion.reintentarReportes);
    expect(filas.first.gravedad, 0);
    expect(filas[1].destino, DestinoAtencion.solicitudes);
    expect(filas[1].primario, isTrue);
  });

  test('reportes en caché con fallo: la fila queda y dice «Sin red»', () {
    final reps = BandejaSwr<ReportePlus>()
      ..exito([rep('Luis')], sello)
      ..fallo();
    final filas = pendientesAtencion(foto(reportes: reps));
    expect(filas, hasLength(1));
    expect(filas.single.destino, DestinoAtencion.reportes);
    expect(filas.single.detalle, contains('Sin red · datos de 9:41 AM'));
  });
}
