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

parted -s "$NBD" mklabel msdos
parted -s "$NBD" mkpart primary ext4 1MiB 100%
parted -s "$NBD" set 1 boot on
partprobe "$NBD"
udevadm settle

mkfs.ext4 -F -L "$ROOT_LABEL" "$PART"
mount "$PART" "$MOUNTPOINT"

INCLUDE="devuan-keyring,ca-certificates,linux-image-amd64,grub-pc,cloud-init,qemu-guest-agent,sudo,ifupdown,isc-dhcp-client,eudev,sysvinit-core,elogind,rsyslog,bash-completion,less,nano,curl"

debootstrap \
  --arch="$ARCH" \
  --variant=minbase \
  --merged-usr \
  --no-check-gpg \
  --include="$INCLUDE" \
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
allow-hotplug ens3
iface ens3 inet dhcp
allow-hotplug eth0
iface eth0 inet dhcp
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

# Avoid service starts in chroot.
printf '#!/bin/sh\nexit 101\n' > "$MOUNTPOINT/usr/sbin/policy-rc.d"
chmod +x "$MOUNTPOINT/usr/sbin/policy-rc.d"

mount --bind /dev "$MOUNTPOINT/dev"
mount --bind /dev/pts "$MOUNTPOINT/dev/pts"
mount -t proc proc "$MOUNTPOINT/proc"
mount -t sysfs sys "$MOUNTPOINT/sys"
mount --bind /run "$MOUNTPOINT/run"

chroot "$MOUNTPOINT" /bin/bash -eux <<CHROOT
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get -y dist-upgrade
dpkg-reconfigure openssh-server || true
update-initramfs -u -k all
update-grub
grub-install --target=i386-pc --recheck "$NBD"
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
