# nx-eventos-lejos.rb — los eventos quietos que no se ven dejan de costar.
#
# Essentials v21 ya lo intenta: Game_Event#should_update? dice que no a los
# eventos que quedan a más de dos casillas fuera de la pantalla, y entonces ni
# el evento (Game_Event#update) ni su sprite (Sprite_Character#update) hacen
# nada en ese fotograma. Pero la primera pregunta que hace es
#
#     return true if @updated_last_frame
#
# y update pone @updated_last_frame = true cada vez que actualiza. O sea que un
# evento que se ha actualizado una vez se actualiza ya siempre, esté donde
# esté, y como al cargar el mapa todos se actualizan una vez (moveto), el
# recorte no recorta nunca. Medido con runtime/diagnostico/nx-mapa.rb andando
# por Pueblo Paleta, en el PC y en Ryujinx igual:
#
#     50 eventos (50 actualizados, 5 en pantalla)
#
# El arreglo NO es quitar esa línea a pelo, porque entonces dejarían de
# actualizarse fuera de pantalla también los PNJ que pasean y los Pokémon de
# VOE, y eso cambia el juego respecto al del PC, que se probó con el fallo. Se
# recortan sólo los eventos QUIETOS: tipo de movimiento fijo, sin ruta forzada,
# sin moverse ni saltar, sin esperar, sin intérprete en marcha, que no sean de
# inicio automático ni paralelos, que no se llamen "update" y que no tengan una
# página pendiente de refrescar (un interruptor que cambia fuera de pantalla
# puede convertir la página en una de inicio automático, y esa página tiene que
# llegar a verse). A un evento así, actualizarlo fuera de pantalla sólo le
# avanza la animación de un dibujo que nadie ve, y Essentials ya lo vuelve a
# poner al día con el margen de dos casillas antes de que entre.
#
# Y el recorte se hace POR FUERA de lo que los plugins cuelgan de los dos
# update. Recortar sólo dentro no bastaba, medido otra vez: con el recorte del
# propio Essentials funcionando, los plugins que envuelven Game_Event#update y
# Sprite_Character#update (en Añil, la Lente de la Verdad con tres expresiones
# regulares por evento, las huellas, las sombras de Overworld Shadows EX y las
# dinámicas, la escalada) seguían corriendo para los cincuenta, porque van
# antes de la vuelta temprana del original: de 1,72 ms de sprites por
# fotograma en Ryujinx sólo se fueron 0,6. Por eso esto se instala tarde, en el
# primer Graphics.update, cuando ya están todos los alias puestos, y queda por
# encima de todos.
#
# should_update? se reescribe entero sólo si es el de Essentials (definido en
# el mismo fichero que tsOn? y compañía); si un plugin lo ha cambiado, se
# envuelve el suyo y se le lleva la contraria únicamente en el caso pegajoso.

module NXEventosLejos
  @instalado = false

  class << self
    attr_reader :instalado

    def log(texto)
      NX.log(texto) if defined?(NX) && NX.respond_to?(:log)
    end

    def instala
      return true if @instalado
      return false unless defined?(Game_Event) && Game_Event.method_defined?(:should_update?)
      # Hasta que no haya escena no se han cargado los plugins: instalarse
      # antes dejaría sus alias por fuera de los nuestros.
      return false if $scene.nil?
      @instalado = true

      # Con refresh no basta: el plugin de arreglos de Añil lo redefine (y
      # update), y la comparación salía "envuelto" con el should_update? de
      # Essentials intacto. tsOn?, clear_starting y erase_route no los toca
      # nadie y viven en el mismo fichero que el original.
      origen = Game_Event.instance_method(:should_update?).source_location&.first
      propio = !origen.nil? && %i[tsOn? clear_starting erase_route].any? do |m|
        Game_Event.method_defined?(m) && Game_Event.instance_method(m).source_location&.first == origen
      end

      Game_Event.class_eval do
        alias_method :nx_should_update_original, :should_update?

        # El nombre no cambia: la expresión regular, una vez por evento.
        def nx_nombre_update?
          @nx_nombre_update = !!(@event && @event.name[/update/i]) if @nx_nombre_update.nil?
          @nx_nombre_update
        end

        def nx_quieto?
          return false if @move_type != 0 || @move_route_forcing || @moveto_happened
          return false if @need_refresh || @starting
          return false if @trigger == 3 || @trigger == 4
          return false if moving? || jumping?
          return false if @wait_count && @wait_count > 0
          return false if @interpreter && @interpreter.running?
          return false if nx_nombre_update?
          true
        end

        # La misma geometría que should_update? de Essentials: dos casillas de
        # margen alrededor de la pantalla, contando el tamaño del dibujo.
        def nx_fuera_de_pantalla?
          margen_x = 2 * Game_Map::TILE_WIDTH
          margen_y = 2 * Game_Map::TILE_HEIGHT
          ancho, alto = @sprite_size || [Game_Map::TILE_WIDTH, Game_Map::TILE_HEIGHT]
          sx = screen_x
          return true if sx - (ancho / 2) > Graphics.width + margen_x
          return true if sx + (ancho / 2) < -margen_x
          sy = screen_y_ground
          return true if sy - alto > Graphics.height + margen_y
          return true if sy < -margen_y
          false
        end
      end

      if propio
        Game_Event.class_eval do
          # El de Essentials, pregunta por pregunta, sin la línea pegajosa
          # para los quietos y con el nombre memorizado.
          def should_update?(recalc = false)
            return @to_update if !recalc
            return true if @nx_decidido
            return true if @trigger && (@trigger == 3 || @trigger == 4)
            return true if @move_route_forcing || @moveto_happened
            return true if nx_nombre_update?
            return true if @updated_last_frame && !nx_quieto?
            !nx_fuera_de_pantalla?
          end
        end
      else
        Game_Event.class_eval do
          def should_update?(recalc = false)
            return @to_update if !recalc
            return true if @nx_decidido
            return nx_should_update_original(true) if !@updated_last_frame
            return true if !nx_quieto?
            !nx_fuera_de_pantalla?
          end
        end
      end

      # Por fuera de todo lo colgado de Game_Event#update: se decide una vez y,
      # si no toca, no corre nada de la cadena. Si toca, la cadena entera corre
      # como siempre y su should_update?(true) contesta lo ya decidido.
      Game_Event.class_eval do
        alias_method :nx_update_cadena, :update

        def update
          unless should_update?(true)
            @to_update = false
            @updated_last_frame = false
            return
          end
          @nx_decidido = true
          begin
            nx_update_cadena
          ensure
            @nx_decidido = false
          end
        end
      end

      # Y por fuera de todo lo colgado de Sprite_Character#update.
      Sprite_Character.class_eval do
        alias_method :nx_update_cadena, :update

        def update
          ch = @character
          return if ch.is_a?(Game_Event) && !ch.should_update?
          nx_update_cadena
        end
      end

      log("[eventos] los quietos fuera de pantalla ya no se actualizan (should_update? #{propio ? 'reescrito' : 'envuelto'})")
      true
    end
  end
end

module Graphics
  class << self
    alias_method :nx_update_sin_eventos_lejos, :update

    def update(*a)
      NXEventosLejos.instala unless NXEventosLejos.instalado
      nx_update_sin_eventos_lejos(*a)
    end
  end
end
