# nx-reborn.rb — lo que Reborn le pide a un mkxp-z que no es el nuestro.
#
# El Game.exe de Reborn 19.5.0 no es mkxp-z 2.4.2 de serie: lleva dentro las
# modificaciones de Splendide Imaginarius (docs/censo-juegos.md). Una de ellas
# es la directiva "patches" del mkxp.json -una superposicion de ficheros para
# los mods- y con ella viene System.file_exist?, que consulta esa superposicion
# ademas del juego base. En src/mkxp-z/binding/binding-mri.cpp de 2.4.2 ese
# metodo NO EXISTE.
#
# Y no es un adorno: Scripts/ScriptLoader.rb define
#
#     def fileExists?(file)
#       return System.file_exist?(file) unless $joiplay
#
# y fileExists? es lo que usa RTP.rb para resolver CADA imagen y cada sonido, y
# Cache.rb para decidir si tiene que recompilar Data/mons.dat, Data/moves.dat y
# otros diez ficheros. Sin el, el juego no encuentra un solo grafico y ademas
# cree que no tiene datos compilados.
#
# La sustitucion es FileTest.exist?, que en este motor ya contesta tambien por
# el contenedor: nx/nx_ficheros.cpp lo engancha al arrancar y lo deja dicho en
# mkxp-boot.log ("[fs] FileTest.exist? contesta tambien por el contenedor",
# README 5.62). Lo unico que se pierde es la superposicion de patch/, que en
# esta version del juego viene VACIA; los mods del jugador no funcionarian, y
# eso esta apuntado como deuda en el perfil.
#
# Se define solo si falta, para que el dia que el motor traiga el suyo propio
# este shim se aparte solo.

module System
  unless respond_to?(:file_exist?)
    def self.file_exist?(ruta)
      FileTest.exist?(ruta)
    end
    NX.log("[reborn] System.file_exist? -> FileTest.exist? " \
           "(mkxp-z 2.4.2 no lo trae; sin superposicion de patch/)")
  else
    NX.log("[reborn] System.file_exist? ya lo trae el motor")
  end
end

# ---------------------------------------------------------------------------
# El teclado, otra vez, y en Reborn no vale el shim generico.
#
# runtime/lib/nx-teclado.rb resuelve el callejon sin salida del nombre haciendo
# que PokemonEntryScene (la del teclado fisico) sea PokemonEntryScene2 (la
# rejilla con cursor). Reborn es Essentials v19 y ahi todavia NO HAY DOS CLASES:
# hay una sola, Scripts/TextEntry.rb:813, que decide dentro:
#
#     if $Settings.useKeyboard?
#       @sprites["entry"] = Window_TextEntry_Keyboard.new(...)
#     else
#       @sprites["entry"] = Window_TextEntry.new(...)
#
# y su pbEntry hace lo mismo: `return $Settings.useKeyboard? ? pbEntry1 : pbEntry2`.
# El shim generico se calla porque pregunta por PokemonEntryScene2 y no existe.
#
# useKeyboard? es `$Settings.keyboard == 0` y Options.rb:286 pone ese ajuste a 0
# de fabrica -"0 is on"-, o sea que Reborn arranca pidiendo teclado. En una
# consola eso es la partida que no puede empezar.
#
# Se cambia el METODO y no el ajuste: $Settings sale de una partida guardada
# (ClientData.rb:40 lo lee con Marshal.load), asi que tocar el numero solo valdria
# para las partidas nuevas y ademas se lo llevaria el guardado. Con el metodo, la
# rejilla sale siempre y el jugador conserva su fichero de opciones tal cual.
#
# Como la clase no existe en el preload -los scripts se cargan despues-, se
# instala tarde, enganchado a Graphics.update, que es el patron de nx-teclado.rb.

module NXRebornTeclado
  @hecho = false
  class << self
    attr_accessor :hecho
  end

  def self.revisar
    return unless defined?(PokemonOptions)
    return unless PokemonOptions.method_defined?(:useKeyboard?)

    @hecho = true
    PokemonOptions.send(:define_method, :useKeyboard?) { false }
    NX.log("[reborn] PokemonOptions#useKeyboard? -> false (en una Switch no hay teclado)")
  rescue Exception => e
    @hecho = true
    NX.log("[reborn] FALLO al quitar el teclado: #{e.class}: #{e.message}")
  end
end

