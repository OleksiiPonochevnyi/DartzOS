#!/bin/bash
# =====================================================================
#  Pasar tu USB a la ultima version de DartzOS SIN perder nada.
#  Hace todo solo: copia de seguridad -> descarga -> grabar -> reiniciar.
#  Al volver, el asistente encuentra la copia y lo recupera todo.
# =====================================================================
set -uo pipefail
[ "$(id -u)" = 0 ] || exec sudo -E bash "$0" "$@"
U="${SUDO_USER:-}"
ISO_URL="https://github.com/OleksiiPonochevnyi/DartzOS/releases/download/ultima/DartzOS.iso"
SHA_URL="https://github.com/OleksiiPonochevnyi/DartzOS/releases/download/ultima/DartzOS.iso.sha256"

echo "🐶 Pasar a la última versión de DartzOS sin perder nada"
echo
[ -d /run/live ] || { echo "❌ Esto solo funciona arrancando DartzOS desde el USB."; exit 1; }
if ! grep -qw toram /proc/cmdline; then
  echo "❌ Tu DartzOS ya es una versión nueva: usa  sudo dartz-actualizar"; exit 1; fi
[ -n "$U" ] && [ "$U" != root ] && [ "$U" != dartz ] || { echo "❌ Ejecútalo desde tu usuario."; exit 1; }
USB=$(lsblk -rpno NAME,TYPE,LABEL | awk '$2=="disk" && $3=="DartzOS"{print $1; exit}')
[ -n "$USB" ] || { echo "❌ No encuentro el USB de DartzOS."; exit 1; }

# dartz-copia (por si tu version aun no lo tiene)
mkdir -p /usr/local/sbin
cat > /usr/local/sbin/dartz-copia <<'DZ_COPIA_FIN'
#!/bin/bash
# Copia de seguridad de DartzOS: tu cuenta, tus archivos, tus apps y tus redes WiFi.
#   sudo dartz-copia guardar            -> guarda una copia en otro disco (BOOTCAMP, otro USB...)
#   sudo dartz-copia restaurar ARCHIVO  -> la recupera en un DartzOS recien grabado
set -uo pipefail
[ "$(id -u)" = 0 ] || exec sudo "$0" "$@"
MODO="${1:-}"
META=/tmp/dartz-copia
PUNTO=/mnt/dartz-copia

dartz_disco() {   # el USB de DartzOS (para no guardar la copia en el mismo USB)
  lsblk -rpno NAME,TYPE,LABEL | awk '$2=="disk" && $3=="DartzOS"{print $1; exit}'
}

