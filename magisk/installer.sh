#!/system/bin/sh
#######################################################################################
# Magisk On VMOS Pro Installer
#######################################################################################

############
# Functions
############

# Pure bash dirname implementation
getdir() {
  case "$1" in
    */*)
      dir=${1%/*}
      if [ -z $dir ]; then
        echo "/"
      else
        echo $dir
      fi
    ;;
    *) echo "." ;;
  esac
}

#################
# Initialization
#################

# Check Magisk State
[ -f "$ROOTFS/sbin/magisk" ] && exit

if [ -z $SOURCEDMODE ]; then
  # Switch to the location of the script file
  cd "$(getdir "${BASH_SOURCE:-$0}")"
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

mkdir -m 755 $ROOTFS/sbin/.magisk/
mkdir -m 777 $ROOTFS/sbin/.magisk/block/
mkdir -m 777 $ROOTFS/sbin/.magisk/mirror/
mkdir -m 777 $ROOTFS/sbin/.magisk/worker/

mkdir -m 755 $ROOTFS/data/adb/magisk/
mkdir -m 755 $ROOTFS/data/adb/magisk/chromeos/
mkdir -m 755 $ROOTFS/data/adb/post-fs-data.d/
mkdir -m 755 $ROOTFS/data/adb/service.d/

mkdir -m 755 $ROOTFS/data/adb/load-module/
mkdir -m 755 $ROOTFS/data/adb/load-module/backup/
mkdir -m 755 $ROOTFS/data/adb/load-module/config/

touch $ROOTFS/sbin/.magisk/config

cp ./magisk32 $ROOTFS/sbin/magisk32
cp ./magisk64 $ROOTFS/sbin/magisk64
cp ./magiskpolicy $ROOTFS/sbin/magiskpolicy
cp ./magiskinit $ROOTFS/sbin/magiskinit

chmod 755 $ROOTFS/sbin/magisk*
chmod 750 $ROOTFS/sbin/magiskinit

ln -s $ROOTFS/data/adb/modules $ROOTFS/sbin/.magisk/modules

ln -s $ROOTFS/sbin/magisk64 $ROOTFS/sbin/magisk
ln -s $ROOTFS/sbin/magisk $ROOTFS/sbin/resetprop
ln -s $ROOTFS/sbin/magiskpolicy $ROOTFS/sbin/supolicy
ln -s $ROOTFS/sbin/magisk $ROOTFS/sbin/su

cp ./busybox-original $ROOTFS/data/adb/magisk/busybox
cp ./magisk32 $ROOTFS/data/adb/magisk/magisk32
cp ./magisk64 $ROOTFS/data/adb/magisk/magisk64
cp ./magiskpolicy $ROOTFS/data/adb/magisk/magiskpolicy
cp ./magiskinit $ROOTFS/data/adb/magisk/magiskinit
cp ./magiskboot $ROOTFS/data/adb/magisk/magiskboot
cp -r ./*.sh $ROOTFS/data/adb/magisk
cp ./stub.apk $ROOTFS/data/adb/magisk/stub.apk
cp -r ./chromeos/* $ROOTFS/data/adb/magisk/chromeos/

chmod 755 -R $ROOTFS/data/adb/magisk/

echo -e '#!/system/bin/sh\n#基础变量\nROOTFS=$(cat /init_shell.sh | xargs -n 1 | grep "init" | sed -e "s|/init||" -e "s|user/0|data|")\n#加载列表\nlist=$ROOTFS/data/adb/load-module/config/load-list\n#清理列表\nsed -i "/^$/d" $list\n#删除文件\nfor module in $(cat $list); do\n  #检测状态\n  [ ! -f "$module/update" -a ! -f "$module/skip_mount" -a ! -f "$module/disable" -a ! -f "$module/remove" ] && continue\n  #重启服务\n  [ -z "$restart" ] && setprop ctl.stop zygote && setprop ctl.stop zygote_secondary && restart=true\n  #执行文件\n  sh $ROOTFS/data/adb/load-module/backup/remove-$(basename $module).sh > /dev/null 2>&1\n  #删除文件\n  rm -f $ROOTFS/data/adb/load-module/backup/remove-$(basename $module).sh\n  #修改文件\n  sed -i "s|$module||" $list\ndone\n#并行运行\n{\n  #等待加载\n  while [ -z "$(cat $ROORFS/cache/magisk.log | grep "* Loading modules")" ]; do sleep 0.0; done\n  #加载文件\n  for module in $ROOTFS/data/adb/modules/*; do\n    #检测状态\n    [ -f "$module/disable" ] && continue\n    #修改属性\n    for prop in $(cat "$module/system.prop"); do\n      echo "$prop" | sed "s/=/ /" | xargs setprop\n    done\n    #检测状态\n    [ "$(cat $list | grep "$module")" ] || [ -f "$module/skip_mount" ] || [ ! -d "$module/system/" ] && continue\n    #重启服务\n    [ -z "$restart" ] && setprop ctl.stop zygote && setprop ctl.stop zygote_secondary && restart=true\n    #切换目录\n    cd "$module/system"\n    #加载文件\n    for file in $(find); do\n      #目标文件\n      target=$(echo "$file" | sed "s/..//")\n      #检查类型\n      if [ -f "$module/system/$target" ]; then\n        #备份文件\n        if [ "$(cat "/system/$target")" ]; then\n          #检查文件\n          [ -f "$ROOTFS/data/adb/load-module/backup/system/$target" ] && continue\n          #创建目录\n          mkdir -p "$ROOTFS/data/adb/load-module/backup/system/$(dirname "$target")" > /dev/null 2>&1\n          #复制文件\n          cp -p "$ROOTFS/system/$target" "$ROOTFS/data/adb/load-module/backup/system/$target" || continue\n          #修改文件\n          echo -e "cp -p $ROOTFS/data/adb/load-module/backup/system/$target $ROOTFS/system/$target\nrm $ROOTFS/data/adb/load-module/backup/system/$target" >> $ROOTFS/data/adb/load-module/backup/remove-$(basename $module).sh\n        else\n          #修改文件\n          echo "rm -f $ROOTFS/system/$target" >> $ROOTFS/data/adb/load-module/backup/remove-$(basename $module).sh\n        fi\n        #复制文件\n        cp -fp "$module/system/$target" "/system/$target"\n      elif [ -d "$module/system/$target" ]; then\n        #检查目录\n        [ -d "/system/$target" ] && continue\n        #创建目录\n        mkdir -m 755 "$ROOTFS/system/$target"\n        #修改文件\n        echo "rm -rf $ROOTFS/system/$target" >> $ROOTFS/data/adb/load-module/backup/remove-$(basename $module).sh\n      fi\n    done\n    #修改文件\n    echo "$module" >> $list\n  done\n  #重启服务\n  [ "$restart" ] && setprop ctl.start zygote && setprop ctl.start zygote_secondary\n} &\nexit 0' > $ROOTFS/data/adb/post-fs-data.d/load-modules.sh

touch $ROOTFS/data/adb/load-module/config/load-list

chmod 755 $ROOTFS/data/adb/post-fs-data.d/load-modules.sh

echo -e 'on post-fs-data\n    start logd\n    exec u:r:magisk:s0 0 0 -- /sbin/magisk --post-fs-data\n\non property:vold.decrypt=trigger_restart_framework\n    exec u:r:magisk:s0 0 0 -- /sbin/magisk --service\n\non nonencrypted\n    exec u:r:magisk:s0 0 0 -- /sbin/magisk --service\n\non property:sys.boot_completed=1\n    exec u:r:magisk:s0 0 0 -- /sbin/magisk --boot-complete\n\non property:init.svc.zygote=stopped\n    exec u:r:magisk:s0 0 0 -- /sbin/magisk --zygote-restart' > $ROOTFS/system/etc/init/magisk.rc


[ "$API" != "28" ] && sed -i "s/nonencrypted/boot/" $ROOTFS/system/etc/init/magisk.rc

chmod 644 $ROOTFS/system/etc/init/magisk.rc

ui_print "- Launch Magisk Daemon"

cd /
export MAGISKTMP=/sbin

/sbin/magisk --post-fs-data
/sbin/magisk --service
/sbin/magisk --boot-complete