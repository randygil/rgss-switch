# nx-fondo-desborde.rb — sonda: reproduce la muerte silenciosa del proceso.
#
# El caso, tal y como lo conto el jugador: al llegar a Ciudad Verde baja a la
# ruta 1, interactua con un Pidgey y el juego se cierra. Sin pantalla de error y
# sin excepcion de Ruby: la consola vuelve al menu. Lo mismo que paso el 4 de
# septiembre configurando el Nuzlocke (README 5.64).
#
# El Pidgey no tiene la culpa. El culpable es el contador de objetos del fondo
# de texturas, que en la 1.0.0 y la 1.1.0 es de 16 bits. Lo que hace el juego
# antes de llegar a la ruta 1 —la intro, el laboratorio, el rival, media hora de
# cuadros de texto— es fabricar texturas diminutas a miles. Cuando el contador
# pasa de 65.535 da la vuelta a cero, el bucle de desalojo de release() sale por
# su `if (objCount == 0) break;` sin borrar nada, y a partir de ese momento el
# fondo crece SIN TECHO. La siguiente escena cara —un combate— pide una textura,
# el driver no puede darla, glTexImage2D deja GL_OUT_OF_MEMORY, Mesa cuelga del
# FBO una textura sin recurso detras y se desreferencia un nulo.
#
# Aqui eso se provoca en segundos en vez de en media hora de partida:
#
#   fase 1  N texturas de 1x1 vivas a la vez, y se sueltan todas de golpe.
#           Son 280 KB en total: no se acerca al presupuesto ni de lejos, asi
#           que NADA las desaloja y el contador llega a 70.000 limpiamente.
#           Con 16 bits eso son 4.464. Ahi esta el desbordamiento, y el registro
#           lo ensena como el desajuste entre "contadas" y "en cola".
#
#   fase 2  texturas grandes de tamanos distintos, que si pesan. En un fondo
#           sano el desalojo las va tirando y el tamano se queda clavado en el
#           presupuesto. Con el contador dado la vuelta, el desalojo se rinde en
#           cuanto el contador llega a cero —quedando en la cola las 65.536 que
#           no ha mirado— y el tamano sube y sube.
#
#   fase 3  el encuentro del jugador: WildBattle.start(:PIDGEY).
#
# Cada paso se registra ANTES de darlo. Si el proceso muere de golpe, la ultima
# linea de mkxp-ruby.log dice hasta donde llego.
#
# Necesita diagnostico.txt en la carpeta del juego para que el lado C++ escriba
# sus lineas [fondo]. No se carga en produccion.

