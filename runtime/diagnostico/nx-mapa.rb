# nx-mapa.rb — en qué se va el fotograma andando por el mapa.
#
# El síntoma que manda esto es otro que el de las demás sondas: no son tirones
# de un segundo (los de cargar un tileset ya se trataron, §5.70-ter), es que
# andar por exteriores va lento todo el rato. Un fotograma de 25 ms no pasa el
# umbral de 250 de nx_tirones.c y no deja ninguna línea, así que no hay registro
# de consola que lo explique. Hay que medir el fotograma NORMAL.
#
# Se envuelven, con una sola capa y tiempo inclusivo, los trozos del bucle de
# Scene_Map: el intérprete, el jugador, los mapas y sus eventos, los spritesets
# y dentro de ellos el TilemapRenderer, el tinte de día y noche y cada uno de
# los manejadores de :on_frame_update por su nombre (ahí se cuelgan los plugins
# que corren cada fotograma, como el aparecer automático de VOE). Y se cuentan
# las pasadas y el tiempo del recolector y los objetos creados, porque en el
# registro de la consola del 9 de septiembre el recolector corre cada cuatro
# segundos con el jugador quieto en el Bosque Verde.
#
# Cada 300 fotogramas de mapa sale una línea [mapa] con la media por fotograma
# de cada trozo. En la consola va a mkxp-ruby.log por NX.log; en el PC, a
# perfil-mapa.log en la carpeta del juego.
#
# BOT. Si en la carpeta del juego existe nx-mapa-bot.txt, la sonda además
# conduce: en cuanto los scripts están cargados, carga la partida que diga ese
# fichero (primera línea; "Partida 1" si está vacío) sin pasar por el título,
# entra en el mapa y anda en cuadrado (derecha, abajo, izquierda, arriba), sin
# teclado ni foco. La segunda línea, si la hay, son los segundos de mapa tras
# los que el juego se cierra solo, sin guardar. Así se mide igual en el PC, en
# el emulador y en la consola, sin nadie al mando. Los fotogramas con un
# mensaje en pantalla o fuera de Scene_Map no cuentan.

