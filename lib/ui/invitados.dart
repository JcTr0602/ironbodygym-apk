/// Bloque G de Invitados (v1.5.0): bandeja de Gestión.
///
/// Lista y detalle de los invitados registrados desde la app de
/// clientes. TODO vive en Supabase y se lee por RPC de staff
/// (lib/invitados.dart): la bandeja necesita conexión; a cambio no
/// hay espejo local que se desactualice. La lista NO muestra datos
/// corporales (diseño §8); las medidas autodeclaradas viven en el
/// detalle, visibles ANTES de Convertir junto con la última sync
/// (ajuste 5 de Argón).
library;

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../auth.dart';
import '../invitados.dart';
import '../negocio.dart';
import '../sync.dart';
import '../tiempo.dart';
import 'componentes.dart';
import 'diseno.dart';
import 'ficha.dart';
import 'inscribir.dart';
import 'widgets.dart';

// ---------------------------------------------------------------------------
// Bandeja (lista)
// ---------------------------------------------------------------------------

class InvitadosScreen extends StatefulWidget {
  const InvitadosScreen({super.key});
  @override
  State<InvitadosScreen> createState() => _InvitadosScreenState();
}

class _InvitadosScreenState extends State<InvitadosScreen> {
  final _svc = InvitadosService();
  static const _filtros = <({String id, String etiqueta})>[
    (id: 'todos', etiqueta: 'Todos'),
    (id: 'solicitudes', etiqueta: 'Solicitudes'),
    (id: 'nuevos', etiqueta: 'Nuevos'),
    (id: 'por_expirar', etiqueta: 'Por expirar'),
    (id: 'convertidos', etiqueta: 'Convertidos'),
  ];
  String _filtro = 'todos';
  bool _cargando = true;
  String? _error;
  List<InvitadoResumen> _lista = [];
  Map<String, ConversionInvitado> _locales = {};

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    setState(() {
      _cargando = true;
      _error = null;
    });
    // Primero cerrar conversiones cuya op ya subió (idempotente).
    try {
      await _svc.verificarConversiones();
    } catch (_) {}
    try {
      final lista = await _svc.listar(filtro: _filtro);
      final locales = await ConversionInvitadoStore().todas();
      if (!mounted) return;
      setState(() {
        _lista = lista;
        _locales = {for (final c in locales) c.invitadoId: c};
        _cargando = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e is InvitadoError
            ? e.mensaje
            : 'Sin conexión o error del servidor.';
        _cargando = false;
      });
    }
  }

  String? _badgeLocal(ConversionInvitado? c) {
    if (c == null) return null;
    switch (c.estado) {
      case EstadoConversion.preparada:
        return 'Conversión preparada';
      case EstadoConversion.opEncolada:
        return 'Inscripción por sincronizar';
      case EstadoConversion.confirmada:
        return 'Convertido desde este teléfono';
      case EstadoConversion.opRechazada:
        return 'Inscripción rechazada';
      case EstadoConversion.cancelada:
        return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final esAdmin = AuthService().isAdmin;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Invitados'),
        actions: [
          if (esAdmin)
            IconButton(
              tooltip: 'Información pública de la app',
              icon: const Icon(Icons.public_rounded),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                    builder: (_) => const InfoPublicaScreen()),
              ),
            ),
          IconButton(
            tooltip: 'Actualizar',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _cargando ? null : _cargar,
          ),
        ],
      ),
      body: Column(
        children: [
          const SyncBanner(compact: true),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(
                AppEspacio.lg, AppEspacio.md, AppEspacio.lg, 0),
            child: Row(
              children: [
                for (final f in _filtros) ...[
                  ChoiceChip(
                    label: Text(f.etiqueta),
                    selected: _filtro == f.id,
                    onSelected: (_) {
                      setState(() => _filtro = f.id);
                      _cargar();
                    },
                  ),
                  const SizedBox(width: AppEspacio.sm),
                ],
              ],
            ),
          ),
          Expanded(child: _cuerpo()),
        ],
      ),
    );
  }

  Widget _cuerpo() {
    if (_cargando) {
      return const Center(
          child: CircularProgressIndicator(color: AppColores.naranja));
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(AppEspacio.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off_rounded,
                  size: 40, color: AppColores.alerta),
              const SizedBox(height: AppEspacio.md),
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: AppEspacio.sm),
              const Text(
                'La bandeja de invitados vive en el servidor: '
                'necesita conexión.',
                textAlign: TextAlign.center,
                style: AppTexto.secundario,
              ),
              const SizedBox(height: AppEspacio.md),
              BotonPrimario(
                  texto: 'Reintentar',
                  icono: Icons.refresh_rounded,
                  onPressed: _cargar),
            ],
          ),
        ),
      );
    }
    if (_lista.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(AppEspacio.xl),
          child: Text(
            'No hay invitados en esta vista.\nLos registros nuevos '
            'desde la app de clientes aparecen aquí.',
            textAlign: TextAlign.center,
            style: AppTexto.secundario,
          ),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _cargar,
      child: ListView.builder(
        padding: const EdgeInsets.all(AppEspacio.lg),
        itemCount: _lista.length,
        itemBuilder: (ctx, i) {
          final inv = _lista[i];
          final badge = _badgeLocal(_locales[inv.id]);
          return Padding(
            padding: const EdgeInsets.only(bottom: AppEspacio.sm),
            child: Tarjeta(
              onTap: () async {
                await Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) =>
                      InvitadoDetalleScreen(invitadoId: inv.id),
                ));
                if (mounted) _cargar();
              },
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.person_outline_rounded,
                          color: AppColores.naranja),
                      const SizedBox(width: AppEspacio.sm),
                      Expanded(
                        child: Text(inv.nombre,
                            style: AppTexto.subtitulo,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis),
                      ),
                      if (inv.tieneSolicitudPendiente)
                        const Icon(Icons.mark_email_unread_rounded,
                            color: AppColores.alerta),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '📱 ${inv.telefono} · registrado '
                    '${inv.creadoEn != null ? hace(inv.creadoEn) : '—'}',
                    style: AppTexto.secundario,
                  ),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      if (inv.tieneSolicitudPendiente)
                        _chip('🙋 Quiere inscribirse',
                            AppColores.alerta),
                      if (inv.convertido)
                        _chip('✓ Convertido', AppColores.exitoOscuro)
                      else if (inv.caducado)
                        _chip('Caducado', AppColores.error)
                      else if (inv.caducaPronto)
                        _chip(
                            'Caduca en ${inv.diasRestantes} día(s)',
                            AppColores.alertaOscuro),
                      if (badge != null)
                        _chip(badge, AppColores.infoOscuro),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

