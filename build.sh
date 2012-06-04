#!/bin/bash

# make sure we have dependencies
hash mkisofs 2>/dev/null || { echo >&2 "ERROR: mkisofs not found.  Aborting."; exit 1; }

# install system dependencies
sudo apt-get install virtualbox virtualbox-qt virtualbox-dkms virtualbox-guest-additions-iso

BOX="ubuntu-12.04-64"
FOLDER_BASE=`pwd`
FOLDER_BUILD="${FOLDER_BASE}/build"
FOLDER_VBOX="${FOLDER_BUILD}/vbox"
FOLDER_ISO="${FOLDER_BUILD}/iso"
FOLDER_ISO_TMP="${FOLDER_BUILD}/iso_tmp"
FOLDER_ISO_CUSTOM="${FOLDER_BUILD}/iso/custom"
FOLDER_ISO_INITRD="${FOLDER_BUILD}/iso/initrd"

# let's make sure they exist
mkdir -p "${FOLDER_BUILD}"
mkdir -p "${FOLDER_VBOX}"
mkdir -p "${FOLDER_ISO}"

sudo rm -rf "${FOLDER_ISO_TMP}"
mkdir -p "${FOLDER_ISO_TMP}"

# let's make sure they're empty
echo "Cleaning Custom build directories..."
sudo rm -rf "${FOLDER_ISO_CUSTOM}"
sudo rm -rf "${FOLDER_ISO_INITRD}"
mkdir -p "${FOLDER_ISO_INITRD}"
sudo rm -rf "${BOX}.box"
VBoxManage unregistervm ${BOX} --delete 1>/dev/null 2>/dev/null

ISO_URL="http://mirror.internode.on.net/pub/ubuntu/releases/12.04/ubuntu-12.04-alternate-amd64.iso"
ISO_FILENAME="${FOLDER_ISO}/`basename ${ISO_URL}`"
ISO_MD5="9fcc322536575dda5879c279f0b142d7"
INITRD_FILENAME="${FOLDER_ISO}/initrd.gz"
ISO_MD5SUM_TEMP="${FOLDER_BUILD}/md5sum"
ISO_GUESTADDITIONS="/usr/share/virtualbox/VBoxGuestAdditions.iso"

# download the installation disk if you haven't already or it is corrupted somehow
echo "Downloading ubuntu-12.04-alternate-amd64.iso ..."
if [ ! -e "${ISO_FILENAME}" ]; then
  curl --output "${ISO_FILENAME}" -L "${ISO_URL}"
fi

# make sure download is right...
echo "${ISO_MD5} *${ISO_FILENAME}" > $ISO_MD5SUM_TEMP
md5sum --status --check $ISO_MD5SUM_TEMP
if [ $? != 0 ]; then
  echo "ERROR: MD5 does not match. Aborting."
  exit 1
fi

# customize it
echo "Creating Custom ISO"

echo "Extracting downloaded ISO ..."
sudo mount -t iso9660 -o ro,loop "${ISO_FILENAME}" "${FOLDER_ISO_TMP}"
cp -a ${FOLDER_ISO_TMP} ${FOLDER_ISO_CUSTOM}
sudo umount "${FOLDER_ISO_TMP}"

# backup initrd.gz
echo "Backing up current init.rd ..."
chmod u+w "${FOLDER_ISO_CUSTOM}/install" "${FOLDER_ISO_CUSTOM}/install/initrd.gz"
mv "${FOLDER_ISO_CUSTOM}/install/initrd.gz" "${FOLDER_ISO_CUSTOM}/install/initrd.gz.org"

# stick in our new initrd.gz
echo "Installing new initrd.gz ..."
cd "${FOLDER_ISO_INITRD}"
gunzip -c "${FOLDER_ISO_CUSTOM}/install/initrd.gz.org" | sudo cpio -id
cd "${FOLDER_BASE}"
cp preseed.cfg "${FOLDER_ISO_INITRD}/preseed.cfg"
cd "${FOLDER_ISO_INITRD}"
find . | sudo cpio --create --format='newc' | gzip  > "${FOLDER_ISO_CUSTOM}/install/initrd.gz"

# clean up permissions
echo "Cleaning up Permissions ..."
chmod u-w "${FOLDER_ISO_CUSTOM}/install" "${FOLDER_ISO_CUSTOM}/install/initrd.gz" "${FOLDER_ISO_CUSTOM}/install/initrd.gz.org"

# replace isolinux configuration
echo "Replacing isolinux config ..."
cd "${FOLDER_BASE}"
chmod u+w "${FOLDER_ISO_CUSTOM}/isolinux" "${FOLDER_ISO_CUSTOM}/isolinux/isolinux.cfg"
rm "${FOLDER_ISO_CUSTOM}/isolinux/isolinux.cfg"
cp isolinux.cfg "${FOLDER_ISO_CUSTOM}/isolinux/isolinux.cfg"
chmod u+w "${FOLDER_ISO_CUSTOM}/isolinux/isolinux.bin"

