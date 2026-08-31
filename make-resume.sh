#!/bin/bash
# DEVKITPRO en forma WINDOWS: switch.specs contiene
#   -T %:getenv(DEVKITPRO /libnx/switch.ld)
# y GCC expande ese getenv internamente, sin traduccion de rutas de MSYS2.
export DEVKITPRO=C:/devkitPro
export DEVKITA64=$DEVKITPRO/devkitA64
export PORTLIBS=$DEVKITPRO/portlibs/switch
export PATH=/c/devkitPro/devkitA64/bin:/c/devkitPro/portlibs/switch/bin:$PATH
ROOT=/c/anilswitch
cd $ROOT/build/ruby-switch
# -k: seguir pese al fallo del ejecutable 'ruby' (que no necesitamos).
# Lo que buscamos son los .a de las extensiones, sobre todo zlib.
make -k -j6 LD=aarch64-none-elf-ld > $ROOT/docs/make-log.txt 2>&1
echo "codigo de salida: $?"
echo ""
echo "--- errores (sin contar el ejecutable ruby) ---"
grep -nE "error:|undefined reference|Error [0-9]" $ROOT/docs/make-log.txt | grep -v "Makefile:294: ruby" | head -15
echo ""
echo "=== EXTENSIONES .a ==="
find . -name "*.a" 2>/dev/null | grep -v libruby | xargs -n1 basename 2>/dev/null | sort | tr '\n' ' '
echo ""
echo ""
echo "=== zlib ==="
ls -la ext/zlib/*.a 2>/dev/null && echo ">>> ZLIB OK <<<" || echo ">>> zlib AUN NO"
