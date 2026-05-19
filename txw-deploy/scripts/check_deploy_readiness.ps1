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
#      contenido de los árboles (git diff) contra la rama objetivo. Esta
#      comparación es inmune a squash merges porque mira el estado final
#      de los archivos, no la historia de commits.
#
# El script ejecuta el checkout y el pull --ff-only por sí mismo. Los checks
# de propagación son informativos: NO abortan el script (queda a criterio de
# Claude mostrarlos y pedir confirmación al usuario).
#
# NOTA sobre squash merges: la comparación de propagación NO usa conteo de
# commits por SHA. Cuando un merge a la rama objetivo se hace con squash, los
# commits originales de la fuente conservan SHAs distintos y un conteo por SHA
# los reportaría como "faltantes" aunque su contenido ya esté propagado. Por
# eso se compara directamente el contenido de los árboles con git diff.
#
# Parámetros:
#   -TargetBranch       Nombre de la rama objetivo (ej: "staging", "master").
#   -ExpectedSources    Array de nombres de ramas que deberían estar propagadas
#                       en la rama objetivo (ej: "develop","master" para QA;
#                       "staging" para PROD).
#   -Whitelist          Array de nombres de archivo cuyos cambios sin commitear
#                       se permiten (típicamente "appsettings.Development.json").
#
# Salida: JSON con la estructura documentada en SKILL.md.
# Exit code:
#   0  - ok=true. Repo en condiciones de deployar. Puede haber propagación
#        pendiente (Claude decide qué hacer con eso).
#   1  - ok=false. Algún problema bloqueante: working dir dirty, rama divergente,
#        commits locales sin pushear, o error de git.

