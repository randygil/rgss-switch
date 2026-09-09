# Empaquetar.ps1 - monta la carpeta que va a la tarjeta SD, con interfaz.
#
# Junta dos cosas que vienen de sitios distintos y que este repositorio no puede
# ni debe mezclar:
#
#   1. TU copia para PC de un juego de RPG Maker XP (Data/, Graphics/, Audio/...)
#   2. La entrega de rgss-switch (motor/rgss-switch.nro, mkxp.base.json, lib/,
#      juegos/, tools/), que es lo que hay en la misma carpeta que este guion.
#
# y deja en la carpeta de salida un switch/<slug>/ listo para copiar a la raiz de
# la SD, mas un <slug>.nsp al lado si hay prod.keys para firmarlo.
#
# NO SABE DE NINGUN JUEGO EN CONCRETO. Antes exigia Data/Scripts.rxdata,
# preload.rb, knownpoint.bmp y selpoint.bmp -ficheros de Pokemon Anil- y por eso
# se negaba a empaquetar Pokemon Opalo, que es un juego perfectamente valido sin
# ninguno de los tres. Ahora pide lo que un juego de RPG Maker XP tiene por
# fuerza -un .ini con [Game], datos (Data/ o un .rgssad) y Graphics/- y todo lo
# demas lo aprende: el titulo de su .ini, el slug de ese titulo, y lo que ese
# juego tenga de particular del perfil de juegos/<slug>/perfil.json.
#
# DOS FORMAS DE LLEVAR LOS RECURSOS. Los recursos de estos juegos son decenas de
# miles de ficheros y cientos de megas, y ahi esta el problema: una tarjeta SD no
# tarda por los bytes, tarda por la cuenta. Cada fichero es una entrada de
# directorio, una asignacion de clusters y una actualizacion de la tabla de
# FAT32; copiarlos sueltos va entre cinco y diez veces mas lento que copiar los
# mismos bytes en un solo fichero, y ademas cualquier corte a mitad deja una
# carpeta a medias que no se distingue de una entera.
#
#   -Contenedor zip       (por omision) un unico datos.zip SIN COMPRIMIR, que el
#                         .nro monta al arrancar con PhysFS. Un fichero que se
#                         copia rapido, se envia de una pieza y se comprueba con
#                         un solo hash.
#   -Contenedor carpetas  Data/, Graphics/, Audio/, Fonts/ y Movies/ sueltas. Es
#                         lo que hay que usar para parchear ficheros del juego
#                         uno a uno, y lo unico posible por encima de 4 GB.
#
# EL TRATO, medido y sin adornos. El contenedor cuesta unos segundos mas de
# arranque cada vez que se abre el juego: hay que abrir el archivo y leer su
# indice antes de empezar. En cambio se ahorra en cada copia, y ahi la diferencia
# se cuenta en decenas de minutos.
#
# Sin comprimir a proposito: la mayor parte de esos megas ya son PNG y OGG, que
# son formatos comprimidos, y los .rxdata llevan zlib dentro. Comprimir ahorra un
# 5% y se paga inflando cada lectura durante la partida.
#
# No necesita nada instalado: PowerShell viene con Windows. Sin interfaz:
#   powershell -File Empaquetar.ps1 -Juego "C:\...\Pokemon Opalo" -Salida D:\sd
#   powershell -File Empaquetar.ps1 -Juego "C:\...\Pokemon Opalo" -SoloDetectar
param(
    [string]$Juego = "",
    [string]$Salida = "",
    [ValidateSet("zip", "carpetas")]
    [string]$Contenedor = "zip",
    [switch]$SinInterfaz,
    # Carpeta de la entrega. Por omision, la del propio guion (§7). Se acepta a
    # mano para poder probar el empaquetador contra una entrega montada aparte
    # sin tener que copiarlo dentro de ella.
    [string]$Entrega = "",
    [string]$Claves = "",
    [switch]$Diagnostico,
    [switch]$SoloDetectar
)

$ErrorActionPreference = "Stop"
$RaizGuion = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $Entrega) { $Entrega = $RaizGuion }

# El nombre lo conoce tambien sharedstate.cpp del motor: si cambia aqui, cambia
# alli. Igual que la ruta de romfs:/juego.txt y el nombre del .nro (§1).
$NombrePaquete = "datos.zip"

# Las cinco carpetas que el motor lee por PhysFS y que por eso pueden viajar
# dentro del contenedor. Todo lo demas se copia suelto, porque Ruby -que es
# quien lee lo demas, con Dir y File.read- no ve dentro de PhysFS.
$CarpetasRecursos = @("Data", "Graphics", "Audio", "Fonts", "Movies")

# Material de desarrollo que un juego publicado no necesita y que en Vanguard son
# cientos de megas. Un perfil puede rescatar cualquiera quitandola de su lista.
$ExcluirPorOmision = @("PBS", "DataBackup", "DataExport", "dist", "Credits")

# Restos de escritorio y binarios de Windows que no pintan nada en una consola.
$NoCopiar = @("*.exe", "*.dll", "*.pdf", "*.lnk", "*.rar", "*.zip", "*.7z",
              "Thumbs.db", "desktop.ini", "*.parcial", ".nomedia")

# §5 capa 2: lo unico que se acepta del mkxp.json del propio juego. Lo que queda
# fuera -resolucion de ventana, vsync, gameFolder, rutas del PC, RTP- no es que
# estorbe: es que describe un escritorio, y aqui no hay ninguno.
$ClavesDelJuego = @(
    "windowTitle", "defScreenW", "defScreenH", "rgssVersion",
    "SESourceCount", "BGMTrackCount",
    "midiSoundFont", "midiChorus", "midiReverb",
    "subImageFix", "enableBlitting", "maxTextureSize",
    "bindingNames", "inputRepeatStart", "inputRepeatDelay",
    "patches", "execName", "solidFonts", "fontSub", "useScriptNames",
    "JITEnable", "JITMaxCache", "JITMinCalls"
)

# Los shims genericos, en su orden. nx-compat.rb va SIEMPRE el primero: define
# el modulo MKXP (la API de JoiPlay) que los preload.rb de varios de estos juegos
# llaman en su primera linea.
$ShimsGenericos = @("nx-compat.rb", "nx-teclado.rb", "nx-rutas.rb")

#============================================================== utilidades base

# PowerShell 5.1 escribe UTF-8 CON BOM por omision (Out-File, Set-Content), y un
# BOM delante de un JSON hace que el analizador de mkxp-z lea basura en la
# primera clave. Todo lo que va a la tarjeta pasa por aqui.
function Escribe-Utf8([string]$ruta, [string]$texto) {
    $sinBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($ruta, $texto, $sinBom)
}

# Estos juegos vienen de sitios muy distintos y sus .ini y .json llegan unas
# veces en UTF-8 y otras en la pagina ANSI de Windows. Se intenta UTF-8 estricto
# -que falla si los bytes no lo son- y solo entonces se cae a ANSI. Al reves, un
# Title con acentos en ANSI se leeria como interrogantes y el slug saldria mal.
function Lee-Texto([string]$ruta) {
    $b = [System.IO.File]::ReadAllBytes($ruta)
    if ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) {
        return [System.Text.Encoding]::UTF8.GetString($b, 3, $b.Length - 3)
    }
    try {
        $estricto = New-Object System.Text.UTF8Encoding($false, $true)
        return $estricto.GetString($b)
    } catch {
        return [System.Text.Encoding]::Default.GetString($b)
    }
}

