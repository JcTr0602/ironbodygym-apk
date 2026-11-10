/// Solicitudes de adelanto (v1.12.0, Bloque 3 F3 — SOLO dueño).
/// Lista del espejo `solicitudes_adelanto`: pendientes primero.
/// Al aprobar, el dueño ELIGE el destino ANTES de confirmar
/// (contrato a7556fd): «Nómina» (por defecto: solo descuenta de
/// la nómina del mes) o «Pendiente a entregar» (descuenta del
/// pendiente a entregar de la gaveta del entrenador y ADEMÁS
/// aparece en su libro de nómina). Al rechazar, el motivo es
/// obligatorio. Todo viaja por sync_ops (la decisión sube cuando
/// haya red); la fila optimista deja de ofrecerse como pendiente
/// sin esperar al pull.
library;

import 'package:flutter/material.dart';

import '../auth.dart';
import '../bloque3.dart';
import '../negocio.dart';
import 'app_bar.dart';
import 'componentes.dart';
import 'diseno.dart';
import 'widgets.dart';
import '../errores_sync.dart';
import '../app_log.dart';

class SolicitudesAdelantoScreen extends StatefulWidget {
  const SolicitudesAdelantoScreen({super.key});
  @override
  State<SolicitudesAdelantoScreen> createState() =>
      _SolicitudesAdelantoScreenState();
}

