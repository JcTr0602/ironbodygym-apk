/// Ítem 13 de la update post-1.8.0 (diseño de Argón, 🟢): todo selector
/// de productos muestra «Nombre · Categoría» — el catálogo tiene
/// productos de nombres parecidos en categorías distintas (C4 en
/// Pre Entrenos vs Cellucor en Creatinas) y elegir por el nombre solo
/// ya causó un bote abierto por error (2026-10-23). Sin categoría
/// cargada se muestra solo el nombre, sin separador huérfano.

/// Etiqueta compuesta de un producto: «C4 · Pre Entrenos».
/// Con categoría nula o vacía devuelve solo el nombre.
/// 1.36 H-B3 (136-760): el nombre se recorta; un nombre vacío
/// o de espacios no deja el separador huérfano « · Categoría»
/// — con categoría se muestra solo la categoría y sin ella,
/// «(Sin nombre)».
String etiquetaProducto(String nombre, String? categoria) {
  final nom = nombre.trim();
  final cat = (categoria ?? '').trim();
  if (nom.isEmpty) return cat.isEmpty ? '(Sin nombre)' : cat;
  if (cat.isEmpty) return nom;
  return '$nom · $cat';
}

/// Mapa id → nombre de categoría desde las filas del espejo
/// `categorias_suplemento` (cada fila trae `id` y `nombre`).
/// 1.36 H-B3 (136-760): con [marcarInactivas], las categorías
/// inactivas se nombran «Nombre (inactiva)» — los selectores
/// que usan el mapa no ofrecen una categoría muerta como si
/// estuviera viva (la lectura de activa/activo es tolerante).
Map<int, String> mapaCategoriasSuplemento(
    List<Map<String, dynamic>> categorias,
    {bool marcarInactivas = false}) {
  final mapa = <int, String>{};
  for (final c in categorias) {
    final id = (c['id'] as num?)?.toInt();
    final nombre = '${c['nombre'] ?? ''}'.trim();
    if (id == null || nombre.isEmpty) continue;
    var activa = true;
    final v = c['activa'] ?? c['activo'];
    if (v is bool) activa = v;
    if (v is num) activa = v != 0;
    if (v is String) {
      final t = v.trim().toLowerCase();
      if (t == '0' || t == 'false') activa = false;
    }
    mapa[id] =
        marcarInactivas && !activa ? '$nombre (inactiva)' : nombre;
  }
  return mapa;
}

/// Nombre de la categoría de un suplemento (fila del espejo
/// `suplementos`, con `categoria_id`), o null si no resuelve.
String? categoriaDeSuplemento(
    Map<String, dynamic> suplemento, Map<int, String> categorias) {
  final id = (suplemento['categoria_id'] as num?)?.toInt();
  return id == null ? null : categorias[id];
}

/// Etiqueta compuesta de una fila del espejo `suplementos`.
String etiquetaDeSuplemento(
    Map<String, dynamic> suplemento, Map<int, String> categorias) {
  return etiquetaProducto(
    '${suplemento['nombre'] ?? ''}',
    categoriaDeSuplemento(suplemento, categorias),
  );
}

/// 1.36 H-B3 (136-760): normalización de búsqueda — minúsculas
/// sin diacríticos y el separador «·» como espacio, para que
/// «proteina» encuentre «Proteína» y «c4 pre» cruce el
/// separador de la etiqueta compuesta.
String normalizarBusquedaProducto(String texto) {
  var t = texto.toLowerCase().replaceAll('·', ' ');
  const acentos = {
    'á': 'a', 'à': 'a', 'ä': 'a', 'â': 'a',
    'é': 'e', 'è': 'e', 'ë': 'e', 'ê': 'e',
    'í': 'i', 'ì': 'i', 'ï': 'i', 'î': 'i',
    'ó': 'o', 'ò': 'o', 'ö': 'o', 'ô': 'o',
    'ú': 'u', 'ù': 'u', 'ü': 'u', 'û': 'u',
    'ñ': 'n', 'ç': 'c',
  };
  acentos.forEach((k, v) => t = t.replaceAll(k, v));
  return t.replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// El buscador de los selectores filtra sobre la cadena COMPUESTA
/// (ajuste de Argón al ítem 13): «c4» encuentra el producto por su
/// nombre y «creatinas» encuentra todos los de esa categoría.
bool coincideBusquedaProducto(
    String consulta, String nombre, String? categoria) {
  final q = normalizarBusquedaProducto(consulta);
  if (q.isEmpty) return true;
  return normalizarBusquedaProducto(
          etiquetaProducto(nombre, categoria))
      .contains(q);
}

/// Filtro de disponibilidad del catálogo (14/25, PURO):
/// 'todos' | 'con_stock' | 'bajo' | 'agotado'. «Bajo» usa la
/// misma regla que el chip de la tarjeta: 0 < stock <= umbral
/// (umbral_stock del producto, 3 por defecto).
bool coincideFiltroStock(Map<String, dynamic> s, String filtro) {
  final stock = (s['stock'] as num?)?.toInt() ?? 0;
  switch (filtro) {
    case 'con_stock':
      return stock > 0;
    case 'bajo':
      final umbral = (s['umbral_stock'] as num?)?.toInt() ?? 3;
      return stock > 0 && stock <= umbral;
    case 'agotado':
      return stock <= 0;
    default:
      return true;
  }
}
