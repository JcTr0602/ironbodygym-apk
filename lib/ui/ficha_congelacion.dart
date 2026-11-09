/// Sección de congelación en la ficha del cliente
/// (Congelación 0.5, M2 — punto único, cualquier rol).
///
/// - Dueño: lee el espejo local. Si hay una solicitud
///   PENDIENTE, avisa y lleva a la bandeja a resolverla; si
///   hay una APROBADA, muestra el sello «❄️ Congelación
///   aprobada» con su ventana y el botón «Cerrar ahora».
/// - Entrenador: su espejo jamás contiene estas filas (el
///   motivo es privado). Lee la RPC congelacion_vigente_staff,
///   que solo devuelve la VENTANA de la pausa aprobada — sin
///   motivo ni categoría — y ofrece el mismo «Cerrar ahora»
///   (el cierre es de staff: es_staff() en el servidor).
///
/// Sin nada vigente, la sección no ocupa espacio. La lectura
/// remota del staff va DESPUÉS de pintar la ficha (widget con
/// estado propio, como SeccionAccesoAppFicha) y con timeout:
/// un fallo la deja invisible, nunca bloquea la ficha.
library;

import 'package:flutter/material.dart';

import '../auth.dart';
import '../congelaciones_gestion.dart';
import '../errores_sync.dart';
import '../tiempo.dart';
import 'componentes.dart';
import 'congelaciones.dart';

String _fmtF(DateTime? d) {
  if (d == null) return '—';
  final dd = d.day.toString().padLeft(2, '0');
  final mm = d.month.toString().padLeft(2, '0');
  return '$dd/$mm/${d.year}';
}

DateTime? _f(Object? v) {
  if (v == null) return null;
  final s = '$v';
  if (s.length < 10) return null;
  return DateTime.tryParse(s.substring(0, 10));
}

class SeccionCongelacionFicha extends StatefulWidget {
  final int clienteId;
  const SeccionCongelacionFicha({super.key, required this.clienteId});
  @override
  State<SeccionCongelacionFicha> createState() =>
      _SeccionCongelacionFichaState();
}

class _SeccionCongelacionFichaState
    extends State<SeccionCongelacionFicha> {
  CongelacionGestion? _pendiente;
  CongelacionGestion? _aprobada;
  Map<String, dynamic>? _vigenteStaff;
  bool _actuando = false;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    if (AuthService().isOwner) {
      final filas = await CongelacionesService.instance
          .deCliente(widget.clienteId);
      if (!mounted) return;
      setState(() {
        _pendiente = null;
        _aprobada = null;
        for (final f in filas) {
          if (f.esPendiente && _pendiente == null) _pendiente = f;
          if (f.esAprobada && _aprobada == null) _aprobada = f;
        }
      });
    } else {
      final v = await CongelacionesService.instance
          .vigenteStaff(widget.clienteId);
      if (!mounted) return;
      setState(() => _vigenteStaff = v);
    }
  }

  void _snack(String texto) {
    if (!mounted) return;
    mostrarSnack(context, texto);
  }

  Future<void> _cerrar(String id) async {
    final confirma = await showDialog<bool>(
      context: context,
      builder: (ctx) => DialogoApp(
        titulo: 'Cerrar la congelación ahora',
        iconoTitulo: Icons.ac_unit_rounded,
        contenido: const Text(
          'La pausa termina ayer: los días congelados hasta '
          'ayer se le devuelven al sincronizar y desde hoy su '
          'mensualidad corre normal. Si aún no había empezado, '
          'se cancela con 0 días. Queda registrado que la '
          'cerraste tú.',
        ),
        acciones: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Volver'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Cerrar ahora'),
          ),
        ],
      ),
    );
    if (confirma != true || !mounted) return;
    setState(() => _actuando = true);
    try {
      final res = await CongelacionesService.instance.cerrar(
        id: id,
        cerradoPorNombre: AuthService().displayName,
      );
      if (!mounted) return;
      if (res['ok'] == true) {
        _snack(res['ya_cerrada'] == true
            ? 'La congelación ya estaba cerrada.'
            : 'Congelación cerrada.');
        await _cargar();
      } else {
        _snack('${res['error'] ?? 'No se pudo cerrar'}');
      }
    } catch (e) {
      _snack('No se pudo cerrar: ${mensajeErrorAmable(e)}');
    } finally {
      if (mounted) setState(() => _actuando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hoy = ahoraHabana();
    // Vista del dueño (espejo completo).
    if (AuthService().isOwner) {
      if (_pendiente == null && _aprobada == null) {
        return const SizedBox.shrink();
      }
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_pendiente != null) ...[
                const Row(
                  children: [
                    Icon(Icons.ac_unit_rounded, size: 20),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '❄️ Solicitud de congelación pendiente',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  '${_fmtF(_pendiente!.desde)} → '
                  '${_fmtF(_pendiente!.hasta)} · '
                  '${etiquetaCategoriaCongelacion(_pendiente!.motivoCategoria)}',
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton(
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const CongelacionesScreen(),
                      ),
                    ).then((_) => _cargar()),
                    child: const Text('Resolver'),
                  ),
                ),
              ],
              if (_aprobada != null) ...[
                if (_pendiente != null) const Divider(),
                Row(
                  children: [
                    const Icon(Icons.ac_unit_rounded, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '❄️ Congelación aprobada · '
                        '${_aprobada!.etiquetaEstado(hoy)}',
                        style: const TextStyle(
                            fontWeight: FontWeight.bold),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  '${_fmtF(_aprobada!.inicioEfectivo ?? _aprobada!.desde)}'
                  ' → ${_fmtF(_aprobada!.finEfectivo)}'
                  '${_aprobada!.materializada ? ' · +${_aprobada!.diasMaterializados} días ya aplicados' : ' · su vigencia se extiende al terminar'}',
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton.tonal(
                    onPressed: _actuando
                        ? null
                        : () => _cerrar(_aprobada!.id),
                    child: const Text('Cerrar ahora'),
                  ),
                ),
              ],
            ],
          ),
        ),
      );
    }
    // Vista del staff (solo la ventana, sin motivo).
    final v = _vigenteStaff;
    if (v == null) return const SizedBox.shrink();
    final inicio = _f(v['inicio_efectivo']) ?? _f(v['desde']);
    final fin = _f(v['hasta_efectivo']) ?? _f(v['hasta']);
    final mat = (v['dias_materializados'] as num?)?.toInt();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.ac_unit_rounded, size: 20),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '❄️ Congelación aprobada',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '${_fmtF(inicio)} → ${_fmtF(fin)}'
              '${mat != null ? ' · +$mat días ya aplicados' : ' · su vigencia se extiende al terminar'}',
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.tonal(
                onPressed:
                    _actuando ? null : () => _cerrar('${v['id']}'),
                child: const Text('Cerrar ahora'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
