/// Detalle / historial por entrenador (v1.0.16).
///
/// Mejoras v1.0.16:
/// 1. Lista de cobros del período (tocable -> ficha del cliente)
/// 2. Incluye pagos diarios en los totales
/// 3. Estado de entrega (entregado vs pendiente)
/// 4. Inscripciones con nombre del cliente
/// 5. Comparativa vs período anterior (la de entrenadores
///    entre sí vive en su pantalla: F3-16)
/// 6. Días compactos (solo con actividad)
/// 7. Actividad por día (barras contra el mejor día)
/// 8. Promedio diario + mejor día
/// 9. Filtros: semana / mes / últimos 90 días
library;

import 'package:flutter/material.dart';

import '../auth.dart';
import '../entrenador_identidad.dart';
import '../localdb.dart';
import '../negocio.dart';
import '../tiempo.dart';
import 'app_bar.dart';
import 'avatar_entrenador.dart';
import 'componentes.dart';
import 'diseno.dart';
import 'comparativa_entrenadores.dart';
import 'ficha.dart';
import 'widgets.dart';

class DetalleEntrenadorScreen extends StatefulWidget {
  final String nombre;

  /// 1.25 T86: la identidad del entrenador (telegram_id)
  /// cuando quien navega la conoce (la comparativa la
  /// trae de su agrupación por ID). Sin ella, la
  /// pantalla la resuelve por nombre desde usuarios_apk.
  final int? telegramId;
  const DetalleEntrenadorScreen(
      {super.key, required this.nombre, this.telegramId});

  @override
  State<DetalleEntrenadorScreen> createState() =>
      _DetalleEntrenadorScreenState();
}

class _DetalleEntrenadorScreenState extends State<DetalleEntrenadorScreen> {
  bool _cargando = true;
  // 0 = semana, 1 = mes, 2 = últimos 90 días (rodantes;
  // F3-27: antes se llamaba «trimestre» y no lo era).
  int _filtro = 1;
  // F3-27: los cobros se cortaban en 50 con un «…y N más»
  // sin salida; ahora la lista se despliega entera.
  bool _verTodosCobros = false;

  double _total = 0;
  int _nCobros = 0;
  int _nDiarios = 0;
  double _entregado = 0;
  double _pendiente = 0;
  double _totalAnterior = 0;
  double _promedioDia = 0;
  String _mejorDia = '';
  double _mejorDiaMonto = 0;
  List<Map<String, dynamic>> _cobros = [];
  List<Map<String, dynamic>> _inscripciones = [];
  List<Map<String, dynamic>> _diasActivos = [];
  // {nombre, total} de otros entrenadores en el mismo período

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  bool _esMio(String? nombre) {
    return (nombre ?? '').trim().toLowerCase() ==
        widget.nombre.toLowerCase();
  }

  /// 1.25 T86: mi telegram_id (el de la navegación o el
  /// resuelto por nombre). Los PAGOS se atribuyen por
  /// ID con filaEsDelEntrenador: un tocayo ya no mezcla
  /// sus cobros aquí.
  int? _miTid;

