import 'package:flutter/material.dart';

import '../auth.dart';
import '../bloque3.dart';
import '../etiqueta_producto.dart';
import '../localdb.dart';
import '../negocio.dart' show edadDeCarnet, fmtMonto;
import '../permisos_entrenador.dart';
import '../servicios.dart';
import '../sync.dart';
import '../tiempo.dart';
import '../cliente_protegido.dart';
import 'componentes.dart';
import 'diseno.dart';
import 'ranking_servicios.dart';
import 'servicios_admin.dart';
import 'servicios_estadisticas.dart';
import 'servicios_historial.dart';

/// v1.8.0: Servicios por dosis — pantalla de venta y cuadre.
///
/// El entrenador vende desde SU pomo; el dueño además gestiona
/// pomos/agua/precios (Administración) y ve las estadísticas. La
/// lógica vive en lib/servicios.dart; aquí solo se presenta y se
/// captura la intención.
class ServiciosScreen extends StatefulWidget {
  /// Ítem 5 (post-1.8.0): el speed dial de Home abre la pantalla ya
  /// posicionada en un tipo de venta ('dosis_sin_agua' |
  /// 'dosis_con_agua' | 'agua_suelta') y el formulario se abre solo.
  final String? tipoInicial;

  const ServiciosScreen({super.key, this.tipoInicial});

  @override
  State<ServiciosScreen> createState() => _ServiciosScreenState();
}

class _ServiciosScreenState extends State<ServiciosScreen> {
  bool _cargando = true;
  bool _actualizando = false;
  bool _esDueno = false;
  ({double sinAgua, double conAgua, double agua, double comision})?
      _precios;
  Map<String, dynamic> _ajustes = const {};
  bool _dialogoInicialAbierto = false;
  ({int saldo, double cpp}) _agua = (saldo: 0, cpp: 0);
  List<Map<String, dynamic>> _misPomos = [];
  int? _pomoSel;
  Map<String, dynamic> _cuadre = const {};
  List<Map<String, dynamic>> _ventasHoy = [];
  List<Map<String, dynamic>> _ventasTodas = [];
  List<Map<String, dynamic>> _ventasHistorial = [];
  List<Map<String, dynamic>> _salidas = [];
  List<Map<String, dynamic>> _salidasHistorial = [];
  Set<int> _reversadas = {};
  Map<int, String> _personas = {};
  int? _miTid;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    final auth = AuthService();
    final tid = auth.telegramId;
    final hoy = hoyHabanaIso();
    final precios = await preciosServicios();
    final ajustes = await LocalDb.instance.getAjustes();
    final agua = await stockAguaLocal();
    // Personas conocidas (para nombrar al titular de cada pomo):
    // quien haya registrado pagos o ventas de suplementos.
    final personas = <int, String>{};
    if (tid != null) {
      personas[tid] = auth.isOwner ? 'Yo (dueño)' : 'Yo';
    }
    for (final p in await LocalDb.instance.allMirror('pagos')) {
      final ptid = LocalDb.normalizarTelegramId(p['telegram_user_id']);
      final nombre = '${p['registrado_por'] ?? ''}';
      if (ptid != null && nombre.isNotEmpty) {
        personas.putIfAbsent(ptid, () => nombre);
      }
    }
    for (final v
        in await LocalDb.instance.allMirror('ventas_suplementos')) {
      final ptid = LocalDb.normalizarTelegramId(v['registrado_por']);
      if (ptid != null) personas.putIfAbsent(ptid, () => 'Entrenador');
    }
    // Ítem 8: el dueño ve TODOS los pomos activos (vende del
    // principal; puede elegir otro); el entrenador solo el suyo.
    final pomos = await pomosActivosLocal(
        titularId: auth.isOwner ? null : tid);
    // Nombre del producto en cada pomo: pomo → suplemento directo.
    // Ítem 13: etiqueta compuesta «Nombre · Categoría».
    final cats = mapaCategoriasSuplemento(
        await LocalDb.instance.allMirror('categorias_suplemento'));
    final nombreSup = <int, String>{
      for (final s in await LocalDb.instance.allMirror('suplementos'))
        if ((s['id'] as num?) != null)
          (s['id'] as num).toInt(): etiquetaDeSuplemento(s, cats),
    };
    for (final l in pomos) {
      l['producto_nombre'] =
          nombreSup[(l['suplemento_id'] as num?)?.toInt()] ?? 'Servicio';
      final respTid =
          LocalDb.normalizarTelegramId(l['titular_telegram_id']);
      l['titular_nombre'] =
          respTid == null ? '—' : (personas[respTid] ?? 'Entrenador');
      l['titular_tid'] = respTid;
    }
    final ventas = await LocalDb.instance.allMirror('servicio_ventas');
    final salidas =
        await LocalDb.instance.allMirror('servicio_salidas');
    final reversadas = <int>{
      for (final v in ventas)
        if ((v['reverso_de'] as num?) != null)
          (v['reverso_de'] as num).toInt(),
    };
    final misPomosIds = <int>{
      for (final l in pomos)
        if ((l['id'] as num?) != null) (l['id'] as num).toInt(),
    };
    // Historial (pedido Jc 2026-10-28): el mismo predicado de rol
    // que «Ventas de hoy», sin el filtro de fecha. Las salidas sin
    // venta solo las registra el dueño, así que al entrenador no
    // le llega ninguna.
    bool visibleParaMi(Map<String, dynamic> v) {
      if (auth.isOwner) return true;
      // Ítem 8 (trazabilidad): el entrenador ve las ventas donde es
      // el VENDEDOR y las hechas de SU pomo (p. ej. por el dueño).
      // Las ventas viejas de la época de lotes (pomo_id NULL) solo
      // le llegan por la vía del vendedor.
      final vend = LocalDb.normalizarTelegramId(v['vendedor_id']) ??
          LocalDb.normalizarTelegramId(v['registrado_por']);
      return vend == tid ||
          misPomosIds.contains((v['pomo_id'] as num?)?.toInt());
    }

