# nx-guion.rb — conduce el juego desde dentro, sin teclado ni foco.
#
# jugar.ps1 manda las pulsaciones con keybd_event, que va a la ventana ACTIVA:
# para que lleguen al emulador hay que quitarle el foco a quien este usando la
# maquina, y cualquier ventana que se ponga delante se come la tecla. Esta
# sonda hace lo mismo sin salir del juego: lee un guion de la carpeta del juego
# y contesta ella las preguntas a Input mientras dure, y las fotos las saca con
# Graphics.snap_to_bitmap en vez de copiar la pantalla. El emulador puede estar
# minimizado o detras de cualquier cosa.
#
# GUION: nx-guion.txt en la carpeta del juego, una orden por linea:
#
#   Z | X | C | ARRIBA | ABAJO | IZQUIERDA | DERECHA [n]
#       el boton de la Switch que en Ryujinx sale de esa tecla (Z = A = aceptar,
#       X = B = cancelar, C = X = menu), sostenido n fotogramas (8 si no se
#       dice) y suelto otros 8 despues
#   Z hasta        Z cada medio segundo hasta que el jugador tenga el control
#                  (sirve con cualquier boton): pasa titulo, avisos, la
#                  pantalla de carga y las escenas, sin contar las cajas
#   esperar n      n fotogramas sin tocar nada
#   hasta          sin tocar nada, hasta que el jugador tenga el control
#   foto nombre    nx-guion-<nombre>.t<i>.png en la carpeta del juego
#   ruby codigo    evalua el resto de la linea y apunta lo que devuelve
#   salir          cierra el juego
#   # ...          comentario
#
# Cada orden deja una linea [guion] en mkxp-ruby.log con el mapa y la casilla
# del jugador. Sin nx-guion.txt no hace nada y el mando funciona normal.
#
# Solo para diagnostico: no se carga en produccion.

