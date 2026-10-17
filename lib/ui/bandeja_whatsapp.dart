/// v1.3.6 (ítem 1A): bandeja "Avisos WhatsApp de Hoy".
///
/// Cumpleañeros, vencimientos, recordatorios y recibos de pago con botón
/// directo a wa.me (1 toque, sin entrar a la ficha). Las tarjetas tocadas
/// hoy quedan marcadas con "✓ Abierto en WhatsApp" (SharedPreferences,
/// clave fecha+tipo+cliente_id, según veredicto de Argón).
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

class _BandejaWhatsappScreenState extends State<BandejaWhatsappScreen> {
  bool _cargando = true;
  List<Map<String, dynamic>> _avisos = [];
  Set<String> _tocados = {};
  late String _hoy;

  @override
  void initState() {
    super.initState();
    _hoy = hoyHabanaIso();
    _cargar();
  }

  /// Clave de "Atendido": fecha + categoría + cliente_id (Argón, v1.3.8).
  /// Formato: atendido_YYYY-MM-DD_categoria_id. La categoría evita que
  /// alguien atendido hoy en "Por vencer" aparezca atenuado mañana en
  /// "Vencen hoy".
  String _clave(Map<String, dynamic> a) =>
      'atendido_${_hoy}_${a['tipo']}_${a['cliente_id']}';

  /// Purga las claves de "atendido" de días anteriores (Argón, v1.3.8).
  Future<void> _purgarViejas(SharedPreferences prefs) async {
    for (final k in prefs.getKeys()) {
      if (!k.startsWith('atendido_')) continue;
      // Formato: atendido_YYYY-MM-DD_...
      final partes = k.split('_');
      if (partes.length < 3) continue;
      final fecha = '${partes[1]}';
      if (fecha.compareTo(_hoy) < 0) {
        await prefs.remove(k);
      }
    }
    // Compat: migrar claves viejas 'wa_tocado_' al formato nuevo.
    for (final k in prefs.getKeys()) {
      if (!k.startsWith('wa_tocado_')) continue;
      // wa_tocado_YYYY-MM-DD_tipo_id -> atendido_YYYY-MM-DD_tipo_id
      final nueva = k.replaceFirst('wa_tocado_', 'atendido_');
      final v = prefs.getBool(k);
      if (v == true) await prefs.setBool(nueva, true);
      await prefs.remove(k);
    }
  }

  Future<void> _cargar() async {
    setState(() => _cargando = true);
    // v1.3.6 (auditoría Argón, Fix 1a): la bandeja es solo del dueño.
    // Guard en la pantalla además del botón oculto en Home.
    if (!AuthService().isOwner) {
      if (mounted) setState(() => _cargando = false);
      return;
    }
    try {
      final avisos = await avisosWhatsappHoy();
      final prefs = await SharedPreferences.getInstance();
      await _purgarViejas(prefs);
      final tocados = <String>{};
      for (final a in avisos) {
        if (prefs.getBool(_clave(a)) == true) {
          tocados.add(_clave(a));
        }
      }
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

  Future<void> _abrirWhatsapp(Map<String, dynamic> a) async {
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
      // Marcar como atendido (check visual).
      await _setAtendido(a, true);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('No se pudo abrir WhatsApp.')));
      }
    }
  }

  /// v1.3.8 (1A): marca/desmarca "Atendido" manualmente. El check tiene
  /// su propia área táctil para no abrir la ficha al tocarlo.
  Future<void> _setAtendido(Map<String, dynamic> a, bool valor) async {
    final prefs = await SharedPreferences.getInstance();
    final clave = _clave(a);
    if (valor) {
      await prefs.setBool(clave, true);
    } else {
      await prefs.remove(clave);
    }
    if (mounted) {
      setState(() {
        if (valor) {
          _tocados.add(clave);
        } else {
          _tocados.remove(clave);
        }
      });
    }
  }

  /// v1.3.8 (1B): diálogo para agregar el teléfono sin salir de la bandeja.
  Future<void> _agregarTelefono(Map<String, dynamic> a) async {
    final ctrl = TextEditingController();
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
            content: Text('Teléfono inválido: 8 dígitos, empieza con 5 o 6.')));
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
          // v1.3.8 (1A): contador de contactados.
          if (!_cargando && AuthService().isOwner && _avisos.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '${_tocados.length} de ${_avisos.length} contactados',
                  style: AppTexto.secundario.copyWith(
                      color: AppColores.textoSecundario(context)),
                ),
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
        if (_avisos.any((a) => a['tipo'] == o.tipo)) o,
    ];
  }

  List<Widget> _bloqueSeccion(
      ({String tipo, String titulo, IconData icono}) seccion) {
    final items =
        _avisos.where((a) => a['tipo'] == seccion.tipo).toList();
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
