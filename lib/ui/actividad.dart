import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../auth.dart';
import '../cliente_protegido.dart';
import '../fotos.dart';
import '../localdb.dart';
import '../negocio.dart';
import '../permisos_entrenador.dart';
import '../tiempo.dart';
import 'auditoria.dart';
import 'arqueo.dart';
import 'componentes.dart';
import 'diseno.dart';
import 'ficha.dart';
import 'historial_ventas.dart';
import 'servicios.dart';

/// Feed de actividad reciente (v1.0.15).
///
/// Muestra inscripciones, pagos y otras acciones de todos los entrenadores,
/// agrupadas por día, con marcador de no leídas.
class ActividadScreen extends StatefulWidget {
  const ActividadScreen({super.key});

  @override
  State<ActividadScreen> createState() => _ActividadScreenState();
}

/// v1.3.7 (Fase 2, B4): quita tildes para búsqueda insensible
/// a acentos. Mapeo 1:1 para no desplazar índices. Top-level para tests.
String sinTildes(String s) {
  const con = 'áéíóúüñÁÉÍÓÚÜÑ';
  const sin = 'aeiouunAEIOUUN';
  final buf = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    final c = s[i];
    final idx = con.indexOf(c);
    buf.write(idx >= 0 ? sin[idx] : c);
  }
  return buf.toString();
}

/// Terra 1.18: teléfono preferido para WhatsApp. `??` solo cae
/// cuando movil es null, no cuando es '' o espacios; aquí se elige
/// el primer valor no vacío (movil, si no telefono). Top-level
/// para tests, igual que sinTildes.
String telefonoPreferido(Map<String, dynamic> c) {
  final movil = '${c['movil'] ?? ''}'.trim();
  return movil.isNotEmpty ? movil : '${c['telefono'] ?? ''}'.trim();
}

/// 1.18 (Jc 2026-10-29, fix Actividad B): el nombre del inscrito
/// desde el texto del detalle del servidor
/// («Nombre Apellido — 2000 CUP ...»). Top-level para tests.
/// Null si el primer segmento no parece un nombre (1 palabra,
/// dígitos, texto genérico). El nombre NO se inventa: es el texto
/// que el servidor ya escribió en el detalle.
String? nombreDeDetalleActividad(String det) {
  // El formato con nombre siempre trae ' — ' (nombre — resto).
  // Sin ese separador, el detalle no lleva nombre.
  if (!det.contains(' — ')) return null;
  final seg = det.split(' — ').first.trim();
  if (seg.isEmpty || seg.length > 60) return null;
  if (seg.toLowerCase().startsWith('cliente ')) return null;
  final partes = seg.split(RegExp(r'\s+'));
  if (partes.length < 2) return null;
  if (!RegExp(r"^[A-Za-zÁÉÍÓÚÜÑáéíóúüñ'.\- ]+$").hasMatch(seg)) {
    return null;
  }
  return seg;
}

/// Categoría de la actividad según la acción (top-level testeable;
/// [_ActividadScreenState._categoriaDe] delega aquí).
String categoriaActividad(String accion) {
  final a = accion.toLowerCase();
  if (a.contains('inscri')) return 'inscripciones';
  if (a.contains('pago_diario') || a == 'diario') return 'diarios';
  if (a.contains('suplemento') || a.contains('categoria')) {
    return 'suplementos';
  }
  if (a.contains('venta_servicio')) return 'servicios';
  if (a.contains('confirmar_entrega') || a.contains('entrega')) {
    return 'entregas';
  }
  if (a.contains('regalo_cumpleanos') ||
      a.contains('regalar_mes')) {
    return 'mensualidades';
  }
  if (a.contains('pago') && !a.contains('diario')) {
    return 'mensualidades';
  }
  if (a == 'mensual') return 'mensualidades';
  return 'otra';
}

/// ¿La acción del servidor representa un cobro real? (top-level
/// testeable; [_ActividadScreenState._esCobroServidor] delega aquí).
/// Solo cobros suman al KPI (no anulaciones, ediciones, gastos,
/// entregas ni ajustes de precios). Las ventas de servicio SÍ son
/// cobro; su reverso, no.
bool esCobroServidor(String accion) {
  final a = accion.toLowerCase();
  if (a.contains('anular_')) return false;
  if (a.contains('editar_')) return false;
  if (a.contains('revertir')) return false;
  if (a.contains('gasto')) return false;
  if (a.contains('entrega')) return false;
  if (a.contains('ajuste')) return false;
  if (a.contains('regalo_cumpleanos')) return false;
  return a.contains('pago') ||
      a.contains('inscri') ||
      a.contains('venta_suplemento') ||
      a.contains('venta_servicio');
}

/// Línea de detalle legible para la tarjeta y la ficha de actividad.
///
/// El servidor YA escribe el detalle ("Ronnie Coleman (RC) x1 — 30 USD
/// (tasa 1) · stock 19 · Cliente externo (vía APK)"), pero la UI nunca
/// lo mostraba: solo lo usaba para sacar el monto. Esta función lo
/// limpia para mostrarlo: quita "(vía APK)", ids internos, montos (que
/// ya van en el badge) y el nombre del cliente cuando ya es el título,
/// y traduce los tipos crudos de servicio. Si no queda nada, ''.
String lineaDetalleActividad(String det, String titulo) {
  var s = det;
  // Tipos crudos de servicio → etiquetas de la app.
  s = s.replaceAll('dosis_sin_agua', 'Dosis sin agua');
  s = s.replaceAll('dosis_con_agua', 'Dosis + agua');
  s = s.replaceAll('agua_suelta', 'Agua suelta');
  // "(vía APK)" puede venir solo o dentro de un paréntesis con más
  // texto ("(mensual, vía APK)"): quitarlo en ambas formas antes de
  // limpiar los paréntesis que deja vacíos o a medias.
  s = s.replaceAll('(vía APK)', '');
  s = s.replaceAll('vía APK', '');
  s = s.replaceAll(RegExp(r',\s*\)'), ')');
  s = s.replaceAll(RegExp(r'\(\s*,'), '(');
  s = s.replaceAll(RegExp(r'\(venta #\d+\)'), '');
  s = s.replaceAll('(tasa 1)', '');
  s = s.replaceAll(RegExp(r'fuera_de_cierre=\S+'), '');
  // Prefijo "cliente 123 — " o "{título} — "/" {título} ".
  s = s.replaceAll(RegExp(r'^cliente\s+\d+\s+—\s+'), '');
  final t = titulo.trim();
  if (t.isNotEmpty) {
    if (s.startsWith('$t — ')) s = s.substring(t.length + 3);
    if (s.startsWith('$t ')) s = s.substring(t.length + 1);
  }
  // Montos (ya van en el badge) y "c/u" huérfano.
  s = s.replaceAll(RegExp(r'\d+(?:\.\d+)?\s*(CUP|USD)'), '');
  s = s.replaceAll(' c/u', '');
  s = s.replaceAll(RegExp(r'\(\d+(?:\.\d+)?\)'), '');
  // Limpieza de puntuación sobrante.
  s = s.replaceAll(RegExp(r',\s*\)'), ')');
  s = s.replaceAll(RegExp(r'\(\s*,'), '(');
  s = s.replaceAll('()', '');
  s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  s = s.replaceAll('— ·', '·').replaceAll('· —', '·');
  while (s.endsWith('—') || s.endsWith('=') || s.endsWith(',') ||
      s.endsWith('·')) {
    s = s.substring(0, s.length - 1).trim();
  }
  if (s.startsWith('(') && s.endsWith(')') && !s.contains(') (')) {
    s = s.substring(1, s.length - 1).trim();
  }
  return s;
}

/// Comprador de una venta de suplemento, sacado del detalle del
/// servidor ("... · stock 19 · Cliente externo (vía APK)"): el
/// segmento tras el stock. Null si el detalle no trae comprador
/// (venta a cliente: el nombre viene por cliente_id).
String? compradorDetalleActividad(String det) {
  final partes = det.split(' · ');
  for (var i = 0; i < partes.length; i++) {
    if (partes[i].trim().startsWith('stock ') && i + 1 < partes.length) {
      var seg = partes[i + 1].replaceAll('(vía APK)', '').trim();
      if (seg.isEmpty) return null;
      if (seg.startsWith('(promo:')) return null;
      return seg;
    }
  }
  return null;
}

/// P2#2 (Argón, 2026-10-29): ¿esta actividad del feed es propia
/// del entrenador que mira? Mismo criterio que AuditoriaScreen
/// ([esOpMia]): la firma de texto del actor contra el nombre de
/// la sesión. Adaptación necesaria porque el feed NO es una op de
/// la cola: su forma es {actor, cliente_id, ...} sin payload.
/// - Op local en cola (_en_cola): nació en este teléfono, es propia
///   (la cola local solo contiene ops de este dispositivo).
/// - Actor con nombre: se acredita con [esOpMia] sobre una op
///   sintética con ese nombre como firma.
/// - Actor vacío en un item del servidor: NO se acredita como
///   propia (fail-closed). Aquí, a diferencia de la cola, un item
///   sin firma puede ser de cualquier entrenador, así que el
///   default «sin firma = mía» de [esOpMia] no aplica.
/// Top-level para tests.
bool esActividadPropia(Map<String, dynamic> a,
    {String? miActor, int? miTelegramId}) {
  if (a['_en_cola'] == true) return true;
  final actor = '${a['actor'] ?? ''}'.trim();
  if (actor.isEmpty) return false;
  return esOpMia(
    {
      'payload': {'registrado_por_nombre': actor},
    },
    miActor: miActor,
    miTelegramId: miTelegramId,
  );
}

/// v1.3.7 (Fase 2, D2): calcula (texto, esPositiva) de la comparativa.
/// Top-level para tests. Si previo <= 0 devuelve "—".
(String, bool) textoComparativa(
    double actual, double previo, String etiqueta) {
  if (previo <= 0) return ('— vs $etiqueta', true);
  final pct = (actual - previo) / previo * 100;
  final flecha = pct >= 0 ? '↑' : '↓';
  final signo = pct >= 0 ? '+' : '';
  return (
    '$flecha $signo${pct.toStringAsFixed(0)}% vs $etiqueta',
    pct >= 0
  );
}

/// v1.3.7 (Fase 2, B2): ¿el monto total en CUP pasa el filtro?
/// Top-level para tests. filtro: 'todo'|'m500'|'m1000'|'m5000'|'rango'.
bool pasaFiltroMonto(double totalCup, String filtro, double? min,
    double? max) {
  switch (filtro) {
    case 'm500':
      return totalCup > 500;
    case 'm1000':
      return totalCup > 1000;
    case 'm5000':
      return totalCup > 5000;
    case 'rango':
      if (min != null && totalCup < min) return false;
      if (max != null && totalCup > max) return false;
      return true;
    default:
      return true;
  }
}

