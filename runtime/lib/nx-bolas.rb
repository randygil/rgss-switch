# nx-bolas.rb — que ChangelingSprite cargue sus imagenes cuando las ensena, no
# cuando se las anuncian.
#
# Abrir el equipo tarda mas de un segundo, y el cronometro por metodo lo reparte
# asi, por cada uno de los seis paneles:
#
#   Panel#initialize 1x/271ms   Panel#enhanced_initialize 1x/50ms
#
# Los 220 ms de diferencia son el plugin [Party UI]: en el constructor de cada
# panel recorre TODOS los objetos del juego (GameData::Item.each), y por cada
# Poke Ball que tiene grafico llama dos veces a @ballsprite.addBitmap, que carga
# la imagen en ese momento. Son unas sesenta imagenes por panel, seis paneles,
# y de las sesenta se va a ensenar UNA: la de la bola en la que viene ese
# Pokemon. Tambien es de ahi el "sub 77x 271 ms" del lado C++: setenta y siete
# subidas a la GPU de imagenes que nadie va a ver.
#
# En vez de tocar el plugin, se cambia ChangelingSprite, que es la clase base de
# Essentials para "un sprite con varias imagenes posibles": add_bitmap apunta
# la ruta pero no carga, y change_bitmap carga la primera vez que se pide esa
# ruta. El resto de la clase no necesita saberlo: update y dispose recorren
# @bitmaps con each_value, y una clave que no existe no se recorre. Lo unico que
# cambia de sitio es cuando se lanzaria el error de "fichero no encontrado";
# [Party UI] comprueba con pbResolveBitmap antes de anunciar, asi que ahi no
# cambia nada.

module NXBolas
  @instalado = false

  class << self
    attr_reader :instalado

    def instala
      return true if @instalado
      return false unless Object.const_defined?(:ChangelingSprite) &&
                          ChangelingSprite.method_defined?(:add_bitmap)
      @instalado = true

      ChangelingSprite.class_eval do
        def add_bitmap(mode, *data)
          if ![1, 5].include?(data.length)
            raise ArgumentError.new(_INTL("wrong number of arguments (given {1}, expected 2 or 6)", data.length + 1))
          end
          @changeling_data[mode] = (data[0].is_a?(Array) ? data[0].clone : [data[0]])
        end

        alias_method :nx_change_bitmap_sin_carga, :change_bitmap

        def change_bitmap(mode)
          datos = @changeling_data[mode]
          if mode && datos
            ruta = datos[0]
            @bitmaps[ruta] = AnimatedBitmap.new(ruta) if !@bitmaps[ruta]
          end
          nx_change_bitmap_sin_carga(mode)
        end
      end

      NX.log("[bolas] ChangelingSprite carga perezosa")
      true
    end
  end
end

module Graphics
  class << self
    alias_method :nx_update_sin_bolas, :update

    def update
      NXBolas.instala unless NXBolas.instalado
      nx_update_sin_bolas
    end
  end
end

NX.log("[bolas] a la espera de ChangelingSprite")
