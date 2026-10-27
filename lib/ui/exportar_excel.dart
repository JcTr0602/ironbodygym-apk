/// 📊 Exportar Excel (CSV) desde la APK.
/// Genera dos CSV: clientes y pagos del mes, y los comparte con share_plus.
library;

import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../auth.dart';
import '../cliente_protegido.dart';
import '../localdb.dart';

String _csv(List<String> cabecera, List<List<String>> filas) {
  String esc(String s) {
    if (s.contains(',') || s.contains('"') || s.contains('\n')) {
      return '"${s.replaceAll('"', '""')}"';
    }
    return s;
  }

  final sb = StringBuffer();
  sb.writeln(cabecera.map(esc).join(','));
  for (final f in filas) {
    sb.writeln(f.map(esc).join(','));
  }
  return sb.toString();
}

/// Genera y comparte los CSV de clientes y pagos del mes.
/// Devuelve true si se compartió, false si hubo error.
Future<bool> exportarExcel() async {
  try {
    // Cliente protegido (2026-10-26, Protegido 2 H8): exportar es
    // solo del dueño, y ningún protegido viaja en los CSV.
    if (!AuthService().isOwner) return false;
    // --- Clientes: nombre, carnet, teléfono, estado, pagado_hasta ---
    final clientes = await LocalDb.instance.allMirror('clientes');
    final protegidos = <int>{};
    for (final c in clientes) {
      final id = (c['id'] as num?)?.toInt();
      if (id != null && esVistaProtegida(c)) protegidos.add(id);
    }
    final csvClientes = _csv(
      ['nombre', 'carnet', 'telefono', 'estado', 'pagado_hasta'],
      [
        // v1.8.0: la cáscara de una baja conservando estadísticas
        // no es una persona exportable (sin datos y fuera de toda
        // lista); sus pagos sí viajan en la hoja de pagos.
        for (final c in clientes)
          if (!LocalDb.esEliminadoDe(c) && !esVistaProtegida(c))
          [
            '${c['nombre'] ?? ''}',
            '${c['carnet'] ?? ''}',
            '${c['telefono'] ?? c['movil'] ?? ''}',
            '${c['estado'] ?? ''}',
            '${c['pagado_hasta'] ?? ''}',
          ]
      ],
    );

    // --- Pagos del mes: fecha, cliente, monto, método ---
    final n = DateTime.now();
    final pref = '${n.year.toString().padLeft(4, '0')}-'
        '${n.month.toString().padLeft(2, '0')}';
    // v1.3.4 (ítem 2): columna `fecha` indexada en vez de allMirror.
    final pagos = await LocalDb.instance.pagosDelMes(pref);
    final nombreCliente = <int, String>{
      for (final c in clientes)
        if (c['id'] is int) c['id'] as int: '${c['nombre'] ?? ''}'
    };
    final pagosMes =
        pagos.where((p) => '${p['fecha'] ?? ''}'.startsWith(pref)).toList();
    final csvPagos = _csv(
      ['fecha', 'cliente', 'monto', 'metodo'],
      [
        for (final p in pagosMes)
          if (!protegidos.contains((p['cliente_id'] as num?)?.toInt()))
          [
            '${p['fecha'] ?? ''}',
            nombreCliente[p['cliente_id'] as int?] ?? '',
            '${p['monto'] ?? ''}',
            '${p['metodo'] ?? ''}',
          ]
      ],
    );

    final dir = await getTemporaryDirectory();
    final f1 = File('${dir.path}/clientes_ironbody.csv');
    final f2 = File(
        '${dir.path}/pagos_${n.year}-${n.month.toString().padLeft(2, '0')}_ironbody.csv');
    await f1.writeAsString(csvClientes);
    await f2.writeAsString(csvPagos);
    await Share.shareXFiles([XFile(f1.path), XFile(f2.path)],
        text: 'Iron Body Gym — clientes y pagos del mes');
    return true;
  } catch (_) {
    return false;
  }
}
