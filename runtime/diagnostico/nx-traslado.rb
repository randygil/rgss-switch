# nx-traslado.rb — que cuesta el fotograma de entrar o salir de una casa.
#
# El jugador dice que "al entrar o salir de una casa se congela unos segundos",
# y los registros de la consola lo confirman: cada "[donde] mapa N" va seguido
# de un [tiron] de 0,7 a 5 s donde casi todo es "cpu" del hilo de Ruby y casi
# nada cae bajo las sondas de C++ (nx/nx_tirones.c lo llama "resto"). Y crece
# con la sesion: Ciudad Carmin costo 1142 ms al empezar y 5204 horas despues.
#
# "Es Ruby" no se arregla. Esta sonda contesta tres preguntas sobre
# Scene_Map#transfer_player, que es donde Essentials cambia de mapa:
#
#   1. Si es el recolector. GC.stat antes y despues de cada traslado: pasadas
#      mayores y menores, milisegundos de GC, objetos creados, por que fue la
#      ultima mayor (GC.latest_gc_info).
#   2. Que trozo. Cronometros directos, inclusivos, sobre las piezas del
#      traslado (MapFactory#setup, los spritesets, el refresco de los
#      seguidores...) y sobre CADA manejador de EventHandlers por su nombre: ahi
#      se cuelgan los plugins (:on_enter_map, :on_new_spriteset_map...).
#   3. Que metodo. Un muestreador de pila: un hilo que, mientras dura el
#      traslado, pide Thread.main.backtrace_locations y reparte el intervalo
#      entre todos los marcos de la pila (inclusivo) y el de arriba (propio).
#      nx-perfil.rb explica por que un muestreador de Ruby miente cuando el hilo
#      medido suelta el GVL en cada llamada al sistema; aqui el traslado es
#      Ruby puro casi entero (eso dice "resto"), y en Ruby puro el hilo solo
#      cede el GVL cuando el reloj del planificador se lo quita, en puntos que
#      no dependen de lo que este haciendo. Son pocas muestras por traslado
#      (el cuanto es de 100 ms), por eso se suman sobre decenas de traslados.
#
# Y una cuarta, la del crecimiento: con "censo cada N" en el fichero del bot,
# cada N traslados (fuera del cronometro, tras un GC.start) cuenta los objetos
# vivos por clase y el tamano de cada Array/Hash colgado de variables globales,
# de las variables de clase y de los @ de cada clase y modulo, y dice los que
# mas han crecido desde el primer censo.
#
# BOT. Con nx-traslado-bot.txt en la carpeta del juego la sonda tambien
# conduce, sin teclado ni foco (como nx-mapa.rb):
#
#   linea 1  partida                 ("Partida 1" si esta vacia)
#   linea 2  mapa x y                destino A
#   linea 3  mapa x y                destino B
#   linea 4  traslados               cuantos en total (A, B, A, B...)
#   linea 5  fotogramas entre dos    (120 si esta vacia)
#   linea 6  censo cada N traslados  (0 o vacia: sin censo)
#   linea 7  1 = GC.start justo antes de cada traslado, fuera del cronometro,
#            y se dice lo que tardo: en Horizon GC.stat(:time) sale a cero
#            (§5.75: el recolector se cronometra con un reloj de CPU que
#            Horizon no tiene), y asi se mide con el de pared lo que cuesta una
#            pasada mayor con el monton de ese momento, y el traslado sin ella.
#
# Carga la partida sin pasar por el titulo, hace los traslados como un evento
# de puerta (Graphics.freeze + transicion, igual que el comando 201) y cierra
# el juego sin guardar. Necesita estar en preloadScript despues de los shims
# del juego. En la consola escribe con NX.log (mkxp-ruby.log); en el PC, en
# traslado.log de la carpeta del juego.
#
# Solo para diagnostico: no se carga en produccion.

