# check_deploy_readiness.ps1
# Valida que el repo esté en condiciones de hacer deploy:
#   1. Working directory limpio (ignora archivos en whitelist).
#   2. Rama objetivo existe localmente (si no, la crea desde origin).
#   3. Checkout de la rama objetivo.
#   4. Fetch de la rama objetivo y de las fuentes esperadas.
#   5. Sincronización local con origin/<target> usando fast-forward only.
#      - Si está al día: no-op.
#      - Si está atrasado y limpio: avanza con fast-forward.
#      - Si está adelantado o divergente: aborta con error.
#   6. Checks de propagación: por cada rama fuente esperada compara el
#      contenido de los árboles (git diff) contra la rama objetivo. La
#      comparación es bidireccional (inmune a squash merges porque mira
#      el estado final de los archivos, no la historia de commits) y
#      después clasifica cada archivo en dos buckets según en qué rama
#      está la versión más reciente:
#        - source más nuevo  -> falta propagar (alerta)
#        - target más nuevo  -> normal en gitflow (no alerta)
#      Solo el primer bucket dispara la confirmación al usuario.
#
# El script ejecuta el checkout y el pull --ff-only por sí mismo. Los checks
# de propagación son informativos: NO abortan el script (queda a criterio de
# Claude mostrarlos y pedir confirmación al usuario).
#
# NOTA sobre squash merges: la comparación de propagación NO usa conteo de
# commits por SHA. Cuando un merge a la rama objetivo se hace con squash, los
# commits originales de la fuente conservan SHAs distintos y un conteo por SHA
# los reportaría como "faltantes" aunque su contenido ya esté propagado. Por
# eso se compara directamente el contenido de los árboles con git diff y
# luego se clasifica por timestamp del último commit por archivo en cada rama.
#
# Parámetros:
#   -ConfigPath   Ruta absoluta al config.json de la skill. El script lee de
#                 ahí target, expected_sources y git_status_whitelist según
#                 el environment, evitando pasar arrays como argumentos
#                 (que no se bindean bien con pwsh -File).
#   -Environment  "QA" o "PROD". Se usa para resolver branches[<Environment>]
#                 en el config.
#
# Salida: JSON con la estructura documentada en SKILL.md.
# Exit code:
#   0  - ok=true. Repo en condiciones de deployar. Puede haber propagación
#        pendiente (Claude decide qué hacer con eso).
#   1  - ok=false. Algún problema bloqueante: working dir dirty, rama divergente,
#        commits locales sin pushear, o error de git/config.

param(
    [Parameter(Mandatory = $true)]
    [string]$ConfigPath,

    [Parameter(Mandatory = $true)]
    [ValidateSet("QA", "PROD")]
    [string]$Environment
)

$ErrorActionPreference = "Stop"

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------

function Emit-Result {
    param(
        [bool]$Ok,
        [hashtable]$WorkingDirectory,
        [hashtable]$LocalSync,
        [array]$Propagation,
        [string]$ErrorMessage = $null
    )

    $result = @{
        ok                = $Ok
        working_directory = $WorkingDirectory
        local_sync        = $LocalSync
        propagation       = $Propagation
    }
    if ($ErrorMessage) {
        $result.error = $ErrorMessage
    }

    # Depth 6 alcanza de sobra para la estructura más anidada
    # (propagation[].changed_files[]).
    $json = $result | ConvertTo-Json -Depth 6 -Compress:$false
    Write-Output $json
    exit ($(if ($Ok) { 0 } else { 1 }))
}

function Invoke-Git {
    # Ejecuta git capturando stdout y stderr juntos pero SIN usar 2>&1 en pipeline,
    # para evitar el NativeCommandError en Windows PowerShell 5.1.
    # Usa Start-Process redirigiendo a archivos temporales.
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $stdoutFile = [System.IO.Path]::GetTempFileName()
    $stderrFile = [System.IO.Path]::GetTempFileName()

    try {
        $proc = Start-Process -FilePath "git" `
            -ArgumentList $Arguments `
            -NoNewWindow `
            -Wait `
            -PassThru `
            -RedirectStandardOutput $stdoutFile `
            -RedirectStandardError $stderrFile

        $stdout = Get-Content $stdoutFile -Raw -ErrorAction SilentlyContinue
        $stderr = Get-Content $stderrFile -Raw -ErrorAction SilentlyContinue

        return [PSCustomObject]@{
            ExitCode = $proc.ExitCode
            Stdout   = if ($null -eq $stdout) { "" } else { $stdout }
            Stderr   = if ($null -eq $stderr) { "" } else { $stderr }
        }
    }
    finally {
        Remove-Item $stdoutFile -ErrorAction SilentlyContinue
        Remove-Item $stderrFile -ErrorAction SilentlyContinue
    }
}

