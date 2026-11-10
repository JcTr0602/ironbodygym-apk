/// 1.24 Bloque 6 (ítem 17 del Panel): editor de «Rutinas del
/// gym» — el banco de rutinas que la app de clientes ofrece
/// en «Del gym» para adoptar con un toque (Fase B de Rutinas).
///
/// El contenido vive SOLO en el servidor (sync_rutinas_gym):
/// se lee y se escribe por las RPC admin_* (guarda es_admin()
/// en el servidor; esta pantalla además se protege a sí misma
/// como solo-dueño). Cada rutina es un nombre + la lista
/// ORDENADA de fichas de la Guía de musculación que la
/// componen; el catálogo sale del espejo local guia_fichas
/// (las publicadas), con el id CANÓNICO '${equipoId}_$slug'
/// que la app de clientes cruza contra su guiaCatalogo al
/// adoptar. (1.24.1, Argón G-09→G-07: la primera versión leía
/// gympedia_articulos — los artículos de LECTURA — y toda
/// rutina publicada era inadoptable.) Sin conexión, la
/// pantalla muestra el error con reintento: nunca un spinner
/// eterno ni datos inventados.
///
/// 1.29 D-22 (oleada propia): el editor se rehace portando
/// el CÓDIGO FUENTE del editor de rutinas de la app de
/// clientes post-O2 (paquetes distintos: se copia y se
/// re-tokeniza a la voz de Gestión — AppColores/AppTexto,
/// iconos _rounded por D-08=A, naranja #E8821A por D-17 SIN
/// UNIFICAR). Selector con búsqueda por título+equipo+
/// sinónimos+músculo y chips por grupo, miniaturas, series
/// SIEMPRE visibles con campos directos, tipo de serie con
/// nombre completo y hoja explicada, REORDENAR por arrastre,
/// quitar ejercicio con «Deshacer» y totales vivos. La
/// carga del catálogo lleva try/catch con error propio y
/// reintento, y el vacío se dice como lo que es (catálogo
/// vacío en el teléfono), nunca culpa del buscador. El
/// contrato NO se toca: mismo JSON v2, mismas RPC admin_*,
/// mismo saneador del servidor.
library;

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../auth.dart';
import '../config.dart';
import '../localdb.dart';
import 'app_bar.dart';
import 'componentes.dart';
import 'editor_avisos_clientes.dart';
import 'skeleton.dart';
import 'diseno.dart';

/// Una serie prescrita (0.15 Bloque 3, Parte B): la forma
/// JSON es IDÉNTICA a la SerieRutina de la app de clientes
/// (tipo/peso_kg/reps_min/reps_max) para que el contenido
/// viaje sin traducción servidor → cliente.
class SerieGymAdmin {
  final String tipo;
  final double? pesoKg;
  final int repsMin;
  final int? repsMax;

  const SerieGymAdmin({
    this.tipo = 'normal',
    this.pesoKg,
    required this.repsMin,
    this.repsMax,
  });

  factory SerieGymAdmin.fromJson(Map<String, dynamic> j) {
    final min = (j['reps_min'] as num?)?.toInt() ?? 10;
    var max = (j['reps_max'] as num?)?.toInt();
    if (max != null && max < min) max = min;
    const tipos = ['normal', 'calentamiento', 'fallo', 'drop'];
    final tipo = '${j['tipo'] ?? 'normal'}';
    return SerieGymAdmin(
      tipo: tipos.contains(tipo) ? tipo : 'normal',
      pesoKg: (j['peso_kg'] as num?)?.toDouble(),
      repsMin: min,
      repsMax: max,
    );
  }

  Map<String, dynamic> toJson() => {
        'tipo': tipo,
        if (pesoKg != null) 'peso_kg': pesoKg,
        'reps_min': repsMin,
        'reps_max': repsMax ?? repsMin,
      };
}

/// Yunque R5-M6-1: tope de series por ejercicio en el
/// editor de rutinas (el chip «Serie» añadía sin límite).
const int kMaxSeriesPorEjercicioRutina = 20;

/// Yunque R5-M6-1: validación de las series de la rutina
/// ANTES de publicar (PURO). Devuelve el primer problema,
/// nombrando el ejercicio por su título (o su id), o null
/// si todo es publicable: repsMin ≥ 1, repsMax ≥ repsMin,
/// peso ≥ 0 o vacío, y como mucho
/// [kMaxSeriesPorEjercicioRutina] series por ejercicio.
/// Hasta aquí, lo imposible viajaba sin validación local
/// (reps 0 por campo vaciado, máx < mín, peso negativo).
String? errorValidacionSeriesRutina(List<EjercicioGymAdmin> ejercicios,
    {required String Function(String fichaId) tituloDe}) {
  for (final ej in ejercicios) {
    final titulo = tituloDe(ej.fichaId);
    if (ej.series.length > kMaxSeriesPorEjercicioRutina) {
      return '«$titulo» tiene ${ej.series.length} series: '
          'el máximo es $kMaxSeriesPorEjercicioRutina por ejercicio.';
    }
    for (var i = 0; i < ej.series.length; i++) {
      final s = ej.series[i];
      if (s.repsMin < 1) {
        return '«$titulo», serie ${i + 1}: escribe las repeticiones '
            'mínimas (al menos 1).';
      }
      if (s.repsMax != null && s.repsMax! < s.repsMin) {
        return '«$titulo», serie ${i + 1}: las repeticiones máximas '
            '(${s.repsMax}) no pueden ser menos que las mínimas '
            '(${s.repsMin}).';
      }
      if (s.pesoKg != null && s.pesoKg! < 0) {
        return '«$titulo», serie ${i + 1}: el peso no puede ser '
            'negativo.';
      }
    }
  }
  return null;
}

/// Un ejercicio de la rutina con sus series prescritas.
class EjercicioGymAdmin {
  final String fichaId;
  final int? descansoSeg;
  final String nota;
  final List<SerieGymAdmin> series;

  const EjercicioGymAdmin({
    required this.fichaId,
    this.descansoSeg,
    this.nota = '',
    required this.series,
  });

  /// Las series con las que nace un ejercicio recién
  /// añadido: 3 × 10 sin peso (Jc las ajusta en el editor).
  static const seriesPorDefecto = [
    SerieGymAdmin(repsMin: 10),
    SerieGymAdmin(repsMin: 10),
    SerieGymAdmin(repsMin: 10),
  ];

  factory EjercicioGymAdmin.desdeFicha(String fichaId) =>
      EjercicioGymAdmin(
          fichaId: fichaId, series: List.of(seriesPorDefecto));

  factory EjercicioGymAdmin.fromJson(Map<String, dynamic> j) {
    final series = <SerieGymAdmin>[];
    final crudas = j['series'];
    if (crudas is List) {
      for (final s in crudas) {
        if (s is Map) {
          series.add(SerieGymAdmin.fromJson(
              Map<String, dynamic>.from(s)));
        }
      }
    }
    return EjercicioGymAdmin(
      fichaId: '${j['ficha_id'] ?? ''}',
      descansoSeg: (j['descanso_seg'] as num?)?.toInt(),
      nota: '${j['nota'] ?? ''}',
      series: series.isEmpty ? List.of(seriesPorDefecto) : series,
    );
  }

  Map<String, dynamic> toJson() => {
        'ficha_id': fichaId,
        if (descansoSeg != null) 'descanso_seg': descansoSeg,
        if (nota.isNotEmpty) 'nota': nota,
        'series': series.map((s) => s.toJson()).toList(),
      };
}

class RutinaGymAdmin {
  final int id;
  final String nombre;
  final List<String> fichaIds;

  /// El contenido v2 (nota general + ejercicios con
  /// series) o null si la rutina es v1 (solo fichas).
  final String nota;
  final List<EjercicioGymAdmin>? ejercicios;

  const RutinaGymAdmin({
    required this.id,
    required this.nombre,
    required this.fichaIds,
    this.nota = '',
    this.ejercicios,
  });

  bool get esV2 => ejercicios != null;

  factory RutinaGymAdmin.fromJson(Map<String, dynamic> j) {
    final crudo = j['ficha_ids'];
    List<EjercicioGymAdmin>? ejercicios;
    var nota = '';
    final contenido = j['contenido'];
    if (contenido is Map) {
      nota = '${contenido['nota'] ?? ''}';
      final lista = contenido['ejercicios'];
      if (lista is List) {
        ejercicios = [
          for (final e in lista)
            if (e is Map)
              EjercicioGymAdmin.fromJson(
                  Map<String, dynamic>.from(e)),
        ];
      }
    }
    return RutinaGymAdmin(
      id: (j['id'] as num?)?.toInt() ?? 0,
      nombre: '${j['nombre'] ?? ''}',
      fichaIds: crudo is List
          ? crudo.map((e) => e.toString()).toList()
          : const [],
      nota: nota,
      ejercicios: ejercicios,
    );
  }

  /// El JSON del parámetro p_contenido del RPC.
  static Map<String, dynamic> contenidoJson(
          List<EjercicioGymAdmin> ejercicios, String nota) =>
      {
        if (nota.isNotEmpty) 'nota': nota,
        'ejercicios': ejercicios.map((e) => e.toJson()).toList(),
      };
}

