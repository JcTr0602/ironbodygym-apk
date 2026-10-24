/// ✅ Pagaron este mes (v1.6.0, retoque pedido por Jc).
/// El LISTADO exacto detrás de la cifra «Pagaron el mes» de Home y
/// del KPI «Pagos este mes» del panel: los clientes que forman la
/// base del mes vigente. La fuente es [NominaCalc.idsQuePagaronElMes]
/// — el MISMO conjunto (misma función) que produce la cifra, así que
/// la lista y el número nunca pueden discrepar: deduplica por
/// cliente sobre el espejo `pagos` y aplica la excepción del mes en
/// curso (quien vence dentro del propio mes no entra en su base).
/// Sin filtro por entrenador a propósito: la cifra de Home es global
/// y esta lista la refleja tal cual.
library;

import 'package:flutter/material.dart';

import '../auth.dart';
import '../localdb.dart';
import '../negocio.dart';
import '../nomina_calc.dart';
import '../sync.dart';
import 'componentes.dart';
import 'ficha.dart';
import 'pagos_realizados.dart' show ClienteAvatarThumb;
import 'widgets.dart';

class PagaronMesScreen extends StatefulWidget {
  const PagaronMesScreen({super.key});

  @override
  State<PagaronMesScreen> createState() => _PagaronMesScreenState();
}

class _PagaronMesScreenState extends State<PagaronMesScreen> {
  bool _cargando = true;
  List<Map<String, dynamic>> _filas = [];

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  /// Mismo patrón que PagosRealizadosScreen: el ⟳ sincroniza el
  /// alcance de pagos y luego relee la lista local.
  Future<void> _actualizar() async {
    try {
      await SyncEngine.instance.sincronizarScope('pagos');
      await _cargar();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Lista actualizada')));
    } catch (_) {
      await _cargar();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Sin conexión: mostrando datos locales')));
    }
  }

  Future<void> _cargar() async {
    // La lista sale del conjunto de NominaCalc (la cifra), no de una
    // consulta paralela: ids primero y datos del espejo después.
    final ids = await NominaCalc.idsQuePagaronElMes(
        NominaCalc.prefMesActual());
    final datos =
        await LocalDb.instance.mirrorPorIds('clientes', ids);
    final porId = <int, Map<String, dynamic>>{
      for (final c in datos) (c['id'] as num).toInt(): c,
    };
    final lista = <Map<String, dynamic>>[
      for (final id in ids)
        if (porId[id] != null)
          {
            'id': id,
            'nombre': '${porId[id]!['nombre'] ?? 'Cliente $id'}',
            'pagado_hasta': porId[id]!['pagado_hasta'],
            'foto_local': porId[id]!['foto_local'],
            'foto_storage': porId[id]!['foto_storage'],
            'sin_datos': false,
          }
        else
          {
            // La regla de NominaCalc CONSERVA en la base al cliente
            // sin fila en el espejo (sync incompleta): la lista lo
            // muestra como marcador para que las filas y la cifra
            // coincidan, sin navegar a una ficha vacía.
            'id': id,
            'nombre': 'Cliente $id',
            'pagado_hasta': null,
            'foto_local': null,
            'foto_storage': null,
            'sin_datos': true,
          },
    ];
    lista.sort(compararPorNombre);
    if (mounted) {
      setState(() {
        _filas = lista;
        _cargando = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // B1 (Jc, 2026-10-24, para la nómina de octubre): la lista ya NO
    // es solo del dueño. El entrenador la ve para verificar su base
    // (cada cliente que pagó = 150 CUP), en SOLO LECTURA: sin dueño
    // no hay chevron ni navegación a la ficha desde aquí (la ficha
    // sigue alcanzable por sus rutas habituales, sin cambio).
    // La lista en sí no tiene ninguna acción de edición.
    final esDueno = AuthService().isOwner;
    return Scaffold(
      appBar: AppBar(
        title: Text(_cargando
            ? 'Pagaron este mes'
            : 'Pagaron este mes (${_filas.length})'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Actualizar (bajar cambios)',
            onPressed: _actualizar,
          ),
        ],
      ),
      body: Column(
        children: [
          const SyncBanner(alcance: 'pagos'),
          Expanded(
            child: _cargando
                ? const Center(child: CircularProgressIndicator())
                : _filas.isEmpty
                    ? const EstadoVacio(
                        icono: Icons.payments,
                        titulo: 'Nadie ha pagado este mes',
                        subtitulo:
                            'Los clientes que paguen aparecerán aquí')
                    : RefreshIndicator(
                        onRefresh: _actualizar,
                        child: ListView.builder(
                          itemCount: _filas.length,
                          itemBuilder: (ctx, i) {
                            final c = _filas[i];
                            final sinDatos = c['sin_datos'] == true;
                            return ListTile(
                              leading: sinDatos
                                  ? const CircleAvatar(
                                      child: Icon(Icons.person_outline),
                                    )
                                  : ClienteAvatarThumb(
                                      fotoLocal:
                                          c['foto_local'] as String?,
                                      fotoStorage:
                                          c['foto_storage'] as String?,
                                    ),
                              title: Text('${c['nombre']}'),
                              subtitle: Text(
                                sinDatos
                                    ? 'Datos aún sin descargar'
                                    : 'Pagado hasta: '
                                        '${fmtFecha(c['pagado_hasta'] as String?)}',
                                style: const TextStyle(fontSize: 12),
                              ),
                              trailing: sinDatos || !esDueno
                                  ? null
                                  : const Icon(Icons.chevron_right),
                              onTap: sinDatos || !esDueno
                                  ? null
                                  : () => Navigator.of(context)
                                      .push(MaterialPageRoute(
                                        builder: (_) => FichaScreen(
                                            clienteId: c['id'] as int),
                                      )).then((_) => _cargar()),
                            );
                          },
                        ),
                      ),
          ),
        ],
      ),
    );
  }
}
