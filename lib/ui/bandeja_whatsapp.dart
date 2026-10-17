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

import '../negocio.dart';
import '../auth.dart';
import '../tiempo.dart';
import 'componentes.dart';
import 'diseno.dart';
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

  /// Clave de tarjeta tocada: fecha + tipo + cliente_id (Argón, ítem 1A).
  String _clave(Map<String, dynamic> a) =>
      'wa_tocado_${_hoy}_${a['tipo']}_${a['cliente_id']}';

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
      // Marcar como tocada hoy (check visual).
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_clave(a), true);
      if (mounted) setState(() => _tocados.add(_clave(a)));
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('No se pudo abrir WhatsApp.')));
      }
    }
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
  List<({String tipo, String titulo, IconData icono})> _secciones() {
    const orden = [
      (tipo: 'cumple', titulo: '🎂 Cumpleaños hoy', icono: Icons.cake),
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
    final tocado = _tocados.contains(clave);
    final tieneTelefono =
        normalizarTelefonoWaMe('${a['telefono'] ?? ''}').isNotEmpty;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppEspacio.sm),
      child: Tarjeta(
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text('${a['nombre']}',
                            style:
                                const TextStyle(fontWeight: FontWeight.w600)),
                      ),
                      if (tocado) ...[
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
                  if (tocado)
                    const Text('✓ Abierto en WhatsApp',
                        style: TextStyle(
                            fontSize: 11,
                            color: Colors.green,
                            fontWeight: FontWeight.w600)),
                  if (!tieneTelefono)
                    const Text('Sin teléfono registrado',
                        style: TextStyle(
                            fontSize: 11,
                            color: AppColores.alerta)),
                ],
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
    );
  }
}
