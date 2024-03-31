##################################
# Magisk app 内部脚本
##################################

run_delay() {
  (sleep $1; $2)&
}

env_check() {
  for file in busybox magiskboot magiskinit util_functions.sh boot_patch.sh; do
    [ -f $MAGISKBIN/$file ] || return 1
  done
  grep -xqF "MAGISK_VER='$1'" "$MAGISKBIN/util_functions.sh" || return 1
  grep -xqF "MAGISK_VER_CODE=$2" "$MAGISKBIN/util_functions.sh" || return 1
  return 0
}

cp_readlink() {
  if [ -z $2 ]; then
    cd $1
  else
    cp -af $1/. $2
    cd $2
  fi
  for file in *; do
    if [ -L $file ]; then
      local full=$(readlink -f $file)
      rm $file
      cp -af $full $file
    fi
  done
  chmod -R 755 .
  cd /
}

fix_env() {
  # 清理并创建目录
  rm -rf $MAGISKBIN/*
  mkdir -p $MAGISKBIN 2>/dev/null
  chmod 700 $NVBASE
  cp_readlink $1 $MAGISKBIN
  rm -rf $1
  chown -R 0:0 $MAGISKBIN
}

direct_install() {
  echo "- 刷入新的 boot 映像"
  flash_image $1/new-boot.img $2
  case $? in
    1)
      echo "! 分区大小不足"
      return 1
      ;;
    2)
      echo "! $2 分区为只读"
      return 2
      ;;
  esac

  rm -f $1/new-boot.img
  fix_env $1
  run_migrations
  copy_sepolicy_rules

  return 0
}

check_install(){
  # 获取 Android 版本
  api_level_arch_detect

  # 检测 Android 版本
  [ "$API" != 28 ] && [ "$API" != 25 ] && exit
}

run_installer(){
  # 默认权限
  umask 022

  # 检测 Android 版本/架构
  api_level_arch_detect

  MAGISKTMP="$ROOTFS"/sbin

  ui_print "- 解压 Magisk 文件"
  for dir in block mirror; do
    mkdir -p "$MAGISKTMP"/.magisk/"$dir"/ 2>/dev/null
  done

  for file in magisk32 magisk64 magiskinit; do
    cp -f ./"$file" "$MAGISKTMP"/"$file" 2>/dev/null

    set_perm "$MAGISKTMP"/"$file" 0 0 0755 2>/dev/null
  done

  [ ! -L "$MAGISKTMP"/.magisk/modules ] && ln -s "$NVBASE"/modules "$MAGISKTMP"/.magisk/modules

  [ "$IS64BIT" = true ] && ln -sf "$MAGISKTMP"/magisk64 "$MAGISKTMP"/magisk || ln -sf "$MAGISKTMP"/magisk32 "$MAGISKTMP"/magisk
  ln -sf "$MAGISKTMP"/magiskinit "$MAGISKTMP"/magiskpolicy
  ln -sf "$MAGISKTMP"/magisk "$MAGISKTMP"/resetprop
  ln -sf "$MAGISKTMP"/magiskpolicy "$MAGISKTMP"/supolicy
  ln -sf "$MAGISKTMP"/magisk "$MAGISKTMP"/su

  if [ ! -f "$MAGISKTMP"/kauditd ]; then
    rm -f "$MAGISKTMP"/su

    cat << 'EOF' > "$MAGISKTMP"/su
#!/system/bin/sh
case $(id -u) in
  0 )
    /sbin/magisk "su" "2000" "-c" "exec "/sbin/magisk" "su" "$@"" || /sbin/magisk "su" "10000"
    ;;
  10000 )
    echo "Permission denied"
    ;;
  * )
    /sbin/magisk "su" "$@"
    ;;
esac
EOF

    set_perm "$MAGISKTMP"/su 0 0 0755
  fi

  for dir in magisk/chromeos load-module/backup post-fs-data.d service.d; do
    mkdir -p "$NVBASE"/"$dir"/ 2>/dev/null
  done

  mkdir -m 750 "$ROOTFS"/cache/ 2>/dev/null

  for file in $(ls ./magisk* ./*.sh) stub.apk; do
    cp -f ./"$file" "$MAGISKBIN"/"$file"
  done

  [ "$IS64BIT" = true ] && cp -f ./busybox.bin "$MAGISKBIN"/busybox || cp -f ./busybox "$MAGISKBIN"/busybox
  cp -r ./chromeos/* "$MAGISKBIN"/chromeos/

  set_perm_recursive "$MAGISKBIN"/ 0 0 0755 0755

  cat << 'EOF' > "$NVBASE"/post-fs-data.d/load-modules.sh
#!/system/bin/sh
#默认权限
umask 022
#基础变量
rootfs="$(dir="$(cat /init_shell.sh | xargs -n 1 | grep "init" | sed "s|/init||")"; [ -d "$dir" ] && echo "$dir" || echo "$(echo "$dir" | sed "s|user/0|data|")")"
#数据目录
bin="$rootfs"/data/adb/load-module
#清理环境
rm -rf "$rootfs"/sbin/.magisk/mirror/*
#恢复更改
for module in $(ls "$rootfs"/data/adb/modules/); do
  #检测状态
  [ ! -f "$bin"/backup/remove-"$module".sh ] && continue
  #模块路径
  path="$rootfs"/data/adb/modules/"$module"
  #检测状态
  [ ! -f "$path"/update -a ! -f "$path"/skip_mount -a ! -f "$path"/disable -a ! -f "$path"/remove ] && continue
  #重启服务
  if [ -z "$restart" ]; then
    #停止服务
    resetprop ctl.stop zygote
    resetprop ctl.stop zygote_secondary
    #启用重启
    restart=true
  fi
  #执行文件
  sh "$bin"/backup/remove-"$module".sh > /dev/null 2>&1
  #删除文件
  rm -f "$bin"/backup/remove-"$module".sh
  #删除变量
  unset path
done
#并行运行
{
  #等待加载
  while [ -z "$(cat "$rootfs"/cache/magisk.log | grep "* Loading modules")" ]; do sleep 0.0; done
  #加载模块
  for module in $(ls "$rootfs"/data/adb/modules/); do
    #检测状态
    [ -f "$bin"/backup/remove-"$module".sh ] && continue
    #模块路径
    path="$rootfs"/data/adb/modules/"$module"
    #检测状态
    [ -f "$path"/disable -o -f "$path"/skip_mount -o ! -d "$path"/system/ ] && continue
    #重启服务
    if [ -z "$restart" ]; then
      #停止服务
      resetprop ctl.stop zygote
      resetprop ctl.stop zygote_secondary
      #启用重启
      restart=true
    fi
    #切换目录
    cd "$path"/system
    #加载文件
    for file in $(find); do
      #目标文件
      target="$(echo "$file" | sed "s/..//")"
      #检查类型
      if [ -f "$path"/system/"$target" ]; then
        #检测文件
        [ "$(basename "$target")" = .replace ] && continue
        #备份文件
        if [ -f "$rootfs"/system/"$target" ]; then
          #检查文件
          [ -f "$bin"/backup/system/"$target" ] && continue
          #创建目录
          mkdir -p "$bin"/backup/system/"$(dirname "$target")"/ 2>/dev/null
          #复制文件
          mv "$rootfs"/system/"$target" "$bin"/backup/system/"$target" || continue
          #修改文件
          echo "mv -f $bin/backup/system/$target $rootfs/system/$target" >> "$bin"/backup/remove-"$module".sh
        else
          #修改文件
          [ ! -f "$path"/system/"$(dirname "$target")"/.replace ] && echo "rm -f $rootfs/system/$target" >> "$bin"/backup/remove-"$module".sh
        fi
        #设置权限
        chmod 777 "$path"/system/"$target"
        #复制文件
        cp -af "$path"/system/"$target" "$rootfs"/system/"$target"
        #设置权限
        chmod 777 "$rootfs"/system/"$target"
      elif [ -d "$path"/system/"$target" ]; then
        #检查目录
        if [ -d "$rootfs"/system/"$target"/ ]; then
          #检测文件
          [ ! -f "$path"/system/"$target"/.replace ] && continue
          #创建目录
          mkdir -p "$bin"/backup/system/"$target"/ 2>/dev/null
          #复制文件
          cp -a "$rootfs"/system/"$target"/* "$bin"/backup/system/"$target"
          #清空目录
          rm -rf "$rootfs"/system/"$target"/*
          #修改文件
          echo -e "rm -rf $rootfs/system/$target/*\ncp -a $bin/backup/system/$target/* $rootfs/system/$target/\nrm -rf $bin/backup/system/$target/*" >> "$bin"/backup/remove-"$module".sh
        else
          #创建目录
          mkdir "$rootfs"/system/"$target"/
          #修改文件
          echo "rm -rf $rootfs/system/$target/" >> "$bin"/backup/remove-"$module".sh
        fi
      fi
      #删除变量
      unset target
    done
    #删除变量
    unset path
  done
  #重启服务
  if [ "$restart" ]; then
    #启动服务
    resetprop ctl.start zygote
    resetprop ctl.start zygote_secondary
  fi
} &
EOF

  set_perm "$NVBASE"/post-fs-data.d/load-modules.sh 0 0 0755

  cat << 'EOF' > "$ROOTFS"/system/etc/init/magisk.rc
on post-fs-data
    start logd
    start magisk_daemon

service magisk_daemon /sbin/magisk --post-fs-data
    user root
    seclabel u:r:magisk:s0
    oneshot

service magisk_service /sbin/magisk --service
    class late_start
    user root
    seclabel u:r:magisk:s0
    oneshot

on property:sys.boot_completed=1
    start magisk_boot

service magisk_boot /sbin/magisk --boot-complete
    user root
    seclabel u:r:magisk:s0
    oneshot
EOF

  set_perm "$ROOTFS"/system/etc/init/magisk.rc 0 0 0644

  ui_print "- 启动 Magisk 守护进程"
  rm -rf "$(pwd)"/
  cd /

  "$MAGISKTMP"/magisk --post-fs-data
  "$MAGISKTMP"/magisk --service
  "$MAGISKTMP"/magisk --boot-complete
}

run_uninstaller() {
  # 默认权限
  umask 022

  if echo $MAGISK_VER | grep -q '\.'; then
    PRETTY_VER=$MAGISK_VER
  else
    PRETTY_VER="$MAGISK_VER($MAGISK_VER_CODE)"
  fi
  print_title "Magisk $PRETTY_VER 卸载程序"

  ui_print "- 删除模块文件"
  for module in $(ls "$NVBASE"/modules/); do
    path="$NVBASE"/modules_update/"$module"

    [ ! -d "$path"/ ] && path="$NVBASE"/modules/"$module"

    sh "$path"/uninstall.sh > /dev/null 2>&1
  done

  ui_print "- 删除 Magisk 文件"
  rm -rf \
  "$ROOTFS"/cache/*magisk* "$ROOTFS"/cache/unblock "$ROOTFS"/data/*magisk* "$ROOTFS"/data/cache/*magisk* "$ROOTFS"/data/property/*magisk* \
  "$ROOTFS"/data/Magisk.apk "$ROOTFS"/data/busybox "$ROOTFS"/data/custom_ramdisk_patch.sh "$NVBASE"/*magisk* \
  "$NVBASE"/load-module "$NVBASE"/modules* "$NVBASE"/post-fs-data.d "$NVBASE"/service.d \
  "$ROOTFS"/data/unencrypted/magisk "$ROOTFS"/metadata/magisk "$ROOTFS"/persist/magisk "$ROOTFS"/mnt/vendor/persist/magisk

  restore_system

  ui_print "- 完成"
}

restore_system() {
  # 删除模块已加载的文件
  for module in $(ls "$NVBASE"/modules/); do
    sh "$NVBASE"/load-module/backup/remove-"$module".sh > /dev/null 2>&1
  done

  # 删除 Magisk 文件
  rm -rf \
  "$ROOTFS"/sbin/*magisk* "$ROOTFS"/sbin/su* "$ROOTFS"/sbin/resetprop "$ROOTFS"/sbin/kauditd "$ROOTFS"/sbin/.magisk \
  "$NVBASE"/load-module/backup/* "$ROOTFS"/system/etc/init/magisk.rc "$ROOTFS"/system/etc/init/kauditd.rc

  return 0
}

post_ota() {
  cd $NVBASE
  cp -f $1 bootctl
  rm -f $1
  chmod 755 bootctl
  ./bootctl hal-info || return
  [ $(./bootctl get-current-slot) -eq 0 ] && SLOT_NUM=1 || SLOT_NUM=0
  ./bootctl set-active-boot-slot $SLOT_NUM
  cat << EOF > post-fs-data.d/post_ota.sh
/data/adb/bootctl mark-boot-successful
rm -f /data/adb/bootctl
rm -f /data/adb/post-fs-data.d/post_ota.sh
EOF
  chmod 755 post-fs-data.d/post_ota.sh
  cd /
}

add_hosts_module() {
  # 不要更改已安装的 hosts 模块
  [ -d $NVBASE/modules/hosts ] && return
  cd $NVBASE/modules
  mkdir -p hosts/system/etc
  cat << EOF > hosts/module.prop
id=hosts
name=Systemless Hosts
version=1.0
versionCode=1
author=Magisk
description=Magisk app built-in systemless hosts module
EOF
  magisk --clone /system/etc/hosts hosts/system/etc/hosts
  touch hosts/update
  cd /
}

adb_pm_install() {
  local tmp=/data/local/tmp/temp.apk
  cp -f "$1" $tmp
  chmod 644 $tmp
  su 2000 -c pm install $tmp || pm install $tmp || su 1000 -c pm install $tmp
  local res=$?
  rm -f $tmp
  # 注意: 改变这个会被 kill
  [ $res != 0 ] && appops set "$2" REQUEST_INSTALL_PACKAGES allow
  return $res
}

check_boot_ramdisk() {
  # 创建 boolean ISAB
  [ -z $SLOT ] && ISAB=false || ISAB=true

  # 将 system mode 设置为 true
  SYSTEMMODE=true
  return 1
}

check_encryption() {
  if $ISENCRYPTED; then
    if [ $SDK_INT -lt 24 ]; then
      CRYPTOTYPE="block"
    else
      CRYPTOTYPE=$(getprop ro.crypto.type)
      if [ -z $CRYPTOTYPE ]; then
        # 如果不通过设备映射器安装则是 FBE
        if grep ' /data ' /proc/mounts | grep -qv 'dm-'; then
          CRYPTOTYPE="file"
        else
          # 要么是 FDE，或者是 metadata 加密 (也是FBE)
          grep -q ' /metadata ' /proc/mounts && CRYPTOTYPE="file" || CRYPTOTYPE="block"
        fi
      fi
    fi
  else
    CRYPTOTYPE="N/A"
  fi
}

##########################
# 无需 root 函数
##########################

mount_partitions() {
  [ "$(getprop ro.build.ab_update)" = "true" ] && SLOT=$(getprop ro.boot.slot_suffix)
  # 检查非 rootfs 根目录是否存在
  grep ' / ' /proc/mounts | grep -qv 'rootfs' && SYSTEM_ROOT=true || SYSTEM_ROOT=false
}

get_flags() {
  KEEPVERITY=$SYSTEM_ROOT
  [ "$(getprop ro.crypto.state)" = "encrypted" ] && ISENCRYPTED=true || ISENCRYPTED=false
  KEEPFORCEENCRYPT=$ISENCRYPTED
  VBMETAEXIST=true
  PATCHVBMETAFLAG=false
  # 不要在此处预设 SYSTEMMODE
}

run_migrations() { return; }

grep_prop() { return; }

#############
# 初始化
#############

app_init() {
  mount_partitions
  get_flags
  run_migrations
  SHA1=$(grep_prop SHA1 $MAGISKTMP/config)
  check_boot_ramdisk && RAMDISKEXIST=true || RAMDISKEXIST=false
  check_encryption
  # 确保 SYSTEMMODE 具有值
  [ -z $SYSTEMMODE ] && SYSTEMMODE=false
}

export BOOTMODE=true