class _ActividadScreenState extends State<ActividadScreen> {
  List<Map<String, dynamic>> _items = [];
  bool _cargando = true;
  // Mejora Actividad 6: true si el feed del servidor llegó al tope.
  bool _feedRecortado = false;
  // v1.3.3: 6 filtros de categoría (diseño Argón).
  String _filtro =
      'todo'; // todo | mensualidades | inscripciones | diarios |
      // suplementos | servicios | entregas
  String _filtroActor = 'todos'; // todos | nombre del actor
  // v1.2.1: mejoras de actividad
  String _filtroFecha = 'todo'; // todo | hoy | ayer | 7dias | mes | rango
  DateTime? _rangoIni;
  DateTime? _rangoFin;
  String _busqueda = '';
  String _agruparPor = 'dia'; // dia | entrenador
  // v1.3.7 (Fase 2, B2): filtro por monto en CUP.
  // 'todo' | 'm500' (>500) | 'm1000' (>1000) | 'm5000' (>5000) | 'rango'
  String _filtroMonto = 'todo';
  double? _montoMin;
  double? _montoMax;
  // v1.3.7 (Fase 2, B2): tasa USD→CUP del día (ajustes) para comparar
  // montos en una sola moneda. Se carga en _cargar().
  double _tasaUsd = 0;
  final _busquedaCtrl = TextEditingController();
  // v1.4.1 (Pieza 7, D3): serie diaria agregada de 30 días (puente).
  List<Map<String, dynamic>> _serie = [];
  bool _verSerie = true;
  // v1.4.1 (Pieza 7, B3): filtros guardados (ámbito: este
  // dispositivo; se validan al restaurar).
  List<Map<String, dynamic>> _guardados = [];
  // Caché: cliente_id -> nombre y foto_storage
  final Map<int, String> _nombres = {};
  final Map<int, String?> _fotos = {};
  // P2#2 (Argón): ids de clientes protegidos vistos en esta carga
  // (solo tiene contenido para un no-dueño; para el dueño
  // esVistaProtegida es false y queda vacío). Se usa en el detalle
  // para no ofrecer ficha ni recibo de un protegido.
  final Set<int> _protegidosIds = {};
  // v1.3.5 (Fase 1, C4): teléfonos para el recibo por WhatsApp.
  final Map<int, String> _telefonos = {};
  // v1.3.5 (Fase 1, C4): claves de ops no confirmadas para el indicador
  // de sync O(1) en el itemBuilder. Se construye UNA vez por carga.
  final Set<String> _pendientesSync = {};

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    setState(() => _cargando = true);
    final raw = await LocalDb.instance.getMeta('sync_estado_actividad');
    final lista = <Map<String, dynamic>>[];
    if (raw != null && raw.isNotEmpty) {
      try {
        for (final a in jsonDecode(raw) as List) {
          lista.add(Map<String, dynamic>.from(a as Map));
        }
      } catch (_) {}
    }
    // Mejora Actividad 6: el servidor ya manda hasta 500 (antes 50).
    // Si vienen 500, el feed puede estar cortado: se avisa en la UI.
    final nMeta = lista.length;
    // v1.3.3: fusión híbrida — ops locales aún no aplicadas.
    // El servidor NO trae op_uuid; para no duplicar solo se toman las
    // ops en estado pendiente/error/necesita_revision (las 'aplicada'
    // ya vienen en sync_estado_actividad).
    try {
      final db = await LocalDb.instance.db;
      final opsPend = await db.query('ops_queue',
          where: "estado IN ('pendiente', 'error', 'necesita_revision')",
          orderBy: 'creada_ts DESC');
      final actorLocal = AuthService().displayName;
      for (final op in opsPend) {
        final tipo = '${op['tipo'] ?? ''}';
        Map<String, dynamic> payload = {};
        try {
          payload =
              jsonDecode(op['payload'] as String) as Map<String, dynamic>;
        } catch (_) {}
        final cup = await montoCobradoCupOp(op);
        final usd = montoCobradoUsdOp(op);
        lista.add({
          'ts': '${op['creada_ts'] ?? ''}',
          'actor': actorLocal,
          'rol': '',
          'accion': tipo,
          'detalle': _detalleOpLocal(tipo, payload, cup, usd),
          'cliente_id': _clienteIdDePayload(payload),
          '_en_cola': true,
          '_monto_cup': cup,
          '_monto_usd': usd,
        });
      }
      // Reordenar la fusión por ts descendente.
      lista.sort(
          (a, b) => '${b['ts'] ?? ''}'.compareTo('${a['ts'] ?? ''}'));
      // v1.3.5 (Fase 1, C4): set en memoria de ops no confirmadas.
      // PROHIBIDO consultar ops_queue por tarjeta (N+1); se resuelve aquí
      // una sola vez por ciclo y el itemBuilder hace lookup O(1).
      // Incluye 'enviada' y 'rechazada' (Argón): una op enviada aún no está
      // confirmada por el servidor. La fusión de _en_cola NO cambia para
      // no duplicar (una 'enviada' puede ya venir en sync_estado_actividad).
      _pendientesSync.clear();
      void agregarClaveOp(String tipo, Map<String, dynamic> payload,
          String creadaTs) {
        final cid = _clienteIdDePayload(payload);
        final dia =
            creadaTs.length >= 10 ? creadaTs.substring(0, 10) : '';
        _pendientesSync.add('${_categoriaDe(tipo)}|${cid ?? ''}|$dia');
      }

      for (final op in opsPend) {
        Map<String, dynamic> payload = {};
        try {
          payload =
              jsonDecode(op['payload'] as String) as Map<String, dynamic>;
        } catch (_) {}
        agregarClaveOp('${op['tipo'] ?? ''}', payload,
            '${op['creada_ts'] ?? ''}');
      }
      try {
        final opsProc = await db.query('ops_queue',
            columns: ['tipo', 'payload', 'creada_ts'],
            where: "estado IN ('enviada', 'rechazada')");
        for (final op in opsProc) {
          Map<String, dynamic> payload = {};
          try {
            payload = jsonDecode(op['payload'] as String)
                as Map<String, dynamic>;
          } catch (_) {}
          agregarClaveOp('${op['tipo'] ?? ''}', payload,
              '${op['creada_ts'] ?? ''}');
        }
      } catch (_) {}
    } catch (_) {}
    // P2#2 (Argón): recorte de visibilidad para no-dueños, ANTES
    // de resolver nombres. Fail-closed: sin dueño confirmado, se
    // recorta (igual que AuditoriaScreen). Solo acciones propias.
    var esDueno = false;
    String? miActor;
    int? miTelegramId;
    try {
      esDueno = AuthService().isOwner;
      miActor = AuthService().displayName;
      miTelegramId = AuthService().telegramId;
    } catch (_) {
      esDueno = false;
      miActor = null;
      miTelegramId = null;
    }
    if (!esDueno) {
      lista.removeWhere((a) => !esActividadPropia(a,
          miActor: miActor, miTelegramId: miTelegramId));
    }
    // P2#19 (Argón): UNA sola consulta al espejo para todos los
    // clientes distintos del feed, en vez de un clientePorId
    // secuencial por cliente.
    final idsDistintos = <int>{};
    for (final a in lista) {
      final id = _clienteIdDe(a);
      if (id != null) idsDistintos.add(id);
    }
    Map<int, Map<String, dynamic>> porId = {};
    try {
      final filas = await LocalDb.instance
          .mirrorPorIds('clientes', idsDistintos.toList());
      for (final f in filas) {
        final rid = f['id'];
        int? ridInt;
        if (rid is int) {
          ridInt = rid;
        } else if (rid is num) {
          ridInt = rid.toInt();
        } else if (rid is String) {
          ridInt = int.tryParse(rid);
        }
        if (ridInt != null) porId[ridInt] = f;
      }
    } catch (_) {
      // Espejo no disponible: se sigue con marcadores
      // 'Cliente $id', sin nombres ni teléfonos reales.
      porId = {};
    }
    // P2#2 (Argón): un protegido nunca entra en la lista de un
    // no-dueño, ni su nombre ni su foto ni su teléfono se precargan.
    // Para el dueño esVistaProtegida es false y no se quita nada.
    _protegidosIds.clear();
    for (final f in porId.values) {
      if (esVistaProtegida(f, esDueno: esDueno)) {
        final rid = f['id'];
        int? ridInt;
        if (rid is int) {
          ridInt = rid;
        } else if (rid is num) {
          ridInt = rid.toInt();
        } else if (rid is String) {
          ridInt = int.tryParse(rid);
        }
        if (ridInt != null) _protegidosIds.add(ridInt);
      }
    }
    if (!esDueno) {
      lista.removeWhere((a) {
        final id = _clienteIdDe(a);
        return id != null && _protegidosIds.contains(id);
      });
    }
    // v1.2.1: resolver nombres y fotos de clientes para cada item.
    _nombres.clear();
    _fotos.clear();
    _telefonos.clear();
    for (final a in lista) {
      final id = _clienteIdDe(a);
      if (id != null && !_nombres.containsKey(id)) {
        final c = porId[id];
        if (c != null) {
          _nombres[id] = '${c['nombre'] ?? 'Cliente $id'}';
          _fotos[id] = c['foto_storage'] as String?;
          // 5ta pasada (A1, mismo arreglo que el camino por
          // nombre): priorizar movil sobre telefono.
          final tel = telefonoPreferido(c);
          if (tel.isNotEmpty) _telefonos[id] = tel;
        } else {
          _nombres[id] = 'Cliente $id';
          _fotos[id] = null;
        }
      }
    }
    // v1.4.1 (Pieza 7): serie diaria para el mini gráfico.
    try {
      final rawSerie =
          await LocalDb.instance.getMeta('sync_estado_actividad_serie');
      if (rawSerie != null && rawSerie.isNotEmpty) {
        _serie = [
          for (final e in jsonDecode(rawSerie) as List)
            Map<String, dynamic>.from(e as Map)
        ];
        // Frescura (panel T4): la serie del puente SIEMPRE
        // termina en hoy (Habana). Si la guardada termina antes
        // de ayer, está vencida: no se presenta como actual.
        if (_serie.isNotEmpty) {
          final hoy = hoyHabanaIso();
          final ayer = DateTime.parse(hoy)
              .subtract(const Duration(days: 1))
              .toIso8601String()
              .substring(0, 10);
          final ultima = '${_serie.last['fecha'] ?? ''}';
          if (ultima != hoy && ultima != ayer) _serie = [];
        }
      }
    } catch (_) {}
    await _cargarGuardados();
    if (mounted) {
      setState(() {
        _items = lista;
        _cargando = false;
        _feedRecortado = nMeta >= 500;
      });
    }
    // v1.3.7 (Fase 2, B2): tasa del día para el filtro por monto.
    try {
      final aj = await LocalDb.instance.getAjustes();
      final t = (aj['tasa_usd'] as num?)?.toDouble() ?? 0;
      if (mounted && t > 0) setState(() => _tasaUsd = t);
    } catch (_) {}
    // Marcar como leídas al abrir
    _marcarLeidas();
  }

  @override
  void dispose() {
    _busquedaCtrl.dispose();
    super.dispose();
  }

  /// v1.4.1 (Pieza 7, B3): lee los filtros guardados del
  /// dispositivo (SharedPreferences). Formato: lista de objetos
  /// con nombre + los campos del filtro.
  Future<void> _cargarGuardados() async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString('actividad_filtros_guardados');
      if (raw != null && raw.isNotEmpty) {
        _guardados = [
          for (final e in jsonDecode(raw) as List)
            Map<String, dynamic>.from(e as Map)
        ];
      }
    } catch (_) {}
  }

  Future<void> _persistirGuardados() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(
          'actividad_filtros_guardados', jsonEncode(_guardados));
    } catch (_) {}
  }

  Map<String, dynamic> _snapshotFiltros(String nombre) => {
        'nombre': nombre,
        'filtro': _filtro,
        'filtroActor': _filtroActor,
        'filtroFecha': _filtroFecha,
        'rangoIni': _rangoIni?.toIso8601String(),
        'rangoFin': _rangoFin?.toIso8601String(),
        'agruparPor': _agruparPor,
        'filtroMonto': _filtroMonto,
        'montoMin': _montoMin,
        'montoMax': _montoMax,
      };

  /// v1.4.1 (Pieza 7, B3): aplica un guardado VALIDANDO cada campo
  /// contra los valores conocidos (diseño: al restaurar se valida
  /// que los campos sigan existiendo; un entrenador que ya no
  /// aparece degrada a "todos", un valor raro degrada a su default).
  void _aplicarGuardado(Map<String, dynamic> g) {
    const tipos = {
      'todo', 'mensualidades', 'inscripciones', 'diarios',
      'suplementos', 'servicios', 'entregas'
    };
    const fechas = {'todo', 'hoy', 'ayer', '7dias', 'mes', 'rango'};
    const montos = {'todo', 'm500', 'm1000', 'm5000', 'rango'};
    var actor = '${g['filtroActor'] ?? 'todos'}';
    if (actor != 'todos' && !_actores.contains(actor)) {
      actor = 'todos';
    }
    // Parseo seguro de montos (panel T4): un valor de otro tipo
    // NO lanza; degrada a null. Negativos/no finitos se descartan.
    // Un solo límite SÍ es válido (la hoja de filtros lo permite
    // crear); min > max con ambos presentes invalida ambos.
    double? montoSeguro(dynamic v) {
      if (v is! num) return null;
      final d = v.toDouble();
      return (d.isFinite && d >= 0) ? d : null;
    }

    var montoMinOk = montoSeguro(g['montoMin']);
    var montoMaxOk = montoSeguro(g['montoMax']);
    if (montoMinOk != null && montoMaxOk != null && montoMinOk > montoMaxOk) {
      montoMinOk = null;
      montoMaxOk = null;
    }
    setState(() {
      _filtro = tipos.contains(g['filtro']) ? '${g['filtro']}' : 'todo';
      _filtroActor = actor;
      _filtroFecha =
          fechas.contains(g['filtroFecha']) ? '${g['filtroFecha']}' : 'todo';
      _rangoIni = DateTime.tryParse('${g['rangoIni'] ?? ''}');
      _rangoFin = DateTime.tryParse('${g['rangoFin'] ?? ''}');
      // Rango incompleto o invertido = no válido (panel T4):
      // degrada a 'todo' en vez de aplicar un rango roto.
      if (_filtroFecha == 'rango' &&
          (_rangoIni == null ||
              _rangoFin == null ||
              _rangoIni!.isAfter(_rangoFin!))) {
        _filtroFecha = 'todo';
      }
      if (_filtroFecha != 'rango') {
        _rangoIni = null;
        _rangoFin = null;
      }
      _agruparPor = g['agruparPor'] == 'entrenador' ? 'entrenador' : 'dia';
      _filtroMonto =
          montos.contains(g['filtroMonto']) ? '${g['filtroMonto']}' : 'todo';
      _montoMin = montoMinOk;
      _montoMax = montoMaxOk;
      if (_filtroMonto == 'rango' && _montoMin == null && _montoMax == null) {
        _filtroMonto = 'todo';
      }
      if (_filtroMonto != 'rango') {
        _montoMin = null;
        _montoMax = null;
      }
    });
  }

  Future<void> _guardarFiltroActual() async {
    final ctrl = TextEditingController();
    final nombre = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Guardar filtros'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(
              labelText: 'Nombre (ej. Cobros de Gabriel)'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(ctx).pop(ctrl.text.trim()),
            child: const Text('Guardar'),
          ),
        ],
      ),
    );
    if (nombre == null || nombre.isEmpty || !mounted) return;
    setState(() {
      _guardados.removeWhere((g) => g['nombre'] == nombre);
      _guardados.add(_snapshotFiltros(nombre));
    });
    await _persistirGuardados();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Filtros «$nombre» guardados')));
    }
  }

  /// v1.4.1 (Pieza 7, D3): tarjeta del mini gráfico de la serie.
  Widget _tarjetaSerie() {
    if (!_verSerie || _serie.length < 7) {
      return const SizedBox.shrink();
    }
    final hayDatos =
        _serie.any((d) => ((d['total'] as num?)?.toInt() ?? 0) > 0);
    if (!hayDatos) return const SizedBox.shrink();
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text('Acciones por día · últimos 30 días',
                      style: TextStyle(
                          fontSize: 12, fontWeight: FontWeight.w600)),
                ),
                InkWell(
                  onTap: () => setState(() => _verSerie = false),
                  child: const Icon(Icons.close,
                      size: 16, color: Colors.grey),
                ),
              ],
            ),
            const SizedBox(height: 6),
            GraficoBarrasDiarias(datos: _serie, altura: 56),
          ],
        ),
      ),
    );
  }

  Future<void> _marcarLeidas() async {
    final p = await SharedPreferences.getInstance();
    // P2#11 (Argón): hora Habana, no UTC crudo. isoHabana lleva el
    // offset explícito, así que actividadNoLeidas (que parsea y pasa
    // a UTC) sigue comparando el mismo instante.
    await p.setString(
        'actividad_vista_ts', isoHabana(ahoraHabana()));
  }

  List<Map<String, dynamic>> get _filtrados {
    final q = _busqueda.trim().toLowerCase();
    return _items.where((a) {
      // v1.3.3: filtro por categoría (diseño Argón).
      if (_filtro != 'todo') {
        if (_categoriaDe('${a['accion'] ?? ''}') != _filtro) {
          return false;
        }
      }
      // v1.0.15: filtro por entrenador/actor
      if (_filtroActor != 'todos') {
        if ('${a['actor'] ?? ''}' != _filtroActor) return false;
      }
      // v1.2.1: filtro por fecha
      if (_filtroFecha != 'todo') {
        final ts = '${a['ts'] ?? ''}';
        final dia = ts.length >= 10 ? ts.substring(0, 10) : '';
        // P2#11 (Argón): hoy/ayer/7 días/mes en hora Habana.
        final ahora = ahoraHabana();
        final hoyStr = _isoDia(ahora);
        final ayerStr =
            _isoDia(ahora.subtract(const Duration(days: 1)));
        switch (_filtroFecha) {
          case 'hoy':
            if (dia != hoyStr) return false;
            break;
          case 'ayer':
            if (dia != ayerStr) return false;
            break;
          case '7dias':
            final limite = _isoDia(
                ahora.subtract(const Duration(days: 7)));
            if (dia.compareTo(limite) < 0) return false;
            break;
          case 'mes':
            final pref =
                '${ahora.year}-${ahora.month.toString().padLeft(2, '0')}';
            if (!dia.startsWith(pref)) return false;
            break;
          case 'rango':
            if (_rangoIni != null) {
              if (dia.compareTo(_isoDia(_rangoIni!)) < 0) {
                return false;
              }
            }
            if (_rangoFin != null) {
              if (dia.compareTo(_isoDia(_rangoFin!)) > 0) {
                return false;
              }
            }
            break;
        }
      }
      // v1.2.1: buscador por nombre de cliente o texto del detalle
      if (q.isNotEmpty) {        final id = _clienteIdDe(a);
        final nombre = id != null ? (_nombres[id] ?? '') : '';
        final detalle = '${a['detalle'] ?? ''}'.toLowerCase();
        final actor = '${a['actor'] ?? ''}'.toLowerCase();
        if (!nombre.toLowerCase().contains(q) &&
            !detalle.contains(q) &&
            !actor.contains(q)) {
          return false;
        }
      }
      // v1.3.7 (Fase 2, B2): filtro por monto en CUP.
      if (!_pasaFiltroMonto(a)) return false;
      return true;
    }).toList();
  }

  String _isoDia(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  /// v1.0.15: actores únicos para el filtro por entrenador.
  List<String> get _actores {
    final s = <String>{};
    for (final a in _items) {
      final actor = '${a['actor'] ?? ''}'.trim();
      if (actor.isNotEmpty) s.add(actor);
    }
    final l = s.toList()..sort();
    return l;
  }

  /// v1.1: usa cliente_id del servidor; fallback a regex para
  /// entradas antiguas (v1.0.15).
  int? _clienteIdDe(Map<String, dynamic> a) {
    final cid = a['cliente_id'];
    if (cid is int) return cid;
    if (cid is String) return int.tryParse(cid);
    final det = '${a['detalle'] ?? ''}';
    final m = RegExp(r'cliente\s+(\d+)').firstMatch(det);
    if (m != null) return int.tryParse(m.group(1)!);
    return null;
  }

  /// 1.18 (fix Actividad B): busca el nombre en el espejo local.
  /// Devuelve la fila solo si resuelve a UN solo cliente; null
  /// si ninguno o varios (ambiguo: no se puede afirmar quién es).
  /// Solo se llama desde el detalle (al tocar), nunca al armar
  /// la lista, para no escanear el espejo por cada fila.
  Future<Map<String, dynamic>?> _clienteUnicoPorNombre(
      String nombre) async {
    // 5ta pasada (A2): plegar tildes en ambos lados: el texto
    // de actividad es inmutable y la ficha puede haberse
    // corregido después ("Maria Rodriguez" → "María Rodríguez").
    final norm = sinTildes(nombre)
        .toLowerCase()
        .trim()
        .replaceAll(RegExp(r'\s+'), ' ');
    Map<String, dynamic>? unico;
    var n = 0;
    for (final c in await LocalDb.instance.allMirror('clientes')) {
      final nom = sinTildes('${c['nombre'] ?? ''}')
          .toLowerCase()
          .trim()
          .replaceAll(RegExp(r'\s+'), ' ');
      if (nom.isNotEmpty && nom == norm) {
        n++;
        unico = c;
        if (n > 1) return null;
      }
    }
    return n == 1 ? unico : null;
  }

  /// v1.3.3: extrae cliente_id del payload de una op local.
  int? _clienteIdDePayload(Map<String, dynamic> payload) {
    for (final k in ['cliente_id', 'id']) {
      final v = payload[k];
      if (v is int) return v;
      if (v is String) {
        final n = int.tryParse(v);
        if (n != null) return n;
      }
    }
    final c = payload['cliente'];
    if (c is Map<String, dynamic>) {
      final v = c['id'];
      if (v is int) return v;
      if (v is String) return int.tryParse(v);
    }
    return null;
  }

  /// v1.3.3: detalle legible para una op local en cola.
  String _detalleOpLocal(String tipo, Map<String, dynamic> payload,
      double cup, double usd) {
    final montoTxt = usd > 0
        ? '${fmtMonto(usd)} USD'
        : (cup > 0 ? '${fmtMonto(cup)} CUP' : '');
    switch (tipo) {
      case 'pago_mensual':
      case 'pago':
      case 'mensual':
        final per = '${payload['periodo'] ?? 'mensual'}';
        final met = '${payload['metodo'] ?? 'efectivo'}';
        return 'Pago mensual ($per, $met)${montoTxt.isNotEmpty ? ' — $montoTxt' : ''}';
      case 'pago_diario':
      case 'diario':
        final cant = payload['cantidad'] ?? '';
        return 'Pago diario x$cant${montoTxt.isNotEmpty ? ' — $montoTxt' : ''}';
      case 'inscribir':
        return 'Inscripción${montoTxt.isNotEmpty ? ' — $montoTxt' : ''}';
      case 'inscripcion_venta_suplemento':
        return 'Inscripción + venta${montoTxt.isNotEmpty ? ' — $montoTxt' : ''}';
      case 'venta_suplemento':
        // v1.3.3 (Argón): montoTxt ya trae la moneda; no repetir $moneda.
        final nombre =
            '${payload['suplemento_nombre'] ?? payload['nombre'] ?? 'Suplemento'}';
        final cant = payload['cantidad'] ?? '';
        return '$nombre x$cant${montoTxt.isNotEmpty ? ' — $montoTxt' : ''}';
      case 'confirmar_entrega':
        return 'Confirmar entrega de cobros';
      case 'regalar_mes_cumpleanos':
      case 'regalo_cumpleanos':
        return 'Mes gratis (cumpleaños)';
      case 'foto':
        return 'Foto de cliente';
      case 'foto_suplemento':
        return 'Foto de suplemento';
      default:
        return tipo.replaceAll('_', ' ');
    }
  }

  /// v1.3.3: categoría de la actividad según la acción
  /// (diseño Argón, 6 filtros). Delega en [categoriaActividad].
  String _categoriaDe(String accion) => categoriaActividad(accion);

  /// v1.3.3: ¿la acción del servidor representa un cobro real?
  /// Solo cobros suman al KPI (no anulaciones, ediciones, gastos,
  /// entregas ni ajustes de precios). Delega en [esCobroServidor].
  bool _esCobroServidor(String accion) => esCobroServidor(accion);

  /// v1.3.7 (Fase 2, B2): monto total del item en CUP (para el filtro
  /// por monto). Convierte USD→CUP con la tasa del día; si no hay tasa,
  /// el USD no se convierte (solo suma el CUP).
  double _montoCupTotal(Map<String, dynamic> a) {
    double cup = 0, usd = 0;
    if (a['_en_cola'] == true) {
      cup = (a['_monto_cup'] as num?)?.toDouble() ?? 0;
      usd = (a['_monto_usd'] as num?)?.toDouble() ?? 0;
    } else {
      final m = _montoServidor('${a['detalle'] ?? ''}');
      cup = m.$1;
      usd = m.$2;
    }
    return cup + (_tasaUsd > 0 ? usd * _tasaUsd : 0);
  }

  /// v1.3.7 (Fase 2, B2): ¿el item pasa el filtro por monto?
  /// Usa la función top-level [pasaFiltroMonto] (testeable).
  bool _pasaFiltroMonto(Map<String, dynamic> a) {
    if (_filtroMonto == 'todo') return true;
    return pasaFiltroMonto(
        _montoCupTotal(a), _filtroMonto, _montoMin, _montoMax);
  }

  /// v1.3.3: extrae (cup, usd) del detalle del servidor.
  /// Suma TODOS los montos encontrados: una inscripcion_venta_suplemento
  /// trae el de la inscripción en CUP y el de la venta (CUP o USD).
  /// v1.3.3 (Argón): allMatches en vez de firstMatch.
  (double, double) _montoServidor(String detalle) {
    var cup = 0.0;
    var usd = 0.0;
    for (final m
        in RegExp(r'(\d+(?:\.\d+)?)\s*(CUP|USD)').allMatches(detalle)) {
      final v = double.tryParse(m.group(1)!) ?? 0;
      if (m.group(2) == 'USD') {
        usd += v;
      } else {
        cup += v;
      }
    }
    return (cup, usd);
  }

  /// Mejora Actividad 2: filas estructuradas de una venta de
  /// suplemento en la ficha: producto, cantidad, comprador, stock
  /// restante, tasa y promo. Lo que no trae el detalle, no se inventa:
  /// el comprador es el nombre resuelto, el del texto del servidor o
  /// "Cliente externo / mostrador".
  List<Widget> _filasVentaSuplemento(
      Map<String, dynamic> a, String? nombreCli) {
    final det = '${a['detalle'] ?? ''}';
    final filas = <Widget>[];
    void fila(String etiqueta, String valor) {
      filas.add(const SizedBox(height: 4));
      filas.add(Text('$etiqueta: $valor', style: AppTexto.cuerpo));
    }

    var base = det.replaceAll('Venta anulada: ', '');
    final mProd = RegExp(r'^(.*?)\s+x\d+').firstMatch(base);
    if (mProd != null && mProd.group(1)!.trim().isNotEmpty) {
      fila('Producto', mProd.group(1)!.trim());
    }
    final mCant = RegExp(r'x(\d+)').firstMatch(base);
    if (mCant != null) fila('Cantidad', mCant.group(1)!);
    final comprador = (nombreCli != null &&
            !nombreCli.startsWith('Cliente '))
        ? nombreCli
        : (compradorDetalleActividad(det) ?? 'Cliente externo / mostrador');
    fila('Comprador', comprador);
    final mStock = RegExp(r'stock (\d+)').firstMatch(det);
    if (mStock != null) fila('Stock restante', mStock.group(1)!);
    final mTasa = RegExp(r'\(tasa ([^)]+)\)').firstMatch(det);
    if (mTasa != null && mTasa.group(1)!.trim() != '1') {
      fila('Tasa USD', mTasa.group(1)!);
    }
    if (det.contains('(promo: mes gratis)')) {
      fila('Promo', 'mes gratis aplicado');
    }
    return filas;
  }

  /// Mejora Actividad 7: destino del salto al registro original
  /// según el tipo. Null si el tipo no tiene destino (los pagos ya
  /// tienen "Ver ficha" por cliente).
  (String, Widget)? _destinoSalto(String accion) {
    final a = accion.toLowerCase();
    if (a.contains('venta_suplemento')) {
      return ('Ver ventas', const HistorialVentasScreen());
    }
    if (a.contains('venta_servicio')) {
      return ('Ver servicios', const ServiciosScreen());
    }
    if (a.contains('confirmar_entrega') || a.contains('c1_entrega')) {
      return ('Ver arqueo', const ArqueoScreen());
    }
    return null;
  }

  /// v1.3.5 (Fase 1, E1+E2): modal de detalle al tocar la tarjeta.
  /// Aloja el botón "Recibo WhatsApp" (wa.me) y el acceso a la ficha.
  Future<void> _abrirDetalle(Map<String, dynamic> a) async {
    final accion = '${a['accion'] ?? ''}';
    var cliId = _clienteIdDe(a);
    // 1.18 (Jc 2026-10-29, fix Actividad B): sin cliente_id, el
    // nombre SÍ viaja en el texto del detalle del servidor
    // («Nombre Apellido — 2000 CUP ...»). Si resuelve a un solo
    // cliente del espejo, se trata como cliente (título, ficha,
    // WhatsApp); si no resuelve a uno único, solo el dueño ve el
    // nombre del texto (resguardo protegido: un nombre ambiguo
    // nunca se muestra como hecho a un entrenador).
    String? nombreTexto;
    if (cliId == null) {
      nombreTexto = nombreDeDetalleActividad('${a['detalle'] ?? ''}');
      if (nombreTexto != null) {
        // Si el espejo falla, el detalle igual abre: sin cliente
        // resuelto, el dueño ve el nombre del texto y el entrenador
        // ve el título genérico. Nunca se cae el detalle por esto.
        try {
          final unico = await _clienteUnicoPorNombre(nombreTexto);
          // P2#2 (Argón, compone con el fix 1.18): si el nombre
          // resuelve a un cliente protegido, un no-dueño NO lo
          // resuelve: queda sin cliente (título genérico, sin ficha
          // ni recibo). esVistaProtegida falla cerrado si Auth no
          // se resuelve, así que el dueño en sesión normal sí pasa.
          if (unico != null && !esVistaProtegida(unico)) {
            cliId = (unico['id'] as num).toInt();
            _nombres[cliId] = '${unico['nombre'] ?? nombreTexto}';
            // 5ta pasada (A1): el móvil de WhatsApp vive en
            // movil; telefono guarda carnet o fijo. Priorizar
            // movil (el resto de la app hace lo mismo).
            final tel = telefonoPreferido(unico);
            if (tel.isNotEmpty) _telefonos[cliId] = tel;
          }
        } catch (_) {
          // Espejo no disponible: se sigue sin resolución (el dueño
          // ve el nombre del texto, el entrenador el título
          // genérico). Degradación segura, no un fallo del detalle.
        }
      }
    }
    final tieneCliente = cliId != null;
    // P2#2 (Argón): cliente protegido visto por un no-dueño. El
    // conjunto solo se llena en _cargar para no-dueños, así que
    // para el dueño siempre es false aquí.
    final esProtegido =
        cliId != null && _protegidosIds.contains(cliId);
    final nombreCli = cliId != null ? _nombres[cliId] : null;
    final titulo = (nombreCli != null &&
            !nombreCli.startsWith('Cliente '))
        ? nombreCli
        : (cliId == null &&
                nombreTexto != null &&
                AuthService().isOwner
            ? nombreTexto
            : _tituloAccion(accion));
    // Entrada resuelta por nombre: la ficha y el recibo re-derivan
    // el id desde la entrada, así que se les pasa la entrada con
    // el id ya resuelto.
    final aRes = cliId != null ? {...a, 'cliente_id': cliId} : a;
    final subtitulo = _subtituloNuevo(a, titulo);
    final pendiente = _pendienteSync(a);
    // Monto para el recibo.
    double cup = 0, usd = 0;
    if (a['_en_cola'] == true) {
      cup = (a['_monto_cup'] as num?)?.toDouble() ?? 0;
      usd = (a['_monto_usd'] as num?)?.toDouble() ?? 0;
    } else if (_esCobroServidor(accion)) {
      final m = _montoServidor('${a['detalle'] ?? ''}');
      cup = m.$1;
      usd = m.$2;
    }
    final montoTxt = usd > 0
        ? '${fmtMonto(usd)} USD'
        : (cup > 0 ? '${fmtMonto(cup)} CUP' : '');
    final telefono =
        cliId != null ? (_telefonos[cliId] ?? '') : '';
    final waNum = normalizarTelefonoWaMe(telefono);
    final fechaLarga = _fechaHoraLarga('${a['ts'] ?? ''}');
    if (!mounted) return;
    await showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
            top: Radius.circular(AppRadio.xl)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppColores.borde(context),
                    borderRadius:
                        BorderRadius.circular(AppRadio.sm),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: Text(titulo,
                        style: AppTexto.titulo
                            .copyWith(fontSize: 18)),
                  ),
                  _indicadorSync(pendiente),
                ],
              ),
              if (subtitulo.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(subtitulo,
                    style: AppTexto.secundario.copyWith(
                        color: AppColores.textoSecundario(
                            context))),
              ],
              // Mejora Actividad 1: el detalle del servidor visible
              // (producto, período, etc.), no solo monto y fecha.
              if (lineaDetalleActividad('${a['detalle'] ?? ''}', titulo)
                  .isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                    lineaDetalleActividad(
                        '${a['detalle'] ?? ''}', titulo),
                    style: AppTexto.cuerpo),
              ],
              // Mejora Actividad 2: filas de la venta de suplemento.
              if (accion.contains('venta_suplemento'))
                ..._filasVentaSuplemento(a, nombreCli),
              if (montoTxt.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(montoTxt,
                    style: const TextStyle(
                        color: AppColores.exito,
                        fontSize: 22,
                        fontWeight: FontWeight.bold)),
              ],
              const SizedBox(height: 8),
              if (fechaLarga.isNotEmpty)
                Text('Fecha: $fechaLarga',
                    style: AppTexto.cuerpo),
              const SizedBox(height: 16),
              Row(
                children: [
                  // P2#2 (Argón): de un protegido, un no-dueño no
                  // recibe ni «Ver ficha» ni «Recibo WhatsApp».
                  if (tieneCliente && !esProtegido)
                    Expanded(
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.person_outline,
                            size: 18),
                        label: const Text('Ver ficha'),
                        onPressed: () {
                          Navigator.of(ctx).pop();
                          _abrirFicha(aRes);
                        },
                      ),
                    ),
                  if (tieneCliente && !esProtegido && waNum.isNotEmpty)
                    const SizedBox(width: 8),
                  if (!esProtegido && waNum.isNotEmpty)
                    Expanded(
                      child: ElevatedButton.icon(
                        icon: const Icon(Icons.share, size: 18),
                        label: const Text('Recibo WhatsApp'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor:
                              AppColores.naranja,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius:
                                BorderRadius.circular(
                                    AppRadio.md),
                          ),
                        ),
                        onPressed: () {
                          Navigator.of(ctx).pop();
                          _compartirRecibo(
                              aRes, titulo, montoTxt, waNum);
                        },
                      ),
                    ),
                ],
              ),
              // Mejora Actividad 7: salto al registro original.
              if (_destinoSalto(accion) != null) ...[
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.open_in_new, size: 18),
                    label: Text(_destinoSalto(accion)!.$1),
                    onPressed: () {
                      Navigator.of(ctx).pop();
                      Navigator.of(context).push(
                        MaterialPageRoute(
                            builder: (_) =>
                                _destinoSalto(accion)!.$2),
                      );
                    },
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// v1.3.5 (Fase 1, E2): comparte el recibo por wa.me con el formato
  /// existente del proyecto (normalizarTelefonoWaMe + launchUrl).
  Future<void> _compartirRecibo(Map<String, dynamic> a, String titulo,
      String montoTxt, String waNum) async {
    // P2#2 (Argón, defensa en profundidad): aunque el botón ya no
    // se ofrece para un protegido, el recibo tampoco se comparte
    // si se invocara por otra vía.
    final idRecibo = _clienteIdDe(a);
    if (idRecibo != null && _protegidosIds.contains(idRecibo)) {
      return;
    }
    final subtitulo = _subtituloNuevo(a, titulo);
    final fechaLarga = _fechaHoraLarga('${a['ts'] ?? ''}');
    final actor = '${a['actor'] ?? ''}'.trim();
    final buf = StringBuffer()
      ..writeln('*Iron Body Gym* — Recibo')
      ..writeln('Cliente: $titulo');
    if (montoTxt.isNotEmpty) buf.writeln('Monto: $montoTxt');
    if (subtitulo.isNotEmpty) buf.writeln('Detalle: $subtitulo');
    if (fechaLarga.isNotEmpty) buf.writeln('Fecha: $fechaLarga');
    if (actor.isNotEmpty) buf.writeln('Cobrado por: $actor');
    final url = Uri.parse(
        'https://wa.me/$waNum?text=${Uri.encodeComponent(buf.toString().trim())}');
    try {
      await launchUrl(url, mode: LaunchMode.externalApplication);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('No se pudo abrir WhatsApp')),
        );
      }
    }
  }

  /// v1.3.5: "dd/MM/yyyy HH:mm" para el detalle.
  String _fechaHoraLarga(String ts) {
    if (ts.isEmpty) return '';
    try {
      final dt = DateTime.parse(ts).toLocal();
      return '${dt.day.toString().padLeft(2, '0')}/'
          '${dt.month.toString().padLeft(2, '0')}/${dt.year} '
          '${dt.hour.toString().padLeft(2, '0')}:'
          '${dt.minute.toString().padLeft(2, '0')}';
    } catch (_) {
      return '';
    }
  }

  Future<void> _abrirFicha(Map<String, dynamic> a) async {
    final id = _clienteIdDe(a);
    if (id == null) return;
    // Verificar que el cliente existe localmente
    final c = await clientePorId(id);
    if (c == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Cliente no disponible offline')),
        );
      }
      return;
    }
    // P2#2 (Argón, defensa en profundidad): un protegido no abre
    // su ficha para un no-dueño aunque llegara aquí por otra vía.
    // esVistaProtegida es owner-safe: al dueño no lo bloquea.
    if (esVistaProtegida(c)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text(mensajeClienteProtegido)),
        );
      }
      return;
    }
    if (mounted) {
      await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => FichaScreen(clienteId: id)),
      );
    }
  }

  /// Icono Material por tipo de acción (v1.1: sin emojis).
  IconData _iconoAccion(String accion) {
    if (accion.contains('inscri')) return Icons.person_add;
    if (accion.contains('pago_diario')) return Icons.receipt_long;
    if (accion.contains('pago')) return Icons.payments;
    // v1.3.3: iconos por categoría (diseño Argón).
    if (accion.contains('regalo_cumpleanos') ||
        accion.contains('regalar_mes')) {
      return Icons.card_giftcard;
    }
    if (accion.contains('suplemento') || accion.contains('categoria')) {
      return Icons.medication;
    }
    if (accion.contains('entrega')) return Icons.delivery_dining;
    if (accion.contains('incidencia')) return Icons.report_problem_outlined;
    if (accion.contains('foto')) return Icons.photo_camera;
    if (accion.contains('editar')) return Icons.edit;
    if (accion.contains('eliminar')) return Icons.delete_outline;
    if (accion.contains('restaur')) return Icons.restore_from_trash;
    if (accion.contains('congel')) return Icons.ac_unit;
    if (accion.contains('verific')) return Icons.verified_user;
    return Icons.assignment;
  }

  /// Color semántico por tipo de acción.
  Color _colorAccion(BuildContext context, String accion) {
    if (accion.contains('inscri')) return AppColores.exito;
    if (accion.contains('pago')) return AppColores.naranja;
    // v1.3.3: colores por categoría (diseño Argón).
    if (accion.contains('suplemento') || accion.contains('categoria')) {
      return AppColores.info;
    }
    if (accion.contains('entrega')) return AppColores.exito;
    if (accion.contains('regalo_cumpleanos') ||
        accion.contains('regalar_mes')) {
      return AppColores.alerta;
    }
    if (accion.contains('eliminar')) return AppColores.error;
    if (accion.contains('editar')) return AppColores.info;
    return AppColores.textoSecundario(context);
  }

  /// v1.3.5 (Fase 1, C4): clave de un item del servidor para buscar
  /// en _pendientesSync. Mismo formato que agregarClaveOp en _cargar.
  String _claveSyncItem(Map<String, dynamic> a) {
    final accion = '${a['accion'] ?? ''}';
    final ts = '${a['ts'] ?? ''}';
    final dia = ts.length >= 10 ? ts.substring(0, 10) : '';
    return '${_categoriaDe(accion)}|${_clienteIdDe(a) ?? ''}|$dia';
  }

  /// v1.3.5 (Fase 1, C4): ¿el item tiene una op pendiente relacionada?
  /// Lookup O(1) en memoria — prohibido query aquí.
  bool _pendienteSync(Map<String, dynamic> a) {
    if (a['_en_cola'] == true) return true;
    return _pendientesSync.contains(_claveSyncItem(a));
  }

  /// v1.3.5 (Fase 1, C2): extrae el método de pago del detalle
  /// ("... (mensual, efectivo, vía APK)"). Best-effort: si no se
  /// encuentra, se omite del subtítulo.
  String _metodoDe(Map<String, dynamic> a) {
    final det = '${a['detalle'] ?? ''}'.toLowerCase();
    final m = RegExp(r'\(([^)]*)\)').firstMatch(det);
    if (m != null) {
      final dentro = m.group(1)!;
      if (dentro.contains('efectivo')) return 'Efectivo';
      if (dentro.contains('transferencia')) return 'Transferencia';
    }
    if (det.contains('usd')) return 'USD';
    return '';
  }

  /// v1.3.5 (Fase 1, C3): hora para el subtítulo — UN solo formato.
  /// Hoy y <60 min: "hace X min" (o "ahora mismo"); hoy y >=60 min: HH:mm;
  /// otro día: dd/MM HH:mm. Nunca "21:07 (ahora mismo)".
  String _horaSubtitulo(Map<String, dynamic> a) {
    final ts = '${a['ts'] ?? ''}';
    if (ts.isEmpty) return '';
    try {
      final dt = DateTime.parse(ts).toLocal();
      final ahora = ahoraHabana();
      final esHoy = dt.year == ahora.year &&
          dt.month == ahora.month &&
          dt.day == ahora.day;
      final hhmm = '${dt.hour.toString().padLeft(2, '0')}:'
          '${dt.minute.toString().padLeft(2, '0')}';
      if (esHoy) {
        final diff = ahora.difference(dt);
        if (!diff.isNegative && diff.inMinutes < 60) {
          final m = diff.inMinutes;
          return m < 1 ? 'ahora mismo' : 'hace $m min';
        }
        return hhmm;
      }
      return '${dt.day.toString().padLeft(2, '0')}/'
          '${dt.month.toString().padLeft(2, '0')} $hhmm';
    } catch (_) {
      return '';
    }
  }

  /// v1.3.5 (Fase 1, C1+C2+C3): subtítulo compacto de 1 línea:
  /// "Tipo · Método · Hora · Entrenador". Sin duplicar el título ni
  /// el monto (el monto va solo a la derecha, en verde).
  String _subtituloNuevo(Map<String, dynamic> a, String titulo) {
    final partes = <String>[];
    final tipo = _tituloAccion('${a['accion'] ?? ''}');
    if (tipo != titulo && tipo.isNotEmpty) partes.add(tipo);
    final metodo = _metodoDe(a);
    if (metodo.isNotEmpty) partes.add(metodo);
    final hora = _horaSubtitulo(a);
    if (hora.isNotEmpty) partes.add(hora);
    final actor = '${a['actor'] ?? ''}'.trim();
    if (actor.isNotEmpty) partes.add(actor);
    return partes.join(' · ');
  }

  /// v1.3.5 (Fase 1, A3): avatar 40×40 unificado. Foto del cliente
  /// (cacheWidth 120, fallback limpio) o círculo semántico por tipo.
  Widget _avatarActividad(String? fotoPath, Color color, String accion,
      String categoria) {
    IconData icono;
    switch (categoria) {
      case 'mensualidades':
        icono = Icons.payments;
        break;
      case 'diarios':
        icono = Icons.receipt_long;
        break;
      case 'suplementos':
      case 'entregas':
        icono = Icons.shopping_bag;
        break;
      default:
        icono = _iconoAccion(accion);
    }
    if (fotoPath != null && fotoPath.isNotEmpty) {
      return FutureBuilder(
        future: FotoCache.instance.obtener(fotoPath),
        builder: (ctx, snap) {
          final f = snap.data;
          if (f != null) {
            return ClipRRect(
              borderRadius: BorderRadius.circular(AppRadio.circular),
              child: Image.file(f,
                  width: 40,
                  height: 40,
                  fit: BoxFit.cover,
                  cacheWidth: 120,
                  errorBuilder: (_, __, ___) =>
                      _iconoAvatar(color, icono)),
            );
          }
          return _iconoAvatar(color, icono);
        },
      );
    }
    return _iconoAvatar(color, icono);
  }

  Widget _iconoAvatar(Color color, IconData icono) {
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        shape: BoxShape.circle,
      ),
      child: Icon(icono, color: color, size: 20),
    );
  }

  /// v1.3.5 (Fase 1, C4): micro-indicador de sync, 14px.
  Widget _indicadorSync(bool pendiente) {
    return Icon(
      pendiente ? Icons.schedule_outlined : Icons.check,
      size: 14,
      color: pendiente
          ? AppColores.alerta
          : AppColores.exito.withValues(alpha: 0.55),
    );
  }

  /// v1.3.5 (Fase 1, F1): resetea todos los filtros.
  void _limpiarFiltros() {
    _busquedaCtrl.clear();
    setState(() {
      _filtro = 'todo';
      _filtroActor = 'todos';
      _filtroFecha = 'todo';
      _rangoIni = null;
      _rangoFin = null;
      _busqueda = '';
      _agruparPor = 'dia';
      // v1.3.7 (Fase 2, B2).
      _filtroMonto = 'todo';
      _montoMin = null;
      _montoMax = null;
    });
  }

  /// v1.3.5 (Fase 1, A1+B1): cantidad de filtros secundarios activos
  /// (para el botón "Filtros · N").
  int get _filtrosSecundariosActivos {
    var n = 0;
    if (_filtro != 'todo') n++;
    if (_filtroActor != 'todos') n++;
    if (_agruparPor != 'dia') n++;
    if (_filtroFecha == 'rango') n++;
    // v1.3.7 (Fase 2, B2): el filtro por monto cuenta como activo.
    if (_filtroMonto != 'todo') n++;
    return n;
  }

  String _etiquetaFiltro(String f) {
    switch (f) {
      case 'mensualidades':
        return 'Mensualidades';
      case 'inscripciones':
        return 'Inscripciones';
      case 'diarios':
        return 'Diarios';
      case 'suplementos':
        return 'Suplementos';
      case 'servicios':
        return 'Servicios';
      case 'entregas':
        return 'Entregas';
      default:
        return 'Todo';
    }
  }

  /// v1.2.1: agrupa por entrenador/actor en vez de por día.
  List<MapEntry<String, List<Map<String, dynamic>>>> _agruparPorEntrenador(
      List<Map<String, dynamic>> items) {
    final grupos = <String, List<Map<String, dynamic>>>{};
    final orden = <String>[];
    for (final a in items) {
      final actor = '${a['actor'] ?? '—'}'.trim();
      final key = actor.isEmpty ? '—' : actor;
      if (!grupos.containsKey(key)) {
        grupos[key] = [];
        orden.add(key);
      }
      grupos[key]!.add(a);
    }
    orden.sort();
    return orden.map((t) => MapEntry(t, grupos[t]!)).toList();
  }

  /// Agrupa por día: devuelve lista de (tituloDia, items).
  List<MapEntry<String, List<Map<String, dynamic>>>> _agruparPorDia(
      List<Map<String, dynamic>> items) {
    final grupos = <String, List<Map<String, dynamic>>>{};
    final orden = <String>[];
    // P2#11 (Argón): «Hoy»/«Ayer» del encabezado en hora Habana.
    final hoy = ahoraHabana();
    final hoyStr =
        '${hoy.year}-${hoy.month.toString().padLeft(2, '0')}-${hoy.day.toString().padLeft(2, '0')}';
    final ayer = hoy.subtract(const Duration(days: 1));
    final ayerStr =
        '${ayer.year}-${ayer.month.toString().padLeft(2, '0')}-${ayer.day.toString().padLeft(2, '0')}';
    for (final a in items) {
      final ts = '${a['ts'] ?? ''}';
      final dia = ts.length >= 10 ? ts.substring(0, 10) : '?';
      String titulo;
      if (dia == hoyStr) {
        titulo = 'Hoy';
      } else if (dia == ayerStr) {
        titulo = 'Ayer';
      } else {
        titulo = fmtFecha(dia);
      }
      if (!grupos.containsKey(titulo)) {
        grupos[titulo] = [];
        orden.add(titulo);
      }
      grupos[titulo]!.add(a);
    }
    return orden.map((t) => MapEntry(t, grupos[t]!)).toList();
  }

  /// v1.3.5 (Fase 1, A1+B1+A4): UNA sola fila horizontal con los chips
  /// rápidos de fecha + botón "Filtros · N" + chips resumen de los
  /// secundarios activos (con × para quitarlos de un toque).
  /// ShaderMask con fade a la derecha (A4): nunca chips mutilados
  /// sin pista visual de scroll.
  Widget _filaFiltros() {
    return ShaderMask(
      shaderCallback: (rect) => const LinearGradient(
        begin: Alignment.centerLeft,
        end: Alignment.centerRight,
        colors: [Colors.black, Colors.black, Colors.transparent],
        stops: [0.0, 0.88, 1.0],
      ).createShader(rect),
      blendMode: BlendMode.dstIn,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            _chipFechaRapida('hoy', 'Hoy'),
            const SizedBox(width: 8),
            _chipFechaRapida('ayer', 'Ayer'),
            const SizedBox(width: 8),
            _chipFechaRapida('7dias', '7 días'),
            const SizedBox(width: 8),
            _chipFechaRapida('mes', 'Mes'),
            const SizedBox(width: 8),
            _botonFiltros(),
            for (final chip in _chipsSecundariosActivos()) ...[
              const SizedBox(width: 8),
              chip,
            ],
            // Espacio para que el fade no corte el último chip.
            const SizedBox(width: 16),
          ],
        ),
      ),
    );
  }

  /// v1.3.5: chip rápido de fecha. Tocar el activo vuelve a "Siempre".
  Widget _chipFechaRapida(String valor, String etiqueta) {
    final activo = _filtroFecha == valor;
    return ChoiceChip(
      label: Text(etiqueta, style: const TextStyle(fontSize: 12)),
      selected: activo,
      onSelected: (_) => setState(
          () => _filtroFecha = activo ? 'todo' : valor),
    );
  }

  /// v1.3.5: botón que abre el panel de filtros secundarios.
  Widget _botonFiltros() {
    final n = _filtrosSecundariosActivos;
    return OutlinedButton.icon(
      icon: const Icon(Icons.filter_list, size: 16),
      label: Text(n > 0 ? 'Filtros · $n' : 'Filtros',
          style: const TextStyle(fontSize: 12)),
      style: OutlinedButton.styleFrom(
        padding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadio.lg),
        ),
      ),
      onPressed: _abrirPanelFiltros,
    );
  }

  /// v1.3.5: chips resumen de secundarios activos, con × para quitar.
  List<Widget> _chipsSecundariosActivos() {
    final chips = <Widget>[];
    if (_filtro != 'todo') {
      chips.add(_chipResumen(_etiquetaFiltro(_filtro),
          () => setState(() => _filtro = 'todo')));
    }
    if (_filtroFecha == 'rango') {
      var etiqueta = 'Rango';
      if (_rangoIni != null && _rangoFin != null) {
        etiqueta =
            '${fmtFecha(_isoDia(_rangoIni!))}–${fmtFecha(_isoDia(_rangoFin!))}';
      }
      chips.add(_chipResumen(etiqueta, () => setState(() {
            _filtroFecha = 'todo';
            _rangoIni = null;
            _rangoFin = null;
          })));
    }
    if (_filtroActor != 'todos') {
      chips.add(_chipResumen(_filtroActor,
          () => setState(() => _filtroActor = 'todos')));
    }
    if (_agruparPor != 'dia') {
      chips.add(_chipResumen('Por entrenador',
          () => setState(() => _agruparPor = 'dia')));
    }
    // v1.3.7 (Fase 2, B2): chip resumen del filtro por monto.
    if (_filtroMonto != 'todo') {
      chips.add(_chipResumen(_etiquetaMonto(),
          () => setState(() {
                _filtroMonto = 'todo';
                _montoMin = null;
                _montoMax = null;
              })));
    }
    return chips;
  }

  /// v1.3.7 (Fase 2, B2): etiqueta legible del filtro por monto.
  String _etiquetaMonto() {
    switch (_filtroMonto) {
      case 'm500':
        return '>500 CUP';
      case 'm1000':
        return '>1000 CUP';
      case 'm5000':
        return '>5000 CUP';
      case 'rango':
        final min = _montoMin != null ? fmtMonto(_montoMin!) : '0';
        final max = _montoMax != null ? fmtMonto(_montoMax!) : '∞';
        return '$min–$max CUP';
      default:
        return '';
    }
  }

  Widget _chipResumen(String etiqueta, VoidCallback onQuitar) {
    return InputChip(
      label: Text(etiqueta, style: const TextStyle(fontSize: 12)),
      deleteIcon: const Icon(Icons.close, size: 16),
      onDeleted: onQuitar,
    );
  }

  /// v1.3.5 (Fase 1, B1): bottom sheet con los filtros secundarios:
  /// tipo de operación, fecha completa, entrenador y agrupamiento.
  Future<void> _abrirPanelFiltros() async {
    var fTipo = _filtro;
    var fFecha = _filtroFecha;
    var fActor = _filtroActor;
    var fAgrupar = _agruparPor;
    // v1.3.7 (Fase 2, B2): filtro por monto.
    var fMonto = _filtroMonto;
    double? mMin = _montoMin;
    double? mMax = _montoMax;
    final minCtrl =
        TextEditingController(text: mMin?.toStringAsFixed(0) ?? '');
    final maxCtrl =
        TextEditingController(text: mMax?.toStringAsFixed(0) ?? '');
    DateTime? rIni = _rangoIni;
    DateTime? rFin = _rangoFin;
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
            top: Radius.circular(AppRadio.xl)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          Widget seccion(String titulo, List<Widget> chips) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(titulo,
                    style: AppTexto.subtitulo.copyWith(
                        fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                Wrap(spacing: 8, runSpacing: 8, children: chips),
                const SizedBox(height: 16),
              ],
            );
          }

          ChoiceChip chipSel(
              String etiqueta, bool sel, VoidCallback onTap) {
            return ChoiceChip(
              label: Text(etiqueta,
                  style: const TextStyle(fontSize: 12)),
              selected: sel,
              onSelected: (_) {
                onTap();
                setSheet(() {});
              },
            );
          }

          Future<void> elegirRangoSheet() async {
            final ini = await showDatePicker(
              context: ctx,
              // initialDate es solo UI y se deja como está (P2#11).
              initialDate: rIni ?? DateTime.now(),
              firstDate: DateTime(2020),
              // P2#11 (Argón): el tope del rango es hoy en Habana.
              lastDate: ahoraHabana(),
              helpText: 'Fecha inicial',
            );
            if (ini == null || !ctx.mounted) return;
            final fin = await showDatePicker(
              context: ctx,
              // initialDate es solo UI y se deja como está (P2#11).
              initialDate: rFin ?? DateTime.now(),
              firstDate: ini,
              lastDate: ahoraHabana(),
              helpText: 'Fecha final',
            );
            if (fin == null || !ctx.mounted) return;
            rIni = ini;
            rFin = fin;
            fFecha = 'rango';
            setSheet(() {});
          }

          return SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: AppColores.borde(context),
                        borderRadius:
                            BorderRadius.circular(AppRadio.sm),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text('Filtros',
                      style: AppTexto.titulo
                          .copyWith(fontSize: 18)),
                  const SizedBox(height: 12),
                  // v1.4.1 (Pieza 7, B3): filtros guardados de este
                  // dispositivo. Tocar aplica y cierra; la × borra.
                  if (_guardados.isNotEmpty) ...[
                    Text('Guardados',
                        style: AppTexto.subtitulo
                            .copyWith(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    Wrap(spacing: 8, runSpacing: 8, children: [
                      for (final g in _guardados)
                        InputChip(
                          label: Text('${g['nombre'] ?? ''}',
                              style:
                                  const TextStyle(fontSize: 12)),
                          deleteIcon:
                              const Icon(Icons.close, size: 16),
                          onPressed: () {
                            _aplicarGuardado(g);
                            Navigator.of(ctx).pop();
                          },
                          onDeleted: () async {
                            setState(() => _guardados.removeWhere(
                                (x) => x['nombre'] == g['nombre']));
                            await _persistirGuardados();
                            setSheet(() {});
                          },
                        ),
                    ]),
                    const SizedBox(height: 4),
                  ],
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      icon: const Icon(Icons.bookmark_add_outlined,
                          size: 18),
                      label: const Text('Guardar filtros actuales'),
                      onPressed: () async {
                        Navigator.of(ctx).pop();
                        await _guardarFiltroActual();
                      },
                    ),
                  ),
                  seccion('Tipo de operación', [
                    chipSel('Todo', fTipo == 'todo',
                        () => fTipo = 'todo'),
                    chipSel('Mensualidades',
                        fTipo == 'mensualidades',
                        () => fTipo = 'mensualidades'),
                    chipSel('Inscripciones',
                        fTipo == 'inscripciones',
                        () => fTipo = 'inscripciones'),
                    chipSel('Diarios', fTipo == 'diarios',
                        () => fTipo = 'diarios'),
                    chipSel('Suplementos',
                        fTipo == 'suplementos',
                        () => fTipo = 'suplementos'),
                    chipSel('Servicios',
                        fTipo == 'servicios',
                        () => fTipo = 'servicios'),
                    chipSel('Entregas', fTipo == 'entregas',
                        () => fTipo = 'entregas'),
                  ]),
                  seccion('Fecha', [
                    chipSel('Siempre', fFecha == 'todo',
                        () => fFecha = 'todo'),
                    chipSel('Hoy', fFecha == 'hoy',
                        () => fFecha = 'hoy'),
                    chipSel('Ayer', fFecha == 'ayer',
                        () => fFecha = 'ayer'),
                    chipSel('7 días', fFecha == '7dias',
                        () => fFecha = '7dias'),
                    chipSel('Este mes', fFecha == 'mes',
                        () => fFecha = 'mes'),
                    chipSel(
                        fFecha == 'rango' && rIni != null
                            ? 'Rango ✓'
                            : 'Rango…',
                        fFecha == 'rango',
                        elegirRangoSheet),
                  ]),
                  if (_actores.length > 1)
                    seccion('Entrenador', [
                      chipSel('Todos', fActor == 'todos',
                          () => fActor = 'todos'),
                      for (final actor in _actores)
                        chipSel(actor, fActor == actor,
                            () => fActor = actor),
                    ]),
                  seccion('Agrupar', [
                    chipSel('Por día', fAgrupar == 'dia',
                        () => fAgrupar = 'dia'),
                    chipSel('Por entrenador',
                        fAgrupar == 'entrenador',
                        () => fAgrupar = 'entrenador'),
                  ]),
                  // v1.3.7 (Fase 2, B2): filtro por monto en CUP.
                  seccion('Monto (CUP)', [
                    chipSel('Todos', fMonto == 'todo',
                        () => fMonto = 'todo'),
                    chipSel('>500', fMonto == 'm500',
                        () => fMonto = 'm500'),
                    chipSel('>1000', fMonto == 'm1000',
                        () => fMonto = 'm1000'),
                    chipSel('>5000', fMonto == 'm5000',
                        () => fMonto = 'm5000'),
                    chipSel('Rango…', fMonto == 'rango', () {
                      fMonto = 'rango';
                      setSheet(() {});
                    }),
                  ]),
                  if (fMonto == 'rango')
                    Padding(
                      padding:
                          const EdgeInsets.only(bottom: 16),
                      child: Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: minCtrl,
                              keyboardType:
                                  TextInputType.number,
                              decoration: const InputDecoration(
                                labelText: 'Mín CUP',
                                border:
                                    OutlineInputBorder(),
                                contentPadding:
                                    EdgeInsets.symmetric(
                                        horizontal: 12,
                                        vertical: 8),
                              ),
                              onChanged: (_) =>
                                  setSheet(() {}),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: TextField(
                              controller: maxCtrl,
                              keyboardType:
                                  TextInputType.number,
                              decoration: const InputDecoration(
                                labelText: 'Máx CUP',
                                border:
                                    OutlineInputBorder(),
                                contentPadding:
                                    EdgeInsets.symmetric(
                                        horizontal: 12,
                                        vertical: 8),
                              ),
                              onChanged: (_) =>
                                  setSheet(() {}),
                            ),
                          ),
                        ],
                      ),
                    ),
                  Row(
                    children: [
                      TextButton(
                        onPressed: () {
                          fTipo = 'todo';
                          fFecha = 'todo';
                          fActor = 'todos';
                          fAgrupar = 'dia';
                          rIni = null;
                          rFin = null;
                          // v1.3.7 (Fase 2, B2).
                          fMonto = 'todo';
                          mMin = null;
                          mMax = null;
                          minCtrl.clear();
                          maxCtrl.clear();
                          setSheet(() {});
                        },
                        child:
                            const Text('Limpiar todo'),
                      ),
                      const Spacer(),
                      ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor:
                              AppColores.naranja,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius:
                                BorderRadius.circular(
                                    AppRadio.md),
                          ),
                        ),
                        onPressed: () {
                          // v1.3.7 (Fase 2, B2): parsear rango.
                          if (fMonto == 'rango') {
                            mMin = double.tryParse(
                                minCtrl.text.trim());
                            mMax = double.tryParse(
                                maxCtrl.text.trim());
                          }
                          setState(() {
                            _filtro = fTipo;
                            _filtroFecha = fFecha;
                            _filtroActor = fActor;
                            _agruparPor = fAgrupar;
                            _rangoIni = rIni;
                            _rangoFin = rFin;
                            _filtroMonto = fMonto;
                            _montoMin = mMin;
                            _montoMax = mMax;
                          });
                          Navigator.of(ctx).pop();
                        },
                        child: const Text('Aplicar'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final filtrados = _filtrados;
    // v1.2.1: agrupar por día o por entrenador.
    final grupos = _agruparPor == 'dia'
        ? _agruparPorDia(filtrados)
        : _agruparPorEntrenador(filtrados);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Actividad reciente'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Actualizar',
            onPressed: _cargar,
          ),
        ],
      ),
      body: Column(
        children: [
          // v1.2.1: buscador por cliente, suplemento o texto.
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: TextField(
              controller: _busquedaCtrl,
              decoration: InputDecoration(
                hintText: 'Buscar por cliente, suplemento…',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _busqueda.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _busquedaCtrl.clear();
                          setState(() => _busqueda = '');
                        },
                      )
                    : null,
                border: OutlineInputBorder(
                  borderRadius:
                      BorderRadius.circular(AppRadio.md),
                ),
                contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 8),
              ),
              onChanged: (v) =>
                  setState(() => _busqueda = v),
            ),
          ),
          // v1.3.5 (Fase 1, A1+B1): UNA sola fila de filtros.
          // Chips rápidos de fecha (uso diario) + botón "Filtros · N".
          // Los secundarios (tipo, entrenador, agrupar, rango) van en el
          // bottom sheet. Tocar un chip rápido activo vuelve a "Siempre".
          _filaFiltros(),
          // v1.4.1 (Pieza 7, D3): mini gráfico de la serie diaria.
          _tarjetaSerie(),
          // v1.3.3: cinta de resumen financiero (KPI bar) con desglose D1.
          // P2#2 (Argón): oculta si quien mira no tiene canVerCifras.
          // Fail-closed: si los permisos no se resuelven, no se muestra.
          if (_puedeVerCifras()) _kpiBar(filtrados),
          // Mejora Actividad 6: aviso honesto si el feed llegó al
          // tope del servidor (500) y puede faltar historia.
          if (_feedRecortado)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
              child: Text(
                'Mostrando las últimas 500 acciones.',
                style: AppTexto.etiqueta.copyWith(
                    color: AppColores.textoSecundario(context)),
                textAlign: TextAlign.center,
              ),
            ),
          Expanded(
            child: _cargando
                ? const EstadoCargando(texto: 'Cargando actividad…')
                : filtrados.isEmpty
                    // v1.3.5 (Fase 1, F1): distinguir "sin datos" de
                    // "filtros sin resultados".
                    ? (_items.isEmpty
                        ? const EstadoVacio(
                            icono: Icons.history_outlined,
                            titulo: 'Sin actividad reciente',
                            subtitulo:
                                'Sincroniza para actualizar.',
                          )
                        : EstadoVacio(
                            icono: Icons.search_off_outlined,
                            titulo:
                                'Sin resultados con estos filtros',
                            subtitulo:
                                'Prueba con otros filtros o límpialos.',
                            textoAccion: 'Limpiar filtros',
                            onAccion: _limpiarFiltros,
                          ))
                    : RefreshIndicator(
                        onRefresh: _cargar,
                        // v1.3.7 (Fase 2, A2): CustomScrollView con
                        // SliverPersistentHeader por grupo — el encabezado
                        // de fecha ("Hoy", "Ayer"…) queda fijo arriba
                        // mientras su grupo está visible.
                        child: CustomScrollView(
                          slivers: [
                            for (final grupo in grupos) ...[
                              SliverPersistentHeader(
                                pinned: true,
                                delegate: _EncabezadoFechaSticky(
                                  titulo: grupo.key,
                                ),
                              ),
                              SliverList(
                                delegate: SliverChildBuilderDelegate(
                                  (ctx, i) =>
                                      _tarjetaActividad(grupo.value[i]),
                                  childCount: grupo.value.length,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
          ),
        ],
      ),
    );
  }

  /// v1.3.7 (Fase 2, B4): Text con el término buscado resaltado.
  /// Sin término activo devuelve el Text idéntico al original
  /// (cero costo, render sin cambios).
  Widget _textoResaltado(
      String texto, TextStyle? estilo, int maxLines) {
    final q = sinTildes(_busqueda.trim().toLowerCase());
    if (q.isEmpty) {
      return Text(texto,
          style: estilo,
          maxLines: maxLines,
          overflow: TextOverflow.ellipsis);
    }
    final norm = sinTildes(texto.toLowerCase());
    final spans = <TextSpan>[];
    var ini = 0;
    // Color según tema: amarillo tenue (claro), naranja tenue (oscuro).
    final esOscuro =
        Theme.of(context).brightness == Brightness.dark;
    final fondo = esOscuro
        ? AppColores.naranja.withValues(alpha: 0.35)
        : const Color(0xFFFFF176).withValues(alpha: 0.7);
    while (true) {
      final idx = norm.indexOf(q, ini);
      if (idx < 0) break;
      if (idx > ini) {
        spans.add(TextSpan(text: texto.substring(ini, idx)));
      }
      spans.add(TextSpan(
        text: texto.substring(idx, idx + q.length),
        style: TextStyle(backgroundColor: fondo),
      ));
      ini = idx + q.length;
    }
    if (ini < texto.length) {
      spans.add(TextSpan(text: texto.substring(ini)));
    }
    return Text.rich(
      TextSpan(children: spans, style: estilo),
      maxLines: maxLines,
      overflow: TextOverflow.ellipsis,
    );
  }

  /// v1.3.7 (Fase 2, A2): tarjeta unificada extraída del itemBuilder
  /// para reutilizarla en SliverList (sticky headers). Idéntica a Fase 1.
  Widget _tarjetaActividad(Map<String, dynamic> a) {
    final accion =
        '${a['accion'] ?? ''}';
    final cliId = _clienteIdDe(a);
    final color =
        _colorAccion(context, accion);
    final categoria =
        _categoriaDe(accion);
    // v1.3.5 (Fase 1, A3): tarjeta unificada.
    // Título: nombre del cliente o concepto.
    // PROHIBIDO repetir nombre/monto/hora.
    final nombreCli = cliId != null
        ? _nombres[cliId]
        : null;
    final titulo =
        (nombreCli != null &&
                !nombreCli.startsWith(
                    'Cliente '))
            ? nombreCli
            : _tituloAccion(accion);
    final subtitulo =
        _subtituloNuevo(a, titulo);
    final fotoPath = cliId != null
        ? _fotos[cliId]
        : null;
    // Monto único (C2): solo a la derecha.
    double badgeCup = 0, badgeUsd = 0;
    if (a['_en_cola'] == true) {
      badgeCup =
          (a['_monto_cup'] as num?)
                  ?.toDouble() ??
              0;
      badgeUsd =
          (a['_monto_usd'] as num?)
                  ?.toDouble() ??
              0;
    } else if (_esCobroServidor(
        accion)) {
      final m = _montoServidor(
          '${a['detalle'] ?? ''}');
      badgeCup = m.$1;
      badgeUsd = m.$2;
    }
    final tieneMonto =
        badgeCup > 0 ||
            badgeUsd > 0;
    final montoTxt = badgeUsd > 0
        ? '+${fmtMonto(badgeUsd)} USD'
        : '+${fmtMonto(badgeCup)} CUP';
    // v1.3.5 (Fase 1, C4): lookup O(1).
    final pendiente =
        _pendienteSync(a);
    return Padding(
      padding: const EdgeInsets
          .symmetric(
          horizontal: 12,
          vertical: 4),
      child: InkWell(
        borderRadius:
            BorderRadius.circular(
                AppRadio.md),
        onTap: () =>
            _abrirDetalle(a),
        child: Padding(
          padding:
              const EdgeInsets
                  .symmetric(
                  horizontal:
                      8,
                  vertical:
                      10),
          child: Row(
            crossAxisAlignment:
                CrossAxisAlignment
                    .center,
            children: [
              _avatarActividad(
                  fotoPath,
                  color,
                  accion,
                  categoria),
              const SizedBox(
                  width:
                      AppEspacio
                          .md),
              Expanded(
                child: Column(
                  crossAxisAlignment:
                      CrossAxisAlignment
                          .start,
                  mainAxisSize:
                      MainAxisSize
                          .min,
                  children: [
                    // v1.3.7 (Fase 2, B4): resalta el término buscado.
                    _textoResaltado(
                      titulo,
                      AppTexto.subtitulo.copyWith(
                          fontWeight: FontWeight.bold),
                      1,
                    ),
                    if (subtitulo
                        .isNotEmpty) ...[
                      const SizedBox(
                          height:
                              2),
                      _textoResaltado(
                        subtitulo,
                        AppTexto.etiqueta.copyWith(
                          color: AppColores
                              .textoSecundario(
                                  context),
                        ),
                        1,
                      ),
                    ],
                    // Mejora Actividad 1: el detalle del servidor
                    // (producto, período, etc.) por fin visible.
                    // En cola, a['detalle'] ya es el detalle local.
                    if (lineaDetalleActividad(
                            '${a['detalle'] ?? ''}', titulo)
                        .isNotEmpty)
                      _textoResaltado(
                        lineaDetalleActividad(
                            '${a['detalle'] ?? ''}', titulo),
                        AppTexto.etiqueta.copyWith(
                          color: AppColores
                              .textoSecundario(
                                  context),
                        ),
                        2,
                      ),
                  ],
                ),
              ),
              const SizedBox(
                  width: 8),
              Column(
                mainAxisSize:
                    MainAxisSize
                        .min,
                crossAxisAlignment:
                    CrossAxisAlignment
                        .end,
                children: [
                  if (tieneMonto)
                    Text(
                      montoTxt,
                      style: const TextStyle(
                          color: AppColores
                              .exito,
                          fontSize:
                              14,
                          fontWeight:
                              FontWeight
                                  .bold),
                    ),
                  const SizedBox(
                      height:
                          4),
                  Row(
                    mainAxisSize:
                        MainAxisSize
                            .min,
                    children: [
                      _indicadorSync(
                          pendiente),
                      const SizedBox(
                          width:
                              2),
                      Icon(
                          Icons
                              .chevron_right,
                          size:
                              20,
                          color: AppColores
                              .textoSecundario(
                                  context)),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// v1.3.7 (Fase B §6.2): ¿el item es una venta en estado "fiado"?
  /// Regla de negocio: el fiado NO suma al "Total cobrado" hasta que
  /// se pague. Lee el campo estructurado `es_fiado`; el chequeo por
  /// texto queda como respaldo con límite de palabra (\bfiado\b)
  /// para no capturar "confiado" (nota de Argón).
  static final _reFiado = RegExp(r'\bfiado\b', caseSensitive: false);
  bool _esFiado(Map<String, dynamic> a) {
    final estructurado = (a['es_fiado'] as num?)?.toInt() == 1;
    if (estructurado) return true;
    final det = '${a['detalle'] ?? ''}';
    return _reFiado.hasMatch(det) &&
        !det.toLowerCase().contains('pagado');
  }

  /// v1.3.7 (Fase 2, D2): total cobrado en CUP de los items en [ini, fin].
  /// Misma base que _kpi (solo cobros reales, sin fiados).
  double _totalEnRango(
      List<Map<String, dynamic>> items, DateTime ini, DateTime fin) {
    var total = 0.0;
    for (final a in items) {
      final ts = '${a['ts'] ?? ''}';
      if (ts.length < 10) continue;
      DateTime? dt;
      try {
        dt = DateTime.parse(ts);
      } catch (_) {
        continue;
      }
      if (dt.isBefore(ini) || dt.isAfter(fin)) continue;
      double cup = 0, usd = 0;
      if (a['_en_cola'] == true) {
        cup = (a['_monto_cup'] as num?)?.toDouble() ?? 0;
        usd = (a['_monto_usd'] as num?)?.toDouble() ?? 0;
      } else {
        final accion = '${a['accion'] ?? ''}';
        if (!_esCobroServidor(accion)) continue;
        if (_esFiado(a)) continue;
        final m = _montoServidor('${a['detalle'] ?? ''}');
        cup = m.$1;
        usd = m.$2;
      }
      total += cup + (_tasaUsd > 0 ? usd * _tasaUsd : 0);
    }
    return total;
  }

  /// v1.3.7 (Fase 2, D2): rango del período anterior según el filtro
  /// de fecha activo. Devuelve (ini, fin, etiqueta) o null si no aplica.
  (DateTime, DateTime, String)? _rangoAnterior() {
    final ahora = ahoraHabana();
    final hoyIni =
        DateTime(ahora.year, ahora.month, ahora.day);
    switch (_filtroFecha) {
      case 'hoy':
        // Corte por hora: ayer hasta la misma hora actual.
        final ayerIni = hoyIni.subtract(const Duration(days: 1));
        return (ayerIni, ayerIni.add(Duration(
            hours: ahora.hour,
            minutes: ahora.minute,
            seconds: ahora.second)), 'ayer hasta ahora');
      case 'ayer':
        final anteayer = hoyIni.subtract(const Duration(days: 2));
        return (
          anteayer,
          anteayer.add(const Duration(
              hours: 23, minutes: 59, seconds: 59)),
          'anteayer'
        );
      case '7dias':
        final fin = hoyIni.subtract(const Duration(days: 8));
        final ini = hoyIni.subtract(const Duration(days: 14));
        return (
          ini,
          fin.add(const Duration(
              hours: 23, minutes: 59, seconds: 59)),
          '7 días previos'
        );
      case 'mes':
        final iniMes = DateTime(ahora.year, ahora.month - 1, 1);
        final finMes = DateTime(ahora.year, ahora.month, 1)
            .subtract(const Duration(seconds: 1));
        return (iniMes, finMes, 'mes anterior');
      case 'rango':
        if (_rangoIni == null || _rangoFin == null) return null;
        final dias =
            _rangoFin!.difference(_rangoIni!).inDays + 1;
        final fin = DateTime(
                _rangoIni!.year, _rangoIni!.month, _rangoIni!.day)
            .subtract(const Duration(seconds: 1));
        final ini = fin.subtract(Duration(days: dias));
        return (ini, fin, '$dias días previos');
      default:
        return null;
    }
  }

  /// v1.3.5 (Fase 1, D1): calcula (n_acciones, mapa categoría→CUP, usd)
  /// sobre los items filtrados. O(N) en memoria, cero costo de BD.
  /// 'inscripciones' se pliega en 'mensualidades' (la inscripción cobra
  /// la primera mensualidad).
  /// Servidor: regex sobre detalle (solo cobros reales).
  /// Local: montos del payload ya calculados al cargar.
  (int, Map<String, double>, double) _kpi(
      List<Map<String, dynamic>> items) {
    final porCat = <String, double>{
      'mensualidades': 0,
      'diarios': 0,
      'suplementos': 0,
      'servicios': 0,
    };
    var usd = 0.0;
    for (final a in items) {
      double cup = 0, u = 0;
      String cat;
      if (a['_en_cola'] == true) {
        cup = (a['_monto_cup'] as num?)?.toDouble() ?? 0;
        u = (a['_monto_usd'] as num?)?.toDouble() ?? 0;
        cat = _categoriaDe('${a['accion'] ?? ''}');
      } else {
        final accion = '${a['accion'] ?? ''}';
        if (!_esCobroServidor(accion)) continue;
        // v1.3.7 (Fase 2, D2): el fiado no suma al total cobrado.
        if (_esFiado(a)) continue;
        final m = _montoServidor('${a['detalle'] ?? ''}');
        cup = m.$1;
        u = m.$2;
        cat = _categoriaDe(accion);
      }
      if (cat == 'inscripciones') cat = 'mensualidades';
      if (porCat.containsKey(cat)) {
        porCat[cat] = porCat[cat]! + cup;
      }
      usd += u;
    }
    return (items.length, porCat, usd);
  }

  /// v1.3.7 (Fase 2, D2): texto de comparativa vs período anterior.
  /// Usa la función top-level [textoComparativa] (testeable).
  (String, bool)? _comparativa(
      List<Map<String, dynamic>> filtrados, double totalCup) {
    final ant = _rangoAnterior();
    if (ant == null) return null;
    // Total actual en CUP (convierte el USD con la tasa del día).
    final kpi = _kpi(filtrados);
    final actualCup = totalCup +
        (_tasaUsd > 0 ? kpi.$3 * _tasaUsd : 0);
    final previo = _totalEnRango(_items, ant.$1, ant.$2);
    final r = textoComparativa(actualCup, previo, ant.$3);
    return r;
  }

  /// P2#2 (Argón): ¿puede ver cifras quien mira? El dueño siempre
  /// (PermisosEntrenador); si la resolución falla, no se muestran.
  bool _puedeVerCifras() {
    try {
      return PermisosEntrenador().canVerCifras;
    } catch (_) {
      return false;
    }
  }

  /// v1.3.5 (Fase 1, D1): cinta de resumen con desglose por tipo.
  Widget _kpiBar(List<Map<String, dynamic>> filtrados) {
    final kpi = _kpi(filtrados);
    final n = kpi.$1;
    final porCat = kpi.$2;
    final usd = kpi.$3;
    final totalCup =
        porCat.values.fold(0.0, (s, v) => s + v);
    final totalTxt = StringBuffer('${fmtMonto(totalCup)} CUP');
    if (usd > 0) totalTxt.write(' (+ ${fmtMonto(usd)} USD)');
    final desglose = <String>[];
    if (porCat['mensualidades']! > 0) {
      desglose.add(
          'Mensualidades ${fmtMonto(porCat['mensualidades']!)}');
    }
    if (porCat['diarios']! > 0) {
      desglose
          .add('Diarios ${fmtMonto(porCat['diarios']!)}');
    }
    if (porCat['suplementos']! > 0) {
      desglose.add(
          'Suplementos ${fmtMonto(porCat['suplementos']!)}');
    }
    if (porCat['servicios']! > 0) {
      desglose.add(
          'Servicios ${fmtMonto(porCat['servicios']!)}');
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
      child: Tarjeta(
        padding: const EdgeInsets.symmetric(
            horizontal: 14, vertical: 10),
        child: Row(
          children: [
            const Icon(Icons.analytics_outlined,
                size: 20, color: AppColores.naranja),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('$n acciones',
                      style: AppTexto.etiqueta.copyWith(
                          color: AppColores.textoSecundario(
                              context))),
                  const SizedBox(height: 2),
                  Text('Total cobrado: $totalTxt',
                      style: AppTexto.subtitulo.copyWith(
                          fontWeight: FontWeight.bold,
                          color: AppColores.exito)),
                  // v1.3.7 (Fase 2, D2): comparativa vs período anterior.
                  Builder(builder: (ctx) {
                    final comp =
                        _comparativa(filtrados, totalCup);
                    if (comp == null) {
                      return const SizedBox.shrink();
                    }
                    return Text(comp.$1,
                        style: AppTexto.etiqueta.copyWith(
                            color: comp.$2
                                ? AppColores.exito
                                : AppColores.error));
                  }),
                  if (desglose.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(desglose.join(' · '),
                        style: AppTexto.etiqueta.copyWith(
                            color: AppColores.textoSecundario(
                                context))),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// v1.3.3: título legible a partir de la acción
  /// ("pago_sync" -> "Pago mensual", "venta_suplemento" -> "Venta").
  String _tituloAccion(String accion) {
    final a = accion.toLowerCase();
    if (a.contains('inscripcion_venta')) return 'Inscripción + venta';
    if (a.contains('inscri')) return 'Inscripción';
    if (a.contains('pago_diario') || a == 'diario') {
      return 'Pago diario';
    }
    if (a.contains('regalo_cumpleanos') ||
        a.contains('regalar_mes')) {
      return 'Mes gratis (cumpleaños)';
    }
    if (a.contains('pago') && !a.contains('diario')) {
      return 'Pago mensual';
    }
    if (a.contains('venta_suplemento')) return 'Venta suplemento';
    if (a.contains('suplemento')) return 'Suplemento';
    if (a.contains('confirmar_entrega')) return 'Entrega confirmada';
    if (a.contains('categoria')) return 'Categoría';
    final t =
        accion.replaceAll('_sync', '').replaceAll('_', ' ').trim();
    if (t.isEmpty) return 'Actividad';
    return t[0].toUpperCase() + t.substring(1);
  }

}

/// v1.3.7 (Fase 2, A2): encabezado de fecha fijo (sticky) para los
/// grupos de actividad. Mismo estilo que el separador anterior, con
/// fondo sólido para que el contenido no se transparente al fijarse.
class _EncabezadoFechaSticky extends SliverPersistentHeaderDelegate {
  final String titulo;

  const _EncabezadoFechaSticky({required this.titulo});

  @override
  double get minExtent => 40;

  @override
  double get maxExtent => 40;

  @override
  Widget build(
      BuildContext context, double shrinkOffset, bool overlapsContent) {
    return Container(
      color: Theme.of(context).scaffoldBackgroundColor,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      alignment: Alignment.centerLeft,
      child: Text(
        titulo,
        style: AppTexto.subtitulo
            .copyWith(color: AppColores.textoSecundario(context)),
      ),
    );
  }

  @override
  bool shouldRebuild(covariant _EncabezadoFechaSticky oldDelegate) =>
      oldDelegate.titulo != titulo;
}

/// Cuenta las actividades no leídas (para el badge).
Future<int> actividadNoLeidas() async {
  try {
    final p = await SharedPreferences.getInstance();
    final vista = p.getString('actividad_vista_ts') ?? '';
    final raw =
        await LocalDb.instance.getMeta('sync_estado_actividad');
    if (raw == null || raw.isEmpty) return 0;
    // v1.0.15 fix: comparar como DateTime, no como texto.
    // El servidor manda 'YYYY-MM-DD HH:MM:SS' y la APK guarda ISO8601;
    // la comparación lexicográfica siempre daba falso.
    final vistaDt =
        vista.isEmpty ? null : DateTime.tryParse(vista)?.toUtc();
    int n = 0;
    for (final a in jsonDecode(raw) as List) {
      final ts = '${(a as Map)['ts'] ?? ''}';
      if (vistaDt == null) {
        n++;
        continue;
      }
      // El servidor guarda ts en UTC sin zona; lo tratamos como UTC.
      var tsDt = DateTime.tryParse(ts);
      if (tsDt != null && tsDt.isUtc == false) {
        tsDt = DateTime.utc(tsDt.year, tsDt.month, tsDt.day, tsDt.hour,
            tsDt.minute, tsDt.second);
      }
      if (tsDt != null && tsDt.isAfter(vistaDt)) n++;
    }
    return n;
  } catch (_) {
    return 0;
  }
}
