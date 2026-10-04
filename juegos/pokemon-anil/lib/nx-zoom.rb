# nx-zoom.rb — Map Zoom sin una textura muerta por fotograma.
#
# El plugin Map Zoom acerca la camara haciendo una foto de la pantalla y
# escalandola. Mientras el zoom esta puesto -lo que dure la escena, y no se
# quita hasta que el evento lo devuelve a 1-, ZoomMap#update hace en CADA
# fotograma
#
#   @sprites["map"].bitmap.clear
#   @sprites["map"].bitmap = Graphics.snap_to_bitmap
#
# y el Bitmap de antes se queda sin nadie que lo use y sin disponer. Son 512x384
# a cuatro bytes, 768 KB de textura por fotograma, 46 MB/s, que solo vuelven
# cuando el recolector de Ruby recoge esos objetos. En la consola eso acabo con
# una partida de dos horas: "No hay memoria de video para una textura de
# 512x384" en Map Zoom.rb:31 (bitacora §5.76).
#
# El arreglo de fondo esta en el motor: el recolector ya sabe cuanta memoria de
# video tiene cada Bitmap y pasa cuando se acumula (texpool.cpp). Esto es lo
# que le toca al juego: devolver la textura en el momento en que deja de
# servir, en vez de esperar a la pasada. Despues del update original, si el
# sprite tiene otro Bitmap, el viejo se dispone; la textura vuelve al fondo y la
# foto del fotograma siguiente sale de ahi como acierto, sin pedir nada nuevo
# al driver. Lo mismo con la ultima foto al quitar el zoom.
#
# ZoomMap la define el plugin despues del preload, asi que se instala tarde, la
# primera vez que existe. En un juego sin Map Zoom no hace nada.

module NXZoom
  @instalado = false

  class << self
    attr_reader :instalado

    # El Bitmap que el sprite del zoom ensena ahora, o nil.
    def foto(zoom)
      sprites = zoom.instance_variable_get(:@sprites)
      return nil unless sprites.is_a?(Hash)
      sprite = sprites["map"]
      return nil if sprite.nil? || sprite.disposed?
      sprite.bitmap
    rescue StandardError
      nil
    end

    def suelta(bitmap)
      bitmap.dispose if bitmap && !bitmap.disposed?
    rescue StandardError
      nil
    end

    def instala
      return true if @instalado
      return false unless Object.const_defined?(:ZoomMap) &&
                          ZoomMap.method_defined?(:update) &&
                          ZoomMap.method_defined?(:dispose)
      @instalado = true

      ZoomMap.class_eval do
        alias_method :nx_update_sin_soltar, :update
        alias_method :nx_dispose_sin_soltar, :dispose

        def update
          vieja = NXZoom.foto(self)
          r = nx_update_sin_soltar
          # Solo si el sprite ya tiene otra: si el update no ha hecho foto
          # (o ha dispuesto el zoom) la de antes sigue siendo la que se ve, o
          # ya no la ve nadie y la recogera dispose.
          nueva = NXZoom.foto(self)
          NXZoom.suelta(vieja) if vieja && nueva && !nueva.equal?(vieja)
          r
        end

        def dispose
          vieja = NXZoom.foto(self)
          r = nx_dispose_sin_soltar
          NXZoom.suelta(vieja)
          r
        end
      end

      NX.log("[zoom] Map Zoom devuelve la foto de cada fotograma")
      true
    end
  end
end

module Graphics
  class << self
    alias_method :nx_update_sin_zoom, :update

    def update(*a)
      NXZoom.instala unless NXZoom.instalado
      nx_update_sin_zoom(*a)
    end
  end
end
