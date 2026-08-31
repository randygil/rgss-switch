#!/bin/bash
# Este CMake es un binario MSYS2: no reconoce "C:/..." como ruta absoluta y la
# concatena al directorio de build. Para los targets de CMake usamos POSIX.
# Solo construimos librerias estaticas, asi que no hace falta switch.ld y no
# aplica el problema de %:getenv(DEVKITPRO) descrito en 5.15.
export DEVKITPRO=/c/devkitPro
export DEVKITA64=$DEVKITPRO/devkitA64
export PORTLIBS=$DEVKITPRO/portlibs/switch
export PATH=/c/devkitPro/devkitA64/bin:/c/devkitPro/portlibs/switch/bin:$PATH
ROOT=/c/anilswitch; PREFIX=/c/anilswitch/out/nx
ARCH="-march=armv8-a+crc+crypto -mtune=cortex-a57 -mtp=soft -fPIE"
export CFLAGS="-g -O2 -std=gnu11 $ARCH -D__SWITCH__"
export CXXFLAGS="-g -O2 -std=gnu++17 $ARCH -D__SWITCH__"

# CMAKE_POLICY_VERSION_MINIMUM: uchardet y SDL_sound piden cmake_minimum_required
# de una version < 3.5, que CMake 4.x ya no acepta. El propio CMake sugiere este flag.
CM="-DCMAKE_TOOLCHAIN_FILE=/c/devkitPro/cmake/Switch.cmake -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY -DCMAKE_INSTALL_PREFIX=$PREFIX -DCMAKE_BUILD_TYPE=Release"

echo "############ uchardet ############"
cd $ROOT/build && rm -rf uchardet && mkdir uchardet && cd uchardet
cmake -G "Unix Makefiles" $CM -DBUILD_SHARED_LIBS=OFF -DBUILD_BINARY=OFF \
  $ROOT/src/uchardet > $ROOT/docs/dep-uchardet.log 2>&1
[ -f Makefile ] && { make -j6 >>$ROOT/docs/dep-uchardet.log 2>&1; make install >>$ROOT/docs/dep-uchardet.log 2>&1; }
ls $ROOT/out/nx/lib/libuchardet* >/dev/null 2>&1 && echo "  >>> libuchardet OK" || { echo "  >>> FALLO"; grep -nE "rror" $ROOT/docs/dep-uchardet.log | head -5; }

echo ""
echo "############ SDL_sound ############"
cd $ROOT/build && rm -rf sdlsound && mkdir sdlsound && cd sdlsound
cmake -G "Unix Makefiles" $CM \
  -DSDLSOUND_BUILD_SHARED=OFF -DSDLSOUND_BUILD_STATIC=ON \
  -DSDLSOUND_BUILD_TEST=OFF -DSDLSOUND_DECODER_MODPLUG=OFF \
  $ROOT/src/SDL_sound > $ROOT/docs/dep-sdlsound.log 2>&1
[ -f Makefile ] && { make -j6 >>$ROOT/docs/dep-sdlsound.log 2>&1; make install >>$ROOT/docs/dep-sdlsound.log 2>&1; }
ls $ROOT/out/nx/lib/libSDL2_sound* >/dev/null 2>&1 && echo "  >>> libSDL2_sound OK" || { echo "  >>> FALLO"; grep -nE "rror" $ROOT/docs/dep-sdlsound.log | head -5; }

echo ""
echo "=================== LIBRERIAS ==================="
ls -la $ROOT/out/nx/lib/*.a 2>/dev/null | awk '{printf "  %-46s %8.1f KB\n", $9, $5/1024}'
