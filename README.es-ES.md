# Junimo-MCP

[![CI](https://github.com/mlkgrnt/Junimo-MCP/actions/workflows/ci.yml/badge.svg)](https://github.com/mlkgrnt/Junimo-MCP/actions/workflows/ci.yml)

[简体中文](README.md) · [繁體中文](README.zh-Hant.md) · [English](README.en-US.md) · **Español**

Un servidor MCP **escrito a mano en OCaml**: un par de manos trabajadoras para agentes de IA en *Stardew Valley* — **35 herramientas de intención**, desde labrar y cosechar hasta recoger objetos, comer, socializar y disfrutar de los festivales, con una ejecución fiable de principio a fin.

- **Capa de protocolo**: JSON-RPC 2.0 sobre stdio, implementado a mano (`initialize` / `tools/list` / `tools/call`), sin dependencias de frameworks MCP
- **Capa de control**: subproceso curl → [NagiBridge-Remix](https://github.com/pendel001/NagiBridge-Remix) por HTTP (por defecto `http://localhost:7842`) → el personaje del juego
- **Sin falsos éxitos**: si una herramienta informa de éxito, es que realmente ocurrió en el juego; la mayoría de los fallos no tienen efectos secundarios (los regalos fallidos se devuelven, comer fallido no consume nada), así que puedes reintentar sin miedo
- **Dependencias mínimas**: la única biblioteca OCaml de terceros es yojson; **cero dependencias externas en ejecución** (HTTP por sockets nativos, sin necesidad de curl del sistema; `STARDEW_HTTP=curl` como respaldo)

## ¿Solo quieres usarlo, no desarrollarlo? Deja que un agente lo despliegue

```bash
git clone https://github.com/mlkgrnt/Junimo-MCP.git
```

Entrega el repositorio a tu cliente de IA (WorkBuddy / Claude Code / Cursor / cualquier agente capaz de leer archivos y ejecutar comandos) y dile:

> **«Lee AGENTS.md y deja Junimo-MCP desplegado y funcionando.»**

El agente seguirá la sección *Despliegue* de `AGENTS.md` y hará todo automáticamente:
**instalar SMAPI → instalar el mod ejecutor → desplegar el servidor → registrar el conector MCP → verificar que funciona.**

Solo necesitas dos cosas: ① un Windows con *Stardew Valley* instalado; ② un clic en **Trust** durante el registro y reiniciar el cliente.

> **Los binarios ya compilados están en Releases**: descarga `junimo-mcp.exe` desde la [última versión](https://github.com/mlkgrnt/Junimo-MCP/releases/latest) (con su archivo de suma de verificación SHA-256) — no hace falta ningún entorno de desarrollo.
> ¿Prefieres hacerlo a mano? Consulta *Instalación manual*.

## Cómo se ve

```
┌────────────┐   stdio (JSON-RPC)   ┌──────────────────┐   HTTP localhost:7842   ┌──────────────────┐
│ Cliente MCP │ ◄──────────────────► │ junimo-mcp.exe  │ ◄─────────────────────► │ NagiBridge-Remix │ ──► Stardew Valley
│  (tu IA)    │   35 herramientas    │    (OCaml 5.5)   │    subproceso curl      │    (SMAPI mod)   │
└────────────┘                       └──────────────────┘                         └──────────────────┘
```

Puntos destacados:

- **Tres disciplinas de fiabilidad**: validación en el lado del juego, puntuación ternaria por casilla (éxito / omisión idempotente / fallo con motivo) y relectura precisa — «nunca un falso éxito»;
- **Cuatro capas de pruebas**: pruebas unitarias + **prueba de humo mock de 114 aserciones** (sin necesidad del juego) + suites en vivo + prueba de estrés;
- **Respuestas en lenguaje natural**: las herramientas devuelven texto legible que el agente puede mostrar al usuario tal cual (por ahora, en chino).

## Requisitos previos

| Elemento | Versión / Notas |
|---|---|
| Juego | Stardew Valley **1.6.15** (probado en la versión de Steam) |
| SMAPI | **4.5.2** (o una versión 4.x compatible) |
| NagiBridge-Remix | **v0.9** (descomprimir en `Mods/NagiBridge/`) |
| OCaml (solo para desarrollo / compilación) | **5.5.0** + dune 3.24 + yojson 3.0 (en Windows: opam + Cygwin gestionado; ver abajo) |

> ⚠️ **Remix y el NagiBridge original no pueden convivir**: tienen UniqueID distintos (`pendel001.NagiBridge` frente a `Nagi.NagiBridge`) y se disputarían el puerto 7842. Para migrar, saca la carpeta antigua `Mods/NagiBridge/` fuera de Mods antes de descomprimir la nueva versión.
>
> Nota de licencia: Remix es una modificación autorizada (PolyForm Noncommercial 1.0.0; gratuita para uso personal / no comercial). Este proyecto se comunica con él por HTTP y no incluye su código.

Inicia el juego ejecutando `StardewModdingAPI.exe` en la carpeta del juego (**no lo inicies desde Steam**, o los mods no se cargarán; el precio es que los logros de Steam quedan desactivados). Al cargar una partida, NagiBridge sirve automáticamente en el puerto 7842.

## Instalación manual (4 pasos)

> Coincide con la sección *Despliegue* de `AGENTS.md`, que incluye la verificación detallada y la solución de problemas.

| Paso | Qué hacer | Notas |
|---|---|---|
| 1 · SMAPI | Instala el cargador de mods | Omítelo si `StardewModdingAPI.exe` ya existe en la carpeta del juego |
| 2 · Mod ejecutor | Instala NagiBridge-Remix | Descomprime en `<CARPETA DEL JUEGO>\Mods\`; **si hay un NagiBridge original, retíralo primero** |
| 3 · Servidor | Descarga `junimo-mcp.exe` de [Releases](https://github.com/mlkgrnt/Junimo-MCP/releases/latest) y colócalo en un sitio fijo | Sin compilar; evita la unidad C: y las rutas con espacios |
| 4 · Registro | Escribe `~/.workbuddy/mcp.json` → Trust → reinicia | Formato abajo |

`~/.workbuddy/mcp.json`:

```json
{
  "mcpServers": {
    "junimo": {
      "command": "D:/junimo-mcp/junimo-mcp.exe",
      "env": { "STARDEW_API_URL": "http://localhost:7842" }
    }
  }
}
```

**No surte efecto automáticamente**: en WorkBuddy abre *Gestión de conectores → Conectores personalizados (arriba a la derecha)*, pulsa **Trust** para `junimo` y reinicia WorkBuddy.

**¿Usas otro cliente? Los cuatro más populares tienen configuración lista para copiar y pegar** (detalles en `AGENTS.md`, *Paso 5 · Registrar en un cliente MCP*):

| Cliente | Ubicación de la configuración | Inicio rápido |
|---|---|---|
| WorkBuddy | `~/.workbuddy/mcp.json` | Pulsa Trust en la interfaz |
| Claude Code | `~/.claude.json` / `.mcp.json` del proyecto | `claude mcp add --transport stdio junimo -- "<EXE>"` |
| Codex | `~/.codex/config.toml` | `codex mcp add junimo -- "<EXE>"` |
| DeepSeek Harness | `$DSH_HOME/profiles/<name>/cordis.patch.yml` | Una entrada cordis patch (ver AGENTS.md) |

## Comprobación rápida

```bash
# ¿Está vivo el puente? (el flag --noproxy '*' es obligatorio: evita el proxy del sistema)
curl -sS --noproxy '*' http://localhost:7842/status
# {"ok":true,"server":"NagiBridge",...,"worldReady":true,...}
```

> ⚠️ La dirección debe ser `http://localhost:7842`, **no `127.0.0.1`**: el HttpListener del mod solo registra el prefijo localhost, y 127.0.0.1 se rechaza con un 400 (comprobado en el juego real).

## Lista de herramientas (35)

| Grupo | Herramienta | Descripción |
|---|---|---|
| Percepción | `get_state` | Estado completo (jugador / posición / hora / **clima** / inventario / menú) + resumen de estado |
| | `look` | Escanea un radio: cultivos (fase / regado / listo para cosechar), objetos, árboles y piedras, NPC |
| | `get_inventory` | Lista del inventario (la regadera incluye el agua restante) |
| Movimiento | `go_to` | Movimiento con búsqueda de ruta (**las distancias largas se dividen automáticamente en tramos**; rechaza el atajo recto que atraviesa muros; ≤1 casilla cuenta como llegada — algunas casillas de destino no son transitables y se detiene en una adyacente informando las coordenadas reales) |
| | `warp` | Teletransporte entre mapas (asíncrono; relee para confirmar dónde aterrizaste) |
| | `face` | Girar 0 arriba / 1 derecha / 2 abajo / 3 izquierda |
| Interacción | `swing_tool` | Usar la herramienta una vez (pasa por `/use`: validación del lado del juego e informa la casilla realmente afectada) |
| | `use_held` | Usar el objeto en mano (plantar / colocar) |
| | `interact` | Interactuar con la casilla de enfrente (= tecla de confirmación); devuelve la información de esa casilla |
| | `press_key` | Simular pulsaciones (confirm / cancel / números / direcciones…) |
| Interfaz | `menu_read` | Leer el menú / diálogo / tienda / botones actuales |
| | `menu_click` | Pulsar en el menú (índice de opción / nombre de botón / coordenadas) |
| Objetos | `select_item` | Seleccionar un objeto del inventario para llevarlo en mano |
| Tareas agrícolas | `till` | Labrar por lotes (movimiento en serpiente; idempotente: «ya labrado» se omite suavemente; se detiene por debajo del 15% de energía) |
| | `plant` | Plantar por lotes (la casilla debe estar labrada; «ya hay un cultivo» se omite suavemente) |
| | `water` | Escanea las casillas «plantadas y sin regar» y las riega una a una (rellena la regadera automáticamente) |
| | `harvest` | Cosechar cultivos maduros por lotes (instantáneo en el juego; van directos al inventario) |
| Cofres | `chest_scan` | Escanear todos los cofres del mapa actual (posición + contenido + ranura) |
| | `chest_take` | Sacar de un cofre (`name` o `slot`; `count` por defecto = todo; si no cabe se queda dentro y se informa) |
| | `chest_take_list` | Reunir una lista de varios cofres (solo cofres a ≤4 casillas, es decir, a tu alcance; los lejanos se listan en tooFar con coordenadas) |
| Comer | `eat` | Comer para recuperar energía / HP / obtener buffs (si das un nombre se selecciona solo; informa valores antes/después; un fallo no consume nada) |
| Social | `find_npc` | Encontrar a cualquier NPC (coincidencia difusa por nombre en chino o inglés; posición / orientación / si duerme / lo que dice) |
| | `friendship` | Consultar amistad (puntos / corazones / regalos enviados esta semana y hoy; los nombres en chino se resuelven automáticamente) |
| | `gift` | Regalar a un NPC (flujo real; informa el nivel de gusto y el cambio de amistad; el regalo se devuelve si se alcanza el límite o lo rechazan) |
| Festivales | `festival` | Información de festivales (hoy / mañana / el siguiente + estado en directo si hay uno activo) |
| | `festival_interact` | Interactuar con NPC en el recinto del festival (se posiciona y lo activa solo; solo durante un festival activo) |
| | `festival_answer` | Enviar una respuesta / rama del festival (índice `answer`) |
| Subsistencia | `sleep` | Dormir para pasar de día (**la única forma de guardar** — SDV solo guarda al dormir / cambiar de día); devuelve el estado del nuevo día |
| | `buy` | Compra remota (precio de venta ×2, va directo al inventario; id 472 = semillas de chirivía) |
| | `ship` | Vender en la caja de envíos (da `name` o `all=true`; herramientas / semillas / equipo se conservan; requiere estar en la granja) |
| | `chest_read` | Leer el contenido de un cofre (a cualquier distancia dentro del mismo mapa, sin abrirlo) |
| | `chest_store` | Guardar objetos del inventario en un cofre (las herramientas se conservan por defecto) |
| | `map_info` | Edificios / teletransportes / NPC / animales (para planificar rutas) |
| | `pause_time` | Congelar el reloj del juego (evita desmayos en tareas largas; recuerda reanudarlo) |
| | `resume_time` | Reanudar el reloj congelado |

Disciplina común de las tareas agrícolas: colocarse en `(tx, ty-1)` mirando hacia abajo → **teletransporte + relectura de verificación precisa** → `/use` (comprobar que la casilla devuelta == la esperada) → settle 0.55s; cada fallo se lista con su motivo — nunca se usa la herramienta a ciegas.

## Compilar desde el código fuente (desarrolladores)

Con un entorno opam estándar (Linux / macOS / Windows normal), usa directamente dune:

```bash
opam install yojson      # la única dependencia de terceros
dune build               # → _build/default/bin/main.exe
dune runtest             # pruebas unitarias
```

En la cadena de herramientas Cygwin gestionada (el entorno de desarrollo de este proyecto), usa el envoltorio `build.sh` — se encarga del bash Cygwin gestionado + `pi-env.sh` + `OCAMLPATH` y elimina siempre `_build/.lock` (un lock obsoleto provoca errores misteriosos):

```bash
bash build.sh build          # dune build → _build/default/bin/main.exe
bash build.sh runtest        # pruebas unitarias
bash build.sh release        # compila y copia a release/junimo-mcp.exe
bash build.sh exec -- ...    # pasa cualquier subcomando de dune
```

Las anécdotas de la cadena de herramientas (montaje, reescritura de argumentos de Cygwin, el lock, etc.) están en la skill complementaria «ocaml-windows-toolchain».

## Pruebas

| Suite | Comando | Descripción |
|---|---|---|
| Pruebas unitarias | `bash build.sh runtest` | Códec JSON-RPC, análisis / renderizado del estado, matemática de casillas en serpiente |
| Humo mock | `python test/mock_smoke.py` (levanta el mock solo) | Un NagiBridge falso (máquina de estados completa: mapa / movimiento / menús / validación / subsistencia / recogida / social / festivales), **114 aserciones** de flujo completo, **sin necesidad del juego** |
| En vivo, extremo a extremo | `python test/live_e2e.py` | Requiere el juego en marcha: labrar → plantar → regar + verificación cruzada por HTTP |
| En vivo, jornada completa | `python test/live_m4.py` | Requiere el juego en marcha: cargar partida → comprar semillas → 3×3 labrar / plantar / regar → madurar y cosechar → navegación por tramos |
| En vivo, subsistencia v2 | `python test/live_v2.py` | Requiere el juego en marcha: map / lectura-escritura de cofres / control del reloj / **dormir para cambiar de día (avanza un día y guarda)** |
| En vivo, vida v3 | `python test/live_v3.py` | Requiere el juego en marcha: clima / escaneo y extracción de cofres / comer / buscar NPC y regalar / festivales (cambios mínimos y reversibles) |
| En vivo, spot-check | `python test/live_swing.py` | Casos positivos / negativos de un único uso de herramienta |
| Prueba de estrés | `python test/live_soak.py [minutos]` | Lectura-escritura + movimiento continuos; informa de la tasa de errores y la recolección de subprocesos curl |

El mock y el juego real comparten la misma ruta de código (solo cambia `STARDEW_API_URL`), y la semántica de validación de `/use` del mock coincide palabra por palabra con la del mod real.

CI (GitHub Actions, ubuntu) se ejecuta en cada push / PR: compilación + pruebas unitarias + humo mock.

## Variables de entorno

| Variable | Por defecto | Descripción |
|---|---|---|
| `STARDEW_API_URL` | `http://localhost:7842` | Dirección de NagiBridge (debe ser localhost) |
| `STARDEW_HTTP` | `native` | Implementación HTTP: `native` (socket + keep-alive) / `curl` (respaldo) |
| `STARDEW_HTTP_TIMEOUT` | `30` | Tiempo de espera por petición HTTP (segundos; súbelo para endpoints por lotes) |
| `STARDEW_SETTLE` | adaptativo | Espera de asentamiento: sin definir = adaptativo (400 ms, +150 al fallar / −50 tras 3 éxitos); `NNN` ms fijos; `fixed` = 550 ms clásico |
| `STARDEW_TIMEOUT` | `30` | Tiempo de espera total de sondeo (segundos) |
| `STARDEW_CURL` | autodetectado | Sobrescribe la ruta de curl.exe (solo con `STARDEW_HTTP=curl`) |
| `STARDEW_NO_STRIP` | sin definir | `=1` desactiva el resumen final de estado |
| `STARDEW_LOG` | `warn` | Nivel de log en stderr (debug / info / warn) |

## Limitaciones conocidas

- **Capturas / vídeo no disponibles**: GDI no captura el fotograma OpenGL en esta máquina — la verificación se apoya en lecturas de la API del juego (más precisas, además).
- **Movimiento de larga distancia**: el BFS del mod tiene un tope de 500 pasos; `go_to` lo sortea con tramos integrados (≤10 casillas por tramo). Para cruzar mapas usa `warp`.
- **Los menús no avanzan solos**: cualquier acción que abra un menú (diálogo / tienda) se aborta con un informe; el agente lo gestiona explícitamente con `menu_read` / `menu_click`.
- **Sesiones largas sin supervisión**: llama antes a `pause_time` para congelar el reloj (unos 12 minutos reales llevan el día del juego a las 2:00 y el personaje se desmaya, con una pérdida medida del 10% del oro); al terminar, `resume_time`.
- **Compra remota**: el endpoint `/buy` del mod cobra ×2 el precio de venta (es un endpoint de conveniencia / depuración, sin interfaz de tienda).
- **Sin «tiempo de mañana»**: solo hay clima del día actual (la línea de clima de `get_state`); «¿hoy / mañana es festival?» lo calcula un calendario integrado.
- **Llegar al festival es cosa tuya**: la familia `festival` cubre la información y la interacción en el recinto; ve al recinto por la entrada normal del juego — no uses `warp` a un mapa de festival (la escena no se activará).
- Antes de cosechar / recoger, comprueba el espacio libre con `get_inventory` (si el inventario está lleno, los objetos caen al suelo).
- **El progreso solo se guarda con `sleep`**: si cierras el juego sin dormir, las acciones del día se pierden — haz que el agente use `sleep` al final de cada sesión.

## Documentación

| Documento | Para quién | Contenido |
|---|---|---|
| `AGENTS.md` *(chino simplificado)* | **Agentes de IA** | Despliegue + diez reglas de hierro + referencia de 35 herramientas + disciplina de desarrollo |
| `README.md` / `README.zh-Hant.md` / `README.en-US.md` / `README.es-ES.md` | Humanos | Chino simplificado (zh-Hans, predeterminado) / Chino tradicional / Inglés / Español (este archivo) |
| `test/` | Desarrolladores | Suite de pruebas de cuatro capas |

## Licencia y créditos

El código de este proyecto es de código abierto bajo licencia **MIT** — ver [LICENSE](./LICENSE).

- Mod ejecutor: [NagiBridge-Remix](https://github.com/pendel001/NagiBridge-Remix) de pendel001 (PolyForm Noncommercial 1.0.0; gratuito para uso personal / no comercial). Este proyecto se comunica con él por HTTP y no incluye su código.
- Upstream original: [NagiBridge](https://github.com/anqinou-art/NagiBridge) (MIT)
- Filosofía de la capa de control y semántica de endpoints: el autor original de NagiBridge (disciplina de postura y tiempos en `farm_row.py` / `water_crops.py`)
- El diseño del resumen de estado (state strip) está inspirado en NagiBridge-Remix
