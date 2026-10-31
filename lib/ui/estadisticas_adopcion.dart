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
import 'componentes.dart';
import 'diseno.dart';

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
  Map<String, dynamic> _d = {};

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
        });
      }
      return;
    }
    setState(() {
      _cargando = true;
      _error = null;
    });
    try {
      final res = await Supabase.instance.client
          .rpc('estadisticas_adopcion');
      if (mounted) {
        setState(() {
          _d = Map<String, dynamic>.from(res as Map);
          _cargando = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'No se pudieron cargar las estadísticas. '
              'Revisa la conexión e inténtalo de nuevo.';
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
      appBar: AppBar(
        title: const Text('Adopción de la app'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Actualizar',
            onPressed: _cargando ? null : _cargar,
          ),
        ],
      ),
      body: _cargando
          ? const EstadoCargando(texto: 'Cargando estadísticas…')
          : _error != null
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(_error!,
                            textAlign: TextAlign.center,
                            style: AppTexto.secundario),
                      ),
                      FilledButton.icon(
                        icon: const Icon(Icons.refresh, size: 18),
                        label: const Text('Reintentar'),
                        onPressed: _cargar,
                      ),
                    ],
                  ),
                )
              : _contenido(),
    );
  }

  Widget _contenido() {
    final tasa = (_d['tasa_activacion'] as num?)?.toDouble();
    final variacion = (_d['variacion_nuevos_pct'] as num?)?.toDouble();
    final serie = _lista('serie_activados');
    final horas = _lista('histograma_horas');
    final top = _lista('top_10');
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            _tarjetaNumero('Accesos creados', '${_n('generados')}'),
            const SizedBox(width: 12),
            _tarjetaNumero('Ya activaron', '${_n('activados')}'),
            const SizedBox(width: 12),
            _tarjetaNumero(
              'Activación',
              tasa == null
                  ? '—'
                  : '${(tasa * 100).toStringAsFixed(0)}%',
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            _tarjetaNumero(
              'Nuevos este mes',
              '${_n('nuevos_mes_actual')}',
              pie: variacion == null
                  ? 'mes anterior: ${_n('nuevos_mes_anterior')}'
                  : '${variacion >= 0 ? '↑' : '↓'} ${variacion.abs().toStringAsFixed(0)}% '
                      'vs mes anterior (${_n('nuevos_mes_anterior')})',
            ),
            const SizedBox(width: 12),
            _tarjetaNumero(
              'Ingresos / semana',
              ((_d['promedio_accesos_semana'] as num?)?.toDouble() ?? 0).toStringAsFixed(1),
              pie: '${_n('ingresos_28d')} ingresos en 28 días',
            ),
          ],
        ),
        const SizedBox(height: 20),
        Text('Activaciones por día · últimos 90 días',
            style: AppTexto.subtitulo
                .copyWith(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        if (serie.isEmpty)
          const Text('Sin datos de activaciones.',
              style: AppTexto.secundario)
        else
          GraficoBarrasDiarias(datos: serie, altura: 96),
        const SizedBox(height: 20),
        Text('Ingresos por hora del día · 90 días',
            style: AppTexto.subtitulo
                .copyWith(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        if (horas.isEmpty)
          const Text('Sin ingresos registrados.', style: AppTexto.secundario)
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
          const Text('Todavía no hay ingresos registrados.',
              style: AppTexto.secundario)
        else
          for (var i = 0; i < top.length; i++)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: CircleAvatar(
                radius: 14,
                child: Text('${i + 1}',
                    style: const TextStyle(fontSize: 12)),
              ),
              title: Text((top[i]['nombre'] ?? '').toString()),
              trailing: Text('${top[i]['ingresos'] ?? 0} ingresos',
                  style: AppTexto.secundario),
            ),
      ],
    );
  }

  Widget _tarjetaNumero(String titulo, String valor, {String? pie}) {
    return Expanded(
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(titulo,
                  style: const TextStyle(
                      fontSize: 11, color: Colors.grey)),
              const SizedBox(height: 4),
              Text(valor,
                  style: const TextStyle(
                      fontSize: 22, fontWeight: FontWeight.bold)),
              if (pie != null) ...[
                const SizedBox(height: 2),
                Text(pie,
                    style: const TextStyle(
                        fontSize: 10, color: Colors.grey)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