Widget _chip(String texto, Color color) {
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(20),
    ),
    child: Text(texto,
        style: TextStyle(
            fontSize: 11, fontWeight: FontWeight.w600, color: color)),
  );
}

String _n(double v) => v == v.roundToDouble() ? '${v.toInt()}' : '$v';

// ---------------------------------------------------------------------------
// Detalle
// ---------------------------------------------------------------------------

class InvitadoDetalleScreen extends StatefulWidget {
  final String invitadoId;
  const InvitadoDetalleScreen({super.key, required this.invitadoId});
  @override
  State<InvitadoDetalleScreen> createState() =>
      _InvitadoDetalleScreenState();
}

class _InvitadoDetalleScreenState extends State<InvitadoDetalleScreen> {
  final _svc = InvitadosService();
  bool _cargando = true;
  bool _actuando = false;
  String? _error;
  InvitadoDetalle? _d;
  ConversionInvitado? _local;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    setState(() {
      _cargando = true;
      _error = null;
    });
    try {
      await _svc.verificarConversiones();
    } catch (_) {}
    try {
      final d = await _svc.detalle(widget.invitadoId);
      var local =
          await ConversionInvitadoStore().leer(widget.invitadoId);
      // G1(b): si este teléfono preparó la conversión y el
      // registro local se perdió (cierre entre la RPC y el
      // guardado), se adopta la preparación que ve el servidor.
      local ??= await _svc.adoptarConversionDelServidor(d);
      // G3: una preparación local cuyo lock venció (o que ya no
      // existe en el servidor) se cierra como cancelada: el
      // detalle no ofrecerá «Reanudar» con un uuid muerto y se
      // podrá preparar una conversión nueva.
      if (local != null) {
        local = await _svc.reconciliarPreparadaObsoleta(d, local);
      }
      if (!mounted) return;
      setState(() {
        _d = d;
        _local = local;
        _cargando = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e is InvitadoError
            ? e.mensaje
            : 'Sin conexión o error del servidor.';
        _cargando = false;
      });
    }
  }

  void _snack(String texto) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(texto)));
  }

  Future<void> _whatsapp() async {
    final d = _d!;
    final num = normalizarTelefonoWaMe(d.telefono);
    if (num.isEmpty) {
      _snack('El teléfono del invitado no es válido para WhatsApp.');
      return;
    }
    final ok = await launchUrl(Uri.parse('https://wa.me/$num'),
        mode: LaunchMode.externalApplication);
    if (!ok) _snack('No se pudo abrir WhatsApp.');
  }

  Future<void> _atender() async {
    setState(() => _actuando = true);
    try {
      final n = await _svc.atenderSolicitud(widget.invitadoId);
      _snack(n > 0
          ? 'Solicitud marcada como atendida'
          : 'La solicitud ya estaba atendida');
      await _cargar();
    } on InvitadoError catch (e) {
      _snack(e.mensaje);
    } finally {
      if (mounted) setState(() => _actuando = false);
    }
  }

  Future<void> _convertir() async {
    final d = _d!;
    setState(() => _actuando = true);
    try {
      final datos = await _svc.prepararConversion(d);
      if (!mounted) return;
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => InscribirScreen(conversion: datos),
      ));
      await _cargar();
    } on InvitadoError catch (e) {
      _snack(e.mensaje);
    } finally {
      if (mounted) setState(() => _actuando = false);
    }
  }

  /// «Reanudar inscripción»: reabre Inscribir con el MISMO
  /// conversion_uuid durable (el formulario se cerró a mitad).
  Future<void> _reanudar() async {
    final d = _d!;
    final local = _local!;
    final datos = DatosConversionInvitado(
      invitadoId: d.id,
      conversionUuid: local.conversionUuid,
      nombre: d.nombre,
      telefono: d.telefono,
      fechaNac: d.fechaNac,
      medidas: d.mediciones,
    );
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => InscribirScreen(conversion: datos),
    ));
    await _cargar();
  }

  Future<void> _cancelarConversion() async {
    final local = _local;
    if (local == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => DialogoApp(
        titulo: 'Cancelar conversión',
        iconoTitulo: Icons.cancel_outlined,
        contenido: const Text(
            'Se cancela la preparación en el servidor y el '
            'invitado vuelve a estar activo normal. Podrás '
            'convertirlo de nuevo cuando quieras.'),
        acciones: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Volver')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColores.error,
                foregroundColor: Colors.white,
              ),
              child: const Text('Cancelar conversión')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _actuando = true);
    try {
      await _svc.cancelarConversion(local.conversionUuid,
          invitadoId: widget.invitadoId);
      _snack('Conversión cancelada');
      await _cargar();
    } on InvitadoError catch (e) {
      _snack(e.mensaje);
    } finally {
      if (mounted) setState(() => _actuando = false);
    }
  }

  Future<void> _sincronizarAhora() async {
    setState(() => _actuando = true);
    try {
      await SyncEngine.instance.push();
      await _svc.verificarConversiones();
      await _cargar();
      _snack('Sincronización revisada');
    } finally {
      if (mounted) setState(() => _actuando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Detalle del invitado')),
      body: Column(
        children: [
          const SyncBanner(compact: true),
          Expanded(child: _cuerpo()),
        ],
      ),
    );
  }

  Widget _cuerpo() {
    if (_cargando) {
      return const Center(
          child: CircularProgressIndicator(color: AppColores.naranja));
    }
    if (_error != null || _d == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(AppEspacio.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off_rounded,
                  size: 40, color: AppColores.alerta),
              const SizedBox(height: AppEspacio.md),
              Text(_error ?? 'Sin datos', textAlign: TextAlign.center),
              const SizedBox(height: AppEspacio.md),
              BotonPrimario(
                  texto: 'Reintentar',
                  icono: Icons.refresh_rounded,
                  onPressed: _cargar),
            ],
          ),
        ),
      );
    }
    final d = _d!;
    return RefreshIndicator(
      onRefresh: _cargar,
      child: ListView(
        padding: const EdgeInsets.all(AppEspacio.lg),
        children: [
          _tarjetaDatos(d),
          if (d.solicitud != null) ...[
            const SizedBox(height: AppEspacio.md),
            _tarjetaSolicitud(d),
          ],
          const SizedBox(height: AppEspacio.md),
          _tarjetaSync(d),
          const SizedBox(height: AppEspacio.md),
          _tarjetaConversion(d),
          const SizedBox(height: AppEspacio.md),
          _tarjetaAcciones(d),
        ],
      ),
    );
  }

  Widget _tarjetaDatos(InvitadoDetalle d) {
    return Tarjeta(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.person_rounded,
                  color: AppColores.naranja),
              const SizedBox(width: AppEspacio.sm),
              Expanded(
                  child: Text(d.nombre, style: AppTexto.titulo)),
            ],
          ),
          const SizedBox(height: AppEspacio.sm),
          _chip('⚠ Teléfono no verificado', AppColores.alertaOscuro),
          const SizedBox(height: AppEspacio.sm),
          _linea('📱 Teléfono', d.telefono),
          if (d.fechaNac != null)
            _linea('🎂 Nacimiento', fmtFecha(d.fechaNac)),
          _linea('🗓 Registrado', fechaAbsoluta(d.creadoEn)),
          _linea(
              '⏳ Caduca',
              d.convertido
                  ? 'ya convertido'
                  : '${fechaAbsoluta(d.caducaEn)}${d.caducado ? ' (caducado)' : ''}'),
          _linea('Estado', d.estado),
        ],
      ),
    );
  }

  Widget _linea(String etiqueta, String valor) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
              width: 130,
              child: Text(etiqueta, style: AppTexto.secundario)),
          Expanded(child: Text(valor, style: AppTexto.cuerpo)),
        ],
      ),
    );
  }

  Widget _tarjetaSolicitud(InvitadoDetalle d) {
    final s = d.solicitud!;
    return Tarjeta(
      color: s.pendiente
          ? AppColores.alerta.withValues(alpha: 0.10)
          : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.mark_email_unread_rounded,
                  color: AppColores.alertaOscuro),
              SizedBox(width: AppEspacio.sm),
              Text('Solicitud «Quiero inscribirme»',
                  style: AppTexto.subtitulo),
            ],
          ),
          const SizedBox(height: AppEspacio.sm),
          Text(
            s.pendiente
                ? 'Pendiente desde ${fechaAbsoluta(s.creadaEn)}'
                : 'Atendida ${s.atendidaEn != null ? fechaAbsoluta(s.atendidaEn) : ''}'
                    '${s.atendidoPor != null ? ' por ${s.atendidoPor}' : ''}'
                    '${s.resultado != null ? ' · ${s.resultado}' : ''}',
            style: AppTexto.cuerpo,
          ),
          if (s.pendiente) ...[
            const SizedBox(height: AppEspacio.md),
            BotonPrimario(
              texto: 'Marcar atendida',
              icono: Icons.done_all_rounded,
              onPressed: _actuando ? null : _atender,
            ),
          ],
        ],
      ),
    );
  }

  /// Ajuste 5 de Argón: lo sincronizado se ve ANTES de convertir;
  /// lo que siga en el teléfono del invitado se pierde al revocar.
  Widget _tarjetaSync(InvitadoDetalle d) {
    return Tarjeta(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.sync_rounded, color: AppColores.naranja),
              SizedBox(width: AppEspacio.sm),
              Text('Datos sincronizados', style: AppTexto.subtitulo),
            ],
          ),
          const SizedBox(height: AppEspacio.sm),
          _linea('Última sync',
              d.ultimaSync != null ? hace(d.ultimaSync) : '—'),
          _linea('Medidas sincronizadas',
              '${d.medicionesSincronizadas}'),
          if (d.mediciones.isEmpty)
            const Text(
              'El invitado aún no ha sincronizado medidas.',
              style: AppTexto.secundario,
            )
          else
            for (final m in d.mediciones) ...[
              const Divider(height: 16),
              _linea('📅 ${fmtFecha(m.fecha)}',
                  m.resumen.isEmpty ? 'medida registrada' : m.resumen),
              if (_detalleMedida(m).isNotEmpty)
                Text(_detalleMedida(m), style: AppTexto.secundario),
              if (m.notas != null && m.notas!.isNotEmpty)
                Text('«${m.notas}»', style: AppTexto.secundario),
            ],
          const SizedBox(height: AppEspacio.sm),
          const Text(
            'Medidas autodeclaradas por el invitado en su app. '
            'Al convertirlo, su acceso de invitado se revoca: las '
            'medidas que aún estén en su teléfono SIN sincronizar '
            'se pierden.',
            style: AppTexto.secundario,
          ),
        ],
      ),
    );
  }

  String _detalleMedida(MedidaInvitado m) {
    final p = <String>[];
    if (m.pechoCm != null) p.add('pecho ${_n(m.pechoCm!)}');
    if (m.brazoCm != null) p.add('brazo ${_n(m.brazoCm!)}');
    if (m.cinturaCm != null) p.add('cintura ${_n(m.cinturaCm!)}');
    if (m.caderaCm != null) p.add('cadera ${_n(m.caderaCm!)}');
    if (m.musloCm != null) p.add('muslo ${_n(m.musloCm!)}');
    return p.isEmpty ? '' : '${p.join(' · ')} cm';
  }

  Widget _tarjetaConversion(InvitadoDetalle d) {
    if (d.convertido) {
      return Tarjeta(
        color: AppColores.exito.withValues(alpha: 0.10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.verified_rounded,
                    color: AppColores.exitoOscuro),
                SizedBox(width: AppEspacio.sm),
                Text('Ya es cliente', style: AppTexto.subtitulo),
              ],
            ),
            const SizedBox(height: AppEspacio.sm),
            Text(
              'Convertido ${d.convertidoEn != null ? fechaAbsoluta(d.convertidoEn) : ''}'
              '${d.clienteId != null ? ' · Cliente #${d.clienteId}' : ''}.',
              style: AppTexto.cuerpo,
            ),
            if (_local?.resultadoMedidas != null) ...[
              const SizedBox(height: AppEspacio.sm),
              Text(_local!.resultadoMedidas!.texto,
                  style: AppTexto.secundario),
            ],
            if (d.clienteId != null) ...[
              const SizedBox(height: AppEspacio.md),
              BotonPrimario(
                texto: 'Ver ficha del cliente',
                icono: Icons.badge_rounded,
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(
                      builder: (_) =>
                          FichaScreen(clienteId: d.clienteId!)),
                ),
              ),
            ],
          ],
        ),
      );
    }

    final reanudar = reanudarPara(
        local: _local, enServidor: d.conversionPreparada);
    switch (reanudar) {
      case ReanudarConversion.abrirInscribir:
        return Tarjeta(
          color: AppColores.info.withValues(alpha: 0.10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
                  Icon(Icons.swap_horiz_rounded,
                      color: AppColores.infoOscuro),
                  SizedBox(width: AppEspacio.sm),
                  Text('Conversión preparada',
                      style: AppTexto.subtitulo),
                ],
              ),
              const SizedBox(height: AppEspacio.sm),
              const Text(
                'La inscripción quedó a mitad en este teléfono. '
                'Reanúdala con el mismo registro preparado: no se '
                'duplica.',
                style: AppTexto.cuerpo,
              ),
              const SizedBox(height: AppEspacio.md),
              BotonPrimario(
                texto: 'Reanudar inscripción',
                icono: Icons.play_arrow_rounded,
                onPressed: _actuando ? null : _reanudar,
              ),
              const SizedBox(height: AppEspacio.sm),
              OutlinedButton.icon(
                icon: const Icon(Icons.cancel_outlined),
                label: const Text('Cancelar conversión'),
                onPressed: _actuando ? null : _cancelarConversion,
              ),
            ],
          ),
        );
      case ReanudarConversion.esperandoSync:
        return Tarjeta(
          color: AppColores.alerta.withValues(alpha: 0.10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
                  Icon(Icons.cloud_upload_rounded,
                      color: AppColores.alertaOscuro),
                  SizedBox(width: AppEspacio.sm),
                  Text('Inscripción guardada',
                      style: AppTexto.subtitulo),
                ],
              ),
              const SizedBox(height: AppEspacio.sm),
              const Text(
                'La inscripción ya se guardó en este teléfono y '
                'está esperando sincronizarse. Al subirse, la '
                'conversión se confirma sola y aquí verás el '
                'resultado de las medidas.',
                style: AppTexto.cuerpo,
              ),
              const SizedBox(height: AppEspacio.md),
              BotonPrimario(
                texto: 'Sincronizar / verificar ahora',
                icono: Icons.sync_rounded,
                onPressed: _actuando ? null : _sincronizarAhora,
              ),
            ],
          ),
        );
      case ReanudarConversion.verResultado:
        return Tarjeta(
          color: AppColores.exito.withValues(alpha: 0.10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
                  Icon(Icons.verified_rounded,
                      color: AppColores.exitoOscuro),
                  SizedBox(width: AppEspacio.sm),
                  Text('Conversión confirmada',
                      style: AppTexto.subtitulo),
                ],
              ),
              const SizedBox(height: AppEspacio.sm),
              if (_local?.resultadoMedidas != null)
                Text(_local!.resultadoMedidas!.texto,
                    style: AppTexto.cuerpo)
              else
                const Text('El invitado ya es cliente.',
                    style: AppTexto.cuerpo),
            ],
          ),
        );
      case ReanudarConversion.revisarFallo:
        return Tarjeta(
          color: AppColores.error.withValues(alpha: 0.10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
                  Icon(Icons.error_outline_rounded,
                      color: AppColores.errorOscuro),
                  SizedBox(width: AppEspacio.sm),
                  Text('La inscripción fue rechazada',
                      style: AppTexto.subtitulo),
                ],
              ),
              const SizedBox(height: AppEspacio.sm),
              const Text(
                'El servidor rechazó la operación de inscripción '
                '(revisa la cola de operaciones para el motivo). '
                'Cancela esta conversión para poder intentarlo de '
                'nuevo.',
                style: AppTexto.cuerpo,
              ),
              const SizedBox(height: AppEspacio.md),
              OutlinedButton.icon(
                icon: const Icon(Icons.cancel_outlined),
                label: const Text('Cancelar conversión'),
                onPressed: _actuando ? null : _cancelarConversion,
              ),
            ],
          ),
        );
      case ReanudarConversion.ninguna:
        final enSrv = d.conversionPreparada;
        return Tarjeta(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
                  Icon(Icons.swap_horiz_rounded,
                      color: AppColores.naranja),
                  SizedBox(width: AppEspacio.sm),
                  Text('Convertir en cliente',
                      style: AppTexto.subtitulo),
                ],
              ),
              const SizedBox(height: AppEspacio.sm),
              if (enSrv != null)
                Text(
                  enSrv.lockVigente
                      ? 'Hay una conversión preparada'
                          '${enSrv.preparadaPor != null ? ' por ${enSrv.preparadaPor}' : ''} '
                          'con bloqueo hasta '
                          '${enSrv.expiraLockEn != null ? fechaAbsoluta(enSrv.expiraLockEn) : '—'}. '
                          'Si la preparaste tú en OTRO teléfono, termínala allá; '
                          'si intentas convertir ahora, el servidor lo rechazará '
                          'hasta que venza el bloqueo.'
                      : 'Hubo una conversión preparada cuyo bloqueo '
                          'ya venció: al convertir se emitirá una nueva.',
                  style: AppTexto.cuerpo,
                )
              else
                const Text(
                  'Abre la inscripción pre-llenada con sus datos. '
                  'Al sincronizarse, el invitado pasa a cliente y '
                  'sus medidas sincronizadas se envían al servidor '
                  'para verificarlas: se importan solo las que el '
                  'servidor confirme como suyas, y el resultado se '
                  'verá al confirmarse la conversión.',
                  style: AppTexto.cuerpo,
                ),
              const SizedBox(height: AppEspacio.md),
              BotonPrimario(
                texto: 'Convertir en cliente',
                icono: Icons.person_add_alt_rounded,
                onPressed: _actuando ? null : _convertir,
              ),
            ],
          ),
        );
    }
  }

  Widget _tarjetaAcciones(InvitadoDetalle d) {
    final esAdmin = AuthService().isAdmin;
    // G4: con una conversión sin resolver, Eliminar queda
    // deshabilitado (la op podría crear el cliente después y la
    // conversión quedaría imposible de confirmar).
    final eliminarBloqueado = eliminarInvitadoBloqueado(
        local: _local, enServidor: d.conversionPreparada);
    return Tarjeta(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Acciones', style: AppTexto.subtitulo),
          const SizedBox(height: AppEspacio.md),
          OutlinedButton.icon(
            icon: const Icon(Icons.chat_rounded),
            label: const Text('Escribir por WhatsApp'),
            onPressed: _whatsapp,
          ),
          if (esAdmin && !d.convertido) ...[
            const SizedBox(height: AppEspacio.sm),
            OutlinedButton.icon(
              icon: const Icon(Icons.key_rounded),
              label: const Text('Ajustar acceso (clave)'),
              onPressed: _actuando ? null : _ajustarClave,
            ),
            const SizedBox(height: AppEspacio.sm),
            OutlinedButton.icon(
              icon: const Icon(Icons.delete_outline_rounded,
                  color: AppColores.error),
              label: const Text('Eliminar invitado',
                  style: TextStyle(color: AppColores.error)),
              onPressed:
                  (_actuando || eliminarBloqueado) ? null : _eliminar,
            ),
            if (eliminarBloqueado) ...[
              const SizedBox(height: AppEspacio.sm),
              const Text(
                'No se puede eliminar mientras haya una '
                'conversión en curso: termínala o cancélala '
                'primero.',
                style: AppTexto.secundario,
              ),
            ],
          ],
        ],
      ),
    );
  }

  /// Regla anti-fuga (§12.3): el ajuste de clave SOLO procede si
  /// la persona confirma el nombre registrado y la fecha de
  /// creación. Si el nombre no coincide con quien reclama, NO se
  /// resetea: se elimina (libera el número) o se inscribe directo.
  Future<void> _ajustarClave() async {
    final d = _d!;
    final ctrl = TextEditingController();
    var confirmado = false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => DialogoApp(
          titulo: 'Ajustar acceso del invitado',
          iconoTitulo: Icons.key_rounded,
          contenido: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'El teléfono del invitado NO está verificado. '
                  'Solo ajusta la clave si la persona confirma '
                  'estos datos:',
                  style: AppTexto.cuerpo,
                ),
                const SizedBox(height: AppEspacio.md),
                _linea('Nombre registrado', d.nombre),
                _linea('Registrado el', fechaAbsoluta(d.creadoEn)),
                const SizedBox(height: AppEspacio.sm),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: confirmado,
                  onChanged: (v) =>
                      setS(() => confirmado = v ?? false),
                  title: const Text(
                      'La persona confirmó su nombre y su fecha '
                      'de registro',
                      style: AppTexto.cuerpo),
                ),
                const SizedBox(height: AppEspacio.sm),
                CampoTexto(
                  controller: ctrl,
                  etiqueta: 'Clave nueva (6–32, sin espacios)',
                  icono: Icons.lock_outline_rounded,
                  obscure: true,
                  onChanged: (_) => setS(() {}),
                ),
                const SizedBox(height: AppEspacio.sm),
                const Text(
                  'Si quien reclama dice que el teléfono es suyo '
                  'pero el nombre NO coincide, no ajustes la '
                  'clave: elimina el invitado (libera el número '
                  'al instante) o inscribe a la persona '
                  'directamente como cliente.',
                  style: AppTexto.secundario,
                ),
              ],
            ),
          ),
          acciones: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancelar')),
            ElevatedButton(
              onPressed: confirmado &&
                      RegExp(r'^\S{6,32}$')
                          .hasMatch(ctrl.text.trim())
                  ? () => Navigator.pop(ctx, true)
                  : null,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColores.naranja,
                foregroundColor: Colors.white,
              ),
              child: const Text('Ajustar clave'),
            ),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _actuando = true);
    try {
      await _svc.ajustarClave(widget.invitadoId, ctrl.text.trim());
      _snack('Clave ajustada. Las sesiones del invitado se '
          'revocaron: debe entrar con la clave nueva y cambiarla.');
      await _cargar();
    } on InvitadoError catch (e) {
      _snack(e.mensaje);
    } finally {
      if (mounted) setState(() => _actuando = false);
    }
  }

  Future<void> _eliminar() async {
    final d = _d!;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => DialogoApp(
        titulo: 'Eliminar invitado',
        iconoTitulo: Icons.delete_outline_rounded,
        contenido: Text(
            'Se elimina a «${d.nombre}» con sus medidas y '
            'sesiones de invitado, y el número ${d.telefono} '
            'queda libre al instante (también se resetea su '
            'límite de registro). Esta acción no se puede '
            'deshacer.'),
        acciones: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColores.error,
                foregroundColor: Colors.white,
              ),
              child: const Text('Eliminar')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _actuando = true);
    try {
      await _svc.eliminar(widget.invitadoId);
      if (!mounted) return;
      Navigator.of(context).pop();
    } on InvitadoError catch (e) {
      _snack(e.mensaje);
      if (mounted) setState(() => _actuando = false);
    }
  }
}

