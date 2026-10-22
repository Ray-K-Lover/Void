#!/usr/bin/env bash
#
# Instalador de Artix Linux "tipo CachyOS" (sin systemd)   [versión v5]
#   init: dinit | UEFI + GPT | ext4 | Limine | NetworkManager | zramen
#   + kernel linux-cachyos-bore (x86-64-v3, repo cachyos-v3) con el kernel 'linux' como respaldo
#   + ajustes tipo CachyOS (sysctl y planificador de E/S)
#   + sonido (PipeWire), vídeo (Mesa/Vulkan/VA-API/códecs) y gaming (Steam)
#   + kitty, fastfetch, sincronización de hora (ntp) y TRIM semanal del SSD
#   + HDD de datos formateado en ext4 para juegos y archivos
#   Pensado para un i5-4440 (Haswell) con gráficos Intel integrados: SSD para el sistema y HDD para datos.
#   El entorno de escritorio (Labwc + Noctalia + emptty) se instala después.
#
# Pensado al 100% para una instalación TOTALMENTE LIMPIA: los discos se dejan completamente
# vacíos (no conserva datos ni sistemas existentes).
#
# Uso (desde el live ISO artix-dinit-base, como root, arrancado en modo UEFI):
#   bash artix-install.sh
#
# ¡ADVERTENCIA! Este script BORRA TODO el disco del sistema (DISK) y TODO el disco de datos (DATA_DISK).

set -Eeuo pipefail
trap 'echo -e "\n[ERROR] Falló la línea $LINENO. Instalación interrumpida." >&2' ERR

# ───────────────────────── CONFIGURACIÓN ─────────────────────────
DISK=""                    # disco del SISTEMA (SE BORRA POR COMPLETO). Vacío = se elige al ejecutar (sugiere el SSD)
USERNAME="mitski"          # usuario normal
KEYMAP="es"                # teclado de la consola
HOST_NAME="artix"          # nombre del equipo
TIMEZONE="America/Lima"    # zona horaria
LOCALE="es_PE.UTF-8"       # idioma del sistema
ESP_SIZE="1GiB"            # tamaño de la partición EFI (montada en /boot)
ZRAM_ALGO="zstd"           # algoritmo de compresión de zram
ZRAM_SIZE="50"             # tamaño de zram en % de la RAM
CACHYOS_KERNEL="yes"       # yes = linux-cachyos-bore desde el repo cachyos-v3 (el kernel 'linux' queda de respaldo)
CACHYOS_TWEAKS="yes"       # yes = sysctl y planificador de E/S tipo CachyOS
USE_DATA_DISK="yes"        # yes = el HDD se BORRA y se formatea en ext4 para juegos y datos | no = no tocarlo
DATA_DISK=""               # disco de datos (SE BORRA POR COMPLETO). Vacío = se elige al ejecutar (sugiere el HDD)
DATA_MOUNT="/mnt/datos"    # dónde se monta el disco de datos (ej. biblioteca de Steam en /mnt/datos/SteamLibrary)
ENABLE_GAMING="yes"        # yes = Steam + [multilib] de Arch + GameMode + MangoHud (implica ENABLE_LIB32)
EXTRA_PKGS=""              # paquetes extra, ej: "base-devel htop"
DESKTOP_BASE="yes"         # yes = polkit (el agente lo aporta Noctalia), xdg-utils, xdg-user-dirs y fuentes
NOCTALIA_DEPS="no"         # yes = base-devel, git y deps para COMPILAR Noctalia (no hace falta: está en galaxy)
ENABLE_LIB32="no"          # yes = activa [lib32] e instala mesa/vulkan/vaapi de 32 bits (Steam, Wine...)
# ─────────────────────────────────────────────────────────────────

msg()  { echo -e "\n\e[1;32m==>\e[0m \e[1m$*\e[0m"; }
warn() { echo -e "\e[1;33m[AVISO]\e[0m $*" >&2; }
die()  { echo -e "\e[1;31m[ERROR]\e[0m $*" >&2; exit 1; }

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

# ───────────────────────── COMPROBACIONES ─────────────────────────
[[ $EUID -eq 0 ]]                    || die "Ejecuta este script como root."
[[ -d /sys/firmware/efi/efivars ]]   || die "No arrancaste en modo UEFI."

