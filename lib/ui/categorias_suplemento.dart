// CRUD de categorías de suplementos (v1.2.1, solo dueño).
//
// Las categorías permiten organizar el catálogo y filtrar por categoría
// en la lista de suplementos (entrenadores y dueño).

import 'package:flutter/material.dart';
import '../negocio.dart';
import 'package:uuid/uuid.dart';

import '../auth.dart';
import '../localdb.dart';
import '../sync.dart';
import '../tiempo.dart';
import 'app_bar.dart';
import 'componentes.dart';
import 'diseno.dart';
import 'skeleton.dart';
import 'widgets.dart';
import '../app_log.dart';

/// 1.36 H-B3 (136-757): lectura TOLERANTE de un flag del
/// espejo (bool, número o texto) — el cast rígido a int
/// rompía la pantalla si el espejo traía el flag en otra
/// forma. [porDefecto] manda cuando el valor no se reconoce.
bool flagEspejoActivo(dynamic v, {bool porDefecto = true}) {
  if (v == null) return porDefecto;
  if (v is bool) return v;
  if (v is num) return v != 0;
  if (v is String) {
    final t = v.trim().toLowerCase();
    if (t == '1' || t == 'true') return true;
    if (t == '0' || t == 'false' || t.isEmpty) return false;
  }
  return porDefecto;
}

/// La categoría está activa, leyendo `activa` o su legado
/// `activo` con la lectura tolerante.
bool categoriaActivaTolerante(Map<String, dynamic> c) =>
    flagEspejoActivo(c['activa'] ?? c['activo']);

class CategoriasSuplementoScreen extends StatefulWidget {
  const CategoriasSuplementoScreen({super.key});

  @override
  State<CategoriasSuplementoScreen> createState() =>
      _CategoriasSuplementoScreenState();
}

