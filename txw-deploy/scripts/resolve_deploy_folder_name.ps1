# resolve_deploy_folder_name.ps1
#
# Determina el nombre de la carpeta de deploy para el día/ambiente actuales,
# añadiendo un contador si ya existe una carpeta con el nombre base.
#
# Chequea tanto el directorio local de deploys como la carpeta de Drive,
# porque puede que un deploy anterior del mismo día ya esté en Drive pero no
# localmente, o al revés.
#
# Estrategia eficiente: lista una sola vez cada ubicación filtrando por el patrón
# YYYYMMDD-ENV*, extrae los contadores existentes, y calcula el próximo disponible.
#
# Uso:
#   pwsh -File resolve_deploy_folder_name.ps1 `
#        -DeploysRoot "C:\...\deploy builds\TruextendWebsite" `
#        -DriveFolder "G:\...\Deploys" `
#        -Environment "QA" `
#        -Date "20260420"
#
# Salida (JSON a stdout):
#   {
#     "folder_name": "20260420-QA",           # o "20260420-QA-2", "20260420-QA-3", etc.
#     "counter": 1,                             # 1 = sin sufijo; 2+ = con sufijo -N
#     "zip_name": "PublishTXWebsite_20260420.zip"  # con contador si aplica, con _PROD si aplica
#   }
#
# Códigos de salida:
#   0: éxito
#   1: error

param(
    [Parameter(Mandatory=$true)] [string]$DeploysRoot,
    [Parameter(Mandatory=$true)] [string]$DriveFolder,
    [Parameter(Mandatory=$true)] [ValidateSet("QA","PROD")] [string]$Environment,
    [Parameter(Mandatory=$true)] [string]$Date
)

$ErrorActionPreference = "Stop"

function Get-UsedCounters {
    param(
        [string]$Folder,
        [string]$BaseName  # ej: "20260420-QA"
    )

    # Si el directorio no existe, no hay contadores usados.
    if (-not (Test-Path $Folder -PathType Container)) {
        return @()
    }

    # Regex: el nombre base exacto, o el nombre base seguido de "-N".
    # Grupo 1 captura el número (vacío si es el nombre base sin sufijo).
    $pattern = "^$([regex]::Escape($BaseName))(?:-(\d+))?$"

    $counters = @()
    foreach ($entry in Get-ChildItem -Path $Folder -Directory -ErrorAction SilentlyContinue) {
        if ($entry.Name -match $pattern) {
            if ($matches[1]) {
                # Nombre con sufijo "-N"
                $counters += [int]$matches[1]
            } else {
                # Nombre base sin sufijo = contador 1
                $counters += 1
            }
        }
    }
    return $counters
}

try {
    $baseName = "$Date-$Environment"

    # Reunir contadores usados en ambas ubicaciones (una sola pasada por cada una)
    $usedCounters = @()
    $usedCounters += Get-UsedCounters -Folder $DeploysRoot -BaseName $baseName
    $usedCounters += Get-UsedCounters -Folder $DriveFolder -BaseName $baseName

    # Calcular el siguiente contador disponible
    if ($usedCounters.Count -eq 0) {
        $counter = 1
    } else {
        $counter = ($usedCounters | Measure-Object -Maximum).Maximum + 1
    }

    # Construir el nombre de la carpeta
    if ($counter -eq 1) {
        $folderName = $baseName
    } else {
        $folderName = "$baseName-$counter"
    }

    # Construir el nombre del zip (sufijo PROD primero si aplica, contador al final)
    $zipBase = "PublishTXWebsite_$Date"
    if ($Environment -eq "PROD") {
        $zipBase = "${zipBase}_PROD"
    }
    if ($counter -gt 1) {
        $zipBase = "${zipBase}_$counter"
    }
    $zipName = "$zipBase.zip"

    $result = [ordered]@{
        folder_name = $folderName
        counter     = $counter
        zip_name    = $zipName
    } | ConvertTo-Json

    Write-Output $result
    exit 0
}
catch {
    $err = @{
        error      = $_.Exception.Message
        error_type = $_.Exception.GetType().Name
    } | ConvertTo-Json
    Write-Error $err
    exit 1
}
