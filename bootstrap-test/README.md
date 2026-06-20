# Banc de test QEMU — install-pkgbase.sh

Banc **local** (macOS Apple Silicon, arm64) qui rejoue le script
d'installation FreeBSD pkgbase de beryl
(`src/beryl/bootstrap/templates/install-pkgbase.sh`) contre des disques
vierges, **puis reboote sur le résultat**, pour prouver que l'install
produit un système amorçable — sans toucher à du vrai matériel OVH.

## Usage

```sh
./run.sh                 # cas normal : install + boot, cleanup en fin
./run.sh --keep          # idem mais conserve disques/overlay/logs sous run/
./run.sh --no-data-pool  # install sans pool data (vtbd3/vtbd4 ignorés)
```

Code retour : `0` = PASS, `1` = FAIL. Le bilan PASS/FAIL est affiché en fin.

## Ce que ça fait

1. Génère une paire de clés SSH de test (`run/id_ed25519`).
2. Crée 4 disques vierges raw de 8 Go (`run/disk1..disk4.raw`).
3. Construit un seed cloud-init (volume `cidata`, datasource NoCloud) qui
   injecte la clé pub de test dans l'utilisateur `freebsd`.
4. **Phase INSTALL** — boote la VM installeur :
   - `vtbd0` = overlay qcow2 de l'image cloud FreeBSD 15 aarch64 (jamais
     modifiée : overlay `-b`) ;
   - `vtbd1..vtbd4` = les 4 disques vierges ;
   - seed cloud-init en CD-ROM ; hostfwd SSH host `:2240`.

   Attend le SSH `freebsd@:2240`, vérifie que `/usr/share/keys/pkgbase-15`
   existe (sinon l'install pkgbase échouerait → on abandonne tôt avec un
   message clair), rend `install-pkgbase.sh` (substitution `sed` des
   placeholders `__XXX__`), le `scp` dans la VM, l'exécute en root
   (`sudo sh /tmp/install-pkgbase.sh`), capture toute la sortie
   (`run/install-output.log`).

   Cas normal substitué : `zroot` **mirror** sur `vtbd1`+`vtbd2`, swap 1 Go,
   user `admin` (groupe `wheel`, clé de test), sudoers `%wheel NOPASSWD`,
   pool data `zdata` sur `vtbd3`+`vtbd4`, ABI `FreeBSD:15:aarch64`.

5. Poweroff propre de la VM installeur, attente de la fin du process QEMU.
6. **Phase BOOT** — boote une **nouvelle** VM depuis **uniquement** les 4
   disques installés (`vtbd0`=disk1 … pas d'image cloud, pas de seed).
   L'UEFI edk2 doit trouver `BOOTAA64.EFI` (posé par le script sur chaque
   disque boot) et amorcer le FreeBSD installé. hostfwd SSH host `:2241`.
7. Attend le SSH **`admin@:2241`** avec la clé de test (timeout 3 min).
   - **SSH admin OK = PASS** : boot + DHCP QEMU + auth admin tous validés.
     Lance `uname -a`, `zpool status`, `sudo -n true`.
   - Échec = dump des 100 dernières lignes du serial.log de boot pour
     diagnostiquer (boot ? panic ? réseau ?).
8. Bilan `PASS`/`FAIL` + cleanup (sauf `--keep`).

## Détails QEMU

- Accélération **hvf**, machine `virt,gic-version=3`, `-cpu host`.
- Firmware UEFI **edk2** en `pflash` (code en lecture seule +
  **vars NVRAM inscriptibles** copiés depuis `edk2-arm-vars.fd`), pour que
  le `BootOrder` écrit par l'install persiste jusqu'à la phase BOOT. Si le
  template de vars manque, repli sur `-bios` (BootOrder non persistant).
- Disques cibles en `virtio` raw → apparaissent comme `vtbd0`, `vtbd1`…
  dans l'ordre des `-drive`.
- VMs lancées en `-daemonize` avec pidfile ; serial redirigé vers un log.

## Artefacts (`run/`, gitignoré)

| Fichier | Contenu |
|---|---|
| `id_ed25519[.pub]` | clé SSH de test |
| `disk1..disk4.raw` | disques cibles |
| `seed.iso` | seed cloud-init |
| `installer-overlay.qcow2` | overlay de l'image cloud |
| `install-pkgbase.rendered.sh` | script après substitution |
| `install-output.log` | sortie complète de l'install |
| `install-serial.log` / `boot-serial.log` | consoles série des 2 phases |

## Pré-requis (déjà satisfaits sur ce poste)

- `qemu-system-aarch64`, `qemu-img` (Homebrew), accel `hvf`.
- Firmware `/opt/homebrew/share/qemu/edk2-aarch64-code.fd` (+ vars).
- Image cloud
  `~/prod-crystal/qemu/images/FreeBSD-15.0-RELEASE-arm64-aarch64-BASIC-CLOUDINIT-ufs.qcow2`.
