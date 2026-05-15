---
name: pr-description
description: "Genera el título y la descripción de un pull request en inglés, basándose únicamente en los cambios de código (no en los mensajes de commit). La rama base contra la que se compara es `develop` por defecto, pero el usuario puede especificar `staging` o `master` en el prompt. Se invoca con el slash command /pr-description, o cuando el usuario pida explícitamente generar/redactar la descripción, el título o el mensaje de un PR, merge request, o pull request. Actívala siempre que el usuario mencione 'descripción de PR', 'título de PR', 'mensaje de PR', 'PR description', o pida ayuda para documentar un pull request sobre el repositorio actual de Claude Code."
---

# PR Description

Genera el título y la descripción de un pull request analizando el diff del branch actual contra la rama base correspondiente. La rama base se resuelve desde el prompt del usuario; por defecto es `develop`. Todo el contenido producido va en inglés.

## Invocación

- Slash command: `/pr-description`
- También cuando el usuario pida generar descripción, título o mensaje de un PR, pull request o merge request.

## Contexto de ejecución

Esta skill se ejecuta desde Claude Code, por lo tanto:
- Ya estás dentro del repositorio del proyecto.
- Git ya está configurado y la rama de trabajo está activa.
- Las ramas base válidas son: `develop`, `staging`, `master`. Por defecto se compara contra `develop`.

## Reglas inviolables

