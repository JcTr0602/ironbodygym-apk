/// v1.2.9+43: clasificación y traducción completa de errores de sync.
///
/// Arquitectura de blindaje anti-fugas técnicas (Gemini R3):
/// - NINGÚN mensaje técnico llega al usuario
/// - Regla de la verdad: solo se afirma "datos guardados" si SQLite tuvo éxito
/// - Todo error tiene: mensaje simple + acción concreta + botón
library;

import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

/// Categoría del error: decide el tratamiento.
enum TipoErrorSync {
  /// Reintentable con backoff (timeout, sin red, 5xx, 429).
  transitorio,

  /// No se arregla reintentando (400, 404, payload inválido).
  permanente,

  /// Requiere re-autenticación (401, sesión vencida).
  auth,

  /// Conflicto de edición concurrente (409).
  conflicto,

  /// Error local del dispositivo (SQLite, disco).
  local,

  /// Permiso del sistema denegado (cámara, almacenamiento).
  permiso,

  /// El servidor rechazó el contenido (validación de negocio).
  validacion,
}

/// Acción del botón primario en la UI.
enum AccionBoton {
  reintentar,
  iniciarSesion,
  verAjustes,
  corregir,
  refrescarTodo,
  esperar,
  contactarSoporte,
  entendido,
}

/// Error clasificado con mensaje humano y acción sugerida.
class ErrorSync {
  /// Código estable, ej. 'sin_conexion', 'timeout', 'servidor_error'.
  final String codigo;
  final TipoErrorSync tipo;

  /// Mensaje en lenguaje humano (sin tecnicismos ni detalles internos).
  final String mensaje;

  /// Qué debe hacer el usuario (instrucción concreta).
  final String accionTexto;

  /// Acción del botón primario.
  final AccionBoton accionBoton;

  /// TRUE solo si SQLite confirmó la escritura local antes del error.
  /// Regla de la verdad: nunca afirmar "datos a salvo" si es false.
  final bool datosGuardadosLocalmente;

  /// Detalle técnico original, solo para logs/depuración. Nunca mostrar al usuario.
  final String? detalleTecnicoOculto;

  const ErrorSync({
    required this.codigo,
    required this.tipo,
    required this.mensaje,
    required this.accionTexto,
    required this.accionBoton,
    required this.datosGuardadosLocalmente,
    this.detalleTecnicoOculto,
  });
}

