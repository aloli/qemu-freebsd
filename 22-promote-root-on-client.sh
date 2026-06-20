#!/usr/bin/env bash
# Promote root SSH access on the client VM (idempotent).
#
# The cloud-init image bootstraps the VM with user `freebsd` (sudoer
# without password) and only that user has its public key in
# /home/freebsd/.ssh/authorized_keys. clevis-zfs itself runs
# fine via `sudo` from the freebsd user, so this script is NOT
# required for the standard test bench (./30-test-bind-unlock.sh).
#
# It IS required when an external tool wants to drive the VM as a
# regular FreeBSD host over SSH-as-root. That's the case for the
# `beryl` integration tests, which call `ssh root@<host>`
# directly without sudo wrapping.
#
# What this script does:
#   1. Copies /home/freebsd/.ssh/authorized_keys to /root/.ssh/.
#   2. Adds `PermitRootLogin prohibit-password` to /etc/ssh/sshd_config
#      (idempotent: appended only if not already there).
#   3. Reloads sshd.
#
# Idempotent: re-running is a no-op.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

echo "[client-root] waiting for SSH..."
wait_for_ssh client

echo "[client-root] copying authorized_keys from freebsd to root"
run_ssh client "sudo mkdir -p /root/.ssh"
run_ssh client "sudo install -m 0600 /home/freebsd/.ssh/authorized_keys /root/.ssh/authorized_keys"
run_ssh client "sudo chown root:wheel /root/.ssh/authorized_keys"

echo "[client-root] enabling PermitRootLogin prohibit-password (idempotent)"
run_ssh client "grep -q '^PermitRootLogin prohibit-password' /etc/ssh/sshd_config || echo 'PermitRootLogin prohibit-password' | sudo tee -a /etc/ssh/sshd_config > /dev/null"

echo "[client-root] reloading sshd"
run_ssh client "sudo service sshd reload"

echo "[client-root] verifying root SSH"
ssh \
  -i "${SSH_KEY}" \
  -p "${CLIENT_SSH_PORT}" \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  -o LogLevel=ERROR \
  -o ConnectTimeout=5 \
  root@127.0.0.1 \
  uname -s

echo "[client-root] OK — root@127.0.0.1:${CLIENT_SSH_PORT} is now reachable via the bench SSH key"
