# Devuan Excalibur amd64 qcow2 image

Minimal Devuan Excalibur amd64 qcow2 image for KVM/libvirt, inspired by Salsa Debian cloud-image builder from https://salsa.debian.org/cloud-team/debian-cloud-images.

The image is built by Github Actions from Devuan `excalibur`, includes `cloud-init`, `openssh-server`, `qemu-guest-agent`, `sysvinit`, `eudev`, `elogind`, `e2fsprogs` and `zstd`. You can see all packages and build process in `.github/workflows/build-devuan-qcow2.yml`

Default image properties:

```text
Distribution: Devuan
Release:      Excalibur
Architecture: amd64
Image format: qcow2
Boot mode:    BIOS / SeaBIOS
Init system:  sysvinit
Cloud-init:   enabled
Default user: devuan
SSH password: disabled
Root login:   disabled
```

## Download

Download the image:

```bash
curl -sSfL -o devuan-excalibur-amd64.qcow2 \
  "https://github.com/techpipe-io/devuan-cloud-images/releases/download/devuan-excalibur-6.1.0-amd64-20260607/devuan-excalibur-amd64.qcow2"
```

Download checksums:

```bash
curl -sSfL -o SHA256SUMS \
  "https://github.com/techpipe-io/devuan-cloud-images/releases/download/devuan-excalibur-6.1.0-amd64-20260607/SHA256SUMS"
```

Verify:

```bash
sha256sum -c SHA256SUMS --ignore-missing
```

Optional: download package manifest:

```bash
curl -sSfL -o devuan-excalibur-amd64.manifest.txt \
  "https://github.com/techpipe-io/devuan-cloud-images/releases/download/devuan-excalibur-6.1.0-amd64-20260607/devuan-excalibur-amd64.manifest.txt"
```

## Usage with libvirt / virsh

### 1. Install required tools

Debian/Devuan/Ubuntu host:

```bash
sudo apt-get update
sudo apt-get install -y \
  qemu-kvm \
  libvirt-daemon-system \
  libvirt-clients \
  virtinst \
  cloud-image-utils
```

Enable libvirt if needed:

```bash
sudo systemctl enable --now libvirtd
```

### 2. Prepare VM disk

Copy the downloaded image into the libvirt images directory:

```bash
sudo cp devuan-excalibur-amd64.qcow2 /var/lib/libvirt/images/devuan-excalibur.qcow2
sudo chown libvirt-qemu:libvirt-qemu /var/lib/libvirt/images/devuan-excalibur.qcow2 2>/dev/null || true
```

Optionally resize the disk:

```bash
sudo qemu-img resize /var/lib/libvirt/images/devuan-excalibur.qcow2 20G
```

### 3. Create cloud-init seed image

Create `user-data`:

```bash
cat > user-data <<'EOF'
#cloud-config
hostname: devuan-test
manage_etc_hosts: true

users:
  - name: devuan
    groups: sudo
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
      - ssh-ed25519 REPLACE_WITH_YOUR_PUBLIC_KEY

ssh_pwauth: false
disable_root: true

package_update: true

growpart:
  mode: auto
  devices: ['/']
  ignore_growroot_disabled: false

resize_rootfs: true
EOF
```

Create `meta-data`:

```bash
cat > meta-data <<'EOF'
instance-id: devuan-test-001
local-hostname: devuan-test
EOF
```

Build the NoCloud seed ISO:

```bash
cloud-localds seed.iso user-data meta-data
```

### 4. Create and start VM

```bash
sudo virt-install \
  --name devuan-test \
  --memory 2048 \
  --vcpus 2 \
  --cpu host \
  --import \
  --os-variant debian12 \
  --disk path=/var/lib/libvirt/images/devuan-excalibur.qcow2,format=qcow2,bus=virtio \
  --disk path="$(pwd)/seed.iso",device=cdrom \
  --network network=default,model=virtio \
  --graphics none \
  --console pty,target_type=serial \
  --noautoconsole
```

Check VM state:

```bash
virsh list --all
```

Get VM IP address:

```bash
virsh domifaddr devuan-test
```

Connect with SSH:

```bash
ssh devuan@<vm-ip-address>
```

Open serial console:

```bash
virsh console devuan-test
```

Destroy and remove the test VM:

```bash
virsh destroy devuan-test
virsh undefine devuan-test --remove-all-storage
```

## Usage with Vagrant and vagrant-libvirt

This image can be used with Vagrant by packaging the qcow2 file as a local libvirt box.

### 1. Install Vagrant and vagrant-libvirt

Debian/Devuan/Ubuntu host:

```bash
sudo apt-get update
sudo apt-get install -y \
  vagrant \
  qemu-kvm \
  libvirt-daemon-system \
  libvirt-clients \
  ebtables \
  dnsmasq-base \
  ruby-libvirt
```

Install the libvirt provider plugin:

```bash
vagrant plugin install vagrant-libvirt
```

### 2. Create a local Vagrant box

Create a temporary box directory:

```bash
mkdir -p devuan-excalibur-box
cp devuan-excalibur-amd64.qcow2 devuan-excalibur-box/box.img
```

Create `metadata.json`:

```bash
cat > devuan-excalibur-box/metadata.json <<'EOF'
{
  "provider": "libvirt",
  "format": "qcow2",
  "virtual_size": 4
}
EOF
```

Create the box archive:

```bash
tar -C devuan-excalibur-box -czf devuan-excalibur-amd64-libvirt.box .
```

Add the local box to Vagrant:

```bash
vagrant box add devuan-excalibur-amd64 devuan-excalibur-amd64-libvirt.box --provider libvirt
```

### 3. Create Vagrantfile

```bash
mkdir devuan-vagrant
cd devuan-vagrant
```

Create `Vagrantfile`:

```ruby
Vagrant.configure("2") do |config|
  config.vm.box = "devuan-excalibur-amd64"
  config.vm.hostname = "devuan-vagrant"

  config.vm.provider :libvirt do |libvirt|
    libvirt.memory = 2048
    libvirt.cpus = 2
    libvirt.disk_bus = "virtio"
    libvirt.nic_model_type = "virtio"
    libvirt.driver = "kvm"
  end

  config.vm.provision "shell", inline: <<-SHELL
    set -eux
    id
    uname -a
    cat /etc/os-release
  SHELL
end
```

Start the VM:

```bash
vagrant up --provider=libvirt
```

Connect:

```bash
vagrant ssh
```

Stop:

```bash
vagrant halt
```

Destroy:

```bash
vagrant destroy -f
```

## Notes

The image is intended for KVM/libvirt with BIOS/SeaBIOS boot. It is not an UEFI/OVMF image.

The image relies on `cloud-init` for first-boot user configuration, SSH keys, hostname and root filesystem expansion.

For direct `virsh` usage, provide a NoCloud seed ISO with `user-data` and `meta-data`.

For Vagrant usage, the qcow2 image should be wrapped into a libvirt `.box` archive.
