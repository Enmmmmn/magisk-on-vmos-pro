############################################
# Magisk 通用实用函数
############################################

# Magisk On VMOS Pro
# 由 Magisk On System 提供支持

MAGISK_VER='24.1'
MAGISK_VER_CODE=24100

###################
# 辅助函数
###################

ui_print() {
  if $BOOTMODE; then
    echo "$1"
  else
    echo -e "ui_print $1\nui_print" >> /proc/self/fd/$OUTFD
  fi
}

toupper() {
  echo "$@" | tr '[:lower:]' '[:upper:]'
}

grep_cmdline() {
  local REGEX="s/^$1=//p"
  { echo $(cat /proc/cmdline)$(sed -e 's/[^"]//g' -e 's/""//g' /proc/cmdline) | xargs -n 1; \
    sed -e 's/ = /=/g' -e 's/, /,/g' -e 's/"//g' /proc/bootconfig; \
  } 2>/dev/null | sed -n "$REGEX"
}

grep_prop() {
  local REGEX="s/^$1=//p"
  shift
  local FILES=$@
  [ -z "$FILES" ] && FILES='/system/build.prop'
  cat $FILES 2>/dev/null | dos2unix | sed -n "$REGEX" | head -n 1
}

grep_get_prop() {
  local result=$(grep_prop $@)
  if [ -z "$result" ]; then
    # 回退到 getprop
    getprop "$1"
  else
    echo $result
  fi
}

getvar() {
  local VARNAME=$1
  local VALUE
  local PROPPATH='/data/.magisk /cache/.magisk'
  [ ! -z $MAGISKTMP ] && PROPPATH="$MAGISKTMP/config $PROPPATH"
  VALUE=$(grep_prop $VARNAME $PROPPATH)
  [ ! -z $VALUE ] && eval $VARNAME=\$VALUE
}

is_mounted() {
  grep -q " $(readlink -f $1) " /proc/mounts 2>/dev/null
  return $?
}

abort() {
  ui_print "$1"
  $BOOTMODE || recovery_cleanup
  [ ! -z $MODPATH ] && rm -rf $MODPATH
  rm -rf $TMPDIR
  exit 1
}

resolve_vars() {
  MAGISKBIN=$NVBASE/magisk
  POSTFSDATAD=$NVBASE/post-fs-data.d
  SERVICED=$NVBASE/service.d
}

print_title() {
  local len line1len line2len bar
  line1len=$(echo -n $1 | wc -c)
  line2len=$(echo -n $2 | wc -c)
  len=$line2len
  [ $line1len -gt $line2len ] && len=$line1len
  len=$((len + 2))
  bar=$(printf "%${len}s" | tr ' ' '*')
  ui_print "$bar"
  ui_print " $1 "
  [ "$2" ] && ui_print " $2 "
  ui_print "$bar"
}

######################
# 环境相关
######################

setup_flashable() {
  ensure_bb
  $BOOTMODE && return
  if [ -z $OUTFD ] || readlink /proc/$$/fd/$OUTFD | grep -q /tmp; then
    # 手动找出 OUTFD
    for FD in `ls /proc/$$/fd`; do
      if readlink /proc/$$/fd/$FD | grep -q pipe; then
        if ps | grep -v grep | grep -qE " 3 $FD |status_fd=$FD"; then
          OUTFD=$FD
          break
        fi
      fi
    done
  fi
  recovery_actions
}

