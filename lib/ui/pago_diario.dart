/// Registro de pagos diarios del turno (ej. 200 CUP por turno).
/// Muestra los turnos ya registrados hoy para evitar duplicados.
///
/// v1.0.13: botón rápido +1, nota opcional, total del día, deshacer,
/// editar/eliminar registros.
library;

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../localdb.dart';
import '../negocio.dart';
import '../sync.dart';
import 'componentes.dart';
import 'diseno.dart';
import 'widgets.dart';

class PagoDiarioScreen extends StatefulWidget {
  const PagoDiarioScreen({super.key});
  @override
  State<PagoDiarioScreen> createState() => _PagoDiarioScreenState();
}

class _PagoDiarioScreenState extends State<PagoDiarioScreen> {
  String _turno = 'mañana';
  int _cantidad = 1;
  bool _guardando = false;
  double _precio = 200;
  List<Map<String, dynamic>> _hoy = [];
  final _notaCtrl = TextEditingController();

  // v1.0.15: modo reporte
  bool _modoReporte = false;
  DateTime _fechaReporte = DateTime.now();
  List<Map<String, dynamic>> _reporteDatos = [];
  Map<String, Map<String, double>> _reporteTurnos = {};
  List<Map<String, dynamic>> _ultimos7 = [];
  bool _cargandoReporte = false;

  @override
  void dispose() {
    _notaCtrl.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    LocalDb.instance.getAjustes().then((aj) {
      if (mounted) {
        setState(() =>
            _precio = (aj['pago_diario'] as num?)?.toDouble() ?? 200);
      }
    });
    _cargarHoy();
  }

  Future<void> _cargarHoy() async {
    final h = await diariosDeHoy();
    if (mounted) setState(() => _hoy = h);
  }

  /// v1.0.15: carga los datos del reporte para la fecha seleccionada.
  Future<void> _cargarReporte() async {
    setState(() => _cargandoReporte = true);
    final iso =
        '${_fechaReporte.year.toString().padLeft(4, '0')}-'
        '${_fechaReporte.month.toString().padLeft(2, '0')}-'
        '${_fechaReporte.day.toString().padLeft(2, '0')}';
    final datos = await diariosDeFecha(iso);
    final turnos = await resumenDiarioPorTurno(iso);
    final ult7 = await totalesDiariosUltimos(7);
    if (mounted) {
      setState(() {
        _reporteDatos = datos;
        _reporteTurnos = turnos;
        _ultimos7 = ult7;
        _cargandoReporte = false;
      });
    }
  }

