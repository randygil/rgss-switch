# nx-cache-gc.rb — cambiar de mapa sin parar el juego a recoger basura.
#
# Scene_Map#transfer_player de Essentials (y de RPG Maker XP) llama a
# RPG::Cache.clear entre tirar los spritesets del mapa viejo y crear los del
# nuevo. El RPG::Cache.clear que trae mkxp-z (binding/module_rpg1.rb) es
#
#     def self.clear
#       @cache = {}
#       GC.start
#     end
#
# y GC.start sin argumentos es la pasada MAYOR más cara que tiene Ruby: marca
# todo lo vivo de una tirada (immediate_mark) y barre el montón entero en el
# acto (immediate_sweep). En el PC son 40 ms y no se notan; en Ryujinx, 250 de
# los 320 ms de Ruby que cuesta entrar en el Centro Pokémon de Ciudad Carmín
# con la partida del jugador; en la consola, la mayor parte del medio segundo
# a cinco segundos que el jugador ve congelado al entrar o salir de una casa.
# Y crece con la sesión, porque lo que cuesta una pasada mayor es lo que hay
# vivo, y la generación vieja engorda con las horas (456.000 objetos viejos al
# empezar, 618.000 horas después, en el registro de la consola). Bitácora §5.77.
#
# El arreglo deja la pasada en MENOR, con barrido perezoso: recorre sólo lo
# joven y lo que la barrera de escritura apuntó, y barre página a página según
# se pide memoria, como las pasadas que Ruby decide por su cuenta. El caché
# queda vacío igual que antes (@cache = {}), y lo que el mapa viejo deja de
# usar se recoge igual: lo joven en esta misma pasada, lo viejo en la próxima
# mayor que Ruby haga cuando le toque (por generación vieja o por oldmalloc,
# que desde §5.76 cuenta también las texturas). Medido en Ryujinx, 40 idas y
# vueltas: ninguna pasada mayor dentro de un traslado, y 9 MB más de Bitmap a
# la espera de recogerse (55 frente a 46).
#
# No vale la pasada mayor INCREMENTAL (immediate_mark: false): en Ruby 3.1 el
# marcado incremental sólo avanza cuando se agotan las páginas libres, con un
# montón holgado se queda a medias durante cientos de fotogramas pagando la
# barrera de escritura, y el siguiente GC.start lo termina de golpe (gc_rest):
# medido en el PC, el traslado a Carmín pasa de 150 a 240 ms.
#
# Va en preloadScript, antes que los scripts del juego: lo único que puede
# reemplazar aquí es el de mkxp-z. Si un juego trae su propio
# RPG::Cache.clear, lo define DESPUÉS y manda el suyo, como debe.
# `nx-sin-cache-gc.txt` en la carpeta del juego lo apaga, para medir.

if !defined?(RPG::Cache) || !RPG::Cache.respond_to?(:clear)
  NX.log("[cache-gc] este motor no trae RPG::Cache.clear: nada que hacer") if defined?(NX)
elsif File.exist?("nx-sin-cache-gc.txt")
  NX.log("[cache-gc] apagado por nx-sin-cache-gc.txt") if defined?(NX)
else
  module RPG
    module Cache
      class << self
        def clear
          @cache = {}
          GC.start(full_mark: false, immediate_sweep: false)
        end
      end
    end
  end
  NX.log("[cache-gc] RPG::Cache.clear recoge sin parar el juego") if defined?(NX)
end
