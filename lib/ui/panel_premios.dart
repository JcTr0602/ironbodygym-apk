import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';

import '../auth.dart';
import '../localdb.dart';
import '../negocio.dart';
import '../premios_panel.dart';
import '../sync.dart';
import '../tiempo.dart';
import 'app_bar.dart';
import 'componentes.dart';
import 'diseno.dart';
import 'logros_premio_ui.dart';
import 'skeleton.dart';

/// 1.28 (M5-A4/C-R2M5-H2): señal entre pestañas del hub
/// de Premios — cuando en «Clientes» se CONCEDE un vale,
/// la Bandeja ya montada (TabBarView la conserva viva)
/// se entera y recarga: el vale nuevo no esperaba a que
/// el dueño saliera y volviera a entrar al hub.
final ValueNotifier<int> premiosAvisosExternos =
    ValueNotifier<int>(0);

/// 1.28 (M5-B6): reconcilia las marcas locales de la
/// bandeja EN LOTE — una lectura de metas por prefijo y
/// una consulta de estados por todas las ops (antes:
/// marca y estado vale a vale, en serie). La regla vive
/// en reconciliarMarcasVales (pura). Devuelve los ids
/// que deben seguir ocultos; las marcas de ops
/// rechazadas se borran aquí.
Future<Set<int>> ocultosPorMarcasLocales(
    BandejaPremios bandeja) async {
  final marcas = await LocalDb.instance
      .metasValoresConPrefijo('premio_vale_resuelto_');
  final opUuids = <String>[
    for (final v in bandeja.vales)
      if (marcas['premio_vale_resuelto_${v.id}'] != null)
        marcas['premio_vale_resuelto_${v.id}']!,
  ];
  final estados = await LocalDb.instance.estadosOps(opUuids);
  final rec = reconciliarMarcasVales(
    valeIds: bandeja.vales.map((v) => v.id),
    marcas: marcas,
    estados: estados,
  );
  for (final id in rec.marcasABorrar) {
    await LocalDb.instance.borrarMeta('premio_vale_resuelto_$id');
  }
  return rec.ocultos;
}

/// 1.28 (M5-B2): cuántos vales esperan decisión, para
/// enseñar el conteo FUERA de Premios (contador del
/// Panel y pastilla de la pestaña del hub) sin obligar
/// a entrar a la bandeja. null = no se pudo saber (sin
/// conexión o respuesta degradada): quien llama NO
/// enseña un 0 mentiroso.
Future<int?> contarValesPorAprobar() async {
  final visibles = await valesVisiblesPorAprobar();
  return visibles?.length;
}

/// 1.29 (Oleada 5, D-23): los vales VISIBLES por aprobar
/// (las mismas filas que [contarValesPorAprobar] cuenta:
/// una sola fuente, dos escaparates). El Panel los
/// necesita como filas para derivar los ítems «POR
/// REVISAR» del módulo Clientes — el distintivo es la
/// longitud de esta lista, no un entero paralelo.
/// null = no se pudo saber (misma regla que el conteo).
Future<List<ValePendiente>?> valesVisiblesPorAprobar() async {
  try {
    final res = await Supabase.instance.client
        .rpc('admin_premios_vales')
        .timeout(const Duration(seconds: 12));
    if (res is! Map) return null;
    final json = Map<String, dynamic>.from(res);
    if (json['ok'] == false ||
        json['vales'] is! List ||
        json['recientes'] is! List) {
      return null;
    }
    final bandeja = parseBandejaPremios(json);
    final ocultos = await ocultosPorMarcasLocales(bandeja);
    return valesVisibles(bandeja.vales, ocultos);
  } catch (_) {
    return null;
  }
}

