/// Administración (solo admin).
///
/// Estadísticas del negocio, montos, usuarios APK, pendiente a entrega,
/// gastos, cierre de caja, papelera y exportar. Todo funciona offline:
/// los cambios se encolan y suben al sincronizar.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:uuid/uuid.dart';

import '../localdb.dart';
import '../negocio.dart';
import '../permisos.dart';
import '../sync.dart';
import '../tipos_pago.dart';
import 'componentes.dart';
import 'diseno.dart';
import 'cuentas_cobrar.dart';
import 'papelera.dart';
import 'congelados.dart';
import 'auditoria.dart';
import 'riesgo.dart';
import 'historial_entrenador.dart';
import 'exportar_excel.dart';
import 'usuarios.dart';
import 'widgets.dart';
import 'detalle_pendiente.dart';

class AdminScreen extends StatefulWidget {
  const AdminScreen({super.key});
  @override
  State<AdminScreen> createState() => _AdminScreenState();
}

class _AdminScreenState extends State<AdminScreen> {
  double _ingresos = 0;
  int _inscMes = 0;
  int _morosos = 0;
  List<Map<String, dynamic>> _pend = [];
  List<Map<String, dynamic>> _inscPorEntrenador = [];
  List<Map<String, dynamic>> _gastos = [];
  Map<String, double> _caja = {'efectivo': 0, 'transferencia': 0};
  double _gastosHoy = 0;
  final Map<String, TextEditingController> _montos = {};
  bool _cargando = true;
  // Salud del sistema
  SyncDetalle _syncDet = const SyncDetalle();
  int _pendientesSubir = 0;

  List<TipoPago> _tipos = [];

  static const _clavesMonto = [
    ('transferencia', 'Mensualidad por transferencia'),
    ('pago_diario', 'Pago diario'),
  ];

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  @override
  void dispose() {
    for (final c in _montos.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _cargar() async {
    final ing = await ingresosMes();
    final insc = await inscripcionesMes();
    final mor = await morosos();
    final pend = await pendientePorEntrenador();
    final inscEntrenador = await inscripcionesPorEntrenador();
    final gastos = await gastosTodos();
    final caja = await cobradoHoyPorMetodo();
    final hoy = DateTime.now();
    final hoyIso = '${hoy.year.toString().padLeft(4, '0')}-'
        '${hoy.month.toString().padLeft(2, '0')}-'
        '${hoy.day.toString().padLeft(2, '0')}';
    final gh = await gastosDe(hoyIso);
    final aj = await LocalDb.instance.getAjustes();
    final tipos = await getTiposPago(soloActivos: false);
    // Salud del sistema
    final det = await SyncEngine.instance.detalle();
    final pendSubir = await LocalDb.instance.countPendingOps();
    if (mounted) {
      setState(() {
        _ingresos = ing;
        _inscMes = insc;
        _morosos = mor;
        _pend = pend;
        _inscPorEntrenador = inscEntrenador;
        _gastos = gastos;
        _caja = caja;
        _gastosHoy = gh;
        _syncDet = det;
        _pendientesSubir = pendSubir;
        _tipos = tipos;
        for (final (clave, _) in _clavesMonto) {
          _montos
              .putIfAbsent(clave, () => TextEditingController())
              .text = '${(aj[clave] as num?) ?? ''}';
        }
        _cargando = false;
      });
    }
  }

  void _ir(Widget w) {
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => w))
        .then((_) => _cargar());
  }

