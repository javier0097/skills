---
name: pr-description
description: "Genera el título y la descripción de un pull request en inglés, basándose únicamente en los cambios de código respecto a master (no en los mensajes de commit). Se invoca con el slash command /pr-description, o cuando el usuario pida explícitamente generar/redactar la descripción, el título o el mensaje de un PR, merge request, o pull request. Actívala siempre que el usuario mencione 'descripción de PR', 'título de PR', 'mensaje de PR', 'PR description', o pida ayuda para documentar un pull request sobre el repositorio actual de Claude Code."
---

# PR Description

Genera el título y la descripción de un pull request analizando el diff del branch actual contra `master`. Todo el contenido producido va en inglés.

## Invocación

- Slash command: `/pr-description`
- También cuando el usuario pida generar descripción, título o mensaje de un PR, pull request o merge request.

## Contexto de ejecución

Esta skill se ejecuta desde Claude Code, por lo tanto:
- Ya estás dentro del repositorio del proyecto.
- Git ya está configurado y la rama de trabajo está activa.
- La rama base contra la que se compara es siempre `master`.

## Reglas inviolables

1. **Nunca leer mensajes de commit.** El análisis se basa exclusivamente en el contenido del diff (archivos cambiados y líneas añadidas/modificadas). Los mensajes de commit suelen ser ruidosos y no representan fielmente la intención del PR.
2. **Todo el output (título y descripción) va en inglés.** La conversación con el usuario puede ser en español.
3. **No dejar rastros.** El archivo temporal de diff debe borrarse al final del procedimiento (ver [Paso 6](#paso-6-limpieza)).
4. **No ejecutar operaciones destructivas.** Solo son aceptables: `git branch`, `git diff`, `git fetch` (para actualizar la referencia `origin/master`), y la escritura en `.git/info/exclude`. Nada de `git add`, `commit`, `push`, `reset`, `checkout`, `merge`, etc.

## Procedimiento

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
git fetch origin master --quiet
git diff origin/master...HEAD > "$TMP_DIFF"
```

**Por qué comparar contra `origin/master` y no contra `master` local:**

Si el usuario hizo `git pull origin master` a su rama de trabajo (por ejemplo para resolver conflictos antes del PR), los commits de master entran a la rama vía un commit de merge. Si comparáramos contra un `master` local desactualizado, esos commits aparecerían como "cambios del PR" aunque no los haya hecho el usuario.

Al actualizar la referencia `origin/master` con `git fetch origin master` y comparar contra ella:

- `git fetch` solo actualiza la referencia remota — no toca el `master` local, no hace checkout, no altera el working directory ni la rama actual. Es una operación de solo lectura desde el punto de vista del usuario.
- El operador `...` calcula el merge-base entre `origin/master` y `HEAD`. Los commits que vinieron del pull de master quedan en el merge-base (porque están en `origin/master`) y **no** aparecen en el diff.
- Las resoluciones manuales de conflicto que el usuario escribió al mergear quedan dentro del commit de merge de su rama, que **no** está en `origin/master`, así que **sí** aparecen en el diff (correcto: son trabajo del usuario).
- Los commits originales de la rama **sí** aparecen.

Si el diff está vacío (archivo de 0 bytes), avisa al usuario que la rama no tiene cambios respecto a master y termina (después de la limpieza del Paso 6).

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

#### Caso A: una sola tarea

Descripción en **prosa** (uno o dos párrafos breves). Explica:
1. Qué hace el PR (el objetivo principal).
2. Si hace falta, un segundo párrafo con detalles relevantes que el reviewer debería saber (ej: nuevo endpoint expuesto, cambio en el flujo de X, etc.).

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

Descripción en **viñetas**, un punto por tarea. Cada punto debe ser autocontenido y describir esa tarea completa.

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
- **No existe el remoto `origin` o la rama `master` en el remoto** (`git fetch origin master` falla): informa al usuario. Esta skill asume que el repositorio tiene un remoto `origin` con una rama `master`.
- **La rama actual es `master`**: informa al usuario que no tiene sentido generar una descripción de PR sobre la rama base.
- **Diff vacío**: la rama no tiene cambios respecto a `origin/master`. Informa y termina (tras limpieza).

## Recordatorios finales

- Nunca basarse en los mensajes de commit.
- Todo el contenido generado (título y descripción) va en inglés.
- Archivo temporal siempre se borra al final.
- El tipo (`feature`/`bug`/`refactor`) lo decide el análisis del diff, no el nombre de la rama.
