#!/system/bin/sh
#######################################################################################
# Magisk On VMOS Pro Installer
#######################################################################################

#################
# Initialization
#################

# Default permissions
umask 022

if [ -z $SOURCEDMODE ]; then
  # Switch to the location of the script file
  cd "$INSTALLER"
  # Load utility functions
  . ./util_functions.sh
  # Get Android version/architecture
  api_level_arch_detect
fi

chmod -R 755 .

#########
# Extract
#########

ui_print "- Extracting Magisk files"

mkdir -p /sbin/.magisk/block/ 2>/dev/null
mkdir /sbin/.magisk/mirror/ 2>/dev/null
mkdir /sbin/.magisk/worker/ 2>/dev/null

touch /sbin/.magisk/config 2>/dev/null

cp -f ./magisk32 /sbin/magisk32 2>/dev/null
cp -f ./magisk64 /sbin/magisk64 2>/dev/null
cp -f ./magiskpolicy /sbin/magiskpolicy
cp -f ./magiskinit /sbin/magiskinit

set_perm /sbin/magisk* 0 0 0755
set_perm /sbin/magiskinit 0 0 0750

[ ! -L "/sbin/.magisk/modules" ] && ln -s /data/adb/modules /sbin/.magisk/modules

if [ "$IS64BIT" = true ]; then
  ln -sf /sbin/magisk64 /sbin/magisk
else
  ln -sf /sbin/magisk32 /sbin/magisk
fi
ln -sf /sbin/magisk /sbin/resetprop
ln -sf /sbin/magiskpolicy /sbin/supolicy

mkdir -p /data/adb/magisk/chromeos/ 2>/dev/null
mkdir /data/adb/post-fs-data.d/ 2>/dev/null
mkdir /data/adb/service.d/ 2>/dev/null

if [ "$IS64BIT" = true ]; then
  cp -f ./busybox-original /data/adb/magisk/busybox
else
  cp -f ./busybox /data/adb/magisk/busybox
fi

for file in $(ls ./magisk*); do cp -f ./$file /data/adb/magisk/$file; done

