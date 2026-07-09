---
name: review-pr
description: "Revisa pull requests en repositorios Azure DevOps, GitHub o GitLab usando solo git (sin CLIs ni APIs REST). Se invoca EXCLUSIVAMENTE con el slash command /review-pr seguido del ID del PR. Ejemplo: /review-pr 1234. La rama base contra la que se compara es `develop` por defecto, pero el usuario puede especificar `staging` o `master` en el prompt. NUNCA activar esta skill por contexto o inferencia — solo cuando el usuario escriba literalmente /review-pr. El PR se analiza sobre el repositorio del proyecto actual en la conversación de Claude Code."
---

# Review PR

Revisa un pull request (o merge request en GitLab) utilizando únicamente comandos git. No se usa ningún CLI ni API REST — todo se resuelve con git fetch y git diff.

## Invocación

Solo por slash command:
```
/review-pr <PR_ID> [<rama_base>]
```

Donde `<PR_ID>` es el número del pull request (o merge request en GitLab). Opcionalmente, el usuario puede mencionar en el prompt la rama base contra la que comparar (ver Paso 2 para las reglas de resolución).

## Contexto importante

Esta skill se ejecuta desde Claude Code, por lo tanto:
- Ya estás dentro del repositorio del proyecto.
- Git ya está configurado con las credenciales necesarias para acceder al remoto.
- No necesitas clonar nada, solo hacer fetch.
- Soporta repositorios en Azure DevOps, GitHub y GitLab.
- Las ramas base válidas son: `develop`, `staging`, `master`. Por defecto se compara contra `develop`.

## Reglas de escritura en disco

Esta skill **no debe dejar modificaciones persistentes en el proyecto**. Su única finalidad es revisar PRs.