module NXMapa
  INFORME_CADA = 300
  RUTA_PC = ::File.join(Dir.pwd, "perfil-mapa.log")

  T = Hash.new(0.0)   # etiqueta => segundos acumulados
  N = Hash.new(0)     # etiqueta => llamadas

  @instalado = false
  @marcos = 0
  @pared = 0.0
  @previo = nil
  @andando = 0
  @gc0 = nil

  GC.measure_total_time = true if GC.respond_to?(:measure_total_time=)

  def self.reloj
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def self.log(texto)
    if defined?(NX) && NX.respond_to?(:log)
      NX.log(texto)
    else
      # Ruta absoluta, fijada al cargar: algún plugin cambia el directorio de
      # trabajo o reinterpreta las rutas relativas, y una línea que se pierde
      # en silencio es peor que ninguna.
      @salida ||= ::File.open(RUTA_PC, "a").tap { |f| f.sync = true }
      @salida.write(texto + "\n")
    end
  rescue StandardError => e
    $stderr.puts("nx-mapa: #{e.class} #{e.message}") rescue nil
    nil
  end

  def self.suma(etiqueta, t0)
    T[etiqueta] += reloj - t0
    N[etiqueta] += 1
  end

  # Envuelve klass#metodo con un módulo antepuesto: va por fuera de todos los
  # alias que los plugins ya hayan puesto, así que mide la cadena entera.
  def self.envuelve(klass, metodo, etiqueta)
    return envuelve_alias(klass, metodo, etiqueta)
  end

  # La versión con módulo antepuesto, que se dejó de usar: un shim que se
  # instale DESPUÉS con alias (lo normal en Essentials) cogería el método del
  # módulo y la llamada daría vueltas sin fin (medido: "stack level too deep"
  # en cuanto nx-eventos-lejos.rb se puso junto a esta sonda).
  def self.envuelve_antepuesto(klass, metodo, etiqueta)
    return unless klass.method_defined?(metodo) || klass.private_method_defined?(metodo)
    privado = klass.private_method_defined?(metodo)
    m = Module.new do
      define_method(metodo) do |*a, &b|
        t0 = NXMapa.reloj
        begin
          super(*a, &b)
        ensure
          NXMapa.suma(etiqueta, t0)
        end
      end
      # Los argumentos con nombre pasan tal cual: sin esto, un método con
      # palabras clave recibiría un Hash suelto y fallaría.
      ruby2_keywords(metodo)
      private metodo if privado
    end
    klass.prepend(m)
  end

  # Lo mismo con alias, para el detalle: anteponer módulos a cientos de
  # métodos que los plugins ya encadenaron con alias acaba en "stack level too
  # deep" (medido), porque un alias apunta al cuerpo y no al nombre.
  def self.envuelve_alias(klass, metodo, etiqueta)
    privado = klass.private_method_defined?(metodo)
    # El nombre del alias lleva la clase: Game_Event#update llama con super a
    # Game_Character#update, y si las dos copias se llamaran igual, el send de
    # la del padre volvería a caer en la del hijo (medido: otra vez "stack
    # level too deep").
    viejo = :"nx_det_#{klass.object_id}_#{metodo.to_s.sub(/[?!]$/) { |c| c == "?" ? "_p" : "_b" }}"
    return if klass.method_defined?(viejo) || klass.private_method_defined?(viejo)
    # Ni los que ya llevan delante un módulo de envuelve(): el alias cogería el
    # del módulo y la llamada daría vueltas sin fin.
    return if klass.instance_method(metodo).owner.is_a?(Module) &&
              !klass.instance_method(metodo).owner.is_a?(Class) &&
              klass.ancestors.index(klass.instance_method(metodo).owner).to_i < klass.ancestors.index(klass).to_i
    klass.send(:alias_method, viejo, metodo)
    klass.send(:define_method, metodo) do |*a, &b|
      t0 = NXMapa.reloj
      begin
        send(viejo, *a, &b)
      ensure
        NXMapa.suma(etiqueta, t0)
      end
    end
    klass.send(:ruby2_keywords, metodo)
    klass.send(:private, metodo) if privado
  rescue StandardError
    nil
  end

  def self.constante(nombre)
    nombre.split("::").inject(Object) { |o, c| o.const_get(c) }
  rescue NameError
    nil
  end

  def self.instala
    return if @instalado
    return unless defined?(Scene_Map) && $scene.is_a?(Scene_Map)
    # Unos fotogramas de margen: los shims que se instalan en el primer
    # Graphics.update con escena tienen que quedar por DENTRO de la sonda,
    # para que ella mida también lo que ellos se ahorran.
    @espera = (@espera || 0) + 1
    return if @espera < 30
    @instalado = true
    [
      ["Scene_Map", :update, "escena"],
      ["Scene_Map", :updateMaps, "mapas"],
      ["Scene_Map", :updateSpritesets, "spritesets"],
      ["Interpreter", :update, "interprete"],
      ["Game_Player", :update, "jugador"],
      ["Game_Map", :update, "game_map"],
      ["Game_Event", :update, "eventos"],
      ["Game_FollowerFactory", :update, "seguidores"],
      ["Spriteset_Map", :update, "spr_map"],
      ["Spriteset_Global", :update, "spr_global"],
      ["Sprite_Character", :update, "spr_char"],
      ["FollowerSprites", :update, "spr_seguidor"],
      ["RPG::Weather", :update, "clima"],
      ["TilemapRenderer", :update, "tilemap"],
      ["Sprite_Picture", :update, "spr_picture"],
      ["DynamicShadows", :update, "sombras"],
    ].each do |clase, metodo, etiqueta|
      k = constante(clase)
      envuelve(k, metodo, etiqueta) if k.is_a?(Module)
    end
    envuelve(Object, :pbDayNightTint, "tinte")
    envuelve(Input.singleton_class, :update, "entrada")
    # La cadena entera de Graphics.update, plugins incluidos, por fuera: con
    # alias, por lo dicho abajo. "graficos" es sólo el del motor, por dentro.
    Graphics.singleton_class.class_eval do
      alias_method :nx_mapa_cadena, :update
      def update(*a)
        t0 = NXMapa.reloj
        r = nx_mapa_cadena(*a)
        NXMapa.suma("cadena_graphics", t0)
        r
      end
    end
    envuelve_manejadores(:on_frame_update)
    envuelve_detalle
    log("[mapa] sonda puesta en #{$scene.class}")
  rescue StandardError => e
    log("[mapa] no se pudo poner: #{e.class} #{e.message}")
  end

  # Con nx-mapa-detalle.txt al lado del juego (una clase por línea), se
  # envuelven TODOS los métodos propios de esas clases: para bajar un escalón
  # cuando una fila de arriba es gorda y no se sabe de qué. Cuesta, y por eso
  # no va por omisión: lo que se lee con esto es el reparto, no el total.
  def self.envuelve_detalle
    return unless File.exist?("nx-mapa-detalle.txt")
    File.read("nx-mapa-detalle.txt").split("\n").map(&:strip).each do |nombre|
      next if nombre.empty? || nombre.start_with?("#")
      k = constante(nombre)
      next unless k.is_a?(Module)
      (k.instance_methods(false) + k.private_instance_methods(false)).uniq.each do |m|
        next if m.to_s.start_with?("nx_") || m.to_s.end_with?("=") || m == :initialize
        envuelve_alias(k, m, "#{nombre}##{m}")
        @detalle = (@detalle || 0) + 1
      end
    end
    log("[mapa] detalle: #{@detalle || 0} metodos envueltos")
  end

  # Cada proc de EventHandlers.add(:on_frame_update, :nombre, ...) se cambia
  # por uno que lo cronometra con su nombre.
  def self.envuelve_manejadores(evento)
    return unless defined?(EventHandlers)
    eventos = EventHandlers.class_variable_get(:@@events) rescue nil
    ne = eventos && eventos[evento]
    return unless ne
    cb = ne.instance_variable_get(:@callbacks)
    return unless cb.is_a?(Hash)
    cb.keys.each do |clave|
      orig = cb[clave]
      etiqueta = "fu:#{clave}"
      cb[clave] = proc do |*a|
        t0 = NXMapa.reloj
        begin
          orig.call(*a)
        ensure
          NXMapa.suma(etiqueta, t0)
        end
      end
    end
  end

  def self.cuenta_marco?
    return false unless $scene.is_a?(Scene_Map)
    return false if $game_temp && $game_temp.respond_to?(:message_window_showing) &&
                    $game_temp.message_window_showing
    true
  end

  def self.gc_ahora
    [GC.stat(:count), GC.respond_to?(:total_time) ? GC.total_time : 0,
     GC.stat(:total_allocated_objects), GC.stat(:minor_gc_count)]
  end

  # Se llama al principio de cada Graphics.update.
  def self.marca
    instala unless @instalado
    ahora = reloj
    anterior = @previo
    @previo = ahora
    unless anterior && @instalado && cuenta_marco?
      # Un fotograma que no cuenta parte la serie: lo que viene empieza limpio.
      reinicia if @marcos > 0 && !cuenta_marco?
      return
    end
    @gc0 ||= gc_ahora
    @pared += ahora - anterior
    @marcos += 1
    @andando += 1 if $game_player && $game_player.moving?
    informa if @marcos >= INFORME_CADA
  end

  def self.reinicia
    T.clear
    N.clear
    @marcos = 0
    @pared = 0.0
    @andando = 0
    @gc0 = nil
  end

  def self.informa
    n = @marcos.to_f
    g1 = gc_ahora
    g0 = @gc0 || g1
    ms = ->(k) { T[k] * 1000.0 / n }
    nombre = ($game_map.name rescue "?").to_s.b.each_byte.map { |b| (b >= 32 && b < 127) ? b.chr : "?" }.join
    eventos = ($game_map.events.size rescue 0)
    # Cuántos eventos se están actualizando de verdad y cuántos están en
    # pantalla: Game_Event#should_update? existe para no actualizar los que
    # quedan lejos, y si la primera cifra es mucho mayor que la segunda no
    # está recortando nada.
    vivos = ($game_map.events.values.count { |e| e.instance_variable_get(:@to_update) } rescue -1)
    dentro = ($game_map.events.values.count do |e|
      sx = e.screen_x; sy = e.screen_y_ground
      sx > -64 && sx < Graphics.width + 64 && sy > -64 && sy < Graphics.height + 96
    end rescue -1)
    eventos = "#{eventos} eventos (#{vivos} actualizados, #{dentro} en pantalla)"
    # Cuántos sprites dibuja el motor en cada fotograma: cada uno es una
    # llamada de dibujo con su sombreador y sus uniformes, y en la consola el
    # coste de una llamada al driver no es el del PC. Con tono, el sombreador
    # es el completo (SpriteShader) en vez del sencillo.
    vis = 0; tono = 0
    ObjectSpace.each_object(Sprite) do |sp|
      next if sp.disposed? || !sp.visible || sp.bitmap.nil? || sp.opacity == 0
      next if sp.viewport && (sp.viewport.disposed? || !sp.viewport.visible)
      vis += 1
      t = sp.tone
      tono += 1 if t.red != 0 || t.green != 0 || t.blue != 0 || t.gray != 0
    end rescue nil
    eventos += " | #{vis} sprites visibles (#{tono} con tono)"
    log(format("[mapa] %d %s | %d fotogramas %.1f ms/f (%.0f fps) | andando %d%% | %s | gc %d pasadas (%d menores) %.1f ms | %d obj/f",
               ($game_map.map_id rescue 0), nombre, @marcos, @pared * 1000.0 / n,
               n / @pared, @andando * 100 / @marcos, eventos,
               g1[0] - g0[0], g1[3] - g0[3], (g1[1] - g0[1]) / 1_000_000.0,
               (g1[2] - g0[2]) / @marcos))
    filas = T.keys.sort_by { |k| -T[k] }.map do |k|
      format("%s %.2f (%dx)", k, ms.(k), (N[k] / n).round)
    end
    log("[mapa]   ms/f: " + filas.join(" | "))
    if @pared * 1000.0 / n < 0.5 && !@pila_dicha
      # Fotogramas de nada: alguien llama a Graphics.update en un bucle vacío.
      @pila_dicha = true
      log("[mapa]   bucle vacio, pila: " + caller(0, 18).join("  <-  ").b.each_byte.map { |b| (b >= 32 && b < 127) ? b.chr : "?" }.join)
    end
    reinicia
  rescue StandardError => e
    log("[mapa] informe roto: #{e.class} #{e.message}")
    reinicia
  end
