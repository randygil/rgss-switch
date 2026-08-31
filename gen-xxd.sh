#!/bin/bash
# H4 — reproduce el codegen de meson sin meson.
#
# meson lanza `xxd -i ../shader/X` desde su directorio de compilacion, y xxd
# construye el nombre del array a partir de LA RUTA que se le pasa:
#   ../shader/common.h  ->  ___shader_common_h
# ('..' -> '__', '/' -> '_', '.' -> '_')
# shader.cpp espera justo esos nombres, asi que hay que invocarlo desde un
# directorio hermano de shader/ y assets/, con la ruta relativa exacta.
set -e
MK=/c/anilswitch/src/mkxp-z
OUT=/c/anilswitch/mkxp-z-nx/generated
mkdir -p "$OUT" "$MK/nxbuild"
cd "$MK/nxbuild"

SHADERS="common.h transSimple.frag trans.frag hue.frag sprite.frag plane.frag
gray.frag bitmapBlit.frag flatColor.frag simple.frag simpleColor.frag
simpleAlpha.frag simpleAlphaUni.frag tilemap.frag flashMap.frag lanczos3.frag
minimal.vert simple.vert simpleColor.vert sprite.vert tilemap.vert
tilemapvx.vert blur.frag blurH.vert blurV.vert simpleMatrix.vert"

# liberation.ttf y no wqymicrohei: cjk_fallback_font queda en false
ASSETS="icon.png gamecontrollerdb.txt liberation.ttf"

n=0
for f in $SHADERS; do xxd -i "../shader/$f" > "$OUT/$f.xxd"; n=$((n+1)); done
for f in $ASSETS;  do xxd -i "../assets/$f" > "$OUT/$f.xxd"; n=$((n+1)); done
echo "generados $n ficheros .xxd en $OUT"
