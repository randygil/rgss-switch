# nx-nube.rb — que guardar no espere a la nube.
#
# "Guardo y se queda colgado." En la consola (registros del 3 de octubre), justo
# despues de cada guardado desde el menu:
#
#   [185009] [tiron] marco 807 ms | cpu 81 ms | io 28782x 2 ms ...    el guardado
#   [188861] [tiron] marco 2441 ms | cpu 272 ms | ... | resto 2431 ms
#   [174307] [tiron] marco 523 ms | cpu 45 ms | io 28781x 1 ms ...    otro dia
#   [245622] [tiron] marco 70612 ms | cpu 74 ms | ... | resto 70600 ms
#
# Es el plugin Cloud Save Sync de Anil. Engancha PokemonSaveScreen#pbSaveScreen
# y, en cuanto la partida esta escrita, llama a UI.after_manual_save, que sube
# la ranura en el hilo principal: leer el fichero, Marshal, CRC32 y base64 en
# Ruby (los 270 ms de cpu) y un POST por HTTPS con la partida entera, por Wi-Fi.
# Con buena red son dos o tres segundos de juego parado; con mala, hasta el
# plazo de libcurl (10 s de conexion, 60 s en total) o mas. Y sin red, otra vez
# en cada guardado hasta que entra el respiro del plugin (300 s).
#
# Lo que se cambia es CUANDO se espera a la red, no lo que se sube ni lo que se
# hace con la respuesta:
#
#   - Al volver de la pantalla de guardado se prepara la subida en el hilo
#     principal con el codigo del plugin (Sync.local_info: el mismo fichero
#     recien escrito, el mismo resumen) y se codifica en base64. Solo lectura:
#     la partida ya esta en disco y aqui no se toca.
#   - El POST va en un hilo de Ruby. HTTPLite suelta el GVL mientras curl
#     espera (binding/http-binding.cpp, rb_thread_call_without_gvl), asi que el
#     juego sigue dibujando. El hilo solo llama a HTTPLite: nada de Graphics,
#     $game_*, mensajes ni cloud_sync.json.
#   - La respuesta se procesa en el hilo principal, desde Graphics.update: la
#     parte de Sync.upload que viene despues de la red (Api.handle_response,
#     que con un 401 borra el token; State.set_slot y State.save).
#   - Lo que ve el jugador: si sale bien, un aviso discreto arriba que no para
#     nada (el plugin ensenaba un mensaje que se cerraba solo); si falla, el
#     mismo mensaje del plugin ("No se pudo subir a la nube..."), pero en el
#     mapa, sin mensaje ni menu abierto, sin evento corriendo y con el jugador
#     quieto. Un conflicto se pregunta igual que antes, en ese mismo momento.
#   - Un guardado con una subida en curso se pone en cola: una subida a la vez,
#     y de cada ranura solo la ultima preparada. La siguiente sale cuando la
#     anterior ha actualizado el estado, asi que lleva la revision buena como
#     base y el servidor no ve un conflicto que no existe.
#   - backoff?, network_failed! y clear_backoff! del plugin, como antes: un
#     fallo de red para la tanda y los guardados de los proximos 300 s no suben.
#
# La otra espera a la red del juego normal es CHECK_ON_LOAD: la pantalla de
# carga pregunta a la nube por las partidas antes de dejar elegir. Se hace como
# nx-actualiza.rb con PokeUpdater: la pregunta sale en un hilo mientras se esta
# en el titulo, y al llegar a la pantalla de carga se usa la respuesta si ya
# esta -con los mismos dialogos del plugin- y si no, este arranque no se espera.
# El menu "Nube" sigue siendo el de siempre: ahi lo ha pedido el jugador, y si
# hay una subida en curso se espera a que acabe, con su cartel, antes de abrirlo.
#
# Se instala en el primer Graphics.update con escena, solo si estan todas las
# piezas del plugin que se usan; si falta alguna no toca nada.