/// Una ficha del catálogo de la Guía de musculación
/// (espejo local guia_fichas, solo publicadas).
///
/// 1.29 D-22: además del id canónico y el título, la ficha
/// lleva lo que el documento del espejo ya trae y el
/// selector/editor necesitan: equipo, músculos, grupo
/// (siluetaId), sinónimos, el descanso recomendado de la
/// dosificación (ya en segundos) y su imagen pública si la
/// tiene. Todo sale del MISMO documento: la composición
/// del id no cambia una coma.
class FichaCatalogo {
  /// Id CANÓNICO '${equipoId}_$slug': el que la app de
  /// clientes espera en ficha_ids al adoptar la rutina.
  final String id;
  final String titulo;

  /// El slug de la fila del espejo (la clave de su imagen
  /// pública, como en la Guía de la propia Gestión).
  final String slug;
  final String equipoNombre;

  /// Músculos principales y secundarios, en ese orden.
  final List<String> musculos;

  /// Grupo de la silueta ('pecho', 'espalda', 'piernas',
  /// 'hombros', 'brazos', 'abdomen') o '' si no viene.
  final String grupo;
  final List<String> sinonimos;

  /// Descanso recomendado por la dosificación de la
  /// ficha, en segundos (null si la ficha no lo trae o
  /// no se entiende).
  final int? descansoSeg;
  final bool tieneImagen;
  final int imagenRev;

  const FichaCatalogo({
    required this.id,
    required this.titulo,
    this.slug = '',
    this.equipoNombre = '',
    this.musculos = const [],
    this.grupo = '',
    this.sinonimos = const [],
    this.descansoSeg,
    this.tieneImagen = false,
    this.imagenRev = 0,
  });

  /// El músculo que se nombra en las filas (el principal).
  String get musculoPrincipal =>
      musculos.isEmpty ? '' : musculos.first;
}

/// La identidad canónica con la que una ficha del espejo
/// entra en las rutinas: '${equipoId}_$slug', EXCEPTO cuando
/// el documento declara `idCanonico`. Dos fichas del
/// catálogo de Clientes comparten slug con distinto equipo
/// (peso-muerto-rumano con barra y con mancuernas) y la PK
/// de la tubería es el slug a secas: la segunda viaja con un
/// slug alias y su `idCanonico` es el id EXACTO que la app
/// de clientes cruza contra su catálogo embebido. Un
/// idCanonico cuyo prefijo no sea el equipoId de la propia
/// fila NO se honra (defensa contra un documento cruzado o
/// corrupto): se cae al compuesto de siempre.
String idCanonicoFichaGuia(
    String slug, String equipoId, dynamic declarado) {
  final compuesto = '${equipoId}_$slug';
  final d = '${declarado ?? ''}'.trim();
  if (d.isEmpty || d == compuesto) return compuesto;
  final prefijo = '${equipoId}_';
  if (!d.startsWith(prefijo)) return compuesto;
  final resto = d.substring(prefijo.length);
  if (resto.isEmpty || resto.contains('_')) return compuesto;
  return d;
}

/// Interpreta el texto de descanso de una ficha («60-90 s»,
/// «2 min», «90 segundos», «1:30»…) y devuelve los segundos.
/// Función pura, portada de la app de clientes (su
/// segundosDescanso, F4.5) sin cambio de reglas: en un rango
/// se toma el valor MAYOR (el descanso completo); «min»
/// multiplica por 60; formato m:ss suma ambas partes; sin
/// número legible → null; ningún descanso de ficha supera
/// 10 minutos (tope de cordura 600).
int? segundosDescansoFicha(String? texto) {
  if (texto == null) return null;
  final t = texto.trim().toLowerCase();
  if (t.isEmpty) return null;

  // Formato m:ss («1:30»).
  final reloj = RegExp(r'^(\d{1,2}):([0-5]\d)$').firstMatch(t);
  if (reloj != null) {
    return int.parse(reloj.group(1)!) * 60 +
        int.parse(reloj.group(2)!);
  }

  final numeros =
      RegExp(r'\d+(?:[.,]\d+)?').allMatches(t).map((m) {
    return double.parse(m.group(0)!.replaceAll(',', '.'));
  }).toList();
  if (numeros.isEmpty) return null;

  var valor = numeros.reduce((a, b) => a > b ? a : b);
  final esMinutos = t.contains('min');
  if (esMinutos) valor *= 60;
  final segundos = valor.round();
  if (segundos <= 0) return null;
  return segundos > 600 ? 600 : segundos;
}

/// Una duración en segundos como «m:ss» (el formato de
/// duración de la casa, portado de clientes).
String textoDuracionSeg(int segundos) {
  final s = segundos < 0 ? 0 : segundos;
  final m = s ~/ 60;
  final resto = (s % 60).toString().padLeft(2, '0');
  return '$m:$resto';
}

/// Quita acentos y diéresis para buscar sin pelear con la
/// ortografía («jalon» encuentra «Jalón»).
String sinAcentosBusqueda(String s) {
  const mapa = {
    'á': 'a', 'à': 'a', 'ä': 'a', 'â': 'a',
    'é': 'e', 'è': 'e', 'ë': 'e', 'ê': 'e',
    'í': 'i', 'ì': 'i', 'ï': 'i', 'î': 'i',
    'ó': 'o', 'ò': 'o', 'ö': 'o', 'ô': 'o',
    'ú': 'u', 'ù': 'u', 'ü': 'u', 'û': 'u',
    'ñ': 'n',
  };
  final b = StringBuffer();
  for (final c in s.toLowerCase().split('')) {
    b.write(mapa[c] ?? c);
  }
  return b.toString();
}

/// ¿La ficha responde a la consulta? Busca en el título,
/// el equipo, los sinónimos y los músculos (sin acentos,
/// sin mayúsculas). Consulta vacía = todo coincide.
/// Función pura: la usa el selector y la congelan los tests.
bool fichaCoincideConBusqueda(FichaCatalogo f, String consulta) {
  final q = sinAcentosBusqueda(consulta.trim());
  if (q.isEmpty) return true;
  bool en(String t) => sinAcentosBusqueda(t).contains(q);
  return en(f.titulo) ||
      en(f.equipoNombre) ||
      f.sinonimos.any(en) ||
      f.musculos.any(en);
}

/// Los grupos (siluetaId) presentes en el catálogo, en el
/// orden fijo de la casa, con su etiqueta visible. Solo
/// salen los grupos que el catálogo realmente tiene.
List<(String, String)> gruposDelCatalogo(List<FichaCatalogo> catalogo) {
  const orden = <(String, String)>[
    ('pecho', 'Pecho'),
    ('espalda', 'Espalda'),
    ('piernas', 'Piernas'),
    ('hombros', 'Hombros'),
    ('brazos', 'Brazos'),
    ('abdomen', 'Abdomen'),
  ];
  return [
    for (final g in orden)
      if (catalogo.any((f) => f.grupo == g.$1)) g,
  ];
}

/// Información de un tipo de serie: nombre COMPLETO y
/// explicación de una línea. Los textos son el lenguaje
/// único aprobado para la casa (los mismos de la app de
/// clientes, JC-11): nada de abreviaturas que nadie sabe
/// qué significan sin abrir la hoja.
class TipoSerieAdminInfo {
  final String valor;
  final String nombre;
  final String explicacion;

  const TipoSerieAdminInfo({
    required this.valor,
    required this.nombre,
    required this.explicacion,
  });
}

/// Los 4 tipos del formato v2 con su lenguaje único.
const tiposSerieAdmin = <TipoSerieAdminInfo>[
  TipoSerieAdminInfo(
    valor: 'normal',
    nombre: 'Normal',
    explicacion: 'La serie de trabajo estándar de tu rutina.',
  ),
  TipoSerieAdminInfo(
    valor: 'calentamiento',
    nombre: 'Calentamiento',
    explicacion: 'Prepara el músculo. No cuenta como serie válida.',
  ),
  TipoSerieAdminInfo(
    valor: 'fallo',
    nombre: 'Al fallo',
    explicacion: 'Sigues hasta no poder completar otra repetición.',
  ),
  TipoSerieAdminInfo(
    valor: 'drop',
    nombre: 'Descendente',
    explicacion: 'Al terminar, bajas el peso y continúas sin descansar.',
  ),
];

/// El info de un tipo; un valor desconocido cae a Normal
/// (el formato ya sanea al leer, esto es cinturón extra).
TipoSerieAdminInfo tipoSerieAdminDe(String valor) =>
    tiposSerieAdmin.firstWhere((t) => t.valor == valor,
        orElse: () => tiposSerieAdmin.first);

/// Colores de la pastilla de tipo, UNA sola definición
/// re-tokenizada a Gestión: la pastilla se apoya en la
/// superficie elevada y el color va en el TEXTO con los
/// roles legibles por brillo (la regla que la app de
/// clientes fijó tras su corrección de contraste). «Al
/// fallo» es el único con fondo de marca pleno, y su
/// texto es el grafito sobreMarca (D-01: blanco sobre
/// naranja, prohibido).
({Color fondo, Color tinta}) coloresTipoSerieAdmin(
    BuildContext context, String tipo) {
  return switch (tipo) {
    'calentamiento' => (
        fondo: AppColores.superficieElevada(context),
        tinta: AppColores.alertaTexto(context)
      ),
    'fallo' => (
        fondo: AppColores.naranja,
        tinta: AppColores.sobreMarca
      ),
    'drop' => (
        fondo: AppColores.superficieElevada(context),
        tinta: AppColores.infoTexto(context)
      ),
    _ => (
        fondo: AppColores.superficieElevada(context),
        tinta: AppColores.textoSecundario(context)
      ),
  };
}

