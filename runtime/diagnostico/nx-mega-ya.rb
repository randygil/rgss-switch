# nx-mega-ya.rb — sonda: reproduce la megaevolucion que tumba el juego.
#
# El caso, tal y como lo conto el jugador: combate contra el Ladron Matias -el
# del laberinto de la Mansion Pokemon, mapa 121-, cuyo Shiftry es de nivel 55.
# Entra con un Pikachu que lleva Pikachuita, cambia a su Charizard de nivel 59
# -Pulso Dragon, Tajo Aereo, Garra Dragon y Lanzallamas-, megaevoluciona y se
# cae.
#
# Llegar ahi jugando son horas. Aqui se monta el equipo, se lanza el combate y
# se le quitan las manos al jugador: la sonda escribe las ordenes del turno
# directamente donde las escribe el menu cuando alguien pulsa.
#
#   turno 1  cambiar al Charizard        (pbRegisterSwitch)
#   turno 2  megaevolucionar y atacar    (pbRegisterMegaEvolution + pbRegisterMove)
#
# Cada paso se registra ANTES de darlo. Si el proceso muere sin excepcion —que
# es lo que hizo—, la ultima linea de mkxp-ruby.log dice hasta donde llego.
#
# No se carga en produccion.

module NXMega
  # El equipo del caso. Cambiar aqui para probar variantes: la piedra del
  # Charizard (X o Y), la del Pikachu, o quitarsela a uno de los dos.
  PIEDRA_PIKACHU   = :PIKACHUITE
  PIEDRA_CHARIZARD = :CHARIZARDITEX
  MOVIMIENTOS      = [:DRAGONPULSE, :AERIALACE, :DRAGONCLAW, :FLAMETHROWER]
  # El entrenador, tal cual lo invoca el evento de Map121:
  #   TrainerBattle.start(:LADRON, "Matias", 0)
  RIVAL_TIPO       = :LADRON
  RIVAL_NOMBRE     = "Matías"
  RIVAL_VERSION    = 0

  @hecho     = false
  @parcheado = false
  @paso      = 0

  class << self
    attr_accessor :hecho, :paso
  end

  def self.log(msg)
    NX.log("[mega] #{msg}")
  end

  # La sonda vacia el equipo del jugador para poner el suyo, asi que mientras
  # este puesta el juego NO puede guardar: bastaria una autopartida -el juego
  # trae "Guardar al curar"- para dejar la partida de verdad con un Pikachu y
  # un Charizard de mentira. Se tapan las dos puertas, la de arriba y la de
  # abajo, y se deja constancia en el registro.
  def self.prohibe_guardar
    return if @sin_guardar
    @sin_guardar = true

    Game.define_singleton_method(:save) do |*_args, **_kw|
      NXMega.log("GUARDADO BLOQUEADO (Game.save) mientras la sonda esta puesta")
      false
    end
    SaveData.define_singleton_method(:save_to_file) do |*_args|
      NXMega.log("GUARDADO BLOQUEADO (SaveData.save_to_file)")
      nil
    end
    log("guardado bloqueado")
  end

  def self.arma_equipo
    prohibe_guardar
    # El juego lleva Level Caps EX, que engancha Pokemon#level= y recorta al
    # tope por medallas: pedir un Charizard de 59 en una partida temprana
    # devuelve uno de 14. El interruptor 29 es la puerta de atras del propio
    # plugin (LevelCapsEX::LEVEL_CAP_BYPASS_SWITCH).
    $game_switches[29] = true
    log("interruptor 29 (saltarse el tope de nivel) = #{$game_switches[29]}")

    # El interruptor no basta. Level Caps EX ademas redefine
    # GameData::GrowthRate.max_level como el tope por medallas, y Pokemon#level=
    # recorta CUALQUIER nivel por encima de ese maximo antes de mirar el
    # interruptor: en una partida temprana pedir un 59 devuelve un 14 y el
    # combate no se parece en nada al del jugador. Se levanta el tope entero.
    if defined?(LevelCapsEX)
      LevelCapsEX.define_singleton_method(:hard_level_cap) { 100 }
      LevelCapsEX.define_singleton_method(:level_cap)      { 100 }
      LevelCapsEX.define_singleton_method(:hard_cap?)      { false }
      LevelCapsEX.define_singleton_method(:soft_cap?)      { false }
      log("tope de nivel levantado a 100")
    end

    $player.party.clear

    pika = Pokemon.new(:PIKACHU, 50)
    pika.item = PIEDRA_PIKACHU if PIEDRA_PIKACHU
    $player.party.push(pika)

    zard = Pokemon.new(:CHARIZARD, 59)
    zard.item = PIEDRA_CHARIZARD if PIEDRA_CHARIZARD
    zard.moves.clear
    MOVIMIENTOS.each { |m| zard.learn_move(m) }
    $player.party.push(zard)

    $player.party.each_with_index do |p, i|
      mega = (p.hasMegaForm? rescue "?")
      log("equipo #{i}: #{p.species} N#{p.level} objeto=#{p.item_id.inspect} " \
          "movs=#{p.moves.map { |m| m.id }.inspect} hasMegaForm?=#{mega}")
    end
  end

  # Battle no existe cuando esto se carga: los preloadScript corren ANTES de
  # que el juego defina sus clases. Se parchea cuando ya esta, justo antes de
  # empezar el combate.
  def self.parchea_battle
    return if @parcheado
    @parcheado = true

    Battle.class_eval do
      alias_method :nx_mega_pbCommandPhaseLoop, :pbCommandPhaseLoop

      def pbCommandPhaseLoop(isPlayer)
        return nx_mega_pbCommandPhaseLoop(isPlayer) if !isPlayer

        NXMega.paso += 1
        b = @battlers[0]
        puede = (pbCanMegaEvolve?(0) rescue "?")
        tiene = (b.hasMega? rescue "?")
        NXMega.log("turno #{NXMega.paso}: en pista #{b.pokemon.species} " \
                   "objeto=#{b.item_id.inspect} hasMega?=#{tiene} puedeMega?=#{puede}")

        case NXMega.paso
        when 1
          NXMega.log("turno 1: cambio al hueco 1 (Charizard)")
          ok = pbRegisterSwitch(0, 1)
          NXMega.log("turno 1: pbRegisterSwitch -> #{ok.inspect}")
          return nx_mega_pbCommandPhaseLoop(isPlayer) if !ok
        when 2
          NXMega.log("turno 2: registrando megaevolucion")
          pbRegisterMegaEvolution(0)
          NXMega.log("turno 2: @megaEvolution=#{@megaEvolution.inspect}")
          pbRegisterMove(0, 0, false)
          NXMega.log("turno 2: orden #{@choices[0].inspect}; empieza el turno")
        else
          # A partir de aqui no hay guion: que el combate siga solo.
          return nx_mega_pbCommandPhaseLoop(isPlayer)
        end
      end
    end

    log("Battle parcheada")
  end

  def self.revisar
    return unless defined?(TrainerBattle) && TrainerBattle.respond_to?(:start)
    return unless defined?($player) && $player
    return unless defined?($scene) && $scene.class.to_s == "Scene_Map"
    return if defined?($game_temp) && $game_temp && $game_temp.message_window_showing
    return if respond_to?(:pbMapInterpreterRunning?) && pbMapInterpreterRunning?

    @hecho = true
    arma_equipo
    parchea_battle
    log("arrancando TrainerBattle.start(#{RIVAL_TIPO.inspect}, #{RIVAL_NOMBRE.inspect}, #{RIVAL_VERSION})")
    resultado = TrainerBattle.start(RIVAL_TIPO, RIVAL_NOMBRE, RIVAL_VERSION)
    log("combate terminado -> #{resultado.inspect}")
  rescue Exception => e
    @hecho = true
    log("FALLO #{e.class}: #{e.message}")
    (e.backtrace || []).first(12).each { |l| log("  #{l}") }
  end
