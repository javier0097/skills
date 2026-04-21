---
name: TXW-deploy
description: Automatiza la preparación de artefactos para deploys del proyecto TruextendWebsite a los ambientes QA y PROD. Usá esta skill cuando el usuario mencione hacer un deploy, preparar un deploy, generar artefactos de deploy, armar carpeta de deploy, o cuando invoque /TXW-deploy. Típicamente el usuario dirá algo como 'hacer deploy a QA', 'preparar deploy a PROD con recipe', 'generar artefactos para deploy QA con cambios en X', etc. La skill hace git pull, corre el publish, limpia el build, detecta si necesita script SQL comparando migraciones, arma la carpeta YYYYMMDD-(QA|PROD)[-N] con todos los artefactos, y la sube a la carpeta compartida de Google Drive. Requiere correr desde Claude Code con el working directory en la raíz del repositorio del proyecto.
---

# TXW-deploy

Skill para preparar y subir artefactos de deploy del proyecto **TruextendWebsite** a la carpeta compartida de Google Drive del equipo de IT.

## Configuración

Toda la configuración (rutas, nombres de proyecto, constantes de ambiente) está en `config.json` en la raíz de esta skill. **Lee `config.json` al inicio de cada invocación** y usa esos valores en lugar de hardcodearlos.

## Paso 0 — Resolución del base path de la skill (OBLIGATORIO primero)

**Antes de ejecutar cualquier otro paso**, identifica el path absoluto donde está instalada esta skill y guárdalo como `$SKILL_BASE`. Este path es necesario para invocar los scripts bundleados de forma confiable.

Formas de obtenerlo, en orden de preferencia:

1. Si Claude Code te proporcionó el base path al cargar la skill, usalo.
2. Si no, buscá la skill en ubicaciones conocidas (Windows):
   - `C:\Users\<usuario>\.claude\skills\TXW-deploy\`
   - `C:\Users\<usuario>\.claude\plugins\...\skills\TXW-deploy\` (si está instalada como plugin)

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
3. **Instrucciones especiales**: cualquier texto que describa una modificación no estándar al Deploy.txt (ej: "agregar X al appsettings").

**NUNCA pidas al usuario si debe haber script SQL** — eso se detecta automáticamente comparando migraciones.

## Flujo de ejecución

Sigue este orden estrictamente. Valida el éxito de cada paso antes de avanzar al siguiente. Si algo falla, aborta e informa claramente qué pasó.

### Paso 1 — Pre-flight

1. Lee `"$SKILL_BASE\config.json"`.
2. Parsea el prompt del usuario para extraer: `environment` (QA/PROD), `has_recipe` (bool), `special_instructions` (string libre o null).
3. Si falta el ambiente, pídelo con una sola pregunta y detente hasta tener respuesta.
4. Valida git status con el siguiente comando, **pasando explícitamente el whitelist como parámetro** (construilo a partir de `config.json[git_status_whitelist]`):

   ```powershell
   pwsh -ExecutionPolicy Bypass -File "$SKILL_BASE\scripts\check_git_status.ps1" -Whitelist "appsettings.Development.json"
   ```

   Si el whitelist tuviera más de un archivo, pasá `-Whitelist "a.json","b.json"` (separados por coma, sin espacios).

   Si el script retorna exit code 1 ("DIRTY"), aborta mostrando qué archivos tienen cambios sin commitear.

5. Determina el publish profile correspondiente según `config.json[publish_profiles]`:
   - `QA` → `FolderProfile.QA`
   - `PROD` → `FolderProfile`

6. Calculá la fecha actual en formato `YYYYMMDD` (zona horaria local de la laptop).

### Paso 2 — Git

Ejecuta en el working directory (que es la raíz del proyecto):

```powershell
git checkout master
git pull
```

Si alguno falla, aborta.

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
    -ZipName "<zip_name>"
```

El script hace internamente:

1. **Publish**: `dotnet publish <startup> -p:PublishProfile=<profile> --configuration Release`.
2. **Valida** que el build se generó correctamente.
3. **Limpieza del build**:
   - Borra `App_Data/tenants.json` (si existe; si no, warning pero no aborta).
   - Vacía el contenido de `App_Data/Sites/Default/` (borra todos los archivos y subcarpetas adentro, pero mantiene la carpeta `Default`).
4. **Crea** la carpeta de deploy con el nombre calculado.
5. **Comprime** el contenido del build a `<zip_name>` DENTRO de la carpeta de deploy.
6. **Valida** que el zip existe y tiene tamaño > 0. Si falla, aborta SIN borrar el build original.
7. Solo si el zip es válido, **borra la carpeta original del build**.

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

   Valida que `script.sql` se generó y no está vacío.

4. Si `needs_script=false`, no hagas nada en este paso y continúa.

### Paso 8 — Generación del Deploy.txt

1. Elige el template según ambiente y si hay script:
   - QA sin script → `"$SKILL_BASE\templates\deploy_qa_build_only.txt"`
   - QA con script → `"$SKILL_BASE\templates\deploy_qa_with_script.txt"`
   - PROD sin script → `"$SKILL_BASE\templates\deploy_prod_build_only.txt"`
   - PROD con script → `"$SKILL_BASE\templates\deploy_prod_with_script.txt"`
2. Los templates tienen placeholder `{{ZIP_NAME}}`. Reemplázalo por el `zip_name` calculado en el Paso 3.
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
5. Muestra un resumen final con:
   - Ruta de la carpeta creada localmente.
   - Lista de archivos que contiene.
   - Ruta destino en Drive.

## Manejo de errores

- Si `git status` tiene cambios fuera del whitelist → aborta y pide al usuario que haga commit/stash primero.
- Si `dotnet publish` falla → muestra la última parte del output y aborta.
- Si falta el publish profile esperado → aborta indicando el path que esperaba.
- Si la detección de migraciones no encuentra scripts pasados del ambiente → aborta e informa.
- Si `dotnet ef migrations script` falla → muestra el error y aborta.
- Si la compresión falla o el zip queda vacío → aborta SIN borrar el build original.
- Si el usuario no confirma el Deploy.txt → no subas nada a Drive, deja todo en local para que pueda revisar manualmente.

## Optimización de tokens

- Lee `config.json` una sola vez al inicio.
- NO cargues al contexto el contenido del build, del zip, ni del script.sql generado. Solo valida existencia y tamaño.
- Para la lectura del último script.sql pasado, NO lo leas desde Claude — delegalo al script `detect_migration.ps1`, que internamente lee solo las últimas 200 líneas y retorna únicamente el JSON con la información necesaria.
- Prefiere ejecutar scripts PowerShell que hagan múltiples operaciones en una sola llamada, en lugar de muchos comandos bash separados.
- No repitas información al usuario en cada paso; muestra progreso solo en hitos importantes (después del publish, antes de confirmar Deploy.txt, al finalizar).

## Detalle importante sobre paths en Windows

Todos los paths en `config.json` usan backslash escapado (`\\`) por ser JSON. Cuando los uses en comandos de PowerShell, no hace falta reescapar. Siempre envolvé los paths con espacios entre comillas dobles.
