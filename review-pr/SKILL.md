---
name: review-pr
description: "Revisa pull requests en repositorios Azure DevOps, GitHub o GitLab usando solo git (sin CLIs ni APIs REST). Se invoca EXCLUSIVAMENTE con el slash command /review-pr seguido del ID del PR. Ejemplo: /review-pr 1234. NUNCA activar esta skill por contexto o inferencia — solo cuando el usuario escriba literalmente /review-pr. El PR se analiza sobre el repositorio del proyecto actual en la conversación de Claude Code."
---

# Review PR

Revisa un pull request (o merge request en GitLab) utilizando únicamente comandos git. No se usa ningún CLI ni API REST — todo se resuelve con git fetch y git diff.

## Invocación

Solo por slash command:
```
/review-pr <PR_ID>
```

Donde `<PR_ID>` es el número del pull request (o merge request en GitLab).

## Contexto importante

Esta skill se ejecuta desde Claude Code, por lo tanto:
- Ya estás dentro del repositorio del proyecto.
- Git ya está configurado con las credenciales necesarias para acceder al remoto.
- No necesitas clonar nada, solo hacer fetch.
- Soporta repositorios en Azure DevOps, GitHub y GitLab.

## Procedimiento

### Paso 1: Identificar el remoto y el proveedor

Ejecuta `git remote -v` para obtener la URL del remoto. Identifica el proveedor según la URL:

- **Azure DevOps**: contiene `dev.azure.com` o `visualstudio.com`
- **GitHub**: contiene `github.com`
- **GitLab**: contiene `gitlab.com` o `gitlab.` (para instancias self-hosted)

Si no coincide con ninguno, informa al usuario que la skill solo soporta Azure DevOps, GitHub y GitLab.

Guarda el proveedor detectado porque determina la ref a usar en el paso 3.

### Paso 2: Obtener la rama principal del repositorio

Git local no tiene concepto de "rama principal" — eso lo define el servidor remoto. Para consultarla, ejecuta:

```bash
git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||'
```

Si no devuelve resultado (puede pasar si el repo se inició con `git init` + `git remote add` en lugar de `git clone`), crea la referencia consultando directamente al servidor:

```bash
git remote set-head origin --auto
```

Y luego vuelve a ejecutar el primer comando. Si aún así falla, informa al usuario que no se pudo determinar la rama principal del remoto.

Guarda el nombre de esa rama (ej: `main`, `master`, `develop`, etc.) para usarla en el paso siguiente.

### Paso 3: Fetch del PR y diff en dos comandos

Cada proveedor expone los PRs como refs especiales con distinto formato. Haz fetch usando la ref que corresponda al proveedor detectado en el paso 1:

- **Azure DevOps o GitHub**: `git fetch origin refs/pull/<PR_ID>/head`
- **GitLab**: `git fetch origin refs/merge-requests/<PR_ID>/head`

Luego compara contra la rama principal usando el operador triple-punto (`...`), que calcula el merge-base automáticamente:

```bash
git diff --stat origin/<RAMA_PRINCIPAL>...FETCH_HEAD
```

`FETCH_HEAD` apunta automáticamente a lo que acabas de descargar, así que no necesitas crear refs locales. El operador `...` se encarga de encontrar el ancestro común, eliminando la necesidad de calcular el merge-base manualmente.

Si el fetch falla, el PR probablemente no existe o no tienes permisos para acceder al repositorio. Informa al usuario.

### Paso 4: Análisis del diff

Antes de presentar el reporte final, ejecuta los checks de calidad sobre el diff completo:

```bash
git diff origin/<RAMA_PRINCIPAL>...FETCH_HEAD
```

Sobre esa salida corren los checks definidos más abajo en la sección [Checks de calidad](#checks-de-calidad). Cada check produce su propia sección del reporte. Si un check no encuentra hallazgos, esa sección se omite por completo del reporte.

**Alcance general de los checks:**
- Se analizan únicamente las **líneas añadidas o modificadas** en el PR (líneas que empiezan con `+` en el diff, excluyendo la cabecera `+++`). No se analiza código preexistente que el autor no tocó.
- Se **saltan archivos generados o vendored**: cualquier ruta que contenga `node_modules/`, `vendor/`, `dist/`, `build/`, `.min.`, `out/`, `target/`, migraciones autogeneradas (`migrations/` con timestamps), lockfiles (`package-lock.json`, `yarn.lock`, `composer.lock`, `*.lock`), o archivos bajo carpetas marcadas con `.gitattributes linguist-generated=true`.

### Paso 5: Presentar el reporte general

Arma un reporte con esta estructura:

1. **Encabezado**: ID del PR revisado y rama principal contra la que se comparó.
2. **Resumen estadístico**: la salida de `git diff --stat` (archivos modificados, inserciones, eliminaciones).
3. **Secciones de checks**: una por cada check que haya producido hallazgos, en el orden en que aparecen en la sección [Checks de calidad](#checks-de-calidad). Si un check no encontró nada, se omite.

Mantén el reporte **compacto**. No inventes datos — muestra exactamente lo que reporta git y lo que los checks detectaron.

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

## Manejo de errores

- Si el PR ID no es un número válido, pide al usuario que verifique.
- Si el fetch falla, puede ser que el PR no exista o que no tengas permisos para acceder al repositorio. Informa claramente.
- Si el remoto no corresponde a Azure DevOps, GitHub ni GitLab, indica que la skill no soporta ese proveedor.

## Notas para evolución futura

Checks adicionales previstos (cada uno será una sección independiente del reporte general siguiendo el mismo patrón de "omitir si no hay hallazgos"):
- Nombres de variables y funciones poco descriptivos
- Funciones demasiado largas o con demasiada responsabilidad
- Código duplicado introducido por el PR
- Manejo de errores ausente o genérico
- Resumen ejecutivo del PR
