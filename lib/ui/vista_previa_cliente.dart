/// Vista previa de la App de Clientes (v1.3.9, F6; rediseño por
/// pestañas en v1.4.4). Solo dueño. Muestra lo mismo que ve el cliente
/// en su app, vía el RPC `preview_datos_cliente` (cero efectos
/// secundarios). Estética cliente: naranja #FF6B00 / grafito #121214.
/// Solo lectura: las acciones (comprar por WhatsApp) se muestran
/// deshabilitadas (condición 5 del veredicto de Argón, 2026-10-21).
library;

import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config.dart';
import 'horario_gym.dart';

/// Resultado del semáforo de membresía (espejo de la lógica de
/// inicio_screen.dart de la app de Clientes, v0.5.2).
class SemaforoVistaPrevia {
  final String titulo;
  final String subtitulo;
  final String badge;
  final Color color;
  const SemaforoVistaPrevia({
    required this.titulo,
    required this.subtitulo,
    required this.badge,
    required this.color,
  });
}

/// Evalúa el estado de la membresía contra la fecha del SERVIDOR
/// (meta.fecha_servidor_cuba de la RPC), nunca contra el reloj local.
/// Réplica fiel de `_evaluarVencimiento` de Clientes.
SemaforoVistaPrevia semaforoVistaPrevia(
    String? pagadoHasta, String? fechaServidor) {
  const rojo = Color(0xFFEF5350);
  const ambar = Color(0xFFFFB300);
  const verde = Color(0xFF66BB6A);
  if (pagadoHasta == null || pagadoHasta.trim().isEmpty) {
    return const SemaforoVistaPrevia(
      titulo: 'SIN FECHA REGISTRADA',
      subtitulo: 'Consulta en recepción el estado actual de tu cuota.',
      badge: 'Pendiente',
      color: ambar,
    );
  }
  final parsed = DateTime.tryParse(pagadoHasta.trim());
  if (parsed == null) {
    return SemaforoVistaPrevia(
      titulo: 'VENCE: $pagadoHasta',
      subtitulo: 'Verifica tu fecha de renovación en recepción.',
      badge: 'Activo',
      color: verde,
    );
  }
  final hoyParsed = DateTime.tryParse(fechaServidor?.trim() ?? '');
  // Panel de código (unánime): NUNCA caer al reloj del teléfono. Sin
  // fecha válida del servidor, el estado no se puede verificar.
  if (hoyParsed == null) {
    return const SemaforoVistaPrevia(
      titulo: 'ESTADO SIN VERIFICAR',
      subtitulo: 'No se pudo obtener la fecha del servidor.',
      badge: 'Pendiente',
      color: ambar,
    );
  }
  final ref = hoyParsed;
  final hoyUtc = DateTime.utc(ref.year, ref.month, ref.day);
  final fechaVencUtc = DateTime.utc(parsed.year, parsed.month, parsed.day);
  final diasRestantes = fechaVencUtc.difference(hoyUtc).inDays;
  if (diasRestantes < 0) {
    final diasVencido = diasRestantes.abs();
    return SemaforoVistaPrevia(
      titulo: 'MEMBRESÍA VENCIDA',
      subtitulo:
          'Tu cuota venció hace $diasVencido ${diasVencido == 1 ? "día" : "días"}. '
          'Renueva en recepción.',
      badge: 'Vencido',
      color: rojo,
    );
  } else if (diasRestantes <= 5) {
    return SemaforoVistaPrevia(
      titulo: diasRestantes == 0 ? 'VENCE HOY' : 'PRÓXIMO A VENCER',
      subtitulo: diasRestantes == 0
          ? 'Hoy es el último día cubierto por tu pago actual.'
          : 'Quedan $diasRestantes ${diasRestantes == 1 ? "día" : "días"} de vigencia en tu mensualidad.',
      badge: diasRestantes == 0
          ? 'Hoy'
          : '$diasRestantes ${diasRestantes == 1 ? "día" : "días"}',
      // Espejo del pedido de Jc (2026-10-21): vence hoy = rojo
      // también en la app de clientes.
      color: diasRestantes == 0 ? rojo : ambar,
    );
  }
  return SemaforoVistaPrevia(
    titulo: 'CUOTA AL DÍA',
    subtitulo:
        'Tienes $diasRestantes días activos disponibles para entrenar.',
    badge: '+$diasRestantes días',
    color: verde,
  );
}

