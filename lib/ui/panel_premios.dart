import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
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
import 'widgets.dart';

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

  /// 1.27: dentro del hub de Premios (pestañas) la
  /// pantalla no pinta su propia AppBar: la pone el hub.
  final bool embebida;

  const PremiosPanelScreen(
      {super.key,
      this.cargarBandeja,
      this.aprobarVale,
      this.rechazarVale,
      this.embebida = false});

  @override
  State<PremiosPanelScreen> createState() => _PremiosPanelScreenState();
}

class _PremiosPanelScreenState extends State<PremiosPanelScreen> {
  bool _cargando = true;
  bool _falloCarga = false;
  bool _resolviendo = false;
  BandejaPremios _bandeja = BandejaPremios.vacia;
  Set<int> _resueltosLocales = {};

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<Map<String, dynamic>> _cargarBandejaReal() async {
    final res = await Supabase.instance.client
        .rpc('admin_premios_vales')
        .timeout(const Duration(seconds: 12));
    if (res is Map) return Map<String, dynamic>.from(res);
    return {};
  }

  Future<void> _cargar() async {
    setState(() {
      _cargando = true;
      _falloCarga = false;
    });
    try {
      final json = await (widget.cargarBandeja ?? _cargarBandejaReal)();
      final bandeja = parseBandejaPremios(json);
      // Vales ya resueltos en ESTE teléfono (op encolada):
      // fuera de la lista para no aprobarlos dos veces.
      final locales = <int>{};
      for (final v in bandeja.vales) {
        if (await LocalDb.instance.getMeta(
                'premio_vale_resuelto_${v.id}') !=
            null) {
          locales.add(v.id);
        }
      }
      if (!mounted) return;
      setState(() {
        _bandeja = bandeja;
        _resueltosLocales = locales;
        _cargando = false;
      });
    } catch (_) {
      if (mounted) {
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
  Future<void> _aprobarReal(ValePendiente v) async {
    final opUuid = const Uuid().v4();
    final cli =
        await LocalDb.instance.mirrorPorIds('clientes', [v.clienteId]);
    final hastaActual = cli.isNotEmpty
        ? cli.first['pagado_hasta'] as String?
        : v.pagadoHasta;
    final nuevoHasta = previewHastaDias(hastaActual, v.premioDias);
    await LocalDb.instance.queueOp(
      opUuid: opUuid,
      tipo: 'regalar_dias_premio',
      payload: {
        'cliente_id': v.clienteId,
        'vale_id': v.id,
        'fecha': hoyHabanaIso(),
      },
    );
    await LocalDb.instance
        .updateMirrorPagadoHasta(v.clienteId, nuevoHasta);
    await LocalDb.instance
        .setMeta('premio_vale_resuelto_${v.id}', opUuid);
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

  Future<void> _aprobar(ValePendiente v) async {
    // Argón 1.26 ALTA: la guarda se toma ANTES del
    // primer await (check-and-set síncrono, patrón
    // mi_turno). Antes se asignaba tras el diálogo y un
    // doble toque abría dos diálogos: dos ops con uuid
    // distinto, el espejo sumando dos veces y la
    // segunda op rechazada en el servidor para siempre.
    if (_resolviendo) return;
    setState(() => _resolviendo = true);
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
          '${v.nombre} reclamó el logro '
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
      setState(() => _resueltosLocales = {..._resueltosLocales, v.id});
      mostrarSnack(
          context, 'Premio aplicado a ${v.nombre}: se sincroniza solo',
          significado: SignificadoChip.exito);
    } catch (_) {
      if (mounted) {
        mostrarSnack(context, 'No se pudo aplicar el premio',
            significado: SignificadoChip.error);
      }
    } finally {
      if (mounted) setState(() => _resolviendo = false);
    }
  }

  Future<void> _rechazar(ValePendiente v) async {
    // Argón 1.26 ALTA: misma guarda síncrona que
    // _aprobar — antes del primer await, no tras el
    // diálogo (doble toque = dos diálogos apilados).
    if (_resolviendo) return;
    setState(() => _resolviendo = true);
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
        mostrarSnack(context, 'Vale de ${v.nombre} rechazado',
            significado: SignificadoChip.exito);
        await _cargar();
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
      if (mounted) setState(() => _resolviendo = false);
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
    final cuerpo = Column(
      children: [
        // Argón 1.26 MEDIA: al terminar el sync la
        // bandeja se recarga (el aviso «terminando de
        // sincronizarse» no queda congelado).
        SyncBanner(alTerminarSync: _cargar),
        Expanded(child: _cuerpo()),
      ],
    );
    if (widget.embebida) return cuerpo;
    return Scaffold(
      appBar: appBarIron(context, 'Premios por aprobar'),
      body: cuerpo,
    );
  }

  Widget _cuerpo() {
    if (_cargando) {
      return const EstadoCargando(texto: 'Cargando premios…');
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
    return RefreshIndicator(
      onRefresh: _cargar,
      child: ListView(
        padding: const EdgeInsets.all(AppEspacio.lg),
        children: [
          const Text(
            'Los clientes reclaman vales en su app al cumplir '
            'un logro. El conteo de días lo verificó el '
            'servidor con sus sesiones subidas. Al aprobar, '
            'el premio se aplica como pago de cortesía y el '
            'vale queda marcado una sola vez.',
            style: AppTexto.secundario,
          ),
          const SizedBox(height: 12),
          if (enCurso > 0)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                '⏳ $enCurso vale(s) aprobado(s) aquí, '
                'terminando de sincronizarse.',
                style: AppTexto.secundario,
              ),
            ),
          if (visibles.isEmpty)
            const EstadoVacio(
              icono: Icons.emoji_events_rounded,
              titulo: 'Sin vales pendientes.',
              subtitulo:
                  'Cuando un cliente cumpla un logro con premio, su vale llega aquí.',
            )
          else
            for (final v in visibles) ...[
              _tarjetaVale(v),
              const SizedBox(height: 12),
            ],
          if (_bandeja.recientes.isNotEmpty) ...[
            const EncabezadoSeccion(titulo: 'Resueltos recientes'),
            for (final r in _bandeja.recientes)
              ListTile(
                leading: Icon(
                    r.canjeado
                        ? Icons.emoji_events_rounded
                        : Icons.block_rounded,
                    color: r.canjeado
                        ? AppColores.naranja
                        : AppColores.textoSecundario(context)),
                title: Text(
                    '${r.nombre} · ${r.premioDias} días'),
                subtitle: Text(
                    '${r.canjeado ? 'Canjeado' : 'Rechazado'}'
                    '${r.resueltoEn.length >= 10 ? ' el ${fmtFecha(r.resueltoEn.substring(0, 10))}' : ''}'
                    '${r.resueltoNota.isNotEmpty ? ' · ${r.resueltoNota}' : ''}'),
              ),
          ],
        ],
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
              const Icon(Icons.emoji_events_rounded,
                  color: AppColores.naranja),
              const SizedBox(width: 8),
              Expanded(
                child: Text(v.nombre, style: AppTexto.subtitulo),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'Logro «${tituloLogroPremio(v.logroId)}» · '
            '${v.diasAlReclamar} días verificados',
            style: AppTexto.cuerpo,
          ),
          Text(
            'Premio: ${v.premioDias} días de mensualidad gratis',
            style: AppTexto.cuerpo,
          ),
          Text(
            'Vence ahora: ${fmtFecha(v.pagadoHasta)}'
            '${v.creadoEn.length >= 10 ? ' · Reclamado el ${fmtFecha(v.creadoEn.substring(0, 10))}' : ''}',
            style: AppTexto.secundario,
          ),
          const SizedBox(height: 10),
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
