/// 1.29 (Oleada 8, FB-23 · Auditoría Total): sección
/// «Actividad en la app de clientes» dentro de Auditoría.
///
/// SOLO dueño: con otra sesión la sección ni se pinta (la
/// misma compuerta que la Auditoría actual) — y aunque se
/// pintara, la RPC deniega en el servidor.
///
/// Flujo (el del plan §9): selector de PERSONA (los clientes
/// del espejo local, sin red) y de RANGO (todo / 30 días /
/// 7 días) → primero se pinta lo que haya en la CACHÉ local
/// de esa persona con su fecha («último descargado el…») →
/// la RPC enriquece en segundo plano (timeout de 12 s) y al
/// aterrizar reemplaza la foto y la guarda en caché → sin
/// conexión, la banda dice honestamente que lo mostrado es
/// lo último descargado y cuándo; si nunca se descargó, se
/// dice que no hay nada que mostrar sin conexión.
///
/// La caché es de consulta, no un espejo (P-08): acotada a
/// 200 filas por persona y 20 personas, y se purga al
/// cerrar sesión (LocalDb.purgaAlCerrarSesion).
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../actividad_cliente.dart';
import '../auth.dart';
import '../localdb.dart';
import '../tiempo.dart';
import 'app_bar.dart';
import 'componentes.dart';
import 'diseno.dart';
import 'skeleton.dart';

/// Un cliente elegible del selector: id + nombre del espejo
/// local (puro, testeable).
typedef ClienteElegibleFb23 = ({int id, String nombre});

/// Clientes del espejo ordenados por nombre (el selector no
/// necesita red: el padrón ya vive en el teléfono). Los
/// eliminados no se ofrecen (su actividad ya no se consulta
/// desde aquí). Puro.
List<ClienteElegibleFb23> clientesElegiblesFb23(
    List<Map<String, dynamic>> espejo) {
  final lista = <ClienteElegibleFb23>[
    for (final c in espejo)
      if (c['id'] is num && !LocalDb.esEliminadoDe(c))
        (
          id: (c['id'] as num).toInt(),
          nombre: '${c['nombre'] ?? ''}'.trim().isEmpty
              ? 'Cliente ${(c['id'] as num).toInt()}'
              : '${c['nombre']}'.trim(),
        ),
  ];
  lista.sort((a, b) =>
      a.nombre.toLowerCase().compareTo(b.nombre.toLowerCase()));
  return lista;
}

/// Rangos de la consulta. `dias == null` = sin rango (todo
/// lo que la RPC devuelva hasta el tope de 200).
enum RangoFb23 {
  todo(null, 'Todo'),
  dias30(30, 'Últimos 30 días'),
  dias7(7, 'Últimos 7 días');

  final int? dias;
  final String etiqueta;
  const RangoFb23(this.dias, this.etiqueta);
}

/// Instantes del rango elegido, calculados en UTC desde el
/// instante actual (la aritmética de días es de instantes:
/// inmune al cambio de horario de Cuba). Función pura.
({DateTime? desde, DateTime? hasta}) rangoFb23(RangoFb23 rango,
    {required DateTime ahoraUtc}) {
  final d = rango.dias;
  if (d == null) return (desde: null, hasta: null);
  return (desde: ahoraUtc.subtract(Duration(days: d)), hasta: null);
}

/// Texto honesto de la banda sin conexión cuando hay caché:
/// «sin conexión: mostrando lo último descargado el …» con
/// la fecha del volcado EN HORA DE LA HABANA. Función pura.
String textoSinConexionFb23(DateTime descargadoEnUtc) {
  final h = aHabana(descargadoEnUtc);
  String dos(int n) => n.toString().padLeft(2, '0');
  return 'Sin conexión: mostrando lo último descargado el '
      '${h.day}/${h.month}/${h.year} a las '
      '${dos(h.hour)}:${dos(h.minute)}';
}

/// Sección embebible en la pantalla de Auditoría (al final
/// del registro local: no bloquea ni sustituye nada de lo
/// que ya hay).
class SeccionActividadAppClientes extends StatefulWidget {
  final ActividadClienteService? servicio;

  /// 1.30 (Oleada 10, FICHA-08): cliente fijo — la
  /// sección nace consultando a ESTA persona y no pinta
  /// selector (la abre la ficha del cliente). Null = la
  /// sección de Auditoría de siempre, con su lista.
  final int? clienteIdFijo;

  const SeccionActividadAppClientes(
      {super.key, this.servicio, this.clienteIdFijo});

  @override
  State<SeccionActividadAppClientes> createState() =>
      _SeccionActividadAppClientesState();
}

