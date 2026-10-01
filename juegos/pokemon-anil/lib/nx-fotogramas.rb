# nx-fotogramas.rb — los fotogramas de un Pokemon animado, cuando se ensenan.
#
# En la consola, los tirones de los menus llevan siempre la misma firma: cientos
# de texturas nuevas en un fotograma.
#
#   [tiron] marco 1338 ms | ... | pool 1621x 660 ms | nue 2941x 653 ms | blt 2985x 45 ms
#
# Y en el PC, el banco de menus (tmp/pc-anil/perfil-menus.rb) dice de donde
# salen: al cambiar de especie en la Pokedex,
#
#   pbUpdateDummyPokemon 1x/99ms  DeluxeBitmapWrapper#refresh 3x/68ms  Bmp.new(wxh) 276x/46ms
#
# Es [DBK] Animated Pokemon System. DeluxeBitmapWrapper#refresh recibe la hoja
# del Pokemon (todos los fotogramas en fila) y la RECORTA ENTERA en el momento:
# un Bitmap.new y un stretch_blt por fotograma, cien y pico por Pokemon, cada
# uno una textura. En la Pokedex son tres a la vez (el de la entrada y el de
# frente y espalda de la pagina de formas); en el equipo y el resumen, uno por
# Pokemon; y en cada cambio, los cien anteriores se tiran. Una textura nueva en
# la consola cuesta 0,2-0,4 ms entre el fondo de texturas y el driver, y el
# fondo acierta un 30 % (§5.70-bis), asi que cien fotogramas son decenas de
# milisegundos por sprite, todos en el mismo fotograma, para enseñar uno.
#
# Aqui la hoja se guarda y cada fotograma se recorta la primera vez que se
# pide: el que se ensena al abrir la pantalla cuesta una textura, y los demas
# van llegando de uno en uno mientras la animacion avanza, repartidos en
# fotogramas distintos. Cuando ya se han recortado todos, la hoja se suelta, y
# la memoria queda como la dejaba el original.
#
# compile_strip, que sprite_bitmap_from_pokemon y setSummaryBitmap llaman
# SIEMPRE despues de crear el wrapper, rehace el recorte entero para poder
# pintar las manchas de Spinda. Para un Pokemon sin funcion "alterBitmap" ese
# segundo recorte da exactamente los mismos pixeles que el primero (mismo
# rectangulo de origen, misma escala), asi que se omite; con Spinda, o con
# cualquier especie que la tenga, se hace el original.
#
# Lo que se respeta del contrato de la clase: hue_change se aplica a lo ya
# recortado y se recuerda para lo que se recorte despues; copy, bitmap y
# dispose saben que hay huecos; disposed? sigue siendo "no quedan
# fotogramas", y las hojas GIF (animated?) siguen el camino de siempre.

module NXFotogramas
  @instalado = false
  @recortes = 0
  @ahorrados = 0

  class << self
    attr_reader :instalado

    def anota(recortados, total)
      @recortes += recortados
      @ahorrados += total - recortados
    end

    def instala
      return true if @instalado
      return false unless Object.const_defined?(:DeluxeBitmapWrapper) &&
                          DeluxeBitmapWrapper.method_defined?(:compile_strip) &&
                          DeluxeBitmapWrapper.method_defined?(:refresh)
      @instalado = true

      DeluxeBitmapWrapper.class_eval do
        alias_method :nx_refresh_entero, :refresh
        alias_method :nx_compile_strip_entero, :compile_strip
        alias_method :nx_dispose_entero, :dispose
        alias_method :nx_hue_change_entero, :hue_change

        def refresh(bitmaps = nil)
          return nx_refresh_entero(bitmaps) unless bitmaps.nil? && @bmp_file.is_a?(String)
          self.dispose
          hoja = Bitmap.new(@bmp_file)
          if hoja.animated? || hoja.width <= hoja.height * 2
            # GIF o imagen de un solo fotograma: nada que ahorrar.
            hoja.dispose
            return nx_refresh_entero(nil)
          end
          @width = hoja.height * @scale
          @height = hoja.height * @scale
          n = (hoja.width.to_f / hoja.height).ceil
          @nx_hoja = hoja
          @nx_lado = hoja.height
          @nx_hues = []
          @nx_hechos = 0
          @bitmaps = Array.new(n)
          @total_frames = n
          @temp_bmp = Bitmap.new(@width, @width)
        end

        def nx_fotograma(i)
          b = @bitmaps[i]
          return b if b || @nx_hoja.nil?
          b = Bitmap.new(@width, @height)
          b.stretch_blt(Rect.new(0, 0, @width, @height), @nx_hoja,
                        Rect.new(i * @nx_lado, 0, @nx_lado, @nx_lado))
          @nx_hues.each { |h| b.hue_change(h) }
          @bitmaps[i] = b
          @nx_hechos += 1
          if @nx_hechos >= @total_frames
            @nx_hoja.dispose
            @nx_hoja = nil
            NXFotogramas.anota(@total_frames, @total_frames)
          end
          b
        end

        def compile_strip(pkmn = nil, back = false)
          if @nx_hoja && !(pkmn && MultipleForms.hasFunction?(pkmn.species, "alterBitmap"))
            # Mismos pixeles que el recorte que ya hay: solo el efecto lateral.
            $game_temp.spinda_spots = nil if $game_temp
            return
          end
          nx_compile_strip_entero(pkmn, back)
        end

        def bitmap
          return @bmp_file if self.is_bitmap? && !@bmp_file.disposed?
          return nil if self.disposed?
          nx_fotograma(@frame_idx) if @nx_hoja
          x, y, w, h = self.box
          @temp_bmp.clear
          @temp_bmp.blt(x, y, @bitmaps[@frame_idx], Rect.new(x, y, w, h))
          return @temp_bmp
        end

        def copy
          nx_fotograma(@frame_idx) if @nx_hoja
          return @bitmaps[@frame_idx].clone
        end

        def hue_change(value)
          @nx_hues << value if @nx_hoja
          @bitmaps.each { |bmp| bmp&.hue_change(value) }
          @changed_hue = true
        end

        def dispose
          if @nx_hoja
            NXFotogramas.anota(@nx_hechos || 0, @total_frames)
            @nx_hoja.dispose
            @nx_hoja = nil
          end
          @bitmaps.each { |bmp| bmp&.dispose }
          @bitmaps.clear
          @temp_bmp.dispose if @temp_bmp && !@temp_bmp.disposed?
        end
      end

      NX.log("[fotogramas] DeluxeBitmapWrapper recorta cada fotograma al ensenarlo")
      true
    end

    def informe
      "[fotogramas] recortados #{@recortes}, ahorrados #{@ahorrados}"
    end
  end
end

module Graphics
  class << self
    alias_method :nx_update_sin_fotogramas, :update

    def update
      NXFotogramas.instala unless NXFotogramas.instalado
      nx_update_sin_fotogramas
    end
  end
end

NX.log("[fotogramas] a la espera de [DBK] Animated Pokemon System")