  // -- montos ----------------------------------------------------------
  Future<void> _guardarMontos() async {
    final cambios = <String, double>{};
    for (final (clave, _) in _clavesMonto) {
      final v = double.tryParse(
          (_montos[clave]?.text ?? '').replaceAll(',', '.'));
      if (v != null && v > 0) cambios[clave] = v;
    }
    if (cambios.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('No hay montos válidos para guardar')));
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Cambiar precios'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final e in cambios.entries)
              Text('• ${_etiqueta(e.key)}: ${fmtMonto(e.value)} CUP'),
            const SizedBox(height: 8),
            const Text(
                'Se aplicará en la próxima sincronización.'),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Confirmar')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    for (final e in cambios.entries) {
      await LocalDb.instance.queueOp(
        opUuid: const Uuid().v4(),
        tipo: 'ajuste',
        payload: {'clave': e.key, 'valor': e.value},
      );
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Precios guardados (se sincronizarán)')));
    SyncEngine.instance.push();
  }

  String _etiqueta(String clave) {
    for (final (c, e) in _clavesMonto) {
      if (c == clave) return e;
    }
    return clave;
  }

  // -- tipos de pago dinámicos (v1.0.16) --------------------------------
  static const _tiposFijos = {
    'mensual',
    'menores',
    'semanal',
    'quincenal'
  };
  bool _esTipoFijo(String id) => _tiposFijos.contains(id);

  void _toggleTipo(TipoPago t, bool v) {
    setState(() {
      _tipos = [
        for (final x in _tipos)
          if (x.id == t.id)
            TipoPago(
                id: x.id,
                nombre: x.nombre,
                monto: x.monto,
                dias: x.dias,
                activo: v,
                soloMenores: x.soloMenores)
          else
            x,
      ];
    });
  }

  Future<void> _editarTipo(TipoPago t) async {
    final nombreCtrl = TextEditingController(text: t.nombre);
    final montoCtrl =
        TextEditingController(text: '${t.monto}');
    final diasCtrl =
        TextEditingController(text: '${t.dias}');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Editar ${t.nombre}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
                controller: nombreCtrl,
                decoration: const InputDecoration(
                    labelText: 'Nombre',
                    border: OutlineInputBorder())),
            const SizedBox(height: 8),
            TextField(
                controller: montoCtrl,
                keyboardType: const TextInputType
                    .numberWithOptions(decimal: true),
                decoration: const InputDecoration(
                    labelText: 'Monto (CUP)',
                    border: OutlineInputBorder())),
            const SizedBox(height: 8),
            TextField(
                controller: diasCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                    labelText: 'Días que cubre',
                    border: OutlineInputBorder())),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Guardar')),
        ],
      ),
    );
    final nombre = nombreCtrl.text.trim();
    final monto = double.tryParse(
        montoCtrl.text.trim().replaceAll(',', '.'));
    final dias = int.tryParse(diasCtrl.text.trim());
    nombreCtrl.dispose();
    montoCtrl.dispose();
    diasCtrl.dispose();
    if (ok != true || !mounted) return;
    if (nombre.isEmpty || monto == null || monto <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Nombre y monto válido requeridos')));
      return;
    }
    setState(() {
      _tipos = [
        for (final x in _tipos)
          if (x.id == t.id)
            TipoPago(
                id: x.id,
                nombre: nombre,
                monto: monto,
                dias: (dias != null && dias > 0) ? dias : x.dias,
                activo: x.activo,
                soloMenores: x.soloMenores)
          else
            x,
      ];
    });
  }

  Future<void> _agregarTipo() async {
    final nombreCtrl = TextEditingController();
    final montoCtrl = TextEditingController();
    final diasCtrl = TextEditingController(text: '30');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Nuevo tipo de pago'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
                controller: nombreCtrl,
                decoration: const InputDecoration(
                    labelText: 'Nombre (ej: Trimestre)',
                    border: OutlineInputBorder())),
            const SizedBox(height: 8),
            TextField(
                controller: montoCtrl,
                keyboardType: const TextInputType
                    .numberWithOptions(decimal: true),
                decoration: const InputDecoration(
                    labelText: 'Monto (CUP)',
                    border: OutlineInputBorder())),
            const SizedBox(height: 8),
            TextField(
                controller: diasCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                    labelText: 'Días que cubre',
                    border: OutlineInputBorder())),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Agregar')),
        ],
      ),
    );
    final nombre = nombreCtrl.text.trim();
    final monto = double.tryParse(
        montoCtrl.text.trim().replaceAll(',', '.'));
    final dias = int.tryParse(diasCtrl.text.trim()) ?? 30;
    nombreCtrl.dispose();
    montoCtrl.dispose();
    diasCtrl.dispose();
    if (ok != true || !mounted) return;
    if (nombre.isEmpty || monto == null || monto <= 0 || dias <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content:
              Text('Nombre, monto y días válidos requeridos')));
      return;
    }
    final id = nombre
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    if (id.isEmpty || _tipos.any((x) => x.id == id)) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Ya existe un tipo con ese nombre')));
      return;
    }
    setState(() {
      _tipos = [
        ..._tipos,
        TipoPago(
            id: id, nombre: nombre, monto: monto, dias: dias),
      ];
    });
  }

  Future<void> _eliminarTipo(TipoPago t) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Eliminar tipo'),
        content: Text(
            '¿Eliminar "${t.nombre}"? Ya no aparecerá al cobrar.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Eliminar')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() {
      _tipos = [for (final x in _tipos) if (x.id != t.id) x];
    });
  }

  Future<void> _guardarTipos() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Guardar tipos de pago'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final t in _tipos)
              Text(
                  '• ${t.nombre}: ${fmtMonto(t.monto)} CUP · ${t.dias} días${t.activo ? '' : ' (inactivo)'}'),
            const SizedBox(height: 8),
            const Text(
                'Se aplicará en la próxima sincronización.'),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Confirmar')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await LocalDb.instance.queueOp(
      opUuid: const Uuid().v4(),
      tipo: 'guardar_tipos_pago',
      payload: {
        'tipos': [for (final t in _tipos) t.toJson()],
      },
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content:
            Text('Tipos guardados (se sincronizarán)')));
    SyncEngine.instance.push();
  }

  // -- pendiente a entrega ----------------------------------------------
  Future<void> _confirmarEntrega(
      {int? trainerId, required String nombre}) async {
    final notaCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Confirmar entrega'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('¿Confirmas que recibiste el dinero pendiente de '
                '"$nombre"? Su pendiente se pondrá en cero.'),
            const SizedBox(height: 12),
            TextField(
              controller: notaCtrl,
              decoration: const InputDecoration(
                labelText: 'Nota (opcional)',
                hintText: 'Ej: entregó en dos partes',
                border: OutlineInputBorder(),
              ),
              maxLines: 2,
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Confirmar')),
        ],
      ),
    );
    final nota = notaCtrl.text.trim();
    notaCtrl.dispose();
    if (ok != true || !mounted) return;
    await LocalDb.instance.queueOp(
      opUuid: const Uuid().v4(),
      tipo: 'confirmar_entrega',
      payload: {
        'trainer_telegram_id': trainerId ?? 'todos',
        if (nota.isNotEmpty) 'nota': nota,
      },
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Entrega confirmada (se sincronizará)')));
    _cargar();
    SyncEngine.instance.push();
  }

  // -- gastos ------------------------------------------------------------
  Future<void> _agregarGasto() async {
    final conceptoCtrl = TextEditingController();
    final montoCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Agregar gasto'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
                controller: conceptoCtrl,
                decoration: const InputDecoration(
                    labelText: 'Concepto (ej: pago de la luz)',
                    border: OutlineInputBorder())),
            const SizedBox(height: 8),
            TextField(
                controller: montoCtrl,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(
                    labelText: 'Monto (CUP)',
                    border: OutlineInputBorder())),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Guardar')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final monto =
        double.tryParse(montoCtrl.text.replaceAll(',', '.'));
    if (conceptoCtrl.text.trim().isEmpty || monto == null || monto <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Concepto o monto inválidos')));
      return;
    }
    final hoy = DateTime.now();
    final fecha = '${hoy.year.toString().padLeft(4, '0')}-'
        '${hoy.month.toString().padLeft(2, '0')}-'
        '${hoy.day.toString().padLeft(2, '0')}';
    await LocalDb.instance.queueOp(
      opUuid: const Uuid().v4(),
      tipo: 'gasto',
      payload: {
        'fecha': fecha,
        'concepto': conceptoCtrl.text.trim(),
        'monto': monto,
      },
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Gasto guardado (se sincronizará)')));
    _cargar();
    SyncEngine.instance.push();
  }

  // -- exportar ----------------------------------------------------------
  String _csv(List<String> cab, List<List<String>> filas) {
    String esc(String s) => '"${s.replaceAll('"', '""')}"';
    final sb = StringBuffer();
    sb.writeln(cab.map(esc).join(','));
    for (final f in filas) {
      sb.writeln(f.map(esc).join(','));
    }
    return sb.toString();
  }

  Future<void> _exportar() async {
    final clientes = await LocalDb.instance.allMirror('clientes');
    final csvClientes = _csv(
      ['id', 'nombre', 'carnet', 'telefono', 'sexo', 'estado',
       'pagado_hasta', 'fecha_inscripcion'],
      [
        for (final c in clientes)
          [
            '${c['id'] ?? ''}',
            '${c['nombre'] ?? ''}',
            '${c['carnet'] ?? ''}',
            '${c['telefono'] ?? ''}',
            '${c['sexo'] ?? ''}',
            '${c['estado'] ?? ''}',
            '${c['pagado_hasta'] ?? ''}',
            '${c['fecha_inscripcion'] ?? ''}',
          ]
      ],
    );
    final n = DateTime.now();
    final pref = '${n.year.toString().padLeft(4, '0')}-'
        '${n.month.toString().padLeft(2, '0')}';
    final pagos = await LocalDb.instance.allMirror('pagos');
    final pagosMes =
        pagos.where((p) => '${p['fecha'] ?? ''}'.startsWith(pref)).toList();
    final csvPagos = _csv(
      ['id', 'cliente_id', 'fecha', 'monto', 'metodo', 'periodo'],
      [
        for (final p in pagosMes)
          [
            '${p['id'] ?? ''}',
            '${p['cliente_id'] ?? ''}',
            '${p['fecha'] ?? ''}',
            '${p['monto'] ?? ''}',
            '${p['metodo'] ?? ''}',
            '${p['periodo'] ?? ''}',
          ]
      ],
    );
    final dir = await getTemporaryDirectory();
    final f1 = File('${dir.path}/clientes_ironbody.csv');
    final f2 = File(
        '${dir.path}/pagos_${n.year}-${n.month.toString().padLeft(2, '0')}_ironbody.csv');
    await f1.writeAsString(csvClientes);
    await f2.writeAsString(csvPagos);
    await Share.shareXFiles([XFile(f1.path), XFile(f2.path)],
        text: 'Iron Body Gym — clientes y pagos del mes');
  }

  // -- UI ------------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    final totalPend =
        _pend.fold<double>(0, (s, e) => s + (e['total'] as double));
    final cobradoHoy = (_caja['efectivo'] ?? 0) + (_caja['transferencia'] ?? 0);
    final neto = cobradoHoy - _gastosHoy;
    return Scaffold(
      appBar: AppBar(title: const Text('Administración')),
      body: Column(
        children: [
          const SyncBanner(),
          Expanded(
            child: _cargando
                ? const Center(child: CircularProgressIndicator())
                : RefreshIndicator(
                    onRefresh: _cargar,
                    child: ListView(
                      padding: const EdgeInsets.all(16),
                      children: [
                        _seccion(Icons.bar_chart, 'Estadísticas del mes', [
                          _fila(Icons.payments, 'Ingresos',
                              '${fmtMonto(_ingresos)} CUP'),
                          _fila(Icons.person_add, 'Inscripciones', '$_inscMes'),
                          _fila(Icons.warning, 'Morosos', '$_morosos'),
                        ]),
                        if (_inscPorEntrenador.isNotEmpty)
                          _seccion(Icons.group, 'Inscripciones por entrenador', [
                            for (final e in _inscPorEntrenador)
                              _fila(null, '${e['nombre']}',
                                  '${e['cantidad']}'),
                          ]),
                        _seccion(Icons.health_and_safety, 'Salud del sistema', [
                          _fila(Icons.sync, 'Última sincronización',
                              _fechaHora(_syncDet.ultimaPush)),
                          _fila(Icons.download, 'Última bajada',
                              _fechaHora(_syncDet.ultimaPull)),
                          _fila(Icons.upload, 'Pendientes por subir',
                              '$_pendientesSubir'),
                          _fila(Icons.download, 'Bajados (última vez)',
                              '${_syncDet.bajados}'),
                          if (_syncDet.error != null &&
                              _syncDet.error!.isNotEmpty)
                            Padding(
                              padding:
                                  const EdgeInsets.only(top: 8),
                              child: Text(
                                _syncDet.error ?? '',
                                style: const TextStyle(
                                    color: Colors.red, fontSize: 13),
                              ),
                            ),
                        ]),
                        _seccion(Icons.payments, 'Tipos de pago', [
                          for (final t in _tipos)
                            ListTile(
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              title: Text(t.nombre,
                                  style: TextStyle(
                                      fontSize: 14,
                                      color: t.activo
                                          ? null
                                          : Colors.grey)),
                              subtitle: Text(
                                  '${fmtMonto(t.monto)} CUP · ${t.dias} días'
                                  '${t.soloMenores ? ' · solo menores' : ''}',
                                  style: const TextStyle(
                                      fontSize: 12)),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Switch(
                                    value: t.activo,
                                    onChanged: (v) =>
                                        _toggleTipo(t, v),
                                  ),
                                  IconButton(
                                    icon: const Icon(
                                        Icons.edit,
                                        size: 20),
                                    onPressed: () =>
                                        _editarTipo(t),
                                  ),
                                  if (!_esTipoFijo(t.id))
                                    IconButton(
                                      icon: const Icon(
                                          Icons.delete_outline,
                                          size: 20,
                                          color: Colors.red),
                                      onPressed: () =>
                                          _eliminarTipo(t),
                                    ),
                                ],
                              ),
                            ),
                          const SizedBox(height: 4),
                          OutlinedButton.icon(
                            icon: const Icon(Icons.add),
                            label: const Text(
                                'Agregar tipo de pago'),
                            onPressed: _agregarTipo,
                          ),
                          const SizedBox(height: 8),
                          SizedBox(
                            width: double.infinity,
                            child: ElevatedButton(
                              onPressed: _guardarTipos,
                              child: const Text(
                                  'Guardar tipos de pago'),
                            ),
                          ),
                        ]),
                        _seccion(Icons.price_change, 'Otros precios', [
                          for (final (clave, etiqueta) in _clavesMonto)
                            Padding(
                              padding:
                                  const EdgeInsets.only(bottom: 8),
                              child: TextField(
                                controller: _montos[clave],
                                keyboardType: const TextInputType
                                    .numberWithOptions(decimal: true),
                                decoration: InputDecoration(
                                    labelText: '$etiqueta (CUP)',
                                    border:
                                        const OutlineInputBorder()),
                              ),
                            ),
                          SizedBox(
                            width: double.infinity,
                            child: ElevatedButton(
                              onPressed: _guardarMontos,
                              child: const Text('Guardar precios'),
                            ),
                          ),
                        ]),
                        if (Permisos().gestionarUsuarios)
                          _seccion(Icons.smartphone, 'Usuarios APK', [
                          SizedBox(
                            width: double.infinity,
                            child: ElevatedButton.icon(
                              icon:
                                  const Icon(Icons.manage_accounts),
                              label: const Text('Gestionar usuarios'),
                              onPressed: () => Navigator.of(context)
                                  .push(MaterialPageRoute(
                                      builder: (_) =>
                                          const UsuariosScreen())),
                            ),
                          ),
                          const SizedBox(height: 4),
                          const Text(
                            'Ver lista, bloquear, desbloquear, cambiar contraseña o eliminar.',
                            style: TextStyle(
                                fontSize: 12, color: Colors.grey),
                          ),
                        ]),
                        _seccion(
                            Icons.outbox,
                            'Pendiente a entregar (${fmtMonto(totalPend)} CUP)',
                            [
                              if (_pend.isEmpty)
                                const Text(
                                    'Nada pendiente. Todo cuadrado.',
                                    style:
                                        TextStyle(color: Colors.grey)),
                              for (final t in _pend)
                                ListTile(
                                  dense: true,
                                  leading: const Text('👤',
                                      style: TextStyle(fontSize: 22)),
                                  title: Text('${t['nombre']}'),
                                  subtitle: Text(
                                      '${t['n']} movimiento(s) — ${fmtMonto(t['total'])} CUP'),
                                  // v1.0.16: tocar abre el detalle
                                  // (qué cobros componen el pendiente)
                                  onTap: () => _ir(
                                      DetallePendienteScreen(
                                          trainerId:
                                              t['id'] as int,
                                          nombre:
                                              '${t['nombre']}')),
                                  trailing: TextButton(
                                    child: const Text('Confirmar'),
                                    onPressed: () =>
                                        _confirmarEntrega(
                                            trainerId:
                                                t['id'] as int?,
                                            nombre:
                                                '${t['nombre']}'),
                                  ),
                                ),
                              if (_pend.isNotEmpty)
                                Align(
                                  alignment:
                                      Alignment.centerRight,
                                  child: TextButton.icon(
                                    icon: const Icon(
                                        Icons.done_all),
                                    label: const Text(
                                        'Confirmar todo'),
                                    onPressed: () =>
                                        _confirmarEntrega(
                                            nombre: 'todos'),
                                  ),
                                ),
                            ]),
                        _seccion(Icons.point_of_sale, 'Cierre de caja (hoy)', [
                          _fila(Icons.payments, 'Efectivo',
                              '${fmtMonto(_caja['efectivo'])} CUP'),
                          _fila(Icons.smartphone, 'Transferencia',
                              '${fmtMonto(_caja['transferencia'])} CUP'),
                          _fila(Icons.receipt_long, 'Gastos',
                              '${fmtMonto(_gastosHoy)} CUP'),
                          const Divider(),
                          _fila(Icons.inventory_2, 'Neto',
                              '${fmtMonto(neto)} CUP',
                              negrita: true),
                          const SizedBox(height: 8),
                          SizedBox(
                            width: double.infinity,
                            child: OutlinedButton.icon(
                              icon: const Icon(Icons.add),
                              label:
                                  const Text('Agregar gasto'),
                              onPressed: _agregarGasto,
                            ),
                          ),
                        ]),
                        _seccion(Icons.receipt_long, 'Últimos gastos', [
                          if (_gastos.isEmpty)
                            const Text('Sin gastos registrados.',
                                style:
                                    TextStyle(color: Colors.grey)),
                          for (final g
                              in _gastos.take(10))
                            ListTile(
                              dense: true,
                              title:
                                  Text('${g['concepto'] ?? '—'}'),
                              subtitle: Text(
                                  fmtFecha(g['fecha'] as String?)),
                              trailing: Text(
                                  '${fmtMonto(g['monto'])} CUP',
                                  style: const TextStyle(
                                      fontWeight:
                                          FontWeight.bold)),
                            ),
                        ]),
                        _seccion(Icons.delete_outline, 'Papelera', [
                          SizedBox(
                            width: double.infinity,
                            child: OutlinedButton.icon(
                              icon: const Icon(
                                  Icons.delete_outline),
                              label: const Text(
                                  'Abrir papelera'),
                              onPressed: () =>
                                  _ir(const PapeleraScreen()),
                            ),
                          ),
                        ]),
                        _seccion(Icons.ac_unit, 'Congelados', [
                          SizedBox(
                            width: double.infinity,
                            child: OutlinedButton.icon(
                              icon: const Icon(Icons.ac_unit),
                              label: const Text(
                                  'Ver congelados'),
                              onPressed: () =>
                                  _ir(const CongeladosScreen()),
                            ),
                          ),
                        ]),
                        _seccion(Icons.account_balance_wallet, 'Cuentas por cobrar', [
                          const Text(
                            'Clientes vencidos ordenados por monto adeudado. El dinero dormido, visible.',
                            style: TextStyle(
                                color: Colors.grey, fontSize: 12),
                          ),
                          const SizedBox(height: 8),
                          SizedBox(
                            width: double.infinity,
                            child: ElevatedButton.icon(
                              icon:
                                  const Icon(Icons.money_off),
                              label: const Text(
                                  'Ver cuentas por cobrar'),
                              onPressed: () => Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) =>
                                      const CuentasCobrarScreen(),
                                ),
                              ),
                            ),
                          ),
                        ]),
                        _seccion(Icons.warning, 'Clientes en riesgo', [
                          const Text(
                            'Inactivos con 3+ pagos cuyo último pago fue hace más de 60 días. Buenos candidatos para recuperar.',
                            style: TextStyle(
                                color: Colors.grey, fontSize: 12),
                          ),
                          const SizedBox(height: 8),
                          SizedBox(
                            width: double.infinity,
                            child: ElevatedButton.icon(
                              icon:
                                  const Icon(Icons.warning_amber),
                              label: const Text(
                                  'Ver clientes en riesgo'),
                              onPressed: () => Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) =>
                                      const RiesgoScreen(),
                                ),
                              ),
                            ),
                          ),
                        ]),
                        _seccion(Icons.history, 'Historial por entrenador', [
                          const Text(
                            'Cobrado, pagos e inscripciones del mes por entrenador.',
                            style: TextStyle(
                                color: Colors.grey, fontSize: 12),
                          ),
                          const SizedBox(height: 8),
                          SizedBox(
                            width: double.infinity,
                            child: ElevatedButton.icon(
                              icon: const Icon(Icons.person_search),
                              label: const Text(
                                  'Ver historial por entrenador'),
                              onPressed: () => Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) =>
                                      const HistorialEntrenadorScreen(),
                                ),
                              ),
                            ),
                          ),
                        ]),
                        _seccion(Icons.fact_check, 'Auditoría', [
                          SizedBox(
                            width: double.infinity,
                            child: ElevatedButton.icon(
                              icon: const Icon(Icons.history),
                              label: const Text(
                                  'Ver quién hizo qué y cuándo'),
                              onPressed: () => Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) =>
                                      const AuditoriaScreen(),
                                ),
                              ),
                            ),
                          ),
                        ]),
                        _seccion(Icons.file_download, 'Exportar', [
                          SizedBox(
                            width: double.infinity,
                            child: ElevatedButton.icon(
                              icon: const Icon(Icons.share),
                              label: const Text(
                                  'Compartir CSV (clientes + pagos del mes)'),
                              onPressed: _exportar,
                            ),
                          ),
                          const SizedBox(height: 8),
                          SizedBox(
                            width: double.infinity,
                            child: ElevatedButton.icon(
                              icon: const Icon(Icons.table_chart),
                              label:
                                  const Text('📊 Exportar Excel'),
                              onPressed: () async {
                                final ok = await exportarExcel();
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context)
                                      .showSnackBar(SnackBar(
                                          content: Text(ok
                                              ? '📊 Archivos listos para compartir'
                                              : '⚠️ No se pudo generar el archivo')));
                                }
                              },
                            ),
                          ),
                        ]),
                        const SizedBox(height: 24),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  /// Sección de administración (v1.1: Tarjeta + icono, sin emojis).
  Widget _seccion(IconData icono, String titulo, List<Widget> hijos) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppEspacio.md),
      child: Tarjeta(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icono,
                    color: AppColores.naranja, size: 20),
                const SizedBox(width: AppEspacio.sm),
                Text(titulo, style: AppTexto.subtitulo),
              ],
            ),
            const SizedBox(height: AppEspacio.sm),
            ...hijos,
          ],
        ),
      ),
    );
  }

  Widget _fila(IconData? icono, String etiqueta, String valor,
      {bool negrita = false}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              if (icono != null) ...[
                Icon(icono,
                    size: 16,
                    color: AppColores.textoSecundarioClaro),
                const SizedBox(width: 6),
              ],
              Text(etiqueta),
            ],
          ),
          Text(valor,
              style: TextStyle(
                  fontWeight:
                      negrita ? FontWeight.bold : FontWeight.w600)),
        ],
      ),
    );
  }

  /// Formatea fecha/hora para la sección de salud ("nunca" si es null).
  String _fechaHora(DateTime? dt) {
    if (dt == null) return 'nunca';
    final d = dt.day.toString().padLeft(2, '0');
    final m = dt.month.toString().padLeft(2, '0');
    final h = dt.hour.toString().padLeft(2, '0');
    final min = dt.minute.toString().padLeft(2, '0');
    return '$d/$m $h:$min';
  }
}