end

# ---------------------------------------------------------------------------
# El conductor. Sólo con nx-mapa-bot.txt al lado del juego.
module NXMapaBot
  ACTIVO = File.exist?("nx-mapa-bot.txt")
  LINEAS = ACTIVO ? (File.read("nx-mapa-bot.txt").split("\n").map(&:strip) rescue []) : []
  PARTIDA = (LINEAS[0].nil? || LINEAS[0].empty?) ? "Partida 1" : LINEAS[0]
  SEGUNDOS = LINEAS[1].to_i
  CUADRADO = [6, 2, 4, 8]
  TRAMO = 150   # fotogramas por lado del cuadrado

  @f = 0
  @en_mapa = 0
  @ultima_escena = nil
  @cargada = false
  @t_mapa = nil

  class << self
    attr_reader :f

    def listo?
      !@cargada && defined?(Game) && Game.respond_to?(:load) && defined?(SaveData) &&
        defined?(Scene_Map) && $data_system
    end

    # Carga la partida y se queda en el mapa DENTRO de este Graphics.update:
    # el bucle de Scene_Map#main vuelve a llamar a Graphics.update, y la
    # pantalla del título que estaba debajo no vuelve a correr nunca.
    def entra
      @cargada = true
      ruta = File.join(System.data_directory, PARTIDA + ".rxdata")
      NXMapa.log("[bot] cargando #{ruta}")
      Game.load(SaveData.read_from_file(ruta))
      $PokemonSystem.bgmvolume = 0 rescue nil
      $PokemonSystem.sevolume = 0 rescue nil
      # Si la pantalla de debajo estaba a media transición especial de
      # Essentials, su objeto seguiría vivo y el Graphics.transition del mapa
      # esperaría por él para siempre: se tira.
      if Graphics.class_variable_defined?(:@@transition)
        Graphics.class_variable_get(:@@transition)&.dispose rescue nil
        Graphics.class_variable_set(:@@transition, nil)
      end
      # Tercera línea opcional, "mapa x y": se aparece ahí, como si el
      # jugador hubiera cruzado una puerta.
      destino = LINEAS[2].to_s.split.map(&:to_i)
      if destino.length == 3
        $game_temp.player_transferring = true
        $game_temp.player_new_map_id = destino[0]
        $game_temp.player_new_x = destino[1]
        $game_temp.player_new_y = destino[2]
        $game_temp.player_new_direction = 2
      end
      $scene = Scene_Map.new unless $scene.is_a?(Scene_Map)
      NXMapa.log("[bot] en el mapa #{$game_map.map_id} (#{$game_player.x},#{$game_player.y})")
      $scene.main while $scene
      Kernel.exit!(0)
    end

    def paso
      @f += 1
      return entra if listo?
      if SEGUNDOS > 0 && @en_mapa > 0
        @t_mapa ||= Process.clock_gettime(Process::CLOCK_MONOTONIC)
        if Process.clock_gettime(Process::CLOCK_MONOTONIC) - @t_mapa > SEGUNDOS
          NXMapa.log("[bot] fin tras #{SEGUNDOS} s de mapa")
          Kernel.exit!(0)
        end
      end
      escena = $scene.class.to_s
      if escena != @ultima_escena
        @ultima_escena = escena
        NXMapa.log("[bot] f#{@f} escena #{escena}")
      end
      @en_mapa = (defined?(Scene_Map) && $scene.is_a?(Scene_Map)) ? @en_mapa + 1 : 0
      # Una foto de lo que dibuja el MOTOR (no de la ventana, que puede estar
      # tapada): sirve para comparar el mapa entre dos compilaciones.
      if [600, 1500].include?(@en_mapa) && Graphics.respond_to?(:snap_to_bitmap)
        begin
          b = Graphics.snap_to_bitmap
          b.to_file("nx-mapa-foto-#{@en_mapa}.png") if b.respond_to?(:to_file)
          b.dispose
          NXMapa.log("[bot] foto nx-mapa-foto-#{@en_mapa}.png")
        rescue StandardError => e
          NXMapa.log("[bot] sin foto: #{e.class} #{e.message}")
        end
      end
    end

    def mensaje?
      $game_temp && $game_temp.respond_to?(:message_window_showing) && $game_temp.message_window_showing
    end

    # Aceptar sólo con un mensaje abierto en el mapa, para cerrarlo.
    def aceptar?
      return false unless ACTIVO && @en_mapa > 0 && mensaje?
      (@f % 30) < 2
    end

    def direccion
      return 0 unless ACTIVO && @en_mapa > 180 && !mensaje?
      CUADRADO[((@en_mapa - 180) / TRAMO) % 4]
    end
  end