class _CategoriasSuplementoScreenState
    extends State<CategoriasSuplementoScreen> {
  final _auth = AuthService();
  List<Map<String, dynamic>> _items = [];
  // Rediseño 1.20: suplementos por categoría (del espejo).
  Map<int, int> _conteos = {};
  // 1.25 T120 (F4-08): con stock por categoría y cubeta de
  // «Sin categoría» (solo vendibles: activos no eliminados).
  Map<int, int> _conStock = {};
  int _sinCategoria = 0;
  // 1.36 H-B3 (136-757): vendibles cuya categoría ya no
  // existe — van a la misma cubeta visible, contados aparte.
  int _huerfanos = 0;
  // 1.36 H-B3 (136-757): el fallo de carga se PINTA (con
  // reintento), no cae en «Sin categorías».
  String? _errorCarga;
  // 1.36 H-B3 (136-759): bloqueos anti-doble-toque de
  // guardar y de cambiar activa.
  bool _guardandoNombre = false;
  final Set<int> _cambiando = {};
  bool _cargando = true;

  bool get _esDueno => _auth.isOwner;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    // (Yunque R2-X1) red de seguridad: la bandera baja
    // SIEMPRE (y el fallo queda en bitácora), también si una lectura local lanza a mitad
    // (spinner eterno: la clase de la ficha 2026-11-02).
    try {
      await _cargarDatos();
    } catch (e) {
      // El error NO se traga: queda en bitácora
      // (la clase nació de fallos mudos).
      AppLog.error('ui', 'carga_fallo', d: '$e');
      // 1.36 H-B3 (136-757): y se pinta con reintento.
      if (mounted) setState(() => _errorCarga = '$e');
    } finally {
      if (mounted && _cargando) {
        setState(() => _cargando = false);
      }
    }
  }

  Future<void> _cargarDatos() async {
    final items =
        await LocalDb.instance.allMirror('categorias_suplemento');
    final sups =
        await LocalDb.instance.allMirror('suplementos');
    // 1.36 H-B3 (136-757): ids con lectura tolerante (el
    // espejo puede traerlos como texto).
    final idsCategorias = <int>{
      for (final c in items)
        if (SyncEngine.enteroTolerante(c['id']) != null)
          SyncEngine.enteroTolerante(c['id'])!,
    };
    final conteos = <int, int>{};
    final conStock = <int, int>{};
    var sinCategoria = 0;
    var huerfanos = 0;
    for (final s in sups) {
      // F4-08: el conteo es del catálogo VENDIBLE — antes
      // sumaba también los eliminados y los inactivos, y la
      // pantalla decía «12 proteínas» cuando vendibles había 7.
      // 1.36 H-B3 (136-757): flags con lectura tolerante.
      if (flagEspejoActivo(s['eliminado'], porDefecto: false)) {
        continue;
      }
      if (!flagEspejoActivo(s['activo'], porDefecto: false)) {
        continue;
      }
      final cid = SyncEngine.enteroTolerante(s['categoria_id']);
      final stock = (s['stock'] as num?)?.toInt() ?? 0;
      if (cid == null) {
        sinCategoria++;
      } else if (!idsCategorias.contains(cid)) {
        // Su categoría ya no existe: a la cubeta visible,
        // no al limbo de un conteo sin tarjeta.
        huerfanos++;
      } else {
        conteos[cid] = (conteos[cid] ?? 0) + 1;
        if (stock > 0) conStock[cid] = (conStock[cid] ?? 0) + 1;
      }
    }
    if (!mounted) return;
    setState(() {
      _items = items
        ..sort(compararPorNombre);
      _conteos = conteos;
      _conStock = conStock;
      _sinCategoria = sinCategoria;
      _huerfanos = huerfanos;
      _errorCarga = null;
      _cargando = false;
    });
  }

  /// F4-08: «N suplementos» y, cuando alguno está agotado,
  /// el desglose «M con stock · K agotados».
  String _textoConteo(int? cid) {
    final n = cid == null ? 0 : (_conteos[cid] ?? 0);
    final base = '$n suplemento${n == 1 ? '' : 's'}';
    if (cid == null || n == 0) return base;
    final con = _conStock[cid] ?? 0;
    final agotados = n - con;
    if (agotados <= 0) return base;
    return '$base · $con con stock · $agotados agotado${agotados == 1 ? '' : 's'}';
  }

  Future<void> _guardar(String nombre, {int? id}) async {
    // 1.36 H-B3 (136-759): un doble toque no encola dos ops
    // con el mismo tmpId.
    if (_guardandoNombre) return;
    _guardandoNombre = true;
    try {
      final opUuid = const Uuid().v4();
      final payload = {
        'nombre': nombre.trim(),
        if (id != null) 'categoria_id': id,
      };
      await LocalDb.instance.queueOp(
        opUuid: opUuid,
        tipo: id == null ? 'crear_categoria' : 'editar_categoria',
        payload: payload,
      );
      // Optimista: reflejar localmente de inmediato. Se guarda el op_uuid
      // para que el push limpie la fila temporal cuando la op se aplique
      // (el registro real llega por el pull y si no se duplica).
      if (id == null) {
        final tmpId = -ahoraHabana().millisecondsSinceEpoch;
        await LocalDb.instance.upsertMirror('categorias_suplemento', tmpId,
            {'id': tmpId, 'nombre': nombre.trim(), 'activa': 1, 'op_uuid': opUuid}, 0);
      } else {
        final actual = _items.firstWhere(
            (c) => SyncEngine.enteroTolerante(c['id']) == id,
            orElse: () => {});
        if (actual.isNotEmpty) {
          await LocalDb.instance.upsertMirror('categorias_suplemento', id,
              {...actual, 'id': id, 'nombre': nombre.trim()}, 0);
        }
      }
      _cargar();
      SyncEngine.instance.push();
    } catch (e) {
      AppLog.error('categorias', 'guardar_fallo', d: '$e');
      if (mounted) {
        mostrarSnack(context, 'No se pudo guardar la categoría.',
            significado: SignificadoChip.error);
      }
    } finally {
      _guardandoNombre = false;
    }
  }

  Future<void> _cambiarActiva(
      Map<String, dynamic> c, bool activa) async {
    final id = SyncEngine.enteroTolerante(c['id']);
    if (id == null || _cambiando.contains(id)) return;
    // 1.36 H-B3 (136-759): desactivar una categoría CON
    // suplementos pide confirmación con el conteo.
    if (!activa && (_conteos[id] ?? 0) > 0) {
      final ok = await DialogoApp.confirmar(
        context,
        titulo: 'Desactivar categoría',
        mensaje: '«${c['nombre'] ?? 'Sin nombre'}» tiene '
            '${_conteos[id]} suplemento(s). Al desactivarla deja '
            'de ofrecerse en los selectores; los suplementos no '
            'se borran.',
        aceptar: 'Desactivar',
        peligro: true,
      );
      if (!ok || !mounted) return;
    }
    _cambiando.add(id);
    // 1.36 H-B3 (136-759): el switch se mueve YA (optimista)
    // y se revierte si la escritura falla — antes el thumb se
    // quedaba en el valor viejo durante queueOp/upsert/carga.
    final anterior = categoriaActivaTolerante(c);
    void pintar(bool v) {
      final i = _items.indexWhere(
          (x) => SyncEngine.enteroTolerante(x['id']) == id);
      if (i >= 0) {
        setState(() => _items[i] = {..._items[i], 'activa': v ? 1 : 0});
      }
    }

    pintar(activa);
    try {
      await LocalDb.instance.queueOp(
        opUuid: const Uuid().v4(),
        tipo: 'editar_categoria',
        payload: {'categoria_id': id, 'activa': activa ? 1 : 0},
      );
      await LocalDb.instance.upsertMirror(
          'categorias_suplemento',
          id,
          {...c, 'id': id, 'activa': activa ? 1 : 0},
          0);
      _cargar();
      SyncEngine.instance.push();
    } catch (e) {
      AppLog.error('categorias', 'cambiar_activa_fallo', d: '$e');
      if (mounted) {
        pintar(anterior);
        mostrarSnack(context, 'No se pudo cambiar la categoría.',
            significado: SignificadoChip.error);
      }
    } finally {
      _cambiando.remove(id);
    }
  }

  Future<void> _dialogoNombre({Map<String, dynamic>? categoria}) async {
    final texto = await showDialog<String>(
      context: context,
      builder: (ctx) => _DialogoNombreCategoria(
        titulo: categoria == null
            ? 'Nueva categoría'
            : 'Editar categoría',
        inicial: categoria != null
            ? '${categoria['nombre'] ?? ''}'
            : '',
      ),
    );
    final nombre = (texto ?? '').trim();
    if (texto != null && nombre.isNotEmpty && mounted) {
      await _guardar(nombre,
          id: categoria == null
              ? null
              : SyncEngine.enteroTolerante(categoria['id']));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: appBarIron(context, 'Categorías'),
      floatingActionButton: _esDueno
          ? FloatingActionButton.extended(
              onPressed: () => _dialogoNombre(),
              icon: const Icon(Icons.add_rounded),
              label: const Text('Nueva'),
            )
          : null,
      body: Column(
        children: [
          const SyncBanner(compact: true),
          Expanded(
            child: _cargando
                // 1.35 (UI-09): esqueleto de lista.
                ? const SkeletonLista(items: 4)
                : _errorCarga != null && _items.isEmpty
                    // 1.36 H-B3 (136-757): un fallo de lectura
                    // NO es «Sin categorías»: error con
                    // reintento.
                    ? EstadoError(
                        titulo: 'No se pudieron cargar las categorías',
                        detalle: _errorCarga,
                        onReintentar: () {
                          setState(() {
                            _errorCarga = null;
                            _cargando = true;
                          });
                          _cargar();
                        },
                      )
                    : _items.isEmpty
                    ? ListView(
                        children: [
                          EstadoVacio(
                            icono: Icons.category_rounded,
                            titulo: 'Sin categorías',
                            // 1.36 H-B3 (136-758): el texto
                            // del vacío depende del rol — el
                            // entrenador no tiene botón Nueva.
                            subtitulo: _esDueno
                                ? 'Crea la primera con el botón Nueva.'
                                : 'El dueño aún no crea categorías.',
                          ),
                          // 1.36 H-B3 (136-758): la cubeta de
                          // sin asignar también vive dentro
                          // del vacío.
                          if (_sinCategoria + _huerfanos > 0)
                            Padding(
                              padding: const EdgeInsets.fromLTRB(
                                  AppEspacio.md,
                                  0,
                                  AppEspacio.md,
                                  AppEspacio.md),
                              child: _tarjetaCubeta(context),
                            ),
                        ],
                      )
                    : RefrescoIron(
                        onRefresh: _cargar,
                        child: ListView.builder(
                          // 1.36 H-B3 (136-758): el hueco
                          // inferior solo existe si hay FAB.
                          padding: EdgeInsets.fromLTRB(
                              AppEspacio.md,
                              AppEspacio.sm,
                              AppEspacio.md,
                              _esDueno ? 96 : AppEspacio.md),
                          itemCount: _items.length +
                              (_sinCategoria + _huerfanos > 0 ? 1 : 0),
                          itemBuilder: (ctx, i) {
                            // F4-08: la última fila es la cubeta
                            // «Sin categoría» (informativa, sin
                            // acciones) cuando hay vendibles sin
                            // asignar.
                            if (i >= _items.length) {
                              return Padding(
                                padding: const EdgeInsets.only(
                                    bottom: AppEspacio.sm),
                                child: _tarjetaCubeta(ctx),
                              );
                            }
                            final c = _items[i];
                            // 1.36 H-B3 (136-757): activa con
                            // lectura tolerante (bool/texto no
                            // rompen la fila).
                            final activa =
                                categoriaActivaTolerante(c);
                            // 1.36 H-B3 (136-759): las altas y
                            // los cambios entran con la
                            // transición de cascada de la casa.
                            return EntradaCascada(
                              child: Padding(
                              padding: const EdgeInsets.only(
                                  bottom: AppEspacio.sm),
                              child: Tarjeta(
                                onTap: _esDueno
                                    ? () => _dialogoNombre(
                                        categoria: c)
                                    : null,
                                padding: const EdgeInsets.all(
                                    AppEspacio.md),
                                child: Row(
                                  children: [
                                    Container(
                                      width: 44,
                                      height: 44,
                                      decoration: BoxDecoration(
                                        // 1.36 H-B3 (136-758):
                                        // tinte con el token de
                                        // opacidad de la casa.
                                        color: AppColores
                                            .naranja
                                            .withValues(
                                                alpha:
                                                    AppOpacidad.tinte),
                                        shape:
                                            BoxShape.circle,
                                      ),
                                      child: Icon(
                                        Icons.category_rounded,
                                        color: AppColores.textoSecundario(context),
                                      ),
                                    ),
                                    const SizedBox(
                                        width: AppEspacio.md),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment
                                                .start,
                                        children: [
                                          Text(
                                              '${c['nombre'] ?? 'Sin nombre'}',
                                              style: AppTexto
                                                  .subtitulo),
                                          Text(
                                              _textoConteo(SyncEngine
                                                  .enteroTolerante(
                                                      c['id'])),
                                              style: AppTexto
                                                  .secundario),
                                          if (!activa)
                                            ChipEstado.libre(
                                                texto:
                                                    'Inactiva',
                                                // 1.36 H-B3
                                                // (136-758): un
                                                // estado negativo
                                                // va con token de
                                                // aviso, no con el
                                                // secundario neutro.
                                                color: AppColores
                                                    .alertaTexto(
                                                        context)),
                                        ],
                                      ),
                                    ),
                                    if (_esDueno) ...[
                                      // 1.36 H-B3 (136-758): el
                                      // switch se anuncia con el
                                      // nombre de SU categoría.
                                      Semantics(
                                        label: 'Categoría activa: '
                                            '${c['nombre'] ?? 'Sin nombre'}',
                                        toggled: activa,
                                        child: Switch(
                                          value: activa,
                                          activeThumbColor:
                                              AppColores.naranja,
                                          onChanged: (v) =>
                                              _cambiarActiva(
                                                  c, v),
                                        ),
                                      ),
                                      IconButton(
                                        icon: const Icon(
                                            Icons.edit_rounded),
                                        tooltip: 'Editar',
                                        onPressed: () =>
                                            _dialogoNombre(
                                                categoria:
                                                    c),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                              ),
                            );
                          },
                        ),
                      ),
          ),
        ],
      ),
    );
  }

  /// F4-08 + 1.36 H-B3 (136-757/758): la cubeta de vendibles
  /// sin categoría asignada — incluye los cuya categoría ya
  /// no existe, contados en su propia frase.
  Widget _tarjetaCubeta(BuildContext context) {
    final total = _sinCategoria + _huerfanos;
    final partes = <String>[
      if (_sinCategoria > 0)
        '$_sinCategoria sin asignar',
      if (_huerfanos > 0)
        '$_huerfanos de categorías que ya no existen',
    ];
    return Tarjeta(
      padding: const EdgeInsets.all(AppEspacio.md),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: AppColores.naranja
                  .withValues(alpha: AppOpacidad.tinte),
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.category_outlined,
                color: AppColores.textoSecundario(context)),
          ),
          const SizedBox(width: AppEspacio.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Sin categoría',
                    style: AppTexto.subtitulo),
                Text(
                    '$total suplemento${total == 1 ? '' : 's'}: '
                    '${partes.join(' · ')}',
                    style: AppTexto.secundario),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 1.30 (Oleada 7, clase B): diálogo de nombre de categoría
/// como StatefulWidget propio: posee y dispone su controlador
/// (antes se creaba en el llamador y nunca se liberaba; el
/// dispose tras showDialog estaba prohibido por Argón #11).
/// Devuelve el texto escrito o null si se cancela.
class _DialogoNombreCategoria extends StatefulWidget {
  final String titulo;
  final String inicial;
  const _DialogoNombreCategoria(
      {required this.titulo, required this.inicial});

  @override
  State<_DialogoNombreCategoria> createState() =>
      _DialogoNombreCategoriaState();
}

class _DialogoNombreCategoriaState
    extends State<_DialogoNombreCategoria> {
  late final TextEditingController _ctrl;
  final _foco = FocusNode();

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.inicial);
    // 1.36 H-B3 (136-758): Guardar se habilita solo con
    // texto real — el diálogo repinta con cada tecla.
    _ctrl.addListener(_repintar);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _foco.requestFocus();
    });
  }

  void _repintar() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _ctrl.removeListener(_repintar);
    _ctrl.dispose();
    _foco.dispose();
    super.dispose();
  }

  bool get _valido => _ctrl.text.trim().isNotEmpty;

  @override
  Widget build(BuildContext context) {
    return DialogoApp(
      titulo: widget.titulo,
      iconoTitulo: Icons.category_rounded,
      contenido: CampoTexto(
        controller: _ctrl,
        focusNode: _foco,
        etiqueta: 'Nombre',
        hint: 'Ej. Proteínas',
        onSubmitted: (_) {
          if (_valido) Navigator.pop(context, _ctrl.text);
        },
      ),
      acciones: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar')),
        // 1.36 H-B3 (136-758): Guardar es el botón primario
        // de la casa y nace deshabilitado sin nombre.
        BotonPrimario(
          texto: 'Guardar',
          expandido: false,
          onPressed: _valido
              ? () => Navigator.pop(context, _ctrl.text)
              : null,
        ),
      ],
    );
  }
}
