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
import 'app_bar.dart';
import 'componentes.dart';
import 'skeleton.dart';
import 'dialogo_telefono.dart';

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
  // #4 (Argón cumpleaños): regalos en curso por cliente. Sin esto,
  // un doble toque abría dos diálogos y confirmar los dos aplicaba
  // el regalo dos veces (el segundo extendía otros 30 días).
  final Set<int> _regalando = {};

  // 1.26 (auditoría de botones, MEDIA 4 + BAJA): felicitaciones
  // en curso por cliente (sin esto, un doble toque abría
  // WhatsApp dos veces) y fallo de carga distinguible de
  // «sin cumpleaños» (antes una carga fallida se disfrazaba
  // de lista vacía).
  final Set<int> _felicitando = {};
  bool _falloCarga = false;

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

  // 1.36 H-C1 (136-588): generación de carga — una
  // respuesta vieja no pisa la lista más nueva.
  int _cargaGen = 0;

  Future<void> _cargar() async {
    // Argón #10-4: _anio se fijaba solo en initState. Si la app
    // quedaba abierta de un año para otro y se refrescaba, las
    // claves de felicitado/regalo usaban el año viejo.
    // 1.36 H-C1 (136-588): el año se FIJA al arrancar la
    // carga y toda la carga usa ese año, no el del campo
    // mutable a mitad de camino.
    final gen = ++_cargaGen;
    final anioFijado = '${ahoraHabana().year}';
    _anio = anioFijado;
    setState(() {
      _cargando = true;
      _falloCarga = false;
    });
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
      // 1.36 H-C1 (136-593): UNA sola pasada de consultas
      // para todos los ids (antes, 2 consultas por cliente).
      final ids = <int>{
        for (final c in [...proximos, ...mes])
          (c['id'] as num?)?.toInt() ?? 0,
      }..removeWhere((i) => i <= 0);
      final regalados = await _regaladosDelAnio(ids, anioFijado);
      if (!mounted || gen != _cargaGen) return;
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
      if (mounted && gen == _cargaGen) {
        setState(() {
          _cargando = false;
          _falloCarga = true;
        });
      }
    }
  }

  /// 1.36 H-C1 (136-593): los regalados del año para un
  /// conjunto de clientes, con las MISMAS dos fuentes que
  /// [_regaloAplicado] (meta anual + pagos de cortesía del
  /// año que no sean canje de premios) pero en una sola
  /// pasada de consultas.
  Future<Set<int>> _regaladosDelAnio(
      Set<int> ids, String anio) async {
    final out = <int>{};
    if (ids.isEmpty) return out;
    try {
      final d = await LocalDb.instance.db;
      final claves = [for (final id in ids) 'regalo_cumple_${id}_$anio'];
      final metas = await d.rawQuery(
          'SELECT k FROM meta WHERE k IN '
          '(${List.filled(claves.length, '?').join(',')})',
          claves);
      for (final m in metas) {
        final k = '${m['k']}';
        final id = int.tryParse(
            k.substring('regalo_cumple_'.length, k.length - anio.length - 1));
        if (id != null) out.add(id);
      }
      final filas = await d.rawQuery(
          'SELECT cliente_id, data FROM pagos WHERE metodo = ? '
          'AND fecha LIKE ? AND cliente_id IN '
          '(${List.filled(ids.length, '?').join(',')})',
          ['cortesia', '$anio%', ...ids]);
      for (final f in filas) {
        try {
          final p = jsonDecode('${f['data']}') as Map<String, dynamic>;
          if (p['periodo'] == 'personalizado') continue;
        } catch (_) {
          continue;
        }
        final id = (f['cliente_id'] as num?)?.toInt() ?? 0;
        if (id > 0) out.add(id);
      }
    } catch (_) {}
    return out;
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
    // 1.25 T42: la marca se COMPARTE con la Bandeja WhatsApp
    // (su marca vive en SQLite por día): felicitar aquí apaga
    // el aviso «cumple» de hoy allí, y desmarcar lo revierte.
    // Antes cada pantalla marcaba en su propio almacén y el
    // cliente podía recibir dos felicitaciones el mismo día.
    try {
      if (valor) {
        await LocalDb.instance
            .marcarAvisoWaContactado(id, 'cumple', hoyHabanaIso());
      } else {
        await LocalDb.instance.desmarcarAvisoWaContactado(
            id, 'cumple', hoyHabanaIso());
      }
    } catch (_) {}
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

  /// 1.26 (auditoría de botones, MEDIA 4): abrir WhatsApp
  /// NO prueba que el mensaje se envió (launchUrl solo
  /// confirma que la app abrió con el texto listo). La
  /// marca «Felicitado» — que además apaga el aviso en la
  /// Bandeja — solo se pone si el usuario confirma el
  /// envío al volver, igual que la Bandeja pregunta el
  /// resultado desde la 1.13.
  Future<bool> _confirmarEnvioWhatsApp(String nombre) async {
    if (!mounted) return false;
    final r = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('¿Se envió la felicitación?'),
        content: Text('WhatsApp se abrió con el mensaje listo '
            'para $nombre. Solo se marca «Felicitado» si '
            'confirmas que lo enviaste.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('No lo envié')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Sí, enviado')),
        ],
      ),
    );
    return r == true;
  }

  /// 2B: felicitar por WhatsApp (SOLO saludo, sin mencionar regalo).
  /// 1.26 (BAJA): guarda por cliente, como _regalarYFelicitar.
  Future<void> _felicitar(Map<String, dynamic> c) async {
    final idPre = (c['id'] as num?)?.toInt() ?? 0;
    if (idPre <= 0 || !mounted) return;
    if (!_felicitando.add(idPre)) return;
    try {
      await _felicitarFlujo(c);
    } finally {
      _felicitando.remove(idPre);
    }
  }

  Future<void> _felicitarFlujo(Map<String, dynamic> c) async {
    final id = (c['id'] as num?)?.toInt() ?? 0;
    final nombre = '${c['nombre'] ?? 'Cliente'}';
    // 1.32 (D-1, familia teléfono efectivo): el wa.me sale del
    // teléfono EFECTIVO (movil primero): con el crudo, al
    // migrado (carnet en `telefono`) se le decía «no tiene
    // teléfono» y al de número viejo el saludo le iba a otra
    // persona.
    final waNum = telefonoEfectivoWa(c);
    if (waNum.isEmpty) {
      if (mounted) {
        mostrarSnack(context, 'Este cliente no tiene teléfono registrado.', significado: SignificadoChip.alerta);
      }
      return;
    }
    // Corrección de campo 1.21 (2026-11-02): si el mes ya se
    // regaló este año, la felicitación anuncia el regalo con
    // las dos fechas; el saludo pelado solo va cuando aún no
    // hay regalo (antes, felicitar tras regalar dejaba al
    // cliente sin enterarse del mes ni de su nuevo vencimiento).
    final regalo = await regaloCumpleDelAnio(id);
    final mensaje = regalo != null
        ? mensajeCumpleConRegalo(
            nombre: nombre,
            anteriorIso: regalo['anterior'] as String?,
            nuevoIso: '${regalo['nuevo']}',
          )
        : '¡Feliz cumpleaños, $nombre! 🎂\n'
            'De parte de todo el equipo de Iron Body Gym, '
            'que tengas un día excelente 💪$lineaMensajeAutomatico';
    final url = Uri.parse(
        'https://wa.me/$waNum?text=${Uri.encodeComponent(mensaje)}');
    // 1.36 H-B1 (136-320): launchUrl puede devolver
    // false SIN lanzar (nadie abre el enlace): cuenta
    // igual que el fallo.
    bool ok;
    try {
      ok = await launchUrl(url, mode: LaunchMode.externalApplication);
    } catch (_) {
      ok = false;
    }
    if (!ok) {
      if (mounted) {
        mostrarSnack(context, 'No se pudo abrir WhatsApp.', significado: SignificadoChip.error);
      }
      return;
    }
    // 1.26 (MEDIA 4): la marca espera la confirmación.
    if (await _confirmarEnvioWhatsApp(nombre)) {
      await _setFelicitado(id, true);
    }
  }

  /// 2C: regalar mes + felicitar. Aplica el regalo (verificando en BD
  /// que no se haya aplicado ya) y abre wa.me con la nueva fecha.
  Future<void> _regalarYFelicitar(Map<String, dynamic> c) async {
    final idPre = (c['id'] as num?)?.toInt() ?? 0;
    if (idPre <= 0 || !mounted) return;
    // Pasada 2 de Argón (1.20): el candado se libera en finally;
    // antes había 6 removes manuales y una excepción intermedia
    // dejaba el cliente bloqueado hasta cerrar la pantalla.
    if (!_regalando.add(idPre)) return;
    try {
      await _regalarYFelicitarFlujo(c, idPre);
    } finally {
      _regalando.remove(idPre);
    }
  }

  Future<void> _regalarYFelicitarFlujo(
      Map<String, dynamic> c, int id) async {
    // #4 (Argón cumpleaños): un solo flujo por cliente (el Set
    // devuelve false si ya está en curso).
    // Misma clase que #10-4: la clave anual del regalo debe usar
    // el año actual, no el de cuando se abrió la pantalla.
    _anio = '${ahoraHabana().year}';
    // Bloqueo anti-duplicado: operación real en BD (Argón).
    if (await _regaloAplicado(id)) {
      if (mounted) {
        mostrarSnack(context, 'Ya se regaló el mes este año.', significado: SignificadoChip.alerta);
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
          BotonPrimario(
            texto: 'Regalar',
            onPressed: () => Navigator.of(ctx).pop(true),
            expandido: false,
          ),
        ],
      ),
    );
    if (confirmar != true) {
      return;
    }
    if (!mounted) {
      return;
    }
    // #4 (Argón cumpleaños): re-chequeo tras confirmar. Otro
    // diálogo del mismo cliente pudo aplicar mientras este
    // esperaba: sin esto, el segundo regalo extendía 30 días más.
    if (await _regaloAplicado(id)) {
      if (mounted) {
        mostrarSnack(context, 'Ya se regaló el mes este año.', significado: SignificadoChip.alerta);
      }
      return;
    }
    // 1.36 H-C1 (136-590): los cuatro pasos locales del
    // regalo (espejo, op, procedencia y candado anual) van
    // en UNA transacción local: un corte a mitad ya no
    // deja el regalo a medias (antes, awaits sueltos).
    final opUuidRegalo = const Uuid().v4();
    try {
      final d = await LocalDb.instance.db;
      await d.transaction((txn) async {
        // a) Espejo local.
        await LocalDb.instance
            .updateMirrorPagadoHasta(id, nuevoHasta, txn: txn);
        // b) Op al servidor.
        await LocalDb.instance.queueOp(
          opUuid: opUuidRegalo,
          tipo: 'regalar_mes_cumpleanos',
          payload: {
            'cliente_id': id,
            'fecha': hoyHabanaIso(),
          },
          txn: txn,
        );
        // b1) YS-5 (H5 de la revisión de Argón): el regalo pinta
        // el vencimiento SIN ser un pago — sella SU op como
        // autora del vencimiento vigente. Sin el sello, la
        // procedencia quedaba con el uuid de un pago anterior
        // (quizá ya muerto) y la guarda de identidad de la
        // reversión decidía sobre ese dato podrido.
        await LocalDb.instance
            .registrarProcedenciaPago(id, opUuidRegalo, txn: txn);
        // c) Meta local (candado anual).
        await LocalDb.instance.setMeta(
            'regalo_cumple_${id}_$_anio',
            jsonEncode(
                {'anterior': pagadoHastaActual, 'nuevo': nuevoHasta}),
            executor: txn);
      });
    } catch (_) {
      if (mounted) {
        mostrarSnack(context,
            'No se pudo aplicar el regalo. Inténtalo de nuevo.',
            significado: SignificadoChip.error);
      }
      return;
    }
    unawaited(SyncEngine.instance.push());
    if (mounted) {
      setState(() => _regaladosAnio.add(id));
    }
    // d) WhatsApp con el mensaje del regalo (formato de FichaScreen).
    // #1 (Argón cumpleaños + regla de Jc): el regalo YA se aplicó
    // arriba; sin teléfono NO se devuelve en silencio: se avisa
    // para felicitar en persona.
    // 1.32 (D-1): también con el teléfono EFECTIVO.
    final waNum = telefonoEfectivoWa(c);
    if (waNum.isEmpty) {
      if (mounted) {
        mostrarSnack(context, 'Regalo aplicado. Este cliente no tiene '
                'teléfono: felicítalo en persona.', significado: SignificadoChip.exito);
      }
      return;
    }
    if (!mounted) {
      return;
    }
    // Argón Clientes #9: el mensaje sale de la función
    // CANÓNICA (mensajeCumpleConRegalo, la misma que usa
    // «Felicitar» cuando el regalo ya existe): esta pantalla
    // lo armaba a mano y era un tercer formato. (El formato
    // de la FICHA sí es distinto a propósito: excepción
    // escrita por Jc el 2026-11-01.)
    final mensaje = mensajeCumpleConRegalo(
      nombre: nombre,
      anteriorIso: (pagadoHastaActual != null &&
              pagadoHastaActual.length >= 10)
          ? pagadoHastaActual
          : null,
      nuevoIso: nuevoHasta,
    );
    final url = Uri.parse(
        'https://wa.me/$waNum?text=${Uri.encodeComponent(mensaje.trim())}');
    // 136-320: el false de launchUrl también es fallo.
    bool ok;
    try {
      ok = await launchUrl(url, mode: LaunchMode.externalApplication);
    } catch (_) {
      ok = false;
    }
    if (!ok) {
      if (mounted) {
        mostrarSnack(context, 'Regalo aplicado. No se pudo abrir WhatsApp.', significado: SignificadoChip.exito);
      }
      return;
    }
    // 1.26 (MEDIA 4): el regalo ya se aplicó (es real);
    // la marca «Felicitado» espera la confirmación del
    // envío, igual que en _felicitarFlujo.
    if (await _confirmarEnvioWhatsApp(nombre)) {
      await _setFelicitado(id, true);
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

  /// 1B reutilizado: agregar teléfono sin salir de la
  /// pantalla. 1.25 T122 (F6-16): diálogo y guardado
  /// compartidos en dialogo_telefono.dart.
  Future<void> _agregarTelefono(Map<String, dynamic> c) async {
    final id = (c['id'] as num?)?.toInt() ?? 0;
    final tel = await dialogoAgregarTelefono(context, clienteId: id);
    if (tel != null && mounted) {
      // 1.36 H-C1 (136-593): el teléfono EFECTIVO manda
      // 'movil' primero (telefonoEfectivoWa): se reflejan
      // AMBOS campos para que la tarjeta use el nuevo
      // número ya, sin esperar a la recarga.
      setState(() {
        c['telefono'] = tel;
        c['movil'] = tel;
      });
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
      // 1.25 T122 (F6-17): appBarIron, la barra compartida.
      appBar: appBarIron(
        context,
        'Cumpleaños de $mes',
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
                // 1.25 T114: esqueleto con la forma de la lista.
                ? const Padding(
                    padding: EdgeInsets.all(AppEspacio.lg),
                    child: SkeletonLista(items: 3))
                : _falloCarga
                    // 1.26 (BAJA): la carga fallida NO es «sin
                    // cumpleaños»: se dice y se deja reintentar.
                    ? EstadoVacio(
                        icono: Icons.cloud_off_rounded,
                        titulo: 'No se pudieron cargar los cumpleaños.',
                        subtitulo:
                            'Revisa los datos del teléfono y vuelve a intentarlo.',
                        textoAccion: 'Reintentar',
                        onAccion: _cargar,
                      )
                    : TabBarView(
                    controller: _tabs,
                    children: [
                      // 1.36 H-B2 (136-591): frases COMPLETAS
                      // por pestaña (antes se interpolaba
                      // «en los $etiqueta» y salía «en los
                      // este mes»).
                      _lista(_proximos,
                          vacio: 'en los próximos 7 días',
                          conteo: 'en los próximos 7 días'),
                      _lista(_mes,
                          vacio: 'en este mes',
                          conteo: 'este mes'),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _lista(List<Map<String, dynamic>> items,
      {required String vacio, required String conteo}) {
    if (items.isEmpty) {
      return EstadoVacio(
        ilustracion: 'assets/vacio_pastel.webp',
        icono: Icons.cake_rounded,
        titulo: 'Sin cumpleaños $vacio.',
        subtitulo: 'La fecha sale del carnet de identidad.',
        textoAccion: 'Actualizar',
        onAccion: _cargar,
      );
    }
    // v1.3.8 (2A/2D): el contador refleja las tarjetas visibles.
    final fel = items
        .where((c) => _felicitados
            .contains(_claveFelicitado((c['id'] as num?)?.toInt() ?? 0)))
        .length;
    return RefrescoIron(
      onRefresh: _cargar,
      child: ListView.builder(
        itemCount: items.length + 1,
        itemBuilder: (ctx, i) {
          if (i == 0) {
            return Padding(
              padding: const EdgeInsets.all(AppEspacio.md),
              child: Text(
                '$fel de ${items.length} felicitados $conteo',
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
    // 1.32 (D-1): «tiene teléfono» también por el efectivo —
    // el migrado con número solo en `movil` SÍ tiene.
    final tieneTelefono = telefonoEfectivoWa(c).isNotEmpty;
    final diasPara = c['_dias_para'] as int?;
    // CU1 (estéticas 1.19): el cumpleañero de hoy destaca sobre
    // el resto (misma condición que la etiqueta '¡Hoy!').
    // Panel Terra B3: antes se comparaba solo el día del mes y
    // un cumpleaños del 30 de noviembre destacaba el 30 de octubre.
    final esHoy = diasPara == 0;
    // 1.36 H-B2 (136-592): el felicitado se dice con un chip
    // «Felicitado», no bajando la opacidad de toda la tarjeta
    // (ilegible y sin contraste garantizado).
    return Container(
        decoration: esHoy
            ? BoxDecoration(
                color: AppColores.alerta.withValues(alpha: 0.12),
                border: const Border(
                  left: BorderSide(
                      color: AppColores.alerta, width: 4),
                ),
              )
            : null,
        child: FilaCliente(
        cliente: c,
        avisoChip: felicitado ? 'Felicitado' : null,
        onTap: () => Navigator.of(context)
            .push(RutaIron(
                builder: (_) => FichaScreen(clienteId: id)))
            .then((_) => _cargar()),
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (esHoy)
                  const Icon(Icons.cake_rounded,
                      size: 16, color: AppColores.alerta),
                if (esHoy) const SizedBox(width: 4),
                Text(_etiqueta(c),
                    style: AppTexto.etiqueta.copyWith(
                        fontWeight: FontWeight.bold,
                        color: esHoy ? AppColores.alerta : null)),
              ],
            ),
            Text(
                '${c['_fecha_cumple']} · Cumple ${c['_cumple']}',
                style: AppTexto.secundario.copyWith(
                    color: AppColores.textoSecundario(context))),
            if (diasPara != null && diasPara > 0)
              Text('en $diasPara día${diasPara == 1 ? '' : 's'}',
                  style: AppTexto.minuscula
                      .copyWith(color: AppColores.exito)),
            const SizedBox(height: 4),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Check "Felicitado" con su propia área táctil.
                InkWell(
                  borderRadius: BorderRadius.circular(AppRadio.lg),
                  onTap: () => _setFelicitado(id, !felicitado),
                  child: Padding(
                    padding: const EdgeInsets.all(AppEspacio.sm),
                    child: Icon(
                      felicitado
                          ? Icons.check_circle_rounded
                          : Icons.radio_button_unchecked_rounded,
                      size: 20,
                      color: felicitado
                          ? AppColores.exito
                          : AppColores.textoSecundario(context),
                    ),
                  ),
                ),
                // Botón Felicitar (wa.me).
                IconButton(
                  // 1.26 (BAJA): sin teléfono el botón abre
                  // «agregar teléfono»; el tooltip lo dice.
                  tooltip: tieneTelefono
                      ? 'Felicitar por WhatsApp'
                      : 'Agregar teléfono',
                  icon: Icon(Icons.chat_rounded,
                      color: tieneTelefono
                          ? AppColores.whatsapp
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
                // #1 (Argón cumpleaños + regla de Jc): sin teléfono
                // el regalo SE APLICA IGUAL y se avisa (antes el
                // botón mandaba a agregar el teléfono y el regalo
                // no se aplicaba).
                if (AuthService().isOwner && !esCuentaCasa(c))
                  IconButton(
                    tooltip: regalado
                        ? 'Mes ya regalado este año'
                        : 'Regalar mes + felicitar',
                    icon: Icon(
                      regalado ? Icons.card_giftcard_rounded : Icons.redeem_rounded,
                      color: regalado
                          ? AppColores.alerta
                          : AppColores.naranja,
                    ),
                    // 1.36 H-C1 (136-593): ya regalado, el
                    // botón se DESHABILITA (antes devolvía
                    // solo un snack negativo al tocarlo).
                    onPressed:
                        regalado ? null : () => _regalarYFelicitar(c),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