/// Traduce cualquier error a un ErrorSync con mensaje en lenguaje simple.
/// GARANTIZA que ningún término técnico llegue al usuario.
ErrorSync traducirErrorSync(Object error, {int? httpStatus, StackTrace? stack}) {
  final raw = error.toString().toLowerCase();

  // 1. Permisos del sistema operativo
  if (raw.contains('cameradenied') ||
      raw.contains('camera permission') ||
      (raw.contains('camera') && raw.contains('denied'))) {
    return ErrorSync(
      codigo: 'permiso_camara',
      tipo: TipoErrorSync.permiso,
      mensaje: 'La app no tiene permiso para usar la cámara.',
      accionTexto: 'Activa el permiso de cámara en los ajustes del teléfono.',
      accionBoton: AccionBoton.verAjustes,
      datosGuardadosLocalmente: true,
      detalleTecnicoOculto: error.toString(),
    );
  }
  if ((raw.contains('storage') || raw.contains('photos')) &&
      (raw.contains('denied') || raw.contains('permission'))) {
    return ErrorSync(
      codigo: 'permiso_almacen',
      tipo: TipoErrorSync.permiso,
      mensaje: 'La app necesita permiso para guardar fotos.',
      accionTexto: 'Permite el acceso a las fotos en los ajustes del teléfono.',
      accionBoton: AccionBoton.verAjustes,
      datosGuardadosLocalmente: true,
      detalleTecnicoOculto: error.toString(),
    );
  }

  // 2. Almacenamiento local / SQLite (Regla de la verdad: datos NO guardados)
  if (raw.contains('sqlite_full') ||
      raw.contains('no space left') ||
      raw.contains('disk full') ||
      raw.contains('enospc')) {
    return ErrorSync(
      codigo: 'disco_lleno',
      tipo: TipoErrorSync.local,
      mensaje: 'El teléfono no tiene espacio libre.',
      accionTexto: 'Libera espacio borrando fotos o archivos viejos.',
      accionBoton: AccionBoton.entendido,
      datosGuardadosLocalmente: false,
      detalleTecnicoOculto: error.toString(),
    );
  }
  if (raw.contains('sqlite_busy') ||
      raw.contains('database is locked') ||
      raw.contains('sqlite_locked')) {
    return ErrorSync(
      codigo: 'bd_bloqueada',
      tipo: TipoErrorSync.local,
      mensaje: 'El teléfono está ocupado con otra tarea.',
      accionTexto: 'Espera unos segundos y vuelve a intentarlo.',
      accionBoton: AccionBoton.reintentar,
      datosGuardadosLocalmente: false,
      detalleTecnicoOculto: error.toString(),
    );
  }
  if (raw.contains('sqlite_corrupt') || raw.contains('database disk image')) {
    return ErrorSync(
      codigo: 'bd_corrupta',
      tipo: TipoErrorSync.local,
      mensaje: 'Hubo un problema con los datos guardados en el teléfono.',
      accionTexto: 'Contacta al soporte para reparar la aplicación.',
      accionBoton: AccionBoton.contactarSoporte,
      datosGuardadosLocalmente: false,
      detalleTecnicoOculto: error.toString(),
    );
  }

  // 3. Desfase de sincronización (watermark/server_seq)
  if (raw.contains('watermark') || raw.contains('server_seq')) {
    return ErrorSync(
      codigo: 'desfase_servidor',
      tipo: TipoErrorSync.conflicto,
      mensaje: 'Hay información nueva del servidor por descargar.',
      accionTexto: 'Toca el botón para actualizar los datos.',
      accionBoton: AccionBoton.refrescarTodo,
      datosGuardadosLocalmente: true,
      detalleTecnicoOculto: error.toString(),
    );
  }

  // 4. Multimedia / fotos / TUS
  if (raw.contains('tus') ||
      (raw.contains('upload') && raw.contains('fail')) ||
      raw.contains('storage_error')) {
    return ErrorSync(
      codigo: 'foto_subida_fallida',
      tipo: TipoErrorSync.transitorio,
      mensaje: 'No se pudo subir la foto por la conexión.',
      accionTexto: 'Se reintentará automáticamente cuando mejore la señal.',
      accionBoton: AccionBoton.reintentar,
      datosGuardadosLocalmente: true,
      detalleTecnicoOculto: error.toString(),
    );
  }
  if (raw.contains('compress') && raw.contains('fail') ||
      raw.contains('image too large')) {
    return ErrorSync(
      codigo: 'foto_muy_pesada',
      tipo: TipoErrorSync.transitorio,
      mensaje: 'La foto es muy grande para esta conexión.',
      accionTexto: 'La app la comprimirá automáticamente.',
      accionBoton: AccionBoton.reintentar,
      datosGuardadosLocalmente: true,
      detalleTecnicoOculto: error.toString(),
    );
  }

  // 5. Autenticación
  if (httpStatus == 401 ||
      raw.contains('jwt') ||
      raw.contains('sessionexpired') ||
      raw.contains('sesion vencida') ||
      raw.contains('unauthorized')) {
    return ErrorSync(
      codigo: 'sesion_caducada',
      tipo: TipoErrorSync.auth,
      mensaje: 'Tu sesión venció.',
      accionTexto: 'Entra de nuevo con tu usuario para continuar.',
      accionBoton: AccionBoton.iniciarSesion,
      datosGuardadosLocalmente: true,
      detalleTecnicoOculto: error.toString(),
    );
  }
  if (httpStatus == 403 || raw.contains('forbidden')) {
    return ErrorSync(
      codigo: 'sin_permiso_rol',
      tipo: TipoErrorSync.auth,
      mensaje: 'No puedes hacer esta acción con tu cuenta.',
      accionTexto: 'Consulta al responsable de tu organización.',
      accionBoton: AccionBoton.entendido,
      datosGuardadosLocalmente: true,
      detalleTecnicoOculto: error.toString(),
    );
  }

  // 6. Red y conexión
  // 1.23 (Push-S P-2; Argón, pasada 2 del Push — H-03): paridad
  // de patrones con los clasificadores hermanos de este mismo
  // dominio (resumenErrorDiagnostico reconoce handshake/reset/
  // certificate; errorSyncLegible reconoce clientexception).
  // Sin ellos, un corte TLS o un ClientException del push caía
  // al fallback «desconocido» con datosGuardadosLocalmente en
  // false — la app decía que los datos podían no estar
  // guardados por un simple corte de red.
  if (raw.contains('socketexception') ||
      raw.contains('socket') && raw.contains('exception') ||
      raw.contains('failed host lookup') ||
      raw.contains('network is unreachable') ||
      raw.contains('handshakeexception') ||
      raw.contains('clientexception') ||
      raw.contains('connection closed') ||
      raw.contains('connection reset') ||
      raw.contains('certificate') ||
      raw.contains('sin internet') ||
      raw.contains('sin conexión')) {
    return ErrorSync(
      codigo: 'sin_conexion',
      tipo: TipoErrorSync.transitorio,
      mensaje: 'No hay conexión a internet.',
      accionTexto: 'Tus datos están guardados en el teléfono. Se enviarán solos cuando vuelva la señal.',
      accionBoton: AccionBoton.reintentar,
      datosGuardadosLocalmente: true,
      detalleTecnicoOculto: error.toString(),
    );
  }
  if (raw.contains('timeout') ||
      raw.contains('timed out') ||
      httpStatus == 408) {
    return ErrorSync(
      codigo: 'tiempo_agotado',
      tipo: TipoErrorSync.transitorio,
      mensaje: 'La conexión está muy lenta.',
      accionTexto: 'Inténtalo de nuevo en un lugar con mejor señal.',
      accionBoton: AccionBoton.reintentar,
      datosGuardadosLocalmente: true,
      detalleTecnicoOculto: error.toString(),
    );
  }

  // 7. HTTP por código
  if (httpStatus != null) {
    if (httpStatus == 429) {
      return ErrorSync(
        codigo: 'servidor_ocupado',
        tipo: TipoErrorSync.transitorio,
        mensaje: 'El sistema está muy ocupado ahora mismo.',
        accionTexto: 'Espera unos minutos y vuelve a intentarlo.',
        accionBoton: AccionBoton.esperar,
        datosGuardadosLocalmente: true,
        detalleTecnicoOculto: 'HTTP 429',
      );
    }
    if (httpStatus >= 500) {
      return ErrorSync(
        codigo: 'servidor_caido',
        tipo: TipoErrorSync.transitorio,
        mensaje: 'El servidor tiene un problema temporal.',
        accionTexto: 'Tus datos están guardados. Se reintentará solo.',
        accionBoton: AccionBoton.reintentar,
        datosGuardadosLocalmente: true,
        detalleTecnicoOculto: 'HTTP $httpStatus',
      );
    }
    if (httpStatus == 409 || raw.contains('idempotencia')) {
      return ErrorSync(
        codigo: 'conflicto_edicion',
        tipo: TipoErrorSync.conflicto,
        mensaje: 'Esta información se cambió desde otro teléfono.',
        accionTexto: 'Revisa los datos actuales antes de guardar de nuevo.',
        accionBoton: AccionBoton.refrescarTodo,
        datosGuardadosLocalmente: false,
        detalleTecnicoOculto: 'HTTP 409',
      );
    }
    if (httpStatus == 422 || raw.contains('validación') || raw.contains('inválid')) {
      return ErrorSync(
        codigo: 'validacion_negocio',
        tipo: TipoErrorSync.validacion,
        mensaje: 'Los datos no son válidos.',
        accionTexto: 'Corrige los campos marcados e inténtalo de nuevo.',
        accionBoton: AccionBoton.corregir,
        datosGuardadosLocalmente: false,
        detalleTecnicoOculto: 'HTTP $httpStatus',
      );
    }
    if (httpStatus == 404) {
      return ErrorSync(
        codigo: 'no_encontrado',
        tipo: TipoErrorSync.permanente,
        mensaje: 'No se encontró esta información en el servidor.',
        accionTexto: 'Toca el botón para actualizar todos los datos.',
        accionBoton: AccionBoton.refrescarTodo,
        datosGuardadosLocalmente: true,
        detalleTecnicoOculto: 'HTTP 404',
      );
    }
  }

  // 8. Fallback seguro: nunca mostrar el error crudo.
  // No afirmar que los datos están guardados sin confirmación.
  return ErrorSync(
    codigo: 'desconocido',
    tipo: TipoErrorSync.transitorio,
    mensaje: 'Hubo un problema al sincronizar.',
    accionTexto: 'Inténtalo de nuevo. Si el problema sigue, contacta al soporte.',
    accionBoton: AccionBoton.reintentar,
    datosGuardadosLocalmente: false,
    detalleTecnicoOculto: error.toString(),
  );
}