# JSON5 -> JSON. Los mkxp.json de estos juegos son el de ejemplo de mkxp con casi
# todo comentado: llevan comentarios // y /* */, y el de Reborn ademas comas
# finales. ConvertFrom-Json no admite ninguna de las dos cosas.
#
# Se recorre caracter a caracter en vez de con expresiones regulares porque las
# dos trampas estan dentro de las cadenas: "http://..." lleva un // que no es un
# comentario, y un texto puede acabar en ", }". Un analizador que sepa cuando
# esta dentro de una cadena no se equivoca en ninguno de los dos casos.
function Limpia-Json5([string]$t) {
    $sb = New-Object System.Text.StringBuilder
    $n = $t.Length; $i = 0; $enCadena = $false; $escape = $false
    while ($i -lt $n) {
        $c = $t[$i]
        if ($enCadena) {
            [void]$sb.Append($c)
            if ($escape) { $escape = $false }
            elseif ($c -eq '\') { $escape = $true }
            elseif ($c -eq '"') { $enCadena = $false }
            $i++; continue
        }
        if ($c -eq '"') { $enCadena = $true; [void]$sb.Append($c); $i++; continue }
        if ($c -eq '/' -and ($i + 1) -lt $n) {
            $d = $t[$i + 1]
            if ($d -eq '/') { while ($i -lt $n -and $t[$i] -ne "`n") { $i++ }; continue }
            if ($d -eq '*') {
                $i += 2
                while (($i + 1) -lt $n -and -not ($t[$i] -eq '*' -and $t[$i + 1] -eq '/')) { $i++ }
                $i += 2; continue
            }
        }
        [void]$sb.Append($c); $i++
    }

    # Segunda pasada, tambien consciente de las cadenas: una coma seguida de } o ]
    # sobra. Aqui ya no hay comentarios que confundan al mirar hacia delante.
    $t2 = $sb.ToString(); $n = $t2.Length; $i = 0
    $out = New-Object System.Text.StringBuilder
    $enCadena = $false; $escape = $false
    while ($i -lt $n) {
        $c = $t2[$i]
        if ($enCadena) {
            [void]$out.Append($c)
            if ($escape) { $escape = $false }
            elseif ($c -eq '\') { $escape = $true }
            elseif ($c -eq '"') { $enCadena = $false }
            $i++; continue
        }
        if ($c -eq '"') { $enCadena = $true; [void]$out.Append($c); $i++; continue }
        if ($c -eq ',') {
            $j = $i + 1
            while ($j -lt $n -and [char]::IsWhiteSpace($t2[$j])) { $j++ }
            if ($j -lt $n -and ($t2[$j] -eq '}' -or $t2[$j] -eq ']')) { $i++; continue }
        }
        [void]$out.Append($c); $i++
    }
    return $out.ToString()
}

function Lee-Json([string]$ruta) {
    if (-not (Test-Path -LiteralPath $ruta)) { return $null }
    $t = Limpia-Json5 (Lee-Texto $ruta)
    if (-not $t.Trim()) { return $null }
    return ($t | ConvertFrom-Json)
}

# ConvertFrom-Json devuelve PSCustomObject y no se puede fundir con un [ordered]:
# no tiene Keys, y el operador de indice no busca propiedades. Esto lo aplana.
function Objeto-A-Tabla($o) {
    $h = [ordered]@{}
    if ($null -eq $o) { return $h }
    if ($o -is [System.Collections.IDictionary]) {
        foreach ($k in $o.Keys) { $h[[string]$k] = $o[$k] }
        return $h
    }
    foreach ($p in $o.PSObject.Properties) { $h[$p.Name] = $p.Value }
    return $h
}

function Valor($o, [string]$nombre) {
    if ($null -eq $o) { return $null }
    $p = $o.PSObject.Properties[$nombre]
    if ($null -eq $p) { return $null }
    return $p.Value
}

function Lista($o, [string]$nombre) {
    $v = Valor $o $nombre
    if ($null -eq $v) { return @() }
    return @($v)
}

# §1: minusculas, sin acentos ni enes, todo lo que no sea [a-z0-9] a guion, los
# guiones se colapsan y se recortan. FormD separa la tilde de la letra, asi que
# "Pokemon Anil" y "Pokemon Anil" con ene dan el mismo slug, que es la gracia.
function Calcula-Slug([string]$titulo) {
    if (-not $titulo) { return "" }
    $d = $titulo.Normalize([System.Text.NormalizationForm]::FormD)
    $sb = New-Object System.Text.StringBuilder
    foreach ($c in $d.ToCharArray()) {
        if ([System.Globalization.CharUnicodeInfo]::GetUnicodeCategory($c) -ne
            [System.Globalization.UnicodeCategory]::NonSpacingMark) { [void]$sb.Append($c) }
    }
    $s = $sb.ToString().ToLowerInvariant()
    $s = [regex]::Replace($s, '[^a-z0-9]', '-')
    $s = [regex]::Replace($s, '-+', '-')
    return $s.Trim('-')
}

# §4: "05" + los 14 primeros hexadecimales de SHA1(slug). El rango 05.. no lo usa
# Nintendo, asi que dos juegos distintos no se pisan entre si ni pisan a nadie.
function Calcula-TitleId([string]$slug) {
    $sha = [System.Security.Cryptography.SHA1]::Create()
    try {
        $h = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($slug))
    } finally { $sha.Dispose() }
    $hex = ($h | ForEach-Object { $_.ToString("x2") }) -join ""
    return ("05" + $hex.Substring(0, 14)).ToUpperInvariant()
}

function Se-Descarta([string]$nombre) {
    foreach ($p in $NoCopiar) { if ($nombre -like $p) { return $true } }
    return $false
}

#=================================================================== deteccion

# Un .ini de RPG Maker XP tiene [Game] con Title=, Library= y Scripts=.
function Lee-Ini([string]$ruta) {
    $secciones = @{}
    $sec = ""
    foreach ($linea in (Lee-Texto $ruta) -split "`r?`n") {
        $l = $linea.Trim()
        if (-not $l -or $l.StartsWith(";") -or $l.StartsWith("#")) { continue }
        if ($l.StartsWith("[") -and $l.EndsWith("]")) {
            $sec = $l.Substring(1, $l.Length - 2)
            if (-not $secciones.ContainsKey($sec)) { $secciones[$sec] = @{} }
            continue
        }
        $ig = $l.IndexOf("=")
        if ($ig -lt 1 -or -not $sec) { continue }
        if (-not $secciones.ContainsKey($sec)) { $secciones[$sec] = @{} }
        $secciones[$sec][$l.Substring(0, $ig).Trim()] = $l.Substring($ig + 1).Trim()
    }
    return $secciones
}

# Cual de los .ini de la carpeta es EL .ini.
#
# No basta con "el unico que tenga [Game]": Iberia y Titan traen un Editor.ini
# que tambien lo tiene y que dice Title=Pokemon Essentials. Con ese, el slug
# saldria "pokemon-essentials" para los dos juegos y se instalarian encima el uno
# del otro. Y Uranium no tiene Game.ini: tiene Uranium.ini, porque mkxp-z y el
# RGSS original buscan <nombre del exe>.ini (config.cpp, execName + ".ini").
#
# Orden: Game.ini, el que se llame como un .exe de la carpeta, y el resto.
function Elige-Ini([string]$juego) {
    $g = Join-Path $juego "Game.ini"
    if (Test-Path -LiteralPath $g) { return "Game.ini" }
    $exes = @(Get-ChildItem -LiteralPath $juego -File -Filter "*.exe" -ErrorAction SilentlyContinue |
              ForEach-Object { [System.IO.Path]::GetFileNameWithoutExtension($_.Name) })
    $inis = @(Get-ChildItem -LiteralPath $juego -File -Filter "*.ini" -ErrorAction SilentlyContinue)
    foreach ($i in $inis) {
        $base = [System.IO.Path]::GetFileNameWithoutExtension($i.Name)
        if ($exes -contains $base) {
            $s = Lee-Ini $i.FullName
            if ($s.ContainsKey("Game")) { return $i.Name }
        }
    }
    foreach ($i in $inis) {
        if ($i.Name -ieq "Editor.ini") { continue }
        $s = Lee-Ini $i.FullName
        if ($s.ContainsKey("Game") -and $s["Game"]["Title"]) { return $i.Name }
    }
    return $null
}

# Cadena ASCII dentro de un binario. Los Game.exe de estos juegos miden entre 11
# y 19 MB: recorrerlos byte a byte desde PowerShell tardaria minutos, asi que se
# decodifican una vez como Latin-1 -que es biyectivo byte a caracter, no como
# UTF-8, que se atraganta y pierde posiciones- y se busca con IndexOf, que es
# codigo de .NET.
function Exe-Contiene([string]$ruta, [string[]]$cadenas) {
    $b = [System.IO.File]::ReadAllBytes($ruta)
    $t = [System.Text.Encoding]::GetEncoding(28591).GetString($b)
    $r = @{}
    foreach ($c in $cadenas) { $r[$c] = ($t.IndexOf($c, [System.StringComparison]::Ordinal) -ge 0) }
    return $r
}

# §6: que interprete traia el juego en el PC. Importa porque este motor lleva
# CRuby 3.1.7 y un juego de Ruby 1.8 puede no arrancar; no es motivo para negarse
# a empaquetarlo, es motivo para avisar antes de que el jugador se lo pregunte.
function Detecta-Familia([string]$juego, [string]$baseExe) {
    if (@(Get-ChildItem -LiteralPath $juego -File -Filter "x64-msvcrt-ruby*.dll" -ErrorAction SilentlyContinue).Count -gt 0) {
        return "ruby31"
    }
    if (@(Get-ChildItem -LiteralPath $juego -File -Filter "msvcrt-ruby*.dll" -ErrorAction SilentlyContinue).Count -gt 0) {
        return "ruby18"
    }
    $exe = $null
    foreach ($n in @(($baseExe + ".exe"), "Game.exe")) {
        if ($n -and (Test-Path -LiteralPath (Join-Path $juego $n))) { $exe = Join-Path $juego $n; break }
    }
    if (-not $exe) {
        $c = @(Get-ChildItem -LiteralPath $juego -File -Filter "*.exe" -ErrorAction SilentlyContinue |
               Sort-Object Length -Descending)
        if ($c.Count -gt 0) { $exe = $c[0].FullName }
    }
    if (-not $exe) { return "desconocido" }

    $tam = (Get-Item -LiteralPath $exe).Length
    $rgssdll = @(Get-ChildItem -LiteralPath $juego -File -Filter "RGSS10*.dll" -ErrorAction SilentlyContinue).Count
    if ($tam -lt 1MB) {
        if ($rgssdll -gt 0) { return "rgss1" }
        return "desconocido"
    }
    $hay = Exe-Contiene $exe @("/lib/ruby/1.8", "mkxp-z.exe")
    if ($hay["/lib/ruby/1.8"]) { return "ruby18" }
    if ($hay["mkxp-z.exe"]) { return "ruby31" }
    return "desconocido"
}

function Aviso-Familia([string]$familia) {
    switch ($familia) {
        "ruby18" { return "AVISO: este juego lleva Ruby 1.8 (su Game.exe es un mkxp-z con el interprete 1.8.7 embebido); el motor de la Switch lleva Ruby 3.1.7. Puede no arrancar. Se empaqueta igual: saberlo cuesta una prueba, suponerlo no cuesta nada y no sirve." }
        "rgss1"  { return "AVISO: este juego es RPG Maker XP original (RGSS10x.dll), o sea Ruby 1.8.1; el motor de la Switch lleva Ruby 3.1.7. Puede no arrancar. Se empaqueta igual." }
        "desconocido" { return "AVISO: no se ha podido averiguar que interprete traia este juego. Se empaqueta igual; si no arranca, manda mkxp-boot.log y errorlog.txt." }
    }
    return $null
}

# Todos los perfiles de la entrega, con el generico aparte.
function Carga-Perfiles() {
    $dir = Join-Path $Entrega "juegos"
    $todos = @()
    if (-not (Test-Path -LiteralPath $dir)) { return $todos }
    foreach ($d in (Get-ChildItem -LiteralPath $dir -Directory | Sort-Object Name)) {
        $p = Join-Path $d.FullName "perfil.json"
        if (-not (Test-Path -LiteralPath $p)) { continue }
        $j = Lee-Json $p
        if ($null -eq $j) { continue }
        $todos += [pscustomobject]@{ Carpeta = $d.FullName; Nombre = $d.Name; Perfil = $j }
    }
    return $todos
}

# Elegir perfil: gana el que empareje por titulo Y por ficheros; luego el que
# empareje por titulo; luego el que empareje solo por ficheros. Empatar por
# ficheros solo sirve para juegos que renombran su Title (Vanguard) o que no lo
# tienen limpio.
function Busca-Perfil([string]$juego, [string]$titulo, $perfiles) {
    $mejor = $null; $mejorPunto = 0
    foreach ($e in $perfiles) {
        if ($e.Nombre -eq "generico") { continue }
        $det = Valor $e.Perfil "detectar"
        if ($null -eq $det) { continue }
        $reTitulo = Valor $det "titulo"
        $ficheros = @(Lista $det "ficheros")

        $porTitulo = $false
        if ($reTitulo -and $titulo) { $porTitulo = ($titulo -match $reTitulo) }

        $porFicheros = $false
        if ($ficheros.Count -gt 0) {
            $porFicheros = $true
            foreach ($f in $ficheros) {
                if (-not (Test-Path -LiteralPath (Join-Path $juego ($f -replace '/', '\')))) { $porFicheros = $false; break }
            }
        }

        $punto = 0
        if ($porTitulo -and $porFicheros) { $punto = 3 }
        elseif ($porTitulo) { $punto = 2 }
        elseif ($porFicheros -and $ficheros.Count -gt 0) { $punto = 1 }
        if ($punto -gt $mejorPunto) { $mejorPunto = $punto; $mejor = $e }
    }
    if ($mejor) { return $mejor }
    foreach ($e in $perfiles) { if ($e.Nombre -eq "generico") { return $e } }
    return $null
}

# Todo lo que se sabe del juego antes de tocar un solo byte. Lo usan por igual el
# empaquetado, -SoloDetectar y la interfaz: que la pantalla y la copia digan lo
# mismo no es un detalle, es la unica manera de que el aviso valga algo.
function Detecta-Juego([string]$juego) {
    $ini = Elige-Ini $juego
    $titulo = ""
    $baseExe = "Game"
    if ($ini) {
        $sec = Lee-Ini (Join-Path $juego $ini)
        if ($sec.ContainsKey("Game") -and $sec["Game"]["Title"]) { $titulo = $sec["Game"]["Title"] }
        $baseExe = [System.IO.Path]::GetFileNameWithoutExtension($ini)
    }
    $perfiles = Carga-Perfiles
    $entrada = Busca-Perfil $juego $titulo $perfiles
    $perfil = $null; $nombrePerfil = "(ninguno)"
    if ($entrada) { $perfil = $entrada.Perfil; $nombrePerfil = $entrada.Nombre }

    $slug = Valor $perfil "slug"
    if (-not $slug) { $slug = Calcula-Slug $titulo }
    if (-not $slug) { $slug = Calcula-Slug (Split-Path -Leaf $juego) }

    $nombre = Valor $perfil "nombre"
    if (-not $nombre) { $nombre = $titulo }
    if (-not $nombre) { $nombre = $slug }

    $autor = Valor $perfil "autor"
    if (-not $autor) { $autor = "Port a Nintendo Switch" }

    $familia = Valor $perfil "motor"
    $familiaVista = Detecta-Familia $juego $baseExe
    if (-not $familia) { $familia = $familiaVista }

    $titleid = Valor $perfil "titleid"
    if (-not $titleid) { $titleid = Calcula-TitleId $slug }

    $rgssad = @(Get-ChildItem -LiteralPath $juego -File -Filter "*.rgssad" -ErrorAction SilentlyContinue)
    $rgss2a = @(Get-ChildItem -LiteralPath $juego -File | Where-Object { $_.Name -match '\.rgss[23]a$' })

    return [pscustomobject]@{
        Carpeta       = $juego
        Ini           = $ini
        Titulo        = $titulo
        Slug          = $slug
        Nombre        = $nombre
        Autor         = $autor
        Perfil        = $perfil
        NombrePerfil  = $nombrePerfil
        CarpetaPerfil = $(if ($entrada) { $entrada.Carpeta } else { $null })
        Familia       = $familia
        FamiliaVista  = $familiaVista
        TitleId       = $titleid
        BaseExe       = $baseExe
        Archivo       = $(if ($rgssad.Count -gt 0) { $rgssad[0].Name } elseif ($rgss2a.Count -gt 0) { $rgss2a[0].Name } else { $null })
    }
}

#================================================================ comprobaciones

# Lo que un juego de RPG Maker XP tiene por fuerza, y ni un fichero mas. Data/ o
# un archivo cifrado, porque Uranium lleva sus datos dentro de Uranium.rgssad y
# no tiene carpeta Data.
function Comprueba-Juego([string]$ruta) {
    if (-not $ruta -or -not (Test-Path -LiteralPath $ruta)) { return "No existe la carpeta." }
    if (-not (Elige-Ini $ruta)) { return "No hay ningun .ini con seccion [Game]: esto no parece la carpeta de un juego de RPG Maker XP." }
    $hayDatos = (Test-Path -LiteralPath (Join-Path $ruta "Data")) -or
                (@(Get-ChildItem -LiteralPath $ruta -File | Where-Object { $_.Name -match '\.rgss(ad|[23]a)$' }).Count -gt 0)
    if (-not $hayDatos) { return "No hay ni carpeta Data\ ni ningun archivo .rgssad: falta lo que el juego carga." }
    if (-not (Test-Path -LiteralPath (Join-Path $ruta "Graphics"))) { return "Falta Graphics\ - no parece la carpeta de un juego." }
    return $null
}

function Comprueba-Entrega() {
    foreach ($f in @("motor\rgss-switch.nro", "mkxp.base.json", "lib", "juegos")) {
        if (-not (Test-Path -LiteralPath (Join-Path $Entrega $f))) {
            return "Falta $f en la entrega ($Entrega) - descomprime la entrega entera y ejecuta el guion desde dentro."
        }
    }
    return $null
}

#================================================================== contenedor
# El contenedor se escribe a mano, byte a byte, y no con el ZipArchive de .NET.
# La razon es concreta: en .NET Framework -el que trae Windows y el que usa
# PowerShell 5.1- CompressionLevel::NoCompression NO almacena. Sigue usando
# deflate (metodo 8) con bloques sin comprimir, de modo que el fichero sale
# incluso cinco bytes mas grande y, sobre todo, COMPRIMIDO a ojos de quien lo
# lea. Se comprobo: las 26 entradas de la prueba salian todas con metodo 8.
#
# Y eso, en la consola, no es un detalle de formato:
#
#   - PhysFS pasa cada lectura del juego por inflate en vez de leer el fichero
#     a un desplazamiento, y reserva la ventana de zlib por cada fichero abierto.
#   - Al buscar hacia atras dentro de una entrada comprimida, PhysFS no puede
#     saltar: rebobina y vuelve a inflar desde el principio. El juego busca hacia
#     atras cada vez que un OGG de musica vuelve a su punto de bucle, y son
#     ficheros de varios megas.
#
# Almacenado (metodo 0), leer del contenedor es leer del fichero a otro
# desplazamiento, y ahi se acaba el coste. Por eso estos 90 renglones de C#:
# escriben cabecera local, indice central y registro final, que es todo lo que
# un zip es. Se compilan al vuelo con Add-Type, que viene con .NET; sigue sin
# hacer falta instalar nada.
#
# Los limites del formato clasico (4 GB y 65.534 entradas) se comprueban y se
# dicen: un zip64 mal hecho seria peor que negarse.
if (-not ('RgssPaquete' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Text;

public class RgssPaquete : IDisposable
{
    private FileStream s;
    private MemoryStream central = new MemoryStream();
    private int entradas;
    private static readonly uint[] tabla = Tabla();

    public long Ficheros;
    public long Bytes;

    public RgssPaquete(string ruta)
    {
        s = new FileStream(ruta, FileMode.Create, FileAccess.Write, FileShare.None, 1 << 20);
    }

    private static uint[] Tabla()
    {
        uint[] t = new uint[256];
        for (uint i = 0; i < 256; i++)
        {
            uint c = i;
            for (int k = 0; k < 8; k++) c = ((c & 1) != 0) ? (0xEDB88320u ^ (c >> 1)) : (c >> 1);
            t[i] = c;
        }
        return t;
    }

    private static void U16(Stream o, int v) { o.WriteByte((byte)v); o.WriteByte((byte)(v >> 8)); }
    private static void U32(Stream o, uint v)
    {
        o.WriteByte((byte)v); o.WriteByte((byte)(v >> 8));
        o.WriteByte((byte)(v >> 16)); o.WriteByte((byte)(v >> 24));
    }
    private static int DosFecha(DateTime d) { return ((d.Year - 1980) << 9) | (d.Month << 5) | d.Day; }
    private static int DosHora(DateTime d) { return (d.Hour << 11) | (d.Minute << 5) | (d.Second / 2); }

    // nombre: separado por '/' y, si es directorio, terminado en '/'
    private void Entrada(string nombre, string local, DateTime fecha, bool dir)
    {
        byte[] nb = Encoding.UTF8.GetBytes(nombre);
        // Bit 11 = el nombre viene en UTF-8. PhysFS lo mira: sin el, interpreta
        // Latin-1 y una tilde en un nombre de fichero se convierte en otra ruta.
        int flags = 0;
        foreach (byte b in nb) if (b > 127) flags = 1 << 11;
        if (fecha.Year < 1980) fecha = new DateTime(1980, 1, 1);

        long donde = s.Position;
        if (donde > 0xFFFFFF00L)
            throw new Exception("el contenedor pasa de 4 GB: empaqueta con carpetas sueltas (-Contenedor carpetas).");
        if (entradas >= 65534)
            throw new Exception("el contenedor pasa de 65.534 entradas: empaqueta con carpetas sueltas (-Contenedor carpetas).");

        U32(s, 0x04034b50); U16(s, 10); U16(s, flags); U16(s, 0);
        U16(s, DosHora(fecha)); U16(s, DosFecha(fecha));
        long hueco = s.Position;          // crc y los dos tamanos, aun sin saber
        U32(s, 0); U32(s, 0); U32(s, 0);
        U16(s, nb.Length); U16(s, 0);
        s.Write(nb, 0, nb.Length);

        uint crc = 0xFFFFFFFF;
        long tam = 0;
        if (!dir)
        {
            byte[] buf = new byte[1 << 20];
            using (FileStream e = new FileStream(local, FileMode.Open, FileAccess.Read, FileShare.Read, buf.Length))
            {
                int n;
                while ((n = e.Read(buf, 0, buf.Length)) > 0)
                {
                    for (int i = 0; i < n; i++) crc = tabla[(crc ^ buf[i]) & 0xFF] ^ (crc >> 8);
                    s.Write(buf, 0, n);
                    tam += n;
                }
            }
        }
        crc ^= 0xFFFFFFFF;

        // El crc se sabe despues de leer el fichero: se vuelve al hueco y se
        // rellena. Una pasada de lectura por fichero, no dos.
        long fin = s.Position;
        s.Position = hueco;
        U32(s, crc); U32(s, (uint)tam); U32(s, (uint)tam);
        s.Position = fin;

        U32(central, 0x02014b50); U16(central, 20); U16(central, 10); U16(central, flags); U16(central, 0);
        U16(central, DosHora(fecha)); U16(central, DosFecha(fecha));
        U32(central, crc); U32(central, (uint)tam); U32(central, (uint)tam);
        U16(central, nb.Length); U16(central, 0); U16(central, 0);
        U16(central, 0); U16(central, 0);
        U32(central, dir ? 0x10u : 0x20u);
        U32(central, (uint)donde);
        central.Write(nb, 0, nb.Length);

        entradas++;
        if (!dir) { Ficheros++; Bytes += tam; }
    }

    public void AnadeDirectorio(string nombre)
    {
        Entrada(nombre.EndsWith("/") ? nombre : nombre + "/", null, DateTime.Now, true);
    }

    public void AnadeFichero(string nombre, string local, DateTime fecha)
    {
        Entrada(nombre, local, fecha, false);
    }

    public void Cierra()
    {
        long inicio = s.Position;
        central.Position = 0;
        central.CopyTo(s);
        long medida = s.Position - inicio;
        U32(s, 0x06054b50); U16(s, 0); U16(s, 0);
        U16(s, entradas); U16(s, entradas);
        U32(s, (uint)medida); U32(s, (uint)inicio); U16(s, 0);
        s.Flush();
    }

    public void Dispose() { if (s != null) { s.Dispose(); s = null; } }
}
'@
}

# Las entradas de directorio se escriben ANTES de su contenido. PhysFS sabe
# deducir los directorios que faltan, pero un zip donde el padre va delante es
# lo que producen zip, 7-Zip y el propio Windows, y es el camino mas trillado.
#
# $prohibidas son rutas relativas en minusculas y con '/' que NO entran en el
# contenedor aunque cuelguen de una carpeta de recursos: Data/Scripts es el caso,
# porque el cargador de Essentials v20 la lee con Dir.foreach y File.open, y Ruby
# no ve dentro de PhysFS.
function Anade-Carpeta($paquete, [string]$raiz, [string]$rel, $prohibidas, [scriptblock]$avisa) {
    $clave = ($rel -replace '\\', '/').ToLowerInvariant()
    if ($prohibidas -contains $clave) { return }
    $abs = Join-Path $raiz $rel
    $paquete.AnadeDirectorio(($rel -replace '\\', '/'))

    foreach ($f in (Get-ChildItem -LiteralPath $abs -File | Sort-Object Name)) {
        if (Se-Descarta $f.Name) { continue }
        $paquete.AnadeFichero((($rel + '\' + $f.Name) -replace '\\', '/'), $f.FullName, $f.LastWriteTime)
        if (($paquete.Ficheros % 2500) -eq 0) {
            $avisa.Invoke(("     {0,6} ficheros, {1,5} MB" -f $paquete.Ficheros, [math]::Round($paquete.Bytes / 1MB)))
        }
    }
    foreach ($d in (Get-ChildItem -LiteralPath $abs -Directory | Sort-Object Name)) {
        Anade-Carpeta $paquete $raiz (Join-Path $rel $d.Name) $prohibidas $avisa
    }
}

function Empaqueta-Contenedor([string]$juego, [string]$destino, $carpetas, $prohibidas, [scriptblock]$avisa) {
    # Se escribe con otro nombre y se renombra al terminar: un zip a medias no
    # puede parecerse a uno acabado, porque el que lo lee es una consola sin
    # teclado a la que no se le puede preguntar.
    $parcial = Join-Path $destino ($NombrePaquete + ".parcial")
    $final = Join-Path $destino $NombrePaquete
    if (Test-Path -LiteralPath $parcial) { Remove-Item -LiteralPath $parcial -Force }

    $paquete = New-Object RgssPaquete($parcial)
    try {
        foreach ($c in $carpetas) {
            if (-not (Test-Path -LiteralPath (Join-Path $juego $c))) { continue }
            $avisa.Invoke("     $c")
            Anade-Carpeta $paquete $juego $c $prohibidas $avisa
        }
        $paquete.Cierra()
    } finally { $paquete.Dispose() }

    $cuenta = [pscustomobject]@{ Ficheros = $paquete.Ficheros; Bytes = $paquete.Bytes }
    Move-Item -LiteralPath $parcial -Destination $final -Force
    $avisa.Invoke(("     {0} ficheros, {1} MB dentro de {2}" -f $cuenta.Ficheros, [math]::Round($cuenta.Bytes / 1MB), $NombrePaquete))
    return $cuenta
}

# Comprobar el zip es volver a abrirlo y leer su indice, no mirar si el fichero
# esta: lo primero demuestra que la consola va a poder leerlo, lo segundo no
# demuestra nada.
function Comprueba-Contenedor([string]$ruta, $cuenta, [scriptblock]$avisa) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null
    $zip = [System.IO.Compression.ZipFile]::OpenRead($ruta)
    try {
        $entradas = $zip.Entries.Count
        $ficheros = @($zip.Entries | Where-Object { -not $_.FullName.EndsWith("/") })
        $bytes = ($ficheros | Measure-Object -Property Length -Sum).Sum
        if ($ficheros.Count -eq 0) { throw "el contenedor no lleva ningun fichero dentro." }
        if ($ficheros.Count -ne $cuenta.Ficheros) { throw ("el contenedor tiene {0} ficheros y se metieron {1}." -f $ficheros.Count, $cuenta.Ficheros) }
        if ($bytes -ne $cuenta.Bytes) { throw ("el contenedor suma {0} bytes y el original {1}." -f $bytes, $cuenta.Bytes) }
        # PhysFS separa con '/'. Una contrabarra en un nombre de entrada la
        # convertiria en parte del nombre del fichero y el juego no lo encontraria.
        foreach ($e in $zip.Entries) {
            if ($e.FullName.Contains('\')) { throw ("nombre de entrada con contrabarra: " + $e.FullName) }
            # Almacenado, no comprimido: en un fichero guardado en claro el tamano
            # comprimido es el mismo. Si alguna entrada saliera con deflate, la
            # consola pagaria una descompresion en cada lectura.
            if ($e.CompressedLength -ne $e.Length) { throw ("entrada comprimida: " + $e.FullName) }
        }
        $avisa.Invoke(("     {0} entradas leidas del indice, {1} MB sin comprimir" -f $entradas, [math]::Round($bytes / 1MB)))
    } finally { $zip.Dispose() }
}

#================================================================== mkxp.json

# §5: cuatro capas, la de abajo pisa a la de arriba. Se escribe SIN comentarios
# -componer y conservar los comentarios de cada capa daria un fichero mentiroso,
# porque la mitad de lo comentado ya no seria lo que vale- pero con una cabecera
# que diga de donde salio cada cosa, para que quien lo abra en la tarjeta sepa
# que no es un fichero a mano y donde esta el original de cada capa.
function Compone-Mkxp($info, [string]$juego, [scriptblock]$avisa) {
    $cfg = [ordered]@{}

    $base = Lee-Json (Join-Path $Entrega "mkxp.base.json")
    foreach ($p in (Objeto-A-Tabla $base).GetEnumerator()) { $cfg[$p.Key] = $p.Value }

    $capa2 = @()
    $suyo = Join-Path $juego "mkxp.json"
    if (Test-Path -LiteralPath $suyo) {
        $j = $null
        try { $j = Lee-Json $suyo }
        catch { $avisa.Invoke("     AVISO: el mkxp.json del juego no se pudo leer ($($_.Exception.Message)); se ignora."); $j = $null }
        if ($j) {
            foreach ($p in (Objeto-A-Tabla $j).GetEnumerator()) {
                if ($ClavesDelJuego -notcontains $p.Key) { continue }
                # midiSoundFont apuntando a un fichero que no esta. Vanguard
                # declara "soundfont.sf2" y no lo trae -ni trae un solo .mid
                # entre sus 5.006 ficheros de audio-, asi que copiar la clave
                # solo consigue que fluidsynth busque en el arranque un fichero
                # que no existe. Se deja fuera y se dice, que no es lo mismo que
                # callarselo.
                if ($p.Key -eq "midiSoundFont" -and $p.Value) {
                    $sf = Join-Path $juego ([string]$p.Value -replace '/', '\')
                    if (-not (Test-Path -LiteralPath $sf)) {
                        $avisa.Invoke("     midiSoundFont: el juego declara '$($p.Value)' y ese fichero no esta en su carpeta; la clave no se copia.")
                        continue
                    }
                }
                $cfg[$p.Key] = $p.Value; $capa2 += $p.Key
            }
        }
    }

    foreach ($p in (Objeto-A-Tabla (Valor $info.Perfil "mkxp")).GetEnumerator()) { $cfg[$p.Key] = $p.Value }

    $preload = @()
    foreach ($s in $ShimsGenericos) { $preload += ("lib/" + $s) }

    # Shim por FAMILIA, antes que los del perfil. Los juegos de la familia
    # ruby18 -Opalo, Iberia, Titan, Z- y el de rgss1 -Uranium- traen scripts
    # escritos para Ruby 1.8: 25-28 lineas de sintaxis que 3.1 ya no acepta y,
    # sobre todo, doce o catorce Win32API.new de nivel superior que revientan el
    # arranque en la seccion 21 de 168 con "uninitialized constant Win32API"
    # (docs/censo-juegos.md). nx-ruby18.rb es lo que los tapa. Va aqui y no en
    # cada perfil porque no es de ningun juego: es de la familia entera.
    if ($info.Familia -eq "ruby18" -or $info.Familia -eq "rgss1") {
        if (Test-Path -LiteralPath (Join-Path $Entrega "lib\nx-ruby18.rb")) {
            $preload += "lib/nx-ruby18.rb"
        } else {
            $avisa.Invoke("     AVISO: este juego es de la familia $($info.Familia) y esta entrega no trae lib\nx-ruby18.rb; se empaqueta sin el, y casi seguro no arranca.")
        }
    }

    foreach ($s in (Lista $info.Perfil "preload")) { $preload += ("lib/" + $s) }

    if ($Diagnostico) {
        $diag = Lee-Json (Join-Path $Entrega "mkxp.diagnostico.json")
        if ($diag) {
            foreach ($p in (Objeto-A-Tabla (Valor $diag "mkxp")).GetEnumerator()) { $cfg[$p.Key] = $p.Value }
            foreach ($s in (Lista $diag "preload")) { $preload += ("lib/" + $s) }
        }
    }

    # El preload.rb del juego va el ULTIMO: los de estos juegos redefinen cosas
    # (Pokemon Z se apodera de Zlib::Inflate) y tienen que encontrarse el
    # interprete ya remendado por nx-compat.rb, no al reves.
    if (Test-Path -LiteralPath (Join-Path $juego "preload.rb")) { $preload += "preload.rb" }
    $cfg["preloadScript"] = $preload

    $rutas = @("lib")
    foreach ($r in (Lista $info.Perfil "rubyLoadpath")) { if ($rutas -notcontains $r) { $rutas += $r } }
    $cfg["rubyLoadpath"] = $rutas

    # windowTitle: el del juego manda, luego el del perfil, y si ninguno lo dice,
    # el Title= de su .ini. Sin esto la ventana se llamaria "mkxp-z", que es lo
    # que sale en el registro y en las capturas y no ayuda a nadie.
    if (-not $cfg["windowTitle"]) {
        if ($info.Titulo) { $cfg["windowTitle"] = $info.Titulo } else { $cfg["windowTitle"] = $info.Nombre }
    }

    $json = $cfg | ConvertTo-Json -Depth 12
    # ConvertTo-Json escapa todo lo que no es ASCII como \uXXXX. Es JSON valido y
    # mkxp-z lo lee bien, pero un windowTitle escrito "Pok\u00e9mon" no se puede
    # corregir a mano en la tarjeta sin un editor que lo entienda. Se desescapa.
    $json = [regex]::Replace($json, '\\u([0-9a-fA-F]{4})', {
        param($m) [char][int]("0x" + $m.Groups[1].Value) })

    $cabecera = @(
        "// mkxp.json generado por Empaquetar.ps1. NO se edita a mano si se va a",
        "// volver a empaquetar: la proxima pasada lo rehace entero.",
        "//",
        "// Se compone en cuatro capas (CONVENCIONES.md §5), la de abajo pisa a la",
        "// de arriba:",
        "//   1. mkxp.base.json de la entrega  (lo que la Switch necesita siempre)",
        ("//   2. mkxp.json del juego, solo estas claves: " + $(if ($capa2.Count) { $capa2 -join ", " } else { "(ninguna)" })),
        ("//   3. juegos/" + $info.NombrePerfil + "/perfil.json  ->  mkxp"),
        "//   4. preloadScript y rubyLoadpath, compuestos aqui",
        "//",
        ("// Juego: " + $info.Nombre + "   slug: " + $info.Slug + "   perfil: " + $info.NombrePerfil),
        ""
    ) -join "`r`n"
    return ($cabecera + $json + "`r`n")
}

#==================================================================== NRO y NSP

function Pon-Cadena([byte[]]$b, [int]$off, [int]$tam, [string]$s) {
    for ($i = 0; $i -lt $tam; $i++) { $b[$off + $i] = 0 }
    $u = [System.Text.Encoding]::UTF8.GetBytes($s)
    if ($u.Length -ge $tam) { throw "el texto '$s' no cabe en $tam bytes del NACP." }
    [Array]::Copy($u, 0, $b, $off, $u.Length)
}

function Pon-U64([byte[]]$b, [int]$off, [uint64]$v) {
    [Array]::Copy([BitConverter]::GetBytes($v), 0, $b, $off, 8)
}

# El NACP: 16 entradas de idioma de 0x300 bytes (0x200 nombre + 0x100 autor), en
# UTF-8. nacptool las escribe desde la linea de ordenes y ahi se pierden los
# acentos -el shell pasa los argumentos en la pagina ANSI y Horizon espera
# UTF-8-, asi que se reescriben aqui con los bytes correctos. Es el mismo trabajo
# que hacia nsp/nacp-utf8.py, traido a PowerShell para que el jugador no necesite
# Python instalado.
#
# Se rellenan TODAS las entradas que ya tuvieran algo (una entrada a cero
# significa "este idioma no esta soportado", no "sin nombre") y, ademas, las tres
# que la consola va a mirar seguro: AmericanEnglish (0, el de reserva de Horizon
# cuando no encuentra el del idioma configurado), LatinAmericanSpanish (5) y
# Spanish (6).
function Reescribe-Nacp([byte[]]$nacp, [string]$nombre, [string]$autor, [string]$titleid, [string]$version) {
    for ($i = 0; $i -lt 16; $i++) {
        $o = $i * 0x300
        if ($nacp[$o] -eq 0 -and $i -ne 0 -and $i -ne 5 -and $i -ne 6) { continue }
        Pon-Cadena $nacp $o 0x200 $nombre
        Pon-Cadena $nacp ($o + 0x200) 0x100 $autor
    }
    if ($version) { Pon-Cadena $nacp 0x3060 0x10 $version }
    if ($titleid) {
        # Los cuatro sitios donde nacptool escribe el title id, deducidos
        # restando dos NACP generados con y sin --titleid: presence group
        # (0x3038), add-on content base = id + 0x1000 (0x3070), save data owner
        # (0x3078) y local communication (0x30B0). Si no cuadran, la consola se
        # hace un lio con la carpeta de la partida guardada.
        $tid = [System.Convert]::ToUInt64($titleid, 16)
        Pon-U64 $nacp 0x3038 $tid
        Pon-U64 $nacp 0x3070 ($tid + 0x1000)
        Pon-U64 $nacp 0x3078 $tid
        Pon-U64 $nacp 0x30B0 $tid
    }
}

# Rehace la seccion ASET del final del .nro. El cuerpo del NRO no se toca: lo que
# cambia es el icono y el NACP, o sea lo que se ve en el menu HOME y en hbmenu.
#
#   0x10  "NRO0"      0x18  tamano del NRO (u32)
#   Si el fichero es mas largo que ese tamano, en ese desplazamiento empieza:
#   "ASET" (4) + version (u32) + tres pares offset/size (u64) para icono, NACP y
#   romfs, con los offsets relativos al inicio del ASET. La cabecera mide 0x38.
function Rehace-Nro([string]$origen, [string]$destino, [string]$icono,
                    [string]$nombre, [string]$autor, [string]$titleid, [string]$version) {
    $b = [System.IO.File]::ReadAllBytes($origen)
    if ([System.Text.Encoding]::ASCII.GetString($b, 0x10, 4) -ne "NRO0") {
        throw "motor\rgss-switch.nro no es un NRO (falta la marca NRO0)."
    }
    $tam = [BitConverter]::ToUInt32($b, 0x18)
    if ($tam -le 0 -or $tam -gt $b.Length) { throw "el tamano declarado en el NRO ($tam) no cuadra con el fichero ($($b.Length))." }

    # El NACP de partida es el del motor: trae ya las clasificaciones por edad,
    # los indicadores de captura de pantalla y el resto de campos que hbmenu y
    # Horizon miran y que aqui no hay por que inventar. Solo se le cambian el
    # nombre, el autor, la version y el title id.
    $nacp = New-Object byte[] 0x4000

    # Y el ROMFS del motor se copia TAL CUAL, sin mirarlo.
    #
    # Es un romfs vacio de 1.728 bytes que pone elf2nro, y esta ahi a proposito:
    # Ryujinx pide el romfs del .nro al arrancar y, si el ASET declara tamano
    # cero, se muere (commit 6128ea3). Un ASET rehecho sin esa seccion produce un
    # .nro del tamano correcto, con el icono correcto y el nombre correcto, que
    # no arranca -y el fallo aparece lejos de aqui, en el emulador, sin una linea
    # que lo explique-. Asi que lo que traiga el motor sale igual por el otro
    # lado; esto no es sitio para tener una opinion sobre el romfs.
    $romfs = New-Object byte[] 0
    if ($b.Length -gt $tam -and [System.Text.Encoding]::ASCII.GetString($b, $tam, 4) -eq "ASET") {
        $no = [BitConverter]::ToUInt64($b, $tam + 0x18)
        $ns = [BitConverter]::ToUInt64($b, $tam + 0x20)
        if ($ns -eq 0x4000 -and ($tam + $no + $ns) -le $b.Length) {
            [Array]::Copy($b, $tam + $no, $nacp, 0, 0x4000)
        }
        $ro = [BitConverter]::ToUInt64($b, $tam + 0x28)
        $rs = [BitConverter]::ToUInt64($b, $tam + 0x30)
        if ($rs -gt 0 -and ($tam + $ro + $rs) -le $b.Length) {
            $romfs = New-Object byte[] $rs
            [Array]::Copy($b, $tam + $ro, $romfs, 0, $rs)
        }
    }
    Reescribe-Nacp $nacp $nombre $autor $titleid $version

    $ico = [System.IO.File]::ReadAllBytes($icono)
    if ($ico.Length -lt 4 -or $ico[0] -ne 0xFF -or $ico[1] -ne 0xD8) {
        throw "el icono $icono no es un JPEG (tiene que ser JPEG 256x256 baseline)."
    }

    $cab = New-Object byte[] 0x38
    [Array]::Copy([System.Text.Encoding]::ASCII.GetBytes("ASET"), 0, $cab, 0, 4)
    Pon-U64 $cab 0x08 ([uint64]0x38)
    Pon-U64 $cab 0x10 ([uint64]$ico.Length)
    Pon-U64 $cab 0x18 ([uint64](0x38 + $ico.Length))
    Pon-U64 $cab 0x20 ([uint64]$nacp.Length)
    if ($romfs.Length -gt 0) {
        Pon-U64 $cab 0x28 ([uint64](0x38 + $ico.Length + $nacp.Length))
        Pon-U64 $cab 0x30 ([uint64]$romfs.Length)
    } else {
        Pon-U64 $cab 0x28 ([uint64]0)
        Pon-U64 $cab 0x30 ([uint64]0)
    }

    $parcial = $destino + ".parcial"
    $fs = New-Object System.IO.FileStream($parcial, [System.IO.FileMode]::Create)
    try {
        $fs.Write($b, 0, $tam)
        $fs.Write($cab, 0, $cab.Length)
        $fs.Write($ico, 0, $ico.Length)
        $fs.Write($nacp, 0, $nacp.Length)
        if ($romfs.Length -gt 0) { $fs.Write($romfs, 0, $romfs.Length) }
    } finally { $fs.Dispose() }
    Move-Item -LiteralPath $parcial -Destination $destino -Force
}

# Sin acentos: nacptool recibe los argumentos en la pagina ANSI del shell y los
# rompe. El nombre bueno se pone despues, reescribiendo el NACP en UTF-8.
function Sin-Acentos([string]$s) {
    $d = $s.Normalize([System.Text.NormalizationForm]::FormD)
    $sb = New-Object System.Text.StringBuilder
    foreach ($c in $d.ToCharArray()) {
        if ([System.Globalization.CharUnicodeInfo]::GetUnicodeCategory($c) -eq
            [System.Globalization.UnicodeCategory]::NonSpacingMark) { continue }
        if ([int]$c -lt 32 -or [int]$c -gt 126) { [void]$sb.Append(' ') } else { [void]$sb.Append($c) }
    }
    return ($sb.ToString() -replace '\s+', ' ').Trim()
}

function Busca-Claves([string]$dadas) {
    if ($dadas) {
        if (Test-Path -LiteralPath $dadas) { return $dadas }
        throw "no existe el fichero de claves $dadas"
    }
    foreach ($c in @((Join-Path $env:USERPROFILE ".switch\prod.keys"),
                     (Join-Path $env:APPDATA "Ryujinx\system\prod.keys"))) {
        if (Test-Path -LiteralPath $c) { return $c }
    }
    return $null
}

# Ejecutar una herramienta de la entrega y quedarse con TODO lo que dice, sin
# que se le escape una linea a la consola. Hay dos razones, y la segunda es la
# que manda:
#
#   1. En PowerShell 5.1, redirigir con 2>&1 la salida de error de un programa
#      nativo convierte cada linea en un ErrorRecord, y con
#      $ErrorActionPreference = "Stop" eso ABORTA el guion aunque el programa
#      haya terminado bien. npdmtool avisa de once campos que su plantilla no
#      trae y hacbrewpack avisa de las claves que no reconoce: los dos "fallan"
#      sin fallar.
#   2. hacbrewpack, al avisar de una clave que no reconoce, LA IMPRIME. Son las
#      claves de la consola de quien empaqueta. Con 2>&1 esa linea ya se ha
#      visto en pantalla antes de que nadie pueda filtrarla; redirigiendo a un
#      fichero se filtra ANTES de enseñar nada. Se filtra y ademas se borra el
#      fichero.
function Ejecuta-Herramienta([string]$exe, [string[]]$argumentos, [string]$tmp, [string]$etiqueta, [scriptblock]$avisa) {
    $fo = Join-Path $tmp ($etiqueta + ".out")
    $fe = Join-Path $tmp ($etiqueta + ".err")
    $comillas = @($argumentos | ForEach-Object { '"' + $_ + '"' })
    $p = Start-Process -FilePath $exe -ArgumentList $comillas -NoNewWindow -Wait -PassThru `
                       -RedirectStandardOutput $fo -RedirectStandardError $fe
    $lineas = @()
    foreach ($f in @($fo, $fe)) {
        if (Test-Path -LiteralPath $f) {
            $lineas += @(Get-Content -LiteralPath $f -ErrorAction SilentlyContinue)
            Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
        }
    }
    foreach ($l in $lineas) {
        $t = ([string]$l).Trim()
        if (-not $t) { continue }
        if ($t -match "Failed to match key") { continue }   # lleva la clave dentro
        if ($t -match "field not present") { continue }     # los once campos de npdmtool
        # hacbrewpack narra cada bloque que escribe: doscientas lineas para decir
        # tres cosas. Se queda con los encabezados de "---->" y con cualquier
        # linea que hable de un fallo, que es lo unico que hay que leer.
        if ($t -match "^(Writing|Calculating|Encrypting|Getting|Renaming|Visiting|===>|--->) ") { continue }
        $avisa.Invoke("       " + $t)
    }
    return $p.ExitCode
}

# El NSP: el juego instalado como aplicacion en vez de lanzado desde el menu
# homebrew. No es comodidad. Un .nro abierto desde el icono del album corre como
# APPLET, y un applet tiene un presupuesto de memoria muy inferior al de una
# aplicacion: cientos de megas de recursos con CRuby dentro no caben ahi.
#
# Los datos NO van dentro del NSP: se quedan en la SD, en /switch/<slug>/. El
# romfs de un NCA es de solo lectura -ahi dentro no se podria guardar la
# partida-, reinstalar cientos de megas en cada cambio es inviable, y actualizar
# el juego se convierte en copiar ficheros. Lo unico que va en el romfs es
# juego.txt con la ruta, porque una aplicacion no tiene argv[0] y sin eso el
# motor no sabria a que carpeta ir (§3).
function Crea-Nsp($info, [string]$salida, [string]$icono, [string]$version, [string]$claves, [scriptblock]$avisa) {
    $tools = Join-Path $Entrega "tools"
    $npdmtool = Join-Path $tools "npdmtool.exe"
    $nacptool = Join-Path $tools "nacptool.exe"
    $hbp = Join-Path $tools "hacbrewpack.exe"
    $main = Join-Path $Entrega "motor\main"
    $npdmBase = Join-Path $Entrega "motor\npdm.json"
    foreach ($f in @($npdmtool, $nacptool, $hbp, $main, $npdmBase)) {
        if (-not (Test-Path -LiteralPath $f)) {
            $avisa.Invoke("     (esta entrega no trae $(Split-Path -Leaf $f): sin NSP, el juego se lanza desde el menu homebrew)")
            return $null
        }
    }

    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("rgss-nsp-" + $info.Slug)
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force }
    foreach ($d in @("exefs", "control", "romfs", "nsp", "nca", "temp")) {
        New-Item -ItemType Directory -Force -Path (Join-Path $tmp $d) | Out-Null
    }

    Copy-Item -LiteralPath $main -Destination (Join-Path $tmp "exefs\main") -Force

    # El NPDM lleva el title id tres veces (el del proceso y los dos extremos del
    # rango) y el nombre interno del programa, que no es el que se ve: es el que
    # aparece en los volcados y en los registros del sistema. El campo del ACI0
    # son 16 bytes terminados en cero, asi que 15 caracteres como mucho.
    $npdm = Lee-Json $npdmBase
    $nombreNpdm = ($info.Slug -replace '[^A-Za-z0-9]', '')
    if ($nombreNpdm.Length -gt 15) { $nombreNpdm = $nombreNpdm.Substring(0, 15) }
    $npdm.name = $nombreNpdm
    $npdm.title_id = "0x" + $info.TitleId
    $npdm.title_id_range_min = "0x" + $info.TitleId
    $npdm.title_id_range_max = "0x" + $info.TitleId
    $rutaNpdm = Join-Path $tmp "npdm.json"
    Escribe-Utf8 $rutaNpdm ($npdm | ConvertTo-Json -Depth 12)
    $c = Ejecuta-Herramienta $npdmtool @($rutaNpdm, (Join-Path $tmp "exefs\main.npdm")) $tmp "npdm" $avisa
    if ($c -ne 0) { throw "npdmtool fallo (codigo $c)" }

    $nacpRuta = Join-Path $tmp "control\control.nacp"
    $c = Ejecuta-Herramienta $nacptool @("--create", (Sin-Acentos $info.Nombre), (Sin-Acentos $info.Autor), $version, $nacpRuta, ("--titleid=" + $info.TitleId)) $tmp "nacp" $avisa
    if ($c -ne 0) { throw "nacptool fallo (codigo $c)" }
    $nacp = [System.IO.File]::ReadAllBytes($nacpRuta)
    Reescribe-Nacp $nacp $info.Nombre $info.Autor $info.TitleId $version
    [System.IO.File]::WriteAllBytes($nacpRuta, $nacp)

    # El icono se elige por idioma de la consola; AmericanEnglish es el que
    # Horizon usa de reserva cuando no encuentra el del idioma configurado.
    foreach ($idioma in @("AmericanEnglish", "Spanish", "LatinAmericanSpanish")) {
        Copy-Item -LiteralPath $icono -Destination (Join-Path $tmp "control\icon_$idioma.dat") -Force
    }

    # §3: una linea, sin BOM y con salto al final. Es lo unico que el NSP sabe
    # del juego, y por eso no hay ninguna ruta escrita en el codigo del motor.
    Escribe-Utf8 (Join-Path $tmp "romfs\juego.txt") ("sdmc:/switch/" + $info.Slug + "`n")

    $avisa.Invoke("     hacbrewpack (firmando el NCA con tus prod.keys)")
    $codigo = Ejecuta-Herramienta $hbp @(
        "-k", $claves,
        "--exefsdir", (Join-Path $tmp "exefs"),
        "--controldir", (Join-Path $tmp "control"),
        "--romfsdir", (Join-Path $tmp "romfs"),
        "--nspdir", (Join-Path $tmp "nsp"),
        "--ncadir", (Join-Path $tmp "nca"),
        "--tempdir", (Join-Path $tmp "temp"),
        "--nologo") $tmp "hbp" $avisa
    if ($codigo -ne 0) { throw "hacbrewpack fallo (codigo $codigo)" }

    $hecho = @(Get-ChildItem -LiteralPath (Join-Path $tmp "nsp") -Filter "*.nsp")
    if ($hecho.Count -eq 0) { throw "hacbrewpack no dejo ningun .nsp" }
    $final = Join-Path $salida ($info.Slug + ".nsp")
    Copy-Item -LiteralPath $hecho[0].FullName -Destination $final -Force
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    return $final
}

#================================================================= empaquetado

function Copia-Arbol([string]$origen, [string]$destino, [scriptblock]$avisa) {
    $xf = @()
    foreach ($p in $NoCopiar) { $xf += $p }
    robocopy $origen $destino /E /NJH /NJS /NFL /NDL /NP /R:2 /W:1 /XF $xf | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "robocopy fallo copiando $origen (codigo $LASTEXITCODE)" }
}

function Empaqueta($info, [string]$salida, [string]$modo, [scriptblock]$avisa) {
    $juego = $info.Carpeta
    $destino = Join-Path $salida ("switch\" + $info.Slug)
    New-Item -ItemType Directory -Force -Path $destino | Out-Null
    $paquete = Join-Path $destino $NombrePaquete

    $sueltos = @(Lista $info.Perfil "sueltos")
    $excluir = @($ExcluirPorOmision)
    foreach ($e in (Lista $info.Perfil "excluir")) { if ($excluir -notcontains $e) { $excluir += $e } }

    # Data/Scripts va suelta SIEMPRE que exista, tenga perfil o no: es el
    # cargador de Essentials v20+, que hace Dir.foreach y File.open sobre ella, y
    # Ruby no ve dentro de PhysFS. Es exactamente el fallo que se paga en la
    # consola sin que nada diga por que.
    if ((Test-Path -LiteralPath (Join-Path $juego "Data\Scripts")) -and ($sueltos -notcontains "Data/Scripts")) {
        $sueltos += "Data/Scripts"
    }
    $prohibidas = @($sueltos | ForEach-Object { ($_ -replace '\\', '/').ToLowerInvariant() })
    foreach ($e in $excluir) { $prohibidas += ($e -replace '\\', '/').ToLowerInvariant() }

    #--- 1. recursos ---------------------------------------------------------
    $cuenta = $null
    $recursosPresentes = @($CarpetasRecursos | Where-Object { Test-Path -LiteralPath (Join-Path $juego $_) })
    if ($modo -eq "zip") {
        $avisa.Invoke("1/5 Recursos del juego -> $NombrePaquete (esto es lo que tarda)")
        $cuenta = Empaqueta-Contenedor $juego $destino $recursosPresentes $prohibidas $avisa
    } else {
        $avisa.Invoke("1/5 Recursos del juego, sueltos (esto es lo que tarda)")
        foreach ($d in $recursosPresentes) {
            $avisa.Invoke("     $d")
            Copia-Arbol (Join-Path $juego $d) (Join-Path $destino $d) $avisa
        }
        # Las prohibidas se copian igual porque estan dentro de una carpeta de
        # recursos; solo hay que quitar las excluidas, que no tienen que estar.
        foreach ($e in $excluir) {
            $r = Join-Path $destino ($e -replace '/', '\')
            if (Test-Path -LiteralPath $r) { Remove-Item -LiteralPath $r -Recurse -Force }
        }
    }

    #--- 2. lo suelto --------------------------------------------------------
    $avisa.Invoke("2/5 Ficheros y carpetas sueltos")

    # Como se llama el juego para mkxp-z. config.cpp abre execName + ".ini" y
    # sharedstate.cpp monta execName + gameArchExt(), que con rgssVersion 1 es
    # ".rgssad". Por omision "Game", y un perfil lo puede cambiar. Uranium es el
    # caso: su .ini es Uranium.ini y su archivo Uranium.rgssad. En vez de fiarlo
    # todo a la clave execName, aqui se NORMALIZAN los nombres al copiar -el ini
    # se copia tambien como Game.ini y el archivo como Game.rgssad-, que es una
    # cosa menos que pueda salir mal en una consola sin teclado.
    $execName = "Game"
    $ex = Valor (Valor $info.Perfil "mkxp") "execName"
    if ($ex) { $execName = $ex }
    $archivoDestino = $execName + ".rgssad"
    # De la raiz se copian TODOS los ficheros salvo los binarios de Windows y los
    # restos de escritorio. Antes solo se copiaban cuatro con nombre fijo, y por
    # eso un juego que trajera un quinto -configuration.json, cacert.pem,
    # rebornmap.png, un .dat de partida- llegaba a la consola incompleto.
    $nSueltos = 0
    foreach ($f in (Get-ChildItem -LiteralPath $juego -File | Sort-Object Name)) {
        if (Se-Descarta $f.Name) { continue }
        if ($f.Name -ieq "mkxp.json") { continue }   # se compone, no se copia
        $comoSeLlama = $f.Name
        # El archivo cifrado del juego se copia UNA vez y con el nombre que el
        # motor va a buscar. Copiarlo con los dos nombres serian 34 MB de mas en
        # la tarjeta para nada.
        if ($info.Archivo -and $f.Name -ieq $info.Archivo) { $comoSeLlama = $archivoDestino }
        Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $destino $comoSeLlama) -Force
        if ($comoSeLlama -ne $f.Name) { $avisa.Invoke("     $($f.Name) -> $comoSeLlama (es como lo busca el motor)") }
        $nSueltos++
    }
    $avisa.Invoke("     $nSueltos ficheros de la raiz")

    if ($info.Ini -and $info.Ini -ne ($execName + ".ini")) {
        Copy-Item -LiteralPath (Join-Path $juego $info.Ini) -Destination (Join-Path $destino ($execName + ".ini")) -Force
        $avisa.Invoke("     $($info.Ini) copiado tambien como $execName.ini")
    }

    $desconocidas = @()
    foreach ($d in (Get-ChildItem -LiteralPath $juego -Directory | Sort-Object Name)) {
        $n = $d.Name
        if ($excluir -contains $n) { $avisa.Invoke("     (excluida ${n}: material de desarrollo)"); continue }
        if ($CarpetasRecursos -contains $n) { continue }
        if ($sueltos -notcontains $n) { $desconocidas += $n }
        $avisa.Invoke("     $n\ (suelta)")
        Copia-Arbol $d.FullName (Join-Path $destino $n) $avisa
    }
    # Las sueltas que cuelgan de una carpeta de recursos (Data/Scripts) hay que
    # sacarlas del contenedor Y ponerlas fuera; en modo carpetas ya estan.
    if ($modo -eq "zip") {
        foreach ($s in $sueltos) {
            if ($s -notmatch '[/\\]') { continue }
            $o = Join-Path $juego ($s -replace '/', '\')
            if (-not (Test-Path -LiteralPath $o)) { continue }
            $avisa.Invoke("     $s\ (suelta, fuera del contenedor)")
            Copia-Arbol $o (Join-Path $destino ($s -replace '/', '\')) $avisa
        }
    }
    if ($desconocidas.Count -gt 0) {
        $avisa.Invoke("     (" + ($desconocidas -join ", ") + ": no las conoce ningun perfil, se copian sueltas por si el juego las lee con File.read)")
    }

    #--- 3. la llave del contenedor ------------------------------------------
    #
    # Pokemon Essentials pregunta si un fichero existe de dos maneras distintas,
    # y elige mirando si hay un Game.rgssad al lado:
    #
    #     def pbRgssExists?(filename)
    #       return !pbGetFileChar(filename).nil? if FileTest.exist?("./Game.rgssad")
    #       return FileTest.exist?(canonicalize(filename))
    #     end
    #
    # Sin archivo pregunta al SISTEMA DE FICHEROS, que no sabe nada de lo que hay
    # dentro del contenedor. Con archivo pregunta por load_data, que va por
    # PhysFS y si lo ve. Se comprobo en el emulador: con el contenedor montado y
    # todo lo demas bien, el juego cargaba sus scripts desde dentro del zip y se
    # moria a los veinte segundos porque no encontraba Data/Map###.rxdata.
    #
    # Estos ocho bytes son la cabecera de un RGSSAD version 1 sin ninguna
    # entrada: un archivo vacio, valido, que mkxp-z monta sin quejarse y que le
    # dice al juego "aqui se lee por el camino de los archivos".
    #
    # Uranium NO la lleva: trae un RGSSAD de verdad con sus 254 ficheros de
    # Data/ dentro, ya copiado arriba con el nombre que el motor busca. Poner la
    # llave encima seria sustituir un archivo con datos por uno vacio.
    $llave = Join-Path $destino $archivoDestino
    if ($modo -eq "zip") {
        if ($info.Archivo) {
            $avisa.Invoke("     ${archivoDestino}: el juego trae su propio archivo cifrado, no hace falta llave")
        } else {
            [System.IO.File]::WriteAllBytes($llave,
                [byte[]](0x52, 0x47, 0x53, 0x53, 0x41, 0x44, 0x00, 0x01))
            $avisa.Invoke("     $execName.rgssad (8 bytes): la llave que hace que el juego lea del contenedor")
        }
    }

    #--- 4. el motor ---------------------------------------------------------
    $avisa.Invoke("3/5 Motor (.nro con el icono y el nombre de este juego, mkxp.json, lib/)")
    $version = "1.0.0"
    $vf = Join-Path $Entrega "VERSION.txt"
    if (Test-Path -LiteralPath $vf) { $version = (Lee-Texto $vf).Trim() }

    $icono = Join-Path $Entrega "motor\icono.jpg"
    if ($info.CarpetaPerfil) {
        $propio = Join-Path $info.CarpetaPerfil "icono.jpg"
        if (Test-Path -LiteralPath $propio) { $icono = $propio }
    }
    Rehace-Nro (Join-Path $Entrega "motor\rgss-switch.nro") (Join-Path $destino ($info.Slug + ".nro")) `
               $icono $info.Nombre $info.Autor $info.TitleId $version
    $avisa.Invoke("     $($info.Slug).nro   title id $($info.TitleId)   " + (Split-Path -Leaf $icono))

    Escribe-Utf8 (Join-Path $destino "mkxp.json") (Compone-Mkxp $info $juego $avisa)
    $avisa.Invoke("     mkxp.json compuesto (base + juego + perfil $($info.NombrePerfil))")

    # Los nx-*.rb de la tarjeta se borran antes de copiar: si el perfil de antes
    # traia shims que este no, quedarian cargandose desde un preloadScript que ya
    # no los nombra... o peor, nombrados y viejos.
    $libDestino = Join-Path $destino "lib"
    if (Test-Path -LiteralPath $libDestino) {
        Get-ChildItem -LiteralPath $libDestino -Filter "nx-*.rb" -ErrorAction SilentlyContinue | Remove-Item -Force
    }
    Copia-Arbol (Join-Path $Entrega "lib") $libDestino $avisa
    if ($info.CarpetaPerfil) {
        $libPerfil = Join-Path $info.CarpetaPerfil "lib"
        if (Test-Path -LiteralPath $libPerfil) {
            Copy-Item -Path (Join-Path $libPerfil "*.rb") -Destination $libDestino -Force
            $avisa.Invoke("     lib/ + los shims del perfil (" + ((Get-ChildItem -LiteralPath $libPerfil -Filter *.rb | ForEach-Object { $_.Name }) -join ", ") + ")")
        }
    }

    if ($Diagnostico) {
        $diagDir = Join-Path $Entrega "diagnostico"
        if (Test-Path -LiteralPath $diagDir) {
            Copy-Item -Path (Join-Path $diagDir "*.rb") -Destination $libDestino -Force
            Escribe-Utf8 (Join-Path $destino "diagnostico.txt") "Puesto por Empaquetar.ps1 -Diagnostico. Borralo para que el juego arranque mas rapido.`r`n"
            $avisa.Invoke("     sondas de diagnostico en lib/ y diagnostico.txt puesto")
        } else {
            $avisa.Invoke("     AVISO: -Diagnostico pedido pero la entrega no trae diagnostico\; se sigue sin sondas.")
        }
    }

    #--- 5. comprobacion -----------------------------------------------------
    $avisa.Invoke("4/5 Comprobacion")
    # Una comprobacion que no puede fallar no es una comprobacion: se cuenta lo
    # que tiene que estar y se compara con lo que esta.
    $pedidos = @(($info.Slug + ".nro"), "mkxp.json", "lib\nx-compat.rb", ($execName + ".ini"))
    if ($info.Ini -and $info.Ini -ne ($execName + ".ini")) { $pedidos += $info.Ini }
    if ($modo -eq "zip") {
        $pedidos += $NombrePaquete
        if (-not $info.Archivo) { $pedidos += $archivoDestino }
    } else {
        if (Test-Path -LiteralPath (Join-Path $juego "Data")) { $pedidos += "Data" }
    }
    if ($info.Archivo) { $pedidos += $archivoDestino }
    # El mkxp.json se vuelve a LEER de la tarjeta y se comprueba que todo lo que
    # nombra esta de verdad ahi. Dos cosas a la vez: que lo escrito se puede
    # analizar -si no, el motor arranca con la configuracion por defecto y nadie
    # se entera- y que ningun preloadScript apunta a un fichero que no viajo.
    #
    # No es hipotetico: Copy-Item con -LiteralPath NO expande comodines, asi que
    # "lib/*.rb" del perfil no copiaba nada, el guion anunciaba los tres shims de
    # Anil como copiados y el mkxp.json los cargaba. En la consola eso es un
    # LoadError en el arranque y una pantalla negra.
    $cfgLeido = $null
    try { $cfgLeido = Lee-Json (Join-Path $destino "mkxp.json") } catch { }
    if ($null -eq $cfgLeido) { throw "el mkxp.json que se acaba de escribir no se puede volver a leer." }
    foreach ($s in @(Lista $cfgLeido "preloadScript")) {
        if (-not (Test-Path -LiteralPath (Join-Path $destino ([string]$s -replace '/', '\')))) {
            throw "mkxp.json carga $s y ese fichero no esta en la salida."
        }
    }
    foreach ($s in @(Lista $cfgLeido "rubyLoadpath")) {
        if (-not (Test-Path -LiteralPath (Join-Path $destino ([string]$s -replace '/', '\')))) {
            throw "rubyLoadpath nombra la carpeta $s y no esta en la salida."
        }
    }

    $faltan = @($pedidos | Where-Object { -not (Test-Path -LiteralPath (Join-Path $destino $_)) })
    if ($faltan.Count -gt 0) { throw ("Faltan en la salida: " + ($faltan -join ", ")) }
    if ($modo -eq "zip") { Comprueba-Contenedor $paquete $cuenta $avisa }
    $nroSalida = (Get-Item -LiteralPath (Join-Path $destino ($info.Slug + ".nro"))).Length
    if ($nroSalida -lt 0x1000) { throw "el $($info.Slug).nro de la salida esta vacio o truncado." }
    $avisa.Invoke("     " + ($pedidos.Count) + " piezas comprobadas, ninguna falta")

    # Los dos modos no se estorban, pero el contenedor manda sobre las carpetas
    # sueltas (PhysFS resuelve por orden de montaje y el .nro lo monta primero).
    # Quedarse con los dos es ocupar el doble y jugar con los datos del zip.
    $avisos = @()
    if ($modo -eq "zip") {
        $mezcla = @($CarpetasRecursos | Where-Object { Test-Path -LiteralPath (Join-Path $destino $_) })
        # Data/ puede quedar legitimamente si solo lleva Scripts/ dentro.
        $mezcla = @($mezcla | Where-Object {
            $_ -ne "Data" -or @(Get-ChildItem -LiteralPath (Join-Path $destino "Data") -File -ErrorAction SilentlyContinue).Count -gt 0
        })
        if ($mezcla.Count -gt 0) {
            $avisos += "AVISO: en la salida quedan tambien las carpetas sueltas de un empaquetado anterior (" + ($mezcla -join ", ") + "). El juego leera del $NombrePaquete; borralas para recuperar el sitio."
        }
    }
    if ($modo -eq "carpetas" -and (Test-Path -LiteralPath $paquete)) {
        $avisos += "AVISO: en la salida queda un $NombrePaquete de un empaquetado anterior, y el juego lo monta ANTES que las carpetas: borralo o seguiras jugando con los datos viejos."
    }
    # La llave sin contenedor no abre nada y ademas estorba: con ella presente el
    # juego pregunta por sus ficheros a traves de load_data en vez de al sistema,
    # que es el camino largo. Se retira solo la nuestra, la de ocho bytes; un
    # archivo de verdad del juego no se toca.
    if ($modo -eq "carpetas" -and (Test-Path -LiteralPath $llave) -and (Get-Item -LiteralPath $llave).Length -eq 8) {
        Remove-Item -LiteralPath $llave -Force
        $avisa.Invoke("     (retirada la llave $archivoDestino de un empaquetado con contenedor)")
    }
    foreach ($a in $avisos) { $avisa.Invoke(""); $avisa.Invoke($a) }

    #--- 6. NSP --------------------------------------------------------------
    $avisa.Invoke("5/5 NSP")
    $llaves = Busca-Claves $Claves
    if ($llaves) {
        $avisa.Invoke("     claves: $llaves (se leen donde estan; no se copian a ningun sitio)")
        $nsp = Crea-Nsp $info $salida $icono $version $llaves $avisa
        if ($nsp) { $avisa.Invoke("     $nsp - instalalo con Awoo Installer, DBI o Goldleaf; el juego sigue en SD:/switch/$($info.Slug)/") }
    } else {
        $avisa.Invoke("     Sin prod.keys no se puede firmar un NSP: se entrega solo el .nro y se lanza desde el menu homebrew.")
        $avisa.Invoke("     Las prod.keys salen de TU consola con Lockpick_RCM; dejalas en %USERPROFILE%\.switch\prod.keys o pasa -Claves <ruta>.")
    }

    $tam = [math]::Round(((Get-ChildItem -LiteralPath $destino -Recurse -File | Measure-Object Length -Sum).Sum / 1MB))
    $cuantos = (Get-ChildItem -LiteralPath $destino -Recurse -File).Count
    $comoQuedo = "recursos sueltos: el arranque mas rapido, muchos ficheros que copiar"
    if ($modo -eq "zip") { $comoQuedo = "un solo contenedor: copia rapida, unos segundos mas de arranque" }
    return "Listo: $destino ($tam MB en $cuantos ficheros, $comoQuedo). Copia la carpeta 'switch' a la raiz de la tarjeta SD."
}

#================================================================ solo detectar

function Informe-Deteccion($info, [bool]$conTamano) {
    $l = @()
    $l += "carpeta   : " + $info.Carpeta
    $l += "ini       : " + $(if ($info.Ini) { $info.Ini } else { "(ninguno)" })
    $l += "titulo    : " + $(if ($info.Titulo) { $info.Titulo } else { "(sin Title=)" })
    $l += "slug      : " + $info.Slug
    $estado = Valor $info.Perfil "estado"
    $l += "perfil    : " + $info.NombrePerfil + "  (" + $info.Nombre + ", estado " + $(if ($estado) { $estado } else { "sin-probar" }) + ")"
    $m = "motor     : " + $info.Familia
    if ($info.FamiliaVista -ne $info.Familia) { $m += "  (el perfil lo dice; mirando el juego se diria " + $info.FamiliaVista + ")" }
    $l += $m
    $l += "title id  : " + $info.TitleId
    if ($info.Archivo) { $l += "archivo   : " + $info.Archivo + " (datos cifrados propios del juego)" }

    $sueltos = @(Lista $info.Perfil "sueltos")
    if (Test-Path -LiteralPath (Join-Path $info.Carpeta "Data\Scripts")) { if ($sueltos -notcontains "Data/Scripts") { $sueltos += "Data/Scripts" } }
    $excluir = @($ExcluirPorOmision)
    foreach ($e in (Lista $info.Perfil "excluir")) { if ($excluir -notcontains $e) { $excluir += $e } }

    $recursos = @($CarpetasRecursos | Where-Object { Test-Path -LiteralPath (Join-Path $info.Carpeta $_) })
    $otras = @(Get-ChildItem -LiteralPath $info.Carpeta -Directory | ForEach-Object { $_.Name } |
               Where-Object { $CarpetasRecursos -notcontains $_ -and $excluir -notcontains $_ })
    $fuera = @(Get-ChildItem -LiteralPath $info.Carpeta -Directory | ForEach-Object { $_.Name } |
               Where-Object { $excluir -contains $_ })
    $l += "recursos  : " + $(if ($recursos.Count) { $recursos -join " " } else { "(ninguna)" })
    $l += "sueltas   : " + $(if (($otras + $sueltos).Count) { (($otras + $sueltos) | Select-Object -Unique) -join " " } else { "(ninguna)" })
    $l += "excluidas : " + $(if ($fuera.Count) { $fuera -join " " } else { "(ninguna)" })

    if ($conTamano) {
        $todo = Get-ChildItem -LiteralPath $info.Carpeta -Recurse -File -ErrorAction SilentlyContinue |
                Measure-Object Length -Sum
        $l += ("tamano    : {0} MB en {1} ficheros" -f [math]::Round($todo.Sum / 1MB), $todo.Count)
    }
    $aviso = Aviso-Familia $info.Familia
    if ($aviso) { $l += ""; $l += $aviso }
    return ($l -join [Environment]::NewLine)
}

#================================================================= sin interfaz

if ($SoloDetectar) {
    $e = Comprueba-Entrega; if ($e) { Write-Error $e; exit 1 }
    $e = Comprueba-Juego $Juego; if ($e) { Write-Error $e; exit 1 }
    $info = Detecta-Juego $Juego
    Write-Host (Informe-Deteccion $info $true)
    exit 0
}

if ($SinInterfaz -or ($Juego -and $Salida)) {
    $e = Comprueba-Entrega; if ($e) { Write-Error $e; exit 1 }
    $e = Comprueba-Juego $Juego; if ($e) { Write-Error $e; exit 1 }
    if (-not $Salida) { Write-Error "Falta -Salida."; exit 1 }
    $info = Detecta-Juego $Juego
    Write-Host (Informe-Deteccion $info $false)
    Write-Host ""
    $r = Empaqueta $info $Salida $Contenedor { param($m) Write-Host $m }
    Write-Host ""
    Write-Host $r
    exit 0
}

#===================================================================== interfaz
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$f = New-Object System.Windows.Forms.Form
$f.Text = "rgss-switch - empaquetador de juegos de RPG Maker XP para Nintendo Switch"
$f.Size = New-Object System.Drawing.Size(660, 520)
$f.StartPosition = "CenterScreen"
$f.FormBorderStyle = "FixedDialog"
$f.MaximizeBox = $false

function Etiqueta($texto, $y) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $texto; $l.Location = New-Object System.Drawing.Point(16, $y); $l.AutoSize = $true
    $f.Controls.Add($l); return $l
}
function Caja($y, $valor) {
    $t = New-Object System.Windows.Forms.TextBox
    $t.Location = New-Object System.Drawing.Point(16, $y); $t.Size = New-Object System.Drawing.Size(510, 24); $t.Text = $valor
    $f.Controls.Add($t); return $t
}
function Boton($texto, $x, $y, $ancho) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $texto; $b.Location = New-Object System.Drawing.Point($x, $y); $b.Size = New-Object System.Drawing.Size($ancho, 26)
    $f.Controls.Add($b); return $b
}

Etiqueta "1. Carpeta de TU copia del juego para PC (la que tiene Game.exe, Data, Graphics...)" 16 | Out-Null
$cajaJuego = Caja 40 $Juego
$bJuego = Boton "Buscar..." 534 39 96

Etiqueta "2. Donde dejar el resultado (una carpeta vacia, o directamente la raiz de la tarjeta SD)" 80 | Out-Null
$cajaSalida = Caja 104 $Salida
$bSalida = Boton "Buscar..." 534 103 96
$bSalida.Add_Click({
    $d = New-Object System.Windows.Forms.FolderBrowserDialog
    $d.Description = "Carpeta de salida (o la tarjeta SD)"
    if ($d.ShowDialog() -eq "OK") { $cajaSalida.Text = $d.SelectedPath }
})

# La casilla decide entre un fichero grande y decenas de miles pequenos. Marcada
# por omision porque copiar a una SD lo agradece muchisimo y porque un solo
# fichero se puede enviar y comprobar; se desmarca para parchear el juego a mano.
#
# Debajo va el trato explicado, porque las dos opciones son razonables y quien
# elige tiene derecho a saber que pierde: una casilla sin explicacion es una
# trampa para el que la desmarca por curiosidad.
$casillaZip = New-Object System.Windows.Forms.CheckBox
$casillaZip.Location = New-Object System.Drawing.Point(16, 132)
$casillaZip.Size = New-Object System.Drawing.Size(614, 22)
$casillaZip.Checked = ($Contenedor -eq "zip")
$casillaZip.Text = "3. Juntar los recursos en un solo fichero ($NombrePaquete)"
$f.Controls.Add($casillaZip)

$explica = New-Object System.Windows.Forms.Label
$explica.Location = New-Object System.Drawing.Point(36, 155)
$explica.Size = New-Object System.Drawing.Size(600, 46)
$explica.ForeColor = [System.Drawing.Color]::FromArgb(90, 90, 90)
$explica.Text = ("MARCADA: un solo fichero. Copiar a la tarjeta pasa de decenas de minutos a unos pocos, y se envia" + [Environment]::NewLine +
                 "y comprueba de una pieza. A cambio el juego tarda unos segundos mas en arrancar, siempre." + [Environment]::NewLine +
                 "SIN MARCAR: los recursos sueltos. Arranca lo mas rapido posible, permite cambiar graficos a mano, y es lo unico posible por encima de 4 GB.")
$f.Controls.Add($explica)

$estado = New-Object System.Windows.Forms.TextBox
$estado.Location = New-Object System.Drawing.Point(16, 208); $estado.Size = New-Object System.Drawing.Size(614, 208)
$estado.Multiline = $true; $estado.ReadOnly = $true; $estado.ScrollBars = "Vertical"
$estado.Font = New-Object System.Drawing.Font("Consolas", 9)
$f.Controls.Add($estado)

$e = Comprueba-Entrega
if ($e) { $estado.Text = "AVISO: $e" } else { $estado.Text = "Entrega encontrada. Elige la carpeta del juego y te digo que juego es, que perfil le toca y con que interprete venia." }

# Al elegir la carpeta se detecta y se ENSENA antes de copiar nada. Es donde
# aparece el aviso de Ruby 1.8: mas vale saberlo antes de esperar veinte minutos
# de copia que despues, mirando una pantalla negra en la consola.
function Detecta-Y-Ensena([string]$ruta) {
    $estado.Clear()
    $err = Comprueba-Juego $ruta
    if ($err) { $estado.AppendText("ERROR: $err" + [Environment]::NewLine); return }
    try {
        $info = Detecta-Juego $ruta
        $estado.AppendText((Informe-Deteccion $info $false) + [Environment]::NewLine)
    } catch {
        $estado.AppendText("ERROR al detectar: " + $_.Exception.Message + [Environment]::NewLine)
    }
}

$bJuego.Add_Click({
    $d = New-Object System.Windows.Forms.FolderBrowserDialog
    $d.Description = "Carpeta del juego para PC"
    if ($d.ShowDialog() -eq "OK") { $cajaJuego.Text = $d.SelectedPath; Detecta-Y-Ensena $d.SelectedPath }
})
$cajaJuego.Add_Leave({ if ($cajaJuego.Text) { Detecta-Y-Ensena $cajaJuego.Text } })

$bIr = Boton "Empaquetar" 16 428 150
$bIr.Font = New-Object System.Drawing.Font($bIr.Font, [System.Drawing.FontStyle]::Bold)
$bIr.Add_Click({
    $estado.Clear()
    $avisa = { param($m) $estado.AppendText($m + [Environment]::NewLine); [System.Windows.Forms.Application]::DoEvents() }
    $err = Comprueba-Entrega; if ($err) { $avisa.Invoke("ERROR: $err"); return }
    $err = Comprueba-Juego $cajaJuego.Text; if ($err) { $avisa.Invoke("ERROR: $err"); return }
    if (-not $cajaSalida.Text) { $avisa.Invoke("ERROR: elige la carpeta de salida."); return }
    $bIr.Enabled = $false
    $modo = "carpetas"; if ($casillaZip.Checked) { $modo = "zip" }
    try {
        $info = Detecta-Juego $cajaJuego.Text
        $avisa.Invoke((Informe-Deteccion $info $false))
        $avisa.Invoke("")
        $r = Empaqueta $info $cajaSalida.Text $modo $avisa
        $avisa.Invoke(""); $avisa.Invoke($r)
        [System.Windows.Forms.MessageBox]::Show($r, "Hecho", "OK", "Information") | Out-Null
    } catch {
        $avisa.Invoke("ERROR: " + $_.Exception.Message)
    } finally { $bIr.Enabled = $true }
})

$bGuia = Boton "Abrir la guia" 492 428 138
$bGuia.Add_Click({ $g = Join-Path $Entrega "GUIA.md"; if (Test-Path -LiteralPath $g) { Start-Process notepad.exe $g } })

[void]$f.ShowDialog()
