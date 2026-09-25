# PBX Asterisk con Docker + WSL — Estado Actual del Proyecto

Repositorio: https://github.com/Danfloca02/voip-pbx

Este documento resume el estado actual del proyecto, cómo levantar el entorno de desarrollo desde cero (WSL + VSCode + Docker) y qué falta por implementar. Está pensado para que un nuevo integrante del equipo pueda ponerse al día y dejar su workspace funcionando sin depender de una explicación oral.

---

## 1. ¿Qué es este proyecto?

Es una central telefónica (PBX) basada en **Asterisk 22**, construida como una imagen Docker (Debian 12 slim) que compila Asterisk desde el código fuente con soporte para **PJSIP** y **SRTP** habilitados vía `menuselect`.

El plan de numeración actual (definido en `config/etc/asterisk/extensions.conf`) reserva un dígito por sede:

| Prefijo | Sede               |
|---------|--------------------|
| 1XXX    | Sede Principal (Caracas) |
| 2XXX    | Sede Occidente (Maracaibo) |
| 3XXX    | Sede Centro (Valencia) |
| 4XXX    | Sede Llanos (Barinas) |
| 5XXX    | Sede Oriente (Puerto La Cruz) |

Actualmente solo existen dos extensiones de prueba configuradas en `pjsip.conf`: **1001** y **1002**, probadas localmente con softphones MicroSIP realizando 2 llamadas simultáneas.

El plan de marcado también contempla salidas hacia troncales externas (aún no configuradas, ver sección de pendientes):
- `9` + número → sale por `trunk_redpublica`
- `8` + número → sale por `trunk_sip`

---

## 2. Cómo configurar el workspace (WSL + VSCode + Docker)

Esta guía asume Windows 10/11 como sistema anfitrión y es la ruta recomendada para un nuevo miembro del equipo.

### 2.1 Instalar WSL2

1. Abrir PowerShell **como administrador** y ejecutar:
   ```powershell
   wsl --install -d Ubuntu
   ```
   Esto instala WSL2 y la distribución Ubuntu (recomendada por compatibilidad con `apt` y con Docker).
2. Reiniciar el equipo si se solicita.
3. Al abrir Ubuntu por primera vez, crear el usuario y contraseña de Linux que se pidan.
4. Verificar la versión de WSL activa:
   ```powershell
   wsl -l -v
   ```
   Debe indicar `VERSION 2` para la distro instalada. Si aparece como versión 1:
   ```powershell
   wsl --set-version Ubuntu 2
   ```

### 2.2 Clonar el proyecto

Dentro de la terminal de WSL (Ubuntu):

```bash
sudo apt update && sudo apt install -y git
git clone https://github.com/Danfloca02/voip-pbx.git
cd voip-pbx
```

**Importante:** el repositorio debe clonarse dentro del sistema de archivos de Linux (por ejemplo `~/proyectos/voip-pbx`), **no** dentro de `/mnt/c/...`. Trabajar sobre `/mnt/c` funciona, pero es notablemente más lento (I/O cruzado Windows↔Linux) y puede causar problemas de permisos con Docker.

### 2.3 Instalar VSCode + extensión WSL

1. Instalar VSCode en Windows (no dentro de WSL) desde https://code.visualstudio.com/.
2. Abrir VSCode e instalar la extensión **"WSL"** (Microsoft, id `ms-vscode-remote.remote-wsl`) desde el marketplace.
3. Abrir el proyecto directamente desde la terminal de WSL:
   ```bash
   cd ~/proyectos/voip-pbx
   code .
   ```
   Esto abre VSCode conectado al backend de WSL (se ve "WSL: Ubuntu" en la esquina inferior izquierda). Todas las extensiones que se necesiten para este proyecto (Docker, YAML, etc.) deben instalarse "en WSL" cuando VSCode lo solicite, no solo en Windows.
4. Extensiones recomendadas: **Docker** (Microsoft) y **Dev Containers** (opcional, no se usa un `devcontainer.json` en este repo todavía).

### 2.4 Instalar Docker