/// Los totales vivos del formulario: ejercicios, series y
/// minutos estimados, con la fórmula portada del editor de
/// clientes (propuesta 2, punto 8): por serie, reps
/// objetivo (repsMax o repsMin) × 4 s acotado a 15–240 s;
/// descanso entre series del mismo ejercicio = el fijado
/// en la rutina, si no el de la ficha, si no 60 s.
class TotalesRutinaAdmin {
  final int ejercicios;
  final int series;
  final int minutos;

  const TotalesRutinaAdmin({
    required this.ejercicios,
    required this.series,
    required this.minutos,
  });

  /// «3 ejercicios · 11 series · ≈ 48 min»
  String get texto =>
      '$ejercicios ejercicio${ejercicios == 1 ? '' : 's'} · '
      '$series serie${series == 1 ? '' : 's'} · '
      '≈ $minutos min';
}

/// Calcula los totales. [descansoFichaPorId] mapea el id
/// canónico de cada ficha a su descanso recomendado en
/// segundos (el del catálogo cargado).
TotalesRutinaAdmin totalesRutinaAdmin(List<EjercicioGymAdmin> ejercicios,
    Map<String, int?> descansoFichaPorId) {
  var series = 0;
  var totalSeg = 0.0;
  for (final e in ejercicios) {
    final descanso =
        e.descansoSeg ?? descansoFichaPorId[e.fichaId] ?? 60;
    for (final s in e.series) {
      series++;
      final reps = s.repsMax ?? s.repsMin;
      totalSeg += (reps * 4).clamp(15, 240);
    }
    if (e.series.length > 1) {
      totalSeg += descanso * (e.series.length - 1);
    }
  }
  var minutos = (totalSeg / 60).round();
  if (minutos < 1 && series > 0) minutos = 1;
  return TotalesRutinaAdmin(
      ejercicios: ejercicios.length, series: series, minutos: minutos);
}

/// Convierte las filas del espejo (guiaPublicadas) en el
/// catálogo del editor de rutinas. Función pura: la usa
/// _cargarCatalogo y la congelan los tests de colisión de
/// slug (guia_id_canonico_test.dart).
List<FichaCatalogo> fichasCatalogoDesdeEspejo(
    List<Map<String, dynamic>> filas) {
  final out = <FichaCatalogo>[];
  for (final f in filas) {
    final slug = '${f['id'] ?? ''}'.trim();
    final equipoId = '${f['equipoId'] ?? ''}'.trim();
    if (slug.isEmpty || equipoId.isEmpty) continue;
    final titulo = '${f['titulo'] ?? ''}'.trim();
    List<String> textosDe(String clave) {
      final v = f[clave];
      if (v is! List) return const [];
      return [
        for (final e in v)
          if ('$e'.trim().isNotEmpty) '$e'.trim(),
      ];
    }

    final dosificacion = f['dosificacion'];
    out.add(FichaCatalogo(
      id: idCanonicoFichaGuia(slug, equipoId, f['idCanonico']),
      titulo: titulo.isEmpty ? slug : titulo,
      slug: slug,
      equipoNombre: '${f['equipoNombre'] ?? ''}'.trim(),
      musculos: [
        ...textosDe('musculosPrincipales'),
        ...textosDe('musculosSecundarios'),
      ],
      grupo: '${f['siluetaId'] ?? ''}'.trim(),
      sinonimos: textosDe('sinonimos'),
      descansoSeg: dosificacion is Map
          ? segundosDescansoFicha('${dosificacion['descanso'] ?? ''}')
          : null,
      tieneImagen: f['tiene_imagen'] == true || f['tiene_imagen'] == 1,
      imagenRev: (f['imagen_rev'] as num?)?.toInt() ?? 0,
    ));
  }
  out.sort((a, b) => a.titulo.compareTo(b.titulo));
  return out;
}

Future<List<FichaCatalogo>> _cargarCatalogo() async {
  // 1.24.1 (Argón G-07): la fuente son las fichas PUBLICADAS
  // de la Guía (guiaPublicadas ya decodifica el espejo y
  // deja el slug en 'id'; el equipoId viaja en el data). Una
  // ficha sin equipoId no tiene id canónico: no entra (el
  // cliente tampoco podría cruzarla).
  final filas = await LocalDb.instance.guiaPublicadas();
  return fichasCatalogoDesdeEspejo(filas);
}

/// Costura para tests (patrón de la casa, como
/// leerNominaPermisosParaTest de la 1.29): si un test la
/// siembra, el formulario lee el catálogo de aquí en vez
/// del espejo local. En producción vale siempre null.
Future<List<FichaCatalogo>> Function()? cargarCatalogoRutinasParaTest;

class EditorRutinasGymScreen extends StatefulWidget {
  const EditorRutinasGymScreen({super.key});

  @override
  State<EditorRutinasGymScreen> createState() =>
      _EditorRutinasGymScreenState();
}

class _EditorRutinasGymScreenState extends State<EditorRutinasGymScreen> {
  List<RutinaGymAdmin> _rutinas = [];
  bool _cargando = true;
  bool _error = false;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    if (mounted) {
      setState(() {
        _cargando = true;
        _error = false;
      });
    }
    try {
      final res = await Supabase.instance.client
          .rpc('admin_listar_rutinas')
          .timeout(const Duration(seconds: 12));
      final lista = ((res as List?) ?? const [])
          .map((e) =>
              RutinaGymAdmin.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
      if (!mounted) return;
      setState(() {
        _rutinas = lista;
        _cargando = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _cargando = false;
        _error = true;
      });
    }
  }

  Future<void> _abrirFormulario([RutinaGymAdmin? rutina]) async {
    final cambiado = await Navigator.push<bool>(
      context,
      RutaIron(
        builder: (_) => FormularioRutinaScreen(rutina: rutina),
      ),
    );
    if (cambiado == true && mounted) await _cargar();
  }

  @override
  Widget build(BuildContext context) {
    if (!AuthService().isOwner) {
      return Scaffold(
        appBar: appBarIron(context, 'Rutinas del gym'),
        body: const EstadoVacio(
          icono: Icons.lock_rounded,
          titulo: 'Solo el dueño',
          subtitulo: 'Las rutinas del gym las publica el dueño.',
        ),
      );
    }
    return Scaffold(
      appBar: appBarIron(context, 'Rutinas del gym'),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _abrirFormulario(),
        icon: const Icon(Icons.add_rounded),
        label: const Text('Nueva rutina'),
      ),
      body: _cargando
          // 1.25 T114: esqueleto con la forma de la lista.
          ? const Padding(
              padding: EdgeInsets.all(AppEspacio.lg),
              child: SkeletonLista(items: 3))
          : _error
              ? EstadoError(
                  titulo: 'No se pudieron cargar las rutinas',
                  detalle: 'Las rutinas viven en el servidor: '
                      'revisa la conexión e inténtalo de nuevo.',
                  onReintentar: _cargar,
                )
              : _rutinas.isEmpty
                  ? const EstadoVacio(
                      icono: Icons.fitness_center_rounded,
                      titulo: 'Sin rutinas del gym',
                      subtitulo: 'Arma la primera rutina con '
                          'fichas de GymPedia para que los '
                          'clientes la adopten desde su app.',
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.all(AppEspacio.lg),
                      itemCount: _rutinas.length,
                      separatorBuilder: (_, __) =>
                          const SizedBox(height: AppEspacio.sm),
                      itemBuilder: (ctx, i) {
                        final r = _rutinas[i];
                        return Tarjeta(
                          onTap: () => _abrirFormulario(r),
                          child: Row(
                            children: [
                              const Icon(Icons.fitness_center_rounded,
                                  color: AppColores.naranja),
                              const SizedBox(width: AppEspacio.sm),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  children: [
                                    Text(r.nombre,
                                        style: AppTexto.subtitulo),
                                    const SizedBox(height: 2),
                                    Text(
                                      '${r.fichaIds.length} ejercicio'
                                      '${r.fichaIds.length == 1 ? '' : 's'}'
                                      '${r.esV2 ? ' · con series puestas' : ''}',
                                      style: AppTexto.secundario,
                                    ),
                                  ],
                                ),
                              ),
                              const Icon(Icons.chevron_right_rounded),
                            ],
                          ),
                        );
                      },
                    ),
    );
  }
}

/// El formulario de UNA rutina (crear o editar). Público
/// (antes privado) para que los tests de D-22 lo monten
/// directo con la costura del catálogo.
class FormularioRutinaScreen extends StatefulWidget {
  final RutinaGymAdmin? rutina;

  /// Costuras de red para los tests (1.30 Oleada 3,
  /// GEN-08): por defecto van las RPC reales
  /// admin_retirar_rutina / admin_listar_rutinas.
  final Future<void> Function(int id)? retirarRutinaRpc;
  final Future<List<RutinaGymAdmin>> Function()? listarRutinasRpc;

  const FormularioRutinaScreen(
      {super.key,
      this.rutina,
      this.retirarRutinaRpc,
      this.listarRutinasRpc});

  @override
  State<FormularioRutinaScreen> createState() =>
      _FormularioRutinaScreenState();
}

class _FormularioRutinaScreenState extends State<FormularioRutinaScreen> {
  late final TextEditingController _nombreCtrl;
  late final TextEditingController _notaCtrl;
  List<FichaCatalogo> _catalogo = [];

