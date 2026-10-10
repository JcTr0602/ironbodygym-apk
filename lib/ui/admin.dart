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
import 'suplementos.dart';
import 'historial_ventas.dart';

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
    final mensaje = [
      for (final e in cambios.entries)
        '• ${_etiqueta(e.key)}: ${fmtMonto(e.value)} CUP',
      '',
      'Se aplicará en la próxima sincronización.',
    ].join('\n');
    final ok = await DialogoApp.confirmar(
      context,
      titulo: 'Cambiar precios',
      mensaje: mensaje,
      aceptar: 'Confirmar',
      icono: Icons.price_change,
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
      builder: (ctx) => DialogoApp(
        titulo: 'Editar ${t.nombre}',
        iconoTitulo: Icons.edit,
        contenido: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CampoTexto(
                controller: nombreCtrl, etiqueta: 'Nombre'),
            const SizedBox(height: 8),
            CampoTexto(
                controller: montoCtrl,
                etiqueta: 'Monto (CUP)',
                teclado: const TextInputType
                    .numberWithOptions(decimal: true)),
            const SizedBox(height: 8),
            CampoTexto(
                controller: diasCtrl,
                etiqueta: 'Días que cubre',
                teclado: TextInputType.number),
          ],
        ),
        acciones: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColores.naranja,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius:
                      BorderRadius.circular(AppRadio.md),
                ),
              ),
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
      builder: (ctx) => DialogoApp(
        titulo: 'Nuevo tipo de pago',
        iconoTitulo: Icons.add,
        contenido: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CampoTexto(
                controller: nombreCtrl,
                etiqueta: 'Nombre (ej: Trimestre)'),
            const SizedBox(height: 8),
            CampoTexto(
                controller: montoCtrl,
                etiqueta: 'Monto (CUP)',
                teclado: const TextInputType
                    .numberWithOptions(decimal: true)),
            const SizedBox(height: 8),
            CampoTexto(
                controller: diasCtrl,
                etiqueta: 'Días que cubre',
                teclado: TextInputType.number),
          ],
        ),
        acciones: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColores.naranja,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius:
                      BorderRadius.circular(AppRadio.md),
                ),
              ),
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
    final ok = await DialogoApp.confirmar(
      context,
      titulo: 'Eliminar tipo',
      mensaje: '¿Eliminar "${t.nombre}"? Ya no aparecerá al cobrar.',
      aceptar: 'Eliminar',
      peligro: true,
      icono: Icons.delete_outline,
    );
    if (ok != true || !mounted) return;
    setState(() {
      _tipos = [for (final x in _tipos) if (x.id != t.id) x];
    });
  }

  Future<void> _guardarTipos() async {
    final mensaje = [
      for (final t in _tipos)
        '• ${t.nombre}: ${fmtMonto(t.monto)} CUP · ${t.dias} días${t.activo ? '' : ' (inactivo)'}',
      '',
      'Se aplicará en la próxima sincronización.',
    ].join('\n');
    final ok = await DialogoApp.confirmar(
      context,
      titulo: 'Guardar tipos de pago',
      mensaje: mensaje,
      aceptar: 'Confirmar',
      icono: Icons.payments,
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
      builder: (ctx) => DialogoApp(
        titulo: 'Confirmar entrega',
        iconoTitulo: Icons.done_all,
        contenido: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
                '¿Confirmas que recibiste el dinero pendiente de '
                '"$nombre"? Su pendiente se pondrá en cero.',
                style: AppTexto.cuerpo),
            const SizedBox(height: 12),
            CampoTexto(
              controller: notaCtrl,
              etiqueta: 'Nota (opcional)',
              hint: 'Ej: entregó en dos partes',
              maxLineas: 2,
            ),
          ],
        ),
        acciones: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColores.naranja,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius:
                      BorderRadius.circular(AppRadio.md),
                ),
              ),
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
      builder: (ctx) => DialogoApp(
        titulo: 'Agregar gasto',
        iconoTitulo: Icons.receipt_long,
        contenido: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CampoTexto(
                controller: conceptoCtrl,
                etiqueta: 'Concepto (ej: pago de la luz)'),
            const SizedBox(height: 8),
            CampoTexto(
                controller: montoCtrl,
                etiqueta: 'Monto (CUP)',
                teclado:
                    const TextInputType.numberWithOptions(decimal: true)),
          ],
        ),
        acciones: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColores.naranja,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius:
                      BorderRadius.circular(AppRadio.md),
                ),
              ),
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
                                style: TextStyle(
                                    color: AppColores.error,
                                    fontSize: 13),
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
                                          : AppColores.textoSecundario(
                                              context))),
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
                                      icon: Icon(
                                          Icons.delete_outline,
                                          size: 20,
                                          color: AppColores.error),
                                      onPressed: () =>
                                          _eliminarTipo(t),
                                    ),
                                ],
                              ),
                            ),
                          const SizedBox(height: 4),
                          BotonSecundario(
                            texto: 'Agregar tipo de pago',
                            icono: Icons.add,
                            onPressed: _agregarTipo,
                          ),
                          const SizedBox(height: 8),
                          BotonPrimario(
                            texto: 'Guardar tipos de pago',
                            icono: Icons.save,
                            onPressed: _guardarTipos,
                          ),
                        ]),
                        _seccion(Icons.price_change, 'Otros precios', [
                          for (final (clave, etiqueta) in _clavesMonto)
                            Padding(
                              padding:
                                  const EdgeInsets.only(bottom: 8),
                              child: CampoTexto(
                                controller: _montos[clave],
                                etiqueta: '$etiqueta (CUP)',
                                teclado: const TextInputType
                                    .numberWithOptions(decimal: true),
                              ),
                            ),
                          BotonPrimario(
                            texto: 'Guardar otros precios',
                            icono: Icons.save,
                            onPressed: _guardarMontos,
                          ),
                        ]),
                        if (Permisos().gestionarUsuarios)
                          _seccion(Icons.smartphone, 'Usuarios APK', [
                          BotonPrimario(
                            texto: 'Gestionar usuarios',
                            icono: Icons.manage_accounts,
                            onPressed: () => Navigator.of(context).push(
                                MaterialPageRoute(
                                    builder: (_) =>
                                        const UsuariosScreen())),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Ver lista, bloquear, desbloquear, cambiar contraseña o eliminar.',
                            style: TextStyle(
                                fontSize: 12,
                                color: AppColores.textoSecundario(
                                    context)),
                          ),
                        ]),
                        _seccion(Icons.medication, 'Suplementos', [
                          BotonPrimario(
                            texto: 'Gestionar catálogo',
                            icono: Icons.inventory_2,
                            onPressed: () => Navigator.of(context).push(
                                MaterialPageRoute(
                                    builder: (_) =>
                                        const SuplementosScreen())),
                          ),
                          const SizedBox(height: AppEspacio.sm),
                          BotonSecundario(
                            texto: 'Historial de ventas',
                            icono: Icons.receipt_long,
                            onPressed: () => Navigator.of(context).push(
                                MaterialPageRoute(
                                    builder: (_) =>
                                        const HistorialVentasScreen())),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Productos, precios oficiales, stock, promo "mes gratis" y ventas.',
                            style: TextStyle(
                                fontSize: 12,
                                color: AppColores.textoSecundario(
                                    context)),
                          ),
                        ]),
                        _seccion(
                            Icons.outbox,
                            'Pendiente a entregar (${fmtMonto(totalPend)} CUP)',
                            [
                              if (_pend.isEmpty)
                                Text(
                                    'Nada pendiente. Todo cuadrado.',
                                    style: TextStyle(
                                        color: AppColores.textoSecundario(
                                            context))),
                              for (final t in _pend)
                                ListTile(
                                  dense: true,
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
                          BotonSecundario(
                            texto: 'Agregar gasto',
                            icono: Icons.add,
                            onPressed: _agregarGasto,
                          ),
                        ]),
                        _seccion(Icons.receipt_long, 'Últimos gastos', [
                          if (_gastos.isEmpty)
                            Text('Sin gastos registrados.',
                                style: TextStyle(
                                    color: AppColores.textoSecundario(
                                        context))),
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
                          BotonSecundario(
                            texto: 'Abrir papelera',
                            icono: Icons.delete_outline,
                            onPressed: () =>
                                _ir(const PapeleraScreen()),
                          ),
                        ]),
                        _seccion(Icons.ac_unit, 'Congelados', [
                          BotonSecundario(
                            texto: 'Ver congelados',
                            icono: Icons.ac_unit,
                            onPressed: () =>
                                _ir(const CongeladosScreen()),
                          ),
                        ]),
                        _seccion(Icons.account_balance_wallet, 'Cuentas por cobrar', [
                          Text(
                            'Clientes vencidos ordenados por monto adeudado. El dinero dormido, visible.',
                            style: TextStyle(
                                color: AppColores.textoSecundario(
                                    context),
                                fontSize: 12),
                          ),
                          const SizedBox(height: 8),
                          BotonPrimario(
                            texto: 'Ver cuentas por cobrar',
                            icono: Icons.money_off,
                            onPressed: () => Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) =>
                                    const CuentasCobrarScreen(),
                              ),
                            ),
                          ),
                        ]),
                        _seccion(Icons.warning, 'Clientes en riesgo', [
                          Text(
                            'Inactivos con 3+ pagos cuyo último pago fue hace más de 60 días. Buenos candidatos para recuperar.',
                            style: TextStyle(
                                color: AppColores.textoSecundario(
                                    context),
                                fontSize: 12),
                          ),
                          const SizedBox(height: 8),
                          BotonPrimario(
                            texto: 'Ver clientes en riesgo',
                            icono: Icons.warning_amber,
                            onPressed: () => Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) =>
                                    const RiesgoScreen(),
                              ),
                            ),
                          ),
                        ]),
                        _seccion(Icons.history, 'Historial por entrenador', [
                          Text(
                            'Cobrado, pagos e inscripciones del mes por entrenador.',
                            style: TextStyle(
                                color: AppColores.textoSecundario(
                                    context),
                                fontSize: 12),
                          ),
                          const SizedBox(height: 8),
                          BotonPrimario(
                            texto: 'Ver historial por entrenador',
                            icono: Icons.person_search,
                            onPressed: () => Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) =>
                                    const HistorialEntrenadorScreen(),
                              ),
                            ),
                          ),
                        ]),
                        _seccion(Icons.fact_check, 'Auditoría', [
                          BotonPrimario(
                            texto: 'Ver quién hizo qué y cuándo',
                            icono: Icons.history,
                            onPressed: () => Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) =>
                                    const AuditoriaScreen(),
                              ),
                            ),
                          ),
                        ]),
                        _seccion(Icons.file_download, 'Exportar', [
                          BotonPrimario(
                            texto: 'Compartir CSV (clientes + pagos del mes)',
                            icono: Icons.share,
                            onPressed: _exportar,
                          ),
                          const SizedBox(height: 8),
                          BotonPrimario(
                            texto: 'Exportar Excel',
                            icono: Icons.table_chart,
                            onPressed: () async {
                                final ok = await exportarExcel();
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context)
                                      .showSnackBar(SnackBar(
                                          content: Text(ok
                                              ? 'Archivos listos para compartir'
                                              : 'No se pudo generar el archivo')));
                                }
                              },
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
                    color: AppColores.textoSecundario(context)),
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
