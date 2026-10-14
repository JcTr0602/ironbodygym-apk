// Ficha del suplemento (v1.2.1).
//
// Al tocar un producto del catálogo se abre su detalle: foto grande,
// descripción, precio en USD y su equivalente en CUP según la tasa del
// día, categoría y stock. Acciones: Vender, Venta rápida y Compartir.
//
// También expone los helpers reutilizables [ventaRapidaSuplemento] y
// [compartirSuplemento] para usarlos desde la lista.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:uuid/uuid.dart';

import '../app_log.dart';
import '../auth.dart';
import '../fotos.dart';
import '../localdb.dart';
import '../negocio.dart';
import '../sync.dart';
import 'componentes.dart';
import 'diseno.dart';
import 'venta_suplemento.dart';
import 'widgets.dart';

/// Venta rápida: 1 unidad al precio oficial (USD), comprador externo.
/// Devuelve true si se registró la venta.
/// ChatGPT CRÍTICO 2: el servidor solo acepta comprador_tipo 'cliente'|'externo'
/// y exige usd_tasa>0 para moneda USD. Se envía 'externo' + tasa del día.
Future<bool> ventaRapidaSuplemento(
    BuildContext context, Map<String, dynamic> s,
    [double? tasaUsd]) async {
  final stock = (s['stock'] as num?)?.toInt() ?? 0;
  if (stock <= 0) {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Sin stock disponible para venta rápida')));
    return false;
  }
  if (tasaUsd == null || tasaUsd <= 0) {
    // v1.2.4: el servidor rechaza ventas USD sin tasa.
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Falta la tasa del día (Admin → Ajustes) '
            'para registrar la venta')));
    return false;
  }
  final precio =
      (s['precio_oficial'] as num?)?.toDouble() ?? 0;
  final ok = await DialogoApp.confirmar(
    context,
    titulo: 'Venta rápida',
    icono: Icons.flash_on,
    mensaje: '${s['nombre']}\n'
        '1 x ${precio.toStringAsFixed(2)} USD'
        ' = ${textoTotalVenta(precio, 'USD', tasaUsd)}\n'
        'Comprador: Cliente externo',
    aceptar: 'Confirmar',
  );
  if (!ok) return false;
  await LocalDb.instance.queueOp(
    opUuid: const Uuid().v4(),
    tipo: 'venta_suplemento',
    payload: {
      'suplemento_id': s['id'],
      'cantidad': 1,
      'precio': precio,
      'moneda': 'USD',
      // ChatGPT CRÍTICO 2: usd_tasa obligatoria para USD, tipo 'externo'.
      'usd_tasa': tasaUsd,
      'comprador_tipo': 'externo',
      'comprador_nombre': 'Cliente externo',
      'fecha':
          DateTime.now().toIso8601String().substring(0, 10),
      'nota': 'venta rápida',
    },
  );
  // Gemini: reducción optimista de stock local (tabla espejo usa JSON en data).
  final db = await LocalDb.instance.db;
  final sid = s['id'] as int?;
  if (sid != null) {
    final rows = await db.query('suplementos',
        columns: ['data'], where: 'id = ?', whereArgs: [sid]);
    if (rows.isNotEmpty) {
      final data =
          jsonDecode(rows.first['data'] as String) as Map<String, dynamic>;
      final stockActual = (data['stock'] as num?)?.toInt() ?? 0;
      data['stock'] = (stockActual - 1).clamp(0, 999999);
      await db.update('suplementos', {'data': jsonEncode(data)},
          where: 'id = ?', whereArgs: [sid]);
    }
  }
  unawaited(SyncEngine.instance.push());
  return true;
}

/// Comparte la info del suplemento (foto + precio) por WhatsApp
/// u otra app mediante la hoja de compartir del sistema.
Future<void> compartirSuplemento(BuildContext context,
    Map<String, dynamic> s, double? tasaUsd) async {
  final nombre = '${s['nombre'] ?? 'Suplemento'}';
  final precio =
      (s['precio_oficial'] as num?)?.toDouble() ?? 0;
  final cup = tasaUsd != null && tasaUsd > 0
      ? ' (≈ ${fmtMonto(precio * tasaUsd)} CUP)'
      : '';
  final stock = (s['stock'] as num?)?.toInt() ?? 0;
  final texto = 'Iron Body Gym — Suplementos\n\n'
      '$nombre\n'
      'Precio: ${precio.toStringAsFixed(2)} USD$cup\n'
      'Disponibles: $stock';
  try {
    final foto = s['foto_storage'] as String?;
    final archivo = await FotoCache.instance.obtener(foto);
    if (archivo != null) {
      await Share.shareXFiles([XFile(archivo.path)],
          text: texto);
    } else {
      await Share.share(texto);
    }
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('No se pudo compartir')));
    }
  }
}

class DetalleSuplementoScreen extends StatelessWidget {
  final Map<String, dynamic> suplemento;
  final String categoriaNombre;
  final double? tasaUsd;

  const DetalleSuplementoScreen({
    super.key,
    required this.suplemento,
    required this.categoriaNombre,
    this.tasaUsd,
  });

