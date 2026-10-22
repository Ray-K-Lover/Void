#!/usr/bin/env bash
#
# Instalador de Artix Linux "tipo CachyOS" (sin systemd)   [versión v13]
#   init: dinit | UEFI + GPT | ext4 | Limine | NetworkManager | zramen
#   + kernel linux-cachyos-bore (x86-64-v3, repo cachyos-v3) con el kernel 'linux' como respaldo
#   + ajustes tipo CachyOS (sysctl y planificador de E/S)
#   + sonido (PipeWire), vídeo (Mesa/Vulkan/VA-API/códecs) y gaming (Steam)
#   + kitty, fastfetch, sincronización de hora (ntp) y TRIM semanal del SSD
#   + HDD de datos formateado en ext4 para juegos y archivos
#   Menú interactivo: detecta la CPU (microcódigo Intel/AMD) y la GPU (drivers Intel o AMD, o Mesa genérico)
#   y pregunta qué instalar. No instala entorno de escritorio: se elige e instala después.
#
# Pensado al 100% para una instalación TOTALMENTE LIMPIA: los discos se dejan completamente
# vacíos (no conserva datos ni sistemas existentes).
#
# Uso (desde el live ISO artix-dinit-base, como root, arrancado en modo UEFI):
#   bash artix-install.sh
# Los valores por defecto se pueden fijar con variables de entorno, por ejemplo:
#   USERNAME=ana KEYMAP=es TIMEZONE=America/Lima LOCALE=es_PE.UTF-8 bash artix-install.sh
#   INTERACTIVE=no ... bash artix-install.sh   (sin menú; exige USERNAME; los discos siempre se confirman)
# Registro: todo lo que sale por pantalla se guarda en /root/artix-install-FECHA.log (variable LOG_FILE) y,
#   al terminar, se copia a /var/log/artix-install.log del sistema instalado (el live vive en RAM).
#
# ¡ADVERTENCIA! Este script BORRA TODO el disco del sistema (DISK) y TODO el disco de datos (DATA_DISK).

set -Eeuo pipefail
trap 'echo -e "\n[ERROR] Falló la línea $LINENO. Instalación interrumpida." >&2' ERR

# ───────────────────────── CONFIGURACIÓN ─────────────────────────
INTERACTIVE="${INTERACTIVE:-yes}"      # yes = menú de preguntas | no = usa estos valores sin preguntar
DISK="${DISK:-}"                       # disco del SISTEMA (SE BORRA POR COMPLETO). Vacío = se elige al ejecutar (sugiere el SSD)
USERNAME="${USERNAME:-}"               # usuario normal (obligatorio)
KEYMAP="${KEYMAP:-es}"                 # teclado de la consola
HOST_NAME="${HOST_NAME:-artix}"        # nombre del equipo
TIMEZONE="${TIMEZONE:-UTC}"            # zona horaria
LOCALE="${LOCALE:-es_ES.UTF-8}"        # idioma del sistema
ESP_SIZE="${ESP_SIZE:-1GiB}"           # tamaño de la partición EFI (montada en /boot)
ZRAM_ALGO="${ZRAM_ALGO:-zstd}"         # algoritmo de compresión de zram
ZRAM_SIZE="${ZRAM_SIZE:-50}"           # tamaño de zram en % de la RAM
CACHYOS_KERNEL="${CACHYOS_KERNEL:-yes}" # yes = repo [cachyos-v3] + linux-cachyos-bore (el kernel 'linux' queda de respaldo)
CACHYOS_TWEAKS="${CACHYOS_TWEAKS:-yes}" # yes = sysctl y planificador de E/S tipo CachyOS
USE_DATA_DISK="${USE_DATA_DISK:-yes}"  # yes = un segundo disco se BORRA y se formatea en ext4 para juegos y datos | no = no tocarlo
DATA_DISK="${DATA_DISK:-}"             # disco de datos (SE BORRA POR COMPLETO). Vacío = se elige al ejecutar (sugiere el HDD)
DATA_MOUNT="${DATA_MOUNT:-/mnt/datos}" # dónde se monta el disco de datos (ej. biblioteca de Steam en /mnt/datos/SteamLibrary)
ENABLE_GAMING="${ENABLE_GAMING:-yes}"  # yes = Steam + [multilib] de Arch + GameMode + MangoHud (implica ENABLE_LIB32)
INSTALL_CODECS="${INSTALL_CODECS:-yes}" # yes = ffmpeg y GStreamer (códecs de vídeo)
EXTRA_PKGS="${EXTRA_PKGS:-}"           # paquetes extra, ej: "base-devel htop" (se instalan uno a uno; si falta alguno, avisa)
DESKTOP_BASE="${DESKTOP_BASE:-yes}"    # yes = polkit, xdg-utils, xdg-user-dirs y fuentes
ENABLE_LIB32="${ENABLE_LIB32:-no}"     # yes = activa [lib32] e instala mesa/vulkan de 32 bits (Steam, Wine...)
GPU_DRIVER_PRESET="${GPU_DRIVER:-}"    # vacío = se detecta | intel-modern | intel-legacy | amd | generic
LOG_FILE="${LOG_FILE:-/root/artix-install-$(date +%Y%m%d-%H%M%S).log}"   # registro de toda la instalación
SCRIPT_VERSION="v13"
# ─────────────────────────────────────────────────────────────────

msg()  { echo -e "\n\e[1;32m==>\e[0m \e[1m$*\e[0m"; }
warn() { echo -e "\e[1;33m[AVISO]\e[0m $*" >&2; }
die()  { echo -e "\e[1;31m[ERROR]\e[0m $*" >&2; exit 1; }

# ── Registro ──
save_log() {  # copia el log al sistema instalado (el live vive en RAM y se pierde al reiniciar)
  if mountpoint -q /mnt 2>/dev/null; then
    sleep 1   # deja que 'tee' termine de volcar
    if [[ -d /mnt/var/log ]]; then cp -f "$LOG_FILE" /mnt/var/log/artix-install.log 2>/dev/null || true; fi
  fi
}

finish() {  # se ejecuta SIEMPRE al salir: éxito, error o cancelación
  local rc=$?
  trap - EXIT
  echo "Fin: $(date '+%F %T') | duración: $(($(date +%s) - START_TS)) s | código de salida: $rc"
  if ((rc != 0)); then
    echo "Instalación NO completada. Registro: $LOG_FILE (si /mnt sigue montado, copia en /mnt/var/log/artix-install.log)" >&2
  fi
  save_log
}

log_summary() {  # lista los avisos y errores que quedaron en el registro (máx. 60 líneas en pantalla)
  local n
  sleep 1
  msg "Resumen del registro"
  n=$(grep -acE '\[(AVISO|ERROR|FALTA)\]|^error:|^warning:' "$LOG_FILE" || true)
  if ((n == 0)); then
    echo "Sin avisos ni errores."
  else
    echo "$n línea(s) de aviso o error (la lista completa está en $LOG_FILE):"
    grep -aE '\[(AVISO|ERROR|FALTA)\]|^error:|^warning:' "$LOG_FILE" | head -n 60 | sed 's/^/  /' || true
  fi
}

