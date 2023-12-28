#MAGISK
############################################
# Magisk Uninstaller (updater-script)
############################################

##############
# Preparation
##############

# Default permissions
umask 022

OUTFD=$2
COMMONDIR=$INSTALLER/assets

if [ ! -f $COMMONDIR/util_functions.sh ]; then
  echo "! Unable to extract zip file!"
  exit 1
fi

# Load utility functions
. $COMMONDIR/util_functions.sh

setup_flashable

############
# Detection
############

if echo $MAGISK_VER | grep -q '\.'; then
  PRETTY_VER=$MAGISK_VER
else
  PRETTY_VER="$MAGISK_VER($MAGISK_VER_CODE)"
fi
print_title "Magisk $PRETTY_VER Uninstaller"

############
# Uninstall
############

if $BOOTMODE; then
  ui_print "- Removing modules"
  magisk --remove-modules -n

  for scripts in $ROOTFS/data/adb/load-module/backup/remove-*.sh; do sh $scripts; done
fi

ui_print "- Removing Magisk files"
rm -rf \
$ROOTFS/sbin/magisk* $ROOTFS/sbin/su* $ROOTFS/sbin/resetprop $ROOTFS/sbin/.magisk \
$ROOTFS/cache/*magisk* $ROOTFS/cache/unblock $ROOTFS/data/*magisk* $ROOTFS/data/cache/*magisk* $ROOTFS/data/property/*magisk* \
$ROOTFS/data/Magisk.apk $ROOTFS/data/busybox $ROOTFS/data/custom_ramdisk_patch.sh $ROOTFS/data/adb/*magisk* \
$ROOTFS/data/adb/load-module $ROOTFS/data/adb/post-fs-data.d $ROOTFS/data/adb/service.d $ROOTFS/data/adb/modules* \
$ROOTFS/data/local/tmp/busybox /$ROOTFS/data/unencrypted/magisk $ROOTFS/metadata/magisk $ROOTFS/persist/magisk \
$ROOTFS/mnt/vendor/persist/magisk $ROOTFS/system/etc/init/magisk.rc $TMPDIR

ui_print "- Done"