class _SeccionActividadAppClientesState
    extends State<SeccionActividadAppClientes> {
  late final ActividadClienteService _servicio =
      widget.servicio ?? ActividadClienteService();

  List<ClienteElegibleFb23> _clientes = [];
  int? _clienteId;
  RangoFb23 _rango = RangoFb23.todo;
  List<ActividadCliente> _filas = [];
  DateTime? _descargadoEn;
  bool _desdeCache = false;
  bool _sinConexion = false;
  bool _cargandoLista = true;
  bool _consultando = false;
  int _generacion = 0;

  @override
  void initState() {
    super.initState();
    final fijo = widget.clienteIdFijo;
    if (fijo != null) {
      // FICHA-08: no hay lista que cargar; la persona se
      // elige sola al primer frame (pinta la caché y
      // enriquece con la RPC, igual que al elegir a mano).
      _cargandoLista = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _elegir(fijo);
      });
    } else {
      _cargarClientes();
    }
  }

  Future<void> _cargarClientes() async {
    final espejo = await LocalDb.instance.allMirror('clientes');
    if (!mounted) return;
    setState(() {
      _clientes = clientesElegiblesFb23(espejo);
      _cargandoLista = false;
    });
  }

  /// Elige persona: pinta primero la caché (si la hay) y
  /// después enriquece con la RPC en segundo plano.
  Future<void> _elegir(int? id) async {
    final gen = ++_generacion;
    setState(() {
      _clienteId = id;
      _filas = [];
      _descargadoEn = null;
      _desdeCache = false;
      _sinConexion = false;
    });
    if (id == null) return;
    final cache = await _servicio.leerCache(id);
    if (!mounted || gen != _generacion) return;
    if (cache != null) {
      setState(() {
        _filas = cache.filas;
        _descargadoEn = cache.descargadoEn;
        _desdeCache = true;
      });
    }
    await _consultar(gen);
  }

  Future<void> _consultar(int gen) async {
    final id = _clienteId;
    if (id == null) return;
    setState(() => _consultando = true);
    final r = rangoFb23(_rango, ahoraUtc: ahoraUtcReal());
    try {
      final filas = await _servicio.consultar(ActividadClienteParams(
        clienteId: id,
        desde: r.desde,
        hasta: r.hasta,
      ));
      if (!mounted || gen != _generacion) return;
      final ahora = ahoraUtcReal();
      await _servicio.guardarCache(id, filas, ahora);
      if (!mounted || gen != _generacion) return;
      setState(() {
        _filas = filas;
        _descargadoEn = ahora;
        _desdeCache = false;
        _sinConexion = false;
        _consultando = false;
      });
    } catch (_) {
      if (!mounted || gen != _generacion) return;
      setState(() {
        // Sin red (o la RPC denegó): si hay foto cacheada se
        // queda pintada y la banda lo dice con su fecha; si
        // nunca se descargó, no hay nada que mostrar y
        // también se dice. Error ≠ vacío.
        _sinConexion = true;
        _consultando = false;
      });
    }
  }

  Future<void> _cambiarRango(RangoFb23 r) async {
    if (r == _rango) return;
    setState(() => _rango = r);
    if (_clienteId != null) await _consultar(++_generacion);
  }

  @override
  Widget build(BuildContext context) {
    // La misma compuerta que la Auditoría actual: sin
    // sesión de dueño, la sección ni se pinta.
    bool esDueno = false;
    try {
      esDueno = AuthService().isOwner;
    } catch (_) {
      esDueno = false;
    }
    if (!esDueno) return const SizedBox.shrink();

    return Tarjeta(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Actividad en la app de clientes',
              style: AppTexto.titulo),
          const SizedBox(height: AppEspacio.xs),
          const Text(
            'Lo que el servidor tiene registrado de la app de '
            'clientes: activaciones, sesiones subidas y vales '
            'de Premios. Los avisos de acceso (PIN) no dejan '
            'rastro durable por diseño y no aparecen aquí.',
            style: AppTexto.secundario,
          ),
          const SizedBox(height: AppEspacio.md),
          // 1.30 (Oleada 10, FICHA-08): con cliente fijo
          // no hay selector — solo los chips de rango.
          if (widget.clienteIdFijo != null)
            Wrap(
              spacing: AppEspacio.sm,
              children: [
                for (final r in RangoFb23.values)
                  ChoiceChip(
                    label: Text(r.etiqueta),
                    selected: _rango == r,
                    onSelected: (_) => _cambiarRango(r),
                  ),
              ],
            )
          else if (_cargandoLista)
            const SkeletonLista(items: 1)
          else if (_clientes.isEmpty)
            const Text(
              'Sin clientes en este teléfono todavía: '
              'sincroniza para poder consultar.',
              style: AppTexto.secundario,
            )
          else ...[
            DropdownButtonFormField<int>(
              initialValue: _clienteId,
              decoration: const InputDecoration(
                labelText: 'Persona',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              items: [
                for (final c in _clientes)
                  DropdownMenuItem(value: c.id, child: Text(c.nombre)),
              ],
              onChanged: _elegir,
            ),
            const SizedBox(height: AppEspacio.sm),
            Wrap(
              spacing: AppEspacio.sm,
              children: [
                for (final r in RangoFb23.values)
                  ChoiceChip(
                    label: Text(r.etiqueta),
                    selected: _rango == r,
                    onSelected: (_) => _cambiarRango(r),
                  ),
              ],
            ),
          ],
          if (_clienteId != null) ...[
            const SizedBox(height: AppEspacio.md),
            if (_sinConexion && _descargadoEn != null)
              AvisoEstado(
                tipo: TipoAviso.aviso,
                texto: textoSinConexionFb23(_descargadoEn!),
              )
            else if (_sinConexion)
              const AvisoEstado(
                tipo: TipoAviso.aviso,
                texto: 'Sin conexión y sin nada descargado '
                    'todavía de esta persona: no hay actividad '
                    'que mostrar.',
              )
            else if (_consultando && _filas.isEmpty)
              const SkeletonLista(items: 2)
            else if (_desdeCache && _descargadoEn != null)
              Text(
                'Mostrando lo último descargado el '
                '${fmtFechaHabana(_descargadoEn!)}…',
                style: AppTexto.secundario,
              ),
            if (_consultando && _filas.isNotEmpty)
              const Padding(
                padding: EdgeInsets.only(top: AppEspacio.sm),
                child: LinearProgressIndicator(minHeight: 2),
              ),
            const SizedBox(height: AppEspacio.sm),
            if (!_consultando && !_sinConexion && _filas.isEmpty)
              Text(
                _desdeCache
                    ? 'La última descarga de esta persona no '
                        'trajo actividad.'
                    : 'Sin actividad registrada de esta '
                        'persona en el servidor.',
                style: AppTexto.secundario,
              )
            else
              for (final f in _filas) _fila(f),
          ],
        ],
      ),
    );
  }

  Widget _fila(ActividadCliente f) {
    final detalle = detalleActividadCliente(f);
    final icono = switch (f.fuente) {
      'sesion' => Icons.fitness_center_rounded,
      'vale' => Icons.emoji_events_rounded,
      _ => Icons.phone_android_rounded,
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppEspacio.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icono,
              size: 20, color: AppColores.textoSecundario(context)),
          const SizedBox(width: AppEspacio.md),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(tituloActividadCliente(f),
                    style: AppTexto.cuerpo
                        .copyWith(fontWeight: FontWeight.w500)),
                if (detalle.isNotEmpty)
                  Text(detalle, style: AppTexto.secundario),
                Text(
                  fmtFechaHabana(f.creadoEn),
                  style: AppTexto.secundario,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Pantalla completa de la sección (la puerta desde la
/// ficha del cliente la abre con la persona ya elegida es
/// la tarjeta de FB-20; esta pantalla queda para un acceso
/// directo si un día se quiere).
class ActividadAppClientesScreen extends StatelessWidget {
  final ActividadClienteService? servicio;
  const ActividadAppClientesScreen({super.key, this.servicio});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: appBarIron(context, 'Actividad en la app de clientes'),
      body: ListView(
        padding: const EdgeInsets.all(AppEspacio.md),
        children: [
          SeccionActividadAppClientes(servicio: servicio),
        ],
      ),
    );
  }
}

/// 1.30 (Oleada 10, FICHA-08): la actividad en la app de
/// UN cliente, abierta desde su ficha: la misma sección
/// de Auditoría con el cliente fijo (sin selector). El
/// nombre va arriba para que se sepa de quién se mira.
class ActividadAppPorClienteScreen extends StatelessWidget {
  final int clienteId;
  final String nombreCliente;
  final ActividadClienteService? servicio;

  const ActividadAppPorClienteScreen({
    super.key,
    required this.clienteId,
    required this.nombreCliente,
    this.servicio,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: appBarIron(context, 'Actividad en la app'),
      body: ListView(
        padding: const EdgeInsets.all(AppEspacio.md),
        children: [
          Text(nombreCliente, style: AppTexto.titulo),
          const SizedBox(height: AppEspacio.sm),
          SeccionActividadAppClientes(
            clienteIdFijo: clienteId,
            servicio: servicio,
          ),
        ],
      ),
    );
  }
}