/// Texto tolerante a tipos (panel de código): el JSON de la RPC puede
/// traer num/objetos donde se espera String; nunca lanzar por un cast.
String? textoSeguro(Object? v) => v?.toString();

/// Mapa tolerante a tipos: cualquier cosa que no sea Map → mapa vacío.
Map<String, dynamic> mapaSeguro(Object? v) =>
    v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};

/// Formatea un monto sin el «.0» que ensuciaba la previa: enteros sin
/// decimales; con decimales, hasta 2 y sin ceros de relleno a la derecha.
String formatoMonto(Object? v) {
  if (v == null) return '—';
  final n = v is num ? v.toDouble() : double.tryParse('$v');
  if (n == null) return '$v';
  if (n == n.roundToDouble()) return '${n.toInt()}';
  var s = n.toStringAsFixed(2);
  while (s.endsWith('0')) {
    s = s.substring(0, s.length - 1);
  }
  if (s.endsWith('.')) s = s.substring(0, s.length - 1);
  return s;
}

/// 'YYYY-MM-DD' → 'DD/MM/YYYY' (si no parsea, devuelve el texto tal cual).
String fechaHumana(Object? v) {
  if (v == null) return '—';
  final s = '$v'.trim();
  if (s.isEmpty) return '—';
  final p = DateTime.tryParse(s);
  if (p == null) return s;
  String dos(int x) => x.toString().padLeft(2, '0');
  return '${dos(p.day)}/${dos(p.month)}/${p.year}';
}

class VistaPreviaClienteScreen extends StatefulWidget {
  final int clienteId;
  final String nombreCliente;
  const VistaPreviaClienteScreen({
    super.key,
    required this.clienteId,
    required this.nombreCliente,
  });
  @override
  State<VistaPreviaClienteScreen> createState() =>
      _VistaPreviaClienteScreenState();
}

