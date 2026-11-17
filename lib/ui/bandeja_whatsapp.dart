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
import 'dart:async';

import '../negocio.dart';
import '../auth.dart';
import '../localdb.dart';
import '../tiempo.dart';
import 'app_bar.dart';
import 'componentes.dart';
import 'skeleton.dart';
import 'dialogo_telefono.dart';
import 'diseno.dart';
import 'ficha.dart';
import 'widgets.dart';

/// 1.25 Panel 13: el estado de un aviso dentro del lote —
/// el «resultado por partes» de la acción en lote. La
/// clave es la misma del registro de atendidos
/// (tipo + cliente_id).
String claveAvisoLote(Map<String, dynamic> a) =>
    '${a['tipo']}_${a['cliente_id']}';

enum EstadoAvisoLote { contactado, sinTelefono, pendiente }

EstadoAvisoLote estadoAvisoLote(
    Map<String, dynamic> a, Set<String> tocados) {
  if (tocados.contains(claveAvisoLote(a))) {
    return EstadoAvisoLote.contactado;
  }
  if (normalizarTelefonoWaMe('${a['telefono'] ?? ''}').isEmpty) {
    return EstadoAvisoLote.sinTelefono;
  }
  return EstadoAvisoLote.pendiente;
}

/// Los avisos agrupados por su estado en el lote (las tres
/// partes del resultado, en orden de lectura: hechos,
/// imposibles y restantes).
Map<EstadoAvisoLote, List<Map<String, dynamic>>> resumenLoteAvisos(
    List<Map<String, dynamic>> avisos, Set<String> tocados) {
  final grupos = <EstadoAvisoLote, List<Map<String, dynamic>>>{
    EstadoAvisoLote.contactado: [],
    EstadoAvisoLote.sinTelefono: [],
    EstadoAvisoLote.pendiente: [],
  };
  for (final a in avisos) {
    grupos[estadoAvisoLote(a, tocados)]!.add(a);
  }
  return grupos;
}

/// Rótulo corto del tipo de aviso para el resumen.
String rotuloTipoAvisoLote(String tipo) => switch (tipo) {
      'vencido' => 'Vencido',
      'vence_hoy' => 'Vence hoy',
      'por_vencer' => 'Por vencer',
      'recibo' => 'Recibo',
      'cumple' => 'Cumpleaños',
      _ => tipo,
    };

class BandejaWhatsappScreen extends StatefulWidget {
  /// 1.32 «Mostrador Táctico»: embebida = pestaña «Avisos
  /// WhatsApp» del Pilar 2 (sin su AppBar).
  final bool embebida;
  const BandejaWhatsappScreen({super.key, this.embebida = false});

  @override
  State<BandejaWhatsappScreen> createState() =>
      _BandejaWhatsappScreenState();
}