/// Clasifica un error (compatibilidad con código existente).
/// Usa traducirErrorSync internamente.
ErrorSync clasificarError(Object e, {int? httpStatus}) =>
    traducirErrorSync(e, httpStatus: httpStatus);

/// v1.8.0: frase corta y legible para un error CRUDO ya guardado
/// como texto (p.ej. el `wm_err_<tabla>` que pinta la pantalla de
/// Diagnóstico). [traducirErrorSync] trabaja sobre excepciones
/// vivas y produce mensaje + acción para diálogos; aquí el dato es
/// un String persistido (posiblemente truncado a 200 caracteres) y
/// solo hace falta una frase de estado que el dueño entienda de un
/// vistazo. Función pura: el texto crudo NUNCA se devuelve — si no
/// se reconoce la causa, cae al genérico.
String resumenErrorDiagnostico(String crudo) {
  final raw = crudo.toLowerCase();
  // 1. Sin conexión con el servidor: red caída, DNS, TLS, rechazo.
  if (raw.contains('socketexception') ||
      raw.contains('failed host lookup') ||
      raw.contains('network is unreachable') ||
      raw.contains('connection refused') ||
      raw.contains('connection reset') ||
      raw.contains('handshakeexception') ||
      raw.contains('certificate')) {
    return 'sin conexión con el servidor';
  }
  // 2. El servidor tardó demasiado en responder.
  if (raw.contains('timeoutexception') ||
      raw.contains('timed out') ||
      raw.contains('timeout')) {
    return 'el servidor tardó demasiado en responder';
  }
  // 3. El servidor rechazó el acceso (401/403).
  if (RegExp(r'\b40[13]\b').hasMatch(raw)) {
    return 'el servidor rechazó el acceso';
  }
  // 4. Error interno del servidor (500/502/503).
  if (RegExp(r'\b50[023]\b').hasMatch(raw)) {
    return 'error interno del servidor';
  }
  // 5. Genérico: sin volcar el texto técnico.
  return 'error de sincronización';
}

