/// Registro de pagos diarios del turno (ej. 200 CUP por turno).
/// Muestra los turnos ya registrados hoy para evitar duplicados.
///
/// v1.0.13: botón rápido +1, nota opcional, total del día, deshacer,
/// editar/eliminar registros.
library;

import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../auth.dart';
import '../localdb.dart';
import '../negocio.dart';
import '../sync.dart';
import '../tiempo.dart';
import 'app_bar.dart';
import 'componentes.dart';
import 'diseno.dart';
import 'reporte_mensual_diarios.dart';
import 'widgets.dart';

/// ¿Puede este usuario editar/anular un registro de pago diario?
/// PURO. Dueño: todo. Entrenador: solo lo suyo. Sin autor conocido
/// o sin identidad propia: no (fail-closed). Terra lote-4 MEDIO: el
/// gate debe cubrir también la rama optimista (cancelar de la cola),
/// no solo los registros sincronizados; y no puede depender del
/// filtro de la lista.
bool puedeEditarRegistroDiario({
  required bool esDueno,
  required int? yo,
  required int? autor,
}) =>
    esDueno || (yo != null && autor == yo);

class PagoDiarioScreen extends StatefulWidget {
  const PagoDiarioScreen({super.key});
  @override
  State<PagoDiarioScreen> createState() => _PagoDiarioScreenState();
}

class _PagoDiarioScreenState extends State<PagoDiarioScreen> {
  String _turno = 'mañana';
  int _cantidad = 1;
  bool _guardando = false;
  bool _editandoRegistro = false;
  double _precio = 200;
  List<Map<String, dynamic>> _hoy = [];
  final _notaCtrl = TextEditingController();