module NXTraslado
  RUTA_PC = ::File.join(Dir.pwd, "traslado.log")
  CIMAS = 25

  T = Hash.new(0.0)   # pieza => segundos dentro del traslado en curso
  N = Hash.new(0)
  TT = Hash.new(0.0)  # pieza => segundos acumulados en todos los traslados
  INCL = Hash.new(0.0)
  PROP = Hash.new(0.0)

  @dentro = false
  @pausa = false
  @instalado = false
  @n = 0
  @muestras = 0
  @cerrojo = Mutex.new
  @ultima = nil
  @serie = []

  GC.measure_total_time = true if GC.respond_to?(:measure_total_time=)

  class << self
    attr_reader :n, :dentro

    def reloj
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def log(texto)
      if defined?(NX) && NX.respond_to?(:log)
        NX.log(texto)
      else
        @salida ||= ::File.open(RUTA_PC, "a").tap { |f| f.sync = true }
        @salida.write(texto + "\n")
      end
    rescue StandardError
      nil
    end

    def ascii(s)
      s.to_s.b.each_byte.map { |b| (b >= 32 && b < 127) ? b.chr : "?" }.join
    end

    def suma(etiqueta, t0)
      return unless @dentro
      d = reloj - t0
      T[etiqueta] += d
      N[etiqueta] += 1
    end

    # Como envuelve_alias de nx-mapa.rb: un alias por fuera de todos los que
    # ya pusieron los plugins, con el nombre de la clase en el alias para que
    # la copia del padre no vuelva a caer en la del hijo.
    def envuelve(klass, metodo, etiqueta)
      return false unless klass.method_defined?(metodo) || klass.private_method_defined?(metodo)
      privado = klass.private_method_defined?(metodo)
      viejo = :"nx_tras_#{klass.object_id}_#{metodo.to_s.sub(/[?!]$/) { |c| c == "?" ? "_p" : "_b" }}"
      return false if klass.method_defined?(viejo) || klass.private_method_defined?(viejo)
      klass.send(:alias_method, viejo, metodo)
      klass.send(:define_method, metodo) do |*a, &b|
        t0 = NXTraslado.reloj
        begin
          send(viejo, *a, &b)
        ensure
          NXTraslado.suma(etiqueta, t0)
        end
      end
      klass.send(:ruby2_keywords, metodo)
      klass.send(:private, metodo) if privado
      true
    rescue StandardError
      false
    end

    def constante(nombre)
      nombre.split("::").inject(Object) { |o, c| o.const_get(c) }
    rescue NameError
      nil
    end

    PIEZAS = [
      ["PokemonMapFactory", :setup, "mapfactory.setup"],
      ["Game_Map", :setup, "game_map.setup"],
      ["Game_Map", :refresh, "game_map.refresh"],
      ["Game_Map", :update, "game_map.update"],
      ["Game_Map", :autoplay, "game_map.autoplay"],
      ["Game_Event", :initialize, "game_event.new"],
      ["Game_Event", :refresh, "game_event.refresh"],
      ["Game_Player", :moveto, "player.moveto"],
      ["Game_Player", :center, "player.center"],
      ["Scene_Map", :disposeSpritesets, "dispose_spritesets"],
      ["Scene_Map", :createSpritesets, "create_spritesets"],
      ["Spriteset_Map", :initialize, "spriteset_map.new"],
      ["Spriteset_Map", :dispose, "spriteset_map.dispose"],
      ["Spriteset_Map", :update, "spriteset_map.update"],
      ["Spriteset_Global", :initialize, "spriteset_global.new"],
      ["Spriteset_Global", :dispose, "spriteset_global.dispose"],
      ["Sprite_Character", :initialize, "sprite_character.new"],
      ["Sprite_Character", :dispose, "sprite_character.dispose"],
      ["TilemapRenderer", :initialize, "tilemap.new"],
      ["TilemapRenderer", :dispose, "tilemap.dispose"],
      ["TilemapRenderer", :refresh, "tilemap.refresh"],
      ["Game_FollowerFactory", :map_transfer_followers, "followers.transfer"],
      ["DynamicShadows", :initialize, "sombras.new"],
      ["Sprite_DynamicShadows", :initialize, "sprite_sombras.new"],
      ["Interpreter", :setup, "interprete.setup"],
    ]

    def instala
      return if @instalado
      return unless defined?(Scene_Map) && $scene.is_a?(Scene_Map)
      # Unos fotogramas de margen para quedar por fuera de lo que otros shims
      # instalen en el primer fotograma de mapa.
      @espera = (@espera || 0) + 1
      return if @espera < 20
      @instalado = true
      puestas = 0
      PIEZAS.each do |clase, metodo, etiqueta|
        k = constante(clase)
        puestas += 1 if k.is_a?(Module) && envuelve(k, metodo, etiqueta)
      end
      if defined?(RPG::Cache)
        puestas += 1 if envuelve(RPG::Cache.singleton_class, :clear, "rpg_cache.clear")
      end
      puestas += 1 if defined?(FollowingPkmn) && envuelve(FollowingPkmn.singleton_class, :refresh, "followingpkmn.refresh")
      puestas += 1 if envuelve(Object, :pbRemovePokeEvents, "voe.remove_poke_events")
      puestas += 1 if envuelve(Object, :pbCancelVehicles, "cancel_vehicles")
      puestas += 1 if envuelve(Object, :autofade, "autofade")
      puestas += 1 if envuelve(Graphics.singleton_class, :frame_reset, "graphics.frame_reset")
      # El traslado entero, por fuera de los alias de los plugins.
      Scene_Map.class_eval do
        alias_method :nx_tras_transfer_player, :transfer_player
        def transfer_player(*a)
          NXTraslado.empieza
          begin
            nx_tras_transfer_player(*a)
          ensure
            NXTraslado.termina
          end
        end
      end
      # La transicion en negro no es trabajo de Ruby: se mide aparte y el
      # muestreador no corre durante ella.
      Graphics.singleton_class.class_eval do
        alias_method :nx_tras_transition, :transition
        def transition(*a)
          return nx_tras_transition(*a) unless NXTraslado.dentro
          NXTraslado.pausa(true)
          t0 = NXTraslado.reloj
          begin
            nx_tras_transition(*a)
          ensure
            NXTraslado.pausa(false)
            NXTraslado::T["(transicion)"] += NXTraslado.reloj - t0
          end
        end
      end
      manejadores = envuelve_manejadores
      arranca_muestreador
      log("[traslado] sonda puesta: #{puestas} piezas, #{manejadores} manejadores")
    rescue StandardError => e
      log("[traslado] no se pudo poner: #{e.class} #{e.message} #{e.backtrace&.first}")
    end

    def envuelve_manejadores
      return 0 unless defined?(EventHandlers)
      eventos = EventHandlers.class_variable_get(:@@events) rescue nil
      return 0 unless eventos.is_a?(Hash)
      total = 0
      eventos.each do |evento, ne|
        cb = ne.instance_variable_get(:@callbacks)
        next unless cb.is_a?(Hash)
        cb.keys.each do |clave|
          orig = cb[clave]
          etiqueta = "#{evento}:#{clave}"
          cb[clave] = proc do |*a|
            t0 = NXTraslado.reloj
            begin
              orig.call(*a)
            ensure
              NXTraslado.suma(etiqueta, t0)
            end
          end
          total += 1
        end
      end
      total
    end

    def pausa(si)
      @cerrojo.synchronize do
        @pausa = si
        @ultima = reloj
      end
    end

    def gc_foto
      s = GC.stat
      {
        count: s[:count], major: s[:major_gc_count], minor: s[:minor_gc_count],
        time: (s[:time] || 0), alloc: s[:total_allocated_objects],
        live: s[:heap_live_slots], old: s[:old_objects], free: s[:heap_free_slots],
        malloc: s[:malloc_increase_bytes], oldmalloc: s[:oldmalloc_increase_bytes],
      }
    end

    def empieza
      T.clear
      N.clear
      @desde = ($game_map.map_id rescue 0)
      @gc0 = gc_foto
      @cerrojo.synchronize do
        @ultima = reloj
        @dentro = true
        @pausa = false
      end
      @t0 = reloj
    end

    def termina
      t = reloj - @t0
      @cerrojo.synchronize { @dentro = false }
      @n += 1
      g1 = gc_foto
      g0 = @gc0
      trans = T["(transicion)"]
      ruby = t - trans
      T.each { |k, v| TT[k] += v }
      info = (GC.latest_gc_info rescue {})
      piezas = T.keys.reject { |k| k == "(transicion)" }.sort_by { |k| -T[k] }.first(10)
                .map { |k| format("%s %d", k, T[k] * 1000) }.join(" | ")
      hacia = ($game_map.map_id rescue 0)
      nombre = ascii(($game_map.name rescue "?"))
      @serie << (ruby * 1000).round
      log(format("[traslado] #%d %d->%d %s | %d ms sin transicion (+%d de transicion)" \
                 " | gc: %d mayor(es), %d menor(es), %d ms segun GC.stat | %d obj creados | vivos %d viejos %d" \
                 " | libres antes %d | ultima gc: %s %s",
                 @n, @desde, hacia, nombre, ruby * 1000, trans * 1000,
                 g1[:major] - g0[:major], g1[:minor] - g0[:minor], g1[:time] - g0[:time],
                 g1[:alloc] - g0[:alloc], g1[:live], g1[:old], g0[:free],
                 info[:major_by].inspect, info[:gc_by].inspect))
      log("[traslado]   piezas ms: " + piezas)
      st = GC.stat
      log(format("[traslado]   monton: %d casillas (%d paginas + %d por crear) | %d libres | %d vivas | viejos %d de %d | wb sin proteger %d de %d | %d mayores y %d menores desde el arranque",
                 st[:heap_available_slots], st[:heap_eden_pages], st[:heap_allocatable_pages],
                 st[:heap_free_slots], st[:heap_live_slots], st[:old_objects], st[:old_objects_limit],
                 st[:remembered_wb_unprotected_objects], st[:remembered_wb_unprotected_objects_limit],
                 st[:major_gc_count], st[:minor_gc_count]))
      if (@n % 10).zero?
        # Los Bitmap que siguen en memoria, recogibles o no: lo que una pasada
        # que no se hace dejaria de liberar.
        bm = 0; px = 0
        ObjectSpace.each_object(Bitmap) do |b|
          next if (b.disposed? rescue true)
          bm += 1
          px += b.width * b.height
        end
        log(format("[traslado]   bitmaps sin liberar: %d, %d MB en RGBA", bm, px * 4 / 1048576))
      end
      informe_muestras if (@n % 10).zero?
      # Lo que viene detras: con la pasada incremental de nx-cache-gc.rb el
      # trabajo del recolector no desaparece, se reparte entre los fotogramas
      # siguientes. Se vigilan DESPUES fotogramas: el peor, y en cual termina la
      # pasada (GC.latest_gc_info(:state) vuelve a :none).
      @post = DESPUES
      @post_peor = 0.0
      @post_fin = nil
      @post_prev = nil
      @post_estado = (GC.latest_gc_info(:state) rescue nil)
    rescue StandardError => e
      log("[traslado] informe roto: #{e.class} #{e.message} #{e.backtrace&.first}")
    end

    DESPUES = 180

    # Se llama al principio de cada Graphics.update.
    def tras_fotograma
      return unless @post && @post > 0
      ahora = reloj
      if @post_prev
        d = ahora - @post_prev
        @post_peor = d if d > @post_peor
      end
      @post_prev = ahora
      n = DESPUES - @post
      if @post_fin.nil? && (GC.latest_gc_info(:state) rescue :none) == :none
        @post_fin = n
      end
      @post -= 1
      return unless @post.zero?
      log(format("[traslado]   despues (%d fotogramas): peor %d ms | la gc estaba en %s al acabar el traslado y termina en el fotograma %s",
                 DESPUES, @post_peor * 1000, @post_estado.inspect, @post_fin.inspect))
    end

    def serie
      @serie
    end

    # ---------------------------------------------------------------- muestreo
    def arranca_muestreador
      return if @hilo
      principal = Thread.main
      @hilo = Thread.new do
        Thread.current.name = "nx-traslado" if Thread.current.respond_to?(:name=)
        loop do
          sleep 0.005
          next unless @dentro && !@pausa
          pila = principal.backtrace_locations(0, 80) rescue nil
          apunta(pila)
        end
      end
    end

    def clave(loc)
      "#{::File.basename(loc.path.to_s)}:#{loc.label}"
    end

    def apunta(pila)
      ahora = reloj
      @cerrojo.synchronize do
        return unless @dentro && !@pausa
        trozo = @ultima ? ahora - @ultima : 0.0
        @ultima = ahora
        return if pila.nil? || pila.empty?
        @muestras += 1
        vistos = {}
        pila.each do |loc|
          k = clave(loc)
          next if vistos[k]
          vistos[k] = true
          INCL[k] += trozo
        end
        arriba = pila.first
        PROP["#{clave(arriba)}:#{arriba.lineno}"] += trozo
      end
    end

    def informe_muestras
      total = 0.0
      incl = prop = nil
      @cerrojo.synchronize do
        total = TT.reject { |k, _| k == "(transicion)" }.values.sum
        incl = INCL.sort_by { |_, v| -v }.first(CIMAS)
        prop = PROP.sort_by { |_, v| -v }.first(15)
      end
      log(format("[traslado] == tras %d traslados: %d muestras; serie ms: %s",
                 @n, @muestras, @serie.join(" ")))
      cron = TT.reject { |k, _| k == "(transicion)" }.sort_by { |_, v| -v }.first(CIMAS)
      log("[traslado] == cronometros (ms por traslado): " +
          cron.map { |k, v| format("%s %.1f", k, v * 1000.0 / @n) }.join(" | "))
      log("[traslado] == pila inclusiva (ms por traslado): " +
          incl.map { |k, v| format("%s %.1f", ascii(k), v * 1000.0 / @n) }.join(" | "))
      log("[traslado] == pila propia (ms por traslado): " +
          prop.map { |k, v| format("%s %.1f", ascii(k), v * 1000.0 / @n) }.join(" | "))
    end

    # ------------------------------------------------------------------ censo
    def censo
      GC.start
      porclase = Hash.new(0)
      ObjectSpace.each_object(Object) do |o|
        k = (o.class rescue nil)
        porclase[k] += 1 if k
      end
      tam = {}
      medir = lambda do |nombre, v|
        if v.is_a?(Array) || v.is_a?(Hash)
          tam[nombre] = v.size if v.size >= 20
        end
      end
      global_variables.each do |g|
        v = (eval(g.to_s) rescue nil)
        medir.call(g.to_s, v)
        next if v.nil? || v.is_a?(Module) || v.is_a?(Numeric) || v.is_a?(String)
        (v.instance_variables rescue []).each do |iv|
          medir.call("#{g}.#{iv}", (v.instance_variable_get(iv) rescue nil))
        end
      end
      ObjectSpace.each_object(Module) do |m|
        nombre = (m.name rescue nil) || next
        (m.instance_variables rescue []).each do |iv|
          medir.call("#{nombre}.#{iv}", (m.instance_variable_get(iv) rescue nil))
        end
        (m.class_variables(false) rescue []).each do |cv|
          medir.call("#{nombre}#{cv}", (m.class_variable_get(cv) rescue nil))
        end
      end
      # Lo que cuelga de la escena y del spriteset vivo, un nivel.
      [[$scene, "$scene"]].each do |obj, n0|
        next unless obj
        obj.instance_variables.each do |iv|
          v = obj.instance_variable_get(iv)
          medir.call("#{n0}.#{iv}", v)
          vs = v.is_a?(Array) ? v : [v]
          vs.each_with_index do |x, i|
            next unless x && x.class.name.to_s.start_with?("Spriteset")
            x.instance_variables.each do |iv2|
              medir.call("#{n0}.#{iv}[#{i}].#{iv2}", x.instance_variable_get(iv2))
            end
          end
        end
      end
      [porclase, tam]
    end

    def censa
      t0 = reloj
      pc, tam = censo
      s = GC.stat
      if @censo0.nil?
        @censo0 = [pc, tam]
        log(format("[censo] #%d base: %d objetos vivos, %d clases, %d contenedores (%d ms)",
                   @n, pc.values.sum, pc.size, tam.size, (reloj - t0) * 1000))
        return
      end
      pc0, tam0 = @censo0
      crece = pc.map { |k, v| [k, v - pc0[k].to_i] }.select { |_, d| d > 0 }.sort_by { |_, d| -d }.first(20)
      log(format("[censo] #%d: %d objetos vivos (base %d), heap_live %d, old %d (%d ms)",
                 @n, pc.values.sum, pc0.values.sum, s[:heap_live_slots], s[:old_objects],
                 (reloj - t0) * 1000))
      log("[censo]   clases que crecen: " + crece.map { |k, d| "#{ascii(k)} +#{d} (#{pc[k]})" }.join(" | "))
      ct = tam.map { |k, v| [k, v - tam0[k].to_i] }.select { |_, d| d > 0 }.sort_by { |_, d| -d }.first(20)
      log("[censo]   contenedores que crecen: " + ct.map { |k, d| "#{ascii(k)} +#{d} (#{tam[k]})" }.join(" | "))
    rescue StandardError => e
      log("[censo] roto: #{e.class} #{e.message} #{e.backtrace&.first}")
    end
  end