/// Premios (Pieza G, 1.26): bandeja «Premios por
/// aprobar» del Panel — los vales que los clientes
/// reclamaron en su app por sus logros.
///
/// Aprobar NO marca nada aquí a la ligera: encola la op
/// regalar_dias_premio y el servidor aplica el pago
/// cortesía y marca el vale en Supabase contra el
/// op_uuid (una sola vez, aunque la op se reintente).
/// Rechazar sí es directo (RPC admin, no mueve dinero).
/// Los cargadores son inyectables para los tests.
class PremiosPanelScreen extends StatefulWidget {
  final Future<Map<String, dynamic>> Function()? cargarBandeja;
  final Future<void> Function(ValePendiente vale)? aprobarVale;
  final Future<Map<String, dynamic>> Function(
      int valeId, String nota)? rechazarVale;

  /// 1.29 (Oleada 6, FB-19): abrir el enlace wa.me del
  /// aviso de un vale resuelto (costura para los tests;
  /// por defecto, launchUrl externo como la bandeja).
  final Future<void> Function(String url)? abrirWhatsApp;

  /// 1.27: dentro del hub de Premios (pestañas) la
  /// pantalla no pinta su propia AppBar: la pone el hub.
  final bool embebida;

  const PremiosPanelScreen(
      {super.key,
      this.cargarBandeja,
      this.aprobarVale,
      this.rechazarVale,
      this.abrirWhatsApp,
      this.embebida = false});

  @override
  State<PremiosPanelScreen> createState() => _PremiosPanelScreenState();
}

class _PremiosPanelScreenState extends State<PremiosPanelScreen> {
  bool _cargando = true;
  bool _falloCarga = false;
  bool _resolviendo = false;
  // (1.36 H-B4 136-962) la resolución se marca POR TARJETA:
  // solo el vale afectado muestra «Aplicando…» /
  // «Rechazando…» y la lista no se recarga entera.
  int? _resolviendoId;
  String _resolviendoAccion = '';
  BandejaPremios _bandeja = BandejaPremios.vacia;
  Set<int> _resueltosLocales = {};

  // 1.28 (M5-A4/C-R2M5-H3): generación de carga — una
  // foto vieja que llega tarde no pisa el estado (y
  // _aprobar la incrementa al resolver: la carga en
  // vuelo en ese momento queda invalidada).
  int _genCarga = 0;

  @override
  void initState() {
    super.initState();
    premiosAvisosExternos.addListener(_alAvisoExterno);
    _cargar();
  }

  @override
  void dispose() {
    premiosAvisosExternos.removeListener(_alAvisoExterno);
    super.dispose();
  }

  void _alAvisoExterno() {
    if (mounted) _cargar();
  }

  Future<Map<String, dynamic>> _cargarBandejaReal() async {
    final res = await Supabase.instance.client
        .rpc('admin_premios_vales')
        .timeout(const Duration(seconds: 12));
    if (res is Map) return Map<String, dynamic>.from(res);
    // 1.28 (M5-A2 ★): una respuesta que no es un mapa NO
    // es una bandeja vacía: es un fallo, y se trata como
    // tal (antes devolvía {} y la pantalla anunciaba
    // «Sin vales pendientes» ante cualquier degradación).
    throw StateError('admin_premios_vales: respuesta no es un mapa');
  }