    final deHoy = ventas.where((v) {
      if ('${v['fecha'] ?? ''}'.length < 10 ||
          '${v['fecha']}'.substring(0, 10) != hoy) {
        return false;
      }
      return visibleParaMi(v);
    }).toList()
      ..sort((a, b) =>
          ((b['id'] as num?)?.toInt() ?? 0)
              .compareTo((a['id'] as num?)?.toInt() ?? 0));
    final historial = ventas.where(visibleParaMi).toList();
    final salidasHistorial =
        auth.isOwner ? salidas : <Map<String, dynamic>>[];
    final cuadre = tid == null
        ? const <String, dynamic>{}
        : await cuadreServiciosDia(tid, hoy);
    if (!mounted) return;
    setState(() {
      _esDueno = auth.isOwner;
      _precios = precios;
      _ajustes = ajustes;
      _personas = personas;
      _miTid = tid;
      _agua = agua;
      _misPomos = pomos;
      if (_pomoSel == null && pomos.isNotEmpty) {
        // El dueño vende del principal por defecto; el entrenador
        // solo tiene su pomo.
        final principal = pomos.where(
            (l) => (l['es_principal'] as num?)?.toInt() == 1).toList();
        _pomoSel = ((auth.isOwner && principal.isNotEmpty
                    ? principal.first
                    : pomos.first)['id'] as num?)
                ?.toInt();
      }
      _cuadre = cuadre;
      _ventasHoy = deHoy;
      _ventasTodas = ventas;
      _ventasHistorial = historial;
      _salidas = salidas;
      _salidasHistorial = salidasHistorial;
      _reversadas = reversadas;
      _cargando = false;
    });
    // Ítem 5: llegada desde el speed dial de Home → el formulario de
    // ese tipo se abre solo, una vez, con lotes y precios ya cargados.
    if (widget.tipoInicial != null && !_dialogoInicialAbierto) {
      _dialogoInicialAbierto = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _vender(widget.tipoInicial!);
      });
    }
  }

  /// Actualizar de la sección: baja SOLO las tablas de Servicios
  /// (scope 'servicios') y luego recarga la vista local. La subida
  /// sigue siendo global: la cola se sube en orden y no se puede
  /// partir por sección sin romper la idempotencia.
  /// Da señal siempre: spinner mientras trabaja y aviso al final.
  /// El éxito se detecta por 'ultimo_pull_ts': el scope sync solo
  /// lo actualiza cuando el pull termina bien (los errores los
  /// traga en su stream, no lanza).
  Future<void> _actualizar() async {
    if (_actualizando) return;
    setState(() => _actualizando = true);
    var ok = false;
    try {
      final antes = await LocalDb.instance.getMeta('ultimo_pull_ts');
      await SyncEngine.instance.sincronizarScope('servicios');
      final despues = await LocalDb.instance.getMeta('ultimo_pull_ts');
      ok = antes != despues;
      await _cargar();
    } catch (_) {
      ok = false;
      try {
        await _cargar();
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() => _actualizando = false);
    _aviso(
      ok ? 'Servicios actualizados' : 'Sin conexión, mostrando datos locales',
      error: !ok,
    );
  }

  Map<String, dynamic>? get _pomoActual {
    for (final l in _misPomos) {
      if ((l['id'] as num?)?.toInt() == _pomoSel) return l;
    }
    return _misPomos.isEmpty ? null : _misPomos.first;
  }

  void _aviso(String msg, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: error ? AppColores.error : null,
    ));
  }

  String _limpio(Object e) =>
      e.toString().replaceFirst('Exception: ', '');

  // ---------------------------------------------------------------
  // Venta
  // ---------------------------------------------------------------

  Future<Map<String, dynamic>?> _elegirCliente() async {
    final clientes = await LocalDb.instance.allMirror('clientes');
    clientes.sort((a, b) =>
        '${a['nombre'] ?? ''}'.compareTo('${b['nombre'] ?? ''}'));
    if (!mounted) return null;
    return showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _DialogoCliente(clientes: clientes),
    );
  }

  Future<void> _vender(String tipo) async {
    if (tipo != 'agua_suelta' && _pomoActual == null) {
      _aviso(
          _esDueno
              ? 'Primero abre un bote en Administración para tener principal'
              : 'No tienes un pomo activo: pide uno al dueño',
          error: true);
      return;
    }
    Map<String, dynamic>? cliente;
    var paraDuenoCasa = false;
    // Ítems 5 y 7 (Argón): el formulario nace posicionado en el
    // primer método HABILITADO del producto.
    var metodo =
        primerMetodoServicioActivo(_ajustes, tipo) ?? 'efectivo';
    var cantidad = 1;
    // Ítem 8 (solo el dueño los usa): roles de la venta. Precarga de
    // Argón: la venta nace «a nombre de» el titular del pomo (para el
    // entrenador y para el agua, de sí mismo) y el responsable del
    // efectivo sigue al vendedor.
    final pomoTitularTid = tipo == 'agua_suelta'
        ? _miTid
        : ((_pomoActual!['titular_tid'] as int?) ?? _miTid);
    var vendedorSel = pomoTitularTid;
    var responsableSel = pomoTitularTid;
    final comisionCtrl = TextEditingController(
        text: (_precios?.comision ?? 0).toStringAsFixed(0));
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) {
          final esCasaCliente = cliente != null &&
              (cliente!['cuenta_casa'] as num?)?.toInt() == 1;
          // 1.14 (D14): carnet + edad del elegido, para verificar
          // antes de confirmar la venta.
          final subCliente =
              cliente == null ? '' : subtituloClienteVenta(cliente!);
          final esCasa = esCasaCliente || paraDuenoCasa;
          // Ítem 7: el precio depende del método elegido y se
          // recalcula en vivo al alternar Efectivo/Transferencia.
          final metodosActivos = <String>[
            for (final m in const ['efectivo', 'transferencia'])
              if (metodoServicioActivo(_ajustes, tipo, m)) m,
          ];
          final precioUnit =
              precioServicioMetodo(_ajustes, tipo, metodo);
          return DialogoApp(
            titulo: tipo == 'dosis_sin_agua'
                ? 'Dosis sin agua'
                : tipo == 'dosis_con_agua'
                    ? 'Dosis con agua'
                    : 'Pomo de agua',
            iconoTitulo: Icons.bolt,
            contenido: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  esCasa
                      ? 'Cuenta a la Casa — sin cobro'
                      : '${fmtMonto(precioUnit)} CUP'
                          '${tipo == 'agua_suelta' ? ' por pomo' : ''}',
                  style: AppTexto.titulo.copyWith(fontSize: 16),
                ),
                // v1.8.1 (pedido de Jc 2026-10-23): el diálogo de agua
                // muestra cuántos pomos quedan (el tope ya existía en
                // el selector de cantidad, pero el número no se veía).
                if (tipo == 'agua_suelta') ...[
                  const SizedBox(height: 4),
                  Text(
                    _agua.saldo > 0
                        ? 'En inventario: ${_agua.saldo} pomos'
                        : '⚠️ Sin pomos en inventario',
                    style: AppTexto.secundario,
                  ),
                ],
                const SizedBox(height: 12),
                // v1.8.1 (pedido de Jc 2026-10-23): el cliente se elige
                // en un campo completo y evidente, como en la venta de
                // suplementos — el botón «Elegir» pequeño no se
                // percibía como buscador de clientes del gym.
                InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () async {
                    final sel = await _elegirCliente();
                    if (sel != null) {
                      setD(() {
                        cliente = sel;
                        paraDuenoCasa = false;
                      });
                    }
                  },
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.grey.shade400),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.person_search, size: 20),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            cliente == null
                                ? 'Cliente: sin identificar — toca para elegir del gym'
                                : 'Cliente: ${cliente!['nombre']}'
                                    '${subCliente.isEmpty ? '' : ' · $subCliente'}',
                            style: AppTexto.cuerpo,
                          ),
                        ),
                        if (cliente != null)
                          IconButton(
                            visualDensity: VisualDensity.compact,
                            icon: const Icon(Icons.close, size: 18),
                            onPressed: () =>
                                setD(() => cliente = null),
                          )
                        else
                          const Icon(Icons.chevron_right, size: 20),
                      ],
                    ),
                  ),
                ),
                if (esCasaCliente)
                  const Chip(
                    label: Text('⭐ Cuenta a la Casa'),
                    visualDensity: VisualDensity.compact,
                  ),
                if (_esDueno && cliente == null)
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    title:
                        const Text('Consumo Casa (para el dueño)'),
                    value: paraDuenoCasa,
                    onChanged: (v) =>
                        setD(() => paraDuenoCasa = v ?? false),
                  ),
                if (!esCasa) ...[
                  const SizedBox(height: 8),
                  // Ítem 7: solo se ofrecen los métodos HABILITADOS
                  // del producto; sin ninguno, aviso claro y el
                  // botón Cobrar queda deshabilitado (la Casa no
                  // cobra y no se ve afectada).
                  if (metodosActivos.isEmpty)
                    Text(
                      '⚠️ Este producto no tiene métodos de cobro '
                      'habilitados (Administración → Servicios).',
                      style: AppTexto.secundario.copyWith(
                          color: AppColores.error),
                    )
                  else
                    // v1.8.1: sin iconos — con icono, «Transferencia»
                    // se partía en dos líneas en el diálogo (visto por
                    // Jc en campo el 2026-10-23).
                    SegmentedButton<String>(
                      segments: [
                        for (final m in metodosActivos)
                          ButtonSegment(
                              value: m,
                              label: Text(m == 'efectivo'
                                  ? 'Efectivo'
                                  : 'Transferencia')),
                      ],
                      selected: {metodo},
                      onSelectionChanged: (s) =>
                          setD(() => metodo = s.first),
                    ),
                  // Ítem 8: el dueño vende «a nombre de» otro y
                  // decide quién gana la comisión y quién entrega
                  // el efectivo de ESTA venta.
                  if (_esDueno) ...[
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        const Text('A nombre de:'),
                        const SizedBox(width: 8),
                        DropdownButton<int>(
                          value: vendedorSel,
                          items: [
                            if (pomoTitularTid != null &&
                                pomoTitularTid != _miTid)
                              DropdownMenuItem(
                                  value: pomoTitularTid,
                                  child: Text(_personas[pomoTitularTid] ??
                                      'Entrenador')),
                            if (_miTid != null)
                              DropdownMenuItem(
                                  value: _miTid,
                                  child: const Text('Yo (dueño)')),
                            if (tipo == 'agua_suelta')
                              for (final e in _personas.entries)
                                if (e.key != _miTid &&
                                    e.key != pomoTitularTid)
                                  DropdownMenuItem(
                                      value: e.key,
                                      child: Text(e.value)),
                          ],
                          onChanged: (v) => setD(() {
                            vendedorSel = v ?? vendedorSel;
                            responsableSel = vendedorSel;
                          }),
                        ),
                      ],
                    ),
                    if (vendedorSel != _miTid)
                      TextField(
                        controller: comisionCtrl,
                        keyboardType: const TextInputType
                            .numberWithOptions(decimal: true),
                        decoration: InputDecoration(
                            labelText: 'Comisión para '
                                '${_personas[vendedorSel] ?? 'el entrenador'} (CUP)'),
                      ),
                    if (metodo == 'efectivo' &&
                        vendedorSel != _miTid)
                      Row(
                        children: [
                          const Text('Efectivo lo entrega:'),
                          const SizedBox(width: 8),
                          DropdownButton<int>(
                            value: responsableSel,
                            items: [
                              DropdownMenuItem(
                                  value: vendedorSel,
                                  child: Text(_personas[vendedorSel] ??
                                      'El vendedor')),
                              if (_miTid != null)
                                DropdownMenuItem(
                                    value: _miTid,
                                    child: const Text('Yo (dueño)')),
                            ],
                            onChanged: (v) => setD(
                                () => responsableSel =
                                    v ?? responsableSel),
                          ),
                        ],
                      ),
                  ],
                ],
                if (tipo == 'agua_suelta') ...[
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      const Text('Pomos:'),
                      IconButton(
                        onPressed: cantidad > 1
                            ? () => setD(() => cantidad--)
                            : null,
                        icon: const Icon(Icons.remove_circle_outline),
                      ),
                      Text('$cantidad',
                          style: AppTexto.titulo
                              .copyWith(fontSize: 16)),
                      IconButton(
                        onPressed: cantidad < _agua.saldo
                            ? () => setD(() => cantidad++)
                            : null,
                        icon: const Icon(Icons.add_circle_outline),
                      ),
                    ],
                  ),
                ],
              ],
            ),
            acciones: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancelar'),
              ),
              FilledButton(
                onPressed: (esCasa || metodosActivos.isNotEmpty)
                    ? () => Navigator.pop(ctx, true)
                    : null,
                child: Text(esCasa ? 'Registrar' : 'Cobrar'),
              ),
            ],
          );
        },
      ),
    );
    if (ok != true) return;
    final esCasaCliente = cliente != null &&
        (cliente!['cuenta_casa'] as num?)?.toInt() == 1;
    try {
      final opUuid = await registrarVentaServicio(
        tipo: tipo,
        pomoId: tipo == 'agua_suelta'
            ? null
            : (_pomoActual!['id'] as num).toInt(),
        cantidad: cantidad,
        clienteId: (cliente?['id'] as num?)?.toInt(),
        metodo: metodo,
        casa: esCasaCliente || paraDuenoCasa,
        beneficiario: paraDuenoCasa ? 'dueno' : null,
        // Ítem 8: el vendedor es el dueño solo si vende a su nombre.
        vendedorEsDueno: _esDueno && vendedorSel == _miTid,
        vendedorId: _esDueno ? vendedorSel : null,
        responsableEfectivoId: _esDueno &&
                !esCasaCliente &&
                !paraDuenoCasa &&
                metodo == 'efectivo'
            ? responsableSel
            : null,
        comisionUnitaria: _esDueno &&
                vendedorSel != _miTid &&
                !esCasaCliente &&
                !paraDuenoCasa
            ? (double.tryParse(
                    comisionCtrl.text.trim().replaceAll(',', '.')) ??
                _precios?.comision)
            : null,
      );
      final cobradoEn = ahoraHabana();
      await _cargar();
      // v1.13.0 (E3): Deshacer 15 s exactos desde el cobro (solo
      // dosis; el agua suelta sube de inmediato y no tiene Deshacer).
      if (tipo != 'agua_suelta') {
        _mostrarDeshacer([opUuid], cobradoEn);
      } else {
        _aviso('Venta registrada');
      }
    } catch (e) {
      _aviso(_limpio(e), error: true);
    }
  }

  /// Snackbar Deshacer E3 (15 s): si la op sigue 'pendiente' y no
  /// pasaron 15 s, se borra la venta completa (en múltiple, todo el
  /// grupo). Si no, solo cabe Reversión.
  void _mostrarDeshacer(List<String> opUuids, DateTime cobradoEn) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('Venta registrada'),
        duration: const Duration(seconds: 15),
        action: SnackBarAction(
          label: 'Deshacer',
          onPressed: () async {
            final ok = await deshacerVentaServicio(opUuids, cobradoEn);
            if (!mounted) return;
            if (ok) {
              _aviso('Venta deshecha');
              await _cargar();
            } else {
              _aviso('Ya no se puede deshacer: solo cabe Reversión',
                  error: true);
            }
          },
        ),
      ),
    );
  }

  /// v1.13.0 (Bloque 4, B2 + D1): venta múltiple con contadores N/M.
  /// N dosis (2 ≤ N ≤ tope) y M pomos (0 ≤ M ≤ N, topado a pomos).
  /// El dueño tiene tope local (saldo del pomo); el entrenador es
  /// ciego al pomo y no tiene tope local (el servidor aplica).
  Future<void> _ventaMultiple() async {
    final pomo = _pomoActual;
    if (pomo == null) {
      _aviso('No tienes un pomo activo', error: true);
      return;
    }
    final topeDosis =
        _esDueno ? ((pomo['saldo_local'] as num?)?.toInt() ?? 0) : 999999;
    if (_esDueno && topeDosis < 2) {
      _aviso('No quedan dosis suficientes en el pomo', error: true);
      return;
    }
    final topePomos = _agua.saldo;
    var n = 2;
    var m = 0;
    Map<String, dynamic>? cliente;
    // 1.15 V7: Casa para el dueño (mismo trato que la venta simple).
    var paraDuenoCasa = false;
    var metodo =
        primerMetodoServicioActivo(_ajustes, 'dosis_con_agua') ?? 'efectivo';
    final metodosActivos = <String>[
      for (final x in const ['efectivo', 'transferencia'])
        if (metodoServicioActivo(_ajustes, 'dosis_con_agua', x)) x,
    ];
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) {
          // 1.14 (D14): carnet + edad del elegido, para verificar
          // antes de confirmar la venta.
          final subCliente =
              cliente == null ? '' : subtituloClienteVenta(cliente!);
          // 1.15 V7: Casa elegible = cliente con cuenta_casa=1 o
          // consumo del dueño. Solo así hay total/comisión cero y
          // se omite el método de cobro; un cliente no elegible
          // nunca llega a Casa (no hay casilla para él).
          final esCasaCliente = cliente != null &&
              (cliente!['cuenta_casa'] as num?)?.toInt() == 1;
          final esCasa = esCasaCliente || paraDuenoCasa;
          final precioSin =
              precioServicioMetodo(_ajustes, 'dosis_sin_agua', metodo);
          final precioCon =
              precioServicioMetodo(_ajustes, 'dosis_con_agua', metodo);
          final resumen = totalesVentaMultipleServicio(
            esCasa: esCasa,
            dosisN: n,
            pomosM: m,
            precioSinAgua: precioSin,
            precioConAgua: precioCon,
            comisionUnitaria: _precios?.comision ?? 50,
          );
          final total = resumen.total;
          final comision = resumen.comision;
          return DialogoApp(
            titulo: 'Venta múltiple',
            iconoTitulo: Icons.library_add,
            contenido: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (!_esDueno)
                  const Text(
                    'Tu pomo es ciego: sin tope local de dosis. '
                    'El servidor aplica la venta.',
                    style: AppTexto.secundario,
                  ),
                if (_esDueno)
                  Text('Dosis en el pomo: $topeDosis',
                      style: AppTexto.secundario),
                Text('Pomos en stock: $topePomos',
                    style: AppTexto.secundario),
                const SizedBox(height: 12),
                InkWell(
                  onTap: () async {
                    final sel = await _elegirCliente();
                    if (sel != null) {
                      setD(() {
                        cliente = sel;
                        paraDuenoCasa = false;
                      });
                    }
                  },
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.grey.shade400),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.person_search, size: 20),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            cliente == null
                                ? 'Elegir cliente'
                                : '${cliente!['nombre']}'
                                    '${subCliente.isEmpty ? '' : ' · $subCliente'}',
                            style: AppTexto.cuerpo,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                // 1.15 V7: consumo Casa del dueño (solo dueño y
                // sin cliente elegido), igual que la venta simple.
                if (esCasaCliente)
                  const Chip(
                    label: Text('⭐ Cuenta a la Casa'),
                    visualDensity: VisualDensity.compact,
                  ),
                if (_esDueno && cliente == null)
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    title:
                        const Text('Consumo Casa (para el dueño)'),
                    value: paraDuenoCasa,
                    onChanged: (v) =>
                        setD(() => paraDuenoCasa = v ?? false),
                  ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    const Text('Dosis:'),
                    IconButton(
                      onPressed:
                          n > 2 ? () => setD(() => n--) : null,
                      icon: const Icon(Icons.remove_circle_outline),
                    ),
                    Text('$n',
                        style: AppTexto.titulo.copyWith(fontSize: 16)),
                    IconButton(
                      onPressed: n < topeDosis
                          ? () => setD(() => n++)
                          : null,
                      icon: const Icon(Icons.add_circle_outline),
                    ),
                    const SizedBox(width: 16),
                    const Text('Pomos:'),
                    IconButton(
                      onPressed:
                          m > 0 ? () => setD(() => m--) : null,
                      icon: const Icon(Icons.remove_circle_outline),
                    ),
                    Text('$m',
                        style: AppTexto.titulo.copyWith(fontSize: 16)),
                    IconButton(
                      onPressed:
                          m < n && m < topePomos
                              ? () => setD(() => m++)
                              : null,
                      icon: const Icon(Icons.add_circle_outline),
                    ),
                  ],
                ),
                // 1.15 V7: Casa no ofrece método de cobro.
                if (!esCasa && metodosActivos.length > 1) ...[
                  const SizedBox(height: 8),
                  SegmentedButton<String>(
                    segments: [
                      for (final x in metodosActivos)
                        ButtonSegment(
                            value: x,
                            label: Text(x == 'efectivo'
                                ? 'Efectivo'
                                : 'Transferencia')),
                    ],
                    selected: {metodo},
                    onSelectionChanged: (s) =>
                        setD(() => metodo = s.first),
                  ),
                ],
                const SizedBox(height: 12),
                Text(
                  esCasa
                      ? 'Cuenta a la Casa — sin cobro'
                      : '$n dosis ($m con agua · ${n - m} sin agua)\n'
                          'Total: ${fmtMonto(total)} CUP · '
                          'Comisión: ${fmtMonto(comision)} CUP',
                  style: AppTexto.cuerpo,
                ),
              ],
            ),
            acciones: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancelar'),
              ),
              FilledButton(
                // 1.15 V7: Casa registra sin cobrar (como la venta
                // simple); sin métodos activos y sin Casa, no hay
                // cobro posible.
                onPressed: (esCasa || metodosActivos.isNotEmpty)
                    ? () => Navigator.pop(ctx, true)
                    : null,
                child: Text(esCasa ? 'Registrar' : 'Cobrar'),
              ),
            ],
          );
        },
      ),
    );
    if (ok != true) return;
    // 1.15 V7: Casa de la venta múltiple, igual que la simple:
    // cliente con cuenta_casa=1 o consumo del dueño.
    final esCasaCliente = cliente != null &&
        (cliente!['cuenta_casa'] as num?)?.toInt() == 1;
    final esCasa = esCasaCliente || paraDuenoCasa;
    try {
      final opUuids = await registrarVentaMultipleServicio(
        pomoId: (pomo['id'] as num).toInt(),
        dosisN: n,
        pomosM: m,
        clienteId: (cliente?['id'] as num?)?.toInt(),
        metodo: metodo,
        casa: esCasa,
        beneficiario: paraDuenoCasa ? 'dueno' : null,
        vendedorEsDueno: _esDueno,
        vendedorId: null,
        responsableEfectivoId:
            _esDueno && !esCasa && metodo == 'efectivo' ? _miTid : null,
        topeDosis: topeDosis,
        topePomos: topePomos,
      );
      final cobradoEn = ahoraHabana();
      await _cargar();
      _mostrarDeshacer(opUuids, cobradoEn);
    } catch (e) {
      _aviso(_limpio(e), error: true);
    }
  }

  Future<void> _salida() async {
    final pomo = _pomoActual;
    if (pomo == null) {
      _aviso('No tienes un pomo activo', error: true);
      return;
    }
    var motivo = 'merma';
    final dosisCtrl = TextEditingController(text: '1');
    final notaCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => DialogoApp(
          titulo: 'Salida sin venta',
          iconoTitulo: Icons.outbox,
          contenido: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<String>(
                value: motivo,
                decoration:
                    const InputDecoration(labelText: 'Motivo'),
                items: [
                  const DropdownMenuItem(
                      value: 'merma', child: Text('Merma / rotura')),
                  if (_esDueno) ...[
                    const DropdownMenuItem(
                        value: 'cortesia',
                        child: Text('Cortesía (solo dueño)')),
                    const DropdownMenuItem(
                        value: 'consumo_staff',
                        child: Text('Consumo del staff (solo dueño)')),
                    const DropdownMenuItem(
                        value: 'ajuste',
                        child: Text('Ajuste (solo dueño)')),
                  ],
                ],
                onChanged: (v) => setD(() => motivo = v ?? 'merma'),
              ),
              TextField(
                controller: dosisCtrl,
                keyboardType: TextInputType.number,
                decoration:
                    const InputDecoration(labelText: 'Dosis'),
              ),
              TextField(
                controller: notaCtrl,
                decoration: const InputDecoration(
                    labelText: 'Nota (opcional)'),
              ),
            ],
          ),
          acciones: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Registrar'),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return;
    try {
      await registrarSalidaServicio(
        pomoId: (pomo['id'] as num).toInt(),
        dosis: int.tryParse(dosisCtrl.text.trim()) ?? 0,
        motivo: motivo,
        nota: notaCtrl.text.trim().isEmpty
            ? null
            : notaCtrl.text.trim(),
      );
      _aviso('Salida registrada');
      await _cargar();
    } catch (e) {
      _aviso(_limpio(e), error: true);
    }
  }

  /// v1.13.0 (Bloque 4, D3 + Híbrido A 1.9.0): Reversión con motivo
  /// OBLIGATORIO + «polvo perdido» + guardarraíl de pomo
  /// desactivado. Deshacer E3 (15 s + synced==0) es otro camino:
  /// este diálogo es solo para cuando ya no cabe Deshacer.
  Future<void> _revertir(Map<String, dynamic> v) async {
    final pomoId = (v['pomo_id'] as num?)?.toInt();
    // Guardarraíl: si el pomo ya fue desactivado por el dueño, la
    // reversión está BLOQUEADA con motivo visible (la dosis no
    // puede volver a un pomo desactivado). Ventas viejas de la
    // época de lotes (pomo_id NULL) conservan su guardarraíl viejo.
    if (pomoId != null) {
      final pomos = await LocalDb.instance.allMirror('servicio_pomos');
      final pomo = pomos.where(
          (l) => (l['id'] as num?)?.toInt() == pomoId).toList();
      if (pomo.isNotEmpty &&
          (pomo.first['activo'] as num?)?.toInt() != 1) {
        _aviso('El pomo de esta venta ya fue desactivado por el dueño',
            error: true);
        return;
      }
    } else {
      final loteId = (v['lote_id'] as num?)?.toInt();
      if (loteId != null) {
        final lotes = await LocalDb.instance.allMirror('servicio_lotes');
        final lote = lotes.where(
            (l) => (l['id'] as num?)?.toInt() == loteId).toList();
        if (lote.isNotEmpty &&
            '${lote.first['estado'] ?? ''}' != 'activo') {
          _aviso('El lote de esta venta ya fue cerrado por el dueño',
              error: true);
          return;
        }
      }
    }
    final motivoCtrl = TextEditingController();
    var polvoPerdido = false;
    // Argón #9 (BAJO): la comisión del diálogo era un texto fijo
    // («50 CUP») aunque la comisión es configurable y puede ser 0
    // (dueño, agua suelta, Casa). Se usa la real de la fila.
    final com = (v['comision_monto'] as num?)?.toDouble() ??
        ((v['comision_unitaria'] as num?)?.toDouble() ?? 0) *
            ((v['cantidad'] as num?)?.toInt() ?? 0);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => DialogoApp(
          titulo: 'Revertir venta',
          iconoTitulo: Icons.undo,
          contenido: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                  'Se registrará un reverso auditable de esta venta '
                  '(${fmtMonto(((v['precio_unitario'] as num?)?.toDouble() ?? 0) * ((v['cantidad'] as num?)?.toDouble() ?? 0))} CUP). '
                  'La dosis vuelve al pomo, el pomo al agua común'
                  '${com > 0 ? ' y se restan los ${fmtMonto(com)} CUP de comisión' : ''}.'),
              const SizedBox(height: 12),
              TextField(
                controller: motivoCtrl,
                decoration: const InputDecoration(
                    labelText: 'Motivo (obligatorio)'),
              ),
              // 1.15 V5: «polvo perdido» solo lo marca el dueño
              // (patrón AuthService().isOwner vía _esDueno). La
              // regla del servidor no cambia: sin salida por merma
              // autorizada, la dosis no vuelve al saldo con una
              // reversión ordinaria. Ventas viejas sin pomo no lo
              // ofrecen: su merma no se puede atribuir a un pomo.
              if (mostrarCheckboxPolvoPerdido(_esDueno) &&
                  (v['pomo_id'] as num?) != null)
                CheckboxListTile(
                  value: polvoPerdido,
                  contentPadding: EdgeInsets.zero,
                  title: const Text(
                      'El polvo se perdió físicamente'),
                  subtitle: const Text(
                      'La reversión anula cobro y comisión y la '
                      'pérdida queda como salida no vendida.'),
                  onChanged: (x) =>
                      setD(() => polvoPerdido = x ?? false),
                ),
            ],
          ),
          acciones: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Revertir'),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return;
    final motivo = motivoCtrl.text.trim();
    if (motivo.isEmpty) {
      _aviso('Escribe el motivo de la reversión', error: true);
      return;
    }
    try {
      await revertirVentaServicio(
        ventaId: (v['id'] as num).toInt(),
        motivo: motivo,
        polvoPerdido: polvoPerdido,
        pomoId: pomoId,
        cantidad: (v['cantidad'] as num?)?.toInt(),
      );
      _aviso('Reverso registrado');
      await _cargar();
    } catch (e) {
      _aviso(_limpio(e), error: true);
    }
  }

  // ---------------------------------------------------------------
  // Vista
  // ---------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Servicios ⚡'),
        actions: [
          // Rediseño opción A (Jc 2026-10-28): Administración,
          // Estadísticas y Ranking suben al AppBar; el cuerpo queda
          // para Mostrador, Cuadre y Ventas. Ítem 9: ranking — dueño
          // siempre; entrenador solo con su permiso (fail-closed).
          if (_esDueno ||
              PermisosEntrenador().canVerRankingServicios)
            IconButton(
              tooltip: 'Ranking de compradores',
              icon: const Icon(Icons.emoji_events_outlined),
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => const RankingServiciosScreen()),
              ),
            ),
          if (_esDueno)
            IconButton(
              tooltip: 'Estadísticas',
              icon: const Icon(Icons.bar_chart),
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) =>
                        const ServiciosEstadisticasScreen()),
              ).then((_) => _cargar()),
            ),
          if (_esDueno)
            IconButton(
              tooltip: 'Administración',
              icon: const Icon(Icons.tune),
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => const ServiciosAdminScreen()),
              ).then((_) => _cargar()),
            ),
          IconButton(
            tooltip: 'Actualizar',
            icon: _actualizando
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
            onPressed: _actualizando ? null : _actualizar,
          ),
        ],
      ),
      body: _cargando
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _actualizar,
              child: ListView(
                padding: const EdgeInsets.all(AppEspacio.lg),
                children: [
                  _tarjetaPomo(),
                  const SizedBox(height: AppEspacio.md),
                  _botonesVenta(),
                  const SizedBox(height: AppEspacio.md),
                  _tarjetaCuadre(),
                  const SizedBox(height: AppEspacio.lg),
                  // Historial completo (pedido Jc 2026-10-28):
                  // todas las operaciones de raciones, combos y
                  // agua, más salidas sin venta, con filtros.
                  Row(
                    children: [
                      Text('Ventas de hoy',
                          style:
                              AppTexto.titulo.copyWith(fontSize: 16)),
                      const Spacer(),
                      TextButton.icon(
                        icon: const Icon(Icons.history, size: 18),
                        label: const Text('Historial'),
                        onPressed: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => ServiciosHistorialScreen(
                              ventas: _ventasHistorial,
                              salidas: _salidasHistorial,
                              reversadas: _reversadas,
                              esDueno: _esDueno,
                              personas: _personas,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppEspacio.sm),
                  if (_ventasHoy.isEmpty)
                    Center(
                      child: Container(
                        padding: const EdgeInsets.all(AppEspacio.lg),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(12),
                          color: AppColores.textoSecundario(context)
                              .withValues(alpha: 0.08),
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.receipt_long,
                              color: AppColores.textoSecundario(context)
                                  .withValues(alpha: 0.5),
                            ),
                            const SizedBox(height: AppEspacio.sm),
                            Text('Sin ventas registradas hoy.',
                                style: AppTexto.cuerpo.copyWith(
                                    color: AppColores.textoSecundario(
                                        context))),
                          ],
                        ),
                      ),
                    )
                  else
                    for (final v in _ventasHoy) _filaVenta(v),
                ],
              ),
            ),
    );
  }

  // Rediseño opción A: etiqueta pequeña del encabezado del pomo.
  // Misma semántica que el título viejo (rol + principal + titular).
  String _etiquetaPomo(Map<String, dynamic>? pomo) {
    if (pomo == null) return 'SIN POMO ACTIVO';
    if (!_esDueno || pomo['titular_tid'] == _miTid) return 'MI POMO';
    if ((pomo['es_principal'] as num?)?.toInt() == 1) {
      return 'POMO PRINCIPAL';
    }
    return 'POMO DE ${(pomo['titular_nombre'] ?? '').toString().toUpperCase()}';
  }

  // 1.15 (decisión Jc 2026-10-26): salida sin venta SOLO dueño,
  // sin importar el motivo. El servidor rechaza además
  // (OPS_SOLO_ADMIN + _require_owner). Compacta, arriba a la derecha.
  Widget _botonSalidaCompacto() {
    return TextButton.icon(
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        minimumSize: const Size(0, 32),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      onPressed: _salida,
      icon: const Icon(Icons.outbox, size: 18),
      label: const Text('Salida sin venta'),
    );
  }

  Widget _pildora(String texto, {bool destacado = false}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        color: destacado
            ? AppColores.naranja.withValues(alpha: 0.15)
            : AppColores.textoSecundario(context)
                .withValues(alpha: 0.10),
      ),
      child: Text(
        texto,
        style: AppTexto.cuerpo.copyWith(
            fontWeight:
                destacado ? FontWeight.w600 : FontWeight.w400),
      ),
    );
  }

  Widget _tarjetaPomo() {
    final pomo = _pomoActual;
    return Tarjeta(
      padding: const EdgeInsets.all(AppEspacio.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Nivel 1 — encabezado. Con más de un pomo, el encabezado
          // entero es el selector de ancho completo; con uno solo,
          // fila limpia (insignia + etiqueta pequeña + nombre).
          if (_misPomos.length > 1)
            Row(
              children: [
                Text(_etiquetaPomo(pomo),
                    style:
                        AppTexto.secundario.copyWith(fontSize: 11)),
                const Spacer(),
                if (pomo != null && _esDueno) _botonSalidaCompacto(),
              ],
            ),
          if (_misPomos.length > 1)
            DropdownButtonHideUnderline(
              child: DropdownButton<int>(
                isExpanded: true,
                value: _pomoSel,
                items: [
                  for (final l in _misPomos)
                    DropdownMenuItem(
                      value: (l['id'] as num).toInt(),
                      // Ítem 6 (pomo ciego): el entrenador NO ve
                      // saldos; el dueño ve producto, titular y saldo.
                      child: Text(
                        _esDueno
                            ? '${l['producto_nombre'] ?? 'Pomo'} · '
                                '${(l['es_principal'] as num?)?.toInt() == 1 ? 'Principal' : l['titular_nombre']} '
                                '(${l['saldo_local']})'
                            : '${l['producto_nombre'] ?? 'Pomo'}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: (v) => setState(() => _pomoSel = v),
              ),
            )
          else
            Row(
              children: [
                IconoModuloBadge.naranja(Icons.local_drink),
                const SizedBox(width: AppEspacio.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_etiquetaPomo(pomo),
                          style: AppTexto.secundario
                              .copyWith(fontSize: 11)),
                      Text(
                        pomo == null
                            ? 'Sin pomo activo'
                            : '${pomo['producto_nombre'] ?? 'Servicio'}',
                        style: AppTexto.titulo.copyWith(fontSize: 16),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                if (pomo != null && _esDueno) _botonSalidaCompacto(),
              ],
            ),
          const SizedBox(height: 8),
          // Nivel 2 — píldoras. Ítem 6: el saldo del pomo solo lo ve
          // el dueño; al entrenador solo el agua común (pomo ciego).
          if (pomo == null)
            Text(
              _esDueno
                  ? 'Abre un bote en Administración para tener principal.'
                  : 'Pide al dueño que te rellene un pomo.',
              style: AppTexto.cuerpo,
            )
          else
            Wrap(
              spacing: AppEspacio.sm,
              runSpacing: AppEspacio.sm,
              children: [
                if (_esDueno)
                  _pildora('Saldo: ${pomo['saldo_local']} dosis',
                      destacado: true),
                _pildora('Agua común: ${_agua.saldo} pomos'),
              ],
            ),
          // v1.13.0 (Bloque 4): desglose del pomo para el dueño
          // (asignadas − repartidas − ventas − salidas, espejo).
          // Al pie, tras un divisor, como micro-datos.
          if (pomo != null && _esDueno)
            Builder(builder: (ctx) {
              final pid = (pomo['id'] as num?)?.toInt();
              final d = desglosePomo(
                pomo: pomo,
                ventasEspejo: _ventasTodas
                    .where((v) => (v['pomo_id'] as num?)?.toInt() == pid)
                    .toList(),
                salidasEspejo: _salidas
                    .where((s) => (s['pomo_id'] as num?)?.toInt() == pid)
                    .toList(),
              );
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Divider(height: 24),
                  Text(
                    'Asignadas: ${d.asignadas} · '
                    'Repartidas: ${d.repartidas} · '
                    'Vendidas: ${d.ventas} · Salidas: ${d.salidas}',
                    style:
                        AppTexto.secundario.copyWith(fontSize: 11),
                  ),
                ],
              );
            }),
          // v1.12.0 (C6): aviso de pomo por agotarse (< 5, umbral
          // fijo de Jc). NO revela el saldo exacto al entrenador
          // (pomo ciego, ítem 6): solo que quedan pocas dosis.
          // NUNCA bloquea la venta, solo advierte. Banda ámbar.
          if (pomo != null &&
              avisoLotePorAgotarse(
                  (pomo['saldo_local'] as num?)?.toInt() ?? 999))
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  color: AppColores.alertaOscuro
                      .withValues(alpha: 0.15),
                ),
                child: Text(
                  _esDueno
                      ? '⚠ Quedan pocas dosis en este pomo (menos de 5).'
                      : '⚠ Te quedan pocas dosis en este pomo (menos de 5): '
                          'avisa al dueño para que te rellene.',
                  style: AppTexto.cuerpo.copyWith(
                      color: AppColores.alertaOscuro,
                      fontWeight: FontWeight.w600),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _botonesVenta() {
    if (_precios == null) return const SizedBox.shrink();
    // Ítem 7: la etiqueta muestra el precio del primer método
    // habilitado del producto (el que el formulario preselecciona).
    double precioDe(String tipo) => precioServicioMetodo(_ajustes,
        tipo, primerMetodoServicioActivo(_ajustes, tipo) ?? 'efectivo');
    Widget boton(String tipo, String etiqueta, double precio,
        IconData icono, Color color, {bool grande = false}) {
      // v1.13.0 (Bloque 4, Argón ajuste 1): bloqueo SEPARADO
      // dosis vs pomos (nunca un interruptor único) + motivo
      // visible bajo el botón apagado. El entrenador sigue ciego
      // al saldo del pomo (ítem 6 de la 1.9.0): solo se le bloquea
      // por falta de pomo o de pomos (el agua común sí la ve).
      final est = estadoBotonVentaServicio(
        tipo: tipo,
        tienePomo: _pomoActual != null,
        dosisRestantes: (_pomoActual?['saldo_local'] as num?)?.toInt() ?? 0,
        pomos: _agua.saldo,
        esDueno: _esDueno,
        precio: precio,
      );
      return Expanded(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: color,
                // Rediseño post-1.15 (Argón, opción A): la fila
                // principal es más alta (64px) para el pulgar en
                // el mostrador; la secundaria mantiene su altura.
                padding: EdgeInsets.symmetric(
                    vertical: grande ? 20 : 14),
              ),
              onPressed:
                  est.habilitado ? () => _vender(tipo) : null,
              icon: Icon(icono, size: 20),
              label: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(etiqueta,
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 13)),
                  Text(
                    precio <= 0 && tipo == 'agua_suelta'
                        ? 'sin precio'
                        : '${fmtMonto(precio)} CUP',
                    style: const TextStyle(fontSize: 11),
                  ),
                ],
              ),
            ),
            if (!est.habilitado && est.motivo != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  est.motivo!,
                  style: AppTexto.secundario,
                  textAlign: TextAlign.center,
                ),
              ),
          ],
        ),
      );
    }

    // Rediseño post-1.15 (Argón, opción A, jerarquía 2 + 2): la
    // venta del servicio (dosis sola o con agua) ocupa la fila
    // principal a lo ancho; el agua suelta y la venta múltiple
    // bajan a una fila secundaria. Precios, estados, motivos y
    // flujos (_vender, _ventaMultiple) intactos.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            boton('dosis_sin_agua', 'Dosis',
                precioDe('dosis_sin_agua'), Icons.bolt, AppColores.naranja,
                grande: true),
            const SizedBox(width: AppEspacio.sm),
            boton('dosis_con_agua', 'Dosis + agua',
                precioDe('dosis_con_agua'), Icons.water_drop, Colors.blue,
                grande: true),
          ],
        ),
        const SizedBox(height: AppEspacio.sm),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // «Solo agua» (antes «Pomo agua»): mismo precio y
            // mismo bloqueo; el nombre ya no se confunde con
            // «Dosis + agua».
            boton('agua_suelta', 'Solo agua',
                precioDe('agua_suelta'), Icons.local_drink, Colors.teal),
            const SizedBox(width: AppEspacio.sm),
            Expanded(
              child: OutlinedButton.icon(
                onPressed:
                    _pomoActual == null ? null : _ventaMultiple,
                icon: const Icon(Icons.library_add, size: 20),
                label: const Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('Venta múltiple',
                        style: TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 13)),
                    Text('Varias dosis',
                        style: TextStyle(fontSize: 11)),
                  ],
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _tarjetaCuadre() {
    final c = _cuadre;
    if (c.isEmpty) return const SizedBox.shrink();
    final dosis = ((c['dosis_sin_agua'] as int?) ?? 0) +
        ((c['dosis_con_agua'] as int?) ?? 0);
    final comision = (c['comision'] as double?) ?? 0;
    return Tarjeta(
      padding: const EdgeInsets.all(AppEspacio.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text('Cuadre de hoy',
                    style: AppTexto.titulo.copyWith(fontSize: 16)),
              ),
              if (comision != 0)
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(20),
                    color:
                        AppColores.exito.withValues(alpha: 0.15),
                  ),
                  child: Text(
                    'Tu comisión: ${fmtMonto(comision)} CUP',
                    style: AppTexto.cuerpo.copyWith(
                        color: AppColores.exito,
                        fontWeight: FontWeight.w600),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Efectivo a entregar',
                        style: AppTexto.secundario),
                    Text('${fmtMonto(c['efectivo'])} CUP',
                        style: AppTexto.titulo.copyWith(fontSize: 16)),
                  ],
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Transferencia',
                        style: AppTexto.secundario),
                    Text('${fmtMonto(c['transferencia'])} CUP',
                        style: AppTexto.titulo.copyWith(fontSize: 16)),
                  ],
                ),
              ),
            ],
          ),
          const Divider(height: 24),
          Row(
            children: [
              Expanded(
                child: Column(
                  children: [
                    Text('$dosis',
                        style: AppTexto.titulo.copyWith(fontSize: 16)),
                    Text('Dosis hoy',
                        style: AppTexto.secundario
                            .copyWith(fontSize: 11)),
                    Text(
                        '${c['dosis_sin_agua']} sin agua · '
                        '${c['dosis_con_agua']} con agua',
                        style: AppTexto.secundario
                            .copyWith(fontSize: 11)),
                  ],
                ),
              ),
              Expanded(
                child: Column(
                  children: [
                    Text('${c['agua_suelta']}',
                        style: AppTexto.titulo.copyWith(fontSize: 16)),
                    Text('Pomos sueltos',
                        style: AppTexto.secundario
                            .copyWith(fontSize: 11)),
                  ],
                ),
              ),
              Expanded(
                child: Column(
                  children: [
                    Text('${c['casa']}',
                        style: AppTexto.titulo.copyWith(fontSize: 16)),
                    Text('Cuenta Casa',
                        style: AppTexto.secundario
                            .copyWith(fontSize: 11)),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _filaVenta(Map<String, dynamic> v) {
    final esReverso = (v['reverso_de'] as num?) != null;
    final yaReversada =
        _reversadas.contains((v['id'] as num?)?.toInt());
    final esCasa = (v['casa'] as num?)?.toInt() == 1;
    final monto = ((v['precio_unitario'] as num?)?.toDouble() ?? 0) *
        ((v['cantidad'] as num?)?.toDouble() ?? 0);
    final tipoTxt = switch ('${v['tipo']}') {
      'dosis_sin_agua' => 'Dosis sin agua',
      'dosis_con_agua' => 'Dosis con agua',
      'agua_suelta' => 'Pomo de agua ×${v['cantidad']}',
      _ => '${v['tipo']}',
    };
    // Ítem 8 (trazabilidad para el entrenador): si la venta salió
    // de MI lote pero el vendedor fue otro (el dueño), se dice con
    // su insignia; si el dueño la registró a MI nombre, también.
    final vendTid = LocalDb.normalizarTelegramId(v['vendedor_id']);
    final regTid = LocalDb.normalizarTelegramId(v['registrado_por']);
    final pomoEsMio = _misPomos.any((l) =>
        (l['id'] as num?)?.toInt() == (v['pomo_id'] as num?)?.toInt());
    String? insignia;
    if (!_esDueno && !esReverso && !esCasa && vendTid != null) {
      if (pomoEsMio && vendTid != _miTid) {
        final respTid = LocalDb.normalizarTelegramId(
            v['responsable_efectivo_id']);
        insignia = 'Vendida por el dueño de tu pomo · '
            'Comisión: ${fmtMonto((v['comision_monto'] as num?)?.toDouble() ?? 0)} CUP · '
            'Efectivo: ${v['metodo'] == 'transferencia' ? '—' : (respTid == _miTid ? 'Tú' : 'Dueño')}';
      } else if (vendTid == _miTid && regTid != _miTid) {
        insignia = 'Registrada por el dueño a tu nombre';
      }
    }
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: Icon(
          esReverso
              ? Icons.undo
              : esCasa
                  ? Icons.star
                  : Icons.bolt,
          color: esReverso
              ? AppColores.error
              : esCasa
                  ? Colors.amber
                  : AppColores.naranja,
        ),
        title: Text(esReverso ? 'Reverso · $tipoTxt' : tipoTxt),
        subtitle: Text(
          '${v['cliente_nombre'] ?? 'Sin identificar'}'
          '${esCasa ? ' · Casa' : ' · ${v['metodo'] ?? ''}'}'
          ' · ${v['registrado_por_nombre'] ?? ''}'
          '${insignia != null ? '\n$insignia' : ''}',
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('${fmtMonto(monto)} CUP',
                style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: esReverso ? AppColores.error : null)),
            if (!esReverso && !yaReversada)
              IconButton(
                tooltip: 'Revertir',
                icon: const Icon(Icons.undo, size: 20),
                onPressed: () => _revertir(v),
              ),
          ],
        ),
      ),
    );
  }
}