Este proyecto usa **Docker Desktop para Windows con integración WSL2** (recomendado, más simple), aunque también es posible instalar Docker Engine nativo dentro de WSL.

**Opción recomendada — Docker Desktop:**
1. Descargar e instalar Docker Desktop desde https://www.docker.com/products/docker-desktop/.
2. Durante o después de la instalación, ir a *Settings → Resources → WSL Integration* y habilitar la integración con la distro Ubuntu usada para el proyecto.
3. Verificar desde la terminal de WSL:
   ```bash
   docker --version
   docker compose version
   ```
   Si ambos comandos responden, la integración quedó correcta.

**Opción alternativa — Docker Engine nativo en WSL** (sin Docker Desktop): instalar `docker.io`/`docker-ce` y `docker-compose-plugin` siguiendo la guía oficial de Docker para Ubuntu, y habilitar el servicio con `sudo service docker start` (WSL no usa systemd por defecto salvo que se habilite explícitamente).

### 2.5 Levantar el proyecto

Con Docker funcionando, desde la raíz del repo:

```bash
make build   # docker compose build — compila Asterisk desde código fuente (puede tardar varios minutos)
make up      # docker compose up -d — levanta el contenedor en segundo plano
make cli     # docker exec -it novalink-voip-pbx asterisk -rvvv — consola CLI de Asterisk
make logs    # docker compose logs -f
make check   # docker compose ps
make down    # docker compose down
make rebuild # down + build --no-cache + up -d
```

La compilación (`make build`) descarga el código fuente de Asterisk 22 desde GitHub y lo compila con `menuselect` habilitando `chan_pjsip`, `res_pjsip` y `res_srtp`, por lo que la primera build puede tardar bastante (el `build.log` versionado en el repo muestra una build de referencia de más de 300s solo en la fase de compilación).

Los archivos de configuración de Asterisk viven en `config/etc/asterisk/` en el host y se montan como volumen dentro del contenedor en `/etc/asterisk`, por lo que **no es necesario reconstruir la imagen para probar cambios de configuración** — basta con `docker compose restart` o recargar el módulo correspondiente desde la CLI de Asterisk (ej. `pjsip reload`, `dialplan reload`).

Puertos publicados actualmente (ver `compose.yaml`): `5060/udp` (SIP) y `10000-10020/udp` (RTP), únicamente en `127.0.0.1`. Si se prueba con un softphone desde Windows, esto funciona porque el compose publica los puertos explícitamente en lugar de usar `network_mode: host` (que no sirve en Docker Desktop, ya que el motor corre dentro de su propia VM y no en la distro WSL).

### 2.6 ¿Qué pasa si Docker no está instalado o no se quiere usar Docker?

El `Dockerfile` es, en esencia, una receta reproducible de instalación manual. Si Docker no está disponible, se puede levantar Asterisk directamente sobre Linux (WSL o un servidor) siguiendo los mismos pasos del Dockerfile a mano:

```bash
sudo apt update && sudo apt install -y --no-install-recommends \
  build-essential git wget curl ca-certificates \
  libssl-dev libncurses5-dev libjansson-dev libsqlite3-dev \
  libedit-dev uuid-dev libxml2-dev pkg-config

cd /usr/src
sudo git clone -b 22 --single-branch --depth 1 https://github.com/asterisk/asterisk.git
cd asterisk
sudo contrib/scripts/install_prereq install

sudo ./configure
make menuselect.makeopts
menuselect/menuselect --enable chan_pjsip --enable res_pjsip --enable res_srtp menuselect.makeopts
make -j"$(nproc)"
sudo make install
sudo make samples
sudo make config
```

Luego, reemplazar el contenido de `/etc/asterisk` generado por `make samples` con el contenido de `config/etc/asterisk/` de este repositorio (o enlazarlo simbólicamente), y arrancar Asterisk en primer plano igual que hace el `ENTRYPOINT` del Dockerfile:

```bash
sudo asterisk -f -vvvc
```

