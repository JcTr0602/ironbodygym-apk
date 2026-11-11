/// Utilidades puras de los envíos de datos de transferencia
/// (v1.1.1): formato de fecha, agrupado del número de tarjeta
/// y agrupación del historial por mes. La pantalla que las
/// enseñaba se retiró en la 1.32 (ver la nota al final).
library;

/// Fecha de un envío para la lista (PURO): '2026-10-30T21:14:00' →
/// '30/10 21:14'. Si el formato no es ISO, se devuelve tal cual.
String textoFechaEnvio(String iso) {
  if (iso.length < 16) return iso;
  return '${iso.substring(8, 10)}/${iso.substring(5, 7)} '
      '${iso.substring(11, 16)}';
}

/// 1.25 T77: el número de la tarjeta agrupado de 4 en 4
/// para leerlo y dictarlo sin error («9224 1299 7203
/// 5419»). Si no son 16 dígitos, se devuelve limpio.
String numeroTarjetaAgrupado(String valor) {
  final d = valor.replaceAll(RegExp(r'[^0-9]'), '');
  if (d.length != 16) return d.isEmpty ? valor : d;
  return [
    for (var i = 0; i < 16; i += 4) d.substring(i, i + 4),
  ].join(' ');
}

const _mesesEnvio = [
  'Enero', 'Febrero', 'Marzo', 'Abril', 'Mayo', 'Junio',
  'Julio', 'Agosto', 'Septiembre', 'Octubre', 'Noviembre',
  'Diciembre',
];

/// 1.25 T77: el historial de envíos agrupado por mes
/// (reciente primero), con el conteo de cada grupo.
/// La clave sale de `enviada_ts` (ISO); sin fecha válida
/// va al grupo «Sin fecha» al final.
List<({String titulo, List<Map<String, dynamic>> envios})>
    gruposEnviosPorMes(List<Map<String, dynamic>> envios) {
  final grupos = <String, List<Map<String, dynamic>>>{};
  final orden = <String>[];
  for (final e in envios) {
    final ts = '${e['enviada_ts'] ?? ''}';
    var clave = 'sin-fecha';
    if (ts.length >= 7) {
      final mes = int.tryParse(ts.substring(5, 7));
      if (mes != null && mes >= 1 && mes <= 12) {
        // Autoauditoría 1.25 ronda 2: el mes va con
        // cero ('2026-09'), si no el orden de texto
        // pone septiembre por encima de oct-dic.
        clave = '${ts.substring(0, 4)}-'
            '${mes.toString().padLeft(2, '0')}';
      }
    }
    if (!grupos.containsKey(clave)) {
      grupos[clave] = [];
      orden.add(clave);
    }
    grupos[clave]!.add(e);
  }
  orden.sort((a, b) {
    if (a == 'sin-fecha') return 1;
    if (b == 'sin-fecha') return -1;
    return b.compareTo(a);
  });
  return [
    for (final clave in orden)
      (
        titulo: clave == 'sin-fecha'
            ? 'Sin fecha'
            : '${_mesesEnvio[int.parse(clave.split('-')[1]) - 1]} '
                '${clave.split('-')[0]}',
        envios: grupos[clave]!,
      ),
  ];
}


/// 1.32 (Oleada 2, Fase 1 — desviación 3): la pantalla
/// TransferenciaScreen se retiró: cero llamadores en
/// lib/ y test/ (grep probado al retirarla). Quedan las
/// funciones puras de arriba (textoFechaEnvio,
/// numeroTarjetaAgrupado, gruposEnviosPorMes), con sus
/// tests vivos (envios_transferencia, gestion125_t70_79).