log_config() {  # deja en el registro la configuración elegida (sin contraseñas)
  msg "Configuración de esta instalación (queda en el registro)"
  echo "  Script: $SCRIPT_VERSION | Fecha: $(date '+%F %T') | Kernel del live: $(uname -r)"
  echo "  CPU: ${CPU_VENDOR:-desconocida} ($(awk -F: '/^model name/ {sub(/^ /, "", $2); print $2; exit}' /proc/cpuinfo 2>/dev/null || true))"
  echo "  Microcódigo: ${UCODE:-ninguno} | x86-64-v3: $V3_OK | GPU: $GPU_DRIVER"
  echo "  Discos: sistema=$DISK datos=${DATA_DISK:-ninguno}"
  echo "  Usuario=$USERNAME teclado=$KEYMAP zona=$TIMEZONE idioma=$LOCALE equipo=$HOST_NAME"
  echo "  Kernel CachyOS=$CACHYOS_KERNEL ajustes=$CACHYOS_TWEAKS gaming=$ENABLE_GAMING códecs=$INSTALL_CODECS escritorio-base=$DESKTOP_BASE"
  echo "  Paquetes extra: ${EXTRA_PKGS:-ninguno}"
}

log_state() {  # deja en el registro el estado del sistema instalado, útil para depurar
  msg "Estado del sistema instalado (para el registro)"
  echo "--- lsblk -f";                 lsblk -f "$DISK" ${DATA_DISK:+"$DATA_DISK"} || true
  echo "--- /etc/fstab";               cat /mnt/etc/fstab || true
  echo "--- /boot/EFI/BOOT/limine.conf"; cat /mnt/boot/EFI/BOOT/limine.conf || true
  echo "--- /boot";                    ls -la /mnt/boot || true
  echo "--- kernels instalados";       artix-chroot /mnt pacman -Q linux linux-cachyos-bore 2>/dev/null || true
  echo "--- servicios en boot.d";      ls /mnt/etc/dinit.d/boot.d || true
}

part_of() {  # part_of /dev/sdb 1 -> /dev/sdb1  |  part_of /dev/nvme0n1 1 -> /dev/nvme0n1p1
  case "$1" in
    *[0-9]) echo "${1}p$2" ;;
    *)      echo "${1}$2" ;;
  esac
}

ask_pass() {  # ask_pass "root" -> deja el resultado en PASS_RESULT
  local p1 p2
  while true; do
    read -rsp "Contraseña para $1: " p1; echo
    read -rsp "Repite la contraseña: " p2; echo
    [[ -n $p1 && $p1 == "$p2" ]] && break
    echo "No coinciden o está vacía, intenta de nuevo."
  done
  PASS_RESULT=$p1
}

disk_in_use() {  # true si el disco (o alguna partición) está montado
  local out
  out=$(lsblk -nr -o MOUNTPOINT "$1") || die "lsblk falló al consultar $1."
  [[ -n $out ]]
}

list_disks() {  # discos físicos no extraíbles -> "ruta rotacional(1=HDD,0=SSD)"
  lsblk -dnpr -o NAME,TYPE,RM,ROTA | awk '$2=="disk" && $3==0 && $1 !~ /zram|\/ram/ {print $1, $4}'
}

net_ok() {  # net_ok host puerto -> ping o, si el ICMP está bloqueado, conexión TCP
  ping -c1 -W3 "$1" >/dev/null 2>&1 && return 0
  command -v timeout >/dev/null 2>&1 || return 1
  timeout 5 bash -c 'exec 3<>"/dev/tcp/$0/$1"' "$1" "$2" >/dev/null 2>&1
}

wait_for_block() {  # espera (máx. 15 s) a que existan los nodos de partición
  local i d ok
  for ((i = 0; i < 15; i++)); do
    ok=yes
    for d in "$@"; do [[ -b $d ]] || ok=no; done
    if [[ $ok == yes ]]; then return 0; fi
    sleep 1
  done
  die "No aparecieron las particiones: $*"
}

verify_install() {  # verify_install RAIZ -> comprueba que el sistema instalado puede arrancar
  local R=$1 f rel svc bad=no
  msg "Verificando la instalación"
  for f in boot/vmlinuz-linux boot/initramfs-linux.img ${UCODE:+boot/$UCODE.img} \
           boot/EFI/BOOT/BOOTX64.EFI boot/EFI/BOOT/limine.conf etc/fstab etc/hostname; do
    [[ -s $R/$f ]] || { echo "[FALTA] /$f" >&2; bad=yes; }
  done
  if [[ -s $R/etc/fstab ]] && ! grep -q "UUID=${ROOT_UUID}" "$R/etc/fstab"; then
    echo "[FALTA] la raíz (UUID=${ROOT_UUID}) en /etc/fstab" >&2; bad=yes
  fi
  if [[ -s $R/boot/EFI/BOOT/limine.conf ]]; then
    grep -q "root=UUID=${ROOT_UUID}" "$R/boot/EFI/BOOT/limine.conf" \
      || { echo "[FALTA] root=UUID=${ROOT_UUID} en limine.conf" >&2; bad=yes; }
    # Todo archivo que Limine vaya a cargar debe existir en la ESP
    while read -r rel; do
      [[ -s $R/boot/$rel ]] || { echo "[FALTA] limine.conf apunta a /boot/$rel" >&2; bad=yes; }
    done < <(grep -oE 'boot\(\):/[^[:space:]]+' "$R/boot/EFI/BOOT/limine.conf" | sed 's|^boot():/||')
  fi
  grep -q "^${USERNAME}:" "$R/etc/passwd" || { echo "[FALTA] el usuario ${USERNAME}" >&2; bad=yes; }
  if [[ $bad == yes ]]; then
    die "La verificación falló: el sistema podría no arrancar. /mnt sigue montado para que lo revises."
  fi
  for svc in NetworkManager dbus; do
    [[ -e $R/etc/dinit.d/boot.d/$svc ]] || warn "El servicio $svc no está enlazado en boot.d."
  done
  [[ -e $R/etc/dinit.d/boot.d/elogind || -e $R/etc/dinit.d/boot.d/logind ]] \
    || warn "El servicio elogind no está enlazado en boot.d."
}