# add late_command script
echo "Add late_command script ..."
chmod u+w "${FOLDER_ISO_CUSTOM}"
cp "${FOLDER_BASE}/late_command.sh" "${FOLDER_ISO_CUSTOM}"

echo "Running mkisofs ..."
mkisofs -r -V "Custom Ubuntu Install CD" \
  -cache-inodes -quiet \
  -J -l -b isolinux/isolinux.bin \
  -c isolinux/boot.cat -no-emul-boot \
  -boot-load-size 4 -boot-info-table \
  -o "${FOLDER_ISO}/custom.iso" "${FOLDER_ISO_CUSTOM}"

# create virtual machine
echo "Creating VM Box..."
VBoxManage createvm \
  --name "${BOX}" \
  --ostype Ubuntu_64 \
  --register \
  --basefolder "${FOLDER_VBOX}"

echo "Modifying VM Box..."
VBoxManage modifyvm "${BOX}" \
  --memory 360 \
  --boot1 dvd \
  --boot2 disk \
  --boot3 none \
  --boot4 none \
  --vram 12 \
  --pae off \
  --rtcuseutc on

echo "Setting storage IDE controller..."
VBoxManage storagectl "${BOX}" \
  --name "IDE Controller" \
  --add ide \
  --controller PIIX4 \
  --hostiocache on

echo "Setting storage IDE attachment..."
VBoxManage storageattach "${BOX}" \
  --storagectl "IDE Controller" \
  --port 1 \
  --device 0 \
  --type dvddrive \
  --medium "${FOLDER_ISO}/custom.iso"

echo "Setting storage SATA controller..."
VBoxManage storagectl "${BOX}" \
  --name "SATA Controller" \
  --add sata \
  --controller IntelAhci \
  --sataportcount 1 \
  --hostiocache off

echo "Creating HD..."
VBoxManage createhd \
  --filename "${FOLDER_VBOX}/${BOX}/${BOX}.vdi" \
  --size 40960

echo "Setting storage SATA attachment..."
VBoxManage storageattach "${BOX}" \
  --storagectl "SATA Controller" \
  --port 0 \
  --device 0 \
  --type hdd \
  --medium "${FOLDER_VBOX}/${BOX}/${BOX}.vdi"

echo "Starting the VM..."
VBoxManage startvm "${BOX}"

echo -n "Waiting for installer to finish "
while VBoxManage list runningvms | grep "${BOX}" >/dev/null; do
  sleep 20
  echo -n "."
done
echo ""

# Forward SSH
echo "Forwarding the SSH port..."
VBoxManage modifyvm "${BOX}" --natpf1 "guestssh,tcp,,2222,,22"

# Attach guest additions iso
echo "Attaching guest additions ISO..."
VBoxManage storageattach "${BOX}" \
  --storagectl "IDE Controller" \
  --port 1 \
  --device 0 \
  --type dvddrive \
  --medium "${ISO_GUESTADDITIONS}"

echo "Starting the VM..."
VBoxManage startvm "${BOX}"

# get private key
echo "Adding private key..."
curl --output "${FOLDER_BUILD}/id_rsa" "https://raw.github.com/mitchellh/vagrant/master/keys/vagrant"
chmod 600 "${FOLDER_BUILD}/id_rsa"

# install virtualbox guest additions
echo "Installing guest additions..."
ssh -i "${FOLDER_BUILD}/id_rsa" -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -p 2222 vagrant@127.0.0.1 "sudo mount /dev/cdrom /media/cdrom; sudo sh /media/cdrom/VBoxLinuxAdditions.run; sudo umount /media/cdrom; sudo shutdown -h now"
echo -n "Waiting for machine to shut off "
while VBoxManage list runningvms | grep "${BOX}" >/dev/null; do
  sleep 20
  echo -n "."
done
echo ""

echo "Removing SSH port forward..."
VBoxManage modifyvm "${BOX}" --natpf1 delete "guestssh"

# Detach guest additions iso
echo "Detach guest additions ..."
VBoxManage storageattach "${BOX}" \
  --storagectl "IDE Controller" \
  --port 1 \
  --device 0 \
  --type dvddrive \
  --medium emptydrive

echo "Building Vagrant Box ..."
vagrant package --base "${BOX}"

# references:
# http://blog.ericwhite.ca/articles/2009/11/unattended-debian-lenny-install/
# http://cdimage.ubuntu.com/releases/precise/beta-2/
# http://www.imdb.com/name/nm1483369/
# http://vagrantup.com/docs/base_boxes.html
