# nx-datos.rb — la pagina Datos de la Pokedex sin recorrer la Pokedex 4.500 veces.
#
# Medido en el PC con el banco de menus (tmp/pc-anil/perfil-menus.rb), al
# entrar en la pagina Datos y en cada cambio de especie dentro de ella:
#
#   drawPageData 1x/90ms  pbGenerateDataLists 1x/78ms  Sp#display_species? 4556x/77ms
#
# El plugin [MUI] Pokedex Data Page arma en pbGenerateDataLists las listas de
# "especies parecidas" (mismo ratio de sexo, mismo habitat, misma forma,
# grupos huevo...) recorriendo TODAS las especies y formas del juego, y por
# cada una llama hasta tres veces a GameData::Species#display_species?, cuya
# primera linea es
#
#   return false if !dexlist.any? { |dex| dex[:species] == @species }
#
# o sea, un recorrido lineal de la lista de la Pokedex (mas de mil entradas)
# por cada llamada. 4.556 llamadas por una media de medio millar de
# comparaciones son unos dos millones de vueltas de bloque de Ruby por cada
# especie que se mira: 78 ms en el PC, del orden de medio segundo en la
# consola, y se paga otra vez con cada arriba/abajo en esa pagina.
#
# La pregunta es "esta esta especie en la lista", y la lista no cambia mientras
# la escena esta abierta. Se responde con un Hash que se construye una vez por
# lista (y se guarda en la propia lista, asi muere con ella; si cambia de
# longitud se rehace). Despues se llama al metodo original con una lista de UN
# elemento que contiene esa especie, para que su any? acierte a la primera y el
# resto del metodo -que es lo que decide de verdad, y que puede cambiar en otra
# version del plugin- quede intacto. Si la especie no esta, se devuelve false,
# que es lo mismo que habria devuelto el original.
#
# Solo vale si el original usa dexlist para esa pregunta y para nada mas, que
# es lo que hace la version de Anil (GameData.rb del plugin, display_species?
# de cuatro argumentos). Por eso se comprueba la firma antes de instalarse.

module NXDatos
  @instalado = false
  UNO = Hash.new { |h, sp| h[sp] = [{ :species => sp }.freeze].freeze }

  class << self
    attr_reader :instalado

    def en_lista?(dexlist, especie)
      return nil unless dexlist.is_a?(Array)
      mapa = dexlist.instance_variable_get(:@nx_especies)
      if mapa.nil? || dexlist.instance_variable_get(:@nx_especies_n) != dexlist.length
        mapa = {}
        dexlist.each { |dex| mapa[dex[:species]] = true if dex.is_a?(Hash) }
        dexlist.instance_variable_set(:@nx_especies, mapa)
        dexlist.instance_variable_set(:@nx_especies_n, dexlist.length)
      end
      mapa.key?(especie)
    end

    def instala
      return true if @instalado
      return false unless Object.const_defined?(:GameData) &&
                          GameData.const_defined?(:Species) &&
                          GameData::Species.method_defined?(:display_species?)
      @instalado = true
      firma = GameData::Species.instance_method(:display_species?).parameters.map(&:last)
      unless firma == [:dexlist, :species, :special, :skip_owned_check]
        NX.log("[datos] display_species? con otra firma (#{firma.inspect}); se deja como estaba")
        return true
      end

      GameData::Species.class_eval do
        alias_method :nx_display_species_lineal, :display_species?

        def display_species?(dexlist, species, special = false, skip_owned_check = false)
          esta = NXDatos.en_lista?(dexlist, @species)
          return nx_display_species_lineal(dexlist, species, special, skip_owned_check) if esta.nil?
          return false unless esta
          nx_display_species_lineal(NXDatos::UNO[@species], species, special, skip_owned_check)
        end
      end

      NX.log("[datos] display_species? pregunta a un Hash en vez de recorrer la Pokedex")
      true
    end
  end
end

module Graphics
  class << self
    alias_method :nx_update_sin_datos, :update

    def update
      NXDatos.instala unless NXDatos.instalado
      nx_update_sin_datos
    end
  end
end

NX.log("[datos] a la espera de la pagina Datos de la Pokedex")
