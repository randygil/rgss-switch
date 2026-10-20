# Conduce el juego en el emulador SIN quitarle el foco a nadie.
#
# jugar.ps1 manda teclas con keybd_event, que van a la ventana activa: para
# que lleguen, el emulador tiene que ponerse delante en cada pulsacion, y
# quien este usando la maquina no puede hacer nada mientras dura la prueba.
# Aqui no se manda ninguna tecla. La sonda runtime/diagnostico/nx-guion.rb lee
# el guion desde dentro del juego, contesta ella a Input y saca las fotos con
# Graphics.snap_to_bitmap; el emulador arranca minimizado y se queda asi.
#
#   .\guion.ps1 -Juego pokemon-iberia -Guion C:\ruta\mi-guion.txt
#
# El juego tiene que estar ya en la tarjeta de Ryujinx (Empaquetar.ps1). Las
# ordenes del guion estan en la cabecera de nx-guion.rb; "Z hasta" y "hasta"
# esperan a que el jugador tenga el control, asi que no hace falta contar
# fotogramas para pasar titulo, avisos y escenas.
#
# Deja:
#   docs/capturas/<slug>-guion-<nombre>.png   una por cada "foto nombre"
#   y las lineas [guion] en mkxp-ruby.log, con el mapa y la casilla de cada orden
#
# Al terminar quita nx-guion.txt de la tarjeta: con el, el juego se conduciria
# solo la proxima vez que alguien lo abriera.
param(
    [Parameter(Mandatory=$true)][string]$Juego,
    [Parameter(Mandatory=$true)][string]$Guion,
    [int]$Tope = 360,
    # Ventana visible pero SIN activarla (SW_SHOWNOACTIVATE): el foco sigue
    # donde estaba. Para lo que no se puede probar minimizado: Ryujinx 1.3.3
    # se cae (0xc0000005 en Ryujinx.exe) con Pokemon Titan minimizado.
    [switch]$Visible
)
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing
Add-Type -Name Ventana -Namespace NxGuion -MemberDefinition @"
[DllImport("user32.dll")] public static extern bool ShowWindow(System.IntPtr h, int cmd);
"@

$dir = "$env:APPDATA\Ryujinx\sdcard\switch\$Juego"
$nro = "$dir\$Juego.nro"
if (-not (Test-Path $nro)) { throw "no esta ${nro}: empaquetalo antes con Empaquetar.ps1" }
if (-not (Test-Path $Guion)) { throw "no esta el guion $Guion" }

# 1. La sonda en lib/ y en preloadScript, despues de los shims del juego.
Copy-Item "$PSScriptRoot\runtime\diagnostico\nx-guion.rb" "$dir\lib\nx-guion.rb" -Force
$json = Get-Content "$dir\mkxp.json" -Raw -Encoding UTF8
if ($json -notmatch '"lib/nx-guion\.rb"') {
    $m = [regex]::Match($json, '"preloadScript"\s*:\s*\[(?<lista>[^\]]*)\]')
    if (-not $m.Success) { throw "mkxp.json sin preloadScript" }
    $lista = $m.Groups["lista"].Value.TrimEnd()
    $nueva = if ($lista.Trim()) { "$lista,`n                          `"lib/nx-guion.rb`"`n                      " } else { "`"lib/nx-guion.rb`"" }
    $json = $json.Substring(0, $m.Groups["lista"].Index) + $nueva + $json.Substring($m.Groups["lista"].Index + $m.Groups["lista"].Length)
    [IO.File]::WriteAllText("$dir\mkxp.json", $json, (New-Object Text.UTF8Encoding($false)))
}
Copy-Item $Guion "$dir\nx-guion.txt" -Force
Get-ChildItem "$dir\nx-guion-*.png" -ErrorAction SilentlyContinue | Remove-Item