for c in lsblk sfdisk wipefs blkid awk udevadm mkfs.fat mkfs.ext4 basestrap fstabgen artix-chroot; do
  command -v "$c" >/dev/null 2>&1 || die "Falta el comando '$c' en este live ISO (¿es artix-dinit-base?)."
done

umount -R /mnt 2>/dev/null || true

loadkeys "$KEYMAP" || warn "No se pudo cargar el teclado '$KEYMAP'."
ping -c1 -W3 artixlinux.org >/dev/null 2>&1 \
  || die "Sin conexión a Internet: conecta la red (cable Ethernet o Wi-Fi) antes de ejecutar el script."

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

if [[ $CACHYOS_KERNEL == yes ]]; then
  LD_HELP=$(/lib/ld-linux-x86-64.so.2 --help 2>/dev/null || true)
  if [[ $LD_HELP != *'x86-64-v3 (supported, searched)'* ]]; then
    warn "Esta CPU no soporta x86-64-v3 (o no se pudo comprobar): se instalará solo el kernel 'linux'."
    CACHYOS_KERNEL=no
  fi
fi

ask_pass "root";        ROOT_PASS=$PASS_RESULT
ask_pass "$USERNAME";   USER_PASS=$PASS_RESULT

ESP_DEV=$(part_of "$DISK" 1)
ROOT_DEV=$(part_of "$DISK" 2)

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
sleep 1

if [[ $USE_DATA_DISK == yes ]]; then
  msg "Preparando $DATA_DISK (GPT + 1 partición ext4)"
  wipefs -af "$DATA_DISK"
  sfdisk --quiet "$DATA_DISK" <<EOF
label: gpt
type=L
EOF
  partprobe "$DATA_DISK" 2>/dev/null || true
  udevadm settle
  sleep 1
fi

msg "Formateando"
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
  linux linux-firmware intel-ucode mkinitcpio
  dosfstools nano sudo
  networkmanager networkmanager-dinit
  limine efibootmgr
  # Video: Mesa + Intel HD Graphics (Haswell) + VA-API + herramientas de diagnóstico
  mesa vulkan-intel libva-intel-driver libva-utils mesa-utils vulkan-tools
  # Audio: PipeWire (con compatibilidad ALSA/PulseAudio/JACK) + WirePlumber + alsa-utils
  pipewire pipewire-alsa pipewire-pulse pipewire-jack wireplumber alsa-utils
)
if [[ $DESKTOP_BASE == yes ]]; then
  PKGS+=(polkit xdg-utils xdg-user-dirs ttf-dejavu)
fi
read -ra EXTRA <<< "$EXTRA_PKGS"
basestrap /mnt "${PKGS[@]}" "${EXTRA[@]}"

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
NOCTALIA_DEPS='${NOCTALIA_DEPS}'
CACHYOS_KERNEL='${CACHYOS_KERNEL}'
CACHYOS_TWEAKS='${CACHYOS_TWEAKS}'
EOF

# ───────────────────────── CONFIGURACIÓN EN CHROOT ─────────────────────────
cat > /mnt/root/chroot-setup.sh <<'CHROOT'
#!/usr/bin/env bash
set -Eeuo pipefail
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
    pacman -S --needed --noconfirm "$p" || echo "[AVISO] No se pudo instalar: $p" >&2
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
pacman -S --needed --noconfirm lib32-mesa lib32-vulkan-intel lib32-libva-intel-driver
LIB32
  then
    echo "[AVISO] No se pudo configurar lib32; hazlo a mano tras el primer arranque." >&2
  fi
fi

echo "==> Códecs de vídeo y Xwayland"
install_pkgs xorg-xwayland ffmpeg \
  gst-plugins-good gst-plugins-bad gst-plugins-ugly gst-libav gst-plugin-pipewire

echo "==> Terminal (kitty), fastfetch, fuentes y manuales"
install_pkgs kitty fastfetch man-db man-pages \
  noto-fonts noto-fonts-emoji ttf-liberation

echo "==> Hora (ntp) y TRIM semanal del SSD (cronie)"
install_pkgs ntp ntp-dinit cronie cronie-dinit
enable_svc ntpd
enable_svc cronie
echo '0 4 * * 0 root /usr/bin/fstrim -av' > /etc/cron.d/fstrim

echo "==> Comprobando servicios de sesión (elogind, dbus)"
[[ -e /etc/dinit.d/boot.d/elogind || -e /etc/dinit.d/boot.d/logind ]] || enable_svc elogind
[[ -e /etc/dinit.d/boot.d/dbus ]] || enable_svc dbus