end

#-------------------------------------------------------------------------------
# Pasar la pantalla de titulo sin manos.
#
# La sonda solo entra cuando el juego ya esta en el mapa, y para llegar ahi hay
# que pulsar A en el titulo y otra vez en "Continuar". Mandar teclas al emulador
# desde fuera funciona pero exige la ventana en primer plano y capturas de
# pantalla; se hace aqui dentro, que es mas limpio y ademas vale igual en la
# consola. Se deja de fingir en cuanto aparece el mapa, para no ir pulsando
# cosas dentro del combate.
#-------------------------------------------------------------------------------
module NXMega
  @marcos = 0

  # Se finge la pulsacion SIEMPRE, tambien dentro del combate: $scene sigue
  # siendo Scene_Map mientras se pelea, y los cuadros de texto de Essentials
  # esperan a que alguien pulse A. Sin esto la sonda se queda en el primer
  # mensaje del turno.
  # Un latido con la pila de Ruby cada 300 fotogramas. Si el juego se queda
  # colgado, esto dice si el bucle principal sigue vivo -y por donde anda- o si
  # se ha parado por debajo de Ruby, que son dos averias distintas.
  @latidos = 0
  def self.latido
    return unless @hecho
    @latidos += 1
    return unless (@latidos % 300).zero?
    log("latido #{@latidos}:")
    caller(1, 12).each { |l| log("   #{l}") }
  end

  def self.finge_pulsacion?
    @marcos += 1
    (@marcos % 20).zero?
  end
end

module Input
  class << self
    alias_method :nx_mega_trigger?, :trigger?

    def trigger?(button)
      return true if button == Input::C && NXMega.finge_pulsacion?
      nx_mega_trigger?(button)
    end
  end
end

module Graphics
  class << self
    alias_method :nx_update_sin_mega, :update

    def update
      NXMega.revisar unless NXMega.hecho
      NXMega.latido
      nx_update_sin_mega
    end
  end
end

NX.log("[mega] sonda instalada")