/// 1.14 (D14): subtítulo del cliente en el selector de venta:
/// carnet + edad. Sin esto, dos hermanos con el mismo apellido
/// son indistinguibles y la venta cae en el equivocado (caso
/// 121/34 de 2026-10-26: la dosis se registró a Richard en vez
/// de a Cristian). La edad sale del carnet (6 primeros dígitos
/// = AAMMDD); con fecha imposible no se muestra edad, solo el
/// carnet. Se usa también en el cliente ya elegido, para
/// verificar ANTES de confirmar la venta.
String subtituloClienteVenta(Map<String, dynamic> c) {
  final carnet = '${c['carnet'] ?? ''}'.trim();
  if (carnet.isEmpty) return '';
  final edad = edadDeCarnet(carnet);
  return edad == null ? 'Carnet $carnet' : 'Carnet $carnet · $edad años';
}

/// Selector de cliente (lista completa del espejo + buscador).
class _DialogoCliente extends StatefulWidget {
  final List<Map<String, dynamic>> clientes;
  const _DialogoCliente({required this.clientes});

  @override
  State<_DialogoCliente> createState() => _DialogoClienteState();
}

class _DialogoClienteState extends State<_DialogoCliente> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final q = _ctrl.text.trim().toLowerCase();
    // 1.14 (D14): buscar también por carnet (solo dígitos), para
    // distinguir homónimos por el documento y no solo por nombre.
    final qDigitos = q.replaceAll(RegExp(r'[^0-9]'), '');
    final filtrados = q.isEmpty
        ? widget.clientes
        : widget.clientes.where((c) {
            if ('${c['nombre'] ?? ''}'.toLowerCase().contains(q)) {
              return true;
            }
            // Cliente protegido (2026-10-26, Protegido 2 H4): al
            // protegido solo se llega por nombre, nunca por carnet.
            if (esVistaProtegida(c)) return false;
            if (qDigitos.isNotEmpty) {
              final carnet =
                  '${c['carnet'] ?? ''}'.replaceAll(RegExp(r'[^0-9]'), '');
              if (carnet.contains(qDigitos)) return true;
            }
            return false;
          }).toList();
    return DialogoApp(
      titulo: 'Cliente del gym',
      iconoTitulo: Icons.person_search,
      contenido: SizedBox(
        width: double.maxFinite,
        height: 380,
        child: Column(
          children: [
            TextField(
              controller: _ctrl,
              autofocus: true,
              decoration: const InputDecoration(
                hintText: 'Buscar por nombre…',
                prefixIcon: Icon(Icons.search),
                border: OutlineInputBorder(),
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: filtrados.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text(
                          // v1.8.1: distinguir «el teléfono aún no
                          // tiene clientes» de «la búsqueda no dio
                          // resultados» (confusión de campo 2026-10-23).
                          widget.clientes.isEmpty
                              ? 'No hay clientes cargados en este teléfono.\n'
                                  'Sincroniza la app y vuelve a intentarlo.'
                              : 'Sin resultados para «$q»',
                          textAlign: TextAlign.center,
                        ),
                      ),
                    )
                  : ListView.builder(
                      shrinkWrap: true,
                      itemCount: filtrados.length,
                      itemBuilder: (_, i) {
                        final c = filtrados[i];
                        final casa =
                            (c['cuenta_casa'] as num?)?.toInt() == 1;
                        final sub = subtituloClienteVenta(c);
                        // Cliente protegido (2026-10-26, A3):
                        // solo nombre y candado (sin subtítulo con
                        // carnet/edad) y la selección se intercepta
                        // en el acto; el diálogo queda abierto.
                        return ListTile(
                          title: Text('${c['nombre'] ?? ''}'),
                          subtitle: esVistaProtegida(c)
                              ? null
                              : (sub.isEmpty ? null : Text(sub)),
                          trailing: esVistaProtegida(c)
                              ? const Icon(Icons.lock,
                                  color: AppColores.naranja)
                              : casa
                                  ? const Chip(
                                      label: Text('⭐ Casa'),
                                      visualDensity:
                                          VisualDensity.compact,
                                    )
                                  : null,
                          onTap: () {
                            if (esVistaProtegida(c)) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                      content: Text(
                                          mensajeClienteProtegido)));
                              return;
                            }
                            Navigator.pop(context, c);
                          },
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      acciones: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
      ],
    );
  }
}