  Future<void> _cargar() async {
    setState(() => _cargando = true);
    _miTid = widget.telegramId ??
        await telegramIdDeEntrenador(widget.nombre);
    final ahora = ahoraHabana();

    // Rango según filtro
    late DateTime inicio;
    late DateTime inicioAnterior;
    late DateTime finAnterior;
    switch (_filtro) {
      case 0: // semana (lunes-domingo)
        final dow = ahora.weekday;
        inicio = ahora.subtract(Duration(days: dow - 1));
        inicioAnterior = inicio.subtract(const Duration(days: 7));
        finAnterior = inicio.subtract(const Duration(days: 1));
        break;
      case 2: // últimos 90 días rodantes
        inicio = ahora.subtract(const Duration(days: 90));
        inicioAnterior = inicio.subtract(const Duration(days: 90));
        finAnterior = inicio.subtract(const Duration(days: 1));
        break;
      default: // mes
        inicio = DateTime(ahora.year, ahora.month, 1);
        final mesAnt = ahora.month == 1 ? 12 : ahora.month - 1;
        final anioAnt = ahora.month == 1 ? ahora.year - 1 : ahora.year;
        inicioAnterior = DateTime(anioAnt, mesAnt, 1);
        finAnterior = DateTime(ahora.year, ahora.month, 1)
            .subtract(const Duration(days: 1));
    }
    final iniStr = _iso(inicio);

    bool enRango(String? fecha) =>
        fecha != null && fecha.compareTo(iniStr) >= 0;
    bool enAnterior(String? fecha) =>
        fecha != null &&
        fecha.compareTo(_iso(inicioAnterior)) >= 0 &&
        fecha.compareTo(_iso(finAnterior)) <= 0;

    // v1.3.4 (ítem 2): columna `fecha` indexada en vez de allMirror;
    // trae desde el inicio del período anterior (los filtros enRango /
    // enAnterior se aplican en Dart como antes).
    final pagos =
        await LocalDb.instance.pagosDesde(_iso(inicioAnterior));
    final diarios = await LocalDb.instance.allMirror('pagos_diarios');
    final clientes = await LocalDb.instance.allMirror('clientes');
    final nombrePorId = <int, String>{};
    for (final c in clientes) {
      final id = (c['id'] as num?)?.toInt();
      if (id != null) {
        nombrePorId[id] = '${c['nombre'] ?? 'Cliente $id'}';
      }
    }

    _total = 0;
    _nCobros = 0;
    _nDiarios = 0;
    _entregado = 0;
    _pendiente = 0;
    _totalAnterior = 0;
    _cobros = [];
    _inscripciones = [];
    final porDia = <String, double>{};

    for (final p in pagos) {
      final fecha = fechaCorta(p['fecha'] ?? '', 10);
      final monto = (p['monto'] as num?)?.toDouble() ?? 0;
      // T86: por ID cuando la fila lo trae (el nombre
      // queda para las filas viejas sin telegram_user_id).
      final mio = filaEsDelEntrenador(p,
          telegramId: _miTid, nombre: widget.nombre);
      if (enAnterior(fecha) && mio) _totalAnterior += monto;
      if (!mio || !enRango(fecha)) continue;
      _total += monto;
      _nCobros++;
      if (esPendiente(p['entregado'])) {
        _pendiente += monto;
      } else {
        _entregado += monto;
      }
      porDia[fecha] = (porDia[fecha] ?? 0) + monto;
      final cid = (p['cliente_id'] as num?)?.toInt() ?? 0;
      _cobros.add({
        'cliente_id': cid,
        'cliente_nombre': nombrePorId[cid] ?? 'Cliente $cid',
        'monto': monto,
        'fecha': fecha,
        'periodo': '${p['periodo'] ?? 'mensual'}',
        'metodo': '${p['metodo'] ?? 'efectivo'}',
      });
    }
    // Pagos diarios del entrenador (idea 2)
    for (final d in diarios) {
      final fecha = fechaCorta(d['fecha'] ?? '', 10);
      final nombre = '${d['registrado_por_nombre'] ?? ''}'.trim();
      final total = (d['total'] as num?)?.toDouble() ?? 0;
      if (!_esMio(nombre)) continue;
      if (enAnterior(fecha)) _totalAnterior += total;
      if (!enRango(fecha)) continue;
      _total += total;
      _nDiarios += (d['cantidad'] as num?)?.toInt() ?? 0;
      if (esPendiente(d['entregado'])) {
        _pendiente += total;
      } else {
        _entregado += total;
      }
      porDia[fecha] = (porDia[fecha] ?? 0) + total;
    }
    // Inscripciones con nombre (idea 4)
    for (final c in clientes) {
      final fecha = '${c['fecha_inscripcion'] ?? ''}';
      if (!enRango(fecha)) continue;
      final nombre =
          ('${c['registrado_por_nombre'] ?? ''}'.trim().isEmpty)
              ? '${c['registrado_por'] ?? ''}'
              : '${c['registrado_por_nombre']}'.trim();
      if (!_esMio(nombre)) continue;
      final id = (c['id'] as num?)?.toInt() ?? 0;
      _inscripciones.add({
        'cliente_id': id,
        'nombre': '${c['nombre'] ?? 'Cliente $id'}',
        'fecha': fechaCorta(fecha, 10),
      });
    }
    _cobros.sort((a, b) =>
        '${b['fecha']}'.compareTo('${a['fecha']}'));
    _inscripciones.sort((a, b) =>
        '${b['fecha']}'.compareTo('${a['fecha']}'));

    // Días con actividad (idea 6)
    final diasOrdenados = porDia.keys.toList()..sort();
    _diasActivos = [
      for (final f in diasOrdenados)
        {'fecha': f, 'monto': porDia[f]!}
    ];
    // Promedio y mejor día (idea 8). F3-15: el promedio es
    // por día CON ACTIVIDAD (la etiqueta lo dice: dividir
    // entre los días del período mezclaría días sin turno).
    final nDias = diasOrdenados.length;
    _promedioDia = nDias > 0 ? _total / nDias : 0;
    _mejorDia = '';
    _mejorDiaMonto = 0;
    for (final f in diasOrdenados) {
      if (porDia[f]! > _mejorDiaMonto) {
        _mejorDiaMonto = porDia[f]!;
        _mejorDia = f;
      }
    }
    if (mounted) setState(() => _cargando = false);
  }

