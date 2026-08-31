#!/bin/bash
# ==============================================================================
#  Post-proceso de libruby-static.a para enlazado estatico de extensiones.
#
#  Ruby mete dmyext.o en el archivo: un Init_ext() VACIO que actua de marcador
#  cuando no hay extensiones estaticas. El enlazador lo resuelve antes de llegar
#  a nuestro extinit.o, dejando zlib/stringio/strscan sin registrar y sin que
#  ningun error lo delate.
#
#  El build normal de Ruby sustituye dmyext.o por ext/extinit.o. Aqui hacemos
#  lo mismo a mano, y de paso metemos los objetos de las extensiones.
# ==============================================================================
set -e
export DEVKITPRO=C:/devkitPro
export PATH=/c/devkitPro/devkitA64/bin:$PATH
ROOT=/c/anilswitch
AR=aarch64-none-elf-ar
NM=aarch64-none-elf-nm

cp "$ROOT/build/ruby-switch/libruby-static.a" "$ROOT/out/nx/lib/libruby-static.a"
cd "$ROOT/out/nx/lib"

echo "=== Retirando dmyext.o (Init_ext vacio) ==="
$AR d libruby-static.a dmyext.o
$NM libruby-static.a 2>/dev/null | grep -qE " T Init_ext$" && echo "  AVISO: sigue habiendo Init_ext" || echo "  Init_ext eliminado"

echo ""
echo "=== Insertando extinit + extensiones ==="
$AR r libruby-static.a "$ROOT"/out/nx/extobj/*.o
$AR s libruby-static.a

echo ""
echo "=== Verificacion ==="
for s in Init_ext Init_zlib Init_stringio Init_strscan ruby_init_ext ruby_init; do
  printf "  %-16s : " "$s"
  $NM libruby-static.a 2>/dev/null | grep -qE " T $s$" && echo "OK" || echo "FALTA"
done
ls -la libruby-static.a