1. **Nunca leer mensajes de commit.** El análisis se basa exclusivamente en el contenido del diff (archivos cambiados y líneas añadidas/modificadas). Los mensajes de commit suelen ser ruidosos y no representan fielmente la intención del PR.
2. **Todo el output (título y descripción) va en inglés.** La conversación con el usuario puede ser en español.
3. **No dejar rastros.** El archivo temporal de diff debe borrarse al final del procedimiento (ver [Paso 8](#paso-8-limpieza)).
4. **No ejecutar operaciones destructivas.** Solo son aceptables: `git branch`, `git diff`, `git fetch` (para actualizar la referencia `origin/<base>`), y la escritura en `.git/info/exclude`. Nada de `git add`, `commit`, `push`, `reset`, `checkout`, `merge`, etc.

## Procedimiento

### Paso 0: Resolver la rama base del PR

Analizá el prompt del usuario que invocó la skill para detectar **menciones literales** de las ramas base válidas: `develop`, `staging`, `master`.

**Reglas de resolución:**

- **Ninguna mención** → rama base = `develop` (default).
- **Exactamente una mención** → rama base = esa rama.
- **Dos o más menciones distintas** → ambiguo. **Pedí aclaración al usuario** mostrándole las ramas detectadas y preguntando cuál es la rama destino del PR. Detené el procedimiento hasta tener respuesta clara (una sola de las tres ramas).

**Detección:** buscá las palabras `develop`, `staging`, `master` como tokens completos en el prompt (no como subcadenas de otras palabras). Variaciones aceptables: minúsculas, mayúsculas, entre comillas, con/sin preposición previa (`hacia master`, `vs staging`, `base: develop`).

**Ejemplos:**

| Prompt | Rama resuelta |
|---|---|
| `/pr-description` | `develop` |
| `/pr-description hacia staging` | `staging` |
| `/pr-description vs master` | `master` |
| `/pr-description el PR del hotfix de login` | `develop` (ninguna mención literal) |
| `/pr-description necesito describir el merge de develop a master` | **ambiguo** → pedir aclaración |
| `/pr-description tiene un cherry-pick de staging` | `staging` (una sola mención) |

**Importante:** una vez resuelta la rama base, **no preguntes al usuario para confirmar**. Seguí directo con el procedimiento. Solo se pregunta cuando hay ambigüedad.

Guarda el nombre de la rama base resuelta como `BASE_BRANCH`. Se usa en los pasos siguientes.

### Paso 1: Obtener el nombre de la rama actual

```bash
git branch --show-current
```

Guarda el nombre de la rama. Se usará para extraer el ticket-id y, en algunos casos, como prefijo del título.

### Paso 2: Extraer el ticket-id

Busca en el nombre de la rama la **primera secuencia de dígitos** que aparezca (sin importar qué prefijo de letras la acompañe).

- Si hay una secuencia de dígitos → el ticket-id es ese número, y se insertará en el prefijo del título como `TXW-<numero>`.
- Si no hay ninguna secuencia de dígitos → no hay ticket-id, y el prefijo del título será el nombre completo de la rama (ver Paso 5).

**Ejemplos:**
- `feature/TXW-1234-login` → ticket-id = `1234`
- `bug/ABC-999-fix-auth` → ticket-id = `999`
- `refactor/5678` → ticket-id = `5678`
- `hotfix-login` → sin ticket-id
- `update-readme` → sin ticket-id

### Paso 3: Preparar archivo temporal y volcar el diff

Se usa archivo temporal en la raíz del repo (no en memoria) para permitir leer el diff por rangos con `view` y evitar cargar PRs grandes enteros al contexto. Esto ahorra tokens cuando el diff es extenso.

Antes de crearlo, registrar su nombre en `.git/info/exclude` para que no aparezca como untracked durante el análisis. `.git/info/exclude` es el mecanismo oficial de git para exclusiones locales no versionadas — no se comparte al hacer push y no contamina el `.gitignore` del proyecto.

```bash
TMP_DIFF="pr-description.diff"
grep -qxF "$TMP_DIFF" .git/info/exclude || echo "$TMP_DIFF" >> .git/info/exclude
git fetch origin "$BASE_BRANCH" --quiet
git diff "origin/$BASE_BRANCH...HEAD" > "$TMP_DIFF"
```

**Por qué comparar contra `origin/<base>` y no contra la rama base local:**

Si el usuario hizo `git pull origin <base>` a su rama de trabajo (por ejemplo para resolver conflictos antes del PR), los commits de la rama base entran a la rama vía un commit de merge. Si comparáramos contra una rama base local desactualizada, esos commits aparecerían como "cambios del PR" aunque no los haya hecho el usuario.

Al actualizar la referencia `origin/<base>` con `git fetch origin <base>` y comparar contra ella:

- `git fetch` solo actualiza la referencia remota — no toca la rama base local, no hace checkout, no altera el working directory ni la rama actual. Es una operación de solo lectura desde el punto de vista del usuario.
- El operador `...` calcula el merge-base entre `origin/<base>` y `HEAD`. Los commits que vinieron del pull de la rama base quedan en el merge-base (porque están en `origin/<base>`) y **no** aparecen en el diff.
- Las resoluciones manuales de conflicto que el usuario escribió al mergear quedan dentro del commit de merge de su rama, que **no** está en `origin/<base>`, así que **sí** aparecen en el diff (correcto: son trabajo del usuario).
- Los commits originales de la rama **sí** aparecen.

Si el diff está vacío (archivo de 0 bytes), avisa al usuario que la rama no tiene cambios respecto a `origin/<base>` y termina (después de la limpieza del Paso 8). Este caso cubre tanto "estás parado en la rama base" como "tu rama está al día con la base sin commits propios".

### Paso 4: Analizar los cambios

Lee el archivo temporal por rangos con `view` según lo necesites. No lo cargues entero si es grande — empieza viendo la lista de archivos modificados (primeras líneas del diff) y luego profundiza en las partes relevantes.

**Análisis a realizar:**

#### 4.1 Identificar el tipo de trabajo (feature / bug / refactor)

Clasifica el PR en **una sola** de estas tres categorías basándote en lo que hacen los cambios:

- **`bug`**: los cambios arreglan comportamiento incorrecto. Señales: corrección de lógica rota, manejo de casos que antes fallaban o lanzaban excepciones, ajustes de condiciones mal evaluadas, parches a cálculos erróneos, fixes de regresiones.
- **`refactor`**: los cambios no añaden funcionalidad nueva ni arreglan bugs — solo mejoran estructura, legibilidad, organización o rendimiento del código sin cambiar comportamiento observable. Señales: extracción de funciones, renombrado, reorganización de archivos, simplificación de lógica equivalente, eliminación de duplicación.
- **`feature`**: todo lo demás. Funcionalidad nueva, extensiones de comportamiento, nuevas pantallas/endpoints/componentes, mejoras visibles.

Si el PR mezcla varios tipos, elige el que mejor represente el trabajo principal del PR. La descripción (no el prefijo) puede aclarar los matices.

#### 4.2 Identificar si el PR hace una o varias tareas

Agrupa los cambios por intención. Pregúntate: **¿todos los cambios sirven a un único objetivo coherente, o hay grupos de cambios que podrían describirse como tareas independientes?**

Ejemplos:
- PR que añade un endpoint nuevo, su servicio, su validación y sus tests → **una sola tarea** (todo sirve al mismo objetivo).
- PR que arregla un bug de login Y también añade un botón de exportar en otra pantalla Y actualiza un string de traducción → **varias tareas** (objetivos distintos, sin relación entre sí).

Si es **una sola tarea** → descripción en prosa (párrafos).
Si son **varias tareas** → descripción en viñetas, un punto por tarea.

#### 4.3 Evaluar si hay cambios significativos en la UI

El criterio rector: **¿vería el usuario/reviewer algo nuevo o distinto que le podría extrañar al abrir la app?**

**Sí amerita sugerir screenshots cuando:**
- Se añade una nueva sección, página, modal, vista o componente visible que antes no existía.
- Se rediseña o reestructura un área existente de forma que cambia cómo se percibe visualmente (ej: se reorganiza el layout de una página, se reemplaza un componente por otro distinto, se cambia la disposición de elementos).
- Se añaden o modifican estructuras con múltiples hijos/hermanos en HTML/JSX que se renderizan en pantalla.
- Se aplica un conjunto de estilos que afecta a una estructura visual amplia de forma notoria (ej: tema nuevo, sistema de espaciado nuevo aplicado a una sección entera).

**NO amerita screenshot cuando:**
- Ajustes menores de estilo: color, padding, margin, tamaño de fuente en elementos aislados.
- Cambios en textos, labels o traducciones.
- Refactors de CSS/clases que no alteran la apariencia final.
- Cambios en atributos invisibles (`aria-*`, `data-*`, `id`, `className` sin impacto visual).
- Correcciones pequeñas de markup que no cambian lo que el usuario ve.

El umbral no es cuantitativo (líneas cambiadas) sino cualitativo. Un refactor de estilos que no altera la apariencia final no amerita screenshot aunque toque 200 líneas; una sección nueva sí lo amerita aunque sean 40 líneas.

### Paso 5: Construir el título

**Estructura del título:**

```
<prefijo>: <resumen conciso en inglés>
```

**Prefijo:**

- Si hay ticket-id (del Paso 2): `<tipo>/TXW-<ticket-id>`
  - Donde `<tipo>` es `feature`, `bug` o `refactor` según el Paso 4.1.
  - Ejemplo: `feature/TXW-1234`, `bug/TXW-999`, `refactor/TXW-5678`.
- Si no hay ticket-id: el prefijo es el **nombre completo de la rama** tal cual.
  - Ejemplo: `hotfix-login`, `update-readme`.

**Resumen:**

- En inglés, imperativo, conciso (idealmente <70 caracteres).
- Describe el *qué* principal del PR, no el *cómo*.
- Si el PR hace varias tareas, el resumen debe capturar el tema general (ej: "Multiple improvements to auth flow") y los detalles van en la descripción.

**Ejemplos de título completo:**
- `feature/TXW-1234: Add CSV export to user reports`
- `bug/TXW-999: Fix session expiration not redirecting to login`
- `refactor/TXW-5678: Extract payment validation into dedicated service`
- `hotfix-login: Prevent null reference on empty credentials`

### Paso 6: Construir la descripción

Todo en inglés. Basado exclusivamente en los cambios del diff.

#### Principio rector: describí comportamiento, no implementación

La descripción debe **agregar valor sobre lo que el reviewer ya ve en el diff**. Hablá de **comportamientos, procesos, efectos y razones**; no de la mecánica del código. Si una oración puede verificarse trivialmente abriendo los archivos del PR, está de más.

**Heurística operativa.** Antes de escribir cada oración, preguntate:

1. **¿Esto se ve trivialmente en el diff?**
   - Si **no** se ve (cambios de comportamiento, flujos, efectos, vistas nuevas, razones) → incluilo.
   - Si **sí** se ve → preguntate si hay una forma de decirlo en términos de comportamiento o efecto. Si la hay → usá esa. Si no la hay → ver el punto 2.

2. **¿Esto le ahorra tiempo al reviewer o le cambia cómo lee el código?** Si sí, mantenelo aunque suene técnico. Si no, omitilo.

**Cuándo es aceptable ser técnico** (no hay que forzar abstracción artificial):

- **PR muy chico / cambio aislado** (típicamente config, constantes, un ajuste en un solo lugar). Forzar lenguaje comportamental sobre dos líneas de cambio suena inflado. Sé directo.
- **Refactors.** A menudo el contenido del PR *es* técnico. Mantenete al nivel de "qué componentes se reorganizaron y bajo qué criterio", **no** descender a "cambié esta variable por esta otra" o "renombré este método".
- **Cuando no hay material comportamental que describir.** En lugar de inflar con jerga, sé directo y breve.

**Anti-patrones a evitar siempre que se pueda** (especialmente en `feature` y `bug`):

- ❌ Mencionar nombres específicos de variables, métodos, clases, archivos.
- ❌ Mencionar la tecnología o librería usada para implementar algo ("uses regex", "via LINQ", "with Entity Framework").
- ❌ Frases tipo "added a variable / flag / property / field / struct / method called X".
- ❌ Describir estructuras de datos campo por campo.
- ❌ Mencionar el endpoint o ruta agregada (el reviewer lo encuentra fácil en el diff).

**Matiz por tipo de PR:**

- **`feature`**: la regla aplica fuerte. Casi siempre hay material comportamental que describir.
- **`bug`**: describí **qué estaba mal** (síntoma observable) y **cómo se comporta ahora** (corrección). Si la corrección introduce un comportamiento nuevo distinto, describilo en términos comportamentales también. Evitá los detalles técnicos del fix; el reviewer los ve en el diff.
- **`refactor`**: a menudo el tecnicismo es inevitable porque el cambio es estructural. Resumí los componentes refactorizados y el criterio, lo más abstracto que se pueda sin perder utilidad.

#### Ejemplos contrastivos

**Feature:**

❌ Demasiado técnico:
```
Added a `validateEmail` method to `UserService.cs` that uses regex to
check the format. Also added a new `EmailValidationException` class and
exposed a new POST /api/users/validate-email endpoint that returns 400
when the format is invalid.
```

✅ Comportamental:
```
Adds email format validation to user registration. Users now receive a
clear error message before submission instead of seeing the request fail
silently downstream.
```

**Bug:**

❌ Demasiado técnico:
```
Fixed a null reference exception in `LoginController.HandleAsync` by
adding a null check on the `refreshToken` parameter before calling
`tokenService.Validate()`.
```

✅ Comportamental:
```
Fixes a crash that occurred when users tried to log in with an expired
session whose refresh token had already been cleared. The login flow now
redirects to the login page instead of returning a 500 error.
```

**Refactor (caso donde el tecnicismo es razonable):**

✅ Aceptable:
```
Extracts payment validation logic out of the order processing service
into its own dedicated component. The new component groups previously
scattered validation rules under a single entry point, making it easier
to add new payment providers without touching order processing.
```

(Notá que no menciona nombres de clases específicas ni archivos — habla de "payment validation logic" y "order processing service" como conceptos. Esto está bien para refactor.)

**PR chico (config / cambio aislado):**

✅ Aceptable ser directo:
```
Enables Information-level logging for the application by configuring
the Logging section in the environment settings.
```

(Acá forzar una descripción puramente comportamental sería artificial. La descripción menciona el nivel concreto porque es información útil que no es trivial inferir.)

#### Caso A: una sola tarea

Descripción en **prosa** (uno o dos párrafos breves). Explica:
1. Qué hace el PR (el objetivo principal, en términos comportamentales).
2. Si hace falta, un segundo párrafo con detalles relevantes que el reviewer debería saber sobre el comportamiento, no sobre la implementación (ej: cambio en el flujo de X, side effect en Y, restricción nueva sobre Z).

No uses viñetas en este caso.

**Ejemplo:**
```
Adds a CSV export option to the user reports page. Users can now
download filtered report data directly from the toolbar, bypassing
the need to copy rows manually.

The export respects the active filters and date range, and is
generated server-side to handle large datasets without blocking
the UI.
```

#### Caso B: varias tareas no relacionadas

Descripción en **viñetas**, un punto por tarea. Cada punto debe ser autocontenido y describir esa tarea completa **en términos comportamentales**.

**Ejemplo:**
```
- Fix session expiration not redirecting to the login page when the
  refresh token is invalid.
- Add an export button to the reports toolbar that downloads the
  current view as CSV.
- Update the Spanish translation for the "Pending approval" label.
```

#### Nota sobre screenshots

Si en el Paso 4.3 se determinó que hay cambios significativos en UI, añade al final de la descripción (después de la prosa o las viñetas) una línea separadora y una nota breve:

```

---
**Screenshots:** please attach screenshots of the updated [sección/pantalla afectada] so reviewers can verify the visual changes.
```

Reemplaza `[sección/pantalla afectada]` con una mención específica a lo que cambió visualmente (ej: "reports page", "new settings modal", "sidebar navigation").

Si no hay cambios significativos en UI, no se añade esta sección.

### Paso 7: Presentar el output en el chat

Presenta título y descripción en el chat, en un formato claro y fácil de copiar. Usa bloques de código para cada uno, separando título de descripción:

```
**Title:**
` ` `
<título generado>
` ` `

**Description:**
` ` `
<descripción generada>
` ` `
```

(Sin espacios entre los backticks — aquí se muestran así solo para documentación.)

No agregues comentarios extra ni explicaciones del análisis, a menos que el usuario pregunte. El output debe ser directo y copy-paste ready.

### Paso 8: Limpieza

Después de presentar el output, borra el archivo temporal:

```bash
rm -f "$TMP_DIFF"
```

La línea agregada a `.git/info/exclude` no hace falta revertirla: apunta a un archivo que ya no existe y no afecta el comportamiento de git. Si se ejecuta la skill de nuevo, el `grep -qxF ... || echo ...` del Paso 3 evita duplicar la entrada.

## Manejo de errores

- **No se está en un repo git** (`git branch --show-current` falla): informa al usuario que la skill debe ejecutarse dentro de un repositorio.
- **No existe el remoto `origin` o la rama base resuelta en el remoto** (`git fetch origin <base>` falla): informa al usuario indicando cuál fue la rama base resuelta. Esta skill asume que el repositorio tiene un remoto `origin` con la rama base disponible.
- **Diff vacío**: la rama no tiene cambios respecto a `origin/<base>`. Informa y termina (tras limpieza). Este caso también cubre el escenario "estás parado en la rama base".
- **Rama base ambigua en el prompt**: si se detectó más de una mención literal de las ramas válidas, no resolver automáticamente — pedir aclaración al usuario y detener el procedimiento hasta tener respuesta (ver Paso 0).

## Recordatorios finales

- Nunca basarse en los mensajes de commit.
- Todo el contenido generado (título y descripción) va en inglés.
- Archivo temporal siempre se borra al final.
- El tipo (`feature`/`bug`/`refactor`) lo decide el análisis del diff, no el nombre de la rama.
