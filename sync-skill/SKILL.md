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

### Paso 3: Sincronizar master con el remoto

**Este paso debe ejecutarse antes de cualquier decisión que dependa del estado del filesystem local.** Si master remoto tiene commits que afectan la carpeta de la skill, decidir creación-vs-actualización contra el estado pre-pull puede llevar a operaciones destructivas (como copiar dentro de una carpeta recién aparecida y crear anidamiento).

Asegúrate de estar en `master` y trae los últimos cambios del remoto:

```bash
git checkout master
git pull origin master
```

### Paso 4: Localizar la skill fuente en el caché de Claude

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

### Paso 5: Determinar si es creación o actualización

Revisa si existe la carpeta `<nombre-skill>/` en la raíz del repositorio local. **Esta verificación es válida porque ya se hizo `git pull` en el Paso 3**, así que el filesystem refleja el estado real de master.

- Si **no existe** → es una skill nueva (creación).
- Si **existe** → compara recursivamente todo el contenido de la carpeta local contra `SKILL_SOURCE`. Si no hay diferencias, informa al usuario que la skill ya está sincronizada y detente.

**La comparación debe ignorar los finales de línea.** El caché de Claude guarda los archivos con LF, pero un repo con `core.autocrlf=true` y sin `.gitattributes` materializa la copia de trabajo con CRLF apenas git la re-escribe (clon nuevo, `git checkout` de rama, `git pull`). Un `diff -r` a secas reporta entonces TODOS los archivos como distintos aunque el contenido sea idéntico, lo que vuelve inalcanzable el camino "ya está sincronizada" y ensucia el mensaje de commit del Paso 8. Usa siempre `--strip-trailing-cr`:

```bash
diff -r --strip-trailing-cr ./<nombre-skill> "$SKILL_SOURCE"
```

Guarda esta salida: el Paso 8 la usa para redactar el mensaje de commit.

### Paso 6: Crear la rama de trabajo

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

### Paso 7: Aplicar los cambios

**Si es una skill nueva:** copia toda la carpeta de la skill desde el caché al repositorio local.

Antes de copiar, **verifica defensivamente que la carpeta destino no existe**. Si existe, aborta con un error claro — esto indica un desfase entre la decisión del Paso 5 y el estado actual, y nunca debería pasar si los pasos previos se ejecutaron correctamente. Esta verificación atrapa bugs o race conditions futuros antes de que causen un anidamiento destructivo.

```bash
if [ -e "./<nombre-skill>" ]; then
  echo "❌ Error inesperado: la carpeta './<nombre-skill>' existe pero el Paso 5 la marcó como creación."
  echo "   Aborta y revisa el estado del repo manualmente."
  exit 1
fi
cp -r "$SKILL_SOURCE" ./<nombre-skill>
```

**Si es una actualización:** reemplaza todo el contenido de la carpeta local con el del caché. Elimina primero el contenido local para cubrir el caso donde se hayan eliminado archivos en la fuente.

```bash
rm -rf ./<nombre-skill>
cp -r "$SKILL_SOURCE" ./<nombre-skill>
```

### Paso 8: Commit

Haz stage de todos los cambios y crea el commit. El mensaje siempre empieza con `sync/<nombre-skill>:` seguido de una oración corta que resuma los cambios reales.

Para generar la descripción:

- **Skill nueva:** lee brevemente el SKILL.md para entender el propósito de la skill y descríbelo. Ejemplo: `sync/conversor-bolivia: add skill for bolivian unit conversions`
- **Actualización:** usa la salida del `diff -r --strip-trailing-cr` del Paso 5 para resumir qué archivos cambiaron y la naturaleza del cambio en una oración. Ejemplo: `sync/saludo: update greeting message and add fallback response`

**Guarda contra el commit vacío.** Aunque el Paso 5 haya detectado diferencias, `git add` normaliza los finales de línea y puede producir blobs idénticos a HEAD. Si no queda nada staged, el `git commit` falla con "nothing to commit" y deja una rama huérfana sin commit, con el repo en un estado raro. Verifica antes de commitear y aborta limpiamente:

```bash
git add ./<nombre-skill>

if git diff --cached --quiet; then
  echo "ℹ️  Nada quedó staged: el contenido del repo ya es idéntico al del caché."
  git checkout master
  git checkout -- .
  git branch -D <nombre-exacto-de-la-rama>
  echo "✅ La skill ya estaba sincronizada. No se creó rama ni commit."
  exit 0
fi

git commit -m "sync/<nombre-skill>: <descripcion-generada>"
```

Si este guard se dispara, **no ejecutes los Pasos 9 y 10**: la ejecución termina acá, e informa al usuario que la skill ya estaba sincronizada.

### Paso 9: Push

Sube la rama al repositorio remoto. Usa el nombre exacto de la rama creada en el Paso 6, incluyendo el sufijo incremental si fue necesario:

```bash
git push origin <nombre-exacto-de-la-rama>
```

### Paso 10: Resultado

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
