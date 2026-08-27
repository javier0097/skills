---
name: TXW-deploy
description: Automatiza la preparación de artefactos para deploys del proyecto TruextendWebsite a los ambientes QA y PROD. Usá esta skill cuando el usuario mencione hacer un deploy, preparar un deploy, generar artefactos de deploy, armar carpeta de deploy, o cuando invoque /TXW-deploy. Típicamente el usuario dirá algo como 'hacer deploy a QA', 'preparar deploy a PROD con recipe', 'generar artefactos para deploy QA con cambios en X', etc. La skill hace git pull, sube el número de versión en version.props (solo en QA), corre el publish, limpia el build, detecta si necesita script SQL comparando migraciones, arma la carpeta YYYYMMDD-(QA|PROD)[-N] con todos los artefactos, la sube a la carpeta compartida de Google Drive, y propaga los archivos de versión actualizados a las ramas inferiores. Requiere correr desde Claude Code con el working directory en la raíz del repositorio del proyecto.
---

# TXW-deploy

Skill para preparar y subir artefactos de deploy del proyecto **TruextendWebsite** a la carpeta compartida de Google Drive del equipo de IT.

## Configuración

Toda la configuración (rutas, nombres de proyecto, constantes de ambiente) está en `config.json` en la raíz de esta skill. **Lee `config.json` al inicio de cada invocación** y usa esos valores en lugar de hardcodearlos.

## Modelo de versionado (leer antes de tocar el flujo)

El proyecto maneja **un solo número de versión** para toda la solución, y dos archivos:

- **`version.props`** (raíz de la solución, en singular) — contiene `<TruextendVersion>`, formato `major.minor.patch` numérico, **sin sufijos** (nada de `-rc1`), porque el valor alimenta `AssemblyVersion`. Se edita a mano antes del publish.
- **`published-versions.props`** (`TruextendWebsite.Web\Properties\PublishProfiles\`) — registra la última versión publicada a cada ambiente con items `<PublishedVersion Include="QA|Production" Version="..." />`. Lo actualiza automáticamente el target `RecordPublishedVersion` durante el publish. **La skill nunca lo escribe**: solo lo lee.

**Convención `Major.Sprint.Patch`:**

- **Major** — cambia bajo criterio humano. La skill nunca lo propone sola.
- **Minor** — es el número de sprint. Sube en el **primer deploy a QA de un sprint nuevo**, o sea cuando la versión actual ya salió a Production.
- **Patch** — sube en **cada deploy a QA** dentro del mismo sprint.
- **Production no bumpea**: publica exactamente la versión que QA validó.

**`ValidatePublishVersion`** (en `Directory.Build.targets`) enforcea esto y rechaza el publish si:
- la versión no es estrictamente mayor que el baseline de ese ambiente, o
- es un publish a Production de una versión distinta a la que QA publicó último.

La skill valida ambas reglas **antes** de compilar (Paso 2.5), así un deploy destinado a fallar se corta al instante en vez de después de varios minutos de build.

**Flujo de ramas:**

1. El publish se hace desde la rama del ambiente: `staging` para QA, `master` para PROD. El gitflow no cambia.
2. El bump se hace solo en QA, justo antes del publish.
3. Al final de todo, ya con los artefactos en Drive, los dos `.props` se commitean en la rama del deploy y se propagan hacia abajo con merges (*backmerge*):
   - Deploy a QA: `staging` → `develop`
   - Deploy a PROD: `master` → `staging` → `develop`

**El orden importa**: el bump se escribe *antes* del publish (porque alimenta el build) pero se commitea al final del flujo, en el último paso. Si el publish falla, `version.props` se revierte para no dejar la rama sucia con un bump de un build que nunca existió.

## Paso 0 — Resolución del base path de la skill (OBLIGATORIO primero)

**Antes de ejecutar cualquier otro paso**, identifica el path absoluto donde está instalada esta skill y guárdalo como `$SKILL_BASE`. Este path es necesario para invocar los scripts bundleados de forma confiable.

En Windows, Claude Desktop suele instalarse como paquete UWP/MSIX (default de la Microsoft Store), por lo que el contenido de la skill queda virtualizado dentro del paquete y **no** vive en `~/.claude\skills\` ni en `~/.claude\plugins\`. Además, los UUIDs del marketplace y del plugin varían entre máquinas, así que no se pueden hardcodear. Resolvé `$SKILL_BASE` en runtime así:

1. **Descubrir la ruta del cache UWP en runtime.** Ejecutá este comando PowerShell, que busca recursivamente la carpeta `txw-deploy` bajo el cache del paquete:

   ```powershell
   Get-ChildItem "$env:LOCALAPPDATA\Packages\Claude_pzs8sxrjxfjjc\LocalCache\Roaming\Claude\local-agent-mode-sessions\skills-plugin" `
       -Recurse -Directory -Filter "txw-deploy" -ErrorAction SilentlyContinue `
   | Select-Object -ExpandProperty FullName -First 1
   ```

   Si retorna un path, ese es `$SKILL_BASE`.

2. **Fallbacks** (instalación no-UWP, o usuario que clonó el repo localmente). Si el comando anterior no retorna nada, probá en este orden y usá el primero que exista:
   - `C:\Users\<usuario>\source\repos\skills\txw-deploy\`
   - `$env:USERPROFILE\.claude\skills\txw-deploy\`

Para todos los scripts que ejecutes, **siempre usá el path absoluto completo** `"$SKILL_BASE\scripts\<nombre>.ps1"` envuelto entre comillas dobles (por si el path tiene espacios). **Nunca uses rutas relativas** como `scripts/xxx.ps1` — Claude Code corre con CWD en el proyecto del usuario, no en la skill, por lo que los paths relativos fallan.

Para leer el `config.json`, usá `"$SKILL_BASE\config.json"`.

Para leer los templates, usá `"$SKILL_BASE\templates\<archivo>.txt"`.

## Invocación de scripts PowerShell

**SIEMPRE invocá los scripts `.ps1` con `-ExecutionPolicy Bypass`** para evitar errores `UnauthorizedAccess` en máquinas con políticas restrictivas (default en muchas instalaciones de Windows). El patrón estándar es:

```powershell
pwsh -ExecutionPolicy Bypass -File "$SKILL_BASE\scripts\<nombre>.ps1" [parámetros]
```

Si `pwsh` (PowerShell Core 7+) no está disponible en la máquina, usá `powershell.exe` (Windows PowerShell 5.1, que viene preinstalado en Windows) con la misma sintaxis:

```powershell
powershell.exe -ExecutionPolicy Bypass -File "$SKILL_BASE\scripts\<nombre>.ps1" [parámetros]
```

`-ExecutionPolicy Bypass` es un override por ejecución — no modifica la configuración global del sistema.

## Invocación típica

El usuario puede invocar la skill de varias formas:

- Con slash command: `/TXW-deploy QA`, `/TXW-deploy PROD con recipe`, etc.
- Con lenguaje natural: "Hacé un deploy a QA", "Preparame los artefactos para PROD con recipe y agregar CVPath con basePath C:\Docs\CV", "Armar deploy QA".

**Importante**: esta skill asume que Claude Code está corriendo con el working directory en la raíz del repositorio del proyecto TruextendWebsite. Todos los comandos de git, dotnet publish y dotnet ef se ejecutan relativos a ese directorio.

Información que el usuario puede mencionar en el prompt:

1. **Ambiente**: `QA` o `PROD` (OBLIGATORIO). Si no lo menciona, pregúntaselo antes de avanzar.
2. **Recipe**: si aparece la palabra "recipe", marca `has_recipe=true`.
3. **Versión**: si menciona un número de versión explícito (ej: "deploy a QA con la 2.4.0"), usalo en el Paso 2.5 en lugar de proponer uno.
4. **Instrucciones especiales**: cualquier texto que describa una modificación no estándar al Deploy.txt (ej: "agregar X al appsettings").

**NUNCA pidas al usuario si debe haber script SQL** — eso se detecta automáticamente comparando migraciones.

## Flujo de ejecución

Sigue este orden estrictamente. Valida el éxito de cada paso antes de avanzar al siguiente. Si algo falla, aborta e informa claramente qué pasó.

### Paso 1 — Pre-flight

1. Lee `"$SKILL_BASE\config.json"`.
2. Parsea el prompt del usuario para extraer: `environment` (QA/PROD), `has_recipe` (bool), `version` (string o null), `special_instructions` (string libre o null).
3. Si falta el ambiente, pídelo con una sola pregunta y detente hasta tener respuesta.
4. Determina el publish profile correspondiente según `config.json[publish_profiles]`:
   - `QA` → `QA` (`Properties\PublishProfiles\QA.pubxml`)
   - `PROD` → `Production` (`Properties\PublishProfiles\Production.pubxml`)

   El nombre del perfil no es cosmético: `ValidatePublishVersion` y `RecordPublishedVersion` (en `Directory.Build.targets`) están condicionados a `'$(_PublishProfileInUse)' != ''`. Si el perfil no resuelve, ambos targets se saltean **en silencio**: el guard de versión no corre y `published-versions.props` nunca se actualiza.
5. Leé `config.json[branches][<environment>].bump_version` para saber si este deploy requiere subir el número de versión (`true` en QA, `false` en PROD). Las rutas de los `.props` no hace falta que las resuelvas acá: de eso se encarga el Paso 2.5.
6. Calculá la fecha actual en formato `YYYYMMDD` (zona horaria local de la laptop).

### Paso 2 — Validación de git y preparación de la rama

Este paso unifica todas las validaciones de git previas al deploy: working directory limpio, sincronización local con el remoto, y propagación de commits desde las ramas fuente esperadas.

1. Determiná la rama objetivo y las fuentes esperadas leyendo `config.json[branches][<environment>]`:
   - `QA` → target: `staging`, expected_sources: `develop`, `master`
   - `PROD` → target: `master`, expected_sources: `staging`

2. Ejecutá el script de readiness. El script lee `target`, `expected_sources` y `git_status_whitelist` del propio `config.json` (evitamos pasar arrays como argumentos porque `pwsh -File` no los bindea bien):

   ```powershell
   pwsh -ExecutionPolicy Bypass -File "$SKILL_BASE\scripts\check_deploy_readiness.ps1" `
       -ConfigPath "$SKILL_BASE\config.json" `
       -Environment "<QA|PROD>"
   ```

   El script hace internamente, en este orden:
   - Lee el config y resuelve target / expected_sources / whitelist según el environment.
   - Valida que el working directory esté limpio (ignora archivos del whitelist).
   - `git fetch` de la rama objetivo y todas las fuentes.
   - Si la rama objetivo no existe localmente, la crea desde `origin/<target>`.
   - `git checkout <target>`.
   - Calcula si la rama local está sincronizada con `origin/<target>`. Si está atrasada y limpia, hace `git pull --ff-only`. Si está adelantada o divergente, aborta.
   - Para cada `expected_source`, compara el contenido contra `origin/<target>` (bidireccional, inmune a squash) y clasifica los archivos que difieren según en qué rama tienen el commit más reciente.

   **Al terminar este paso el repo queda parado en la rama del deploy**, que es donde se hace el bump, el publish y el commit de versiones.

3. Salida JSON del script:

   ```json
   {
       "ok": true,
       "working_directory": {
           "status": "clean",
           "files": []
       },
       "local_sync": {
           "status": "ok",
           "ahead_count": 0,
           "behind_count": 0
       },
       "propagation": [
           {
               "source": "develop",
               "has_changes": true,
               "changed_files": [
                   "src/Controllers/UserController.cs",
                   "src/Services/AuthService.cs"
               ],
               "target_ahead_files": []
           },
           {
               "source": "master",
               "has_changes": false,
               "changed_files": [],
               "target_ahead_files": [
                   "src/Hotfix/SomeFile.cs"
               ]
           }
       ]
   }
   ```

   Estados posibles:
   - `working_directory.status`: `"clean"`, `"dirty"`, `"error"`.
   - `local_sync.status`: `"ok"` (al día), `"behind"` (estaba atrasado, ya hizo ff), `"ahead"` (bloqueante), `"diverged"` (bloqueante), `"error"`, `"not_checked"`.

   **Cómo interpretar cada entrada de `propagation`:**

   El check compara el contenido entre `origin/<source>` y `origin/<target>` con `git diff --name-only` (bidireccional, inmune a squash merges). De los archivos que difieren, clasifica según en qué rama está el último commit que los tocó (committer time):

   - **`changed_files`**: archivos modificados más recientemente en `<source>` que en `<target>`. Es decir, trabajo de la fuente que **falta propagar** al target. Esta es la única lista que debe disparar alerta.
   - **`target_ahead_files`**: archivos modificados más recientemente en `<target>` que en `<source>`. Es el caso normal de gitflow (ej: un hotfix en `master` que ya está propagado a `staging` pero `develop` aún no lo recibió). **No es motivo de alerta**; se incluye solo como información.
   - **`has_changes`**: depende **solo** de `changed_files`. Si está vacío, `has_changes=false` aunque haya cosas en `target_ahead_files`.

   Nota: es esperable que `version.props` y `published-versions.props` aparezcan en `target_ahead_files` cuando la rama del deploy ya recibió un bump que las inferiores todavía no. No es una alerta.

4. **Manejo del resultado:**

   - Si `ok=false` (exit code 1): aborta el deploy. Mostrá al usuario el campo `error` y los detalles relevantes (archivos dirty, contadores ahead/behind, etc.) para que pueda corregir antes de reintentar.

   - Si `ok=true`: revisá cada entrada de `propagation` y decidí según **`has_changes`**:

     - Si todas las fuentes tienen `has_changes = false` → no hay nada sin propagar. Seguí con el Paso 2.5 sin preguntar nada.

     - Si alguna fuente tiene `has_changes = true` → hay trabajo en la fuente que no está propagado al target. **Mostrá al usuario los archivos afectados (`changed_files`)** y pedí confirmación explícita antes de seguir. Formato sugerido:

       > Detecté cambios en ramas fuente que aún no están propagados a `<target>`:
       >
       > **`develop`** — 2 archivos sin propagar:
       >   - `src/Controllers/UserController.cs`
       >   - `src/Services/AuthService.cs`
       >
       > Esto suele indicar que falta hacer un PR de `develop` → `<target>`. ¿Querés seguir con el deploy de todas formas?

       Si el usuario no responde afirmativamente de forma clara (`sí`, `seguir`, `s`, etc.), **abortá el deploy**. Default seguro: ante duda, no avanzar.

       Los archivos en `target_ahead_files` NO se muestran ni disparan alerta: son el caso normal de gitflow.

### Paso 2.5 — Estado de versión y bump

Este paso corre **siempre**, en QA y en PROD. En QA además hace el bump; en PROD solo valida.

1. Ejecutá el script de estado de versión:

   ```powershell
   pwsh -ExecutionPolicy Bypass -File "$SKILL_BASE\scripts\resolve_version_state.ps1" `
       -ConfigPath "$SKILL_BASE\config.json" `
       -Environment "<QA|PROD>"
   ```

   El script localiza `version.props` (acepta también `versions.props`) y `published-versions.props`, lee la versión actual y los baselines de cada ambiente, y aplica la convención `Major.Sprint.Patch` para proponer el número que corresponde. No escribe nada.

   Salida JSON:

   ```json
   {
       "ok": true,
       "versions_props_path": "version.props",
       "published_versions_props_path": "TruextendWebsite.Web\\Properties\\PublishProfiles\\published-versions.props",
       "version_element": "TruextendVersion",
       "current_version": "2.11.3",
       "baselines": { "QA": "2.11.3", "Production": "2.11.3" },
       "environment": "QA",
       "bump_required": true,
       "suggested_version": "2.12.0",
       "suggestion_reason": "La versión 2.11.3 ya se publicó a Production, así que el sprint está cerrado...",
       "validation": { "status": "ok", "messages": [] }
   }
   ```

   **Guardá `versions_props_path` y `published_versions_props_path`**: los vas a pasar a los scripts de los Pasos 4-6 y 11.

2. **Manejo de `validation.status`:**

   - `"ok"` → seguí.
   - `"warning"` → mostrale los `messages` al usuario y seguí (típicamente: el bump ya estaba aplicado de un publish anterior que falló).
   - `"error"` (exit code 1) → **abortá**. Son los casos que `ValidatePublishVersion` va a rechazar: en PROD, que `version.props` no coincida con lo que QA publicó, o que la versión ya se haya desplegado. Mostrá los `messages`, que ya explican qué revisar.

3. **Si `bump_required = false` (PROD)**: no toques `version.props`. Informá qué versión se va a desplegar (`current_version`) y seguí con el Paso 3.

4. **Si `bump_required = true` (QA)**: mostrá la propuesta y **pedí confirmación explícita**:

   > Versión actual: **2.11.3**
   > Propuesta para este deploy a QA: **2.12.0**
   >
   > Motivo: la 2.11.3 ya salió a Production, así que este es el primer deploy del sprint 12.
   >
   > ¿Confirmás, o querés otro número?

   El `suggestion_reason` del JSON ya trae el motivo redactado: usalo, no lo reformules.

   **Siempre preguntá, aunque la propuesta parezca obvia.** Hay excepciones a la convención (un cambio de major, o un sprint que no cierra con un deploy a PROD) que solo el usuario conoce. Este es el único valor del deploy que queda inmutable en el historial de git.

   Si el usuario propone otro número, validá que sea `major.minor.patch` sin sufijos y estrictamente mayor que el baseline de QA. Si no lo es, decíselo y volvé a preguntar.

5. **Editá `version.props`** reemplazando el contenido de `<TruextendVersion>` por el número confirmado. Es un reemplazo de una línea: no reformatees el archivo ni toques los comentarios.

6. **No commitees todavía.** El commit se hace en el Paso 11, junto con `published-versions.props`, después de validar el zip.

7. **Guardá el número confirmado** en una variable `version`: lo usás en el mensaje de commit del Paso 11.

### Paso 3 — Resolver nombre de carpeta de deploy y del zip

Determiná el nombre de la carpeta y del zip, considerando que puede haber más de un deploy del mismo día al mismo ambiente:

```powershell
pwsh -ExecutionPolicy Bypass -File "$SKILL_BASE\scripts\resolve_deploy_folder_name.ps1" `
    -DeploysRoot "<deploys_root>" `
    -DriveFolder "<drive_deploys_folder>" `
    -Environment "<QA|PROD>" `
    -Date "<YYYYMMDD>"
```

El script chequea tanto el directorio local como Drive para encontrar el máximo contador usado y retorna el siguiente disponible. Salida JSON:

```json
{
    "folder_name": "20260420-QA",
    "counter": 1,
    "zip_name": "PublishTXWebsite_20260420.zip"
}
```

- `folder_name`: nombre de la carpeta a crear (ej: `20260420-QA`, `20260420-QA-2`, `20260420-QA-3`).
- `counter`: `1` si es el primer deploy del día para ese ambiente, `2+` si hay duplicados.
- `zip_name`: nombre del zip. Incluye el sufijo `_PROD` si aplica y el contador al final si `counter > 1`:
  - Primer deploy QA: `PublishTXWebsite_20260420.zip`
  - Segundo deploy QA: `PublishTXWebsite_20260420_2.zip`
  - Primer deploy PROD: `PublishTXWebsite_20260420_PROD.zip`
  - Segundo deploy PROD: `PublishTXWebsite_20260420_PROD_2.zip`

**Guardá estos tres valores** (`folder_name`, `counter`, `zip_name`) y usalos en los pasos siguientes.

Si el script falla (exit code != 0), aborta mostrando el error.

### Pasos 4-6 — Publish, limpieza y armado (un solo script)

Los pasos de publish, limpieza del build y armado de la carpeta de deploy se ejecutan juntos con `build_and_package.ps1`:

```powershell
pwsh -ExecutionPolicy Bypass -File "$SKILL_BASE\scripts\build_and_package.ps1" `
    -StartupProjectRelativePath "<startup_project_relative_path>" `
    -PublishProfile "<profile_sin_extension>" `
    -BuildOutputPath "<build_output_path>" `
    -DeployFolder "<deploys_root>\<folder_name>" `
    -ZipName "<zip_name>" `
    -VersionsPropsPath "<versions_props_path del Paso 2.5>" `
    -PublishedVersionsPropsPath "<published_versions_props_path del Paso 2.5>" `
    [-RevertVersionsPropsOnFailure]
```

Pasá `-RevertVersionsPropsOnFailure` **solo si hiciste el bump** en el Paso 2.5 (es decir, solo en QA). En PROD omitilo: no tocaste `version.props`, así que no hay nada que revertir.

El script hace internamente:

1. **Snapshot** del hash de `published-versions.props` antes de compilar.
2. **Publish**: `dotnet publish <startup> -p:PublishProfile=<profile> --configuration Release`.
3. **Valida** que el build se generó correctamente. Si el publish falla y se pasó `-RevertVersionsPropsOnFailure`, hace `git checkout -- version.props` para dejar la rama limpia.
4. **Verifica que el publish regeneró `published-versions.props`** comparando el hash. Esto NO aborta el build; se reporta en la última línea del output:
   `[RESULT] published_versions_changed=true|false|unknown`
5. **Limpieza del build**:
   - Borra `App_Data/tenants.json` (si existe; si no, warning pero no aborta).
   - Vacía el contenido de `App_Data/Sites/Default/` (borra todos los archivos y subcarpetas adentro, pero mantiene la carpeta `Default`).
6. **Crea** la carpeta de deploy con el nombre calculado.
7. **Comprime** el contenido del build a `<zip_name>` DENTRO de la carpeta de deploy.
8. **Valida** que el zip existe y tiene tamaño > 0. Si falla, aborta SIN borrar el build original.
9. Solo si el zip es válido, **borra la carpeta original del build**.

**Manejo de `published_versions_changed`:**

- `true` → todo normal, seguí.
- `false` → el publish no modificó el archivo. En un deploy a QA con bump esto no debería pasar; avisale al usuario y **pedí confirmación antes de seguir** (puede indicar que el target de versionado no corrió). En PROD es menos raro pero igual conviene mencionarlo.
- `unknown` → no se encontró el archivo. Avisá que hay que revisar la ruta en `config.version_files` y seguí (el build es válido).

Si el script falla (exit code != 0), aborta mostrando el error.

### Paso 7 — Detección y generación de script SQL

Este paso usa dos scripts para minimizar tokens: uno para encontrar la carpeta con el último script, y otro para comparar migraciones.

1. Encontrá la última carpeta de deploy del ambiente que contenga `script.sql`:

   ```powershell
   pwsh -ExecutionPolicy Bypass -File "$SKILL_BASE\scripts\find_last_script_folder.ps1" `
       -DriveFolder "<drive_deploys_folder>" `
       -Environment "<QA|PROD>"
   ```

   Retorna JSON: `{ "found": bool, "folder_name": str, "folder_path": str, "script_path": str }`.

   Si `found=false`, aborta e informa al usuario (no debería pasar, pero validamos).

2. Decidí si hay que generar script comparando migraciones:

   ```powershell
   pwsh -ExecutionPolicy Bypass -File "$SKILL_BASE\scripts\detect_migration.ps1" `
       -LastScriptPath "<script_path del paso 1>" `
       -MigrationsFolder "<working_dir>\<migrations_folder_relative_path>"
   ```

   Retorna JSON: `{ "needs_script": bool, "last_deployed_migration": str, "latest_local_migration": str, "from_migration": str | null }`.

3. Si `needs_script=true`, ejecuta desde el working directory:

   ```powershell
   dotnet ef migrations script "<from_migration>" `
       --context "<ef_context>" `
       --project "<ef_project_relative_path>" `
       --startup-project "<startup_project_relative_path>" `
       --output "<deploys_root>\<folder_name>\script.sql"
   ```

   No uses `2>&1` al ejecutar este comando: dotnet escribe avisos benignos en stderr y eso puede generar falsos positivos. Validá el resultado revisando `$LASTEXITCODE` y la existencia del archivo de salida.

   Valida que `script.sql` se generó y no está vacío.

4. Si `needs_script=false`, no hagas nada en este paso y continúa.

### Paso 8 — Generación del Deploy.txt

1. Elige el template según ambiente y si hay script:
   - QA sin script → `"$SKILL_BASE\templates\deploy_qa_build_only.txt"`
   - QA con script → `"$SKILL_BASE\templates\deploy_qa_with_script.txt"`
   - PROD sin script → `"$SKILL_BASE\templates\deploy_prod_build_only.txt"`
   - PROD con script → `"$SKILL_BASE\templates\deploy_prod_with_script.txt"`
2. Los templates tienen un placeholder:
   - `{{ZIP_NAME}}` → reemplazalo por el `zip_name` calculado en el Paso 3.
3. Si el usuario mencionó `special_instructions`:
   - Adapta la instrucción según el ambiente (ej: `appsettings.QA.json` vs `appsettings.json`).
   - Intercala los pasos adicionales en el lugar correcto del template (típicamente entre "Copy configuration files" y "Run script/Start"), renumerando los pasos posteriores.
4. **Muestra al usuario el draft completo del Deploy.txt y espera confirmación explícita** antes de grabarlo. Si pide cambios, aplícalos y vuelve a mostrar.
5. Graba el archivo como `Deploy_<environment>.txt` (ej: `Deploy_QA.txt`) en la carpeta de deploy.

### Paso 9 — Recipe (solo si has_recipe)

Si `has_recipe=true`:

1. Dile al usuario: "Por favor, pegá el archivo `update-recipe.json` en la ruta: `<deploys_root>\<folder_name>\`. Avisame cuando esté listo."
2. Espera su confirmación.
3. Valida que `update-recipe.json` existe en la carpeta.
4. Copia `"$SKILL_BASE\templates\admin_tasks.txt"` a `<deploys_root>\<folder_name>\Admin tasks.txt`.

### Paso 10 — Subida a Drive

1. Copia la carpeta completa `<deploys_root>\<folder_name>\` a `<drive_deploys_folder>\<folder_name>\`.
2. Usa `Copy-Item -Recurse` en PowerShell o `robocopy`.
3. Después de copiar, espera unos segundos y valida que la carpeta existe en el destino.
4. **Nota importante**: Drive para escritorio sincroniza en segundo plano. La carpeta aparecerá localmente de inmediato en `G:\`, pero la sincronización a la nube puede tardar unos segundos o minutos. Informale al usuario que la copia local ya terminó y que Drive la sincronizará automáticamente.
5. Muestra un resumen con:
   - Ruta de la carpeta creada localmente.
   - Lista de archivos que contiene.
   - Ruta destino en Drive.
   - Versión que se está desplegando.
6. **Invitá al usuario a revisar los archivos en Drive antes de seguir.** El Paso 11 es el primero que escribe en el remoto, así que este es el último momento para rehacer algo sin tener que revertir commits.

### Paso 11 — Commit y propagación de los archivos de versión

Este es el **último** paso del flujo, y el único que escribe en el remoto. Va al final a propósito: todo lo anterior es reversible borrando una carpeta, mientras que esto deja commits en tres ramas. Si al revisar los archivos en Drive aparece algo para corregir, todavía estás a tiempo de rehacer el deploy sin ensuciar el historial.

**Antes de ejecutar el script, pedí confirmación explícita:**

> Los artefactos ya están en Drive. Falta commitear los archivos de versión y propagarlos.
>
> - Commit en `<rama del deploy>`: `version.props` + `published-versions.props`
> - Backmerge: `<cadena de ramas>`
>
> ¿Reviso algo más antes, o propago?

Si el usuario quiere corregir algo, **no corras el script**: `version.props` queda modificado sin commitear en la rama del deploy, que es exactamente el estado desde el que puede rehacer el publish sin perder el bump.

```powershell
pwsh -ExecutionPolicy Bypass -File "$SKILL_BASE\scripts\propagate_versions.ps1" `
    -ConfigPath "$SKILL_BASE\config.json" `
    -Environment "<QA|PROD>" `
    -Version "<version o cadena vacía>" `
    -VersionsPropsPath "<versions_props_path del Paso 2.5>" `
    -PublishedVersionsPropsPath "<published_versions_props_path del Paso 2.5>"
```

El script hace internamente:

1. Valida que el repo esté parado en la rama del deploy (`staging` en QA, `master` en PROD). Si no, aborta sin commitear nada.
2. Stagea `version.props` y `published-versions.props`.
3. **Si no hay cambios en ninguno de los dos**, sale con `ok=true` y `committed=false` sin hacer commits vacíos ni merges. Es un caso raro pero contemplado.
4. Commitea con mensaje `chore(version): update version files after <version> deploy to <QA|PROD>`.
5. Pushea la rama del deploy. Si el push se rechaza, aborta **antes** de tocar las demás ramas.
6. Recorre `backmerge_chain` mergeando cada rama desde la anterior y pusheando:
   - QA: `staging` → `develop`
   - PROD: `master` → `staging` → `develop`
7. Vuelve a la rama del deploy.

Salida JSON:

```json
{
    "ok": true,
    "committed": true,
    "commit_sha": "a1b2c3d",
    "changed_files": ["version.props", "published-versions.props"],
    "propagated_branches": ["develop"],
    "steps": ["..."]
}
```

**Manejo del resultado:**

- `ok=true, committed=true` → mostrá al usuario qué ramas quedaron actualizadas. El deploy terminó.
- `ok=true, committed=false` → avisá que no hubo cambios de versión que propagar. El deploy terminó.
- `ok=false` → el deploy en sí ya está hecho: los artefactos están en Drive y son válidos. Lo que falló es la propagación en git. Mostrá el `error` y el array `steps` (que indica hasta dónde llegó) y decile al usuario qué le queda por resolver a mano. Un conflicto de merge en `develop` no invalida nada de lo que ya se subió.

Al terminar, mostrá el resumen final: versión desplegada, commit creado, y ramas que quedaron actualizadas.


## Manejo de errores

- Si el check de readiness falla con `working_directory.status="dirty"` → aborta y pide al usuario que haga commit/stash primero.
- Si el check de readiness falla con `local_sync.status="ahead"` → aborta y pide al usuario que haga `git push` antes de deployar.
- Si el check de readiness falla con `local_sync.status="diverged"` → aborta y pide al usuario que resuelva el merge/rebase antes de deployar.
- Si hay cambios sin propagar (`propagation[].has_changes = true`, es decir, archivos en `changed_files`) y el usuario no confirma explícitamente → aborta.
- Si `resolve_version_state.ps1` devuelve `validation.status="error"` → abortá antes de compilar: el publish sería rechazado por `ValidatePublishVersion`.
- Si `resolve_version_state.ps1` no encuentra `version.props` o `published-versions.props` → abortá indicando las rutas que probó; hay que corregir `config.version_files`.
- Si el usuario no confirma el número de versión propuesto → no escribas el archivo; pedile el número que quiere.
- Si el usuario propone una versión con sufijo (`-rc1`) o menor o igual al baseline de QA → rechazala y explicá por qué; el build fallaría igual.
- Si `dotnet publish` falla → muestra la última parte del output y aborta. Si hiciste bump, verificá que el script haya revertido `version.props` (`git status` debe estar limpio); si no, revertilo vos.
- Si `published_versions_changed=false` en un deploy a QA → avisá y pedí confirmación antes de seguir.
- Si falta el publish profile esperado → aborta indicando el path que esperaba.
- Si la detección de migraciones no encuentra scripts pasados del ambiente → aborta e informa.
- Si `dotnet ef migrations script` falla → muestra el error y aborta.
- Si la compresión falla o el zip queda vacío → aborta SIN borrar el build original.
- Si el usuario no confirma el Deploy.txt → no subas nada a Drive, deja todo en local para que pueda revisar manualmente. Tampoco corras la propagación de versiones.
- Si el usuario no confirma la propagación del Paso 11 → no corras el script y dejá `version.props` modificado sin commitear: es el estado desde el que puede rehacer el deploy conservando el bump.
- Si la propagación de versiones falla (`propagate_versions.ps1` con `ok=false`) → el deploy ya está completo; informá qué ramas quedaron sin actualizar y qué hay que resolver a mano.
- Si el push de la rama del deploy se rechaza porque alguien pusheó mientras corría el deploy → el commit queda local; avisale al usuario que haga `git pull --rebase` y vuelva a correr solo la propagación.

## Optimización de tokens

- Lee `config.json` una sola vez al inicio.
- NO cargues al contexto el contenido del build, del zip, ni del script.sql generado. Solo valida existencia y tamaño.
- NO leas `version.props` ni `published-versions.props` desde Claude: `resolve_version_state.ps1` te devuelve la versión actual, los baselines y la propuesta en un JSON chico. Solo abrí `version.props` para editarlo en el Paso 2.5.
- Para la lectura del último script.sql pasado, NO lo leas desde Claude — delegalo al script `detect_migration.ps1`, que internamente lee solo las últimas 200 líneas y retorna únicamente el JSON con la información necesaria.
- Prefiere ejecutar scripts PowerShell que hagan múltiples operaciones en una sola llamada, en lugar de muchos comandos bash separados.

## Chequeo de sintaxis (después de editar cualquier script)

Un error de parseo en un `.ps1` no se manifiesta como un fallo parcial: el script sale con exit 1 **sin emitir JSON**, y el paso que dependía de él se corta entero. Después de tocar cualquier script, corré:

```powershell
Get-ChildItem "$SKILL_BASE\scripts\*.ps1" | ForEach-Object {
    $e = $null
    [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$e)
    if ($e.Count) { "$($_.Name): $($e[0].Message)" }
}
```

Sin salida = todos parsean. El error más fácil de cometer en este código es `"texto $variable: más texto"` dentro de un string: PowerShell lee `$variable:` como un scope/drive y falla. Se arregla con `$($variable):`.
- No repitas información al usuario en cada paso; muestra progreso solo en hitos importantes (después del bump, después del publish, antes de confirmar Deploy.txt, después de la propagación, al finalizar).

## Detalle importante sobre paths en Windows

Todos los paths en `config.json` usan backslash escapado (`\\`) por ser JSON. Cuando los uses en comandos de PowerShell, no hace falta reescapar. Siempre envolvé los paths con espacios entre comillas dobles.