  /// Bloque 3: la rutina se edita como ejercicios con
  /// series (v2). Una rutina v1 entra con las series por
  /// defecto sembradas en memoria, pero si Jc no toca ni
  /// las fichas ni las series se guarda COMO v1 (el
  /// servidor no recibe contenido): publicar no debe
  /// imponer series que nadie decidió.
  final List<EjercicioGymAdmin> _ejercicios = [];
  late final List<String> _fichasIniciales;
  late final bool _eraV2;
  bool _seriesEditadas = false;
  bool _cargandoCatalogo = true;

  /// D-22: la carga del catálogo puede FALLAR (BD
  /// bloqueada, JSON corrupto en una fila): error propio
  /// con reintento, nunca spinner eterno ni un vacío
  /// disfrazado (error ≠ vacío).
  bool _errorCatalogo = false;
  bool _guardando = false;

  @override
  void initState() {
    super.initState();
    final r = widget.rutina;
    _nombreCtrl = TextEditingController(text: r?.nombre ?? '');
    _notaCtrl = TextEditingController(text: r?.nota ?? '');
    _eraV2 = r?.esV2 ?? false;
    _fichasIniciales = List.of(r?.fichaIds ?? const []);
    if (r != null && r.ejercicios != null) {
      _ejercicios.addAll(r.ejercicios!);
    } else {
      for (final id in _fichasIniciales) {
        _ejercicios.add(EjercicioGymAdmin.desdeFicha(id));
      }
    }
    // Yunque R5-M6-8: deduplicar al cargar (primera
    // aparición): si el servidor devolviera una ficha
    // repetida, el ReorderableListView montaba dos tarjetas
    // con la misma ValueKey y el editor moría con error de
    // claves duplicadas justo para corregirla.
    final vistos = <String>{};
    _ejercicios.retainWhere((e) => vistos.add(e.fichaId));
    _cargarCatalogoFormulario();
  }

  @override
  void dispose() {
    _nombreCtrl.dispose();
    _notaCtrl.dispose();
    super.dispose();
  }

  /// D-22: carga del catálogo con try/catch y estados
  /// honestos (cargando / error con reintento / vacío de
  /// verdad). La versión anterior encadenaba un `.then()`
  /// sin catchError: si la lectura lanzaba, el formulario
  /// se quedaba en «Cargando GymPedia…» para siempre.
  Future<void> _cargarCatalogoFormulario() async {
    if (mounted) {
      setState(() {
        _cargandoCatalogo = true;
        _errorCatalogo = false;
      });
    }
    try {
      final lista = await (cargarCatalogoRutinasParaTest?.call() ??
          _cargarCatalogo());
      if (!mounted) return;
      setState(() {
        _catalogo = lista;
        _cargandoCatalogo = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _cargandoCatalogo = false;
        _errorCatalogo = true;
      });
    }
  }

  FichaCatalogo? _fichaDe(String id) {
    for (final f in _catalogo) {
      if (f.id == id) return f;
    }
    return null;
  }

  String _tituloDe(String id) => _fichaDe(id)?.titulo ?? id;

  List<String> get _seleccion =>
      _ejercicios.map((e) => e.fichaId).toList();

  bool get _fichasCambiaron {
    final ahora = _seleccion;
    if (ahora.length != _fichasIniciales.length) return true;
    for (var i = 0; i < ahora.length; i++) {
      if (ahora[i] != _fichasIniciales[i]) return true;
    }
    return false;
  }

  /// ¿Se manda p_contenido? Solo si la rutina ya era v2 o
  /// Jc tocó las fichas o las series en esta edición.
  bool get _enviaContenido =>
      _eraV2 || _seriesEditadas || _fichasCambiaron;

  /// El catálogo se cargó bien y trajo cero fichas: el
  /// vacío VERDADERO, que se dice como tal.
  bool get _catalogoVacio =>
      !_cargandoCatalogo && !_errorCatalogo && _catalogo.isEmpty;

  bool get _puedeElegir =>
      !_guardando && !_cargandoCatalogo && !_errorCatalogo && !_catalogoVacio;

  Future<void> _elegirFichas() async {
    final elegidas = await Navigator.push<List<String>>(
      context,
      RutaIron(
        builder: (_) => SelectorFichasScreen(
          catalogo: _catalogo,
          seleccionInicial: _seleccion,
        ),
      ),
    );
    if (elegidas == null || !mounted) return;
    setState(() {
      // Conservar las series ya editadas de las fichas que
      // siguen; las nuevas nacen con las de por defecto.
      final porId = {for (final e in _ejercicios) e.fichaId: e};
      _ejercicios
        ..clear()
        ..addAll([
          for (final id in elegidas)
            porId[id] ?? EjercicioGymAdmin.desdeFicha(id),
        ]);
    });
  }

  /// D-22: quitar un ejercicio sale al instante PERO con
  /// red: el aviso nombra el ejercicio y cuántas series se
  /// lleva, y ofrece «Deshacer». El dato es inmutable y el
  /// padre siempre guarda la última versión emitida por la
  /// tarjeta, así que reinsertar el objeto no pierde ni un
  /// campo editado.
  void _quitarEjercicio(int i) {
    if (i < 0 || i >= _ejercicios.length) return;
    final quitado = _ejercicios[i];
    final titulo = _tituloDe(quitado.fichaId);
    final n = quitado.series.length;
    setState(() => _ejercicios.removeAt(i));
    mostrarSnack(
      context,
      'Se quitó $titulo · $n ${n == 1 ? 'serie' : 'series'}',
      accion: 'Deshacer',
      alAccion: () {
        if (!mounted) return;
        setState(() {
          final destino =
              i > _ejercicios.length ? _ejercicios.length : i;
          _ejercicios.insert(destino, quitado);
        });
      },
      duracion: const Duration(seconds: 5),
    );
  }

