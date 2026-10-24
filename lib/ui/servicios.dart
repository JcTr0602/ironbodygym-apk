import 'package:flutter/material.dart';

import '../auth.dart';
import '../localdb.dart';
import '../negocio.dart' show fmtMonto;
import '../servicios.dart';
import '../tiempo.dart';
import 'componentes.dart';
import 'diseno.dart';
import 'servicios_admin.dart';
import 'servicios_estadisticas.dart';

/// v1.8.0: Servicios por dosis — pantalla de venta y cuadre.
///
/// El entrenador vende desde SU lote activo; el dueño además
/// gestiona botes/lotes/agua/precios (Administración) y ve las
/// estadísticas. La lógica vive en lib/servicios.dart; aquí solo
/// se presenta y se captura la intención.
class ServiciosScreen extends StatefulWidget {
  const ServiciosScreen({super.key});

  @override
  State<ServiciosScreen> createState() => _ServiciosScreenState();
}

class _ServiciosScreenState extends State<ServiciosScreen> {
  bool _cargando = true;
  bool _esDueno = false;
  ({double sinAgua, double conAgua, double agua, double comision})?
      _precios;
  ({int saldo, double cpp}) _agua = (saldo: 0, cpp: 0);
  List<Map<String, dynamic>> _misLotes = [];
  int? _loteSel;
  Map<String, dynamic> _cuadre = const {};
  List<Map<String, dynamic>> _ventasHoy = [];
  Set<int> _reversadas = {};

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
    final agua = await stockAguaLocal();
    final lotes = await lotesActivosLocal(responsableId: tid);
    // Nombre del producto en cada lote: lote → bote → suplemento.
    final nombreSup = <int, String>{
      for (final s in await LocalDb.instance.allMirror('suplementos'))
        if ((s['id'] as num?) != null)
          (s['id'] as num).toInt(): '${s['nombre'] ?? ''}',
    };
    final boteSup = <int, int>{
      for (final b in await LocalDb.instance.allMirror('servicio_botes'))
        if ((b['id'] as num?) != null && (b['suplemento_id'] as num?) != null)
          (b['id'] as num).toInt(): (b['suplemento_id'] as num).toInt(),
    };
    for (final l in lotes) {
      final supId = boteSup[(l['bote_id'] as num?)?.toInt()];
      l['producto_nombre'] = nombreSup[supId] ?? 'Servicio';
    }
    final ventas = await LocalDb.instance.allMirror('servicio_ventas');
    final reversadas = <int>{
      for (final v in ventas)
        if ((v['reverso_de'] as num?) != null)
          (v['reverso_de'] as num).toInt(),
    };
    final deHoy = ventas.where((v) {
      if ('${v['fecha'] ?? ''}'.length < 10 ||
          '${v['fecha']}'.substring(0, 10) != hoy) {
        return false;
      }
      return auth.isOwner ||
          LocalDb.normalizarTelegramId(v['registrado_por']) == tid;
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
    final pr = _precios;
    if (pr == null) return;
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
    var metodo = 'efectivo';
    var cantidad = 1;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) {
          final esCasaCliente = cliente != null &&
              (cliente!['cuenta_casa'] as num?)?.toInt() == 1;
          final esCasa = esCasaCliente || paraDuenoCasa;
          final precioUnit = tipo == 'dosis_sin_agua'
              ? pr.sinAgua
              : tipo == 'dosis_con_agua'
                  ? pr.conAgua
                  : pr.agua;
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
                  // v1.8.1: sin iconos — con icono, «Transferencia»
                  // se partía en dos líneas en el diálogo (visto por
                  // Jc en campo el 2026-10-23).
                  SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(
                          value: 'efectivo', label: Text('Efectivo')),
                      ButtonSegment(
                          value: 'transferencia',
                          label: Text('Transferencia')),
                    ],
                    selected: {metodo},
                    onSelectionChanged: (s) =>
                        setD(() => metodo = s.first),
                  ),
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
                onPressed: () => Navigator.pop(ctx, true),
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
        vendedorEsDueno: _esDueno,
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
                      : 'Mi lote · ${lote['producto_nombre'] ?? 'Servicio'}',
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
                        child: Text(
                            '${l['producto_nombre'] ?? 'Lote'} (${l['saldo_local']})'),
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
                : 'Saldo: ${lote['saldo_local']} dosis · '
                    'Agua común: ${_agua.saldo} pomos',
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
    final pr = _precios;
    if (pr == null) return const SizedBox.shrink();
    Widget boton(String tipo, String etiqueta, double precio,
        IconData icono, Color color) {
      final deshabilitado = tipo == 'agua_suelta'
          ? _agua.saldo <= 0 || pr.agua <= 0
          : _loteActual == null ||
              ((_loteActual!['saldo_local'] as int?) ?? 0) <= 0;
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
                pr.agua <= 0 && tipo == 'agua_suelta'
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
        boton('dosis_sin_agua', 'Dosis', pr.sinAgua, Icons.bolt,
            AppColores.naranja),
        const SizedBox(width: AppEspacio.sm),
        boton('dosis_con_agua', 'Dosis + agua', pr.conAgua,
            Icons.water_drop, Colors.blue),
        const SizedBox(width: AppEspacio.sm),
        boton('agua_suelta', 'Pomo agua', pr.agua, Icons.local_drink,
            Colors.teal),
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
          ' · ${v['registrado_por_nombre'] ?? ''}',
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
