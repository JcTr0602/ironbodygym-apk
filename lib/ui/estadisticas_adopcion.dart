// lib/ui/estadisticas_adopcion.dart
// v1.4.1 (Pieza 9): estadísticas de adopción de la app de clientes.
// Los datos los agrega el servidor en la RPC
// public.estadisticas_adopcion() (SECURITY DEFINER, solo el dueño
// vía es_admin(); cortes de día/mes en America/Havana). Definiciones:
// "activado" = acceso con al menos un ingreso registrado; la serie
// cuenta el día del PRIMER ingreso de cada acceso (90 días).
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../auth.dart';
import 'app_bar.dart';
import 'componentes.dart';
import 'diseno.dart';

/// 1.32 (B1-H8): el mensaje de ORIGEN de un error de la
/// RPC de estadísticas. El `RAISE` del servidor («Solo el
/// administrador puede ver las estadísticas.») viaja en el
/// mensaje de la PostgrestException; se detecta por el
/// nombre del tipo, sin importar Supabase en el clasificador
/// (mismo espíritu que `mensajeErrorAmable`).
String mensajeDeErrorServidor(Object e) {
  if (e.runtimeType.toString() == 'PostgrestException') {
    return ((e as dynamic).message?.toString() ?? '').trim();
  }
  return e.toString();
}

/// 1.32 (B1-H8): ¿el desenlace de la carga es un error de
/// PERMISO? Verdadero si la guarda local de dueño lo marcó
/// ([mostrado] empieza por «Solo el dueño») o si el mensaje
/// de ORIGEN del servidor dice «administrador» (el RAISE de
/// la RPC). Antes el catch sustituía el error por el
/// genérico de conexión y la clase de permiso quedaba
/// inalcanzable por la vía del servidor.
bool esErrorPermisoEstadisticas({String? mostrado, String? origen}) =>
    (mostrado != null && mostrado.startsWith('Solo el dueño')) ||
    (origen != null && origen.contains('administrador'));

class EstadisticasAdopcionScreen extends StatefulWidget {
  const EstadisticasAdopcionScreen({super.key});

  @override
  State<EstadisticasAdopcionScreen> createState() =>
      _EstadisticasAdopcionScreenState();
}

