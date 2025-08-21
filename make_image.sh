#!/bin/bash
echo "create and partition disk image..."

IMAGE="dual-os.img"
SIZE="8G"  # Larger size for two OSes

# Create image
fallocate -l $SIZE $IMAGE
LOOP=$(sudo losetup -f --show -P $IMAGE)

# Create partition table
sudo parted $LOOP mklabel msdos

# Create partitions
sudo parted $LOOP mkpart primary ext4 1MiB 513MiB     # boot
sudo parted $LOOP mkpart primary ext4 513MiB 4257MiB  # OS1 (3.7GB)
sudo parted $LOOP mkpart primary ext4 4257MiB 100%    # OS2 (remaining)

# Set boot flag
sudo parted $LOOP set 1 boot on

# Format partitions
sudo mkfs.ext4 -L "BOOT" ${LOOP}p1
sudo mkfs.ext4 -L "OS1-ROOT" ${LOOP}p2
sudo mkfs.ext4 -L "OS2-ROOT" ${LOOP}p3

echo "setup mount points"
# Create mount directories
BOOT_MNT="/tmp/shared-boot"
OS1_MNT="/tmp/os1-root"
OS2_MNT="/tmp/os2-root"

sudo mkdir -p $BOOT_MNT $OS1_MNT $OS2_MNT

# Mount partitions
sudo mount ${LOOP}p1 $BOOT_MNT
sudo mount ${LOOP}p2 $OS1_MNT
sudo mount ${LOOP}p3 $OS2_MNT

# Create boot directories in each OS
sudo mkdir -p $OS1_MNT/boot $OS2_MNT/boot

echo "setup first OS (ubuntu)"

# Debootstrap Ubuntu
sudo debootstrap --arch=amd64 jammy $OS1_MNT http://archive.ubuntu.com/ubuntu/

# Bind mount shared boot
sudo mount --bind $BOOT_MNT $OS1_MNT/boot

# Before chrooting, mount these filesystems
sudo mount --bind /dev $OS1_MNT/dev
sudo mount --bind /proc $OS1_MNT/proc
sudo mount --bind /sys $OS1_MNT/sys

# Configure first OS
sudo chroot $OS1_MNT /bin/bash << 'EOF'
# Set hostname
echo "ubuntu-os" > /etc/hostname

# Configure fstab
cat > /etc/fstab << 'FSTAB'
LABEL=OS1-ROOT / ext4 defaults 0 1
LABEL=BOOT /boot ext4 defaults 0 2
FSTAB

# Set root password
echo "root:ubuntu123" | chpasswd

# Install kernel and essential packages
apt update
apt install -y linux-image-generic grub-pc

# Install GRUB to the disk (not partition)
grub-install --boot-directory=/boot /dev/loop0

# Generate initial grub config
update-grub
EOF

# After chrooting, unmount
sudo umount $OS1_MNT/dev
sudo umount $OS1_MNT/proc
sudo umount $OS1_MNT/sys

# Unmount boot bind mount
sudo umount $OS1_MNT/boot

echo "install second OS (Debian)"

# Debootstrap Debian
sudo debootstrap --arch=amd64 bookworm $OS2_MNT http://deb.debian.org/debian/

# Bind mount shared boot
sudo mount --bind $BOOT_MNT $OS2_MNT/boot

# Configure second OS
sudo chroot $OS2_MNT /bin/bash << 'EOF'
set -e

# Set hostname
echo "debian-os" > /etc/hostname

# Configure fstab
cat > /etc/fstab << 'FSTAB'
LABEL=OS2-ROOT / ext4 defaults 0 1
LABEL=BOOT /boot ext4 defaults 0 2
FSTAB

# Set root password
echo "root:debian123" | chpasswd

# Update package lists
apt update

# Install kernel and GRUB tools
DEBIAN_FRONTEND=noninteractive apt install -y linux-image-amd64 grub2-common grub-pc-bin

# Check if update-grub exists, if not use grub-mkconfig
if command -v update-grub >/dev/null 2>&1; then
    update-grub
else
    grub-mkconfig -o /boot/grub/grub.cfg
