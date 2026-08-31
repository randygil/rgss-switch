#!/bin/bash
# Dependencias de mkxp-z que devkitPro no empaqueta, portadas a Switch.
export DEVKITPRO=C:/devkitPro
export DEVKITA64=$DEVKITPRO/devkitA64
export PORTLIBS=$DEVKITPRO/portlibs/switch
export PATH=/c/devkitPro/devkitA64/bin:/c/devkitPro/portlibs/switch/bin:$PATH
ROOT=/c/anilswitch
ROOT_W=C:/anilswitch
PREFIX=$ROOT_W/out/nx

ARCH="-march=armv8-a+crc+crypto -mtune=cortex-a57 -mtp=soft -fPIE"
export CC=aarch64-none-elf-gcc CXX=aarch64-none-elf-g++
export AR=aarch64-none-elf-ar RANLIB=aarch64-none-elf-ranlib
export CFLAGS="-g -O2 -std=gnu11 $ARCH -D__SWITCH__ -ffunction-sections -fdata-sections -I$DEVKITPRO/libnx/include -I$PORTLIBS/include"
export CXXFLAGS="-g -O2 -std=gnu++17 $ARCH -D__SWITCH__ -ffunction-sections -fdata-sections -I$DEVKITPRO/libnx/include -I$PORTLIBS/include"
export CPPFLAGS="-D__SWITCH__ -I$DEVKITPRO/libnx/include -I$PORTLIBS/include"
export LDFLAGS="-specs=$DEVKITPRO/libnx/switch.specs $ARCH -L$ROOT_W/out/lib -L$DEVKITPRO/libnx/lib -L$PORTLIBS/lib"
export LIBS="-lnxcompat -lnx"

# ---------------------------------------------------------------- libiconv
echo "############ libiconv ############"
cd $ROOT/build && rm -rf libiconv && mkdir libiconv && cd libiconv
$ROOT/src/libiconv-1.16/configure --host=aarch64-none-elf --prefix=$PREFIX \
  --disable-shared --enable-static --disable-nls --enable-relocatable=no \
  > $ROOT/docs/dep-libiconv.log 2>&1
if [ -f Makefile ]; then
  make -j6 >> $ROOT/docs/dep-libiconv.log 2>&1
  make install >> $ROOT/docs/dep-libiconv.log 2>&1
fi
[ -f $ROOT/out/nx/lib/libiconv.a ] && echo "  >>> libiconv.a OK" || { echo "  >>> FALLO"; tail -12 $ROOT/docs/dep-libiconv.log; }

# ---------------------------------------------------------------- uchardet
echo ""
echo "############ uchardet ############"
cd $ROOT/build && rm -rf uchardet && mkdir uchardet && cd uchardet
cmake -G "Unix Makefiles" \
  -DCMAKE_TOOLCHAIN_FILE=$DEVKITPRO/cmake/Switch.cmake -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
  -DCMAKE_INSTALL_PREFIX=$PREFIX \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=OFF -DBUILD_BINARY=OFF \
  $ROOT/src/uchardet > $ROOT/docs/dep-uchardet.log 2>&1
if [ -f Makefile ]; then
  make -j6 >> $ROOT/docs/dep-uchardet.log 2>&1
  make install >> $ROOT/docs/dep-uchardet.log 2>&1
fi
ls $ROOT/out/nx/lib/libuchardet* >/dev/null 2>&1 && echo "  >>> libuchardet OK" || { echo "  >>> FALLO"; tail -12 $ROOT/docs/dep-uchardet.log; }

# ---------------------------------------------------------------- SDL_sound
echo ""
echo "############ SDL_sound ############"
cd $ROOT/build && rm -rf sdlsound && mkdir sdlsound && cd sdlsound
cmake -G "Unix Makefiles" \
  -DCMAKE_TOOLCHAIN_FILE=$DEVKITPRO/cmake/Switch.cmake -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
  -DCMAKE_INSTALL_PREFIX=$PREFIX -DCMAKE_BUILD_TYPE=Release \
  -DSDLSOUND_BUILD_SHARED=OFF -DSDLSOUND_BUILD_STATIC=ON \
  -DSDLSOUND_BUILD_TEST=OFF -DSDLSOUND_DECODER_MODPLUG=OFF \
  $ROOT/src/SDL_sound > $ROOT/docs/dep-sdlsound.log 2>&1
if [ -f Makefile ]; then
  make -j6 >> $ROOT/docs/dep-sdlsound.log 2>&1
  make install >> $ROOT/docs/dep-sdlsound.log 2>&1
fi
ls $ROOT/out/nx/lib/libSDL2_sound* >/dev/null 2>&1 && echo "  >>> libSDL2_sound OK" || { echo "  >>> FALLO"; grep -nE "error|Error|CMake Error" $ROOT/docs/dep-sdlsound.log | head -6; }

# ---------------------------------------------------------------- pixman
echo ""
echo "############ pixman ############"
cd $ROOT/src/pixman
if [ ! -f configure ]; then
  echo "  generando configure (autoreconf)..."
  NOCONFIGURE=1 ./autogen.sh > $ROOT/docs/dep-pixman-autogen.log 2>&1 || \
    autoreconf -fi >> $ROOT/docs/dep-pixman-autogen.log 2>&1
fi
if [ -f configure ]; then
  cd $ROOT/build && rm -rf pixman && mkdir pixman && cd pixman
  $ROOT/src/pixman/configure --host=aarch64-none-elf --prefix=$PREFIX \
    --disable-shared --enable-static --disable-gtk --disable-libpng \
    --disable-openmp --disable-arm-simd --disable-arm-iwmmxt \
    > $ROOT/docs/dep-pixman.log 2>&1
  if [ -f Makefile ]; then
    make -j6 -C pixman >> $ROOT/docs/dep-pixman.log 2>&1
    make -C pixman install >> $ROOT/docs/dep-pixman.log 2>&1
    make install-pkgconfigDATA >> $ROOT/docs/dep-pixman.log 2>&1 || true
  fi
else
  echo "  >>> autoreconf fallo"; tail -8 $ROOT/docs/dep-pixman-autogen.log
fi
[ -f $ROOT/out/nx/lib/libpixman-1.a ] && echo "  >>> libpixman-1.a OK" || { echo "  >>> FALLO"; grep -nE "error:|Error [0-9]" $ROOT/docs/dep-pixman.log 2>/dev/null | head -6; }

echo ""
echo "=================== RESUMEN ==================="
ls -la $ROOT/out/nx/lib/*.a 2>/dev/null | awk '{printf "  %-28s %8.1f KB\n", $9, $5/1024}'
