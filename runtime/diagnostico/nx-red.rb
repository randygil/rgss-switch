# nx-red.rb — sonda de HTTPLite (http y https). No se carga en produccion.
#
# HTTPLite no llegaba a la red en Switch: ni sockets (nadie llamaba a
# socketInitialize) ni TLS (cpp-httplib sin OpenSSL). Desde que net.cpp va
# sobre libcurl y nx/nx_red.c abre los sockets, esta sonda comprueba lo que
# necesita un plugin de guardado en la nube, que es JSON por HTTPS con cuerpos
# de varios megas:
#
#   1. GET con cabeceras propias, y que el JSON llega como UTF-8.
#   2. GET de un cuerpo binario con los 256 valores de byte.
#   3. POST (post_body) de 3 MB de JSON en base64 que vuelve en espejo, igual.
#   4. POST de un cuerpo con \0 dentro: tiene que llegar entero.
#   5. POST de formulario (HTTPLite.post) y redireccion seguida.
#   6. Un puerto cerrado: tiene que ser una excepcion, no un cuelgue.
#   7. HTTPS GET y POST a servidores publicos.
#   8. Lo que hace un plugin con sus ficheros: Dir.mkdir de una subcarpeta,
#      escribir, File.rename encima de otro y borrar.
#   9. Solo si existe red-certificados-malos.txt: HTTPS a un certificado
#      autofirmado y a uno de otro nombre, que tienen que FALLAR porque la
#      verificacion esta encendida. En Ryujinx esto cierra el emulador (ver
#      abajo): es una prueba para la consola.
#
# El servidor de 1-6 es un Node de prueba (eco, binario, espejo, redir). Su
# direccion se lee de red-servidor.txt en la carpeta del juego (una linea,
# "http://IP:PUERTO"); si no esta, se prueba 127.0.0.1:8787, que en Ryujinx es
# el propio PC. Todo va a mkxp-ruby.log con el prefijo [red]; al final escribe
# "[red] FIN n/m" con cuantas pruebas pasaron.

