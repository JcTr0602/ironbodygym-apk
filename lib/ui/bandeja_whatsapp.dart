/// v1.3.6 (ítem 1A): bandeja "Avisos WhatsApp de Hoy".
///
/// Cumpleañeros, vencimientos, recordatorios y recibos de pago con botón
/// directo a wa.me (1 toque, sin entrar a la ficha).
///
/// v1.13.0 (Bloque 4, Argón ajuste 5): el progreso («contactado»)
/// vive en SQLite local (tabla avisos_wa_contactados: cliente_id +
/// tipo + fecha Habana), NO solo en RAM ni en SharedPreferences:
/// Android mata el proceso al ir a WhatsApp y el estado se perdía.
/// Las claves viejas de prefs se migran una sola vez al primer uso.
/// Además: barra de progreso real, filtro «solo con teléfono»,
/// búsqueda por nombre, subgrupos de atraso en Vencidos y modo
/// «Enviar en lote» (siguiente aviso sin teléfono no: solo con
/// teléfono, en orden de la bandeja).
library;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';
import 'dart:async';

import '../negocio.dart';
import '../auth.dart';
import '../localdb.dart';
import '../sync.dart';
import '../tiempo.dart';
import 'componentes.dart';
import 'diseno.dart';
import 'ficha.dart';
import 'widgets.dart';

class BandejaWhatsappScreen extends StatefulWidget {
  const BandejaWhatsappScreen({super.key});

  @override
  State<BandejaWhatsappScreen> createState() =>
      _BandejaWhatsappScreenState();
}