module NXGuion
  FICHERO = "nx-guion.txt"
  SUELTA = 8

  BOTONES = {
    "Z" => :C, "X" => :B, "C" => :A,
    "ARRIBA" => :UP, "ABAJO" => :DOWN, "IZQUIERDA" => :LEFT, "DERECHA" => :RIGHT
  }
  DIR = { :DOWN => 2, :LEFT => 4, :RIGHT => 6, :UP => 8 }

  @cola = []
  @boton = nil      # simbolo de Input sostenido ahora
  @sostiene = 0     # fotogramas que le quedan sostenido
  @pausa = 0        # fotogramas de espera antes de la siguiente orden
  @marco = 0        # fotogramas desde que se sostiene (para trigger/repeat)
  @n = 0
  @hasta = false    # esperando a que el jugador tenga el control
  @insiste = nil    # boton que se pulsa mientras tanto
  @quieto = 0       # fotogramas seguidos con el control
  @tope = 0
  ESTABLE = 30      # una caja que se cierra deja un hueco de un fotograma
  TOPE_HASTA = 60 * 120

  def self.log(t)
    NX.log(t) if defined?(NX) && NX.respond_to?(:log)
  end

  def self.carga
    return unless File.file?(FICHERO)
    File.readlines(FICHERO).each do |l|
      l = l.strip
      next if l.empty? || l.start_with?("#")
      @cola << (l =~ /\Aruby\s+/i ? ["RUBY", $'] : l.split(/\s+/))
    end
    log("[guion] #{@cola.size} ordenes de #{FICHERO}")
  rescue StandardError => e
    log("[guion] no se pudo leer #{FICHERO}: #{e.class}: #{e.message}")
  end

  def self.activo? = !@cola.empty? || @boton || @pausa > 0 || @hasta

  # Lo que en RPG Maker XP quiere decir que el jugador se puede mover.
  def self.control?
    return false unless defined?(Scene_Map) && $scene.is_a?(Scene_Map)
    return false if $game_temp.message_window_showing
    return false if $game_temp.player_transferring || $game_temp.transition_processing
    return false if $game_system.map_interpreter.running?
    return false if $game_player.move_route_forcing
    true
  rescue StandardError
    false
  end

  def self.donde
    return "" unless defined?($game_map) && $game_map && defined?($game_player) && $game_player
    " (mapa #{$game_map.map_id} en #{$game_player.x},#{$game_player.y})"
  rescue StandardError
    ""
  end

  # Una vez por fotograma, desde Input.update.
  def self.avanza
    if @boton
      @marco += 1
      @sostiene -= 1
      if @sostiene <= 0
        @boton = nil
        @pausa = SUELTA
      end
      return
    end
    if @pausa > 0
      @pausa -= 1
      return
    end
    if @hasta
      @tope += 1
      @quieto = control? ? @quieto + 1 : 0
      if @quieto >= ESTABLE || @tope >= TOPE_HASTA
        log("[guion] #{@quieto >= ESTABLE ? 'control' : 'TOPE sin control'} tras #{@tope} fotogramas#{donde}")
        @hasta = false
        @insiste = nil
      elsif @insiste && @quieto == 0 && @tope % 30 == 0
        @boton = @insiste
        @sostiene = 8
        @marco = 0
      end
      return
    end
    orden = @cola.shift
    return unless orden
    @n += 1
    nombre, arg = orden
    log("[guion] #{@n}: #{orden.join(' ')}#{donde}")
    case nombre.upcase
    when "ESPERAR"
      @pausa = arg.to_i
    when "HASTA"
      empieza_hasta(nil)
    when "RUBY"
      begin
        log("[guion] => #{TOPLEVEL_BINDING.eval(arg).inspect}")
      rescue Exception => e
        log("[guion] => #{e.class}: #{e.message}")
      end
    when "FOTO"
      foto(arg || @n.to_s)
    when "SALIR"
      log("[guion] fin")
      exit
    else
      sim = BOTONES[nombre.upcase]
      if sim && arg && arg.upcase == "HASTA"
        empieza_hasta(sim)
      elsif sim
        @boton = sim
        @sostiene = (arg || 8).to_i
        @marco = 0
      else
        log("[guion] orden desconocida: #{nombre}")
      end
    end
  end

  def self.empieza_hasta(sim)
    @hasta = true
    @insiste = sim
    @quieto = 0
    @tope = 0
  end

  # En Ryujinx, leer un Bitmap creado en memoria con un ancho multiplo de 16
  # trae solo la cuarta parte de las columnas (nx-lote-ab.rb lo cuenta). Asi
  # que la foto se guarda en tiras de 171, nx-guion-<nombre>.t<i>.png, que se
  # cosen en el PC.
  TIRA = 171

  def self.foto(nombre)
    b = Graphics.snap_to_bitmap
    (0...b.width).step(TIRA).each_with_index do |x0, i|
      cw = [TIRA, b.width - x0].min
      t = Bitmap.new(cw, b.height)
      t.blt(0, 0, b, Rect.new(x0, 0, cw, b.height))
      t.to_file("nx-guion-#{nombre}.t#{i}.png")
      t.dispose
    end
    b.dispose
  rescue StandardError => e
    log("[guion] foto #{nombre}: #{e.class}: #{e.message}")
  end

  def self.codigo
    @boton ? Input.const_get(@boton) : nil
  end

  def self.press?(k) = (codigo == k)
  def self.trigger?(k) = (codigo == k && @marco == 0)
  # La cadencia de repeat? del motor: el primero, y luego cada 6 tras 24.
  def self.repeat?(k) = (codigo == k && (@marco == 0 || (@marco >= 24 && @marco % 6 == 0)))
  def self.dir = (@boton ? (DIR[@boton] || 0) : 0)

  # Antepuesto y no con alias: el juego reescribe Input entero y
  # NX18Tarde.entrada lo repone con define_method en cada seccion, y un modulo
  # antepuesto sigue delante de todo eso.
  module Entrada
    def update
      super
      NXGuion.avanza
    end
    def press?(k)   = NXGuion.activo? ? NXGuion.press?(k)   : super
    def trigger?(k) = NXGuion.activo? ? NXGuion.trigger?(k) : super
    def repeat?(k)  = NXGuion.activo? ? NXGuion.repeat?(k)  : super
    def dir4        = NXGuion.activo? ? NXGuion.dir         : super
    def dir8        = NXGuion.activo? ? NXGuion.dir         : super
  end
end

NXGuion.carga
Input.singleton_class.prepend(NXGuion::Entrada) if NXGuion.activo?
