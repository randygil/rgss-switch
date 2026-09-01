# Empaquetar.ps1 — monta la carpeta que va a la tarjeta SD, con interfaz.
#
# Junta dos cosas que vienen de sitios distintos y que este repositorio no puede
# ni debe mezclar:
#
#   1. TU copia de Pokemon Anil 4.0 para PC (Data/, Graphics/, Audio/, Fonts/...)
#   2. La entrega del port (pokemon-anil.nro, mkxp.json, lib/), que es lo que
#      hay en la misma carpeta que este guion.
#
# y deja en la carpeta de salida un directorio switch/pokemon-anil/ listo para
# copiar a la raiz de la SD. Si en la entrega hay un pokemon-anil.nsp, lo deja
# al lado para instalarlo (Awoo Installer, DBI o Goldleaf).
#
# No necesita nada instalado: PowerShell viene con Windows. Se puede usar sin
# interfaz:   powershell -File Empaquetar.ps1 -Juego "C:\...\Pokemon Anil" -Salida D:\sd
param(
    [string]$Juego = "",
    [string]$Salida = "",
    [switch]$SinInterfaz
)

$ErrorActionPreference = "Stop"
$Entrega = Split-Path -Parent $MyInvocation.MyCommand.Path

function Comprueba-Juego([string]$ruta) {
    if (-not $ruta -or -not (Test-Path $ruta)) { return "No existe la carpeta." }
    foreach ($imprescindible in @("Data\Scripts.rxdata", "Graphics", "Audio")) {
        if (-not (Test-Path (Join-Path $ruta $imprescindible))) { return "Falta $imprescindible - no parece la carpeta de Pokemon Anil." }
    }
    return $null
}

function Comprueba-Entrega() {
    foreach ($f in @("pokemon-anil.nro", "mkxp.json", "lib")) {
        if (-not (Test-Path (Join-Path $Entrega $f))) { return "Falta $f junto a este guion - descomprime la entrega entera." }
    }
    return $null
}

function Empaqueta([string]$juego, [string]$salida, [scriptblock]$avisa) {
    $destino = Join-Path $salida "switch\pokemon-anil"
    New-Item -ItemType Directory -Force -Path $destino | Out-Null

    $avisa.Invoke("1/4 Recursos del juego (esto es lo que tarda: ~700 MB)")
    foreach ($d in @("Data", "Graphics", "Audio", "Fonts")) {
        $o = Join-Path $juego $d
        if (Test-Path $o) {
            $avisa.Invoke("     $d")
            robocopy $o (Join-Path $destino $d) /E /NJH /NJS /NFL /NDL /NP /R:2 /W:1 | Out-Null
            if ($LASTEXITCODE -ge 8) { throw "robocopy fallo copiando $d (codigo $LASTEXITCODE)" }
        }
    }
    foreach ($f in @("Game.ini", "preload.rb", "knownpoint.bmp", "selpoint.bmp")) {
        $o = Join-Path $juego $f
        if (Test-Path $o) { Copy-Item $o (Join-Path $destino $f) -Force }
    }
    # Restos de escritorio que no pintan nada en una consola.
    Get-ChildItem $destino -Recurse -File -Include *.exe, *.dll, Thumbs.db | Remove-Item -Force -ErrorAction SilentlyContinue

    $avisa.Invoke("2/4 Motor del port (.nro, mkxp.json, lib/)")
    Copy-Item (Join-Path $Entrega "pokemon-anil.nro") (Join-Path $destino "pokemon-anil.nro") -Force
    Copy-Item (Join-Path $Entrega "mkxp.json") (Join-Path $destino "mkxp.json") -Force
    Get-ChildItem (Join-Path $destino "lib") -Filter "nx-*.rb" -ErrorAction SilentlyContinue | Remove-Item -Force
    robocopy (Join-Path $Entrega "lib") (Join-Path $destino "lib") /E /NJH /NJS /NFL /NDL /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "robocopy fallo copiando lib/ (codigo $LASTEXITCODE)" }

    $avisa.Invoke("3/4 Comprobacion")
    # Una comprobacion que no puede fallar no es una comprobacion: se cuenta lo
    # que tiene que estar y se compara con lo que esta.
    $pedidos = @("pokemon-anil.nro", "mkxp.json", "Game.ini", "preload.rb", "Data\Scripts.rxdata", "lib\nx-compat.rb", "lib\nx-rutas.rb", "lib\socket.rb")
    $faltan = @($pedidos | Where-Object { -not (Test-Path (Join-Path $destino $_)) })
    if ($faltan.Count -gt 0) { throw ("Faltan en la salida: " + ($faltan -join ", ")) }
    $nroLocal = (Get-Item (Join-Path $Entrega "pokemon-anil.nro")).Length
    $nroSalida = (Get-Item (Join-Path $destino "pokemon-anil.nro")).Length
    if ($nroLocal -ne $nroSalida) { throw "El .nro copiado no tiene el mismo tamano que el original." }

    $avisa.Invoke("4/4 NSP")
    $nsp = Join-Path $Entrega "pokemon-anil.nsp"
    if (Test-Path $nsp) {
        Copy-Item $nsp (Join-Path $salida "pokemon-anil.nsp") -Force
        $avisa.Invoke("     pokemon-anil.nsp copiado a la salida. Instalalo con Awoo/DBI/Goldleaf; el juego sigue en SD:/switch/pokemon-anil/")
    } else {
        $avisa.Invoke("     (esta entrega no trae .nsp; el juego se lanza desde el menu homebrew)")
    }

    $tam = [math]::Round(((Get-ChildItem $destino -Recurse -File | Measure-Object Length -Sum).Sum / 1MB))
    return "Listo: $destino ($tam MB). Copia la carpeta 'switch' a la raiz de la tarjeta SD."
}