// ---------------------------------------------------------------------------
// Información pública (panel del dueño): lo que la app de
// clientes muestra al invitado. Cambiar un enlace o un número
// aquí NO exige actualizar la app (diseño §10.2). Vacío = la
// clave se borra y el dato/botón no se muestra.
// ---------------------------------------------------------------------------

class InfoPublicaScreen extends StatefulWidget {
  const InfoPublicaScreen({super.key});
  @override
  State<InfoPublicaScreen> createState() => _InfoPublicaScreenState();
}

class _InfoPublicaScreenState extends State<InfoPublicaScreen> {
  final _svc = InvitadosService();
  final Map<String, TextEditingController> _ctrls = {};
  Map<String, String> _originales = {};
  bool _cargando = true;
  bool _guardando = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    for (final c in clavesInfoPublica) {
      _ctrls[c.clave] = TextEditingController();
    }
    _cargar();
  }

  @override
  void dispose() {
    for (final c in _ctrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _cargar() async {
    setState(() {
      _cargando = true;
      _error = null;
    });
    try {
      final info = await _svc.infoPublica();
      if (!mounted) return;
      setState(() {
        _originales = info;
        for (final c in clavesInfoPublica) {
          _ctrls[c.clave]!.text = info[c.clave] ?? '';
        }
        _cargando = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e is InvitadoError
            ? e.mensaje
            : 'Sin conexión o error del servidor.';
        _cargando = false;
      });
    }
  }

  Future<void> _guardar() async {
    final cambios = <String, String>{};
    for (final c in clavesInfoPublica) {
      // G6: las claves de teléfono se comparan y guardan
      // NORMALIZADAS (8 dígitos); el resto, como texto libre.
      final v =
          valorAGuardarInfoPublica(c.clave, _ctrls[c.clave]!.text);
      if (v != (_originales[c.clave] ?? '')) cambios[c.clave] = v;
    }
    if (cambios.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Sin cambios que guardar')));
      return;
    }
    // G6: un teléfono que no cumple (8 dígitos) frena TODO el
    // guardado con aviso claro: nada llega a info_publica_guardar
    // a medias.
    for (final c in clavesInfoPublica) {
      if (!cambios.containsKey(c.clave)) continue;
      final error = validarValorInfoPublica(
          c.clave, _ctrls[c.clave]!.text);
      if (error != null) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('«${c.etiqueta}» $error')));
        return;
      }
    }
    setState(() => _guardando = true);
    try {
      for (final e in cambios.entries) {
        await _svc.guardarInfoPublica(e.key, e.value);
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text(
              'Información pública actualizada: la app de '
              'clientes la verá en su próxima sincronización')));
      await _cargar();
    } on InvitadoError catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.mensaje)));
    } finally {
      if (mounted) setState(() => _guardando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Información pública')),
      body: Column(
        children: [
          const SyncBanner(compact: true),
          Expanded(child: _cuerpo()),
        ],
      ),
    );
  }

  Widget _cuerpo() {
    if (_cargando) {
      return const Center(
          child: CircularProgressIndicator(color: AppColores.naranja));
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(AppEspacio.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off_rounded,
                  size: 40, color: AppColores.alerta),
              const SizedBox(height: AppEspacio.md),
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: AppEspacio.md),
              BotonPrimario(
                  texto: 'Reintentar',
                  icono: Icons.refresh_rounded,
                  onPressed: _cargar),
            ],
          ),
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.all(AppEspacio.lg),
      children: [
        const Text(
          'Esto es lo que ve el invitado en su portada: redes, '
          'contactos, precios estándar, horario y ubicación. '
          'Deja un campo vacío para que no se muestre.',
          style: AppTexto.secundario,
        ),
        const SizedBox(height: AppEspacio.md),
        for (final c in clavesInfoPublica) ...[
          CampoTexto(
            controller: _ctrls[c.clave],
            etiqueta: c.etiqueta,
            hint: c.ayuda,
          ),
          const SizedBox(height: AppEspacio.md),
        ],
        const SizedBox(height: AppEspacio.sm),
        _guardando
            ? const Center(
                child:
                    CircularProgressIndicator(color: AppColores.naranja))
            : BotonPrimario(
                texto: 'Guardar información pública',
                icono: Icons.save_rounded,
                onPressed: _guardar,
              ),
        const SizedBox(height: AppEspacio.lg),
      ],
    );
  }
}
