#!/usr/bin/env bash
set -euxo pipefail

RELEASE="${1:-excalibur}"
SIZE="${2:-4G}"
ARCH="amd64"
IMAGE="devuan-${RELEASE}-${ARCH}.raw"
QCOW2="devuan-${RELEASE}-${ARCH}.qcow2"
ROOT_LABEL="rootfs"
MIRROR="http://deb.devuan.org/merged"
WORKDIR="${WORKDIR:-$PWD/work}"
OUTDIR="${OUTDIR:-$PWD/out}"
MOUNTPOINT="$WORKDIR/mnt"
NBD="/dev/nbd0"
PART="/dev/nbd0p1"

cleanup() {
  set +e
  mountpoint -q "$MOUNTPOINT/dev/pts" && umount -lf "$MOUNTPOINT/dev/pts"
  mountpoint -q "$MOUNTPOINT/dev" && umount -lf "$MOUNTPOINT/dev"
  mountpoint -q "$MOUNTPOINT/proc" && umount -lf "$MOUNTPOINT/proc"
  mountpoint -q "$MOUNTPOINT/sys" && umount -lf "$MOUNTPOINT/sys"
  mountpoint -q "$MOUNTPOINT/run" && umount -lf "$MOUNTPOINT/run"
  mountpoint -q "$MOUNTPOINT" && umount -lf "$MOUNTPOINT"
  qemu-nbd --disconnect "$NBD" >/dev/null 2>&1 || true
}
trap cleanup EXIT

mkdir -p "$WORKDIR" "$OUTDIR" "$MOUNTPOINT"
rm -f "$WORKDIR/$IMAGE" "$OUTDIR/$QCOW2"

# Ubuntu runners may not have a Devuan suite script; Excalibur follows Debian Trixie.
if [[ "$RELEASE" == "excalibur" && ! -e /usr/share/debootstrap/scripts/excalibur ]]; then
  ln -s /usr/share/debootstrap/scripts/trixie /usr/share/debootstrap/scripts/excalibur
fi

modprobe nbd max_part=8
qemu-img create -f raw "$WORKDIR/$IMAGE" "$SIZE"
qemu-nbd --format=raw --connect="$NBD" "$WORKDIR/$IMAGE"
udevadm settle

parted -s "$NBD" mklabel msdos
parted -s "$NBD" mkpart primary ext4 1MiB 100%
parted -s "$NBD" set 1 boot on
partprobe "$NBD"
udevadm settle

for _ in $(seq 1 20); do
  [[ -b "$PART" ]] && break
  partprobe "$NBD" || true
  udevadm settle || true
  sleep 1
done
[[ -b "$PART" ]]

mkfs.ext4 -F -L "$ROOT_LABEL" "$PART"
mount "$PART" "$MOUNTPOINT"

# Keep debootstrap minimal. Packages with maintainer scripts are installed later,
# after /dev, /dev/pts, /proc and /sys are available inside the target rootfs.
DEBOOTSTRAP_INCLUDE="devuan-keyring,ca-certificates,apt"

debootstrap \
  --arch="$ARCH" \
  --variant=minbase \
  --merged-usr \
  --no-check-gpg \
  --include="$DEBOOTSTRAP_INCLUDE" \
  "$RELEASE" "$MOUNTPOINT" "$MIRROR"

cat > "$MOUNTPOINT/etc/apt/sources.list" <<APT
# Devuan ${RELEASE}
deb http://deb.devuan.org/merged ${RELEASE} main
deb http://deb.devuan.org/merged ${RELEASE}-updates main
deb http://deb.devuan.org/merged ${RELEASE}-security main
APT

cat > "$MOUNTPOINT/etc/fstab" <<FSTAB
LABEL=${ROOT_LABEL} / ext4 defaults 0 1
FSTAB

cat > "$MOUNTPOINT/etc/hostname" <<EOFHOST
devuan-${RELEASE}
EOFHOST

