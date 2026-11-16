/// Ayuda para entrenadores.
///
/// Secciones plegables por tema + "Lo Nuevo" con la versión actual destacada.
/// Contenido revisado a fondo en la v1.4.2 (rescate de Ayuda): las
/// guías viejas mandaban a botones que ya no existen y daban cifras
/// de un motor de sync anterior. Regla: nada de frecuencias ni
/// absolutos sin verificar en el código vigente.
library;

import 'package:flutter/material.dart';

import '../config.dart';
import '../novedades.dart';
import 'app_bar.dart';
import 'componentes.dart';
import 'diseno.dart';

class AyudaScreen extends StatefulWidget {
  const AyudaScreen({super.key});

  @override
  State<AyudaScreen> createState() => _AyudaScreenState();
}

class _AyudaScreenState extends State<AyudaScreen> {
  final _buscador = TextEditingController();
  String _consulta = '';
  final _clavesTema = <String, GlobalKey>{};

  @override
  void dispose() {
    _buscador.dispose();
    super.dispose();
  }

  GlobalKey _claveDe(String tema) =>
      _clavesTema.putIfAbsent(tema, () => GlobalKey());

  void _irATema(String tema) {
    final ctx = _clavesTema[tema]?.currentContext;
    if (ctx == null) return;
    Scrollable.ensureVisible(ctx,
        duration: AppMovimiento.larga,
        curve: AppMovimiento.curvaSuave);
  }