ensure_bb() {
  if set -o | grep -q standalone; then
    # 现在已经在 busybox ash 内
    set -o standalone
    return
  fi

  # 寻找 busybox 文件
  local bb
  if [ -f $TMPDIR/busybox ]; then
    bb=$TMPDIR/busybox
  elif [ -f $MAGISKBIN/busybox ]; then
    bb=$MAGISKBIN/busybox
  else
    abort "! 无法找到 BusyBox 文件"
  fi
  chmod 755 $bb

  # Busybox 可以是一个脚本, 确保 /system/bin/sh 存在
  if [ ! -f /system/bin/sh ]; then
    umount -l /system 2>/dev/null
    mkdir -p /system/bin
    ln -s $(command -v sh) /system/bin/sh
  fi

  export ASH_STANDALONE=1

  # 找到当前的 arguments
  # 在 busybox 环境下运行, 保证结果一致
  # /proc/<pid>/cmdline 应为 <interpreter> <script> <arguments...>
  local cmds="$($bb sh -c "
  for arg in \$(tr '\0' '\n' < /proc/$$/cmdline); do
    if [ -z \"\$cmds\" ]; then
      # 跳过第一个参数, 因为我们要更改解释器
      cmds=\"sh\"
    else
      cmds=\"\$cmds '\$arg'\"
    fi
  done
  echo \$cmds")"

  # 重新执行我们的脚本
  echo $cmds | $bb xargs $bb
  exit
}

recovery_actions() {
  # 确保 random 不会被阻止
  mount -o bind /dev/urandom /dev/random
  # 取消已设置的库路径
  OLD_LD_LIB=$LD_LIBRARY_PATH
  OLD_LD_PRE=$LD_PRELOAD
  OLD_LD_CFG=$LD_CONFIG_FILE
  unset LD_LIBRARY_PATH
  unset LD_PRELOAD
  unset LD_CONFIG_FILE
}

recovery_cleanup() {
  local DIR
  ui_print "- 卸载分区"
  (umount_apex
  if [ ! -d /postinstall/tmp ]; then
    umount -l /system
    umount -l /system_root
  fi
  umount -l /vendor
  umount -l /persist
  umount -l /metadata
  for DIR in /apex /system /system_root; do
    if [ -L "${DIR}_link" ]; then
      rmdir $DIR
      mv -f ${DIR}_link $DIR
    fi
  done
  umount -l /dev/random) 2>/dev/null
  [ -z $OLD_LD_LIB ] || export LD_LIBRARY_PATH=$OLD_LD_LIB
  [ -z $OLD_LD_PRE ] || export LD_PRELOAD=$OLD_LD_PRE
  [ -z $OLD_LD_CFG ] || export LD_CONFIG_FILE=$OLD_LD_CFG
}

#######################
# 安装相关
#######################

# find_block [分区名称...]
find_block() {
  local BLOCK DEV DEVICE DEVNAME PARTNAME UEVENT
  for BLOCK in "$@"; do
    DEVICE=`find /dev/block \( -type b -o -type c -o -type l \) -iname $BLOCK | head -n 1` 2>/dev/null
    if [ ! -z $DEVICE ]; then
      readlink -f $DEVICE
      return 0
    fi
  done
  # 通过解析 sysfs uevent 进行回退
  for UEVENT in /sys/dev/block/*/uevent; do
    DEVNAME=`grep_prop DEVNAME $UEVENT`
    PARTNAME=`grep_prop PARTNAME $UEVENT`
    for BLOCK in "$@"; do
      if [ "$(toupper $BLOCK)" = "$(toupper $PARTNAME)" ]; then
        echo /dev/block/$DEVNAME
        return 0
      fi
    done
  done
  # 仅查看 /dev, 以防没有处理 /dev/block devices/links 的 MTD/NAND
  for DEV in "$@"; do
    DEVICE=`find /dev \( -type b -o -type c -o -type l \) -maxdepth 1 -iname $DEV | head -n 1` 2>/dev/null
    if [ ! -z $DEVICE ]; then
      readlink -f $DEVICE
      return 0
    fi
  done
  return 1
}

# setup_mntpoint <挂载点>
setup_mntpoint() {
  local POINT=$1
  [ -L $POINT ] && mv -f $POINT ${POINT}_link
  if [ ! -d $POINT ]; then
    rm -f $POINT
    mkdir -p $POINT
  fi
}

# mount_name <分区名称(s)> <挂载点> <标签>
mount_name() {
  local PART=$1
  local POINT=$2
  local FLAG=$3
  setup_mntpoint $POINT
  is_mounted $POINT && return
  # 首先尝试使用 fstab 挂载
  mount $FLAG $POINT 2>/dev/null
  if ! is_mounted $POINT; then
    local BLOCK=$(find_block $PART)
    mount $FLAG $BLOCK $POINT || return
  fi
  ui_print "- 挂载 $POINT"
}

# mount_ro_ensure <分区名称(s)> <挂载点>
mount_ro_ensure() {
  # 我们仅在 recovery 中处理只读分区
  $BOOTMODE && return
  local PART=$1
  local POINT=$2
  mount_name "$PART" $POINT '-o ro'
  is_mounted $POINT || abort "! 无法挂载 $POINT"
}

mount_partitions() {
  # 检测 A/B 槽位
  SLOT=`grep_cmdline androidboot.slot_suffix`
  if [ -z $SLOT ]; then
    SLOT=`grep_cmdline androidboot.slot`
    [ -z $SLOT ] || SLOT=_${SLOT}
  fi
  [ -z $SLOT ] || ui_print "- 当前 boot 槽位: $SLOT"

  # 挂载只读分区
  if is_mounted /system_root; then
    umount /system 2&>/dev/null
    umount /system_root 2&>/dev/null
  fi
  mount_ro_ensure "system$SLOT app$SLOT" /system
  if [ -f /system/init -o -L /system/init ]; then
    SYSTEM_ROOT=true
    setup_mntpoint /system_root
    if ! mount --move /system /system_root; then
      umount /system
      umount -l /system 2>/dev/null
      mount_ro_ensure "system$SLOT app$SLOT" /system_root
    fi
    mount -o bind /system_root/system /system
  else
    SYSTEM_ROOT=false
    grep ' / ' /proc/mounts | grep -qv 'rootfs' || grep -q ' /system_root ' /proc/mounts && SYSTEM_ROOT=true
  fi
  # /vendor 仅在某些较旧的设备上用于恢复 AVB v1 签名, 因此如果失败并不重要
  [ -L /system/vendor ] && mount_name vendor$SLOT /vendor '-o ro'
  $SYSTEM_ROOT && ui_print "- 设备是 system-as-root"

  # 在 recovery 中允许 Android 10+ 上的 /system/bin 命令 (dalvikvm)
  $BOOTMODE || mount_apex
}

# loop_setup <ext4_映像>, 设置 LOOPDEV
loop_setup() {
  unset LOOPDEV
  local LOOP
  local MINORX=1
  [ -e /dev/block/loop1 ] && MINORX=$(stat -Lc '%T' /dev/block/loop1)
  local NUM=0
  while [ $NUM -lt 64 ]; do
    LOOP=/dev/block/loop$NUM
    [ -e $LOOP ] || mknod $LOOP b 7 $((NUM * MINORX))
    if losetup $LOOP "$1" 2>/dev/null; then
      LOOPDEV=$LOOP
      break
    fi
    NUM=$((NUM + 1))
  done
}

mount_apex() {
  $BOOTMODE || [ ! -d /system/apex ] && return
  local APEX DEST
  setup_mntpoint /apex
  mount -t tmpfs tmpfs /apex -o mode=755
  local PATTERN='s/.*"name":[^"]*"\([^"]*\).*/\1/p'
  for APEX in /system/apex/*; do
    if [ -f $APEX ]; then
      # 处理 CAPEX APKs，首先提取实际的 APEX APK
      unzip -qo $APEX original_apex -d /apex
      [ -f /apex/original_apex ] && APEX=/apex/original_apex # unzip 不执行返回代码
      # APEX APKs, 提取和循环安装
      unzip -qo $APEX apex_payload.img -d /apex
      DEST=$(unzip -qp $APEX apex_manifest.pb | strings | head -n 1)
      [ -z $DEST ] && DEST=$(unzip -qp $APEX apex_manifest.json | sed -n $PATTERN)
      [ -z $DEST ] && continue
      DEST=/apex/$DEST
      mkdir -p $DEST
      loop_setup /apex/apex_payload.img
      if [ ! -z $LOOPDEV ]; then
        ui_print "- 挂载 $DEST"
        mount -t ext4 -o ro,noatime $LOOPDEV $DEST
      fi
      rm -f /apex/original_apex /apex/apex_payload.img
    elif [ -d $APEX ]; then
      # APEX folders, 绑定挂载目录
      if [ -f $APEX/apex_manifest.json ]; then
        DEST=/apex/$(sed -n $PATTERN $APEX/apex_manifest.json)
      elif [ -f $APEX/apex_manifest.pb ]; then
        DEST=/apex/$(strings $APEX/apex_manifest.pb | head -n 1)
      else
        continue
      fi
      mkdir -p $DEST
      ui_print "- 挂载 $DEST"
      mount -o bind $APEX $DEST
    fi
  done
  export ANDROID_RUNTIME_ROOT=/apex/com.android.runtime
  export ANDROID_TZDATA_ROOT=/apex/com.android.tzdata
  export ANDROID_ART_ROOT=/apex/com.android.art
  export ANDROID_I18N_ROOT=/apex/com.android.i18n
  local APEXJARS=$(find /apex -name '*.jar' | sort | tr '\n' ':')
  local FWK=/system/framework
  export BOOTCLASSPATH=${APEXJARS}\
$FWK/framework.jar:$FWK/ext.jar:$FWK/telephony-common.jar:\
$FWK/voip-common.jar:$FWK/ims-common.jar:$FWK/telephony-ext.jar
}

umount_apex() {
  [ -d /apex ] || return
  umount -l /apex
  for loop in /dev/block/loop*; do
    losetup -d $loop 2>/dev/null
  done
  unset ANDROID_RUNTIME_ROOT
  unset ANDROID_TZDATA_ROOT
  unset ANDROID_ART_ROOT
  unset ANDROID_I18N_ROOT
  unset BOOTCLASSPATH
}

# 调用该函数后，将设置以下变量:
# KEEPVERITY, KEEPFORCEENCRYPT, RECOVERYMODE, PATCHVBMETAFLAG,
# ISENCRYPTED, VBMETAEXIST
get_flags() {
  getvar KEEPVERITY
  getvar KEEPFORCEENCRYPT
  getvar RECOVERYMODE
  getvar PATCHVBMETAFLAG
  if [ -z $KEEPVERITY ]; then
    if $SYSTEM_ROOT; then
      KEEPVERITY=true
      ui_print "- System-as-root, 保留 dm/avb-verity"
    else
      KEEPVERITY=false
    fi
  fi
  ISENCRYPTED=false
  grep ' /data ' /proc/mounts | grep -q 'dm-' && ISENCRYPTED=true
  [ "$(getprop ro.crypto.state)" = "encrypted" ] && ISENCRYPTED=true
  if [ -z $KEEPFORCEENCRYPT ]; then
    # 没有 data 访问意味着无法在 recovery 中解密
    if $ISENCRYPTED || ! $DATA; then
      KEEPFORCEENCRYPT=true
      ui_print "- 已加密的 data, 保留强制加密"
    else
      KEEPFORCEENCRYPT=false
    fi
  fi
  VBMETAEXIST=true
  if [ -z $PATCHVBMETAFLAG ]; then
    if $VBMETAEXIST; then
      PATCHVBMETAFLAG=false
    else
      PATCHVBMETAFLAG=true
      ui_print "- 没有找到 vbmeta 分区, 修补 boot 映像内的 vbmeta"
    fi
  fi
  [ -z $RECOVERYMODE ] && RECOVERYMODE=false
}

find_boot_image() {
  BOOTIMAGE=
  if $RECOVERYMODE; then
    BOOTIMAGE=`find_block recovery_ramdisk$SLOT recovery$SLOT sos`
  elif [ ! -z $SLOT ]; then
    BOOTIMAGE=`find_block ramdisk$SLOT recovery_ramdisk$SLOT boot$SLOT`
  else
    BOOTIMAGE=`find_block ramdisk recovery_ramdisk kern-a android_boot kernel bootimg boot lnx boot_a`
  fi
  if [ -z $BOOTIMAGE ]; then
    # 查看 fstab
    BOOTIMAGE=`grep -v '#' /etc/*fstab* | grep -E '/boot(img)?[^a-zA-Z]' | grep -oE '/dev/[a-zA-Z0-9_./-]*' | head -n 1`
  fi
}

flash_image() {
  case "$1" in
    *.gz) CMD1="gzip -d < '$1' 2>/dev/null";;
    *)    CMD1="cat '$1'";;
  esac
  if $BOOTSIGNED; then
    CMD2="$BOOTSIGNER -sign"
    ui_print "- 签名映像"
  else
    CMD2="cat -"
  fi
  if [ -b "$2" ]; then
    local img_sz=$(stat -c '%s' "$1")
    local blk_sz=$(blockdev --getsize64 "$2")
    [ "$img_sz" -gt "$blk_sz" ] && return 1
    blockdev --setrw "$2"
    local blk_ro=$(blockdev --getro "$2")
    [ "$blk_ro" -eq 1 ] && return 2
    eval "$CMD1" | eval "$CMD2" | cat - /dev/zero > "$2" 2>/dev/null
  elif [ -c "$2" ]; then
    flash_eraseall "$2" >&2
    eval "$CMD1" | eval "$CMD2" | nandwrite -p "$2" - >&2
  else
    ui_print "- 不是 block 或 char 设备, 保留映像"
    eval "$CMD1" | eval "$CMD2" > "$2" 2>/dev/null
  fi
  return 0
}

# flash_script.sh 和 addon.d.sh 的通用安装函数
install_magisk() {
  cd $MAGISKBIN

  if [ ! -c $BOOTIMAGE ]; then
    eval $BOOTSIGNER -verify < $BOOTIMAGE && BOOTSIGNED=true
    $BOOTSIGNED && ui_print "- Boot 映像已签名并为 AVB 1.0"
  fi

  # 修补 boot 映像
  SOURCEDMODE=true
  . ./boot_patch.sh "$BOOTIMAGE"

  ui_print "- 刷入新的 boot 映像"
  flash_image new-boot.img "$BOOTIMAGE"
  case $? in
    1)
      abort "! 分区大小不足"
      ;;
    2)
      abort "! $BOOTIMAGE 分区为只读"
      ;;
  esac

  ./magiskboot cleanup
  rm -f new-boot.img

  run_migrations
}

sign_chromeos() {
  ui_print "- 签名 ChromeOS boot 映像"

  echo > empty
  ./chromeos/futility vbutil_kernel --pack new-boot.img.signed \
  --keyblock ./chromeos/kernel.keyblock --signprivate ./chromeos/kernel_data_key.vbprivk \
  --version 1 --vmlinuz new-boot.img --config empty --arch arm --bootloader empty --flags 0x1

  rm -f empty new-boot.img
  mv new-boot.img.signed new-boot.img
}

remove_system_su() {
  if [ -f /system/bin/su -o -f /system/xbin/su ] && [ ! -f /su/bin/su ]; then
    ui_print "- 删除已安装的 system root"
    blockdev --setrw /dev/block/mapper/system$SLOT 2>/dev/null
    mount -o rw,remount /system
    # SuperSU
    if [ -e /system/bin/.ext/.su ]; then
      mv -f /system/bin/app_process32_original /system/bin/app_process32 2>/dev/null
      mv -f /system/bin/app_process64_original /system/bin/app_process64 2>/dev/null
      mv -f /system/bin/install-recovery_original.sh /system/bin/install-recovery.sh 2>/dev/null
      cd /system/bin
      if [ -e app_process64 ]; then
        ln -sf app_process64 app_process
      elif [ -e app_process32 ]; then
        ln -sf app_process32 app_process
      fi
    fi
    rm -rf /system/.pin /system/bin/.ext /system/etc/.installed_su_daemon /system/etc/.has_su_daemon \
    /system/xbin/daemonsu /system/xbin/su /system/xbin/sugote /system/xbin/sugote-mksh /system/xbin/supolicy \
    /system/bin/app_process_init /system/bin/su /cache/su /system/lib/libsupol.so /system/lib64/libsupol.so \
    /system/su.d /system/etc/install-recovery.sh /system/etc/init.d/99SuperSUDaemon /cache/install-recovery.sh \
    /system/.supersu /cache/.supersu /data/.supersu \
    /system/app/Superuser.apk /system/app/SuperSU /cache/Superuser.apk
  elif [ -f /cache/su.img -o -f /data/su.img -o -d /data/adb/su -o -d /data/su ]; then
    ui_print "- 删除已安装的 systemless root"
    umount -l /su 2>/dev/null
    rm -rf /cache/su.img /data/su.img /data/adb/su /data/adb/suhide /data/su /cache/.supersu /data/.supersu \
    /cache/supersu_install /data/supersu_install
  fi
}

api_level_arch_detect() {
  API=$(grep_get_prop ro.build.version.sdk)
  ABI=$(grep_get_prop ro.product.cpu.abi)
  if [ "$ABI" = "x86" ]; then
    ARCH=x86
    ABI32=x86
    IS64BIT=false
  elif [ "$ABI" = "arm64-v8a" ]; then
    ARCH=arm64
    ABI32=armeabi-v7a
    IS64BIT=true
  elif [ "$ABI" = "x86_64" ]; then
    ARCH=x64
    ABI32=x86
    IS64BIT=true
  else
    ARCH=arm
    ABI=armeabi-v7a
    ABI32=armeabi-v7a
    IS64BIT=false
  fi
}

check_data() {
  DATA=false
  DATA_DE=false
  if grep ' /data ' /proc/mounts | grep -vq 'tmpfs'; then
    # 测试 data 是否可写
    touch /data/.rw && rm /data/.rw && DATA=true
    # 测试 data 是否已被解密
    $DATA && [ -d /data/adb ] && touch /data/adb/.rw && rm /data/adb/.rw && DATA_DE=true
    $DATA_DE && [ -d /data/adb/magisk ] || mkdir /data/adb/magisk || DATA_DE=false
  fi
  NVBASE=/data
  $DATA || NVBASE=/cache/data_adb
  $DATA_DE && NVBASE=/data/adb
  resolve_vars
}

find_magisk_apk() {
  local DBAPK
  [ -z $APK ] && APK=$NVBASE/magisk.apk
  [ -f $APK ] || APK=$MAGISKBIN/magisk.apk
  [ -f $APK ] || APK=/data/app/com.topjohnwu.magisk*/*.apk
  [ -f $APK ] || APK=/data/app/*/com.topjohnwu.magisk*/*.apk
  if [ ! -f $APK ]; then
    DBAPK=$(magisk --sqlite "SELECT value FROM strings WHERE key='requester'" 2>/dev/null | cut -d= -f2)
    [ -z $DBAPK ] && DBAPK=$(strings $NVBASE/magisk.db | grep -oE 'requester..*' | cut -c10-)
    [ -z $DBAPK ] || APK=/data/user_de/*/$DBAPK/dyn/*.apk
    [ -f $APK ] || [ -z $DBAPK ] || APK=/data/app/$DBAPK*/*.apk
    [ -f $APK ] || [ -z $DBAPK ] || APK=/data/app/*/$DBAPK*/*.apk
  fi
  [ -f $APK ] || ui_print "! 无法检测 Boot 签名的 Magisk app APK"
}

run_migrations() {
  local LOCSHA1
  local TARGET
  # 旧版 Magisk app 安装
  local BACKUP=$MAGISKBIN/stock_boot*.gz
  if [ -f $BACKUP ]; then
    cp $BACKUP /data
    rm -f $BACKUP
  fi

  # 旧版备份
  for gz in /data/stock_boot*.gz; do
    [ -f $gz ] || break
    LOCSHA1=`basename $gz | sed -e 's/stock_boot_//' -e 's/.img.gz//'`
    [ -z $LOCSHA1 ] && break
    mkdir /data/magisk_backup_${LOCSHA1} 2>/dev/null
    mv $gz /data/magisk_backup_${LOCSHA1}/boot.img.gz
  done

  # 备份
  LOCSHA1=$SHA1
  for name in boot dtb dtbo dtbs; do
    BACKUP=$MAGISKBIN/stock_${name}.img
    [ -f $BACKUP ] || continue
    if [ $name = 'boot' ]; then
      LOCSHA1=`$MAGISKBIN/magiskboot sha1 $BACKUP`
      mkdir /data/magisk_backup_${LOCSHA1} 2>/dev/null
    fi
    TARGET=/data/magisk_backup_${LOCSHA1}/${name}.img
    cp $BACKUP $TARGET
    rm -f $BACKUP
    gzip -9f $TARGET
  done
}

copy_sepolicy_rules() {
  # 删除所有的现有 sepolicy rule 文件夹
  rm -rf /data/unencrypted/magisk /cache/magisk /metadata/magisk /persist/magisk /mnt/vendor/persist/magisk

  # 查找当前活动的 RULESDIR
  local RULESDIR
  local ACTIVEDIR=$(magisk --path)/.magisk/mirror/sepolicy.rules
  if [ -L $ACTIVEDIR ]; then
    RULESDIR=$(readlink $ACTIVEDIR)
    [ "${RULESDIR:0:1}" != "/" ] && RULESDIR="$(magisk --path)/.magisk/mirror/$RULESDIR"
  elif ! $ISENCRYPTED; then
    RULESDIR=$NVBASE/modules
  elif [ -d /data/unencrypted ] && ! grep ' /data ' /proc/mounts | grep -qE 'dm-|f2fs'; then
    RULESDIR=/data/unencrypted/magisk
  elif grep ' /cache ' /proc/mounts | grep -q 'ext4' ; then
    RULESDIR=/cache/magisk
  elif grep ' /metadata ' /proc/mounts | grep -q 'ext4' ; then
    RULESDIR=/metadata/magisk
  elif grep ' /persist ' /proc/mounts | grep -q 'ext4' ; then
    RULESDIR=/persist/magisk
  elif grep ' /mnt/vendor/persist ' /proc/mounts | grep -q 'ext4' ; then
    RULESDIR=/mnt/vendor/persist/magisk
  else
    ui_print "- 无法找到 sepolicy rules 目录"
    return 1
  fi

  if [ -d ${RULESDIR%/magisk} ]; then
    ui_print "- Sepolicy rules 目录为 ${RULESDIR%/magisk}"
  else
    ui_print "- Sepolicy rules 目录 ${RULESDIR%/magisk} 不存在"
    return 1
  fi

  # 复制所有已启用模块的 sepolicy.rule
  for r in $NVBASE/modules*/*/sepolicy.rule; do
    [ -f "$r" ] || continue
    local MODDIR=${r%/*}
    [ -f $MODDIR/disable ] && continue
    [ -f $MODDIR/remove ] && continue
    local MODNAME=${MODDIR##*/}
    mkdir -p $RULESDIR/$MODNAME
    cp -f $r $RULESDIR/$MODNAME/sepolicy.rule
  done
}