# ----------------------------------------------------------------------------
# Paso 0: Leer config y resolver target / expected_sources / whitelist
# ----------------------------------------------------------------------------

if (-not (Test-Path $ConfigPath)) {
    Emit-Result -Ok $false `
        -WorkingDirectory @{ status = "error"; files = @() } `
        -LocalSync @{ status = "not_checked"; ahead_count = 0; behind_count = 0 } `
        -Propagation @() `
        -ErrorMessage "No se encontró el config.json en '$ConfigPath'."
}

try {
    $config = Get-Content $ConfigPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
}
catch {
    Emit-Result -Ok $false `
        -WorkingDirectory @{ status = "error"; files = @() } `
        -LocalSync @{ status = "not_checked"; ahead_count = 0; behind_count = 0 } `
        -Propagation @() `
        -ErrorMessage "No se pudo parsear config.json: $($_.Exception.Message)"
}

$branchConfig = $config.branches.$Environment
if (-not $branchConfig) {
    Emit-Result -Ok $false `
        -WorkingDirectory @{ status = "error"; files = @() } `
        -LocalSync @{ status = "not_checked"; ahead_count = 0; behind_count = 0 } `
        -Propagation @() `
        -ErrorMessage "config.branches.$Environment no existe en el config.json."
}

$TargetBranch = [string]$branchConfig.target
$ExpectedSources = @($branchConfig.expected_sources)
$Whitelist = if ($config.git_status_whitelist) { @($config.git_status_whitelist) } else { @() }

if (-not $TargetBranch) {
    Emit-Result -Ok $false `
        -WorkingDirectory @{ status = "error"; files = @() } `
        -LocalSync @{ status = "not_checked"; ahead_count = 0; behind_count = 0 } `
        -Propagation @() `
        -ErrorMessage "config.branches.$Environment.target está vacío."
}

# ----------------------------------------------------------------------------
# Paso 1: Working directory limpio (ignora whitelist)
# ----------------------------------------------------------------------------

$statusResult = Invoke-Git -Arguments @("status", "--porcelain")
if ($statusResult.ExitCode -ne 0) {
    Emit-Result -Ok $false `
        -WorkingDirectory @{ status = "error"; files = @() } `
        -LocalSync @{ status = "not_checked"; ahead_count = 0; behind_count = 0 } `
        -Propagation @() `
        -ErrorMessage "git status falló: $($statusResult.Stderr.Trim())"
}

$dirtyFiles = @()
if (-not [string]::IsNullOrWhiteSpace($statusResult.Stdout)) {
    $lines = $statusResult.Stdout -split "`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    foreach ($line in $lines) {
        $fileName = $line.Substring(3).Trim()
        if ($fileName.StartsWith('"') -and $fileName.EndsWith('"')) {
            $fileName = $fileName.Substring(1, $fileName.Length - 2)
        }
        $baseName = Split-Path $fileName -Leaf

        $isWhitelisted = $false
        foreach ($allowed in $Whitelist) {
            if ($baseName -eq $allowed -or $fileName -eq $allowed) {
                $isWhitelisted = $true
                break
            }
        }
        if (-not $isWhitelisted) {
            $dirtyFiles += $fileName
        }
    }
}

if ($dirtyFiles.Count -gt 0) {
    Emit-Result -Ok $false `
        -WorkingDirectory @{ status = "dirty"; files = $dirtyFiles } `
        -LocalSync @{ status = "not_checked"; ahead_count = 0; behind_count = 0 } `
        -Propagation @() `
        -ErrorMessage "Hay archivos modificados sin commitear (fuera del whitelist). Hacé commit o stash antes de seguir."
}

$workingDirectory = @{ status = "clean"; files = @() }

# ----------------------------------------------------------------------------
# Paso 2: Fetch de todas las ramas relevantes (objetivo + fuentes)
# ----------------------------------------------------------------------------

