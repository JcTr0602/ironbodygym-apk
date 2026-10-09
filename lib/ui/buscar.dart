/// Búsqueda de clientes (consulta/gestión): lista completa por defecto,
/// filtrado por nombre, carnet, teléfono y —opcional— notas.
/// El tap abre la ficha del cliente. El cobro vive en "Agregar pago".
library;

import 'dart:io';

import 'package:flutter/material.dart';

import '../fotos.dart';
import '../negocio.dart';
import '../sync.dart';
import 'componentes.dart';
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

  @override
  void initState() {
    super.initState();
    _buscar(); // lista completa por defecto
  }

  Future<void> _buscar() async {
    var r = await listaClientes(_q.text);
    final q = _q.text.trim();
    // v1.0.15: búsqueda avanzada — también en notas.
    if (_enNotas && q.isNotEmpty) {
      final nq = q.toLowerCase();
      final todos = await listaClientes('');
      final vistos = <dynamic>{for (final c in r) c['id']};
      final extra = todos.where((c) =>
          !vistos.contains(c['id']) &&
          '${c['notas'] ?? ''}'.toLowerCase().contains(nq));
      r = [...r, ...extra];
      r.sort(
          (a, b) => '${a['nombre']}'.compareTo('${b['nombre']}'));
    }
    // Filtros de estado de mensualidad.
    if (_filtro != 'todos' && _filtro != 'sinfoto') {
      r = r.where((c) {
        final dias = _diasRestantes(c);
        switch (_filtro) {
          case 'aldia':
            return dias > 7;
          case 'vencidos':
            return dias < 0;
          case 'porvencer':
            return dias >= 0 && dias <= 7;
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
    if (mounted) {
      setState(() {
        _res = r;
        _busco = true;
      });
    }
  }

  int _diasRestantes(Map<String, dynamic> c) {
    try {
      final ph = '${c['pagado_hasta'] ?? ''}';
      if (ph.length < 10) return 999;
      final v = DateTime.parse(ph.substring(0, 10));
      final hoy = DateTime.now();
      final hoyDia = DateTime(hoy.year, hoy.month, hoy.day);
      return v.difference(hoyDia).inDays;
    } catch (_) {
      return 999;
    }
  }

  /// Botón "Actualizar": baja cambios del servidor y recarga la lista.
  Future<void> _actualizar() async {
    await SyncEngine.instance.pull();
    await _buscar();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('✅ Lista actualizada')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('🔍 Buscar cliente'),
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
            child: TextField(
              controller: _q,
              decoration: const InputDecoration(
                  labelText: 'Nombre, carnet o teléfono',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.search)),
              onChanged: (_) => _buscar(),
              onSubmitted: (_) => _buscar(),
            ),
          ),
          Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 12),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text('${_res.length} cliente(s)',
                  style: const TextStyle(
                      color: Colors.grey, fontSize: 12)),
            ),
          ),
          // v1.0.15: filtros rápidos
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Row(
              children: [
                _chipFiltro('todos', 'Todos'),
                const SizedBox(width: 6),
                _chipFiltro('aldia', '🟢 Al día'),
                const SizedBox(width: 6),
                _chipFiltro('porvencer', '🟡 Por vencer'),
                const SizedBox(width: 6),
                _chipFiltro('vencidos', '🔴 Vencidos'),
                const SizedBox(width: 6),
                _chipFiltro('sinfoto', '📷 Sin foto'),
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
                        style: TextStyle(
                            fontSize: 12, color: Colors.grey)),
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
                ? Center(
                    child: Text(_busco
                        ? 'Sin resultados'
                        : 'Cargando…'))
                : RefreshIndicator(
                    onRefresh: _actualizar,
                    child: ListView.builder(
                      itemCount: _res.length,
                      itemBuilder: (ctx, i) {
                        final c = _res[i];
                        // v1.0.15: Buscar es consulta/gestión — el tap abre
                        // la ficha. Sin cobro rápido (eso vive en
                        // "Agregar pago").
                        return _FilaCliente(
                          cliente: c,
                          onTap: () => Navigator.of(context)
                              .push(MaterialPageRoute(
                                  builder: (_) => FichaScreen(
                                      clienteId:
                                          (c['id'] as int?) ?? 0)))
                              .then((_) => _buscar()),
                        );
                      },
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _chipFiltro(String valor, String etiqueta) {
    final activo = _filtro == valor;
    return ChoiceChip(
      label: Text(etiqueta, style: const TextStyle(fontSize: 12)),
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
  Widget build(BuildContext context) =>
      _FilaCliente(cliente: cliente, onTap: onTap, onLongPress: onLongPress, trailing: trailing, leading: leading);
}

class _FilaCliente extends StatefulWidget {
  final Map<String, dynamic> cliente;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final Widget? trailing;
  final Widget? leading;
  const _FilaCliente(
      {required this.cliente, this.onTap, this.onLongPress, this.trailing, this.leading});

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
    _resueltoPara = sp;
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
                ? 'Vence hoy'
                : '$dias días restantes';
    return InkWell(
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      child: Padding(
        padding: const EdgeInsets.symmetric(
            horizontal: AppEspacio.lg, vertical: AppEspacio.sm),
        child: Row(
          children: [
            // Foto
            widget.leading ??
                (_foto != null
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
                      )),
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
                const Icon(Icons.chevron_right,
                    color: Colors.grey),
          ],
        ),
      ),
    );
  }
}
