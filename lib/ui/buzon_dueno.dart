/// 1.29 (Oleada 5, FB-12) · Buzón del dueño en la
/// principal: lo que espera respuesta del dueño, contado
/// SOLO con datos locales ya presentes en el teléfono —
/// las reservas por responder de la app de Clientes, las
/// solicitudes de adelanto `pendiente` del espejo (que
/// existe desde la 1.12) y las solicitudes de relleno
/// `pendiente` del espejo de la oleada 4. TRES fuentes
/// obligatorias (ajuste H-08 de Argón): el texto suma
/// las tres y cada parte lleva a su bandeja. Con cero
/// en las tres, el aviso no existe.
///
/// Derivación pura, hermana de `pendientesAtencion`
/// (panel_dueno_atencion.dart): la carga vive en Home
/// (segundo pase, por fuente, como _cargarAtencionDueno)
/// y aquí solo se decide el texto.
library;

/// A qué bandeja lleva cada parte del buzón. Lo
/// resuelve Home.
enum DestinoBuzon { reservas, adelantos, rellenos }

/// Una parte no-cero del buzón, con su texto listo.
class ParteBuzon {
  final DestinoBuzon destino;
  final int conteo;
  final String texto;

  const ParteBuzon({
    required this.destino,
    required this.conteo,
    required this.texto,
  });
}

/// El conteo del buzón y sus partes visibles.
class ConteoBuzon {
  final int reservas;
  final int adelantos;
  final int rellenos;

  const ConteoBuzon({
    this.reservas = 0,
    this.adelantos = 0,
    this.rellenos = 0,
  });

  int get total => reservas + adelantos + rellenos;

  /// Con cero en las TRES fuentes, el aviso no existe.
  bool get hay => total > 0;

  /// Las partes no-cero, en el orden del plan (reservas,
  /// adelantos, rellenos), cada una con su gramática.
  List<ParteBuzon> get partes => [
        if (reservas > 0)
          ParteBuzon(
            destino: DestinoBuzon.reservas,
            conteo: reservas,
            texto: reservas == 1
                ? '1 reserva por responder'
                : '$reservas reservas por responder',
          ),
        if (adelantos > 0)
          ParteBuzon(
            destino: DestinoBuzon.adelantos,
            conteo: adelantos,
            texto: adelantos == 1
                ? '1 solicitud de adelanto'
                : '$adelantos solicitudes de adelanto',
          ),
        if (rellenos > 0)
          ParteBuzon(
            destino: DestinoBuzon.rellenos,
            conteo: rellenos,
            texto: rellenos == 1
                ? '1 solicitud de relleno'
                : '$rellenos solicitudes de relleno',
          ),
      ];

  /// El texto completo del aviso, con las partes unidas
  /// («2 reservas por responder · 1 solicitud de
  /// adelanto»). Vacío si no hay nada.
  String get textoCompleto =>
      partes.map((p) => p.texto).join(' · ');
}