class _BandejaWhatsappScreenState extends State<BandejaWhatsappScreen>
    with WidgetsBindingObserver {
  bool _cargando = true;
  List<Map<String, dynamic>> _avisos = [];
  // Claves SQLite 'tipo_clienteId' del día (tabla
  // avisos_wa_contactados). NUNCA solo en RAM.
  Set<String> _tocados = {};
  late String _hoy;
  // Corrección panel 1.13: el aviso que se abrió en WhatsApp y
  // espera confirmación al volver (sin marcar todavía).
  Map<String, dynamic>? _confirmarAlVolver;
  bool _confirmarEnLote = false;
  // v1.13.0: filtros de la bandeja.
  bool _soloConTelefono = false;
  String _busqueda = '';
  final _busquedaCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _hoy = hoyHabanaIso();
    _cargar();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _busquedaCtrl.dispose();
    super.dispose();
  }

  /// Corrección panel 1.13 (MEDIO): al volver de WhatsApp se
  /// pregunta si el mensaje se envió, en vez de marcar atendido
  /// al abrir wa.me. El temporizador del Deshacer corría
  /// mientras WhatsApp estaba en primer plano y ya había
  /// expirado al volver; y si no se enviaba nada, el aviso
  /// quedaba marcado igual. Sin confirmar, sigue pendiente
  /// (fallo seguro: no se pierde ningún aviso).
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    final a = _confirmarAlVolver;
    if (a == null || !mounted) return;
    _confirmarAlVolver = null;
    final enLote = _confirmarEnLote;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
            '¿Enviaste el mensaje a ${a['nombre'] ?? 'este cliente'}?'),
        action: SnackBarAction(
          label: 'Sí, enviado',
          onPressed: () async {
            await _setAtendido(a, true);
            if (!mounted) return;
            if (enLote) {
              final quedan = _pendientesLote();
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(quedan > 0
                      ? 'Contactado. Quedan $quedan en el lote.'
                      : 'Lote completo.'),
                  action: quedan > 0
                      ? SnackBarAction(
                          label: 'Siguiente',
                          onPressed: _enviarLote,
                        )
                      : null,
                ),
              );
            } else {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: const Text('Marcado como contactado.'),
                  action: SnackBarAction(
                    label: 'Deshacer',
                    onPressed: () => _setAtendido(a, false),
                  ),
                ),
              );
            }
          },
        ),
      ),
    );
  }

  /// Clave de "Atendido" en SQLite: tipo + cliente_id (la fecha va
  /// en su propia columna). La categoría evita que alguien atendido
  /// hoy en "Por vencer" aparezca atenuado mañana en "Vencen hoy".
  String _clave(Map<String, dynamic> a) =>
      '${a['tipo']}_${a['cliente_id']}';

  /// Migración única desde SharedPreferences (1.3.8/1.3.6): las
  /// claves atendido_YYYY-MM-DD_* de HOY pasan a SQLite y se borran
  /// de prefs; las de días viejos solo se borran. Después de esto,
  /// prefs ya no se usa para el progreso de la bandeja.
  ///
  /// Corrección panel 1.13 (MEDIO): el tipo puede llevar guion
  /// bajo (vence_hoy, por_vencer). El parseo viejo tomaba solo
  /// el primer segmento como tipo y el resto como id, así que
  /// el id salía «hoy_123», el parse fallaba y la clave se
  /// borraba igual: el progreso se perdía. Ahora el id es el
  /// ÚLTIMO segmento y el tipo es todo lo del medio; y una
  /// clave de hoy con valor true que no parsea NO se borra,
  /// para no perderla en un reintento futuro.
  Future<void> _migrarDesdePrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      for (final k in prefs.getKeys().toList()) {
        String? prefijo;
        if (k.startsWith('wa_tocado_')) {
          prefijo = 'wa_tocado_';
        } else if (k.startsWith('atendido_')) {
          prefijo = 'atendido_';
        } else {
          continue;
        }
        final resto = k.substring(prefijo.length);
        final partes = resto.split('_');
        if (partes.length < 3) {
          await prefs.remove(k);
          continue;
        }
        final fecha = partes[0];
        if (fecha != _hoy || prefs.getBool(k) != true) {
          await prefs.remove(k);
          continue;
        }
        final cid = int.tryParse(partes.last);
        if (cid == null) continue; // No borrar: reintento futuro.
        final tipo = partes.sublist(1, partes.length - 1).join('_');
        await LocalDb.instance.marcarAvisoWaContactado(cid, tipo, _hoy);
        await prefs.remove(k);
      }
    } catch (_) {}
  }

  Future<void> _cargar() async {
    // Argón #10-4: _hoy se fijaba solo en initState. Si la app
    // quedaba abierta de un día para otro y se refrescaba, los
    // avisos eran del día nuevo pero las marcas de contactado se
    // guardaban bajo la fecha vieja. Se refresca en cada carga.
    _hoy = hoyHabanaIso();
    setState(() => _cargando = true);
    // v1.3.6 (auditoría Argón, Fix 1a): la bandeja es solo del dueño.
    // Guard en la pantalla además del botón oculto en Home.
    if (!AuthService().isOwner) {
      if (mounted) setState(() => _cargando = false);
      return;
    }
    try {
      final avisos = await avisosWhatsappHoy();
      await _migrarDesdePrefs();
      final tocados =
          await LocalDb.instance.avisosWaContactados(_hoy);
      if (mounted) {
        setState(() {
          _avisos = avisos;
          _tocados = tocados;
          _cargando = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _cargando = false);
    }
  }

  /// Avisos tras aplicar los filtros (teléfono + búsqueda).
  List<Map<String, dynamic>> get _avisosFiltrados {
    return _avisos.where((a) {
      if (_soloConTelefono &&
          normalizarTelefonoWaMe('${a['telefono'] ?? ''}').isEmpty) {
        return false;
      }
      if (_busqueda.isNotEmpty) {
        final nombre = '${a['nombre'] ?? ''}'.toLowerCase();
        if (!nombre.contains(_busqueda.toLowerCase())) return false;
      }
      return true;
    }).toList();
  }

  /// Próximo aviso del lote: sin contactar y CON teléfono, en el
  /// orden de la bandeja (Vencidos > Vencen hoy > Por vencer >
  /// Recibos > Cumpleaños).
  Map<String, dynamic>? _siguienteLote() {
    const orden = [
      'vencido',
      'vence_hoy',
      'por_vencer',
      'recibo',
      'cumple'
    ];
    final pendientes = _avisosFiltrados.where((a) {
      if (_tocados.contains(_clave(a))) return false;
      return normalizarTelefonoWaMe('${a['telefono'] ?? ''}')
          .isNotEmpty;
    }).toList();
    pendientes.sort((a, b) {
      final ia = orden.indexOf('${a['tipo']}');
      final ib = orden.indexOf('${b['tipo']}');
      return ia.compareTo(ib);
    });
    return pendientes.isEmpty ? null : pendientes.first;
  }

  int _pendientesLote() {
    var n = 0;
    for (final a in _avisosFiltrados) {
      if (_tocados.contains(_clave(a))) continue;
      if (normalizarTelefonoWaMe('${a['telefono'] ?? ''}')
          .isEmpty) continue;
      n++;
    }
    return n;
  }

  /// Modo lote: abre el próximo aviso pendiente (con teléfono) en
  /// wa.me; al volver, el snackbar ofrece «Siguiente».
  Future<void> _enviarLote() async {
    final siguiente = _siguienteLote();
    if (siguiente == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Lote completo: no quedan avisos '
                'pendientes con teléfono.')));
      }
      return;
    }
    await _abrirWhatsapp(siguiente, enLote: true);
  }

  Future<void> _abrirWhatsapp(Map<String, dynamic> a,
      {bool enLote = false}) async {
    final waNum = normalizarTelefonoWaMe('${a['telefono'] ?? ''}');
    if (waNum.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Este cliente no tiene teléfono registrado.')));
      }
      return;
    }
    final url = Uri.parse(
        'https://wa.me/$waNum?text=${Uri.encodeComponent('${a['mensaje']}')}');
    try {
      await launchUrl(url, mode: LaunchMode.externalApplication);
      // Corrección panel 1.13: NO marcar aquí. launchUrl resuelve
      // al abrir WhatsApp, no al volver; marcar al instante
      // dejaba el aviso como contactado aunque no se enviara
      // nada, y el Deshacer expiraba fuera de la app. La
      // confirmación llega en didChangeAppLifecycleState al
      // volver a primer plano.
      if (!mounted) return;
      _confirmarAlVolver = a;
      _confirmarEnLote = enLote;
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('No se pudo abrir WhatsApp.')));
      }
    }
  }

  /// v1.3.8 (1A): marca/desmarca "Atendido" manualmente (SQLite, al
  /// instante). El check tiene su propia área táctil para no abrir
  /// la ficha al tocarlo.
  Future<void> _setAtendido(Map<String, dynamic> a, bool valor) async {
    final cid = (a['cliente_id'] as num?)?.toInt() ?? 0;
    final tipo = '${a['tipo']}';
    if (cid <= 0) return;
    if (valor) {
      await LocalDb.instance.marcarAvisoWaContactado(cid, tipo, _hoy);
    } else {
      await LocalDb.instance
          .desmarcarAvisoWaContactado(cid, tipo, _hoy);
    }
    if (mounted) {
      setState(() {
        if (valor) {
          _tocados.add(_clave(a));
        } else {
          _tocados.remove(_clave(a));
        }
      });
    }
  }

  /// v1.3.8 (1B): diálogo para agregar el teléfono sin salir de la bandeja.
  Future<void> _agregarTelefono(Map<String, dynamic> a) async {
    // Ronda 17 M7-H3: agregar teléfonos es solo del dueño.
    if (!AuthService().isOwner) return;
    final ctrl = TextEditingController();
    try {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Agregar teléfono'),
          content: TextField(
            controller: ctrl,
            keyboardType: TextInputType.phone,
            maxLength: 8,
            decoration: const InputDecoration(
              hintText: 'Ej. 58191577',
              helperText: '8 dígitos, empieza con 5 o 6',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Guardar'),
            ),
          ],
        ),
      );
      if (ok != true || !mounted) return;
      final tel = ctrl.text.trim();
      if (!validarTelefono(tel)) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content:
                  Text('Teléfono inválido: 8 dígitos, empieza con 5 o 6.')));
        }
        return;
      }
      final cid = (a['cliente_id'] as num?)?.toInt() ?? 0;
      if (cid <= 0) return;
      await LocalDb.instance.updateMirrorTelefono(cid, tel);
      // Encolar la edición para el servidor.
      await LocalDb.instance.queueOp(
        opUuid: const Uuid().v4(),
        tipo: 'editar_cliente',
        payload: {'cliente_id': cid, 'telefono': tel},
      );
      unawaited(SyncEngine.instance.push());
      if (mounted) {
        // Actualiza el aviso en memoria para activar el botón wa.me.
        setState(() {
          a['telefono'] = tel;
        });
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Teléfono guardado.')));
      }
    } finally {
      // Ronda 17 M7-H3: el controlador del diálogo se libera
      // siempre (antes quedaba vivo en cada apertura).
      ctrl.dispose();
    }
  }

  /// v1.3.8: abre la ficha del cliente al tocar la tarjeta.
  void _irAFicha(Map<String, dynamic> a) {
    final cid = (a['cliente_id'] as num?)?.toInt() ?? 0;
    if (cid <= 0) return;
    Navigator.of(context)
        .push(MaterialPageRoute(
            builder: (_) => FichaScreen(clienteId: cid)))
        .then((_) => _cargar());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Avisos WhatsApp de hoy'),
        actions: [
          IconButton(
            tooltip: 'Actualizar',
            icon: const Icon(Icons.refresh),
            onPressed: _cargar,
          ),
        ],
      ),
      body: Column(
        children: [
          const SyncBanner(),
          // v1.13.0: barra de progreso REAL (SQLite) + filtros +
          // modo lote.
          if (!_cargando && AuthService().isOwner && _avisos.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Builder(builder: (_) {
                    final total = _avisos.length;
                    final hechos = _avisos
                        .where((a) => _tocados.contains(_clave(a)))
                        .length;
                    final ratio =
                        total > 0 ? hechos / total : 0.0;
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '$hechos de $total contactados',
                          style: AppTexto.secundario.copyWith(
                              color: AppColores.textoSecundario(context)),
                        ),
                        const SizedBox(height: 4),
                        LinearProgressIndicator(value: ratio),
                      ],
                    );
                  }),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _busquedaCtrl,
                          decoration: const InputDecoration(
                            hintText: 'Buscar por nombre',
                            prefixIcon: Icon(Icons.search, size: 20),
                            isDense: true,
                          ),
                          onChanged: (v) =>
                              setState(() => _busqueda = v.trim()),
                        ),
                      ),
                      const SizedBox(width: 8),
                      FilterChip(
                        label: const Text('Con teléfono'),
                        selected: _soloConTelefono,
                        onSelected: (v) => setState(
                            () => _soloConTelefono = v),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed:
                          _pendientesLote() > 0 ? _enviarLote : null,
                      icon: const Icon(Icons.send, size: 18),
                      label: Text(_pendientesLote() > 0
                          ? 'Enviar en lote (${_pendientesLote()} pendientes)'
                          : 'Lote completo'),
                    ),
                  ),
                ],
              ),
            ),
          Expanded(
            child: _cargando
                ? const Center(child: CircularProgressIndicator())
                : !AuthService().isOwner
                    // v1.3.6 (auditoría Argón, Fix 1a): solo el dueño.
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(32),
                          child: Text(
                            'Esta bandeja es solo para el dueño del gym.',
                            textAlign: TextAlign.center,
                            style: AppTexto.secundario,
                          ),
                        ),
                      )
                    : _avisos.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(32),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.mark_chat_read_outlined,
                                  size: 56, color: Colors.green),
                              const SizedBox(height: 12),
                              const Text('Sin avisos por hoy.',
                                  style: AppTexto.subtitulo),
                              const SizedBox(height: 8),
                              Text(
                                'Cuando haya cumpleaños, vencimientos o '
                                'cobros del día, aparecerán aquí.',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                    color: AppColores.textoSecundario(
                                        context)),
                              ),
                            ],
                          ),
                        ),
                      )
                    : _avisosFiltrados.isEmpty
                    ? const Center(
                        child: Padding(
                          padding: EdgeInsets.all(32),
                          child: Text(
                            'Ningún aviso coincide con los filtros.',
                            textAlign: TextAlign.center,
                            style: AppTexto.secundario,
                          ),
                        ),
                      )
                    : RefreshIndicator(
                        onRefresh: _cargar,
                        child: ListView(
                          padding: const EdgeInsets.all(16),
                          children: [
                            for (final seccion in _secciones())
                              ..._bloqueSeccion(seccion),
                          ],
                        ),
                      ),
          ),
        ],
      ),
    );
  }

  /// Agrupa los avisos por tipo en el orden de la bandeja.
  /// v1.3.8 (1C): Vencidos > Vencen hoy > Por vencer > Recibos > Cumpleaños.
  /// v1.13.0: sobre los avisos FILTRADOS (teléfono + búsqueda).
  List<({String tipo, String titulo, IconData icono})> _secciones() {
    const orden = [
      (
        tipo: 'vencido',
        titulo: '🔴 Vencidos',
        icono: Icons.error_outline
      ),
      (
        tipo: 'vence_hoy',
        titulo: '⏰ Vencen hoy',
        icono: Icons.warning_amber_outlined
      ),
      (
        tipo: 'por_vencer',
        titulo: '📩 Por vencer',
        icono: Icons.schedule_outlined
      ),
      (
        tipo: 'recibo',
        titulo: '🧾 Recibos de hoy',
        icono: Icons.receipt_long_outlined
      ),
      (tipo: 'cumple', titulo: '🎂 Cumpleaños hoy', icono: Icons.cake),
    ];
    return [
      for (final o in orden)
        if (_avisosFiltrados.any((a) => a['tipo'] == o.tipo)) o,
    ];
  }

  List<Widget> _bloqueSeccion(
      ({String tipo, String titulo, IconData icono}) seccion) {
    final items =
        _avisosFiltrados.where((a) => a['tipo'] == seccion.tipo).toList();
    // v1.13.0: subgrupos de atraso dentro de Vencidos (1–7 / 8–30
    // días), por el campo numérico dias_atraso del aviso.
    if (seccion.tipo == 'vencido') {
      final recientes = items
          .where((a) => ((a['dias_atraso'] as num?)?.toInt() ?? 0) <= 7)
          .toList();
      final viejos = items
          .where((a) => ((a['dias_atraso'] as num?)?.toInt() ?? 0) > 7)
          .toList();
      return [
        Padding(
          padding:
              const EdgeInsets.only(top: AppEspacio.sm, bottom: 8),
          child: Row(
            children: [
              Icon(seccion.icono,
                  color: AppColores.naranja, size: 20),
              const SizedBox(width: 8),
              Text('${seccion.titulo} (${items.length})',
                  style: AppTexto.subtitulo),
            ],
          ),
        ),
        if (recientes.isNotEmpty) ...[
          const Padding(
            padding: EdgeInsets.only(bottom: 4),
            child: Text('Hace 1–7 días',
                style: TextStyle(fontWeight: FontWeight.w600)),
          ),
          for (final a in recientes) _tarjeta(a),
        ],
        if (viejos.isNotEmpty) ...[
          const Padding(
            padding: EdgeInsets.only(bottom: 4, top: 4),
            child: Text('Hace 8–30 días',
                style: TextStyle(fontWeight: FontWeight.w600)),
          ),
          for (final a in viejos) _tarjeta(a),
        ],
        const SizedBox(height: AppEspacio.sm),
      ];
    }
    return [
      Padding(
        padding:
            const EdgeInsets.only(top: AppEspacio.sm, bottom: 8),
        child: Row(
          children: [
            Icon(seccion.icono,
                color: AppColores.naranja, size: 20),
            const SizedBox(width: 8),
            Text('${seccion.titulo} (${items.length})',
                style: AppTexto.subtitulo),
          ],
        ),
      ),
      for (final a in items) _tarjeta(a),
      const SizedBox(height: AppEspacio.sm),
    ];
  }

  Widget _tarjeta(Map<String, dynamic> a) {
    final clave = _clave(a);
    final atendido = _tocados.contains(clave);
    final tieneTelefono =
        normalizarTelefonoWaMe('${a['telefono'] ?? ''}').isNotEmpty;
    // v1.3.8 (1A): los atendidos se atenúan.
    final contenido = Opacity(
      opacity: atendido ? 0.55 : 1.0,
      child: Padding(
        padding: const EdgeInsets.only(bottom: AppEspacio.sm),
        child: Tarjeta(
          child: Row(
            children: [
              // v1.3.8 (1A): check con su propia área táctil (no abre la ficha).
              InkWell(
                borderRadius: BorderRadius.circular(20),
                onTap: () => _setAtendido(a, !atendido),
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Icon(
                    atendido
                        ? Icons.check_circle
                        : Icons.radio_button_unchecked,
                    size: 22,
                    color: atendido
                        ? Colors.green
                        : AppColores.textoSecundario(context),
                  ),
                ),
              ),
              // v1.3.8: tocar la tarjeta abre la ficha del cliente.
              Expanded(
                child: InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () => _irAFicha(a),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text('${a['nombre']}',
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w600)),
                            ),
                            if (atendido) ...[
                              const SizedBox(width: 6),
                              const Icon(Icons.check_circle,
                                  size: 16, color: Colors.green),
                            ],
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text('${a['detalle']}',
                            style: TextStyle(
                                fontSize: 12,
                                color: AppColores.textoSecundario(context))),
                        if (atendido)
                          const Text('✓ Atendido',
                              style: TextStyle(
                                  fontSize: 11,
                                  color: Colors.green,
                                  fontWeight: FontWeight.w600)),
                        if (!tieneTelefono)
                          InkWell(
                            onTap: () => _agregarTelefono(a),
                            child: const Padding(
                              padding: EdgeInsets.only(top: 2),
                              child: Text('Sin teléfono registrado · toca para agregar',
                                  style: TextStyle(
                                      fontSize: 11,
                                      color: AppColores.alerta,
                                      decoration: TextDecoration.underline)),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              // Botón WhatsApp: verde reconocible, 1 toque.
              InkWell(
                borderRadius: BorderRadius.circular(24),
                onTap: tieneTelefono ? () => _abrirWhatsapp(a) : null,
                child: Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: tieneTelefono
                        ? const Color(0xFF25D366)
                        : AppColores.textoSecundario(context)
                            .withValues(alpha: 0.3),
                  ),
                  child: const Icon(Icons.chat,
                      color: Colors.white, size: 24),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    return contenido;
  }
}
