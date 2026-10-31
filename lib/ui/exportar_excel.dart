/// 📊 Exportar Excel (CSV) desde la APK.
/// Genera CSV y los comparte con share_plus: clientes, pagos del
/// mes, ventas del mes, catálogo de suplementos y nómina del mes.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../adelantos.dart';
import '../auth.dart';
import '../cliente_protegido.dart';
import '../localdb.dart';
import '../nomina_bonos.dart';
import '../nomina_calc.dart';
import '../perfil.dart';
import '../tiempo.dart';

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

/// Venta anulada (misma regla que el Extracto): no viaja en la hoja
/// de ventas. PURO. A prueba de tipos: el espejo puede traer 1, 1.0
/// o true según el origen.
bool esVentaAnulada(Map<String, dynamic> v) {
  bool marca(dynamic x) => x == 1 || x == true;
  return marca(v['anulada']) ||
      marca(v['anulado']) ||
      '${v['estado'] ?? ''}' == 'anulada';
}

/// Filas de la hoja de ventas del mes (PURO): solo el mes [pref],
/// sin anuladas y sin compradores protegidos (misma privacidad que
/// la hoja de pagos). Columnas: fecha, producto, cantidad, monto,
/// moneda, comprador, vendedor.
List<List<String>> filasVentasMes(
  List<Map<String, dynamic>> ventas,
  Map<int, String> nombreProducto,
  String pref,
  Set<int> protegidos,
) {
  final out = <List<String>>[];
  for (final v in ventas) {
    if (!'${v['fecha'] ?? ''}'.startsWith(pref)) continue;
    if (esVentaAnulada(v)) continue;
    final cid = (v['cliente_id'] as num?)?.toInt() ??
        (v['fiado_cliente_id'] as num?)?.toInt();
    if (cid != null && protegidos.contains(cid)) continue;
    final prodId = (v['suplemento_id'] as num?)?.toInt();
    out.add([
      '${v['fecha'] ?? ''}',
      prodId != null
          ? (nombreProducto[prodId] ?? 'Producto $prodId')
          : 'Producto',
      '${(v['cantidad'] as num?)?.toInt() ?? 0}',
      '${v['total'] ?? v['precio'] ?? ''}',
      '${v['moneda'] ?? 'CUP'}',
      '${v['comprador_nombre'] ?? ''}',
      '${v['registrado_por_nombre'] ?? v['registrado_por'] ?? ''}',
    ]);
  }
  return out;
}

/// Filas del catálogo de suplementos (PURO): nombre, categoría,
/// precio oficial, stock.
List<List<String>> filasSuplementos(
  List<Map<String, dynamic>> suplementos,
  Map<int, String> nombreCategoria,
) {
  return [
    for (final s in suplementos)
      [
        '${s['nombre'] ?? ''}',
        nombreCategoria[(s['categoria_id'] as num?)?.toInt()] ?? '',
        '${s['precio_oficial'] ?? s['precio'] ?? ''}',
        '${(s['stock'] as num?)?.toInt() ?? 0}',
      ]
  ];
}

/// Fila de nómina del mes para un entrenador (PURO) a partir de su
/// MesLibroAdelantos del mes: entrenador, clientes base, bruto,
/// comisiones, bonos, devengado, adelantos, deuda entrante, neto,
/// a pagar, liquidada. La base se deriva de bruto/tarifa (el bruto
/// es conteo × tarifa en la composición de la pantalla de Nómina).
List<String> filaNominaMes(
  String nombre,
  MesLibroAdelantos libro,
  double tarifa, {
  bool liquidada = false,
}) {
  final base = tarifa > 0 ? (libro.bruto / tarifa).round() : 0;
  String num(double v) =>
      v == v.roundToDouble() ? '${v.toInt()}' : v.toStringAsFixed(2);
  return [
    nombre,
    '$base',
    num(libro.bruto),
    num(libro.comisiones),
    num(libro.bonos),
    num(libro.devengado),
    num(libro.adelantos),
    num(libro.deudaEntrante),
    num(libro.neto),
    num(libro.aPagar),
    liquidada ? 'sí' : 'no',
  ];
}