if [[ ${NOCTALIA_DEPS:-no} == yes ]]; then
  echo "==> Herramientas y dependencias para compilar Noctalia"
  install_pkgs base-devel git meson just \
    wayland wayland-protocols libglvnd freetype2 fontconfig cairo pango \
    libxkbcommon glib2 sdbus-cpp libpipewire libwireplumber polkit pam curl \
    libwebp librsvg libqalculate jemalloc
fi

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
pacman -S --noconfirm --needed lib32-mesa lib32-vulkan-intel lib32-vulkan-icd-loader \
  lib32-libva-intel-driver lib32-pipewire lib32-libpulse lib32-alsa-plugins
pacman -S --noconfirm --needed steam
pacman -S --noconfirm --needed gamemode lib32-gamemode mangohud lib32-mangohud \
  || echo "[AVISO] GameMode/MangoHud no se instalaron (son opcionales)." >&2
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

if [[ $CACHY_OK == yes ]]; then
  cat >> /boot/EFI/BOOT/limine.conf <<EOF

/Artix Linux (CachyOS BORE)
    protocol: linux
    path: boot():/vmlinuz-linux-cachyos-bore
    cmdline: root=UUID=${ROOT_UUID} rw loglevel=3
    module_path: boot():/intel-ucode.img
    module_path: boot():/initramfs-linux-cachyos-bore.img
EOF
fi

cat >> /boot/EFI/BOOT/limine.conf <<EOF

/Artix Linux (kernel linux)
    protocol: linux
    path: boot():/vmlinuz-linux
    cmdline: root=UUID=${ROOT_UUID} rw loglevel=3
    module_path: boot():/intel-ucode.img
    module_path: boot():/initramfs-linux.img

/Artix Linux (fallback)
    protocol: linux
    path: boot():/vmlinuz-linux
    cmdline: root=UUID=${ROOT_UUID} rw
    module_path: boot():/intel-ucode.img
    module_path: boot():/initramfs-linux-fallback.img
EOF

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
sync
umount -R /mnt

msg "Instalación terminada. Retira el USB y reinicia."
echo "Usuario: $USERNAME | Teclado: $KEYMAP | Sistema: $DISK | Datos: ${DATA_DISK:-ninguno}"

DATA_NOTE=""
if [[ -n $DATA_PART ]]; then
  DATA_NOTE="  - Datos:  el HDD está en ${DATA_MOUNT} (nofail: si falta, el sistema arranca igual).
            En Steam: Ajustes > Almacenamiento > añade ${DATA_MOUNT}/SteamLibrary."
fi
cat <<EOF

Después del primer arranque:
  - Kernel: 'uname -r' debería mostrar la versión cachyos-bore (si no, arrancó el kernel 'linux':
            revisa los [AVISO] de la instalación). Limine tiene ambas entradas.
  - Ajustes: 'sysctl vm.swappiness' (100) y 'cat /sys/block/sd*/queue/scheduler'
             (bfq en el HDD, mq-deadline en el SSD) confirman que se aplicaron.
${DATA_NOTE}
  - Audio: ejecuta 'alsamixer' y desmutea la salida con la tecla M. Tu salida es HDMI:
           elige el dispositivo con 'wpctl status'. Llama a 'start-audio' desde el
           autostart de tu entorno.
  - Video: comprueba con 'glxinfo -B', 'vainfo' y 'vulkaninfo --summary'.
  - zram:  comprueba con 'zramctl && swapon --show'.
  - Gaming: Steam ya está instalado si ENABLE_GAMING=yes. Los gráficos Haswell tienen
            soporte Vulkan incompleto: si un juego con Proton falla, prueba con
            PROTON_USE_WINED3D=1 en las opciones de lanzamiento.
  - Entorno: Xwayland, polkit, PipeWire y kitty ya están listos. Falta instalar:
               sudo pacman -S labwc emptty emptty-dinit noctalia
             No hace falta un agente polkit aparte: usa el integrado de Noctalia.
  - Servicios: comprueba con 'dinitctl list' que elogind, dbus, NetworkManager,
               zramen, ntpd y cronie estén activos.
EOF
read -rp "¿Reiniciar ahora? [s/N] " R
[[ ${R,,} == s ]] && reboot
exit 0