  // v1.0.15: modo reporte
  bool _modoReporte = false;
  DateTime _fechaReporte = ahoraHabana();
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
    // v1.3.1: turno por defecto según la hora del día.
    _turno = ahoraHabana().hour >= 12 ? 'tarde' : 'mañana';
    LocalDb.instance.getAjustes().then((aj) {
      if (mounted) {
        setState(() =>
            _precio = (aj['pago_diario'] as num?)?.toDouble() ?? 200);
      }
    });
    _cargarHoy();
  }

  Future<void> _cargarHoy() async {
    // Argón lote 4 MEDIO: sin filtro, el entrenador veía los diarios
    // de todos y podía editarlos (ver _editarRegistro). El dueño ve
    // todo; el entrenador, solo lo suyo.
    // Terra lote-4: si el entrenador no tiene telegram_id, null era
    // "sin filtro" (veía TODOS). Con -1 no ve ninguno (fail-closed).
    final h = await diariosDeHoy(
        soloTelegramId: AuthService().isOwner
            ? null
            : (AuthService().telegramId ?? -1));
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
      lastDate: ahoraHabana(),
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

  /// Guarda un pago diario. Devuelve el op_uuid para poder deshacer,
  /// o null si el usuario declinó el aviso de duplicado.
  Future<String?> _guardarOp(
      {required int cantidad, String? nota}) async {
    // Argón lote 4 MEDIO: la cabecera promete evitar duplicados pero
    // nada advertía al registrar otro lote del mismo turno/día. Se
    // avisa (no se bloquea: un segundo lote puede ser legítimo) y
    // solo se encola si el usuario confirma. Sin autor = optimista
    // propio (la cola es del propio teléfono).
    final yo = AuthService().telegramId;
    final ya = _hoy.any((r) {
      if ('${r['turno'] ?? ''}' != _turno) return false;
      final autor = LocalDb.normalizarTelegramId(r['registrado_por']);
      return autor == null || autor == yo;
    });
    if (ya && mounted) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => DialogoApp(
          titulo: 'Turno ya registrado',
          iconoTitulo: Icons.warning_amber_rounded,
          contenido: Text(
              'El turno $_turno ya tiene un pago registrado hoy. '
              '¿Registrar otro pago para el mismo turno?'),
          acciones: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancelar')),
            ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColores.naranja,
                  foregroundColor: Colors.white,
                ),
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Registrar otro')),
          ],
        ),
      );
      if (ok != true) return null;
    }
    final uuid = const Uuid().v4();
    await LocalDb.instance.queueOp(
      opUuid: uuid,
      tipo: 'pago_diario',
      payload: {
        // v1.4.0 (Argón §8): fecha de negocio en hora de La Habana,
        // nunca DateTime.now() crudo en payloads.
        'fecha': hoyHabanaIso(),
        // v1.2.7: timestamp para deduplicar pagos idénticos (fix Gemini).
        'creado_en': isoHabana(ahoraHabana()),
        'turno': _turno,
        'cantidad': cantidad,
        // v1.3.1: total calculado + registrado_por para deduplicación.
        'total': cantidad * _precio,
        // Fase A 2026-10-25 (A1): la UI de diarios es solo
        // efectivo; el método va explícito para que el espejo y
        // el pendiente puedan filtrarlo (antes no viajaba y el
        // pendiente sumaba cualquier diario sin distinguir).
        'metodo': 'efectivo',
        'registrado_por': AuthService().telegramId,
        if (nota != null && nota.isNotEmpty) 'nota': nota,
      },
    );
    return uuid;
  }

  void _trasGuardar(String? uuid, int cantidad) {
    _cargarHoy();
    SyncEngine.instance.push();
    // v1.2.6 (Gemini): confirmación háptica al cobrar.
    vibrarConfirmacion();
    if (!mounted) return;
    // Gramática de avisos (1.23): por el helper único, que
    // reemplaza la barra anterior en vez de encolarla.
    mostrarSnack(context, '$cantidad pago(s) guardado(s)',
        significado: SignificadoChip.exito,
        // v1.2.7 (A3): se descarta solo a los 4s, no obliga a interactuar.
        duracion: const Duration(seconds: 4),
        accion: uuid == null ? null : 'Deshacer',
        alAccion: uuid == null ? null : () => _deshacer(uuid));
  }

  /// Deshace un pago recién guardado (lo elimina de la cola si no subió).
  /// v1.2.7 (A2): si ya se subió, avisa que no se puede deshacer localmente.
  Future<void> _deshacer(String uuid) async {
    final ok = await LocalDb.instance.cancelOp(uuid);
    _cargarHoy();
    if (!mounted) return;
    mostrarSnack(
        context,
        ok
            ? 'Registro deshecho'
            : 'Ya se envió al servidor, no se puede deshacer',
        significado:
            ok ? SignificadoChip.exito : SignificadoChip.alerta,
        duracion: const Duration(seconds: 3));
  }

  Future<void> _guardar() async {
    if (_guardando) return;
    setState(() => _guardando = true);
    try {
      final cantGuardada = _cantidad;
      final uuid = await _guardarOp(
        cantidad: cantGuardada,
        nota: _notaCtrl.text.trim().isEmpty
            ? null
            : _notaCtrl.text.trim(),
      );
      if (uuid == null) return;
      _notaCtrl.clear();
      setState(() => _cantidad = 1);
      _trasGuardar(uuid, cantGuardada);
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
      if (uuid == null) return;
      _trasGuardar(uuid, 1);
    } finally {
      if (mounted) setState(() => _guardando = false);
    }
  }

  /// Editar o eliminar un registro del día.
  Future<void> _editarRegistro(Map<String, dynamic> d) async {
    // Argón lote 4 MEDIO: sin guardia de reentrada, dos toques
    // abrían dos diálogos y podían encolar dos ops.
    if (_editandoRegistro) return;
    setState(() => _editandoRegistro = true);
    try {
      await _editarRegistroAhora(d);
    } finally {
      if (mounted) setState(() => _editandoRegistro = false);
    }
  }

  Future<void> _editarRegistroAhora(Map<String, dynamic> d) async {
    final id = d['id'] as int?;
    final opUuid = d['op_uuid'] as String?;
    // Terra lote-4 MEDIO: el gate va ANTES de separar la rama
    // optimista. Antes, cancelar un pendiente (id == null) llegaba
    // a cancelOp sin comprobar autoría; la lista filtrada no
    // sustituye un gate en la operación destructiva.
    final yo = AuthService().telegramId;
    final autor = LocalDb.normalizarTelegramId(d['registrado_por']);
    if (!puedeEditarRegistroDiario(
        esDueno: AuthService().isOwner, yo: yo, autor: autor)) {
      if (!mounted) return;
      mostrarSnack(context, 'Solo puedes editar tus propios registros.', significado: SignificadoChip.alerta);
      return;
    }
    // v1.3.1: si es optimista (sin id), solo permite eliminar de la cola.
    if (id == null) {
      if (opUuid == null) return;
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => DialogoApp(
          titulo: '¿Eliminar?',
          iconoTitulo: Icons.delete_rounded,
          contenido: const Text(
              'Se eliminará este registro pendiente (aún no sincronizado).'),
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
      if (ok == true) {
        final cancelado = await LocalDb.instance.cancelOp(opUuid);
        _cargarHoy();
        if (mounted) {
          mostrarSnack(context, cancelado
                  ? 'Registro eliminado'
                  : 'Ya se envió al servidor, espera a que sincronice');
        }
      }
      return;
    }
    // (El gate de autoría ya se aplicó arriba, antes de la rama
    // optimista; no se duplica aquí.)
    final cantCtrl = TextEditingController(
        text: '${d['cantidad'] ?? 1}');
    final notaCtrl =
        TextEditingController(text: '${d['nota'] ?? ''}');
    final accion = await showDialog<String>(
      context: context,
      builder: (ctx) => DialogoApp(
        titulo: 'Editar pago diario',
        iconoTitulo: Icons.edit_rounded,
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
    // v1.3.1: capturar antes del dispose (evita used after disposed).
    final cantTexto = cantCtrl.text.trim();
    final notaTexto = notaCtrl.text.trim();
    cantCtrl.dispose();
    notaCtrl.dispose();
    if (accion == null || !mounted) return;

    if (accion == 'eliminar') {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => DialogoApp(
          titulo: '¿Eliminar?',
          iconoTitulo: Icons.delete_rounded,
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
      // v1.3.1: borrado optimista local.
      // Autoauditoría 1.22 #2 (D2-05): borrado del espejo + op
      // en UNA transacción (antes dos awaits sueltos: un cierre
      // entre ambos dejaba el registro borrado localmente sin
      // que el servidor se enterara jamás).
      final connDel = await LocalDb.instance.db;
      await connDel.transaction((txn) async {
        await LocalDb.instance
            .deleteMirror('pagos_diarios', id, txn: txn);
        await LocalDb.instance.queueOp(
          opUuid: const Uuid().v4(),
          tipo: 'anular_pago_diario',
          payload: {'pago_diario_id': id},
          txn: txn,
        );
      });
      _cargarHoy();
      SyncEngine.instance.push();
      if (!mounted) return;
      mostrarSnack(context, 'Registro eliminado', significado: SignificadoChip.exito);
      return;
    }

    // Guardar edición
    final cantidad = int.tryParse(cantTexto) ?? 0;
    if (cantidad < 1) {
      if (!mounted) return;
      mostrarSnack(context, 'La cantidad debe ser al menos 1', significado: SignificadoChip.alerta);
      return;
    }
    // v1.3.1: actualización optimista local.
    // Argón Dinero #10: el total se recalcula con el precio
    // UNITARIO DEL PROPIO REGISTRO (total/cantidad guardados),
    // no con la tarifa vigente: si el precio del diario subió
    // entre el registro y la edición, editar solo la cantidad
    // revaluaba cobros viejos a precio nuevo en espejo y
    // servidor.
    // Autoauditoría 1.22 #2 (D2-05): si la fila YA NO está en
    // el espejo (anulada en otro teléfono, pull que la borró),
    // NO se edita: antes se caía al precio VIGENTE (_precio) y
    // se encolaba una edición con total recalculado a precio
    // nuevo contra un registro que este teléfono no tiene.
    final db = await LocalDb.instance.db;
    final rows = await db.query('pagos_diarios',
        columns: ['data'], where: 'id = ?', whereArgs: [id], limit: 1);
    if (rows.isEmpty) {
      if (!mounted) return;
      mostrarSnack(context,
          'Ese registro ya no está en este teléfono; no se editó',
          significado: SignificadoChip.alerta);
      _cargarHoy();
      return;
    }
    final previa = Map<String, dynamic>.from(
        jsonDecode(rows.first['data'] as String) as Map);
    final cantVieja = (previa['cantidad'] as num?)?.toDouble() ?? 0;
    final totalViejo = (previa['total'] as num?)?.toDouble() ?? 0;
    var precioUnitario = _precio;
    if (cantVieja > 0 && totalViejo > 0) {
      precioUnitario = totalViejo / cantVieja;
    }
    final data = previa;
    data['cantidad'] = cantidad;
    data['total'] = cantidad * precioUnitario;
    data['nota'] = notaTexto;
    // Espejo + op en UNA transacción (antes dos awaits sueltos).
    await db.transaction((txn) async {
      await txn.update('pagos_diarios', {'data': jsonEncode(data)},
          where: 'id = ?', whereArgs: [id]);
      await LocalDb.instance.queueOp(
        opUuid: const Uuid().v4(),
        tipo: 'editar_pago_diario',
        payload: {
          'pago_diario_id': id,
          'cantidad': cantidad,
          'nota': notaTexto,
          // Argón lote 4 MEDIO: el espejo local ya actualizaba total
          // pero el payload no lo llevaba; si la tarifa cambió o el
          // servidor no recalcula igual, espejo y servidor divergen.
          'total': cantidad * precioUnitario,
        },
        txn: txn,
      );
    });
    _cargarHoy();
    SyncEngine.instance.push();
    if (!mounted) return;
    mostrarSnack(context, 'Registro actualizado', significado: SignificadoChip.exito);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: appBarIron(
        context,
        'Pago diario',
        acciones: [
          // v1.0.15: alternar entre registrar y reporte
          // Argón PASADA 2 MEDIO: el reporte muestra totales globales
          // y filas de todos; solo el dueño lo abre. Sin botón, el
          // modo reporte es inalcanzable (este es el único sitio que
          // pone _modoReporte en true).
          if (AuthService().isOwner)
            TextButton.icon(
              icon: Icon(
                  _modoReporte ? Icons.edit_rounded : Icons.bar_chart_rounded),
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
      padding: const EdgeInsets.all(AppEspacio.lg),
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
                  icono: Icons.flash_on_rounded,
                  onPressed: _guardando ? null : _rapido,
                ),
                const SizedBox(height: 12),
                const Text('O varios a la vez:'),
                Row(
                  children: [
                    const Text('Cantidad: '),
                    IconButton(
                        icon: const Icon(
                            Icons.remove_circle_outline_rounded),
                        onPressed: _cantidad > 1
                            ? () => setState(() => _cantidad--)
                            : null),
                    Text('$_cantidad',
                        style: AppTexto.metrica.copyWith(
                            fontWeight: FontWeight.normal)),
                    IconButton(
                        icon: const Icon(
                            Icons.add_circle_outline_rounded),
                        onPressed: () =>
                            setState(() => _cantidad++)),
                  ],
                ),
                CampoTexto(
                  controller: _notaCtrl,
                  etiqueta: 'Nota (opcional)',
                  hint: 'Ej: grupo de 3',
                  icono: Icons.note_rounded,
                ),
                const SizedBox(height: 8),
                Text('Total: ${fmtMonto(_precio * _cantidad)} CUP',
                    style: AppTexto.tituloPagina),
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
                    padding: const EdgeInsets.only(bottom: AppEspacio.sm),
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
                            Icons.edit_rounded,
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
        ? const EstadoCargando(texto: 'Cargando pago diario…')
        : ListView(
            padding: const EdgeInsets.all(AppEspacio.lg),
            children: [
              // v1.3.2: acceso al resumen mensual.
              Padding(
                padding:
                    const EdgeInsets.only(bottom: AppEspacio.md),
                child: OutlinedButton.icon(
                  icon: const Icon(
                      Icons.calendar_month_rounded),
                  label: const Text(
                      'Ver resumen mensual'),
                  onPressed: () =>
                      Navigator.push(
                    context,
                    RutaIron(
                      builder: (_) =>
                          const ReporteMensualDiariosScreen(),
                    ),
                  ),
                ),
              ),
              // Selector de fecha
              Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.chevron_left_rounded),
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
                            vertical: AppEspacio.md),
                        decoration: BoxDecoration(
                          border: Border.all(
                              color: AppColores.borde(context)),
                          borderRadius:
                              BorderRadius.circular(AppRadio.md),
                        ),
                        child: Text(
                          fmtFecha(_fechaReporte.toIso8601String().substring(0, 10)),
                          textAlign: TextAlign.center,
                          style: AppTexto.titulo,
                        ),
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.chevron_right_rounded),
                    onPressed: _fechaReporte
                            .toIso8601String()
                            .substring(0, 10) ==
                        hoyHabanaIso()
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
                      style: AppTexto.metrica.copyWith(
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
                  padding: const EdgeInsets.all(AppEspacio.sm),
                  decoration: BoxDecoration(
                    color: AppColores.superficie(context),
                    border: Border.all(
                        color: AppColores.borde(context)),
                    borderRadius: BorderRadius.circular(AppRadio.md),
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
                                AppTexto.minuscula,
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
                  padding: const EdgeInsets.only(bottom: AppEspacio.sm),
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
      padding: const EdgeInsets.all(AppEspacio.md),
      child: Column(
        children: [
          Text(titulo,
              style: AppTexto.cuerpo),
          const SizedBox(height: 4),
          Text(fmtMonto(total),
              style: AppTexto.titulo.copyWith(color: AppColores.naranja)),
          Text('$cantidad pagos',
              style: AppTexto.metadato.copyWith(color: AppColores.textoSecundario(context))),
        ],
      ),
    );
  }
}
