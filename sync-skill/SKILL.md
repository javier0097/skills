---
name: sync-skill
description: Sincroniza una skill personal desde Claude hacia un repositorio git local. Se invoca exclusivamente con /sync-skill seguido del nombre de la skill. Compara la skill cacheada en el sistema con su copia en el repo local, crea una rama, aplica los cambios y hace push. Usa esta skill cuando el usuario quiera sincronizar, actualizar, respaldar o bajar una skill a su repositorio local de skills.
---

# Sync Skill

Sincroniza una skill personal desde Claude hacia el repositorio local de skills. Esta skill está diseñada para ejecutarse exclusivamente desde Claude Code, donde la carpeta del proyecto es el repositorio local de skills.

## Invocación

```
/sync-skill <nombre-skill>
```

El argumento `<nombre-skill>` es el nombre exacto de la carpeta de la skill tal como aparece en Claude (por ejemplo: `saludo`, `conversor-bolivia`, `prueba`).

## Flujo completo

Sigue estos pasos en orden. Si alguna validación falla, detente, informa al usuario y no ejecutes nada más.

### Paso 1: Validar el repositorio local

Verifica que la carpeta de trabajo actual (el proyecto de Claude Code) cumple dos condiciones:

1. El nombre de la carpeta es `skills` — esto confirma que el proyecto apunta al repositorio correcto.
2. Existe un directorio `.git/` en la raíz — esto confirma que es un repositorio git.

Si alguna de estas condiciones no se cumple, informa al usuario con un mensaje claro indicando qué condición falló y no hagas nada más.

### Paso 2: Verificar estado limpio del repo

Ejecuta `git status --porcelain` en la carpeta del proyecto. Si hay cualquier cambio sin commitear (archivos modificados, staged, o untracked que no estén en .gitignore), informa al usuario que el repositorio tiene cambios pendientes y detente sin hacer nada.

### Paso 3: Localizar la skill fuente en el caché de Claude

Las skills instaladas en Claude se cachean localmente en el sistema. Para encontrar la skill fuente, busca dinámicamente en la ruta de caché de Claude:

```bash
find "$APPDATA/Claude/local-agent-mode-sessions/skills-plugin" -type d -name "<nombre-skill>" 2>/dev/null
```

Donde `$APPDATA` es la variable de entorno de Windows que apunta a `AppData/Roaming`.

Si el `find` devuelve múltiples resultados (varias sesiones pueden cachear la misma skill), selecciona la más reciente comparando la fecha de modificación del archivo `SKILL.md` dentro de cada resultado:

```bash
find "$APPDATA/Claude/local-agent-mode-sessions/skills-plugin" -path "*/<nombre-skill>/SKILL.md" -printf '%T@ %h\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2
```

Si no se encuentra ningún resultado, informa al usuario que la skill no fue encontrada en el caché de Claude y detente.

Guarda la ruta encontrada en una variable (la llamaremos `SKILL_SOURCE` en los pasos siguientes).

### Paso 4: Determinar si es creación o actualización

Revisa si existe la carpeta `<nombre-skill>/` en la raíz del repositorio local:

- Si **no existe** → es una skill nueva (creación).
- Si **existe** → compara recursivamente todo el contenido de la carpeta local contra `SKILL_SOURCE`. Usa `diff -r` para esto. Si no hay diferencias, informa al usuario que la skill ya está sincronizada y detente.

### Paso 5: Crear la rama de trabajo

Asegúrate de estar en la rama `master` antes de crear la nueva rama:

```bash
git checkout master
git pull origin master
```

Genera el nombre de la rama con el formato:

```
sync/<nombre-skill>/<fecha-YYYY-MM-DD>
```

Por ejemplo: `sync/conversor-bolivia/2026-04-12`.

Si la rama ya existe, agrega un sufijo incremental: `sync/conversor-bolivia/2026-04-12-2`, `sync/conversor-bolivia/2026-04-12-3`, etc.

Crea la rama y posiciónate en ella:

```bash
git checkout -b sync/<nombre-skill>/<fecha>
```

### Paso 6: Aplicar los cambios

**Si es una skill nueva:** copia toda la carpeta de la skill desde el caché al repositorio local.

```bash
cp -r "$SKILL_SOURCE" ./<nombre-skill>
```

**Si es una actualización:** reemplaza todo el contenido de la carpeta local con el del caché. Elimina primero el contenido local para cubrir el caso donde se hayan eliminado archivos en la fuente.

```bash
rm -rf ./<nombre-skill>
cp -r "$SKILL_SOURCE" ./<nombre-skill>
```

### Paso 7: Commit

Haz stage de todos los cambios y crea el commit. El mensaje siempre empieza con `sync/<nombre-skill>:` seguido de una oración corta que resuma los cambios reales.

Para generar la descripción:

- **Skill nueva:** lee brevemente el SKILL.md para entender el propósito de la skill y descríbelo. Ejemplo: `sync/conversor-bolivia: add skill for bolivian unit conversions`
- **Actualización:** usa la salida del `diff -r` del paso 4 para resumir qué archivos cambiaron y la naturaleza del cambio en una oración. Ejemplo: `sync/saludo: update greeting message and add fallback response`

```bash
git add ./<nombre-skill>
git commit -m "sync/<nombre-skill>: <descripcion-generada>"
```

### Paso 8: Push

Sube la rama al repositorio remoto. Usa el nombre exacto de la rama creada en el paso 5, incluyendo el sufijo incremental si fue necesario:

```bash
git push origin <nombre-exacto-de-la-rama>
```

### Paso 9: Resultado

Informa al usuario con un resumen:

- Nombre de la skill sincronizada
- Tipo de operación (nueva o actualización)
- Nombre de la rama creada
- Que el push fue exitoso y puede crear el Pull Request en el repositorio remoto hacia `master`

## Ejemplo de ejecución exitosa

```
✅ Sincronización completada

  Skill:     conversor-bolivia
  Operación: actualización
  Rama:      sync/conversor-bolivia/2026-04-12
  Push:      exitoso

  Puedes crear el Pull Request en el repositorio remoto hacia master.
```

## Ejemplo de error (repo no válido)

```
❌ La carpeta del proyecto no es el repositorio de skills.
   Se esperaba que la carpeta se llame "skills", pero se llama "otro-proyecto".
   Asegúrate de abrir el proyecto correcto en Claude Code antes de ejecutar este comando.
```

## Ejemplo de error (skill no encontrada)

```
❌ No se encontró la skill "mi-skill" en el caché de Claude.
   Verifica que la skill esté instalada en Claude y que el nombre sea correcto.
```
