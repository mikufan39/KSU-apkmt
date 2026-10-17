#!/system/bin/sh
# APKM 直装器 (apkmt) — 模块卸载清理
# 只删除本模块自己写入的运行数据（安装历史、日志、临时目录）；
# 不触碰用户已经安装的应用，也不删除 /sdcard 里的安装包。

rm -rf /data/adb/apkmt 2>/dev/null
rm -rf /data/local/tmp/apkmt 2>/dev/null
rm -f /data/local/tmp/apkmt-ui.log 2>/dev/null

exit 0