# ---------------------------------------------------------------- sin interfaz
if ($SinInterfaz -or ($Juego -and $Salida)) {
    $e = Comprueba-Entrega; if ($e) { Write-Error $e; exit 1 }
    $e = Comprueba-Juego $Juego; if ($e) { Write-Error $e; exit 1 }
    $r = Empaqueta $Juego $Salida { param($m) Write-Host $m }
    Write-Host $r
    exit 0
}

# ---------------------------------------------------------------- interfaz
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$f = New-Object System.Windows.Forms.Form
$f.Text = "Pokemon Anil para Nintendo Switch - empaquetador"
$f.Size = New-Object System.Drawing.Size(640, 400)
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
    $t.Location = New-Object System.Drawing.Point(16, $y); $t.Size = New-Object System.Drawing.Size(500, 24); $t.Text = $valor
    $f.Controls.Add($t); return $t
}
function Boton($texto, $x, $y, $ancho) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $texto; $b.Location = New-Object System.Drawing.Point($x, $y); $b.Size = New-Object System.Drawing.Size($ancho, 26)
    $f.Controls.Add($b); return $b
}

Etiqueta "1. Carpeta de TU copia de Pokemon Anil 4.0 para PC (la que tiene Game.exe, Data, Graphics...)" 16 | Out-Null
$cajaJuego = Caja 40 $Juego
$bJuego = Boton "Buscar..." 524 39 90
$bJuego.Add_Click({
    $d = New-Object System.Windows.Forms.FolderBrowserDialog
    $d.Description = "Carpeta de Pokemon Anil 4.0"
    if ($d.ShowDialog() -eq "OK") { $cajaJuego.Text = $d.SelectedPath }
})

Etiqueta "2. Donde dejar el resultado (una carpeta vacia, o directamente la raiz de la tarjeta SD)" 80 | Out-Null
$cajaSalida = Caja 104 $Salida
$bSalida = Boton "Buscar..." 524 103 90
$bSalida.Add_Click({
    $d = New-Object System.Windows.Forms.FolderBrowserDialog
    $d.Description = "Carpeta de salida (o la tarjeta SD)"
    if ($d.ShowDialog() -eq "OK") { $cajaSalida.Text = $d.SelectedPath }
})

$estado = New-Object System.Windows.Forms.TextBox
$estado.Location = New-Object System.Drawing.Point(16, 150); $estado.Size = New-Object System.Drawing.Size(598, 160)
$estado.Multiline = $true; $estado.ReadOnly = $true; $estado.ScrollBars = "Vertical"
$estado.Font = New-Object System.Drawing.Font("Consolas", 9)
$f.Controls.Add($estado)
$e = Comprueba-Entrega
if ($e) { $estado.Text = "AVISO: $e" } else { $estado.Text = "Entrega encontrada junto a este guion. Elige las dos carpetas y pulsa Empaquetar." }

$bIr = Boton "Empaquetar" 16 322 140
$bIr.Font = New-Object System.Drawing.Font($bIr.Font, [System.Drawing.FontStyle]::Bold)
$bIr.Add_Click({
    $estado.Clear()
    $avisa = { param($m) $estado.AppendText($m + [Environment]::NewLine); [System.Windows.Forms.Application]::DoEvents() }
    $err = Comprueba-Entrega; if ($err) { $avisa.Invoke("ERROR: $err"); return }
    $err = Comprueba-Juego $cajaJuego.Text; if ($err) { $avisa.Invoke("ERROR: $err"); return }
    if (-not $cajaSalida.Text) { $avisa.Invoke("ERROR: elige la carpeta de salida."); return }
    $bIr.Enabled = $false
    try {
        $r = Empaqueta $cajaJuego.Text $cajaSalida.Text $avisa
        $avisa.Invoke(""); $avisa.Invoke($r)
        [System.Windows.Forms.MessageBox]::Show($r, "Hecho", "OK", "Information") | Out-Null
    } catch {
        $avisa.Invoke("ERROR: " + $_.Exception.Message)
    } finally { $bIr.Enabled = $true }
})

$bGuia = Boton "Abrir la guia" 476 322 138
$bGuia.Add_Click({ $g = Join-Path $Entrega "GUIA.md"; if (Test-Path $g) { Start-Process notepad.exe $g } })

[void]$f.ShowDialog()