module NXFondo
  # Cuantas texturas diminutas se tienen vivas a la vez. Tiene que pasar de
  # 65.536, que es lo que cabe en el contador de 16 bits, con margen suficiente
  # para que el desajuste se lea de un vistazo.
  # A ESCALA DE LA MAQUETA. El motor compilado con NX_FONDO_MAQUETA lleva el
  # contador de 8 bits y el presupuesto en 2 MB: la misma relacion que 65.536 y
  # 512 MB, 256 veces mas barata. Para el motor de verdad hay que subir estas
  # constantes y entonces solo vale la consola: el emulador no llega.
  MINIMAS      = 400
  LOTE_AVISO   = 100

  # Fase 2. Cada textura es de un ancho distinto para que la peticion FALLE y
  # haya que crearla: si se pidiera siempre el mismo tamano, el fondo la
  # serviria de su propio alijo y no creceria nada.
  GRANDES      = 200
  ALTO_GRANDE  = 128
  ANCHO_BASE   = 128

  @paso  = 0
  @hecho = false
  class << self
    attr_accessor :hecho, :paso
  end

  def self.log(msg)
    NX.log("[fondo] #{msg}")
  end

  # La sonda mete un Pokemon en el equipo si hace falta, asi que mientras este
  # puesta el juego NO puede guardar: bastaria una autopartida para dejar la
  # partida de verdad tocada. Se tapan las dos puertas.
  def self.prohibe_guardar
    return if @sin_guardar
    @sin_guardar = true
    if defined?(Game) && Game.respond_to?(:save)
      Game.define_singleton_method(:save) do |*_a, **_k|
        NXFondo.log("GUARDADO BLOQUEADO (Game.save)")
        false
      end
    end
    if defined?(SaveData) && SaveData.respond_to?(:save_to_file)
      SaveData.define_singleton_method(:save_to_file) do |*_a|
        NXFondo.log("GUARDADO BLOQUEADO (SaveData.save_to_file)")
        nil
      end
    end
    log("guardado bloqueado mientras la sonda este puesta")
  end

  def self.listo?
    return false unless defined?($scene) && $scene.class.to_s == "Scene_Map"
    return false if defined?($game_temp) && $game_temp && $game_temp.message_window_showing
    return false if respond_to?(:pbMapInterpreterRunning?) && pbMapInterpreterRunning?
    true
  end

  # --------------------------------------------------------------- fase 1
  def self.fase_minimas
    log("fase 1: #{MINIMAS} texturas de 1x1 vivas a la vez")
    t0 = Time.now
    vivas = []
    i = 0
    while i < MINIMAS
      vivas << Bitmap.new(1, 1)
      i += 1
      if (i % LOTE_AVISO).zero?
        ms = ((Time.now - t0) * 1000).round
        log("  #{i} creadas en #{ms} ms (#{(i * 1000.0 / [ms, 1].max).round}/s)")
      end
    end
    log("  creadas #{vivas.length} en #{((Time.now - t0) * 1000).round} ms")

    # Soltarlas todas. Cada dispose devuelve su textura al fondo y sube el
    # contador en uno. Ninguna se desaloja: N texturas de 1x1 son 280 KB
    # y el presupuesto son 512 MB.
    log("  soltandolas todas -> aqui es donde el contador da la vuelta")
    t1 = Time.now
    vivas.each { |b| b.dispose rescue nil }
    vivas.clear
    GC.start
    log("  soltadas en #{((Time.now - t1) * 1000).round} ms")
  end

  # --------------------------------------------------------------- fase 2
  def self.fase_grandes
    log("fase 2: #{GRANDES} texturas grandes de tamanos distintos")
    log("  un fondo sano se queda clavado en 512 MB; uno desbordado sube sin techo")
    t0 = Time.now
    i = 0
    while i < GRANDES
      ancho = ANCHO_BASE + i          # cada una de un tamano distinto
      b = Bitmap.new(ancho, ALTO_GRANDE)
      b.dispose
      i += 1
      if (i % 25).zero?
        kb = (i * ancho * ALTO_GRANDE * 4) / 1024
        log("  #{i} sueltas (unos #{kb} KB pedidos) en " \
            "#{((Time.now - t0) * 1000).round} ms")
      end
    end
    log("  fase 2 terminada en #{((Time.now - t0) * 1000).round} ms")
  end

  # --------------------------------------------------------------- fase 3
  def self.fase_pidgey
    unless defined?(WildBattle) && WildBattle.respond_to?(:start)
      log("fase 3: no hay WildBattle; se salta")
      return
    end
    prohibe_guardar
    if $player.party.empty?
      pbAddPokemonSilent(:CHARMANDER, 5)
      log("fase 3: equipo vacio; se anade el inicial de nivel 5")
    end
    log("fase 3: equipo #{$player.party.map { |p| "#{p.species} N#{p.level}" }.inspect}")
    log("fase 3: WildBattle.start(:PIDGEY, 2) — el encuentro del jugador")
    t0 = Time.now
    r = WildBattle.start(:PIDGEY, 2)
    log("fase 3: terminado -> #{r.inspect} en #{((Time.now - t0) * 1000).round} ms")
  end

  def self.revisar
    return unless listo?
    @hecho = true
    log("sonda en marcha; build del motor en la primera linea de mkxp-boot.log")
    fase_minimas
    fase_grandes
    fase_pidgey
    log("FIN: el proceso ha sobrevivido a las tres fases")
  rescue Exception => e
    @hecho = true
    log("EXCEPCION #{e.class}: #{e.message}")
    (e.backtrace || []).first(8).each { |l| log("  #{l}") }
  end
end

module Graphics
  class << self
    alias_method :nx_update_sin_fondo, :update

    def update
      NXFondo.revisar unless NXFondo.hecho
      nx_update_sin_fondo
    end
  end
end

NX.log("[fondo] sonda instalada")