class _SolicitudesAdelantoScreenState
    extends State<SolicitudesAdelantoScreen> {
  bool _cargando = true;
  bool _actuando = false;
  List<SolicitudAdelanto> _lista = [];

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    // (Yunque R2-X1) red de seguridad: la bandera baja
    // SIEMPRE (y el fallo queda en bitácora), también si una lectura local lanza a mitad
    // (spinner eterno: la clase de la ficha 2026-11-02).
    try {
      await _cargarDatos();
    } catch (e) {
      // El error NO se traga: queda en bitácora
      // (la clase nació de fallos mudos).
      AppLog.error('ui', 'carga_fallo', d: '$e');
    } finally {
      if (mounted && _cargando) {
        setState(() => _cargando = false);
      }
    }
  }

  Future<void> _cargarDatos() async {
    setState(() => _cargando = true);
    final lista =
        await SolicitudesAdelantoService.instance.todasParaDueno();
    lista.sort((a, b) {
      final pa = a.pendiente ? 0 : 1;
      final pb = b.pendiente ? 0 : 1;
      if (pa != pb) return pa - pb;
      return (b.creadoEn ?? '').compareTo(a.creadoEn ?? '');
    });
    if (!mounted) return;
    setState(() {
      _lista = lista;
      _cargando = false;
    });
  }

  void _snack(String texto) {
    if (!mounted) return;
    mostrarSnack(context, texto);
  }

  /// Diálogo de aprobación con el selector de destino OBLIGATORIO
  /// antes de confirmar (el dueño ve qué significa cada destino).
  /// Fase A 2026-10-25 (B1): también se elige CÓMO se paga el
  /// adelanto; por transferencia, «Pendiente a entregar» no está
  /// disponible (una transferencia no sale de la gaveta) y el
  /// destino se fuerza a «Nómina» antes de enviar.
  Future<void> _aprobar(SolicitudAdelanto s) async {
    // P2#9: aprobar es escritura solo-dueño (defensa además del
    // botón: la pantalla puede estar abierta con cambio de sesión).
    if (!AuthService().isOwner) {
      _snack('Solo el dueño puede aprobar adelantos.');
      return;
    }
    // 1.25 T118 (F2-12): diálogo propio con DialogoApp y
    // RadioGroup (antes AlertDialog crudo con la API de radios
    // deprecada).
    final eleccion = await showDialog<
        ({String metodo, String destino})>(
      context: context,
      builder: (ctx) => _DialogoAprobarAdelanto(solicitud: s),
    );
    if (eleccion == null || !mounted) return;
    final metodo = eleccion.metodo;
    final destino = eleccion.destino;

    // B1: el destino efectivo (forzado) es el que se muestra.
    final destinoFinal =
        destinoEfectivoF3(metodo: metodo, destino: destino);
    setState(() => _actuando = true);
    try {
      await SolicitudesAdelantoService.instance.resolver(
          solicitud: s,
          aprobar: true,
          destino: destino,
          metodo: metodo);
      _snack('Adelanto aprobado '
          '(${destinoFinal == 'nomina' ? 'Nómina' : 'Pendiente a entregar'}).');
      await _cargar();
    } catch (e) {
      AppLog.error('solicitudes_adelanto', 'aprobar_fallo', d: '$e');
      _snack('No se pudo aprobar: ${mensajeErrorAmable(e)}');
    } finally {
      if (mounted) setState(() => _actuando = false);
    }
  }

  Future<void> _rechazar(SolicitudAdelanto s) async {
    // P2#9: igual que _aprobar.
    if (!AuthService().isOwner) {
      _snack('Solo el dueño puede rechazar adelantos.');
      return;
    }
    // F2-12: diálogo propio (posee y dispone su controlador;
    // antes quedaba sin disponer).
    final motivo = await showDialog<String>(
      context: context,
      builder: (ctx) => const _DialogoRechazarAdelanto(),
    );
    if (motivo == null || motivo.isEmpty || !mounted) return;
    setState(() => _actuando = true);
    try {
      await SolicitudesAdelantoService.instance
          .resolver(solicitud: s, aprobar: false, motivo: motivo);
      _snack('Solicitud rechazada.');
      await _cargar();
    } catch (e) {
      AppLog.error('solicitudes_adelanto', 'rechazar_fallo', d: '$e');
      _snack('No se pudo rechazar: ${mensajeErrorAmable(e)}');
    } finally {
      if (mounted) setState(() => _actuando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // P2#9: pantalla SOLO dueño sin guarda.
    if (!AuthService().isOwner) {
      return Scaffold(
          appBar: appBarIron(context, 'Solicitudes de adelanto'),
          body: const Center(
              child: Text('Solo el dueño ve esta pantalla.')));
    }
    return Scaffold(
      appBar: appBarIron(context, 'Solicitudes de adelanto'),
      body: Column(
        children: [
          const SyncBanner(compact: true),
          Expanded(
            // 1.23 T7: cruce por tipo de estado (la key es solo
            // el tipo, nunca los datos).
            child: CruceEstados(
              estado: _cargando
                  ? 'cargando'
                  : _lista.isEmpty
                      ? 'vacio'
                      : 'contenido',
              child: _cuerpo(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _cuerpo() {
    if (_cargando) {
      return const Center(
          child: CircularProgressIndicator(color: AppColores.naranja));
    }
    if (_lista.isEmpty) {
      // 1.23 B7: vacío compartido del sistema.
      return const EstadoVacio(
        icono: Icons.payments_rounded,
        titulo: 'No hay solicitudes de adelanto.',
      );
    }
    // 1.25 T118 (F2-12): cabecera con lo que espera decisión —
    // antes el dueño aprobaba una a una sin ver el total.
    final pendientes = _lista.where((s) => s.pendiente).toList();
    final totalPendiente =
        pendientes.fold<double>(0, (a, s) => a + s.monto);
    return FadeEntrada(
      child: Column(
        children: [
          if (pendientes.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  AppEspacio.lg, AppEspacio.lg, AppEspacio.lg, 0),
              child: Tarjeta(
                child: Row(
                  children: [
                    const Icon(Icons.pending_actions_rounded,
                        color: AppColores.alerta),
                    const SizedBox(width: AppEspacio.sm),
                    Expanded(
                      child: Text(
                        '${pendientes.length} solicitud${pendientes.length == 1 ? '' : 'es'} '
                        'por decidir · ${fmtMonto(totalPendiente)} CUP pedidos',
                        style: AppTexto.cuerpo,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          Expanded(
            child: RefreshIndicator(
        onRefresh: _cargar,
        child: ListView.builder(
          padding: const EdgeInsets.all(AppEspacio.lg),
          itemCount: _lista.length,
          itemBuilder: (ctx, i) {
            final s = _lista[i];
            final nombre =
                s.entrenadorNombre ?? s.entrenador ?? 'Entrenador';
            return Padding(
              padding: const EdgeInsets.only(bottom: AppEspacio.md),
              child: Tarjeta(
                color: s.pendiente
                    ? AppColores.alerta.withValues(alpha: 0.10)
                    : null,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            '$nombre · ${fmtMonto(s.monto)} CUP',
                            style: AppTexto.subtitulo,
                          ),
                        ),
                        _chipEstado(s.estado),
                      ],
                    ),
                    const SizedBox(height: 4),
                    if (s.motivo.isNotEmpty)
                      Text('«${s.motivo}»', style: AppTexto.cuerpo),
                    if (s.creadoEn != null)
                      Text('Pedida el ${fmtFecha(s.creadoEn)}',
                          style: AppTexto.secundario),
                    if (s.destinoEtiqueta != null)
                      Text('Destino: ${s.destinoEtiqueta}',
                          style: AppTexto.secundario),
                    if (s.estado == 'rechazado' &&
                        (s.motivoResolucion ?? '').isNotEmpty)
                      Text('Motivo: «${s.motivoResolucion}»',
                          style: AppTexto.secundario),
                    if (s.resueltoEn != null)
                      Text(
                        'Resuelta el ${fmtFecha(s.resueltoEn)}'
                        '${(s.resueltoPorNombre ?? '').isNotEmpty ? ' por ${s.resueltoPorNombre}' : ''}',
                        style: AppTexto.secundario,
                      ),
                    if (s.pendiente) ...[
                      const SizedBox(height: AppEspacio.md),
                      Wrap(
                        spacing: AppEspacio.sm,
                        children: [
                          FilledButton.icon(
                            icon: const Icon(Icons.check_rounded,
                                size: 18),
                            label: const Text('Aprobar'),
                            onPressed:
                                _actuando ? null : () => _aprobar(s),
                          ),
                          OutlinedButton.icon(
                            icon: const Icon(Icons.block_rounded,
                                size: 18),
                            label: const Text('Rechazar'),
                            onPressed:
                                _actuando ? null : () => _rechazar(s),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            );
          },
        ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _chipEstado(String estado) {
    final color = switch (estado) {
      'aprobado' => AppColores.exitoOscuro,
      'rechazado' => AppColores.error,
      _ => AppColores.alertaOscuro,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppEspacio.sm, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        switch (estado) {
          'aprobado' => 'Aprobada',
          'rechazado' => 'Rechazada',
          _ => 'Pendiente',
        },
        style: AppTexto.minuscula.copyWith(color: color, fontWeight: FontWeight.w600),
      ),
    );
  }
}

/// 1.25 T118 (F2-12): diálogo de aprobación del adelanto como
/// StatefulWidget propio, con DialogoApp y RadioGroup (la API
/// vigente; RadioListTile con groupValue/onChanged quedó
/// deprecada). Conserva el acoplamiento B1: por transferencia
/// el destino es Nómina (el radio «Pendiente a entregar» se
/// deshabilita y el destino vuelve a nómina al elegirla).
/// Devuelve la elección o null si se cancela.
class _DialogoAprobarAdelanto extends StatefulWidget {
  final SolicitudAdelanto solicitud;
  const _DialogoAprobarAdelanto({required this.solicitud});

  @override
  State<_DialogoAprobarAdelanto> createState() =>
      _DialogoAprobarAdelantoState();
}

class _DialogoAprobarAdelantoState
    extends State<_DialogoAprobarAdelanto> {
  String _metodo = 'efectivo';
  String _destino = 'nomina';

  @override
  Widget build(BuildContext context) {
    final s = widget.solicitud;
    return DialogoApp(
      titulo: 'Aprobar adelanto',
      iconoTitulo: Icons.payments_rounded,
      contenido: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${s.entrenadorNombre ?? s.entrenador ?? 'Entrenador'}'
              ' · ${fmtMonto(s.monto)} CUP'
              '${s.motivo.isNotEmpty ? ' · «${s.motivo}»' : ''}',
              style: AppTexto.cuerpo,
            ),
            const SizedBox(height: AppEspacio.md),
            const Text('¿Cómo se paga?',
                style: AppTexto.subtitulo),
            RadioGroup<String>(
              groupValue: _metodo,
              onChanged: (v) => setState(() {
                _metodo = v ?? 'efectivo';
                // B1: por transferencia no hay gaveta de donde
                // descontar: el destino vuelve a Nómina solo.
                if (_metodo == 'transferencia') _destino = 'nomina';
              }),
              child: const Column(
                children: [
                  RadioListTile<String>(
                    value: 'efectivo',
                    title: Text('Efectivo'),
                    subtitle: Text(
                      'Sale de la caja del turno.',
                      style: AppTexto.secundario,
                    ),
                  ),
                  RadioListTile<String>(
                    value: 'transferencia',
                    title: Text('Transferencia'),
                    subtitle: Text(
                      'Va directo a su cuenta; no descuenta del '
                      'pendiente a entregar.',
                      style: AppTexto.secundario,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppEspacio.md),
            const Text('¿De dónde sale el dinero?',
                style: AppTexto.subtitulo),
            RadioGroup<String>(
              groupValue: _destino,
              onChanged: (v) =>
                  setState(() => _destino = v ?? 'nomina'),
              child: Column(
                children: [
                  const RadioListTile<String>(
                    value: 'nomina',
                    title: Text('Nómina'),
                    subtitle: Text(
                      'Solo descuenta de la nómina del mes.',
                      style: AppTexto.secundario,
                    ),
                  ),
                  RadioListTile<String>(
                    value: 'pendiente',
                    // B1: deshabilitado por transferencia.
                    enabled: _metodo != 'transferencia',
                    title: const Text('Pendiente a entregar'),
                    subtitle: const Text(
                      'Descuenta del pendiente a entregar de su '
                      'gaveta y además aparece en su libro de nómina.',
                      style: AppTexto.secundario,
                    ),
                  ),
                ],
              ),
            ),
            if (_metodo == 'transferencia')
              const Text(
                'Por transferencia el destino es Nómina: el '
                'pendiente a entregar es efectivo en mano.',
                style: AppTexto.secundario,
              ),
          ],
        ),
      ),
      acciones: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context)
              .pop((metodo: _metodo, destino: _destino)),
          child: const Text('Aprobar'),
        ),
      ],
    );
  }
}

/// F2-12: diálogo de rechazo como StatefulWidget propio: posee
/// y dispone el controlador del motivo (antes quedaba sin
/// disponer). Devuelve el motivo (puede ir vacío: el llamador
/// exige que no lo sea) o null si se cancela.
class _DialogoRechazarAdelanto extends StatefulWidget {
  const _DialogoRechazarAdelanto();

  @override
  State<_DialogoRechazarAdelanto> createState() =>
      _DialogoRechazarAdelantoState();
}

class _DialogoRechazarAdelantoState
    extends State<_DialogoRechazarAdelanto> {
  final _motivoCtrl = TextEditingController();

  @override
  void dispose() {
    _motivoCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DialogoApp(
      titulo: 'Rechazar solicitud',
      iconoTitulo: Icons.block_rounded,
      contenido: TextField(
        controller: _motivoCtrl,
        decoration: const InputDecoration(
          labelText: 'Motivo del rechazo',
          border: OutlineInputBorder(),
        ),
        maxLength: 120,
      ),
      acciones: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: () =>
              Navigator.of(context).pop(_motivoCtrl.text.trim()),
          child: const Text('Rechazar'),
        ),
      ],
    );
  }
}