fi
exit
EOF

# Unmount boot bind mount
sudo umount $OS2_MNT/boot

echo "Create unified GRUB configuration"

# Mount boot partition to configure GRUB
sudo mount ${LOOP}p1 $BOOT_MNT

# Create custom grub.cfg
sudo tee $BOOT_MNT/grub/grub.cfg > /dev/null << 'EOF'
set timeout=10
set default=0

menuentry "Ubuntu OS" {
    linux /vmlinuz root=LABEL=OS1-ROOT ro quiet splash
    initrd /initrd.img
}

menuentry "Debian OS" {
    linux /vmlinuz root=LABEL=OS2-ROOT ro quiet
    initrd /initrd.img
}

menuentry "Ubuntu OS (recovery)" {
    linux /vmlinuz root=LABEL=OS1-ROOT ro recovery nomodeset
    initrd /initrd.img
}

menuentry "Debian OS (recovery)" {
    linux /vmlinuz root=LABEL=OS2-ROOT ro recovery nomodeset
    initrd /initrd.img
}
EOF

echo "handle kernel management..."
# Rename kernels to avoid conflicts
sudo chroot $OS1_MNT /bin/bash << 'EOF'
# Create update hook to rename Ubuntu kernels
cat > /etc/kernel/postinst.d/zz-rename-ubuntu << 'SCRIPT'
#!/bin/bash
version="$1"
bootdir="$2"
# Rename Ubuntu kernels with ubuntu- prefix
if [ -f "$bootdir/vmlinuz-$version" ]; then
    cp "$bootdir/vmlinuz-$version" "$bootdir/vmlinuz-ubuntu-$version"
    cp "$bootdir/initrd.img-$version" "$bootdir/initrd.img-ubuntu-$version"
fi
SCRIPT
chmod +x /etc/kernel/postinst.d/zz-rename-ubuntu
EOF

sudo chroot $OS2_MNT /bin/bash << 'EOF'
# Create update hook to rename Debian kernels
cat > /etc/kernel/postinst.d/zz-rename-debian << 'SCRIPT'
#!/bin/bash
version="$1"
bootdir="$2"
# Rename Debian kernels with debian- prefix
if [ -f "$bootdir/vmlinuz-$version" ]; then
    cp "$bootdir/vmlinuz-$version" "$bootdir/vmlinuz-debian-$version"
    cp "$bootdir/initrd.img-$version" "$bootdir/initrd.img-debian-$version"
fi
SCRIPT
chmod +x /etc/kernel/postinst.d/zz-rename-debian
EOF

echo "Update GRUB configuration for specific kernels..."
# Get actual kernel versions and update grub.cfg
UBUNTU_KERNEL=$(ls $BOOT_MNT/vmlinuz-* | grep -v ubuntu | grep -v debian | head -1 | sed 's/.*vmlinuz-//')
DEBIAN_KERNEL=$(ls $OS2_MNT/boot/vmlinuz-* 2>/dev/null | head -1 | sed 's/.*vmlinuz-//' || echo "")

# Update grub.cfg with actual kernel names
sudo tee $BOOT_MNT/grub/grub.cfg > /dev/null << EOF
set timeout=10
set default=0

menuentry "Ubuntu OS" {
    linux /vmlinuz-${UBUNTU_KERNEL} root=LABEL=OS1-ROOT ro quiet splash
    initrd /initrd.img-${UBUNTU_KERNEL}
}

menuentry "Debian OS" {
    linux /vmlinuz-${DEBIAN_KERNEL} root=LABEL=OS2-ROOT ro quiet
    initrd /initrd.img-${DEBIAN_KERNEL}
}
EOF

echo "cleanup..."
# Unmount everything
sudo umount $BOOT_MNT $OS1_MNT $OS2_MNT
sudo rmdir $BOOT_MNT $OS1_MNT $OS2_MNT
sudo losetup -d $LOOP

echo "Dual-OS image created: $IMAGE"

echo "creating vhd image..."
qemu-img convert -f raw -O vpc dual-os.img dual-os.vhd