module NXRed
  @ok = 0
  @total = 0

  def self.log(m) NX.log("[red] #{m}") end

  def self.prueba(nombre)
    @total += 1
    t = Time.now
    r = yield
    ms = ((Time.now - t) * 1000).round
    if r
      @ok += 1
      log("OK    #{nombre} (#{ms} ms) #{r == true ? '' : r}")
    else
      log("FALLO #{nombre} (#{ms} ms)")
    end
  rescue Exception => e
    ms = ((Time.now - t) * 1000).round
    log("FALLO #{nombre} (#{ms} ms) #{e.class}: #{e.message}")
  end

  # Como prueba(), pero lo que se espera es una excepcion.
  def self.debe_fallar(nombre)
    @total += 1
    t = Time.now
    r = yield
    ms = ((Time.now - t) * 1000).round
    log("FALLO #{nombre} (#{ms} ms) no fallo: status #{r[:status] rescue r.inspect}")
  rescue Exception => e
    ms = ((Time.now - t) * 1000).round
    @ok += 1
    log("OK    #{nombre} (#{ms} ms) fallo como debe: #{e.class}: #{e.message}")
  end

  def self.servidor
    f = "red-servidor.txt"
    File.file?(f) ? File.read(f).strip : "http://127.0.0.1:8787"
  end

  def self.probar
    log("HTTPLite: #{defined?(HTTPLite) ? 'definido' : 'NO DEFINIDO'}")
    base = servidor
    log("servidor de prueba: #{base}")

    prueba("GET eco con cabeceras") do
      r = HTTPLite.get("#{base}/eco?x=1", { "X-Prueba" => "sonda", "Accept" => "application/json" })
      j = HTTPLite::JSON.parse(r[:body])
      r[:status] == 200 && j["headers"]["x-prueba"] == "sonda" &&
        r[:body].encoding.to_s == "UTF-8" && j["texto"] == "ñandú" &&
        "status #{r[:status]} enc #{r[:body].encoding} ua=#{j['headers']['user-agent']} cab=#{r[:headers].keys.sort.join(',')}"
    end

    prueba("GET binario 0..255") do
      r = HTTPLite.get("#{base}/binario")
      b = r[:body].bytes
      b == (0..255).to_a && "#{b.size} bytes, enc #{r[:body].encoding}"
    end

    prueba("POST 3 MB base64 JSON en espejo") do
      crudo = (0...(2 * 1024 * 1024)).map { |i| (i * 7 + i / 256) & 0xFF }.pack("C*")
      cuerpo = "{\"slot\":1,\"data\":\"" + [crudo].pack("m0") + "\"}"
      r = HTTPLite.post_body("#{base}/espejo", cuerpo, "application/json",
                             { "Authorization" => "Bearer prueba" })
      r[:status] == 200 && r[:body].bytesize == cuerpo.bytesize && r[:body] == cuerpo &&
        "#{cuerpo.bytesize} B ida y vuelta"
    end

    prueba("POST binario con NUL") do
      cuerpo = (0..255).to_a.pack("C*") * 4
      r = HTTPLite.post_body("#{base}/espejo", cuerpo, "application/octet-stream")
      r[:body].bytes == cuerpo.bytes && "#{r[:body].bytesize} B, X-Largo=#{r[:headers]['x-largo'] || r[:headers]['X-Largo']}"
    end

    prueba("POST formulario") do
      r = HTTPLite.post("#{base}/eco", { "a" => "1", "b" => "dos y tres&=" })
      j = HTTPLite::JSON.parse(r[:body])
      r[:status] == 200 && j["len"] > 0 && j["headers"]["content-type"].to_s.include?("urlencoded") &&
        "len #{j['len']}"
    end

    prueba("GET redireccion seguida") do
      r = HTTPLite.get("#{base}/redir", nil, true)
      j = HTTPLite::JSON.parse(r[:body])
      r[:status] == 200 && j["url"] == "/eco?desde=redir" && "llego a #{j['url']}"
    end

    prueba("GET redireccion sin seguir") do
      r = HTTPLite.get("#{base}/redir")
      r[:status] == 302 && "status 302"
    end

    debe_fallar("GET a puerto cerrado") { HTTPLite.get("http://127.0.0.1:9") }

    ["https://www.google.com/", "https://httpbin.org/get", "https://example.com/"].each do |u|
      prueba("HTTPS GET #{u}") do
        r = HTTPLite.get(u, { "Accept" => "*/*" }, true)
        r[:status] >= 200 && r[:status] < 400 && "status #{r[:status]}, #{r[:body].bytesize} B"
      end
    end

    prueba("HTTPS POST https://httpbin.org/post") do
      r = HTTPLite.post_body("https://httpbin.org/post", "{\"hola\":\"switch\"}", "application/json")
      r[:status] == 200 && r[:body].include?("switch") && "status #{r[:status]}"
    end

    # Lo que haria un plugin de guardado en la nube con sus ficheros, en una
    # subcarpeta de la del juego. Se limpia antes por si una vuelta anterior
    # murio a medias.
    dir = "nx-prueba-red"
    a = File.join(dir, "partida.json.tmp")
    b = File.join(dir, "partida.json")
    sub = File.join(dir, "sub")
    [a, b].each { |f| File.delete(f) if File.file?(f) }
    Dir.rmdir(sub) if File.directory?(sub)
    Dir.rmdir(dir) if File.directory?(dir)

    prueba("ficheros: Dir.mkdir en la carpeta del juego y anidado") do
      Dir.mkdir(dir)
      Dir.mkdir(sub)
      File.directory?(dir) && File.directory?(sub) && "#{dir}/ y #{sub}/"
    end

    prueba("ficheros: File.rename a un nombre libre") do
      File.open(a, "wb") { |f| f.write("nuevo") }
      File.rename(a, b)
      File.read(b) == "nuevo" && !File.exist?(a) && "tmp -> definitivo"
    end

    # En POSIX rename() pisa el destino; en Horizon no: fsFsRenameFile
    # contesta "ya existe" y Ruby lo da como Errno::EEXIST. Aqui se MIDE, no
    # se da por bueno ni por malo: quien escriba "tmp + rename" tiene que
    # borrar antes el destino.
    @total += 1
    begin
      File.open(a, "wb") { |f| f.write("otra") }
      File.rename(a, b)
      @ok += 1
      log("OK    ficheros: File.rename ENCIMA de uno que existe: lo pisa (#{File.read(b)})")
    rescue SystemCallError => e
      @ok += 1
      log("OK    ficheros: File.rename ENCIMA de uno que existe NO lo pisa: #{e.class} " \
          "(Horizon; hay que borrar el destino antes)")
      File.delete(b)
      File.rename(a, b)
      log("      borrando antes el destino si: #{File.read(b) == 'otra'}")
    end

    prueba("ficheros: File.delete y Dir.rmdir") do
      [a, b].each { |f| File.delete(f) if File.file?(f) }
      Dir.rmdir(sub)
      Dir.rmdir(dir)
      !File.exist?(dir) && "limpio"
    end

    # Al final y sólo a petición: en Ryujinx (1.x, servicio ssl sobre el
    # SslStream de .NET) un certificado que no valida no vuelve como error,
    # sino como una excepción sin recoger que CIERRA EL EMULADOR. En la consola
    # el servicio ssl devuelve el error y HTTPLite lo lanza como MKXPError.
    if File.file?("red-certificados-malos.txt")
      debe_fallar("HTTPS certificado autofirmado") { HTTPLite.get("https://self-signed.badssl.com/") }
      debe_fallar("HTTPS nombre equivocado") { HTTPLite.get("https://wrong.host.badssl.com/") }
    else
      log("(sin red-certificados-malos.txt: no se prueban certificados invalidos)")
    end

    log("FIN #{@ok}/#{@total}")
  rescue Exception => e
    log("ABORTADA #{e.class}: #{e.message} | #{(e.backtrace || []).first(3).join(' | ')}")
    log("FIN #{@ok}/#{@total}")
  end
end

NXRed.probar
