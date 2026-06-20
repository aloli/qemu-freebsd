#!/usr/bin/env bash
# =====================================================================
# Banc de test QEMU local pour install-pkgbase.sh (beryl)
# =====================================================================
#
# But : rejouer le script d'install FreeBSD pkgbase de beryl contre des
# disques vierges dans une VM FreeBSD installeur, PUIS rebooter UNIQUEMENT
# sur les disques installés, pour prouver que l'install produit un système
# amorçable — sans toucher à du vrai matériel OVH.
#
# Flux :
#   1. génère une paire de clés SSH de test ;
#   2. crée 4 disques vierges raw de 8 Go ;
#   3. construit un seed cloud-init (injecte la clé pub de test) ;
#   4. PHASE INSTALL : boote l'image cloud (vtbd0) + seed + 4 disques
#      (vtbd1..vtbd4) ; attend le SSH freebsd@:2240 ; vérifie les clés
#      pkgbase ; rend install-pkgbase.sh (sed) ; l'exécute en root ;
#   5. poweroff propre de la VM installeur ;
#   6. PHASE BOOT : boote UNIQUEMENT depuis les 4 disques installés
#      (vtbd0=disk1.raw …, pas d'image cloud, pas de seed) ; attend le
#      SSH admin@:2241 avec la clé de test ;
#   7. SSH admin OK = PASS ; sinon FAIL + dump du serial.log.
#
# Usage : ./run.sh [--keep] [--no-data-pool] [--encrypted]
#   --keep         : ne nettoie pas (laisse disques/overlay/logs) en fin.
#   --no-data-pool : install sans pool data (vtbd3/vtbd4 ignorés).
#   --encrypted    : profil Option I — datasets système chiffrés (zroot/encrypted
#                    /home,/opt,/usr/local/etc) + root clé-seule fail-safe. La
#                    phase BOOT vérifie alors : datasets VERROUILLÉS au boot, root
#                    joignable (porte de secours), unlock → datasets montés.
#
# Tout vit sous qemu/bootstrap-test/run/ (gitignore conseillé).
# =====================================================================

set -euo pipefail

# --------------------------------------------------------------------
# Constantes / chemins
# --------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_DIR="${SCRIPT_DIR}/run"

# beryl est le sibling `../../beryl` (le banc vit dans ~/prod-crystal/qemu/, pas
# dans beryl/qemu/). Override possible via la variable d'env BERYL_ROOT.
BERYL_ROOT="${BERYL_ROOT:-${HOME}/prod-crystal/beryl}"
TEMPLATE="${BERYL_ROOT}/src/beryl/bootstrap/templates/install-pkgbase.sh"

# Image installeur (cloud FreeBSD 15 aarch64) — NE PAS modifier : overlay.
CLOUD_IMAGE="${HOME}/prod-crystal/qemu/images/FreeBSD-15.0-RELEASE-arm64-aarch64-BASIC-CLOUDINIT-ufs.qcow2"

QEMU_BIN="$(command -v qemu-system-aarch64)"
EDK2_FIRMWARE="/opt/homebrew/share/qemu/edk2-aarch64-code.fd"

# Firmware UEFI : edk2 a besoin d'un volume NVRAM inscriptible séparé pour
# mémoriser les BootXXXX (sinon BootOrder non persistant → la phase BOOT
# peut ne pas retrouver le loader). On donne donc à chaque VM son propre
# vars store (copie du template vars d'edk2).
EDK2_VARS_TEMPLATE="/opt/homebrew/share/qemu/edk2-arm-vars.fd"

VM_CPUS="2"
VM_MEM="2048"

INSTALL_SSH_PORT="2240"
BOOT_SSH_PORT="2241"

# Overlay de l'image cloud + seed + disques.
OVERLAY="${RUN_DIR}/installer-overlay.qcow2"
SEED_ISO="${RUN_DIR}/seed.iso"
DISK1="${RUN_DIR}/disk1.raw"
DISK2="${RUN_DIR}/disk2.raw"
DISK3="${RUN_DIR}/disk3.raw"
DISK4="${RUN_DIR}/disk4.raw"

