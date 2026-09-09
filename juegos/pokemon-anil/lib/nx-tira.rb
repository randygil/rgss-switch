# nx-tira.rb — no volver a fabricar la tira de animacion del mismo Pokemon.
#
# Medido en la consola, un cambio de pestana en la vista de datos:
#
#   marco 594 ms | nue 238x | blt 264x | tira 252x | 84.000 objetos de Ruby
#
# Y leido el codigo, de donde sale: drawPage llama a setPokemonBitmap, que en
# el nucleo hace @_iconbitmap.dispose y pide un bitmap nuevo. Con [DBK] Animated
# Pokemon System instalado, ese bitmap nuevo es un DeluxeBitmapWrapper cuyo
# constructor RECORTA la hoja de sprites en sus ~120 fotogramas (un Bitmap.new
# y un stretch_blt por fotograma), y acto seguido sprite_bitmap_from_pokemon
# llama a compile_strip, que tira ese recorte y lo vuelve a hacer entero para
# aplicar las manchas de Spinda. Dos recortes: 240 bitmaps. Y antes, el dispose
# de los 120 del recorte anterior. Ese es exactamente el 238 / 264 / 252.
#
# Todo eso para volver a ensenar el MISMO Pokemon, en la MISMA pose, porque el
# jugador ha pulsado derecha para ver otra pestana de texto.
#
# La memoria es por sprite y la clave es lo que determina los pixeles de la
# tira: el fichero de la hoja (que ya lleva especie, forma, sexo, shiny,
# sombra, huevo y frente/espalda), el hue de super shiny si lo hay, y el ID
# personal, porque las manchas de Spinda son de cada individuo. Si la clave no
# cambia, la tira no cambia, y se reutiliza.
#
# Lo que si hay que repetir en un acierto es lo barato que hacia el camino
# normal: apuntar al Pokemon, recalcular la velocidad de animacion segun su
# estado, el gris de debilitado, el color, el origen y la colocacion. Y hay dos
# trampas que el camino normal no tenia porque partia siempre de un wrapper
# recien hecho:
#
#   - setPokemon aplica hue_change sin comprobar si ya se aplico; sobre una
#     tira reutilizada la tenniria dos veces. No se vuelve a llamar.
#   - pbSetDisplay ACUMULA en constrict_x/constrict_y (+=). Se ponen a cero
#     antes de volver a llamarlo, que es el estado de un wrapper nuevo.
#
# Se engancha por fuera de la reapertura de [DBK], asi que se instala tarde,
# cuando PokemonSprite ya responde a pbSetDisplay.

module NXTira
  @instalado = false
  @aciertos = 0
  @fallos = 0

  class << self
    attr_reader :instalado

    def anota(acierto)
      acierto ? @aciertos += 1 : @fallos += 1
      NX.log("[tira] aciertos #{@aciertos} fallos #{@fallos}") if (@aciertos + @fallos) % 10 == 1
    end

    def clave(pokemon, back)
      return nil unless pokemon.is_a?(Pokemon)
      fichero = GameData::Species.sprite_filename(
        pokemon.species, pokemon.form, pokemon.gender, pokemon.shiny?,
        pokemon.shadowPokemon?, back, pokemon.egg?)
      hue = (pokemon.respond_to?(:super_shiny?) && pokemon.super_shiny?) ? pokemon.super_shiny_hue : nil
      [fichero, back ? 1 : 0, pokemon.personalID, hue]
    rescue StandardError
      nil
    end

    def instala
      return true if @instalado
      return false unless Object.const_defined?(:PokemonSprite) &&
                          PokemonSprite.method_defined?(:pbSetDisplay) &&
                          Object.const_defined?(:DeluxeBitmapWrapper)
      @instalado = true

      PokemonSprite.class_eval do
        alias_method :nx_setPokemonBitmap_sin_memoria, :setPokemonBitmap

        def setPokemonBitmap(pokemon, back = false)
          clave = NXTira.clave(pokemon, back)
          tira = @_iconbitmap
          if clave && clave == @nx_clave_tira && tira.is_a?(DeluxeBitmapWrapper) &&
             !tira.disposed? && !self.disposed?
            NXTira.anota(true)
            @pkmn = pokemon
            tira.instance_variable_set(:@pokemon, pokemon)
            tira.update_pokemon_sprite
            self.bitmap = tira.bitmap
            self.color = Color.new(0, 0, 0, 0)
            self.make_grey_if_fainted = pokemon.perma_faint
            changeOrigin
            if tira.respond_to?(:constrict_x=)
              tira.constrict_x = 0
              tira.constrict_y = 0
              tira.constrict_w = nil
              tira.constrict_h = nil
            end
            pbSetDisplay
            return
          end
          NXTira.anota(false)
          nx_setPokemonBitmap_sin_memoria(pokemon, back)
          @nx_clave_tira = clave
        end
      end

      NX.log("[tira] memoria de tiras de animacion puesta")
      true
    end
  end
end

module Graphics
  class << self
    alias_method :nx_update_sin_tira, :update

    def update
      NXTira.instala unless NXTira.instalado
      nx_update_sin_tira
    end
  end
end

NX.log("[tira] a la espera de PokemonSprite con [DBK]")