end

# ---------------------------------------------------------------------------
# El conductor. Solo con nx-traslado-bot.txt al lado del juego.
module NXTrasladoBot
  ACTIVO = File.exist?("nx-traslado-bot.txt")
  LINEAS = ACTIVO ? (File.read("nx-traslado-bot.txt").split("\n").map(&:strip) rescue []) : []
  PARTIDA = (LINEAS[0].nil? || LINEAS[0].empty?) ? "Partida 1" : LINEAS[0]
  DESTINOS = [LINEAS[1], LINEAS[2]].map { |l| l.to_s.split.map(&:to_i) }
  TOTAL = LINEAS[3].to_i
  ENTRE = LINEAS[4].to_i > 0 ? LINEAS[4].to_i : 120
  CENSO = LINEAS[5].to_i
  GC_ANTES = LINEAS[6].to_i == 1

  @cargada = false
  @quieto = 0
  @hechos = 0

  class << self
    def listo?
      !@cargada && defined?(Game) && Game.respond_to?(:load) && defined?(SaveData) &&
        defined?(Scene_Map) && $data_system
    end

    def entra
      @cargada = true
      ruta = File.join(System.data_directory, PARTIDA + ".rxdata")
      NXTraslado.log("[bot] cargando #{ruta}")
      Game.load(SaveData.read_from_file(ruta))
      $PokemonSystem.bgmvolume = 0 rescue nil
      $PokemonSystem.sevolume = 0 rescue nil
      if Graphics.class_variable_defined?(:@@transition)
        Graphics.class_variable_get(:@@transition)&.dispose rescue nil
        Graphics.class_variable_set(:@@transition, nil)
      end
      $scene = Scene_Map.new unless $scene.is_a?(Scene_Map)
      NXTraslado.log("[bot] en el mapa #{$game_map.map_id} (#{$game_player.x},#{$game_player.y})")
      $scene.main while $scene
      Kernel.exit!(0)
    end

    def mensaje?
      $game_temp && $game_temp.respond_to?(:message_window_showing) && $game_temp.message_window_showing
    end

    def ocupado?
      return true unless $scene.is_a?(Scene_Map)
      return true if mensaje? || $game_temp.player_transferring || $game_temp.transition_processing
      return true if $game_system.map_interpreter.running? rescue false
      return true if $game_player.moving? rescue false
      false
    end

    def paso
      return entra if listo?
      return unless @cargada
      return unless defined?(NXTraslado) && NXTraslado.instance_variable_get(:@instalado)
      if ocupado?
        @quieto = 0
        return
      end
      @quieto += 1
      return if @quieto < ENTRE
      @quieto = 0
      if @hechos >= TOTAL
        NXTraslado.informe_muestras
        NXTraslado.log("[bot] fin tras #{@hechos} traslados")
        Kernel.exit!(0)
      end
      if CENSO > 0 && (@hechos == 2 || (@hechos > 2 && (@hechos % CENSO).zero?))
        NXTraslado.censa
      end
      if GC_ANTES
        t0 = NXTraslado.reloj
        GC.start
        NXTraslado.log(format("[traslado] GC.start antes del #%d: %d ms", @hechos + 1,
                              (NXTraslado.reloj - t0) * 1000))
      end
      d = DESTINOS[@hechos % 2]
      @hechos += 1
      return if d.length != 3
      # Lo mismo que el comando 201 con fundido.
      Graphics.freeze
      $game_temp.transition_processing = true
      $game_temp.transition_name = ""
      $game_temp.player_transferring = true
      $game_temp.player_new_map_id = d[0]
      $game_temp.player_new_x = d[1]
      $game_temp.player_new_y = d[2]
      $game_temp.player_new_direction = 2
    end

    def aceptar?
      ACTIVO && @cargada && mensaje? && (Graphics.frame_count % 30) < 2
    end
  end
end

if NXTrasladoBot::ACTIVO
  module Input
    class << self
      alias_method :nx_tbot_trigger?, :trigger?
      def trigger?(b)
        return true if b == Input::C && NXTrasladoBot.aceptar?
        nx_tbot_trigger?(b)
      end
    end
  end
end

module Graphics
  class << self
    alias_method :nx_tras_update, :update
    def update(*a)
      begin
        NXTraslado.instala unless NXTraslado.instance_variable_get(:@instalado)
        NXTraslado.tras_fotograma
        NXTrasladoBot.paso if NXTrasladoBot::ACTIVO
      rescue StandardError => e
        NXTraslado.log("[traslado] fallo en la sonda: #{e.class} #{e.message} #{e.backtrace&.first}")
      end
      nx_tras_update(*a)
    end
  end
end

NXTraslado.log("[traslado] sonda de traslados cargada (bot: #{NXTrasladoBot::ACTIVO})")