SSH_KEY="${RUN_DIR}/id_ed25519"

INSTALL_LOG="${RUN_DIR}/install-serial.log"
BOOT_LOG="${RUN_DIR}/boot-serial.log"
INSTALL_PID="${RUN_DIR}/installer.pid"
BOOT_PID="${RUN_DIR}/boot.pid"
RENDERED="${RUN_DIR}/install-pkgbase.rendered.sh"
INSTALL_OUT="${RUN_DIR}/install-output.log"

INSTALL_VARS="${RUN_DIR}/installer-vars.fd"
BOOT_VARS="${RUN_DIR}/boot-vars.fd"

# Paramètres d'install (cas normal).
BOOT_DISKS="/dev/vtbd1 /dev/vtbd2"
BOOT_RAID="mirror"
POOL_NAME="zroot"
HOSTNAME_VM="qtest"
ABI="FreeBSD:15:aarch64"
SWAP_GB="1"
TIMEZONE="Europe/Paris"
PACKAGES=""   # 1er test minimal : pas de paquets supplémentaires.

# --------------------------------------------------------------------
# Options
# --------------------------------------------------------------------
KEEP=0
DATA_POOL=1
ENCRYPTED=0
for arg in "$@"; do
  case "${arg}" in
    --keep)         KEEP=1 ;;
    --no-data-pool) DATA_POOL=0 ;;
    --encrypted)    ENCRYPTED=1 ;;
    *) echo "Option inconnue : ${arg}" >&2; exit 2 ;;
  esac
done

