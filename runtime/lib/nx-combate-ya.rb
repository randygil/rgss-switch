# nx-combate-ya.rb — sonda: mete al jugador en un combate salvaje.
#
# El combate es la escena mas cara del juego —fondo, dos sprites grandes,
# animaciones de ataque, ventanas de texto y musica propia— y es lo unico que
# quedaba por medir. Llegar a uno jugando exige salir de casa, cruzar el pueblo
# y meterse en la hierba alta, que son varios minutos de mando guionizado por
# cada intento.
#
# Asi que se llama a WildBattle.start directamente, que es lo mismo que hace el
# juego al pisar hierba. Si el equipo esta vacio —lo normal nada mas empezar,
# antes de que el profesor de el inicial— se le pone un Pokemon, porque
# BattleCreationHelperMethods.skip_battle? se salta el combate si no hay ninguno
# en condiciones y no habria nada que medir.
#
# Espera a que la sonda de guardado haya terminado: interesa este orden, primero
# guardar el estado limpio y luego romperlo con un combate de mentira.
#
# No se carga en produccion.

module NXCombate
  @hecho = false
  class << self
    attr_accessor :hecho
  end

  def self.revisar
    # Si la sonda de guardado esta puesta, esperar a que acabe: interesa este
    # orden. Si no lo esta, adelante.
    return if defined?(NXGuardarYa) && !NXGuardarYa.hecho
    return unless defined?(WildBattle) && WildBattle.respond_to?(:start)
    return unless defined?($player) && $player
    return unless defined?($scene) && $scene.class.to_s == "Scene_Map"
    return if defined?($game_temp) && $game_temp && $game_temp.message_window_showing
    return if respond_to?(:pbMapInterpreterRunning?) && pbMapInterpreterRunning?

    @hecho = true

    if $player.party.empty?
      pbAddPokemonSilent(:PIKACHU, 20)
      NX.log("[combate] equipo vacio; se anade PIKACHU nivel 20")
    end
    NX.log("[combate] equipo: " +
           $player.party.map { |p| "#{p.species} N#{p.level}" }.inspect)

    t0 = Time.now
    NX.log("[combate] arrancando WildBattle.start(:PIDGEY, 15)")
    resultado = WildBattle.start(:PIDGEY, 15)
    NX.log("[combate] terminado -> #{resultado.inspect} en " +
           "#{((Time.now - t0) * 1000).round} ms")
  rescue Exception => e
    @hecho = true
    NX.log("[combate] FALLO #{e.class}: #{e.message}")
    (e.backtrace || []).first(6).each { |l| NX.log("[combate]   #{l}") }
  end
end

module Graphics
  class << self
    alias_method :nx_update_sin_combate, :update

    def update
      NXCombate.revisar unless NXCombate.hecho
      nx_update_sin_combate
    end
  end
end

NX.log("[combate] sonda instalada")
