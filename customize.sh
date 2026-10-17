#!/system/bin/sh
# APKM 直装器 (apkmt) — 模块安装脚本（KernelSU / Magisk 通用 customize.sh）
# 只做两件事，不挂载任何 system 目录（SKIPMOUNT=true），不安装开机服务（引擎由 WebUI 按需调用）：
#   1) 权限设置与运行数据目录；
#   2) 请求 KernelSU 官方热安装（v1.3.5 起只走官方协议，老版本如实提示需重启）。
#
# 免重启的唯一条件：管理器自身支持官方热安装 —— 安装器导出 KSU_HAS_HOT_INSTALL=true
# （2026-10 起的 KernelSU main 分支；正式版 v3.3.1 及更早没有这个能力，管理器一定会提示重启）。
#   - 支持：设置 MODULE_HOT_INSTALL_REQUEST=true，安装结束后由 ksud 把暂存目录整体换上（swap），
#     首次安装也一样，管理器不会再要求重启（分区挂载类模块除外，本模块不挂载）。
#   - 不支持：保持 KernelSU 默认行为（暂存到 modules_update/<id>，重启后合并），如实提示
#     “需要重启一次生效”。不做文件同步，也不再用“可忽略”之类的话术掩盖管理器行为。

SKIPMOUNT=true
PROPFILE=false
POSTFSDATA=false
LATESTARTSERVICE=false

[ -n "$MODPATH" ] || MODPATH="$(cd "$(dirname "$0")" && pwd)"

say() {
  if command -v ui_print >/dev/null 2>&1; then
    ui_print "$1"
  else
    echo "$1"
  fi
}

VER="$(sed -n 's/^version=//p' "$MODPATH/module.prop" 2>/dev/null | head -n 1)"
[ -n "$VER" ] || VER="?"

say "- APKM 直装器 (apkmt) $VER"

chmod 0755 "$MODPATH/bin/apkmt.sh" 2>/dev/null
chmod 0755 "$MODPATH/customize.sh" 2>/dev/null
chmod 0755 "$MODPATH/uninstall.sh" 2>/dev/null
chmod 0644 "$MODPATH/module.prop" 2>/dev/null

if [ -d "$MODPATH/webroot" ]; then
  chmod 0755 "$MODPATH/webroot" 2>/dev/null
  chmod 0644 "$MODPATH/webroot"/* 2>/dev/null
  say "- WebUI: KernelSU 管理器 → 模块 → APKM 直装器 → 打开"
else
  say "- 警告: 未找到 webroot/，WebUI 无法打开"
fi

# 运行数据目录（安装历史、临时文件）；引擎自己也会按需创建
mkdir -p /data/adb/apkmt 2>/dev/null
chmod 0700 /data/adb/apkmt 2>/dev/null

# ---------------------------------------------------------------------------
# 热更新（只支持 KernelSU 官方协议；老版本没有这个能力，如实提示重启）
# ---------------------------------------------------------------------------
if [ "${KSU_HAS_HOT_INSTALL:-}" = "true" ]; then
  MODULE_HOT_INSTALL_REQUEST=true
  say "- 热更新：已请求 KernelSU 官方热安装，安装完成后立即生效（无需重启）"
else
  say "- 提示：当前 KernelSU 版本不支持热安装，需要重启一次才能生效"
fi