  Future<void> _cargar() async {
    final gen = ++_genCarga;
    setState(() {
      _cargando = true;
      _falloCarga = false;
    });
    try {
      final json = await (widget.cargarBandeja ?? _cargarBandejaReal)();
      // 1.28 (M5-A2 ★): la RPC NO devuelve clave 'ok' en
      // el éxito — devuelve {vales, recientes} — así que
      // lo que se valida es la FORMA: ok no puede ser
      // false y ambas listas deben venir como listas. Un
      // mapa sin esa forma es un fallo de carga, no una
      // bandeja vacía (lo cargado no miente).
      final formaOk = json['ok'] != false &&
          json['vales'] is List &&
          json['recientes'] is List;
      if (!formaOk) {
        if (mounted && gen == _genCarga) {
          setState(() {
            _cargando = false;
            _falloCarga = true;
          });
        }
        return;
      }
      final bandeja = parseBandejaPremios(json);
      // Vales ya resueltos en ESTE teléfono (op encolada):
      // fuera de la lista para no aprobarlos dos veces.
      // 1.28 (M5-A3 ★/C-R1M5-H1): la marca se RECONCILIA
      // con el estado real de su op — si el servidor la
      // RECHAZÓ, la marca se borra y el vale vuelve a ser
      // accionable (antes el vale quedaba bloqueado para
      // siempre en este teléfono pese al rechazo). Si la
      // op sigue en vuelo o ya se aplicó, sigue oculto;
      // si la op ya se purgó (sin estado), la marca se
      // conserva (conservador).
      // 1.28 (M5-B6): la misma reconciliación, en LOTE
      // (ver ocultosPorMarcasLocales): la regla no
      // cambia — rechazada libera el vale, el resto
      // sigue oculto — pero deja de costar una consulta
      // por vale en cada carga.
      final locales = await ocultosPorMarcasLocales(bandeja);
      if (!mounted || gen != _genCarga) return;
      setState(() {
        _bandeja = bandeja;
        _resueltosLocales = locales;
        _cargando = false;
      });
    } catch (_) {
      if (mounted && gen == _genCarga) {
        setState(() {
          _cargando = false;
          _falloCarga = true;
        });
      }
    }
  }

  /// Aprobación real: op de canje + espejo optimista +
  /// marca local anti-doble-aprobación (patrón del
  /// regalo de cumpleaños).
  ///
  /// 1.28 (M5-A3 ★): los tres pasos van en UNA
  /// transacción. Antes iban sueltos: si el proceso
  /// moría entre ellos quedaba una foto a medias (op
  /// sin marca — el vale reaparecía y podía aprobarse
  /// otra vez — o espejo adelantado sin op). Precedente
  /// de la casa: queueOpYMarcarEliminado. La lectura del
  /// espejo se hace FUERA: dentro de la transacción no
  /// se lee por LocalDb.db (regla anti-deadlock).
  Future<void> _aprobarReal(ValePendiente v) async {
    final opUuid = const Uuid().v4();
    final cli =
        await LocalDb.instance.mirrorPorIds('clientes', [v.clienteId]);
    final hastaActual = cli.isNotEmpty
        ? cli.first['pagado_hasta'] as String?
        : v.pagadoHasta;
    final nuevoHasta = previewHastaDias(hastaActual, v.premioDias);
    final d = await LocalDb.instance.db;
    await d.transaction((txn) async {
      // Ajuste Argón 1.28 (hallazgo #1): dentro de la
      // transacción se opera SOLO contra txn vía los
      // núcleos con ejecutor explícito (queueOpEn /
      // updateMirrorPagadoHastaEn / setMetaEn), que no
      // conocen el getter db: la garantía anti-deadlock
      // es estructural, no de disciplina del llamador.
      await LocalDb.instance.queueOpEn(
        txn,
        opUuid: opUuid,
        tipo: 'regalar_dias_premio',
        payload: {
          'cliente_id': v.clienteId,
          'vale_id': v.id,
          'fecha': hoyHabanaIso(),
        },
      );
      await LocalDb.instance
          .updateMirrorPagadoHastaEn(txn, v.clienteId, nuevoHasta);
      await LocalDb.instance
          .setMetaEn(txn, 'premio_vale_resuelto_${v.id}', opUuid);
    });
    unawaited(SyncEngine.instance.push());
  }

  Future<Map<String, dynamic>> _rechazarReal(
      int valeId, String nota) async {
    final res = await Supabase.instance.client.rpc(
      'admin_rechazar_vale_premio',
      params: {'p_vale_id': valeId, 'p_nota': nota},
    ).timeout(const Duration(seconds: 12));
    if (res is Map) return Map<String, dynamic>.from(res);
    return {};
  }

