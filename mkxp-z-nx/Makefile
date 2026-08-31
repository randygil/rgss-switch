#===============================================================================
# mkxp-z 2.4.2 para Nintendo Switch (Horizon OS) — hito H4
#
# Sin meson, a proposito. Tres razones:
#   1. El unico codegen de meson es `xxd -i`, que reproduce gen-xxd.sh.
#   2. Los .pc de portlibs llevan prefix=/opt/devkitpro, que bajo nuestro GCC
#      de Windows se resuelve mal (problema §5.15). pkg-config es un pasivo.
#   3. El Makefile de devkitPro ya produjo un NRO valido en H2.
#===============================================================================

# GCC crea ficheros temporales via GetTempPath(). Al cruzar MSYS2, las rutas
# con contrabarras de TMP/TEMP se corrompen y GCC cae a C:\WINDOWS, donde no
# tiene permiso de escritura. Se fijan aqui para que la compilacion no dependa
# del entorno del shell.
export TMPDIR := C:/anilswitch/tmp
export TMP    := C:/anilswitch/tmp
export TEMP   := C:/anilswitch/tmp

# switch.specs contiene -T %:getenv(DEVKITPRO /libnx/switch.ld), y GCC expande
# %:getenv leyendo el ENTORNO, no las variables de make. Sin `export` el enlace
# muere con "environment variable 'DEVKITPRO' not defined". Es la tercera
# aparicion del mismo problema (§5.15): forma Windows, no /opt/devkitpro.
export DEVKITPRO := C:/devkitPro
DEVKITA64 := $(DEVKITPRO)/devkitA64
PORTLIBS  := $(DEVKITPRO)/portlibs/switch
LIBNX     := $(DEVKITPRO)/libnx
NXPREFIX  := C:/anilswitch/out/nx
MKXPZ     := C:/anilswitch/src/mkxp-z

PREFIX  := $(DEVKITA64)/bin/aarch64-none-elf-
CC      := $(PREFIX)gcc
CXX     := $(PREFIX)g++
AS      := $(PREFIX)as
AR      := $(PREFIX)ar
OBJCOPY := $(PREFIX)objcopy

TARGET  := pokemon-anil
BUILD   := build

#-------------------------------------------------------------------------------
# Fuentes. Listadas a mano a partir de src/meson.build y binding/meson.build:
# un glob de binding/ arrastraria cusl-binding, miniffi-binding y miniffi, que
# meson solo compila con Steamworks o MiniFFI activados.
#-------------------------------------------------------------------------------
SRC_MAIN := main.cpp config.cpp eventthread.cpp settingsmenu.cpp sharedstate.cpp \
  audio/alstream.cpp audio/audio.cpp audio/audiostream.cpp audio/fluid-fun.cpp \
  audio/midisource.cpp audio/sdlsoundsource.cpp audio/soundemitter.cpp \
  audio/vorbissource.cpp \
  crypto/rgssad.cpp \
  display/autotiles.cpp display/autotilesvx.cpp display/bitmap.cpp \
  display/font.cpp display/graphics.cpp display/plane.cpp display/sprite.cpp \
  display/tilemap.cpp display/tilemapvx.cpp display/viewport.cpp \
  display/window.cpp display/windowvx.cpp \
  display/gl/gl-debug.cpp display/gl/gl-fun.cpp display/gl/gl-meta.cpp \
  display/gl/glstate.cpp display/gl/scene.cpp display/gl/shader.cpp \
  display/gl/texpool.cpp display/gl/tileatlas.cpp display/gl/tileatlasvx.cpp \
  display/gl/tilequad.cpp display/gl/vertex.cpp \
  util/iniconfig.cpp util/win-consoleutils.cpp \
  etc/etc.cpp etc/table.cpp \
  filesystem/filesystem.cpp filesystem/filesystemImpl.cpp \
  input/input.cpp input/keybindings.cpp \
  net/LUrlParser.cpp net/net.cpp \
  system/systemImpl.cpp

SRC_C := theoraplay/theoraplay.c display/libnsgif/libnsgif.c display/libnsgif/lzw.c

SRC_BIND := binding-mri.cpp binding-util.cpp table-binding.cpp etc-binding.cpp \
  bitmap-binding.cpp font-binding.cpp graphics-binding.cpp input-binding.cpp \
  sprite-binding.cpp viewport-binding.cpp plane-binding.cpp window-binding.cpp \
  tilemap-binding.cpp audio-binding.cpp module_rpg.cpp filesystem-binding.cpp \
  windowvx-binding.cpp tilemapvx-binding.cpp http-binding.cpp

