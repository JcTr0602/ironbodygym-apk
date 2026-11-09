/// Datos de transferencia: muestra las tarjetas y permite enviar los datos
/// por SMS o WhatsApp al móvil de un cliente (v1.1.1).
library;

import 'package:flutter/material.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config.dart';
import '../localdb.dart';
import '../negocio.dart';
import '../tipos_pago.dart';
import 'app_bar.dart';
import 'componentes.dart';
import 'diseno.dart';
import 'widgets.dart';

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

class TransferenciaScreen extends StatefulWidget {
  const TransferenciaScreen({super.key});
  @override
  State<TransferenciaScreen> createState() => _TransferenciaScreenState();
}

class _TransferenciaScreenState extends State<TransferenciaScreen> {
  double _efectivo = 2000;
  double _transfer = 2500;
  // v1.0.16: datos bancarios desde ajustes remotos (fallback a constantes)
  String _bandec = AppConfig.tarjetaBandec;
  String _bpa = AppConfig.tarjetaBpa;
  String _movil = AppConfig.movilConfirmacion;

  // v1.1.1: un campo de móvil por tarjeta para el envío
  final _movilBandec = TextEditingController();
  final _movilBpa = TextEditingController();
  final _movilConfirmar = TextEditingController();
  // 5/25: registro local de envíos (a quién, qué tarjeta, cuándo).
  List<Map<String, dynamic>> _envios = [];

  @override
  void initState() {
    super.initState();
    LocalDb.instance.getAjustes().then((aj) {
      if (mounted) {
        final banc = AppConfig.datosBancarios(aj);
        setState(() {
          // Yunque B (YB-DIN-02): lector tolerante — con el
          // cast duro, un importe como texto impedía cargar
          // hasta los datos bancarios de esta pantalla.
          _efectivo = montoAjusteTolerante(aj['mensualidad']) ?? 2000;
          _transfer = montoAjusteTolerante(aj['transferencia']) ?? 2500;
          _bandec = banc['bandec']!;
          _bpa = banc['bpa']!;
          _movil = banc['movil']!;
        });
      }
    });
    _cargarEnvios();
  }

  Future<void> _cargarEnvios() async {
    final envios = await LocalDb.instance.listarEnviosTransferencia();
    if (mounted) setState(() => _envios = envios);
  }