  String _iso(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  String _nombrePeriodo() =>
      const ['esta semana', 'este mes', 'últimos 90 días'][_filtro];
  String _nombreAnterior() =>
      const ['semana anterior', 'mes anterior', '90 días anteriores'][
          _filtro];

  @override
  Widget build(BuildContext context) {
    // P2#9: pantalla de admin sin guarda de dueño.
    if (!AuthService().isOwner) {
      return Scaffold(
          appBar: appBarIron(context, widget.nombre),
          body: const Center(
              child: Text('Solo el dueño ve esta pantalla.')));
    }
    return Scaffold(
      appBar: appBarIron(context, widget.nombre),
      body: Column(
        children: [
          const SyncBanner(),
          // Filtros (idea 9)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: SegmentedButton<int>(
              segments: const [
                ButtonSegment(
                    value: 0, label: Text('Semana')),
                ButtonSegment(value: 1, label: Text('Mes')),
                ButtonSegment(
                    value: 2, label: Text('90 días')),
              ],
              selected: {_filtro},
              onSelectionChanged: (s) {
                setState(() => _filtro = s.first);
                _cargar();
              },
            ),
          ),
          Expanded(
            child: _cargando
                ? const Center(
                    child: CircularProgressIndicator())
                : RefreshIndicator(
                    onRefresh: _cargar,
                    child: ListView(
                      padding: const EdgeInsets.all(AppEspacio.lg),
                      children: [
                        // 1.25 T83: cabecera con la cara del
                        // entrenador (su foto de usuario o
                        // su inicial con su color).
                        Row(
                          children: [
                            AvatarEntrenador(
                                nombre: widget.nombre, tamano: 56),
                            const SizedBox(width: AppEspacio.md),
                            Expanded(
                              child: Column(
                                crossAxisAlignment:
                                    CrossAxisAlignment.start,
                                children: [
                                  Text(widget.nombre,
                                      style: AppTexto.subtitulo),
                                  const Text('Entrenador',
                                      style: AppTexto.secundario),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: AppEspacio.md),
                        // Resumen
                        Row(
                          children: [
                            Expanded(
                              child: _tarjeta(
                                  'Total ${_nombrePeriodo()}',
                                  '${fmtMonto(_total)} CUP',
                                  '$_nCobros cobros'
                                  '${_nDiarios > 0 ? ' · $_nDiarios diarios' : ''}'),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: _tarjeta(
                                  'Promedio / mejor día',
                                  '${fmtMonto(_promedioDia)} CUP/día activo',
                                  _mejorDia.isEmpty
                                      ? 'sin actividad'
                                      : '${fmtFecha(_mejorDia)}: ${fmtMonto(_mejorDiaMonto)} CUP'),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        // Estado de entrega (idea 3)
                        _seccion(Icons.outbox_rounded, 'Estado de entrega', [
                          Text(
                              'Entregado: ${fmtMonto(_entregado)} CUP',
                              style: const TextStyle(
                                  color: AppColores.exito,
                                  fontWeight:
                                      FontWeight.w500)),
                          Text(
                              'Pendiente: ${fmtMonto(_pendiente)} CUP',
                              style: const TextStyle(
                                  color: AppColores.alerta,
                                  fontWeight:
                                      FontWeight.w500)),
                          const SizedBox(height: 8),
                          if (_total > 0)
                            ClipRRect(
                              borderRadius:
                                  BorderRadius.circular(4),
                              child: LinearProgressIndicator(
                                value: (_entregado / _total)
                                    .clamp(0.0, 1.0),
                                backgroundColor: AppColores
                                    .alerta
                                    .withValues(alpha: 0.3),
                                valueColor:
                                    const AlwaysStoppedAnimation<
                                            Color>(
                                        AppColores.exito),
                                minHeight: 8,
                              ),
                            ),
                        ]),
                        // Comparativa (idea 5). F3-16: la
                        // lista de «otros» que vivía aquí sumaba
                        // SOLO pagos (sin diarios) mientras el
                        // total propio incluía ambos: la
                        // comparación salía desigual. La
                        // comparativa entre entrenadores es la
                        // de su pantalla (con ventas y dosis);
                        // aquí queda la fila contra el período
                        // anterior — consistente — y el enlace.
                        _seccion(Icons.bar_chart_rounded, 'Comparativa', [
                          _filaComparativa(
                              'Vs ${_nombreAnterior()}',
                              _totalAnterior,
                              _total),
                          const Divider(height: 12),
                          Align(
                            alignment: Alignment.centerLeft,
                            child: TextButton.icon(
                              icon: const Icon(
                                  Icons.bar_chart_rounded, size: 18),
                              label: const Text(
                                  'Ver comparativa entre entrenadores'),
                              onPressed: () => Navigator.of(context)
                                  .push(RutaIron(
                                      builder: (_) =>
                                          const ComparativaEntrenadoresScreen())),
                            ),
                          ),
                        ]),
                        // Actividad por día (ideas 6 y 7)
                        if (_diasActivos.isNotEmpty)
                          _seccion(Icons.calendar_today_rounded, 'Actividad por día', [
                            for (final d in _diasActivos)
                              Padding(
                                padding:
                                    const EdgeInsets.only(
                                        bottom: 6),
                                child: Row(
                                  children: [
                                    Flexible(
                                      flex: 4,
                                      child: Text(
                                        fmtFecha(
                                            d['fecha']),
                                        overflow: TextOverflow
                                            .ellipsis,
                                        style: AppTexto.metadato,
                                      ),
                                    ),
                                    Expanded(
                                      flex: 5,
                                      child:
                                          // F3-15: la barra se
                                          // normaliza contra el
                                          // MEJOR día, no contra el
                                          // total del período (que
                                          // las dejaba minúsculas).
                                          LinearProgressIndicator(
                                        value: _mejorDiaMonto > 0
                                            ? ((d['monto']
                                                        as double) /
                                                    _mejorDiaMonto)
                                                .clamp(
                                                    0.0, 1.0)
                                            : 0,
                                        minHeight: 8,
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Flexible(
                                      flex: 3,
                                      child: Text(
                                        fmtMonto((d['monto']
                                                as num)
                                            .toDouble()),
                                        textAlign:
                                            TextAlign.right,
                                        overflow: TextOverflow
                                            .ellipsis,
                                        style: AppTexto.metadato,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                          ]),
                        // Cobros del período (idea 1)
                        _seccion(Icons.receipt_long_rounded, 'Cobros (${_cobros.length})',
                            [
                              if (_cobros.isEmpty)
                                Text(
                                    'Sin cobros en el período.',
                                    style: AppTexto.secundario.copyWith(color: AppColores
                                            .textoSecundario(context))),
                              for (final c in (_verTodosCobros
                                  ? _cobros
                                  : _cobros.take(50)))
                                ListTile(
                                  dense: true,
                                  contentPadding:
                                      EdgeInsets.zero,
                                  title: Text(
                                      '${c['cliente_nombre']}',
                                      style: AppTexto.cuerpo),
                                  subtitle: Text(
                                      '${_etiquetaPeriodo(c)} · ${fmtFecha(c['fecha'])}',
                                      style: AppTexto.metadato),
                                  trailing: Text(
                                      '${fmtMonto((c['monto'] as num).toDouble())} CUP',
                                      style: AppTexto.secundario),
                                  onTap: () {
                                    final cid = c[
                                            'cliente_id']
                                        as int?;
                                    if (cid == null ||
                                        cid == 0) {
                                      return;
                                    }
                                    Navigator.of(context)
                                        .push(
                                            RutaIron(
                                                builder: (_) =>
                                                    FichaScreen(
                                                        clienteId:
                                                            cid)));
                                  },
                                ),
                              if (_cobros.length > 50)
                                Align(
                                  alignment: Alignment.centerLeft,
                                  child: TextButton.icon(
                                    icon: Icon(_verTodosCobros
                                        ? Icons.expand_less_rounded
                                        : Icons.expand_more_rounded),
                                    label: Text(_verTodosCobros
                                        ? 'Ver menos'
                                        : 'Ver todos (${_cobros.length})'),
                                    onPressed: () => setState(() =>
                                        _verTodosCobros =
                                            !_verTodosCobros),
                                  ),
                                ),
                            ]),
                        // Inscripciones (idea 4)
                        _seccion(Icons.person_add_rounded, 'Inscripciones (${_inscripciones.length})',
                            [
                              if (_inscripciones.isEmpty)
                                Text(
                                    'Sin inscripciones en el período.',
                                    style: AppTexto.secundario.copyWith(color: AppColores
                                            .textoSecundario(context))),
                              for (final ins
                                  in _inscripciones)
                                ListTile(
                                  dense: true,
                                  contentPadding:
                                      EdgeInsets.zero,
                                  title: Text(
                                      '${ins['nombre']}',
                                      style: AppTexto.cuerpo),
                                  subtitle: Text(
                                      fmtFecha(
                                          ins['fecha']),
                                      style: AppTexto.metadato),
                                  trailing: Icon(
                                      Icons.chevron_right_rounded,
                                      size: 18,
                                      color: AppColores
                                          .textoSecundario(context)),
                                  onTap: () {
                                    final cid = ins[
                                            'cliente_id']
                                        as int?;
                                    if (cid == null ||
                                        cid == 0) {
                                      return;
                                    }
                                    Navigator.of(context)
                                        .push(
                                            RutaIron(
                                                builder: (_) =>
                                                    FichaScreen(
                                                        clienteId:
                                                            cid)));
                                  },
                                ),
                            ]),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _seccion(IconData icono, String titulo, List<Widget> hijos) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppEspacio.md),
      child: Tarjeta(
        padding: const EdgeInsets.all(AppEspacio.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icono,
                    size: 18, color: AppColores.textoSecundario(context)),
                const SizedBox(width: 8),
                Text(titulo, style: AppTexto.subtitulo),
              ],
            ),
            const SizedBox(height: 8),
            ...hijos,
          ],
        ),
      ),
    );
  }

  Widget _tarjeta(
      String titulo, String valor, String subtitulo) {
    return Tarjeta(
      padding: const EdgeInsets.all(AppEspacio.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(titulo,
              style: AppTexto.minuscula.copyWith(
                  color: AppColores.textoSecundario(context))),
          const SizedBox(height: 4),
          Text(valor,
              style: AppTexto.titulo),
          Text(subtitulo,
              style: AppTexto.minuscula.copyWith(
                  color: AppColores.textoSecundario(context))),
        ],
      ),
    );
  }

  Widget _filaComparativa(
      String etiqueta, double anterior, double actual) {
    final dif = actual - anterior;
    final pct = anterior > 0 ? (dif / anterior * 100) : 0.0;
    final sube = dif >= 0;
    return Row(
      children: [
        Expanded(
            child: Text(etiqueta,
                style: AppTexto.secundario)),
        Text(
          '${sube ? '↑' : '↓'} ${pct.abs().toStringAsFixed(0)}%',
          style: AppTexto.cuerpo.copyWith(color: sube
                  ? AppColores.exito
                  : AppColores.error, fontWeight: FontWeight.bold),
        ),
        const SizedBox(width: 8),
        Text('${fmtMonto(anterior)} → ${fmtMonto(actual)}',
            style: AppTexto.metadato.copyWith(color: AppColores.textoSecundario(context))),
      ],
    );
  }

  /// Delegada en la función pública de negocio.dart (misma lógica).
  String _etiquetaPeriodo(Map<String, dynamic> c) =>
      etiquetaPeriodo(c);
}
