/// "Lo Nuevo": cambios por versión, para la sección de Ayuda.
///
/// Se muestra automáticamente una vez tras actualizar la app (punto 46).
library;

import 'package:flutter/material.dart';

import 'config.dart';
import 'perfil.dart';
import 'ui/diseno.dart';

class Novedad {
  final String version;
  final List<String> cambios;
  const Novedad(this.version, this.cambios);
}

const novedades = [
  Novedad('1.30.0', [
    'Diseño renovado en toda la app: los encabezados de sección se ven iguales en todas las pantallas, las listas abren con su franja de resumen, las pantallas de carga muestran la forma real de lo que viene y el movimiento al pasar de una pantalla a otra es suave y uniforme',
    '«Visto por» en los avisos al equipo: en el aviso ves quién lo vio y cuándo, para saber que llegó sin tener que preguntar (el servidor ya lo soporta, no hace falta tocar nada más)',
    'Marcas verificadas: en la ficha de cada cliente ves las marcas que registra en su app y las verificas con un toque —queda registrado quién verificó y cuándo—; si el cliente edita una marca ya verificada, el aval se retira solo hasta que la vuelvan a verificar',
    'Servicios Admin por grupos: precios y comisión se editan por producto, cada grupo se guarda por separado y la propia tarjeta te dice si quedó guardado o si tienes cambios sin guardar',
    'Catálogo de suplementos más claro: la rejilla ya no recorta nombres ni precios aunque la letra del teléfono sea grande, el stock se lee en palabras («Agotado», «Quedan 3») y los productos sin foto enseñan una imagen genérica marcada como tal, nunca como si fuera la suya',
    'Buscar y Vencimientos más ligeros: fuera la cabecera grande; arriba ves cuándo se actualizó la lista y el orden vive en un menú junto al buscador',
    'Ayuda con buscador: escribe unas letras y el tema aparece al momento, con su texto abierto y sin tener que desplegar uno por uno',
    'Incidencias con una sola tarjeta: las del equipo y las de sincronización se leen igual, con el motivo en lenguaje claro y las acciones siempre en el mismo sitio; y Control suma también los «Cambios por subir» y te lleva directo a la cola',
    'Eliminar un suplemento lo elimina todo: también sus pomos y lotes abiertos con sus dosis, sin dejar restos por ningún lado; la puerta de «Anuncios» sale del Panel (en la app de Clientes se siguen viendo igual que antes)',
    'Fotos a prueba de cortes: si Android cierra el selector de fotos a mitad de camino (al elegir foto de un suplemento, el comprobante de un pago, una imagen de GymPedia o un avatar), la app se recupera y avisa en vez de quedarse muda',
  ]),
  Novedad('1.29.0', [
    'Inicio con cabecera principal renovada: el logo y el nombre del gym se presentan con más presencia, los botones de arriba son circulares y el de sincronizar muestra su estado en vivo (girando al sincronizar, con su punto de al día, pendientes o error)',
    'Editor de rutinas del gym nuevo: busca ejercicios por nombre, equipo o músculo y míralos con su foto; añade series con sus valores a la vista, reordena arrastrando, quita con Deshacer y sigue los totales de la rutina mientras la armas',
    'Avisos a la app de Clientes con fecha de fin: al publicar un aviso puedes elegir hasta qué día se muestra; al terminar ese día deja de entregarse solo, sin tener que retirarlo a mano',
    'Pedir relleno de pomo: cuando al entrenador se le está acabando un suplemento, su pantalla le ofrece pedir relleno con un toque y tú lo ves en Servicios para rellenar su pomo; la petición no se pierde ni se duplica aunque la conexión falle a mitad de camino',
    'Gastos de cada quien, bien: el entrenador ve sus gastos —también los que ya se sincronizaron— y solo los suyos; tú sigues viendo los de todos',
    'Actividad del cliente en su app: desde su ficha puedes consultar lo último que hizo en su aplicación, sin salir de Gestión',
    'Panel que avisa lo que hay por revisar: cada módulo muestra cuántas decisiones tienes pendientes y, al entrar, te enseña esa misma lista arriba del todo para resolverla sin buscarla',
    'Diseño más cuidado en toda la app: los textos y botones sobre el naranja se leen con el contraste correcto y los iconos son uniformes; y al inscribir, si el selector de fotos se corta a mitad, la app se recupera y avisa en vez de quedarse muda',
    'Correcciones de la revisión final: editar un aviso que ya venció ya no cierra la app, y las ventas de servicios que aún están en cola ya cuentan en la nómina con su fecha y su comisión correctas desde el primer momento',
  ]),
  Novedad('1.28.0', [
    'Sincronización blindada y a la vista: la pantalla «Salud de la sincronización» muestra el estado de cada tabla con un semáforo; si el espejo de un teléfono se desfasa, la app lo detecta y lo repara sola, y la cola de operaciones explica por fila por qué algo no subió y qué hacer',
    'Panel reorganizado: los seis módulos se llaman como los usas —«Caja y dinero», «Clientes e invitados», «Equipo y turnos», «Suplementos y contenido», «Configuración y datos» y «Control y sistema»—, cada uno con su línea de estado en vivo, y el Panel abre al instante con los datos del día',
    'Anuncios desde la app: crea los anuncios de la app de Clientes sin salir de Gestión, con vista previa tal como los verán, audiencia a elegir (todos, clientes, invitados o específicos) y ventana de vigencia',
    'Dinero sin dobleces: liquidar dos veces el mismo pendiente ya es imposible; el resumen de liquidación se comparte por WhatsApp tal cual se registra; si liquidaste por error, puedes deshacerlo mientras la orden siga en tu teléfono; y el historial de liquidaciones queda consultable con buscador',
    'Pendiente que avisa solo: si un entrenador acumula entregas de varios días o mucho efectivo sin entregar, el Panel lo marca con su antigüedad antes de que sea un problema',
    'La ficha del cliente abre y se desplaza sin tirones: carga por partes según bajas, y la sección «Qué le falta» te dice en la propia ficha qué le falta a ese cliente y te da el botón para resolverlo',
    'Turnos, Servicios y nómina más honestos: el turno olvidado se cierra marcado como cierre automático tardío; las ventas muestran su estado («Por sincronizar» o «Revertida»); y al liquidar la nómina, el resumen sale listo para WhatsApp',
    'Recordatorios con pausa hasta una fecha: pausas los avisos hasta el día que elijas y la pausa vale en todos los teléfonos, no solo en el tuyo; los vales de Premios por aprobar se anuncian en el Panel y los premios se ven con su nombre y su medalla en todas partes',
  ]),
  Novedad('1.27.0', [
    'Premios con control total: el catálogo de premios se edita desde la app (días, meta y activo), puedes crear un vale manual para cualquier cliente con su motivo, ver el historial completo de cada uno y anular un vale ya canjeado eligiendo si quitas el pago completo o solo los días no usados',
    'Gastos para el equipo: un entrenador con tu permiso ya puede registrar gastos desde su teléfono (nueva sección «Gastos»); sin permiso, ni siquiera puede encolarlos',
    'Comunidad bajo tu mirada: en el Panel ves qué clientes tienen su vitrina encendida y qué comparten, y puedes ocultar un perfil; encenderla sigue siendo decisión de cada cliente',
    'Fotos de progreso en la nube: si un cliente elige guardarlas en la nube, las ves en su ficha (solo tú, el dueño) y puedes ampliarlas o eliminarlas',
    'Turnos que se curan solos: si un cierre de turno se hizo desde el servidor, el teléfono del entrenador lo refleja sin tener que cerrar sesión; y la tarjeta «A entregar» del Inicio ahora abre el detalle completo de lo que debe entregar',
    'Servicios más fiable: el chequeo diario de sincronización ahora vigila también pomos, ventas y salidas — si el espejo de un teléfono se desfasaba, se corrige solo en la siguiente sincronización',
    'Adelantos honestos: si falta un dato para registrar un adelanto, la app lo dice en el momento en vez de mostrar un falso «registrado»',
  ]),
  Novedad('1.26.1', [
    'Cobrar parcial en «Pendiente a recoger»: si recoges menos de lo que el entrenador debe, escribes la cantidad y listo — el resto queda visible como «Saldo de cobros parciales» y se cobra primero la próxima vez; los pagos se cubren del más viejo al más nuevo, sin partir ninguno',
    'La pantalla de pendientes se lee mejor: las filas salen con contraste pleno (antes se veían atenuadas) y el cuadre a WhatsApp queda como acción discreta bajo los botones de cobro',
    'Inicio más fluido: el scroll ya no se corta ni pierde el impulso cuando la sincronización refresca la pantalla en segundo plano, y cada pestaña (Hoy, Módulos, Más) recuerda dónde ibas',
  ]),
  Novedad('1.26.0', [
    'Premios por aprobar: los vales que los clientes reclaman en su app al cumplir un logro llegan al Panel (módulo Clientes) y se aprueban con un toque: el premio se aplica como días de mensualidad gratis y queda registrado una sola vez',
    'Doble toque, doble problema — resuelto: cerrar turno, cobrar desde Buscar, vender en Servicios y generar el PIN ya no se duplican si se toca dos veces seguidas',
    'Cumpleaños honesto: «Felicitado» solo se marca cuando confirmas que el mensaje sí se envió (si abres WhatsApp y no envías nada, el aviso sigue vivo)',
    'Suplementos de verdad: deslizar para actualizar ahora sí sincroniza con el servidor, y cuando el aviso de sincronización termina, el catálogo se recarga solo',
    'Toques que ya no hacen daño en silencio: borrar la fecha de pago de una ficha pide confirmación; salir de Ajustes del gym con cambios sin guardar pregunta antes; y guardar una vista sin nombre avisa en vez de cerrar sin guardar',
  ]),
  Novedad('1.25.0', [
    'Panel renovado: buscador global de funciones y clientes, contadores de pendientes en cada módulo, y las cifras de ingresos y pagos con su comparación contra el mes anterior y la mini-tendencia de los últimos 7 días',
    'Tu día a tu manera: la estación diaria del Inicio se personaliza (mostrador, finanzas, bandeja y alertas) y las listas de clientes guardan vistas con su pestaña, orden y búsqueda',
    'Cuando una lista sale vacía, la app dice por qué: sin resultados de la búsqueda, sin datos todavía o no se pudo cargar (con botón para reintentar), en vez de un hueco sin explicación',
    'Ficha del cliente: el anillo de la foto muestra el progreso del período pagado, el historial de cobros viene agrupado por meses plegables y el último cobro se repite en un toque (el monto se calcula con la tarifa de hoy)',
    'Bandeja de WhatsApp: al terminar un envío en lote ves el resultado por partes (contactados, sin teléfono y pendientes), y con presión larga sobre el botón verde la plantilla sale en un toque, sin pasar por el editor',
    'Turnos: el calendario marca lo que pasó de verdad contra lo programado (verde si abrieron todos, ámbar si abrió otro o faltó uno, rojo si nadie abrió) y cerrar turno pide el permiso de gestionar turnos en todas las pantallas',
    'Precios en un solo centro: métodos, tipos de pago, tarifas especiales, datos bancarios y pago base en un mismo sitio, y cada precio se guarda solo al salir del campo',
    'La Biblioteca de la Guía muestra la foto de cada ficha y el conteo por equipo; el Centro de control reúne Actividad, Registro, Por persona y Anomalías; y toda la mensajería (bandeja, cumpleaños, campañas, avisos y plantillas) vive en un solo hub de Comunicación',
    'Corrección: el cierre de turno ahora confirma de verdad antes de anunciar «Turno cerrado», y el detalle de un entrenador suma sus pagos diarios por su cuenta, no por el nombre (un tocayo ya no mezcla sus cifras)',
  ]),
  Novedad('1.24.2', [
    'Buscar clientes, renovada: anillo de color en la foto según el estado (verde al día, ámbar por vencer, rojo vencido, dorado Casa) y un icono cuando el cliente tiene notas',
    'Orden a elegir en la lista de clientes (por nombre, por vencimiento o los vencidos primero) y vista compacta para ver más clientes por pantalla; la cabecera ocupa menos y la lista se ve desde más arriba',
    'Mantén presionado un cliente para cobrar, registrar su pago diario, vender, escribir por WhatsApp, llamar o editar, sin entrar a su ficha',
    'Botón de WhatsApp directo en los clientes vencidos o por vencer, con el aviso ya escrito según su estado; y selección múltiple para avisar a varios, uno tras otro',
    'Sincronización más dura: los recordatorios recurrentes ya bajan con su frecuencia (antes llegaban como aviso único) y una foto lenta ya no traba la subida de las demás',
    'Comprobantes de pago: si una subida falla, el reintento espera pausas crecientes en vez de gastar todos los intentos en pocos minutos',
    'Corrección: si una operación queda en revisión, el dinero adelantado en el teléfono (vencimientos y entregas de efectivo) se revierte solo, igual que cuando el servidor la rechaza',
    'Corrección: el cartel rojo de error de sincronización ahora se toca y muestra qué pasó y qué hacer (antes no respondía), y el resumen de la Cola ya no dice «completada» cuando hubo un error',
    'Corrección: los interruptores apagados ya se distinguen en el tema oscuro, y la exención de batería para subir fotos pide el permiso de verdad y avisa si el teléfono no la concede',
  ]),
  Novedad('1.24.1', [
    'Corrección: el botón de abrir/cerrar turno ya no desaparece del Inicio de un entrenador cuando el dueño le oculta la vista de nómina',
    'Corrección: el aviso previo a exportar una copia de seguridad ya no cuenta como «sin subir» las fotos que ya subieron, ni repite la alerta tras sincronizar',
    'Corrección: la vigencia de un bloqueo de acceso de cliente se calcula con el reloj correcto aunque el teléfono esté en otra zona horaria',
    'Corrección: la Actividad de un entrenador reconoce a sus clientes aunque la firma de quién lo inscribió venga guardada como texto',
    'Corrección: la sincronización ya completa — dos espejos nuevos (nómina liquidada y aperturas de turno) rechazaban sus datos en cada descarga y el ciclo nunca cerraba limpio',
    'Corrección: los cierres de turno bajan por fin con su detalle completo (hora de apertura y cierre, pendientes y revisiones), no solo con los totales',
    'Corrección: las rutinas del gym que armas en el Panel ya usan las fichas de la Guía de verdad — la app de clientes puede adoptarlas (antes tomaba los artículos de lectura y ninguna rutina encajaba)',
    'Corrección: si un cobro se queda en revisión por fallos repetidos de red, el vencimiento adelantado también se revierte solo, no solo cuando el servidor lo rechaza',
  ]),
  Novedad('1.24.0', [
    'Blindaje de pagos: si el servidor rechaza o deja en revisión un pago, el vencimiento que la app había adelantado se revierte solo al dato anterior (antes el espejo local quedaba adelantado hasta que alguien lo notara)',
    'Un pago parecido en la cola ya se detecta aunque el monto sea distinto: la app pregunta antes de duplicar un cobro del mismo cliente y el mismo día',
    'Permisos de entrenador que se cumplen de verdad: cobrar, inscribir, editar fichas y gestionar turnos respetan lo que el dueño haya apagado, y cuando un permiso falta el botón avisa en vez de fallar en silencio',
    'Los menores siempre abren el cobro en 1500 CUP, sin excepción',
    'Avisos y rutinas para la app de clientes (solo dueño): desde el Panel puedes publicar avisos y armar las rutinas del gym sin tocar el servidor',
    'Actividad reciente en el Panel: lo último cobrado, inscrito y vendido; cada entrenador ve solo lo suyo y lo de sus clientes',
    'Copias de seguridad más seguras: avisan cuántas fotos y comprobantes faltan por subir antes de exportar, y un respaldo de una versión más nueva de la app ya no se puede importar por error',
    'Sincronización más honesta: si la lista no pudo actualizarse, la app lo dice en vez de anunciar «actualizada»',
  ]),
  Novedad('1.23.0', [
    'Diseño renovado (segunda parte): tarjetas, superficies y diálogos uniformes en toda la app, con el naranja de la casa y cifras alineadas',
    'Sincronización en segundo plano: la app se pone al día sola aunque esté cerrada, sin tener que abrirla para sincronizar',
    'Cada teléfono descarga solo los datos que su rol necesita: los entrenadores ya no bajan la información interna del dueño',
    'Aviso antes de cerrar sesión: si quedan cobros o comprobantes sin subir, la app te avisa antes de que se pierdan al salir',
    'Importar un respaldo ahora puede hacerlo cualquier miembro del staff (con aviso si hay material sin subir); exportarlo sigue siendo solo del dueño',
    'Historial de pagos con quién cobró cada mensualidad, y administración de suplementos ampliada: dosis y botes, reservas, fiados y productos sin foto o sin precio',
    'La Guía puede actualizar sus imágenes sin que tengas que actualizar la app',
    'Correcciones de conteo y de sincronización detectadas en la doble auditoría de cierre de esta versión',
  ]),
  Novedad('1.22.0', [
    'Diseño renovado (primera parte): cabeceras con la identidad del gym, tarjetas y botones más claros en la pantalla principal y en las secciones más usadas',
    'Sincronización reforzada: la bajada de datos se verifica fila a fila para que el espejo local nunca quede a medias cuando la conexión falla',
    'Tarifas: cuando un cliente tiene tarifa especial pactada, esa manda siempre sobre la tarifa de menores, igual en la app y en el servidor',
    'Corrección (1.22.1): las fotos de los clientes ya no se ven deformadas en la ficha ni en las listas',
  ]),
  Novedad('1.21.0', [
    'Candado de acceso (solo dueño): pausa el acceso a la app para todos, para un rol o para una persona, con tu mensaje y caducidad; lo que se intente registrar durante la pausa se guarda y sube solo al reactivar',
    'Cumpleaños: si ya regalaste el mes a un cliente, la felicitación de WhatsApp ahora anuncia el regalo con su nuevo vencimiento (antes salía el saludo sin mencionarlo)',
    'Sincronización reforzada: auditoría completa de la subida y la bajada (operaciones, fotos y comprobantes) con varias correcciones para que nada se pierda ni se duplique cuando la conexión falla a mitad de camino',
    'Comprobantes: la foto en espera ya no gasta sus intentos de subida mientras hay cobros pendientes por subir',
    'Bitácora renovada: el registro interno se agrupa por error repetido, se limpia solo y se exporta por partes para diagnosticar problemas sin archivos enormes',
  ]),
  Novedad('1.20.1', [
    'Corrección importante: la foto de la liquidación de nómina, los expedientes de diferencia de caja y los movimientos de stock ya bajan a la app (en la 1.20.0 se quedaban en el servidor)',
  ]),
  Novedad('1.20.0', [
    'Diseño renovado en toda la app: textos más claros, iconos uniformes, avisos con color según su importancia y montos que se animan al cambiar',
    'Suplementos rediseñados: tarjeta con foto y estado de stock, venta rápida de 1 unidad y ajuste de stock con motivo (merma, regalo, error de conteo...)',
    'Foto del comprobante: al cobrar por transferencia puedes adjuntar la foto y verla después desde la ficha del cliente',
    'Conciliación de transferencias (solo dueño): marca cada transferencia como comprobada o con problema, con su nota; el Dashboard avisa cuántas faltan por comprobar',
    'Diferencias de caja (solo dueño): si una entrega queda por debajo de lo esperado, puedes abrir un expediente y cerrarlo con su explicación',
    'La nómina liquidada guarda la foto del cálculo (base, bonos, adelantos) y cada entrenador confirma en su pantalla que la recibió',
    'Corregir el origen de un adelanto: si un adelanto salió de la caja y era de tu bolsillo (o al revés), el dueño puede corregirlo sin anularlo',
    'Estado de cuenta en la ficha: un resumen listo para enviar al cliente por WhatsApp con su vigencia, pagos y deuda',
    'Comparativa de entrenadores del mes (solo dueño): cobros, ventas, dosis e inscripciones lado a lado',
    'Aviso de operaciones parecidas: si cobras o vendes algo casi igual a lo de hace unos minutos, la app pregunta antes de duplicar',
    'La bandeja de WhatsApp permite editar el mensaje antes de enviarlo, y cualquier recibo de pago se puede reenviar desde la ficha',
    'Las copias de respaldo ahora se verifican antes de compartirse: verás si la copia es válida o falló',
    'Recordatorios que se repiten: cada semana o cada mes, además de la fecha única de siempre',
    'Un entrenador puede cubrir el turno de otro y queda registrado a nombre de quién cubre',
    'Buscar por número: si escribes el número de un cliente en el buscador, aparece primero aunque no coincida el nombre',
  ]),
  Novedad('1.19.0', [
    'Pantalla principal por zonas: módulos agrupados (Cobrar y clientes, El gym hoy, Mi trabajo), turno como chip de color y avisos de vencimientos con su urgencia',
    'Dashboard nuevo: lo urgente del día arriba (pendientes, vencimientos, cumpleaños, stock bajo), balance del mes y ritmo de cierre estimado, todo más rápido',
    'Hub de turnos: quién trabaja hoy, abrir y cerrar el turno del día y el pendiente de cada entrenador en un solo lugar',
    'Historial de caja y de ventas con dólares: filtros, buscador y salto del extracto a la venta; el recibo de WhatsApp ya sale completo',
    'Servicios más firmes: el cuadre ya no carga un reverso al dueño, las ventas de hoy tienen su ficha al tocar, y la carga ya no relee todo el espejo',
    'Notificaciones del sistema: los recordatorios del día avisan a las 8 de la mañana aunque la app esté cerrada',
    'Ficha del cliente con su Plus, bonos con respaldo del servidor, y el entrenador ya ve su solicitud de adelanto mientras sube',
    'Diseño más maduro en toda la app: estados de carga con texto, errores con Reintentar, botones y tarjetas del sistema, y colores coherentes',
    'Corrección de decimales: los montos ya no salen con colas raras (3119.9999…) en Estadísticas',
  ]),
  Novedad('1.18.0', [
    'Servicios rediseñado: botones de venta más claros, MI POMO con el saldo grande para el dueño y pomo ciego para el entrenador, y Administrar, Estadísticas y Ranking reubicados sin tocar los permisos',
    'Actividad: al abrir un detalle, la app ya resuelve el cliente por el nombre del texto y abre su ficha con su botón de WhatsApp; los nombres con tildes, puntos y guiones ya resuelven bien',
    'Bot más firme: un cobro ya no se pierde si se pulsa dos veces seguidas, el recordatorio de entregas ya incluye suplementos y servicios, y las lectoras ya no se quedan fuera de los comandos de consulta',
    'Guía de invitado: cada invitado ya ve solo lo suyo en el mismo teléfono, sin mezclar favoritos, hechos ni rutinas con otro invitado',
    'Pagos por método: las ventas de servicios pagadas por transferencia ya no se cuentan como efectivo en el mes anterior',
  ]),
  Novedad('1.17.0', [
    'Seguridad cerrada: en Auditoría, Administración y GymPedia el entrenador ya solo ve y toca lo suyo; los accesos, la cola y la búsqueda ya no dejan ver ni tocar clientes protegidos',
    'Nómina y pendientes cuadran: las cuentas Casa ya no inflan los ingresos, los servicios ya suman en el día y por entrenador, y el conteo global solo se muestra con permiso',
    'Accesos por lote con aviso: si seleccionas más de 40 clientes entre varias búsquedas, la app te avisa para que desmarques el excedente en vez de recortarlo en silencio',
    'Fotos en fichas más firmes: si la base de datos está ocupada al abrir una ficha, la app reintenta antes de decidir, y una foto eliminada ya no vuelve a aparecer',
    'Renovaciones y ventas con el precio correcto: la renovación cobra según la tarifa real del cliente, y los precios en dólares ya muestran su equivalente en CUP',
  ]),
  Novedad('1.16.0', [
    'Pantalla principal rediseñada por zonas: acciones rápidas arriba (Cobrar, Pago diario, Inscribir, Dosis) a un toque, los números del mes se tocan para ver el detalle, la bandeja de avisos de WhatsApp del día subió arriba y la tarjeta del turno quedó compacta',
    'Servicios rediseñado: botones grandes para dosis, dosis con agua, agua suelta y venta múltiple; cada pomo con su nombre, su saldo y su historial a la vista, y el cuadre con tu comisión del día',
    'Historial de Servicios nuevo: todas las operaciones (raciones, combos, agua suelta y salidas sin venta) de nuevas a viejas, con filtros por tipo y por vendedor; las ventas revertidas salen marcadas y nada se borra',
    '«Pago de entrenadores» en la principal ya muestra el neto real (base + comisiones por dosis − adelantos − deudas arrastradas), no el bruto',
    'Correcciones de auditoría: la venta en dólares sin tasa ya no se guarda mal, las estadísticas de servicios ya cuadran (inversión, costo y margen), y Ajustes, Reservas y accesos quedaron con sus permisos cerrados',
    'Limpieza: los textos de la app ya no muestran códigos internos de las funciones',
  ]),
  Novedad('1.14.0', [
    'Administración reorganizada: la pantalla principal ahora abre con lo que necesita tu atención, una estación diaria (Cobrar, Mi Día, Arqueo, Cierre) y los números del mes que se pueden tocar para ver el detalle; todo lo demás quedó agrupado en 6 módulos por tarea',
    'Cobros por transferencia bien valorados: una inscripción con venta por transferencia ya se muestra a su precio real (2500) en Actividad y pendientes, no a precio de efectivo',
    'Nómina: el mes liquidado ya se ve liquidado también cuando se aprueba desde las solicitudes de los entrenadores',
    'Reparar lista de clientes ahora purga de verdad: si un cliente eliminado seguía apareciendo, con la cola limpia desaparece al tocar Reparar',
    'Venta de servicios: cada cliente muestra su carnet y su edad, y el buscador también busca por carnet, para no confundir hermanos o tocayos',
    'Turnos: las horas se muestran en hora de Cuba aunque el teléfono esté en otra zona',
    'Ranking de servicios: las ventas viejas ya muestran el nombre del cliente en vez de «Cliente 121»',
    'Copia de seguridad: la exportación en frío ahora avisa si no pudo volcar los últimos datos, en vez de compartir una copia incompleta',
  ]),
  Novedad('1.8.0', [
    'Eliminar conservando estadísticas: al eliminar definitivamente a un cliente (desde su ficha o desde la Papelera) ahora puedes elegir — «Eliminar conservando estadísticas» hace desaparecer a la persona pero sus pagos y ventas quedan anónimos, para que las estadísticas y la nómina de meses pasados no cambien; «Eliminar todo» borra también el dinero, como siempre',
    'Si el cliente debe un fiado, el diálogo avisa el monto: al eliminar conservando, la deuda se da por incobrable',
    'Vista del entrenador: cada dato de su tarjeta «Mi Turno Hoy» abre ahora su propio detalle («Pagaron el mes» abre el listado y «Mi base del mes» abre la Nómina), en vez de llevar todo a Mi Turno',
  ]),
  Novedad('1.7.0', [
    'Cuenta a la Casa: las personas de la casa (familia, cortesías) quedan marcadas en dorado, con acceso permanente sin pagar ni vencer; no cuentan en nómina, vencimientos ni ingresos. Solo tú la otorgas o la quitas, desde la ficha del cliente o al inscribir',
    'Reportes App Plus: bandeja nueva con los pagos del App Plus que reportan los invitados; solo tú confirmas o rechazas (con motivo), y el Plus se activa al sincronizar',
    'Precio del App Plus editable en Configuración (por defecto 1000 CUP por 30 días): al guardarlo se actualiza también lo que ve el invitado al cotizar',
    'GymPedia por niveles: 7 artículos esenciales quedan gratis para invitados; el resto es contenido Plus (App Plus o cliente con mensualidad activa). El nivel de cada artículo se elige en su editor',
    'Control de Acceso: las Cuentas a la Casa se distinguen con su chip dorado «Casa»',
    'Cumpleaños: a una Cuenta a la Casa se la felicita igual, pero ya no se le ofrece el regalo de mes (no lo necesita)',
  ]),
  Novedad('1.6.0', [
    'Panel del dueño rediseñado: la Administración abre ahora con lo que necesita tu atención (solicitudes de invitados, reservas por confirmar, efectivo por liquidar, cierres pendientes y stock crítico, cada uno con su botón para resolverlo)',
    'Usuarios: entrenadores, clientes e invitados se gestionan en una sola zona con pestañas; la bandeja de invitados vive ahí, con sus solicitudes a mano',
    'Acciones rápidas arriba: Cobrar, Arqueo y Cierre a un toque, sin entrar a ningún módulo',
    'Resumen del mes de un vistazo: ingresos, pagos y clientes activos, con la hora de la última sincronización',
    'Las secciones de siempre, agrupadas en 5 módulos con nombres de tarea: Caja y dinero, Clientes y equipo, Suplementos y contenido, Control y sistema y Configuración y datos',
    'Turnos en una sola puerta: plan semanal y ajustes por fecha juntos, con la regla a la vista (la app muestra al entrenador programado y solo cambia si abre otro)',
    'Auditoría: abre mostrando lo de otros y las operaciones sensibles o rechazadas; tus operaciones quedan a un toque en «Solo mías»',
    'El aviso de turnos sin reporte ya no reaparece tras descartarlo: el descarte se guarda por día y turno',
    'Información pública: el horario dejó de teclearse a mano; se muestra el horario del sistema y se republica tal cual al guardar',
    'Estadísticas rápidas: «Pagaron el mes» abre el listado de clientes y «Pago de entrenadores» (antes «Base del mes») abre la nómina',
    'El invitado convertido muestra su fecha de conversión y, si su cliente fue eliminado después, lo dice en su registro',
  ]),
  Novedad('1.5.0', [
    'Invitados: nueva bandeja con las personas que se registran desde la app de clientes; se pueden ver sus datos y medidas sincronizadas, atender su solicitud y convertirlas en clientes con un toque',
    'Al convertir un invitado, sus medidas sincronizadas se importan a su ficha tras verificarlas en el servidor',
    'Información pública editable: grupo de WhatsApp, Instagram, contactos y precios que ve el invitado en su app',
    'Carnet: si los dígitos no forman una fecha real (día y mes invertidos), la app avisa al momento sin bloquear el guardado',
  ]),
  Novedad('1.4.6', [
    'Moneda por suplemento: cada suplemento tiene su moneda (CUP o USD) y su precio, sus ventas y sus reservas se muestran y cobran en esa moneda',
    'Ficha del cliente: el historial de pagos ahora dice quién cobró cada pago; también en «Pagos realizados»',
    'Reservas: el importe de cada reserva se muestra en su moneda (la de la foto al reservar)',
  ]),
  Novedad('1.4.5', [
    'Reservas de suplementos: bandeja nueva en Suplementos con las solicitudes de los clientes; puedes confirmarlas, rechazarlas y cobrarlas desde ahí',
    'Panel de permisos completo: las 13 claves de cada entrenador (cobrar, inscribir, editar fichas, vender suplementos, gastos, turnos y visibilidad de cifras)',
    'Sin permiso de cifras, el entrenador ve el panel sin importes y en «Pagos realizados» solo los pagos registrados por él',
    'Administración: nuevo campo «Titular de la cuenta» para los datos de transferencia, y tarifa especial por transferencia en la ficha del cliente',
    'La fase «Subiendo fotos…» solo aparece cuando de verdad hay fotos pendientes',
  ]),
  Novedad('1.4.4', [
    'Vista previa del cliente: desde su ficha ves exactamente lo que él ve en su app (inicio, pagos, suplementos, plan y progreso)',
    'La sincronización ahora limpia los datos fantasma y rellena huecos: si un pago no te aparece, una sincronización completa lo trae',
    'El botón de actualizar en «Pagos realizados» ahora sincroniza de verdad (antes solo releía el teléfono)',
    'Si suspendes a un entrenador, su app se cierra al momento; y el panel de permisos confirma cada cambio contra el servidor',
    'El cartel «Hay cambios nuevos» ya no se queda fijo por los borrados de otros dispositivos',
    'Las notificaciones de ajustes dicen qué cambió (por ejemplo, «titular de la cuenta actualizado»)',
  ]),
  Novedad('1.4.3', [
    'Ficha del suplemento: ahora escribes el contenido del envase (ej. 300 g) y los servicios por envase; el cliente los ve en su catálogo',
    'Listas ordenadas por el nombre real: los clientes escritos en minúsculas (p. ej. «alberto prueba») ya no quedan al final, tras la Z',
    'Limpieza interna: se retiró el sistema viejo de subida de fotos; la cola actual es el único camino (sin cambios visibles)',
  ]),
  Novedad('1.4.2', [
    'Nómina: «Pagaron el mes» ya no cuenta a los clientes que vencen dentro del mismo mes (ese pago corresponde al mes siguiente)',
    'Panel: tocar una barra de la gráfica de 7 días ya muestra el detalle del día (antes podía cerrar la pantalla)',
    'Panel: el desglose del mes ahora incluye los suplementos y cuadra con el total',
    'Panel: «Pendiente por entrenador» muestra también lo que falta en USD',
    'Panel: nueva fila «Neto del mes» (ingresos menos gastos) y acceso directo a los que están por vencer',
    'Ayuda al día: la guía ya refleja las pantallas actuales',
  ]),
  Novedad('1.4.1', [
    'La app ahora se llama Iron Body Gestión',
    'Administración reorganizada: lo de todos los días quedó arriba',
    'Control de Acceso: opciones rápidas en cada cliente (los tres puntos de su tarjeta)',
    'Horario de turnos del dueño: la app de clientes muestra quién abre según el horario cuando no hay turno registrado',
    'Actividad: gráfico de acciones por día (30 días) y filtros que quedan guardados',
    'Adopción y Campaña WA (solo dueño): estadísticas de la app de clientes e invitaciones por tandas',
    'Foto del cliente: el recorte al ajustarla ahora sí se aplica tal cual lo dejas',
    'Eliminar la foto de un cliente funciona aunque nunca se haya descargado en este teléfono',
    'Ficha del cliente reorganizada: acciones juntas y el acceso a su app más claro',
  ]),
  Novedad('1.4.0', [
    'Control de Acceso: entrenadores y accesos de la app de clientes en un solo lugar',
    'Los clientes pueden activar su app ellos mismos con el PIN inicial',
    'Turnos manuales: marca quién abrió si el registro automático falló',
    'Estadísticas rápidas en el inicio: cuántos pagaron el mes y la base de la nómina',
    'Nómina pre-calculada (solo dueño) en Administración',
    'Mediciones del cliente simplificadas en su ficha',
    'Botón de sincronizar con estados claros: sincronizando, al día o esperando conexión',
  ]),
  Novedad('1.3.9', [
    'Permisos por usuario: cada quien ve y hace solo lo que le toca',
    'App de clientes: mediciones de progreso y planes nutricionales',
    'Al inscribir: tipos de pago personalizados en la lista (por ejemplo, las ofertas)',
  ]),
  Novedad('1.3.8', [
    'Avisos de WhatsApp mejorados',
    'Cumpleaños mejor presentados en el inicio y en los avisos',
  ]),
  Novedad('1.3.7', [
    'Suplementos: margen por producto, aviso de stock bajo y control de fiados',
    'Comprobante de venta para enviar por WhatsApp',
    'Buscar al cliente al registrar una venta',
    'Actividad y Auditoría rediseñadas; Administración reorganizada',
    '"Por vencer" ya no mezcla a los que vencen hoy (tienen su propia lista)',
  ]),
  Novedad('1.3.6', [
    'Avisos WhatsApp de hoy: cumpleaños, vencimientos y recibos en una sola bandeja',
    'Arqueo de caja (solo dueño): liquida el efectivo pendiente de cada entrenador',
    'Incidencias de sincronización visibles en Administración',
    'Botón de acciones rápidas (el rayo) en el inicio: Cobrar, Pago diario e Inscribir',
  ]),
  Novedad('1.3.5', [
    'Confirmación con resumen antes de inscribir un cliente',
    'Actividad renovada: más detalle de quién hizo qué',
    'Sincronización por alcance: baja solo lo que cambió, más ligera',
  ]),
  Novedad('1.3.4', [
    'Motor de sincronización nuevo: más rápido y más fiable',
    'Las fotos suben sin bloquear los cobros: primero los datos, después las fotos',
    'Limpieza interna de la base de datos: la app responde mejor con muchos clientes',
  ]),
  Novedad('1.3.2', [
    'Plantillas de descripción por tipo de incidencia',
    'Acciones en lote para incidencias (cambiar estado de varias a la vez)',
    '"¿Siguió viniendo?": elige la base al cobrar un pago vencido',
    'Reportes diarios por entrenador y turnos sin reporte',
    'Resumen mensual de pagos diarios por turno y entrenador',
    'Correcciones de sincronización, dinero y permisos (auditoría completa)',
  ]),
  Novedad('1.3.1', [
    'Confirmar entregas sin crashes: corrección crítica de base de datos',
    'Suplementos: precio recordado se preserva en sincronización',
    'Incidencias: no se pierden cambios locales pendientes',
    'Ventas en USD: tasa opcional, validación robusta',
    'Pago a entrenadores movido a Administración',
  ]),
  Novedad('1.3.0', [
    'Módulo de Incidencias: reporta y sigue problemas del gym',
    'Eliminar suplementos (solo dueño, con validación contable)',
    'Fotos: botón para descartar fotos atascadas en la cola',
    'Diagnóstico de sincronización mejorado',
  ]),
  Novedad('1.2.9', [
    'Fotos con subida reanudable: si se corta el internet, continúa donde quedó',
    'Sincronización blindada: lock entre procesos, sin bloqueos de base de datos',
    'Búsquedas y reportes más rápidos: filtros directos en la base de datos',
    'Fotos optimizadas: la app descarga la versión ligera (WebP), no la original',
  ]),
  Novedad('1.2.5', [
    'Cierres de turno sincronizados: el dueño ve los cierres de todos los entrenadores en Historial de caja',
    'Cierre con desglose: aviso del efectivo pendiente antes de cerrar',
    'Búsqueda rápida: índice de texto completo (nombres y teléfonos), sin trabas',
    'Sincronización más robusta: tolera cortes largos y cada tabla avanza a su ritmo',
    'PIN más seguro: el bloqueo ya no se elude adelantando el reloj del teléfono',
    'Banner de sincronización más claro y vibración en acciones importantes',
  ]),
  Novedad('1.2.4', [
    'Incidencias bidireccionales: reporta y sigue su estado con el dueño',
    'Centro de diagnóstico y bandeja de incidencias',
    'Datos bancarios en Administración',
    'Seguridad: datos sensibles fuera del repositorio público',
  ]),
  Novedad('1.2.3', [
    'Resincronizar fotos implementado de verdad',
    'Sección "Sin stock" para el dueño',
    'Control de reintentos en fotos (sin bucles infinitos)',
    'Fix USD/CUP según el modelo real del negocio',
    'Seguridad: sin atajos inseguros para detectar al dueño',
  ]),
  Novedad('1.2.2', [
    'Control de inventario: alerta de stock en 0',
    'Historial de suplementos en la ficha del cliente',
    'Tu perfil (móvil/carnet) sobrevive reinstalaciones',
    'Seguridad: el rol se lee de donde debe',
    'Fixes: USD/CUP invertido, precio de menores automático',
  ]),
  Novedad('1.2.1', [
    'Categorías de suplementos',
    '12 bugs corregidos y mejoras en Actividad',
    'Fixes de auditoría de seguridad',
  ]),
  Novedad('1.2.0', [
    'Módulo de suplementos: inventario, stock y foto',
    'Ventas de suplementos en CUP y USD con tasa configurable',
    'Inscripción + venta de suplemento en un solo flujo',
    'Promo: 1 mes gratis por compra de suplemento',
    'Pendientes CUP/USD por entrenador con desglose',
    'Historial de ventas y anulación',
    'Dashboard según rol (dueño/entrenador)',
    'Administración reorganizada (secciones A–G)',
    '"Mi día" ahora es "Día del gym"',
    'Fix: "Último acceso" muestra actividad real',
  ]),
  Novedad('1.1.1', [
    'Inicio: contador de clientes que pagaron este mes (tocable) y de clientes al día',
    'Datos de transferencia: enviar por SMS o WhatsApp al móvil del cliente',
    'Mi Turno: cierre de turno real, sin necesidad de pagos diarios',
    'Tarjeta "Lo Nuevo" con nuevo diseño',
    'Errores de red en lenguaje simple',
  ]),
  Novedad('1.1.0', [
    'Rediseño visual completo: colores carbón y naranja, tarjetas, iconos Material en vez de emojis',
    'Login, Home, listas, ficha e inscripción rediseñados',
    'Cobrar, Mi Turno/Mis cobros y diálogo de pago renovados',
    'Sincronización y Administración con nuevo diseño',
    'Actividad: más detalles y tocar un registro abre la ficha del cliente',
    'Papelera con foto de cliente',
    'Pagos realizados accesible desde el inicio',
  ]),
  Novedad('1.0.16', [
    'Tipos de pago dinámicos: agrégalos, edítalos o desactívalos en Administración → Tipos de pago',
    'Precio de menores configurable (ya no fijo en el código)',
    'Pendiente por entrenador tocable: ves qué compone cada monto',
    'Historial por entrenador mejorado: tendencia, comparativas y filtros',
    'Mi Turno mejorado: cierre de turno, qué entregar, vencimientos, tendencia, historial semanal',
    'Para el dueño: "Mi turno" ahora es "Mis cobros" (sin pendiente/entregas)',
    'Icono nuevo, SyncBanner rediseñado, Sincronización como tarjeta propia',
  ]),
  Novedad('1.0.15', [
    'Dashboard mejorado: comparativa del mes, desgloses, proyección, ranking de entrenadores, alerta por vencer, gráfico 30 días',
    'Buscar diferenciado: búsqueda en notas, rango de edad, filtro sin foto',
    'Caja rápida en Agregar pago',
    'Reporte de pagos diarios por fecha y turno',
    'Eliminar foto de cliente desde la ficha',
    'Actividad con badge, pendiente a recoger',
  ]),
  Novedad('1.0.14', [
    'Menores de 18 pagan 1500 CUP/mes automáticamente',
    'Usuarios APK: rol, dispositivo, historial de accesos, foto, compartir credenciales por WhatsApp',
    'Cierre de turno sin pagos diarios',
    'Aviso visual de días vigentes al pagar por adelantado (fix del preview)',
    'Distingue "sin internet" de "servidor inaccesible" (fix del falso "sin conexión")',
    'Fix: la huella ahora sí se verifica al abrir',
    'Pantalla de sincronización con 3 estados y mejor UX',
  ]),
  Novedad('1.0.13', [
    'Pagos realizados tocable: lista de clientes que pagaron',
    '️ Miniaturas de fotos en Mi día',
    'Ayuda rediseñada por temas, más fácil de leer',
    'Pago diario: botón rápido, nota, total del día, deshacer y corregir',
    '️ Eliminar cliente definitivamente desde la papelera (arreglado)',
  ]),
  Novedad('1.0.12', [
    'Gestión de usuarios APK: lista con estado y último acceso',
    'Bloquear/desbloquear/cambiar contraseña sin escribir nombres',
    'Cerrar sesión a distancia desde la lista de usuarios',
    'Seguridad en perfil: vincular dispositivo, huella digital, PIN rápido',
    'Detalle por entrenador al tocar (hoy, últimos 7 días, mes)',
    'Auditoría mejorada: cliente, qué cambió y foto',
    '️ Editar pago completo: monto, fecha y método',
    '️ Fixes de seguridad: sync real, precios siempre actualizados',
  ]),
  Novedad('1.0.11', [
    'Quitado botón flotante de sincronizar (tapaba Ayuda)',
    'Editar vencimiento de mensualidad desde la ficha',
    'Detalle de cada operación sincronizada',
    'Foto en grande al tocarla en la ficha',
    'Elegir teléfono desde los contactos del móvil',
    'Dashboard interactivo (toca las tarjetas)',
    'Dueño ya no se debe a sí mismo en Pendiente a entregar',
    'Miniatura de foto en Cuentas por cobrar',
    'Rol en home: Dueño / Entrenador',
  ]),
  Novedad('1.0.10', [
    'Fecha del pago elegible al renovar (ayer, hoy, etc.)',
    '️ Botón "Verificar con servidor" en la ficha del cliente',
    '️ Lista de congelados en Administración (descongelar)',
    'Pantalla de sincronización rediseñada',
    'Avisado ahora es toggle (se puede deshacer)',
    '"Inscrito por" muestra "Migración del sistema anterior"',
    '️ Miniaturas de fotos en lista corregidas',
    'Caché de fotos se invalida al cambiar la foto',
  ]),
  Novedad('1.0.9', [
    'Historial por entrenador: cobrado, pagos, inscripciones y pendiente',
    '️ Congelar membresía: pausa el vencimiento (no aparece en vencidos)',
    'Exportar Excel: clientes y pagos del mes en CSV',
  ]),
  Novedad('1.0.8', [
    'Dashboard: ingresos hoy/7 días/mes, activos vs vencidos',
    'Mi día: cobros del turno, por cobrar hoy, cerrar turno',
    'Cuentas por cobrar: dinero dormido en vencidos',
    'Marcar avisado en vencidos',
    'Mis avisos: configura notificaciones',
    'Gráfico de ingresos últimos 7 días',
  ]),
  Novedad('1.0.7', [
    'Resumen post-sync: popup con lo subido/bajado',
    'Cumpleaños del mes mejorado',
    'Panel salud del sistema',
    'Editor de foto: zoom y mover para centrar',
    'Sync silenciosa al abrir la app',
    '️ Papelera con selección múltiple',
    '️ Eliminar definitivo (solo dueño)',
    'Cobro en 2 toques',
    '️ Clientes en riesgo',
    'Ficha 360 con totales',
  ]),
  Novedad('1.0.6', [
    'Rechazadas: ahora puedes ver el motivo y reenviar la operación',
    'Confirmación de cobro a pantalla completa (check grande, monto, vencimiento)',
    'Auditoría: quién hizo qué y cuándo (solo dueño)',
    'Pago rápido desde vencidos (ya existía, mejorado)',
  ]),
  Novedad('1.0.5', [
    'La APK ahora verifica si el servidor rechazó una operación (no más falso "aplicada")',
    'Fix: clientes nuevos desde la APK ahora aparecen correctamente',
    'Diálogo "Novedades" al actualizar',
  ]),
  Novedad('1.0.4', [
    'Fix crítico: el botón de sincronizar ahora sí funciona (bug _running)',
    'Al archivar, el cliente desaparece al momento (actualización optimista)',
    'La descarga se repite hasta estar al día (no más falso "sincronizado")',
    'Fix error 400 en gastos que bloqueaba la descarga',
    'Detalle tocable de operaciones con errores en lenguaje claro',
    'Iniciales en vez de silueta para clientes sin foto',
    'Colores: rojo vencido, amarillo por vencer, verde al día',
    '️ Pull-to-refresh en la lista de clientes',
    'Login con animación, recuerda usuario y muestra versión',
  ]),
  Novedad('1.0.3', [
    '️ Sección Administración (solo Jc): estadísticas, precios, usuarios APK, pendiente a entregar, gastos, cierre de caja y exportar',
    'Pendiente a entregar ahora cuenta también lo que aún no se sincroniza',
    'Mi Turno con historial diario, desglose por método y última entrega confirmada',
    'Botón Actualizar en Buscar y miniaturas que se descargan solas',
    'El botón Atrasados ahora abre los atrasados de menos de 30 días',
    'Nueva tarjeta "Pagos realizados" en el inicio',
    '️ Corregir pagos (monto/fecha o anular) desde la ficha, solo admin',
    'Alerta de duplicados por carnet al inscribir',
    'Gastos del gym y cierre de caja diario',
    'La sesión ahora refresca el token antes de pedirte entrar de nuevo',
    'Si una operación es rechazada por el servidor, ya no bloquea a las demás',
  ]),
  Novedad('1.0.2', [
    'Cumpleaños de la semana (la fecha sale del carnet)',
    '️ Nueva sección de Ajustes: foto de perfil, móvil, carnet, tema',
    'Cambia tu contraseña dentro de la app',
    'Las fotos se suben por partes: si se corta la conexión, continúan donde quedaron',
    'La sincronización muestra el progreso de lo pendiente por subir y bajar',
    '⏰ Aviso si llevas más de 8 horas sin subir cambios',
    'Renovación rápida con un toque (también desde la papelera)',
    'Cambia la foto de un cliente: cámara o galería',
    'Ordena las listas por nombre, vencimiento o días restantes',
    '️ Solo Jc puede eliminar definitivamente desde la papelera',
  ]),
  Novedad('1.0.1', [
    'Buscar muestra todos los clientes, con estado y días restantes',
    '️ Períodos de pago: semana, quincena y días personalizados',
    '️ Papelera recuperable',
    'Foto del cliente en ficha y listas',
    'Pago rápido desde las listas',
    'Pendiente a entregar con desglose',
    'Sincronización detallada con hora de última vez',
  ]),
];

