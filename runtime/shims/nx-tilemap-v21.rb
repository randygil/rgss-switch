# nx-tilemap-v21.rb — el TilemapRenderer de Essentials v21, sin el trabajo que
# no se ve.
#
# Essentials v20/v21 ya no dibuja el mapa con el Tilemap del motor: lo dibuja
# en Ruby, con un Sprite por casilla y capa. A 512x384 son 17x13 casillas x 3
# capas = 663 sprites, y TilemapRenderer#update los recorre TODOS en cada
# fotograma: lee el dato del mapa, lo compara y, si la pantalla se ha movido
# aunque sea un pixel, les vuelve a poner x e y (y z si se ha movido en
# vertical). Andando, eso es la pantalla entera cada fotograma. Medido con
# runtime/diagnostico/nx-mapa.rb en Ryujinx, andando por Pueblo Paleta:
#
#     tilemap 2,2 ms por fotograma, de 6,3 ms de Ruby y 8,7 de CPU del hilo
#
# y en la consola, más. Es la fila más gorda del fotograma del mapa.
#
# Este update es el MISMO algoritmo, línea a línea, con tres cambios que no
# cambian nada de lo que se ve:
#
#   1. Las casillas vacías (sin bitmap: la capa 2 y 3 de casi todo el mapa)
#      no se recolocan. Un sprite invisible no se dibuja, y su sitio se vuelve
#      a calcular entero en refresh_tile el día que deja de estar vacío, que
#      es el único camino por el que puede dejar de estarlo.
#   2. Los bucles son while con índices en vez de each_with_index con bloques,
#      y las dos funciones de recolocar (refresh_tile_coordinates y
#      refresh_tile_z) van escritas dentro. Sólo se hace si siguen siendo las
#      del propio TilemapRenderer: si un plugin las ha cambiado, no se instala
#      nada y queda el original.
#   3. La tabla de casillas visitadas se reutiliza en vez de crearse dieciocho
#      Array nuevos por fotograma, y las casillas fuera de todo mapa que ya
#      están vacías no se vuelven a vaciar (set_bitmap crea un Rect cada vez).

