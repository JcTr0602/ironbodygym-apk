/// 🛡️ Administración (solo admin).
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
import '../sync.dart';
import 'papelera.dart';
import 'auditoria.dart';
import 'widgets.dart';

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
  List<Map<String, dynamic>> _gastos = [];
  Map<String, double> _caja = {'efectivo': 0, 'transferencia': 0};
  double _gastosHoy = 0;
  final Map<String, TextEditingController> _montos = {};
  bool _cargando = true;

  static const _clavesMonto = [
    ('mensualidad', 'Mensualidad'),
    ('transferencia', 'Mensualidad por transferencia'),
    ('pago_diario', 'Pago diario'),
    ('pago_semanal', 'Semana'),
    ('pago_quincenal', 'Quincena'),
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
    final gastos = await gastosTodos();
    final caja = await cobradoHoyPorMetodo();
    final hoy = DateTime.now();
    final hoyIso = '${hoy.year.toString().padLeft(4, '0')}-'
        '${hoy.month.toString().padLeft(2, '0')}-'
        '${hoy.day.toString().padLeft(2, '0')}';
    final gh = await gastosDe(hoyIso);
    final aj = await LocalDb.instance.getAjustes();
    if (mounted) {
      setState(() {
        _ingresos = ing;
        _inscMes = insc;
        _morosos = mor;
        _pend = pend;
        _gastos = gastos;
        _caja = caja;
        _gastosHoy = gh;
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
        title: const Text('💰 Cambiar precios'),
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
        const SnackBar(content: Text('✅ Precios guardados (se sincronizarán)')));
    SyncEngine.instance.push();
  }

  String _etiqueta(String clave) {
    for (final (c, e) in _clavesMonto) {
      if (c == clave) return e;
    }
    return clave;
  }

  // -- usuarios APK ----------------------------------------------------
  Future<void> _crearUsuario() async {
    final nombreCtrl = TextEditingController();
    final passCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('👤 Crear usuario APK'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
                controller: nombreCtrl,
                decoration: const InputDecoration(
                    labelText: 'Nombre de usuario',
                    border: OutlineInputBorder())),
            const SizedBox(height: 8),
            TextField(
                controller: passCtrl,
                obscureText: true,
                decoration: const InputDecoration(
                    labelText: 'Contraseña',
                    border: OutlineInputBorder())),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Crear')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final nombre = nombreCtrl.text.trim();
    final pass = passCtrl.text;
    if (nombre.isEmpty || pass.length < 4) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Nombre vacío o contraseña muy corta (mín. 4)')));
      return;
    }
    await LocalDb.instance.queueOp(
      opUuid: const Uuid().v4(),
      tipo: 'admin_usuario',
      payload: {'accion': 'crear', 'username': nombre, 'password': pass},
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('✅ Usuario encolado (se sincronizará)')));
    SyncEngine.instance.push();
  }

  Future<void> _accionUsuario() async {
    final userCtrl = TextEditingController();
    final passCtrl = TextEditingController();
    String accion = 'bloquear';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: const Text('👤 Gestionar usuario'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                  controller: userCtrl,
                  decoration: const InputDecoration(
                      labelText: 'Nombre de usuario',
                      border: OutlineInputBorder())),
              const SizedBox(height: 8),
              DropdownButton<String>(
                value: accion,
                isExpanded: true,
                items: const [
                  DropdownMenuItem(
                      value: 'bloquear',
                      child: Text('Bloquear')),
                  DropdownMenuItem(
                      value: 'desbloquear',
                      child: Text('Desbloquear')),
                  DropdownMenuItem(
                      value: 'password',
                      child: Text('Cambiar contraseña')),
                  DropdownMenuItem(
                      value: 'eliminar',
                      child: Text('Eliminar')),
                ],
                onChanged: (v) => setS(() => accion = v ?? accion),
              ),
              if (accion == 'password') ...[
                const SizedBox(height: 8),
                TextField(
                    controller: passCtrl,
                    obscureText: true,
                    decoration: const InputDecoration(
                        labelText: 'Nueva contraseña',
                        border: OutlineInputBorder())),
              ],
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancelar')),
            ElevatedButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Aplicar')),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) return;
    final username = userCtrl.text.trim();
    if (username.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Escribe el nombre de usuario')));
      return;
    }
    if (accion == 'password' && passCtrl.text.length < 4) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Contraseña muy corta (mín. 4)')));
      return;
    }
    if (accion == 'eliminar') {
      final conf = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('⚠️ Eliminar usuario'),
          content: Text(
              '¿Eliminar definitivamente al usuario "$username"?'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('No')),
            ElevatedButton(
                style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red),
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Sí, eliminar')),
          ],
        ),
      );
      if (conf != true || !mounted) return;
    }
    await LocalDb.instance.queueOp(
      opUuid: const Uuid().v4(),
      tipo: 'admin_usuario',
      payload: {
        'accion': accion,
        'username': username,
        if (accion == 'password') 'password': passCtrl.text,
      },
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('✅ Acción encolada (se sincronizará)')));
    SyncEngine.instance.push();
  }

  // -- pendiente a entrega ----------------------------------------------
  Future<void> _confirmarEntrega(
      {int? trainerId, required String nombre}) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('💰 Confirmar entrega'),
        content: Text('¿Confirmas que recibiste el dinero pendiente de '
            '"$nombre"? Su pendiente se pondrá en cero.'),
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
      tipo: 'confirmar_entrega',
      payload: {
        'trainer_telegram_id': trainerId ?? 'todos',
      },
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('✅ Entrega confirmada (se sincronizará)')));
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
        title: const Text('🧾 Agregar gasto'),
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
        const SnackBar(content: Text('✅ Gasto guardado (se sincronizará)')));
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
      appBar: AppBar(title: const Text('🛡️ Administración')),
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
                        _seccion('📊 Estadísticas del mes', [
                          _fila('💰 Ingresos',
                              '${fmtMonto(_ingresos)} CUP'),
                          _fila('➕ Inscripciones', '$_inscMes'),
                          _fila('⏳ Morosos', '$_morosos'),
                        ]),
                        _seccion('💵 Montos (precios)', [
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
                        _seccion('👥 Usuarios APK', [
                          Row(
                            children: [
                              Expanded(
                                child: ElevatedButton.icon(
                                  icon: const Icon(Icons.person_add),
                                  label: const Text('Crear usuario'),
                                  onPressed: _crearUsuario,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: OutlinedButton.icon(
                                  icon:
                                      const Icon(Icons.manage_accounts),
                                  label: const Text('Gestionar'),
                                  onPressed: _accionUsuario,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          const Text(
                            'Bloquear, desbloquear, cambiar contraseña o eliminar por nombre de usuario.',
                            style: TextStyle(
                                fontSize: 12, color: Colors.grey),
                          ),
                        ]),
                        _seccion(
                            '💰 Pendiente a entregar (${fmtMonto(totalPend)} CUP)',
                            [
                              if (_pend.isEmpty)
                                const Text(
                                    '🎉 Nada pendiente. Todo cuadrado.',
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
                        _seccion('🧾 Cierre de caja (hoy)', [
                          _fila('💵 Efectivo',
                              '${fmtMonto(_caja['efectivo'])} CUP'),
                          _fila('💳 Transferencia',
                              '${fmtMonto(_caja['transferencia'])} CUP'),
                          _fila('🧾 Gastos',
                              '${fmtMonto(_gastosHoy)} CUP'),
                          const Divider(),
                          _fila('📦 Neto',
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
                        _seccion('🧾 Últimos gastos', [
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
                        _seccion('🗑️ Papelera', [
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
                        _seccion('📋 Auditoría', [
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
                        _seccion('💾 Exportar', [
                          SizedBox(
                            width: double.infinity,
                            child: ElevatedButton.icon(
                              icon: const Icon(Icons.share),
                              label: const Text(
                                  'Compartir CSV (clientes + pagos del mes)'),
                              onPressed: _exportar,
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

  Widget _seccion(String titulo, List<Widget> hijos) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(titulo,
                style: const TextStyle(
                    fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            ...hijos,
          ],
        ),
      ),
    );
  }

  Widget _fila(String etiqueta, String valor, {bool negrita = false}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(etiqueta),
          Text(valor,
              style: TextStyle(
                  fontWeight:
                      negrita ? FontWeight.bold : FontWeight.w600)),
        ],
      ),
    );
  }
}