# --------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------
log()  { printf '\033[1;34m[banc]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ OK ]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*" >&2; }

# Clés SSH host à ignorer (les VMs sont éphémères).
SSH_OPTS=(
  -i "${SSH_KEY}"
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o LogLevel=ERROR
  -o ConnectTimeout=5
  -o IdentitiesOnly=yes
)

kill_pidfile() {
  local pf="$1"
  if [[ -f "${pf}" ]]; then
    local pid
    pid="$(cat "${pf}" 2>/dev/null || true)"
    if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
      kill "${pid}" 2>/dev/null || true
      # attend la mort, SIGKILL si récalcitrant.
      for _ in $(seq 1 20); do
        kill -0 "${pid}" 2>/dev/null || break
        sleep 0.5
      done
      kill -9 "${pid}" 2>/dev/null || true
    fi
    rm -f "${pf}"
  fi
}

cleanup_vms() {
  kill_pidfile "${INSTALL_PID}"
  kill_pidfile "${BOOT_PID}"
}

final_cleanup() {
  cleanup_vms
  if [[ "${KEEP}" -eq 0 ]]; then
    log "Nettoyage (disques/overlay/logs). Utilisez --keep pour conserver."
    rm -f "${OVERLAY}" "${SEED_ISO}" "${DISK1}" "${DISK2}" "${DISK3}" "${DISK4}" \
          "${INSTALL_VARS}" "${BOOT_VARS}" \
          "${INSTALL_LOG}" "${BOOT_LOG}" "${RENDERED}" "${INSTALL_OUT}"
  else
    log "--keep : fichiers conservés sous ${RUN_DIR}"
  fi
}

# Attend qu'une commande SSH réussisse. wait_ssh <port> <user> <timeout_s>
wait_ssh() {
  local port="$1" user="$2" timeout="$3"
  local deadline=$(( $(date +%s) + timeout ))
  while [[ $(date +%s) -lt ${deadline} ]]; do
    if ssh "${SSH_OPTS[@]}" -p "${port}" "${user}@127.0.0.1" true 2>/dev/null; then
      return 0
    fi
    sleep 3
  done
  return 1
}

ssh_install() { ssh "${SSH_OPTS[@]}" -p "${INSTALL_SSH_PORT}" "freebsd@127.0.0.1" "$@"; }
# SSH dans la VM bootée. Premier arg = user (root pour la porte de secours
# fail-safe en --encrypted, admin sinon).
ssh_boot() { local u="$1"; shift; ssh "${SSH_OPTS[@]}" -p "${BOOT_SSH_PORT}" "${u}@127.0.0.1" "$@"; }

dump_tail() {
  local f="$1" n="${2:-100}"
  if [[ -f "${f}" ]]; then
    echo "----- ${f} (dernières ${n} lignes) -----"
    tail -n "${n}" "${f}"
    echo "----- fin ${f} -----"
  else
    echo "(pas de log ${f})"
  fi
}

# --------------------------------------------------------------------
# Pré-vol
# --------------------------------------------------------------------
[[ -x "${QEMU_BIN}" ]]        || { err "qemu-system-aarch64 introuvable"; exit 1; }
[[ -f "${CLOUD_IMAGE}" ]]     || { err "image cloud introuvable : ${CLOUD_IMAGE}"; exit 1; }
[[ -f "${EDK2_FIRMWARE}" ]]   || { err "firmware edk2 introuvable : ${EDK2_FIRMWARE}"; exit 1; }
[[ -f "${TEMPLATE}" ]]        || { err "template install-pkgbase.sh introuvable : ${TEMPLATE}"; exit 1; }

mkdir -p "${RUN_DIR}"
trap final_cleanup EXIT

# --------------------------------------------------------------------
# 1. Clé SSH de test
# --------------------------------------------------------------------
if [[ ! -f "${SSH_KEY}" ]]; then
  log "Génération de la paire de clés SSH de test"
  ssh-keygen -t ed25519 -N "" -f "${SSH_KEY}" -C "beryl-bootstrap-test" >/dev/null
fi
PUBKEY="$(cat "${SSH_KEY}.pub")"
ok "clé de test : ${SSH_KEY}"

# --------------------------------------------------------------------
# 2. 4 disques vierges raw de 8 Go
# --------------------------------------------------------------------
log "Création des 4 disques vierges (8 Go)"
for d in "${DISK1}" "${DISK2}" "${DISK3}" "${DISK4}"; do
  rm -f "${d}"
  qemu-img create -f raw "${d}" 8G >/dev/null
done
ok "disques : disk1..disk4.raw"

# --------------------------------------------------------------------
# 3. Seed cloud-init
# --------------------------------------------------------------------
log "Construction du seed cloud-init"
SEED_STAGE="$(mktemp -d)"
# NB : l'image FreeBSD utilise `nuageinit` (cloud-init natif), qui REFUSE
# un meta-data vide (« error parsing nocloud meta-data »). On fournit donc
# un meta-data minimal valide (instance-id + local-hostname).
cat > "${SEED_STAGE}/meta-data" <<EOF
instance-id: ${HOSTNAME_VM}-installer
local-hostname: ${HOSTNAME_VM}-installer
EOF
cat > "${SEED_STAGE}/user-data" <<EOF
#cloud-config
ssh_pwauth: true
disable_root: false
# L'image cloud FreeBSD ne livre PAS sudo. On l'installe au boot pour
# pouvoir lancer install-pkgbase.sh en root (« sh: sudo: not found »
# sinon). package_update rafraîchit le catalogue ports avant l'install.
package_update: true
packages:
  - sudo
users:
  - name: freebsd
    groups: wheel
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: false
    plain_text_passwd: freebsd
    ssh_authorized_keys:
      - ${PUBKEY}
datasource_list: [NoCloud]
EOF

rm -f "${SEED_ISO}" "${SEED_ISO}.tmp" "${SEED_ISO}.tmp.iso"
# Le volume DOIT s'appeler cidata pour le datasource NoCloud.
hdiutil makehybrid -quiet -o "${SEED_ISO}.tmp" -hfs -joliet -iso \
  -default-volume-name cidata "${SEED_STAGE}" >/dev/null
if [[ -f "${SEED_ISO}.tmp.iso" ]]; then
  mv "${SEED_ISO}.tmp.iso" "${SEED_ISO}"
else
  mv "${SEED_ISO}.tmp" "${SEED_ISO}"
fi
rm -rf "${SEED_STAGE}"
ok "seed : ${SEED_ISO}"

# --------------------------------------------------------------------
# 4. PHASE INSTALL : boote la VM installeur
# --------------------------------------------------------------------
log "Préparation de l'overlay de l'image cloud (vtbd0)"
rm -f "${OVERLAY}"
qemu-img create -f qcow2 -F qcow2 -b "${CLOUD_IMAGE}" "${OVERLAY}" >/dev/null

# Vars NVRAM inscriptibles (copie du template edk2). Si le template
# n'existe pas, edk2-aarch64-code.fd sait fonctionner seul via -bios, mais
# alors BootOrder n'est pas persistant. On privilégie le pflash si dispo.
USE_PFLASH=0
if [[ -f "${EDK2_VARS_TEMPLATE}" ]]; then
  USE_PFLASH=1
fi

start_installer() {
  local -a drives=(
    -drive if=virtio,format=qcow2,file="${OVERLAY}"
    -drive if=virtio,format=raw,readonly=on,file="${SEED_ISO}"
    -drive if=virtio,format=raw,file="${DISK1}"
    -drive if=virtio,format=raw,file="${DISK2}"
    -drive if=virtio,format=raw,file="${DISK3}"
    -drive if=virtio,format=raw,file="${DISK4}"
  )
  local -a fw
  if [[ "${USE_PFLASH}" -eq 1 ]]; then
    cp "${EDK2_FIRMWARE}" "${RUN_DIR}/installer-code.fd"
    cp "${EDK2_VARS_TEMPLATE}" "${INSTALL_VARS}"
    fw=(
      -drive if=pflash,format=raw,readonly=on,file="${RUN_DIR}/installer-code.fd"
      -drive if=pflash,format=raw,file="${INSTALL_VARS}"
    )
  else
    fw=( -bios "${EDK2_FIRMWARE}" )
  fi
  "${QEMU_BIN}" \
    -name beryl-installer \
    -machine virt,gic-version=3 -accel hvf -cpu host \
    -smp "${VM_CPUS}" -m "${VM_MEM}" \
    "${fw[@]}" \
    "${drives[@]}" \
    -netdev user,id=net0,hostfwd=tcp::"${INSTALL_SSH_PORT}"-:22 \
    -device virtio-net-device,netdev=net0 \
    -display none -serial file:"${INSTALL_LOG}" \
    -pidfile "${INSTALL_PID}" -daemonize
}

log "Boot de la VM installeur (SSH host :${INSTALL_SSH_PORT})"
: > "${INSTALL_LOG}"
start_installer
ok "installeur lancé (pid $(cat "${INSTALL_PID}"))"

log "Attente du SSH freebsd@:${INSTALL_SSH_PORT} (cloud-init, ~2-3 min)…"
if ! wait_ssh "${INSTALL_SSH_PORT}" "freebsd" 240; then
  err "pas de SSH sur l'installeur après 240 s"
  dump_tail "${INSTALL_LOG}" 80
  exit 1
fi
ok "SSH installeur up"

# Vérifie la présence des clés pkgbase (sinon pkg --rootdir échouera).
log "Vérification des clés pkgbase dans la VM installeur"
VMAJ="$(ssh_install 'uname -r | cut -d. -f1' 2>/dev/null || echo '?')"
if ssh_install "test -d /usr/share/keys/pkgbase-${VMAJ}" 2>/dev/null; then
  ok "clés pkgbase présentes : /usr/share/keys/pkgbase-${VMAJ}"
else
  err "/usr/share/keys/pkgbase-${VMAJ} ABSENT dans l'image installeur."
  err "L'install pkgbase échouera (fingerprints introuvables)."
  err "Contenu de /usr/share/keys :"
  ssh_install 'ls -la /usr/share/keys/ 2>&1' || true
  exit 1
fi

# Attente de sudo : `wait_ssh` rend la main dès que SSH+clé répond, ce qui
# peut précéder la fin de nuageinit (install du paquet sudo). On boucle
# jusqu'à ce que sudo soit présent (sinon « sudo: not found », rc=127).
log "Attente de la disponibilité de sudo (nuageinit)…"
SUDO_OK=0
for _ in $(seq 1 40); do
  if ssh_install 'command -v sudo >/dev/null 2>&1'; then SUDO_OK=1; break; fi
  sleep 5
done
if [[ "${SUDO_OK}" -ne 1 ]]; then
  err "sudo toujours absent après 200 s — nuageinit n'a pas installé le paquet."
  err "Diag : derniers logs nuageinit / pkg :"
  ssh_install 'tail -20 /var/log/messages 2>/dev/null; pkg info sudo 2>&1' || true
  exit 1
fi
ok "sudo disponible"

# --------------------------------------------------------------------
# 5. Rendu + exécution de install-pkgbase.sh
# --------------------------------------------------------------------
log "Rendu de install-pkgbase.sh (substitution des placeholders)"

# USERS_TSV : admin avec la clé pub de test.
USERS_TSV="admin|wheel||/bin/sh|${PUBKEY}"
USERS_TSV_B64="$(printf '%s' "${USERS_TSV}" | base64 | tr -d '\n')"
SUDOERS_B64="$(printf '%s' '%wheel ALL=(ALL) NOPASSWD:ALL' | base64 | tr -d '\n')"

if [[ "${DATA_POOL}" -eq 1 ]]; then
  DATA_POOLS_SCRIPT="$(cat <<'DPS'
zpool create -f -R /mnt -m /data zdata vtbd3 vtbd4
zpool set cachefile=/mnt/boot/zfs/zpool.cache zdata
DPS
)"
else
  DATA_POOLS_SCRIPT=""