end

if NXMapaBot::ACTIVO
  module Input
    class << self
      alias_method :nx_bot_trigger?, :trigger?
      alias_method :nx_bot_press?, :press?
      alias_method :nx_bot_repeat?, :repeat?
      alias_method :nx_bot_dir4, :dir4
      alias_method :nx_bot_dir8, :dir8

      def trigger?(b)
        return true if b == Input::C && NXMapaBot.aceptar?
        nx_bot_trigger?(b)
      end

      def repeat?(b)
        return true if b == Input::C && NXMapaBot.aceptar?
        d = NXMapaBot.direccion
        return true if d != 0 && b == { 2 => Input::DOWN, 4 => Input::LEFT, 6 => Input::RIGHT, 8 => Input::UP }[d]
        nx_bot_repeat?(b)
      end

      def press?(b)
        return true if b == Input::C && NXMapaBot.aceptar?
        d = NXMapaBot.direccion
        return true if d != 0 && b == { 2 => Input::DOWN, 4 => Input::LEFT, 6 => Input::RIGHT, 8 => Input::UP }[d]
        nx_bot_press?(b)
      end

      def dir4
        d = NXMapaBot.direccion
        d != 0 ? d : nx_bot_dir4
      end

      def dir8
        d = NXMapaBot.direccion
        d != 0 ? d : nx_bot_dir8
      end
    end
  end