- **Archivos temporales permitidos**: se puede crear un archivo diff en la raíz del proyecto (ej: `review-pr-<PR_ID>.diff`) para poder leerlo por partes y ahorrar tokens frente a cargarlo entero en contexto. **Debe borrarse al finalizar** (ver [Paso 6](#paso-6-limpieza)).
- **Ocultar el archivo de git**: antes de crearlo, registrar su nombre en `.git/info/exclude` para que no aparezca como untracked durante el análisis. Este archivo es el mecanismo oficial de git para exclusiones locales no versionadas (equivalente a un `.gitignore` personal que vive dentro de `.git/` y no se comparte). Existe en todo repo git desde su inicialización.

  ```bash
  TMP_DIFF="review-pr-<PR_ID>.diff"
  grep -qxF "$TMP_DIFF" .git/info/exclude || echo "$TMP_DIFF" >> .git/info/exclude
  ```

  La línea agregada no hace falta revertirla: apunta a un archivo que ya no existirá después del análisis. El `grep -qxF ... || echo ...` evita duplicar la línea si se ejecuta la skill varias veces.
- **No crear ni modificar** archivos en `.claude/`, `.vscode/`, `.idea/` ni cualquier otra carpeta de configuración del proyecto.
- **No ejecutar operaciones que alteren el repo**: nada de `git add`, `git commit`, `git push`, `git reset`, `git checkout` a ramas, `git merge`, etc. Solo son aceptables: `git remote`, `git fetch`, `git diff`, y la escritura a `.git/info/exclude` descrita arriba.

Si durante la ejecución Claude Code pide permisos para escribir algo fuera de los archivos listados aquí, esa es señal de que algo se está haciendo mal — revisar el procedimiento.

## Procedimiento

### Paso 1: Identificar el remoto y el proveedor

Ejecuta `git remote -v` para obtener la URL del remoto. Identifica el proveedor según la URL:

- **Azure DevOps**: contiene `dev.azure.com` o `visualstudio.com`
- **GitHub**: contiene `github.com`
- **GitLab**: contiene `gitlab.com` o `gitlab.` (para instancias self-hosted)

Si no coincide con ninguno, informa al usuario que la skill solo soporta Azure DevOps, GitHub y GitLab.

Guarda el proveedor detectado porque determina la ref a usar en el paso 3.

### Paso 2: Resolver la rama base del PR

Analizá el prompt del usuario que invocó la skill para detectar **menciones literales** de las ramas base válidas: `develop`, `staging`, `master`.

**Reglas de resolución:**

- **Ninguna mención** → rama base = `develop` (default).
- **Exactamente una mención** → rama base = esa rama.
- **Dos o más menciones distintas** → ambiguo. **Pedí aclaración al usuario** mostrándole las ramas detectadas y preguntando cuál es la rama destino del PR. Detené el procedimiento hasta tener respuesta clara (una sola de las tres ramas).

**Detección:** buscá las palabras `develop`, `staging`, `master` como tokens completos en el prompt (no como subcadenas de otras palabras). Variaciones aceptables: minúsculas, mayúsculas, entre comillas, con/sin preposición previa (`hacia master`, `vs staging`, `base: develop`).

**Ejemplos:**

| Prompt | Rama resuelta |
|---|---|
| `/review-pr 1234` | `develop` |
| `/review-pr 1234 hacia staging` | `staging` |
| `/review-pr 1234 vs master` | `master` |
| `/review-pr 1234 revisar el hotfix` | `develop` (ninguna mención literal) |
| `/review-pr 1234 es el merge de develop a master` | **ambiguo** → pedir aclaración |

**Importante:** una vez resuelta la rama base, **no preguntes al usuario para confirmar**. Seguí directo con el procedimiento. Solo se pregunta cuando hay ambigüedad.

Guardá el nombre de la rama base resuelta como `BASE_BRANCH`. Se usa en los pasos siguientes y se muestra explícitamente en el encabezado del reporte final (Paso 5) para que el usuario verifique que se comparó contra la rama correcta.

### Paso 3: Fetch de la rama base, fetch del PR, y diff

Cada proveedor expone los PRs como refs especiales con distinto formato. Hacé los fetch en este orden:

1. **Primero la rama base** resuelta en el Paso 2, para asegurar que la referencia local `origin/$BASE_BRANCH` esté actualizada.
2. **Después el PR**, usando la ref que corresponda al proveedor detectado en el Paso 1.

El orden importa porque el `git diff` siguiente usa `FETCH_HEAD`, que apunta al último fetch realizado — necesitamos que apunte al PR, no a la rama base.

```bash
# 1. Fetch de la rama base
git fetch origin "$BASE_BRANCH" --quiet

# 2. Fetch del PR (elegí según proveedor)
# Azure DevOps o GitHub:
git fetch origin "refs/pull/<PR_ID>/head"
# GitLab:
# git fetch origin "refs/merge-requests/<PR_ID>/head"

# 3. Diff del PR contra la rama base
git diff --stat "origin/$BASE_BRANCH...FETCH_HEAD"
```

El operador `...` calcula automáticamente el merge-base entre `origin/$BASE_BRANCH` y `FETCH_HEAD`, eliminando la necesidad de hacerlo manualmente.

**Manejo de fallos:**
- Si el fetch de la rama base falla → la rama resuelta no existe en el remoto. Informá al usuario y aborta.
- Si el fetch del PR falla → el PR probablemente no existe o no tenés permisos. Informá al usuario y aborta.

### Paso 4: Análisis del diff

Antes de presentar el reporte final, ejecuta los checks de calidad sobre el diff completo. Para evitar cargar el diff entero en contexto (costoso en tokens para PRs grandes), **persiste el diff en un archivo en la raíz del proyecto** y léelo por partes según lo necesite cada check.

Antes de crearlo, registrar su nombre en `.git/info/exclude` para que no aparezca como untracked durante el análisis:

```bash
TMP_DIFF="review-pr-<PR_ID>.diff"
grep -qxF "$TMP_DIFF" .git/info/exclude || echo "$TMP_DIFF" >> .git/info/exclude
git diff "origin/$BASE_BRANCH...FETCH_HEAD" > "$TMP_DIFF"
```

Sobre ese archivo corren los checks definidos más abajo en la sección [Checks de calidad](#checks-de-calidad). Cada check produce su propia sección del reporte. Si un check no encuentra hallazgos, esa sección se omite por completo del reporte.

**Recordatorio:** el archivo debe borrarse al final (ver [Paso 6](#paso-6-limpieza) y [Reglas de escritura en disco](#reglas-de-escritura-en-disco)).

**Alcance general de los checks:**
- Se analizan únicamente las **líneas añadidas o modificadas** en el PR (líneas que empiezan con `+` en el diff, excluyendo la cabecera `+++`). No se analiza código preexistente que el autor no tocó.
- Se **saltan archivos generados o vendored**: cualquier ruta que contenga `node_modules/`, `vendor/`, `dist/`, `build/`, `.min.`, `out/`, `target/`, migraciones autogeneradas (`migrations/` con timestamps), lockfiles (`package-lock.json`, `yarn.lock`, `composer.lock`, `*.lock`), o archivos bajo carpetas marcadas con `.gitattributes linguist-generated=true`.

### Paso 5: Presentar el reporte general

Arma un reporte con esta estructura:

1. **Encabezado**: ID del PR revisado y rama base contra la que se comparó. **Mostrá la rama base de forma explícita y visible** para que el usuario pueda detectar inmediatamente si se comparó contra la rama equivocada. Ejemplo de formato: `Reviewing PR #1234 against origin/develop`.
2. **Resumen estadístico**: la salida de `git diff --stat` (archivos modificados, inserciones, eliminaciones).
3. **Secciones de checks**: una por cada check que haya producido hallazgos, en el orden en que aparecen en la sección [Checks de calidad](#checks-de-calidad). Si un check no encontró nada, se omite.

Mantén el reporte **compacto**. No inventes datos — muestra exactamente lo que reporta git y lo que los checks detectaron.

### Paso 6: Limpieza

Una vez presentado el reporte, elimina el archivo temporal del diff:

```bash
rm -f "$TMP_DIFF"
```

Si por cualquier razón se crearon otros archivos temporales durante los checks, bórralos también aquí. La skill no debe dejar archivos residuales en el proyecto.

## Checks de calidad

Los checks se ejecutan sobre las líneas añadidas/modificadas del diff (ver Paso 4). Cada check define sus propias reglas y formato de salida dentro del reporte general.

### Check: Comentarios innecesarios

Evalúa los comentarios que el PR introduce o modifica. El principio rector: **un comentario solo se justifica cuando el código no se explica por sí mismo**. Si los nombres de variables, funciones y estructuras son suficientemente intuitivos, el comentario sobra.

**Idioma:** todos los comentarios deben estar en inglés. Cualquier comentario en otro idioma se reporta como innecesario bajo la categoría `non-english`, incluso si su contenido sería válido en inglés.

#### Categorías de comentarios innecesarios (se reportan)

| Categoría | Descripción |
|---|---|
| `decorative-delimiter` | Separadores visuales sobre código o HTML semánticamente claro (`// ===== SECCIÓN =====`, `<!-- HEADER -->` sobre un `<header>`, etc.) |
| `tautological` | Repite lo que el código ya dice (`// incrementa i` sobre `i++`, `// obtiene el usuario` sobre `getUser()`) |
| `commented-out-code` | Bloques de código comentado sin explicación de por qué se mantiene |
| `obsolete` | Describe comportamiento que el código actual ya no tiene |
| `inline-changelog` | Registros de modificaciones, fechas, tickets de cambio embebidos en el código (eso vive en git) |
| `empty-doc` | JSDoc / PHPDoc / TSDoc vacío, autogenerado o escueto que no aporta información real (descripciones, ejemplos, casos borde, excepciones). **También se reporta cualquier bloque de documentación fuera de controladores**, aunque su contenido sea rico: solo se permite documentación estructurada en archivos de controladores. |
| `orphan-todo` | `TODO` / `FIXME` sin dueño, sin ticket asociado, sin fecha o contexto accionable |
| `misplaced-signature` | Firma de autor/fecha fuera del inicio de una clase o función. Al inicio de clases o funciones **sí se permite** (aporta trazabilidad que `git blame` pierde ante renames/moves/refactors). |
| `non-english` | Comentario en idioma distinto al inglés |

#### Qué NO se reporta (comentarios legítimos)

Los siguientes casos se consideran válidos y **no aparecen en el reporte**:

- Explican el *por qué*, no el *qué* (razón de una decisión, contexto no obvio).
- Workarounds, `HACK`, bugs conocidos con explicación.
- Decisiones de negocio no evidentes desde el código.
- Regex complejos, fórmulas matemáticas, operaciones bitwise, algoritmos no triviales.
- Advertencias concretas al próximo desarrollador (orden de llamadas, precondiciones no obvias).
- Explicaciones de performance que justifican una elección de implementación.
- Aclaraciones sobre código que *parece* un bug pero no lo es (ej: `<=` intencional).
- Intención general en JS de vistas complejas donde la manipulación del DOM o flujo de eventos no es legible a simple vista.
- JSDoc/TSDoc **con contenido real** (descripciones, ejemplos, excepciones, casos borde) **únicamente en archivos de controladores**.
- Firma de autor/fecha **al inicio** de clases o funciones.
- Headers de licencia/copyright al inicio de archivos.
- Regiones de IDE (`#region`, `// #pragma mark`, `// MARK:`).
- Comentarios en archivos de configuración que justifican por qué una opción está activada.

#### Detección de controladores

Para decidir si `empty-doc` aplica o no a un bloque de documentación, el archivo se considera controlador si cumple alguna de estas señales:

- Ruta contiene `controllers/` o `Controllers/` (case-insensitive).
- Nombre del archivo termina en `Controller.{js,ts,cs,java,php,rb,py}` o equivalente.
- El archivo contiene decoradores/anotaciones de controlador: `@Controller`, `@RestController`, `@ApiController`, `[ApiController]`, `@Route`, `@ApiOperation`.

Si ninguna señal aplica, se asume que **no es controlador** y cualquier documentación estructurada ahí se reporta como `empty-doc` sin importar su riqueza de contenido.

#### Formato en el reporte

El check produce una sección titulada **Comentarios innecesarios**, agrupada por categoría. Dentro de cada categoría, se listan las ubicaciones una por línea:

```
### Comentarios innecesarios

**decorative-delimiter**
- src/views/user-form.html:12
- src/views/user-form.html:45

**tautological**
- src/services/auth.service.ts:23

**empty-doc**
- src/repositories/user.repository.ts:8 — JSDoc fuera de controlador
- src/controllers/order.controller.ts:15 — descripción vacía

**non-english**
- src/utils/date-helper.ts:4
```

Reglas de formato:
- Solo se incluyen comentarios problemáticos. Los correctos no aparecen.
- Las categorías vacías se omiten.
- Si el check completo no tiene hallazgos, la sección **Comentarios innecesarios** no aparece en el reporte.
- Una nota breve al final de cada entrada (tras `—`) solo cuando ayuda a entender por qué se marcó; si la categoría ya lo deja claro, se omite la nota.

### Check: Acceso a datos en la capa de aplicación

**Principio:** el acceso a datos debe estar **encapsulado en la capa de datos**,
nunca disperso por la aplicación. Ningún componente fuera de esa capa
(servicios, controllers, filtros, helpers) debe conocer ni tocar el ORM
directamente — su único punto de entrada a los datos es `IUnitOfWork`. Esto
mantiene la lógica de persistencia en un solo lugar, testeable y reemplazable.

Concretamente: el `CoreDbContext`, los `DbSet<>` y `SaveChanges` viven
exclusivamente en la capa de datos; los servicios dependen solo de
`IUnitOfWork` inyectado por constructor.

**Solo aplica a archivos `.cs`.**

#### Determinar la capa del archivo

Un archivo pertenece a la **capa de datos** (uso legítimo, se ignora) si su
ruta/nombre cumple alguna señal:
- la ruta contiene `/Data/`
- la ruta contiene `/Repositories/` o el archivo termina en `Repository.cs`
- el archivo es `UnitOfWork.cs` o termina en `DbContext.cs`

Cualquier otro `.cs` (servicios, controllers, filtros, helpers) es **capa de
aplicación**: ahí los primitivos de acceso a datos se reportan.

#### Señales que se reportan (capa de aplicación)

| Categoría | Patrón | Sugerencia |
|---|---|---|
| `dbcontext-dependency` | un tipo `*DbContext` como parámetro de constructor o campo | Inyectar `IUnitOfWork` en su lugar |
| `dbset-usage` | `DbSet<…>` | Acceder vía el repositorio del UoW |
| `savechanges` | `.SaveChanges(...)` / `.SaveChangesAsync(...)` | Persistir con `_unitOfWork.Save()` |

#### Qué NO se reporta (legítimo)

- `using Microsoft.EntityFrameworkCore;` por sí solo.
- `.Include(...)` / `.ThenInclude(...)`: los servicios arman include-expressions
  que le pasan al repositorio; es el patrón correcto.
- Cualquier acceso a través de `_unitOfWork` o un repositorio. En particular
  `_unitOfWork.Save()` es lo correcto — **no** confundir con `.SaveChanges()`.

#### Formato en el reporte

El check produce una sección titulada **Acceso a datos en la capa de
aplicación**. Por cada violación se lista la ubicación (`archivo:línea`), el
fragmento ofensor y una sugerencia. Ejemplo de salida:
```
### Acceso a datos en la capa de aplicación

**dbcontext-dependency**
- Modules/Truextend.Core/Services/ApplicantService.cs:13 — `CoreDbContext context` en el constructor → inyectar `IUnitOfWork`

**savechanges**
- Modules/Truextend.Core/Services/ApplicantService.cs:34 — `.SaveChanges()` → usar `_unitOfWork.Save()`
```

Si el check no encuentra hallazgos, la sección completa se omite del reporte.

### Check: Duplicación de modelos

**Principio:** antes de crear un modelo (entidad) nuevo o ampliar uno existente,
verificar que no se esté **recreando un dato que ya vive en otro modelo**. El
foco es estructural, no de validación fina: *¿hace falta este modelo, completa o
parcialmente, o se está duplicando uno que ya existe?* La duplicación se evalúa
por **concepto, no por nombre exacto** — dos propiedades pueden representar el
mismo dato con nombres distintos (`LinkedInProfile` vs `LinkedInUrl`).

**Solo aplica a archivos `.cs` en `/Models/`.** Se dispara cuando el PR agrega un
modelo nuevo o agrega propiedades a uno existente. Para comparar, lee los
modelos completos (la contraparte puede ser preexistente).

#### Cómo razona

- Toma las propiedades de dominio del modelo nuevo/modificado.
- Las compara contra las de los demás modelos buscando las que representen el
  **mismo concepto**: mismo nombre, o nombre similar (stem compartido) con tipo
  compatible. Aplica juicio para confirmar que es el mismo concepto antes de
  contarlo.
- Reporta el solapamiento si el modelo comparte **≥3 propiedades de dominio** o
  **≥50% de las suyas** con otro modelo (lo que se cumpla primero).
- No afirma "borrá el modelo" (puede tener razón de existir): plantea la pregunta
  de necesidad sobre los campos duplicados.

**Se ignoran** (ruido infraestructural): `Id`, claves foráneas (`*Id`),
propiedades de navegación, colecciones, y timestamps de auditoría (`CreatedAt`,
`UpdatedAt`, `LastUpdate`).

#### Formato en el reporte

Sección **Duplicación de modelos**. Por cada modelo con solapamiento, el modelo
contraparte, la lista de propiedades compartidas y la pregunta de necesidad.
Ejemplo:

```
### Duplicación de modelos

**Applicant** comparte 8 propiedades de dominio con **CandidateRequest**:
FullName, Email, PhonePrefix, PhoneNumber, LinkedInProfile, City, Country, Address
→ Evaluar si estos campos deben vivir en Applicant o si duplican datos de CandidateRequest.
```

Si no hay hallazgos, la sección se omite.

### Check: Consistencia modelo ↔ representación (DTO/ViewModel)

**Principio:** una propiedad de un DTO o ViewModel que **representa** una
propiedad de un modelo debe tener el **mismo nombre** y, **si declara
validaciones, las mismas validaciones**. No se exige que el DTO/VM valide: una
propiedad sin atributos es válida y no se reporta. Pero si valida, su validación
no puede divergir de la del modelo (ni más laxa, ni más estricta, ni renombrar
el concepto).

**Alcance:** modelos (`/Models/`) ↔ DTOs (`*Dto.cs`, `/DTOs/`) y ViewModels
(`*ViewModel.cs`, `/ViewModels/`). Disparado por el diff; lee los archivos
completos de ambos lados (la contraparte puede ser preexistente).

#### Cómo establece la correspondencia

- **`divergent-validation`**: propiedad homónima entre modelo y DTO/VM, o
  propiedades conectadas por un mapeo explícito.
- **`inconsistent-name`**: requiere **mapeo explícito** (AutoMapper
  `CreateMap<…>` o método de mapeo manual) que conecte dos propiedades de
  **nombre distinto**.

Antes de reportar, confirma por juicio que ambas propiedades representan el mismo
concepto (mismo tipo, concepto plausible). **No** marca colisiones casuales de
nombre (p. ej. un `Email` de filtro de búsqueda que no espeja la entidad).

#### Categorías que se reportan

| Categoría | Qué detecta |
|---|---|
| `divergent-validation` | la propiedad del DTO/VM **declara validaciones** que difieren de las del modelo (`[MaxLength]`, `[Required]`, `[EmailAddress]`, `[Url]`, `[Range]`…). Si el DTO/VM no declara validaciones para esa propiedad, no se reporta. |
| `inconsistent-name` | el mapeo conecta `Modelo.X` con `Dto.Y` de nombre distinto |

**Se ignoran** las mismas propiedades infraestructurales que en el check anterior
(`Id`, FKs, navegaciones, colecciones, auditoría).

#### Formato en el reporte

Sección **Consistencia modelo ↔ representación**, agrupada por categoría.
Ejemplo:

```
### Consistencia modelo ↔ representación

**divergent-validation**
- FullName — CandidateRequest: `MaxLength(250)` vs ApplicantProfileUpdateRequestDto / ApplicantRegisterRequestDto: `MaxLength(150)`
- Email — CandidateRequest: `[EmailAddress][MaxLength(250)]` vs ApplicantRegisterRequestDto: `[Required][EmailAddress][MaxLength(150)]`

**inconsistent-name**
- CandidateRequest.LinkedInProfile ↔ ApplicantProfileUpdateRequestDto.LinkedInUrl (conectadas por el mapper)
```

Si no hay hallazgos, la sección se omite.

### Check: Un tipo público por archivo

**Principio:** cada tipo público debe vivir en su **propio archivo, nombrado igual que el tipo**. Es la convención estándar de .NET (StyleCop `SA1402` / `SA1649`): descubribilidad por nombre, diffs e historial limpios, y una sola razón de cambio por archivo. Aplica a **todo el código C#**, no solo a DTOs/ViewModels — aunque ahí es donde más se viola y menos se justifica.

**Alcance:** archivos `.cs`, salvo autogenerados (migraciones, `*.Designer.cs`), ya excluidos por el skip global del Paso 4. Disparado por el diff: solo se evalúan archivos que el PR agregó o modificó.

#### Qué se reporta

Todo archivo que declara **más de un tipo público de primer nivel** (`class`, `record`, `struct`, `interface`, `enum`). Los tipos anidados o `internal` no cuentan: solo los `public` de primer nivel.

Un tipo subordinado a otro no justifica compartir archivo siendo público: si de verdad es subordinado debería ser `internal` o anidado (y entonces deja de contar); si tiene identidad propia, va en su propio archivo. En ambos casos el hallazgo es legítimo.

#### Formato en el reporte

Sección **Un tipo por archivo**, una entrada por archivo con los tipos que
declara y el arreglo sugerido. Ejemplo:

```
### Un tipo por archivo

- DTOs/ApplicantDtos.cs declara 4 tipos públicos: ApplicantRegisterRequestDto, ApplicantLoginRequestDto, ApplicantProfileResponseDto, ApplicantApplicationResponseDto → separar uno por archivo
- Common/ImportResult.cs declara 2 tipos públicos: ImportResult, ImportError → separar en archivos, o hacer ImportError internal/anidado si es subordinado
```

Si no hay hallazgos, la sección se omite.

### Check: Mapeo manual pudiendo usar el mapper

**Principio:** la conversión entre objetos (modelo ↔ DTO/ViewModel) se centraliza
en AutoMapper (`MappingProfile` + `IMapper`), no se escribe a mano. El mapeo
manual dispersa la lógica de conversión, se **desincroniza** al agregar
propiedades (se suma un campo al DTO y el copiado manual lo olvida), y duplica lo
que el mapper ya resuelve.

**Alcance:** archivos `.cs`, líneas añadidas/modificadas. Aplica en todo el
proyecto: `IMapper`/AutoMapper está disponible globalmente.

#### Qué se reporta

Mapeo manual objeto-a-objeto que el mapper debería cubrir, cuando copia **3 o
más** miembros desde un mismo objeto fuente de otro tipo (modelo/DTO/VM):

| Categoría | Qué detecta |
|---|---|
| `manual-object-init` | `new FooDto { A = src.A, B = src.B, … }` — inicializador que copia ≥3 miembros desde un mismo objeto fuente |
| `manual-assignments` | secuencia `dest.A = src.A; dest.B = src.B; …` (≥3) entre dos objetos de tipos distintos |
| `manual-mapping-method` | un método/extension dedicado a convertir (`ToDto()`, `ToViewModel()`, un `*MappingExtensions`) cuyo cuerpo es esencialmente lo anterior — AutoMapper debería ser el dueño |

#### Qué NO se reporta (filtro de juicio)

- **Actualizaciones parciales sobre entidades existentes/trackeadas** con
  semántica de preservar valor (`x.A = src.A?.Trim() ?? x.A`): es lógica de
  update con estado, no un map puro.
- Bloques donde **domina la transformación/lógica de negocio** por sobre la copia
  directa: el check apunta a las copias mayormente directas, no a fabricar
  `CreateMap` cargados de lógica.
- Construcción a partir de **escalares o variables locales**, no de otro objeto:
  no es un mapeo.
- Mapeos de menos de 3 miembros.

#### Formato en el reporte

Sección **Mapeo manual pudiendo usar el mapper**, agrupada por categoría, una
ubicación por línea con los tipos involucrados y la sugerencia. Cuando sea
posible, indicar si el `CreateMap<Src, Dest>` ya existe en `MappingProfile.cs` o
si hay que agregarlo. Ejemplo:

```
### Mapeo manual pudiendo usar el mapper

**manual-object-init**
- Services/PositionApplicantService.cs:88 — new ApplicantApplicationResponseDto { … } copia 6 miembros desde PositionApplicant → usar _mapper.Map<ApplicantApplicationResponseDto>(src) (ya existe CreateMap en MappingProfile)

**manual-mapping-method**
- Mapping/ApplicantMappingExtensions.cs:12 — ToProfileDto() replica el mapeo; mover a MappingProfile y usar IMapper
```

Si no hay hallazgos, la sección se omite.

## Manejo de errores

- Si el PR ID no es un número válido, pide al usuario que verifique.
- Si el fetch de la rama base falla, la rama resuelta (`develop`, `staging` o `master`) no existe en el remoto. Informa indicando cuál fue la rama base resuelta y aborta.
- Si el fetch del PR falla, puede ser que el PR no exista o que no tengas permisos para acceder al repositorio. Informa claramente.
- Si el remoto no corresponde a Azure DevOps, GitHub ni GitLab, indica que la skill no soporta ese proveedor.
- **Rama base ambigua en el prompt**: si se detectó más de una mención literal de las ramas válidas, no resolver automáticamente — pedir aclaración al usuario y detener el procedimiento hasta tener respuesta (ver Paso 2).

## Notas para evolución futura

Checks adicionales previstos (cada uno será una sección independiente del reporte general siguiendo el mismo patrón de "omitir si no hay hallazgos"):
- Nombres de variables y funciones poco descriptivos
- Funciones demasiado largas o con demasiada responsabilidad
- Código duplicado introducido por el PR
- Manejo de errores ausente o genérico
- Resumen ejecutivo del PR