#!/usr/bin/env bash
# Test d'intégration `beryl apply` (moteur de recettes) sur le banc QEMU.
#
# Exerce les primitives idempotentes contre une VRAIE VM FreeBSD :
# valide la syntaxe réelle des commandes (sysrc, pw, getent, stat,
# sha256, sshd -t, crontab, service) que les specs unitaires ne testent
# que sur un FakeShell.
#
# Primitives couvertes (volontairement SANS réseau ni risque de lock-out) :
#   - sysrc-set
#   - file-write (+ mode + owner)
#   - user-create
#   - user-update-keys (sur un user de test, garde-fou non déclenché)
#   - sshd-config-set (sshd -t + reload)
#   - cron-entry
#   - service-enable (chemin skip sur sshd, valide la lecture d'état)
#
# Volontairement EXCLUES de l'automatique (à tester à la main) :
#   - pkg-install / pkg-remove : nécessitent le réseau du guest.
#   - pf-rule / firewall-pf : pfctl pourrait couper le SSH du banc.
#
# Pré-requis : banc QEMU `prod-crystal/qemu/` démarré (VM client sur
# 2223 avec root SSH). Voir start-bench.sh.
#
# Le test :
#   1. Pré-flight VM client.
#   2. Env beryl éphémère /tmp/beryl-apply-qemu-XXXX/ : dépôt de
#      recettes local + dossier d'orchestration du host clientvm.
#   3. apply #1 → assertions sur l'état réel de la VM.
#   4. apply #2 → idempotence (0 applied, tout skip).
#   5. Cleanup VM (sauf --keep).
#
# Idempotent : relançable en boucle (cleanup en début ET fin).
#
# Usage :
#   ./test-apply.sh            # exécute, nettoie à la fin
#   ./test-apply.sh --keep     # garde l'env temp + l'état VM (debug)
#   ./test-apply.sh --no-cleanup-vm

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/assert.sh
source "${SCRIPT_DIR}/lib/assert.sh"

BENCH_DIR="${HOME}/prod-crystal/qemu"
BENCH_SSH_KEY="${BENCH_DIR}/ssh/id_ed25519"
BENCH_PUB_KEY="${BENCH_DIR}/ssh/id_ed25519.pub"
BERYL_REPO="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Identifiants des objets de test posés sur la VM (préfixés pour un
# cleanup ciblé sans toucher au reste).
TEST_USER="beryltest"
TEST_FILE="/root/beryl-bench.conf"
TEST_SYSRC="beryl_bench"
TEST_SSHD_CONF="/etc/ssh/sshd_config.d/beryl.conf"
TEST_CRON_TAG="beryl-bench"

KEEP_TEMP=false
CLEANUP_VM=true
for arg in "$@"; do
  case "$arg" in
    --keep)          KEEP_TEMP=true; CLEANUP_VM=false ;;
    --no-cleanup-vm) CLEANUP_VM=false ;;
    -h|--help)
      sed -n '2,/^set -/p' "$0" | sed -n '/^# /s/^# \?//p'
      exit 0 ;;
    *) ko "argument inconnu : $arg"; exit 1 ;;
  esac
done

BERYL_TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/beryl-apply-qemu-XXXXXX")"
log "environnement temporaire : ${BERYL_TEST_ROOT}"

cleanup_vm() {
  # sysrc
  ssh_client "sysrc -x ${TEST_SYSRC} >/dev/null 2>&1 || true"
  # fichier
  ssh_client "rm -f ${TEST_FILE}"
  # user de test (+ home)
  ssh_client "pw userdel ${TEST_USER} -r >/dev/null 2>&1 || true"
  # directive sshd gérée par beryl
  ssh_client "rm -f ${TEST_SSHD_CONF} && service sshd reload >/dev/null 2>&1 || true"
  # entrée crontab : retire le bloc beryl de la crontab de root
  ssh_client "crontab -l -u root 2>/dev/null | sed '/# >>> beryl >>>/,/# <<< beryl <<</d' | crontab -u root - 2>/dev/null || true"
}

on_exit() {
  local rc=$?
  if [ "$KEEP_TEMP" = true ]; then
    log "--keep : conservation de ${BERYL_TEST_ROOT}"
  else
    rm -rf "${BERYL_TEST_ROOT}"
  fi
  if [ "$CLEANUP_VM" = true ]; then
    log "cleanup VM : retrait des objets de test"
    cleanup_vm || warn "cleanup VM partiel — vérifiez à la main"
  fi
  if [ "$rc" -eq 0 ]; then
    ok "test-apply.sh : tous les tests sont passés"
  else
    ko "test-apply.sh : échec (code $rc)"
  fi
  return $rc
}
trap on_exit EXIT

