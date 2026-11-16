/// Vista previa de la App de Clientes (v1.3.9, F6; rediseño por
/// pestañas en v1.4.4). Solo dueño. Muestra lo mismo que ve el cliente
/// en su app, vía el RPC `preview_datos_cliente` (cero efectos
/// secundarios). Estética cliente: naranja de marca
/// #E8821A / grafito #121214 (1.35, UI-18: antes un
/// naranja viejo #FF6B00 que no era el de la marca).
/// Solo lectura: las acciones (comprar por WhatsApp) se muestran
/// deshabilitadas (condición 5 del veredicto de Argón, 2026-10-21).
library;

import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../auth.dart';
import '../config.dart';
import '../errores_sync.dart' show mensajeErrorAmable;
import '../negocio.dart' show clientePorId, esCuentaCasa;
import 'diseno.dart';
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
    String? pagadoHasta, String? fechaServidor,
    {bool esCasa = false}) {
  const rojo = Color(0xFFEF5350);
  const ambar = Color(0xFFFFB300);
  const verde = Color(0xFF66BB6A);
  // 1.28 (M4-A10/R1M4-M6): la Cuenta a la Casa NO vence —
  // la app de Clientes real la respeta y esta vista previa
  // enseñaba «MEMBRESÍA VENCIDA» o «SIN FECHA REGISTRADA»
  // de un cliente de la casa. Dorado, como en el resto de
  // la casa.
  if (esCasa) {
    return const SemaforoVistaPrevia(
      titulo: 'CUENTA A LA CASA',
      subtitulo: 'Cliente de la casa: su membresía no vence.',
      badge: 'Casa',
      color: Color(0xFFB8860B),
    );
  }
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
    // Argón Clientes #11: una fecha ILEGIBLE no es «Activo»
    // (en el resto de la app una fecha no parseable cuenta
    // como vencido/pendiente). Verde aquí mentía al cliente.
    return SemaforoVistaPrevia(
      titulo: 'VENCE: $pagadoHasta',
      subtitulo: 'Verifica tu fecha de renovación en recepción.',
      badge: 'Pendiente',
      color: ambar,
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

/// SL-2 G03-8: traductor del estado del espejo para la
/// vista previa. Una clave desconocida (la que el servidor
/// añada mañana) NO se pinta cruda: se lee «Sin verificar».
String etiquetaEstadoVistaPrevia(Object? estado) => switch ('$estado') {
      'activo' => 'Activo',
      'congelado' => 'Congelado',
      'inactivo' => 'Inactivo',
      _ => 'Sin verificar',
    };

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
  // 1.28 (M4-A10): foto LOCAL del cliente (espejo) para la
  // primera pintura y para saber si es Cuenta a la Casa sin
  // depender de que la RPC lo traiga.
  Map<String, dynamic>? _clienteLocal;
  // Argón P1#13: horario canónico (no texto fijo): se carga junto a
  // los datos; mientras tanto se muestra el texto anterior.
  String? _horarioCanonico;
  late final TabController _tabs;

  // Colores de la app de clientes.
  // 1.35 (UI-18): el naranja de marca, desde el token.
  static const _naranja = AppColores.naranja;
  // 1.35 (UX-07): la superficie espejo habla los
  // tokens de la plantilla (antes literales propios
  // #121214/#1E1E20 fuera de la fundación).
  static const _grafito = AppColores.pizarra;
  static const _colorTarjeta = AppColores.grafitoTactico;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 5, vsync: this);
    _leerEspejoLocal();
    _cargar();
  }

  /// 1.28 (M4-A10/R1M4-B3): lectura local inmediata — la
  /// vista previa pintaba SOLO un spinner hasta que la RPC
  /// volvía (hasta 12 s sin red para ver un nombre que el
  /// teléfono ya tiene). El espejo da la primera pintura; la
  /// RPC la sustituye al llegar.
  Future<void> _leerEspejoLocal() async {
    try {
      final c = await clientePorId(widget.clienteId);
      if (c != null && mounted) {
        setState(() => _clienteLocal = c);
      }
    } catch (_) {}
  }

  /// ¿Cuenta a la Casa? Manda la RPC si lo trae; si no, el
  /// espejo local (que siempre lo trae).
  bool get _esCasa {
    if (_cliente['cuenta_casa'] == true ||
        _cliente['cuenta_casa'] == 1) {
      return true;
    }
    final local = _clienteLocal;
    return local != null && esCuentaCasa(local);
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _cargar() async {
    // Autoauditoría 1.22 #2 (P-2): la pantalla se declara
    // «Solo dueño» en su cabecera pero NO tenía guarda alguna:
    // el botón de la ficha se muestra a todos y cualquier
    // sesión que llegara aquí invocaba el RPC de vista previa.
    // Guarda fail-closed en el método (patrón ficha_acceso).
    if (!AuthService().isOwner) {
      setState(() {
        _error = 'Solo el dueño puede ver la vista previa '
            'de la app del cliente.';
        _cargando = false;
      });
      return;
    }
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
      // Autoauditoría 1.22 #2: lectura con timeout (12 s): sin
      // tope, una conexión colgada dejaba la vista previa en
      // «cargando» eterno (un cuelgue no es un error).
      final res = await Supabase.instance.client
          .rpc('preview_datos_cliente', params: {
            'p_cliente_id': widget.clienteId,
          })
          .timeout(const Duration(seconds: 12));
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
          // 1.25 T20: mensaje en sencillo + reintento.
          // SL-2 G03-8: la excepción cruda NO se pinta ni
          // como detalle: el texto sale del traductor
          // amable de la casa, que solo afirma «sin
          // conexión» cuando la causa es de red.
          _error = mensajeErrorAmable(e,
              enTimeout:
                  'Sin respuesta del servidor al pedir la vista previa.');
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
                // Yunque 2.34 (F-1): el indicador viene del
                // tabBarTheme de la marca; las etiquetas se
                // quedan aquí porque esta barra vive sobre
                // grafito (superficie propia de la vista
                // previa). Yunque 4 (L3-2): también la ACTIVA
                // — la del tema se resuelve por brillo y en
                // tema claro cae a naranjaTexto (3,73:1 sobre
                // este grafito fijo); sobre grafito manda el
                // naranja de marca local (6,81:1).
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
          // 1.25 T117 (F1-76): la franja solo vive en la
          // pestaña Inicio; antes ocupaba alto en las 5
          // pestañas repitiendo lo que el título ya dice.
          AnimatedBuilder(
            animation: _tabs,
            builder: (context, _) => _tabs.index == 0
                ? Container(
                    width: double.infinity,
                    color: _naranja,
                    padding: const EdgeInsets.symmetric(
                        vertical: AppEspacio.sm,
                        horizontal: AppEspacio.lg),
                    child: Text(
                      'VISTA PREVIA — lo que ve el cliente en su app',
                      style: AppTexto.metadato.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.w600),
                      textAlign: TextAlign.center,
                    ),
                  )
                : const SizedBox.shrink(),
          ),
          // 1.25 T62: el contenido vive dentro de una
          // silueta de teléfono (marco, notch y sombra):
          // de un vistazo se distingue «esto es el
          // teléfono del cliente» de la app de gestión.
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(AppEspacio.md),
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(36),
                  border: Border.all(
                      color: Colors.white24, width: 3),
                  boxShadow: const [
                    BoxShadow(
                        color: Colors.black54,
                        blurRadius: 18,
                        offset: Offset(0, 6)),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(33),
                  child: Column(
                    children: [
                      // El notch: pastilla centrada sobre el
                      // fondo grafito de la «pantalla».
                      Container(
                        color: _grafito,
                        padding: const EdgeInsets.only(
                            top: AppEspacio.sm,
                            bottom: AppEspacio.xs),
                        alignment: Alignment.center,
                        child: Container(
                          width: 96,
                          height: 18,
                          decoration: BoxDecoration(
                            color: Colors.black,
                            borderRadius:
                                BorderRadius.circular(9),
                          ),
                        ),
                      ),
                      Expanded(
                        child: _contenidoTelefono(),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _contenidoTelefono() {
    // 1.28 (M4-A10/R1M4-B3): con la foto local ya leída, la
    // primera pintura enseña el nombre (y la Casa, que no
    // necesita fecha del servidor) mientras la RPC resuelve;
    // sin foto local, el spinner de siempre.
    if (_cargando && _clienteLocal != null) {
      final semaforo = semaforoVistaPrevia(null, null, esCasa: _esCasa);
      return ListView(
        padding: const EdgeInsets.all(AppEspacio.lg),
        children: [
          Text(
              '${_clienteLocal!['nombre'] ?? widget.nombreCliente}',
              style: AppTexto.titulo.copyWith(color: Colors.white)),
          const SizedBox(height: AppEspacio.md),
          if (_esCasa)
            Container(
              padding: const EdgeInsets.all(AppEspacio.md),
              decoration: BoxDecoration(
                color: semaforo.color.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(AppRadio.md),
                border: Border.all(color: semaforo.color),
              ),
              child: Text(
                '${semaforo.titulo} · ${semaforo.subtitulo}',
                style: const TextStyle(color: Colors.white70),
              ),
            )
          else
            const Row(
              children: [
                SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                      color: _naranja, strokeWidth: 2),
                ),
                SizedBox(width: AppEspacio.sm),
                Text('Verificando el estado con el servidor…',
                    style: TextStyle(color: Colors.white54)),
              ],
            ),
        ],
      );
    }
    return _cargando
                ? const Center(
                    child: CircularProgressIndicator(color: _naranja))
                : _error != null
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(AppEspacio.xl),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                  Icons.cloud_off_rounded,
                                  size: 44,
                                  color: Colors.white38),
                              const SizedBox(
                                  height: AppEspacio.md),
                              Text(_error!,
                                  style: const TextStyle(
                                      color: Colors.white70),
                                  textAlign: TextAlign.center),
                              // SL-2 G03-8: el detalle crudo de
                              // la excepción NO se pinta (queda
                              // solo el mensaje amable de _error).
                              const SizedBox(
                                  height: AppEspacio.lg),
                              OutlinedButton.icon(
                                icon: const Icon(
                                    Icons.refresh_rounded,
                                    size: 18),
                                label: const Text('Reintentar'),
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: _naranja,
                                  side: const BorderSide(
                                      color: _naranja),
                                ),
                                onPressed: _cargar,
                              ),
                            ],
                          ),
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
      esCasa: _esCasa,
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
      padding: const EdgeInsets.all(AppEspacio.lg),
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
                        style: AppTexto.titulo.copyWith(color: Colors.white)),
                    if (plan.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      _chip('Plan: $plan', _naranja),
                    ],
                    const SizedBox(height: 4),
                    Text('Estado: ${etiquetaEstadoVistaPrevia(c['estado'])}',
                        style: AppTexto.secundario.copyWith(color: Colors.white70)),
                  ],
                ),
              ),
            ],
          ),
        ]),
        // Semáforo de membresía (espejo de Clientes).
        Container(
          margin: const EdgeInsets.only(bottom: AppEspacio.sm),
          padding: const EdgeInsets.all(AppEspacio.md),
          decoration: BoxDecoration(
            color: semaforo.color.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(AppRadio.md),
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
                        style: AppTexto.titulo.copyWith(color: semaforo.color)),
                    const SizedBox(height: 2),
                    Text(semaforo.subtitulo,
                        style: AppTexto.secundario.copyWith(color: Colors.white70)),
                  ],
                ),
              ),
              _chip(semaforo.badge, semaforo.color),
            ],
          ),
        ),
        // 1.25 T117 (F1-76): los umbrales de aviso no coinciden
        // a propósito (la app del cliente avisa a los 5 días y
        // Gestión a los 7): se dice en la propia vista para que
        // la diferencia no se lea como un error.
        Padding(
          padding: const EdgeInsets.only(bottom: AppEspacio.sm),
          child: Text(
              'Nota: en la app del cliente el aviso de vencimiento '
              'sale a los 5 días; en Gestión, a los 7.',
              style:
                  AppTexto.metadato.copyWith(color: Colors.white38)),
        ),
        // Entrenador de turno: abierto por horario ≠ entrenador asignado.
        _tarjeta([
          Text('ENTRENADOR DE TURNO HOY',
              style: AppTexto.metadato.copyWith(color: _naranja, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          if (turno.isNotEmpty) ...[
            Text('${turno['entrenador_nombre'] ?? '—'}',
                style: AppTexto.titulo.copyWith(color: Colors.white, fontWeight: FontWeight.w600)),
            Text(
                'Turno: ${_turnoLegible(turno['turno'])}'
                '${(turno['hora_apertura'] ?? '').toString().isNotEmpty ? ' · desde ${turno['hora_apertura']}' : ''}',
                style: AppTexto.secundario.copyWith(color: Colors.white70)),
          ] else if (abierto)
            const Text('Sin entrenador asignado',
                style: TextStyle(color: Colors.white))
          else
            const Text('Gimnasio cerrado por horario',
                style: TextStyle(color: Colors.white)),
          const SizedBox(height: 4),
          Text(
              // 1.25 T117 (F1-70): si el horario canónico no
              // cargó, el de respaldo se marca «sin confirmar»:
              // no es el horario verificado del gym.
              'Horario: ${_horarioCanonico ?? 'L–V 6:00–12:00 y 14:00–20:00 · Sáb 7:00–12:00 · Dom cerrado (sin confirmar)'}',
              style: AppTexto.metadato.copyWith(color: Colors.white54)),
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
      padding: const EdgeInsets.all(AppEspacio.lg),
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
          _vacioOscuro(Icons.receipt_long_rounded,
              'Sin pagos registrados',
              'En su app, esta lista saldría vacía.')
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
                  style: AppTexto.secundario.copyWith(color: Colors.white70)),
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
      padding: const EdgeInsets.all(AppEspacio.lg),
      children: [
        _tituloSeccion('Catálogo (${catalogo.length})'),
        Padding(
          padding: EdgeInsets.only(bottom: AppEspacio.sm),
          child: Text('Vista previa: las acciones están deshabilitadas',
              style: AppTexto.metadato.copyWith(color: Colors.white54)),
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
                            style: AppTexto.secundario.copyWith(color: Colors.white70)),
                      if (_presentacion(s) != null)
                        Text(_presentacion(s)!,
                            style: AppTexto.secundario.copyWith(color: Colors.white70)),
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
            // Condición 5: visible por fidelidad. F15 (1.20):
            // ya no es un botón MUERTO — al tocarlo explica
            // qué hace en la app del cliente; la vista previa
            // no envía WhatsApp reales desde el teléfono del
            // dueño.
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () => _explicarCompraWhatsApp(s),
                icon: const Icon(Icons.chat_bubble_outline_rounded, size: 16),
                label: const Text('Comprar por WhatsApp'),
              ),
            ),
          ]),
        const SizedBox(height: 8),
        _tituloSeccion('Compras del cliente'),
        if (totalCompras != null && totalCompras > compras.length)
          _rotuloCorte(compras.length, totalCompras),
        if (compras.isEmpty)
          _vacioOscuro(Icons.shopping_bag_rounded,
              'Sin compras registradas',
              'En su app, esta lista saldría vacía.')
        else
          for (final vc in compras)
            _tarjeta([
              Text(
                  '${fechaHumana(vc['fecha'])} · ${formatoMonto(vc['cantidad'])}x · ${formatoMonto(vc['precio'])} ${vc['moneda'] ?? ''}',
                  style: const TextStyle(color: Colors.white)),
              if (nombresPorId[vc['suplemento_id']] != null)
                Text(nombresPorId[vc['suplemento_id']]!,
                    style: AppTexto.secundario.copyWith(color: Colors.white70)),
            ]),
      ],
    );
  }

  /// F15: qué hace «Comprar por WhatsApp» en la app del
  /// cliente (en esta vista previa no se envía nada).
  void _explicarCompraWhatsApp(Map<dynamic, dynamic> s) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Vista previa'),
        content: Text(
            'En la app del cliente, este botón abre su WhatsApp '
            'con el pedido ya escrito al número del gym '
            '(58191577):\n\n'
            '«Hola, quiero comprar: ${s['nombre'] ?? 'este producto'} '
            '(\$${formatoMonto(s['precio_oficial'])})»\n\n'
            'Aquí es solo una muestra: no se envía ningún mensaje.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Entendido'),
          ),
        ],
      ),
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
      return Center(
        child: _vacioOscuro(Icons.restaurant_menu_rounded,
            'Sin plan asignado',
            'En su app, aquí iría su plan nutricional.'),
      );
    }
    final detalle = '${plan['detalle'] ?? ''}';
    return ListView(
      padding: const EdgeInsets.all(AppEspacio.lg),
      children: [
        _tarjeta([
          Text('Objetivo: ${plan['objetivo'] ?? '—'}',
              style: const TextStyle(
                  color: Colors.white, fontWeight: FontWeight.w600)),
          // 1.25 T117 (F1-71): fecha legible, no el ISO crudo.
          Text('Actualizado: ${fechaHumana(plan['actualizado_en'])}',
              style: AppTexto.secundario.copyWith(color: Colors.white70)),
        ]),
        if (detalle.isNotEmpty)
          _tarjeta([
            MarkdownBody(
              data: detalle,
              styleSheet: MarkdownStyleSheet(
                p: AppTexto.cuerpo.copyWith(
                    color: Colors.white70, height: 1.4),
                h1: AppTexto.tituloPagina.copyWith(color: Colors.white),
                h2: AppTexto.titulo.copyWith(color: Colors.white),
                h3: AppTexto.titulo.copyWith(color: Colors.white),
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
      padding: const EdgeInsets.all(AppEspacio.lg),
      children: [
        _tituloSeccion('Mediciones'),
        if (totalMed != null && totalMed > mediciones.length)
          _rotuloCorte(mediciones.length, totalMed),
        if (mediciones.isEmpty)
          _vacioOscuro(Icons.monitor_weight_rounded,
              'Sin mediciones registradas',
              'En su app, esta lista saldría vacía.')
        else ...[
          _tarjetaMedicion(mediciones.first,
              destacada: true,
              anterior:
                  mediciones.length > 1 ? mediciones[1] : null),
          // 1.25 T63: la tendencia de peso y grasa tras
          // la destacada — «¿va mejorando?» se responde
          // con la línea, sin restar de cabeza.
          _tarjetaTendencia(mediciones),
          for (final m in mediciones.skip(1)) _tarjetaMedicion(m),
        ],
        const SizedBox(height: 8),
        _tituloSeccion('Marcas — récords'),
        if (records.isEmpty)
          _vacioOscuro(Icons.emoji_events_rounded,
              'Sin marcas registradas',
              'En su app, esta lista saldría vacía.')
        else
          for (final r in records)
            _tarjeta([
              Row(
                children: [
                  Icon(Icons.emoji_events_rounded,
                      color: AppColores.textoSecundario(context), size: 18),
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
                  style: AppTexto.secundario.copyWith(color: Colors.white70)),
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
                  style: AppTexto.secundario.copyWith(color: Colors.white70)),
            ]),
        ],
      ],
    );
  }

  /// 1.25 T63: tarjeta de tendencia con las líneas de
  /// peso y grasa en orden cronológico y la variación
  /// total de la serie visible. Sin color bueno/malo.
  Widget _tarjetaTendencia(List<dynamic> mediciones) {
    Widget linea(String nombre, String clave, String unidad) {
      final serie = serieTendenciaVistaPrevia(mediciones, clave);
      if (serie.length < 2) return const SizedBox.shrink();
      final d = serie.last - serie.first;
      return Padding(
        padding: const EdgeInsets.only(top: AppEspacio.sm),
        child: Row(
          children: [
            SizedBox(
              width: 92,
              child: Text(
                  '$nombre\n'
                  '${formatoMonto(serie.first)} → '
                  '${formatoMonto(serie.last)} $unidad',
                  style: AppTexto.secundario
                      .copyWith(color: Colors.white70)),
            ),
            Expanded(
              child: SizedBox(
                height: 34,
                child: CustomPaint(
                  painter: _SparkPainter(serie),
                  size: Size.infinite,
                ),
              ),
            ),
            const SizedBox(width: AppEspacio.sm),
            Text(
                d == 0
                    ? 'sin cambio'
                    : '${d > 0 ? '▲' : '▼'} ${formatoMonto(d.abs())}',
                style: AppTexto.secundario.copyWith(color: _naranja)),
          ],
        ),
      );
    }

    final hayPeso =
        serieTendenciaVistaPrevia(mediciones, 'peso_kg').length >= 2;
    final hayGrasa =
        serieTendenciaVistaPrevia(mediciones, 'grasa_pct').length >= 2;
    if (!hayPeso && !hayGrasa) return const SizedBox.shrink();
    return _tarjeta([
      const Text('Tendencia',
          style: TextStyle(
              color: Colors.white, fontWeight: FontWeight.bold)),
      if (hayPeso) linea('Peso', 'peso_kg', 'kg'),
      if (hayGrasa) linea('Grasa', 'grasa_pct', '%'),
    ]);
  }

  Widget _tarjetaMedicion(dynamic m,
      {bool destacada = false, dynamic anterior}) {
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
    // 1.25 T117 (F1-75): en la medición destacada, el cambio
    // desde la anterior (peso, grasa, cintura) con flecha; sin
    // color de bueno/malo: si subió o bajó es bueno depende
    // del objetivo del cliente, que esta vista no conoce.
    final deltas = <String>[];
    if (destacada && anterior != null) {
      void delta(String clave, String nombre, String unidad) {
        final a = m[clave], b = anterior[clave];
        if (a is num && b is num) {
          final d = a.toDouble() - b.toDouble();
          if (d != 0) {
            deltas.add('$nombre ${d > 0 ? '▲' : '▼'} '
                '${formatoMonto(d.abs())} $unidad');
          }
        }
      }

      delta('peso_kg', 'Peso', 'kg');
      delta('grasa_pct', 'Grasa', '%');
      delta('cintura_cm', 'Cintura', 'cm');
    }
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
                AppTexto.secundario.copyWith(color: Colors.white70)),
      if (deltas.isNotEmpty)
        Text('Desde la anterior: ${deltas.join(' · ')}',
            style: AppTexto.secundario.copyWith(color: _naranja)),
      if ('${m['notas'] ?? ''}'.isNotEmpty)
        Text('${m['notas']}',
            style:
                AppTexto.secundario.copyWith(color: Colors.white54)),
    ]);
  }

  // ---------------- Piezas comunes ----------------

  Widget _rotuloCorte(int mostrados, int total) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppEspacio.sm),
      child: Text('Mostrando últimos $mostrados de $total',
          style: AppTexto.metadato.copyWith(color: Colors.white54)),
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
      padding: const EdgeInsets.only(top: AppEspacio.xs, bottom: AppEspacio.sm),
      child: Text(t,
          style: AppTexto.titulo.copyWith(color: _naranja)),
    );
  }

  Widget _tarjeta(List<Widget> hijos) {
    return Container(
      margin: const EdgeInsets.only(bottom: AppEspacio.sm),
      padding: const EdgeInsets.all(AppEspacio.md),
      decoration: BoxDecoration(
        color: _colorTarjeta,
        borderRadius: BorderRadius.circular(AppRadio.md),
        border:
            Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: hijos,
      ),
    );
  }

  // 1.25 T117 (F1-73): vacío propio de esta pantalla espejo —
  // icono, título y subtítulo en su lenguaje oscuro. El
  // EstadoVacio de Gestión pertenece al tema de Gestión y
  // aquí rompería la fidelidad con la app del cliente.
  Widget _vacioOscuro(
      IconData icono, String titulo, String subtitulo) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppEspacio.lg),
      child: Column(
        children: [
          Icon(icono, size: 36, color: Colors.white24),
          const SizedBox(height: AppEspacio.sm),
          Text(titulo,
              style: const TextStyle(
                  color: Colors.white70,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 2),
          Text(subtitulo,
              style:
                  AppTexto.metadato.copyWith(color: Colors.white38),
              textAlign: TextAlign.center),
        ],
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
                  AppTexto.cuerpo.copyWith(color: Colors.white70)),
          Expanded(
            child: Text(valor,
                style: AppTexto.cuerpo.copyWith(color: destacado ? _naranja : Colors.white, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  Widget _chip(String texto, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppEspacio.sm, vertical: AppEspacio.xs),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(AppRadio.md),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Text(texto, style: AppTexto.metadato.copyWith(color: color)),
    );
  }

  Widget _chipDisponibilidad(String disp) {
    // 1.25 T117 (F1-72): sin texto no hay pastilla (antes la
    // cadena vacía caía en el «resto» rojo y pintaba una
    // pastilla vacía en rojo); el color se mapea por
    // contenido, no por igualdad exacta con dos frases.
    final t = disp.trim().toLowerCase();
    if (t.isEmpty) return const SizedBox.shrink();
    final color = t.contains('agot')
        ? Colors.red
        : (t.contains('últim') || t.contains('ultim'))
            ? Colors.amber
            : t.contains('dispon')
                ? Colors.green
                : Colors.white54;
    return _chip(disp, color);
  }
}


/// 1.25 T63: los valores de [clave] de las mediciones en
/// orden CRONOLÓGICO (la vista las trae recientes
/// primero), solo los numéricos presentes.
List<double> serieTendenciaVistaPrevia(
    List<dynamic> mediciones, String clave) {
  final valores = <double>[];
  for (final m in mediciones.reversed) {
    final v = (m as Map)[clave];
    if (v is num) valores.add(v.toDouble());
  }
  return valores;
}

/// 1.25 T63: línea de tendencia mínima — puntos unidos,
/// primero y último resaltados.
class _SparkPainter extends CustomPainter {
  final List<double> serie;
  const _SparkPainter(this.serie);

  @override
  void paint(Canvas canvas, Size size) {
    if (serie.length < 2) return;
    var min = serie.first, max = serie.first;
    for (final v in serie) {
      if (v < min) min = v;
      if (v > max) max = v;
    }
    final rango = (max - min) == 0 ? 1.0 : (max - min);
    Offset punto(int i) => Offset(
          size.width * i / (serie.length - 1),
          size.height -
              4 -
              (serie[i] - min) / rango * (size.height - 8),
        );
    final trazo = Paint()
      ..color = AppColores.naranja
      ..strokeWidth = 1.6
      ..style = PaintingStyle.stroke;
    final camino = Path()..moveTo(punto(0).dx, punto(0).dy);
    for (var i = 1; i < serie.length; i++) {
      camino.lineTo(punto(i).dx, punto(i).dy);
    }
    canvas.drawPath(camino, trazo);
    final puntoPint = Paint()..color = Colors.white;
    for (var i = 0; i < serie.length; i++) {
      canvas.drawCircle(punto(i), i == serie.length - 1 ? 3 : 1.8,
          i == serie.length - 1
              ? (Paint()..color = AppColores.naranja)
              : puntoPint);
    }
  }

  @override
  bool shouldRepaint(_SparkPainter old) => old.serie != serie;
}
