// SL-2 (Ficha) — refuerzos del relevo: G03-10 por causa
// concreta (500 de servidor), estructura del plegado de
// G03-2, y la pieza A2 (fiados al eliminar), cuyo flujo
// vive FUERA del mapa de archivos de SL-2 (papelera.dart +
// componentes.dart): estos tests fijan su ubicación y su
// cobertura parcial verificada, sin invadir esos archivos.
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/foto_personal_ficha.dart'
    show esFalloDeRedFotoPersonal, textoErrorFotoPersonal;
import 'package:ironbody_gym/ui/auditoria_persona.dart'
    show fechaLegibleAuditoria;
import 'package:ironbody_gym/ui/ficha_acceso.dart'
    show etiquetaAccionAcceso;

String _src(String p) => File(p).readAsStringSync();

/// Un fallo con forma de error de servidor (500): trae
/// marcadores de Postgrest, nada de red.
class _FalloServidor500 implements Exception {
  @override
  String toString() =>
      'PostgrestException(message: Internal server error, '
      'code: 500, details: null)';
}

void main() {
  group('G03-10 foto personal: la causa manda', () {
    test('un 500 de servidor NO es fallo de red', () {
      expect(esFalloDeRedFotoPersonal(_FalloServidor500()), isFalse);
      expect(
          textoErrorFotoPersonal(
              fueDeRed:
                  esFalloDeRedFotoPersonal(_FalloServidor500())),
          'Foto personal: no se pudo verificar.');
    });
    test('un SocketException SÍ es fallo de red', () {
      expect(
          esFalloDeRedFotoPersonal(
              const SocketException('Connection failed')),
          isTrue);
      expect(textoErrorFotoPersonal(fueDeRed: true),
          'Foto personal: sin conexión para verificar.');
    });
    test('un timeout NO se afirma como «sin conexión»', () {
      expect(
          esFalloDeRedFotoPersonal(
              TimeoutException('sin respuesta')),
          isFalse);
    });
  });

  group('G03-7/G03-12 bordes de los traductores', () {
    test('fechaLegibleAuditoria sin fecha → guion, no vacío', () {
      expect(fechaLegibleAuditoria(null), '—');
      expect(fechaLegibleAuditoria(''), '—');
    });
    test('etiquetaAccionAcceso nula → genérico', () {
      expect(etiquetaAccionAcceso(null), 'Acción registrada');
      expect(etiquetaAccionAcceso('resetear_pin'), 'PIN reseteado');
    });
  });

  group('G03-2 estructura del plegado', () {
    test('la principal precede al plegable y las ocasionales '
        'van dentro de la lista plegada', () {
      final s = _src('lib/ui/ficha_acceso.dart');
      final iPrincipal = s.indexOf("label: const Text('Restablecer acceso')");
      final iPlegable = s.indexOf('Más acciones');
      final iOcasionales = s.indexOf('final ocasionales');
      expect(iPrincipal, greaterThan(0));
      expect(iOcasionales, greaterThan(0));
      expect(iPlegable, greaterThan(iOcasionales),
          reason: 'el plegable se construye DESPUÉS de la '
              'lista de ocasionales que contiene');
      // F02-HD (z17_tests_sl2-6): lo que el título promete —
      // la principal PRECEDE al plegable en el árbol (orden
      // de montaje): «Restablecer acceso» no puede vivir
      // dentro ni debajo del pliegue.
      expect(iPlegable, greaterThan(iPrincipal),
          reason: 'G03-2: la acción principal se monta ANTES '
              'del plegable «Más acciones»');
      final segOcasionales = s.substring(iOcasionales, iPlegable);
      for (final txt in [
        'Forzar cambio de PIN',
        'Cerrar sesión remota',
        'Cambiar teléfono',
        'Revocar acceso',
        'Reactivar acceso',
      ]) {
        expect(segOcasionales.contains(txt), isTrue,
            reason: '$txt vive en la lista plegada');
      }
      // F02-HD (z17_tests_sl2-6): el ExpansionTile consume
      // LA lista de ocasionales construida arriba, no una
      // copia inline: su segmento declara la lista como
      // hijas (envuelta en el Wrap del cuerpo del tile).
      final iTile = s.indexOf('ExpansionTile', iOcasionales);
      expect(iTile, greaterThan(iPrincipal),
          reason: 'G03-2: el plegable se monta tras la '
              'principal y tras construir las ocasionales');
      expect(
          s
              .substring(iTile,
                  iTile + 1200 > s.length ? s.length : iTile + 1200)
              .contains('children: ocasionales'),
          isTrue,
          reason: 'G03-2: el ExpansionTile pinta la lista '
              '`ocasionales`, no widgets sueltos');
    });
  });

  group('A2 fiados al eliminar: ubicación y cobertura', () {
    test('el flujo de eliminación definitiva vive en la '
        'Papelera (fuera del mapa SL-2), no en la ficha', () {
      final ficha = _src('lib/ui/ficha.dart');
      expect(ficha.contains('eliminar_cliente'), isFalse,
          reason: 'la ficha no encola eliminar_cliente: el '
              'borrado físico vive solo en la Papelera');
      final papelera = _src('lib/ui/papelera.dart');
      expect(papelera.contains('_eliminarDefinitivoConfirmado'),
          isTrue);
      expect(papelera.contains("tipo: 'eliminar_cliente'"), isTrue);
    });
    test('la Papelera YA suma los fiados vivos del espejo y '
        'avisa de incobrables al elegir modo', () {
      final papelera = _src('lib/ui/papelera.dart');
      expect(papelera.contains('fiadoPendienteDeCliente'), isTrue);
      expect(papelera.contains('incobrables'), isTrue);
      expect(papelera.contains('avisoFiado: avisoFiado'), isTrue);
      final componentes = _src('lib/ui/componentes.dart');
      expect(componentes.contains('elegirModoEliminacion'), isTrue);
      expect(componentes.contains('String? avisoFiado'), isTrue);
    });
    test('A2 cerrada por SL-X1: el aviso de fiado se pinta '
        'con cualquier modo elegido', () {
      // Este test nació en SL-2 fijando el hueco (el aviso
      // solo salía con «conservar»). SL-X1 aplicó A2 y el
      // coordinador actualizó la fijación al comportamiento
      // corregido: la condición ya no mira el modo.
      final componentes = _src('lib/ui/componentes.dart');
      expect(
          componentes
              .contains("avisoFiado != null && modo == 'conservar'"),
          isFalse,
          reason: 'A2: el aviso de fiado debe mostrarse '
              'también con «Eliminar todo»');
      expect(componentes.contains('if (avisoFiado != null)'),
          isTrue);
    });
  });
}