/// Compara versiones semánticas (1.0.10 > 1.0.9).
/// La comparación de strings falla: "1.0.10" < "1.0.9" letra por letra.
int compararVersiones(String a, String b) {
  // 1.28 (M5-A9/R3M5-H04): el sufijo «+build» se limpia
  // ANTES de trocear: la versión guardada es la completa
  // ('1.26.1+87') y su tercer componente se parseaba
  // como '1+87' → null → 0, así que la 1.26.1 instalada
  // se comparaba como 1.26.0 y sus notas se repetían en
  // cada actualización siguiente.
  List<int> partes(String v) => v
      .split('+')
      .first
      .split('.')
      .map((e) => int.tryParse(e) ?? 0)
      .toList();
  final pa = partes(a);
  final pb = partes(b);
  for (var i = 0; i < 3; i++) {
    final x = i < pa.length ? pa[i] : 0;
    final y = i < pb.length ? pb[i] : 0;
    if (x != y) return x.compareTo(y);
  }
  return 0;
}

/// 1.28 (M5-B5): las novedades «de mi versión» — la
/// instalada y la inmediatamente anterior — para
/// volver a leerlas desde Ajustes sin arrastrar el
/// historial entero. Si la instalada no está en la
/// lista (una versión intermedia), se devuelven las
/// dos más recientes que no la superen. PURO.
List<Novedad> novedadesDeMiVersion([String? instalada]) {
  final v = instalada ?? AppConfig.appVersion;
  final i =
      novedades.indexWhere((n) => compararVersiones(n.version, v) == 0);
  if (i >= 0) {
    return [
      novedades[i],
      if (i + 1 < novedades.length) novedades[i + 1],
    ];
  }
  return novedades
      .where((n) => compararVersiones(n.version, v) <= 0)
      .take(2)
      .toList();
}

