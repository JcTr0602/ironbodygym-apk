/// Gestión 1.30 · Oleada D2 «Home y sync»: UI130-05
/// (cabecera en dos niveles), UI130-06 (mostrador único
/// y dial de Servicios), UI130-07 (sync en un solo
/// lenguaje), UI130-31 (Hoy por rol), UI130-23
/// (Administración en Hoy + Módulos compacto), UI130-33
/// (buzón: conciliaciones) + GEN-03 (conciliaciones en
/// «Por revisar») + GEN-10 («visto por» en avisos).
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/bloque3.dart';
import 'package:ironbody_gym/sync.dart';
import 'package:ironbody_gym/ui/buzon_dueno.dart';
import 'package:ironbody_gym/ui/diseno.dart';
import 'package:ironbody_gym/ui/panel_por_revisar.dart';
import 'package:ironbody_gym/ui/widgets.dart';

void main() {
  group('D2 · UI130-07 mapa de estados del banner (fijado ANTES '
      'de tocar pantallas)', () {
    // Cada foto del motor → su variante de siempre → su nivel
    // nuevo. La tabla es exhaustiva: las 9 variantes.
    final casos = <(SyncStatus, VarianteBanner, NivelBanner)>[
      (
        const SyncStatus(phase: SyncPhase.uploading),
        VarianteBanner.enviando,
        NivelBanner.filaNeutra
      ),
      (
        const SyncStatus(phase: SyncPhase.downloading),
        VarianteBanner.descargando,
        NivelBanner.filaNeutra
      ),
      (
        const SyncStatus(phase: SyncPhase.photos),
        VarianteBanner.fotos,
        NivelBanner.filaNeutra
      ),
      (
        const SyncStatus(phase: SyncPhase.error),
        VarianteBanner.error,
        NivelBanner.avisoError
      ),
      (
        const SyncStatus(enLinea: false),
        VarianteBanner.sinConexion,
        NivelBanner.filaNeutra
      ),
      (
        const SyncStatus(pending: 3),
        VarianteBanner.pendientes,
        NivelBanner.filaNeutra
      ),
      (
        const SyncStatus(hayNovedades: true),
        VarianteBanner.novedades,
        NivelBanner.filaNeutra
      ),
      (
        const SyncStatus(),
        VarianteBanner.sinSincronizar,
        NivelBanner.filaNeutra
      ),
      (
        SyncStatus(lastOk: DateTime(2026, 11, 8)),
        VarianteBanner.alDia,
        NivelBanner.ninguno
      ),
    ];

    test('las 9 variantes caen en su nivel', () {
      expect(casos, hasLength(9));
      for (final (foto, variante, nivel) in casos) {
        expect(varianteBannerDe(foto), variante, reason: '$foto');
        expect(nivelBannerDe(variante), nivel, reason: '$variante');
      }
    });

    test('solo «al día» no ocupa banda y solo el error es aviso '
        'sólido (exhaustivo sobre el enum)', () {
      for (final v in VarianteBanner.values) {
        final n = nivelBannerDe(v);
        if (v == VarianteBanner.alDia) {
          expect(n, NivelBanner.ninguno, reason: '$v');
        } else if (v == VarianteBanner.error) {
          expect(n, NivelBanner.avisoError, reason: '$v');
        } else {
          expect(n, NivelBanner.filaNeutra, reason: '$v');
        }
      }
    });

    test('el color del estado es el token de su familia', () {
      expect(colorEstadoBanner(VarianteBanner.enviando),
          AppColores.alerta);
      expect(colorEstadoBanner(VarianteBanner.descargando),
          AppColores.info);
      expect(colorEstadoBanner(VarianteBanner.fotos), AppColores.info);
      expect(colorEstadoBanner(VarianteBanner.error), AppColores.error);
      expect(colorEstadoBanner(VarianteBanner.sinConexion),
          AppColores.alertaOscuro);
      expect(colorEstadoBanner(VarianteBanner.pendientes),
          AppColores.alerta);
      expect(colorEstadoBanner(VarianteBanner.novedades),
          AppColores.info);
      expect(colorEstadoBanner(VarianteBanner.sinSincronizar),
          AppColores.alertaOscuro);
      expect(colorEstadoBanner(VarianteBanner.alDia), AppColores.exito);
    });
  });

  group('D2 · UI130-33 buzón con cuarta fuente (conciliaciones)', () {
    test('con cero en las cuatro fuentes el aviso no existe', () {
      const b = ConteoBuzon();
      expect(b.hay, isFalse);
      expect(b.total, 0);
      expect(b.partes, isEmpty);
    });

    test('solo conciliaciones: el buzón existe con esa parte', () {
      const b = ConteoBuzon(conciliaciones: 1);
      expect(b.hay, isTrue);
      expect(b.total, 1);
      expect(b.partes, hasLength(1));
      expect(b.partes.single.destino, DestinoBuzon.conciliaciones);
      expect(b.partes.single.texto, '1 transferencia por comprobar');
    });

    test('la parte de conciliaciones va AL FINAL, tras rellenos, '
        'con su gramática', () {
      const b = ConteoBuzon(
          reservas: 1, adelantos: 1, rellenos: 1, conciliaciones: 2);
      expect(b.total, 5);
      expect(
          b.partes.map((p) => p.destino),
          [
            DestinoBuzon.reservas,
            DestinoBuzon.adelantos,
            DestinoBuzon.rellenos,
            DestinoBuzon.conciliaciones,
          ]);
      expect(b.partes.last.texto, '2 transferencias por comprobar');
      expect(
          b.textoCompleto,
          '1 reserva por responder · 1 solicitud de adelanto · '
          '1 solicitud de relleno · 2 transferencias por comprobar');
    });

    test('Home lee la cuarta fuente del servicio de conciliación '
        'y abre su pantalla (fuente)', () {
      final home = File('lib/ui/home.dart').readAsStringSync();
      expect(home, contains('ConciliacionService.instance'));
      expect(home, contains('conteoPorComprobar()'));
      expect(home, contains('DestinoBuzon.conciliaciones'));
      expect(home, contains('const ConciliacionScreen()'));
    });
  });

  group('D2 · GEN-03 conciliaciones en «Por revisar» de Caja', () {
    test('con conteo > 0 nace UN ítem de Caja a Conciliación', () {
      final items = pendientesPorModulo(
          const FotoPendientesModulos(conciliacionesPorComprobar: 3));
      final caja = items[ModuloPanel.caja]!;
      expect(caja, hasLength(1));
      expect(caja.single.destino, DestinoPorRevisar.conciliaciones);
      expect(caja.single.titulo, 'Transferencias por comprobar');
      expect(caja.single.detalle,
          '3 transferencias esperando tu comprobación');
    });

    test('singular con 1 y ningún ítem con 0', () {
      final uno = pendientesPorModulo(
          const FotoPendientesModulos(conciliacionesPorComprobar: 1));
      expect(uno[ModuloPanel.caja]!.single.detalle,
          '1 transferencia esperando tu comprobación');
      final cero = pendientesPorModulo(const FotoPendientesModulos());
      expect(cero[ModuloPanel.caja], isEmpty);
    });

    test('el ítem convive con las liquidaciones sin pisarlas', () {
      final items = pendientesPorModulo(const FotoPendientesModulos(
        pendientesLiquidar: [(nombre: 'Duany', total: 500.0)],
        conciliacionesPorComprobar: 2,
      ));
      final caja = items[ModuloPanel.caja]!;
      expect(caja, hasLength(2));
      expect(caja.first.destino, DestinoPorRevisar.liquidacion);
      expect(caja.last.destino, DestinoPorRevisar.conciliaciones);
    });
  });
  group('UI130-05 · cabecera en dos niveles', () {
    final home = File('lib/ui/home.dart').readAsStringSync();

    test('la fila de estado lleva la píldora a lo ancho', () {
      final cab = home.substring(home.indexOf('Widget _cabecera()'),
          home.indexOf('Widget _chipRol()'));
      expect(cab.contains('anchoCompleto: true'), isTrue,
          reason: 'la píldora ocupa el ancho de la fila');
      expect(cab.contains('SyncPill('), isTrue);
    });

    test('el botón-icono de sync separado desaparece', () {
      expect(home.contains('_BotonSyncCabecera'), isFalse,
          reason: 'UI130-07: una sola señal de sync, la '
              'píldora');
    });

    test('Ayuda y Tema viven en el menú «más» (⋯)', () {
      expect(home.contains('PopupMenuButton<String>'), isTrue);
      expect(home.contains('Icons.more_vert_rounded'), isTrue);
      final menu = home.substring(
          home.indexOf('Widget _menuMasCabecera()'),
          home.indexOf('Widget _chipRol()'));
      expect(menu.contains("valor == 'ayuda'"), isTrue);
      expect(menu.contains("valor == 'tema'"), isTrue);
      expect(menu.contains('ThemeController.ciclo()'), isTrue);
    });

    test('el logo dice su destino: insignia de engranaje', () {
      final cab = home.substring(home.indexOf('Widget _cabecera()'),
          home.indexOf('Widget _chipRol()'));
      expect(cab.contains('Icons.settings_rounded'), isTrue,
          reason: 'la insignia sobre el logo dice Ajustes');
    });
  });

  group('UI130-06 · mostrador único y dial de Servicios', () {
    final home = File('lib/ui/home.dart').readAsStringSync();

    test('el mostrador ya no es naranja pleno', () {
      final ini = home.indexOf('Widget _mostradorRapido()');
      final fin = home.indexOf('Widget _cabecera()', ini);
      final dock = home.substring(ini, fin);
      expect(dock.contains('backgroundColor: AppColores.naranja'),
          isFalse);
      expect(dock.contains('Icons.payments_rounded'), isTrue,
          reason: 'Cobrar sigue en el mostrador');
      expect(dock.contains('Icons.person_add_rounded'), isTrue,
          reason: 'Inscribir sigue en el mostrador');
    });

    test('el dial ya no conoce las acciones de membresía', () {
      final ini = home.indexOf('class _FabAccionesRapidas');
      final dial = home.substring(ini);
      expect(dial.contains('onCobrar'), isFalse);
      expect(dial.contains('onPagoDiario'), isFalse);
      expect(dial.contains('onInscribir'), isFalse);
      expect(dial.contains('onVenderAgua'), isTrue);
      expect(dial.contains('onVenderRacion'), isTrue);
      expect(dial.contains('onVenderCombo'), isTrue);
      expect(dial.contains('const total = 3;'), isTrue,
          reason: 'el escalonado se reparte entre 3 píldoras');
    });

    test('el FAB lleva el icono propio de dosis', () {
      final ini = home.indexOf('class _FabAccionesRapidas');
      final dial = home.substring(ini);
      expect(dial.contains('Icons.science_rounded'), isTrue);
    });
  });

  group('UI130-31 · Hoy por rol', () {
    final home = File('lib/ui/home.dart').readAsStringSync();

    test('existen las dos vistas y el despacho es por rol', () {
      expect(home.contains('class _VistaHoyDueno'), isTrue);
      expect(home.contains('class _VistaHoyEntrenador'), isTrue);
      expect(home.contains('_VistaHoyDueno('), isTrue);
      expect(home.contains('_VistaHoyEntrenador('), isTrue);
    });

    test('la vista del entrenador NO recibe stock ni saldos',
        () {
      // La zona de CAMPOS Y CONSTRUCTOR: el blindaje es
      // sobre lo que la vista puede recibir, no sobre
      // los comentarios de otras clases del archivo.
      final ini = home.indexOf('class _VistaHoyEntrenador');
      final fin = home.indexOf('List<Widget> secciones()', ini);
      final vista = home.substring(ini, fin).toLowerCase();
      expect(vista.contains('pomo'), isFalse,
          reason: 'blindaje: el entrenador no ve el conteo '
              'de su contenedor de dosis (regla de Servicios)');
      expect(vista.contains('saldo'), isFalse);
      expect(vista.contains('dosis'), isFalse);
    });

    test('el orden del entrenador: alertas antes que finanzas',
        () {
      final ini = home.indexOf('class _VistaHoyEntrenador');
      final fin = home.indexOf('class _FabAccionesRapidas', ini);
      final vista = home.substring(ini, fin);
      expect(
          vista.indexOf("ValueKey('hoy-alertas')") <
              vista.indexOf("ValueKey('hoy-finanzas')"),
          isTrue,
          reason: 'primero sus vencimientos de hoy');
    });

    test('el orden del dueño conserva finanzas tras el '
        'mostrador y la bandeja sobre las alertas', () {
      final ini = home.indexOf('class _VistaHoyDueno');
      final fin = home.indexOf('class _VistaHoyEntrenador', ini);
      final vista = home.substring(ini, fin);
      expect(
          vista.indexOf("ValueKey('hoy-mostrador')") <
              vista.indexOf("ValueKey('hoy-admin')"),
          isTrue);
      expect(
          vista.indexOf("ValueKey('hoy-admin')") <
              vista.indexOf("ValueKey('hoy-finanzas')"),
          isTrue,
          reason: 'UI130-23: Administración entre el '
              'mostrador y Estadísticas Rápidas');
      expect(
          vista.indexOf("ValueKey('hoy-bandeja')") <
              vista.indexOf("ValueKey('hoy-alertas')"),
          isTrue);
    });

    test('las claves de sección se conservan', () {
      for (final k in [
        'hoy-mostrador',
        'hoy-finanzas',
        'hoy-bandeja',
        'hoy-buzon',
        'hoy-alertas',
        'hoy-vacio',
        'hoy-aire',
        'hoy-admin',
      ]) {
        expect(home.contains("ValueKey('$k')"), isTrue,
            reason: 'clave $k');
      }
    });
  });

  group('UI130-23 · Administración en Hoy y rejilla cerrada',
      () {
    final home = File('lib/ui/home.dart').readAsStringSync();

    test('la tarjeta de Administración existe y va al Panel',
        () {
      expect(home.contains('_tarjetaAdministracionHoy()'), isTrue);
      final ini =
          home.indexOf('Widget _tarjetaAdministracionHoy()');
      final tarjeta = home.substring(ini, ini + 1800);
      expect(tarjeta.contains('AdminScreen'), isTrue);
      expect(
          tarjeta.contains(
              'Precios y tarifas · Plus · Usuarios y permisos'),
          isTrue,
          reason: 'el subtítulo del diseño aprobado');
    });

    test('la rejilla cerrada sustituye a GridView.count', () {
      expect(home.contains('_rejillaCerrada('), isTrue);
      expect(home.contains('GridView.count('), isFalse,
          reason: 'sin la celda vacía del conteo impar');
    });

    test('Hoy no pinta el bloque de Módulos', () {
      final ini = home.indexOf('class _VistaHoyDueno');
      final fin = home.indexOf('class _FabAccionesRapidas', ini);
      final hoy = home.substring(ini, fin);
      expect(hoy.contains('_gridModulos'), isFalse);
      expect(hoy.contains('_gridMas'), isFalse);
    });
  });

  group('D2 · GEN-10 «visto por» en avisos', () {
    const avisoTodos = AvisoEntrenador(id: 'a1', titulo: 'T', mensaje: 'M');
    const avisoDuany = AvisoEntrenador(
        id: 'a2',
        titulo: 'T',
        mensaje: 'M',
        destinatarioTelegramId: 969869611);
    const vistoDuany = VistoAviso(
        avisoId: 'a1',
        telegramId: 969869611,
        nombreServidor: 'Duany',
        vistoEn: '2026-11-08T07:42:00');
    const vistoGabriel = VistoAviso(
        avisoId: 'a1',
        telegramId: 1403501391,
        nombreServidor: 'Gabriel',
        vistoEn: '2026-11-08T08:05:00');

    test('fechaVistoCorta formatea la ISO Habana sin convertir', () {
      expect(fechaVistoCorta('2026-11-08T07:42:00'), '8 nov, 07:42');
      expect(fechaVistoCorta('2026-01-31 23:05:11'), '31 ene, 23:05');
      expect(fechaVistoCorta(null), '');
      expect(fechaVistoCorta('basura'), '');
      expect(fechaVistoCorta('2026-13-08T07:42:00'), '');
    });

    test('vistosDeAviso filtra por aviso', () {
      const deOtro = VistoAviso(
          avisoId: 'otro',
          telegramId: 969869611,
          vistoEn: '2026-11-08T07:42:00');
      expect(vistosDeAviso([vistoDuany, deOtro], 'a1'),
          [vistoDuany]);
      expect(vistosDeAviso([vistoDuany], 'a2'), isEmpty);
    });

    test('VistoAviso.fromMirror acepta telegram_id texto y número', () {
      final deTexto = VistoAviso.fromMirror({
        'aviso_id': 'a1',
        'telegram_id': '969869611',
        'nombre': 'Nombre Servidor',
        'visto_en': '2026-11-08T07:42:00',
        'descartado': 1,
      });
      expect(deTexto.telegramId, 969869611);
      expect(deTexto.descartado, isTrue);
      // El nombre visible prefiere el canónico de la siembra.
      expect(deTexto.nombreVisible, 'Duany');
      final deNumero = VistoAviso.fromMirror({
        'aviso_id': 'a1',
        'telegram_id': 1403501391,
        'nombre': 'Gabriel',
        'visto_en': null,
        'descartado': 0,
      });
      expect(deNumero.telegramId, 1403501391);
      expect(deNumero.vistoEn, isNull);
      expect(deNumero.descartado, isFalse);
    });

    test('dirigido: visto con fecha / aún no lo vio', () {
      expect(
          textoVistoPor(avisoDuany, const [
            VistoAviso(
                avisoId: 'a2',
                telegramId: 969869611,
                vistoEn: '2026-11-08T07:42:00')
          ]),
          'Visto por Duany · 8 nov, 07:42');
      expect(textoVistoPor(avisoDuany, const []), 'Aún no lo vio');
      // El visto de OTRO entrenador no cuenta para el dirigido.
      expect(
          textoVistoPor(avisoDuany, const [
            VistoAviso(
                avisoId: 'a2',
                telegramId: 1403501391,
                vistoEn: '2026-11-08T07:42:00')
          ]),
          'Aún no lo vio');
    });

    test('para todos: ambos / falta uno / nadie', () {
      expect(textoVistoPor(avisoTodos, [vistoDuany, vistoGabriel]),
          'Visto por Duany y Gabriel');
      expect(textoVistoPor(avisoTodos, [vistoDuany]),
          'Visto por Duany · falta Gabriel');
      expect(textoVistoPor(avisoTodos, const []),
          'Aún no lo vio nadie');
    });

    test('fuente: espejo, op y pantalla cableados', () {
      final sync = File('lib/sync.dart').readAsStringSync();
      expect(sync.contains("'avisos_vistos': 'sync_avisos_vistos'"),
          isTrue);
      expect(sync.contains("'sync_avisos_vistos': 'avisos_vistos'"),
          isTrue);
      final localdb = File('lib/localdb.dart').readAsStringSync();
      expect(
          localdb
              .contains('CREATE TABLE IF NOT EXISTS avisos_vistos'),
          isTrue);
      expect(localdb.contains("'avisos_vistos',"), isTrue);
      final bloque3 = File('lib/bloque3.dart').readAsStringSync();
      expect(bloque3.contains("kTipoOpMarcarAvisoVisto = "
          "'marcar_aviso_visto'"), isTrue);
      expect(bloque3.contains('tipo: kTipoOpMarcarAvisoVisto'),
          isTrue);
      final tipos =
          File('lib/tipos_operacion.dart').readAsStringSync();
      expect(tipos.contains("'marcar_aviso_visto':"), isTrue);
      final pantalla =
          File('lib/ui/avisos_entrenador.dart').readAsStringSync();
      expect(pantalla.contains('textoVistoPor('), isTrue);
      expect(pantalla.contains('vistosDeAviso(_vistos, a.id)'),
          isTrue);
    });
  });
}
