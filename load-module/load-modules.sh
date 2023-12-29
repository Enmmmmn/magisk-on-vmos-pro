#!/system/bin/sh
#加载列表
list=/data/adb/load-module/config/load-list
#清理列表
sed -i "/^$/d" $list
#删除文件
for module in $(cat $list); do
  #检测状态
  [ ! -f "$module/update" -a ! -f "$module/skip_mount" -a ! -f "$module/disable" -a ! -f "$module/remove" ] && continue
  #重启服务
  [ -z "$restart" ] && setprop ctl.stop zygote && setprop ctl.stop zygote_secondary && restart=true
  #执行文件
  sh /data/adb/load-module/backup/remove-$(basename $module).sh > /dev/null 2>&1
  #删除文件
  rm -f /data/adb/load-module/backup/remove-$(basename $module).sh
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
    for prop in $(cat "$module/system.prop"); do
      echo "$prop" | sed "s/=/ /" | xargs setprop
    done
    #检测状态
    [ "$(cat $list | grep "$module")" ] || [ -f "$module/skip_mount" ] || [ ! -d "$module/system/" ] && continue
    #重启服务
    [ -z "$restart" ] && setprop ctl.stop zygote && setprop ctl.stop zygote_secondary && restart=true
    #切换目录
    cd "$module/system"
    #加载文件
    for file in $(find); do
      #目标文件
      target=$(echo "$file" | sed "s/..//")
      #检查类型
      if [ -f "$module/system/$target" ]; then
        #备份文件
        if [ "$(cat "/system/$target")" ]; then
          #检查文件
          [ -f "/data/adb/load-module/backup/system/$target" ] && continue
          #创建目录
          mkdir -p "/data/adb/load-module/backup/system/$(dirname "$target")" > /dev/null 2>&1
          #复制文件
          cp -p "/system/$target" "/data/adb/load-module/backup/system/$target" || continue
          #修改文件
          echo -e "cp -p /data/adb/load-module/backup/system/$target /system/$target\nrm /data/adb/load-module/backup/system/$target" >> /data/adb/load-module/backup/remove-$(basename $module).sh
        else
          #修改文件
          echo "rm -f /system/$target" >> /data/adb/load-module/backup/remove-$(basename $module).sh
        fi
        #复制文件
        cp -fp "$module/system/$target" "/system/$target"
      elif [ -d "$module/system/$target" ]; then
        #检查目录
        [ -d "/system/$target" ] && continue
        #创建目录
        mkdir -m 755 "/system/$target"
        #修改文件
        echo "rm -rf /system/$target" >> /data/adb/load-module/backup/remove-$(basename $module).sh
      fi
    done
    #修改文件
    echo "$module" >> $list
  done
  #重启服务
  [ "$restart" ] && setprop ctl.start zygote && setprop ctl.start zygote_secondary
} &
exit 0