**Limitaciones de esta ruta sin Docker:**
- No hay aislamiento: Asterisk corre directamente sobre el sistema operativo del desarrollador/servidor, compitiendo por puertos (5060/udp, rango RTP) con cualquier otro servicio SIP que exista en la máquina.
- Hay que gestionar manualmente las dependencias de compilación y su actualización; el equipo pierde la reproducibilidad que da la imagen versionada.
- `make build/up/down/logs` del `Makefile` dejan de servir, ya que están escritos en términos de `docker compose`; habría que reemplazarlos por `systemctl`/`service asterisk` o ejecutar `asterisk` manualmente.
- Sin el mapeo de puertos explícito de `compose.yaml`, hay que asegurarse manualmente de que el firewall (o el de Windows, si es WSL) permita tráfico UDP en 5060 y en el rango RTP definido en `rtp.conf` (actualmente 10000-10020).
- Es la vía recomendada solo como plan de contingencia o para un servidor Linux dedicado de producción; para desarrollo en equipo, Docker sigue siendo el camino soportado por este repositorio.

---

## 3. Guía rápida de despliegue en servidor Linux (producción)

Para desplegar esta PBX en un servidor Linux limpio (por ejemplo, para pruebas entre sedes reales):

1. **Requisitos previos del servidor:** Debian/Ubuntu con Docker Engine y el plugin `docker compose` instalados (`docker --version`, `docker compose version`), y acceso saliente a internet solo durante el build (para clonar Asterisk y descargar paquetes).
2. **Clonar el repo:**
   ```bash
   git clone https://github.com/Danfloca02/voip-pbx.git
   cd voip-pbx
   ```
3. **Ajustar `compose.yaml` para producción**, ya que actualmente los puertos están publicados solo en `127.0.0.1` (pensado para pruebas locales con Docker Desktop en Windows). En un servidor real, los binds deben cambiar a `0.0.0.0` (o a la IP pública/privada del servidor) para que los softphones y las troncales externas puedan alcanzar el servicio:
   ```yaml
   ports:
     - "5060:5060/udp"
     - "10000-10020:10000-10020/udp"
   ```