end

# Con alias y no con un módulo antepuesto, y a propósito: los plugins de
# Essentials encadenan Graphics.update con alias, y un alias tomado DESPUÉS de
# anteponer apunta al método antepuesto; la llamada vuelve a entrar por él y
# no termina nunca (medido: el plugin de Discord y esta sonda llamándose el uno
# al otro, un millón de "fotogramas" por segundo). Por eso tampoco se mide
# Graphics.update desde instala: ahí ya están todos los alias puestos.
module Graphics
  class << self
    alias_method :nx_mapa_update, :update
    def update(*a)
      begin
        unless NXMapa.instance_variable_get(:@visto)
          NXMapa.instance_variable_set(:@visto, true)
          NXMapa.log("[mapa] primer Graphics.update")
        end
        NXMapaBot.paso if NXMapaBot::ACTIVO
        NXMapa.marca
      rescue StandardError => e
        # Un instrumento nunca debe poder tumbar el juego que mide.
        NXMapa.log("[mapa] fallo en la sonda: #{e.class} #{e.message} #{e.backtrace&.first}")
      end
      t0 = NXMapa.reloj
      r = nx_mapa_update(*a)
      NXMapa.suma("graficos", t0)
      r
    end
  end
end

NXMapa.log("[mapa] sonda de mapa cargada (bot: #{NXMapaBot::ACTIVO})")