/// 1.28 (M1-C5): explicación EN LENGUAJE LLANO de por qué
/// una operación de la cola está como está y qué se puede
/// hacer con ella. Función PURA y única: la usan la fila de
/// la cola, el bloque de bloqueadas y el detalle de la op,
/// para que las tres superficies digan lo mismo (antes cada
/// una traducía por su cuenta y la fila de bloqueadas
/// enseñaba el texto técnico crudo).
///
/// El texto CRUDO nunca se devuelve como motivo salvo que
/// sea un motivo de negocio que el propio servidor escribió
/// en español (sin marcas de excepción ni códigos HTTP):
/// esos motivos SÍ son el dato que el dueño necesita.
({String motivo, String accion}) explicacionOp({
  required String estado,
  String error = '',
  String codigoError = '',
  bool? hayInternet,
}) {
  final err = error.trim();
  final primeraLinea = err.split('\n').first.trim();
  switch (estado) {
    case 'pendiente':
      return (
        motivo: 'Todavía no se ha enviado.',
        accion: 'Se subirá sola cuando haya conexión.',
      );
    case 'enviada':
      return (
        motivo: 'Se envió y el servidor aún no la confirma.',
        accion: 'Se confirma sola en la próxima sincronización.',
      );
    case 'aplicada':
      return (motivo: 'El servidor ya la confirmó.', accion: '');
    case 'error':
      if (err.isEmpty) {
        return (
          motivo: 'Falló el último intento de envío.',
          accion: 'Se reintenta sola; también puedes reintentarla '
              'con el botón de la fila.',
        );
      }
      final t = traducirErrorSync(err);
      // Corrección A4-D2 (auditorías 1.28): el contrafuerte
      // que el ciclo SÍ aplica desde la v1.2.5
      // (_describeErrorVisible en sync.dart): si la op
      // quedó clasificada «sin conexión» pero el teléfono
      // SÍ tiene internet, lo que no responde es el
      // SERVIDOR — decir «No hay conexión a internet» es
      // falso y es el síntoma que Jc reportó en campo el
      // 2026-11-05 («operaciones pendientes dicen que no
      // hay internet» con WhatsApp funcionando). Sin dato
      // de internet (null), se conserva la traducción.
      if (t.codigo == 'sin_conexion' && hayInternet == true) {
        return (
          motivo: 'No se pudo contactar el servidor.',
          accion: 'Tus cambios están guardados en el teléfono.',
        );
      }
      return (motivo: t.mensaje, accion: t.accionTexto);
    case 'rechazada':
    case 'necesita_revision':
      final esRevision = estado == 'necesita_revision';
      final accion = esRevision
          ? 'La decide el dueño: reintentarla o descartarla.'
          : 'Puedes reintentarla o descartarla con los botones '
              'de la fila. Si el motivo es un dato incorrecto, '
              'corrígelo antes de reintentar.';
      if (err.contains('cliente no existe')) {
        return (
          motivo: 'El cliente ya no existe en el servidor '
              '(fue eliminado).',
          accion: 'No es necesario reintentar: descártala.',
        );
      }
      if (err.contains('HTTP 409') ||
          codigoError.toUpperCase().contains('DUPLICAD')) {
        return (
          motivo: 'La operación ya fue registrada (duplicada).',
          accion: 'No es necesario reintentar: descártala.',
        );
      }
      if (err.contains('HTTP 400')) {
        return (
          motivo:
              'El servidor rechazó la operación por datos inválidos.',
          accion: accion,
        );
      }
      // Motivo de negocio del servidor (español, sin marcas
      // técnicas): es el dato útil, se muestra tal cual.
      final pareceTecnico = err.contains('Exception') ||
          err.contains('HTTP') ||
          err.contains('Socket') ||
          err.contains('timeout') ||
          err.contains('Timeout');
      if (primeraLinea.isNotEmpty &&
          !pareceTecnico &&
          primeraLinea.length <= 200) {
        return (motivo: primeraLinea, accion: accion);
      }
      return (
        motivo: esRevision
            ? 'El servidor la dejó apartada para revisión.'
            : 'El servidor rechazó esta operación.',
        accion: accion,
      );
    default:
      return (motivo: 'Estado: $estado.', accion: '');
  }
}