# ============================================================
# PHASE 0 — pré-flight
# ============================================================

log "phase 0 — pré-flight"

[ -r "${BENCH_SSH_KEY}" ] || { ko "clé SSH du banc absente : ${BENCH_SSH_KEY}"; exit 2; }
[ -r "${BENCH_PUB_KEY}" ] || { ko "clé publique du banc absente : ${BENCH_PUB_KEY}"; exit 2; }

assert_tcp_open 2223 "VM client SSH"

client_uname="$(ssh_client uname -s 2>/dev/null || true)"
if [ "$client_uname" = "FreeBSD" ]; then
  ok "root@VM client répond FreeBSD"
else
  ko "root@VM client ne répond pas en SSH (lancez 22-promote-root-on-client.sh côté banc)"
  exit 2
fi

# ============================================================
# PHASE 1 — environnement beryl éphémère
# ============================================================

log "phase 1 — création env beryl dans ${BERYL_TEST_ROOT}"

RECIPES_DIR="${BERYL_TEST_ROOT}/recipes/recipes"
HOST_DIR="${BERYL_TEST_ROOT}/qemu/test/clientvm"
mkdir -p "${RECIPES_DIR}" "${HOST_DIR}"

# _default.yml : pointe le dépôt central de recettes sur notre dossier.
cat > "${BERYL_TEST_ROOT}/_default.yml" <<EOF
freebsd:
  timezone: Europe/Paris
recipes:
  local_path: ${BERYL_TEST_ROOT}/recipes
EOF

# Domaine + clé publique du banc inline.
PUB_KEY_INLINE="$(cat "${BENCH_PUB_KEY}")"
cat > "${BERYL_TEST_ROOT}/qemu/test.domain.yml" <<EOF
ssh_keys:
  - ${PUB_KEY_INLINE}
EOF

# Host clientvm.
cat > "${BERYL_TEST_ROOT}/qemu/test/clientvm.host.yml" <<EOF
provider: local
ssh_host: 127.0.0.1
port: 2223
user: root
identity_file: ${BENCH_SSH_KEY}
os: freebsd
freebsd:
  hostname: clientvm
EOF

# --- Recettes du dépôt central éphémère ---------------------------

cat > "${RECIPES_DIR}/bench-sysrc.recipe.yml" <<EOF
recipe: bench-sysrc
description: Pose une variable rc.conf de test.
steps:
  - sysrc-set:
      key: ${TEST_SYSRC}
      value: "ok"
EOF

cat > "${RECIPES_DIR}/bench-file.recipe.yml" <<EOF
recipe: bench-file
description: Écrit un fichier de test avec mode et owner.
steps:
  - file-write:
      path: ${TEST_FILE}
      mode: "0644"
      owner: root:wheel
      content: |
        bonjour depuis beryl apply
EOF

cat > "${RECIPES_DIR}/bench-user.recipe.yml" <<EOF
recipe: bench-user
description: Crée un utilisateur de test.
steps:
  - user-create:
      name: ${TEST_USER}
      shell: /bin/sh
EOF

cat > "${RECIPES_DIR}/bench-keys.recipe.yml" <<EOF
recipe: bench-keys
description: Synchronise les clés SSH du user de test.
requires:
  - bench-user
steps:
  - user-update-keys:
      user: ${TEST_USER}
      keys:
        - ${PUB_KEY_INLINE}
EOF

cat > "${RECIPES_DIR}/bench-sshd.recipe.yml" <<EOF
recipe: bench-sshd
description: Pose une directive sshd (inoffensive).
steps:
  - sshd-config-set:
      key: ClientAliveInterval
      value: "300"
EOF

cat > "${RECIPES_DIR}/bench-cron.recipe.yml" <<EOF
recipe: bench-cron
description: Pose une entrée crontab de test.
steps:
  - cron-entry:
      user: root
      entry: "@daily /usr/bin/true # ${TEST_CRON_TAG}"
EOF

cat > "${RECIPES_DIR}/bench-service.recipe.yml" <<EOF
recipe: bench-service
description: Vérifie la lecture d'état d'un service (sshd, déjà actif).
steps:
  - service-enable:
      name: sshd
EOF

# Recettes ssh-hardening RÉELLES (copiées du dépôt beryl-recipes) : on
# teste les vraies recettes + la méta + l'interpolation {{ company }},
# pas des copies inline qui dériveraient.
cp "${SCRIPT_DIR}/../beryl-recipes/recipes/sshd-auth-keys-only.recipe.yml" \
   "${SCRIPT_DIR}/../beryl-recipes/recipes/sshd-host-key-ed25519.recipe.yml" \
   "${SCRIPT_DIR}/../beryl-recipes/recipes/sshd-crypto-modern.recipe.yml" \
   "${SCRIPT_DIR}/../beryl-recipes/recipes/sshd-banner-neutral.recipe.yml" \
   "${SCRIPT_DIR}/../beryl-recipes/recipes/ssh-hardening.recipe.yml" \
   "${RECIPES_DIR}/"