/// 1.28 (M5-C5): la VITRINA de novedades — tarjetas por
/// versión (icono, versión, sello «Nuevo» en la
/// instalada y viñetas cortas con su marca), en vez del
/// muro de texto corrido. La usan el diálogo automático
/// tras actualizar y la relectura desde Ajustes (B5).
class DialogoNovedades extends StatelessWidget {
  final List<Novedad> lista;
  final String titulo;

  const DialogoNovedades({
    super.key,
    required this.lista,
    this.titulo = 'Lo nuevo en esta versión',
  });

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(titulo),
      content: SizedBox(
        width: double.maxFinite,
        child: ListView.builder(
          shrinkWrap: true,
          itemCount: lista.length,
          itemBuilder: (context, i) {
            final n = lista[i];
            final esInstalada =
                compararVersiones(n.version, AppConfig.appVersion) ==
                    0;
            return Card(
              margin: const EdgeInsets.only(bottom: AppEspacio.sm),
              child: Padding(
                padding: const EdgeInsets.all(AppEspacio.md),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.new_releases_rounded,
                            color: AppColores.naranja, size: 20),
                        const SizedBox(width: AppEspacio.sm),
                        Flexible(
                          child: Text('Versión ${n.version}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: AppTexto.subtitulo),
                        ),
                        if (esInstalada) ...[
                          const SizedBox(width: AppEspacio.sm),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: AppEspacio.sm, vertical: 2),
                            decoration: BoxDecoration(
                              color: AppColores.naranja,
                              borderRadius: BorderRadius.circular(
                                  AppRadio.circular),
                            ),
                            child: Text('Nuevo',
                                style: AppTexto.minuscula.copyWith(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w700)),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: AppEspacio.sm),
                    for (final c in n.cambios)
                      Padding(
                        padding: const EdgeInsets.only(
                            bottom: AppEspacio.xs),
                        child: Row(
                          crossAxisAlignment:
                              CrossAxisAlignment.start,
                          children: [
                            const Icon(Icons.check_circle_rounded,
                                size: 15, color: AppColores.exito),
                            const SizedBox(width: 6),
                            Expanded(
                                child: Text(c,
                                    style: AppTexto.secundario)),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
      actions: [
        ElevatedButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Entendido')),
      ],
    );
  }
}

/// Abre la vitrina de novedades con la lista dada.
Future<void> mostrarVitrinaNovedades(
  BuildContext context,
  List<Novedad> lista, {
  String titulo = 'Lo nuevo en esta versión',
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => DialogoNovedades(lista: lista, titulo: titulo),
  );
}

/// Muestra "Lo Nuevo" una sola vez tras actualizar. Devuelve true si la mostró.
Future<bool> mostrarNovedadesSiHay(BuildContext context) async {
  final perfil = PerfilService.instance;
  final vista = await perfil.getUltimaVersionVista();
  if (vista == AppConfig.appVersion) return false;
  // 1.28 (M5-A9/R1M5-6): en una instalación LIMPIA
  // (vista == null) solo se muestran las notas de la
  // versión instalada — volcar las 60+ versiones
  // históricas sobre un teléfono nuevo no informa de
  // nada nuevo para él.
  final nuevas = vista == null
      ? novedades
          .where((n) =>
              compararVersiones(n.version, AppConfig.appVersion) ==
              0)
          .toList()
      : novedades
          .where((n) => compararVersiones(n.version, vista) > 0)
          .toList();
  if (nuevas.isEmpty) {
    // Nada que mostrar: se marca igual (no hay nada que
    // perder) y no se reintenta en cada arranque.
    await perfil.setUltimaVersionVista(AppConfig.appVersion);
    return false;
  }
  // 1.28 (M5-A9/R3M5-H07): sin contexto montado NO se
  // marca: la oferta se repite en el próximo arranque.
  if (!context.mounted) return false;
  // 1.28 (M5-C5): el diálogo automático también es la
  // vitrina de tarjetas, no el muro de texto.
  await mostrarVitrinaNovedades(context, nuevas);
  // 1.28 (M5-A9/R3M5-H07): «visto» se marca SOLO tras
  // cerrar el diálogo: si el proceso muere con el
  // diálogo abierto, las notas se reofrecen al volver
  // (antes se marcaba antes de mostrar y se perdían).
  await perfil.setUltimaVersionVista(AppConfig.appVersion);
  return true;
}
