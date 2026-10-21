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
import 'componentes.dart';
import 'diseno.dart';
import 'widgets.dart';

class AyudaScreen extends StatelessWidget {
  const AyudaScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Ayuda')),
      body: Column(
        children: [
          const SyncBanner(),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _novedadesCard(context),
                const _Tema('Tu trabajo diario'),
                const _Seccion(
                  'Inscribir un cliente',
                  '1. En el inicio, toca el botón naranja del rayo (abajo '
                  'a la derecha) y elige "Inscribir".\n'
                  '2. Escribe el nombre y, si quieres, teléfono, carnet y foto.\n'
                  '3. Elige el tipo de pago y confirma el resumen.\n'
                  '4. Si ya existe alguien parecido, la app te avisa '
                  'antes de duplicarlo.\n\n'
                  'Todo se guarda en el teléfono aunque no haya internet.',
                  icono: Icons.edit_note,
                  color: AppColores.info,
                ),
                const _Seccion(
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
                  icono: Icons.payments,
                  color: AppColores.exito,
                ),
                const _Seccion(
                  'Pago diario',
                  'Para quien entrena un día suelto.\n'
                  'En el inicio, toca el botón del rayo y elige '
                  '"Pago diario". Queda registrado en tu turno y en tu '
                  'pendiente si es en efectivo.',
                  icono: Icons.receipt_long,
                  color: AppColores.infoOscuro,
                ),
                const _Seccion(
                  'Las listas',
                  '• Hoy: vencen hoy.\n'
                  '• Por vencer: vencen en los próximos 3 días (sin '
                  'contar los de hoy).\n'
                  '• Atrasados -30d: vencidos hace menos de un mes.\n'
                  '• Atrasados +30d: vencidos hace más de un mes.\n'
                  '• Al día: clientes activos con su pago corriente.\n\n'
                  'Toca Pagar en cualquier fila para cobrar sin entrar '
                  'a la ficha.',
                  icono: Icons.list_alt,
                  color: AppColores.alerta,
                ),
                const _Seccion(
                  'Mi turno',
                  'Tus cobros de hoy, tu cierre de turno y tu pendiente '
                  'a entregar. Con tu usuario solo ves tus números.',
                  icono: Icons.person,
                  color: AppColores.infoOscuro,
                ),
                const _Seccion(
                  'Avisos WhatsApp de hoy',
                  'El botón de avisos del inicio junta lo del día: '
                  'cumpleaños, clientes que vencen hoy, por vencer y '
                  'recibos de pago.\n\n'
                  'Al tocar un aviso se abre TU WhatsApp con el mensaje '
                  'ya escrito; tú decides si lo envías. La app no '
                  'envía nada sola.',
                  icono: Icons.chat,
                  color: AppColores.exito,
                ),
                const _Seccion(
                  'Foto del cliente',
                  'Al poner o cambiar la foto puedes acercarla y '
                  'moverla para encuadrar el rostro: lo que dejes en '
                  'el cuadro es lo que se guarda.\n\n'
                  'Para quitarla, en la ficha toca "Eliminar foto" '
                  '(funciona aunque la foto nunca se haya descargado '
                  'en este teléfono).',
                  icono: Icons.photo_camera,
                  color: AppColores.info,
                ),
                const _Tema('Dinero'),
                const _Seccion(
                  'Pendiente a entregar',
                  'Es el efectivo que cobraste (pagos, diarios y ventas '
                  'en efectivo) y aún no le entregaste al dueño. '
                  'Baja cuando el dueño hace el arqueo y confirma la '
                  'entrega; no es un error.\n\n'
                  'Las transferencias no entran aquí: van directo a '
                  'la cuenta del dueño.',
                  icono: Icons.handshake,
                  color: AppColores.exito,
                ),
                const _Seccion(
                  'Cobro por transferencia',
                  'Muestra los datos de las tarjetas para que el cliente '
                  'transfiera y confirme por WhatsApp al móvil de '
                  'confirmación que aparece en esa pantalla.',
                  icono: Icons.smartphone,
                  color: AppColores.infoOscuro,
                ),
                const _Seccion(
                  'Suplementos',
                  'Para vender: busca el producto (o el cliente, si la '
                  'venta es suya), elige cantidad y moneda (CUP o USD) '
                  'y confirma. Puedes enviar el comprobante por '
                  'WhatsApp.\n\n'
                  'Si un producto se vende a crédito queda como fiado '
                  'hasta que se salde. El dueño controla el stock, '
                  'los márgenes y los fiados desde Administración.',
                  icono: Icons.medication,
                  color: AppColores.info,
                ),
                const _Seccion(
                  'Nómina (solo dueño)',
                  'En Administración → Nómina: la base es el número de '
                  'clientes que pagaron el mes, por la tarifa de cada '
                  'entrenador, más los bonos. La app la pre-calcula '
                  'sola.\n\n'
                  'Ojo: quien paga este mes pero su cobertura vence '
                  'dentro del propio mes (por ejemplo un semanal) no '
                  'entra en la base de este mes.',
                  icono: Icons.calculate,
                  color: AppColores.alerta,
                ),
                const _Tema('Gestión'),
                const _Seccion(
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
                  icono: Icons.badge,
                  color: AppColores.info,
                ),
                const _Seccion(
                  'Adopción y Campaña WA (solo dueño)',
                  'En Control de Acceso → Clientes:\n\n'
                  '• Adopción: cuántos clientes ya tienen acceso a su '
                  'app y cuántos la han activado.\n'
                  '• Campaña WA: una tanda guiada para invitar por '
                  'WhatsApp a los clientes que faltan, uno por uno '
                  '(máximo 40 por tanda). La app prepara cada mensaje '
                  'y recuerda por dónde quedaste; el envío siempre '
                  'lo haces tú desde tu WhatsApp.',
                  icono: Icons.campaign,
                  color: AppColores.naranja,
                ),
                const _Seccion(
                  'Incidencias',
                  'Si algo anda mal en el gym (equipo roto, un problema '
                  'con un cliente, lo que sea), repórtalo como '
                  'incidencia con su descripción. El dueño las sigue '
                  'y las marca resueltas; tú ves el estado de las '
                  'tuyas.',
                  icono: Icons.report_problem,
                  color: AppColores.alerta,
                ),
                const _Seccion(
                  'Papelera',
                  'Los clientes inactivos van a la papelera. Desde '
                  'ahí puedes recuperarlos sin inscribirlos de nuevo. '
                  'Eliminarlos definitivamente solo puede hacerlo '
                  'el dueño.',
                  icono: Icons.delete_outline,
                ),
                const _Tema('La app'),
                const _Seccion(
                  '¿Necesita internet?',
                  'No para trabajar. Inscribes y cobras con normalidad '
                  'en el gym; cuando tengas conexión, los datos se '
                  'envían solos.',
                  icono: Icons.signal_cellular_alt,
                  color: AppColores.naranja,
                ),
                const _Seccion(
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
                  icono: Icons.sync,
                  color: AppColores.info,
                ),
                const _Tema('Si algo falla'),
                const _Seccion(
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
                  icono: Icons.warning,
                  color: AppColores.error,
                ),
                const _Seccion(
                  'Tu privacidad',
                  'Con tu usuario ves tus cobros, tu turno y tu '
                  'pendiente. El dueño ve los totales de todo el gym '
                  'para llevar el control.',
                  icono: Icons.lock,
                  color: AppColores.error,
                ),
                const _Seccion(
                  'Contacto',
                  '¿Dudas con la app? Escríbele al dueño por '
                  'Telegram: ${AppConfig.telegramContacto}.',
                  icono: Icons.phone,
                  color: AppColores.exito,
                ),
                Padding(
                  padding:
                      const EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    'Iron Body Gestión · versión ${AppConfig.appVersion}',
                    style: AppTexto.minuscula.copyWith(
                        color: AppColores.textoSecundario(
                            context)),
                    textAlign: TextAlign.center,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Tarjeta "Lo Nuevo": la versión actual destacada, las anteriores plegadas.
  /// Tarjeta "Lo Nuevo" v1.1.1: cabecera con gradiente, cambios con
  /// iconos y versiones anteriores con chips. Ya no es plegable la actual.
  static Widget _novedadesCard(BuildContext context) {
    if (novedades.isEmpty) return const SizedBox.shrink();
    final actual = novedades.first;
    final anteriores = novedades.skip(1).toList();
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Tarjeta(
        padding: EdgeInsets.zero,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Cabecera con gradiente naranja
            Container(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
              decoration: const BoxDecoration(
                gradient: AppColores.gradienteNaranja,
                borderRadius: BorderRadius.vertical(
                    top: Radius.circular(AppRadio.lg)),
              ),
              child: Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.22),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.new_releases,
                        color: Colors.white, size: 24),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text('Lo Nuevo',
                        style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 17,
                            color: Colors.white)),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.22),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text('v${actual.version}',
                        style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 13)),
                  ),
                ],
              ),
            ),
            // Cambios de la versión actual, con iconos
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 10, 8, 4),
              child: Column(
                children: [
                  for (final c in actual.cambios)
                    Padding(
                      padding: const EdgeInsets.symmetric(
                          vertical: 5, horizontal: 8),
                      child: Row(
                        crossAxisAlignment:
                            CrossAxisAlignment.start,
                        children: [
                          const Padding(
                            padding: EdgeInsets.only(top: 2),
                            child: Icon(Icons.check_circle,
                                size: 18,
                                color: AppColores.naranja),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(c,
                                style: const TextStyle(
                                    fontSize: 14,
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
                      horizontal: 16),
                  title: Text('Versiones anteriores',
                      style: TextStyle(
                          fontSize: 13,
                          color: AppColores.textoSecundario(
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
                                    horizontal: 8,
                                    vertical: 2),
                            decoration: BoxDecoration(
                              color: AppColores.naranja
                                  .withValues(alpha: 0.15),
                              borderRadius:
                                  BorderRadius.circular(12),
                            ),
                            child: Text('v${n.version}',
                                style: const TextStyle(
                                    fontWeight:
                                        FontWeight.bold,
                                    fontSize: 12,
                                    color:
                                        AppColores.naranja)),
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
                                    const EdgeInsets.only(top: 5),
                                child: Icon(
                                    Icons.fiber_manual_record,
                                    size: 8,
                                    color: AppColores
                                        .textoSecundario(
                                            context)),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(c,
                                    style: TextStyle(
                                        fontSize: 13,
                                        color: AppColores
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

/// Encabezado de grupo temático.
class _Tema extends StatelessWidget {
  final String texto;
  const _Tema(this.texto);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 12, 4, 4),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(texto,
            style: AppTexto.subtitulo
                .copyWith(color: AppColores.naranja)),
      ),
    );
  }
}

class _Seccion extends StatelessWidget {
  final String titulo;
  final String texto;
  final IconData icono;
  final Color? color;
  const _Seccion(this.titulo, this.texto,
      {required this.icono, this.color});

  @override
  Widget build(BuildContext context) {
    final c = color ?? AppColores.textoSecundario(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Tarjeta(
        padding: EdgeInsets.zero,
        child: ExpansionTile(
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