$branchesToFetch = @($TargetBranch) + $ExpectedSources | Select-Object -Unique
$fetchArgs = @("fetch", "origin") + $branchesToFetch + @("--quiet")
$fetchResult = Invoke-Git -Arguments $fetchArgs
if ($fetchResult.ExitCode -ne 0) {
    Emit-Result -Ok $false `
        -WorkingDirectory $workingDirectory `
        -LocalSync @{ status = "error"; ahead_count = 0; behind_count = 0 } `
        -Propagation @() `
        -ErrorMessage "git fetch falló: $($fetchResult.Stderr.Trim())"
}

# ----------------------------------------------------------------------------
# Paso 3: Asegurar que la rama objetivo existe localmente y hacer checkout
# ----------------------------------------------------------------------------

$branchExistsResult = Invoke-Git -Arguments @("show-ref", "--verify", "--quiet", "refs/heads/$TargetBranch")
if ($branchExistsResult.ExitCode -ne 0) {
    # No existe localmente: crearla trackeando origin/<target>
    $createResult = Invoke-Git -Arguments @("checkout", "-b", $TargetBranch, "origin/$TargetBranch")
    if ($createResult.ExitCode -ne 0) {
        Emit-Result -Ok $false `
            -WorkingDirectory $workingDirectory `
            -LocalSync @{ status = "error"; ahead_count = 0; behind_count = 0 } `
            -Propagation @() `
            -ErrorMessage "No se pudo crear la rama local '$TargetBranch' desde origin/$($TargetBranch): $($createResult.Stderr.Trim())"
    }
}
else {
    $checkoutResult = Invoke-Git -Arguments @("checkout", $TargetBranch)
    if ($checkoutResult.ExitCode -ne 0) {
        Emit-Result -Ok $false `
            -WorkingDirectory $workingDirectory `
            -LocalSync @{ status = "error"; ahead_count = 0; behind_count = 0 } `
            -Propagation @() `
            -ErrorMessage "git checkout $TargetBranch falló: $($checkoutResult.Stderr.Trim())"
    }
}

# ----------------------------------------------------------------------------
# Paso 4: Calcular sincronización local antes de pull
# ----------------------------------------------------------------------------

$aheadResult = Invoke-Git -Arguments @("rev-list", "--count", "origin/$TargetBranch..HEAD")
$behindResult = Invoke-Git -Arguments @("rev-list", "--count", "HEAD..origin/$TargetBranch")

if ($aheadResult.ExitCode -ne 0 -or $behindResult.ExitCode -ne 0) {
    Emit-Result -Ok $false `
        -WorkingDirectory $workingDirectory `
        -LocalSync @{ status = "error"; ahead_count = 0; behind_count = 0 } `
        -Propagation @() `
        -ErrorMessage "No se pudo calcular el estado de sincronización local."
}

$ahead = [int]($aheadResult.Stdout.Trim())
$behind = [int]($behindResult.Stdout.Trim())

# Caso 1: adelantado (commits locales sin pushear) -> abortar
if ($ahead -gt 0 -and $behind -eq 0) {
    Emit-Result -Ok $false `
        -WorkingDirectory $workingDirectory `
        -LocalSync @{ status = "ahead"; ahead_count = $ahead; behind_count = 0 } `
        -Propagation @() `
        -ErrorMessage "La rama local '$TargetBranch' tiene $ahead commit(s) que no están en origin/$TargetBranch. Hacé git push antes de deployar."
}

# Caso 2: divergente -> abortar
if ($ahead -gt 0 -and $behind -gt 0) {
    Emit-Result -Ok $false `
        -WorkingDirectory $workingDirectory `
        -LocalSync @{ status = "diverged"; ahead_count = $ahead; behind_count = $behind } `
        -Propagation @() `
        -ErrorMessage "La rama local '$TargetBranch' divergió de origin/$TargetBranch ($ahead local, $behind remoto). Resolvé el merge/rebase antes de deployar."
}

