/// Administración (solo admin).
///
/// Estadísticas del negocio, montos, usuarios APK, pendiente a entrega,
/// gastos, cierre de caja, papelera y exportar. Todo funciona offline:
/// los cambios se encolan y suben al sincronizar.
library;

import 'dart:io';

import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:uuid/uuid.dart';

import '../auth.dart';
import '../localdb.dart';
import '../negocio.dart';
import '../perfil.dart';
import '../permisos.dart';
import '../sync.dart';
import '../tipos_pago.dart';
import 'componentes.dart';
import 'diseno.dart';
import 'admin_secciones.dart';
import 'arqueo.dart';
import 'auditoria.dart';
import 'auditoria_silenciosa.dart';
import 'nomina.dart';
import 'riesgo.dart';
import 'papelera.dart';
import 'congelados.dart';
import 'usuarios.dart';
import 'incidencias/lista_incidencias.dart';
import 'historial_caja.dart';
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
  // v1.2.4: datos bancarios (strings, no montos)
  final Map<String, TextEditingController> _bancarios = {};
  bool _cargando = true;
  // Salud del sistema
  SyncDetalle _syncDet = const SyncDetalle();
  int _pendientesSubir = 0;

  List<TipoPago> _tipos = [];
  // v1.3.1: pago por cliente a entrenadores (movido desde Ajustes, solo dueño).
  int _pagoEntrenador = 150;

  static const _clavesMonto = [
    ('transferencia', 'Mensualidad por transferencia'),
    ('pago_diario', 'Pago diario'),
    // v1.2.1: precio de menores configurable (antes hardcodeado 1500).
    ('mensualidad_menores', 'Mensualidad menores'),
    // v1.2.1: tasa USD del día para mostrar precios CUP en suplementos.
    ('tasa_usd', 'Tasa USD (CUP por 1 USD)'),
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
    for (final c in _bancarios.values) {
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
    final pagoEnt = await PerfilService.instance.getPagoEntrenador();
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
        _pagoEntrenador = pagoEnt;
        for (final (clave, _) in _clavesMonto) {
          _montos
              .putIfAbsent(clave, () => TextEditingController())
              .text = '${(aj[clave] as num?) ?? ''}';
        }
        // v1.2.4: cargar datos bancarios (strings)
        for (final clave in ['tarjeta_bandec', 'tarjeta_bpa', 'movil_confirmacion']) {
          _bancarios
              .putIfAbsent(clave, () => TextEditingController())
              .text = '${aj[clave] ?? ''}';
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
    // v1.3.1: actualización optimista del espejo local.
    final aj = await LocalDb.instance.getAjustes();
    for (final e in cambios.entries) {
      aj[e.key] = e.value;
    }
    await LocalDb.instance.setAjustes(aj);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Precios guardados (se sincronizarán)')));
    SyncEngine.instance.push();
  }

  /// v1.2.4: Guardar datos bancarios (strings, no montos).
  Future<void> _guardarBancarios() async {
    // v1.2.4 (Hark): valida formato y solo envía lo que cambió.
    final aj = await LocalDb.instance.getAjustes();
    if (!mounted) return;
    final cambios = <String, String>{};
    final errores = <String>[];
    for (final clave in ['tarjeta_bandec', 'tarjeta_bpa', 'movil_confirmacion']) {
      final v = (_bancarios[clave]?.text ?? '').trim();
      // v1.2.4: vaciar un dato bancario se decide en el servidor
      // (pendiente de aprobación); la app solo envía valores no vacíos.
      if (v.isEmpty) continue;
      final digitos = v.replaceAll(RegExp(r'[\s-]'), '');
      {
        if (clave.startsWith('tarjeta') &&
            !RegExp(r'^\d{16}$').hasMatch(digitos)) {
          errores.add('${clave == 'tarjeta_bandec' ? 'BANDEC' : 'BPA'}: 16 dígitos');
          continue;
        }
        if (clave == 'movil_confirmacion' &&
            !RegExp(r'^[56]\d{7}$').hasMatch(digitos)) {
          errores.add('Móvil: 8 dígitos, empieza por 5 o 6');
          continue;
        }
      }
      final normal = clave.startsWith('tarjeta') && digitos.length == 16
          ? [for (var i = 0; i < 16; i += 4) digitos.substring(i, i + 4)].join(' ')
          : digitos;
      if (normal != '${aj[clave] ?? ''}'.trim()) cambios[clave] = normal;
    }
    if (errores.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Revisa: ${errores.join(' · ')}')));
      return;
    }
    if (cambios.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('No hay cambios en los datos bancarios')));
      return;
    }
    final ok = await DialogoApp.confirmar(
      context,
      titulo: 'Guardar datos bancarios',
      mensaje: 'Se actualizarán los datos de transferencia.\n'
          'Se aplicará en la próxima sincronización.',
      aceptar: 'Confirmar',
      icono: Icons.account_balance,
    );
    if (ok != true || !mounted) return;
    for (final e in cambios.entries) {
      await LocalDb.instance.queueOp(
        opUuid: const Uuid().v4(),
        tipo: 'ajuste',
        payload: {'clave': e.key, 'valor': e.value},
      );
    }
    // v1.3.1: actualización optimista del espejo local.
    for (final e in cambios.entries) {
      aj[e.key] = e.value;
    }
    await LocalDb.instance.setAjustes(aj);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Datos bancarios guardados (se sincronizarán)')));
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

  Future<void> _persistirTipos() async {
    await LocalDb.instance.queueOp(
      opUuid: const Uuid().v4(),
      tipo: 'guardar_tipos_pago',
      payload: {
        'tipos': [for (final t in _tipos) t.toJson()],
      },
    );
    // v1.3.1: optimismo local (tipos visibles al instante al cobrar).
    final aj = await LocalDb.instance.getAjustes();
    aj['tipos_pago'] = [for (final t in _tipos) t.toJson()];
    await LocalDb.instance.setAjustes(aj);
    SyncEngine.instance.push();
  }

  Future<void> _toggleTipo(TipoPago t, bool v) async {
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
    await _persistirTipos();
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
    // v1.3.2 (Argón #11): NO hacer dispose tras showDialog; el diálogo
    // sigue animando su cierre y el controller aún está en uso.
    // Los controllers locales los recoge el GC (igual que dialogo_pago).
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
    await _persistirTipos();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Tipo de pago actualizado (se sincronizará)')));
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
    // v1.3.2 (Argón #11): sin dispose tras showDialog (ver arriba).
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
    await _persistirTipos();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Tipo de pago agregado (se sincronizará)')));
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
    await _persistirTipos();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Tipo de pago eliminado (se sincronizará)')));
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
  /// v1.3.1: elegir cuánto se paga por cliente a entrenadores.
  /// Movido desde Ajustes (solo dueño).
  Future<void> _elegirPagoEntrenador() async {
    final ctrl = TextEditingController(text: '$_pagoEntrenador');
    final sel = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Pago a entrenadores'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
                'CUP por cada cliente que pagó su mensualidad:'),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                suffixText: 'CUP',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancelar')),
          ElevatedButton(
              onPressed: () {
                final v = int.tryParse(ctrl.text);
                Navigator.pop(ctx, v != null && v > 0 ? v : null);
              },
              child: const Text('Guardar')),
        ],
      ),
    );
    // v1.3.1: no hacer dispose aquí — el TextField sigue montado durante
    // la animación de salida del diálogo (error "used after being disposed").
    if (sel != null) {
      await PerfilService.instance.setPagoEntrenador(sel);
      if (mounted) {
        setState(() => _pagoEntrenador = sel);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content:
                Text('Pago actualizado: $sel CUP por cliente')));
      }
    }
  }

  /// v1.3.1: marca como entregado en SQLite local (optimismo).
  /// Filtra en Dart con esPendiente() (seguro sin JSON1 y con NULLs).
  Future<void> _marcarEntregadoLocal(int? trainerId) async {
    final d = await LocalDb.instance.db;
    final ahora = DateTime.now().toIso8601String();
    await d.transaction((txn) async {
      for (final tabla in ['pagos', 'pagos_diarios', 'ventas_suplementos']) {
        final col =
            tabla == 'pagos' ? 'telegram_user_id' : 'registrado_por';
        final rows =
            await txn.query(tabla, columns: ['id', 'data']);
        for (final r in rows) {
          final data = Map<String, dynamic>.from(
              jsonDecode(r['data'] as String) as Map);
          if (!esPendiente(data['entregado'])) continue;
          if (tabla == 'pagos' && data['metodo'] != 'efectivo') continue;
          if (trainerId != null && data[col] != trainerId) continue;
          data['entregado'] = 1;
          data['entregado_ts'] = ahora;
          await txn.update(tabla, {'data': jsonEncode(data)},
              where: 'id = ?', whereArgs: [r['id']]);
        }
      }
    });
  }

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
    // v1.3.1: actualización optimista local (la UI se pone en 0 al instante).
    await _marcarEntregadoLocal(trainerId);
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
    await _cargar();
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
    final concepto = conceptoCtrl.text.trim();
    final montoTexto = montoCtrl.text.replaceAll(',', '.');
    conceptoCtrl.dispose();
    montoCtrl.dispose();
    if (ok != true || !mounted) return;
    final monto = double.tryParse(montoTexto);
    if (concepto.isEmpty || monto == null || monto <= 0) {
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
        'concepto': concepto,
        'monto': monto,
      },
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Gasto guardado (se sincronizará)')));
    await _cargar();
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
    // v1.3.4 (ítem 2): columna `fecha` indexada en vez de allMirror.
    final pagosMes = await LocalDb.instance.pagosDelMes(pref);
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

  // -- UI (hub por flujos, v1.3.7) -------------------------------------------
  @override
  Widget build(BuildContext context) {
    // Datos para las líneas de resumen de cada tarjeta.
    final cajaTotal = (_caja['efectivo'] ?? 0) + (_caja['transferencia'] ?? 0);
    final netoHoy = cajaTotal - _gastosHoy;
    final pendTotal =
        _pend.fold<double>(0, (s, e) => s + (e['total'] as double? ?? 0));

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
                        // -- 💰 DINERO ------------------------------------------------
                        _encabezadoGrupo('💰', 'DINERO'),
                        _tarjetaFlujo(
                          Icons.point_of_sale_rounded,
                          'Cierre de caja',
                          'Neto hoy: ${fmtMonto(netoHoy)} CUP',
                          () => _ir(SeccionCobrosScreen(
                            getCaja: () => _caja,
                            getGastosHoy: () => _gastosHoy,
                            getPend: () => _pend,
                            onConfirmarEntrega: _confirmarEntrega,
                            onIr: _irYRecargar,
                          )),
                        ),
                        _tarjetaFlujo(
                          Icons.account_balance_wallet_rounded,
                          'Arqueo de caja',
                          pendTotal > 0
                              ? '${fmtMonto(pendTotal)} CUP por liquidar'
                              : 'Todo cuadrado',
                          () => _ir(const ArqueoScreen()),
                        ),
                        _tarjetaFlujo(
                          Icons.payments_rounded,
                          'Nómina del mes',
                          'Proyección: clientes pagados × 150 CUP',
                          () => _ir(const NominaScreen()),
                        ),
                        _tarjetaFlujo(
                          Icons.receipt_long_rounded,
                          'Últimos gastos',
                          'Hoy: ${fmtMonto(_gastosHoy)} CUP',
                          () => _ir(SeccionGastosScreen(
                            getGastos: () => _gastos,
                            onAgregarGasto: _agregarGasto,
                          )),
                        ),
                        _tarjetaFlujo(
                          Icons.history_outlined,
                          'Historial de caja',
                          'Cierres por entrenador y fecha',
                          () => _ir(const HistorialCajaScreen()),
                        ),
                        // v1.3.1: pago por cliente a entrenadores (solo dueño).
                        if (AuthService().isOwner)
                          _tarjetaFlujo(
                            Icons.payments_outlined,
                            'Pago a entrenadores',
                            '$_pagoEntrenador CUP por cliente que pagó',
                            _elegirPagoEntrenador,
                          ),

                        // -- 👥 CLIENTES ----------------------------------------------
                        _encabezadoGrupo('👥', 'CLIENTES'),
                        _tarjetaFlujo(
                          Icons.warning_amber_rounded,
                          'Clientes en riesgo',
                          'Inactivos 60+ días, buenos para recuperar',
                          () => _ir(const RiesgoScreen()),
                        ),
                        _tarjetaFlujo(
                          Icons.delete_outline_rounded,
                          'Papelera',
                          'Clientes eliminados (recuperables)',
                          () => _ir(const PapeleraScreen()),
                        ),
                        _tarjetaFlujo(
                          Icons.ac_unit_rounded,
                          'Congelados',
                          'Membresías pausadas',
                          () => _ir(const CongeladosScreen()),
                        ),

                        // -- 📊 OPERACIÓN ----------------------------------------------
                        _encabezadoGrupo('📊', 'OPERACIÓN'),
                        // Estado y último error como tarjetas compactas.
                        _tarjetaCompacta(
                          _pendientesSubir > 0
                              ? Icons.sync_problem_rounded
                              : Icons.check_circle_outline_rounded,
                          'Estado de sync',
                          _pendientesSubir > 0
                              ? '$_pendientesSubir por subir'
                              : 'Todo sincronizado',
                          _pendientesSubir > 0
                              ? AppColores.alerta
                              : AppColores.exito,
                        ),
                        if (_syncDet.error != null &&
                            _syncDet.error!.isNotEmpty)
                          _tarjetaCompacta(
                            Icons.error_outline_rounded,
                            'Último error',
                            _syncDet.error!,
                            AppColores.error,
                          ),
                        _tarjetaFlujo(
                          Icons.bar_chart_rounded,
                          'Estadísticas del mes',
                          '${fmtMonto(_ingresos)} CUP · $_inscMes insc.',
                          () => _ir(SeccionResumenScreen(
                            ingresos: _ingresos,
                            inscMes: _inscMes,
                            morosos: _morosos,
                            inscPorEntrenador: _inscPorEntrenador,
                          )),
                        ),
                        _tarjetaFlujo(
                          Icons.inventory_2_rounded,
                          'Suplementos',
                          'Catálogo, categorías y ventas',
                          () => _ir(SeccionSuplementosScreen(
                            onIr: _irYRecargar,
                          )),
                        ),
                        _tarjetaFlujo(
                          Icons.fact_check_rounded,
                          'Auditoría',
                          'Quién hizo qué y cuándo',
                          () => _ir(const AuditoriaScreen()),
                        ),
                        _tarjetaFlujo(
                          Icons.radar_rounded,
                          'Anomalías',
                          'Detección silenciosa (solo dueño)',
                          () => _ir(const AuditoriaSilenciosaScreen()),
                        ),
                        _tarjetaFlujo(
                          Icons.monitor_heart_rounded,
                          'Salud del sistema',
                          _pendientesSubir > 0
                              ? '$_pendientesSubir ops por subir'
                              : 'Sincronizado',
                          () => _ir(const SeccionDiagnosticoScreen()),
                        ),
                        _tarjetaFlujo(
                          Icons.warning_amber_rounded,
                          'Incidencias',
                          'Errores que requieren atención',
                          () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) =>
                                    const ListaIncidenciasScreen(),
                              ),
                            );
                          },
                        ),

                        // -- ⚙️ CONFIGURACIÓN ------------------------------------------
                        _encabezadoGrupo('⚙️', 'CONFIGURACIÓN'),
                        _tarjetaFlujo(
                          Icons.payments_outlined,
                          'Tipos de pago',
                          '${_tipos.length} tipos configurados',
                          () => _ir(_pantallaAjustes()),
                        ),
                        _tarjetaFlujo(
                          Icons.price_change_rounded,
                          'Otros precios',
                          'Mensualidades, diario, tasa USD',
                          () => _ir(_pantallaAjustes()),
                        ),
                        _tarjetaFlujo(
                          Icons.account_balance_rounded,
                          'Datos bancarios',
                          'Tarjetas y móvil de confirmación',
                          () => _ir(_pantallaAjustes()),
                        ),
                        _tarjetaFlujo(
                          Icons.manage_accounts_rounded,
                          'Usuarios APK',
                          'Gestionar accesos de entrenadores',
                          () => _ir(const UsuariosScreen()),
                        ),
                        _tarjetaFlujo(
                          Icons.file_download_rounded,
                          'Exportar',
                          'CSV y Excel de clientes y pagos',
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
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  /// Construye la pantalla de Ajustes (se reutiliza en 3 tarjetas).
  Widget _pantallaAjustes() {
    return SeccionAjustesScreen(
      getTipos: () => _tipos,
      onToggleTipo: _toggleTipo,
      onEditarTipo: _editarTipo,
      onEliminarTipo: _eliminarTipo,
      onAgregarTipo: _agregarTipo,
      onGuardarTipos: _guardarTipos,
      montos: _montos,
      clavesMonto: _clavesMonto,
      onGuardarMontos: _guardarMontos,
      bancarios: _bancarios,
      onGuardarBancarios: _guardarBancarios,
      gestionarUsuarios: Permisos().gestionarUsuarios,
      onIr: _irYRecargar,
      esTipoFijo: _esTipoFijo,
    );
  }

  /// Encabezado de grupo (emoji + título).
  Widget _encabezadoGrupo(String emoji, String titulo) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 16, 4, 8),
      child: Text(
        '$emoji  $titulo',
        style: AppTexto.subtitulo.copyWith(
          fontWeight: FontWeight.bold,
          letterSpacing: 1.2,
        ),
      ),
    );
  }

  /// Tarjeta de flujo: badge + título + una línea de resumen.
  Widget _tarjetaFlujo(
      IconData icono, String titulo, String resumen, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Tarjeta(
        onTap: onTap,
        child: Row(
          children: [
            IconoModuloBadge.naranja(icono),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(titulo, style: AppTexto.subtitulo),
                  const SizedBox(height: 2),
                  Text(
                    resumen,
                    style: TextStyle(
                        fontSize: 12,
                        color: AppColores.textoSecundario(context)),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded,
                color: AppColores.textoSecundario(context)),
          ],
        ),
      ),
    );
  }

  /// Tarjeta compacta informativa (no navegable): Estado / Último error.
  Widget _tarjetaCompacta(
      IconData icono, String titulo, String detalle, Color color) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Tarjeta(
        child: Row(
          children: [
            Icon(icono, color: color, size: 22),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(titulo,
                      style: AppTexto.cuerpo
                          .copyWith(fontWeight: FontWeight.w600)),
                  Text(
                    detalle,
                    style: TextStyle(
                        fontSize: 12,
                        color: AppColores.textoSecundario(context)),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
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
