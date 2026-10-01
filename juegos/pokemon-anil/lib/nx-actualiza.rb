# nx-actualiza.rb — que la pantalla de carga no espere a internet.
#
# Al abrir la pantalla de carga (pbStartLoadScreen, la de "Continuar / Partida
# nueva"), Anil llama a PokeUpdater.check_for_updates ANTES de pintar el menu,
# y eso es, en el mismo fotograma: network_available? -un GET por HTTPS a
# google.com, y si falla a 1.1.1.1, a 8.8.8.8 y a api.github.com- y despues
# pbDownloadToString de un pastebin con la ultima version del juego. Hasta la
# 0.1.x esto no costaba nada en la consola porque HTTPLite fallaba al momento;
# desde que el motor tiene red (0.2.0) se hace de verdad, por Wi-Fi y con el
# TLS del servicio ssl de Horizon, una vez por arranque. En el PC, con fibra,
# solo network_available? ya eran 0,5 s (bitacora §5.72); sin red, cada
# intento fallido puede llegar al plazo de conexion de libcurl.
#
# El aviso de "hay version nueva" es informacion para el jugador y se respeta:
# lo que se cambia es CUANDO se pregunta a la red, no lo que se hace con la
# respuesta. La pregunta se lanza en un hilo de Ruby en cuanto el plugin existe
# (el primer Graphics.update con los scripts cargados: la intro y el titulo
# dan segundos de margen), y HTTPLite suelta el GVL mientras espera, asi que el
# juego sigue dibujando. Cuando el juego llega a la pantalla de carga:
#
#   - si la respuesta ya llego, se hace lo mismo que el original con ella
#     (validate_version, con sus mensajes y sus preguntas, desde el hilo
#     principal y sin volver a descargar nada);
#   - si no ha llegado, este arranque no se espera: es lo mismo que haria el
#     original sin red. El boton "Buscar actualizaciones" del menu sigue
#     siendo el de siempre y si espera, porque ahi lo ha pedido el jugador.
#
# Lo mismo para la vuelta al titulo: la respuesta se usa una sola vez por
# arranque, igual que el original pregunta una vez por pantalla de carga... y
# la segunda vez ya no espera a nada.

module NXActualiza
  @instalado = false
  @hilo = nil
  @url = nil
  @datos = nil        # lo que devolvio el pastebin ("" o nil si no hubo red)
  @usada = false

  class << self
    attr_reader :instalado

    def reloj
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def lanza
      cfg = PokeUpdater::Config.poke_updater_config
      PokeUpdater.fill_updater_config if !cfg || !cfg['PASTEBIN_URL']
      cfg = PokeUpdater::Config.poke_updater_config
      @url = cfg && cfg['PASTEBIN_URL']
      return if @url.nil? || @url == ''
      t0 = reloj
      @hilo = Thread.new do
        Thread.current.report_on_exception = false
        datos = nil
        begin
          datos = pbDownloadToString(@url) if network_available?
        rescue Exception
          # MKXPError (lo que lanza HTTPLite sin red) no hereda de
          # StandardError, y pbDownloadToString solo rescata StandardError.
          datos = nil
        end
        @datos = datos
        NX.log(format("[actualiza] respuesta de la red en %.0f ms (%s)", (reloj - t0) * 1000.0,
                      (datos.nil? || datos.empty?) ? "sin datos" : "#{datos.bytesize} bytes"))
      end
    end

    # La respuesta que trajo el hilo, una sola vez y solo para su URL.
    def toma(url)
      return nil unless @hilo && !@hilo.alive? && !@usada && url == @url
      @usada = true
      @datos
    end

    def comprueba
      return if $DEBUG
      if @hilo.nil? || @usada
        return
      elsif @hilo.alive?
        @usada = true
        NX.log("[actualiza] la red aun no ha contestado: este arranque no se espera")
        return
      end
      datos = @datos
      if datos.nil? || datos.empty?
        @usada = true
        return
      end
      # validate_version descarga la URL otra vez; aqui contesta toma().
      PokeUpdater.validate_version(@url, false)
    ensure
      @usada = true
    end

    def instala
      return true if @instalado
      return false unless Object.const_defined?(:PokeUpdater) &&
                          PokeUpdater.respond_to?(:check_for_updates) &&
                          PokeUpdater.respond_to?(:validate_version) &&
                          PokeUpdater.respond_to?(:fill_updater_config) &&
                          (Object.private_method_defined?(:pbDownloadToString) ||
                           Object.method_defined?(:pbDownloadToString)) &&
                          (Object.private_method_defined?(:network_available?) ||
                           Object.method_defined?(:network_available?))
      @instalado = true

      Object.class_eval do
        alias_method :nx_pbDownloadToString_sin_memoria, :pbDownloadToString
        def pbDownloadToString(url)
          datos = NXActualiza.toma(url) if Thread.current == Thread.main
          return datos unless datos.nil?
          nx_pbDownloadToString_sin_memoria(url)
        end
      end

      PokeUpdater.singleton_class.class_eval do
        alias_method :nx_check_for_updates_bloqueante, :check_for_updates
        def check_for_updates(from_update_button = false)
          return nx_check_for_updates_bloqueante(from_update_button) if from_update_button
          NXActualiza.comprueba
        end
      end

      begin
        lanza
      rescue StandardError => e
        NX.log("[actualiza] no se pudo lanzar la pregunta: #{e.class}: #{e.message}")
      end
      NX.log("[actualiza] la pantalla de carga no espera a la red")
      true
    end
  end
end

module Graphics
  class << self
    alias_method :nx_update_sin_actualiza, :update

    def update
      NXActualiza.instala unless NXActualiza.instalado
      nx_update_sin_actualiza
    end
  end
end

NX.log("[actualiza] a la espera de PokeUpdater")
