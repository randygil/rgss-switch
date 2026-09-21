# rubygems.rb — sustituto para Nintendo Switch (Horizon OS)
#
# Reborn hace `gem 'rubygems'` en dos sitios (Scripts/Updater.rb:38 y
# Scripts/Reborn/RebornScripts.rb:2352), y su `gem` es un `require` con una
# vuelta para JoiPlay. Lo unico que usa de todo RubyGems es Gem::Version:
#
#   Updater.rb:45,66,113-117,126   Gem::Version.correct? y comparar versiones
#   RebornScripts.rb:2358-2359     Gem::Version.new de la version de la partida
#
# Cargar el RubyGems de verdad -el que Reborn trae en stdlib/- no se puede, y no
# por una sola cosa sino por dos, las dos medidas en el emulador:
#
#   stdlib/rubygems.rb:8: cannot load such file -- rbconfig (LoadError)
#   stdlib/monitor.rb:90: cannot load such file -- monitor.so (LoadError)
#
# El primero porque Reborn solo trae stdlib/x64-mingw32/rbconfig.rb y su
# ScriptLoader solo mete esa carpeta en la ruta cuando System.platform dice
# Windows, y aqui dice Linux (mkxp-z 2.4.2 no conoce Horizon: binding-mri.cpp
# contesta "Linux" en todo lo que no sea macOS ni Windows). El segundo porque
# monitor es una extension NATIVA y este interprete se compilo con
# --with-static-linked-ext y solo tres dentro: zlib, stringio y strscan
# (patches/extinit.c). Un LoadError ahi no se queda en "sin RubyGems": el
# cargador de Reborn rescata StandardError y LoadError es ScriptError, asi que
# se lleva el arranque entero por delante.
#
# Como lib/ va antes que stdlib/ en rubyLoadpath, gana este fichero y no se
# llega a mirar el otro. De paso se ahorra el arranque de un gestor de paquetes
# entero -que escanea directorios- en una consola donde no hay ninguna gema que
# instalar.
#
# Gem::Version se reimplementa aqui con la misma regla que la de verdad: la
# version es una lista de segmentos separados por puntos, los numericos se
# comparan como numeros y los alfabeticos como cadenas, un segmento alfabetico
# es SIEMPRE menor que uno numerico (asi "1.0.a" < "1.0.0") y los ceros de mas
# al final no cuentan ("1.0" == "1.0.0"). Es lo que hace falta para decidir si
# 19.5.0 es mas nueva que la version que diga el servidor.

module Gem
  class Version
    include Comparable

    # Copiada tal cual de rubygems: numeros y letras separados por puntos, con
    # un sufijo opcional detras de un guion. La cadena vacia tambien vale y es
    # la version 0.
    ANCHORED = /\A\s*([0-9]+(\.[0-9a-zA-Z]+)*(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?)?\s*\z/

    def self.correct?(version)
      return false if version.nil?
      ANCHORED.match?(version.to_s)
    end

    def self.new(version)
      version = version.version if version.is_a?(Version)
      super(version)
    end

    def self.create(input)
      input.is_a?(Version) ? input : new(input)
    end

    attr_reader :version
    alias to_s version

    def initialize(version)
      unless self.class.correct?(version)
        raise ArgumentError, "Malformed version number string #{version.inspect}"
      end
      @version = version.to_s.strip.freeze
      @version = "0" if @version.empty?
    end

    def segments
      @segments ||= @version.scan(/[0-9]+|[a-z]+/i).map { |s| s =~ /\A\d+\z/ ? s.to_i : s }
    end

    def <=>(otra)
      return nil unless otra.is_a?(Version)
      a = segments.dup
      b = otra.segments.dup
      # Los ceros del final no cuentan: 1.0 y 1.0.0 son la misma version.
      a.pop while a.last == 0
      b.pop while b.last == 0
      [a.size, b.size].max.times do |i|
        x = a[i] || 0
        y = b[i] || 0
        next if x == y
        # Un segmento con letras es una prerelease y va SIEMPRE por debajo de
        # uno numerico: 1.0.a es anterior a 1.0.0.
        return -1 if x.is_a?(String) && y.is_a?(Integer)
        return  1 if x.is_a?(Integer) && y.is_a?(String)
        return x <=> y
      end
      0
    end

    def eql?(otra);  otra.is_a?(Version) && @version == otra.version end
    def ==(otra);    otra.is_a?(Version) && (self <=> otra) == 0     end
    def hash;        segments.hash                                   end
    def prerelease?; segments.any? { |s| s.is_a?(String) }           end
    def inspect;     "#<Gem::Version #{@version.inspect}>"           end

    def release
      return self unless prerelease?
      Version.new(segments.take_while { |s| s.is_a?(Integer) }.join("."))
    end
  end

  # Alguna comprobacion suelta pregunta por esto y no cuesta nada contestar.
  RUBYGEMS_DIR = nil

  def self.ruby_version
    Version.new(RUBY_VERSION)
  end
end

NX.log("[reborn] rubygems postizo: solo Gem::Version (el de stdlib pide rbconfig y monitor.so)") if defined?(NX)
