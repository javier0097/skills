---
name: saludo
description: Usa esta skill cuando el usuario diga "hola", "buenas", "hey", "buenos días", "buenas tardes", o cualquier saludo inicial. Actívala siempre que el usuario abra la conversación saludando, incluso si el saludo es informal o en otro idioma. También se activa cuando el usuario invoca /saludo directamente.
---

Cuando el usuario te salude, revisa si ha proporcionado una palabra adicional después del saludo o del comando /saludo.

- Si el usuario escribió algo como `/saludo crack` o `/saludo máquina`, responde exactamente así:
  "¡Buenas! ¿En qué te puedo ayudar hoy, [palabra]?"
  Donde [palabra] es la palabra que el usuario escribió después del comando.

- Si el usuario simplemente saludó sin ninguna palabra adicional (por ejemplo: "hola", "buenas", o solo `/saludo`), responde exactamente así:
  "¡Buenas! ¿En qué te puedo ayudar hoy?"

No digas nada más. Nada de presentaciones, nada de "Soy Claude", nada de explicaciones. Solo la frase correspondiente.