class _EstadisticasAdopcionScreenState
    extends State<EstadisticasAdopcionScreen> {
  bool _cargando = true;
  String? _error;

  /// 1.32 (B1-H8): el mensaje de ORIGEN del último error
  /// del servidor, conservado aparte del texto amable que
  /// se pinta: es sobre él (y no sobre el genérico) que se
  /// clasifica el permiso.
  String _errorOrigen = '';
  Map<String, dynamic> _d = {};

  /// El aviso de permiso (no es un fallo de lectura): B6 lo
  /// clasifica C4 y no ofrece Reintentar.
  bool get _esErrorDePermiso => esErrorPermisoEstadisticas(
      mostrado: _error, origen: _errorOrigen);

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    // Argón stats MENOR: el servidor ya exige es_admin, pero no hay
    // que disparar la RPC fallida si un entrenador llega a la ruta.
    if (!AuthService().isOwner) {
      if (mounted) {
        setState(() {
          _cargando = false;
          _error = 'Solo el dueño ve estas estadísticas.';
          _errorOrigen = '';
        });
      }
      return;
    }
    setState(() {
      _cargando = true;
      _error = null;
      _errorOrigen = '';
    });
    try {
      // Autoauditoría 1.22 #2: lectura con timeout (12 s): sin
      // tope, una conexión colgada dejaba el spinner eterno y el
      // error con reintento de abajo nunca se alcanzaba.
      final res = await Supabase.instance.client
          .rpc('estadisticas_adopcion')
          .timeout(const Duration(seconds: 12));
      if (mounted) {
        setState(() {
          _d = Map<String, dynamic>.from(res as Map);
          _cargando = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          // 1.32 (B1-H8): el texto pintado sigue siendo el
          // amable, pero el ORIGEN se conserva para que la
          // clase de permiso sea alcanzable (el RAISE del
          // servidor ya no se pierde en el catch).
          // 1.36 H-B1 (136-319): sin atribuir el fallo a
          // la conexión (el origen clasificado ya viaja en
          // _errorOrigen para el detalle).
          _error = 'No se pudieron cargar las estadísticas. '
              'Inténtalo de nuevo.';
          _errorOrigen = mensajeDeErrorServidor(e);
          _cargando = false;
        });
      }
    }
  }

  int _n(String k) => (_d[k] as num?)?.toInt() ?? 0;

  List<Map<String, dynamic>> _lista(String k) {
    final v = _d[k];
    if (v is! List) return [];
    return [
      for (final e in v) Map<String, dynamic>.from(e as Map)
    ];
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: appBarIron(
        context,
        'Adopción de la app',
        acciones: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: 'Actualizar',
            onPressed: _cargando ? null : _cargar,
          ),
        ],
      ),
      // 1.23 T7: cruce por tipo de estado (cargando/error/
      // contenido). 1.23 B6: el error es el EstadoError
      // clasificado — el fallo de lectura es C1 (Reintentar
      // idempotente); el aviso de «solo el dueño» es permiso
      // (C4: sin acción, reintentar no cambia nada).
      body: CruceEstados(
        estado: _cargando
            ? 'cargando'
            : _error != null
                ? 'error'
                : 'contenido',
        child: _cargando
            ? const EstadoCargando(texto: 'Cargando estadísticas…')
            : _error != null
              ? EstadoError(
                  detalle: _error!,
                  claseError: _esErrorDePermiso
                      ? ClaseError.validacion
                      : ClaseError.lectura,
                  onReintentar: _cargar,
                )
              // Argón Estadísticas #9: pull-to-refresh como
              // el resto de pantallas de estadísticas.
              : RefrescoIron(
                  onRefresh: _cargar,
                  child: _contenido(),
                ),
      ),
    );
  }

  Widget _contenido() {
    final tasa = (_d['tasa_activacion'] as num?)?.toDouble();
    final variacion = (_d['variacion_nuevos_pct'] as num?)?.toDouble();
    final serie = _lista('serie_activados');
    final horas = _lista('histograma_horas');
    final top = _lista('top_10');
    return ListView(
      padding: const EdgeInsets.all(AppEspacio.lg),
      children: [
        // SL-10 G13-2 (sync-una-vez): sin banda de sync
        // en Adopción — el estado lo dice una sola vez el
        // icono de la cabecera de la app.
        // 1.36 H-B3 (136-737): los 3 KPI en Wrap responsive
        // (antes Expanded fijos que apretaban en pantallas
        // estrechas): 3 por fila en ancho, 2+1 en estrecho.
        LayoutBuilder(
          builder: (ctx, cons) {
            final ancho = cons.maxWidth;
            final porFila = ancho >= 560 ? 3 : 2;
            final w = (ancho - 12 * (porFila - 1)) / porFila;
            return Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                SizedBox(
                    width: w,
                    child: _tarjetaNumero(
                        'Accesos creados', '${_n('generados')}')),
                SizedBox(
                    width: w,
                    child: _tarjetaNumero(
                        'Ya activaron', '${_n('activados')}')),
                SizedBox(
                  width: w,
                  child: _tarjetaNumero(
                    'Activación',
                    tasa == null
                        ? '—'
                        : '${(tasa * 100).toStringAsFixed(0)}%',
                  ),
                ),
              ],
            );
          },
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _tarjetaNumero(
                'Nuevos este mes',
                '${_n('nuevos_mes_actual')}',
                pie: variacion == null
                    ? 'mes anterior: ${_n('nuevos_mes_anterior')}'
                    : '${variacion.abs().toStringAsFixed(0)}% '
                        'vs mes anterior (${_n('nuevos_mes_anterior')})',
                // 1.36 H-B3 (136-738): la tendencia va con
                // ICONO y color semánticos + etiqueta para el
                // lector (antes una flecha «↑/↓» en el texto,
                // sin color ni semántica).
                pieIcono: variacion == null
                    ? null
                    : (variacion >= 0
                        ? Icons.trending_up_rounded
                        : Icons.trending_down_rounded),
                pieColor: variacion == null
                    ? null
                    : (variacion >= 0
                        ? AppColores.exito
                        : AppColores.error),
                pieSemantica: variacion == null
                    ? null
                    : (variacion >= 0 ? 'Sube' : 'Baja'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _tarjetaNumero(
                'Ingresos / semana',
                ((_d['promedio_accesos_semana'] as num?)?.toDouble() ?? 0).toStringAsFixed(1),
                pie: '${_n('ingresos_28d')} ingresos en 28 días',
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        Text('Activaciones por día · últimos 90 días',
            style: AppTexto.subtitulo
                .copyWith(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        if (serie.isEmpty)
          // 1.36 H-B3 (136-738): vacíos con EstadoVacio de
          // la casa, no Text sueltos.
          const EstadoVacio(
            sinMarco: true,
            icono: Icons.bar_chart_rounded,
            titulo: 'Sin datos de activaciones',
            subtitulo: 'Aún no hay activaciones en los últimos 90 días.',
          )
        else
          GraficoBarrasDiarias(datos: serie, altura: 96),
        const SizedBox(height: 20),
        Text('Ingresos por hora del día · 90 días',
            style: AppTexto.subtitulo
                .copyWith(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        if (horas.isEmpty)
          const EstadoVacio(
            sinMarco: true,
            icono: Icons.schedule_rounded,
            titulo: 'Sin ingresos registrados',
            subtitulo: 'Aún no hay ingresos por hora en los últimos 90 días.',
          )
        else
          GraficoBarrasDiarias(
            datos: [
              for (final h in horas)
                {'fecha': '', 'total': h['total'] ?? 0}
            ],
            altura: 72,
            etiquetaPrimera: '0h',
            etiquetaUltima: '23h',
          ),
        const SizedBox(height: 20),
        Text('Clientes más activos · 90 días',
            style: AppTexto.subtitulo
                .copyWith(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        if (top.isEmpty)
          const EstadoVacio(
            sinMarco: true,
            icono: Icons.emoji_events_rounded,
            titulo: 'Todavía no hay ingresos registrados',
            subtitulo: 'Los clientes más activos aparecerán aquí.',
          )
        else
          for (var i = 0; i < top.length; i++)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: CircleAvatar(
                radius: 14,
                child: Text('${i + 1}',
                    style: AppTexto.metadato),
              ),
              title: Text((top[i]['nombre'] ?? '').toString()),
              trailing: Text('${top[i]['ingresos'] ?? 0} ingresos',
                  style: AppTexto.secundario),
            ),
      ],
    );
  }

  Widget _tarjetaNumero(String titulo, String valor,
      {String? pie,
      IconData? pieIcono,
      Color? pieColor,
      String? pieSemantica}) {
    // 1.36 H-B3 (136-737): la tarjeta ya no nace Expanded —
    // cada llamador decide su rejilla (Wrap o Row).
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppEspacio.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(titulo,
                style: AppTexto.minuscula.copyWith(
                    color: AppColores.textoSecundario(context))),
            const SizedBox(height: 4),
            Text(valor, style: AppTexto.metrica),
            if (pie != null) ...[
              const SizedBox(height: 2),
              if (pieIcono != null)
                Semantics(
                  label: pieSemantica != null
                      ? '$pieSemantica: $pie'
                      : pie,
                  child: Row(
                    children: [
                      Icon(pieIcono, size: 14, color: pieColor),
                      const SizedBox(width: 2),
                      Expanded(
                        child: Text(pie,
                            style: AppTexto.minuscula
                                .copyWith(color: pieColor)),
                      ),
                    ],
                  ),
                )
              else
                Text(pie,
                    style: AppTexto.minuscula.copyWith(
                        color: AppColores.textoSecundario(context))),
            ],
          ],
        ),
      ),
    );
  }
}