guardar() {
  U="${SUDO_USER:-}"
  if [ -z "$U" ] || [ "$U" = root ] || [ "$U" = dartz ]; then
    echo "Ejecutalo desde tu usuario:  sudo dartz-copia guardar"; exit 1; fi
  H=$(getent passwd "$U" | cut -d: -f6)
  echo "🐶 Copia de seguridad de DartzOS para $U"
  echo
  USB=$(dartz_disco)
  mapfile -t OPC < <(lsblk -rpno NAME,FSTYPE,LABEL,SIZE,TYPE | awk -v usb="$USB" '
     $5=="part" && $2 ~ /^(ntfs|exfat|vfat|ext4|btrfs)$/ && index($1, usb)!=1 && $3!="persistence" {print $1" "$2" "$3" "$4}')
  ELEGIDO="${2:-}"
  if [ -z "$ELEGIDO" ]; then   # si hay una particion BOOTCAMP (Windows del Mac), esa directamente
    for o in "${OPC[@]}"; do set -- $o; [ "${3:-}" = BOOTCAMP ] && ELEGIDO=$1; done
  fi
  if [ ${#OPC[@]} -eq 0 ]; then
    echo "❌ No encuentro ningún disco donde guardarla."
    echo "   Mete otro USB o disco (FAT32, exFAT o NTFS) y vuelve a probar."; exit 1; fi
  if [ -n "$ELEGIDO" ]; then
    DEV=$ELEGIDO; FS=$(lsblk -rno FSTYPE "$DEV" | head -1)
    echo "   Se guarda en $(lsblk -rno LABEL "$DEV" | head -1) ($DEV)"
  else
    echo "¿Dónde la guardo? (tiene que ser otro disco, no este USB)"
    i=1; for o in "${OPC[@]}"; do set -- $o; printf "  %d) %-10s %-6s %s (%s)\n" $i "${3:-sin-nombre}" "$2" "$1" "$4"; i=$((i+1)); done
    read -rp "Número: " N
    [[ "$N" =~ ^[0-9]+$ ]] && [ "$N" -ge 1 ] && [ "$N" -le ${#OPC[@]} ] || { echo "Número no válido"; exit 1; }
    set -- ${OPC[$((N-1))]}; DEV=$1; FS=$2
  fi
  mkdir -p "$PUNTO"; umount "$PUNTO" 2>/dev/null
  DESTINO=$(lsblk -rno MOUNTPOINT "$DEV" | head -1)
  if [ -z "$DESTINO" ]; then
    if [ "$FS" = ntfs ]; then mount -t ntfs3 "$DEV" "$PUNTO" 2>/dev/null || mount -t ntfs-3g "$DEV" "$PUNTO"
    else mount "$DEV" "$PUNTO"; fi || {
      echo "❌ No he podido abrir ese disco para escribir."
      [ "$FS" = ntfs ] && echo "   Si es la partición de Windows (BOOTCAMP): arranca Windows, desactiva el «Inicio rápido» y apágalo del todo."
      exit 1; }
    DESTINO=$PUNTO
  fi
  touch "$DESTINO/.dartz-prueba" 2>/dev/null && rm -f "$DESTINO/.dartz-prueba" || { echo "❌ Ese disco es de solo lectura."; exit 1; }

  echo "🐶 [1/3] Preparando (cuenta, apps, redes WiFi)..."
  rm -rf "$META"; mkdir -p "$META/apt/sources" "$META/apt/keys" "$META/red"
  {
    printf 'USUARIO=%q\n' "$U"
    printf 'UID_U=%q\n' "$(id -u "$U")"
    printf 'NOMBRE=%q\n' "$(getent passwd "$U" | cut -d: -f5 | cut -d, -f1)"
    printf 'GRUPOS=%q\n' "$(id -nG "$U" | tr ' ' ',')"
  } > "$META/cuenta.txt"
  grep "^$U:" /etc/shadow | cut -d: -f2 > "$META/clave.txt"; chmod 600 "$META/clave.txt"
  apt-mark showmanual > "$META/paquetes.txt" 2>/dev/null
  cp -a /etc/apt/sources.list.d/. "$META/apt/sources/" 2>/dev/null
  cp -a /etc/apt/trusted.gpg.d/. "$META/apt/keys/" 2>/dev/null
  mkdir -p "$META/apt/keyrings-usr" "$META/apt/keyrings-etc"
  for k in /usr/share/keyrings/*; do   # solo las llaves que no son de Debian (apps que instalaste)
    dpkg -S "$k" >/dev/null 2>&1 || cp -a "$k" "$META/apt/keyrings-usr/"
  done
  cp -a /etc/apt/keyrings/. "$META/apt/keyrings-etc/" 2>/dev/null
  cp -a /etc/NetworkManager/system-connections/. "$META/red/" 2>/dev/null
  cat /etc/dartzos/version > "$META/version.txt" 2>/dev/null
  TAM=$(du -sm --exclude="$H/.cache" --exclude="$H/.local/share/Trash" "$H" 2>/dev/null | cut -f1)
  LIBRE=$(df -Pm "$DESTINO" | awk 'NR==2{print $4}')
  echo "   Tu carpeta ocupa unos $TAM MB; en el disco hay $LIBRE MB libres."
  [ "$LIBRE" -gt "$TAM" ] || { echo "❌ No cabe. Libera espacio o borra Descargas grandes."; exit 1; }

  F="$DESTINO/DartzOS-copia-$U-$(date +%Y-%m-%d).tar"
  if command -v zstd >/dev/null; then COMP="zstd -T0 -3"; F="$F.zst"; else COMP="gzip -1"; F="$F.gz"; fi
  echo "🐶 [2/3] Guardando tus archivos (puede tardar unos minutos)..."
  sync
  TARCMD=(tar -cf - --exclude="home/$U/.cache" --exclude="home/$U/.local/share/Trash" \
          --exclude="home/$U/.config/google-chrome/*/Service Worker/CacheStorage" \
          -C /tmp dartz-copia -C / "home/$U")
  if [ "$FS" = vfat ]; then   # FAT32 no admite archivos de mas de 4 GB: se trocea
    "${TARCMD[@]}" 2>/dev/null | $COMP | split -b 3900M -d - "$F.parte-"
  else
    "${TARCMD[@]}" 2>/dev/null | $COMP > "$F"
  fi
  chmod 600 "$F"* 2>/dev/null   # lleva tu contraseña (cifrada) y las de tus WiFi
  sync; rm -rf "$META"
  echo "🐶 [3/3] Listo"
  echo
  echo "✅ Copia guardada en: $F"
  echo "$F" > /tmp/dartz-copia-ultima
  echo "   Ahora puedes grabar DartzOS nuevo con Etcher. Al arrancarlo, el asistente"
  echo "   te preguntará si tienes una copia: elige este archivo y todo volverá."
  [ "${DARTZ_NO_DESMONTAR:-}" ] || { [ "$DESTINO" = "$PUNTO" ] && umount "$PUNTO" 2>/dev/null; }
}

buscar() {   # encuentra la copia mas reciente en cualquier disco conectado (para el asistente)
  USB=$(dartz_disco)
  for d in $(lsblk -rpno NAME,FSTYPE,TYPE | awk '$3=="part" && $2 ~ /^(ntfs|exfat|vfat|ext4|btrfs)$/{print $1}'); do
    [ -n "$USB" ] && [[ "$d" == "$USB"* ]] && continue
    M=$(lsblk -rno MOUNTPOINT "$d" | head -1)
    if [ -z "$M" ]; then
      M="/mnt/dartz-busca/$(basename "$d")"; mkdir -p "$M"
      FS=$(lsblk -rno FSTYPE "$d" | head -1)
      if [ "$FS" = ntfs ]; then mount -o ro -t ntfs3 "$d" "$M" 2>/dev/null || mount -o ro -t ntfs-3g "$d" "$M" 2>/dev/null
      else mount -o ro "$d" "$M" 2>/dev/null; fi || { rmdir "$M"; continue; }
    fi
    ls -1t "$M"/DartzOS-copia-*.tar.* 2>/dev/null | grep -v '\.parte-0[1-9]' | head -1
  done | head -1
}

restaurar() {
  F="${2:-}"
  [ -n "$F" ] && [ -e "$F" ] || { echo "Uso: sudo dartz-copia restaurar ARCHIVO"; exit 1; }
  leer() {   # saca el contenido de la copia (sea entera o en trozos)
    if [[ "$F" == *.parte-* ]]; then cat "${F%.parte-*}".parte-*; else cat "$F"; fi |
      if [[ "$F" == *.zst* ]]; then zstd -dc -T0; else gzip -dc; fi
  }
  echo "10"; echo "# Leyendo la copia..."
  rm -rf "$META"; leer | tar -xf - -C /tmp dartz-copia || { echo "# ❌ La copia está dañada"; exit 1; }
  . "$META/cuenta.txt"
  echo "25"; echo "# Recreando tu cuenta ($USUARIO)..."
  if ! id "$USUARIO" >/dev/null 2>&1; then
    if getent passwd "$UID_U" >/dev/null; then useradd -M -s /bin/bash -c "$NOMBRE" "$USUARIO"
    else useradd -M -u "$UID_U" -s /bin/bash -c "$NOMBRE" "$USUARIO"; fi
  fi
  usermod -p "$(cat "$META/clave.txt")" "$USUARIO"
  for g in ${GRUPOS//,/ }; do getent group "$g" >/dev/null && usermod -aG "$g" "$USUARIO"; done
  echo "40"; echo "# Recuperando tus archivos..."
  leer | tar -xf - -C / "home/$USUARIO"
  chown -R "$USUARIO:" "/home/$USUARIO"
  echo "55"; echo "# Recuperando tus redes WiFi..."
  cp -a "$META/red/." /etc/NetworkManager/system-connections/ 2>/dev/null
  chmod 600 /etc/NetworkManager/system-connections/* 2>/dev/null
  nmcli connection reload 2>/dev/null
  cp -an "$META/apt/sources/." /etc/apt/sources.list.d/ 2>/dev/null
  cp -an "$META/apt/keys/." /etc/apt/trusted.gpg.d/ 2>/dev/null
  cp -an "$META/apt/keyrings-usr/." /usr/share/keyrings/ 2>/dev/null
  mkdir -p /etc/apt/keyrings; cp -an "$META/apt/keyrings-etc/." /etc/apt/keyrings/ 2>/dev/null
  echo "65"; echo "# Esperando a internet..."
  nm-online -q -t 40 2>/dev/null
  echo "70"; echo "# Reinstalando tus apps (Spotify, VS Code, Chrome...). Puede tardar."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update >/dev/null 2>&1
  FALTAN=(); NOHAY=()
  while read -r p; do
    [ -n "$p" ] || continue
    dpkg -s "$p" >/dev/null 2>&1 && continue
    if apt-cache show "$p" >/dev/null 2>&1; then FALTAN+=("$p"); else NOHAY+=("$p"); fi
  done < "$META/paquetes.txt"
  [ ${#FALTAN[@]} -gt 0 ] && apt-get install -y "${FALTAN[@]}" >/dev/null 2>&1
  for p in "${NOHAY[@]}"; do   # apps que se instalaron con un .deb suelto
    case "$p" in
      zoom) curl -fsSL -o /tmp/zoom.deb https://zoom.us/client/latest/zoom_amd64.deb && apt-get install -y /tmp/zoom.deb >/dev/null 2>&1 ;;
      code) curl -fsSL -o /tmp/code.deb "https://code.visualstudio.com/sha/download?build=stable&os=linux-deb-x64" && apt-get install -y /tmp/code.deb >/dev/null 2>&1 ;;
    esac
  done
  command -v google-chrome >/dev/null && update-alternatives --set x-www-browser /usr/bin/google-chrome-stable 2>/dev/null
  echo "90"; echo "# Últimos retoques..."
  mkdir -p /var/lib/AccountsService/users /var/lib/AccountsService/icons
  cp /usr/share/dartzos/icono-128.png "/var/lib/AccountsService/icons/$USUARIO" 2>/dev/null
  printf '[User]\nIcon=/var/lib/AccountsService/icons/%s\n' "$USUARIO" > "/var/lib/AccountsService/users/$USUARIO"
  rm -rf "$META"
  echo "100"; echo "# ✅ Todo recuperado"
}

case "$MODO" in
  guardar) guardar ;;
  restaurar) restaurar "$@" ;;
  buscar) buscar ;;
  *) echo "Uso: sudo dartz-copia guardar   |   sudo dartz-copia restaurar ARCHIVO" ;;
esac
DZ_COPIA_FIN
chmod +x /usr/local/sbin/dartz-copia
command -v zstd >/dev/null || apt-get install -y zstd >/dev/null 2>&1

echo "🐶 [1/4] Copia de seguridad de tu cuenta, archivos, apps y WiFi"
DARTZ_NO_DESMONTAR=1 SUDO_USER="$U" /usr/local/sbin/dartz-copia guardar || { echo "❌ No se pudo hacer la copia. No he tocado nada."; exit 1; }
COPIA=$(cat /tmp/dartz-copia-ultima 2>/dev/null)
[ -f "$COPIA" ] || [ -f "$COPIA.parte-00" ] || { echo "❌ No encuentro la copia. No he tocado nada."; exit 1; }
DESTINO=$(dirname "$COPIA")
LIBRE=$(df -Pm "$DESTINO" | awk 'NR==2{print $4}')
[ "$LIBRE" -gt 2300 ] || { echo "❌ No hay sitio para descargar DartzOS nuevo (hacen falta 2,3 GB libres en $DESTINO)."; exit 1; }

echo "🐶 [2/4] Descargando DartzOS nuevo (unos 1,8 GB)..."
ISO="$DESTINO/DartzOS-nuevo.iso"
curl -fL --retry 3 -o "$ISO" "$ISO_URL" || { echo "❌ No se pudo descargar. No he tocado nada (tu copia está en $COPIA)."; exit 1; }
SUMA=$(curl -fsL "$SHA_URL" | awk '{print $1}')
echo "   Comprobando que se ha descargado bien..."
[ -n "$SUMA" ] && [ "$(sha256sum "$ISO" | awk '{print $1}')" = "$SUMA" ] || { echo "❌ La descarga está dañada. No he tocado nada."; exit 1; }
TAM_ISO=$(stat -c %s "$ISO"); TAM_USB=$(blockdev --getsize64 "$USB")
[ "$TAM_ISO" -lt "$TAM_USB" ] || { echo "❌ El USB es demasiado pequeño."; exit 1; }

echo
echo "✅ Todo preparado:"
echo "   • Tu copia:      $COPIA"
echo "   • DartzOS nuevo: descargado y comprobado"
echo
echo "🐶 [3/4] Ahora grabo DartzOS nuevo en este USB ($USB) y reinicio."
echo "   ⚠️  No apagues ni saques el USB hasta que se reinicie (1-3 minutos)."
echo "   ⚠️  Al reiniciar, mantén pulsada la tecla ⌥ (alt) y elige «EFI Boot»."
read -rp "   ¿Empiezo? Escribe  si  y pulsa Enter: " R </dev/tty
[ "$R" = si ] || [ "$R" = SI ] || [ "$R" = sí ] || { echo "Vale, no he grabado nada. Tu copia sigue en $COPIA"; exit 0; }

# DartzOS esta funcionando desde la RAM (toram): el USB se puede reescribir.
# Congelamos la memoria del USB para que nada escriba en el mientras se graba.
swapoff -a 2>/dev/null
sync
echo 1 > /proc/sys/kernel/sysrq
for P in /run/live/persistence/*; do mountpoint -q "$P" && fsfreeze -f "$P" 2>/dev/null; done
echo "🐶 [4/4] Grabando..."
# borrar primero la copia de la tabla de particiones vieja (al final del USB)
dd if=/dev/zero of="$USB" bs=1M count=2 seek=$(( TAM_USB / 1048576 - 2 )) oflag=direct conv=fsync 2>/dev/null
dd if="$ISO" of="$USB" bs=4M oflag=direct conv=fsync status=progress
# a partir de aqui, solo cosas que no leen del USB (todo esta en la RAM)
echo "✅ Grabado. Reiniciando... (mantén ⌥ y elige EFI Boot)"
read -rt 4 </dev/zero 2>/dev/null; read -rt 4 _ <> <(:) 2>/dev/null
echo b > /proc/sysrq-trigger