CPPSRC := $(addprefix $(MKXPZ)/src/,$(SRC_MAIN)) $(addprefix $(MKXPZ)/binding/,$(SRC_BIND))
CSRC   := $(addprefix $(MKXPZ)/src/,$(SRC_C))
# codigo propio del port (backend de Switch)
CPPSRC += $(wildcard $(CURDIR)/nx/*.cpp)
CSRC   += $(wildcard $(CURDIR)/nx/*.c)

OBJS := $(addprefix $(BUILD)/,$(notdir $(CPPSRC:.cpp=.o)) $(notdir $(CSRC:.c=.o)))
VPATH := $(sort $(dir $(CPPSRC) $(CSRC)))

#-------------------------------------------------------------------------------
# Includes
#-------------------------------------------------------------------------------
MKXPZ_INC := . audio crypto display display/gl display/libnsgif \
             display/libnsgif/utils etc filesystem filesystem/ghc input net \
             system util util/sigslot util/sigslot/adapter
INCLUDE := $(addprefix -I$(MKXPZ)/src/,$(MKXPZ_INC)) \
           -I$(MKXPZ)/binding \
           -I$(CURDIR)/generated -I$(CURDIR)/nx \
           -I$(NXPREFIX)/include -I$(NXPREFIX)/include/SDL2 \
           -I$(MKXPZ)            -I$(NXPREFIX)/include/pixman-1            -I$(PORTLIBS)/include -I$(PORTLIBS)/include/SDL2            -I$(PORTLIBS)/include/AL \
           -I$(PORTLIBS)/include/freetype2 \
           -I$(LIBNX)/include \
           -IC:/anilswitch/patches/include

#-------------------------------------------------------------------------------
# Defines equivalentes a los que inyecta meson
#-------------------------------------------------------------------------------
DEFINES := -D__SWITCH__ -DMKXPZ_BUILD_MESON -DMKXPZ_VERSION=\"2.4.2\" \
           -DHAVE_NANOSLEEP -DMKXPZ_INIT_GL_LATER \
           -DGLES2_HEADER \
           -DMKXPZ_ALCDEVICE=ALCdevice \
           -DAL_LIBTYPE_STATIC \
           -DWORKDIR_CURRENT
# GLES2_HEADER    -> backend GLES en vez de GL de escritorio (gfx_backend=gles)
# MKXPZ_ALCDEVICE -> openal-soft 1.21.1 de portlibs usa `ALCdevice` (>=1.20.1)
# AL_LIBTYPE_STATIC -> enlace estatico de OpenAL
# WORKDIR_CURRENT -> el juego se busca en el directorio de trabajo actual

ARCH   := -march=armv8-a+crc+crypto -mtune=cortex-a57 -mtp=soft -fPIE
WARN   := -Wall -Wno-non-virtual-dtor -Wno-reorder -Wno-uninitialized \
          -Wno-unknown-pragmas -Wno-stringop-truncation -Wno-unused-variable \
          -Wno-unused-but-set-variable -Wno-deprecated-declarations
CFLAGS   := -g -O2 $(ARCH) $(WARN) $(DEFINES) $(INCLUDE) -ffunction-sections -fdata-sections \
            -fno-omit-frame-pointer
CXXFLAGS := $(CFLAGS) -std=gnu++14 -fexceptions -frtti

LIBDIRS  := -L$(NXPREFIX)/lib -L$(PORTLIBS)/lib -L$(LIBNX)/lib
LIBS     := -lruby-static -lnxcompat \
            -lSDL2_sound -lSDL2_ttf -lSDL2_image -lSDL2 \
            -lphysfs -lopenal \
            -ltheoradec -ltheora -lvorbisfile -lvorbis -logg \
            -lmpg123 -lmodplug \
            -lpixman-1 -luchardet -lfreetype -lharfbuzz -lfreetype \
            -lpng16 -ljpeg -lwebp -lz -lbz2 -liconv -lcharset \
            -lEGL -lglapi -ldrm_nouveau \
            -lnx -lm -lstdc++
# --wrap=fcntl: libnx solo implementa fcntl para sockets y devuelve ENOTSOCK
# para los ficheros, lo que rompe require() en Ruby. Ver nx/nx_fcntl.c.
# --wrap=realpath: newlib reintroduce el prefijo de dispositivo. Ver §5.34.
# --wrap=pipe/poll/select: Horizon no tiene tuberias y poll/select pertenecen a
# la capa de sockets de libnx. Ver nx/nx_pipe.c y §5.41.
LDFLAGS  := -specs=$(LIBNX)/switch.specs -g $(ARCH) -Wl,--gc-sections \
            -Wl,--wrap=fcntl -Wl,--wrap=realpath \
            -Wl,--wrap=pipe -Wl,--wrap=poll -Wl,--wrap=select \
            -Wl,--wrap=diagAbortWithResult -Wl,--wrap=fatalThrow $(LIBDIRS)

.PHONY: all clean dirs
all: dirs $(TARGET).nro

dirs:
	@mkdir -p $(BUILD) $(TMPDIR)

$(BUILD)/%.o: %.cpp
	@echo "CXX  $(notdir $<)"
	@$(CXX) $(CXXFLAGS) -MMD -MP -c $< -o $@

$(BUILD)/%.o: %.c
	@echo "CC   $(notdir $<)"
	@$(CC) $(CFLAGS) -MMD -MP -c $< -o $@

$(TARGET).elf: $(OBJS)
	@echo "LD   $@"
	@$(CXX) $(LDFLAGS) $(OBJS) $(LIBS) -o $@
	@echo "ARM  $@"
	@python C:/anilswitch/fixup-arm64.py $@

# El NRO necesita su seccion ASET (icono + NACP). Es la unica diferencia
# estructural que habia con el hello-ruby-nx de H2, que si carga: alli el
# campo `size` de la cabecera era MENOR que el fichero porque llevaba el ASET
# detras; el nuestro salia sin el.
APP_TITLE   := Pokemon Anil 4.0
APP_AUTHOR  := Port a Nintendo Switch
APP_VERSION := 4.0
APP_ICON    := $(LIBNX)/default_icon.jpg

$(TARGET).nacp:
	@echo "NACP $@"
	@$(DEVKITPRO)/tools/bin/nacptool --create "$(APP_TITLE)" "$(APP_AUTHOR)" "$(APP_VERSION)" $@

$(TARGET).nro: $(TARGET).elf $(TARGET).nacp
	@echo "NRO  $@"
	@$(DEVKITPRO)/tools/bin/elf2nro $< $@ --icon=$(APP_ICON) --nacp=$(TARGET).nacp

clean:
	@rm -rf $(BUILD) $(TARGET).elf $(TARGET).nro

-include $(BUILD)/*.d