  Future<void> _elegirFecha() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _fechaReporte,
      firstDate: DateTime(2024),
      lastDate: DateTime.now(),
    );
    if (picked != null) {
      setState(() => _fechaReporte = picked);
      _cargarReporte();
    }
  }

  /// Total cobrado hoy en pagos diarios.
  double get _totalHoy {
    double t = 0;
    for (final d in _hoy) {
      t += (d['total'] as num?)?.toDouble() ?? 0;
    }
    return t;
  }

  /// Guarda un pago diario. Devuelve el op_uuid para poder deshacer.
  Future<String?> _guardarOp(
      {required int cantidad, String? nota}) async {
    final uuid = const Uuid().v4();
    await LocalDb.instance.queueOp(
      opUuid: uuid,
      tipo: 'pago_diario',
      payload: {
        'fecha': DateTime.now().toIso8601String().substring(0, 10),
        'turno': _turno,
        'cantidad': cantidad,
        if (nota != null && nota.isNotEmpty) 'nota': nota,
      },
    );
    return uuid;
  }

  void _trasGuardar(String? uuid, int cantidad) {
    _cargarHoy();
    SyncEngine.instance.push();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('$cantidad pago(s) guardado(s)'),
      action: uuid == null
          ? null
          : SnackBarAction(
              label: 'Deshacer',
              onPressed: () => _deshacer(uuid),
            ),
    ));
  }

  /// Deshace un pago recién guardado (lo elimina de la cola si no subió).
  Future<void> _deshacer(String uuid) async {
    await LocalDb.instance.cancelOp(uuid);
    _cargarHoy();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Registro deshecho')));
  }

  Future<void> _guardar() async {
    if (_guardando) return;
    setState(() => _guardando = true);
    try {
      final uuid = await _guardarOp(
        cantidad: _cantidad,
        nota: _notaCtrl.text.trim().isEmpty
            ? null
            : _notaCtrl.text.trim(),
      );
      _notaCtrl.clear();
      setState(() => _cantidad = 1);
      _trasGuardar(uuid, _cantidad);
    } finally {
      if (mounted) setState(() => _guardando = false);
    }
  }

  /// Botón rápido: registra 1 pago de un toque.
  Future<void> _rapido() async {
    if (_guardando) return;
    setState(() => _guardando = true);
    try {
      final uuid = await _guardarOp(cantidad: 1);
      _trasGuardar(uuid, 1);
    } finally {
      if (mounted) setState(() => _guardando = false);
    }
  }

  /// Editar o eliminar un registro del día.
  Future<void> _editarRegistro(Map<String, dynamic> d) async {
    final id = d['id'] as int?;
    if (id == null) return;
    final cantCtrl = TextEditingController(
        text: '${d['cantidad'] ?? 1}');
    final notaCtrl =
        TextEditingController(text: '${d['nota'] ?? ''}');
    final accion = await showDialog<String>(
      context: context,
      builder: (ctx) => DialogoApp(
        titulo: 'Editar pago diario',
        iconoTitulo: Icons.edit,
        contenido: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: cantCtrl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                  labelText: 'Cantidad'),
            ),
            TextField(
              controller: notaCtrl,
              decoration:
                  const InputDecoration(labelText: 'Nota'),
            ),
          ],
        ),
        acciones: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'eliminar'),
            child: const Text('Eliminar',
                style: TextStyle(color: AppColores.error)),
          ),
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancelar')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, 'guardar'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColores.naranja,
                foregroundColor: Colors.white,
              ),
              child: const Text('Guardar')),
        ],
      ),
    );
    cantCtrl.dispose();
    notaCtrl.dispose();
    if (accion == null || !mounted) return;

    if (accion == 'eliminar') {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => DialogoApp(
          titulo: '¿Eliminar?',
          iconoTitulo: Icons.delete,
          contenido: const Text(
              'Se eliminará este registro de pago diario.'),
          acciones: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancelar')),
            ElevatedButton(
                style: ElevatedButton.styleFrom(
                    backgroundColor: AppColores.error),
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Eliminar')),
          ],
        ),
      );
      if (ok != true) return;
      await LocalDb.instance.queueOp(
        opUuid: const Uuid().v4(),
        tipo: 'anular_pago_diario',
        payload: {'pago_diario_id': id},
      );
      _cargarHoy();
      SyncEngine.instance.push();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Registro eliminado')));
      return;
    }

    // Guardar edición
    final cantidad = int.tryParse(cantCtrl.text.trim()) ?? 0;
    if (cantidad < 1) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('La cantidad debe ser al menos 1')));
      return;
    }
    await LocalDb.instance.queueOp(
      opUuid: const Uuid().v4(),
      tipo: 'editar_pago_diario',
      payload: {
        'pago_diario_id': id,
        'cantidad': cantidad,
        'nota': notaCtrl.text.trim(),
      },
    );
    _cargarHoy();
    SyncEngine.instance.push();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Registro actualizado')));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Pago diario'),
        actions: [
          // v1.0.15: alternar entre registrar y reporte
          TextButton.icon(
            icon: Icon(
                _modoReporte ? Icons.edit_outlined : Icons.bar_chart),
            label: Text(_modoReporte ? 'Registrar' : 'Reporte'),
            onPressed: () {
              setState(() => _modoReporte = !_modoReporte);
              if (_modoReporte) _cargarReporte();
            },
          ),
        ],
      ),
      body: Column(
        children: [
          const SyncBanner(compact: true),
          Expanded(
            child: _modoReporte
                ? _vistaReporte()
                : _vistaRegistro(),
          ),
        ],
      ),
    );
  }

  /// v1.0.15: vista de registro (la original).
  Widget _vistaRegistro() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
                Text('(${fmtMonto(_precio)} CUP por turno)',
                    style: TextStyle(
                        color: AppColores.textoSecundario(context))),
                const SizedBox(height: 16),
                const Text('Turno:'),
                Row(
                  children: [
                    ChoiceChip(
                        label: const Text('Mañana'),
                        selected: _turno == 'mañana',
                        onSelected: (_) =>
                            setState(() => _turno = 'mañana')),
                    const SizedBox(width: 8),
                    ChoiceChip(
                        label: const Text('Tarde'),
                        selected: _turno == 'tarde',
                        onSelected: (_) =>
                            setState(() => _turno = 'tarde')),
                  ],
                ),
                const SizedBox(height: 16),
                // Botón rápido + cantidad
                BotonPrimario(
                  texto: 'Registrar 1',
                  icono: Icons.flash_on,
                  onPressed: _guardando ? null : _rapido,
                ),
                const SizedBox(height: 12),
                const Text('O varios a la vez:'),
                Row(
                  children: [
                    const Text('Cantidad: '),
                    IconButton(
                        icon: const Icon(
                            Icons.remove_circle_outline),
                        onPressed: _cantidad > 1
                            ? () => setState(() => _cantidad--)
                            : null),
                    Text('$_cantidad',
                        style: const TextStyle(fontSize: 28)),
                    IconButton(
                        icon: const Icon(
                            Icons.add_circle_outline),
                        onPressed: () =>
                            setState(() => _cantidad++)),
                  ],
                ),
                CampoTexto(
                  controller: _notaCtrl,
                  etiqueta: 'Nota (opcional)',
                  hint: 'Ej: grupo de 3',
                  icono: Icons.note_outlined,
                ),
                const SizedBox(height: 8),
                Text('Total: ${fmtMonto(_precio * _cantidad)} CUP',
                    style: const TextStyle(
                        fontSize: 20, fontWeight: FontWeight.bold)),
                const SizedBox(height: 12),
                BotonSecundario(
                  texto: 'Guardar cantidad',
                  onPressed: _guardando ? null : _guardar,
                ),
                const SizedBox(height: 24),
                const Divider(),
                Row(
                  mainAxisAlignment:
                      MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Registrados hoy:',
                        style: TextStyle(
                            fontWeight: FontWeight.bold)),
                    Text(
                        '${fmtMonto(_totalHoy)} CUP',
                        style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            color: AppColores.naranja)),
                  ],
                ),
                const SizedBox(height: 8),
                if (_hoy.isEmpty)
                  Text('Nada registrado hoy todavía',
                      style: TextStyle(
                          color: AppColores.textoSecundario(context))),
                for (final d in _hoy)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Tarjeta(
                      padding: EdgeInsets.zero,
                      child: ListTile(
                        dense: true,
                        leading: ChipEstado(
                          texto: d['turno'] == 'mañana'
                              ? 'Mañana'
                              : 'Tarde',
                          color: AppColores.naranja,
                        ),
                        title: Text(
                            '${d['cantidad']} pago(s) — ${fmtMonto(d['total'])} CUP'),
                        subtitle: Text([
                          if ((d['nota'] as String?)
                                  ?.isNotEmpty ==
                              true)
                            '${d['nota']}',
                          '${d['registrado_por_nombre'] ?? ''}',
                        ].join(' · ')),
                        trailing: const Icon(
                            Icons.edit_outlined,
                            size: 20),
                        onTap: () => _editarRegistro(d),
                      ),
                    ),
                  ),
              ],
            );
  }

  /// v1.0.15: vista de reporte por fecha y turno.
  Widget _vistaReporte() {
    final man = _reporteTurnos['mañana'];
    final tar = _reporteTurnos['tarde'];
    final cantMan = (man?['cantidad'] ?? 0).toInt();
    final totMan = man?['total'] ?? 0;
    final cantTar = (tar?['cantidad'] ?? 0).toInt();
    final totTar = tar?['total'] ?? 0;
    final total = totMan + totTar;

    // Comparativa: ayer y promedio 7 días
    double ayerTotal = 0;
    double prom7 = 0;
    if (_ultimos7.length >= 2) {
      ayerTotal =
          (_ultimos7[_ultimos7.length - 2]['total'] as num)
              .toDouble();
    }
    if (_ultimos7.isNotEmpty) {
      double suma = 0;
      for (final d in _ultimos7) {
        suma += (d['total'] as num).toDouble();
      }
      prom7 = suma / _ultimos7.length;
    }

    return _cargandoReporte
        ? const Center(child: CircularProgressIndicator())
        : ListView(
            padding: const EdgeInsets.all(16),
            children: [
              // Selector de fecha
              Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.chevron_left),
                    onPressed: () {
                      setState(() {
                        _fechaReporte = _fechaReporte.subtract(
                            const Duration(days: 1));
                      });
                      _cargarReporte();
                    },
                  ),
                  Expanded(
                    child: InkWell(
                      onTap: _elegirFecha,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            vertical: 12),
                        decoration: BoxDecoration(
                          border: Border.all(
                              color: AppColores.borde(context)),
                          borderRadius:
                              BorderRadius.circular(12),
                        ),
                        child: Text(
                          fmtFecha(_fechaReporte.toIso8601String().substring(0, 10)),
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold),
                        ),
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.chevron_right),
                    onPressed: _fechaReporte
                            .toIso8601String()
                            .substring(0, 10) ==
                        DateTime.now()
                            .toIso8601String()
                            .substring(0, 10)
                        ? null
                        : () {
                            setState(() {
                              _fechaReporte =
                                  _fechaReporte.add(
                                      const Duration(days: 1));
                            });
                            _cargarReporte();
                          },
                  ),
                ],
              ),
              const SizedBox(height: 16),
              // Total del día
              Tarjeta(
                color: AppColores.naranja,
                child: Column(
                  children: [
                    Text(
                      '${fmtMonto(total)} CUP',
                      style: const TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.bold,
                          color: Colors.white),
                    ),
                    Text(
                      '${cantMan + cantTar} pagos en el día',
                      style: const TextStyle(
                          color: Colors.white70),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              // Desglose por turno
              Row(
                children: [
                  Expanded(
                      child: _tarjetaTurno('Mañana',
                          cantMan, totMan)),
                  const SizedBox(width: 8),
                  Expanded(
                      child: _tarjetaTurno(
                          'Tarde', cantTar, totTar)),
                ],
              ),
              const SizedBox(height: 12),
              // Comparativas
              if (ayerTotal > 0 || prom7 > 0)
                Tarjeta(
                  child: Column(
                    crossAxisAlignment:
                        CrossAxisAlignment.start,
                    children: [
                      const Text('Comparativa',
                          style: TextStyle(
                              fontWeight:
                                  FontWeight.bold)),
                      const SizedBox(height: 4),
                      if (ayerTotal > 0)
                        Text(
                            'Ayer: ${fmtMonto(ayerTotal)} CUP'),
                      if (prom7 > 0)
                        Text(
                            'Promedio 7 días: ${fmtMonto(prom7)} CUP/día'),
                    ],
                  ),
                ),
              const SizedBox(height: 12),
              // Mini-gráfico 7 días
              if (_ultimos7.isNotEmpty) ...[
                const Text('Últimos 7 días',
                    style: TextStyle(
                        fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                Container(
                  height: 100,
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: AppColores.superficie(context),
                    border: Border.all(
                        color: AppColores.borde(context)),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    crossAxisAlignment:
                        CrossAxisAlignment.end,
                    mainAxisAlignment:
                        MainAxisAlignment.spaceAround,
                    children: _ultimos7.map((d) {
                      final m =
                          (d['total'] as num).toDouble();
                      final maxM = _ultimos7
                          .map((e) =>
                              (e['total'] as num).toDouble())
                          .reduce(
                              (a, b) => a > b ? a : b);
                      final h = maxM > 0
                          ? (m / maxM * 60)
                              .clamp(4.0, 60.0)
                          : 4.0;
                      return Column(
                        mainAxisAlignment:
                            MainAxisAlignment.end,
                        children: [
                          Container(
                            width: 24,
                            height: h,
                            decoration: BoxDecoration(
                              color: AppColores.naranja,
                              borderRadius:
                                  BorderRadius.circular(4),
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            (d['fecha'] as String)
                                .substring(8, 10),
                            style:
                                const TextStyle(fontSize: 9),
                          ),
                        ],
                      );
                    }).toList(),
                  ),
                ),
                const SizedBox(height: 12),
              ],
              // Detalle de registros
              const Text('Registros del día',
                  style:
                      TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              if (_reporteDatos.isEmpty)
                Text('Sin registros este día',
                    style: TextStyle(
                        color: AppColores.textoSecundario(context))),
              for (final d in _reporteDatos)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Tarjeta(
                    padding: EdgeInsets.zero,
                    child: ListTile(
                      dense: true,
                      leading: ChipEstado(
                        texto: d['turno'] == 'mañana'
                            ? 'Mañana'
                            : 'Tarde',
                        color: AppColores.naranja,
                      ),
                    title: Text(
                        '${d['cantidad']} pago(s) — ${fmtMonto(d['total'])} CUP'),
                    subtitle: Text([
                      if ((d['nota'] as String?)
                              ?.isNotEmpty ==
                          true)
                        '${d['nota']}',
                      '${d['registrado_por_nombre'] ?? ''}',
                      if ((d['creado'] as String?)
                              ?.isNotEmpty ==
                          true)
                        (d['creado'] as String).length >= 16 ? (d['creado'] as String).substring(11, 16) : '',
                    ]
                        .where((s) => s.isNotEmpty)
                        .join(' · ')),
                    ),
                  ),
                ),
            ],
          );
  }

  Widget _tarjetaTurno(String titulo, int cantidad, double total) {
    return Tarjeta(
      padding: const EdgeInsets.all(12),
      child: Column(
        children: [
          Text(titulo,
              style: const TextStyle(fontSize: 14)),
          const SizedBox(height: 4),
          Text(fmtMonto(total),
              style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: AppColores.naranja)),
          Text('$cantidad pagos',
              style: TextStyle(
                  fontSize: 12,
                  color: AppColores.textoSecundario(context))),
        ],
      ),
    );
  }
}
