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
import 'admin_secciones.dart';
import 'exportar_excel.dart';
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

  /// Navega a una subpantalla y recarga al volver (para las secciones).
  Future<void> _irYRecargar(Widget w) async {
    await Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => w));
    await _cargar();
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

  // -- UI (hub A–G) ---------------------------------------------------------
  @override
  Widget build(BuildContext context) {
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
                    child: GridView.count(
                      padding: const EdgeInsets.all(16),
                      crossAxisCount: 2,
                      mainAxisSpacing: AppEspacio.md,
                      crossAxisSpacing: AppEspacio.md,
                      childAspectRatio: 1.05,
                      children: [
                        _tarjetaHub(
                          'A',
                          Icons.bar_chart,
                          'Resumen',
                          'Estadísticas e inscripciones del mes',
                          () => _ir(SeccionResumenScreen(
                            ingresos: _ingresos,
                            inscMes: _inscMes,
                            morosos: _morosos,
                            inscPorEntrenador: _inscPorEntrenador,
                          )),
                        ),
                        _tarjetaHub(
                          'B',
                          Icons.point_of_sale,
                          'Cobros',
                          'Cierre de caja, pendientes y cuentas',
                          () => _ir(SeccionCobrosScreen(
                            getCaja: () => _caja,
                            getGastosHoy: () => _gastosHoy,
                            getPend: () => _pend,
                            onConfirmarEntrega: _confirmarEntrega,
                            onIr: _irYRecargar,
                          )),
                        ),
                        _tarjetaHub(
                          'C',
                          Icons.group,
                          'Clientes',
                          'Papelera, congelados y en riesgo',
                          () => _ir(SeccionClientesScreen(
                            onIr: _irYRecargar,
                          )),
                        ),
                        _tarjetaHub(
                          'D',
                          Icons.health_and_safety,
                          'Sistema',
                          'Salud, auditoría y exportar',
                          () => _ir(SeccionSistemaScreen(
                            syncDet: _syncDet,
                            pendientesSubir: _pendientesSubir,
                            fechaHora: _fechaHora,
                            onExportar: _exportar,
                            onExportarExcel: () async {
                              final ok = await exportarExcel();
                              if (context.mounted) {
                                ScaffoldMessenger.of(context)
                                    .showSnackBar(SnackBar(
                                        content: Text(ok
                                            ? 'Archivos listos para compartir'
                                            : 'No se pudo generar el archivo')));
                              }
                            },
                            onIr: _irYRecargar,
                          )),
                        ),
                        _tarjetaHub(
                          'E',
                          Icons.settings,
                          'Ajustes',
                          'Tipos de pago, precios y usuarios',
                          () => _ir(SeccionAjustesScreen(
                            getTipos: () => _tipos,
                            onToggleTipo: _toggleTipo,
                            onEditarTipo: _editarTipo,
                            onEliminarTipo: _eliminarTipo,
                            onAgregarTipo: _agregarTipo,
                            onGuardarTipos: _guardarTipos,
                            montos: _montos,
                            clavesMonto: _clavesMonto,
                            onGuardarMontos: _guardarMontos,
                            gestionarUsuarios:
                                Permisos().gestionarUsuarios,
                            onIr: _irYRecargar,
                            esTipoFijo: _esTipoFijo,
                          )),
                        ),
                        _tarjetaHub(
                          'F',
                          Icons.receipt_long,
                          'Gastos',
                          'Últimos gastos registrados',
                          () => _ir(SeccionGastosScreen(
                            getGastos: () => _gastos,
                            onAgregarGasto: _agregarGasto,
                          )),
                        ),
                        _tarjetaHub(
                          'G',
                          Icons.medication,
                          'Suplementos',
                          'Catálogo y ventas',
                          () => _ir(SeccionSuplementosScreen(
                            onIr: _irYRecargar,
                          )),
                        ),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  /// Tarjeta del hub (letra + icono + título + subtítulo).
  Widget _tarjetaHub(String letra, IconData icono, String titulo,
      String subtitulo, VoidCallback onTap) {
    return Tarjeta(
      onTap: onTap,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color:
                      AppColores.naranja.withValues(alpha: 0.15),
                  borderRadius:
                      BorderRadius.circular(AppRadio.md),
                ),
                child: Center(
                  child: Text(
                    letra,
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      color: AppColores.naranja,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: AppEspacio.sm),
              Icon(icono,
                  color: AppColores.naranja, size: 28),
            ],
          ),
          const SizedBox(height: AppEspacio.sm),
          Text(titulo, style: AppTexto.subtitulo),
          const SizedBox(height: 2),
          Text(
            subtitulo,
            style: TextStyle(
                fontSize: 12,
                color: AppColores.textoSecundario(context)),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
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