  @override
  Widget build(BuildContext context) {
    final buscando = _consulta.isNotEmpty;
    final q = _sinAcentosAyuda(_consulta);
    bool coincide(_SeccionAyuda s) =>
        !buscando ||
        _sinAcentosAyuda(s.titulo).contains(q) ||
        _sinAcentosAyuda(s.texto).contains(q);
    final hijos = <Widget>[];
    var resultados = 0;
    for (final t in _temasAyuda) {
      final ss = t.secciones.where(coincide).toList();
      resultados += ss.length;
      if (ss.isEmpty) continue;
      hijos.add(_Tema(t.nombre, key: _claveDe(t.nombre)));
      for (final s in ss) {
        hijos.add(_Seccion(
          s.titulo,
          s.texto,
          key: ValueKey('ayuda-${s.titulo}-$buscando'),
          icono: s.icono,
          color: s.color,
          expandida: buscando,
        ));
      }
    }
    if (buscando) {
      hijos.insert(
        0,
        resultados == 0
            ? EstadoVacio(
                icono: Icons.search_off_rounded,
                titulo: 'Sin resultados',
                subtitulo:
                    'Nada en la ayuda coincide con «$_consulta». '
                    'Prueba con otra palabra.')
            : Padding(
                padding:
                    const EdgeInsets.only(bottom: AppEspacio.sm),
                child: Text(
                    '$resultados resultado${resultados == 1 ? '' : 's'}',
                    style: AppTexto.metadato.copyWith(
                        color: AppColores.textoSecundario(
                            context))),
              ),
      );
    } else {
      hijos.insert(0, _novedadesCard(context));
      hijos.add(Padding(
        padding:
            const EdgeInsets.symmetric(vertical: AppEspacio.md),
        child: Text(
          'Iron Body Gestión · versión ${AppConfig.appVersion}',
          style: AppTexto.minuscula.copyWith(
              color: AppColores.textoSecundario(context)),
          textAlign: TextAlign.center,
        ),
      ));
    }
    return Scaffold(
      appBar: appBarIron(context, 'Ayuda'),
      body: Column(
        children: [
          // SL-10 G13-2 (sync-una-vez): sin banda de sync
          // en Ayuda — el estado lo dice una sola vez el
          // icono de la cabecera de la app.
          // 1.30 (Oleada D6, UI130-21): buscador en vivo
          // (título y cuerpo, sin acentos) con las
          // coincidencias auto-expandidas y su conteo;
          // la fila de temas queda fija sobre la lista
          // y cada chip desplaza hasta su tema. «Lo
          // Nuevo» se oculta al buscar; un tema sin
          // coincidencias no aparece.
          Padding(
            padding: const EdgeInsets.fromLTRB(
                AppEspacio.lg, AppEspacio.sm, AppEspacio.lg,
                AppEspacio.xs),
            child: CampoTexto(
              controller: _buscador,
              hint: 'Buscar en la ayuda…',
              icono: Icons.search_rounded,
              onChanged: (v) =>
                  setState(() => _consulta = v.trim()),
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(
                AppEspacio.lg, AppEspacio.xs, AppEspacio.lg,
                AppEspacio.sm),
            child: Row(
              children: [
                for (final t in _temasAyuda) ...[
                  ActionChip(
                    label: Text(t.nombre,
                        style: AppTexto.etiqueta),
                    onPressed: () => _irATema(t.nombre),
                  ),
                  const SizedBox(width: 8),
                ],
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(AppEspacio.lg),
              children: hijos,
            ),
          ),
        ],
      ),
    );
  }

  /// Tarjeta "Lo Nuevo": la versión actual destacada, las anteriores plegadas.
  /// Tarjeta "Lo Nuevo" v1.1.1: cabecera con gradiente, cambios con
  /// iconos y versiones anteriores con chips. Ya no es plegable la actual.
  Widget _novedadesCard(BuildContext context) {
    if (novedades.isEmpty) return const SizedBox.shrink();
    final actual = novedades.first;
    final anteriores = novedades.skip(1).toList();
    return Padding(
      padding: const EdgeInsets.only(bottom: AppEspacio.md),
      child: Tarjeta(
        padding: EdgeInsets.zero,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Cabecera «Lo Nuevo» — 1.30 D1 (UI130-01):
            // fuera el blanco sobre el gradiente naranja
            // (1,83/2,73): la cabecera pasa a carbón con
            // acento naranja y el chip de versión a
            // carbonProfundo con texto blanco.
            Container(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
              decoration: const BoxDecoration(
                gradient: AppColores.gradienteCarbon,
                borderRadius: BorderRadius.vertical(
                    top: Radius.circular(AppRadio.lg)),
              ),
              child: Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: const BoxDecoration(
                      color: AppColores.carbonProfundo,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.new_releases_rounded,
                        color: AppColores.naranja, size: 24),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text('Lo Nuevo',
                        style: AppTexto.titulo.copyWith(color: Colors.white)),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: AppEspacio.xs),
                    decoration: BoxDecoration(
                      color: AppColores.carbonProfundo,
                      borderRadius:
                          BorderRadius.circular(AppRadio.chip),
                    ),
                    child: Text('v${actual.version}',
                        style: AppTexto.secundario.copyWith(color: Colors.white, fontWeight: FontWeight.bold)),
                  ),
                ],
              ),
            ),
            // Cambios de la versión actual, con iconos
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 12, 8, 4),
              child: Column(
                children: [
                  for (final c in actual.cambios)
                    Padding(
                      padding: const EdgeInsets.symmetric(
                          vertical: 5, horizontal: AppEspacio.sm),
                      child: Row(
                        crossAxisAlignment:
                            CrossAxisAlignment.start,
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Icon(Icons.check_circle_rounded,
                                size: 18,
                                color: AppColores.textoSecundario(context)),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(c,
                                style: AppTexto.cuerpo.copyWith(
                                    height: 1.35)),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            if (anteriores.isNotEmpty)
              Theme(
                data: ThemeData(
                    dividerColor: Colors.transparent),
                child: ExpansionTile(
                  tilePadding: const EdgeInsets.symmetric(
                      horizontal: AppEspacio.lg),
                  title: Text('Versiones anteriores',
                      style: AppTexto.secundario.copyWith(color: AppColores.textoSecundario(
                              context))),
                  children: [
                    for (final n in anteriores) ...[
                      Padding(
                        padding: const EdgeInsets.fromLTRB(
                            16, 4, 16, 0),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Container(
                            padding:
                                const EdgeInsets.symmetric(
                                    horizontal: AppEspacio.sm,
                                    vertical: 2),
                            decoration: BoxDecoration(
                              color: AppColores.naranja
                                  .withValues(alpha: 0.15),
                              borderRadius:
                                  BorderRadius.circular(AppRadio.md),
                            ),
                            child: Text('v${n.version}',
                                style: AppTexto.metadato.copyWith(color: AppColores.textoNaranja(context), fontWeight: FontWeight.bold)),
                          ),
                        ),
                      ),
                      for (final c in n.cambios)
                        Padding(
                          padding:
                              const EdgeInsets.fromLTRB(
                                  24, 4, 16, 2),
                          child: Row(
                            crossAxisAlignment:
                                CrossAxisAlignment.start,
                            children: [
                              Padding(
                                padding:
                                    const EdgeInsets.only(top: AppEspacio.xs),
                                child: Icon(
                                    Icons.fiber_manual_record_rounded,
                                    size: 8,
                                    color: AppColores
                                        .textoSecundario(
                                            context)),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(c,
                                    style: AppTexto.secundario.copyWith(color: AppColores
                                            .texto(context))),
                              ),
                            ],
                          ),
                        ),
                      const SizedBox(height: 8),
                    ],
                  ],
                ),
              ),
            const SizedBox(height: 4),
          ],
        ),
      ),
    );
  }
}