  Future<void> _vender(BuildContext context) async {
    final vendido = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) =>
            VentaSuplementoScreen(suplemento: suplemento),
      ),
    );
    if (vendido == true && context.mounted) {
      Navigator.pop(context, true);
    }
  }

  Future<void> _ventaRapida(BuildContext context) async {
    // Gemini-2: confirmación previa (riesgo de toques accidentales).
    final confirmar = await DialogoApp.confirmar(
      context,
      titulo: 'Venta rápida',
      mensaje: '¿Registrar venta de 1 unidad de ${suplemento['nombre']} '
          'a precio oficial?',
      aceptar: 'Vender',
      icono: Icons.flash_on,
    );
    if (!confirmar || !context.mounted) return;
    final ok =
        await ventaRapidaSuplemento(context, suplemento, tasaUsd);
    if (!context.mounted) return;
    if (ok) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content:
                  Text('Venta registrada (se sincronizará)')));
      Navigator.pop(context, true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final nombre = '${suplemento['nombre'] ?? 'Sin nombre'}';
    final descripcion =
        '${suplemento['descripcion'] ?? ''}'.trim();
    final precio =
        (suplemento['precio_oficial'] as num?)?.toDouble() ?? 0;
    final stock =
        (suplemento['stock'] as num?)?.toInt() ?? 0;
    final inactivo = (suplemento['activo'] as int?) != 1;
    final foto = suplemento['foto_storage'] as String?;
    final cup = tasaUsd != null && tasaUsd! > 0
        ? '≈ ${fmtMonto(precio * tasaUsd!)} CUP'
        : null;

    return Scaffold(
      appBar: AppBar(
        title: Text(nombre,
            overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            icon: const Icon(Icons.share_outlined),
            tooltip: 'Compartir por WhatsApp',
            onPressed: () =>
                compartirSuplemento(context, suplemento, tasaUsd),
          ),
          if (AuthService().isOwner)
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: 'Eliminar suplemento',
              onPressed: () =>
                  _eliminarSuplemento(context, suplemento),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(AppEspacio.lg),
        children: [
          const SyncBanner(compact: true),
          const SizedBox(height: AppEspacio.md),
          // Foto grande.
          FutureBuilder(
            future: FotoCache.instance.obtener(foto),
            builder: (ctx, snap) {
              final f = snap.data;
              if (f == null) {
                return Container(
                  height: 200,
                  decoration: BoxDecoration(
                    color: AppColores.fondo(context),
                    borderRadius:
                        BorderRadius.circular(AppRadio.lg),
                  ),
                  child: const Icon(
                      Icons.medication_outlined,
                      size: 72,
                      color: AppColores.naranja),
                );
              }
              return ClipRRect(
                borderRadius:
                    BorderRadius.circular(AppRadio.lg),
                child: Image.file(f,
                    height: 220,
                    width: double.infinity,
                    fit: BoxFit.cover),
              );
            },
          ),
          const SizedBox(height: AppEspacio.md),
          Row(
            children: [
              Expanded(
                child: Text(nombre,
                    style: AppTexto.titulo),
              ),
              if (inactivo)
                const ChipEstado(
                    texto: 'Inactivo',
                    color: Colors.grey),
            ],
          ),
          const SizedBox(height: AppEspacio.xs),
          ChipEstado(
              texto: categoriaNombre,
              color: AppColores.naranja),
          if (descripcion.isNotEmpty) ...[
            const SizedBox(height: AppEspacio.md),
            Text(descripcion, style: AppTexto.cuerpo),
          ],
          const SizedBox(height: AppEspacio.md),
          // Precio USD + equivalente CUP + stock.
          Tarjeta(
            child: Row(
              children: [
                const Icon(Icons.payments_outlined,
                    color: AppColores.naranja, size: 32),
                const SizedBox(width: AppEspacio.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment:
                        CrossAxisAlignment.start,
                    children: [
                      Text(
                          '${precio.toStringAsFixed(2)} USD',
                          style: AppTexto.displayPequeno),
                      if (cup != null)
                        Text(cup,
                            style: AppTexto.cuerpo.copyWith(
                                color: AppColores.naranja,
                                fontWeight:
                                    FontWeight.bold)),
                      Text('$stock disponibles',
                          style: AppTexto.secundario),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppEspacio.lg),
          BotonPrimario(
            texto: 'Vender',
            onPressed:
                stock > 0 ? () => _vender(context) : null,
          ),
          const SizedBox(height: AppEspacio.sm),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              icon: const Icon(Icons.flash_on,
                  color: AppColores.naranja),
              label: const Text('Venta rápida (1 unidad)'),
              onPressed: stock > 0
                  ? () => _ventaRapida(context)
                  : null,
            ),
          ),
        ],
      ),
    );
  }
}

/// Elimina un suplemento (v1.3.1).
/// Pide confirmación, lo marca como eliminado localmente y encola la op.
Future<void> _eliminarSuplemento(
    BuildContext context, Map<String, dynamic> s) async {
  final nombre = '${s['nombre'] ?? 'suplemento'}';
  final ok = await DialogoApp.confirmar(
    context,
    titulo: 'Eliminar suplemento',
    mensaje: '¿Eliminar "$nombre" del catálogo? Esta acción no se puede deshacer.',
    aceptar: 'Eliminar',
  );
  if (ok != true || !context.mounted) return;

  final db = LocalDb.instance;
  final id = s['id'];
  // Marcar como eliminado localmente.
  final d = await db.db;
  await d.delete('suplementos', where: 'id = ?', whereArgs: [id]);

  await db.queueOp(
    opUuid: const Uuid().v4(),
    tipo: 'eliminar_suplemento',
    payload: {'suplemento_id': id},
  );
  AppLog.info('suplementos', 'eliminar', d: 'id=$id nombre=$nombre');

  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Suplemento eliminado')));
  Navigator.of(context).pop();
  SyncEngine.instance.push();
}
