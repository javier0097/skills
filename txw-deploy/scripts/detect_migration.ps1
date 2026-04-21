# detect_migration.ps1
#
# Detecta si hay que generar un nuevo script.sql comparando:
#   1. La última migración ya desplegada en el ambiente (del último script.sql en Drive).
#   2. La última migración disponible localmente en la carpeta de Migrations.
#
# Uso:
#   pwsh -File detect_migration.ps1 `
#        -LastScriptPath "G:\...\20260410-QA\script.sql" `
#        -MigrationsFolder "C:\...\Truextend.Core\Migrations"
#
# Salida (JSON a stdout):
#   {
#       "needs_script": true/false,
#       "last_deployed_migration": "20260325155427_RemoveRequiredFromLevelAssessed",
#       "latest_local_migration": "20260418120000_AddSomethingNew",
#       "from_migration": "20260325155427_RemoveRequiredFromLevelAssessed" or null
#   }
#
# Códigos de salida:
#   0: éxito (needs_script puede ser true o false)
#   1: error

param(
    [Parameter(Mandatory=$true)] [string]$LastScriptPath,
    [Parameter(Mandatory=$true)] [string]$MigrationsFolder
)

$ErrorActionPreference = "Stop"

function Find-LastDeployedMigration {
    param([string]$ScriptPath)

    if (-not (Test-Path $ScriptPath -PathType Leaf)) {
        throw [System.IO.FileNotFoundException]::new("No se encontró el script SQL: $ScriptPath")
    }

    # Leer solo las últimas 200 líneas (el último VALUES siempre está al final)
    $lines = Get-Content $ScriptPath -Tail 200

    # Buscar todos los VALUES (N'<nombre>', N'<version>')
    $pattern = "VALUES\s*\(\s*N'([^']+)'\s*,\s*N'[^']+'\s*\)"
    $lastMatch = $null

    foreach ($line in $lines) {
        $matches = [regex]::Matches($line, $pattern)
        foreach ($m in $matches) {
            $lastMatch = $m.Groups[1].Value
        }
    }

    if (-not $lastMatch) {
        throw "No se encontró ningún INSERT a __EFMigrationsHistory en $ScriptPath"
    }

    return $lastMatch
}

function Find-LatestLocalMigration {
    param([string]$Folder)

    if (-not (Test-Path $Folder -PathType Container)) {
        throw [System.IO.FileNotFoundException]::new("No se encontró la carpeta de Migrations: $Folder")
    }

    # Patrón: YYYYMMDDHHMMSS_Name.cs (sin puntos en medio → filtra Designer.cs)
    $migrationPattern = "^(\d{14}_[^.]+)\.cs$"

    # Listar archivos y ordenar descendentemente por nombre.
    # Los nombres empiezan con timestamp, por lo que el orden alfabético desc coincide con cronológico.
    $files = Get-ChildItem -Path $Folder -File |
        Where-Object { $_.Name -notlike "*.Designer.cs" -and $_.Name -notlike "*ModelSnapshot*" } |
        Sort-Object -Property Name -Descending

    foreach ($file in $files) {
        if ($file.Name -match $migrationPattern) {
            return $matches[1]
        }
    }

    throw "No se encontró ninguna migración en $Folder"
}

try {
    $lastDeployed = Find-LastDeployedMigration -ScriptPath $LastScriptPath
    $latestLocal  = Find-LatestLocalMigration -Folder $MigrationsFolder

    $needsScript = $lastDeployed -ne $latestLocal

    $result = [ordered]@{
        needs_script            = $needsScript
        last_deployed_migration = $lastDeployed
        latest_local_migration  = $latestLocal
        from_migration          = if ($needsScript) { $lastDeployed } else { $null }
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