#################
# 模块相关
#################

set_perm() {
  chmod $4 $1 || return 1
}

set_perm_recursive() {
  find $1 -type d 2>/dev/null | while read dir; do
    set_perm $dir $2 $3 $4 $6
  done
  find $1 -type f -o -type l 2>/dev/null | while read file; do
    set_perm $file $2 $3 $5 $6
  done
}

mktouch() {
  mkdir -p ${1%/*} 2>/dev/null
  [ -z $2 ] && touch $1 || echo $2 > $1
  chmod 644 $1
}

request_size_check() {
  reqSizeM=`du -ms "$1" | cut -f1`
}

request_zip_size_check() {
  reqSizeM=`unzip -l "$1" | tail -n 1 | awk '{ print int(($1 - 1) / 1048576 + 1) }'`
}

boot_actions() { return; }

# 要求已设置 ZIPFILE 变量
is_legacy_script() {
  unzip -l "$ZIPFILE" install.sh | grep -q install.sh
  return $?
}

# 要求已设置 OUTFD ZIPFILE 变量
install_module() {
  rm -rf $TMPDIR
  mkdir -p $TMPDIR
  cd $TMPDIR

  setup_flashable
  mount_partitions
  api_level_arch_detect

  # 设置 busybox 和二进制文件
  if $BOOTMODE; then
    boot_actions
  else
    recovery_actions
  fi

  # 解压 module.prop 文件
  unzip -o "$ZIPFILE" module.prop -d $TMPDIR >&2
  [ ! -f $TMPDIR/module.prop ] && abort "! 无法解压文件!"

  local MODDIRNAME=modules
  $BOOTMODE && MODDIRNAME=modules_update
  local MODULEROOT=$NVBASE/$MODDIRNAME
  MODID=`grep_prop id $TMPDIR/module.prop`
  MODNAME=`grep_prop name $TMPDIR/module.prop`
  MODAUTH=`grep_prop author $TMPDIR/module.prop`
  MODPATH=$MODULEROOT/$MODID

  # 创建模块目录
  rm -rf $MODPATH
  mkdir -p $MODPATH

  if is_legacy_script; then
    unzip -oj "$ZIPFILE" module.prop install.sh uninstall.sh 'common/*' -d $TMPDIR >&2

    # 加载安装脚本
    . $TMPDIR/install.sh

    # 启动安装
    print_modname
    on_install

    [ -f $TMPDIR/uninstall.sh ] && cp -af $TMPDIR/uninstall.sh $MODPATH/uninstall.sh
    $SKIPMOUNT && touch $MODPATH/skip_mount
    $PROPFILE && cp -af $TMPDIR/system.prop $MODPATH/system.prop
    cp -af $TMPDIR/module.prop $MODPATH/module.prop
    $POSTFSDATA && cp -af $TMPDIR/post-fs-data.sh $MODPATH/post-fs-data.sh
    $LATESTARTSERVICE && cp -af $TMPDIR/service.sh $MODPATH/service.sh

    ui_print "- 设置文件权限"
    set_permissions
  else
    print_title "$MODNAME" "作者: $MODAUTH"
    print_title "由 Magisk 提供支持"

    unzip -o "$ZIPFILE" customize.sh -d $MODPATH >&2

    if ! grep -q '^SKIPUNZIP=1$' $MODPATH/customize.sh 2>/dev/null; then
      ui_print "- 解压模块文件"
      unzip -o "$ZIPFILE" -x 'META-INF/*' -d $MODPATH >&2

      # 默认设置权限
      set_perm_recursive $MODPATH 0 0 0755 0644
      set_perm_recursive $MODPATH/system/bin 0 2000 0755 0755
      set_perm_recursive $MODPATH/system/xbin 0 2000 0755 0755
      set_perm_recursive $MODPATH/system/system_ext/bin 0 2000 0755 0755
      set_perm_recursive $MODPATH/system/vendor/bin 0 2000 0755 0755 u:object_r:vendor_file:s0
    fi

    # 加载自定义安装脚本
    [ -f $MODPATH/customize.sh ] && . $MODPATH/customize.sh
  fi

  # 处理替换目录
  for TARGET in $REPLACE; do
    ui_print "- 替换目标: $TARGET"
    mktouch $MODPATH$TARGET/.replace
  done

  if $BOOTMODE; then
    # Magisk app 的更新信息
    mktouch $NVBASE/modules/$MODID/update
    rm -rf $NVBASE/modules/$MODID/remove 2>/dev/null
    rm -rf $NVBASE/modules/$MODID/disable 2>/dev/null
    cp -af $MODPATH/module.prop $NVBASE/modules/$MODID/module.prop
  fi

  # 复制自定义 sepolicy rules
  if [ -f $MODPATH/sepolicy.rule ]; then
    ui_print "- 安装自定义 sepolicy rules"
    copy_sepolicy_rules
  fi

  # 删除不属于模块的内容并清理所有空目录
  rm -rf \
  $MODPATH/system/placeholder $MODPATH/customize.sh \
  $MODPATH/README.md $MODPATH/.git*
  rmdir -p $MODPATH

  cd /
  $BOOTMODE || recovery_cleanup
  rm -rf $TMPDIR

  ui_print "- 完成"
}

##########
# 预设
##########

# 检测是否处于启动模式
[ -z $BOOTMODE ] && ps | grep zygote | grep -qv grep && BOOTMODE=true
[ -z $BOOTMODE ] && ps -A 2>/dev/null | grep zygote | grep -qv grep && BOOTMODE=true
[ -z $BOOTMODE ] && BOOTMODE=false

ROOTFS=$(dir=$(cat /init_shell.sh | xargs -n 1 | grep "init" | sed "s|/init||"); [ -d "$dir" ] && echo "$dir" || echo "$(echo "$dir" | sed "s|user/0|data|")")
NVBASE="$ROOTFS"/data/adb
TMPDIR="$NVBASE"/tmp

# Boot 签名相关
BOOTSIGNERCLASS=com.topjohnwu.signing.SignBoot
BOOTSIGNER='/system/bin/dalvikvm -Xnoimage-dex2oat -cp $APK $BOOTSIGNERCLASS'
BOOTSIGNED=false

resolve_vars
