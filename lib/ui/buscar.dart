/// Búsqueda de clientes (consulta/gestión): lista completa por defecto,
/// filtrado por nombre, carnet, teléfono y —opcional— notas.
/// El tap abre la ficha del cliente. El cobro vive en "Agregar pago".
library;

import 'dart:io';

import 'package:flutter/material.dart';

import '../fotos.dart';
import '../localdb.dart';
import '../perfil.dart';
import '../negocio.dart';
import '../tiempo.dart';
import '../sync.dart';
import 'componentes.dart';
import 'dialogo_pago.dart';
import 'pago_diario.dart';
import 'preview_cobro.dart';
import 'suplementos.dart';
import 'diseno.dart';
import 'ficha.dart';
import 'widgets.dart';

class BuscarScreen extends StatefulWidget {
  const BuscarScreen({super.key});
  @override
  State<BuscarScreen> createState() => _BuscarScreenState();
}

class _BuscarScreenState extends State<BuscarScreen> {
  final _q = TextEditingController();
  List<Map<String, dynamic>> _res = [];
  bool _busco = false;
  String _filtro = 'todos'; // todos | aldia | vencidos | porvencer | sinfoto
  bool _enNotas = false; // v1.0.15: búsqueda avanzada en notas
  String _rangoEdad = 'todas'; // v1.0.15: todas | 18-25 | 26-35 | 36-50 | 50+
  // Bloque 1: contadores por estado (siempre visibles), frescura
  // de la lista, deslizables configurables y salto por letra.
  Map<String, int> _conteos = {};
  DateTime? _ultimoPull;
  String _swipeDer = 'cobrar';
  String _swipeIzq = 'ninguna';
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _cargarConfig();
    _buscar(); // lista completa por defecto
  }

  /// Bloque 1: config local de deslizables + última bajada
  /// registrada por el motor de sync (meta ultimo_pull_ts).
  /// Un valor guardado fuera de la lista cerrada se ignora y
  /// vuelve al default (nunca se ejecuta una acción desconocida).
  Future<void> _cargarConfig() async {
    const cerrada = {'ninguna', 'cobrar', 'diario', 'venta', 'editar'};
    final der = await PerfilService.instance.getSwipeBuscarDer();
    final izq = await PerfilService.instance.getSwipeBuscarIzq();
    final ts = await LocalDb.instance.getMeta('ultimo_pull_ts');
    if (!mounted) return;
    setState(() {
      _swipeDer = cerrada.contains(der) ? der : 'cobrar';
      _swipeIzq = cerrada.contains(izq) ? izq : 'ninguna';
      _ultimoPull = ts == null ? null : DateTime.tryParse(ts);
    });
  }

  int _gen = 0;

  Future<void> _buscar() async {
    // v1.3.1: descartar resultados obsoletos (race condition).
    final gen = ++_gen;
    final q = _q.text.trim();
    var r = await listaClientes(q);
    if (gen != _gen) return;
    // v1.0.15: búsqueda avanzada — también en notas.
    if (_enNotas && q.isNotEmpty) {
      final nq = q.toLowerCase();
      final todos = await listaClientes('');
      if (gen != _gen) return;
      final vistos = <dynamic>{for (final c in r) c['id']};
      final extra = todos.where((c) =>
          !vistos.contains(c['id']) &&
          '${c['notas'] ?? ''}'.toLowerCase().contains(nq));
      r = [...r, ...extra];
      r.sort(
          compararPorNombre);
    }
    // Bloque 1: contadores por estado (sobre la búsqueda,
    // ANTES del filtro de estado: siempre visibles).
    final conteos = <String, int>{
      'todos': r.length,
      'aldia': 0,
      'porvencer': 0,
      'vencidos': 0,
      'sinfoto': 0,
    };
    for (final c in r) {
      final dias = diasRestantes(c['pagado_hasta'] as String?);
      if (dias != null && dias > 7) {
        conteos['aldia'] = conteos['aldia']! + 1;
      } else if (dias != null && dias >= 0 && dias <= 7) {
        conteos['porvencer'] = conteos['porvencer']! + 1;
      } else if (dias == null || dias < 0) {
        conteos['vencidos'] = conteos['vencidos']! + 1;
      }
      final ref = c['foto_storage'] as String?;
      if (ref == null || ref.isEmpty) {
        conteos['sinfoto'] = conteos['sinfoto']! + 1;
      }
    }
    // Filtros de estado de mensualidad.
    // v1.3.1: sin fecha = vencido (no "al día").
    if (_filtro != 'todos' && _filtro != 'sinfoto') {
      r = r.where((c) {
        final dias = diasRestantes(c['pagado_hasta'] as String?);
        switch (_filtro) {
          case 'aldia':
            return dias != null && dias > 7;
          case 'vencidos':
            return dias == null || dias < 0;
          case 'porvencer':
            return dias != null && dias >= 0 && dias <= 7;
          default:
            return true;
        }
      }).toList();
    }
    // v1.0.15: filtro por rango de edad (edad desde el carnet).
    if (_rangoEdad != 'todas') {
      r = r.where((c) {
        final edad = edadDeCarnet('${c['carnet'] ?? ''}');
        if (edad == null) return false;
        switch (_rangoEdad) {
          case '18-25':
            return edad >= 18 && edad <= 25;
          case '26-35':
            return edad >= 26 && edad <= 35;
          case '36-50':
            return edad >= 36 && edad <= 50;
          case '50+':
            return edad > 50;
          default:
            return true;
        }
      }).toList();
    }
    // v1.1 fix: solo clientes sin foto asignada (sin referencia
    // foto_storage). Antes verificaba el caché local, así que clientes
    // CON foto pero sin descargar aparecían erróneamente aquí.
    if (_filtro == 'sinfoto') {
      r = r.where((c) {
        final ref = c['foto_storage'] as String?;
        return ref == null || ref.isEmpty;
      }).toList();
    }
    if (mounted && gen == _gen) {
      setState(() {
        _res = r;
        _busco = true;
        _conteos = conteos;
      });
    }
  }

  /// Botón "Actualizar": baja cambios del servidor y recarga la lista.
  Future<void> _actualizar() async {
    // v1.3.1: manejar fallo de red (offline-first en Cuba).
    try {
      await SyncEngine.instance.pull();
      // Bloque 1: la bajada quedó registrada en ultimo_pull_ts.
      final ts = await LocalDb.instance.getMeta('ultimo_pull_ts');
      if (mounted && ts != null) {
        setState(() => _ultimoPull = DateTime.tryParse(ts));
      }
      await _buscar();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Lista actualizada')));
    } catch (_) {
      await _buscar();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Sin conexión: mostrando datos locales')));
    }
  }

  @override
  void dispose() {
    _q.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Buscar cliente'),
        actions: [
          IconButton(
            tooltip: 'Actualizar (bajar cambios)',
            icon: const Icon(Icons.refresh),
            onPressed: _actualizar,
          ),
        ],
      ),
      body: Column(
        children: [
          const SyncBanner(),
          Padding(
            padding: const EdgeInsets.all(12),
            child: CampoTexto(
              controller: _q,
              hint: 'Nombre, carnet o teléfono',
              icono: Icons.search,
              onChanged: (_) => _buscar(),
            ),
          ),
          Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                Text('${_res.length} cliente(s)',
                    style: TextStyle(
                        color: AppColores.textoSecundario(context),
                        fontSize: 12)),
                const Spacer(),
                Text(_textoActualizado(),
                    style: TextStyle(
                        color: AppColores.textoSecundario(context),
                        fontSize: 12)),
              ],
            ),
          ),
          // Bloque 1: cartel de lista vieja a las 24 h sin bajar
          // cambios (12 h alertaría cada mañana; 24 h no).
          if (_ultimoPull != null &&
              ahoraHabana().difference(_ultimoPull!).inHours >= 24)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: AppColores.alerta.withValues(alpha: 0.12),
                  borderRadius:
                      BorderRadius.circular(AppRadio.md),
                  border: Border.all(color: AppColores.alerta),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.warning_amber,
                        size: 18, color: AppColores.alerta),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text(
                          'Lista desactualizada: hace más de 24 h sin bajar cambios',
                          style: TextStyle(fontSize: 12.5)),
                    ),
                    TextButton(
                      onPressed: _actualizar,
                      child: const Text('Actualizar'),
                    ),
                  ],
                ),
              ),
            ),
          // v1.0.15: filtros rápidos
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Row(
              children: [
                _chipFiltro('todos',
                    'Todos (${_conteos['todos'] ?? 0})'),
                const SizedBox(width: 6),
                _chipFiltro('aldia',
                    'Al día (${_conteos['aldia'] ?? 0})',
                    punto: AppColores.exito),
                const SizedBox(width: 6),
                _chipFiltro('porvencer',
                    'Por vencer (${_conteos['porvencer'] ?? 0})',
                    punto: AppColores.alerta),
                const SizedBox(width: 6),
                _chipFiltro('vencidos',
                    'Vencidos (${_conteos['vencidos'] ?? 0})',
                    punto: AppColores.error),
                const SizedBox(width: 6),
                _chipFiltro('sinfoto',
                    'Sin foto (${_conteos['sinfoto'] ?? 0})'),
              ],
            ),
          ),
          // v1.0.15: búsqueda avanzada (notas + rango de edad)
          ExpansionTile(
            dense: true,
            visualDensity: VisualDensity.compact,
            title: const Text('Búsqueda avanzada',
                style: TextStyle(fontSize: 13)),
            children: [
              SwitchListTile(
                dense: true,
                visualDensity: VisualDensity.compact,
                title: const Text('Buscar también en notas',
                    style: TextStyle(fontSize: 13)),
                value: _enNotas,
                onChanged: (v) {
                  setState(() => _enNotas = v);
                  _buscar();
                },
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Rango de edad',
                        style: TextStyle(fontSize: 12)),
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 6,
                      children: [
                        _chipEdad('todas', 'Todas'),
                        _chipEdad('18-25', '18–25'),
                        _chipEdad('26-35', '26–35'),
                        _chipEdad('36-50', '36–50'),
                        _chipEdad('50+', '50+'),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          Expanded(
            child: _res.isEmpty
                ? EstadoVacio(
                    icono: Icons.search_off,
                    titulo: _busco ? 'Sin resultados' : 'Busca un cliente',
                    subtitulo: _busco
                        ? 'Prueba con otro nombre, carnet o teléfono'
                        : null,
                  )
                : Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: RefreshIndicator(
                          onRefresh: _actualizar,
                          child: FadeEntrada(
                            child: ListView.builder(
                              controller: _scroll,
                              itemCount: _res.length,
                              itemBuilder: (ctx, i) {
                                final c = _res[i];
                                // Bloque 1 (A1): cada fila es una
                                // tarjeta; el tap abre la ficha.
                                // v1.3.1: ValueKey por id.
                                final fila = Card(
                                  margin: const EdgeInsets.symmetric(
                                      horizontal: 12, vertical: 4),
                                  elevation: 0,
                                  shape: RoundedRectangleBorder(
                                    borderRadius:
                                        BorderRadius.circular(
                                            AppRadio.md),
                                    side: BorderSide(
                                        color: AppColores.borde(
                                            context)),
                                  ),
                                  child: FilaCliente(
                                    cliente: c,
                                    onTap: () {
                                      final id = c['id'];
                                      final cid = id is int
                                          ? id
                                          : int.tryParse('$id');
                                      if (cid == null) return;
                                      Navigator.of(context)
                                          .push(MaterialPageRoute(
                                              builder: (_) => FichaScreen(
                                                  clienteId: cid)))
                                          .then((_) {
                                        if (mounted) _buscar();
                                      });
                                    },
                                  ),
                                );
                                // Bloque 1: deslizables configurables
                                // desde Ajustes (lista cerrada). Sin
                                // acción configurada no hay Dismissible.
                                final tieneDer =
                                    _swipeDer != 'ninguna';
                                final tieneIzq =
                                    _swipeIzq != 'ninguna';
                                if (!tieneDer && !tieneIzq) {
                                  return fila;
                                }
                                final dir = tieneDer && tieneIzq
                                    ? DismissDirection.horizontal
                                    : tieneDer
                                        ? DismissDirection
                                            .startToEnd
                                        : DismissDirection
                                            .endToStart;
                                return Dismissible(
                                  key: ValueKey(
                                      'buscar_${c['id']}'),
                                  direction: dir,
                                  background: _fondoSwipe(
                                      _swipeDer, true),
                                  secondaryBackground: _fondoSwipe(
                                      _swipeIzq, false),
                                  // La fila nunca se borra: la acción
                                  // se ejecuta y la fila se queda.
                                  confirmDismiss: (d) async {
                                    final accion = d ==
                                            DismissDirection
                                                .startToEnd
                                        ? _swipeDer
                                        : _swipeIzq;
                                    await _ejecutarSwipe(accion, c);
                                    return false;
                                  },
                                  child: fila,
                                );
                              },
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  /// Bloque 1: texto de frescura de la lista.
  String _textoActualizado() {
    final ts = _ultimoPull;
    if (ts == null) return 'Sin registro de actualización';
    final mins = ahoraHabana().difference(ts).inMinutes;
    if (mins < 1) return 'Actualizado ahora mismo';
    if (mins < 60) return 'Actualizado hace $mins min';
    final horas = mins ~/ 60;
    if (horas < 24) return 'Actualizado hace $horas h';
    final dias = horas ~/ 24;
    return 'Actualizado hace $dias día${dias == 1 ? '' : 's'}';
  }

  String _etiquetaSwipeAccion(String v) => switch (v) {
        'cobrar' => 'Cobrar mes',
        'diario' => 'Pago diario',
        'venta' => 'Venta',
        'editar' => 'Editar',
        _ => '',
      };

  Widget _fondoSwipe(String accion, bool derecha) {
    Color color;
    IconData icono;
    switch (accion) {
      case 'cobrar':
        color = AppColores.exito;
        icono = Icons.payments;
      case 'diario':
        color = AppColores.info;
        icono = Icons.today;
      case 'venta':
        color = AppColores.naranja;
        icono = Icons.shopping_bag;
      case 'editar':
        color = Colors.grey;
        icono = Icons.edit;
      default:
        color = Colors.grey;
        icono = Icons.block;
    }
    return Container(
      color: color,
      alignment:
          derecha ? Alignment.centerLeft : Alignment.centerRight,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icono, color: Colors.white, size: 22),
          const SizedBox(width: 8),
          Text(_etiquetaSwipeAccion(accion),
              style: const TextStyle(
                  color: Colors.white, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  /// Bloque 1: ejecuta la acción al deslizar. Cobrar pasa por el
  /// Preview obligatorio (nunca cobra directo); el resto navega
  /// a su pantalla (Editar abre la ficha directo en Editar).
  Future<void> _ejecutarSwipe(
      String accion, Map<String, dynamic> c) async {
    switch (accion) {
      case 'cobrar':
        if (await mostrarBloqueoCasa(context, c)) return;
        if (!mounted) return;
        final payload = await pagoDialogo(context, c);
        if (payload == null || !mounted) return;
        final deshecho = await cobrarConPreviewYRecibo(
          context: context,
          nombreCliente: '${c['nombre'] ?? ''}',
          payload: payload,
        );
        if (!mounted) return;
        if (deshecho) {
          ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Cobro deshecho')));
        }
        await _buscar();
        SyncEngine.instance.push();
        return;
      case 'diario':
        if (!mounted) return;
        await Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const PagoDiarioScreen()));
        if (mounted) await _buscar();
        return;
      case 'venta':
        if (!mounted) return;
        await Navigator.of(context).push(
            MaterialPageRoute(
                builder: (_) => const SuplementosScreen()));
        if (mounted) await _buscar();
        return;
      case 'editar':
        final id = c['id'];
        final cid = id is int ? id : int.tryParse('$id');
        if (cid == null || !mounted) return;
        await Navigator.of(context).push(MaterialPageRoute(
            builder: (_) =>
                FichaScreen(clienteId: cid, editarAlAbrir: true)));
        if (mounted) await _buscar();
        return;
      default:
        return;
    }
  }

  Widget _chipFiltro(String valor, String etiqueta,
      {Color? punto}) {
    final activo = _filtro == valor;
    return ChoiceChip(
      label: Text(etiqueta, style: const TextStyle(fontSize: 12)),
      avatar: punto == null
          ? null
          : Icon(Icons.circle, size: 10, color: punto),
      selected: activo,
      visualDensity: VisualDensity.compact,
      onSelected: (_) {
        setState(() => _filtro = valor);
        _buscar();
      },
    );
  }

  /// v1.0.15: chip de rango de edad (búsqueda avanzada).
  Widget _chipEdad(String valor, String etiqueta) {
    final activo = _rangoEdad == valor;
    return ChoiceChip(
      label: Text(etiqueta, style: const TextStyle(fontSize: 12)),
      selected: activo,
      visualDensity: VisualDensity.compact,
      onSelected: (_) {
        setState(() => _rangoEdad = valor);
        _buscar();
      },
    );
  }
}

/// Fila de cliente con mini foto (reutilizable en listas).
class FilaCliente extends StatelessWidget {
  final Map<String, dynamic> cliente;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final Widget? trailing;
  final Widget? leading;
  const FilaCliente(
      {super.key,
      required this.cliente,
      this.onTap,
      this.onLongPress,
      this.trailing,
      this.leading});

  @override
  Widget build(BuildContext context) => _FilaCliente(
      key: ValueKey(cliente['id']),
      cliente: cliente,
      onTap: onTap,
      onLongPress: onLongPress,
      trailing: trailing,
      leading: leading);
}

class _FilaCliente extends StatefulWidget {
  final Map<String, dynamic> cliente;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final Widget? trailing;
  final Widget? leading;
  const _FilaCliente(
      {super.key,
      required this.cliente,
      this.onTap,
      this.onLongPress,
      this.trailing,
      this.leading});

  @override
  State<_FilaCliente> createState() => _FilaClienteState();
}

class _FilaClienteState extends State<_FilaCliente> {
  File? _foto;
  String? _resueltoPara;

  @override
  void initState() {
    super.initState();
    _resolverFoto();
  }

  @override
  void didUpdateWidget(_FilaCliente old) {
    super.didUpdateWidget(old);
    // v1.1: re-resuelve siempre (no solo si cambió foto_storage).
    // Así, si la foto se descargó en la ficha y ahora está en caché,
    // la miniatura aparece al volver a la lista.
    _resolverFoto();
  }

  /// Lee la caché; si hay foto_storage sin caché, la descarga en
  /// segundo plano. Así la miniatura aparece aunque la fila ya se
  /// hubiera construido antes (al volver de la ficha, Flutter reutiliza
  /// el estado y el initState no se repite).
  Future<void> _resolverFoto() async {
    final sp = widget.cliente['foto_storage'] as String?;
    // Argón: limpiar siempre que cambie el cliente, antes de async.
    if (sp != _resueltoPara && _foto != null && mounted) {
      setState(() => _foto = null);
    }
    _resueltoPara = sp;
    if (sp == null || sp.isEmpty) return;
    final enCache =
        await FotoCache.instance.enCache(sp);
    if (!mounted || _resueltoPara != sp) return;
    if (enCache != null) {
      setState(() => _foto = enCache);
      return;
    }
    final descargada = await FotoCache.instance.obtener(sp);
    if (!mounted || _resueltoPara != sp) return;
    if (descargada != null) setState(() => _foto = descargada);
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.cliente;
    final ph = c['pagado_hasta'] as String?;
    final d = diasRestantes(ph);
    // Iniciales para el placeholder (ej: "Juan Pérez" -> "JP")
    final nombre = '${c['nombre']}';
    final partes = nombre.trim().split(RegExp(r'\s+'));
    String iniciales = '';
    if (partes.isNotEmpty) {
      iniciales = partes[0].isNotEmpty ? partes[0][0].toUpperCase() : '';
      if (partes.length > 1 && partes.last.isNotEmpty) {
        iniciales += partes.last[0].toUpperCase();
      }
    }
    if (iniciales.isEmpty) iniciales = '?';
    // v1.1: badge según días restantes (con icono + texto, nunca solo color)
    final dias = d ?? 999999;
    final badge = BadgeEstado.desdeDias(dias);
    final textoDias = d == null
        ? 'Sin fecha'
        : dias < 0
            ? 'Vencido hace ${dias.abs()} días'
            : dias == 0
                // v1.2.1: el badge ya dice "VENCE HOY", no repetir.
                ? 'Vence ${fmtFecha(ph)}'
                : '$dias días restantes';
    return InkWell(
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      child: Padding(
        padding: const EdgeInsets.symmetric(
            horizontal: AppEspacio.lg, vertical: AppEspacio.sm),
        child: Row(
          children: [
            // v1.1 papelera: el leading (checkbox) convive con la foto,
            // no la reemplaza.
            if (widget.leading != null) ...[
              widget.leading!,
              const SizedBox(width: AppEspacio.sm),
            ],
            // Foto
            _foto != null
                ? ClipRRect(
                    borderRadius: BorderRadius.circular(28),
                    child: Image.file(_foto!,
                        width: 56,
                        height: 56,
                        fit: BoxFit.cover),
                  )
                : CircleAvatar(
                    radius: 28,
                    backgroundColor: AppColores.naranja
                        .withValues(alpha: 0.15),
                    child: Text(iniciales,
                        style: const TextStyle(
                            color: AppColores.naranja,
                            fontWeight: FontWeight.bold,
                            fontSize: 20)),
                  ),
            const SizedBox(width: AppEspacio.md),
            // Nombre + badge + días
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(nombre,
                      style: AppTexto.subtitulo.copyWith(
                          fontSize: 16)),
                  const SizedBox(height: 4),
                  badge,
                  const SizedBox(height: 2),
                  Text(textoDias,
                      style: AppTexto.secundario.copyWith(
                          color: AppColores.textoSecundario(
                              context))),
                ],
              ),
            ),
            // Acción rápida (o chevron por defecto)
            widget.trailing ??
                Icon(Icons.chevron_right,
                    color: AppColores.textoSecundario(context)),
          ],
        ),
      ),
    );
  }
}