cat > "$MOUNTPOINT/etc/hosts" <<HOSTS
127.0.0.1 localhost
127.0.1.1 devuan-${RELEASE}
::1 localhost ip6-localhost ip6-loopback
HOSTS

cat > "$MOUNTPOINT/etc/network/interfaces" <<NET
source /etc/network/interfaces.d/*
auto lo
iface lo inet loopback
iface ens3 inet dhcp
iface eth0 inet dhcp
iface eth0 inet6 manual
NET

mkdir -p "$MOUNTPOINT/etc/cloud/cloud.cfg.d"
cat > "$MOUNTPOINT/etc/cloud/cloud.cfg.d/99-devuan-default-user.cfg" <<CLOUD
system_info:
  default_user:
    name: devuan
    lock_passwd: true
    gecos: Devuan
    groups: [adm, cdrom, dip, sudo]
    sudo: ["ALL=(ALL) NOPASSWD:ALL"]
    shell: /bin/bash
ssh_pwauth: false
disable_root: true
CLOUD

cat > "$MOUNTPOINT/etc/default/grub" <<GRUB
GRUB_DEFAULT=0
GRUB_TIMEOUT=1
GRUB_DISTRIBUTOR="Devuan"
GRUB_CMDLINE_LINUX_DEFAULT="console=ttyS0,115200n8"
GRUB_CMDLINE_LINUX="net.ifnames=0"
GRUB_TERMINAL="serial console"
GRUB_SERIAL_COMMAND="serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1"
GRUB

mkdir -p "$MOUNTPOINT/dev" "$MOUNTPOINT/dev/pts" "$MOUNTPOINT/proc" "$MOUNTPOINT/sys" "$MOUNTPOINT/run"
mount --bind /dev "$MOUNTPOINT/dev"
mount --bind /dev/pts "$MOUNTPOINT/dev/pts"
mount -t proc proc "$MOUNTPOINT/proc"
mount -t sysfs sys "$MOUNTPOINT/sys"
mount --bind /run "$MOUNTPOINT/run"

cat > "$MOUNTPOINT/usr/sbin/policy-rc.d" <<'POLICY'
#!/bin/sh
exit 101
POLICY
chmod +x "$MOUNTPOINT/usr/sbin/policy-rc.d"

cat > "$MOUNTPOINT/etc/apt/apt.conf.d/99cloud-image-build" <<'APTCONF'
APT::Install-Recommends "false";
APT::Install-Suggests "false";
Dpkg::Options {
  "--force-confdef";
  "--force-confold";
};
APTCONF

chroot "$MOUNTPOINT" /bin/bash -eux <<'CHROOT'
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get -y dist-upgrade
apt-get install -y --no-install-recommends \
  linux-image-amd64 \
  grub-pc \
  e2fsprogs \
  zstd \
  openssh-server \
  cloud-init \
  qemu-guest-agent \
  sudo \
  ifupdown \
  isc-dhcp-client \
  eudev \
  sysvinit-core \
  elogind \
  rsyslog \
  bash-completion \
  less \
  nano \
  curl

# Make sure host keys exist for images where openssh postinst skipped generation.
dpkg-reconfigure openssh-server || true
ssh-keygen -A || true

update-initramfs -u -k all
update-grub
CHROOT

chroot "$MOUNTPOINT" grub-install --target=i386-pc --recheck "$NBD"

chroot "$MOUNTPOINT" /bin/bash -eux <<'CHROOT'
export DEBIAN_FRONTEND=noninteractive
apt-get autoremove --purge -y
apt-get clean
rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*
CHROOT

rm -f "$MOUNTPOINT/usr/sbin/policy-rc.d"
chroot "$MOUNTPOINT" dpkg-query -W > "$OUTDIR/devuan-${RELEASE}-${ARCH}.manifest.txt"

cleanup
trap - EXIT

qemu-img convert -f raw -O qcow2 -c "$WORKDIR/$IMAGE" "$OUTDIR/$QCOW2"
qemu-img info "$OUTDIR/$QCOW2"
