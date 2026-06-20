#!/usr/bin/env bash
# Provision the Tang VM: install the package, generate keys, start
# THREE tangd instances (8888, 8889, 8890) so the client VM can
# exercise multi-Tang K=2/N=3 against three independent Tangs from
# a single host.
#
# Notes on the FreeBSD port `security/tang`:
#  - tangd runs as root (no dedicated user is created).
#  - The rc.conf variable for the keys dir is `tangd_jwkdir`, not
#    `tangd_keys_dir`.
#  - Default port is already 8888 (matches our TANG_HTTP_PORT).
#  - The rc.d script only handles ONE instance; Tang #2 and #3 are
#    launched manually via `/usr/local/libexec/tangd -p PORT -l DIR`.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

echo "[tang] waiting for SSH..."
wait_for_ssh tang

echo "[tang] installing package security/tang + curl"
run_ssh tang "sudo pkg install -y -q tang curl"

echo "[tang] preparing /var/db/tang{,2,3} and generating server keys"
for i in "" 2 3; do
  dir="/var/db/tang${i}"
  run_ssh tang "sudo mkdir -p ${dir} && sudo chmod 700 ${dir}"
  run_ssh tang "[ -z \"\$(ls ${dir}/*.jwk 2>/dev/null)\" ] && sudo /usr/local/libexec/tangd-keygen ${dir} || true"
done
run_ssh tang "sudo ls /var/db/tang/"

echo "[tang] enabling tangd #1 in rc.conf (for future VM reboots)"
run_ssh tang "sudo sysrc tangd_enable=YES tangd_jwkdir=/var/db/tang tangd_port=${TANG_HTTP_PORT}"
run_ssh tang "sudo touch /var/log/tang && sudo chmod 644 /var/log/tang"

echo "[tang] starting tangd #1 (port ${TANG_HTTP_PORT}) via daemon -f"
# `service tangd restart` over SSH hangs because the rc.d wrapper does
# not detach all file descriptors from the SSH session. We bypass the
# rc.d for the in-test launch and use `daemon -f` directly, which is
# what tangd #2 and #3 already use below. The rc.conf config above
# remains so that a manual VM reboot restarts tangd via rc.d normally.
run_ssh tang "sudo service tangd onestop 2>/dev/null || true"
run_ssh tang "sudo pkill -f 'tangd -p ${TANG_HTTP_PORT} ' 2>/dev/null || true"
run_ssh tang "sudo daemon -f -p /var/run/tangd.pid -o /var/log/tang /usr/local/libexec/tangd -p ${TANG_HTTP_PORT} -l /var/db/tang"

echo "[tang] launching tangd #2 (port ${TANG_HTTP_PORT2}) and tangd #3 (port ${TANG_HTTP_PORT3}) via daemon -f"
run_ssh tang "sudo pkill -f 'tangd -p ${TANG_HTTP_PORT2} ' 2>/dev/null || true"
run_ssh tang "sudo pkill -f 'tangd -p ${TANG_HTTP_PORT3} ' 2>/dev/null || true"
run_ssh tang "sudo daemon -f -p /var/run/tangd2.pid -o /var/log/tang2.log /usr/local/libexec/tangd -p ${TANG_HTTP_PORT2} -l /var/db/tang2"
run_ssh tang "sudo daemon -f -p /var/run/tangd3.pid -o /var/log/tang3.log /usr/local/libexec/tangd -p ${TANG_HTTP_PORT3} -l /var/db/tang3"
run_ssh tang "sleep 1 && sudo sockstat -l4 | grep tangd"

echo "[tang] checking advertisements are reachable from host"
for p in "${TANG_HTTP_PORT}" "${TANG_HTTP_PORT2}" "${TANG_HTTP_PORT3}"; do
  if ! curl -fs --max-time 5 "http://127.0.0.1:${p}/adv" >/dev/null; then
    echo "[tang] FAIL: advertisement not reachable on port ${p}" >&2
    exit 1
  fi
  echo "[tang] OK port ${p}"
done

echo "[tang] all 3 Tangs ready : 8888, 8889, 8890 (host) -> /var/db/tang{,2,3} (guest)"