/// Calcula el backoff con jitter para un reintento.
Duration backoffReintento(int intentos) {
  const baseSeg = 30;
  const topeSeg = 300;
  var seg = baseSeg * (1 << (intentos - 1).clamp(0, 4));
  if (seg > topeSeg) seg = topeSeg;
  final jitter = ((intentos * 37) % 41) - 20;
  seg = (seg * (100 + jitter) / 100).round();
  return Duration(seconds: seg.clamp(10, topeSeg));
}

const maxIntentosTransitorio = 25;

/// v1.2.9+46 (Gemini): función pura para la UI. Traduce cualquier error
/// a lenguaje natural usando traducirErrorSync. Si no se reconoce,
/// sugiere exportar la bitácora.
String describirError(Object error) {
  try {
    final e = traducirErrorSync(error);
    var msg = e.mensaje;
    if (e.accionTexto.isNotEmpty) msg += ' ${e.accionTexto}';
    return msg;
  } catch (_) {
    return 'Hubo un problema al sincronizar. Exporta la bitácora '
        'desde Ajustes y envíala para revisión.';
  }
}

/// Pieza añadida de la oleada (incidencia de campo de Jc,
/// 2026-11-09): el contrafuerte A4-D2 aplicado a la BANDA
/// de la corrida (la cabecera «Falló la última
/// sincronización» de la pantalla de Sincronización). El
/// error guardado de la corrida se clasificó al capturarse
/// — quizá en el mismo apagón de transporte que tumbó
/// también la comprobación de internet de ese instante —
/// y la banda lo re-pintaba crudo: «No hay conexión a
/// internet» con 4G activo y WhatsApp funcionando, cuando
/// lo que falló fue contactar el SERVIDOR. Si el error se
/// clasifica «sin conexión» y AHORA hay internet
/// confirmado, la banda dice la verdad de ahora. Sin dato
/// de internet (null) se conserva la traducción. Función
/// pura, el mismo patrón que el motivo de las ops (A4-D2).
String describirErrorCorrida(Object error, {bool? hayInternet}) {
  try {
    final t = traducirErrorSync(error);
    if (t.codigo == 'sin_conexion' && hayInternet == true) {
      return 'No se pudo contactar el servidor. '
          'Tus cambios están guardados en el teléfono.';
    }
  } catch (_) {}
  return describirError(error);
}

