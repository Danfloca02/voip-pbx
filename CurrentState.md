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
4. **Abrir el firewall** del servidor (ej. `ufw`) para UDP 5060 y el rango RTP configurado en `rtp.conf`.
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

A continuación se detalla lo que falta por implementar, con el estado real encontrado en el código a la fecha (2026-09-16):

### 4.1 Codecs de audio y video
`codecs.conf` está presente únicamente con los valores de ejemplo por defecto que trae Asterisk (`speex`, `silk8/12/16/24`, opus comentado, etc.) — no ha sido ajustado para el proyecto. Los endpoints en `pjsip.conf` (1001, 1002) solo tienen `allow=ulaw`. Falta:
- Definir explícitamente la lista de codecs permitidos por endpoint/plantilla (ej. `ulaw`, `alaw`, `g722` para voz de buena calidad en LAN; evaluar `opus` para WAN con pérdida).
- Decidir si se requiere soporte de video (actualmente no hay ningún `allow=h264`/`vp8` configurado).
- Documentar la política de codecs por troncal vs. por extensión interna, ya que las troncales externas pueden exigir codecs distintos a los internos.

### 4.2 Troncales SIP y PJSIP
`extensions.conf` ya referencia dos contextos de salida (`salientes_redpublica` → `trunk_redpublica`, `salientes_troncal_sip` → `trunk_sip`), pero **ninguna de las dos troncales está definida en `pjsip.conf`**. Falta:
- Crear los `endpoint`/`aor`/`auth`/`identify` (o `registration` si el proveedor requiere registro saliente) para `trunk_redpublica` y `trunk_sip`.
- Definir el contexto de entrada para llamadas que lleguen desde esas troncales (actualmente no existe ningún `context` de entrada de troncal en el dialplan).
- Validar interconexión entre sedes (ver punto 4.7, "Troncales de interconexión").

### 4.3 Asegurar soporte simultáneo de SIP y PJSIP
El proyecto compila y usa únicamente **PJSIP** (`chan_pjsip`/`res_pjsip` habilitados en `menuselect`; no se habilita `chan_sip`, que además está descontinuado/eliminado en versiones recientes de Asterisk). Falta decidir y documentar:
- Si "SIP" se refiere a soporte del canal legado `chan_sip` (deprecado, removido de Asterisk desde la serie 21 en adelante — probablemente no aplica a Asterisk 22) o si se refiere a compatibilidad con dispositivos/proveedores que hablan SIP estándar sobre PJSIP (que ya es el caso).
- Si es lo segundo, el trabajo pendiente es de validación de compatibilidad con distintos softphones/proveedores, no de habilitar un módulo adicional.

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
| Codecs de audio/video | ❌ Pendiente (solo `ulaw`, sin ajustar `codecs.conf`) |
| Troncales SIP/PJSIP salientes | ❌ Referenciadas en dialplan, no definidas en `pjsip.conf` |
| Cifrado SRTP/TLS | ❌ Módulo compilado, sin transporte TLS ni `media_encryption` configurado |
| Hold / Forwarding / Voicemail / Conferencias | ❌ Pendiente |
| Parámetros SDP explícitos | ❌ Pendiente |
| Interconexión de troncales entre sedes | ❌ Pendiente |
| Script automático de captura TCPDUMP | ❌ Pendiente (solo hay una captura manual `inside.pcap`) |
| Colgado de Hold a los 15 min | ⚠️ Parcial (`rtp_timeout_hold=900` por endpoint; falta validar y generalizar) |
 