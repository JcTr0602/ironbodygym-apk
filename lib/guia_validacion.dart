import 'dart:convert';

/// Biblioteca / Guía (v47): validación local de fichas, espejo de
/// `_validar_ficha_guia` del servidor (los mismos topes, en BYTES
/// UTF-8, no en caracteres; diseño Fase 1 §2.2, total 16.384
/// aprobado P3, series 1–10 fijado P8). El servidor sigue siendo
/// la autoridad: esto solo evita encolar una op condenada al
/// rechazo. El editor muestra TODOS los errores juntos.
class GuiaValidacion {
  static const List<String> siluetas = [
    'pecho',
    'espalda',
    'piernas',
    'gluteos',
    'hombros',
    'brazos',
    'core',
  ];

  static const Map<String, String> nombreSilueta = {
    'pecho': 'Pecho',
    'espalda': 'Espalda',
    'piernas': 'Piernas',
    'gluteos': 'Glúteos',
    'hombros': 'Hombros',
    'brazos': 'Brazos',
    'core': 'Core',
  };

  static final RegExp _reSlug = RegExp(r'^[a-z0-9]+(-[a-z0-9]+)*$');

  static int bytes(String s) => utf8.encode(s).length;

  static bool slugValido(String slug) =>
      slug.isNotEmpty && slug.length <= 80 && _reSlug.hasMatch(slug);

  static void _listaTextos(List<String> errores, dynamic lista,
      String campo, int maxb, int minimo, int maximo) {
    if (lista == null) {
      if (minimo > 0) errores.add('«$campo» debe tener al menos $minimo.');
      return;
    }
    if (lista is! List) {
      errores.add('«$campo» debe ser una lista.');
      return;
    }
    if (lista.length < minimo || lista.length > maximo) {
      errores.add('«$campo» debe tener entre $minimo y $maximo.');
      return;
    }
    for (final item in lista) {
      if (item is! String || item.trim().isEmpty) {
        errores.add('Cada elemento de «$campo» debe ser texto.');
        break;
      }
      if (bytes(item) > maxb) {
        errores.add('Un elemento de «$campo» supera los $maxb bytes.');
        break;
      }
    }
  }

  static void _texto(List<String> errores, dynamic valor, String campo,
      int maxb, bool obligatorio) {
    if (valor == null) {
      if (obligatorio) errores.add('Falta «$campo».');
      return;
    }
    if (valor is! String) {
      errores.add('«$campo» debe ser texto.');
      return;
    }
    if (obligatorio && valor.trim().isEmpty) {
      errores.add('Falta «$campo».');
      return;
    }
    if (bytes(valor) > maxb) {
      errores.add('«$campo» supera los $maxb bytes.');
    }
  }

  /// Valida una ficha con la forma del payload de publicación.
  /// [equiposVigentes] = equipoIds activos de `guia_equipos` (el
  /// servidor valida contra la lista vigente en gym.db).
  /// Devuelve errores legibles; lista vacía = válida.
  static List<String> validar(Map<String, dynamic> a,
      {required Set<String> equiposVigentes}) {
    final errores = <String>[];
    final slug = '${a['id'] ?? ''}';
    if (!slugValido(slug)) {
      errores.add(
          'El identificador (slug) debe ser minúsculas, números y guiones, sin espacios ni tildes (máx. 80).');
    }
    final titulo = '${a['titulo'] ?? ''}';
    if (titulo.trim().isEmpty) errores.add('Falta el título.');
    if (bytes(titulo) > 300) errores.add('El título supera los 300 bytes.');
    final sinon = a['sinonimos'];
    if (sinon != null) {
      if (sinon is! List) {
        errores.add('Los sinónimos deben ser una lista.');
      } else {
        if (sinon.length > 6) {
          errores.add('Como máximo 6 sinónimos.');
        }
        final vistos = <String>{};
        for (final s in sinon) {
          if (s is! String || s.trim().isEmpty) {
            errores.add('Cada sinónimo debe ser texto.');
            break;
          }
          if (bytes(s) > 40) {
            errores.add('Un sinónimo supera los 40 bytes.');
            break;
          }
          final t = s.trim();
          if (t == titulo.trim()) {
            errores.add('Un sinónimo no puede ser el propio título.');
            break;
          }
          if (!vistos.add(t)) {
            errores.add('Sinónimo repetido: $t');
            break;
          }
        }
      }
    }
    final equipoId = '${a['equipoId'] ?? ''}';
    if (!slugValido(equipoId)) {
      errores.add('Equipo no válido.');
    } else if (!equiposVigentes.contains(equipoId)) {
      errores.add('El equipo «$equipoId» no está en la lista vigente.');
    }
    _listaTextos(errores, a['musculosPrincipales'],
        'músculos principales', 50, 1, 6);
    _listaTextos(errores, a['musculosSecundarios'],
        'músculos secundarios', 50, 0, 6);
    if (!siluetas.contains('${a['siluetaId'] ?? ''}')) {
      errores.add('Silueta no válida.');
    }
    if (a['esencial'] is! bool) {
      errores.add('«Esencial» debe ser sí o no.');
    }
    final vr = a['vistaRapida'];
    if (vr is! Map) {
      errores.add('Falta la vista rápida.');
    } else {
      _texto(errores, vr['ajusteMaquina'], 'ajuste de máquina', 500, true);
      _listaTextos(errores, vr['claves'], 'claves', 300, 1, 2);
      _texto(errores, vr['advertenciaClave'], 'advertencia clave', 500,
          true);
    }
    final dos = a['dosificacion'];
    if (dos is! Map) {
      errores.add('Falta la dosificación.');
    } else {
      final series = dos['series'];
      if (series is! int || series < 1 || series > 10) {
        errores.add('Las series deben ser un número entre 1 y 10.');
      }
      _texto(errores, dos['repeticiones'], 'repeticiones', 20, true);
      _texto(errores, dos['descanso'], 'descanso', 20, true);
      _texto(errores, dos['pesoInicial'], 'peso inicial', 150, true);
    }
    _listaTextos(errores, a['ejecutar'], 'pasos de ejecución', 300, 1, 12);
    _listaTextos(errores, a['errores'], 'errores', 300, 1, 12);
    final seg = a['seguridad'];
    if (seg is! Map) {
      errores.add('Falta la seguridad.');
    } else {
      _texto(errores, seg['senalParada'], 'señal de parada', 500, true);
      _texto(
          errores, seg['autoVerificacion'], 'auto-verificación', 500, true);
    }
    final regresion = a['regresion'];
    if (regresion != null && regresion is! String) {
      errores.add('La regresión debe ser texto.');
    } else if (regresion is String && bytes(regresion) > 150) {
      errores.add('La regresión supera los 150 bytes.');
    }
    // La regresión vacía NO es error en la v1 (D8: aviso en el
    // editor, obligatoria desde la segunda vuelta).
    try {
      // Medido sobre el documento del editor (sin nivel/revisión
      // del servidor: ~60 bytes menos que el guardado; el tope
      // tiene holgura de sobra: la ficha mayor real mide 2.173).
      if (bytes(jsonEncode(a)) > 16384) {
        errores.add('La ficha completa supera los 16384 bytes.');
      }
    } catch (_) {
      errores.add('La ficha no se pudo serializar.');
    }
    return errores;
  }
}