/// 1.30 (Oleada D6, UI130-21): los temas y las
/// secciones de Ayuda como DATOS — los mismos
/// títulos y textos de siempre, intactos — para que
/// el buscador filtre y auto-expanda sobre esta
/// misma lista, sin duplicar contenido.
const _temasAyuda = <_TemaAyuda>[
    _TemaAyuda('Tu trabajo diario', [
    _SeccionAyuda(
      'Inscribir un cliente',
      '1. En el inicio, toca el botón naranja del rayo (abajo '
      'a la derecha) y elige "Inscribir".\n'
      '2. Escribe el nombre y, si quieres, teléfono, carnet y foto.\n'
      '3. Elige el tipo de pago y confirma el resumen.\n'
      '4. Si ya existe alguien parecido, la app te avisa '
      'antes de duplicarlo.\n\n'
      'Todo se guarda en el teléfono aunque no haya internet.',
      icono: Icons.edit_note_rounded,
      color: AppColores.info,
    ),
    _SeccionAyuda(
      'Cobrar una mensualidad',
      '1. Busca al cliente o ábrelo desde las listas.\n'
      '2. En su ficha toca "Registrar pago" (o el botón Pagar '
      'de la lista). También puedes tocar el botón del rayo '
      'del inicio y elegir "Cobrar".\n'
      '3. Elige el tipo de pago (mensual, semanal, quincenal '
      'u ofertas como "Oferta 50%") y el método: efectivo o '
      'transferencia.\n'
      '4. Confirma el resumen.\n\n'
      'Si está vencido, en su ficha verás "Renovación rápida" '
      'para cobrarle 1 mes con un toque.',
      icono: Icons.payments_rounded,
      color: AppColores.exito,
    ),
    _SeccionAyuda(
      'Pago diario',
      'Para quien entrena un día suelto.\n'
      'En el inicio, toca el botón del rayo y elige '
      '"Pago diario". Queda registrado en tu turno y en tu '
      'pendiente si es en efectivo.',
      icono: Icons.receipt_long_rounded,
      color: AppColores.infoOscuro,
    ),
    _SeccionAyuda(
      'Las listas',
      '• Hoy: vencen hoy.\n'
      '• Por vencer: vencen en los próximos 3 días (sin '
      'contar los de hoy).\n'
      '• Atrasados -30d: vencidos hace menos de un mes.\n'
      '• Atrasados +30d: vencidos hace más de un mes.\n'
      '• Al día: clientes activos con su pago corriente.\n\n'
      'Toca Pagar en cualquier fila para cobrar sin entrar '
      'a la ficha.',
      icono: Icons.list_alt_rounded,
      color: AppColores.alerta,
    ),
    _SeccionAyuda(
      'Mi turno',
      'Tus cobros de hoy, tu cierre de turno y tu pendiente '
      'a entregar. Con tu usuario solo ves tus números.',
      icono: Icons.person_rounded,
      color: AppColores.infoOscuro,
    ),
    _SeccionAyuda(
      'Avisos WhatsApp de hoy',
      'El botón de avisos del inicio junta lo del día: '
      'cumpleaños, clientes que vencen hoy, por vencer y '
      'recibos de pago.\n\n'
      'Al tocar un aviso se abre TU WhatsApp con el mensaje '
      'ya escrito; tú decides si lo envías. La app no '
      'envía nada sola.',
      icono: Icons.chat_rounded,
      color: AppColores.exito,
    ),
    _SeccionAyuda(
      'Foto del cliente',
      'Al poner o cambiar la foto puedes acercarla y '
      'moverla para encuadrar el rostro: lo que dejes en '
      'el cuadro es lo que se guarda.\n\n'
      'Para quitarla, en la ficha toca "Eliminar foto" '
      '(funciona aunque la foto nunca se haya descargado '
      'en este teléfono).',
      icono: Icons.photo_camera_rounded,
      color: AppColores.info,
    ),
    ]),
    _TemaAyuda('Dinero', [
    _SeccionAyuda(
      'Pendiente a entregar',
      'Es el efectivo que cobraste (pagos, diarios y ventas '
      'en efectivo) y aún no le entregaste al dueño. '
      'Baja cuando el dueño hace el arqueo y confirma la '
      'entrega; no es un error.\n\n'
      'Las transferencias no entran aquí: van directo a '
      'la cuenta del dueño.',
      icono: Icons.handshake_rounded,
      color: AppColores.exito,
    ),
    _SeccionAyuda(
      'Cobro por transferencia',
      'Muestra los datos de las tarjetas para que el cliente '
      'transfiera y confirme por WhatsApp al móvil de '
      'confirmación que aparece en esa pantalla.',
      icono: Icons.smartphone_rounded,
      color: AppColores.infoOscuro,
    ),
    _SeccionAyuda(
      'Suplementos',
      'Para vender: busca el producto (o el cliente, si la '
      'venta es suya), elige cantidad y moneda (CUP o USD) '
      'y confirma. Puedes enviar el comprobante por '
      'WhatsApp.\n\n'
      'Si un producto se vende a crédito queda como fiado '
      'hasta que se salde. El dueño controla el stock, '
      'los márgenes y los fiados desde Administración.',
      icono: Icons.medication_rounded,
      color: AppColores.info,
    ),
    _SeccionAyuda(
      'Nómina (solo dueño)',
      'En Administración → Nómina: la base es el número de '
      'clientes que pagaron el mes, por la tarifa de cada '
      'entrenador, más los bonos. La app la pre-calcula '
      'sola.\n\n'
      'Ojo: quien paga este mes pero su cobertura vence '
      'dentro del propio mes (por ejemplo un semanal) no '
      'entra en la base de este mes.',
      icono: Icons.calculate_rounded,
      color: AppColores.alerta,
    ),
    ]),
    _TemaAyuda('Gestión', [
    _SeccionAyuda(
      'Control de Acceso',
      'En Administración → Control de Acceso, con dos '
      'pestañas:\n\n'
      '• Entrenadores: los usuarios de esta app de gestión '
      'y sus turnos.\n'
      '• Clientes: el acceso de cada cliente a su app. '
      'Ahí generas o reseteas su PIN y, con el botón de '
      'tres puntos de cada tarjeta, tienes las opciones '
      'rápidas (ver ficha, avisar por WhatsApp y más).\n\n'
      'Si un día el registro automático de turnos falló, '
      'el dueño puede marcar el turno a mano. El horario '
      'semanal de turnos lo define el dueño en '
      'Administración → Horario.',
      icono: Icons.badge_rounded,
      color: AppColores.info,
    ),
    _SeccionAyuda(
      'Adopción y Campaña WA (solo dueño)',
      'En Control de Acceso → Clientes:\n\n'
      '• Adopción: cuántos clientes ya tienen acceso a su '
      'app y cuántos la han activado.\n'
      '• Campaña WA: una tanda guiada para invitar por '
      'WhatsApp a los clientes que faltan, uno por uno '
      '(máximo 40 por tanda). La app prepara cada mensaje '
      'y recuerda por dónde quedaste; el envío siempre '
      'lo haces tú desde tu WhatsApp.',
      icono: Icons.campaign_rounded,
      color: AppColores.naranja,
    ),
    _SeccionAyuda(
      'Incidencias',
      'Si algo anda mal en el gym (equipo roto, un problema '
      'con un cliente, lo que sea), repórtalo como '
      'incidencia con su descripción. El dueño las sigue '
      'y las marca resueltas; tú ves el estado de las '
      'tuyas.',
      icono: Icons.report_problem_rounded,
      color: AppColores.alerta,
    ),
    _SeccionAyuda(
      'Papelera',
      'Los clientes inactivos van a la papelera. Desde '
      'ahí puedes recuperarlos sin inscribirlos de nuevo. '
      'Eliminarlos definitivamente solo puede hacerlo '
      'el dueño.',
      icono: Icons.delete_outline_rounded,
    ),
    ]),
    _TemaAyuda('La app', [
    _SeccionAyuda(
      '¿Necesita internet?',
      'No para trabajar. Inscribes y cobras con normalidad '
      'en el gym; cuando tengas conexión, los datos se '
      'envían solos.',
      icono: Icons.signal_cellular_alt_rounded,
      color: AppColores.naranja,
    ),
    _SeccionAyuda(
      'Sincronización',
      '• La app sincroniza sola al abrirla y cuando hay '
      'cambios con conexión: sube lo tuyo y baja lo de '
      'los demás.\n'
      '• El botón de sincronizar del inicio muestra el '
      'estado (al día, sincronizando, esperando '
      'conexión) y tocándolo fuerzas una sincronización.\n'
      '• Si ves "N por subir", son tus cambios esperando '
      'conexión; no se pierden.\n'
      '• Las fotos suben después de los datos, para que '
      'un cobro nunca espere por una foto.',
      icono: Icons.sync_rounded,
      color: AppColores.info,
    ),
    ]),
    _TemaAyuda('Si algo falla', [
    _SeccionAyuda(
      'Problemas comunes',
      '• "Sin conexión": sigue trabajando, todo se guarda '
      'y sube después.\n'
      '• "Conexión muy lenta": ten paciencia, las fotos '
      'continúan donde quedaron.\n'
      '• "Error del servidor": reintenta luego; si sigue, '
      'avisa al dueño.\n'
      '• "Te saca al login": tu sesión venció, entra de '
      'nuevo.\n'
      '• "Un cliente no aparece": sincroniza manualmente '
      'desde el inicio.',
      icono: Icons.warning_amber_rounded,
      color: AppColores.error,
    ),
    _SeccionAyuda(
      'Tu privacidad',
      'Con tu usuario ves tus cobros, tu turno y tu '
      'pendiente. El dueño ve los totales de todo el gym '
      'para llevar el control.',
      icono: Icons.lock_rounded,
      color: AppColores.error,
    ),
    _SeccionAyuda(
      'Contacto',
      '¿Dudas con la app? Escríbele al dueño por '
      'Telegram: ${AppConfig.telegramContacto}.',
      icono: Icons.phone_rounded,
      color: AppColores.exito,
    ),
    ]),
];

