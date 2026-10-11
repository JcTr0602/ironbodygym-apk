/// v1.2.5 Fase 2 (D15/D16): clasificación y traducción de errores de sync.
///
/// - Los errores se clasifican PRIMERO (transitorio | permanente | auth |
///   validación) y después se decide: reintentar con backoff, marcar
///   'necesita_revision', o pedir re-autenticación.
/// - Los mensajes usan códigos estables, no texto del error: el mismo fallo
///   siempre muestra el mismo mensaje y la misma acción.
/// - Sin detalles internos en el mensaje visible.
library;

/// Categoría del error: decide el tratamiento.
enum TipoErrorSync {
  /// Reintentable con backoff (timeout, sin red, 5xx, 429).
  transitorio,

  /// No se arregla reintentando (400, 404, payload inválido).
  permanente,

  /// Requiere re-autenticación (401, sesión vencida).
  auth,

  /// El servidor rechazó el contenido (validación de negocio).
  validacion,
}

/// Error clasificado con mensaje humano y acción sugerida.
class ErrorSync {
  /// Código estable, ej. 'sin_conexion', 'timeout', 'servidor_error'.
  final String codigo;
  final TipoErrorSync tipo;

  /// Mensaje en lenguaje humano (sin tecnicismos ni detalles internos).
  final String mensaje;

  /// Qué puede hacer el usuario, ej. 'Reintentar', 'Revisar', 'Entrar de nuevo'.
  final String accion;

  const ErrorSync({
    required this.codigo,
    required this.tipo,
    required this.mensaje,
    required this.accion,
  });
}

/// Clasifica un error de red/HTTP en un ErrorSync.
ErrorSync clasificarError(Object e, {int? httpStatus}) {
  final texto = e.toString().toLowerCase();

  // Auth primero: 401 o sesión vencida.
  if (httpStatus == 401 ||
      texto.contains('sesion vencida') ||
      texto.contains('sessionexpired') ||
      texto.contains('jwt')) {
    return const ErrorSync(
      codigo: 'sesion_vencida',
      tipo: TipoErrorSync.auth,
      mensaje: 'Tu sesión venció. Entra de nuevo para seguir sincronizando.',
      accion: 'Entrar de nuevo',
    );
  }
  if (httpStatus == 403) {
    return const ErrorSync(
      codigo: 'no_autorizado',
      tipo: TipoErrorSync.auth,
      mensaje: 'No tienes permiso para esta operación.',
      accion: 'Revisar',
    );
  }

  // Sin conexión / timeout.
  if (texto.contains('socketexception') ||
      texto.contains('network is unreachable') ||
      texto.contains('failed host lookup') ||
      texto.contains('sin internet') ||
      texto.contains('sin conexión')) {
    return const ErrorSync(
      codigo: 'sin_conexion',
      tipo: TipoErrorSync.transitorio,
      mensaje: 'Sin conexión. Tus cambios están guardados en este teléfono.',
      accion: 'Reintentar',
    );
  }
  if (texto.contains('timeout') || texto.contains('timed out')) {
    return const ErrorSync(
      codigo: 'timeout',
      tipo: TipoErrorSync.transitorio,
      mensaje: 'El servidor tardó demasiado en responder. Se reintentará.',
      accion: 'Reintentar',
    );
  }

  // HTTP por código.
  if (httpStatus != null) {
    if (httpStatus == 429) {
      return const ErrorSync(
        codigo: 'limite_excedido',
        tipo: TipoErrorSync.transitorio,
        mensaje: 'Demasiadas peticiones. Se reintentará en unos minutos.',
        accion: 'Esperar',
      );
    }
    if (httpStatus >= 500) {
      return const ErrorSync(
        codigo: 'servidor_error',
        tipo: TipoErrorSync.transitorio,
        mensaje: 'El servidor falló. Tus cambios están a salvo, se reintentará.',
        accion: 'Reintentar',
      );
    }
    if (httpStatus == 404) {
      return const ErrorSync(
        codigo: 'no_encontrado',
        tipo: TipoErrorSync.permanente,
        mensaje: 'El servidor no reconoce esta operación. Necesita revisión.',
        accion: 'Revisar',
      );
    }
    if (httpStatus >= 400) {
      return const ErrorSync(
        codigo: 'peticion_invalida',
        tipo: TipoErrorSync.permanente,
        mensaje: 'Hay un problema con esta operación. Necesita revisión.',
        accion: 'Revisar',
      );
    }
  }

  // Rechazo del servidor con mensaje de validación.
  if (texto.contains('rechazada') ||
      texto.contains('validación') ||
      texto.contains('inválid')) {
    return const ErrorSync(
      codigo: 'validacion',
      tipo: TipoErrorSync.validacion,
      mensaje: 'El servidor rechazó esta operación. Necesita revisión.',
      accion: 'Revisar',
    );
  }

  // Conflicto de idempotencia.
  if (texto.contains('idempotencia')) {
    return const ErrorSync(
      codigo: 'conflicto',
      tipo: TipoErrorSync.permanente,
      mensaje: 'Esta operación cambió en otro lugar. Necesita revisión.',
      accion: 'Revisar',
    );
  }

  return const ErrorSync(
    codigo: 'desconocido',
    tipo: TipoErrorSync.transitorio,
    mensaje: 'Algo falló al sincronizar. Se reintentará automáticamente.',
    accion: 'Reintentar',
  );
}

/// Calcula el backoff con jitter para un reintento.
///
/// base 30s, duplica por intento, tope 5 min, ±20% jitter.
/// v1.2.5 (D14): acotado, solo transitorios, un único ciclo.
Duration backoffReintento(int intentos) {
  const baseSeg = 30;
  const topeSeg = 300; // 5 min
  var seg = baseSeg * (1 << (intentos - 1).clamp(0, 4));
  if (seg > topeSeg) seg = topeSeg;
  // jitter ±20% determinista por intento (sin Random global).
  final jitter = ((intentos * 37) % 41) - 20; // -20..+20
  seg = (seg * (100 + jitter) / 100).round();
  return Duration(seconds: seg.clamp(10, topeSeg));
}

/// Intentos máximos de transitorios antes de 'necesita_revision'.
const maxIntentosTransitorio = 5;
