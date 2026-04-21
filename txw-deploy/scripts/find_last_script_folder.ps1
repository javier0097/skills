# find_last_script_folder.ps1
#
# Encuentra la carpeta de deploy más reciente de un ambiente específico (QA o PROD)
# que contenga un archivo script.sql.
#
# Estrategia: ordena las carpetas descendentemente (las más recientes primero) y se
# detiene en la primera que cumpla con el patrón de nombre YYYYMMDD-<ENV>[-N] y contenga
# un archivo script.sql. Esto evita recorrer toda la lista.
#
# Uso:
#   pwsh -File find_last_script_folder.ps1 `
#        -DriveFolder "G:\...\Deploys" `
#        -Environment "QA"
#
# Salida (JSON a stdout):
#   Si encuentra:
#     { "found": true, "folder_name": "20260408-QA", "folder_path": "...", "script_path": "..." }
#   Si no encuentra:
#     { "found": false }
#
# Códigos de salida:
#   0: éxito (found puede ser true o false)
#   1: error

param(
    [Parameter(Mandatory=$true)] [string]$DriveFolder,
    [Parameter(Mandatory=$true)] [ValidateSet("QA","PROD")] [string]$Environment
)

$ErrorActionPreference = "Stop"

try {
    if (-not (Test-Path $DriveFolder -PathType Container)) {
        $err = @{
            error = "No se encontró la carpeta de Drive: $DriveFolder"
            error_type = "FileNotFoundError"
        } | ConvertTo-Json
        Write-Error $err
        exit 1
    }

    # Patrón: 8 dígitos (fecha), guion, el ambiente, opcionalmente -N (contador)
    $folderPattern = "^(\d{8})-$Environment(?:-(\d+))?$"

    # Listar carpetas que matchean el patrón, extrayendo fecha y contador para ordenar.
    # Nota: ordenar solo por nombre alfabético NO sirve porque "YYYYMMDD-QA-10" < "YYYYMMDD-QA-2"
    # alfabéticamente. Hay que ordenar por fecha desc y luego por contador numérico desc.
    $folders = Get-ChildItem -Path $DriveFolder -Directory |
        Where-Object { $_.Name -match $folderPattern } |
        ForEach-Object {
            $null = $_.Name -match $folderPattern
            $date = $matches[1]
            $counter = if ($matches[2]) { [int]$matches[2] } else { 1 }
            [PSCustomObject]@{
                Name     = $_.Name
                FullName = $_.FullName
                Date     = $date
                Counter  = $counter
            }
        } |
        Sort-Object -Property @{Expression="Date"; Descending=$true},
                              @{Expression="Counter"; Descending=$true}

    foreach ($folder in $folders) {
        $scriptPath = Join-Path $folder.FullName "script.sql"
        if (Test-Path $scriptPath -PathType Leaf) {
            $result = @{
                found = $true
                folder_name = $folder.Name
                folder_path = $folder.FullName
                script_path = $scriptPath
            } | ConvertTo-Json
            Write-Output $result
            exit 0
        }
    }

    # Ninguna carpeta coincidente tiene script.sql
    $result = @{ found = $false } | ConvertTo-Json
    Write-Output $result
    exit 0
}
catch {
    $err = @{
        error = $_.Exception.Message
        error_type = $_.Exception.GetType().Name
    } | ConvertTo-Json
    Write-Error $err
    exit 1
}
