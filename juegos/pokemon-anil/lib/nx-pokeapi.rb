# nx-pokeapi.rb — que la pagina de Datos de la Pokedex no espere a internet.
#
# "Si pulso A sin querer en la Pokedex se congela unos segundos." Medido en el
# PC con el banco de menus (tmp/pc-anil/perfil-menus.rb), con banda ancha de
# fibra y la cache de PokeAPI vacia:
#
#   [lento] 1204 ms | datos: A (menu de datos) | API#get_data 1x/1186ms
#           HTTP#get 2x/1180ms  network_available? 1x/501ms  pbDownloadData 1x/679ms
#
# Es el plugin PokeAPI de Anil (plugins/PokeAPI.rb): al pulsar A en la pagina
# Datos, pbDataPageMenu llama a PokeAPI.get_data ANTES de pintar nada, y eso
# es, en el mismo fotograma, network_available? -un GET por HTTPS a google.com
# para ver si hay red, y si falla otro a 1.1.1.1, otro a 8.8.8.8 y otro a
# api.github.com- y despues el JSON entero de https://pokeapi.co/api/v2/pokemon/
# <especie>. Desde que el motor tiene red (0.2.0, HTTPLite sobre libcurl) eso
# pasa de verdad en la consola, con el TLS del servicio ssl de Horizon y por
# Wi-Fi: varios segundos de pantalla parada. Sin red es peor: cada intento
# fallido son hasta 10 s de plazo de conexion, cuatro veces, y no se recuerda
# el fallo, asi que se repite en cada pulsacion. Y no solo con A: mover el
# cursor a "estadisticas" (pbDataTextStats) o a "movimientos"
# (show_ability_diffs) tambien llama a get_data si esa especie no esta en cache.
#
# Para que sirve esa descarga: para comparar las estadisticas, tipos y
# habilidades del juego con las oficiales (el boton Especial y los colores de
# la pagina). Es un adorno, y no puede costar un congelamiento. Asi que:
#
#   - get_data devuelve lo que haya en cache AL MOMENTO. Si no hay, lanza la
#     descarga en un hilo de Ruby y devuelve nil, que es lo mismo que devolvia
#     el original sin red: el plugin ya sabe pintar la pagina sin esos datos.
#     HTTPLite suelta el GVL mientras espera a la red, asi que el juego sigue
#     dibujando.
#   - Cuando el hilo termina, el resultado pasa a la cache desde el hilo
#     principal (en pbUpdate de la escena), nunca desde el hilo: la cache vive
#     en $PokemonGlobal y se guarda con la partida, y escribir ahi en mitad de
#     un Marshal.dump seria buscarse un problema. Si la escena sigue en el menu
#     de datos de esa especie, se le da @api_data y se repinta la nota, y el
#     boton Especial empieza a funcionar.
#   - network_available? recuerda su respuesta (10 min si habia red, 2 si no),
#     y una especie cuya descarga fallo no se reintenta en 2 minutos.
#
# Y un segundo problema que salio al medir: cada entrada de la cache guarda el
# JSON ENTERO de PokeAPI (todos los movimientos con sus versiones, los sprites
# de todas las generaciones...). En la partida del PC, dos especies vistas son
# 455.440 bytes de los 782.176 de la partida: el 58 %. Cada especie que se
# mira en Datos engorda la partida unos 190 KB, y eso se escribe en cada
# guardado y se lee en cada carga. Aqui se guarda solo lo que el juego lee
# despues -species, form, stats, abilities, types, sprite_urls y los sprites
# sin "versions"-, y las entradas que ya trae la partida se adelgazan la
# primera vez que se usa la cache.