4. **Abrir el firewall** del servidor para UDP 5060 y el rango RTP configurado en `rtp.conf`. Ver [`docs/TRONCALES.md` §2.4.2](docs/TRONCALES.md#242-servidor-linux-con-docker) para los comandos de `ufw`/`firewalld`, los grupos de seguridad del proveedor cloud y, sobre todo, **el aviso de que Docker en modo bridge se salta `ufw`**: en un servidor Linux la opción recomendada es `network_mode: host`, que además conserva la IP de origen y permite ampliar el rango RTP sin publicar miles de puertos.
5. **Ajustar direcciones en `pjsip.conf`:** `external_media_address` y `external_signaling_address` están hardcodeadas a `127.0.0.1`, lo cual solo tiene sentido en local. En un servidor deben apuntar a la IP pública (o usar detección NAT vía `external_media_address`/`external_signaling_address` con la IP real, o STUN si la IP es dinámica).
6. **Build y arranque:**
   ```bash
   make build
   make up
   make check   # confirmar que el contenedor está healthy/running
   make logs    # seguir el arranque de Asterisk
   ```
7. **Persistencia:** solo `config/etc/asterisk` está montado como volumen; cualquier otro estado (voicemail, grabaciones, CDR si se habilita una base de datos) vive dentro del contenedor y se perderá con `docker compose down -v` o al recrear el contenedor. Si el servidor va a producción real, hay que planear volúmenes adicionales para `/var/spool/asterisk` y `/var/log/asterisk`.
8. **Reinicio automático:** `compose.yaml` ya define `restart: unless-stopped`, por lo que el contenedor se recupera solo ante reinicios del host o caídas del proceso.

---

## 4. Pendientes del proyecto

A continuación se detalla lo que falta por implementar, con el estado real encontrado en el código. Última actualización: **2026-09-20**.

### 4.1 Codecs de audio y video — ✅ RESUELTO

`pjsip.conf` fue reestructurado con plantillas y ahora define explícitamente la política de codecs del proyecto:

| Plantilla | Codecs | Aplica a |
|---|---|---|
| `[codec-interno]` | `g722`, `ulaw`, `alaw` (en ese orden de preferencia) | Extensiones (1001, 1002 y futuras) |
| `[codec-troncal]` | `ulaw`, `alaw` | Troncales externas y entre sedes |

Decisiones tomadas y documentadas en el propio archivo:

- **Sin video.** No se declara ningún codec de video (`h264`/`vp8`) a propósito. Si cambia, se añade en estas mismas plantillas.
- **Sin G.729.** Asterisk no lo compila, por lo que sólo podría hacer *passthrough*: una llamada `g729 ↔ ulaw` se quedaría sin audio. Se descarta para no anunciar un codec que la PBX no puede transcodificar. Si en el futuro se requiere de verdad, hay que compilar `bcg729` + `codec_g729` en el `Dockerfile` (la patente expiró en 2017).
- **`g722` se excluye de las troncales** a propósito: rara vez lo soportan los proveedores PSTN y anunciarlo sólo provoca transcodificación innecesaria dentro de la PBX.

`codecs.conf` lleva ahora una cabecera que aclara que ese archivo **no** decide qué codecs se negocian (eso es `allow`/`disallow` en `pjsip.conf`); sólo ajusta parámetros de codecs paramétricos (speex, silk, opus), ninguno de los cuales usa el proyecto.

Toda extensión nueva debe heredar de `[endpoint-interno]`, `[aor-interno]` y `[auth-interno]` para recibir automáticamente codecs, timeouts y comportamiento NAT del proyecto.

### 4.2 Troncales SIP y PJSIP — ⚠️ Plantillas listas, pendiente de datos reales

**Guía completa de configuración: [`docs/TRONCALES.md`](docs/TRONCALES.md)** — cubre la preparación de red en ambas máquinas (IP interna con `ipconfig`, IP pública, `compose.yaml`, reglas de firewall UDP en Windows, transporte PJSIP), llamadas entre softphones en dos laptops distintas, troncal entre dos PBX en la misma LAN o en redes distintas (NAT/registro/VPN), troncal hacia un proveedor SIP comercial, seguridad anti-fraude y tabla de diagnóstico.

Lo que ya está hecho:

- Plantilla `[endpoint-troncal]` en `pjsip.conf` con los ajustes de NAT y los timeouts del proyecto.
- Tres plantillas de AOR según dónde esté el otro extremo: `[aor-troncal-lan]` (misma LAN, IP fija), `[aor-troncal-externa]` (IP pública o dominio fijo) y `[aor-troncal-dinamica]` (el otro extremo se registra, sin `contact`).
- Los objetos completos de `trunk_redpublica` (autenticación usuario/clave + registro saliente) y `trunk_sip` (autenticación por IP, sin registro) escritos y comentados en la sección 5 de `pjsip.conf`, con placeholders en MAYÚSCULAS listos para rellenar.
- Contextos de entrada `[entrantes_redpublica]` y `[entrantes_troncal_sip]` creados en `extensions.conf`.
- **Corregido un fallo de enrutamiento:** los endpoints están en `context=llamadas_internas`, pero los patrones `_9X.` y `_8X.` viven en `salientes_redpublica` / `salientes_troncal_sip` y no había ningún `include =>`. Marcar `9...` u `8...` desde un softphone no encontraba destino aunque las troncales existieran. Se añadieron los `include` correspondientes.

Lo que falta:

- Montar la segunda instancia de Asterisk (segunda laptop con este mismo repo) que hará de otro extremo de `trunk_sip`.
- Rellenar los placeholders con las IPs reales y descomentar los bloques.
- **Publicar los puertos fuera de `127.0.0.1`** en `compose.yaml` y abrir UDP 5060 + 10000-10020 en el Firewall de Windows; mientras sigan atados a loopback, ninguna troncal externa puede alcanzar la PBX.
- **Cambiar `external_media_address` / `external_signaling_address`** de `127.0.0.1` a la IP real de cada máquina; si no, la llamada se establece pero no hay audio.
- **Cambiar las contraseñas de 1001/1002** (hoy son iguales al número de extensión) antes de exponer el 5060 a la red.

### 4.3 Asegurar soporte simultáneo de SIP y PJSIP — ✅ RESUELTO (decisión documentada)

**Decisión: el proyecto usa exclusivamente PJSIP. No se habilitará `chan_sip`.**

El razonamiento, para que quede por escrito y no se vuelva a abrir:

- `chan_sip` (el canal SIP legado) fue **eliminado de Asterisk a partir de la serie 21**. En Asterisk 22 el módulo sencillamente no existe, así que "soportar ambos simultáneamente" no es una opción técnica disponible, independientemente de lo que se configure en `menuselect`.
- PJSIP **es** SIP: implementa el mismo protocolo estándar (RFC 3261). Cualquier softphone, teléfono IP o proveedor que "hable SIP" se conecta a `res_pjsip` sin problema. Los dos softphones MicroSIP ya probados son la demostración.
- Por tanto, si el requisito original quería decir *"que convivan dispositivos y proveedores SIP de distinta procedencia"*, **ya está cumplido**: es lo que hace la configuración actual.

Lo que queda no es habilitar un módulo, sino **validar compatibilidad**. Checklist sugerido conforme se incorporen dispositivos:

| Cliente / proveedor | Registra | Audio bidireccional | Codec negociado | DTMF | Notas |
|---|---|---|---|---|---|
| MicroSIP (Windows) | ✅ | ✅ | ulaw | — | Probado, 2 llamadas simultáneas |
| Zoiper / Linphone | ⬜ | ⬜ | ⬜ | ⬜ | |
| Teléfono IP físico | ⬜ | ⬜ | ⬜ | ⬜ | |
| Troncal del proveedor | ⬜ | ⬜ | ⬜ | ⬜ | |

Herramientas para llenarla, desde `make cli`:

```
pjsip set logger on           ; ver la señalización SIP en crudo
pjsip show endpoints          ; estado de registro
core show channels verbose    ; codec realmente negociado en una llamada activa
```

### 4.4 Cifrado de audio (SRTP) y señalización (TLS)
`res_srtp` ya se habilita en el `Dockerfile` vía `menuselect`, pero **no hay ningún transporte TLS ni ningún endpoint con `media_encryption` configurado** en `pjsip.conf`. Solo existe `[transport-udp]` sin cifrado. Falta:
- Añadir un `[transport-tls]` en `pjsip.conf` con certificado/clave (autofirmado para pruebas, CA real para producción).
- Configurar `media_encryption=sdes` (o `dtls` si se usará WebRTC) en los endpoints que deban cifrar RTP.
- Definir política de convivencia entre extensiones cifradas y no cifradas (¿se exige TLS/SRTP a todos los endpoints o es opcional por sede?).

### 4.5 Funcionalidades de llamada pendientes
No existe ningún dialplan para las siguientes funciones (los `.conf` correspondientes están solo en su versión de ejemplo, sin personalizar):
- **Hold (retención de llamada):** falta lógica de dialplan/feature codes; ver además el punto 4.9 sobre el timeout de 15 minutos en hold.
- **Transferencia (Forwarding):** no hay `followme.conf` personalizado ni lógica de `Dial` con opciones de transferencia/CFWD configurada.
- **Buzón de voz (Voice Inbox):** `voicemail.conf` está en su versión de ejemplo (contexto `default`, buzón `1234`); falta crear buzones reales por extensión y enlazarlos a los endpoints (`mailboxes=` en `pjsip.conf`) y a `hints`/`VoiceMailMain` en el dialplan.
- **Conferencias:** `confbridge.conf` está sin personalizar; falta definir salas, perfiles de usuario/bridge y el/los números de acceso en el dialplan.

### 4.6 Parámetros SDP
No hay ninguna configuración explícita de SDP más allá de lo que Asterisk aplica por defecto (no se tocó `pjsip.conf` en este aspecto: no hay `rtp_symmetric` a nivel de SDP fino, `direct_media` está en `no` para 1001/1002, no hay control de `T.140`, `send/recvonly`, etc.). Falta definir explícitamente qué atributos SDP necesita el proyecto (por ejemplo, para soportar early media, DTMF vía `rfc4733`, o restricciones de `direct_media` por sede/troncal).

### 4.7 Interconexión de troncales entre sedes
El plan de numeración por sede (1XXX–5XXX) sugiere una arquitectura multi-sede, pero actualmente solo existe una instancia de Asterisk con extensiones locales (1001, 1002 en el rango 1XXX). Falta:
- Decidir el modelo de interconexión: una sola instancia central con todas las sedes registradas como endpoints PJSIP, vs. una instancia de Asterisk por sede interconectada por troncal SIP (IAX2 también es una opción, aunque no está habilitado en el build actual).
- Configurar el enrutamiento del dialplan para que, por ejemplo, marcar `2XXX` desde la sede 1 salga por la troncal hacia la sede 2 en lugar de buscar la extensión localmente.

### 4.8 Script automático de TCPDUMP para monitoreo de llamadas
Ya existe un `inside.pcap` de ejemplo en la raíz del repo (capturado manualmente), pero no hay ningún script versionado que automatice la captura. Falta:
- Crear un script (bash) que ejecute `tcpdump` filtrando puertos SIP/RTP relevantes (5060/udp y el rango de `rtp.conf`, 10000-10020) dentro o fuera del contenedor.
- Integrarlo como target de `Makefile` (ej. `make pcap`) o como sidecar/servicio en `compose.yaml`, para poder abrir la captura resultante en Wireshark y depurar llamadas.
- Definir rotación/nombrado de archivos por llamada o por sesión de prueba.

### 4.9 Colgado automático de Hold tras 15 minutos
Actualmente el único timeout relacionado es `rtp_timeout_hold=900` (900 segundos = 15 minutos) en los endpoints 1001 y 1002 de `pjsip.conf`, que corta la llamada si no hay actividad RTP durante ese tiempo estando en hold. Falta:
- Confirmar que este es el comportamiento deseado (colgar automáticamente, no solo detectar inactividad) y validarlo con pruebas reales de hold prolongado.
- Extender este valor a cualquier endpoint/troncal nuevo que se agregue (actualmente es una configuración por endpoint, no global).
- Evaluar si además se requiere lógica de dialplan (ej. un `Set(TIMEOUT(absolute)=900)` o similar) en vez de depender únicamente del timeout de RTP, según cómo se implemente finalmente la función de Hold del punto 4.5.

---

## 5. Resumen de estado

| Área | Estado |
|---|---|
| Build Docker (Asterisk 22 + PJSIP + SRTP compilado) | ✅ Funcional |
| Extensiones internas (1001, 1002) | ✅ Probado con MicroSIP, 2 llamadas simultáneas |
| Dialplan interno por sede (1XXX-5XXX) | ✅ Definido, solo probado en sede 1 |
| Codecs de audio/video | ✅ Política definida (`g722`/`ulaw`/`alaw` interno, `ulaw`/`alaw` troncal, sin video, sin G.729) |
| Troncales SIP/PJSIP salientes | ⚠️ Plantillas y contextos de entrada listos + guía en `docs/TRONCALES.md`; faltan IPs reales y segunda PBX |
| Cifrado SRTP/TLS | ❌ Módulo compilado, sin transporte TLS ni `media_encryption` configurado |
| Soporte SIP (chan_sip vs PJSIP) | ✅ Decidido: sólo PJSIP (`chan_sip` no existe en Asterisk 22); queda validar compatibilidad por dispositivo |
| Hold / Forwarding / Voicemail / Conferencias | ❌ Pendiente |
| Parámetros SDP explícitos | ❌ Pendiente |
| Interconexión de troncales entre sedes | ❌ Pendiente |
| Script automático de captura TCPDUMP | ❌ Pendiente (solo hay una captura manual `inside.pcap`) |
| Colgado de Hold a los 15 min | ⚠️ Parcial (`rtp_timeout_hold=900` por endpoint; falta validar y generalizar) |
 