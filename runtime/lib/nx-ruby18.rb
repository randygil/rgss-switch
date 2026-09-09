# encoding: utf-8
#
# nx-ruby18.rb — lo que le falta a un juego de Ruby 1.8 para correr sobre el
# CRuby 3.1.7 de la Switch.
#
# Cuatro juegos del censo (Opalo, Iberia, Titan, Z) comparten el mismo Game.exe
# byte a byte: mkxp-z con Ruby 1.8.7 embebido. Uranium es RGSS1 (Ruby 1.8.1).
# El motor de esta consola lleva 3.1.7 y no se va a portar el 1.8: el censo
# midio que la sintaxis de 1.8 son 25-28 lineas por juego en 3-4 ficheros sobre
# corpus de 118.000 a 160.000 lineas —entre el 0,002 % y el 0,02 % del fuente—,
# mientras que Win32API son 134-166 referencias en 20-29 ficheros. Portar el
# interprete costaria lo mismo en Win32API y ademas el interprete.
#
# Asi que aqui hay tres cosas, en este orden:
#
#   1. NXFuente.transforma  — arregla la sintaxis de 1.8 al cargar cada seccion
#                             de Scripts.rxdata, GUIADA POR EL COMPILADOR.
#   2. Win32API             — la clase postiza. Es lo que impide llegar a la
#                             pantalla de titulo: 12-14 de esas llamadas son
#                             asignaciones que se evaluan AL CARGAR el script,
#                             asi que revientan con NameError en la seccion 21
#                             de 168 y el juego no dibuja ni un pixel.
#   3. Metodos de 1.8       — solo los que se han contado en los cinco corpus.
#
# Se carga despues de nx-compat.rb, que es quien define NX.log y el modulo MKXP.