choose_system_disk() {
  local d rot default="" cands=()
  while read -r d rot; do
    if disk_in_use "$d"; then continue; fi
    cands+=("$d")
    if [[ -z $default && $rot == 0 ]]; then default=$d; fi
  done < <(list_disks)
  if ((${#cands[@]} == 0)); then die "No hay discos libres (¿todos montados?)."; fi
  msg "Discos disponibles: elige el SSD para el SISTEMA"
  lsblk -d -o NAME,SIZE,MODEL,TRAN,ROTA "${cands[@]}"
  echo "(ROTA=0 es SSD, ROTA=1 es HDD)"
  read -rp "Disco del SISTEMA [${default:-sin sugerencia}]: " DISK
  DISK=${DISK:-$default}
  [[ -n $DISK ]] || die "No elegiste ningún disco."
  [[ $DISK == /dev/* ]] || DISK=/dev/$DISK
}

choose_data_disk() {  # deja DATA_DISK y DATA_PART listos; el disco se BORRA y se formatea en ext4
  DATA_PART=""
  if [[ $USE_DATA_DISK != yes ]]; then DATA_DISK=""; return 0; fi

  local d rot default="" cands=() C
  if [[ -z $DATA_DISK ]]; then
    while read -r d rot; do
      if [[ $d == "$DISK" ]]; then continue; fi
      if disk_in_use "$d"; then continue; fi
      cands+=("$d")
      if [[ -z $default && $rot == 1 ]]; then default=$d; fi
    done < <(list_disks)
    if ((${#cands[@]} == 0)); then
      warn "No hay otro disco libre para datos; se omite el HDD."
      USE_DATA_DISK=no
      return 0
    fi
    msg "Disco de DATOS (HDD para juegos y archivos; se BORRARÁ y se formateará en ext4)"
    lsblk -d -o NAME,SIZE,MODEL,TRAN,ROTA "${cands[@]}"
    read -rp "Disco de datos [${default:-ninguno}] (n = no usar): " DATA_DISK
    DATA_DISK=${DATA_DISK:-$default}
    if [[ -z $DATA_DISK || $DATA_DISK == n ]]; then
      DATA_DISK=""
      USE_DATA_DISK=no
      return 0
    fi
    [[ $DATA_DISK == /dev/* ]] || DATA_DISK=/dev/$DATA_DISK
  fi

  [[ -b $DATA_DISK ]]         || die "No existe el disco de datos $DATA_DISK."
  [[ $DATA_DISK != "$DISK" ]] || die "El disco de datos no puede ser el del sistema."
  if disk_in_use "$DATA_DISK"; then die "$DATA_DISK tiene particiones montadas."; fi

  echo
  lsblk -o NAME,SIZE,FSTYPE,LABEL "$DATA_DISK"
  echo "Se BORRARÁ TODO el contenido de $DATA_DISK."
  read -rp "Escribe el nombre del disco ($DATA_DISK) para confirmar: " C
  [[ $C == "$DATA_DISK" ]] || die "Cancelado."
  DATA_PART=$(part_of "$DATA_DISK" 1)
}

# ───────────────────────── HARDWARE Y MENÚ INTERACTIVO ─────────────────────────
GPU_CHOICES=(intel-modern intel-legacy amd generic)

gpu_label() {
  case $1 in
    intel-modern) echo "Intel (Broadwell o posterior): vulkan-intel + intel-media-driver" ;;
    intel-legacy) echo "Intel antigua (Haswell o anterior): vulkan-intel + libva-intel-driver" ;;
    amd)          echo "AMD: vulkan-radeon (la aceleración de vídeo VA-API ya viene en mesa)" ;;
    generic)      echo "Solo Mesa genérico (máquina virtual u otra GPU)" ;;
  esac
}

detect_hw() {  # CPU_VENDOR, UCODE y GPU_DRIVER por defecto (solo Intel y AMD tienen driver propio)
  local cpuinfo=${HW_CPUINFO:-/proc/cpuinfo} drm=${HW_DRM:-/sys/class/drm}
  local c v intel=no amd=no fam mod
  CPU_VENDOR=$(awk -F: '/^vendor_id/ {gsub(/[ \t]/, "", $2); print $2; exit}' "$cpuinfo" 2>/dev/null || true)
  case $CPU_VENDOR in
    GenuineIntel) UCODE=intel-ucode ;;
    AuthenticAMD) UCODE=amd-ucode ;;
    *)            UCODE="" ;;
  esac
  for c in "$drm"/card[0-9] "$drm"/card[0-9][0-9]; do
    [[ -r $c/device/vendor ]] || continue
    v=$(<"$c/device/vendor")
    case $v in
      0x8086) intel=yes ;;
      0x1002) amd=yes ;;
    esac
  done
  GPU_DRIVER=generic
  if [[ $amd == yes ]]; then
    GPU_DRIVER=amd
  elif [[ $intel == yes ]]; then
    GPU_DRIVER=intel-modern
    # Generación por family/model de la CPU (el nombre comercial falla con i5-1135G7, Pentium, Celeron...).
    # Haswell o anterior usa libva-intel-driver (i965): Nehalem/Westmere, Sandy, Ivy, Haswell y Bay Trail.
    fam=$(awk -F: '/^cpu family/ {gsub(/[ \t]/, "", $2); print $2; exit}' "$cpuinfo" 2>/dev/null || true)
    mod=$(awk -F: '/^model[ \t]*:/ {gsub(/[ \t]/, "", $2); print $2; exit}' "$cpuinfo" 2>/dev/null || true)
    if [[ $fam == 6 ]]; then
      case $mod in
        26|30|31|37|42|44|45|46|47|55|58|60|62|63|69|70) GPU_DRIVER=intel-legacy ;;
      esac
    fi
  fi
  if [[ -n ${GPU_DRIVER_PRESET:-} ]]; then
    case $GPU_DRIVER_PRESET in
      intel-modern|intel-legacy|amd|generic) GPU_DRIVER=$GPU_DRIVER_PRESET ;;
      *) die "GPU_DRIVER no válido: $GPU_DRIVER_PRESET (usa intel-modern, intel-legacy, amd o generic)." ;;
    esac
  fi
}

set_gpu_pkgs() {  # paquetes según GPU_DRIVER; se instalan uno a uno en el chroot (si falta uno, avisa y sigue)
  GPU32_MULTILIB=""
  case $GPU_DRIVER in
    intel-modern) GPU_PKGS="vulkan-intel intel-media-driver";  GPU32_PKGS="lib32-vulkan-intel" ;;
    intel-legacy) GPU_PKGS="vulkan-intel libva-intel-driver";  GPU32_PKGS="lib32-vulkan-intel"
                  GPU32_MULTILIB="lib32-libva-intel-driver" ;;
    amd)          GPU_PKGS="vulkan-radeon";                    GPU32_PKGS="lib32-vulkan-radeon" ;;
    *)            GPU_PKGS="vulkan-swrast";                    GPU32_PKGS="lib32-vulkan-swrast" ;;
  esac
}

# Validadores: devuelven 0 si el valor es válido; si no, explican por qué.
ok_username() {
  local re='^[a-z_][a-z0-9_-]{0,30}$' uid
  [[ $1 =~ $re && $1 != root ]] \
    || { echo "  Usuario no válido (minúsculas, números, _ y -; no puede empezar por número ni ser root)."; return 1; }
  # No pisar cuentas del sistema: useradd fallaría en el chroot, cuando los discos ya se borraron.
  uid=$(getent passwd "$1" 2>/dev/null | cut -d: -f3 || true)
  case $1 in ntp|polkitd|dbus) uid=0 ;; esac   # las crean paquetes que el script instala después
  if [[ -n $uid ]] && ((uid < 1000 || uid == 65534)); then
    echo "  '$1' es una cuenta del sistema; elige otro nombre."; return 1
  fi
}
ok_hostname() {
  local re='^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$'
  [[ $1 =~ $re ]] || { echo "  Nombre no válido (letras, números y guiones; sin empezar ni acabar en guion)."; return 1; }
}
ok_keymap() {
  [[ -d /usr/share/kbd/keymaps ]] || return 0
  [[ -n $(find /usr/share/kbd/keymaps -name "$1.map*" -print -quit 2>/dev/null) ]] \
    || { echo "  No existe el teclado '$1' (ejemplos: es, us, la-latin1, br-abnt2)."; return 1; }
}
ok_timezone() {
  [[ ! -d /usr/share/zoneinfo || -f /usr/share/zoneinfo/$1 ]] \
    || { echo "  Zona horaria desconocida (ejemplos: America/Lima, Europe/Madrid, UTC)."; return 1; }
}
ok_locale() {
  local re='^[a-z]{2,3}_[A-Z]{2}\.UTF-8$'
  [[ $1 =~ $re ]] || { echo "  Formato no válido (ejemplo: es_ES.UTF-8)."; return 1; }
  if [[ -r /usr/share/i18n/SUPPORTED ]] && ! grep -qx "$1 UTF-8" /usr/share/i18n/SUPPORTED; then
    echo "  Idioma no soportado por glibc: $1"; return 1
  fi
}
ok_pkgs() {
  local re='^[A-Za-z0-9@._+ -]*$'
  [[ $1 =~ $re ]] || { echo "  Solo nombres de paquetes separados por espacios."; return 1; }
}

apply_keymap() {
  loadkeys "$KEYMAP" >/dev/null 2>&1 \
    || warn "No se pudo cargar el teclado '$KEYMAP' en el live (se usará igualmente en el sistema instalado)."
}

ask_text() {  # ask_text VARIABLE "Pregunta" validador [yes = obligatorio]
  local var=$1 q=$2 check=$3 req=${4:-no} cur v
  while true; do
    cur=${!var}
    if [[ -n $cur ]]; then read -rp "$q [$cur]: " v; v=${v:-$cur}; else read -rp "$q: " v; fi
    if [[ $v == - && $req != yes ]]; then v=""; fi
    if [[ -z $v ]]; then
      if [[ $req == yes ]]; then echo "  Este dato es obligatorio."; continue; fi
      printf -v "$var" '%s' ""; return 0
    fi
    if "$check" "$v"; then printf -v "$var" '%s' "$v"; return 0; fi
  done
}

ask_yn() {  # ask_yn VARIABLE "Pregunta": Enter mantiene el valor actual
  local var=$1 q=$2 d a
  if [[ ${!var} == yes ]]; then d="S/n"; else d="s/N"; fi
  while true; do
    read -rp "$q [$d]: " a
    case ${a,,} in
      "")           return 0 ;;
      s|si|sí|y|yes) printf -v "$var" '%s' yes; return 0 ;;
      n|no)         printf -v "$var" '%s' no;  return 0 ;;
      *)            echo "  Responde s o n." ;;
    esac
  done
}

ask_gpu() {
  local i a
  echo "Driver de vídeo (detectado: $(gpu_label "$GPU_DRIVER")):"
  for i in "${!GPU_CHOICES[@]}"; do printf '  %d) %s\n' $((i + 1)) "$(gpu_label "${GPU_CHOICES[i]}")"; done
  while true; do
    read -rp "Opción [Enter = mantener]: " a
    if [[ -z $a ]]; then return 0; fi
    if [[ $a =~ ^[1-4]$ ]]; then GPU_DRIVER=${GPU_CHOICES[a-1]}; return 0; fi
    echo "  Elige un número del 1 al 4."
  done
}

yn() { if [[ $1 == yes ]]; then echo "sí"; else echo "no"; fi; }
row() { printf '  %2s) %-46s %s\n' "$1" "$2" "$3"; }

show_summary() {
  msg "Resumen (escribe un número para cambiarlo)"
  echo "  Equipo: CPU ${CPU_VENDOR:-desconocida} | microcódigo: ${UCODE:-ninguno}"
  row 1  "Teclado de la consola"                    "$KEYMAP"
  row 2  "Zona horaria"                             "$TIMEZONE"
  row 3  "Idioma del sistema"                       "$LOCALE"
  row 4  "Usuario"                                  "$USERNAME"
  row 5  "Nombre del equipo"                        "$HOST_NAME"
  if [[ $V3_OK == yes ]]; then
    row 6 "Repo [cachyos-v3] + kernel CachyOS"      "$(yn "$CACHYOS_KERNEL")"
  else
    row 6 "Repo [cachyos-v3] + kernel CachyOS"      "no disponible (la CPU no soporta x86-64-v3)"
  fi
  row 7  "Ajustes de rendimiento tipo CachyOS"      "$(yn "$CACHYOS_TWEAKS")"
  row 8  "Gaming (Steam, GameMode, MangoHud)"       "$(yn "$ENABLE_GAMING")"
  row 9  "Códecs de vídeo (ffmpeg, GStreamer)"      "$(yn "$INSTALL_CODECS")"
  row 10 "Base de escritorio (polkit, xdg, fuentes)" "$(yn "$DESKTOP_BASE")"
  row 11 "Paquetes extra"                           "${EXTRA_PKGS:-ninguno}"
  row 12 "Driver de vídeo"                          "$(gpu_label "$GPU_DRIVER")"
}

run_menu() {
  local a
  msg "Configuración (Enter acepta el valor entre corchetes)"
  ask_text KEYMAP    "Teclado de la consola (ej. es, us, la-latin1)"           ok_keymap   yes; apply_keymap
  ask_text TIMEZONE  "Zona horaria (ej. America/Lima, Europe/Madrid, UTC)"     ok_timezone yes
  ask_text LOCALE    "Idioma del sistema (ej. es_ES.UTF-8, en_US.UTF-8)"       ok_locale   yes
  ask_text USERNAME  "Nombre de usuario"                                        ok_username yes
  ask_text HOST_NAME "Nombre del equipo"                                        ok_hostname yes
  if [[ $V3_OK == yes ]]; then
    echo "  Nota: el kernel CachyOS sale de un repo externo; si sus mirrors caen, 'pacman -Syu' falla hasta que lo comentes."
    ask_yn CACHYOS_KERNEL "¿Agregar el repo [cachyos-v3] e instalar el kernel linux-cachyos-bore?"
  else
    CACHYOS_KERNEL=no
  fi
  ask_yn CACHYOS_TWEAKS "¿Aplicar ajustes de rendimiento tipo CachyOS (sysctl y planificador de E/S)?"
  ask_yn ENABLE_GAMING  "¿Instalar gaming (Steam, GameMode, MangoHud y el repo [multilib] de Arch)?"
  ask_yn INSTALL_CODECS "¿Instalar códecs de vídeo (ffmpeg y GStreamer)?"
  ask_yn DESKTOP_BASE   "¿Instalar la base de escritorio (polkit, xdg-utils y fuentes)?"
  ask_text EXTRA_PKGS   "Paquetes extra (separados por espacios; - para vaciar)" ok_pkgs no
  ask_gpu
  while true; do
    echo
    show_summary
    read -rp "Número para cambiar, Enter para continuar, q para salir: " a
    case $a in
      "") break ;;
      q|Q) die "Cancelado." ;;
      1)  ask_text KEYMAP    "Teclado de la consola"  ok_keymap   yes; apply_keymap ;;
      2)  ask_text TIMEZONE  "Zona horaria"           ok_timezone yes ;;
      3)  ask_text LOCALE    "Idioma del sistema"     ok_locale   yes ;;
      4)  ask_text USERNAME  "Nombre de usuario"      ok_username yes ;;
      5)  ask_text HOST_NAME "Nombre del equipo"      ok_hostname yes ;;
      6)  if [[ $V3_OK == yes ]]; then
            ask_yn CACHYOS_KERNEL "¿Agregar el repo [cachyos-v3] e instalar el kernel linux-cachyos-bore?"
          else
            echo "  No disponible: la CPU no soporta x86-64-v3."
          fi ;;
      7)  ask_yn CACHYOS_TWEAKS "¿Aplicar ajustes de rendimiento tipo CachyOS?" ;;
      8)  ask_yn ENABLE_GAMING  "¿Instalar gaming (Steam, GameMode, MangoHud)?" ;;
      9)  ask_yn INSTALL_CODECS "¿Instalar códecs de vídeo?" ;;
      10) ask_yn DESKTOP_BASE   "¿Instalar la base de escritorio?" ;;
      11) ask_text EXTRA_PKGS   "Paquetes extra (- para vaciar)" ok_pkgs no ;;
      12) ask_gpu ;;
      *)  echo "  Opción no válida." ;;
    esac
  done
}

check_config() {  # sin menú (INTERACTIVE=no): valida los valores de la configuración
  [[ -n $USERNAME ]] || die "Con INTERACTIVE=no debes definir USERNAME."
  ok_username "$USERNAME" && ok_hostname "$HOST_NAME" && ok_keymap "$KEYMAP" \
    && ok_timezone "$TIMEZONE" && ok_locale "$LOCALE" && ok_pkgs "$EXTRA_PKGS" \
    || die "Configuración no válida."
}

# ───────────────────────── COMPROBACIONES ─────────────────────────
[[ $EUID -eq 0 ]]                    || die "Ejecuta este script como root."
[[ -d /sys/firmware/efi/efivars ]]   || die "No arrancaste en modo UEFI."

# Registro: stdout y stderr van a pantalla y al archivo (sin códigos de color). Las contraseñas no aparecen:
# se leen con 'read -s' y nunca se imprimen. Con pipes, pacman no dibuja barras de progreso (el log queda limpio).
START_TS=$(date +%s)
mkdir -p "$(dirname "$LOG_FILE")"
exec > >(tee >(sed -u -e 's/\x1b\[[0-9;?]*[A-Za-z]//g' -e 's/\r$//' >> "$LOG_FILE")) 2>&1
trap finish EXIT
echo "Registro de esta instalación: $LOG_FILE"

for c in lsblk sfdisk wipefs blkid awk udevadm mkfs.fat mkfs.ext4 basestrap fstabgen artix-chroot; do
  command -v "$c" >/dev/null 2>&1 || die "Falta el comando '$c' en este live ISO (¿es artix-dinit-base?)."
done

umount -R /mnt 2>/dev/null || true

net_ok artixlinux.org 443 \
  || die "Sin conexión a Internet: conecta la red (cable Ethernet o Wi-Fi) antes de ejecutar el script."

detect_hw
V3_OK=no
LD_HELP=$(/lib/ld-linux-x86-64.so.2 --help 2>/dev/null || true)
if [[ $LD_HELP == *'x86-64-v3 (supported, searched)'* ]]; then V3_OK=yes; fi
if [[ $INTERACTIVE == yes ]]; then run_menu; else check_config; apply_keymap; fi
set_gpu_pkgs

if [[ -z $DISK ]]; then choose_system_disk; fi
[[ -b $DISK ]] || die "No existe el disco $DISK."
if disk_in_use "$DISK"; then die "$DISK tiene particiones montadas (¿es el USB del instalador?)."; fi

msg "Disco del sistema"
lsblk -o NAME,SIZE,MODEL,TRAN,FSTYPE "$DISK"
echo
echo "Se BORRARÁ TODO el contenido de $DISK."
read -rp "Escribe el nombre del disco ($DISK) para confirmar: " CONFIRM
[[ $CONFIRM == "$DISK" ]] || die "Cancelado."

choose_data_disk

if [[ $CACHYOS_KERNEL == yes && $V3_OK != yes ]]; then
  warn "Esta CPU no soporta x86-64-v3 (o no se pudo comprobar): se instalará solo el kernel 'linux'."
  CACHYOS_KERNEL=no
fi

ask_pass "root";        ROOT_PASS=$PASS_RESULT
ask_pass "$USERNAME";   USER_PASS=$PASS_RESULT

ESP_DEV=$(part_of "$DISK" 1)
ROOT_DEV=$(part_of "$DISK" 2)

log_config

# ───────────────────────── RELOJ ─────────────────────────
if ! dinitctl start ntpd >/dev/null 2>&1; then
  command -v ntpd >/dev/null 2>&1 && ntpd -gq >/dev/null 2>&1 \
    || warn "No se pudo sincronizar la hora en el live; si los mirrors HTTPS fallan por certificados, ajusta la hora con 'date -s'."
fi

# ───────────────────────── PARTICIONADO ─────────────────────────
msg "Particionando $DISK (GPT: ESP $ESP_SIZE + raíz ext4)"
wipefs -af "$DISK"
sfdisk --quiet "$DISK" <<EOF
label: gpt
size=${ESP_SIZE}, type=U
type=L
EOF
partprobe "$DISK" 2>/dev/null || true
udevadm settle
wait_for_block "$ESP_DEV" "$ROOT_DEV"

if [[ $USE_DATA_DISK == yes ]]; then
  msg "Preparando $DATA_DISK (GPT + 1 partición ext4)"
  wipefs -af "$DATA_DISK"
  sfdisk --quiet "$DATA_DISK" <<EOF
label: gpt
type=L
EOF
  partprobe "$DATA_DISK" 2>/dev/null || true
  udevadm settle
  wait_for_block "$DATA_PART"
fi

msg "Formateando"
wipefs -af "$ESP_DEV" "$ROOT_DEV"
if [[ $USE_DATA_DISK == yes ]]; then wipefs -af "$DATA_PART"; fi
mkfs.fat -F 32 -n ESP "$ESP_DEV"
mkfs.ext4 -F -L ROOT "$ROOT_DEV"
if [[ $USE_DATA_DISK == yes ]]; then
  mkfs.ext4 -F -m 1 -L DATOS "$DATA_PART"
fi

msg "Montando"
mount "$ROOT_DEV" /mnt
mkdir -p /mnt/boot
mount "$ESP_DEV" /mnt/boot

# ───────────────────────── SISTEMA BASE ─────────────────────────
msg "Instalando el sistema base (basestrap)"
PKGS=(
  # Sistema
  base dinit elogind-dinit
  linux linux-firmware mkinitcpio
  dosfstools nano sudo
  networkmanager networkmanager-dinit
  limine efibootmgr
  # Video: Mesa + herramientas de diagnóstico (los drivers según la GPU se instalan en el chroot)
  mesa libva-utils mesa-utils vulkan-tools
  # Audio: PipeWire (con compatibilidad ALSA/PulseAudio/JACK) + WirePlumber + alsa-utils
  pipewire pipewire-alsa pipewire-pulse pipewire-jack wireplumber alsa-utils
)
if [[ $DESKTOP_BASE == yes ]]; then
  PKGS+=(polkit xdg-utils xdg-user-dirs ttf-dejavu)
fi
if [[ -n $UCODE ]]; then PKGS+=("$UCODE"); fi
basestrap /mnt "${PKGS[@]}"

msg "Generando fstab"
fstabgen -U /mnt > /mnt/etc/fstab
sed -i 's/relatime/noatime/' /mnt/etc/fstab

if [[ -n $DATA_PART ]]; then
  DATA_UUID=$(blkid -s UUID -o value "$DATA_PART")
  mkdir -p "/mnt${DATA_MOUNT}"
  printf 'UUID=%s\t%s\text4\tdefaults,noatime,nofail\t0 2\n' "$DATA_UUID" "$DATA_MOUNT" >> /mnt/etc/fstab
  # Se monta ahora para dejarlo a nombre del usuario al final
  mount "$DATA_PART" "/mnt${DATA_MOUNT}"
fi

ROOT_UUID=$(blkid -s UUID -o value "$ROOT_DEV")

cat > /mnt/root/install.env <<EOF
USERNAME='${USERNAME}'
KEYMAP='${KEYMAP}'
HOST_NAME='${HOST_NAME}'
TIMEZONE='${TIMEZONE}'
LOCALE='${LOCALE}'
ROOT_UUID='${ROOT_UUID}'
ZRAM_ALGO='${ZRAM_ALGO}'
ZRAM_SIZE='${ZRAM_SIZE}'
ENABLE_LIB32='${ENABLE_LIB32}'
ENABLE_GAMING='${ENABLE_GAMING}'
UCODE='${UCODE}'
GPU_PKGS='${GPU_PKGS}'
GPU32_PKGS='${GPU32_PKGS}'
GPU32_MULTILIB='${GPU32_MULTILIB}'
INSTALL_CODECS='${INSTALL_CODECS}'
EXTRA_PKGS='${EXTRA_PKGS}'
CACHYOS_KERNEL='${CACHYOS_KERNEL}'
CACHYOS_TWEAKS='${CACHYOS_TWEAKS}'
EOF

# ───────────────────────── CONFIGURACIÓN EN CHROOT ─────────────────────────
cat > /mnt/root/chroot-setup.sh <<'CHROOT'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "[ERROR] Falló la línea $LINENO de chroot-setup.sh." >&2' ERR
set -a; source /root/install.env; set +a

mkdir -p /etc/dinit.d/boot.d

enable_svc() {
  if [[ -e /etc/dinit.d/$1 ]]; then
    ln -sf "../$1" "/etc/dinit.d/boot.d/$1"
  else
    echo "[AVISO] No existe el servicio $1 en /etc/dinit.d" >&2
  fi
}

# Instala paquete por paquete: si uno no existe, avisa y sigue con el resto.
install_pkgs() {
  local p
  for p in "$@"; do
    pacman -S --needed --noconfirm -- "$p" || echo "[AVISO] No se pudo instalar: $p" >&2
  done
}

echo "==> Hora y locales"
ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
hwclock --systohc || echo "[AVISO] No se pudo ajustar el reloj de hardware (hwclock)." >&2
sed -i -e "s/^#\(${LOCALE} UTF-8\)/\1/" -e 's/^#\(en_US.UTF-8 UTF-8\)/\1/' /etc/locale.gen
locale-gen
printf 'LANG=%s\nLC_COLLATE=C\n' "$LOCALE" > /etc/locale.conf

echo "==> Teclado de la consola"
echo "KEYMAP=${KEYMAP}" > /etc/vconsole.conf
mkdir -p /etc/conf.d
echo "keymap=\"${KEYMAP}\"" > /etc/conf.d/keymaps

echo "==> Hostname"
echo "$HOST_NAME" > /etc/hostname
cat > /etc/hosts <<EOF
127.0.0.1  localhost
::1        localhost
127.0.1.1  ${HOST_NAME}.localdomain ${HOST_NAME}
EOF

echo "==> Usuario ${USERNAME}"
useradd -m -G wheel,audio,video -s /bin/bash "$USERNAME"
echo '%wheel ALL=(ALL:ALL) ALL' > /etc/sudoers.d/10-wheel
chmod 440 /etc/sudoers.d/10-wheel

echo "==> Red (NetworkManager)"
enable_svc NetworkManager

echo "==> Llavero de pacman"
[[ -f /etc/pacman.d/gnupg/trustdb.gpg ]] || pacman-key --init
pacman-key --populate artix || echo "[AVISO] No se pudo poblar el llavero de Artix." >&2

echo "==> Repositorios galaxy y lib32"
if ! grep -q '^\[galaxy\]' /etc/pacman.conf; then
  printf '\n[galaxy]\nInclude = /etc/pacman.d/mirrorlist\n' >> /etc/pacman.conf
fi
if [[ $ENABLE_LIB32 == yes || $ENABLE_GAMING == yes ]]; then
  if ! grep -q '^\[lib32\]' /etc/pacman.conf; then
    printf '\n[lib32]\nInclude = /etc/pacman.d/mirrorlist\n' >> /etc/pacman.conf
  fi
fi

echo "==> Sincronizando y actualizando (pacman -Syu)"
pacman -Syu --noconfirm

echo "==> Drivers de vídeo"
read -ra GPU_LIST <<< "${GPU_PKGS:-}"
install_pkgs "${GPU_LIST[@]}"

echo "==> zramen"
if ! bash -e <<'ZRAM'
pacman -S --needed --noconfirm zramen zramen-dinit
ln -sf ../zramen /etc/dinit.d/boot.d/zramen

ENVFILE=$(sed -n 's/^env-file[[:space:]]*=[[:space:]]*//p' /etc/dinit.d/zramen | head -n1)
if [[ -z $ENVFILE ]]; then
  ENVFILE=/etc/dinit.d/config/zramen.conf
  printf '\nenv-file = %s\n' "$ENVFILE" >> /etc/dinit.d/zramen
fi
[[ $ENVFILE == /* ]] || ENVFILE=/etc/dinit.d/$ENVFILE
mkdir -p "$(dirname "$ENVFILE")"
printf 'ZRAM_COMP_ALGORITHM=%s\nZRAM_SIZE=%s\n' "$ZRAM_ALGO" "$ZRAM_SIZE" > "$ENVFILE"
ZRAM
then
  echo "[AVISO] No se pudo configurar zramen; configúralo a mano tras el primer arranque." >&2
fi

echo "==> Servicios dinit de PipeWire (de usuario, opcionales)"
if ! bash -e <<'AUDIO'
pacman -S --needed --noconfirm pipewire-dinit pipewire-pulse-dinit wireplumber-dinit
AUDIO
then
  echo "[AVISO] No se instalaron los servicios dinit de PipeWire; usa start-audio (ver más abajo)." >&2
fi

if [[ $ENABLE_LIB32 == yes || $ENABLE_GAMING == yes ]]; then
  echo "==> Drivers de 32 bits (repo lib32 de Artix)"
  if ! bash -e <<'LIB32'
# Uno a uno: si falta un paquete en [lib32], avisa y sigue (un objetivo inexistente cancela toda la transacción).
# Los drivers de VA-API de 32 bits que solo están en [multilib] de Arch los instala el bloque de gaming.
for p in lib32-mesa $GPU32_PKGS; do
  pacman -S --needed --noconfirm "$p" || echo "[AVISO] No se pudo instalar: $p" >&2
done
LIB32
  then
    echo "[AVISO] No se pudo configurar lib32; hazlo a mano tras el primer arranque." >&2
  fi
fi

echo "==> Códecs de vídeo y Xwayland"
install_pkgs xorg-xwayland
if [[ ${INSTALL_CODECS:-yes} == yes ]]; then
  install_pkgs ffmpeg gst-plugins-good gst-plugins-bad gst-plugins-ugly gst-libav gst-plugin-pipewire
fi

echo "==> Terminal (kitty), fastfetch, fuentes y manuales"
install_pkgs kitty fastfetch man-db man-pages \
  noto-fonts noto-fonts-emoji ttf-liberation

if [[ -n ${EXTRA_PKGS:-} ]]; then
  echo "==> Paquetes extra"
  read -ra EXTRA_LIST <<< "$EXTRA_PKGS"
  install_pkgs "${EXTRA_LIST[@]}"
fi

echo "==> Hora (ntp) y TRIM semanal del SSD (cronie)"
install_pkgs ntp ntp-dinit cronie cronie-dinit
enable_svc ntpd
enable_svc cronie
mkdir -p /etc/cron.d
echo '0 4 * * 0 root /usr/bin/fstrim -av' > /etc/cron.d/fstrim

echo "==> Comprobando servicios de sesión (elogind, dbus)"
[[ -e /etc/dinit.d/boot.d/elogind || -e /etc/dinit.d/boot.d/logind ]] || enable_svc elogind
[[ -e /etc/dinit.d/boot.d/dbus ]] || enable_svc dbus

if [[ $ENABLE_GAMING == yes ]]; then
  echo "==> Gaming (multilib de Arch, Steam, GameMode, MangoHud)"
  mkdir -p /etc/security/limits.d
  echo '* hard nofile 524288' > /etc/security/limits.d/10-gaming.conf
  if ! bash -e <<'GAMING'
pacman -S --needed --noconfirm artix-archlinux-support lib32-artix-archlinux-support
if ! grep -q '^\[multilib\]' /etc/pacman.conf; then
  printf '\n[multilib]\nInclude = /etc/pacman.d/mirrorlist-arch\n' >> /etc/pacman.conf
fi
grep -q '^Server' /etc/pacman.d/mirrorlist-arch \
  || echo 'Server = https://geo.mirror.pkgbuild.com/$repo/os/$arch' >> /etc/pacman.d/mirrorlist-arch
pacman-key --populate archlinux
pacman -Syu --noconfirm
# Drivers de 32 bits ANTES de Steam, para que pacman no elija otro proveedor Vulkan/GL
for p in $GPU32_PKGS $GPU32_MULTILIB; do
  pacman -S --noconfirm --needed "$p" || echo "[AVISO] No se pudo instalar: $p" >&2
done
# Uno a uno: un paquete inexistente cancelaría toda la transacción y, con 'bash -e', también Steam.
for p in lib32-mesa lib32-vulkan-icd-loader lib32-pipewire lib32-libpulse lib32-alsa-plugins; do
  pacman -S --noconfirm --needed "$p" || echo "[AVISO] No se pudo instalar: $p" >&2
done
pacman -S --noconfirm --needed steam
pacman -S --noconfirm --needed gamemode lib32-gamemode mangohud lib32-mangohud \
  || echo "[AVISO] GameMode/MangoHud no se instalaron (son opcionales)." >&2
# Arch Wiki: sin el grupo 'gamemode' el demonio no puede cambiar el governor ni la prioridad de los procesos
if pacman -Q gamemode >/dev/null 2>&1; then
  getent group gamemode >/dev/null || groupadd -r gamemode
  usermod -aG gamemode "$USERNAME" || echo "[AVISO] No se pudo añadir $USERNAME al grupo gamemode." >&2
fi
GAMING
  then
    echo "[AVISO] No se pudo completar la parte de gaming (Steam); repítela a mano tras el primer arranque." >&2
  fi
fi

# El repo de CachyOS se añade AL FINAL de pacman.conf: pacman da prioridad a los repos de arriba,
# así que de cachyos-v3 solo salen los paquetes que Artix/Arch no tienen (el kernel).
if [[ $CACHYOS_KERNEL == yes ]]; then
  echo "==> Kernel CachyOS (linux-cachyos-bore, repo cachyos-v3)"
  cp /etc/pacman.conf /etc/pacman.conf.pre-cachyos
  if ! bash -e <<'CACHY'
pacman-key --recv-keys F3B607488DB35A47 --keyserver keyserver.ubuntu.com
pacman-key --lsign-key F3B607488DB35A47
pacman -U --noconfirm 'https://mirror.cachyos.org/repo/x86_64/cachyos/cachyos-keyring-20240331-1-any.pkg.tar.zst' \
  || echo "[AVISO] No se instaló cachyos-keyring; se sigue solo con la clave maestra." >&2

# pacman estándar solo acepta paquetes x86_64_v3 si se lo indicamos en Architecture
if grep -q '^Architecture' /etc/pacman.conf; then
  sed -i -E 's/^Architecture.*/Architecture = x86_64 x86_64_v3/' /etc/pacman.conf
else
  sed -i '/^\[options\]/a Architecture = x86_64 x86_64_v3' /etc/pacman.conf
fi

cat > /etc/pacman.d/cachyos-v3-mirrorlist <<'EOF'
# Mirrors de CachyOS (repo optimizado x86-64-v3)
Server = https://cdn77.cachyos.org/repo/x86_64_v3/$repo
Server = https://mirror.cachyos.org/repo/x86_64_v3/$repo
EOF
printf '\n[cachyos-v3]\nInclude = /etc/pacman.d/cachyos-v3-mirrorlist\n' >> /etc/pacman.conf

pacman -Syu --noconfirm
pacman -S --needed --noconfirm linux-cachyos-bore
CACHY
  then
    cp /etc/pacman.conf.pre-cachyos /etc/pacman.conf
    echo "[AVISO] No se pudo instalar el kernel de CachyOS; se usará solo el kernel 'linux' estándar." >&2
  fi
fi

if [[ $CACHYOS_TWEAKS == yes ]]; then
  echo "==> Ajustes tipo CachyOS (sysctl y planificador de E/S)"
  mkdir -p /etc/sysctl.d
  cat > /etc/sysctl.d/99-cachyos-like.conf <<'EOF'
# Ajustes inspirados en CachyOS, pensados para 8 GB de RAM con zram
vm.swappiness = 100
vm.vfs_cache_pressure = 50
vm.page-cluster = 0
vm.dirty_bytes = 268435456
vm.dirty_background_bytes = 67108864
vm.dirty_writeback_centisecs = 1500
kernel.nmi_watchdog = 0
EOF
  if [[ $ENABLE_GAMING == yes ]]; then
    echo 'vm.max_map_count = 2147483642' >> /etc/sysctl.d/99-cachyos-like.conf
  fi
  mkdir -p /etc/udev/rules.d
  cat > /etc/udev/rules.d/60-ioschedulers.rules <<'EOF'
# HDD -> bfq ; SSD SATA -> mq-deadline
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="1", ATTR{queue/scheduler}="bfq"
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="mq-deadline"
EOF
fi

echo "==> Script de arranque de audio (start-audio)"
cat > /usr/local/bin/start-audio <<'EOF'
#!/bin/sh
# Arranca PipeWire, pipewire-pulse y WirePlumber para el usuario actual.
# PipeWire no usa un servicio del sistema: llama a este script desde el
# autostart de tu entorno (exec-once, ~/.xinitrc, ~/.xprofile, etc.).
start() {
  pgrep -u "$(id -u)" -x "$1" >/dev/null 2>&1 || setsid "/usr/bin/$1" >/dev/null 2>&1 &
}
start pipewire
sleep 0.5
start pipewire-pulse
start wireplumber
EOF
chmod 755 /usr/local/bin/start-audio

echo "==> initramfs"
mkinitcpio -P

CACHY_OK=no
if [[ -f /boot/vmlinuz-linux-cachyos-bore && -f /boot/initramfs-linux-cachyos-bore.img ]]; then
  CACHY_OK=yes
elif [[ $CACHYOS_KERNEL == yes ]]; then
  echo "[AVISO] No se encontró el kernel linux-cachyos-bore en /boot; Limine arrancará solo el kernel 'linux'." >&2
fi

echo "==> Limine (UEFI)"
mkdir -p /boot/EFI/BOOT
cp /usr/share/limine/BOOTX64.EFI /boot/EFI/BOOT/BOOTX64.EFI
echo 'timeout: 5' > /boot/EFI/BOOT/limine.conf

write_entry() {  # write_entry "Nombre" kernel initramfs [parámetros extra de la línea de comandos]
  {
    printf '\n/%s\n' "$1"
    printf '    protocol: linux\n'
    printf '    path: boot():/%s\n' "$2"
    printf '    cmdline: root=UUID=%s rw%s\n' "$ROOT_UUID" "${4:+ $4}"
    if [[ -n ${UCODE:-} ]]; then printf '    module_path: boot():/%s.img\n' "$UCODE"; fi
    printf '    module_path: boot():/%s\n' "$3"
  } >> /boot/EFI/BOOT/limine.conf
}

if [[ $CACHY_OK == yes ]]; then
  write_entry "Artix Linux (CachyOS BORE)" vmlinuz-linux-cachyos-bore initramfs-linux-cachyos-bore.img loglevel=3
fi

write_entry "Artix Linux (kernel linux)" vmlinuz-linux initramfs-linux.img loglevel=3

# El paquete linux ya no trae preset 'fallback': la entrada solo se crea si la imagen existe.
if [[ -f /boot/initramfs-linux-fallback.img ]]; then
  write_entry "Artix Linux (fallback)" vmlinuz-linux initramfs-linux-fallback.img
fi

mkdir -p /etc/pacman.d/hooks
cat > /etc/pacman.d/hooks/99-limine.hook <<'EOF'
[Trigger]
Operation = Install
Operation = Upgrade
Type = Package
Target = limine

[Action]
Description = Desplegando Limine tras la actualización...
When = PostTransaction
Exec = /usr/bin/cp /usr/share/limine/BOOTX64.EFI /boot/EFI/BOOT/BOOTX64.EFI
EOF
CHROOT

chmod +x /mnt/root/chroot-setup.sh
msg "Configurando el sistema (chroot)"
artix-chroot /mnt /root/chroot-setup.sh

msg "Asignando contraseñas"
printf 'root:%s\n'        "$ROOT_PASS" | artix-chroot /mnt chpasswd
printf '%s:%s\n' "$USERNAME" "$USER_PASS" | artix-chroot /mnt chpasswd

if [[ -n $DATA_PART ]]; then
  msg "Dejando $DATA_MOUNT a nombre de $USERNAME"
  artix-chroot /mnt chown "$USERNAME:$USERNAME" "$DATA_MOUNT"
fi

log_state
verify_install /mnt

# ───────────────────────── ENTRADA UEFI ─────────────────────────
msg "Registrando la entrada de arranque UEFI"
EFI_CMD=(efibootmgr)
command -v efibootmgr >/dev/null || EFI_CMD=(artix-chroot /mnt efibootmgr)
"${EFI_CMD[@]}" --create --disk "$DISK" --part 1 \
  --label "Artix Linux (Limine)" \
  --loader '\EFI\BOOT\BOOTX64.EFI' --unicode \
  || warn "No se pudo crear la entrada NVRAM; elige el disco en el menú UEFI (ruta por defecto EFI/BOOT)."

# ───────────────────────── LIMPIEZA ─────────────────────────
rm -f /mnt/root/install.env /mnt/root/chroot-setup.sh
log_summary
save_log
sync
umount -R /mnt

msg "Instalación terminada. Retira el USB y reinicia."
echo "Usuario: $USERNAME | Teclado: $KEYMAP | Sistema: $DISK | Datos: ${DATA_DISK:-ninguno}"

GPU_NOTE=""
if [[ $GPU_DRIVER == intel-legacy ]]; then
  GPU_NOTE="            Con GPU Intel antigua el soporte Vulkan es incompleto: si un juego con Proton falla,
            prueba PROTON_USE_WINED3D=1 en las opciones de lanzamiento."
fi
KERNEL_NOTE=""
if [[ $CACHYOS_KERNEL == yes ]]; then
  KERNEL_NOTE="  - Kernel: 'uname -r' debería mostrar la versión cachyos-bore (si no, arrancó el kernel 'linux':
            revisa los [AVISO] de la instalación). Limine tiene ambas entradas."
fi
TWEAKS_NOTE=""
if [[ $CACHYOS_TWEAKS == yes ]]; then
  TWEAKS_NOTE="  - Ajustes: 'sysctl vm.swappiness' (100) y 'cat /sys/block/sd*/queue/scheduler'
             (bfq en el HDD, mq-deadline en el SSD) confirman que se aplicaron."
fi
UPDATE_NOTE="  - Actualizar: usa siempre 'sudo pacman -Syu' (nunca '-Sy' ni '-Sy paquete')."
if [[ $CACHYOS_KERNEL == yes ]]; then
  UPDATE_NOTE+=" Si un mirror de
               CachyOS está caído, pacman -Syu falla entero: comenta '[cachyos-v3]' en
               /etc/pacman.conf, actualiza y vuelve a descomentarlo. Tras actualizar el kernel, reinicia."
fi
DATA_NOTE=""
if [[ -n $DATA_PART ]]; then
  DATA_NOTE="  - Datos:  el HDD está en ${DATA_MOUNT} (nofail: si falta, el sistema arranca igual).
            En Steam: Ajustes > Almacenamiento > añade ${DATA_MOUNT}/SteamLibrary."
fi
cat <<EOF

Después del primer arranque:
${KERNEL_NOTE}
${TWEAKS_NOTE}
${DATA_NOTE}
  - Audio: ejecuta 'alsamixer' y desmutea la salida con la tecla M. Si usas HDMI u otra salida,
           elige el dispositivo con 'wpctl status'. Llama a 'start-audio' desde el
           autostart de tu entorno.
  - Video: comprueba con 'glxinfo -B', 'vainfo' y 'vulkaninfo --summary'.
  - zram:  comprueba con 'zramctl && swapon --show'.
  - Gaming: Steam ya está instalado si lo elegiste en el menú.
${GPU_NOTE}
  - Escritorio: este script no instala ninguno. Xwayland, PipeWire y kitty ya están listos
                (y polkit y xdg-utils si elegiste la base de escritorio); instala el que prefieras.
${UPDATE_NOTE}
  - Servicios: comprueba con 'dinitctl list' que elogind, dbus, NetworkManager,
               zramen, ntpd y cronie estén activos.
  - Registro: copia de la instalación en /var/log/artix-install.log (en el live: ${LOG_FILE}).
              Solo avisos y errores: grep -aE '\[(AVISO|ERROR|FALTA)\]|^error:' /var/log/artix-install.log
EOF
sync
sleep 1
read -rp "¿Reiniciar ahora? [s/N] " R
[[ ${R,,} == s ]] && reboot
exit 0