class _BandejaWhatsappScreenState extends State<BandejaWhatsappScreen>
    with WidgetsBindingObserver {
  bool _cargando = true;
  // 1.25 Panel 14: la carga falló — el vacío debe decirlo,
  // no «Sin avisos por hoy».
  bool _falloCarga = false;
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
  // SL-10 G04-5: los controles nacen PLEGADOS tras su
  // botón resumen; la lista de avisos es la protagonista.
  bool _controlesAbiertos = false;
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
    // Pasada 2 de Argón (1.20): si el SnackBar de confirmación
    // de un aviso anterior seguía en pantalla, su botón podía
    // marcar ese aviso viejo (o disparar el lote) a destiempo.
    // B6 (1.23): los tres avisos del flujo van por el helper
    // único (mostrarSnack ya limpia también la cola al entrar).
    // La pregunta conserva 4 s explícitos: hay que leerla y
    // decidir, no es un aviso de paso.
    mostrarSnack(
      context,
      '¿Enviaste el mensaje a ${a['nombre'] ?? 'este cliente'}?',
      duracion: const Duration(seconds: 4),
      accion: 'Sí, enviado',
      alAccion: () async {
        await _setAtendido(a, true);
        if (!mounted) return;
        if (enLote) {
          final quedan = _pendientesLote();
          mostrarSnack(
            context,
            quedan > 0
                ? 'Contactado. Quedan $quedan en el lote.'
                : 'Lote completo.',
            // Panel 13: al cerrar el lote, el snack lleva
            // al resultado por partes (qué se hizo, qué
            // no se pudo y qué falta).
            accion: quedan > 0 ? 'Siguiente' : 'Ver resumen',
            alAccion: quedan > 0 ? _enviarLote : _mostrarResumenLote,
          );
        } else {
          mostrarSnack(
            context,
            'Marcado como contactado.',
            accion: 'Deshacer',
            alAccion: () => _setAtendido(a, false),
          );
        }
      },
    );
  }

  /// Clave de "Atendido" en SQLite: tipo + cliente_id (la fecha va
  /// en su propia columna). La categoría evita que alguien atendido
  /// hoy en "Por vencer" aparezca atenuado mañana en "Vencen hoy".
  String _clave(Map<String, dynamic> a) => claveAvisoLote(a);

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
      // 1.25 T42: la marca de la pantalla de Cumpleaños (prefs
      // felicitado_<año>_<id>) también apaga el aviso aquí:
      // las dos pantallas comparten marca o el cliente recibe
      // dos felicitaciones el mismo día.
      try {
        final prefs = await SharedPreferences.getInstance();
        final anio = ahoraHabana().year;
        for (final a in avisos) {
          if ('${a['tipo']}' != 'cumple') continue;
          final cid = (a['cliente_id'] as num?)?.toInt() ?? 0;
          if (cid > 0 &&
              prefs.getBool('felicitado_${anio}_$cid') == true) {
            tocados.add(_clave(a));
          }
        }
      } catch (_) {}
      if (mounted) {
        setState(() {
          _avisos = avisos;
          _tocados = tocados;
          _cargando = false;
          _falloCarga = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _cargando = false;
          _falloCarga = true;
        });
      }
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

  /// 1.25 Panel 13: el resultado POR PARTES del lote —
  /// quién quedó contactado, quién no se pudo (sin
  /// teléfono) y quién falta, con nombres. Sin esto, el
  /// lote solo decía «completo» y el detalle se perdía.
  void _mostrarResumenLote() {
    final grupos = resumenLoteAvisos(_avisos, _tocados);
    Widget seccion(String titulo, IconData icono,
        List<Map<String, dynamic>> filas) {
      if (filas.isEmpty) return const SizedBox.shrink();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: AppEspacio.md),
          Row(children: [
            Icon(icono, size: 18, color: AppColores.naranja),
            const SizedBox(width: 6),
            Text('$titulo (${filas.length})',
                style: AppTexto.etiqueta),
          ]),
          const SizedBox(height: 4),
          for (final a in filas)
            Padding(
              padding: const EdgeInsets.only(left: AppEspacio.xl, bottom: 2),
              child: Text(
                  '${a['nombre'] ?? 'Sin nombre'} · '
                  '${rotuloTipoAvisoLote('${a['tipo'] ?? ''}')}',
                  style: AppTexto.secundario),
            ),
        ],
      );
    }

    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Resultado del lote'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              seccion('Contactados', Icons.check_circle_rounded,
                  grupos[EstadoAvisoLote.contactado]!),
              seccion('Sin teléfono', Icons.phone_disabled_rounded,
                  grupos[EstadoAvisoLote.sinTelefono]!),
              seccion('Pendientes', Icons.schedule_rounded,
                  grupos[EstadoAvisoLote.pendiente]!),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cerrar')),
        ],
      ),
    );
  }

  /// Modo lote: abre el próximo aviso pendiente (con teléfono) en
  /// wa.me; al volver, el snackbar ofrece «Siguiente».
  Future<void> _enviarLote() async {
    final siguiente = _siguienteLote();
    if (siguiente == null) {
      if (mounted) {
        mostrarSnack(context, 'Lote completo: no quedan avisos '
                'pendientes con teléfono.');
      }
      return;
    }
    await _abrirWhatsapp(siguiente, enLote: true);
  }

  Future<void> _abrirWhatsapp(Map<String, dynamic> a,
      {bool enLote = false, bool directo = false}) async {
    final waNum = normalizarTelefonoWaMe('${a['telefono'] ?? ''}');
    if (waNum.isEmpty) {
      if (mounted) {
        mostrarSnack(context, 'Este cliente no tiene teléfono registrado.', significado: SignificadoChip.alerta);
      }
      return;
    }
    // W9 (1.20): vista previa editable — el mensaje se
    // puede ajustar para ESTE envío antes de abrir WhatsApp
    // (no cambia la plantilla ni el aviso guardado). Un
    // texto vaciado vuelve al mensaje original.
    // 1.25 Panel 18: con [directo] (toque largo en el botón
    // verde) la PLANTILLA se envía tal cual, sin editor:
    // el recordatorio en 1 toque.
    final editado =
        directo ? '${a['mensaje']}' : await _editarAntesDeEnviar(a);
    if (editado == null || !mounted) return;
    // Pasada 2 de Argón (1.20): al abrir otro aviso, cualquier
    // SnackBar de confirmación anterior muere (su acción ya no
    // corresponde a este contexto).
    ScaffoldMessenger.of(context).clearSnackBars(); // 1.23: tambien la cola (gramatica de avisos)
    final texto =
        editado.trim().isEmpty ? '${a['mensaje']}' : editado;
    final url = Uri.parse(
        'https://wa.me/$waNum?text=${Uri.encodeComponent(texto)}');
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
        mostrarSnack(context, 'No se pudo abrir WhatsApp.', significado: SignificadoChip.error);
      }
    }
  }

  /// W9: muestra el editor del mensaje y devuelve el texto
  /// a enviar (null si se cancela).
  Future<String?> _editarAntesDeEnviar(Map<String, dynamic> a) {
    return showDialog<String>(
      context: context,
      builder: (_) => _DialogoEditarMensaje(
        nombre: '${a['nombre'] ?? 'el cliente'}',
        mensaje: '${a['mensaje']}',
      ),
    );
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
    // 1.25 T42: espejo inverso de la marca compartida — un
    // «cumple» atendido aquí marca Felicitado en la pantalla
    // de Cumpleaños (prefs), y desmarcar lo quita.
    if (tipo == 'cumple') {
      try {
        final prefs = await SharedPreferences.getInstance();
        final clave = 'felicitado_${ahoraHabana().year}_$cid';
        if (valor) {
          await prefs.setBool(clave, true);
        } else {
          await prefs.remove(clave);
        }
      } catch (_) {}
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

  /// v1.3.8 (1B): agregar el teléfono sin salir de la
  /// bandeja. 1.25 T122 (F6-16): el diálogo y el guardado
  /// viven en dialogo_telefono.dart, compartidos con
  /// Cumpleaños (estaban copiados).
  Future<void> _agregarTelefono(Map<String, dynamic> a) async {
    final cid = (a['cliente_id'] as num?)?.toInt() ?? 0;
    final tel = await dialogoAgregarTelefono(context,
        clienteId: cid, soloDueno: true);
    if (tel != null && mounted) {
      // Actualiza el aviso en memoria para activar el botón wa.me.
      setState(() => a['telefono'] = tel);
    }
  }

  /// v1.3.8: abre la ficha del cliente al tocar la tarjeta.
  void _irAFicha(Map<String, dynamic> a) {
    final cid = (a['cliente_id'] as num?)?.toInt() ?? 0;
    if (cid <= 0) return;
    Navigator.of(context)
        .push(RutaIron(
            builder: (_) => FichaScreen(clienteId: cid)))
        .then((_) => _cargar());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: widget.embebida
          ? null
          : appBarIron(
        context,
        'Avisos WhatsApp de hoy',
        acciones: [
          IconButton(
            tooltip: 'Actualizar',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _cargar,
          ),
        ],
      ),
      body: Column(
        children: [
          // 1.35 (campo nº 13): embebida en el pilar, sin
          // banda — el estado de sync lo dice una sola vez
          // la píldora de la cabecera de la app.
          if (!widget.embebida) const SyncBanner(),
          // v1.13.0: barra de progreso REAL (SQLite) + filtros +
          // modo lote.
          if (!_cargando && AuthService().isOwner && _avisos.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Builder(builder: (_) {
                final total = _avisos.length;
                final hechos = _avisos
                    .where((a) => _tocados.contains(_clave(a)))
                    .length;
                final ratio = total > 0 ? hechos / total : 0.0;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // SL-10 G04-5: el botón que RESUME los
                    // controles (progreso + filtros activos)
                    // y los despliega solo a petición.
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            '$hechos de $total contactados'
                            '${_soloConTelefono ? ' · solo con teléfono' : ''}'
                            '${_busqueda.isNotEmpty ? ' · «$_busqueda»' : ''}',
                            style: AppTexto.secundario.copyWith(
                                color:
                                    AppColores.textoSecundario(context)),
                          ),
                        ),
                        TextButton.icon(
                          onPressed: () => setState(() =>
                              _controlesAbiertos = !_controlesAbiertos),
                          icon: Icon(
                              _controlesAbiertos
                                  ? Icons.expand_less_rounded
                                  : Icons.expand_more_rounded,
                              size: 18),
                          label: const Text('Controles'),
                        ),
                      ],
                    ),
                    if (_controlesAbiertos) ...[
                      const SizedBox(height: 4),
                      LinearProgressIndicator(value: ratio),
                      const SizedBox(height: 8),
                      Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _busquedaCtrl,
                          decoration: const InputDecoration(
                            hintText: 'Buscar por nombre',
                            prefixIcon: Icon(Icons.search_rounded, size: 20),
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
                      icon: const Icon(Icons.send_rounded, size: 18),
                      label: Text(_pendientesLote() > 0
                          ? 'Enviar en lote (${_pendientesLote()} pendientes)'
                          : 'Lote completo'),
                    ),
                  ),
                  // 1.25 Panel 13: el resultado por partes
                  // del lote, consultable en cuanto hay
                  // actividad (no solo al terminar).
                  if (_tocados.isNotEmpty)
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton.icon(
                        onPressed: _mostrarResumenLote,
                        icon: const Icon(Icons.fact_check_rounded,
                            size: 18),
                        label: const Text('Resultado por partes'),
                      ),
                    ),
                      const Padding(
                        padding: EdgeInsets.only(top: 2),
                        child: Text(
                          'Mantén pulsado el botón verde de un aviso '
                          'para enviar su plantilla sin editar.',
                          style: AppTexto.minuscula,
                        ),
                      ),
                    ],
                  ],
                );
              }),
            ),
          Expanded(
            child: _cargando
                // 1.25 T114: esqueleto con la forma de la lista.
                ? const Padding(
                    padding: EdgeInsets.all(AppEspacio.lg),
                    child: SkeletonLista(items: 4))
                : !AuthService().isOwner
                    // v1.3.6 (auditoría Argón, Fix 1a): solo el dueño.
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(AppEspacio.xxl),
                          child: Text(
                            'Esta bandeja es solo para el dueño del gym.',
                            textAlign: TextAlign.center,
                            style: AppTexto.secundario,
                          ),
                        ),
                      )
                    : _avisos.isEmpty && _falloCarga
                    ? EstadoVacio(
                        icono: Icons.cloud_off_rounded,
                        titulo: 'No se pudo cargar la bandeja',
                        subtitulo: 'Los datos de este teléfono no '
                            'respondieron; puede que sí haya '
                            'avisos hoy.',
                        textoAccion: 'Reintentar',
                        onAccion: _cargar,
                      )
                    : _avisos.isEmpty
                    // 1.30 (Oleada D6, UI130-22): el vacío
                    // artesanal pasa al EstadoVacio de la
                    // casa, con el sobre de la lámina.
                    ? const EstadoVacio(
                        ilustracion: 'assets/vacio_sobre.webp',
                        icono: Icons.mark_chat_read_rounded,
                        titulo: 'Sin avisos por hoy.',
                        subtitulo:
                            'Cuando haya cumpleaños, vencimientos '
                            'o cobros del día, aparecerán aquí.',
                      )
                    : _avisosFiltrados.isEmpty
                    ? const Center(
                        child: Padding(
                          padding: EdgeInsets.all(AppEspacio.xxl),
                          child: Text(
                            'Ningún aviso coincide con los filtros.',
                            textAlign: TextAlign.center,
                            style: AppTexto.secundario,
                          ),
                        ),
                      )
                    : RefrescoIron(
                        onRefresh: _cargar,
                        child: ListView(
                          padding: const EdgeInsets.all(AppEspacio.lg),
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
    // SL-10 G04-11: UN solo lenguaje de icono en la
    // bandeja — la familia Material «rounded» de la
    // casa. Fuera los emojis que duplicaban al icono en
    // los títulos de sección y el único icono «outline»
    // (error_outline) entre todos los «rounded».
    const orden = [
      (
        tipo: 'vencido',
        titulo: 'Vencidos',
        icono: AppIconos.error, // 1.36 (136-277): glifo canónico de error
      ),
      (
        tipo: 'vence_hoy',
        titulo: 'Vencen hoy',
        icono: Icons.warning_amber_rounded
      ),
      (
        tipo: 'por_vencer',
        titulo: 'Por vencer',
        icono: Icons.schedule_rounded
      ),
      (
        tipo: 'recibo',
        titulo: 'Recibos de hoy',
        icono: Icons.receipt_long_rounded
      ),
      (tipo: 'cumple', titulo: 'Cumpleaños hoy', icono: Icons.cake_rounded),
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
              const EdgeInsets.only(top: AppEspacio.sm, bottom: AppEspacio.sm),
          child: Row(
            children: [
              Icon(seccion.icono,
                  color: AppColores.textoSecundario(context), size: 20),
              const SizedBox(width: 8),
              Text('${seccion.titulo} (${items.length})',
                  style: AppTexto.subtitulo),
            ],
          ),
        ),
        if (recientes.isNotEmpty) ...[
          const Padding(
            padding: EdgeInsets.only(bottom: AppEspacio.xs),
            child: Text('Hace 1–7 días',
                style: TextStyle(fontWeight: FontWeight.w600)),
          ),
          for (final a in recientes) _tarjeta(a),
        ],
        if (viejos.isNotEmpty) ...[
          const Padding(
            padding: EdgeInsets.only(bottom: AppEspacio.xs, top: AppEspacio.xs),
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
            const EdgeInsets.only(top: AppEspacio.sm, bottom: AppEspacio.sm),
        child: Row(
          children: [
            Icon(seccion.icono,
                color: AppColores.textoSecundario(context), size: 20),
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
                  padding: const EdgeInsets.all(AppEspacio.sm),
                  child: Icon(
                    atendido
                        ? Icons.check_circle_rounded
                        : Icons.radio_button_unchecked_rounded,
                    size: 22,
                    color: atendido
                        ? AppColores.exito
                        : AppColores.textoSecundario(context),
                  ),
                ),
              ),
              // 1.30 (Oleada D6, UI130-28): la bandeja era
              // la última lista sin foto — avatar con la
              // foto del aviso (o iniciales, como en
              // Buscar y Vencimientos).
              AvatarClienteConFoto(
                nombre: '${a['nombre'] ?? ''}',
                fotoStorage: a['foto_storage'] as String?,
                fotoLocal: a['foto_local'] as String?,
              ),
              const SizedBox(width: AppEspacio.sm),
              // v1.3.8: tocar la tarjeta abre la ficha del cliente.
              Expanded(
                child: InkWell(
                  borderRadius: BorderRadius.circular(AppRadio.sm),
                  onTap: () => _irAFicha(a),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: AppEspacio.xs),
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
                              const SizedBox(width: 8),
                              const Icon(Icons.check_circle_rounded,
                                  size: 16, color: AppColores.exito),
                            ],
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text('${a['detalle']}',
                            style: AppTexto.metadato.copyWith(color: AppColores.textoSecundario(context))),
                        if (atendido)
                          Text('✓ Atendido',
                              style: AppTexto.minuscula.copyWith(color: AppColores.exito, fontWeight: FontWeight.w600)),
                        if (!tieneTelefono)
                          InkWell(
                            onTap: () => _agregarTelefono(a),
                            child: Padding(
                              padding: const EdgeInsets.only(top: 2),
                              child: Text('Sin teléfono registrado · toca para agregar',
                                  style: AppTexto.minuscula.copyWith(
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
                borderRadius: BorderRadius.circular(AppRadio.xl),
                onTap: tieneTelefono ? () => _abrirWhatsapp(a) : null,
                // Panel 18: toque largo = plantilla directa.
                onLongPress: tieneTelefono
                    ? () => _abrirWhatsapp(a, directo: true)
                    : null,
                child: Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: tieneTelefono
                        ? AppColores.whatsapp
                        : AppColores.textoSecundario(context)
                            .withValues(alpha: 0.3),
                  ),
                  child: const Icon(Icons.chat_rounded,
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

/// W9 (1.20): editor del mensaje antes de enviar. Es dueño
/// de su controlador (se descarta con el diálogo) y devuelve
/// el texto al cerrar con «Abrir WhatsApp».
class _DialogoEditarMensaje extends StatefulWidget {
  final String nombre;
  final String mensaje;
  const _DialogoEditarMensaje(
      {required this.nombre, required this.mensaje});

  @override
  State<_DialogoEditarMensaje> createState() =>
      _DialogoEditarMensajeState();
}

class _DialogoEditarMensajeState
    extends State<_DialogoEditarMensaje> {
  late final _ctrl = TextEditingController(text: widget.mensaje);

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Mensaje para ${widget.nombre}'),
      content: TextField(
        controller: _ctrl,
        maxLines: 8,
        minLines: 3,
        autofocus: true,
        decoration:
            const InputDecoration(border: OutlineInputBorder()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _ctrl.text),
          child: const Text('Abrir WhatsApp'),
        ),
      ],
    );
  }
}