# 2. Minimizado, y se espera a la linea "[guion] fin" que se escriba a partir
# de ahora (el registro puede traer la de una vuelta anterior).
$log = "$dir\mkxp-ruby.log"
$dbg = "$dir\mkxp-debug.log"
$desde = if (Test-Path $log) { (Get-Item $log).Length } else { 0 }
$desdeDbg = if (Test-Path $dbg) { (Get-Item $dbg).Length } else { 0 }
function Nuevo($f, $desde) {
    if (-not (Test-Path $f)) { return "" }
    # Compartido: el emulador lo tiene abierto para escribir mientras corre.
    $s = New-Object IO.FileStream($f, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
        if ($s.Length -lt $desde) { $desde = 0 }   # el motor lo empezo de nuevo
        $s.Position = $desde
        $b = New-Object byte[] ($s.Length - $desde)
        [void]$s.Read($b, 0, $b.Length)
    } finally { $s.Dispose() }
    return [Text.Encoding]::UTF8.GetString($b)
}
$p = Start-Process -FilePath "C:\Games\publish\Ryujinx.exe" -ArgumentList "`"$nro`"" -WindowStyle Minimized -PassThru
if ($Visible) {
    for ($i = 0; $i -lt 60 -and $p.MainWindowHandle -eq [IntPtr]::Zero; $i++) { Start-Sleep -Milliseconds 500; $p.Refresh() }
    [void][NxGuion.Ventana]::ShowWindow($p.MainWindowHandle, 4)   # SW_SHOWNOACTIVATE
    Write-Output "Ryujinx PID $($p.Id), visible sin foco"
} else {
    Write-Output "Ryujinx PID $($p.Id), minimizado"
}
$t0 = Get-Date
$motivo = "tope de $Tope s"
try {
    while (((Get-Date) - $t0).TotalSeconds -lt $Tope) {
        Start-Sleep -Seconds 3
        if ($p.HasExited) { $motivo = "el emulador termino"; break }
        if ((Nuevo $log $desde) -match "\[guion\] fin") { $motivo = "guion terminado"; break }
        if ((Nuevo $dbg $desdeDbg) -match "Shutting down") { $motivo = "el juego se cerro antes de acabar el guion"; break }
    }
    Start-Sleep -Seconds 2
} finally {
    if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force }
    Remove-Item "$dir\nx-guion.txt" -ErrorAction SilentlyContinue
}
Write-Output ("{0} a los {1:N0} s" -f $motivo, ((Get-Date) - $t0).TotalSeconds)

# 3. Las fotos llegan en tiras de 171 columnas (ver nx-guion.rb): se cosen.
$capturas = Join-Path $PSScriptRoot "docs\capturas"
New-Item -ItemType Directory -Force -Path $capturas | Out-Null
Get-ChildItem "$dir\nx-guion-*.t*.png" -ErrorAction SilentlyContinue |
    Group-Object { $_.Name -replace '^nx-guion-(.+)\.t\d+\.png$', '$1' } | ForEach-Object {
        $tiras = $_.Group | Sort-Object { [int]($_.Name -replace '^.*\.t(\d+)\.png$', '$1') }
        $imgs = @($tiras | ForEach-Object { [Drawing.Image]::FromFile($_.FullName) })
        $destino = Join-Path $capturas "$Juego-guion-$($_.Name).png"
        try {
            [int]$ancho = 0
            foreach ($i in $imgs) { $ancho += $i.Width }
            $foto = New-Object Drawing.Bitmap -ArgumentList $ancho, ([int]$imgs[0].Height)
            $g = [Drawing.Graphics]::FromImage($foto)
            [int]$x = 0
            foreach ($i in $imgs) { $g.DrawImage($i, $x, 0, $i.Width, $i.Height); $x += $i.Width }
            $g.Dispose()
            $foto.Save($destino, [Drawing.Imaging.ImageFormat]::Png)
            $foto.Dispose()
        } finally {
            $imgs | ForEach-Object { $_.Dispose() }
        }
        $tiras | Remove-Item
        Write-Output "  foto -> $destino"
    }

# 4. Lo que dijo la sonda en esta vuelta.
(Nuevo $log $desde) -split "`n" | Where-Object { $_ -match "\[guion\] (=>|control|TOPE|orden desconocida|fin|foto .*:)|\[excepcion\]" } |
    ForEach-Object { Write-Output "  $($_.TrimEnd())" }
$errores = (Nuevo $dbg $desdeDbg) -split "`n" | Where-Object { $_ -match "Error|from Section" } | Select-Object -First 8
if ($errores) { Write-Output "mkxp-debug.log:"; $errores | ForEach-Object { Write-Output "  $($_.TrimEnd())" } }
