import 'localdb.dart';
import 'tiempo.dart';

/// 1.23 (W7, ruta 1 de Jc): invitado frecuente → candidato a
/// cliente, con registro MÍNIMO de visitas.
///
/// Los invitados viven en el servidor y no existe registro de
/// visitas (la pieza completa de asistencia era la propuesta
/// T19, no seleccionada). La ruta elegida: el staff registra
/// la visita con un toque desde la ficha del invitado, el
/// conteo vive SOLO en este teléfono (tabla local
/// visitas_invitados) y el Panel del dueño lista a quienes
/// superan el umbral como candidatos a convertir.
///
/// Las visitas se agrupan por IDENTIDAD NORMALIZADA (la clave
/// del diseño): primero el carnet de 11 dígitos; si falta, el
/// teléfono en 8 dígitos limpios; si falta, el nombre
/// normalizado. Cuando la identidad se FORTALECE (al invitado
/// que venía por teléfono le aparece el carnet), el registro
/// REASIGNA sus visitas previas de la misma ficha a la clave
/// nueva: el conteo no se parte en dos. Las marcas de tiempo
/// se guardan como instante UTC canónico (delta del panel):
/// comparar textos ISO con offsets distintos (horario de
/// verano) no siempre ordena como el tiempo real.

/// Umbral por defecto de visitas en 30 días para considerar
/// candidato a un invitado (editable por el dueño en el
/// Panel; meta `w7_umbral_visitas`).
const int umbralVisitasDefecto = 8;
const int diasVentanaVisitas = 30;

String _soloDigitos(String? s) =>
    (s ?? '').replaceAll(RegExp(r'\D'), '');

String _nombreNormalizado(String? s) {
  var t = (s ?? '').trim().toLowerCase();
  const mapa = {
    'á': 'a', 'é': 'e', 'í': 'i', 'ó': 'o', 'ú': 'u',
    'ü': 'u', 'ñ': 'n',
  };
  for (final e in mapa.entries) {
    t = t.replaceAll(e.key, e.value);
  }
  return t.replaceAll(RegExp(r'\s+'), ' ');
}

/// Clave de identidad normalizada del invitado para agrupar
/// sus visitas. Nunca vacía si hay ALGÚN dato; '' solo cuando
/// no hay ni carnet ni teléfono ni nombre (no se puede
/// agrupar: el registro se omite).
String claveIdentidadInvitado({
  String? carnet,
  String? telefono,
  String? nombre,
}) {
  final ci = _soloDigitos(carnet);
  if (ci.length == 11) return 'ci:$ci';
  var tel = _soloDigitos(telefono);
  if (tel.length == 10 && tel.startsWith('53')) {
    tel = tel.substring(2);
  }
  if (tel.length == 8) return 'tel:$tel';
  final nom = _nombreNormalizado(nombre);
  if (nom.isNotEmpty) return 'nom:$nom';
  return '';
}

/// Umbral vigente (editable), saneado a 2..30.
Future<int> umbralVisitasInvitado() async {
  final txt = await LocalDb.instance.getMeta('w7_umbral_visitas');
  final n = int.tryParse(txt ?? '');
  if (n == null) return umbralVisitasDefecto;
  return n.clamp(2, 30);
}

Future<void> fijarUmbralVisitasInvitado(int n) async {
  await LocalDb.instance
      .setMeta('w7_umbral_visitas', '${n.clamp(2, 30)}');
}

String _desdeIso(int dias) =>
    ahoraUtcReal().subtract(Duration(days: dias)).toIso8601String();

/// Registra la visita de HOY para [clave]. Devuelve el conteo
/// resultante en la ventana de 30 días. Idempotencia blanda:
/// dos toques el mismo día cuentan dos visitas — es el
/// registro fiel de lo que el staff marcó (la ficha muestra
/// el conteo antes de registrar una segunda vez el mismo día).
/// Si la visita trae ficha, primero reasigna a esta clave
/// las visitas previas de la ficha (identidad fortalecida).
Future<int> registrarVisitaInvitadoAhora({
  required String clave,
  required int? invitadoId,
  required String? nombre,
}) async {
  if (invitadoId != null) {
    await LocalDb.instance.reasignarClaveVisitas(invitadoId, clave);
  }
  await LocalDb.instance.registrarVisitaInvitado(
    clave: clave,
    invitadoId: invitadoId,
    nombre: nombre,
    tsIso: ahoraUtcReal().toIso8601String(),
  );
  final filas = await LocalDb.instance
      .visitasDeInvitado(clave, _desdeIso(diasVentanaVisitas));
  return filas.length;
}

/// Visitas de [clave] en la ventana de 30 días.
Future<int> conteoVisitasInvitado(String clave) async {
  final filas = await LocalDb.instance
      .visitasDeInvitado(clave, _desdeIso(diasVentanaVisitas));
  return filas.length;
}

/// Candidatos vigentes según el umbral editable.
Future<List<Map<String, dynamic>>> candidatosInvitados() async {
  final umbral = await umbralVisitasInvitado();
  return LocalDb.instance.candidatosInvitadosFrecuentes(
      umbral, _desdeIso(diasVentanaVisitas));
}
