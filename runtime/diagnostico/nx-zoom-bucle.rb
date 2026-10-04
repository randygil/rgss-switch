# nx-zoom-bucle.rb — Map Zoom puesto sin fin, y lo que hace con la memoria.
#
# La caida de §5.76: el plugin Map Zoom, mientras el zoom esta puesto, hace una
# Graphics.snap_to_bitmap por fotograma y no dispone la anterior. 768 KB de
# textura por fotograma que solo vuelven cuando pasa el recolector de Ruby, y
# el recolector no sabia nada de ellas: en la consola las texturas vivas
# subieron de 650 a 1.169 MB en segundos y la GPU dijo que no.
#
# Esto lo provoca a voluntad. En cuanto el jugador lleva ESPERA fotogramas en
# el mapa, se pone el zoom y no se quita nunca:
#
#   plugin  (por omision) pbZoomMap(1.5, ...) del propio juego. Con nx-zoom.rb
#           del perfil cargado, el plugin ya dispone su foto; para medir solo
#           el motor hay que quitarlo del preloadScript.
#   crudo   lo mismo sin el plugin: un Sprite y, cada fotograma,
#           sprite.bitmap = Graphics.snap_to_bitmap sin disponer la de antes.
#           Sirve en cualquier juego.
#
# Se elige con nx-zoom-bucle.txt junto al juego (primera linea: plugin o crudo;
# segunda, los fotogramas de mapa antes de empezar, 300 si no). Para llegar al
# mapa sin mando va con el bot de nx-mapa.rb (nx-mapa-bot.txt), que ademas lo
# cierra a los segundos que diga.
#
# Cada 300 fotogramas, una linea [zoombucle] en mkxp-ruby.log: fotogramas por
# segundo de reloj de pared, pasadas del recolector (menores y mayores), los
# contadores de malloc que deciden la siguiente pasada y cuantos Bitmap sin
# disponer quedan. La memoria de video la dice el lado C++ cada 30 s en
# mkxp-boot.log: "[monton] texturas vivas ... | en manos del juego N MB".
#
# Ojo al leer los [tiron]: contar los Bitmap es un ObjectSpace.each_object, y
# eso termina de golpe el barrido perezoso del recolector si estaba a medias.
# Con el zoom puesto apenas cuesta (las pasadas van seguidas y dejan poco por
# barrer); con el zoom arreglado, o con el informe de nx-mapa.rb (que hace lo
# mismo con los Sprite), sale un fotograma de 120-150 ms en Ryujinx por cada
# pasada que no es del juego, es de la sonda.

module NXZoomBucle
  CADA = 300
  LINEAS = (File.exist?("nx-zoom-bucle.txt") ? File.read("nx-zoom-bucle.txt").split("\n").map(&:strip) : []) rescue []
  MODO = (LINEAS[0].nil? || LINEAS[0].empty?) ? "plugin" : LINEAS[0]
  ESPERA = LINEAS[1].to_i > 0 ? LINEAS[1].to_i : 300

  @en_mapa = 0
  @puesto = false
  @sprite = nil
  @viewport = nil
  @f = 0
  @t0 = nil
  @t_inicio = nil
  @gc0 = nil
  @gc_visto = GC.count
  @motivos = Hash.new(0)

  class << self
    def reloj
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def log(s)
      if defined?(NX) && NX.respond_to?(:log)
        NX.log(s)
      else
        @salida ||= File.open(File.join(Dir.pwd, "zoom-bucle.log"), "a").tap { |f| f.sync = true }
        @salida.puts(s)
      end
    rescue StandardError
      nil
    end

    def gc
      s = GC.stat
      [s[:count], s[:minor_gc_count], s[:major_gc_count]]
    end

    def pon
      @puesto = true
      @t_inicio = reloj
      if MODO == "plugin" && (Object.private_method_defined?(:pbZoomMap) || Object.method_defined?(:pbZoomMap))
        pbZoomMap(1.5, 0.005, "in")
        log("[zoombucle] zoom puesto con pbZoomMap del juego" +
            (defined?(NXZoom) && NXZoom.instalado ? " (con nx-zoom.rb)" : " (sin nx-zoom.rb)"))
      else
        @modo_crudo = true
        @viewport = Viewport.new(0, 0, Graphics.width, Graphics.height)
        @viewport.z = 99999
        @sprite = Sprite.new(@viewport)
        log("[zoombucle] zoom crudo: snap_to_bitmap por fotograma sin disponer")
      end
    end

    # Antes de cada Graphics.update. Si ha pasado el recolector, por que fue
    # mayor (latest_gc_info: :nofree, :oldgen, :oldmalloc, :force...) o si fue
    # menor; con varias pasadas en un fotograma solo se ve la ultima.
    def marca
      c = GC.count
      if c != @gc_visto
        @gc_visto = c
        por = GC.latest_gc_info(:major_by)
        @motivos[por ? por.to_s : "menor"] += 1 if @puesto
      end
      if defined?(Scene_Map) && $scene.is_a?(Scene_Map)
        @en_mapa += 1
      else
        @en_mapa = 0
      end
      pon if !@puesto && @en_mapa >= ESPERA
      return unless @puesto

      if @modo_crudo && @sprite && !@sprite.disposed?
        @sprite.bitmap.clear if @sprite.bitmap && !@sprite.bitmap.disposed?
        @sprite.bitmap = Graphics.snap_to_bitmap
        @sprite.zoom_x = @sprite.zoom_y = 1.5
        @sprite.ox = @sprite.bitmap.width / 4
        @sprite.oy = @sprite.bitmap.height / 4
      end

      @t0 ||= reloj
      @gc0 ||= gc
      @f += 1
      informa if @f >= CADA
    end

    def informa
      t = reloj
      g = gc
      s = GC.stat
      vivos = 0
      ObjectSpace.each_object(Bitmap) { |b| vivos += 1 unless b.disposed? }
      log(format("[zoombucle] %4d s | %d f en %.1f s (%.1f fps) | gc +%d (%d menores, %d mayores; total %d) | malloc %d/%d KB | oldmalloc %d/%d KB | %d Bitmap sin disponer | %s",
                 (t - @t_inicio).round, @f, t - @t0, @f / (t - @t0),
                 g[0] - @gc0[0], g[1] - @gc0[1], g[2] - @gc0[2], g[0],
                 s[:malloc_increase_bytes] / 1024, s[:malloc_increase_bytes_limit] / 1024,
                 s[:oldmalloc_increase_bytes] / 1024, s[:oldmalloc_increase_bytes_limit] / 1024,
                 vivos, @motivos.map { |k, v| "#{k} #{v}" }.join(", ")))
      @motivos.clear
      @f = 0
      @t0 = reloj
      @gc0 = gc
    rescue StandardError => e
      log("[zoombucle] informe roto: #{e.class} #{e.message}")
      @f = 0
      @t0 = reloj
      @gc0 = gc
    end
  end
end

module Graphics
  class << self
    alias_method :nx_update_sin_zoombucle, :update

    def update(*a)
      NXZoomBucle.marca
      nx_update_sin_zoombucle(*a)
    end
  end
end