class _VistaPreviaClienteScreenState
    extends State<VistaPreviaClienteScreen>
    with SingleTickerProviderStateMixin {
  Map<String, dynamic>? _datos;
  bool _cargando = true;
  String? _error;
  // Argón P1#13: horario canónico (no texto fijo): se carga junto a
  // los datos; mientras tanto se muestra el texto anterior.
  String? _horarioCanonico;
  late final TabController _tabs;

  // Colores de la app de clientes.
  static const _naranja = Color(0xFFFF6B00);
  static const _grafito = Color(0xFF121214);
  static const _colorTarjeta = Color(0xFF1E1E20);

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 5, vsync: this);
    _cargar();
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _cargar() async {
    setState(() {
      _cargando = true;
      _error = null;
    });
    // Horario canónico en paralelo al RPC (caché local primero).
    cargarHorarioCanonico().then((dias) {
      final texto = textoHorarioCanonico(dias);
      if (texto.isNotEmpty && mounted) {
        setState(() => _horarioCanonico = texto);
      }
    }).catchError((_) {});
    try {
      final res = await Supabase.instance.client
          .rpc('preview_datos_cliente', params: {
        'p_cliente_id': widget.clienteId,
      });
      final data = Map<String, dynamic>.from(res as Map);
      if (data['status'] != 200) {
        throw '${data['error'] ?? 'Error desconocido'}';
      }
      if (mounted) {
        setState(() {
          _datos = data;
          _cargando = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '$e';
          _cargando = false;
        });
      }
    }
  }

  Map<String, dynamic> get _cliente => mapaSeguro(_datos?['cliente']);
  Map<String, dynamic> get _meta => mapaSeguro(_datos?['meta']);
  List<dynamic> _lista(String clave) {
    final v = _datos?[clave];
    return v is List ? List<dynamic>.from(v) : const [];
  }
  int? _total(String clave) {
    final v = _datos?[clave];
    return v is num ? v.toInt() : null;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _grafito,
      appBar: AppBar(
        title: Text('Vista previa: ${widget.nombreCliente}'),
        backgroundColor: _grafito,
        foregroundColor: Colors.white,
        bottom: _cargando || _error != null
            ? null
            : TabBar(
                controller: _tabs,
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                indicatorColor: _naranja,
                labelColor: _naranja,
                unselectedLabelColor: Colors.white70,
                tabs: const [
                  Tab(text: 'Inicio'),
                  Tab(text: 'Pagos'),
                  Tab(text: 'Suplementos'),
                  Tab(text: 'Plan'),
                  Tab(text: 'Progreso'),
                ],
              ),
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            color: _naranja,
            padding:
                const EdgeInsets.symmetric(vertical: 6, horizontal: 16),
            child: const Text(
              'VISTA PREVIA — lo que ve el cliente en su app',
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w600),
              textAlign: TextAlign.center,
            ),
          ),
          Expanded(
            child: _cargando
                ? const Center(
                    child: CircularProgressIndicator(color: _naranja))
                : _error != null
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(_error!,
                              style:
                                  const TextStyle(color: Colors.white70),
                              textAlign: TextAlign.center),
                        ),
                      )
                    : TabBarView(
                        controller: _tabs,
                        children: [
                          _tabInicio(),
                          _tabPagos(),
                          _tabSuplementos(),
                          _tabPlan(),
                          _tabProgreso(),
                        ],
                      ),
          ),
        ],
      ),
    );
  }

  // ---------------- Inicio ----------------

  Widget _tabInicio() {
    final c = _cliente;
    final nombre = '${c['nombre'] ?? widget.nombreCliente}';
    final plan = '${c['plan'] ?? ''}'.trim();
    final semaforo = semaforoVistaPrevia(
      textoSeguro(c['pagado_hasta']),
      textoSeguro(_meta['fecha_servidor_cuba']),
    );
    final turno = mapaSeguro(_meta['entrenador_turno']);
    final abierto = _meta['gimnasio_abierto_horario'] == true;
    final totalPagos = _total('total_pagos') ?? _lista('historial_pagos').length;
    final totalCompras =
        _total('total_compras') ?? _lista('historial_compras').length;
    final totalMed = _total('total_mediciones') ??
        _lista('progreso_mediciones').length;
    final totalMarcas =
        _total('total_registros_marcas') ?? _registrosMarcas().length;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _tarjeta([
          Row(
            children: [
              _foto(textoSeguro(c['foto_storage']),
                  size: 64, nombre: nombre, circular: true),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(nombre,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.bold)),
                    if (plan.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      _chip('Plan: $plan', _naranja),
                    ],
                    const SizedBox(height: 4),
                    Text('Estado: ${c['estado'] ?? '—'}',
                        style: const TextStyle(
                            color: Colors.white70, fontSize: 13)),
                  ],
                ),
              ),
            ],
          ),
        ]),
        // Semáforo de membresía (espejo de Clientes).
        Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: semaforo.color.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
                color: semaforo.color.withValues(alpha: 0.55)),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(semaforo.titulo,
                        style: TextStyle(
                            color: semaforo.color,
                            fontSize: 16,
                            fontWeight: FontWeight.bold)),
                    const SizedBox(height: 2),
                    Text(semaforo.subtitulo,
                        style: const TextStyle(
                            color: Colors.white70, fontSize: 13)),
                  ],
                ),
              ),
              _chip(semaforo.badge, semaforo.color),
            ],
          ),
        ),
        // Entrenador de turno: abierto por horario ≠ entrenador asignado.
        _tarjeta([
          const Text('ENTRENADOR DE TURNO HOY',
              style: TextStyle(
                  color: _naranja,
                  fontSize: 12,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          if (turno.isNotEmpty) ...[
            Text('${turno['entrenador_nombre'] ?? '—'}',
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w600)),
            Text(
                'Turno: ${_turnoLegible(turno['turno'])}'
                '${(turno['hora_apertura'] ?? '').toString().isNotEmpty ? ' · desde ${turno['hora_apertura']}' : ''}',
                style: const TextStyle(
                    color: Colors.white70, fontSize: 13)),
          ] else if (abierto)
            const Text('Sin entrenador asignado',
                style: TextStyle(color: Colors.white))
          else
            const Text('Gimnasio cerrado por horario',
                style: TextStyle(color: Colors.white)),
          const SizedBox(height: 4),
          Text(
              'Horario: ${_horarioCanonico ?? 'L–V 6:00–12:00 y 14:00–20:00 · Sáb 7:00–12:00 · Dom cerrado'}',
              style: const TextStyle(color: Colors.white54, fontSize: 12)),
        ]),
        // Resumen rápido.
        _tituloSeccion('Resumen rápido'),
        _tarjeta([
          _fila('Pagos registrados', '$totalPagos'),
          _fila('Compras de suplementos', '$totalCompras'),
          _fila('Mediciones de progreso', '$totalMed'),
          _fila('Registros de marcas', '$totalMarcas'),
        ]),
      ],
    );
  }

  String _turnoLegible(Object? t) {
    final s = '${t ?? ''}'.toLowerCase();
    if (s.contains('tarde')) return 'Tarde';
    if (s.contains('ma')) return 'Mañana';
    return s.isEmpty ? '—' : '$t';
  }

  // ---------------- Pagos ----------------

  Widget _tabPagos() {
    final pagos = _lista('historial_pagos');
    final total = _total('total_pagos');
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _tarjeta([
          _fila('Mensualidad',
              '${formatoMonto(_cliente['monto_mensualidad'])} CUP',
              destacado: true),
          _fila('Pagado hasta', fechaHumana(_cliente['pagado_hasta'])),
        ]),
        _tituloSeccion('Historial de pagos'),
        if (total != null && total > pagos.length)
          _rotuloCorte(pagos.length, total),
        if (pagos.isEmpty)
          const Text('Sin pagos registrados',
              style: TextStyle(color: Colors.white70))
        else
          for (final p in pagos)
            _tarjeta([
              Text(
                  '${fechaHumana(p['fecha'])} · ${formatoMonto(p['monto'])} CUP',
                  style: const TextStyle(color: Colors.white)),
              Text(
                  [p['periodo'], p['metodo']]
                      .where((x) => '${x ?? ''}'.isNotEmpty)
                      .join(' · '),
                  style: const TextStyle(
                      color: Colors.white70, fontSize: 13)),
            ]),
      ],
    );
  }

  // ---------------- Suplementos ----------------

  Widget _tabSuplementos() {
    final catalogo = _lista('catalogo_suplementos');
    final compras = _lista('historial_compras');
    final totalCompras = _total('total_compras');
    final nombresPorId = <int, String>{
      for (final s in catalogo)
        if (s['id'] is num) (s['id'] as num).toInt(): '${s['nombre'] ?? ''}',
    };
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _tituloSeccion('Catálogo (${catalogo.length})'),
        const Padding(
          padding: EdgeInsets.only(bottom: 8),
          child: Text('Vista previa: las acciones están deshabilitadas',
              style: TextStyle(color: Colors.white54, fontSize: 12)),
        ),
        for (final s in catalogo)
          _tarjeta([
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _foto(textoSeguro(s['foto_storage']),
                    size: 64, nombre: '${s['nombre'] ?? ''}'),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text('${s['nombre'] ?? ''}',
                                style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w600)),
                          ),
                          _chipDisponibilidad(
                              '${s['disponibilidad'] ?? ''}'),
                        ],
                      ),
                      if ('${s['descripcion'] ?? ''}'.isNotEmpty)
                        Text('${s['descripcion']}',
                            style: const TextStyle(
                                color: Colors.white70, fontSize: 13)),
                      if (_presentacion(s) != null)
                        Text(_presentacion(s)!,
                            style: const TextStyle(
                                color: Colors.white70, fontSize: 13)),
                      Text(
                          'Precio oficial: \$${formatoMonto(s['precio_oficial'])}',
                          style: const TextStyle(
                              color: _naranja,
                              fontWeight: FontWeight.w600)),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            // Condición 5: visible por fidelidad, deshabilitado.
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: null,
                icon: const Icon(Icons.chat_bubble_outline, size: 16),
                label: const Text('Comprar por WhatsApp'),
              ),
            ),
          ]),
        const SizedBox(height: 8),
        _tituloSeccion('Compras del cliente'),
        if (totalCompras != null && totalCompras > compras.length)
          _rotuloCorte(compras.length, totalCompras),
        if (compras.isEmpty)
          const Text('Sin compras registradas',
              style: TextStyle(color: Colors.white70))
        else
          for (final vc in compras)
            _tarjeta([
              Text(
                  '${fechaHumana(vc['fecha'])} · ${formatoMonto(vc['cantidad'])}x · ${formatoMonto(vc['precio'])} ${vc['moneda'] ?? ''}',
                  style: const TextStyle(color: Colors.white)),
              if (nombresPorId[vc['suplemento_id']] != null)
                Text(nombresPorId[vc['suplemento_id']]!,
                    style: const TextStyle(
                        color: Colors.white70, fontSize: 13)),
            ]),
      ],
    );
  }

  String? _presentacion(Map<dynamic, dynamic> s) {
    final partes = <String>[];
    final pv = s['peso_valor'];
    final pu = '${s['peso_unidad'] ?? ''}'.trim();
    if (pv != null) {
      partes.add(pu.isEmpty ? formatoMonto(pv) : '${formatoMonto(pv)} $pu');
    }
    final sv = s['servicios_estandar'];
    if (sv != null) partes.add('${formatoMonto(sv)} servicios');
    return partes.isEmpty ? null : partes.join(' · ');
  }

  // ---------------- Plan ----------------

  Widget _tabPlan() {
    final planCrudo = _datos?['plan_nutricional'];
    final plan = planCrudo == null ? null : mapaSeguro(planCrudo);
    if (plan == null) {
      return const Center(
        child: Text('Sin plan asignado',
            style: TextStyle(color: Colors.white70)),
      );
    }
    final detalle = '${plan['detalle'] ?? ''}';
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _tarjeta([
          Text('Objetivo: ${plan['objetivo'] ?? '—'}',
              style: const TextStyle(
                  color: Colors.white, fontWeight: FontWeight.w600)),
          Text('Actualizado: ${plan['actualizado_en'] ?? '—'}',
              style: const TextStyle(
                  color: Colors.white70, fontSize: 13)),
        ]),
        if (detalle.isNotEmpty)
          _tarjeta([
            MarkdownBody(
              data: detalle,
              styleSheet: MarkdownStyleSheet(
                p: const TextStyle(
                    color: Colors.white70, fontSize: 14, height: 1.4),
                h1: const TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.bold),
                h2: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold),
                h3: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.bold),
                strong: const TextStyle(
                    color: Colors.white, fontWeight: FontWeight.bold),
                listBullet: const TextStyle(color: Colors.white70),
              ),
            ),
          ]),
      ],
    );
  }

  // ---------------- Progreso ----------------

  List<dynamic> _registrosMarcas() {
    final m = mapaSeguro(_datos?['marcas']);
    final regs = m['registros'];
    return regs is List ? List<dynamic>.from(regs) : const [];
  }

  Widget _tabProgreso() {
    final mediciones = _lista('progreso_mediciones');
    final totalMed = _total('total_mediciones');
    final marcas = mapaSeguro(_datos?['marcas']);
    final recordsCrudos = marcas['records'];
    final records = recordsCrudos is List
        ? List<dynamic>.from(recordsCrudos)
        : const <dynamic>[];
    final registros = _registrosMarcas();
    final totalReg = _total('total_registros_marcas');
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _tituloSeccion('Mediciones'),
        if (totalMed != null && totalMed > mediciones.length)
          _rotuloCorte(mediciones.length, totalMed),
        if (mediciones.isEmpty)
          const Text('Sin mediciones registradas',
              style: TextStyle(color: Colors.white70))
        else ...[
          _tarjetaMedicion(mediciones.first, destacada: true),
          for (final m in mediciones.skip(1)) _tarjetaMedicion(m),
        ],
        const SizedBox(height: 8),
        _tituloSeccion('Marcas — récords'),
        if (records.isEmpty)
          const Text('Sin marcas registradas',
              style: TextStyle(color: Colors.white70))
        else
          for (final r in records)
            _tarjeta([
              Row(
                children: [
                  const Icon(Icons.emoji_events,
                      color: _naranja, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                        '${r['ejercicio_nombre'] ?? 'Ejercicio #${r['ejercicio_id'] ?? '—'}'}',
                        style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w600)),
                  ),
                  Text('${formatoMonto(r['peso'])} kg',
                      style: const TextStyle(
                          color: _naranja, fontWeight: FontWeight.bold)),
                ],
              ),
              Text(fechaHumana(r['fecha']),
                  style: const TextStyle(
                      color: Colors.white70, fontSize: 13)),
            ]),
        if (registros.isNotEmpty) ...[
          const SizedBox(height: 8),
          _tituloSeccion('Historial de marcas'),
          if (totalReg != null && totalReg > registros.length)
            _rotuloCorte(registros.length, totalReg),
          for (final r in registros)
            _tarjeta([
              Text(
                  '${r['ejercicio_nombre'] ?? 'Ejercicio #${r['ejercicio_id'] ?? '—'}'} · ${formatoMonto(r['peso'])} kg',
                  style: const TextStyle(color: Colors.white)),
              Text(fechaHumana(r['fecha']),
                  style: const TextStyle(
                      color: Colors.white70, fontSize: 13)),
            ]),
        ],
      ],
    );
  }

  Widget _tarjetaMedicion(dynamic m, {bool destacada = false}) {
    final medidas = <String>[
      if (m['peso_kg'] != null) 'Peso ${formatoMonto(m['peso_kg'])} kg',
      if (m['grasa_pct'] != null) 'Grasa ${formatoMonto(m['grasa_pct'])} %',
      if (m['pecho_cm'] != null) 'Pecho ${formatoMonto(m['pecho_cm'])} cm',
      if (m['brazo_cm'] != null) 'Brazo ${formatoMonto(m['brazo_cm'])} cm',
      if (m['cintura_cm'] != null)
        'Cintura ${formatoMonto(m['cintura_cm'])} cm',
      if (m['cadera_cm'] != null)
        'Cadera ${formatoMonto(m['cadera_cm'])} cm',
      if (m['muslo_cm'] != null) 'Muslo ${formatoMonto(m['muslo_cm'])} cm',
    ];
    return _tarjeta([
      Row(
        children: [
          Expanded(
            child: Text(fechaHumana(m['fecha']),
                style: TextStyle(
                    color: Colors.white,
                    fontWeight:
                        destacada ? FontWeight.bold : FontWeight.normal)),
          ),
          if (destacada) _chip('Última', _naranja),
        ],
      ),
      if (medidas.isNotEmpty)
        Text(medidas.join(' · '),
            style:
                const TextStyle(color: Colors.white70, fontSize: 13)),
      if ('${m['notas'] ?? ''}'.isNotEmpty)
        Text('${m['notas']}',
            style:
                const TextStyle(color: Colors.white54, fontSize: 13)),
    ]);
  }

  // ---------------- Piezas comunes ----------------

  Widget _rotuloCorte(int mostrados, int total) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text('Mostrando últimos $mostrados de $total',
          style: const TextStyle(color: Colors.white54, fontSize: 12)),
    );
  }

  Widget _foto(String? ref,
      {required double size,
      required String nombre,
      bool circular = false}) {
    final radio = circular ? size / 2 : 12.0;
    Widget fallback = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: _naranja.withValues(alpha: 0.25),
        borderRadius: BorderRadius.circular(radio),
      ),
      alignment: Alignment.center,
      child: Text(_iniciales(nombre),
          style: TextStyle(
              color: _naranja,
              fontWeight: FontWeight.bold,
              fontSize: size * 0.36)),
    );
    if (ref == null || ref.isEmpty) return fallback;
    // Panel de código: URL vía el SDK de Storage (codifica la ruta;
    // la concatenación manual rompía con espacios/#/? en el nombre).
    final ruta = ref.startsWith('/') ? ref.substring(1) : ref;
    final url = Supabase.instance.client.storage
        .from(AppConfig.bucketFotos)
        .getPublicUrl(ruta);
    return ClipRRect(
      borderRadius: BorderRadius.circular(radio),
      child: Image.network(
        url,
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => fallback,
        loadingBuilder: (context, child, progress) =>
            progress == null ? child : fallback,
      ),
    );
  }

  String _iniciales(String nombre) {
    final partes = nombre.trim().split(RegExp(r'\s+'));
    if (partes.isEmpty || partes.first.isEmpty) return 'IB';
    if (partes.length == 1) return partes.first[0].toUpperCase();
    return '${partes[0][0]}${partes[1][0]}'.toUpperCase();
  }

  Widget _tituloSeccion(String t) {
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 8),
      child: Text(t,
          style: const TextStyle(
              color: _naranja,
              fontSize: 16,
              fontWeight: FontWeight.bold)),
    );
  }

  Widget _tarjeta(List<Widget> hijos) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _colorTarjeta,
        borderRadius: BorderRadius.circular(12),
        border:
            Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: hijos,
      ),
    );
  }

  Widget _fila(String etiqueta, String valor, {bool destacado = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Text('$etiqueta: ',
              style:
                  const TextStyle(color: Colors.white70, fontSize: 14)),
          Expanded(
            child: Text(valor,
                style: TextStyle(
                    color: destacado ? _naranja : Colors.white,
                    fontSize: 14,
                    fontWeight: destacado
                        ? FontWeight.bold
                        : FontWeight.normal)),
          ),
        ],
      ),
    );
  }

  Widget _chip(String texto, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Text(texto, style: TextStyle(color: color, fontSize: 11)),
    );
  }

  Widget _chipDisponibilidad(String disp) {
    final color = disp == 'Disponible'
        ? Colors.green
        : disp == 'Últimas unidades'
            ? Colors.amber
            : Colors.red;
    return _chip(disp, color);
  }
}