module Graphics
  class << self
    alias_method :nx_update_sin_teclado_reborn, :update

    def update
      NXRebornTeclado.revisar unless NXRebornTeclado.hecho
      nx_update_sin_teclado_reborn
    end
  end
end

# ---------------------------------------------------------------------------
# Input::D, Input::E e Input::F: tres botones que este mkxp-z no tiene.
#
# El mkxp.json de Reborn declara ONCE botones en bindingNames -los ocho de
# siempre mas d, e y f- porque su Game.exe es el mkxp-z de Splendide
# Imaginarius, que anadio esos tres. mkxp-z 2.4.2 solo conoce ocho
# (src/input/input.h, enum ButtonCode), asi que las constantes no existen y el
# juego se para en el primer fotograma del video de introduccion:
#
#   System:88:in `update': uninitialized constant Input::E (NameError)
#   EventScene:705 -> Scene_Intro:19 -> Main:38
#
# Los tres sitios que las usan son accesorios: System.rb:88 el turbo,
# System.rb:94 el silencio y Walk_Run.rb:32 correr con el gatillo. Ninguno hace
# falta para jugar, y en una consola no hay tecla que asignarles.
#
# Los numeros son 50, 51 y 52 a proposito: estan FUERA del mapa de botones de
# mkxp-z, y su getStateCheck (input.cpp:796) recorta cualquier codigo fuera de
# rango al estado 0 -None-, que nunca esta pulsado. O sea que Input.trigger? con
# estos tres contesta false siempre y no puede salirse de ningun array. No se
# reutiliza un boton real porque entonces el turbo o el silencio se dispararian
# solos al pulsar el que fuera.
module Input
  D = 50 unless const_defined?(:D)
  E = 51 unless const_defined?(:E)
  F = 52 unless const_defined?(:F)
end
NX.log("[reborn] Input::D/E/F definidos fuera del mapa de botones (turbo, silencio y correr con gatillo, apagados)")

# ---------------------------------------------------------------------------
# TilemapUtils.updateAutoTiles, otra cosa del mkxp-z de Splendide.
#
#   Scene_Map:45:in `updateSpritesets': uninitialized constant Scene_Map::TilemapUtils
#
# Aparece UNA vez en los 193 scripts, en Scene_Map.rb:45:
#
#   TilemapUtils.updateAutoTiles unless $joiplay
#
# y se llama en cada fotograma del mapa, asi que sin ella no se ve un solo mapa.
# En el mkxp-z de ese fork es quien hace avanzar la animacion de los autotiles
# (el agua, la hierba alta) desde Ruby; en mkxp-z 2.4.2 esa animacion la lleva
# el propio Tilemap por dentro, con su contador de fotogramas, y no hay nada que
# empujar desde aqui. De ahi que esto sea un metodo vacio y no una
# reimplementacion: no falta trabajo, falta la firma.
#
# Si algun dia se ve el agua quieta en este juego, mirar aqui primero.
module TilemapUtils
  def self.updateAutoTiles(*)
    nil
  end
end
NX.log("[reborn] TilemapUtils.updateAutoTiles vacio (en mkxp-z 2.4.2 los autotiles se animan solos)")

# ---------------------------------------------------------------------------
# Audio.se_play_position: sonido posicional, que este motor no tiene.
#
#   Audio:522:in `internal_se_play': undefined method `se_play_position'
#   for Audio:Module (NoMethodError)
#
# Scripts/Audio.rb:521 dice
#
#   Audio.se_play(name, volume, pitch)  si es JoiPlay
#   Audio.se_play_position(name, volume, pitch, x, y, z)  si no
#
# o sea que TODO efecto de sonido del juego pasa por aqui: el primer pitido de
# un cuadro de texto en el mapa de introduccion ya se lleva la partida por
# delante. Los tres ultimos argumentos son la posicion en el mapa de lo que
# suena, para repartirlo entre los altavoces; mkxp-z 2.4.2 solo tiene el
# se_play de RGSS, sin panoramica.
#
# Se tira la posicion y se reproduce el sonido. Perder de que lado suena una
# puerta es infinitamente mejor que quedarse sin sonido -y sin partida-, y el
# dia que el motor tenga panoramica esto se cambia en un sitio.
if defined?(Audio) && !Audio.respond_to?(:se_play_position)
  module Audio
    def self.se_play_position(nombre, volumen = 100, tono = 100, x = 0, y = 0, z = 0)
      se_play(nombre, volumen, tono)
    end
  end
  NX.log("[reborn] Audio.se_play_position -> se_play sin panoramica")
end