fi
DATA_POOLS_SCRIPT_B64="$(printf '%s' "${DATA_POOLS_SCRIPT}" | base64 | tr -d '\n')"
# Datasets système chiffrés (profil C+) + clés root. Vides par défaut →
# install-pkgbase.sh garde /home + /var/log clairs et root coupé (banc
# historique). Le mode --encrypted les remplit (profil Option I).
SYSTEM_DATASETS_SCRIPT_B64=""
ROOT_KEYS_B64=""
SYS_KEY_HEX=""
if [[ "${ENCRYPTED}" -eq 1 ]]; then
  log "Mode --encrypted : datasets système chiffrés (profil Option I)"
  # Clé maître 64-hex (comme beryl bootstrap). On la garde côté banc pour
  # déverrouiller en phase BOOT (équivalent de `beryl unlock` ssh_unlock).
  SYS_KEY_HEX="$(openssl rand -hex 32)"
  SYS_KEY_B64="$(printf '%s' "${SYS_KEY_HEX}" | base64 | tr -d '\n')"
  # MÊME FORMAT que beryl system_datasets_script (qemu_in_rescue.cr) : le format
  # réel est garanti par le spec unitaire ; ici on en rejoue un fidèle. La clé
  # n'apparaît jamais en argv (base64 → $KEY → stdin de zfs create keyformat=hex).
  SYSTEM_DATASETS_SCRIPT="$(cat <<SDS
{
  KEY=\$(echo '${SYS_KEY_B64}' | base64 -d)
  printf '%s' "\$KEY" | zfs create -o encryption=on -o keyformat=hex -o keylocation=prompt -o canmount=off -o mountpoint=none ${POOL_NAME}/encrypted
  unset KEY
}
zfs create -o compression=lz4 -o mountpoint=/home ${POOL_NAME}/encrypted/home
zfs create -o compression=lz4 -o mountpoint=/opt ${POOL_NAME}/encrypted/opt
zfs create -o compression=zstd-3 -o mountpoint=/usr/local/etc ${POOL_NAME}/encrypted/usrlocaletc
zfs create -o compression=zstd-3 -o mountpoint=/var/log ${POOL_NAME}/zlog
SDS
)"
  SYSTEM_DATASETS_SCRIPT_B64="$(printf '%s' "${SYSTEM_DATASETS_SCRIPT}" | base64 | tr -d '\n')"
  # Porte de secours fail-safe : root clé-seule = la clé de test (dans /root clair).
  ROOT_KEYS_B64="$(printf '%s' "${PUBKEY}" | base64 | tr -d '\n')"