# Agrégat demandé sur le host.
cat > "${HOST_DIR}/bench-all.recipe.yml" <<EOF
recipe: bench-all
description: Agrégat de test des primitives apply.
requires:
  - bench-sysrc
  - bench-file
  - bench-user
  - bench-keys
  - bench-sshd
  - bench-cron
  - bench-service
  - ssh-hardening
EOF

# Sanity : beryl show parse le host.
assert_contains "beryl show parse YAML host" "ssh_host:       127.0.0.1" \
  run_beryl show qemu/clientvm

# Reset d'un éventuel état laissé par un run précédent.
cleanup_vm 2>/dev/null || true

# ============================================================
# PHASE 2 — apply #1 (application réelle)
# ============================================================

log "phase 2 — apply #1 (application)"

apply1="$(run_beryl apply qemu/clientvm)" || { ko "apply #1 a échoué"; printf '%s\n' "$apply1" >&2; exit 1; }
printf '%s\n' "$apply1" >&2

if printf '%s' "$apply1" | grep -F -q "0 failed"; then
  ok "apply #1 sans échec"
else
  ko "apply #1 a des steps failed"; exit 1
fi

# Ordre topologique : bench-user doit précéder bench-keys (dépendance).
if printf '%s' "$apply1" | grep 'ordre résolu' | grep -Eq 'bench-user.*bench-keys'; then
  ok "ordre topologique : bench-user avant bench-keys"
else
  ko "ordre topologique incorrect (bench-user devrait précéder bench-keys)"; exit 1
fi

# --- Assertions sur l'état réel de la VM --------------------------

assert_contains "sysrc-set : variable posée" "ok" \
  ssh_client "sysrc -n ${TEST_SYSRC}"

assert_contains "file-write : contenu écrit" "bonjour depuis beryl apply" \
  ssh_client "cat ${TEST_FILE}"
assert_contains "file-write : mode 0644" "644" \
  ssh_client "stat -f %Lp ${TEST_FILE}"
assert_contains "file-write : owner root:wheel" "root:wheel" \
  ssh_client "stat -f %Su:%Sg ${TEST_FILE}"

assert_contains "user-create : utilisateur créé" "${TEST_USER}" \
  ssh_client "pw usershow ${TEST_USER}"

assert_contains "user-update-keys : clé déployée" "${PUB_KEY_INLINE}" \
  ssh_client "cat ~${TEST_USER}/.ssh/authorized_keys"

assert_contains "sshd-config-set : directive posée" "ClientAliveInterval 300" \
  ssh_client "cat ${TEST_SSHD_CONF}"

assert_contains "cron-entry : entrée posée" "${TEST_CRON_TAG}" \
  ssh_client "crontab -l -u root"

# --- ssh-hardening (méta) : vraies recettes + interpolation {{ company }} ---
# Le host est en qemu/test/clientvm → société = "qemu" → VersionAddendum qemu.
assert_contains "ssh-hardening : VersionAddendum = société (interpolation {{ company }})" "VersionAddendum qemu" \
  ssh_client "cat ${TEST_SSHD_CONF}"
assert_contains "ssh-hardening : kex moderne (mlkem PQ)" "mlkem768x25519-sha256" \
  ssh_client "cat ${TEST_SSHD_CONF}"
assert_contains "ssh-hardening : host key ed25519 unique" "HostKey /etc/ssh/ssh_host_ed25519_key" \
  ssh_client "cat ${TEST_SSHD_CONF}"
assert_contains "ssh-hardening : sshd -t valide la conf complète" "SSHD_CONF_OK" \
  ssh_client "sshd -t && echo SSHD_CONF_OK"

# ============================================================
# PHASE 3 — apply #2 (idempotence)
# ============================================================

log "phase 3 — apply #2 (idempotence : tout doit être skip)"

apply2="$(run_beryl apply qemu/clientvm)" || { ko "apply #2 a échoué"; printf '%s\n' "$apply2" >&2; exit 1; }
printf '%s\n' "$apply2" >&2

if printf '%s' "$apply2" | grep -F -q "0 applied"; then
  ok "apply #2 : 0 applied (idempotent)"
else
  ko "apply #2 a appliqué des changements (non idempotent)"; exit 1
fi
if printf '%s' "$apply2" | grep -F -q "0 failed"; then
  ok "apply #2 : 0 failed"
else
  ko "apply #2 a des steps failed"; exit 1
fi

log "tous les tests d'intégration apply sont passés"