/// 1.30 Oleada 8 (ítem añadido «Errores amables» + GEN-09):
/// traduce CUALQUIER error a UN texto breve y en sencillo para
/// enseñar en un snack o un campo de error de pantalla. Es el
/// traductor genérico `Object → texto de pantalla`: NO sustituye
/// a [traducirErrorSync] (que clasifica errores DEL pipeline de
/// sync, con la regla de la verdad sobre datos guardados) ni
/// delega en `errorSyncLegible` (su fallback devuelve el texto
/// crudo recortado, y aquí la garantía es la contraria: NADA
/// técnico llega a la UI jamás). La excepción cruda la registra
/// quien llama, en la bitácora interna (AppLog), con su pantalla
/// y acción; a la UI solo llega lo que devuelve esta función.
///
/// Tabla (propuesta_130 §9.2):
/// - TimeoutException → [enTimeout] del llamador si lo pasa; si
///   no, «Sin respuesta del servidor. Inténtalo de nuevo.»
/// - Red (SocketException, ClientException, host lookup y demás
///   cortes de transporte) → «Sin conexión a internet. Revisa
///   tus datos o el Wi-Fi.»
/// - PostgrestException código P0001 (validación de negocio de
///   nuestras funciones SQL; el mensaje ya nace en español) →
///   su mensaje, tal cual.
/// - PostgrestException, cualquier otro código → «El servidor
///   no aceptó la operación. Inténtalo de nuevo.»
/// - Mensaje de negocio curado (fila GEN-09, misma filosofía que
///   P0001): un StateError o un Exception genérico cuyo texto —
///   sin el prefijo «Exception: »/«Bad state: » — ya nace en
///   español para el usuario y no trae marcadores técnicos pasa
///   tal cual (es el canal normal de los rechazos locales:
///   adelantos, caja, solicitudes). Con cualquier marcador
///   técnico, cae al genérico.
/// - Cualquier otro → «Algo salió mal. Inténtalo de nuevo.»
///
/// PostgrestException se detecta sin importar supabase en este
/// módulo (Dart puro; lo importan localdb/sync): nombre del tipo
/// en runtime y lectura dinámica de code/message — el mismo
/// espíritu con el que traducirErrorSync clasifica por contenido
/// sin importar los paquetes de origen.
String mensajeErrorAmable(Object error, {String? enTimeout}) {
  if (error is TimeoutException) {
    return enTimeout ?? 'Sin respuesta del servidor. Inténtalo de nuevo.';
  }
  if (error.runtimeType.toString() == 'PostgrestException') {
    final dyn = error as dynamic;
    final code = dyn.code?.toString() ?? '';
    final message = (dyn.message?.toString() ?? '').trim();
    if (code == 'P0001' && message.isNotEmpty) return message;
    return 'El servidor no aceptó la operación. Inténtalo de nuevo.';
  }
  final raw = error.toString().toLowerCase();
  if (error is SocketException ||
      error is http.ClientException ||
      raw.contains('failed host lookup') ||
      raw.contains('socketexception') ||
      raw.contains('clientexception') ||
      raw.contains('handshakeexception') ||
      raw.contains('network is unreachable') ||
      raw.contains('connection closed') ||
      raw.contains('connection reset')) {
    return 'Sin conexión a internet. Revisa tus datos o el Wi-Fi.';
  }
  // Mensaje de negocio curado (GEN-09): StateError trae su texto
  // en .message; un Exception genérico lo trae en el toString
  // tras el prefijo «Exception: ». Solo pasa si el texto es
  // limpio: sin marcadores técnicos, no se pinta.
  String? candidato;
  if (error is StateError) {
    candidato = error.message.trim();
  } else if (error is Exception) {
    var t = error.toString().trim();
    if (t.startsWith('Exception: ')) t = t.substring(11).trim();
    candidato = t;
  }
  if (candidato != null && _esTextoDeNegocioLimpio(candidato)) {
    return candidato;
  }
  return 'Algo salió mal. Inténtalo de nuevo.';
}

/// ¿Es [t] un texto de negocio redactado para el usuario (y no
/// un resto técnico)? Conservador a propósito: ante la duda, no
/// pasa (manda el genérico de mensajeErrorAmable).
bool _esTextoDeNegocioLimpio(String t) {
  if (t.isEmpty || t.length > 200) return false;
  final low = t.toLowerCase();
  const marcadores = [
    'exception',
    'bad state',
    'null check',
    'sqflite',
    'postgrest',
    'assertion',
    'subtype',
    'stack',
    'http',
    '://',
    'future not completed',
    'timeout',
    'errno',
    'os error',
  ];
  for (final m in marcadores) {
    if (low.contains(m)) return false;
  }
  return true;
}