fi

# sed : on utilise un délimiteur improbable (|) et on protège les valeurs
# contenant des slashs/espaces. Les placeholders b64 ne contiennent que
# [A-Za-z0-9+/=], sans |.
render() {
  sed \
    -e "s|__BOOT_DISKS__|${BOOT_DISKS}|g" \
    -e "s|__BOOT_RAID__|${BOOT_RAID}|g" \
    -e "s|__POOL_NAME__|${POOL_NAME}|g" \
    -e "s|__HOSTNAME__|${HOSTNAME_VM}|g" \
    -e "s|__ABI__|${ABI}|g" \
    -e "s|__SWAP_GB__|${SWAP_GB}|g" \
    -e "s|__TIMEZONE__|${TIMEZONE}|g" \
    -e "s|__USERS_TSV_B64__|${USERS_TSV_B64}|g" \
    -e "s|__PACKAGES__|${PACKAGES}|g" \
    -e "s|__SUDOERS_B64__|${SUDOERS_B64}|g" \
    -e "s|__DATA_POOLS_SCRIPT_B64__|${DATA_POOLS_SCRIPT_B64}|g" \
    -e "s|__SYSTEM_DATASETS_SCRIPT_B64__|${SYSTEM_DATASETS_SCRIPT_B64}|g" \
    -e "s|__ROOT_KEYS_B64__|${ROOT_KEYS_B64}|g" \
    "${TEMPLATE}"
}
render > "${RENDERED}"

