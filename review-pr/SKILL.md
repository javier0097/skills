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

### Paso 4: Presentar el resultado

Muestra al usuario:
1. El ID del PR que se revisó.
2. La lista completa de archivos modificados con sus contadores de inserciones y eliminaciones (la salida de `git diff --stat`).
3. Un resumen final con el total de archivos cambiados, inserciones y eliminaciones.

Usa un formato claro y legible. No inventes datos — muestra exactamente lo que reporta git.

## Manejo de errores

- Si el PR ID no es un número válido, pide al usuario que verifique.
- Si el fetch falla, puede ser que el PR no exista o que no tengas permisos para acceder al repositorio. Informa claramente.
- Si el remoto no corresponde a Azure DevOps, GitHub ni GitLab, indica que la skill no soporta ese proveedor.

## Notas para evolución futura

Esta skill se irá expandiendo progresivamente para incluir:
- Revisión del diff completo por archivo
- Análisis de calidad del código
- Detección de problemas comunes
- Sugerencias de mejora
- Resumen ejecutivo del PR

Por ahora, solo muestra los archivos modificados y el resumen estadístico.