  /// 1.29 (Oleada 6, FB-19): tras resolver un vale, el
  /// aviso de éxito ofrece «Avisar por WhatsApp» con el
  /// mensaje ya compuesto, al teléfono que el propio vale
  /// trae. Sin teléfono válido no se ofrece (el aviso
  /// queda como siempre). Enviar es el toque humano
  /// sobre la acción: aquí solo se abre wa.me con el
  /// texto puesto.
  void _ofrecerAvisoWhatsApp({
    required String textoSnack,
    required ValePendiente v,
    required String mensaje,
  }) {
    final wa = normalizarTelefonoWaMe(v.telefono);
    if (wa.isEmpty) {
      mostrarSnack(context, textoSnack,
          significado: SignificadoChip.exito);
      return;
    }
    mostrarSnack(
      context,
      textoSnack,
      significado: SignificadoChip.exito,
      accion: 'Avisar por WhatsApp',
      alAccion: () async {
        try {
          await (widget.abrirWhatsApp ??
              (u) => launchUrl(Uri.parse(u),
                  mode: LaunchMode.externalApplication))(
              urlWaRecordatorio(wa, mensaje));
        } catch (_) {}
      },
      duracion: const Duration(seconds: 10),
    );
  }

  Future<void> _aprobar(ValePendiente v) async {
    // Argón 1.26 ALTA: la guarda se toma ANTES del
    // primer await (check-and-set síncrono, patrón
    // mi_turno). Antes se asignaba tras el diálogo y un
    // doble toque abría dos diálogos: dos ops con uuid
    // distinto, el espejo sumando dos veces y la
    // segunda op rechazada en el servidor para siempre.
    if (_resolviendo) return;
    setState(() {
      _resolviendo = true;
      _resolviendoId = v.id;
      _resolviendoAccion = 'Aplicando…';
    });
    try {
      final cli =
          await LocalDb.instance.mirrorPorIds('clientes', [v.clienteId]);
      final hastaActual = cli.isNotEmpty
          ? cli.first['pagado_hasta'] as String?
          : v.pagadoHasta;
      final nuevoHasta = previewHastaDias(hastaActual, v.premioDias);
      if (!mounted) return;
      final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('🏆 Aprobar premio'),
        content: Text(
          v.esManual
              ? 'Vale manual creado por ti para ${v.nombre}'
                  '${v.creadoNota.isNotEmpty ? ' («${v.creadoNota}»)' : ''}. '
                  'Al concederlo tenía ${v.diasAlReclamar} días '
                  'entrenados verificados por el servidor.\n\n'
                  'Premio: ${v.premioDias} días de mensualidad '
                  'gratis.\n'
                  'Su vencimiento pasaría a ${fmtFecha(nuevoHasta)}.'
              // 1.28 (M5-A8/C-R3M5-H2): un vale CONCEDIDO
              // por el dueño con un logro real (la nota de
              // creación viene llena) no se presenta como
              // «reclamó el logro»: lo concedió el dueño.
              : v.creadoNota.isNotEmpty
                  ? 'Vale concedido por ti para ${v.nombre} '
                      'con el logro '
                      '«${tituloLogroPremio(v.logroId)}» '
                      '(«${v.creadoNota}»). Al concederlo '
                      'tenía ${v.diasAlReclamar} días '
                      'entrenados verificados por el '
                      'servidor.\n\n'
                      'Premio: ${v.premioDias} días de '
                      'mensualidad gratis.\n'
                      'Su vencimiento pasaría a '
                      '${fmtFecha(nuevoHasta)}.'
                  : '${v.nombre} reclamó el logro '
                      '«${tituloLogroPremio(v.logroId)}» con '
                      '${v.diasAlReclamar} días entrenados verificados '
                      'por el servidor.\n\n'
                      'Premio: ${v.premioDias} días de mensualidad '
                      'gratis.\n'
                      'Su vencimiento pasaría a ${fmtFecha(nuevoHasta)}.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Ahora no')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Aprobar premio')),
        ],
      ),
    );
      if (ok != true || !mounted) return;
      // Argón 1.26 ALTA (segunda capa): si este vale ya
      // se resolvió en este teléfono (la marca sobrevive
      // a un reinicio de la app, la bandeja puede venir
      // vieja), no se encola otra op.
      final yaResuelto = await LocalDb.instance
          .getMeta('premio_vale_resuelto_${v.id}');
      if (yaResuelto != null) {
        if (!mounted) return;
        mostrarSnack(context, 'Ese vale ya estaba resuelto',
            significado: SignificadoChip.alerta);
        await _cargar();
        return;
      }
      await (widget.aprobarVale ?? _aprobarReal)(v);
      if (!mounted) return;
      // 1.28 (M5-A4/C-R2M5-H3): resolver invalida la
      // carga en vuelo: su foto vieja (sin este vale en
      // _resueltosLocales) no puede pisar el estado.
      _genCarga++;
      // 1.28 (M5-B2): la pestaña del hub refresca su
      // contador de pendientes al oír el aviso.
      premiosAvisosExternos.value++;
      setState(() => _resueltosLocales = {..._resueltosLocales, v.id});
      // FB-19: con el nuevo vencimiento YA calculado para
      // la confirmación, el aviso ofrece avisar al cliente.
      _ofrecerAvisoWhatsApp(
        textoSnack:
            'Premio aplicado a ${v.nombre}: se sincroniza solo',
        v: v,
        mensaje: mensajeWaValeAprobado(
            nombre: v.nombre,
            premioDias: v.premioDias,
            nuevoHastaIso: nuevoHasta),
      );
    } catch (_) {
      if (mounted) {
        mostrarSnack(context, 'No se pudo aplicar el premio',
            significado: SignificadoChip.error);
      }
    } finally {
      if (mounted) {
        setState(() {
          _resolviendo = false;
          _resolviendoId = null;
        });
      }
    }
  }

  Future<void> _rechazar(ValePendiente v) async {
    // Argón 1.26 ALTA: misma guarda síncrona que
    // _aprobar — antes del primer await, no tras el
    // diálogo (doble toque = dos diálogos apilados).
    if (_resolviendo) return;
    setState(() {
      _resolviendo = true;
      _resolviendoId = v.id;
      _resolviendoAccion = 'Rechazando…';
    });
    try {
      final nota = await showDialog<String>(
        context: context,
        builder: (_) => _DialogoRechazoVale(nombre: v.nombre),
      );
      if (nota == null || !mounted) return;
      final res =
          await (widget.rechazarVale ?? _rechazarReal)(v.id, nota);
      if (!mounted) return;
      if (res['ok'] == true) {
        // FB-19: el aviso del rechazo lleva el motivo que
        // el dueño escribió en el diálogo.
        _ofrecerAvisoWhatsApp(
          textoSnack: 'Vale de ${v.nombre} rechazado',
          v: v,
          mensaje: mensajeWaValeRechazado(
              nombre: v.nombre, motivo: nota),
        );
        // 1.28 (M5-B2): el contador del hub se refresca.
        premiosAvisosExternos.value++;
        // (1.36 H-B4 136-962) sin recarga entera: el vale
        // sale de la lista localmente, como al aprobar.
        _genCarga++;
        setState(
            () => _resueltosLocales = {..._resueltosLocales, v.id});
      } else {
        mostrarSnack(
            context,
            res['motivo'] == 'vale_ya_resuelto'
                ? 'Ese vale ya estaba resuelto'
                : 'No se pudo rechazar el vale',
            significado: SignificadoChip.alerta);
        await _cargar();
      }
    } catch (_) {
      if (mounted) {
        mostrarSnack(
            context, 'Sin conexión: el rechazo no se aplicó',
            significado: SignificadoChip.error);
      }
    } finally {
      if (mounted) {
        setState(() {
          _resolviendo = false;
          _resolviendoId = null;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!AuthService().isOwner) {
      const cuerpo = Center(
          child: Text('Solo el dueño aprueba premios.'));
      if (widget.embebida) return cuerpo;
      return Scaffold(
          appBar: appBarIron(context, 'Premios por aprobar'),
          body: cuerpo);
    }
    // SL-10 G13-2 (sync-una-vez): sin banda de sync en
    // Premios — el estado lo dice una sola vez el icono
    // de la cabecera de la app. (Se retira también el
    // alTerminarSync: la recarga llega por el refresco
    // de la propia bandeja.)
    final cuerpo = _cuerpo();
    if (widget.embebida) return cuerpo;
    return Scaffold(
      appBar: appBarIron(context, 'Premios por aprobar'),
      body: cuerpo,
    );
  }

  Widget _cuerpo() {
    if (_cargando) {
      // 1.28 (M5-C3): esqueleto con la forma de la
      // bandeja (intro + tarjetas de vale).
      return const SkeletonPremiosBandeja();
    }
    if (_falloCarga) {
      return EstadoVacio(
        icono: Icons.cloud_off_rounded,
        titulo: 'No se pudieron cargar los premios.',
        subtitulo:
            'La bandeja vive en el servidor: hace falta conexión.',
        textoAccion: 'Reintentar',
        onAccion: _cargar,
      );
    }
    final visibles = valesVisibles(_bandeja.vales, _resueltosLocales);
    final enCurso = _bandeja.vales.length - visibles.length;
    final recientes = _bandeja.recientes;
    // 1.28 (M5-B6): la lista se construye PEREZOSA
    // (builder): con el historial creciendo, montar
    // todas las tarjetas de golpe ya no hace falta.
    // Tramos: intro · nota en curso · vacío o vales ·
    // encabezado de recientes · recientes.
    final nVales = visibles.isEmpty ? 1 : visibles.length;
    final total = 1 +
        (enCurso > 0 ? 1 : 0) +
        nVales +
        (recientes.isNotEmpty ? 1 + recientes.length : 0);
    return RefrescoIron(
      onRefresh: _cargar,
      child: ListView.builder(
        padding: const EdgeInsets.all(AppEspacio.lg),
        itemCount: total,
        itemBuilder: (context, i) {
          var idx = i;
          if (idx == 0) {
            return const Padding(
              padding: EdgeInsets.only(bottom: 12),
              child: Text(
                'Los clientes reclaman vales en su app al cumplir '
                'un logro. El conteo de días lo verificó el '
                'servidor con sus sesiones subidas. Al aprobar, '
                'el premio se aplica como pago de cortesía y el '
                'vale queda marcado una sola vez.',
                style: AppTexto.secundario,
              ),
            );
          }
          idx--;
          if (enCurso > 0) {
            if (idx == 0) {
              return Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  '⏳ $enCurso vale(s) aprobado(s) aquí, '
                  'terminando de sincronizarse.',
                  style: AppTexto.secundario,
                ),
              );
            }
            idx--;
          }
          if (idx < nVales) {
            if (visibles.isEmpty) {
              return const EstadoVacio(
                icono: Icons.emoji_events_rounded,
                titulo: 'Sin vales pendientes.',
                subtitulo:
                    'Cuando un cliente cumpla un logro con premio, su vale llega aquí.',
              );
            }
            final v = visibles[idx];
            return Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: _tarjetaVale(v),
            );
          }
          idx -= nVales;
          if (idx == 0) {
            return const EncabezadoSeccion(
                titulo: 'Resueltos recientes');
          }
          idx--;
          final r = recientes[idx];
          // H-05 (Argón 1.27): switch por el ESTADO
          // real del vale, no por el booleano canjeado:
          // un vale 'anulado' (S7) se pintaba como
          // «Rechazado». Mismo patrón de
          // _tarjetaValeHistorial (clientes).
          // 1.28 (M5-C4): si la RPC trae el logro, la
          // fila lo nombra (pendiente de servidor: hoy
          // «recientes» aún no lo devuelve).
          return ListTile(
            leading: Icon(
                switch (r.estado) {
                  'canjeado' => Icons.emoji_events_rounded,
                  'anulado' => Icons.undo_rounded,
                  _ => Icons.block_rounded,
                },
                color: switch (r.estado) {
                  'canjeado' => AppColores.naranja,
                  'anulado' => AppColores.alerta,
                  _ => AppColores.textoSecundario(context),
                }),
            title: Text('${r.nombre} · ${r.premioDias} días'),
            subtitle: Text(
                '${switch (r.estado) {
                  'canjeado' => 'Canjeado',
                  'anulado' => 'Anulado',
                  _ => 'Rechazado',
                }}'
                '${r.logroId.isNotEmpty ? ' · ${tituloLogroPremio(r.logroId)}' : ''}'
                '${r.resueltoEn.isNotEmpty ? ' el ${fmtFechaDeInstanteServidor(r.resueltoEn)}' : ''}'
                '${r.resueltoNota.isNotEmpty ? ' · ${r.resueltoNota}' : ''}'),
          );
        },
      ),
    );
  }

  Widget _tarjetaVale(ValePendiente v) {
    return Tarjeta(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // 1.28 (M5-C4): la medalla del logro del
              // vale, no un trofeo genérico.
              MedallaLogroPremio(logroId: v.logroId),
              const SizedBox(width: 10),
              Expanded(
                child: Text(v.nombre, style: AppTexto.subtitulo),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            v.esManual
                ? 'Vale manual creado por ti · '
                    '${v.diasAlReclamar} días verificados al concederlo'
                // 1.28 (M5-A8/C-R3M5-H2): concesión del
                // dueño con logro real (nota de creación
                // llena): se dice concedido, no reclamado.
                : v.creadoNota.isNotEmpty
                    ? 'Vale concedido por ti · logro '
                        '«${tituloLogroPremio(v.logroId)}» · '
                        '${v.diasAlReclamar} días verificados'
                    : 'Logro «${tituloLogroPremio(v.logroId)}» · '
                        '${v.diasAlReclamar} días verificados',
            style: AppTexto.cuerpo,
          ),
          if (v.creadoNota.isNotEmpty)
            Text('📝 ${v.creadoNota}', style: AppTexto.cuerpo),
          Text(
            'Premio: ${v.premioDias} días de mensualidad gratis',
            style: AppTexto.cuerpo,
          ),
          Text(
            'Vence ahora: ${fmtFecha(v.pagadoHasta)}'
            '${v.creadoEn.isNotEmpty ? ' · Reclamado el ${fmtFechaDeInstanteServidor(v.creadoEn)}' : ''}',
            style: AppTexto.secundario,
          ),
          const SizedBox(height: 10),
          // (1.36 H-B4 136-962) solo ESTA tarjeta se bloquea
          // y dice qué está haciendo.
          if (_resolviendoId == v.id)
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 10),
                Text(_resolviendoAccion, style: AppTexto.secundario),
              ],
            )
          else
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: _resolviendo ? null : () => _rechazar(v),
                  child: const Text('Rechazar'),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: _resolviendo ? null : () => _aprobar(v),
                  icon: const Icon(Icons.done_all_rounded, size: 18),
                  label: const Text('Aprobar premio'),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

/// Diálogo de rechazo con nota opcional (controlador
/// propio con dispose, regla de la casa).
class _DialogoRechazoVale extends StatefulWidget {
  final String nombre;
  const _DialogoRechazoVale({required this.nombre});

  @override
  State<_DialogoRechazoVale> createState() =>
      _DialogoRechazoValeState();
}

class _DialogoRechazoValeState extends State<_DialogoRechazoVale> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Rechazar vale'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('El vale de ${widget.nombre} se cerrará sin '
              'aplicar el premio. El cliente lo verá como no '
              'aprobado.'),
          const SizedBox(height: 12),
          TextField(
            controller: _ctrl,
            decoration: const InputDecoration(
                labelText: 'Nota (opcional)'),
            maxLength: 200,
          ),
        ],
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar')),
        FilledButton(
          onPressed: () => Navigator.pop(context, _ctrl.text.trim()),
          style: FilledButton.styleFrom(
              backgroundColor: AppColores.error),
          child: const Text('Rechazar vale'),
        ),
      ],
    );
  }
}