# Caso 3: atrasado y limpio -> pull --ff-only
if ($behind -gt 0) {
    $pullResult = Invoke-Git -Arguments @("pull", "--ff-only", "origin", $TargetBranch)
    if ($pullResult.ExitCode -ne 0) {
        Emit-Result -Ok $false `
            -WorkingDirectory $workingDirectory `
            -LocalSync @{ status = "error"; ahead_count = 0; behind_count = $behind } `
            -Propagation @() `
            -ErrorMessage "git pull --ff-only falló: $($pullResult.Stderr.Trim())"
    }
    $localSync = @{ status = "behind"; ahead_count = 0; behind_count = $behind }
}
else {
    # Caso 4: ya al día
    $localSync = @{ status = "ok"; ahead_count = 0; behind_count = 0 }
}

# ----------------------------------------------------------------------------
# Paso 5: Checks de propagación (bidireccional con clasificación por timestamp)
#
# Se compara el CONTENIDO del árbol con `git diff --name-only origin/<target>
# origin/<source>`. Esto es inmune a squash merges porque mira el estado final
# de los archivos. Después, para cada archivo que difiere, se clasifica según
# en qué rama está el último commit que lo tocó (mediante committer time):
#
#   - sourceTime > targetTime  -> el archivo se modificó más recientemente en
#                                 <source> que en <target>: falta propagar.
#                                 Aparece en changed_files y dispara has_changes.
#
#   - targetTime >= sourceTime -> el archivo está más "fresco" en <target>.
#                                 Caso normal en gitflow (ej: hotfix de master
#                                 propagado a staging que aún no llegó a
#                                 develop). NO dispara alerta; se reporta
#                                 aparte en target_ahead_files como info.
#
# Esto elimina los falsos positivos que aparecían cuando el diff bidireccional
# detectaba diferencias "del lado de target" en escenarios esperados del flujo.
#
# No se aplica whitelist acá: el whitelist sirve para ignorar cambios LOCALES
# sin commitear en el working directory. Esta comparación es entre dos ramas
# remotas, donde no hay cambios locales; cualquier archivo que difiera es una
# diferencia real de contenido.
# ----------------------------------------------------------------------------

$propagation = @()
foreach ($source in $ExpectedSources) {
    $diffResult = Invoke-Git -Arguments @("diff", "--name-only", "origin/$TargetBranch", "origin/$source")
    if ($diffResult.ExitCode -ne 0) {
        Emit-Result -Ok $false `
            -WorkingDirectory $workingDirectory `
            -LocalSync $localSync `
            -Propagation @() `
            -ErrorMessage "No se pudo comparar el contenido de origin/$source con origin/$($TargetBranch): $($diffResult.Stderr.Trim())"
    }

    $allDifferingFiles = @()
    if (-not [string]::IsNullOrWhiteSpace($diffResult.Stdout)) {
        $diffLines = $diffResult.Stdout -split "`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        foreach ($diffFile in $diffLines) {
            $df = $diffFile.Trim()
            if ($df.StartsWith('"') -and $df.EndsWith('"')) {
                $df = $df.Substring(1, $df.Length - 2)
            }
            $allDifferingFiles += $df
        }
    }

    # Clasificar cada archivo por timestamp del último commit en cada rama.
    $sourceAheadFiles = @()
    $targetAheadFiles = @()

    foreach ($file in $allDifferingFiles) {
        $sourceTimeResult = Invoke-Git -Arguments @("log", "-1", "--format=%ct", "origin/$source", "--", $file)
        $targetTimeResult = Invoke-Git -Arguments @("log", "-1", "--format=%ct", "origin/$TargetBranch", "--", $file)

        $sourceTime = 0
        $targetTime = 0
        if ($sourceTimeResult.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($sourceTimeResult.Stdout)) {
            $sourceTime = [long]($sourceTimeResult.Stdout.Trim())
        }
        if ($targetTimeResult.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($targetTimeResult.Stdout)) {
            $targetTime = [long]($targetTimeResult.Stdout.Trim())
        }

        if ($sourceTime -gt $targetTime) {
            $sourceAheadFiles += $file
        }
        else {
            $targetAheadFiles += $file
        }
    }

    $propagation += @{
        source             = $source
        has_changes        = ($sourceAheadFiles.Count -gt 0)
        changed_files      = $sourceAheadFiles
        target_ahead_files = $targetAheadFiles
    }
}

# ----------------------------------------------------------------------------
# Resultado final: ok=true (propagación pendiente NO bloquea acá)
# ----------------------------------------------------------------------------

Emit-Result -Ok $true `
    -WorkingDirectory $workingDirectory `
    -LocalSync $localSync `
    -Propagation $propagation