# Garde-fou : aucun placeholder RÉEL résiduel. On ne matche QUE les noms
# de placeholders connus — le commentaire d'en-tête du script contient
# « __XXX__ » (texte d'explication), à ne pas confondre avec un oubli.
RESIDUAL_RE='__(BOOT_DISKS|BOOT_RAID|POOL_NAME|HOSTNAME|ABI|SWAP_GB|TIMEZONE|USERS_TSV_B64|PACKAGES|SUDOERS_B64|DATA_POOLS_SCRIPT_B64|SYSTEM_DATASETS_SCRIPT_B64|ROOT_KEYS_B64)__'
if grep -qE "${RESIDUAL_RE}" "${RENDERED}"; then
  err "placeholders résiduels après rendu :"
  grep -oE "${RESIDUAL_RE}" "${RENDERED}" | sort -u >&2
  exit 1
fi
ok "script rendu : ${RENDERED}"

log "Copie du script dans la VM installeur"
scp "${SSH_OPTS[@]}" -P "${INSTALL_SSH_PORT}" "${RENDERED}" \
  "freebsd@127.0.0.1:/tmp/install-pkgbase.sh" >/dev/null
ok "scp OK"

log "Exécution de l'install (sudo sh /tmp/install-pkgbase.sh)…"
set +e
ssh_install 'sudo sh /tmp/install-pkgbase.sh' 2>&1 | tee "${INSTALL_OUT}"
INSTALL_RC="${PIPESTATUS[0]}"
set -e

if [[ "${INSTALL_RC}" -ne 0 ]]; then
  err "install-pkgbase.sh a échoué (rc=${INSTALL_RC})"
  err "Sortie complète ci-dessus (aussi dans ${INSTALL_OUT})."
  exit 1
fi
ok "install-pkgbase.sh terminé sans erreur"

# --------------------------------------------------------------------
# 6. Poweroff propre de la VM installeur
# --------------------------------------------------------------------
log "Poweroff de la VM installeur"
ssh_install 'sudo poweroff' 2>/dev/null || true
# attend la fin du process QEMU.
if [[ -f "${INSTALL_PID}" ]]; then
  IPID="$(cat "${INSTALL_PID}")"
  for _ in $(seq 1 60); do
    kill -0 "${IPID}" 2>/dev/null || break
    sleep 1
  done
  kill -0 "${IPID}" 2>/dev/null && { log "installeur récalcitrant, kill"; kill_pidfile "${INSTALL_PID}"; }