module NXTilemapV21
  @instalado = false

  class << self
    attr_reader :instalado

    def propio?(k, m)
      k.instance_method(m).owner == k
    rescue NameError
      false
    end

    def instala
      return true if @instalado
      return false unless defined?(TilemapRenderer) && defined?(Game_Map)
      k = TilemapRenderer
      @instalado = true
      necesarios = %i[update refresh_tile refresh_tile_coordinates refresh_tile_z
                      refresh_tile_frame check_if_screen_moved]
      unless necesarios.all? { |m| propio?(k, m) } &&
             k.const_defined?(:DISPLAY_TILE_WIDTH) && k.const_defined?(:DISPLAY_TILE_HEIGHT) &&
             k.const_defined?(:SOURCE_TILE_HEIGHT) && k.const_defined?(:ZOOM_X)
        NX.log("[tilemap] TilemapRenderer no es el de v21: se deja el original") if defined?(NX) && NX.respond_to?(:log)
        return true
      end
      # Las tres que se escriben dentro tienen que venir del mismo fichero que
      # update: si alguien las ha redefinido en otro sitio, no son las de v21.
      origen = k.instance_method(:update).source_location&.first
      unless %i[refresh_tile_coordinates refresh_tile_z refresh_tile_frame].all? { |m| k.instance_method(m).source_location&.first == origen }
        NX.log("[tilemap] refresh_tile_* redefinidas por un plugin: se deja el original") if defined?(NX) && NX.respond_to?(:log)
        return true
      end

      k.class_eval do
        alias_method :nx_update_original, :update

        def update
          # Tono y color: igual que el original.
          if @old_tone != @tone
            @tiles.each do |col|
              col.each do |coord|
                coord.each { |tile| tile.tone = @tone }
              end
            end
            @old_tone = @tone.clone
          end
          if @old_color != @color
            @tiles.each do |col|
              col.each do |coord|
                coord.each { |tile| tile.color = @color }
              end
            end
            @old_color = @color.clone
          end
          @tilesets.update
          @autotiles.update
          do_full_refresh = @need_refresh
          if @viewport.ox != @old_viewport_ox || @viewport.oy != @old_viewport_oy
            @old_viewport_ox = @viewport.ox
            @old_viewport_oy = @viewport.oy
            do_full_refresh = true
          end
          @screen_moved = false
          @screen_moved_vertically = false
          if $PokemonGlobal.bridge != @bridge
            @bridge = $PokemonGlobal.bridge
            @screen_moved_vertically = true
          end
          do_full_refresh = true if check_if_screen_moved
          hcount = @tiles_horizontal_count
          vcount = @tiles_vertical_count
          visited = @nx_visitados
          if !visited || visited.length != hcount
            visited = @nx_visitados = Array.new(hcount) { Array.new(vcount, false) }
          else
            visited.each { |c| c.fill(false) }
          end
          moved = @screen_moved
          moved_v = @screen_moved_vertically
          frames = @autotiles.changed
          pox = @pixel_offset_x
          poy = @pixel_offset_y
          dtw = TilemapRenderer::DISPLAY_TILE_WIDTH
          dth = TilemapRenderer::DISPLAY_TILE_HEIGHT
          sth = TilemapRenderer::SOURCE_TILE_HEIGHT
          bridge_on = $PokemonGlobal.bridge > 0
          gw2 = Graphics.width / 2
          gh2 = Graphics.height / 2
          $map_factory.maps.each do |map|
            map_display_x = (map.display_x.to_f / Game_Map::X_SUBPIXELS).round
            map_display_x = ((map_display_x + gw2) * TilemapRenderer::ZOOM_X) - gw2 if TilemapRenderer::ZOOM_X != 1
            map_display_y = (map.display_y.to_f / Game_Map::Y_SUBPIXELS).round
            map_display_y = ((map_display_y + gh2) * TilemapRenderer::ZOOM_Y) - gh2 if TilemapRenderer::ZOOM_Y != 1
            map_display_x_tile = map_display_x / dtw
            map_display_y_tile = map_display_y / dth
            start_x = [-map_display_x_tile, 0].max
            start_y = [-map_display_y_tile, 0].max
            end_x = [hcount - 1, map.width - map_display_x_tile - 1].min
            end_y = [vcount - 1, map.height - map_display_y_tile - 1].min
            next if start_x > end_x || start_y > end_y || end_x < 0 || end_y < 0
            data = map.data
            i = start_x
            while i <= end_x
              tile_x = i + map_display_x_tile
              col = @tiles[i]
              vcol = visited[i]
              sx = (i * dtw) - pox
              j = start_y
              while j <= end_y
                tile_y = j + map_display_y_tile
                stack = col[j]
                layer = 0
                while layer < 3
                  tile = stack[layer]
                  tile_id = data[tile_x, tile_y, layer]
                  if do_full_refresh || tile.need_refresh || tile.tile_id != tile_id
                    refresh_tile(tile, i, j, map, layer, tile_id)
                  elsif tile.visible
                    @autotiles.set_src_rect(tile, tile_id) if frames && tile.animated
                    if moved
                      tile.x = sx
                      tile.y = (j * dth) - poy
                    end
                    if moved_v
                      if tile.shows_reflection
                        tile.z = -100
                      elsif tile.bridge && bridge_on
                        tile.z = 0
                      else
                        pr = tile.priority
                        tile.z = (pr == 0) ? 0 : (j * sth) + (pr * sth) + sth + 1
                      end
                    end
                  end
                  layer += 1
                end
                vcol[j] = true
                j += 1
              end
              i += 1
            end
          end
          # Las casillas que no son de ningún mapa se vacían, como en el
          # original, salvo las que ya lo están.
          i = 0
          while i < hcount
            col = @tiles[i]
            vcol = visited[i]
            j = 0
            while j < vcount
              unless vcol[j]
                col[j].each do |tile|
                  next if tile.need_refresh && tile.tile_id == 0 && tile.bitmap.nil? &&
                          !tile.shows_reflection && !tile.bridge
                  tile.set_bitmap("", 0, false, false, 0, nil)
                  tile.shows_reflection = false
                  tile.bridge           = false
                end
              end
              j += 1
            end
            i += 1
          end
          @need_refresh = false
          @autotiles.changed = false
        end
      end

      NX.log("[tilemap] TilemapRenderer#update sin recolocar casillas vacias") if defined?(NX) && NX.respond_to?(:log)
      true
    end
  end
end

module Graphics
  class << self
    alias_method :nx_update_sin_tilemap_v21, :update

    def update(*a)
      NXTilemapV21.instala unless NXTilemapV21.instalado
      nx_update_sin_tilemap_v21(*a)
    end
  end
end
