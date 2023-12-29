#MAGISK
############################################
# Magisk Uninstaller (updater-script)
############################################

##############
# Preparation
##############

# Default permissions
umask 022

if [ ! -f $INSTALLER/util_functions.sh ]; then
  echo "! Unable to extract zip file!"
  exit 1
fi

# Load utility functions
. $INSTALLER/util_functions.sh

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

ui_print "- Stop Magisk Daemon"
magisk --stop

ui_print "- Removing modules"
for module in /data/adb/modules/*; do
  dir=$(echo "$module" | sed "s/modules/modules_update/")

  [ ! -d "$dir" ] && dir=$module

  sh $dir/uninstall.sh
  sh /data/adb/load-module/backup/remove-$(basename $module).sh
done

ui_print "- Removing Magisk files"
rm -rf \
/sbin/magisk* /sbin/su* /sbin/resetprop /sbin/.magisk \
/cache/*magisk* /cache/unblock /data/*magisk* /data/cache/*magisk* /data/property/*magisk* \
/data/Magisk.apk /data/busybox /data/custom_ramdisk_patch.sh /data/adb/*magisk* \
/data/adb/load-module /data/adb/post-fs-data.d /data/adb/service.d /data/adb/modules* \
/data/local/tmp/busybox //data/unencrypted/magisk /metadata/magisk /persist/magisk \
/mnt/vendor/persist/magisk /system/etc/init/magisk.rc $TMPDIR

ui_print "- Done"