cp -f ./addon.d.sh /data/adb/magisk/addon.d.sh
cp -f ./util_functions.sh /data/adb/magisk/util_functions.sh
cp -f ./stub.apk /data/adb/magisk/stub.apk
cp -r ./chromeos/* /data/adb/magisk/chromeos/

set_perm_recursive /data/adb/magisk/ 0 0 0755 0755

#########
# Create
#########

rm -f /sbin/su

cat << 'EOF' > /sbin/su
#!/system/bin/sh
if [ "$(id -u)" = "0" ]; then
  /sbin/magisk "su" "2000" "-c" "exec "/sbin/magisk" "su" "$@"" || /sbin/magisk "su" "10000"
elif [ "$(id -u)" = "10000" ]; then
  echo "Permission denied"
else
  /sbin/magisk "su" "$@"
fi
EOF

set_perm /sbin/su 0 0 0755

mkdir -p /data/adb/load-module/backup/ 2>/dev/null
mkdir /data/adb/load-module/config/ 2>/dev/null

[ ! -d "/cache/" ] && mkdir -m 770 /cache/

cat << 'EOF' > /data/adb/post-fs-data.d/load-module.sh
#!/system/bin/sh
#加载模块
/system/bin/sh /data/adb/load-module/load-modules.sh --load-modules
exit 0
EOF

cat << 'EOF' > /data/adb/load-module/load-modules.sh
#!/system/bin/sh
#默认权限
umask 022
#检测输入
if [ -z "$1" ]; then
  exit 1
elif [ "$1" = "--load-modules" ]; then
  #加载列表
  list=/data/adb/load-module/config/load-list
  #清理列表
  sed -i "/^$/d" $list
  #删除文件
  for module in $(cat $list); do
    #检测状态
    [ ! -f "$module/update" -a ! -f "$module/skip_mount" -a ! -f "$module/disable" -a ! -f "$module/remove" ] && continue
    #重启服务
    [ -z "$restart" ] && setprop ctl.stop zygote; setprop ctl.stop zygote_secondary; restart=true
    #执行文件
    sh /data/adb/load-module/backup/remove-$(basename $module).sh > /dev/null 2>&1
    #删除文件
    rm -f /data/adb/load-module/backup/remove-$(basename $module).sh
    #检测状态
    [ -f "$module/remove" ] && rm -f /data/adb/load-module/config/load-$(basename $module)-list
    #修改文件
    sed -i "s|$module||" $list
  done
  #并行运行
  {
    #等待加载
    while [ -z "$(cat /cache/magisk.log | grep "* Loading modules")" ]; do sleep 0.0; done
    #加载文件
    for module in /data/adb/modules/*; do
      #检测状态
      [ -f "$module/disable" ] && continue
      #修改属性
      for prop in $(cat "$module/system.prop" 2>/dev/null); do
        echo "$prop" | sed "s/=/ /" | xargs setprop
      done
      #检测状态
      [ "$(cat $list | grep "$module")" ] || [ -f "$module/skip_mount" ] || [ ! -d "$module/system/" ] && continue
      #重启服务
      [ -z "$restart" ] && setprop ctl.stop zygote; setprop ctl.stop zygote_secondary; restart=true
      #切换目录
      cd "$module/system"
      #加载文件
      for file in $(find); do
        #目标文件
        target=$(echo "$file" | sed "s/..//")
        #备份配置
        config=$(cat /data/adb/load-module/config/load-$(basename $module)-list | sed -n "s|^/system/$target=||p" | head -n 1)
        #检查类型
        if [ -f "$module/system/$target" ]; then
          #备份文件
          if [ "$config" = "backup" ]; then
            #检查文件
            [ -f "/data/adb/load-module/backup/system/$target" ] && continue
            #创建目录
            mkdir -p "/data/adb/load-module/backup/system/$(dirname "$target")" 2>/dev/null
            #复制文件
            cp -p "/system/$target" "/data/adb/load-module/backup/system/$target" || continue
            #修改文件
            echo -e "cp -fp /data/adb/load-module/backup/system/$target /system/$target\nrm /data/adb/load-module/backup/system/$target" >> /data/adb/load-module/backup/remove-$(basename $module).sh
          elif [ "$config" = "remove" ]; then
            #修改文件
            echo "rm -f /system/$target" >> /data/adb/load-module/backup/remove-$(basename $module).sh
          else
            continue
          fi
          #复制文件
          cp -fp "$module/system/$target" "/system/$target"
        elif [ -d "$module/system/$target" ]; then
          #检查目录
          [ "$config" != "remove" ] && continue
          #创建目录
          mkdir "/system/$target" 2>/dev/null
          #修改文件
          echo "rm -rf /system/$target" >> /data/adb/load-module/backup/remove-$(basename $module).sh
        fi
      done
      #修改文件
      echo "$module" >> $list
    done
    #重启服务
    [ "$restart" ] && setprop ctl.start zygote; setprop ctl.start zygote_secondary
  } &
elif [ "$1" = "--detect" ]; then
  #检测输入
  [ -z "$2" ] && exit 1
  #删除文件
  rm -f /data/adb/load-module/config/load-$(basename $2)-list
  #切换目录
  cd "$2/system"
  #加载文件
  for file in $(find); do
    #目标文件
    target=$(echo "$file" | sed "s/..//")
    #检查类型
    if [ -f "$2/system/$target" ]; then
      #检查文件
      if [ -f "/system/$target" ]; then
        #修改文件
        echo "/system/$target=backup" >> /data/adb/load-module/config/load-$(basename $2)-list
      else
        #修改文件
        echo "/system/$target=remove" >> /data/adb/load-module/config/load-$(basename $2)-list
      fi
    elif [ -d "$2/system/$target" ]; then
      #检查目录
      [ -d "/system/$target" ] && continue
      #修改文件
      echo "/system/$target=remove" >> /data/adb/load-module/config/load-$(basename $2)-list
    fi
  done
fi
exit 0
EOF

touch /data/adb/load-module/config/load-list 2>/dev/null

set_perm /data/adb/load-module/load-modules.sh 0 0 0755
set_perm /data/adb/post-fs-data.d/load-module.sh 0 0 0755

[ "$API" = "28" ] && TRIGGER=nonencrypted || TRIGGER=boot

cat << EOF > /system/etc/init/magisk.rc
on post-fs-data
    start logd
    exec u:r:magisk:s0 0 0 -- /sbin/magisk --post-fs-data

on property:vold.decrypt=trigger_restart_framework
    exec u:r:magisk:s0 0 0 -- /sbin/magisk --service

on $TRIGGER
    exec u:r:magisk:s0 0 0 -- /sbin/magisk --service

on property:sys.boot_completed=1
    exec u:r:magisk:s0 0 0 -- /sbin/magisk --boot-complete

on property:init.svc.zygote=stopped
    exec u:r:magisk:s0 0 0 -- /sbin/magisk --zygote-restart
EOF

#########
# Launch
#########

ui_print "- Launch Magisk Daemon"

cd /
export MAGISKTMP=/sbin

/sbin/magisk --post-fs-data
/sbin/magisk --service
/sbin/magisk --boot-complete