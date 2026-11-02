#!/bin/bash
# P1 (productividad, selección 1.22): suite de tests en PARALELO.
#
# `flutter test` corre cada archivo en su propio proceso; lo que
# obligaba a --concurrency=1 era que todos compartían el archivo
# .dart_tool/sqflite_common_ffi/databases/ironbody.db y los setUp
# se lo borraban entre sí. Con IRONBODY_TEST_DB=1, LocalDb usa
# ironbody_<pid>.db por proceso (ver _nombreArchivoDb en
# lib/localdb.dart) y resetParaTest borra ese archivo: la suite
# puede correr con -j N sin pisarse.
#
# Uso: tool/test_par.sh [-j N] [rutas de test...]
# Sin rutas: corre toda la suite. La limpieza previa/posterior
# solo toca los ironbody_<pid>.db* huérfanos, nunca ironbody.db.
set -u
cd "$(dirname "$0")/.."

export JAVA_HOME=/home/hatch/jdk17
export PATH=/home/hatch/jdk17/bin:$HOME/flutter-sdk/flutter/bin:$PATH
export TZ=America/Havana
export IRONBODY_TEST_DB=1

DBDIR=.dart_tool/sqflite_common_ffi/databases
limpiar() {
  # Solo archivos de proceso: ironbody_<dígitos>.db (+ -wal/-shm).
  find "$DBDIR" -maxdepth 1 -regextype posix-extended \
    -regex '.*/ironbody_[0-9]+\.db(-wal|-shm)?' -delete 2>/dev/null
}
mkdir -p "$DBDIR"
limpiar
# /tmp es un tmpfs de 512 MB: las corridas matadas dejan restos.
rm -rf /tmp/flutter_tools.* 2>/dev/null

J=4
ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    -j) J="$2"; shift 2 ;;
    *) ARGS+=("$1"); shift ;;
  esac
done

flutter test -j "$J" "${ARGS[@]}"
RC=$?
limpiar
exit $RC