module NXPokeAPI
  RED_BIEN  = 600   # s que se da por buena una respuesta de "hay red"
  RED_MAL   = 120   # s que se da por buena una de "no hay red"
  REINTENTO = 120   # s antes de volver a pedir una especie que fallo
  GUARDA = %w[species form stats abilities types sprite_urls name id].freeze

  @instalado = false
  @hilos = {}       # clave -> Thread
  @listos = {}      # clave -> datos ya procesados, o :fallo
  @fallos = {}      # clave -> instante del ultimo fallo
  @red = nil
  @red_t = -1e9
  @adelgazada = nil
  @mutex = Mutex.new

  # Lo que puede tirar una descarga. pbDownloadToString falla con MKXPError
  # ("Couldn't resolve host" sin red, un 404 con una forma que pokeapi.co no
  # tiene), y MKXPError NO es un StandardError: el motor la cuelga directamente
  # de Exception (binding-util.cpp). Con solo StandardError y ScriptError el
  # hilo de la descarga moria con ella, la clave se quedaba en @hilos para
  # siempre -sin apuntarse en @fallos, asi que esa especie no se volvia a pedir
  # en toda la partida aunque volviera la red- y Ruby escribia la pila entera en
  # el registro (report_on_exception). Visto en Ryujinx, que no tiene red.
  FALLOS = [StandardError, ScriptError] +
           (Object.const_defined?(:MKXPError) ? [MKXPError] : [])

  class << self
    attr_reader :instalado

    def reloj
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def adelgaza(d)
      return d unless d.is_a?(Hash)
      r = {}
      GUARDA.each { |k| r[k] = d[k] if d.key?(k) }
      spr = d["sprites"]
      r["sprites"] = spr.reject { |k, _| k == "versions" } if spr.is_a?(Hash)
      r
    end

    # Las partidas guardadas antes de este shim traen la cache gorda.
    def adelgaza_cache
      g = $PokemonGlobal
      return if g.nil? || @adelgazada.equal?(g)
      @adelgazada = g
      cache = g.pokeapi_cache
      return unless cache.is_a?(Hash)
      n = 0
      cache.each_value do |e|
        next unless e.is_a?(Hash) && e[:data].is_a?(Hash) && e[:data].key?("moves")
        e[:data] = adelgaza(e[:data])
        n += 1
      end
      NX.log("[pokeapi] #{n} entradas de la cache adelgazadas") if n > 0
    end

    def red?(original)
      t = reloj
      if @red.nil? || (t - @red_t) > (@red ? RED_BIEN : RED_MAL)
        @red = begin
                 original.call ? true : false
               rescue *FALLOS
                 false
               end
        @red_t = reloj
      end
      @red
    end

    def pendientes?
      !@listos.empty?
    end

    # En el hilo principal: pasa a la cache de la partida lo que ya llego.
    def recoge
      return if @listos.empty?
      listos = nil
      @mutex.synchronize { listos = @listos; @listos = {} }
      listos.each do |clave, datos|
        @hilos.delete(clave)
        if datos == :fallo || datos.nil?
          @fallos[clave] = reloj
        else
          PokeAPI.cache_data(clave, adelgaza(datos))
        end
      end
    end

    # Lo mismo que hacia el original despues de mirar la cache, en otro hilo.
    def pide(clave, species)
      return if @hilos[clave]
      f = @fallos[clave]
      return if f && (reloj - f) < REINTENTO
      @hilos[clave] = Thread.new do
        datos = nil
        begin
          datos = descarga(species) if network_available?
        rescue *FALLOS
          datos = nil
        end
        @mutex.synchronize { @listos[clave] = datos || :fallo }
      end
    end

    def descarga(species)
      if species.is_a?(GameData::Species)
        nombre = PokeAPI.get_species_name(species)
        if species.form > 0
          if species.mega_stone || species.mega_move
            nombre += PokeAPI.get_mega_form_name(species)
          else
            nombre += PokeAPI.get_form_name(species)
          end
        end
      else
        nombre = species.downcase
      end
      respuesta = pbDownloadToString("https://pokeapi.co/api/v2/pokemon/#{nombre}")
      return nil if respuesta.nil? || respuesta.empty?
      data = HTTPLite::JSON.parse(respuesta)
      return nil if data.nil?
      adelgaza(PokeAPI.parse_data(data, species))
    end

    def instala
      return true if @instalado
      return false unless Object.const_defined?(:PokeAPI) &&
                          PokeAPI.respond_to?(:get_data) &&
                          PokeAPI.respond_to?(:get_cached_data) &&
                          (Object.private_method_defined?(:network_available?) ||
                           Object.method_defined?(:network_available?))
      @instalado = true

      Object.class_eval do
        alias_method :nx_network_available_sin_memoria, :network_available?
        def network_available?
          NXPokeAPI.red?(method(:nx_network_available_sin_memoria))
        end
      end

      PokeAPI.singleton_class.class_eval do
        alias_method :nx_get_data_bloqueante, :get_data
        def get_data(species)
          # Desde otro hilo que no sea el principal (no lo hace nadie en Anil),
          # el camino de siempre.
          return nx_get_data_bloqueante(species) unless Thread.current == Thread.main
          NXPokeAPI.adelgaza_cache
          NXPokeAPI.recoge
          clave = generate_cache_key(species)
          datos = get_cached_data(clave)
          return datos if datos
          NXPokeAPI.pide(clave, species)
          nil
        end
      end

      if Object.const_defined?(:PokemonPokedexInfo_Scene) &&
         PokemonPokedexInfo_Scene.method_defined?(:pbDataPageMenu)
        PokemonPokedexInfo_Scene.class_eval do
          alias_method :nx_pbDataPageMenu_sin_espera, :pbDataPageMenu
          def pbDataPageMenu
            @nx_menu_datos = true
            nx_pbDataPageMenu_sin_espera
          ensure
            @nx_menu_datos = false
          end

          alias_method :nx_pbUpdate_sin_pokeapi, :pbUpdate
          def pbUpdate
            nx_pbUpdate_sin_pokeapi
            return unless NXPokeAPI.pendientes?
            NXPokeAPI.recoge
            return unless @nx_menu_datos
            sp = GameData::Species.get_species_form(@species, @form)
            return if @api_data && @api_data["species"] == sp.id && @api_data["form"] == @form
            datos = PokeAPI.get_cached_data(PokeAPI.generate_cache_key(sp))
            return unless datos
            @api_data = datos
            pbDrawDataNotes if respond_to?(:pbDrawDataNotes)
          end
        end
      end

      NX.log("[pokeapi] get_data sin esperar a la red; network_available? con memoria")
      true
    end
  end
end

module Graphics
  class << self
    alias_method :nx_update_sin_pokeapi, :update

    def update
      NXPokeAPI.instala unless NXPokeAPI.instalado
      nx_update_sin_pokeapi
    end
  end
end

NX.log("[pokeapi] a la espera del plugin PokeAPI")