  @override
  void dispose() {
    _movilBandec.dispose();
    _movilBpa.dispose();
    _movilConfirmar.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: appBarIron(context, 'Datos de transferencia'),
      body: Column(
        children: [
          const SyncBanner(compact: true),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(AppEspacio.lg),
              children: [
                const Text(
                    'Puedes pagar tu mensualidad con Transfermóvil o Enzona '
                    'a cualquiera de estas tarjetas:'),
                const SizedBox(height: 16),
                _tarjeta(context, 'Bandec', _bandec, _movilBandec),
                _tarjeta(context, 'BPA', _bpa, _movilBpa),
                _tarjeta(context, 'Móvil para confirmar', _movil,
                    _movilConfirmar),
                const Divider(),
                Text(
                    'Mensualidad por transferencia: ${fmtMonto(_transfer)} CUP',
                    style:
                        const TextStyle(fontWeight: FontWeight.bold)),
                Text('(En efectivo: ${fmtMonto(_efectivo)} CUP)'),
                const SizedBox(height: 12),
                const Text(
                  'IMPORTANTE: tienes que habilitar la opción para que '
                  'se vea el móvil del cual hiciste la transferencia. Así '
                  'verificamos tu pago y activamos tu mensualidad.',
                ),
                const SizedBox(height: 12),
                const Text(' Telegram: ${AppConfig.telegramContacto}'),
                // v1.2.4: el número sale del móvil de confirmación (ajustes).
                if (_movil.isNotEmpty) Text('WhatsApp: $_movil'),
                const Divider(),
                const Text('Envíos registrados',
                    style:
                        TextStyle(fontWeight: FontWeight.bold)),
                const Text(
                  'Se registra cuando se abre SMS o WhatsApp con el '
                  'mensaje para ese móvil.',
                  style: AppTexto.secundario,
                ),
                const SizedBox(height: 8),
                if (_envios.isEmpty)
                  const Text(
                    'Todavía no se ha enviado ninguna tarjeta desde '
                    'este teléfono.',
                    style: AppTexto.secundario,
                  )
                else
                  // 1.25 T77: agrupado por mes, con el
                  // total de envíos de cada mes.
                  for (final grupo in gruposEnviosPorMes(_envios)) ...[
                    Padding(
                      padding: const EdgeInsets.only(
                          top: AppEspacio.sm, bottom: AppEspacio.xs),
                      child: Row(
                        mainAxisAlignment:
                            MainAxisAlignment.spaceBetween,
                        children: [
                          Text(grupo.titulo,
                              style: AppTexto.subtitulo),
                          Text(
                            '${grupo.envios.length} envío${grupo.envios.length == 1 ? '' : 's'}',
                            style: AppTexto.secundario,
                          ),
                        ],
                      ),
                    ),
                    for (final e in grupo.envios)
                      Padding(
                        padding:
                            const EdgeInsets.only(bottom: AppEspacio.xs),
                        child: Text(
                          '${e['tarjeta']} → ${e['movil']} · ${e['canal']} '
                          '· ${textoFechaEnvio('${e['enviada_ts'] ?? ''}')}',
                          style: AppTexto.cuerpo,
                        ),
                      ),
                  ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Tarjeta con número copiable + envío por SMS/WhatsApp a un cliente.
  /// 1.25 T77: las cuentas (Bandec/BPA) se presentan como
  /// una TARJETA BANCARIA: degradado grafito, el número
  /// grande en mono agrupado de 4 en 4 y el botón
  /// «Copiar datos» a la vista — es la pantalla que el
  /// staff enseña para dar los datos de pago y el número
  /// debe ser lo más claro de la app. El móvil de
  /// confirmación no es una cuenta: conserva su fila.
  Widget _tarjeta(BuildContext context, String etiqueta, String valor,
      TextEditingController movilCtrl) {
    final esCuenta = etiqueta == 'Bandec' || etiqueta == 'BPA';
    return Padding(
      padding: const EdgeInsets.only(bottom: AppEspacio.md),
      child: Tarjeta(
        padding: const EdgeInsets.all(AppEspacio.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (esCuenta)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(AppEspacio.lg),
                decoration: BoxDecoration(
                  gradient: AppColores.gradienteCarbon,
                  borderRadius:
                      BorderRadius.circular(AppRadio.lg),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(etiqueta.toUpperCase(),
                            style: AppTexto.etiqueta.copyWith(
                                color: AppColores.naranja,
                                letterSpacing: 2)),
                        const Spacer(),
                        const Icon(Icons.nfc_rounded,
                            color: Colors.white38, size: 22),
                      ],
                    ),
                    const SizedBox(height: AppEspacio.lg),
                    Text(
                      numeroTarjetaAgrupado(valor),
                      style: const TextStyle(
                        color: Colors.white,
                        fontFamily: 'monospace',
                        fontSize: 21,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 1.2,
                      ),
                    ),
                    const SizedBox(height: AppEspacio.md),
                    Row(
                      children: [
                        Text('IRON BODY GYM',
                            style: AppTexto.minuscula.copyWith(
                                color: Colors.white54,
                                letterSpacing: 1.5)),
                        const Spacer(),
                        OutlinedButton.icon(
                          icon: const Icon(Icons.copy_rounded,
                              size: 16),
                          label: const Text('Copiar datos'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.white,
                            side: const BorderSide(
                                color: Colors.white38),
                          ),
                          onPressed: () => copiar(context,
                              valor.replaceAll(' ', '')),
                        ),
                      ],
                    ),
                  ],
                ),
              )
            else
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment:
                          CrossAxisAlignment.start,
                      children: [
                        Text(etiqueta,
                            style: const TextStyle(
                                fontWeight: FontWeight.bold)),
                        const SizedBox(height: 2),
                        Text(valor,
                            style: AppTexto.titulo.copyWith(
                                fontFamily: 'monospace',
                                fontWeight: FontWeight.normal)),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.copy_rounded),
                    tooltip: 'Copiar',
                    onPressed: () =>
                        copiar(context, valor.replaceAll(' ', '')),
                  ),
                ],
              ),
            const Divider(height: 20),
            Text('Enviar a un cliente:',
                style: AppTexto.secundario.copyWith(color: AppColores.textoSecundario(context))),
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: CampoTexto(
                    controller: movilCtrl,
                    hint: 'Móvil del cliente',
                    icono: Icons.phone_rounded,
                    teclado: TextInputType.phone,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.contacts_rounded),
                  tooltip: 'Elegir de contactos',
                  onPressed: () =>
                      _elegirContacto(context, movilCtrl),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: BotonSecundario(
                    texto: 'SMS',
                    icono: Icons.sms_rounded,
                    onPressed: () => _enviar(
                        context, etiqueta, valor,
                        movilCtrl.text, porWhatsapp: false),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: BotonSecundario(
                    texto: 'WhatsApp',
                    icono: Icons.chat_rounded,
                    onPressed: () => _enviar(
                        context, etiqueta, valor,
                        movilCtrl.text, porWhatsapp: true),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Elige un móvil cubano de los contactos del teléfono.
  Future<void> _elegirContacto(
      BuildContext ctx, TextEditingController ctrl) async {
    if (!await FlutterContacts.requestPermission(
        readonly: true)) {
      if (ctx.mounted) {
        mostrarSnack(ctx, 'Sin permiso de contactos no se puede elegir', significado: SignificadoChip.alerta);
      }
      return;
    }
    final contacto = await FlutterContacts.openExternalPick();
    if (contacto == null) return;
    for (final tel in contacto.phones) {
      var d = tel.number.replaceAll(RegExp(r'\D'), '');
      if (d.startsWith('53') && d.length > 8) {
        d = d.substring(2);
      }
      if (d.length == 8 && validarTelefono(d)) {
        ctrl.text = d;
        return;
      }
    }
    if (ctx.mounted) {
      mostrarSnack(ctx, 'El contacto "${contacto.displayName}" no tiene un móvil cubano válido', significado: SignificadoChip.alerta);
    }
  }

  /// Abre SMS o WhatsApp con el mensaje de la tarjeta ya escrito.
  Future<void> _enviar(BuildContext ctx, String etiqueta,
      String valor, String movilRaw,
      {required bool porWhatsapp}) async {
    var movil = movilRaw.replaceAll(RegExp(r'\D'), '');
    if (movil.startsWith('53') && movil.length > 8) {
      movil = movil.substring(2);
    }
    if (!validarTelefono(movil)) {
      mostrarSnack(ctx, 'Escribe un móvil cubano válido (8 dígitos)', significado: SignificadoChip.alerta);
      return;
    }
    final mensaje = 'Iron Body Gym: paga tu mensualidad '
        '(${fmtMonto(_transfer)} CUP) por Transfermóvil/Enzona a la '
        'tarjeta $etiqueta $valor. IMPORTANTE: activa la opción para '
        'que se vea tu número y así verificamos el pago. '
        '${_movil.isNotEmpty ? 'Dudas: WhatsApp $_movil' : ''}';
    final uri = porWhatsapp
        ? Uri.parse(
            'https://wa.me/53$movil?text=${Uri.encodeComponent(mensaje)}')
        : Uri.parse(
            'sms:$movil?body=${Uri.encodeComponent(mensaje)}');
    final ok = await launchUrl(uri,
        mode: LaunchMode.externalApplication);
    if (!ok) {
      if (ctx.mounted) {
        mostrarSnack(ctx, 'No se pudo abrir ${porWhatsapp ? 'WhatsApp' : 'SMS'}', significado: SignificadoChip.error);
      }
      return;
    }
    // 5/25: constancia del envío (tarjeta, móvil, canal, hora). Solo
    // cuando la app externa abrió: si no abrió, nada se envió.
    await LocalDb.instance.registrarEnvioTransferencia(
      tarjeta: etiqueta,
      movil: movil,
      canal: porWhatsapp ? 'WhatsApp' : 'SMS',
    );
    _cargarEnvios();
  }
}