param(
    [Parameter(Mandatory = $true)]
    [string]$TargetBranch,

    [Parameter(Mandatory = $true)]
    [string[]]$ExpectedSources,

    [Parameter(Mandatory = $false)]
    [string[]]$Whitelist = @()
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
        [string]$Error = $null
    )

    $result = @{
        ok                = $Ok
        working_directory = $WorkingDirectory
        local_sync        = $LocalSync
        propagation       = $Propagation
    }
    if ($Error) {
        $result.error = $Error
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
        [string[]]$Args
    )

    $stdoutFile = [System.IO.Path]::GetTempFileName()
    $stderrFile = [System.IO.Path]::GetTempFileName()

    try {
        $proc = Start-Process -FilePath "git" `
            -ArgumentList $Args `
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
# Paso 1: Working directory limpio (ignora whitelist)
# ----------------------------------------------------------------------------

$statusResult = Invoke-Git -Args @("status", "--porcelain")
if ($statusResult.ExitCode -ne 0) {
    Emit-Result -Ok $false `
        -WorkingDirectory @{ status = "error"; files = @() } `
        -LocalSync @{ status = "not_checked"; ahead_count = 0; behind_count = 0 } `
        -Propagation @() `
        -Error "git status falló: $($statusResult.Stderr.Trim())"
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
        -Error "Hay archivos modificados sin commitear (fuera del whitelist). Hacé commit o stash antes de seguir."
}

$workingDirectory = @{ status = "clean"; files = @() }

# ----------------------------------------------------------------------------
# Paso 2: Fetch de todas las ramas relevantes (objetivo + fuentes)
# ----------------------------------------------------------------------------

$branchesToFetch = @($TargetBranch) + $ExpectedSources | Select-Object -Unique
$fetchArgs = @("fetch", "origin") + $branchesToFetch + @("--quiet")
$fetchResult = Invoke-Git -Args $fetchArgs
if ($fetchResult.ExitCode -ne 0) {
    Emit-Result -Ok $false `
        -WorkingDirectory $workingDirectory `
        -LocalSync @{ status = "error"; ahead_count = 0; behind_count = 0 } `
        -Propagation @() `
        -Error "git fetch falló: $($fetchResult.Stderr.Trim())"
}

# ----------------------------------------------------------------------------
# Paso 3: Asegurar que la rama objetivo existe localmente y hacer checkout
# ----------------------------------------------------------------------------

$branchExistsResult = Invoke-Git -Args @("show-ref", "--verify", "--quiet", "refs/heads/$TargetBranch")
if ($branchExistsResult.ExitCode -ne 0) {
    # No existe localmente: crearla trackeando origin/<target>
    $createResult = Invoke-Git -Args @("checkout", "-b", $TargetBranch, "origin/$TargetBranch")
    if ($createResult.ExitCode -ne 0) {
        Emit-Result -Ok $false `
            -WorkingDirectory $workingDirectory `
            -LocalSync @{ status = "error"; ahead_count = 0; behind_count = 0 } `
            -Propagation @() `
            -Error "No se pudo crear la rama local '$TargetBranch' desde origin/$($TargetBranch): $($createResult.Stderr.Trim())"
    }
}
else {
    $checkoutResult = Invoke-Git -Args @("checkout", $TargetBranch)
    if ($checkoutResult.ExitCode -ne 0) {
        Emit-Result -Ok $false `
            -WorkingDirectory $workingDirectory `
            -LocalSync @{ status = "error"; ahead_count = 0; behind_count = 0 } `
            -Propagation @() `
            -Error "git checkout $TargetBranch falló: $($checkoutResult.Stderr.Trim())"
    }
}

# ----------------------------------------------------------------------------
# Paso 4: Calcular sincronización local antes de pull
# ----------------------------------------------------------------------------

$aheadResult = Invoke-Git -Args @("rev-list", "--count", "origin/$TargetBranch..HEAD")
$behindResult = Invoke-Git -Args @("rev-list", "--count", "HEAD..origin/$TargetBranch")

if ($aheadResult.ExitCode -ne 0 -or $behindResult.ExitCode -ne 0) {
    Emit-Result -Ok $false `
        -WorkingDirectory $workingDirectory `
        -LocalSync @{ status = "error"; ahead_count = 0; behind_count = 0 } `
        -Propagation @() `
        -Error "No se pudo calcular el estado de sincronización local."
}

$ahead = [int]($aheadResult.Stdout.Trim())
$behind = [int]($behindResult.Stdout.Trim())

# Caso 1: adelantado (commits locales sin pushear) -> abortar
if ($ahead -gt 0 -and $behind -eq 0) {
    Emit-Result -Ok $false `
        -WorkingDirectory $workingDirectory `
        -LocalSync @{ status = "ahead"; ahead_count = $ahead; behind_count = 0 } `
        -Propagation @() `
        -Error "La rama local '$TargetBranch' tiene $ahead commit(s) que no están en origin/$TargetBranch. Hacé git push antes de deployar."
}

# Caso 2: divergente -> abortar
if ($ahead -gt 0 -and $behind -gt 0) {
    Emit-Result -Ok $false `
        -WorkingDirectory $workingDirectory `
        -LocalSync @{ status = "diverged"; ahead_count = $ahead; behind_count = $behind } `
        -Propagation @() `
        -Error "La rama local '$TargetBranch' divergió de origin/$TargetBranch ($ahead local, $behind remoto). Resolvé el merge/rebase antes de deployar."
}

# Caso 3: atrasado y limpio -> pull --ff-only
if ($behind -gt 0) {
    $pullResult = Invoke-Git -Args @("pull", "--ff-only", "origin", $TargetBranch)
    if ($pullResult.ExitCode -ne 0) {
        Emit-Result -Ok $false `
            -WorkingDirectory $workingDirectory `
            -LocalSync @{ status = "error"; ahead_count = 0; behind_count = $behind } `
            -Propagation @() `
            -Error "git pull --ff-only falló: $($pullResult.Stderr.Trim())"
    }
    $localSync = @{ status = "behind"; ahead_count = 0; behind_count = $behind }
}
else {
    # Caso 4: ya al día
    $localSync = @{ status = "ok"; ahead_count = 0; behind_count = 0 }
}

# ----------------------------------------------------------------------------
# Paso 5: Checks de propagación
#
# Para cada rama fuente se compara el CONTENIDO del árbol contra la rama
# objetivo con `git diff --name-only origin/<target> origin/<source>`.
#
# Esto lista los archivos cuyo contenido FINAL difiere entre las dos ramas.
# Es la pregunta correcta: si un archivo que <source> modificó ya quedó
# idéntico en <target> (porque el merge lo propagó — squash incluido), los
# árboles coinciden en ese archivo y NO aparece. Inmune a squash merges,
# porque mira el estado final de los archivos, no la historia de commits.
#
# No se usa conteo de commits por SHA: un squash le da SHAs nuevos a los
# commits propagados, así que un conteo reportaría falsos positivos.
#
# No se aplica whitelist acá: el whitelist sirve para ignorar cambios LOCALES
# sin commitear en el working directory. Esta comparación es entre dos ramas
# remotas, donde no hay cambios locales; cualquier archivo que difiera es una
# diferencia real de contenido que el usuario debe ver.
#
# Si la lista de archivos queda vacía -> no hay nada que propagar.
# Si tiene archivos -> hay diferencia real de contenido: puede ser trabajo de
# <source> sin propagar, o trabajo que <target> tiene y <source> no (ej:
# hotfix de master). Ambos casos son relevantes, porque deployar <source>
# sobrescribiría ese estado.
# ----------------------------------------------------------------------------

$propagation = @()
foreach ($source in $ExpectedSources) {
    $diffResult = Invoke-Git -Args @("diff", "--name-only", "origin/$TargetBranch", "origin/$source")
    if ($diffResult.ExitCode -ne 0) {
        Emit-Result -Ok $false `
            -WorkingDirectory $workingDirectory `
            -LocalSync $localSync `
            -Propagation @() `
            -Error "No se pudo comparar el contenido de origin/$source con origin/$($TargetBranch): $($diffResult.Stderr.Trim())"
    }

    $changedFiles = @()
    if (-not [string]::IsNullOrWhiteSpace($diffResult.Stdout)) {
        $diffLines = $diffResult.Stdout -split "`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        foreach ($diffFile in $diffLines) {
            $df = $diffFile.Trim()
            if ($df.StartsWith('"') -and $df.EndsWith('"')) {
                $df = $df.Substring(1, $df.Length - 2)
            }
            $changedFiles += $df
        }
    }

    $propagation += @{
        source        = $source
        has_changes   = ($changedFiles.Count -gt 0)
        changed_files = $changedFiles
    }
}

# ----------------------------------------------------------------------------
# Resultado final: ok=true (propagación pendiente NO bloquea acá)
# ----------------------------------------------------------------------------

Emit-Result -Ok $true `
    -WorkingDirectory $workingDirectory `
    -LocalSync $localSync `
    -Propagation $propagation