  Future<void> _guardar() async {
    // Yunque R5-M6-5: guarda de rol DENTRO de la acción,
    // como en la Guía — el widget es público y montable
    // directo; la guarda de la lista no basta.
    if (!AuthService().isOwner) return;
    // Anti-doble-toque síncrono (ítem 5).
    if (_guardando) return;
    final nombre = _nombreCtrl.text.trim();
    if (nombre.isEmpty) {
      mostrarSnack(context, 'La rutina necesita un nombre',
          significado: SignificadoChip.alerta);
      return;
    }
    if (_seleccion.isEmpty) {
      mostrarSnack(context, 'Elige al menos una ficha de GymPedia',
          significado: SignificadoChip.alerta);
      return;
    }
    // Yunque R5-M6-1: las series se validan en local ANTES
    // de publicar (sin esto, lo imposible viajaba tal cual:
    // reps 0, máx < mín, peso negativo, series sin tope).
    if (_enviaContenido) {
      final errorSeries = errorValidacionSeriesRutina(_ejercicios,
          tituloDe: _tituloDe);
      if (errorSeries != null) {
        mostrarSnack(context, errorSeries,
            significado: SignificadoChip.alerta);
        return;
      }
    }
    // Yunque R5-M6-7: una ficha retirada de la Guía no se
    // re-publica en silencio al re-editar la rutina: se
    // AVISA nombrándolas (no se bloquea: puede ser la
    // intención de Jc retirar la rutina entera después).
    if (!_cargandoCatalogo && !_errorCatalogo) {
      final ausentes = [
        for (final id in _seleccion)
          if (_fichaDe(id) == null) id,
      ];
      if (ausentes.isNotEmpty) {
        mostrarSnack(context,
            'Ojo: estas fichas ya no están en la Guía y se '
            'publicarán igual: ${ausentes.join(', ')}',
            significado: SignificadoChip.alerta);
      }
    }
    setState(() => _guardando = true);
    try {
      await Supabase.instance.client
          .rpc('admin_guardar_rutina', params: {
            'p_id': widget.rutina?.id,
            'p_nombre': nombre,
            'p_ficha_ids': _seleccion,
            // Bloque 3: el contenido v2 solo viaja cuando
            // aplica (ver _enviaContenido); el servidor lo
            // sanea y DERIVA ficha_ids de él.
            if (_enviaContenido)
              'p_contenido': RutinaGymAdmin.contenidoJson(
                  _ejercicios, _notaCtrl.text.trim()),
          })
          // 1.24 Bloque 4: timeout de escritura (12 s).
          .timeout(const Duration(seconds: 12));
      if (!mounted) return;
      mostrarSnack(context, 'Rutina publicada',
          significado: SignificadoChip.exito);
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _guardando = false);
      mostrarSnack(context, 'No se pudo publicar: $e',
          significado: SignificadoChip.error);
    }
  }

  Future<void> _retirarReal(int id) async {
    await Supabase.instance.client
        .rpc('admin_retirar_rutina', params: {'p_id': id})
        // 1.24 Bloque 4: timeout de escritura (12 s).
        .timeout(const Duration(seconds: 12));
  }

  Future<List<RutinaGymAdmin>> _listarReal() async {
    final res = await Supabase.instance.client
        .rpc('admin_listar_rutinas')
        .timeout(const Duration(seconds: 12));
    return ((res as List?) ?? const [])
        .map((e) =>
            RutinaGymAdmin.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  Future<void> _retirar() async {
    // Yunque R5-M6-5: guarda de rol en la acción, como
    // _guardar.
    if (!AuthService().isOwner) return;
    final rutina = widget.rutina;
    if (rutina == null || _guardando) return;
    // Escalera de confirmaciones (ítem 2): retirar es
    // destructivo → confirmación explícita en rojo.
    final ok = await DialogoApp.confirmar(
      context,
      titulo: 'Retirar rutina',
      mensaje: '«${rutina.nombre}» dejará de ofrecerse en el '
          'banco «Del gym» de la app de clientes. Las rutinas que '
          'un cliente ya adoptó NO se le borran.',
      aceptar: 'Retirar',
      icono: Icons.delete_outline_rounded,
      peligro: true,
    );
    if (ok != true || !mounted) return;
    setState(() => _guardando = true);
    // 1.30 (Oleada 3, GEN-08): retiro VERIFICADO con el
    // MISMO motor que estrenan los avisos
    // (ejecutarRetiroVerificado, en
    // editor_avisos_clientes.dart): si la llamada falla
    // (timeout), se comprueba si la rutina ya no está en
    // la lista antes de enseñar un error falso.
    final resultado = await ejecutarRetiroVerificado(
      retirar: () =>
          (widget.retirarRutinaRpc ?? _retirarReal)(rutina.id),
      sigueEnLaLista: () async {
        final lista =
            await (widget.listarRutinasRpc ?? _listarReal)();
        return lista.any((r) => r.id == rutina.id);
      },
    );
    if (!mounted) return;
    switch (resultado) {
      case ResultadoRetiroAviso.retirado:
        mostrarSnack(context, 'Rutina retirada',
            significado: SignificadoChip.exito);
        Navigator.pop(context, true);
      case ResultadoRetiroAviso.noRetirado:
        setState(() => _guardando = false);
        mostrarSnack(context,
            'No se pudo retirar la rutina. Revisa la '
            'conexión e inténtalo de nuevo.',
            significado: SignificadoChip.error);
      case ResultadoRetiroAviso.sinConfirmar:
        // No se sabe si aterrizó: se vuelve a la lista (que
        // se recarga) para comprobarlo ANTES de repetir.
        mostrarSnack(context,
            'No se pudo confirmar si la rutina se retiró. '
            'Revisa la lista antes de intentarlo de nuevo.',
            significado: SignificadoChip.alerta);
        Navigator.pop(context, true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final esEdicion = widget.rutina != null;
    final totales = totalesRutinaAdmin(_ejercicios,
        {for (final f in _catalogo) f.id: f.descansoSeg});
    return Scaffold(
      appBar: appBarIron(
          context, esEdicion ? 'Editar rutina' : 'Nueva rutina'),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(AppEspacio.lg,
                AppEspacio.lg, AppEspacio.lg, 0),
            child: Column(
              children: [
                TextField(
                  controller: _nombreCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Nombre de la rutina',
                    hintText: 'Ej.: Pecho y tríceps — nivel inicial',
                  ),
                  textInputAction: TextInputAction.done,
                ),
                const SizedBox(height: AppEspacio.md),
                TextField(
                  controller: _notaCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Nota para el cliente (opcional)',
                    hintText: 'Ej.: Sube peso cuando completes todas',
                  ),
                  maxLines: 2,
                ),
              ],
            ),
          ),
          if (_errorCatalogo)
            Padding(
              padding: const EdgeInsets.fromLTRB(AppEspacio.lg,
                  AppEspacio.md, AppEspacio.lg, 0),
              child: Column(
                children: [
                  const AvisoEstado(
                    tipo: TipoAviso.error,
                    texto: 'No se pudo leer el catálogo de '
                        'GymPedia de este teléfono. Las series '
                        'se pueden seguir editando; para elegir '
                        'fichas hace falta reintentar.',
                  ),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(
                      onPressed: _cargarCatalogoFormulario,
                      icon: const Icon(Icons.refresh_rounded, size: 18),
                      label: const Text('Reintentar'),
                    ),
                  ),
                ],
              ),
            ),
          if (_catalogoVacio)
            Padding(
              padding: const EdgeInsets.fromLTRB(AppEspacio.lg,
                  AppEspacio.md, AppEspacio.lg, 0),
              child: Column(
                children: [
                  const AvisoEstado(
                    tipo: TipoAviso.aviso,
                    texto: 'El catálogo de GymPedia está vacío '
                        'en este teléfono: sin fichas no se '
                        'puede armar la rutina. Sincroniza la '
                        'app y reintenta; si sigue vacío, el '
                        'catálogo aún no se ha publicado en el '
                        'servidor.',
                  ),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(
                      onPressed: _cargarCatalogoFormulario,
                      icon: const Icon(Icons.refresh_rounded, size: 18),
                      label: const Text('Reintentar'),
                    ),
                  ),
                ],
              ),
            ),
          if (_ejercicios.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(AppEspacio.lg,
                  AppEspacio.lg, AppEspacio.lg, 0),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Ejercicios (${_ejercicios.length})',
                            style: AppTexto.subtitulo),
                        const SizedBox(height: 2),
                        Text(totales.texto,
                            style: AppTexto.secundario.copyWith(
                                color: AppColores.textoSecundario(
                                    context))),
                      ],
                    ),
                  ),
                  if (_ejercicios.length > 1)
                    Text('Arrastra por el asa',
                        style: AppTexto.metadato.copyWith(
                            color:
                                AppColores.textoSecundario(context))),
                ],
              ),
            ),
          ],
          const SizedBox(height: AppEspacio.sm),
          Expanded(
            child: _cargandoCatalogo
                ? const EstadoCargando(texto: 'Cargando GymPedia…')
                : _ejercicios.isEmpty
                    // El vacío va en un scroll con alto mínimo:
                    // en pantallas bajas (o con el aviso del
                    // catálogo visible) el EstadoVacio no cabe
                    // en el hueco y desbordaba en vez de
                    // dejarse desplazar.
                    ? LayoutBuilder(
                        builder: (ctx, c) => SingleChildScrollView(
                          child: ConstrainedBox(
                            constraints:
                                BoxConstraints(minHeight: c.maxHeight),
                            child: const EstadoVacio(
                              icono: Icons.fitness_center_rounded,
                              titulo: 'Todavía no hay ejercicios',
                              subtitulo: 'Elige fichas de GymPedia '
                                  'para armar la rutina: el cliente '
                                  'entrena con las series que '
                                  'pongas aquí.',
                            ),
                          ),
                        ),
                      )
                    : ReorderableListView.builder(
                        buildDefaultDragHandles: false,
                        padding: const EdgeInsets.fromLTRB(
                            AppEspacio.lg,
                            0,
                            AppEspacio.lg,
                            AppEspacio.lg),
                        itemCount: _ejercicios.length,
                        onReorderItem: (antes, despues) =>
                            setState(() {
                          final movido =
                              _ejercicios.removeAt(antes);
                          _ejercicios.insert(despues, movido);
                        }),
                        itemBuilder: (ctx, i) => Padding(
                          key: ValueKey(_ejercicios[i].fichaId),
                          padding: const EdgeInsets.only(
                              bottom: AppEspacio.sm),
                          child: _TarjetaEjercicioEditor(
                            indice: i,
                            ficha: _fichaDe(_ejercicios[i].fichaId),
                            datos: _ejercicios[i],
                            bloqueado: _guardando,
                            reordenable: _ejercicios.length > 1,
                            onCambio: (nuevo) => setState(() {
                              _ejercicios[i] = nuevo;
                              _seriesEditadas = true;
                            }),
                            onQuitar: () => _quitarEjercicio(i),
                          ),
                        ),
                      ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(AppEspacio.lg,
                  AppEspacio.sm, AppEspacio.lg, AppEspacio.md),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  OutlinedButton.icon(
                    onPressed: _puedeElegir ? _elegirFichas : null,
                    icon: const Icon(Icons.add_rounded),
                    label: Text(_ejercicios.isEmpty
                        ? 'Elegir fichas de GymPedia'
                        : 'Añadir o quitar fichas'),
                  ),
                  const SizedBox(height: AppEspacio.sm),
                  Text(
                    'El cliente la ve en «Del gym»: puede '
                    'entrenarla directo con tus series o '
                    'adoptarla como copia suya editable.',
                    style: AppTexto.metadato.copyWith(
                        color: AppColores.textoSecundario(context)),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: AppEspacio.sm),
                  ElevatedButton(
                    onPressed: _guardando ? null : _guardar,
                    child: Text(_guardando
                        ? 'Publicando…'
                        : (esEdicion
                            ? 'Guardar cambios'
                            : 'Publicar rutina')),
                  ),
                  if (esEdicion)
                    TextButton(
                      onPressed: _guardando ? null : _retirar,
                      child: const Text('Retirar rutina',
                          style: TextStyle(color: AppColores.error)),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// La pastilla de tipo de serie: nombre COMPLETO (con
/// FittedBox para que nunca se corte a mitad de palabra),
/// color por tipo y blanco táctil generoso. Tocar NO rota
/// nada: abre la hoja explicada (abrirSelectorTipoSerieAdmin).
class _PastillaTipoSerie extends StatelessWidget {
  final String tipo;
  final VoidCallback? onTap;

  const _PastillaTipoSerie({required this.tipo, this.onTap});

  @override
  Widget build(BuildContext context) {
    final colores = coloresTipoSerieAdmin(context, tipo);
    final info = tipoSerieAdminDe(tipo);
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadio.circular),
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 40),
          padding: const EdgeInsets.symmetric(horizontal: AppEspacio.sm),
          decoration: BoxDecoration(
            color: colores.fondo,
            borderRadius: BorderRadius.circular(AppRadio.circular),
          ),
          child: Center(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                info.nombre,
                maxLines: 1,
                style: AppTexto.minuscula.copyWith(
                    fontWeight: FontWeight.w800, color: colores.tinta),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// El selector de tipo de serie EXPLICADO (portado de la
/// app de clientes, JC-11, re-tokenizado): los 4 tipos
/// como filas con la pastilla, el nombre completo, la
/// explicación y la marca del actual. Tocar aplica y
/// cierra: cambiar el tipo nunca es un gesto invisible.
class _SelectorTipoSerieAdmin extends StatelessWidget {
  final String actual;
  final ValueChanged<String> onElegir;

  const _SelectorTipoSerieAdmin({
    required this.actual,
    required this.onElegir,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(AppEspacio.lg,
              AppEspacio.md, AppEspacio.lg, AppEspacio.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Tipo de serie', style: AppTexto.titulo),
              const SizedBox(height: AppEspacio.md),
              for (final info in tiposSerieAdmin)
                Padding(
                  padding: const EdgeInsets.only(bottom: AppEspacio.sm),
                  child: Material(
                    type: MaterialType.transparency,
                    child: InkWell(
                      borderRadius:
                          BorderRadius.circular(AppRadio.sm),
                      onTap: () => onElegir(info.valor),
                      child: Container(
                        constraints:
                            const BoxConstraints(minHeight: 56),
                        padding: const EdgeInsets.symmetric(
                            horizontal: AppEspacio.md,
                            vertical: AppEspacio.sm),
                        decoration: BoxDecoration(
                          color: actual == info.valor
                              ? AppColores.superficieElevada(context)
                              : null,
                          borderRadius:
                              BorderRadius.circular(AppRadio.sm),
                          border: Border.all(
                            color: actual == info.valor
                                ? AppColores.naranja
                                : AppColores.bordeSutil(context),
                          ),
                        ),
                        child: Row(
                          children: [
                            SizedBox(
                              width: 104,
                              child:
                                  _PastillaTipoSerie(tipo: info.valor),
                            ),
                            const SizedBox(width: AppEspacio.md),
                            Expanded(
                              child: Column(
                                crossAxisAlignment:
                                    CrossAxisAlignment.start,
                                children: [
                                  Text(info.nombre,
                                      style: AppTexto.subtitulo),
                                  Text(info.explicacion,
                                      style: AppTexto.secundario
                                          .copyWith(
                                              color: AppColores
                                                  .textoSecundario(
                                                      context))),
                                ],
                              ),
                            ),
                            SizedBox(
                              width: 24,
                              child: actual == info.valor
                                  ? const Icon(Icons.check_rounded,
                                      size: 20,
                                      color: AppColores.naranja)
                                  : null,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Abre el selector de tipo explicado como hoja inferior;
/// al elegir, avisa por onElegir y cierra.
Future<void> abrirSelectorTipoSerieAdmin(
  BuildContext context, {
  required String actual,
  required ValueChanged<String> onElegir,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => _SelectorTipoSerieAdmin(
      actual: actual,
      onElegir: (v) {
        onElegir(v);
        Navigator.of(ctx).pop();
      },
    ),
  );
}

/// Diálogo de la nota de UN ejercicio. StatefulWidget
/// dueño de su TextEditingController (regla de la casa:
/// quien crea controladores los libera en su dispose).
class _DialogoNotaEjercicio extends StatefulWidget {
  final String titulo;
  final String inicial;
  const _DialogoNotaEjercicio({
    required this.titulo,
    required this.inicial,
  });

  @override
  State<_DialogoNotaEjercicio> createState() =>
      _DialogoNotaEjercicioState();
}

class _DialogoNotaEjercicioState extends State<_DialogoNotaEjercicio> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.inicial);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.titulo, style: AppTexto.subtitulo),
      content: TextField(
        controller: _ctrl,
        autofocus: true,
        maxLength: 120,
        maxLines: 3,
        textCapitalization: TextCapitalization.sentences,
        decoration: const InputDecoration(
          labelText: 'Nota del ejercicio (opcional)',
          hintText: 'Ej.: Baja despacio, 3 segundos',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
        ElevatedButton(
          onPressed: () => Navigator.of(context).pop(_ctrl.text),
          child: const Text('Guardar'),
        ),
      ],
    );
  }
}

/// Diálogo «otro tiempo» del descanso: pide los segundos
/// en texto y devuelve el texto crudo (la validación la
/// hace quien llama, como en la app de clientes).
/// StatefulWidget dueño de su controlador.
class _DialogoSegundos extends StatefulWidget {
  final String inicial;
  const _DialogoSegundos({required this.inicial});

  @override
  State<_DialogoSegundos> createState() => _DialogoSegundosState();
}

class _DialogoSegundosState extends State<_DialogoSegundos> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.inicial);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title:
          const Text('Descanso en segundos', style: AppTexto.subtitulo),
      content: TextField(
        controller: _ctrl,
        autofocus: true,
        keyboardType: TextInputType.number,
        decoration: const InputDecoration(
          labelText: 'Segundos',
          hintText: 'Ej.: 90',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
        ElevatedButton(
          onPressed: () => Navigator.of(context).pop(_ctrl.text),
          child: const Text('Aplicar'),
        ),
      ],
    );
  }
}

class _CtrlsSerie {
  final TextEditingController peso;
  final TextEditingController min;
  final TextEditingController max;
  String tipo;
  _CtrlsSerie(SerieGymAdmin s)
      : peso = TextEditingController(
            text: s.pesoKg == null
                ? ''
                : (s.pesoKg! % 1 == 0
                    ? '${s.pesoKg!.toInt()}'
                    : '${s.pesoKg}')),
        min = TextEditingController(text: '${s.repsMin}'),
        max = TextEditingController(
            text: '${s.repsMax ?? s.repsMin}'),
        tipo = s.tipo;

  void dispose() {
    peso.dispose();
    min.dispose();
    max.dispose();
  }
}

/// D-22: la tarjeta de UN ejercicio en 3 ZONAS delimitadas
/// (portada de la TarjetaEjercicioIron de clientes,
/// re-tokenizada): cabecera con asa de arrastre, número,
/// miniatura y título protegido · zona de series SIEMPRE
/// visible con campos directos · pie de acciones (serie,
/// descanso, nota). Es StatefulWidget propio porque posee
/// los TextEditingController de las series (regla de la
/// casa); el descanso y la nota viven como dato local y se
/// emiten con cada cambio, como el resto: el formulario
/// solo guarda el EjercicioGymAdmin reconstruido.
class _TarjetaEjercicioEditor extends StatefulWidget {
  final int indice;
  final FichaCatalogo? ficha;
  final EjercicioGymAdmin datos;
  final bool bloqueado;
  final bool reordenable;
  final void Function(EjercicioGymAdmin) onCambio;
  final VoidCallback onQuitar;

  const _TarjetaEjercicioEditor({
    required this.indice,
    required this.ficha,
    required this.datos,
    required this.bloqueado,
    required this.reordenable,
    required this.onCambio,
    required this.onQuitar,
  });

  @override
  State<_TarjetaEjercicioEditor> createState() =>
      _TarjetaEjercicioEditorState();
}

class _TarjetaEjercicioEditorState
    extends State<_TarjetaEjercicioEditor> {
  late int? _descansoSeg;
  late String _nota;
  late final List<_CtrlsSerie> _series;

  @override
  void initState() {
    super.initState();
    _descansoSeg = widget.datos.descansoSeg;
    _nota = widget.datos.nota;
    _series = [for (final s in widget.datos.series) _CtrlsSerie(s)];
  }

  @override
  void dispose() {
    for (final s in _series) {
      s.dispose();
    }
    super.dispose();
  }

  String get _titulo => widget.ficha?.titulo ?? widget.datos.fichaId;

  void _emitir() {
    widget.onCambio(EjercicioGymAdmin(
      fichaId: widget.datos.fichaId,
      descansoSeg: _descansoSeg,
      nota: _nota,
      series: [
        for (final c in _series)
          SerieGymAdmin(
            tipo: c.tipo,
            pesoKg: double.tryParse(
                c.peso.text.trim().replaceAll(',', '.')),
            repsMin: int.tryParse(c.min.text.trim()) ?? 0,
            repsMax: int.tryParse(c.max.text.trim()),
          ),
      ],
    ));
  }

  /// El descanso efectivo que enseña el chip del pie: el
  /// fijado en la rutina o, si no hay, el de la ficha.
  String get _textoChipDescanso {
    if (_descansoSeg != null) return textoDuracionSeg(_descansoSeg!);
    final deFicha = widget.ficha?.descansoSeg;
    if (deFicha != null) return '${textoDuracionSeg(deFicha)} · ficha';
    return 'De la ficha';
  }

  Future<void> _editarDescanso() async {
    final deFicha = widget.ficha?.descansoSeg;
    final elegido = await showModalBottomSheet<int>(
      context: context,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                title: const Text('Descanso tras este ejercicio'),
                subtitle: Text(_descansoSeg != null
                    ? 'Ahora: ${textoDuracionSeg(_descansoSeg!)} '
                        '(fijado en la rutina)'
                    : 'Ahora: el de la ficha de GymPedia'
                        '${deFicha != null ? ' (${textoDuracionSeg(deFicha)})' : ''}'),
              ),
              ListTile(
                title: const Text('El de la ficha de GymPedia'),
                subtitle: deFicha != null
                    ? Text(textoDuracionSeg(deFicha))
                    : const Text('La ficha no trae uno: el '
                        'cliente usa 60 s por defecto'),
                trailing: _descansoSeg == null
                    ? const Icon(Icons.check_rounded,
                        color: AppColores.naranja)
                    : null,
                onTap: () => Navigator.of(ctx).pop(-1),
              ),
              for (final seg in const [30, 60, 90, 120, 180, 300])
                ListTile(
                  title: Text(textoDuracionSeg(seg)),
                  trailing: _descansoSeg == seg
                      ? const Icon(Icons.check_rounded,
                          color: AppColores.naranja)
                      : null,
                  onTap: () => Navigator.of(ctx).pop(seg),
                ),
              ListTile(
                leading: const Icon(Icons.edit_rounded, size: 20),
                title: const Text('Otro tiempo…'),
                onTap: () => Navigator.of(ctx).pop(-2),
              ),
            ],
          ),
        ),
      ),
    );
    if (elegido == null || !mounted) return;
    if (elegido == -2) {
      final texto = await showDialog<String>(
        context: context,
        builder: (_) =>
            _DialogoSegundos(inicial: _descansoSeg?.toString() ?? ''),
      );
      if (texto == null || !mounted) return;
      final nuevo = int.tryParse(texto.trim());
      if (nuevo == null || nuevo <= 0 || nuevo > 3600) {
        mostrarSnack(context,
            'Ese descanso no es válido (1 a 3600 s): no se aplicó.',
            significado: SignificadoChip.error);
        return;
      }
      setState(() {
        _descansoSeg = nuevo;
        _emitir();
      });
      return;
    }
    setState(() {
      _descansoSeg = elegido < 0 ? null : elegido;
      _emitir();
    });
  }

  Future<void> _editarNota() async {
    final texto = await showDialog<String>(
      context: context,
      builder: (_) =>
          _DialogoNotaEjercicio(titulo: _titulo, inicial: _nota),
    );
    if (texto == null || !mounted) return;
    setState(() {
      _nota = texto.trim();
      _emitir();
    });
  }

  Widget _chipAccion({
    required IconData icono,
    required String texto,
    required VoidCallback? onTap,
    bool marcado = false,
  }) {
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadio.circular),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(
              horizontal: AppEspacio.md, vertical: AppEspacio.sm),
          decoration: BoxDecoration(
            color: AppColores.superficieElevada(context),
            borderRadius: BorderRadius.circular(AppRadio.circular),
            border: Border.all(
              color:
                  marcado ? AppColores.naranja : AppColores.borde(context),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icono,
                  size: 15,
                  color: AppColores.textoSecundario(context)),
              const SizedBox(width: AppEspacio.xs),
              Text(texto,
                  style: AppTexto.etiqueta.copyWith(
                      color: AppColores.textoSecundario(context))),
            ],
          ),
        ),
      ),
    );
  }

  Widget _miniatura() {
    final ficha = widget.ficha!;
    return ClipRRect(
      borderRadius: BorderRadius.circular(AppRadio.sm),
      child: Image(
        image: providerFotoAcotada(
            NetworkImage(
                AppConfig.urlImagenGuia(ficha.slug, ficha.imagenRev)),
            ancho: 240),
        width: 40,
        height: 40,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => _cajaMiniatura(),
        loadingBuilder: (_, hijo, progreso) =>
            progreso == null ? hijo : _cajaMiniatura(),
      ),
    );
  }

  Widget _cajaMiniatura() {
    return Container(
      width: 40,
      height: 40,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: AppColores.superficieHundida(context),
        borderRadius: BorderRadius.circular(AppRadio.sm),
        border: Border.all(color: AppColores.borde(context)),
      ),
      child: Icon(Icons.fitness_center_rounded,
          size: 18, color: AppColores.textoSecundario(context)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final oscuro = Theme.of(context).brightness == Brightness.dark;
    final ficha = widget.ficha;
    return Container(
      decoration: BoxDecoration(
        color: AppColores.superficie(context),
        borderRadius: BorderRadius.circular(AppRadio.lg),
        border: Border.all(color: AppColores.borde(context)),
        // La misma elevación que da Tarjeta (D-18).
        boxShadow: [
          BoxShadow(
            color: (oscuro ? Colors.black : Colors.grey)
                .withValues(alpha: oscuro ? 0.4 : 0.12),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadio.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── Zona 1 · Cabecera ──────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(AppEspacio.md,
                  AppEspacio.md, AppEspacio.sm, AppEspacio.md),
              child: Row(
                children: [
                  if (widget.reordenable)
                    ReorderableDragStartListener(
                      index: widget.indice,
                      child: Padding(
                        padding:
                            const EdgeInsets.only(right: AppEspacio.xs),
                        child: Icon(Icons.drag_handle_rounded,
                            size: 20,
                            color:
                                AppColores.textoSecundario(context)),
                      ),
                    ),
                  Container(
                    width: 26,
                    height: 26,
                    decoration: BoxDecoration(
                      color: AppColores.superficieElevada(context),
                      shape: BoxShape.circle,
                    ),
                    alignment: Alignment.center,
                    child: Text('${widget.indice + 1}',
                        style: AppTexto.etiqueta.copyWith(
                            color:
                                AppColores.textoSecundario(context))),
                  ),
                  const SizedBox(width: AppEspacio.sm),
                  if (ficha != null && ficha.tieneImagen) ...[
                    _miniatura(),
                    const SizedBox(width: AppEspacio.md),
                  ],
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _titulo,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppTexto.subtitulo,
                        ),
                        if (ficha != null &&
                            ficha.equipoNombre.isNotEmpty)
                          Text(
                            ficha.equipoNombre,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppTexto.metadato.copyWith(
                                color: AppColores.textoSecundario(
                                    context)),
                          ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close_rounded),
                    tooltip: 'Quitar ejercicio',
                    onPressed: widget.bloqueado ? null : widget.onQuitar,
                  ),
                ],
              ),
            ),
            if (_nota.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(AppEspacio.lg, 0,
                    AppEspacio.lg, AppEspacio.md),
                child: InkWell(
                  borderRadius: BorderRadius.circular(AppRadio.sm),
                  onTap: widget.bloqueado ? null : _editarNota,
                  child: Row(
                    children: [
                      Icon(Icons.edit_note_rounded,
                          size: 16,
                          color: AppColores.textoSecundario(context)),
                      const SizedBox(width: AppEspacio.sm),
                      Expanded(
                        child: Text(
                          'Nota: $_nota',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppTexto.metadato.copyWith(
                              color: AppColores.textoSecundario(
                                  context)),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            // ── Zona 2 · Series (fondo interior) ───────
            Container(
              decoration: BoxDecoration(
                color: AppColores.superficieHundida(context),
                border: Border(
                  top: BorderSide(
                      color: AppColores.bordeSutil(context)),
                  bottom: BorderSide(
                      color: AppColores.bordeSutil(context)),
                ),
              ),
              padding: const EdgeInsets.fromLTRB(AppEspacio.md,
                  AppEspacio.sm, AppEspacio.md, AppEspacio.md),
              child: Column(
                children: [
                  Row(
                    children: [
                      SizedBox(
                        width: 124,
                        child: Text('SERIE',
                            style: AppTexto.etiqueta.copyWith(
                                color: AppColores.textoSecundario(
                                    context))),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text('KG',
                            textAlign: TextAlign.center,
                            style: AppTexto.etiqueta.copyWith(
                                color: AppColores.textoSecundario(
                                    context))),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text('REPS',
                            textAlign: TextAlign.center,
                            style: AppTexto.etiqueta.copyWith(
                                color: AppColores.textoSecundario(
                                    context))),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text('A',
                            textAlign: TextAlign.center,
                            style: AppTexto.etiqueta.copyWith(
                                color: AppColores.textoSecundario(
                                    context))),
                      ),
                      const SizedBox(width: 32),
                    ],
                  ),
                  const SizedBox(height: AppEspacio.sm),
                  for (var i = 0; i < _series.length; i++)
                    _filaSerie(i),
                ],
              ),
            ),
            // ── Zona 3 · Pie de acciones ───────────────
            Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: AppEspacio.md, vertical: AppEspacio.md),
              child: Wrap(
                spacing: AppEspacio.sm,
                runSpacing: AppEspacio.sm,
                children: [
                  _chipAccion(
                    icono: Icons.add_rounded,
                    texto: 'Serie',
                    onTap: widget.bloqueado
                        ? null
                        : () => setState(() {
                              _series.add(_CtrlsSerie(_series.isEmpty
                                  ? const SerieGymAdmin(repsMin: 10)
                                  : SerieGymAdmin(
                                      tipo: _series.last.tipo,
                                      pesoKg: double.tryParse(
                                          _series.last.peso.text),
                                      repsMin: int.tryParse(_series
                                                  .last.min.text) ??
                                          10,
                                      repsMax: int.tryParse(
                                          _series.last.max.text),
                                    )));
                              _emitir();
                            }),
                  ),
                  _chipAccion(
                    icono: Icons.schedule_rounded,
                    texto: _textoChipDescanso,
                    marcado: _descansoSeg != null,
                    onTap: widget.bloqueado ? null : _editarDescanso,
                  ),
                  _chipAccion(
                    icono: Icons.edit_note_rounded,
                    texto: 'Nota',
                    marcado: _nota.isNotEmpty,
                    onTap: widget.bloqueado ? null : _editarNota,
                  ),
                  if (_series.length > 1)
                    _chipAccion(
                      icono: Icons.copy_all_rounded,
                      texto: 'Aplicar la 1ª a todas',
                      onTap: widget.bloqueado
                          ? null
                          : () => setState(() {
                                final p = _series.first;
                                for (final c in _series.skip(1)) {
                                  c.peso.text = p.peso.text;
                                  c.min.text = p.min.text;
                                  c.max.text = p.max.text;
                                  c.tipo = p.tipo;
                                }
                                _emitir();
                              }),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _filaSerie(int i) {
    final c = _series[i];
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          SizedBox(
            width: 22,
            child: Text('${i + 1}',
                style: AppTexto.secundario.copyWith(
                    color: AppColores.textoSecundario(context)),
                textAlign: TextAlign.center),
          ),
          const SizedBox(width: 6),
          SizedBox(
            width: 96,
            child: _PastillaTipoSerie(
              tipo: c.tipo,
              onTap: widget.bloqueado
                  ? null
                  : () => abrirSelectorTipoSerieAdmin(
                        context,
                        actual: c.tipo,
                        onElegir: (t) => setState(() {
                          c.tipo = t;
                          _emitir();
                        }),
                      ),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: TextField(
              controller: c.peso,
              enabled: !widget.bloqueado,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              textAlign: TextAlign.center,
              decoration: const InputDecoration(isDense: true),
              onChanged: (_) => _emitir(),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: TextField(
              controller: c.min,
              enabled: !widget.bloqueado,
              keyboardType: TextInputType.number,
              textAlign: TextAlign.center,
              decoration: const InputDecoration(isDense: true),
              onChanged: (_) => _emitir(),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: TextField(
              controller: c.max,
              enabled: !widget.bloqueado,
              keyboardType: TextInputType.number,
              textAlign: TextAlign.center,
              decoration: const InputDecoration(isDense: true),
              onChanged: (_) => _emitir(),
            ),
          ),
          SizedBox(
            width: 32,
            child: IconButton(
              icon: const Icon(Icons.close_rounded, size: 18),
              tooltip: 'Quitar serie',
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(
                  minWidth: 32, minHeight: 32),
              onPressed: widget.bloqueado || _series.length <= 1
                  ? null
                  : () => setState(() {
                        _series.removeAt(i).dispose();
                        _emitir();
                      }),
            ),
          ),
        ],
      ),
    );
  }
}

/// Selector múltiple del catálogo (D-22, portado del
/// selector de la app de clientes y re-tokenizado):
/// buscador por título, equipo, sinónimos y músculo;
/// chips por grupo muscular; miniatura por ficha; la
/// selección conserva el orden en que se toca cada ficha
/// (así se arma la rutina) y cada elegida lleva su número
/// de orden. Los vacíos son honestos: catálogo vacío en el
/// teléfono NO es «sin resultados de búsqueda».
class SelectorFichasScreen extends StatefulWidget {
  final List<FichaCatalogo> catalogo;
  final List<String> seleccionInicial;
  const SelectorFichasScreen({
    super.key,
    required this.catalogo,
    required this.seleccionInicial,
  });

  @override
  State<SelectorFichasScreen> createState() =>
      _SelectorFichasScreenState();
}

class _SelectorFichasScreenState extends State<SelectorFichasScreen> {
  late final List<String> _seleccion;
  String _busqueda = '';
  String? _grupo;

  @override
  void initState() {
    super.initState();
    _seleccion = List.of(widget.seleccionInicial);
  }

  List<FichaCatalogo> get _visibles => widget.catalogo
      .where((f) =>
          (_grupo == null || f.grupo == _grupo) &&
          fichaCoincideConBusqueda(f, _busqueda))
      .toList();

  void _alternar(FichaCatalogo f) {
    setState(() {
      if (_seleccion.contains(f.id)) {
        _seleccion.remove(f.id);
      } else {
        _seleccion.add(f.id);
      }
    });
  }

  Widget _miniatura(FichaCatalogo f) {
    if (!f.tieneImagen) return _cajaMiniatura();
    return ClipRRect(
      borderRadius: BorderRadius.circular(AppRadio.sm),
      child: Image(
        image: providerFotoAcotada(
            NetworkImage(AppConfig.urlImagenGuia(f.slug, f.imagenRev)),
            ancho: 264),
        width: 44,
        height: 44,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => _cajaMiniatura(),
        loadingBuilder: (_, hijo, progreso) =>
            progreso == null ? hijo : _cajaMiniatura(),
      ),
    );
  }

  Widget _cajaMiniatura() {
    return Container(
      width: 44,
      height: 44,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: AppColores.superficieHundida(context),
        borderRadius: BorderRadius.circular(AppRadio.sm),
        border: Border.all(color: AppColores.borde(context)),
      ),
      child: Icon(Icons.fitness_center_rounded,
          size: 20, color: AppColores.textoSecundario(context)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final visibles = _visibles;
    final grupos = gruposDelCatalogo(widget.catalogo);
    return Scaffold(
      appBar: appBarIron(context, 'Fichas de GymPedia'),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(AppEspacio.lg,
                AppEspacio.lg, AppEspacio.lg, 0),
            child: TextField(
              decoration: const InputDecoration(
                labelText: 'Buscar ficha',
                hintText: 'Nombre, equipo o músculo…',
                prefixIcon: Icon(Icons.search_rounded),
              ),
              onChanged: (v) => setState(() => _busqueda = v),
            ),
          ),
          if (grupos.length > 1)
            Padding(
              padding: const EdgeInsets.fromLTRB(AppEspacio.lg,
                  AppEspacio.md, AppEspacio.lg, AppEspacio.xs),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    Padding(
                      padding:
                          const EdgeInsets.only(right: AppEspacio.sm),
                      child: ChoiceChip(
                        label: const Text('Todas'),
                        selected: _grupo == null,
                        onSelected: (_) =>
                            setState(() => _grupo = null),
                      ),
                    ),
                    for (final (id, etiqueta) in grupos)
                      Padding(
                        padding:
                            const EdgeInsets.only(right: AppEspacio.sm),
                        child: ChoiceChip(
                          label: Text(etiqueta),
                          selected: _grupo == id,
                          onSelected: (_) =>
                              setState(() => _grupo = id),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          Expanded(
            child: widget.catalogo.isEmpty
                ? const EstadoVacio(
                    icono: Icons.menu_book_rounded,
                    titulo: 'El catálogo está vacío',
                    subtitulo: 'Este teléfono aún no tiene '
                        'fichas de GymPedia: sincroniza la app '
                        'y vuelve a intentarlo.',
                  )
                : visibles.isEmpty
                    ? const EstadoVacio(
                        icono: Icons.search_off_rounded,
                        titulo: 'Ninguna ficha coincide',
                        subtitulo: 'Prueba con otro nombre o '
                            'quita el filtro de grupo.',
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(
                            AppEspacio.lg,
                            AppEspacio.md,
                            AppEspacio.lg,
                            AppEspacio.lg),
                        itemCount: visibles.length,
                        itemBuilder: (ctx, i) {
                          final f = visibles[i];
                          final pos = _seleccion.indexOf(f.id);
                          final elegida = pos >= 0;
                          return Padding(
                            padding: const EdgeInsets.only(
                                bottom: AppEspacio.sm),
                            child: Container(
                              decoration: BoxDecoration(
                                color: AppColores.superficie(context),
                                borderRadius: BorderRadius.circular(
                                    AppRadio.md),
                                border: Border.all(
                                  color: elegida
                                      ? AppColores.naranja
                                      : AppColores.borde(context),
                                  width: elegida ? 1.5 : 1,
                                ),
                              ),
                              child: Material(
                                type: MaterialType.transparency,
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(
                                      AppRadio.md),
                                  onTap: () => _alternar(f),
                                  child: Padding(
                                    padding: const EdgeInsets.all(
                                        AppEspacio.md),
                                    child: Row(
                                      children: [
                                        _miniatura(f),
                                        const SizedBox(
                                            width: AppEspacio.sm),
                                        CircleAvatar(
                                          radius: 16,
                                          backgroundColor: elegida
                                              ? AppColores.naranja
                                              : AppColores
                                                  .superficieElevada(
                                                      context),
                                          child: Text(
                                            elegida ? '${pos + 1}' : '',
                                            style: AppTexto.etiqueta
                                                .copyWith(
                                              fontWeight:
                                                  FontWeight.w800,
                                              color: elegida
                                                  ? AppColores
                                                      .sobreMarca
                                                  : AppColores
                                                      .textoSecundario(
                                                          context),
                                            ),
                                          ),
                                        ),
                                        const SizedBox(
                                            width: AppEspacio.sm),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment
                                                    .start,
                                            children: [
                                              Text(f.titulo,
                                                  style: AppTexto
                                                      .subtitulo),
                                              if (f.equipoNombre
                                                      .isNotEmpty ||
                                                  f.musculoPrincipal
                                                      .isNotEmpty)
                                                Text(
                                                  [
                                                    if (f.equipoNombre
                                                        .isNotEmpty)
                                                      f.equipoNombre,
                                                    if (f
                                                        .musculoPrincipal
                                                        .isNotEmpty)
                                                      f.musculoPrincipal,
                                                  ].join(' · '),
                                                  style: AppTexto
                                                      .metadato
                                                      .copyWith(
                                                          color: AppColores
                                                              .textoSecundario(
                                                                  context)),
                                                ),
                                            ],
                                          ),
                                        ),
                                        Icon(
                                          elegida
                                              ? Icons
                                                  .check_circle_rounded
                                              : Icons
                                                  .radio_button_unchecked_rounded,
                                          color: elegida
                                              ? AppColores.naranja
                                              : AppColores
                                                  .textoSecundario(
                                                      context),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(AppEspacio.lg),
              child: ElevatedButton(
                onPressed: () => Navigator.pop(context, _seleccion),
                child: Text('Listo (${_seleccion.length})'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