# ---------------------------------------------------------------------------
# 1. NXFuente: la transformacion de fuente
# ---------------------------------------------------------------------------
#
# El gancho del motor: antes de evaluar cada seccion de Scripts.rxdata mira si
# existe un modulo NXFuente que responda a `transforma`, y si existe evalua lo
# que devuelve. Si esto lanza, el motor registra la excepcion y evalua el
# original: nunca se puede quedar peor que sin shim.
#
# POR QUE GUIADA POR EL COMPILADOR Y NO A CIEGAS. Un gsub sobre 136.000 lineas
# encuentra `when` dentro de cadenas, `?:` ternarios y `break` de bloques, que
# son legitimos y que romper cuesta un fallo en mitad de una batalla, no un
# error al cargar. Aqui se compila primero: si compila —y compilan ~211 de los
# 214 scripts de Opalo, y los 450 de Anil, y los 432 de Vanguard— se devuelve el
# fuente sin tocar ni un byte. Solo cuando el compilador senala una linea con un
# error concreto se toca ESA linea, y se vuelve a compilar para comprobarlo.
# El censo llego a mano a 25 lineas en Opalo; este bucle tiene que llegar solo.
module NXFuente
  VUELTAS = 40          # tope: 23 `when X:` en un fichero caen en ~5 vueltas
  @ms = 0.0
  @secciones = 0
  @tocadas = 0
  @arreglos = 0
  @resumido = false

  class << self
    attr_reader :ms, :secciones, :tocadas, :arreglos
  end

  def self.reloj
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  # Un error de compilacion de Ruby 3.1 puede traer VARIOS errores concatenados
  # con saltos de linea (AudioUtilities da cinco de golpe), y cada uno viene con
  # su "nombre:LINEA: ". Se sacan todos: asi una vuelta arregla cuatro `when` en
  # vez de uno, y el bucle converge en cinco pasadas y no en veintitres.
  def self.errores(nombre, mensaje)
    lista = []
    escapado = Regexp.escape(nombre.to_s)
    mensaje.to_s.each_line do |bruta|
      # chomp obligatorio: e.message de un SyntaxError con varios errores los
      # trae separados por saltos de linea y \z no casa con el \n final. Sin
      # esto, de los cinco errores de AudioUtilities solo se veia el ultimo
      # —"unexpected `end'", que no tiene arreglo— y los 23 `when X:` no se
      # tocaban nunca.
      linea = bruta.chomp
      if linea =~ /\A#{escapado}:(\d+): (.+)\z/
        lista << [$1.to_i, $2.strip]
      elsif linea =~ /\A.*?:(\d+): (syntax error.+|Invalid .+|invalid .+|too short .+)\z/
        # Reserva: el motor podria pasar un nombre con dos puntos dentro.
        lista << [$1.to_i, $2.strip]
      end
    end
    lista
  end

  def self.clasifica(texto)
    case texto
    when /Invalid break/                                  then :break
    when /Invalid retry/                                  then :retry
    when /invalid multibyte escape/,
         /too short escaped multibyte character/,
         /invalid multibyte char/                         then :regex
    when /unexpected ':'/, /expecting `then'/, /unexpected `when'/ then :cuando
    end
  end

  # La regex es LA DEL CENSO, no una parecida:
  #   /^(\s*when\b.*[^:\s]):(\s*(#.*)?)$/  ->  '\1 then\2'
  # Exige que lo de antes de los dos puntos no acabe en `:` ni en espacio (asi
  # no toca `when x ? a : b`) y que detras de los dos puntos no quede mas que
  # espacio o un comentario (asi no toca un `when` dentro de una cadena que
  # siga con texto). Los 23 de AudioUtilities son "  when 0: # dialtone".
  CUANDO = /^(\s*when\b.*[^:\s]):(\s*(#.*)?)$/

  def self.arregla(lineas, n, tipo, texto)
    i = n - 1
    return nil if i < 0 || i >= lineas.size
    vieja = lineas[i]
    nueva =
      case tipo
      when :cuando
        vieja.sub(CUANDO, '\1 then\2')
      when :break
        # `break` en el cuerpo de un metodo (no en un bloque) es un error de
        # COMPILACION, no de analisis: por eso el censo no uso `ruby -c`, que
        # daba "Syntax OK" sobre un fichero que no carga. En 1.8 salia del
        # metodo; el equivalente exacto en 3.1 es `return`. Tres casos, todos
        # en Iberia y Titan, todos de la forma "break if !opponent.pbCanX?".
        vieja.sub(/\bbreak\b/, "return")
      when :retry
        # `retry` fuera de un rescue se retiro en 1.9. Aqui esta dentro de un
        # bucle de la pantalla de carga ("vuelve a preguntar tras borrar la
        # partida"), y ahi el equivalente es `redo`. Mismo fichero y casi la
        # misma linea en los cuatro juegos (508 o 544).
        vieja.sub(/\bretry\b/, "redo")
      when :regex
        arregla_regex(vieja, texto)
      end
    return nil if nueva.nil? || nueva == vieja
    lineas[i] = nueva
    nueva
  end

  # El literal problematico viene DENTRO del mensaje de error:
  #   "invalid multibyte escape: /\"[^\"\\\\\\n\\r\\x00-\\x1f\\x7f-\\x9f]*\"/"
  # asi que no hay que adivinar donde empieza y acaba la expresion regular en
  # una linea que ademas lleva un comentario detras (`#"`): se busca ese texto
  # exacto y se le anade el modificador `n`, que es lo que le dice a Ruby que la
  # expresion es una secuencia de BYTES y no de caracteres UTF-8. Son literales
  # como /[\x00-\x1f\x7f-\x9f]/ que en 1.8 eran bytes por definicion.
  def self.arregla_regex(linea, texto)
    literal = texto[/(?:escape|character|char):\s*(\/.*\/)\s*\z/, 1]
    if literal && (pos = linea.index(literal))
      fin = pos + literal.length
      fin += 1 while fin < linea.length && linea[fin] =~ /[imxounse]/
      return linea[0...fin] + "n" + linea[fin..-1].to_s
    end
    # Reserva sin el mensaje: el primer literal de la linea que lleve un \xNN.
    linea.sub(%r{(/[^/\n]*\\x[0-9A-Fa-f]{2}[^/\n]*/)([imxounse]*)}) { "#{$1}#{$2}n" }
  end

  # El fuente llega del motor como String UTF-8.
  #
  # Reconvertir desde Windows-1252 es EL ULTIMO RECURSO y no el primero, y esto
  # se aprendio probando: 0140_PokemonOrgBattleRules.rb de Iberia tiene bytes
  # que no son UTF-8 valido y aun asi COMPILA, porque estan dentro de literales
  # de bytes. Reconvertirlo "por si acaso" cambiaba el fichero —y con el, el
  # significado de esos literales— sin que hiciera falta para nada. El censo ya
  # lo habia dicho: ni un solo fichero de los cinco juegos esta en Latin-1.
  # Asi que solo se intenta cuando el fichero no compila, no es UTF-8 valido y
  # no hay ningun arreglo conocido que aplicarle.
  def self.reencodifica(nombre, src)
    return nil if src.valid_encoding?
    convertido = src.encode("UTF-8", "Windows-1252")
    NX.log("[fuente] #{nombre}: no compila y no es UTF-8 valido; reconvertido de Windows-1252")
    convertido
  rescue StandardError
    nil
  end

  def self.transforma(nombre, codigo)
    t0 = reloj
    @secciones += 1
    src = codigo
    hechos = 0
    begin
      src = codigo.dup.force_encoding("UTF-8")
      src, hechos = bucle(nombre.to_s, src)
    rescue Exception => e
      # Cualquier cosa que no sea un SyntaxError esperado: se devuelve lo que
      # haya y se deja constancia. El motor evaluaria el original de todos
      # modos, pero asi el fallo tiene nombre.
      NX.log("[fuente] #{nombre}: FALLO de la transformacion #{e.class}: #{e.message}")
    end
    @ms += (reloj - t0) * 1000.0
    @tocadas += 1 if hechos > 0
    @arreglos += hechos
    resumen if nombre.to_s == "Main"
    src
  end

  def self.bucle(nombre, src)
    hechos = 0
    ya = {}
    silencio, $VERBOSE = $VERBOSE, nil   # compilar dos veces duplicaria los avisos
    begin
      VUELTAS.times do
        begin
          RubyVM::InstructionSequence.compile(src, nombre)
          NX.log("[fuente] #{nombre}: #{hechos} arreglos, compila") if hechos > 0
          return [src, hechos]
        rescue SyntaxError => e
          lista = errores(nombre, e.message)
          # Sin linea no hay a quien apuntar. Unico caso en que se toca el
          # fichero entero: los `when X:`, que la regex del censo acota sola.
          if lista.empty?
            lineas = src.lines
            n = 0
            lineas.each_index do |i|
              if lineas[i] =~ CUANDO
                lineas[i] = lineas[i].sub(CUANDO, '\1 then\2')
                n += 1
              end
            end
            if n == 0
              otro = reencodifica(nombre, src)
              if otro
                src = otro
                hechos += 1
                next
              end
              NX.log("[fuente] #{nombre}: NO COMPILA y el error no trae linea: #{e.message.lines.first.to_s.strip}")
              return [src, hechos]
            end
            NX.log("[fuente] #{nombre}: #{n} `when X:` sin linea en el mensaje, arreglados a ciegas con la regex del censo")
            hechos += n
            src = lineas.join
            next
          end

          lineas = src.lines
          cambio = 0
          lista.each do |linea, texto|
            tipo = clasifica(texto)
            next if tipo.nil?
            clave = "#{tipo}:#{linea}"
            next if ya[clave]          # no repetir el mismo arreglo en la misma linea
            nueva = arregla(lineas, linea, tipo, texto)
            next if nueva.nil?
            ya[clave] = true
            cambio += 1
            NX.log("[fuente] #{nombre}: linea #{linea} #{etiqueta(tipo)}")
          end
          if cambio == 0
            otro = reencodifica(nombre, src)
            if otro
              src = otro
              hechos += 1
              next
            end
            NX.log("[fuente] #{nombre}: NO COMPILA, sin arreglo conocido: #{e.message.lines.first.to_s.strip}")
            return [src, hechos]
          end
          hechos += cambio
          src = lineas.join
        end
      end
      NX.log("[fuente] #{nombre}: NO COMPILA tras #{VUELTAS} vueltas, se devuelve lo mejor que hay")
      [src, hechos]
    ensure
      $VERBOSE = silencio
    end
  end

  def self.etiqueta(tipo)
    case tipo
    when :cuando then "when X: -> when X then"
    when :break  then "break -> return (cuerpo de metodo)"
    when :retry  then "retry -> redo (fuera de rescue)"
    when :regex  then "regex con \\xNN -> se le anade /n"
    else tipo.to_s
    end
  end

  # "Main" es la ultima seccion de todo proyecto de RPG Maker XP, asi que el
  # resumen sale justo cuando ya han pasado todas y antes de que el juego
  # empiece. Lo que se quiere saber en la consola es el COSTE: esto se paga al
  # arrancar, una vez, y compilar dos veces cada seccion no es gratis.
  def self.resumen
    return if @resumido
    @resumido = true
    NX.log("[fuente] TOTAL: #{@secciones} secciones, #{@tocadas} tocadas, " \
           "#{@arreglos} arreglos, #{@ms.round(1)} ms")
  end
end
NX.log("[nx] NXFuente.transforma listo (sintaxis de Ruby 1.8 guiada por el compilador)")

# ---------------------------------------------------------------------------
# 2. Win32API postizo
# ---------------------------------------------------------------------------
#
# En mkxp-z lo aporta binding/miniffi-binding.cpp sobre SDL_LoadObject, y el
# Makefile de mkxp-z-nx lo excluye a proposito. Aunque se compilara, en Horizon
# no hay user32.dll que cargar.
#
# Lo que mata el arranque no son las llamadas: son las 12-14 asignaciones que se
# evaluan al cargar el script (`RtlMoveMemory = Win32API.new(...)` en el cuerpo
# de una clase, `@GetKeyState=Win32API.new(...)` en el de un modulo). Con la
# clase definida, todas ellas construyen un objeto y siguen adelante.
#
# OJO: los juegos REABREN esta clase. Opalo trae un 0005_Win32API.rb entero que
# hace `class Win32API` y le anade metodos de clase (SetWindowText, SetWindowPos,
# pbFindRgssWindow...), y su cuerpo lleva `@@GetCurrentThreadId=Win32API.new(...)`.
# Por eso esto tiene que ser una CLASE de verdad y no un modulo con method_missing.
class Win32API
  # Registro con cuentagotas. Estos juegos construyen el objeto Win32API DENTRO
  # del metodo que lo llama (Winsock hace `Win32API.new(DLL,"send",...).call(...)`
  # en cada envio) y algunos se llaman por fotograma: registrar cada vez llenaria
  # la SD y costaria un fsync a 60 Hz. Se registra la primera vez que se pide una
  # funcion y la primera vez que se llama, y nada mas.
  @@pedidas = {}
  @@llamadas = {}

  def self.nx_visto(mapa, clave, texto)
    return if mapa[clave]
    mapa[clave] = true
    NX.log(texto)
  end

  # 'kernel32', 'kernel32.dll', 'Kernel32.dll', './rubyscreen.dll' y
  # 'winmm.dll' aparecen los cinco en el mismo corpus: se normaliza o la tabla
  # de semanticas tendria que llevar cada variante.
  def self.nx_clave(dll, funcion)
    d = dll.to_s.tr("\\", "/").split("/").last.to_s
    d = d.sub(/\.dll\z/i, "")
    "#{d.downcase}!#{funcion}"
  end

  attr_reader :nx_dll, :nx_funcion, :nx_importa, :nx_exporta, :nx_clave

  def initialize(dll = "", funcion = "", importa = nil, exporta = nil)
    @nx_dll     = dll.to_s
    @nx_funcion = funcion.to_s
    # `importa` llega de siete formas distintas en el mismo juego: 'LLIIIII',
    # %w(l p) (Array), ['P']*3 (Array), '%w(l p)' (una cadena con el %w dentro,
    # que en 1.8 tampoco significaba nada) y '' . No se usa para nada; se guarda
    # tal cual por si algun dia hace falta para diagnosticar.
    @nx_importa = importa
    @nx_exporta = (exporta.is_a?(Array) ? exporta.join : exporta.to_s)
    @nx_clave   = Win32API.nx_clave(@nx_dll, @nx_funcion)
    Win32API.nx_visto(@@pedidas, @nx_clave,
                      "[win32api] #{@nx_clave} pedido por el script")
  end

  def call(*args)
    Win32API.nx_visto(@@llamadas, @nx_clave,
                      "[win32api] #{@nx_clave} llamado (solo se avisa la 1a vez)")
    NXWin32.despacha(@nx_clave, @nx_exporta, args)
  rescue Exception => e
    # Un fallo del postizo no puede tumbar el juego: devolver el neutro es
    # exactamente lo que haria la version muda.
    NX.log("[win32api] #{@nx_clave}: FALLO del postizo #{e.class}: #{e.message}")
    NXWin32.neutro(@nx_exporta)
  end
  alias Call call

  def to_s
    "#<Win32API #{@nx_clave}>"
  end
  alias inspect to_s
end

# La semantica, separada de la clase para que los juegos puedan reabrir
# `class Win32API` sin riesgo de pisar nada de esto.
module NXWin32
  # El valor neutro segun el tipo de retorno declarado.
  #
  # Se devuelve 0 tambien para 'v'/'V' (void) y para '' aunque en Win32API de
  # verdad no devuelvan nada: en estos scripts el resultado de una llamada de
  # tipo 'V' se compara con cero (`mciSendString`) o se le aplica una mascara
  # (`@GetKeyState.call(key)&0x8000`), y un nil daria NoMethodError en un sitio
  # que no tiene ninguna relacion con el problema.
  def self.neutro(exporta)
    case exporta.to_s[0, 1].to_s.downcase
    when "p" then ""
    else 0
    end
  end

  # Tamano de la ventana. Los juegos preguntan por el para centrar la ventana y
  # para calcular margenes; devolver 0 lo mas facil, pero un 0 aqui se acaba
  # dividiendo en algun sitio. Se contesta con la resolucion real si Graphics ya
  # existe (en el preload todavia no) y con la de Essentials clasico si no.
  def self.ancho
    (defined?(Graphics) && Graphics.respond_to?(:width) ? Graphics.width : 512) rescue 512
  end

  def self.alto
    (defined?(Graphics) && Graphics.respond_to?(:height) ? Graphics.height : 384) rescue 384
  end

  # Escribe en un bufer que el script paso por referencia. En Win32API el
  # patron es siempre el mismo: `buf = "\0"*256; api.call(..., buf, 256, ...)` y
  # luego `buf.delete!("\0")` o `buf.unpack(...)`. En Ruby eso solo funciona si
  # se MUTA la cadena que llego; asignarle otra no hace nada.
  def self.rellena(buf, datos)
    return 0 unless buf.is_a?(String)
    n = buf.bytesize
    d = datos.to_s.dup.force_encoding("ASCII-8BIT")
    d = d[0, n] if n > 0 && d.bytesize > n
    d += "\0" * (n - d.bytesize) if n > d.bytesize
    buf.replace(d)
    datos.to_s.bytesize
  end

  # Un puñado de constantes de winsock, para que se lea lo que devuelve.
  INVALID_SOCKET  = -1
  SOCKET_ERROR    = -1
  WSAENETDOWN     = 10050
  INADDR_NONE     = 0xFFFFFFFF

  def self.despacha(clave, exporta, args)
    case clave

    # --- Game.ini: lo unico de esta lista que se implementa DE VERDAD --------
    # Los juegos guardan y leen opciones ahi (el nombre del Scripts.rxdata, la
    # ruta del RTP, ajustes propios), y el fichero existe en la tarjeta porque
    # §2 de CONVENCIONES.md copia sueltos todos los ficheros de la raiz.
    # Firma: GetPrivateProfileString(seccion, clave, omision, buf, tam, ruta)
    when "kernel32!GetPrivateProfileString"
      seccion, llave, omision, buf, _tam, ruta = args
      valor = NXIni.lee(ruta, seccion, llave, omision.to_s)
      rellena(buf, valor)

    # Firma: WritePrivateProfileString(seccion, clave, valor, ruta)
    when "kernel32!WritePrivateProfileString"
      seccion, llave, valor, ruta = args
      NXIni.escribe(ruta, seccion, llave, valor) ? 1 : 0

    # WriteProfileString escribe en WIN.INI (el del sistema). Aqui no hay
    # ninguno y nadie lo lee: 1 (exito) para que el llamante no reintente.
    when "kernel32!WriteProfileString"
      1

    # --- memoria ------------------------------------------------------------
    # RtlMoveMemory es 34 de las 164 referencias de Opalo y NO SE PUEDE hacer:
    # el juego pasa `bitmap.__id__*2+16` como si el object_id fuera la direccion
    # del objeto, que era cierto en el Ruby 1.8 de 32 bits y no lo es en ningun
    # Ruby moderno. Escribir ahi seria corromper el monton. Devuelve 0 y el
    # bufer del script se queda a ceros, que es lo que ya pasa hoy.
    when "kernel32!RtlMoveMemory"
      NXWin32.aviso(clave, "no se copia memoria: los __id__ de 3.1 no son punteros")
      0

    # --- ventana ------------------------------------------------------------
    # pbFindRgssWindow de 0005_Win32API.rb hace
    #   begin; nextwindow=FindWindowEx.call(0,nextwindow,"RGSS Player",0)
    #     ... end until nextwindow==0
    #   raise "Can't find RGSS player window"
    # o sea que si FindWindow devuelve 0 el metodo LANZA. Se devuelve un asa
    # falsa (1) y se hace que GetCurrentThreadId y GetWindowThreadProcessId
    # coincidan, con lo que el bucle sale en la primera vuelta con la asa 1 y
    # nadie lanza nada. Todo lo que se haga despues con esa asa es inofensivo.
    when "user32!FindWindow", "user32!FindWindowEx", "user32!GetForegroundWindow",
         "user32!GetActiveWindow"
      1
    when "kernel32!GetCurrentThreadId", "user32!GetWindowThreadProcessId"
      1

    when "user32!GetWindowRect", "user32!GetClientRect"
      # rect.unpack('l4') -> x, y, derecha, abajo. El script hace
      # Rect.new(x,y,width-x,height-y), asi que 0,0,W,H da la ventana entera.
      rect = args[1]
      rellena(rect, [0, 0, ancho, alto].pack("l4"))
      1

    when "user32!GetSystemMetrics"
      # SM_CXSCREEN=0, SM_CYSCREEN=1. Lo demas, 0.
      case args[0].to_i
      when 0 then 1280
      when 1 then 720
      else 0
      end

    when "user32!GetCursorPos"
      rellena(args[0], [0, 0].pack("l2"))
      1

    when "user32!ScreenToClient"
      1

    # Mover, redimensionar y renombrar la ventana no significa nada con la
    # pantalla completa fija de la consola: 0 y a otra cosa.
    when "user32!SetWindowPos", "user32!SetWindowLong", "user32!SetWindowTextA",
         "user32!ShowWindow", "user32!MoveWindow", "user32!SendMessage",
         "user32!PostMessage", "user32!SetCapture", "user32!ReleaseCapture",
         "user32!ShowCursor", "user32!RegisterHotKey", "user32!MessageBox"
      0

    # --- teclado y raton ----------------------------------------------------
    # 0 = ninguna tecla pulsada. La entrada del jugador NO pasa por aqui: pasa
    # por Input.*, que mkxp-z tiene y el motor mapea a los botones del mando.
    # Estos Win32API son el teclado "extra" (atajos de depuracion, el editor de
    # animaciones, la tarjeta de entrenador de Opalo) y el ToUnicode de la
    # entrada de texto. Ver la nota sobre USEKEYBOARDTEXTENTRY al final.
    when "user32!GetKeyState", "user32!GetAsyncKeyState", "user32!MapVirtualKey",
         "user32!ToUnicode", "user32!PeekMessage"
      0

    when "user32!GetKeyboardState"
      rellena(args[0], "\0" * 256)
      1

    # --- bateria ------------------------------------------------------------
    # pbBatteryLow? hace power="\0"*12; sps.call(power); power.unpack("CCCCVV").
    # Se rellena la SYSTEM_POWER_STATUS de una maquina enchufada y sin bateria:
    # ACLineStatus=1, BatteryFlag=128 (sin bateria), BatteryLifePercent=255
    # (desconocido), y los dos tiempos a -1. Con eso pbBatteryLow? da false y el
    # juego no ensena el aviso de "guarda, que te quedas sin bateria" en una
    # consola cuya bateria no controla.
    when "kernel32!GetSystemPowerStatus"
      rellena(args[0], [1, 128, 255, 0, 0xFFFFFFFF, 0xFFFFFFFF].pack("CCCCVV"))
      1

    # --- usuario y sistema --------------------------------------------------
    # GetUserName(buf, tambuf): el juego lo usa para el nombre por omision del
    # entrenador y para la carpeta de guardado. "Switch" es mejor que vacio.
    when "advapi32!GetUserName", "advapi32!GetUserNameA"
      rellena(args[0], "Switch\0")
      rellena(args[1], [7].pack("L")) if args[1].is_a?(String)
      1

    when "kernel32!GetUserDefaultLangID"
      0x0C0A          # espanol (Espana). Estos cuatro juegos estan en espanol.
    when "kernel32!GetUserGeoID"
      217             # Espana
    when "kernel32!GetLastError"
      0
    when "kernel32!GetCurrentProcess"
      1
    when "kernel32!SetPriorityClass", "kernel32!LoadLibrary", "kernel32!FreeLibrary"
      # LoadLibrary devuelve 0 = "no se pudo cargar": es lo que se quiere, que
      # el juego concluya que la DLL no esta y se vaya por el camino de reserva.
      0

    # La consola de depuracion de Windows. No hay ninguna; ya se escribe todo en
    # mkxp-ruby.log por el $stdout de nx-compat.rb.
    when /\Akernel32!(AllocConsole|CreateConsoleScreenBuffer|SetConsole|WriteConsole|ReadConsole|FormatMessage)/
      0

    # El registro de Windows (MiniRegistry: busca la ruta del RTP y el ajuste
    # PlaySound). 2 = ERROR_FILE_NOT_FOUND, que es la verdad.
    when /\Aadvapi32!Reg/
      2

    # --- lo que no se puede tapar, solo callar ------------------------------
    when /\Awinmm!/, /\Awinmm\.dll!/
      # mciSendString (video), waveOut* (el segundo sistema de audio, el que
      # reproduce wave a mano para los tonos del telefono). El audio normal del
      # juego va por la clase Audio de mkxp-z y no pasa por aqui.
      0

    when /\Arubyscreen!/
      NXWin32.aviso(clave, "captura de pantalla desactivada")
      0

    when "gdi32!AddFontResource"
      # Las fuentes del juego las carga mkxp-z solo desde Fonts/.
      0

    when /\Agdi32!/
      0

    when /\Akleinbitmap!/
      NXWin32.aviso(clave, "KleinBitmap.dll no esta: ese bitmap NO se ha procesado")
      0

    when /\Agif!/
      # Va protegido con `if safeExists?("gif.dll")` y la DLL no viaja a la
      # tarjeta, asi que esto no deberia llamarse nunca. Si sale en el registro,
      # es que alguien copio la DLL a mano.
      0

    when /\Aaudio!/, /\Argss linker!/, /\Argss fmodex!/
      NXWin32.aviso(clave, "audio nativo desactivado; suena por la clase Audio de mkxp-z")
      0

    when /\Ashell32!/, /\Aole32!/
      # SHGetSpecialFolderLocation / SHGetKnownFolderPath: "Mis documentos",
      # donde Essentials quiere guardar. 1 = fallo -> el juego cae a su reserva,
      # que es guardar junto al ejecutable, que es lo que hay que hacer aqui.
      1

    when /\Amsvcrt!/, /\Axinput/
      0

    # --- sockets ------------------------------------------------------------
    # 0006_Sockets.rb monta TCP entero sobre Win32API de ws2_32 (12 usos en un
    # fichero). No hay red que ofrecer, pero SI hay que contestar de forma que
    # el codigo concluya "sin conexion" y siga: devolver 0 en `socket` seria un
    # descriptor VALIDO y el juego se quedaria esperando datos para siempre.
    when "ws2_32!socket", "ws2_32!accept"
      INVALID_SOCKET
    when "ws2_32!connect", "ws2_32!bind", "ws2_32!listen", "ws2_32!send",
         "ws2_32!recv", "ws2_32!select", "ws2_32!setsockopt", "ws2_32!shutdown",
         "ws2_32!ioctlsocket", "ws2_32!WSAStartup"
      SOCKET_ERROR
    when "ws2_32!WSAGetLastError"
      WSAENETDOWN                       # "la red esta caida": la verdad exacta
    when "ws2_32!closesocket"
      0                                 # cerrar lo que no existe siempre va bien
    when "ws2_32!gethostbyname", "ws2_32!gethostbyaddr", "ws2_32!getservbyname"
      0                                 # NULL
    when "ws2_32!inet_addr"
      INADDR_NONE
    when "ws2_32!inet_ntoa"
      "0.0.0.0"
    when "ws2_32!htons", "ws2_32!htonl", "ws2_32!ntohs", "ws2_32!ntohl"
      args[0].to_i                      # sin conversion: nadie mira el orden
    when "ws2_32!gethostname"
      rellena(args[0], "switch\0")
      0

    else
      NXWin32.aviso(clave, "sin semantica: se devuelve el neutro")
      neutro(exporta)
    end
  end

  @@avisos = {}
  def self.aviso(clave, texto)
    return if @@avisos[clave]
    @@avisos[clave] = true
    NX.log("[win32api] #{clave}: #{texto}")
  end
end

# Un .ini de veinte lineas. No se usa una gema ni se intenta cubrir el formato
# entero: sirve para Game.ini, que es "[Game]\nLibrary=...\nScripts=...".
module NXIni
  # Las rutas llegan como ".\\Game.ini" y como "./Game.ini". El motor ya hizo
  # chdir a la carpeta del juego, asi que basta con quedarse con el nombre.
  def self.ruta(r)
    s = r.to_s.tr("\\", "/")
    s = s.sub(%r{\A\./}, "")
    s
  end

  def self.lee(r, seccion, llave, omision)
    texto = File.binread(ruta(r)) rescue nil
    return omision unless texto
    actual = nil
    texto.force_encoding("UTF-8")
    texto.each_line do |l|
      l = l.strip
      next if l.empty? || l.start_with?(";", "#")
      if l =~ /\A\[(.*)\]\z/
        actual = $1.strip.downcase
      elsif (i = l.index("="))
        next unless actual == seccion.to_s.downcase
        next unless l[0...i].strip.downcase == llave.to_s.downcase
        return l[(i + 1)..-1].to_s.strip
      end
    end
    omision
  rescue StandardError => e
    NX.log("[ini] no se pudo leer #{ruta(r)}: #{e.class}: #{e.message}")
    omision
  end

  def self.escribe(r, seccion, llave, valor)
    destino = ruta(r)
    lineas = (File.binread(destino).force_encoding("UTF-8").lines rescue [])
    actual = nil
    puesto = false
    fin_seccion = nil
    lineas.each_index do |i|
      l = lineas[i].strip
      if l =~ /\A\[(.*)\]\z/
        fin_seccion = i if actual == seccion.to_s.downcase && fin_seccion.nil?
        actual = $1.strip.downcase
      elsif (j = l.index("=")) && actual == seccion.to_s.downcase &&
            l[0...j].strip.downcase == llave.to_s.downcase
        lineas[i] = "#{llave}=#{valor}\n"
        puesto = true
        break
      end
    end
    unless puesto
      if lineas.any? { |l| l.strip.downcase == "[#{seccion.to_s.downcase}]" }
        pos = fin_seccion || lineas.size
        lineas.insert(pos, "#{llave}=#{valor}\n")
      else
        lineas << "\n" unless lineas.empty? || lineas.last.end_with?("\n")
        lineas << "[#{seccion}]\n" << "#{llave}=#{valor}\n"
      end
    end
    File.binwrite(destino, lineas.join)
    true
  rescue StandardError => e
    NX.log("[ini] no se pudo escribir #{ruta(r)}: #{e.class}: #{e.message}")
    false
  end
end
NX.log("[nx] Win32API postizo definido (Game.ini de verdad; el resto, neutro y registrado)")

# ---------------------------------------------------------------------------
# 3. Los metodos que 1.8 tenia y 3.1 no
# ---------------------------------------------------------------------------
#
# Nada de esto se anade "por si acaso": cada uno se conto antes con un grep
# sobre los cinco corpus (Opalo 214 scripts, Iberia 168, Titan 167, Z 235,
# Uranium 260) y lo que salio a cero no esta aqui. Menos superficie, menos
# sorpresas. Todos van con `unless method_defined?`, porque los juegos definen
# algunos de estos nombres para sus propias clases y el suyo tiene que ganar,
# que es exactamente lo que pasaba en 1.8.

# Array#nitems — 7 usos en CADA uno de los cinco juegos, y el censo se equivoco
# al descartarlo. Es verdad que PokemonBox define `def nitems`, pero lo que ese
# metodo hace es `return @pokemon.nitems`, y @pokemon es un Array de 30 huecos
# con nil dentro: la llamada de verdad es Array#nitems, "cuantos no son nil".
# Sin esto, `full?` y `pbFirstFreePos` mueren con NoMethodError la primera vez
# que se abre el PC de Pokemon o se captura el septimo bicho.
class Array
  unless method_defined?(:nitems)
    def nitems
      count { |x| !x.nil? }
    end
  end
end

# Thread.critical — 12 usos en cada uno de los cinco juegos, en Audio.rb
# (Thread.exclusive) y en BitmapCache. Se retiro en 1.9 con los hilos nativos.
# El patron es siempre `_old = Thread.critical; Thread.critical = true; ...
# ensure Thread.critical = _old`, asi que hace falta el par lector/escritor o el
# `ensure` casca. No-op: en la Switch el juego corre en un hilo y no hay nada
# que excluir; mkxp-z ya serializa las llamadas al motor.
class Thread
  class << self
    unless respond_to?(:critical)
      def critical
        false
      end

      def critical=(valor)
        valor
      end
    end
  end
end

# Object#type — el alias de `class` que 1.8 traia y que 1.9 retiro. El grep no
# discrimina (121 `.type` en Opalo, 129 en Z... pero Anil, que corre sobre 3.1,
# tiene 90: en un juego de Pokemon `.type` mide la palabra "tipo"). Se define
# igualmente porque no cuesta nada y porque las clases que definen el suyo
# —PBMove#type, PokemonRules#type, el `type=` del clima— lo pisan, que es
# justo lo que ocurria en 1.8. Se registran las diez primeras llamadas CON EL
# LLAMANTE: si en el registro aparecen, ahi hay codigo de 1.8 de verdad; si no
# aparece ninguna, este metodo no ha hecho falta nunca y sobra.
class Object
  unless method_defined?(:type)
    # Una variable global y no una de clase: una @@ en Object la comparten
    # todas sus descendientes y Ruby 3.x lanza RuntimeError en cuanto una
    # subclase la toca ("class variable of Object is overtaken by ...").
    $nx_type_avisos = 0
    def type
      if $nx_type_avisos.to_i < 10
        $nx_type_avisos = $nx_type_avisos.to_i + 1
        NX.log("[1.8] Object#type sobre #{self.class} desde #{caller(1, 1).to_a.first}")
      end
      self.class
    end
  end
end

# Lo que se busco y NO se encontro en ninguno de los cinco juegos, y por eso no
# esta definido: Array#indexes / Array#indices (0), Array#choice (0),
# Hash#index (0), Hash#indexes (0), Object#to_a (los 9 `.to_a` del corpus son
# Range#to_a y String#bytes.to_a, que 3.1 tiene), Kernel#getc (los 2 usos son
# metodos `getc` que los propios juegos definen en File_Mixins y SpriteWindow),
# String#each y String#to_a (0 usos localizables), Symbol#to_proc (ya existe).

# ---------------------------------------------------------------------------
# La entrada de texto de la familia v16: USEKEYBOARDTEXTENTRY
# ---------------------------------------------------------------------------
#
# runtime/lib/nx-teclado.rb desvia pbEnterText a la rejilla de caracteres
# mirando `$PokemonSystem.textinput`, y eso NO SIRVE en estos cinco juegos:
# `textinput` sale 0 veces en los cinco corpus. En Essentials clasico la
# eleccion es una constante que se fija al cargar el script 0001_Settings.rb:
#
#     USEKEYBOARDTEXTENTRY = true          # Opalo 0001_Settings.rb:358
#     if USEKEYBOARDTEXTENTRY              # 0054_TextEntry.rb:1601
#       sscene=PokemonEntryScene.new       # "escribe con el teclado y pulsa Enter"
#     else
#       sscene=PokemonEntryScene2.new      # la rejilla con cursor
#
# Con la constante a true el juego pide el nombre del entrenador por teclado, y
# en una consola sin teclado eso es un callejon sin salida silencioso: la
# partida no puede empezar y no sale ningun error.
#
# El arreglo tiene que ser tardio porque la constante no existe hasta que se
# carga el script del juego. Se engancha a Graphics.update, se cambia en cuanto
# aparece y se desengancha: el coste en regimen es un `defined?` por fotograma
# hasta la primera pantalla, y cero despues.
module NXTexto18
  @hecho = false
  class << self
    attr_accessor :hecho
  end

  def self.revisar
    return unless Object.const_defined?(:USEKEYBOARDTEXTENTRY)
    @hecho = true
    return unless Object.const_get(:USEKEYBOARDTEXTENTRY)
    silencio, $VERBOSE = $VERBOSE, nil     # "already initialized constant"
    Object.const_set(:USEKEYBOARDTEXTENTRY, false)
    $VERBOSE = silencio
    NX.log("[teclado] USEKEYBOARDTEXTENTRY = false: el nombre se escribe en la rejilla")
  rescue Exception => e
    @hecho = true
    NX.log("[teclado] FALLO al cambiar USEKEYBOARDTEXTENTRY: #{e.class}: #{e.message}")
  end
end

if defined?(Graphics) && Graphics.respond_to?(:update)
  module Graphics
    class << self
      alias_method :nx_update_sin_texto18, :update

      def update
        NXTexto18.revisar unless NXTexto18.hecho
        nx_update_sin_texto18
      end
    end
  end
end

# ---------------------------------------------------------------------------
# Lo que habra que ir viendo en el registro
# ---------------------------------------------------------------------------
#
# Compilar no es correr, y esto es lo que un compilador no ve. No se puede
# emular globalmente porque cambiaria el significado del codigo bueno tambien;
# se deja escrito para que quien arranque el juego sepa que buscar en
# mkxp-ruby.log cuando algo salga raro.
#
#   String#[] con un entero. En 1.8 "abc"[0] daba 97 (el codigo del caracter);
#   en 3.1 da "a". Redefinirlo romperia todo el codigo que ya cuenta con la
#   semantica nueva. Sintoma: comparaciones de caracteres que nunca aciertan, y
#   `TypeError: no implicit conversion of String into Integer`. No es
#   grepeable: `[0]` sale por todas partes.
#
#   Array#to_s. En 1.8 [1,2].to_s daba "12"; en 3.1 da "[1, 2]". Sintoma:
#   corchetes y comas dentro de un texto de la pantalla. Tampoco es grepeable:
#   186 `.to_s` en Anil, que corre.
#
#   methods / instance_methods devolvian Strings y ahora devuelven Symbols. El
#   patron acotable es `.methods.include?("...")`, que sale CERO veces en los
#   cinco juegos, asi que este probablemente no aparezca.
#
#   Proc.new sin bloque (heredaba el bloque del metodo): 7 usos en cada juego,
#   pero hay que mirarlos uno a uno porque casi todos son `Proc.new {...}`, que
#   sigue siendo legal. En 3.1 el `Proc.new` sin bloque es ArgumentError, y sale
#   con nombre y linea en el registro, asi que se vera cuando pase.
#
#   Hash#index -> Hash#key. Cero usos localizados, pero un `.index(` sobre un
#   Hash daria NoMethodError con nombre y linea: facil de identificar.
#
#   RtlMoveMemory. 34 referencias en el corpus, todas partiendo de que
#   `objeto.__id__ * 2` es la direccion del objeto. Eso era cierto en el Ruby
#   1.8 de 32 bits y no lo es aqui. El postizo devuelve 0 y no toca memoria: el
#   bitmap que se iba a exportar sale en negro, el juego no se cae.
#
#   KleinBitmap.dll. Segun 0181_KleinBitmapFunctions.rb es una biblioteca de
#   efectos sobre Bitmap: save_pallete/modify_pallete (guardar y aplicar una
#   paleta .kpal), scroll_up/down/left/right (desplazar el contenido del bitmap,
#   que es como se animan las cascadas y el agua), to_retro (reducir a cuatro
#   colores), modify_color y add_outline. Todas llaman
#   `klein_dll(func, ...).call(self.__id__, ...)`, otra vez el puntero por
#   __id__. Con el postizo devuelven 0 y el bitmap sale SIN EL EFECTO: no falta
#   nada en pantalla, esta sin retocar. En Iberia y Titan hay ademas un
#   `Map - Klein.rb` que es el exportador de mapas de KleinStudio (Control+P
#   guarda el mapa entero a PNG); es una herramienta de desarrollo atada a un
#   atajo de teclado que en la consola no se puede pulsar, no el dibujado del
#   mapa. Quien pruebe Iberia debe mirar el agua y las cascadas, no el mapa.
NX.log("[nx] nx-ruby18.rb cargado: Array#nitems, Thread.critical, Object#type")
