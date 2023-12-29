#!/system/bin/sh
#######################################################################################
# Magisk On VMOS Pro Installer
#######################################################################################

#################
# Initialization
#################

# Check Magisk State
[ -f "/sbin/magisk" ] && exit

if [ -z $SOURCEDMODE ]; then
  # Switch to the location of the script file
  cd "$INSTALLER"
  # Load utility functions
  . ./util_functions.sh
  # Check Android version
  api_level_arch_detect
fi

chmod -R 755 .

#########
# Installer
#########

ui_print "- Extracting Magisk files"

mkdir -m 755 /sbin/.magisk/
mkdir -m 777 /sbin/.magisk/block/
mkdir -m 777 /sbin/.magisk/mirror/
mkdir -m 777 /sbin/.magisk/worker/

mkdir -m 755 /data/adb/magisk/
mkdir -m 755 /data/adb/magisk/chromeos/
mkdir -m 755 /data/adb/post-fs-data.d/
mkdir -m 755 /data/adb/service.d/

mkdir -m 755 /data/adb/load-module/
mkdir -m 755 /data/adb/load-module/backup/
mkdir -m 755 /data/adb/load-module/config/

touch /sbin/.magisk/config

cp ./magisk32 /sbin/magisk32
cp ./magisk64 /sbin/magisk64
cp ./magiskpolicy /sbin/magiskpolicy
cp ./magiskinit /sbin/magiskinit

chmod 755 /sbin/magisk*
chmod 750 /sbin/magiskinit

ln -s /data/adb/modules /sbin/.magisk/modules

ln -s /sbin/magisk64 /sbin/magisk
ln -s /sbin/magisk /sbin/resetprop
ln -s /sbin/magiskpolicy /sbin/supolicy
ln -s /sbin/magisk /sbin/su

cp ./busybox-original /data/adb/magisk/busybox
cp ./magisk32 /data/adb/magisk/magisk32
cp ./magisk64 /data/adb/magisk/magisk64
cp ./magiskpolicy /data/adb/magisk/magiskpolicy
cp ./magiskinit /data/adb/magisk/magiskinit
cp ./magiskboot /data/adb/magisk/magiskboot
cp ./addon.d.sh /data/adb/magisk/addon.d.sh
cp ./util_functions.sh /data/adb/magisk/util_functions.sh
cp ./stub.apk /data/adb/magisk/stub.apk
cp -r ./chromeos/* /data/adb/magisk/chromeos/

chmod 755 -R /data/adb/magisk/

echo -e '#!/system/bin/sh\n#加载模块\n/system/bin/sh /data/adb/load-module/load-modules.sh\nexit 0' > /data/adb/post-fs-data.d/load-module.sh
echo -e '#!/system/bin/sh\n#加载列表\nlist=/data/adb/load-module/config/load-list\n#清理列表\nsed -i "/^$/d" $list\n#删除文件\nfor module in $(cat $list); do\n  #检测状态\n  [ ! -f "$module/update" -a ! -f "$module/skip_mount" -a ! -f "$module/disable" -a ! -f "$module/remove" ] && continue\n  #重启服务\n  [ -z "$restart" ] && setprop ctl.stop zygote && setprop ctl.stop zygote_secondary && restart=true\n  #执行文件\n  sh /data/adb/load-module/backup/remove-$(basename $module).sh > /dev/null 2>&1\n  #删除文件\n  rm -f /data/adb/load-module/backup/remove-$(basename $module).sh\n  #修改文件\n  sed -i "s|$module||" $list\ndone\n#并行运行\n{\n  #等待加载\n  while [ -z "$(cat /cache/magisk.log | grep "* Loading modules")" ]; do sleep 0.0; done\n  #加载文件\n  for module in /data/adb/modules/*; do\n    #检测状态\n    [ -f "$module/disable" ] && continue\n    #修改属性\n    for prop in $(cat "$module/system.prop"); do\n      echo "$prop" | sed "s/=/ /" | xargs setprop\n    done\n    #检测状态\n    [ "$(cat $list | grep "$module")" ] || [ -f "$module/skip_mount" ] || [ ! -d "$module/system/" ] && continue\n    #重启服务\n    [ -z "$restart" ] && setprop ctl.stop zygote && setprop ctl.stop zygote_secondary && restart=true\n    #切换目录\n    cd "$module/system"\n    #加载文件\n    for file in $(find); do\n      #目标文件\n      target=$(echo "$file" | sed "s/..//")\n      #检查类型\n      if [ -f "$module/system/$target" ]; then\n        #备份文件\n        if [ "$(cat "/system/$target")" ]; then\n          #检查文件\n          [ -f "/data/adb/load-module/backup/system/$target" ] && continue\n          #创建目录\n          mkdir -p "/data/adb/load-module/backup/system/$(dirname "$target")" > /dev/null 2>&1\n          #复制文件\n          cp -p "/system/$target" "/data/adb/load-module/backup/system/$target" || continue\n          #修改文件\n          echo -e "cp -p /data/adb/load-module/backup/system/$target /system/$target\nrm /data/adb/load-module/backup/system/$target" >> /data/adb/load-module/backup/remove-$(basename $module).sh\n        else\n          #修改文件\n          echo "rm -f /system/$target" >> /data/adb/load-module/backup/remove-$(basename $module).sh\n        fi\n        #复制文件\n        cp -fp "$module/system/$target" "/system/$target"\n      elif [ -d "$module/system/$target" ]; then\n        #检查目录\n        [ -d "/system/$target" ] && continue\n        #创建目录\n        mkdir -m 755 "/system/$target"\n        #修改文件\n        echo "rm -rf /system/$target" >> /data/adb/load-module/backup/remove-$(basename $module).sh\n      fi\n    done\n    #修改文件\n    echo "$module" >> $list\n  done\n  #重启服务\n  [ "$restart" ] && setprop ctl.start zygote && setprop ctl.start zygote_secondary\n} &\nexit 0' > /data/adb/load-module/load-modules.sh

touch /data/adb/load-module/config/load-list

chmod 755 /data/adb/load-module/load-modules.sh
chmod 755 /data/adb/post-fs-data.d/load-module.sh

echo -e 'on post-fs-data\n    start logd\n    exec u:r:magisk:s0 0 0 -- /sbin/magisk --post-fs-data\n\non property:vold.decrypt=trigger_restart_framework\n    exec u:r:magisk:s0 0 0 -- /sbin/magisk --service\n\non nonencrypted\n    exec u:r:magisk:s0 0 0 -- /sbin/magisk --service\n\non property:sys.boot_completed=1\n    exec u:r:magisk:s0 0 0 -- /sbin/magisk --boot-complete\n\non property:init.svc.zygote=stopped\n    exec u:r:magisk:s0 0 0 -- /sbin/magisk --zygote-restart' > /system/etc/init/magisk.rc


[ "$API" != "28" ] && sed -i "s/nonencrypted/boot/" /system/etc/init/magisk.rc

chmod 644 /system/etc/init/magisk.rc

ui_print "- Launch Magisk Daemon"

cd /
export MAGISKTMP=/sbin

/sbin/magisk --post-fs-data
/sbin/magisk --service
/sbin/magisk --boot-complete