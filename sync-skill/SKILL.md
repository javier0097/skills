---
name: sync-skill
description: Sincroniza una skill personal desde Claude hacia un repositorio git local. Se invoca con /sync-skill seguido del nombre de la skill. Compara la skill cacheada en el sistema con su copia en el repo local y, si hay cambios reales, crea una rama, aplica los cambios y hace push; si no los hay, termina sin crear rama ni commit. Usa esta skill cuando el usuario quiera sincronizar, actualizar, respaldar o bajar una skill a su repositorio local de skills.
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

**La comparación debe ignorar los finales de línea.** El caché de Claude guarda los archivos con LF. En el repo de skills la causa raíz ya está resuelta: un `.gitattributes` en la raíz con `* text=auto eol=lf` garantiza que la copia de trabajo también se materialice en LF, así que el diff crudo da cero diferencias. Pero la skill puede correr contra un repo sin ese atributo configurado, y ahí `core.autocrlf=true` hace que git materialice CRLF apenas re-escribe los archivos (clon nuevo, `git checkout` de rama, `git pull`): un `diff -r` a secas reportaría TODOS los archivos como distintos aunque el contenido sea idéntico. Por eso `--strip-trailing-cr` se mantiene como defensa en profundidad. Úsalo siempre:

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

Si el nombre ya está tomado, agrega un sufijo incremental: `sync/conversor-bolivia/2026-04-12-2`, `sync/conversor-bolivia/2026-04-12-3`, etc.

**"Ya está tomado" significa: existe como rama local O como rama remota conocida.** Basta con que aparezca en cualquiera de las dos para incrementar. El caso más común es una rama local que sobrevivió al merge de su PR y ya fue borrada del remoto: reutilizar ese nombre haría que el commit nuevo caiga sobre historia vieja, así que igual hay que incrementar.

```bash
git rev-parse --verify --quiet "refs/heads/<rama>" || \
git rev-parse --verify --quiet "refs/remotes/origin/<rama>"
```

Si cualquiera de los dos devuelve un hash, el nombre está tomado. Ten en cuenta que las refs de `origin/` pueden estar desactualizadas — el Paso 3 solo trae `master`. Ante la duda, incrementar es siempre seguro.

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
  git checkout master
  git branch -D <nombre-exacto-de-la-rama>
  echo "   Se descartó la rama vacía creada en el Paso 6. Revisa el estado del repo manualmente."
  exit 1
fi
cp -r "$SKILL_SOURCE" ./<nombre-skill>
```

Si esta verificación falla, **no ejecutes ningún paso posterior**: el `exit 1` solo termina ese comando de shell, no la ejecución de la skill — detenerte es responsabilidad tuya. Informa al usuario del error y no sigas. Borrar la rama no pierde información de diagnóstico: la carpeta inesperada vive en `master` y queda intacta.

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

**Guarda contra el commit vacío.** El Paso 5 puede detectar diferencias que `git add` termina no registrando como cambio real, por cualquier motivo: normalización aplicada por `.gitattributes`, archivos que git considera iguales, o un falso positivo del propio Paso 5. Si no queda nada staged, el `git commit` falla con "nothing to commit" y deja una rama huérfana sin commit, con el repo en un estado raro. Esta verificación es la red de seguridad: no depende de ninguna causa en particular, solo del hecho de que no hay nada que commitear.

```bash
git add ./<nombre-skill>

if git diff --cached --quiet; then
  echo "ℹ️  Nada quedó staged: el contenido del repo ya es idéntico al del caché."
  git checkout master
  git branch -D <nombre-exacto-de-la-rama>
  echo "✅ La skill ya estaba sincronizada. No se creó rama ni commit."
  exit 0
fi

git commit -m "sync/<nombre-skill>: <descripcion-generada>"
```

Si este guard se dispara, **no ejecutes los Pasos 9 y 10**: el `exit 0` solo termina ese comando de shell, no la ejecución de la skill — detenerte es responsabilidad tuya. Informa al usuario que la skill ya estaba sincronizada y no sigas.

### Paso 9: Push

Sube la rama al repositorio remoto. Usa el nombre exacto de la rama creada en el Paso 6, incluyendo el sufijo incremental si fue necesario.

**Corre el push en background.** Este repo usa Git Credential Manager por HTTPS: en foreground el comando queda esperando autenticación y, con timeout corto, se mata solo antes de completar. Redirige la salida a un log y verifica después:

```bash
git push origin <nombre-exacto-de-la-rama> > /tmp/push-<nombre-skill>.log 2>&1 &
```

Para confirmar que terminó bien, revisa el log y comprueba que la ref remota quedó actualizada:

```bash
cat /tmp/push-<nombre-skill>.log
git rev-parse --verify --quiet "refs/remotes/origin/<nombre-exacto-de-la-rama>"
```

Un push exitoso actualiza la rama de seguimiento, así que si el `rev-parse` devuelve un hash, el push llegó.

### Paso 10: Resultado

**Reporta según lo que haya devuelto la verificación del Paso 9. No afirmes que el push fue exitoso sin haberlo comprobado.**

Si la verificación confirmó el push, informa al usuario con un resumen:

- Nombre de la skill sincronizada
- Tipo de operación (nueva o actualización)
- Nombre de la rama creada
- Que el push fue exitoso y puede crear el Pull Request en el repositorio remoto hacia `master`

Si la verificación no confirmó el push, informa que el commit quedó hecho en la rama local pero el push no se completó, incluye el contenido del log, e indica que hay que reintentarlo manualmente. No menciones el Pull Request.

## Ejemplo de ejecución exitosa

```
✅ Sincronización completada

  Skill:     conversor-bolivia
  Operación: actualización
  Rama:      sync/conversor-bolivia/2026-04-12
  Push:      exitoso

  Puedes crear el Pull Request en el repositorio remoto hacia master.
```

## Ejemplo de skill ya sincronizada

```
ℹ️  La skill ya estaba sincronizada

  Skill:     conversor-bolivia
  Estado:    sin diferencias respecto del repositorio local
  Rama:      no se creó
  Commit:    no se creó

  No hay nada que subir.
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