/// Una sección de Ayuda como dato.
class _SeccionAyuda {
  final String titulo;
  final String texto;
  final IconData icono;
  final Color? color;
  const _SeccionAyuda(this.titulo, this.texto,
      {required this.icono, this.color});
}

/// Un tema de Ayuda con sus secciones, en orden.
class _TemaAyuda {
  final String nombre;
  final List<_SeccionAyuda> secciones;
  const _TemaAyuda(this.nombre, this.secciones);
}

/// Pliegue del buscador de Ayuda: sin acentos
/// (mismo patrón que la búsqueda de la Guía).
String _sinAcentosAyuda(String s) {
  const mapa = {
    'á': 'a', 'é': 'e', 'í': 'i', 'ó': 'o', 'ú': 'u',
    'ü': 'u', 'ñ': 'n',
  };
  var r = s.toLowerCase();
  mapa.forEach((k, v) => r = r.replaceAll(k, v));
  return r;
}

/// Encabezado de grupo temático.
class _Tema extends StatelessWidget {
  final String texto;
  const _Tema(this.texto, {super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 12, 4, 4),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(texto,
            style: AppTexto.subtitulo
                .copyWith(color: AppColores.textoNaranja(context))),
      ),
    );
  }
}

class _Seccion extends StatelessWidget {
  final String titulo;
  final String texto;
  final IconData icono;
  final Color? color;
  // 1.30 (Oleada D6, UI130-21): al buscar, las
  // coincidencias nacen expandidas.
  final bool expandida;
  const _Seccion(this.titulo, this.texto,
      {super.key,
      required this.icono,
      this.color,
      this.expandida = false});

  @override
  Widget build(BuildContext context) {
    final c = color ?? AppColores.textoSecundario(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: AppEspacio.sm),
      child: Tarjeta(
        padding: EdgeInsets.zero,
        child: ExpansionTile(
          initiallyExpanded: expandida,
          leading: CircleAvatar(
            backgroundColor: c.withValues(alpha: 0.15),
            child: Icon(icono, size: 20, color: c),
          ),
          title: Text(titulo, style: AppTexto.subtitulo),
          children: [
            Padding(
              padding:
                  const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(texto,
                    style: AppTexto.cuerpo
                        .copyWith(height: 1.4)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