/// Genera y comparte los CSV del mes (clientes, pagos, ventas,
/// suplementos y nómina; la nómina se omite si su cálculo falla).
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
    final n = ahoraHabana();
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

    // --- Ventas del mes: fecha, producto, cantidad, monto, moneda,
    // comprador, vendedor (sin anuladas ni compradores protegidos) ---
    final ventas =
        await LocalDb.instance.allMirror('ventas_suplementos');
    final suplementos = await LocalDb.instance.allMirror('suplementos');
    final nombreProd = <int, String>{
      for (final s in suplementos)
        if ((s['id'] as num?) != null)
          (s['id'] as num).toInt(): '${s['nombre'] ?? ''}',
    };
    final csvVentas = _csv(
      ['fecha', 'producto', 'cantidad', 'monto', 'moneda', 'comprador',
        'vendedor'],
      filasVentasMes(ventas, nombreProd, pref, protegidos),
    );
    final f3 = File(
        '${dir.path}/ventas_${n.year}-${n.month.toString().padLeft(2, '0')}_ironbody.csv');

    // --- Catálogo de suplementos: nombre, categoría, precio, stock ---
    final categorias =
        await LocalDb.instance.allMirror('categorias_suplemento');
    final nombreCat = <int, String>{
      for (final c in categorias)
        if ((c['id'] as num?) != null)
          (c['id'] as num).toInt(): '${c['nombre'] ?? ''}',
    };
    final csvSuplementos = _csv(
      ['nombre', 'categoria', 'precio_oficial', 'stock'],
      filasSuplementos(suplementos, nombreCat),
    );
    final f4 = File('${dir.path}/suplementos_ironbody.csv');

    // --- Nómina del mes: MISMA composición que la pantalla de
    // Nómina (mismos servicios y funciones, mes a mes desde el
    // primer mes con datos para que la deuda arrastrada cuadre).
    // Si algo falla aquí, las demás hojas se comparten igual: la
    // nómina se omite en vez de tumbar todo el export.
    File? f5;
    try {
      final tarifa =
          await PerfilService.instance.getPagoEntrenador();
      final ventasServ =
          await LocalDb.instance.allMirror('servicio_ventas');
      final rawApk = await LocalDb.instance.getMeta('usuarios_apk');
      final usuariosApk = <Map<String, dynamic>>[];
      if (rawApk != null && rawApk.isNotEmpty) {
        for (final u in jsonDecode(rawApk) as List) {
          usuariosApk.add(Map<String, dynamic>.from(u as Map));
        }
      }
      final personas =
          <String, ({String id, int? telegramId, String nombre})>{};
      for (final u in usuariosApk) {
        final clave =
            NominaCalc.claveEntrenador('${u['username'] ?? ''}');
        if (clave != null) {
          personas[clave] = (
            id: '${u['id'] ?? ''}',
            telegramId: (u['telegram_id'] as num?)?.toInt() ??
                int.tryParse('${u['telegram_id'] ?? ''}'),
            nombre: (u['nombre'] as String?) ?? clave,
          );
        }
      }
      // Comisiones por dosis del mes por clave (igual que la
      // pantalla): respaldo para el entrenador sin telegram_id.
      final comisionDosis = <String, ({int dosis, double total})>{};
      final nombrePorTid =
          NominaCalc.tidsConComisionServicio(ventasServ, usuariosApk);
      for (final tid in nombrePorTid.keys) {
        final r = NominaCalc.comisionDosisDesdeVentas(
            ventasServ, tid, pref);
        if (r.total == 0 && r.dosis == 0) continue;
        final clave = NominaCalc.claveEntrenador(nombrePorTid[tid]);
        if (clave != null) comisionDosis[clave] = r;
      }
      final conteoCache = <String, int>{};
      final filasNomina = <List<String>>[];
      for (final e in personas.entries) {
        if (e.value.id.isEmpty) continue;
        final eventos = await AdelantosService.instance
            .eventosDe(e.value.id, telegramId: e.value.telegramId);
        var primero = pref;
        for (final ev in eventos) {
          final mm = '${ev['mes_nomina'] ?? ''}';
          if (mm.length == 7 && mm.compareTo(primero) < 0) {
            primero = mm;
          }
        }
        final brutoPorMes = <String, double>{};
        var mes = primero;
        while (mes.compareTo(pref) <= 0) {
          conteoCache[mes] ??=
              await NominaCalc.clientesQuePagaronElMes(mes);
          brutoPorMes[mes] = conteoCache[mes]! * tarifa.toDouble();
          mes = mesSiguiente(mes);
        }
        final libro = libroAdelantos(
          eventos: eventos,
          brutoPorMes: brutoPorMes,
          comisionesPorMes: e.value.telegramId == null
              ? {pref: comisionDosis[e.key]?.total ?? 0}
              : NominaCalc.comisionesPorMesDesdeVentas(
                  ventasServ, e.value.telegramId!, primero, pref),
          bonosPorMes: await BonosNominaService.instance
              .bonosPorMes(e.key, primero, pref),
          hastaMes: pref,
        );
        final liquidada = await AdelantosService.instance
            .nominaLiquidada(pref, e.value.id);
        for (final m in libro) {
          if (m.mes == pref) {
            filasNomina.add(filaNominaMes(
              e.value.nombre,
              m,
              tarifa.toDouble(),
              liquidada: liquidada,
            ));
          }
        }
      }
      final csvNomina = _csv(
        ['entrenador', 'clientes_base', 'bruto', 'comisiones',
          'bonos', 'devengado', 'adelantos', 'deuda_entrante',
          'neto', 'a_pagar', 'liquidada'],
        filasNomina,
      );
      f5 = File(
          '${dir.path}/nomina_${n.year}-${n.month.toString().padLeft(2, '0')}_ironbody.csv');
      await f5.writeAsString(csvNomina);
    } catch (_) {
      f5 = null;
    }

    await f1.writeAsString(csvClientes);
    await f2.writeAsString(csvPagos);
    await f3.writeAsString(csvVentas);
    await f4.writeAsString(csvSuplementos);
    final archivos = [
      XFile(f1.path),
      XFile(f2.path),
      XFile(f3.path),
      XFile(f4.path),
      if (f5 != null) XFile(f5.path),
    ];
    await Share.shareXFiles(archivos,
        text: 'Iron Body Gym — clientes, pagos, ventas, suplementos'
            ' y nómina del mes');
    return true;
  } catch (_) {
    return false;
  }
}
