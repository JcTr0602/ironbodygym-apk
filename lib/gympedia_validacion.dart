import 'dart:convert';

/// v1.4.4 (v33): validación local de artículos GymPedia, espejo de
/// `_validar_articulo_gympedia` del servidor (los mismos topes, en
/// BYTES UTF-8, no en caracteres). El servidor sigue siendo la
/// autoridad: esto solo evita encolar una op condenada al rechazo.
class GympediaValidacion {
  static const List<String> categorias = [
    'empieza-aqui',
    'entrenamiento',
    'nutricion',
    'suplementos',
    'descanso',
    'mitos',
    'tecnica',
  ];

  static const List<String> sellos = ['verde', 'amarillo', 'gris'];

  static const Map<String, String> nombreCategoria = {
    'empieza-aqui': 'Empieza aquí',
    'entrenamiento': 'Entrenamiento',
    'nutricion': 'Nutrición',
    'suplementos': 'Suplementos',
    'descanso': 'Descanso y recuperación',
    'mitos': 'Mitos',
    'tecnica': 'Técnica de ejercicios',
  };

  static final RegExp _reSlug = RegExp(r'^[a-z0-9]+(-[a-z0-9]+)*$');

  static int bytes(String s) => utf8.encode(s).length;

  static bool slugValido(String slug) =>
      slug.isNotEmpty && slug.length <= 80 && _reSlug.hasMatch(slug);

  /// Valida un artículo con la forma del payload de publicación.
  /// [slugsPublicados] = ids presentes en el espejo (para related_ids,
  /// igual que el servidor valida contra los publicados en gym.db).
  /// Devuelve errores legibles; lista vacía = válido.
  static List<String> validar(Map<String, dynamic> a,
      {required Set<String> slugsPublicados}) {
    final errores = <String>[];
    final slug = '${a['id'] ?? ''}';
    if (!slugValido(slug)) {
      errores.add(
          'El identificador (slug) debe ser minúsculas, números y guiones, sin espacios ni tildes (máx. 80).');
    }
    final titulo = '${a['titulo'] ?? ''}';
    if (titulo.trim().isEmpty) errores.add('Falta el título.');
    if (bytes(titulo) > 300) errores.add('El título supera los 300 bytes.');
    if (!categorias.contains('${a['categoria'] ?? ''}')) {
      errores.add('Categoría no válida.');
    }
    final esencial = '${a['lo_esencial'] ?? ''}';
    if (esencial.trim().isEmpty) errores.add('Falta «Lo esencial».');
    if (bytes(esencial) > 500) {
      errores.add('«Lo esencial» supera los 500 bytes.');
    }
    final explicacion = '${a['explicacion_md'] ?? ''}';
    if (explicacion.trim().isEmpty) errores.add('Falta la explicación.');
    if (bytes(explicacion) > 8192) {
      errores.add('La explicación supera los 8192 bytes.');
    }
    for (final campo in ['pasos', 'errores']) {
      final lista = a[campo];
      // Tipos estrictos (panel 2026-10-21), espejo del servidor:
      // ausente = lista vacía (válido); presente con un tipo raro
      // es un error explícito, no un pase en silencio.
      if (lista == null) continue;
      if (lista is! List) {
        errores.add('«$campo» debe ser una lista.');
        continue;
      }
      if (lista.length > 10) {
        errores.add('«$campo» admite como máximo 10 elementos.');
      }
      for (final item in lista) {
        if (item is! String) {
          errores.add('Cada elemento de «$campo» debe ser texto.');
          break;
        }
        if (bytes(item) > 300) {
          errores.add('Un elemento de «$campo» supera los 300 bytes.');
          break;
        }
      }
    }
    final refs = a['referencias'];
    if (refs is! List || refs.length < 2 || refs.length > 6) {
      errores.add('Las referencias deben ser entre 2 y 6.');
    } else {
      for (final r in refs) {
        if (r is! Map ||
            '${r['titulo'] ?? ''}'.trim().isEmpty ||
            '${r['fuente'] ?? ''}'.trim().isEmpty ||
            '${r['url'] ?? ''}'.trim().isEmpty) {
          errores.add('Cada referencia necesita título, fuente y enlace.');
          break;
        }
        final url = '${r['url']}';
        if (!url.startsWith('http://') && !url.startsWith('https://')) {
          errores.add('Los enlaces de referencias deben empezar por http.');
          break;
        }
      }
    }
    if (!sellos.contains('${a['sello'] ?? ''}')) {
      errores.add('Sello no válido.');
    }
    final rel = a['related_ids'];
    if (rel != null && rel is! List) {
      errores.add('Los artículos relacionados deben ser una lista.');
    } else if (rel is List) {
      if (rel.length > 6) {
        errores.add('Como máximo 6 artículos relacionados.');
      }
      final vistos = <String>{};
      for (final r in rel) {
        final s = '$r';
        if (!slugValido(s)) {
          errores.add('Relacionado con formato no válido: $s');
        } else if (s == slug) {
          errores.add('Un artículo no puede relacionarse consigo mismo.');
        } else if (!vistos.add(s)) {
          errores.add('Relacionado repetido: $s');
        } else if (!slugsPublicados.contains(s)) {
          errores.add('El relacionado «$s» no está publicado.');
        }
      }
    }
    try {
      if (bytes(jsonEncode(a)) > 12288) {
        errores.add('El artículo completo supera los 12288 bytes.');
      }
    } catch (_) {
      // Serializar es parte de validar (panel): si no se puede
      // codificar, el artículo no es publicable.
      errores.add('El artículo no se pudo serializar.');
    }
    return errores;
  }
}