fi
rm -f "${INSTALL_PID}"
ok "installeur arrêté"

# --------------------------------------------------------------------
# 7. PHASE BOOT : boote UNIQUEMENT sur les disques installés
# --------------------------------------------------------------------
log "Boot depuis les disques installés (pas d'image cloud, pas de seed)"
: > "${BOOT_LOG}"

start_boot() {
  # vtbd0=disk1, vtbd1=disk2, vtbd2=disk3, vtbd3=disk4 : l'UEFI cherche
  # BOOTAA64.EFI sur l'un d'eux (posé par install-pkgbase.sh sur efi0/efi1).
  local -a drives=(
    -drive if=virtio,format=raw,file="${DISK1}"
    -drive if=virtio,format=raw,file="${DISK2}"
    -drive if=virtio,format=raw,file="${DISK3}"
    -drive if=virtio,format=raw,file="${DISK4}"
  )
  local -a fw
  if [[ "${USE_PFLASH}" -eq 1 ]]; then
    cp "${EDK2_FIRMWARE}" "${RUN_DIR}/boot-code.fd"
    cp "${EDK2_VARS_TEMPLATE}" "${BOOT_VARS}"
    fw=(
      -drive if=pflash,format=raw,readonly=on,file="${RUN_DIR}/boot-code.fd"
      -drive if=pflash,format=raw,file="${BOOT_VARS}"
    )
  else
    fw=( -bios "${EDK2_FIRMWARE}" )
  fi
  "${QEMU_BIN}" \
    -name beryl-boot \
    -machine virt,gic-version=3 -accel hvf -cpu host \
    -smp "${VM_CPUS}" -m "${VM_MEM}" \
    "${fw[@]}" \
    "${drives[@]}" \
    -netdev user,id=net0,hostfwd=tcp::"${BOOT_SSH_PORT}"-:22 \
    -device virtio-net-device,netdev=net0 \
    -display none -serial file:"${BOOT_LOG}" \
    -pidfile "${BOOT_PID}" -daemonize
}

start_boot
ok "VM de boot lancée (pid $(cat "${BOOT_PID}"))"

