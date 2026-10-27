/// 🎂 Cumpleaños: pestañas "Próximos 7 días" y "Mes completo".
///
/// v1.3.8: botones "Felicitar" (wa.me, solo saludo) y "Regalar mes +
/// felicitar" (aplica el regalo y abre wa.me con la nueva fecha).
/// Marca "Felicitado" local (felicitado_YYYY_id). El bloqueo
/// anti-duplicado del regalo verifica la operación real en BD,
/// NUNCA el check local (regla crítica de Argón).
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';

import '../auth.dart';
import '../cliente_protegido.dart';
import '../localdb.dart';
import '../negocio.dart';
import '../sync.dart';
import '../tiempo.dart';
import 'buscar.dart';
import 'diseno.dart';
import 'ficha.dart';
import 'widgets.dart';

class CumpleanosScreen extends StatefulWidget {
  const CumpleanosScreen({super.key});
  @override
  State<CumpleanosScreen> createState() => _CumpleanosScreenState();
}

class _CumpleanosScreenState extends State<CumpleanosScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabs;
  List<Map<String, dynamic>> _proximos = [];
  List<Map<String, dynamic>> _mes = [];
  Set<String> _felicitados = {};
  Set<int> _regaladosAnio = {};
  bool _cargando = true;
  late String _anio;

  static const _meses = [
    '',
    'enero',
    'febrero',
    'marzo',
    'abril',
    'mayo',
    'junio',
    'julio',
    'agosto',
    'septiembre',
    'octubre',
    'noviembre',
    'diciembre'
  ];

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
    _anio = '${ahoraHabana().year}';
    _cargar();
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  /// Clave de "Felicitado": incluye el año para caducar solo (Argón).
  String _claveFelicitado(int id) => 'felicitado_${_anio}_$id';

  Future<void> _cargar() async {
    // Argón #10-4: _anio se fijaba solo en initState. Si la app
    // quedaba abierta de un año para otro y se refrescaba, las
    // claves de felicitado/regalo usaban el año viejo.
    _anio = '${ahoraHabana().year}';
    setState(() => _cargando = true);
    try {
      // Cliente protegido (2026-10-26, Protegido 2 H6): la pantalla
      // de cumpleaños trae regalar, agregar teléfono y WhatsApp;
      // un no-dueño no ve protegidos aquí.
      final proximos = (await cumpleanosProximos(dias: 7))
          .where((c) => !esVistaProtegida(c))
          .toList();
      final mes = (await cumpleanosDelMes())
          .where((c) => !esVistaProtegida(c))
          .toList();
      final prefs = await SharedPreferences.getInstance();
      final felicitados = <String>{};
      for (final c in [...proximos, ...mes]) {
        final id = (c['id'] as num?)?.toInt() ?? 0;
        if (prefs.getBool(_claveFelicitado(id)) == true) {
          felicitados.add(_claveFelicitado(id));
        }
      }
      // Regalos ya aplicados este año (verificación en BD, no en el
      // check local — regla crítica de Argón).
      final regalados = <int>{};
      for (final c in [...proximos, ...mes]) {
        final id = (c['id'] as num?)?.toInt() ?? 0;
        if (id <= 0) continue;
        if (await _regaloAplicado(id)) regalados.add(id);
      }
      if (mounted) {
        setState(() {
          _proximos = proximos;
          _mes = mes;
          _felicitados = felicitados;
          _regaladosAnio = regalados;
          _cargando = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _cargando = false);
    }
  }

  /// ¿Ya se regaló el mes este año? Verifica la operación real en BD:
  /// meta local + pagos de cortesía (igual que FichaScreen).
  /// NUNCA usa el check "Felicitado" (Argón).
  Future<bool> _regaloAplicado(int clienteId) async {
    try {
      final meta = await LocalDb.instance
          .getMeta('regalo_cumple_${clienteId}_$_anio');
      if (meta != null) return true;
    } catch (_) {}
    try {
      final pagos = await LocalDb.instance
          .pagosCortesiaClienteAnio(clienteId, _anio);
      if (pagos.isNotEmpty) return true;
    } catch (_) {}
    return false;
  }

  Future<void> _setFelicitado(int id, bool valor) async {
    final prefs = await SharedPreferences.getInstance();
    final clave = _claveFelicitado(id);
    if (valor) {
      await prefs.setBool(clave, true);
    } else {
      await prefs.remove(clave);
    }
    if (mounted) {
      setState(() {
        if (valor) {
          _felicitados.add(clave);
        } else {
          _felicitados.remove(clave);
        }
      });
    }
  }

  /// 2B: felicitar por WhatsApp (SOLO saludo, sin mencionar regalo).
  Future<void> _felicitar(Map<String, dynamic> c) async {
    final id = (c['id'] as num?)?.toInt() ?? 0;
    final nombre = '${c['nombre'] ?? 'Cliente'}';
    final tel = '${c['telefono'] ?? ''}'.trim();
    final waNum = normalizarTelefonoWaMe(tel);
    if (waNum.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Este cliente no tiene teléfono registrado.')));
      }
      return;
    }
    final mensaje = '¡Feliz cumpleaños, $nombre! 🎂\n'
        'De parte de todo el equipo de Iron Body Gym, '
        'que tengas un día excelente 💪';
    final url = Uri.parse(
        'https://wa.me/$waNum?text=${Uri.encodeComponent(mensaje)}');
    try {
      await launchUrl(url, mode: LaunchMode.externalApplication);
      await _setFelicitado(id, true);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('No se pudo abrir WhatsApp.')));
      }
    }
  }

  /// 2C: regalar mes + felicitar. Aplica el regalo (verificando en BD
  /// que no se haya aplicado ya) y abre wa.me con la nueva fecha.
  Future<void> _regalarYFelicitar(Map<String, dynamic> c) async {
    final id = (c['id'] as num?)?.toInt() ?? 0;
    if (id <= 0 || !mounted) return;
    // Misma clase que #10-4: la clave anual del regalo debe usar
    // el año actual, no el de cuando se abrió la pantalla.
    _anio = '${ahoraHabana().year}';
    // Bloqueo anti-duplicado: operación real en BD (Argón).
    if (await _regaloAplicado(id)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Ya se regaló el mes este año.')));
      }
      return;
    }
    final nombre = '${c['nombre'] ?? 'Cliente'}';
    // Trae el pagado_hasta actual del espejo.
    final cli = await LocalDb.instance.mirrorPorIds('clientes', [id]);
    final pagadoHastaActual = cli.isNotEmpty
        ? cli.first['pagado_hasta'] as String?
        : null;
    final nuevoHasta = previewHastaDias(pagadoHastaActual, 30);
    final hastaFmt = fmtFecha(nuevoHasta) ?? nuevoHasta;
    final confirmar = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('🎁 Regalar mensualidad'),
        content: Text('¿Regalar 1 mes a $nombre?\nVálido hasta $hastaFmt.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Regalar'),
          ),
        ],
      ),
    );
    if (confirmar != true || !mounted) return;
    // a) Espejo local.
    await LocalDb.instance.updateMirrorPagadoHasta(id, nuevoHasta);
    // b) Op al servidor.
    await LocalDb.instance.queueOp(
      opUuid: const Uuid().v4(),
      tipo: 'regalar_mes_cumpleanos',
      payload: {
        'cliente_id': id,
        'fecha': hoyHabanaIso(),
      },
    );
    // c) Meta local (candado anual).
    await LocalDb.instance.setMeta(
        'regalo_cumple_${id}_$_anio',
        jsonEncode(
            {'anterior': pagadoHastaActual, 'nuevo': nuevoHasta}));
    unawaited(SyncEngine.instance.push());
    if (mounted) {
      setState(() => _regaladosAnio.add(id));
    }
    // d) WhatsApp con el mensaje del regalo (formato de FichaScreen).
    final tel = '${c['telefono'] ?? ''}'.trim();
    final waNum = normalizarTelefonoWaMe(tel);
    if (waNum.isEmpty || !mounted) return;
    final anteriorFmt = (pagadoHastaActual != null &&
            pagadoHastaActual.length >= 10)
        ? _fechaLarga(pagadoHastaActual)
        : null;
    final buf = StringBuffer()
      ..writeln('¡Feliz cumpleaños, *$nombre*! 🎂🎉')
      ..writeln('Te hemos regalado 1 mensualidad por tu día.');
    if (anteriorFmt != null) {
      buf.writeln('📅 Vencía el: *$anteriorFmt*');
      buf.writeln('✅ Nuevo vencimiento: *${_fechaLarga(nuevoHasta)}*');
    } else {
      buf.writeln('✅ Válida hasta el: *${_fechaLarga(nuevoHasta)}*');
    }
    buf.writeln('¡A seguir dándole duro! — Iron Body Gym 💪🔥');
    final url = Uri.parse(
        'https://wa.me/$waNum?text=${Uri.encodeComponent(buf.toString().trim())}');
    try {
      await launchUrl(url, mode: LaunchMode.externalApplication);
      await _setFelicitado(id, true);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Regalo aplicado. No se pudo abrir WhatsApp.')));
      }
    }
  }

  /// "2026-12-05" → "5 de diciembre".
  String _fechaLarga(String iso) {
    try {
      final d = DateTime.parse(iso.substring(0, 10));
      return '${d.day} de ${_meses[d.month]}';
    } catch (_) {
      return iso;
    }
  }

  /// 1B reutilizado: agregar teléfono sin salir de la pantalla.
  Future<void> _agregarTelefono(Map<String, dynamic> c) async {
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
            content:
                Text('Teléfono inválido: 8 dígitos, empieza con 5 o 6.')));
      }
      return;
    }
    final id = (c['id'] as num?)?.toInt() ?? 0;
    if (id <= 0) return;
    await LocalDb.instance.updateMirrorTelefono(id, tel);
    await LocalDb.instance.queueOp(
      opUuid: const Uuid().v4(),
      tipo: 'editar_cliente',
      payload: {'cliente_id': id, 'telefono': tel},
    );
    unawaited(SyncEngine.instance.push());
    if (mounted) {
      setState(() => c['telefono'] = tel);
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Teléfono guardado.')));
    }
  }

  String _etiqueta(Map<String, dynamic> c) {
    final hoy = ahoraHabana();
    final dia = c['_dia'] as int? ?? 0;
    if (dia == hoy.day) return '¡Hoy!';
    if (c['_paso'] == true) return 'Ya cumplió';
    return 'Día $dia';
  }

  @override
  Widget build(BuildContext context) {
    final mes = _meses[ahoraHabana().month];
    return Scaffold(
      appBar: AppBar(
        title: Text('Cumpleaños de $mes'),
        bottom: TabBar(
          controller: _tabs,
          tabs: const [
            Tab(text: 'Próximos 7 días'),
            Tab(text: 'Mes completo'),
          ],
        ),
      ),
      body: Column(
        children: [
          const SyncBanner(),
          Expanded(
            child: _cargando
                ? const Center(child: CircularProgressIndicator())
                : TabBarView(
                    controller: _tabs,
                    children: [
                      _lista(_proximos, 'próximos 7 días'),
                      _lista(_mes, 'este mes'),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _lista(List<Map<String, dynamic>> items, String etiqueta) {
    if (items.isEmpty) {
      return Center(
          child: Text('Sin cumpleaños en los $etiqueta.\n'
              'La fecha sale del carnet de identidad.',
              textAlign: TextAlign.center));
    }
    // v1.3.8 (2A/2D): el contador refleja las tarjetas visibles.
    final fel = items
        .where((c) => _felicitados
            .contains(_claveFelicitado((c['id'] as num?)?.toInt() ?? 0)))
        .length;
    return RefreshIndicator(
      onRefresh: _cargar,
      child: ListView.builder(
        itemCount: items.length + 1,
        itemBuilder: (ctx, i) {
          if (i == 0) {
            return Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                '$fel de ${items.length} felicitados en los $etiqueta',
                style: AppTexto.secundario.copyWith(
                    color: AppColores.textoSecundario(context)),
              ),
            );
          }
          return _tarjeta(items[i - 1]);
        },
      ),
    );
  }

  Widget _tarjeta(Map<String, dynamic> c) {
    final id = (c['id'] as num?)?.toInt() ?? 0;
    final felicitado = _felicitados.contains(_claveFelicitado(id));
    final regalado = _regaladosAnio.contains(id);
    final tieneTelefono =
        normalizarTelefonoWaMe('${c['telefono'] ?? ''}').isNotEmpty;
    final diasPara = c['_dias_para'] as int?;
    return Opacity(
      opacity: felicitado ? 0.6 : 1.0,
      child: FilaCliente(
        cliente: c,
        onTap: () => Navigator.of(context)
            .push(MaterialPageRoute(
                builder: (_) => FichaScreen(clienteId: id)))
            .then((_) => _cargar()),
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(_etiqueta(c),
                style: const TextStyle(fontWeight: FontWeight.bold)),
            Text(
                '${c['_fecha_cumple']} · Cumple ${c['_cumple']}',
                style: AppTexto.secundario.copyWith(
                    color: AppColores.textoSecundario(context))),
            if (diasPara != null && diasPara > 0)
              Text('en $diasPara día${diasPara == 1 ? '' : 's'}',
                  style: const TextStyle(
                      fontSize: 11, color: Colors.green)),
            const SizedBox(height: 4),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Check "Felicitado" con su propia área táctil.
                InkWell(
                  borderRadius: BorderRadius.circular(16),
                  onTap: () => _setFelicitado(id, !felicitado),
                  child: Padding(
                    padding: const EdgeInsets.all(6),
                    child: Icon(
                      felicitado
                          ? Icons.check_circle
                          : Icons.radio_button_unchecked,
                      size: 20,
                      color: felicitado
                          ? Colors.green
                          : AppColores.textoSecundario(context),
                    ),
                  ),
                ),
                // Botón Felicitar (wa.me).
                IconButton(
                  tooltip: 'Felicitar por WhatsApp',
                  icon: Icon(Icons.chat,
                      color: tieneTelefono
                          ? const Color(0xFF25D366)
                          : AppColores.textoSecundario(context)
                              .withValues(alpha: 0.4)),
                  onPressed: tieneTelefono
                      ? () => _felicitar(c)
                      : () => _agregarTelefono(c),
                ),
                // Botón Regalar mes + felicitar (solo dueño).
                // v1.7.0 (regla firme de Argón): una Cuenta a la
                // Casa se celebra pero NO recibe «regalo de mes»:
                // el botón se omite; Felicitar queda igual.
                if (AuthService().isOwner && !esCuentaCasa(c))
                  IconButton(
                    tooltip: regalado
                        ? 'Mes ya regalado este año'
                        : 'Regalar mes + felicitar',
                    icon: Icon(
                      regalado ? Icons.card_giftcard : Icons.redeem,
                      color: regalado
                          ? Colors.amber
                          : AppColores.naranja,
                    ),
                    onPressed: tieneTelefono
                        ? () => _regalarYFelicitar(c)
                        : () => _agregarTelefono(c),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
