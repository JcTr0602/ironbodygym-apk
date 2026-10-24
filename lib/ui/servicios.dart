import 'package:flutter/material.dart';

import '../auth.dart';
import '../etiqueta_producto.dart';
import '../localdb.dart';
import '../negocio.dart' show fmtMonto;
import '../permisos_entrenador.dart';
import '../servicios.dart';
import '../tiempo.dart';
import 'componentes.dart';
import 'diseno.dart';
import 'ranking_servicios.dart';
import 'servicios_admin.dart';
import 'servicios_estadisticas.dart';

/// v1.8.0: Servicios por dosis — pantalla de venta y cuadre.
///
/// El entrenador vende desde SU lote activo; el dueño además
/// gestiona botes/lotes/agua/precios (Administración) y ve las
/// estadísticas. La lógica vive en lib/servicios.dart; aquí solo
/// se presenta y se captura la intención.
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
  bool _esDueno = false;
  ({double sinAgua, double conAgua, double agua, double comision})?
      _precios;
  Map<String, dynamic> _ajustes = const {};
  bool _dialogoInicialAbierto = false;
  ({int saldo, double cpp}) _agua = (saldo: 0, cpp: 0);
  List<Map<String, dynamic>> _misLotes = [];
  int? _loteSel;
  Map<String, dynamic> _cuadre = const {};
  List<Map<String, dynamic>> _ventasHoy = [];
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
    // Personas conocidas (para nombrar al dueño de cada lote):
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
    // Ítem 8: el dueño ve TODOS los lotes activos (vende de
    // cualquiera); el entrenador solo los suyos.
    final lotes = await lotesActivosLocal(
        responsableId: auth.isOwner ? null : tid);
    // Nombre del producto en cada lote: lote → bote → suplemento.
    // Ítem 13: etiqueta compuesta «Nombre · Categoría».
    final cats = mapaCategoriasSuplemento(
        await LocalDb.instance.allMirror('categorias_suplemento'));
    final nombreSup = <int, String>{
      for (final s in await LocalDb.instance.allMirror('suplementos'))
        if ((s['id'] as num?) != null)
          (s['id'] as num).toInt(): etiquetaDeSuplemento(s, cats),
    };
    final boteSup = <int, int>{
      for (final b in await LocalDb.instance.allMirror('servicio_botes'))
        if ((b['id'] as num?) != null && (b['suplemento_id'] as num?) != null)
          (b['id'] as num).toInt(): (b['suplemento_id'] as num).toInt(),
    };
    for (final l in lotes) {
      final supId = boteSup[(l['bote_id'] as num?)?.toInt()];
      l['producto_nombre'] = nombreSup[supId] ?? 'Servicio';
      final respTid =
          LocalDb.normalizarTelegramId(l['responsable_id']);
      l['responsable_nombre'] =
          respTid == null ? '—' : (personas[respTid] ?? 'Entrenador');
      l['responsable_tid'] = respTid;
    }
    final ventas = await LocalDb.instance.allMirror('servicio_ventas');
    final reversadas = <int>{
      for (final v in ventas)
        if ((v['reverso_de'] as num?) != null)
          (v['reverso_de'] as num).toInt(),
    };
    final misLotesIds = <int>{
      for (final l in lotes)
        if ((l['id'] as num?) != null) (l['id'] as num).toInt(),
    };
    final deHoy = ventas.where((v) {
      if ('${v['fecha'] ?? ''}'.length < 10 ||
          '${v['fecha']}'.substring(0, 10) != hoy) {
        return false;
      }
      if (auth.isOwner) return true;
      // Ítem 8 (trazabilidad): el entrenador ve las ventas donde es
      // el VENDEDOR y las hechas de SU lote (p. ej. por el dueño).
      final vend = LocalDb.normalizarTelegramId(v['vendedor_id']) ??
          LocalDb.normalizarTelegramId(v['registrado_por']);
      return vend == tid ||
          misLotesIds.contains((v['lote_id'] as num?)?.toInt());
    }).toList()
      ..sort((a, b) =>
          ((b['id'] as num?)?.toInt() ?? 0)
              .compareTo((a['id'] as num?)?.toInt() ?? 0));
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
      _misLotes = lotes;
      if (_loteSel == null && lotes.isNotEmpty) {
        _loteSel = (lotes.first['id'] as num?)?.toInt();
      }
      _cuadre = cuadre;
      _ventasHoy = deHoy;
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

  Map<String, dynamic>? get _loteActual {
    for (final l in _misLotes) {
      if ((l['id'] as num?)?.toInt() == _loteSel) return l;
    }
    return _misLotes.isEmpty ? null : _misLotes.first;
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
    if (tipo != 'agua_suelta' && _loteActual == null) {
      _aviso(
          _esDueno
              ? 'Primero crea un lote para ti en Administración'
              : 'No tienes un lote activo: pide uno al dueño',
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
    // Argón: la venta nace «a nombre de» el dueño del lote (para el
    // entrenador y para el agua, de sí mismo) y el responsable del
    // efectivo sigue al vendedor.
    final loteRespTid = tipo == 'agua_suelta'
        ? _miTid
        : ((_loteActual!['responsable_tid'] as int?) ?? _miTid);
    var vendedorSel = loteRespTid;
    var responsableSel = loteRespTid;
    final comisionCtrl = TextEditingController(
        text: (_precios?.comision ?? 0).toStringAsFixed(0));
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) {
          final esCasaCliente = cliente != null &&
              (cliente!['cuenta_casa'] as num?)?.toInt() == 1;
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
                                : 'Cliente: ${cliente!['nombre']}',
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
                            if (loteRespTid != null &&
                                loteRespTid != _miTid)
                              DropdownMenuItem(
                                  value: loteRespTid,
                                  child: Text(_personas[loteRespTid] ??
                                      'Entrenador')),
                            if (_miTid != null)
                              DropdownMenuItem(
                                  value: _miTid,
                                  child: const Text('Yo (dueño)')),
                            if (tipo == 'agua_suelta')
                              for (final e in _personas.entries)
                                if (e.key != _miTid &&
                                    e.key != loteRespTid)
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
      await registrarVentaServicio(
        tipo: tipo,
        loteId: tipo == 'agua_suelta'
            ? null
            : (_loteActual!['id'] as num).toInt(),
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
      _aviso('Venta registrada');
      await _cargar();
    } catch (e) {
      _aviso(_limpio(e), error: true);
    }
  }

  Future<void> _salida() async {
    final lote = _loteActual;
    if (lote == null) {
      _aviso('No tienes un lote activo', error: true);
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
        loteId: (lote['id'] as num).toInt(),
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

  Future<void> _revertir(Map<String, dynamic> v) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => DialogoApp(
        titulo: 'Revertir venta',
        iconoTitulo: Icons.undo,
        contenido: Text(
            'Se registrará un reverso auditable de esta venta '
            '(${fmtMonto(((v['precio_unitario'] as num?)?.toDouble() ?? 0) * ((v['cantidad'] as num?)?.toDouble() ?? 0))} CUP). '
            'La dosis vuelve al lote y el dinero sale de la caja.'),
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
    );
    if (ok != true) return;
    try {
      await revertirVentaServicio(
          ventaId: (v['id'] as num).toInt());
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
          IconButton(
            tooltip: 'Actualizar',
            icon: const Icon(Icons.refresh),
            onPressed: _cargar,
          ),
        ],
      ),
      body: _cargando
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _cargar,
              child: ListView(
                padding: const EdgeInsets.all(AppEspacio.lg),
                children: [
                  _tarjetaLote(),
                  const SizedBox(height: AppEspacio.md),
                  _botonesVenta(),
                  const SizedBox(height: AppEspacio.md),
                  _tarjetaCuadre(),
                  if (_esDueno) ...[
                    const SizedBox(height: AppEspacio.md),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                  builder: (_) =>
                                      const ServiciosAdminScreen()),
                            ).then((_) => _cargar()),
                            icon: const Icon(Icons.tune),
                            label: const Text('Administración'),
                          ),
                        ),
                        const SizedBox(width: AppEspacio.sm),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                  builder: (_) =>
                                      const ServiciosEstadisticasScreen()),
                            ),
                            icon: const Icon(Icons.bar_chart),
                            label: const Text('Estadísticas'),
                          ),
                        ),
                      ],
                    ),
                  ],
                  // Ítem 9: ranking de compradores — dueño siempre;
                  // entrenador solo con su permiso (apagado por
                  // defecto, fail-closed sin foto de permisos).
                  if (_esDueno ||
                      PermisosEntrenador().canVerRankingServicios) ...[
                    const SizedBox(height: AppEspacio.md),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) =>
                                  const RankingServiciosScreen()),
                        ),
                        icon: const Icon(Icons.emoji_events_outlined),
                        label: const Text('Ranking de compradores'),
                      ),
                    ),
                  ],
                  const SizedBox(height: AppEspacio.lg),
                  Text('Ventas de hoy',
                      style: AppTexto.titulo.copyWith(fontSize: 16)),
                  const SizedBox(height: AppEspacio.sm),
                  if (_ventasHoy.isEmpty)
                    Text('Sin ventas registradas hoy.',
                        style: AppTexto.cuerpo.copyWith(
                            color: AppColores.textoSecundario(
                                context)))
                  else
                    for (final v in _ventasHoy) _filaVenta(v),
                ],
              ),
            ),
    );
  }

  Widget _tarjetaLote() {
    final lote = _loteActual;
    return Tarjeta(
      padding: const EdgeInsets.all(AppEspacio.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IconoModuloBadge.naranja(Icons.local_drink),
              const SizedBox(width: AppEspacio.sm),
              Expanded(
                child: Text(
                  lote == null
                      ? 'Sin lote activo'
                      : (!_esDueno ||
                              lote['responsable_tid'] == _miTid
                          ? 'Mi lote · ${lote['producto_nombre'] ?? 'Servicio'}'
                          : 'Lote de ${lote['responsable_nombre']} · '
                              '${lote['producto_nombre'] ?? 'Servicio'}'),
                  style: AppTexto.titulo.copyWith(fontSize: 16),
                ),
              ),
              if (_misLotes.length > 1)
                DropdownButton<int>(
                  value: _loteSel,
                  items: [
                    for (final l in _misLotes)
                      DropdownMenuItem(
                        value: (l['id'] as num).toInt(),
                        // Ítem 6 (lote ciego): el entrenador NO ve
                        // saldos; el dueño ve producto, dueño y saldo.
                        child: Text(_esDueno
                            ? '${l['producto_nombre'] ?? 'Lote'} · '
                                '${l['responsable_nombre']} '
                                '(${l['saldo_local']})'
                            : '${l['producto_nombre'] ?? 'Lote'}'),
                      ),
                  ],
                  onChanged: (v) => setState(() => _loteSel = v),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            lote == null
                ? (_esDueno
                    ? 'Crea un lote en Administración para empezar a vender.'
                    : 'Pide al dueño que te reparta un lote.')
                : _esDueno
                    ? 'Saldo: ${lote['saldo_local']} dosis · '
                        'Agua común: ${_agua.saldo} pomos'
                    // Ítem 6: al entrenador solo el agua común
                    // (el saldo de su lote es ciego para él).
                    : 'Agua común: ${_agua.saldo} pomos',
            style: AppTexto.cuerpo,
          ),
          if (lote != null)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: _salida,
                icon: const Icon(Icons.outbox, size: 18),
                label: const Text('Salida sin venta'),
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
        IconData icono, Color color) {
      // Ítem 6: el saldo del lote solo deshabilita para el DUEÑO
      // (él conoce la cantidad); al entrenador ciego nunca se le
      // bloquea la venta por saldo.
      final deshabilitado = tipo == 'agua_suelta'
          ? _agua.saldo <= 0 || precio <= 0
          : _loteActual == null ||
              (_esDueno &&
                  ((_loteActual!['saldo_local'] as int?) ?? 0) <= 0);
      return Expanded(
        child: FilledButton.icon(
          style: FilledButton.styleFrom(
            backgroundColor: color,
            padding: const EdgeInsets.symmetric(vertical: 14),
          ),
          onPressed: deshabilitado ? null : () => _vender(tipo),
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
      );
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        boton('dosis_sin_agua', 'Dosis', precioDe('dosis_sin_agua'),
            Icons.bolt, AppColores.naranja),
        const SizedBox(width: AppEspacio.sm),
        boton('dosis_con_agua', 'Dosis + agua',
            precioDe('dosis_con_agua'), Icons.water_drop, Colors.blue),
        const SizedBox(width: AppEspacio.sm),
        boton('agua_suelta', 'Pomo agua', precioDe('agua_suelta'),
            Icons.local_drink, Colors.teal),
      ],
    );
  }

  Widget _tarjetaCuadre() {
    final c = _cuadre;
    if (c.isEmpty) return const SizedBox.shrink();
    final dosis = ((c['dosis_sin_agua'] as int?) ?? 0) +
        ((c['dosis_con_agua'] as int?) ?? 0);
    return Tarjeta(
      padding: const EdgeInsets.all(AppEspacio.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Cuadre de hoy',
              style: AppTexto.titulo.copyWith(fontSize: 16)),
          const SizedBox(height: 8),
          Text(
            'Dosis: $dosis (${c['dosis_sin_agua']} sin agua · '
            '${c['dosis_con_agua']} con agua) · '
            'Pomos sueltos: ${c['agua_suelta']} · Casa: ${c['casa']}',
            style: AppTexto.cuerpo,
          ),
          Text(
            'Efectivo a entregar: ${fmtMonto(c['efectivo'])} CUP · '
            'Transferencia: ${fmtMonto(c['transferencia'])} CUP',
            style: AppTexto.cuerpo,
          ),
          if (((c['comision'] as double?) ?? 0) != 0)
            Text(
              'Tu comisión de hoy: ${fmtMonto(c['comision'])} CUP',
              style: AppTexto.cuerpo.copyWith(
                  color: AppColores.exito,
                  fontWeight: FontWeight.w600),
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
    final loteEsMio = _misLotes
        .any((l) => (l['id'] as num?)?.toInt() == (v['lote_id'] as num?)?.toInt());
    String? insignia;
    if (!_esDueno && !esReverso && !esCasa && vendTid != null) {
      if (loteEsMio && vendTid != _miTid) {
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
    final filtrados = q.isEmpty
        ? widget.clientes
        : widget.clientes
            .where((c) =>
                '${c['nombre'] ?? ''}'.toLowerCase().contains(q))
            .toList();
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
                        return ListTile(
                          title: Text('${c['nombre'] ?? ''}'),
                          trailing: casa
                              ? const Chip(
                                  label: Text('⭐ Casa'),
                                  visualDensity:
                                      VisualDensity.compact,
                                )
                              : null,
                          onTap: () => Navigator.pop(context, c),
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