module NXNube
  # Todo con ||= / const_defined?: si el fichero se cargara dos veces, la
  # segunda no pierde la cola ni la subida en curso.
  QUIETO = 30 unless const_defined?(:QUIETO)  # fotogramas de mapa tranquilo antes de un aviso
  AVISO = 150 unless const_defined?(:AVISO)   # fotogramas que dura el aviso de subida correcta
  CADA = 30 unless const_defined?(:CADA)      # cada cuantos fotogramas se mira si toca preguntar

  @instalado ||= false
  @descartado ||= false
  @cola ||= []          # subidas preparadas, en orden; como mucho una por ranura
  @vuelo ||= nil        # la subida en curso: {"entrada", "hilo", "t0"}
  @avisos ||= []        # [tipo, dato] para el mapa tranquilo
  @quieto ||= 0
  @perfiles ||= nil     # la pregunta de la pantalla de carga: {"hilo", "t0"}
  @dentro ||= false
  @ui ||= 0             # > 0 mientras corre una pantalla del plugin
  @cartel ||= nil       # [viewport, sprite, bitmap, fotogramas que quedan]
  @cuenta ||= 0

  class << self
    attr_reader :instalado, :descartado

    def log(msg)
      NX.log("[nube] #{msg}") if Object.const_defined?(:NX) && NX.respond_to?(:log)
    end

    def reloj
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def ms(t0)
      ((reloj - t0) * 1000.0).round
    end

    def ocupado?
      !@vuelo.nil? || !@cola.empty?
    end

    # Lo unico que corre fuera del hilo principal. MKXPError (HTTPLite sin red)
    # no hereda de StandardError: se recoge todo y se convierte despues.
    def hilo_red(&peticion)
      Thread.new do
        Thread.current.report_on_exception = false
        begin
          [:ok, peticion.call]
        rescue Exception => e
          [:error, e]
        end
      end
    end

    def resultado(hilo)
      r = (hilo.value rescue nil)
      r.is_a?(Array) ? r : [:error, RuntimeError.new("el hilo de la red no devolvio nada")]
    end

    def cabeceras
      { "Accept" => "application/json", "Authorization" => "Bearer #{CloudSync::Api.token}" }
    end

    #------------------------------------------------------------------------
    # Subida automatica tras guardar
    #------------------------------------------------------------------------

    # Sustituye a UI.after_manual_save: mismas condiciones, misma cola del
    # plugin, sin esperar a la red.
    def tras_guardar
      slots = CloudSync::Sync.take_auto_uploads
      return if slots.empty? || !CloudSync::UI.available?
      return if CloudSync::Sync.backoff?
      slots.each do |slot|
        begin
          t0 = reloj
          encola(prepara(slot))
          log("#{slot} preparada en #{ms(t0)} ms; la subida no se espera")
        rescue Exception => e
          raise e if CloudSync.fatal?(e)
          fallo(e)
        end
      end
      despacha
    rescue Exception => e
      raise e if CloudSync.fatal?(e)
      log("tras guardar: #{e.class}: #{e.message}")
    end

    # La parte de Sync.upload que lee la partida (hilo principal: Meta.summary
    # pregunta el nombre del mapa al juego).
    def prepara(slot)
      info = CloudSync::Sync.local_info(slot)
      { "slot" => slot, "summary" => info["summary"], "crc32" => info["crc32"],
        "size" => info["size"], "b64" => CloudSync::Base64.encode(info["bytes"]) }
    end

    def encola(entrada)
      i = @cola.index { |e| e["slot"] == entrada["slot"] }
      if i
        @cola[i] = entrada
      else
        @cola << entrada
      end
    end

    # Saca de la cola hasta que una subida queda en vuelo (o no queda nada).
    def despacha
      while @vuelo.nil? && !@cola.empty?
        e = @cola.shift
        begin
          res = envia(e)
          reacciona(res) if res
        rescue Exception => err
          raise err if CloudSync.fatal?(err)
          fallo(err)
        end
      end
    end

    # Sync.upload hasta la red, con el estado de AHORA (la subida anterior de
    # la misma ranura ya lo ha actualizado). Devuelve un resultado si no hace
    # falta la red, o nil con la peticion en vuelo.
    def envia(e)
      unless CloudSync::Sync.linked?
        raise CloudSync::ApiError.new(CloudSync.t("Este dispositivo no está vinculado."), "not_linked")
      end
      slot = e["slot"]
      summ = e["summary"]
      crc = e["crc32"]
      st = CloudSync::State.slot(slot)
      same_profile = st && st["profileKey"].to_s == summ["profileKey"]
      if same_profile && st["crc32"].to_i == crc && !st["revisionId"].to_s.empty?
        return { "result" => "skipped", "slot" => slot }
      end
      base = same_profile ? st["revisionId"] : nil
      base = nil if base.to_s.empty?
      payload = {
        "profileKey"     => summ["profileKey"],
        "playerName"     => CloudSync.truncate_utf8(summ["playerName"], 60),
        "trainerId"      => summ["trainerId"],
        "slotName"       => CloudSync.truncate_utf8(slot.to_s, 60),
        "baseRevisionId" => base,
        "force"          => false,
        "size"           => e["size"],
        "crc32"          => crc,
        "meta"           => summ["meta"],
        "dataB64"        => CloudSync::JSON::Raw.new(e["b64"])
      }
      http = CloudSync::Api.transport
      if http.nil? || !http.respond_to?(:get)
        raise CloudSync::NetworkError.new(CloudSync.t("Este juego no tiene soporte de red (HTTPLite)."), "no_http")
      end
      api = CloudSync::Api
      url = api.base_url + "/sync/games/#{api.url_escape(api.game_key)}/upload"
      cuerpo = CloudSync::JSON.generate(payload)
      cab = cabeceras
      hilo = hilo_red { http.post_body(url, cuerpo, "application/json", cab) }
      @vuelo = { "entrada" => e, "hilo" => hilo, "t0" => reloj }
      nil
    end

    # Sync.upload despues de la red, en el hilo principal.
    def termina(v)
      e = v["entrada"]
      slot = e["slot"]
      summ = e["summary"]
      crc = e["crc32"]
      tipo, valor = resultado(v["hilo"])
      if tipo == :error
        log("#{slot}: la red fallo a los #{ms(v['t0'])} ms (#{valor.class}: #{valor.message})")
        raise CloudSync::NetworkError.new(CloudSync::Api.network_message(valor), "network")
      end
      log("#{slot}: la red contesto en #{ms(v['t0'])} ms (#{CloudSync::Api.field(valor, :status)})")
      res = begin
        CloudSync::Api.handle_response(valor)
      rescue CloudSync::ApiError => err
        if err.status == 409 && err.code == "conflict"
          head = err.data.is_a?(Hash) ? err.data["head"] : nil
          return { "result" => "conflict", "slot" => slot, "head" => head, "local" => summ,
                   "message" => err.message }
        end
        raise err
      end
      rev = res["revision"].is_a?(Hash) ? res["revision"] : {}
      prof = res["profile"].is_a?(Hash) ? res["profile"] : {}
      if rev["id"].to_s.empty?
        raise CloudSync::ApiError.new(CloudSync.t("Respuesta inválida del servidor."), "bad_response")
      end
      if rev["crc32"] && rev["crc32"].to_i != crc
        CloudSync.log("aviso: CRC remoto #{rev['crc32']} != local #{crc}")
      end
      CloudSync::State.set_slot(slot, {
        "profileId" => prof["id"], "revisionId" => rev["id"], "crc32" => crc,
        "profileKey" => summ["profileKey"], "syncedAt" => CloudSync.iso8601(Time.now)
      })
      CloudSync::State.save
      { "result" => res["status"].to_s, "slot" => slot, "revision" => rev, "profile" => prof }
    end

    # Lo que hacia UI.do_upload con auto = true, sin modales fuera del mapa.
    def reacciona(res)
      CloudSync::Sync.clear_backoff!
      slot = res["slot"]
      case res["result"]
      when "created"
        n = res["revision"].is_a?(Hash) ? res["revision"]["number"] : nil
        texto = n ? CloudSync.t("{1} subida a la nube (revisión {2}).", slot, n) : CloudSync.t("{1} subida a la nube.", slot)
        log(texto)
        cartel(texto) if CloudSync::Config::AUTO_UPLOAD_NOTIFY_SUCCESS
      when "conflict"
        log("#{slot}: conflicto, se preguntara en el mapa")
        avisa(:conflicto, res)
      else
        log("#{slot}: #{res['result']}")
      end
    end

    # Lo que hacia el rescue de UI.after_manual_save.
    def fallo(e)
      if e.is_a?(CloudSync::NetworkError)
        CloudSync::Sync.network_failed!
        @cola.clear
        avisa(:breve, CloudSync.t("No se pudo subir a la nube (sin conexión). Tu partida está guardada en este dispositivo."))
      else
        CloudSync.log("auto-subida: #{e.class}: #{e.message}")
        log("auto-subida: #{e.class}: #{e.message}")
        if e.is_a?(CloudSync::ApiError) && e.code == "invalid_token"
          avisa(:informe, e)
        else
          avisa(:breve, CloudSync.t("No se pudo subir a la nube: {1}", CloudSync::UI.esc(e.message)))
        end
      end
    end

    def avisa(tipo, dato)
      if tipo == :conflicto
        @avisos.reject! { |t, d| t == :conflicto && d["slot"] == dato["slot"] }
      elsif tipo == :breve
        @avisos.reject! { |t, d| t == :breve && d == dato }
      end
      @avisos << [tipo, dato]
    end

    #------------------------------------------------------------------------
    # Cada fotograma, desde Graphics.update
    #------------------------------------------------------------------------
    def bomba
      @cuenta += 1
      return if @vuelo.nil? && @cola.empty? && @cartel.nil? && (@cuenta % CADA) != 0
      return if @dentro
      @dentro = true
      begin
        recoge if @ui == 0
        despacha if @ui == 0
        mira_perfiles if (@cuenta % CADA) == 0
        anima_cartel if @cartel
      rescue Exception => e
        raise e if CloudSync.fatal?(e)
        log("bomba: #{e.class}: #{e.message}")
      ensure
        @dentro = false
      end
    end

    def recoge
      return unless @vuelo && !@vuelo["hilo"].alive?
      v = @vuelo
      @vuelo = nil
      @perfiles = nil   # una respuesta de antes de esta subida ya no vale
      begin
        reacciona(termina(v))
      rescue Exception => e
        raise e if CloudSync.fatal?(e)
        fallo(e)
      end
    end

    # Antes del menu "Nube": la subida en curso acaba, con su cartel.
    def espera_subida
      return unless @vuelo
      slot = @vuelo["entrada"]["slot"]
      t0 = reloj
      # Con @ui puesto la bomba no recoge ni saca otra de la cola mientras tanto:
      # se espera a esta y nada mas.
      en_ui do
        CloudSync::UI.busy(CloudSync.t("Subiendo {1} a la nube...", slot)) do
          Graphics.update while @vuelo["hilo"].alive?
        end
      end
      log("el menu Nube espero #{ms(t0)} ms a la subida de #{slot}")
      recoge
    rescue Exception => e
      raise e if CloudSync.fatal?(e)
      log("espera: #{e.class}: #{e.message}")
    end

    def en_ui
      @ui += 1
      yield
    ensure
      @ui -= 1
    end

    #------------------------------------------------------------------------
    # Avisos en el mapa, al final de Scene_Map#update
    #------------------------------------------------------------------------
    def tranquilo?(escena)
      return false unless $scene.equal?(escena)
      t = $game_temp
      return false if t.nil?
      %i[message_window_showing in_menu menu_calling ready_menu_calling interact_calling
         in_battle in_storage player_transferring transition_processing title_screen_calling
         in_mini_update].each do |m|
        return false if t.respond_to?(m) && t.send(m)
      end
      return false if respond_to?(:pbMapInterpreterRunning?, true) && pbMapInterpreterRunning?
      pl = $game_player
      return false if pl.nil?
      return false if pl.respond_to?(:moving?) && pl.moving?
      return false if pl.respond_to?(:move_route_forcing) && pl.move_route_forcing
      g = $PokemonGlobal
      return false if g && g.respond_to?(:forced_movement?) && g.forced_movement?
      return false if respond_to?(:pbIsFaded?, true) && pbIsFaded?
      true
    end

    def en_mapa(escena)
      if @avisos.empty? || @ui > 0
        @quieto = 0
        return
      end
      @quieto = tranquilo?(escena) ? @quieto + 1 : 0
      return if @quieto < QUIETO
      @quieto = 0
      tipo, dato = @avisos.shift
      log("aviso en el mapa: #{tipo}")
      en_ui { ensena(tipo, dato) }
    rescue Exception => e
      raise e if CloudSync.fatal?(e)
      log("aviso: #{e.class}: #{e.message}")
    end

    def ensena(tipo, dato)
      ui = CloudSync::UI
      case tipo
      when :breve then ui.brief(dato)
      when :informe then ui.report(dato)
      when :conflicto
        begin
          ui.resolve_conflict(dato, :pause)
          CloudSync::Sync.clear_backoff!
        rescue CloudSync::NetworkError
          CloudSync::Sync.network_failed!
          ui.brief(CloudSync.t("No se pudo subir a la nube (sin conexión). Tu partida está guardada en este dispositivo."))
        rescue Exception => e
          raise e if CloudSync.fatal?(e)
          CloudSync.log("auto-subida: #{e.class}: #{e.message}")
          if e.is_a?(CloudSync::ApiError) && e.code == "invalid_token"
            ui.report(e)
          else
            ui.brief(CloudSync.t("No se pudo subir a la nube: {1}", ui.esc(e.message)))
          end
        end
      end
    end

    #------------------------------------------------------------------------
    # El aviso discreto: una franja arriba que se va sola y no coge el mando
    #------------------------------------------------------------------------
    def cartel(texto)
      quita_cartel
      w = Graphics.width
      h = 36
      vp = Viewport.new(0, 0, w, h)
      vp.z = 99_999
      bmp = Bitmap.new(w, h)
      pbSetSystemFont(bmp) if respond_to?(:pbSetSystemFont, true)
      bmp.font.size = 20
      bmp.fill_rect(0, 0, w, h, Color.new(0, 0, 0, 170))
      bmp.font.color = Color.new(248, 248, 248)
      bmp.draw_text(8, 4, w - 16, h - 8, texto, 0)
      spr = Sprite.new(vp)
      spr.bitmap = bmp
      @cartel = [vp, spr, bmp, AVISO]
    rescue Exception => e
      raise e if CloudSync.fatal?(e)
      log("cartel: #{e.class}: #{e.message}")
      quita_cartel
    end

    def anima_cartel
      c = @cartel
      c[3] -= 1
      if c[3] <= 0
        quita_cartel
      elsif c[3] < 20
        c[1].opacity = c[3] * 255 / 20
      end
    end

    def quita_cartel
      c = @cartel
      @cartel = nil
      return unless c
      c[0..2].each { |o| (o.dispose rescue nil) if o }
    end

    #------------------------------------------------------------------------
    # CHECK_ON_LOAD: la pregunta sale en el titulo, la respuesta se usa en la
    # pantalla de carga si ya ha llegado
    #------------------------------------------------------------------------
    def mira_perfiles
      return unless CloudSync::Config::CHECK_ON_LOAD
      p = @perfiles
      if p && !p["hilo"].alive? && reloj - p["t0"] > CloudSync::Config::CHECK_ON_LOAD_INTERVAL_SEC
        @perfiles = nil
      end
      return if @perfiles || ocupado? || @ui > 0
      return if $scene.nil? || (Object.const_defined?(:Scene_Map) && $scene.is_a?(Scene_Map))
      return unless CloudSync::UI.check_due?
      lanza_perfiles
    end

    def lanza_perfiles
      api = CloudSync::Api
      http = api.transport
      return if http.nil? || !http.respond_to?(:get)
      url = api.base_url + "/sync/games/#{api.url_escape(api.game_key)}/profiles"
      cab = cabeceras
      @perfiles = { "hilo" => hilo_red { http.get(url, cab) }, "t0" => reloj }
      log("pregunta por las partidas de la nube en segundo plano")
    end

    # [:ok, respuesta] o [:error, excepcion], o nil si no hay que esperar.
    def toma_perfiles
      p = @perfiles
      if p.nil?
        log("la pantalla de carga no tiene respuesta de la nube: no se espera")
        return nil
      end
      if p["hilo"].alive?
        log("la nube aun no ha contestado (#{ms(p['t0'])} ms): la pantalla de carga no espera")
        return nil
      end
      if ocupado?
        log("hay una subida pendiente: la comprobacion de la nube se deja para otra vez")
        return nil
      end
      @perfiles = nil
      log("la pantalla de carga usa la respuesta de la nube (pedida hace #{ms(p['t0'])} ms)")
      resultado(p["hilo"])
    end

    #------------------------------------------------------------------------
    # Instalacion
    #------------------------------------------------------------------------
    def falta
      return "CloudSync" unless Object.const_defined?(:CloudSync)
      cs = CloudSync
      %i[Sync UI Api State Config Base64 JSON NetworkError ApiError].each do |c|
        return "CloudSync::#{c}" unless cs.const_defined?(c, false)
      end
      return "CloudSync::JSON::Raw" unless cs::JSON.const_defined?(:Raw, false)
      { cs => %i[fatal? t iso8601 truncate_utf8 log],
        cs::Sync => %i[take_auto_uploads backoff? network_failed! clear_backoff! local_info linked? plan_on_load],
        cs::UI => %i[after_manual_save check_on_load check_due? available? brief report resolve_conflict
                     main_menu busy run_plan esc],
        cs::Api => %i[handle_response network_message base_url game_key url_escape token transport field],
        cs::State => %i[slot set_slot save],
        cs::Base64 => %i[encode],
        cs::JSON => %i[generate] }.each do |m, metodos|
        metodos.each { |x| return "#{m}.#{x}" unless m.respond_to?(x) }
      end
      %i[AUTO_UPLOAD_NOTIFY_SUCCESS CHECK_ON_LOAD CHECK_ON_LOAD_INTERVAL_SEC].each do |c|
        return "CloudSync::Config::#{c}" unless cs::Config.const_defined?(c, false)
      end
      return "Scene_Map#update" unless Object.const_defined?(:Scene_Map) && Scene_Map.method_defined?(:update)
      nil
    end

    def instala
      return true if @instalado
      return false if @descartado || $scene.nil?   # hasta que esten todos los scripts
      que = falta
      if que
        @descartado = true
        log("no se instala: falta #{que}")
        return false
      end
      @instalado = true

      CloudSync::UI.singleton_class.class_eval do
        unless method_defined?(:nx_after_manual_save_bloqueante)
          alias_method :nx_after_manual_save_bloqueante, :after_manual_save
          def after_manual_save
            NXNube.tras_guardar
          end
        end

        unless method_defined?(:nx_main_menu_bloqueante)
          alias_method :nx_main_menu_bloqueante, :main_menu
          def main_menu(context = :pause)
            NXNube.espera_subida
            NXNube.en_ui { nx_main_menu_bloqueante(context) }
          end
        end

        # El cuerpo de UI.check_on_load con la respuesta que trajo el hilo.
        unless method_defined?(:nx_check_on_load_bloqueante)
          alias_method :nx_check_on_load_bloqueante, :check_on_load
          def check_on_load
            return nil unless check_due?
            NXNube.en_ui do
              r = NXNube.toma_perfiles
              next nil if r.nil?
              @last_check_at = Time.now.to_f
              tipo, valor = r
              profiles = nil
              begin
                if tipo == :error
                  raise CloudSync::NetworkError.new(CloudSync::Api.network_message(valor), "network")
                end
                profiles = CloudSync::Api.handle_response(valor)["profiles"]
              rescue CloudSync::NetworkError => e
                CloudSync.log("comprobación al cargar: #{e.message}")
                brief(CloudSync.t("Sin conexión con la nube."))
                next nil
              rescue Exception => e
                raise e if CloudSync.fatal?(e)
                CloudSync.log("comprobación al cargar: #{e.class}: #{e.message}")
                next nil
              end
              next nil unless profiles.is_a?(Array)
              plan = busy(CloudSync.t("Comparando con tus partidas...")) { CloudSync::Sync.plan_on_load(profiles) }
              run_plan(plan)
            end
          rescue Exception => e
            raise e if CloudSync.fatal?(e)
            CloudSync.log("check_on_load: #{e.class}: #{e.message}")
            nil
          end
        end
      end

      Scene_Map.class_eval do
        unless method_defined?(:nx_update_sin_nube)
          alias_method :nx_update_sin_nube, :update
          def update(*args)
            ret = nx_update_sin_nube(*args)
            NXNube.en_mapa(self)
            ret
          end
        end
      end

      log("la subida tras guardar y la comprobacion de la pantalla de carga no esperan a la red")
      true
    rescue Exception => e
      raise e if Object.const_defined?(:CloudSync) && CloudSync.respond_to?(:fatal?) && CloudSync.fatal?(e)
      @descartado = true
      log("no se pudo instalar: #{e.class}: #{e.message}")
      false
    end
  end
end

module Graphics
  class << self
    unless method_defined?(:nx_update_sin_nube)
      alias_method :nx_update_sin_nube, :update

      def update
        if NXNube.instalado
          NXNube.bomba
        elsif !NXNube.descartado
          NXNube.instala
        end
        nx_update_sin_nube
      end
    end
  end
end

NXNube.log("a la espera de Cloud Save Sync")