# --------------------------------------------------------------------
# 8. Vérification de la VM bootée
# --------------------------------------------------------------------
RESULT="FAIL"
if [[ "${ENCRYPTED}" -eq 1 ]]; then
  # Profil Option I : au boot, /home est CHIFFRÉ et VERROUILLÉ (keylocation=
  # prompt, clé larguée au reboot) → admin NE PEUT PAS se connecter (sa clé est
  # dans /home/admin/.ssh, illisible). Seul root (clé dans /root CLAIR) répond =
  # porte de secours fail-safe. On vérifie le verrou, on déverrouille (zfs
  # load-key via SSH = équivalent `beryl unlock` ssh_unlock), puis on re-vérifie.
  log "Attente du SSH root@:${BOOT_SSH_PORT} (porte de secours fail-safe, ~3 min)…"
  if wait_ssh "${BOOT_SSH_PORT}" "root" 180; then
    ok "SSH root OK — porte de secours fail-safe joignable (/root clair)"
    RESULT="PASS"

    # 1. Datasets VERROUILLÉS au boot.
    KS="$(ssh_boot root "zfs get -H -o value keystatus ${POOL_NAME}/encrypted" 2>/dev/null || true)"
    if [[ "${KS}" == "unavailable" ]]; then
      ok "datasets chiffrés VERROUILLÉS au boot (keystatus=unavailable)"
    else err "keystatus attendu 'unavailable', obtenu : '${KS}'"; RESULT="FAIL"; fi

    # 2. root clé-seule.
    PRL="$(ssh_boot root "grep -h PermitRootLogin /etc/ssh/sshd_config.d/10-beryl-bootstrap.conf 2>/dev/null" 2>/dev/null || true)"
    if printf '%s' "${PRL}" | grep -q 'prohibit-password'; then
      ok "PermitRootLogin prohibit-password (root clé-seule)"
    else err "PermitRootLogin prohibit-password absent (obtenu : '${PRL}')"; RESULT="FAIL"; fi

    # 3. /home PAS monté tant que verrouillé.
    HM="$(ssh_boot root "zfs get -H -o value mounted ${POOL_NAME}/encrypted/home" 2>/dev/null || true)"
    if [[ "${HM}" == "no" ]]; then
      ok "/home non monté avant unlock (dataset chiffré verrouillé)"
    else err "/home (mounted) attendu 'no', obtenu : '${HM}'"; RESULT="FAIL"; fi

    # 4. UNLOCK : clé via stdin SSH (équivalent beryl unlock ssh_unlock).
    log "Déverrouillage : zfs load-key via SSH (équivalent beryl unlock)…"
    if printf '%s' "${SYS_KEY_HEX}" | ssh_boot root "zfs load-key ${POOL_NAME}/encrypted && zfs mount -a -l"; then
      ok "unlock OK (clé chargée + zfs mount -a -l)"
    else err "unlock a échoué"; RESULT="FAIL"; fi

    # 5. Après unlock : déverrouillé + /home monté.
    KS2="$(ssh_boot root "zfs get -H -o value keystatus ${POOL_NAME}/encrypted" 2>/dev/null || true)"
    HM2="$(ssh_boot root "zfs get -H -o value mounted ${POOL_NAME}/encrypted/home" 2>/dev/null || true)"
    if [[ "${KS2}" == "available" && "${HM2}" == "yes" ]]; then
      ok "après unlock : keystatus=available + /home monté"
    else err "après unlock : keystatus='${KS2}' (attendu available), /home='${HM2}' (attendu yes)"; RESULT="FAIL"; fi

    # 6. Bonus : admin joignable maintenant que /home déchiffré est monté.
    if wait_ssh "${BOOT_SSH_PORT}" "admin" 30; then
      ok "admin joignable après unlock (/home déchiffré)"
    else err "admin toujours injoignable après unlock"; RESULT="FAIL"; fi

    echo "===== diagnostics (root) ====="
    ssh_boot root 'uname -a; echo "---"; zpool status; echo "---"; zfs list -o name,mounted,keystatus' 2>&1 || true
    echo "=============================="
  else
    err "pas de SSH root après 180 s — diagnostic via le serial.log :"
    dump_tail "${BOOT_LOG}" 100
  fi
else
  log "Attente du SSH admin@:${BOOT_SSH_PORT} (boot + DHCP + auth, ~3 min)…"
  if wait_ssh "${BOOT_SSH_PORT}" "admin" 180; then
    ok "SSH admin OK — le système installé boote et répond !"
    RESULT="PASS"
    echo "===== diagnostics dans la VM bootée ====="
    ssh_boot admin 'uname -a; echo "---"; zpool status; echo "---"; (sudo -n true && echo SUDO_OK) || echo SUDO_KO' 2>&1 || true
    echo "========================================="
  else
    err "pas de SSH admin après 180 s — diagnostic via le serial.log :"
    dump_tail "${BOOT_LOG}" 100
  fi
fi

# --------------------------------------------------------------------
# 9. Bilan
# --------------------------------------------------------------------
echo
if [[ "${RESULT}" == "PASS" ]]; then
  ok "============================================"
  if [[ "${ENCRYPTED}" -eq 1 ]]; then
    ok " BILAN : PASS — bootstrap Option I (chiffré)"
    ok "  → datasets verrouillés au boot, root fail-safe,"
    ok "    unlock → /home monté, admin joignable"
  else
    ok " BILAN : PASS — install pkgbase multi-disque"
    ok "  → boot sur disques installés + SSH admin OK"
  fi
  ok "============================================"
  EXIT=0
else
  err "============================================"
  err " BILAN : FAIL — voir le serial.log ci-dessus"
  err "  install rc=${INSTALL_RC:-?}, serial : ${BOOT_LOG}"
  err "============================================"
  EXIT=1
fi

# Le trap EXIT fait le cleanup (sauf --keep).
exit "${EXIT}"
