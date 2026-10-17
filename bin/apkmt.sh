#!/system/bin/sh
# ==============================================================================
#  APKM 直装器 (apkmt) 引擎  v1.3.5
#  纯 POSIX sh。KernelSU WebUI / action.sh / CLI 共用同一套逻辑。
#
#  输出协议：每行一条记录，字段用 | 分隔（引擎输出保持纯 ASCII，中文在 WebUI 层）
#    META|key|value
#    ENTRY|name|size|kind|token|selected|reason_code
#    PROGRESS|percent|stage|bytes_done|bytes_total|splits_done|splits_total
#    RESULT|OK|pkg|version|message
#    RESULT|FAIL|error_code|message
#    DETAIL|raw text
#    LOG|text
#    DIAG|key|value
#    LS|D|name|size|mtime     (目录)
#    LS|F|name|size|mtime     (文件)
#
#  安装历史（hist_file()，WebUI 历史页与 CLI 共用，固定 7 个字段）：
#    <epoch>|OK|<pkg>|<version>|<mode>|installed|<bundle path>
#    <epoch>|FAIL|<pkg>|<version>|<mode>|<error code>|<bundle path>
#  v1.0.0 写的是空格分隔 + ISO 时间戳的另一套格式，WebUI 旧版本只认管道格式，
#  于是历史页永远退化成原始文本；v1.3.1 统一成上面这种（WebUI 侧两种都兼容）。
#
#  元信息（META|pkg / version / version_code / min_api / target_api）来源优先级：
#    info.json|manifest.json|meta.json  →  基础包内的 AndroidManifest.xml（权威）
#    →  toc.pb 的 package_name 字段  →  strings 兜底猜测
#
#  图标与应用名（v1.3.2 起，v1.3.3 补齐资源表解析）：预装阶段 ksu://icon 还拿不到
#  图，所以从包内提取——
#    META|icon       相对模块 webroot 的图片 URL（icon-cache/<pkg>.<ext>?v<ts>）
#    META|icon_bg    自适应图标的背景层：CSS 颜色（#rrggbb / rgba(...)）或图片 URL
#    META|icon_scale 自适应图标前景层的放大倍数（108dp 画布取中间 72dp，=1.5）
#    META|icon_src   arsc（资源表解析的位图）| adaptive（自适应图标）| vector（矢量）
#                    | root（xapk/apkm 根目录 icon.png）| mipmap（res/mipmap 启发式）
#    META|label_src  json（info/manifest/meta.json）| arsc（资源表字符串池）
#                    | manifest（APK 清单字面量）
#  Android 的 android:label / android:icon 绝大多数是 @string/xxx、@mipmap/xxx 资源
#  引用，manifest 里只有资源 ID——必须查 resources.arsc 才能拿到字面量和真实文件。
#  自适应图标（API 26+）拆成背景层（纯色/渐变）+ 前景层（矢量/位图）两层渲染，
#  这样前端才能画出和系统启动器一致的图标，而不是一片空白/首字母。
#  取不到时 META|icon 为空、source=none，WebUI 回退到“已装应用图标 / 首字母”。
#
#  热更新（v1.3.5）：只支持 KernelSU 官方热安装协议——管理器导出 KSU_HAS_HOT_INSTALL=true
#  时，customize.sh 设置 MODULE_HOT_INSTALL_REQUEST=true，ksud 在安装结束后把暂存目录
#  整体换上（swap），更新和首次安装都无需重启。老版本 KernelSU / Magisk 没有这个能力，
#  保持默认行为（暂存到 modules_update，重启后合并）并如实提示；本引擎不做文件同步，
#  也不再清理安装器写的 update 标记（那个提示归管理器管）。
#  用法：
#    apkmt.sh diag
#    apkmt.sh list <dir>
#    apkmt.sh inspect <bundle> [--mode auto|all|manual] [--splits a,b] [--lang sys|all]
#    apkmt.sh install <bundle> [--mode ...] [--splits ...] [--lang ...] [--user N]
#                               [--installer PKG] [--downgrade] [--grant] [--dry-run]
#                               [--test-write]  仅流式写入后 abandon（不提交，诊断用）
#    apkmt.sh action
# ==============================================================================

APKMT_VERSION="1.3.5"
STATE_DIR="/data/adb/apkmt"
TMP_BASE="/data/local/tmp/apkmt"
# 模块目录（v1.3.2）：预装阶段要把包内图标落到 webroot/icon-cache/。WebUI 的资源
# 加载器按目录映射 webroot，所以图片必须落在模块自己的 webroot 下、前端用相对 URL
# 引用；直接给绝对 file:// 路径在部分 WebView 上会被拦。测试用 APKMT_MODDIR 指定。
APKMT_MODDIR="${APKMT_MODDIR:-}"
# 为了一张图标去解嵌套基础包时允许的最大字节数。元信息解析的阈值是 256MB，但图标
# 只是锦上添花，不值得为它解出几百 MB（图标解析失败前端会回退字母/已装图标）。
# 注意：实际生效值是 min(APKMT_ICON_BASE_MAX, APKMT_BASE_META_MAX)——后者是"允许
# 为解析目的把基础包落盘"的总闸，把它调小（例如排障时设成 1024）应同时关掉图标解包。
APKMT_ICON_BASE_MAX="${APKMT_ICON_BASE_MAX:-67108864}"
# 解析嵌套基础包（.apkm/.apks/.xapk 里的 base apk）元信息时，最多愿意落盘多少字节。
# 超过就跳过 manifest 解析，退回 info.json / toc.pb，避免大包在 /data 里解出几百 MB。
APKMT_BASE_META_MAX="${APKMT_BASE_META_MAX:-268435456}"
# 交给 AXML 解析器的最大字节数（AndroidManifest.xml 一般 < 100KB）
AXML_MAX_BYTES="${AXML_MAX_BYTES:-524288}"
# resources.arsc 只解析前这么多字节（超过就放弃资源表解析，退回旧启发式）。
# 中转出来的是十六进制文本（2 字符/字节），8MB 资源表约 16MB 文本，小包通常 < 2MB。
ARSC_MAX_BYTES="${ARSC_MAX_BYTES:-8388608}"
# 矢量 XML 转出来的 SVG 上限（正常图标 SVG 只有几 KB）
ICON_SVG_MAX="${ICON_SVG_MAX:-262144}"

PATH="/system/bin:/system/xbin:$PATH"
[ -d /data/adb/ksu/bin ] && PATH="/data/adb/ksu/bin:$PATH"
export PATH
LC_ALL=C
export LC_ALL

# ---------------------------------------------------------------- 基础工具

say() { printf '%s\n' "$*"; }
rec() { printf '%s|%s\n' "$1" "$2"; }

# 模块目录：$0 形如 /data/adb/modules/apkmt/bin/apkmt.sh 时取 $0 的父父目录；
# 从别处调用（测试/排障）则探测标准安装路径。成功时缓存进 APKMT_MODDIR。
moddir_get() {
  [ -n "$APKMT_MODDIR" ] && { printf '%s' "$APKMT_MODDIR"; return 0; }
  MC=""
  case "$0" in
    */bin/*) MC="${0%/bin/*}";;
  esac
  if [ -z "$MC" ] || [ ! -d "$MC/webroot" ]; then
    MC=""
    for c in /data/adb/modules/apkmt /data/adb/modules_update/apkmt; do
      [ -d "$c/webroot" ] && { MC="$c"; break; }
    done
  fi
  [ -n "$MC" ] || return 1
  APKMT_MODDIR="$MC"
  printf '%s' "$APKMT_MODDIR"
}

# 历史记录落盘位置（root 下用 STATE_DIR，非 root 调试时退回 TMP_BASE）
hist_file() {
  if [ -d "$STATE_DIR" ] && [ -w "$STATE_DIR" ]; then echo "$STATE_DIR/history.log"
  else echo "$TMP_BASE/history.log"; fi
}

# 写一条安装历史。字段里的 | 与换行必须剔掉，否则 WebUI 按 | 切列会整体错位。
# （Android 的 mksh 里 ${x%%|*} 不可用，见 classify 注释，所以这里只用 tr。）
hist_add() { # $1=OK|FAIL  $2=pkg  $3=version  $4=状态或错误码
  HF=$(hist_file)
  HS=$(date +%s 2>/dev/null); [ -n "$HS" ] || HS=0
  HP=$(printf '%s' "$2" | tr -d '|\r\n')
  HV=$(printf '%s' "$3" | tr -d '|\r\n')
  HM=$(printf '%s' "$MODE" | tr -d '|\r\n')
  HC=$(printf '%s' "$4" | tr -d '|\r\n')
  HB=$(printf '%s' "$BUNDLE" | tr -d '|\r\n')
  printf '%s|%s|%s|%s|%s|%s|%s\n' "$HS" "$1" "$HP" "$HV" "$HM" "$HC" "$HB" >> "$HF" 2>/dev/null
  return 0
}

# 全局运行目录
init_tmp() {
  if mkdir -p "$STATE_DIR/tmp" 2>/dev/null && [ -w "$STATE_DIR/tmp" ]; then
    TMP="$STATE_DIR/tmp"
  else
    mkdir -p "$TMP_BASE" 2>/dev/null
    TMP="$TMP_BASE"
  fi
  TMP="$TMP/$$"
  mkdir -p "$TMP" 2>/dev/null || TMP="$TMP_BASE"
}

cleanup_tmp() {
  [ -n "$TMP" ] && rm -rf "$TMP" 2>/dev/null
  return 0
}

# 查找 unzip：优先 KernelSU 自带 busybox（zip64 支持更好），退回系统 toybox unzip
find_unzip() {
  [ -n "$UNZIP" ] && return 0
  if [ -x /data/adb/ksu/bin/busybox ]; then
    if /data/adb/ksu/bin/busybox unzip -h >/dev/null 2>&1 || /data/adb/ksu/bin/busybox 2>&1 | grep -qw unzip; then
      UNZIP="/data/adb/ksu/bin/busybox unzip"; return 0
    fi
  fi
  if [ -x /system/bin/unzip ]; then UNZIP="/system/bin/unzip"; return 0; fi
  if command -v unzip >/dev/null 2>&1; then UNZIP="unzip"; return 0; fi
  if command -v busybox >/dev/null 2>&1; then UNZIP="busybox unzip"; return 0; fi
  return 1
}

# 某个 unzip 命令能否真正列出该包的条目。busybox 与 toybox 的 -l 输出格式不同，
# zip64 支持也不同；这里的判据与 zip_table() 完全一致，避免"命令能跑但解析为空"。
unzip_lists() { # $1 = 包路径, $2 = unzip 命令（可能含空格，故意不加引号）
  $2 -l "$1" 2>/dev/null | awk 'NF>=4 && $1 ~ /^[0-9]+$/ {n++} END{exit !(n>0)}'
}

# 针对具体包挑一个真能解析它的 unzip（root 下优先 KernelSU 自带 busybox）
find_unzip_for() { # $1 = 包路径
  UZ_F="$1"
  for c in "/data/adb/ksu/bin/busybox unzip" "busybox unzip" "/system/bin/unzip" "unzip" "toybox unzip"; do
    set -- $c
    command -v "$1" >/dev/null 2>&1 || continue
    if unzip_lists "$UZ_F" "$c"; then UNZIP="$c"; return 0; fi
  done
  UNZIP=""
  return 1
}

find_pm() {
  [ -n "$PM" ] && return 0
  if [ -x /system/bin/pm ]; then PM="/system/bin/pm"; return 0; fi
  if command -v pm >/dev/null 2>&1; then PM="pm"; return 0; fi
  return 1
}

fmt_size() { # 人类可读（ASCII）
  awk -v b="$1" 'BEGIN{
    split("B KB MB GB TB",u," "); i=1;
    while (b>=1024 && i<5) { b/=1024; i++ }
    printf (i==1 ? "%.0f%s" : "%.2f%s"), b, u[i]
  }'
}

# 是否支持某 ABI/密度条目（归一化比较）
norm() { printf '%s' "$1" | tr -d '_-' | tr 'A-Z' 'a-z'; }

contains_word() { # $1 list(逗号分隔) $2 word
  case ",$1," in *",$2,"*) return 0;; esac
  return 1
}

# ---------------------------------------------------------------- 设备探测

probe_device() {
  DEV_SDK=$(getprop ro.build.version.sdk)
  DEV_RELEASE=$(getprop ro.build.version.release)
  DEV_ABILIST=$(getprop ro.product.cpu.abilist)
  [ -n "$DEV_ABILIST" ] || DEV_ABILIST=$(getprop ro.product.cpu.abi)
  DEV_ABI_PRIMARY=$(printf '%s' "$DEV_ABILIST" | cut -d, -f1)
  # 密度：用户调过"显示大小"（wm density override）时必须用当前生效值，
  # 否则会按物理密度挑分片，和系统实际缩放对不上。
  WM_DENSITY_OUT=$(wm density 2>/dev/null)
  DEV_DENSITY_PHYS=$(printf '%s' "$WM_DENSITY_OUT" | sed -n 's/.*[Pp]hysical density: *\([0-9][0-9]*\).*/\1/p' | head -1)
  DEV_DENSITY_OVERRIDE=$(printf '%s' "$WM_DENSITY_OUT" | sed -n 's/.*[Oo]verride density: *\([0-9][0-9]*\).*/\1/p' | head -1)
  DEV_DENSITY="$DEV_DENSITY_OVERRIDE"
  [ -n "$DEV_DENSITY" ] || DEV_DENSITY="$DEV_DENSITY_PHYS"
  [ -n "$DEV_DENSITY" ] || DEV_DENSITY=$(getprop ro.sf.lcd_density)
  [ -n "$DEV_DENSITY" ] || DEV_DENSITY=160
  DEV_LOCALE=$(getprop persist.sys.locale)
  [ -n "$DEV_LOCALE" ] || DEV_LOCALE=$(getprop ro.product.locale)
  [ -n "$DEV_LOCALE" ] || DEV_LOCALE="en-US"
  DEV_LANG=$(printf '%s' "$DEV_LOCALE" | cut -d- -f1 | cut -d_ -f1 | tr 'A-Z' 'a-z')
  DEV_MODEL=$(getprop ro.product.model)
}

# ---------------------------------------------------------------- 目录列举

cmd_list() {
  DIR="$1"
  [ -n "$DIR" ] || { say "LS|ERROR|no_dir"; return 1; }
  case "$DIR" in /*) ;; *) say "LS|ERROR|need_absolute_path"; return 1;; esac
  if [ ! -d "$DIR" ]; then say "LS|ERROR|not_a_directory|$DIR"; return 1; fi
  say "LS|HDR|$DIR"
  CNT=0
  for p in "$DIR"/* "$DIR"/.[!.]*; do
    [ -e "$p" ] || continue
    n=$(basename "$p")
    if [ -d "$p" ]; then
      mt=$(stat -c %Y "$p" 2>/dev/null); [ -n "$mt" ] || mt=0
      say "LS|D|$n|0|$mt"
    else
      sz=$(stat -c %s "$p" 2>/dev/null); [ -n "$sz" ] || sz=0
      mt=$(stat -c %Y "$p" 2>/dev/null); [ -n "$mt" ] || mt=0
      say "LS|F|$n|$sz|$mt"
    fi
    CNT=$((CNT + 1))
    [ "$CNT" -ge 800 ] && { say "LS|TRUNC|800"; break; }
  done
  say "LS|END|$CNT"
  return 0
}

# ---------------------------------------------------------------- zip 解析

# 输出：SIZE<TAB>NAME（所有条目）
zip_table() {
  $UNZIP -l "$1" 2>/dev/null | awk '
    NF >= 4 && $1 ~ /^[0-9]+$/ {
      name = $4
      for (i = 5; i <= NF; i++) name = name " " $i
      print $1 "\t" name
    }'
}

tbl_get() { awk -F'\t' -v n="$1" '$2 == n { print $1; exit }' "$2"; }

# 找出基础包（base）。结果同时写入全局 BASE_KIND：base | universal | standalone
#
# v1.3.1 修正：旧实现拿"整条 zip 条目路径"去比 "base.apk" / "base-master.apk"，
# 而 bundletool 生成的 .apks 里基础包叫 splits/base-master.apk —— 于是两条精确
# 规则永远不命中，最后走"最大 apk"兜底，把 base-arm64_v8a.apk 之类的配置分片
# 当成了基础包（写进会话后必然 INSTALL_FAILED/解析不出包）。
# 现在一律按 basename 比较，并显式识别 universal / standalones/ 两种独立包形态。
find_base() {
  T="$1"
  BASE_KIND="base"
  # 1) base.apk（APKMirror .apkm、部分 .xapk）
  B=$(awk -F'\t' '{ n=split($2,p,"/"); if (tolower(p[n])=="base.apk") { print $2; exit } }' "$T")
  [ -n "$B" ] && { printf '%s' "$B"; return; }
  # 2) base-master.apk（bundletool .apks，带 splits/ 目录前缀）
  B=$(awk -F'\t' '{ n=split($2,p,"/"); if (tolower(p[n])=="base-master.apk") { print $2; exit } }' "$T")
  [ -n "$B" ] && { printf '%s' "$B"; return; }
  # 3) 整包只有 1 个 apk：就是它（改过后缀的单文件包）
  B=$(awk -F'\t' 'tolower($2) ~ /\.apk$/ { v=$2; c++ } END{ if (c==1) print v }' "$T")
  [ -n "$B" ] && { printf '%s' "$B"; return; }
  # 4) universal.apk（bundletool --mode=universal 的独立包）
  B=$(awk -F'\t' '{ n=split($2,p,"/"); if (tolower(p[n])=="universal.apk") { print $2; exit } }' "$T")
  [ -n "$B" ] && { BASE_KIND="universal"; printf '%s' "$B"; return; }
  # 5) standalones/（bundletool --mode=standalone）：优先设备主 ABI，其次无 ABI 的通用包
  if awk -F'\t' 'tolower($2) ~ /(^|\/)standalones\// { f=1 } END{ exit !f }' "$T"; then
    B=$(awk -F'\t' -v abi="$DEV_ABI_PRIMARY" '
      function nz(s){ gsub(/[-_]/,"",s); return tolower(s) }
      tolower($2) ~ /(^|\/)standalones\// && tolower($2) ~ /\.apk$/ {
        n=split($2,p,"/"); bn=nz(p[n]); sc=0
        if (abi != "" && bn ~ nz(abi)) sc=2
        else if (bn !~ /arm64v8a|armeabiv7a|armeabi|riscv64|x8664|x86|armv7a/) sc=1
        if (best=="" || sc>bsc || (sc==bsc && $1+0>bsz)) { best=$2; bsc=sc; bsz=$1+0 }
      }
      END{ if (best != "") print best }' "$T")
    [ -n "$B" ] && { BASE_KIND="standalone"; printf '%s' "$B"; return; }
  fi
  # 6) 名字里没有 split/config/master 的最大 apk（.xapk 的 <包名>.apk 走这条）
  B=$(awk -F'\t' '
    { n=split($2,p,"/"); bn=tolower(p[n]); full=tolower($2) }
    full ~ /\.apk$/ && full !~ /standalones\// && bn !~ /split|config|master/ { print $1 "\t" $2 }
  ' "$T" | sort -rn | head -1 | cut -f2)
  [ -n "$B" ] && { printf '%s' "$B"; return; }
  # 7) 兜底：最大 apk（含 asset_pack_*-master 之类）
  awk -F'\t' 'tolower($2) ~ /\.apk$/ { print $1 "\t" $2 }' "$T" | sort -rn | head -1 | cut -f2
}

# 分类：结果写入全局 CKIND / CTOK（kind: base|abi|dpi|lang|other）
# 禁止在这里用命令替换 + "${x%%|*}" 解析：Android 的 mksh(R59) 把模式里的 '|'
# 当作交替符，${c%%|*} 会返回空串（kernelsu 的 busybox ash 则不会），两边行为不一致。
classify() {
  CKIND="other"; CTOK=""
  n=$(basename "$1"); s=$(printf '%s' "$n" | tr 'A-Z' 'a-z')
  full=$(printf '%s' "$1" | tr 'A-Z' 'a-z')
  case "$s" in *.apk) ;; *) return;; esac
  # 独立包（bundletool --mode=standalone）：每个条目都是完整 APK，只能装一个。
  # 必须先于 ABI/DPI 判断，否则会被当成 ABI/DPI 分片一起选进来 ——
  # 一个安装会话里出现两个完整包，pm 直接报错。
  case "$full" in standalones/*|*standalones/*|standalone/*|*standalone/*) CKIND="standalone"; return;; esac
  stem=${s%.apk}
  t=$(printf '%s' "$stem" | tr '-' '_')
  case "$t" in
    *arm64_v8a*) CKIND="abi"; CTOK="arm64-v8a"; return;;
    *armeabi_v7a*) CKIND="abi"; CTOK="armeabi-v7a"; return;;
    *armeabi*) CKIND="abi"; CTOK="armeabi"; return;;
    *x86_64*) CKIND="abi"; CTOK="x86_64"; return;;
    *x86*) CKIND="abi"; CTOK="x86"; return;;
    *riscv64*) CKIND="abi"; CTOK="riscv64"; return;;
  esac
  case "$stem" in
    *xxxhdpi*) CKIND="dpi"; CTOK="640"; return;;
    *xxhdpi*) CKIND="dpi"; CTOK="480"; return;;
    *xhdpi*) CKIND="dpi"; CTOK="320"; return;;
    *tvdpi*) CKIND="dpi"; CTOK="213"; return;;
    *nodpi*) CKIND="dpi"; CTOK="nodpi"; return;;
    *anydpi*) CKIND="dpi"; CTOK="anydpi"; return;;
    *hdpi*) CKIND="dpi"; CTOK="240"; return;;
    *mdpi*) CKIND="dpi"; CTOK="160"; return;;
    *ldpi*) CKIND="dpi"; CTOK="120"; return;;
  esac
  case "$stem" in
    *base|*_master|*-master) CKIND="master"; return;;
  esac
  # 语言：bundletool 会生成 base-<lang> / b+<lang>+<script>、config.<lang>、
  # <name>-rXX、<name>-<lang>-<script|region> 等形态
  case "$stem" in
    *b+*)
      L=$(printf '%s' "$stem" | sed -n 's/.*b+\([a-z][a-z][a-z]*\).*/\1/p')
      [ -n "$L" ] && { CKIND="lang"; CTOK="$L"; return; }
      ;;
  esac
  # -rXX（区域后缀）必须在"末段"判断之前处理，否则 zh-rCN 会被读成语言码 "cn"
  case "$stem" in
    *-r[a-z][a-z])
      L=$(printf '%s' "$stem" | sed -n 's/^\([a-z][a-z]\)-r[a-z][a-z]$/\1/p')
      [ -n "$L" ] || L=$(printf '%s' "$stem" | sed -n 's/.*[^a-z]\([a-z][a-z]\)-r[a-z][a-z]$/\1/p')
      [ -n "$L" ] || L=$(printf '%s' "$stem" | sed -n 's/.*-r\([a-z][a-z]\)$/\1/p')
      if [ -n "$L" ]; then
        # token 里保留区域码（zh-cn）：只在"语言"这一层比较，会让 base-zh 和
        # base-zh-rCN 同时命中，同一语言装两份资源；带上区域才能按精度挑一个
        R=$(printf '%s' "$stem" | sed -n 's/.*-r\([a-z][a-z]\)$/\1/p')
        CKIND="lang"
        if [ -n "$R" ] && [ "$R" != "$L" ]; then CTOK="$L-$R"; else CTOK="$L"; fi
        return
      fi
      ;;
  esac
  # <lang>-<script|region>（base-zh-hans / config.pt-br）：token 保留完整标签。
  # 旧代码只取语言码，于是 base-zh 与 base-zh-hans 的 token 都是 zh，两个都选；
  # 而且 region 只有 2 个字母（pt-br）时旧模式 [a-z][a-z][a-z]* 根本不匹配，
  # 会掉到"末段两字母"分支变成 token=br，该语言分片永远选不上。
  case "$stem" in
    *-[a-z][a-z]-[a-z][a-z][a-z][a-z]|*-[a-z][a-z]-[a-z][a-z])
      L=$(printf '%s' "$stem" | sed -n 's/.*[^a-z]\([a-z][a-z]-[a-z0-9][a-z0-9]*\)$/\1/p')
      [ -n "$L" ] && { CKIND="lang"; CTOK="$L"; return; }
      ;;
  esac
  # 末段两字母（base-en / split_config.zh）
  last=${stem##*.}; last=${last##*-}
  case "$last" in
    [a-z][a-z]) CKIND="lang"; CTOK="$last"; return;;
  esac
}

# ---------------------------------------------------------------- 元信息

# ---------------------------------------------------------------- 二进制 Manifest
#
# 为什么自己解析 AXML：KernelSU 模块环境里没有 aapt/aapt2，也不该要求用户装。
# AndroidManifest.xml 是结构化的二进制 XML（chunk 表 + 字符串池 + 属性表），
# 按十六进制字节读一遍就能拿到权威的 package / versionCode / versionName /
# minSdkVersion / targetSdkVersion —— 比 strings 猜包名可靠得多。
# 注意：LC_ALL=C 已在上方导出，保证 awk 的 sprintf("%c",n) 输出单字节。

# od 的藏身处各 ROM 不同，逐个试（od 读的是文件，失败了可以重试，不会吃掉 stdin）
hex_file() { # $1 = 文件；stdout = 十六进制字节
  HF="$1"; HOUT="$TMP/.hx"
  for c in "od" "busybox od" "toybox od"; do
    set -- $c
    command -v "$1" >/dev/null 2>&1 || continue
    $c -An -tx1 -v "$HF" > "$HOUT" 2>/dev/null
    if [ -s "$HOUT" ]; then cat "$HOUT"; rm -f "$HOUT"; return 0; fi
  done
  rm -f "$HOUT"
  return 1
}

# AXML 十六进制流 -> "pkg|versionName|versionCode|minSdk|targetSdk|label|label_ref|icon_ref"
# label 只在 android:label 是字面量字符串时才给；label_ref / icon_ref 是资源引用
# （@7f110050 这种）去掉 @ 之后的 8 位十六进制 ID，由 resources.arsc 解析成
# 真正的应用名 / 图标文件（v1.3.3）。
axml_meta() {
  awk '
  function b8(o) { return HX[b[o+1]] }
  function u16(o) { return b8(o) + 256*b8(o+1) }
  function u32(o) { return b8(o) + 256*b8(o+1) + 65536*b8(o+2) + 16777216*b8(o+3) }
  function u8(o) { return sprintf("%c", b8(o)) }
  function utf8c(c) {
    if (c < 128) return sprintf("%c", c)
    if (c < 2048) return sprintf("%c%c", 192+int(c/64), 128+c%64)
    if (c < 65536) return sprintf("%c%c%c", 224+int(c/4096), 128+int(c/64)%64, 128+c%64)
    return sprintf("%c%c%c%c", 240+int(c/262144), 128+int(c/4096)%64, 128+int(c/64)%64, 128+c%64)
  }
  function tval(dt, da) {
    if (dt==1) return "@" sprintf("%x", da)
    if (dt==2) return "?" sprintf("%x", da)
    if (dt==3 || dt==4 || dt==5 || dt==6) return S[da]
    if (dt==16) return sprintf("%.0f", da)
    if (dt==17) return sprintf("%.0f", da)   # versionCode/min/target 一律十进制
    if (dt==18) return (da!=0 ? "true" : "false")
    return ""
  }
  function parse_pool(p,   cnt,fl,so,i,j,q,ln,bl,k,c,c2,s2) {
    cnt=u32(p+8); fl=u32(p+16); so=u32(p+20)
    utf8=(int(fl/256)%2==1)
    for (i=0;i<cnt;i++) {
      q=p+so+u32(p+28+4*i); ln=0; k=0; s2=""
      if (q>nb) { S[i]=""; continue }
      if (utf8) {
        # AOSP 的 UTF-8 池条目带两个长度前缀：先是 UTF-16 码元数，再是 UTF-8
        # 字节数（各自 1 字节，>=0x80 时两字节，最大 15 位）。旧代码把第一个
        # 前缀当成字节数、又从 q+1 开始读到 NUL，字符串前面会多出一个长度
        # 字节（包名直接失效），所以 UTF-8 池的 manifest 全部解析不出东西。
        ln=b8(q); k=1
        if (ln>=128) { ln=(ln-128)*256+b8(q+1); k=2 }
        bl=b8(q+k); k++
        if (bl>=128) { bl=(bl-128)*256+b8(q+k); k++ }
        for (j=0;j<bl;j++) { c=b8(q+k+j); if (c==0) break; s2 = s2 u8(q+k+j) }
      } else {
        ln=u16(q); k=2
        if (ln>=32768) { ln=(ln-32768)*65536+u16(q+2); k=4 }
        for (j=0;j<ln;j++) {
          c=u16(q+k+2*j)
          if (c>=55296 && c<=56319 && j+1<ln) {
            c2=u16(q+k+2*j+2)
            if (c2>=56320 && c2<=57343) { c=65536+(c-55296)*1024+(c2-56320); j++ }
          }
          s2 = s2 utf8c(c)
        }
      }
      S[i]=s2
    }
  }
  function parse_elem(p,   a,i,ac,as,an,av,rv,r0,dt,da,nm) {
    # attributeStart 是"相对 attrExt 结构体"的偏移，而 attrExt 紧跟 16 字节
    # 的 ResXMLTree_node 头（p+8 起是 lineNumber/comment），所以属性表在
    # p + 16 + attributeStart（标准值 0x14 → p+36）。
    ac=u16(p+28); as=u16(p+26); a=p+16+u16(p+24); nm=S[u32(p+20)]
    if (as<=0) return
    for (i=0;i<ac;i++) {
      an=S[u32(a+i*as+4)]; rv=u32(a+i*as+8)
      r0=b8(a+i*as+14); dt=b8(a+i*as+15); da=u32(a+i*as+16)
      av=(rv!=4294967295) ? S[rv] : tval(dt,da)
      if (nm=="manifest") {
        if (an=="package") PKG=av
        else if (an=="versionCode") VCODE=av
        else if (an=="versionName") VNAME=av
      } else if (nm=="uses-sdk") {
        if (an=="minSdkVersion") MINAPI=av
        else if (an=="targetSdkVersion") TGTAPI=av
      } else if (nm=="application") {
        # android:label 是字面量就用；是资源引用（REFERENCE/ATTRIBUTE）就只记下 ID，
        # 交给 resources.arsc 解析（v1.3.3），不要把 @7f110050 当应用名显示。
        if (an=="label") {
          if (rv!=4294967295 || dt==3) LBL=av
          else if (dt==1 || dt==2) LREF=sprintf("%08x", da)
        } else if (an=="icon") {
          if (rv==4294967295 && (dt==1 || dt==2)) IREF=sprintf("%08x", da)
        }
      }
    }
    if (nm=="application") sawapp=1
    if (nm=="manifest" || nm=="uses-sdk" || nm=="application") {
      if (PKG!="" && VCODE!="" && MINAPI!="" && TGTAPI!="" && sawapp) done=1
    }
  }
  BEGIN { for (i=0;i<256;i++) { h=sprintf("%02x",i); HX[h]=i; HX[toupper(h)]=i } }
  { for (i=1;i<=NF;i++) b[++nb]=$i }
  END {
    if (nb<8) exit 1
    if (u16(0)!=3) exit 1
    p=8
    while (p+8<=nb && !done) {
      t=u16(p); cs=u32(p+4)
      if (cs<=0 || p+cs>nb) break
      if (t==1) parse_pool(p)
      else if (t==258) parse_elem(p)
      else if (t==257) break
      p+=cs
    }
    if (PKG=="" && VCODE=="" && MINAPI=="" && TGTAPI=="" && LBL=="" && LREF=="" && IREF=="") exit 1
    printf "%s|%s|%s|%s|%s|%s|%s|%s\n", PKG, VNAME, VCODE, MINAPI, TGTAPI, LBL, LREF, IREF
  }'
}

axml_meta_of() { # $1 = AXML 文件；stdout = 元信息行
  L=$(hex_file "$1" | axml_meta)
  [ -n "$L" ] || return 1
  printf '%s' "$L"
}

# 把 "pkg|versionName|versionCode|minSdk|targetSdk|label|label_ref|icon_ref" 填进 META_*。
# 基础包里的 manifest 是权威来源：可以覆盖 toc.pb 的猜测，但不会覆盖 info.json。
# label_ref / icon_ref 只是资源 ID，等 probe_icon 阶段查 resources.arsc 才有结果。
apkmeta_apply() { # $1 = 元信息行
  AKP=$(printf '%s' "$1" | cut -d'|' -f1)
  AKV=$(printf '%s' "$1" | cut -d'|' -f2)
  AKC=$(printf '%s' "$1" | cut -d'|' -f3)
  AKN=$(printf '%s' "$1" | cut -d'|' -f4)
  AKG=$(printf '%s' "$1" | cut -d'|' -f5)
  AKL=$(printf '%s' "$1" | cut -d'|' -f6)
  AKR=$(printf '%s' "$1" | cut -d'|' -f7)
  AKI=$(printf '%s' "$1" | cut -d'|' -f8)
  [ -n "$AKR" ] && META_LABEL_REF="$AKR"
  [ -n "$AKI" ] && META_ICON_REF="$AKI"
  case "$META_PKG_SRC" in
    ""|none|toc.pb|"toc.pb(guess)")
      if [ -n "$AKP" ]; then META_PKG="$AKP"; META_PKG_SRC="manifest"; fi;;
  esac
  if [ -z "$META_VERSION" ] && [ -n "$AKV" ]; then META_VERSION="$AKV"; fi
  if [ -z "$META_VCODE" ] && [ -n "$AKC" ]; then META_VCODE="$AKC"; fi
  if [ -z "$META_MINAPI" ] && [ -n "$AKN" ]; then META_MINAPI="$AKN"; fi
  if [ -z "$META_TGTAPI" ] && [ -n "$AKG" ]; then META_TGTAPI="$AKG"; fi
  if [ -z "$META_LABEL" ] && [ -n "$AKL" ]; then META_LABEL="$AKL"; META_LABEL_SRC="manifest"; fi
}

# 从磁盘上的 APK 文件读 manifest（要求 $UNZIP 能列出并解压它）
meta_from_apk_file() { # $1 = apk 路径
  AKT="$TMP/.apk_table"; AKX="$TMP/.axml"
  zip_table "$1" > "$AKT" 2>/dev/null
  AKM=$(awk -F'\t' 'tolower($2) == "androidmanifest.xml" { print $2; exit }' "$AKT")
  if [ -z "$AKM" ]; then rm -f "$AKT"; return 1; fi
  $UNZIP -p "$1" "$AKM" 2>/dev/null | head -c "$AXML_MAX_BYTES" > "$AKX" 2>/dev/null
  rm -f "$AKT"
  if [ ! -s "$AKX" ]; then rm -f "$AKX"; return 1; fi
  AKL=$(axml_meta_of "$AKX")
  rm -f "$AKX"
  [ -n "$AKL" ] || return 1
  apkmeta_apply "$AKL"
}

# 从 bundle 里的基础包读 manifest。基础包过大就跳过，避免在 /data 里解出几百 MB。
meta_from_base() {
  [ -n "$BASE_NAME" ] && [ -n "$UNZIP" ] || return 1
  BBSZ=$(tbl_get "$BASE_NAME" "$TBL"); [ -n "$BBSZ" ] || BBSZ=0
  awk -v s="$BBSZ" -v m="$APKMT_BASE_META_MAX" 'BEGIN{ exit !(s+0 > m+0) }' && return 1
  BBA="$TMP/.base.apk"
  $UNZIP -p "$BUNDLE" "$BASE_NAME" > "$BBA" 2>/dev/null
  if [ ! -s "$BBA" ]; then rm -f "$BBA"; return 1; fi
  # 留着这个文件：probe_icon 还要在它里面找 res/mipmap 图标，别为一张图再解一次
  BASE_APK_FILE="$BBA"
  meta_from_apk_file "$BBA"
  BBR=$?
  [ "$BBR" = 0 ] || { rm -f "$BBA"; BASE_APK_FILE=""; }
  return $BBR
}

# toc.pb（bundletool 的 BuildApksResult）第一个字段就是 package_name：
# protobuf 线格式 tag=0x0A（field 1, length-delimited）+ varint 长度 + 字符串。
# 旧实现用 strings 捞包名，还把 org.*/android.* 开头的真包名当噪声滤掉了。
tocpb_pkg() {
  [ -n "$UNZIP" ] || return 1
  TPF="$TMP/.toc.pb"
  $UNZIP -p "$BUNDLE" toc.pb 2>/dev/null | head -c 65536 > "$TPF" 2>/dev/null
  if [ ! -s "$TPF" ]; then rm -f "$TPF"; return 1; fi
  P=$(hex_file "$TPF" | awk '
    function b8(o) { return HX[b[o+1]] }
    BEGIN { for (i=0;i<256;i++) { h=sprintf("%02x",i); HX[h]=i; HX[toupper(h)]=i } }
    { for (i=1;i<=NF;i++) b[++n]=$i }
    END {
      if (n<4) exit 1
      if (b8(0)!=10) exit 1
      L=0; sh=1; p=1
      while (p<=n) { c=b8(p); p++; L+=(c%128)*sh; sh*=128; if (c<128) break }
      if (L<=0 || p+L-1>n) exit 1
      s=""
      for (i=0;i<L;i++) s = s sprintf("%c", b8(p+i))
      if (s !~ /^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+$/) exit 1
      print s
    }')
  rm -f "$TPF"
  [ -n "$P" ] || return 1
  printf '%s' "$P"
}

# JSON 里的第一个字符串字段（$2 只允许字母/下划线）。
# 不用 sed 的贪婪 .*"key"：manifest.json 被 tr 压成一行后，贪婪匹配取到的是
# **最后一个**同名键（XAPK 的 split_apks 数组里也常有 name），拿错应用名/丢掉
# 应用名都可能是它；grep -o 从左到右取第一个。
jstr() {
  printf '%s' "$1" | grep -o "\"$2\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" 2>/dev/null \
    | head -n 1 | sed 's/^[^:]*:[[:space:]]*"//; s/"$//'
}

# JSON 数字字段（允许带引号：XAPK 的 version_code 常写成 "2000051"）
jnum() {
  printf '%s' "$1" | grep -o "\"$2\"[[:space:]]*:[[:space:]]*\"*[0-9][0-9]*" 2>/dev/null \
    | head -n 1 | sed 's/^[^:]*:[[:space:]]*"*//'
}

# 还原 JSON 转义：\uXXXX（含代理对）以及 \" \\ \/ \n \t \r。
# LC_ALL=C 保证 sprintf("%c",n) 输出单字节，多字节字符按原字节透传。
junesc() {
  printf '%s' "$1" | awk '
  function hx(c) { return index("0123456789abcdef", tolower(c)) - 1 }
  function esc4(s) { return hx(substr(s,1,1))*4096 + hx(substr(s,2,1))*256 + hx(substr(s,3,1))*16 + hx(substr(s,4,1)) }
  function u8(c) {
    if (c < 128) return sprintf("%c", c)
    if (c < 2048) return sprintf("%c%c", 192+int(c/64), 128+c%64)
    if (c < 65536) return sprintf("%c%c%c", 224+int(c/4096), 128+int(c/64)%64, 128+c%64)
    return sprintf("%c%c%c%c", 240+int(c/262144), 128+int(c/4096)%64, 128+int(c/64)%64, 128+c%64)
  }
  function is4(s) { return substr(s,1,1) ~ /[0-9A-Fa-f]/ && substr(s,2,1) ~ /[0-9A-Fa-f]/ && substr(s,3,1) ~ /[0-9A-Fa-f]/ && substr(s,4,1) ~ /[0-9A-Fa-f]/ }
  {
    s = $0; out = ""
    while (length(s) > 0) {
      if (substr(s,1,2) == "\\u" && is4(substr(s,3,4))) {
        c = esc4(substr(s,3,4)); s = substr(s,7)
        if (c >= 55296 && c <= 56319 && substr(s,1,2) == "\\u" && is4(substr(s,3,4))) {
          d = esc4(substr(s,3,4)); s = substr(s,7)
          c = 65536 + (c-55296)*1024 + (d-56320)
        }
        out = out u8(c); continue
      }
      ch = substr(s,1,1); s = substr(s,2)
      if (ch == "\\") {
        nx = substr(s,1,1); s = substr(s,2)
        if (nx == "n" || nx == "t" || nx == "r") continue
        out = out nx; continue
      }
      out = out ch
    }
    printf "%s", out
  }'
}

meta_from_json() {
  J="$1"
  SRC="${2:-info.json}"
  V=$(jstr "$J" pname)
  [ -n "$V" ] || V=$(jstr "$J" package_name)
  [ -n "$V" ] && { META_PKG="$V"; META_PKG_SRC="$SRC"; }

  V=$(jstr "$J" release_version)
  [ -n "$V" ] || V=$(jstr "$J" version_name)
  [ -n "$V" ] && META_VERSION="$V"

  V=$(jnum "$J" versioncode)
  [ -n "$V" ] || V=$(jnum "$J" version_code)
  [ -n "$V" ] && META_VCODE="$V"

  V=$(jnum "$J" min_api)
  [ -n "$V" ] || V=$(jnum "$J" min_sdk_version)
  [ -n "$V" ] && META_MINAPI="$V"

  V=$(jnum "$J" target_api)
  [ -n "$V" ] || V=$(jnum "$J" target_sdk_version)
  [ -n "$V" ] && META_TGTAPI="$V"

  V=$(jstr "$J" name)
  [ -n "$V" ] || V=$(jstr "$J" app_name)
  [ -n "$V" ] || V=$(jstr "$J" apk_title)
  [ -n "$V" ] || V=$(jstr "$J" release_title)
  if [ -n "$V" ]; then
    # 解转义后再剔掉 | 和控制字符：META 记录是"竖线分隔、一行一条"，
    # 应用名里出现换行/竖线会把整条流切错。（junesc 是"参数进、stdout 出"）
    V=$(junesc "$V" | tr -d '\r\n\t|')
    [ -n "$V" ] && { META_LABEL="$V"; META_LABEL_SRC="json"; }
  fi
}

meta_from_bundle() {
  # 1) info.json / manifest.json / meta.json（APKMirror 的 .apkm、APKPure 的 .xapk）
  METAFILE=$(awk -F'\t' 'tolower($2) ~ /(^|\/)(info|manifest|meta)\.json$/ { print $2; exit }' "$TBL")
  if [ -n "$METAFILE" ]; then
    # 上限 256KB：XAPK 的 manifest.json 会列 split_apks/permissions，大包可能几十 KB，
    # 旧的 64KB 截断会把排在后面的 name/version 直接切掉（真机"没有应用名"的可疑原因）。
    J=$($UNZIP -p "$BUNDLE" "$METAFILE" 2>/dev/null | tr '\n' ' ' | head -c 262144)
    meta_from_json "$J" "$(basename "$METAFILE")"
  fi
  # JSON 里五项都齐了就不用再解基础包（省一次解压）
  if [ -n "$META_PKG" ] && [ -n "$META_VERSION" ] && [ -n "$META_VCODE" ] \
     && [ -n "$META_MINAPI" ] && [ -n "$META_TGTAPI" ]; then
    return 0
  fi
  # 2) 基础包里的 AndroidManifest.xml：权威来源，补齐 JSON 缺的字段
  meta_from_base
  [ -n "$META_PKG" ] && return 0
  # 3) toc.pb（bundletool/SAI 的 .apks）：结构化读 package_name 字段
  if awk -F'\t' 'tolower($2) == "toc.pb" { f=1 } END { exit !f }' "$TBL"; then
    C=$(tocpb_pkg)
    [ -n "$C" ] && { META_PKG="$C"; META_PKG_SRC="toc.pb"; return 0; }
    # 4) 兜底：strings 猜（toc.pb 结构与预期不符时）。注意 org.* / com.* 都可能是
    #    真包名，只排除明确的库命名空间，并且不要带下划线的候选（资源/符号名）。
    C=$($UNZIP -p "$BUNDLE" toc.pb 2>/dev/null | strings 2>/dev/null \
        | grep -E '^[a-z][a-z0-9_]*(\.[a-z0-9_]+)+$' \
        | grep -vE '^(android|androidx|java|javax|kotlin|dalvik|bundletool)(\.|$)' \
        | grep -vE '^com\.android(\.|$)' | grep -vE '^com\.google\.android(\.|$)' \
        | grep -v '_' | head -1)
    [ -n "$C" ] && { META_PKG="$C"; META_PKG_SRC="toc.pb(guess)"; }
  fi
  return 0
}

# ---------------------------------------------------------------- 包内图标（v1.3.2）
#
# 预装阶段 ksu://icon/<pkg> 拿不到图（应用还没装进系统），用户看到的就是一片
# 空白/字母。所以从 bundle 里把图标图挖出来，落到 <模块>/webroot/icon-cache/，
# 前端用相对 URL 显示（WebUI 资源加载器按目录映射 webroot）。
# 优先级：xapk/apkm 根目录的 icon.png（APKPure/APKMirror 规范）> 基础 APK 里
# res/mipmap* 的启动图标 > 放弃（前端回退到 ksu://icon / 字母）。
# 安全：目标文件名只由包名净化得到，绝不使用 zip 里的条目名做路径，杜绝 ../ 穿越。

hex_head() { # $1=文件 $2=字节数；stdout=小写十六进制
  HRF="$1"; HRN="$2"; HHF="$TMP/.hh"
  head -c "$HRN" "$HRF" 2>/dev/null > "$HHF" 2>/dev/null
  if [ ! -s "$HHF" ]; then rm -f "$HHF"; return 1; fi
  HHO=$(od -An -tx1 -v "$HHF" 2>/dev/null | tr -d ' \n\t\r')
  [ -n "$HHO" ] || HHO=$(busybox od -An -tx1 -v "$HHF" 2>/dev/null | tr -d ' \n\t\r')
  [ -n "$HHO" ] || HHO=$(toybox od -An -tx1 -v "$HHF" 2>/dev/null | tr -d ' \n\t\r')
  rm -f "$HHF"
  [ -n "$HHO" ] || return 1
  printf '%s' "$HHO"
}

# 只认真正的图片：大小合理 + 魔数对（PNG/JPEG/GIF/WEBP）
img_ok() {
  IMO="$1"
  [ -f "$IMO" ] || return 1
  IMS=$(stat -c %s "$IMO" 2>/dev/null); [ -n "$IMS" ] || return 1
  [ "$IMS" -ge 128 ] 2>/dev/null || return 1
  [ "$IMS" -lt 2097152 ] 2>/dev/null || return 1
  IMW=$(hex_head "$IMO" 12) || return 1
  case "$IMW" in
    89504e470d0a1a0a*) return 0;;             # PNG
    ffd8ff*) return 0;;                       # JPEG
    47494638*) return 0;;                     # GIF
    52494646????????57454250*) return 0;;     # RIFF....WEBP
  esac
  return 1
}

# 外层 zip 根目录/一层的 icon.*（xapk、apkm 的规范位置）
icon_entry_root() {
  [ -s "$TBL" ] || return 1
  awk -F'\t' '
    BEGIN { best = ""; bs = -1 }
    {
      n = $2; low = tolower(n)
      base = low; sub(/.*\//, "", base)
      if (base !~ /^icon\.(png|webp|jpg|jpeg)$/) next
      d = n; gsub(/[^\/]/, "", d)
      if (length(d) > 1) next
      s = $1 + 0
      if (s > bs) { bs = s; best = n }
    }
    END { if (best != "") print best }' "$TBL"
}

# APK 条目表里挑启动图标：res/mipmap* 优先，其次 drawable*；名字像 launcher/icon
# 的位图优先，同分取高密度、再取大文件。自适应图标的前景/背景层与通知图标剔除。
icon_entry_apk() {
  [ -s "$1" ] || return 1
  awk -F'\t' '
    function dens(p,  d) {
      d = 0
      if (p ~ /xxxhdpi/) d = 6
      else if (p ~ /xxhdpi/) d = 5
      else if (p ~ /xhdpi/) d = 4
      else if (p ~ /hdpi/) d = 3
      else if (p ~ /mdpi/) d = 2
      else if (p ~ /ldpi/) d = 1
      return d
    }
    BEGIN { best = ""; bs = -1; bz = -1 }
    {
      n = $2; low = tolower(n)
      if (low !~ /\.(png|webp)$/) next
      if (low !~ /(^|\/)res\//) next
      base = low; sub(/.*\//, "", base)
      if (base ~ /(foreground|background|notification|splash|banner|logo|adaptive)/) next
      nm = 0
      if (base ~ /ic_launcher/) nm = 10
      else if (base ~ /icon/) nm = 9
      else if (base ~ /launcher/) nm = 8
      else if (base ~ /^ic_/) nm = 6
      else next
      mp = (low ~ /(^|\/)res\/mipmap/) ? 400 : 0
      sc = mp + nm * 20 + dens(low) * 3
      if (base ~ /round/) sc -= 2
      s = $1 + 0
      if (sc > bs || (sc == bs && s > bz)) { bs = sc; bz = s; best = n }
    }
    END { if (best != "") print best }' "$1"
}

# 把某个 zip 里的条目落成 icon-cache 下的图片文件；成功则写好 ICON_REL/ICON_SRC
icon_install() { # $1=zip 文件  $2=条目名  $3=来源标记
  [ -n "$UNZIP" ] || return 1
  [ -n "$ICON_DIR" ] || return 1
  IIF="$TMP/.icon.bin"
  $UNZIP -p "$1" "$2" 2>/dev/null | head -c 2097152 > "$IIF" 2>/dev/null
  if ! img_ok "$IIF"; then rm -f "$IIF"; return 1; fi
  IEXT=$(printf '%s' "$2" | sed 's/.*\.//' | tr 'A-Z' 'a-z')
  case "$IEXT" in
    png|gif|webp) ;;
    jpg|jpeg) IEXT="jpg";;
    *) IEXT="png";;
  esac
  ISAFE=$(printf '%s' "$META_PKG" | sed 's/[^A-Za-z0-9._-]/_/g' | cut -c1-96)
  [ -n "$ISAFE" ] || ISAFE="bundle"
  case "$ISAFE" in .|..) ISAFE="bundle";; esac
  ITMP="$ICON_DIR/.tmp.$$.$IEXT"
  if ! cp "$IIF" "$ITMP" 2>/dev/null; then rm -f "$IIF"; return 2; fi
  rm -f "$IIF"
  # 同目录 rename 是原子的：并发跑两次 inspect 也只会看到完整文件
  if ! mv -f "$ITMP" "$ICON_DIR/$ISAFE.$IEXT" 2>/dev/null; then
    rm -f "$ITMP"
    return 2
  fi
  ITS=$(date +%s 2>/dev/null); [ -n "$ITS" ] || ITS=0
  ICON_REL="icon-cache/$ISAFE.$IEXT?v$ITS"
  ICON_SRC="$3"
  return 0
}

# 缓存只留最近 40 张，避免长期使用后 webroot 里堆一堆历史图标
prune_icons() {
  [ -n "$ICON_DIR" ] || return 0
  ls -t "$ICON_DIR" 2>/dev/null | sed -n '41,$p' > "$TMP/.oldico" 2>/dev/null || return 0
  while IFS= read -r IPF; do
    case "$IPF" in ""|*/*|.*) continue;; esac
    rm -f "$ICON_DIR/$IPF"
  done < "$TMP/.oldico"
  rm -f "$TMP/.oldico"
}

# ------------------------------------------------ 资源表解析（resources.arsc，v1.3.3）
#
# Android 的 android:label / android:icon 基本都是资源引用（@string/app_name、
# @mipmap/ic_launcher），manifest 里只有资源 ID。真正的应用名和图标文件只有
# resources.arsc 知道，所以这里实现一个"只取指定资源 ID"的读取器：
#   - 解析全局字符串池（UTF-8 与 UTF-16 两种编码）
#   - 遍历 package / type 块，按 entryIndex 命中目标条目
#   - 偏移表三种排布都支持：普通 uint32、FLAG_SPARSE（稀疏索引）、FLAG_OFFSET16
#   - 值类型：字符串 / 引用 / 颜色(ARGB8,RGB8,ARGB4,RGB4) / 浮点 / 整数 / 布尔
# 同一 ID 可能有多个 density 变体，arsc_pick 按设备当前密度用 AOSP 的
# ResTable_config::isBetterThan 规则挑选（与系统资源匹配算法一致）。
#
# 矢量图标（VectorDrawable）无法直接当图片用，这里把它和它的组变换、描边、
# 渐变一起翻译成 SVG；自适应图标（API 26+）的 background/foreground 两层分别
# 翻译，前端叠起来显示（背景层铺满、前景层放大 1.5 倍并裁掉四周 18dp 出血）。

arsc_lookup() { # $1 = 逗号分隔资源 ID（8 位十六进制，可带 0x）；stdin = arsc 十六进制
  awk -v ids="$1" '
  function b8(o) { return HX[substr(H, 2*o+1, 2)] }
  function u16(o) { return b8(o) + 256*b8(o+1) }
  function u32(o) { return b8(o) + 256*b8(o+1) + 65536*b8(o+2) + 16777216*b8(o+3) }
  function u8(o) { return sprintf("%c", b8(o)) }
  function utf8c(c) {
    if (c < 128) return sprintf("%c", c)
    if (c < 2048) return sprintf("%c%c", 192+int(c/64), 128+c%64)
    if (c < 65536) return sprintf("%c%c%c", 224+int(c/4096), 128+int(c/64)%64, 128+c%64)
    return sprintf("%c%c%c%c", 240+int(c/262144), 128+int(c/4096)%64, 128+int(c/64)%64, 128+c%64)
  }
  function f32(v,   s,e,m) {
    if (v == 0) return "0"
    s = 1
    if (int(v/2147483648) == 1) { s = -1; v = v - 2147483648 }
    e = int(v/8388608); m = v - e*8388608
    if (e == 255) return "nan"
    if (e == 0) return numstr(s * (m/8388608) * 0.000000000000000000000000000000000000011754943508222875)
    return numstr(s * (1 + m/8388608) * (2 ^ (e - 127)))
  }
  function numstr(x) {
    if (x == int(x) && x < 1e15 && x > -1e15) return sprintf("%.0f", x)
    return sprintf("%.6f", x)
  }
  function cssc(dt, da,   a,r,g,b) {
    if (dt == 28) {
      a = int(da/16777216)%256; r = int(da/65536)%256; g = int(da/256)%256; b = da%256
      if (a == 255) return sprintf("#%02x%02x%02x", r, g, b)
      return sprintf("rgba(%d,%d,%d,%.3f)", r, g, b, a/255)
    }
    if (dt == 29) { r = int(da/65536)%256; g = int(da/256)%256; b = da%256
                    return sprintf("#%02x%02x%02x", r, g, b) }
    if (dt == 30) { a = int(da/4096)%256; r = int(da/256)%16; g = int(da/16)%16; b = da%16
                    a = a*17; r = r*17; g = g*17; b = b*17
                    if (a == 255) return sprintf("#%02x%02x%02x", r, g, b)
                    return sprintf("rgba(%d,%d,%d,%.3f)", r, g, b, a/255) }
    if (dt == 31) { r = int(da/256)%16; g = int(da/16)%16; b = da%16
                    return sprintf("#%02x%02x%02x", r*17, g*17, b*17) }
    return ""
  }
  function gstr(i,   o,q,ln,bl,k,j,c,c2,s2) {
    if (i in GS) return GS[i]
    if (i < 0 || i >= UCNT) { GS[i] = ""; return "" }
    o = u32(UOFF + 4*i); q = US0 + o; s2 = ""
    if (q > nb) { GS[i] = ""; return "" }
    if (UTF8) {
      ln = b8(q); k = 1
      if (ln >= 128) { ln = (ln-128)*256 + b8(q+1); k = 2 }
      bl = b8(q+k); k++
      if (bl >= 128) { bl = (bl-128)*256 + b8(q+k); k++ }
      for (j = 0; j < bl; j++) { c = b8(q+k+j); if (c == 0) break; s2 = s2 u8(q+k+j) }
    } else {
      ln = u16(q); k = 2
      if (ln >= 32768) { ln = (ln-32768)*65536 + u16(q+2); k = 4 }
      for (j = 0; j < ln; j++) {
        c = u16(q+k+2*j)
        if (c >= 55296 && c <= 56319 && j+1 < ln) {
          c2 = u16(q+k+2*j+2)
          if (c2 >= 56320 && c2 <= 57343) { c = 65536 + (c-55296)*1024 + (c2-56320); j++ }
        }
        s2 = s2 utf8c(c)
      }
    }
    GS[i] = s2
    return s2
  }
  function valstr(dt, da) {
    if (dt == 3) return "S:" gstr(da)
    if (dt == 1 || dt == 7) return "R:" sprintf("%08x", da)
    if (dt == 28 || dt == 29 || dt == 30 || dt == 31) return "C:" cssc(dt, da)
    if (dt == 4) return "F:" f32(da)
    if (dt == 16 || dt == 17) return "I:" sprintf("%.0f", da)
    if (dt == 18) return "I:" (da != 0 ? "1" : "0")
    return "X:" dt ":" da
  }
  function scan_type(q, tid,   cnt,estart,flags,cfg,csz,dens,isdef,obase,ei,eo,off,e,esize,ef,v,dt,da,oflag,j,k) {
    flags = b8(q+9); cnt = u32(q+12); estart = u32(q+16)
    cfg = q + 20; csz = u32(cfg)
    dens = (csz >= 16) ? u16(cfg+14) : 0
    # 默认配置 = 除 density 外所有字段为 0（夜间模式、locale、uiMode 都在更后面，
    # 旧实现只看前 16 字节，会把 values-night 里的颜色当成默认色）
    isdef = 1
    if (dens != 0) isdef = 0
    for (j = 4; j < csz && isdef; j++) {
      if (j == 14 || j == 15) continue
      if (b8(cfg+j) != 0) isdef = 0
    }
    oflag = flags - int(flags/4)*4
    obase = q + u16(q+2)
    for (j = 1; j <= WN[tid]; j++) {
      ei = WE[tid, j]
      if (ei < 0) continue
      eo = -1
      if (oflag >= 2) {
        if (ei < cnt) { off = u16(obase + 2*ei); eo = (off == 65535) ? -1 : off*4 }
      } else if (oflag == 1) {
        for (k = 0; k < cnt; k++) {
          if (u16(obase + 4*k) == ei) { eo = u16(obase + 4*k + 2)*4; break }
        }
      } else {
        if (ei < cnt) { off = u32(obase + 4*ei); eo = (off == 4294967295) ? -1 : off }
      }
      if (eo < 0) continue
      e = q + estart + eo
      if (e + 8 > nb) continue
      esize = u16(e); ef = u16(e+2)
      if (ef - int(ef/2)*2 == 1) continue
      if (esize <= 0) esize = 8
      v = e + esize
      dt = b8(v+3); da = u32(v+4)
      printf "%s|%d|%d|%s\n", WID[tid, j], dens, isdef, valstr(dt, da)
    }
  }
  BEGIN {
    for (i = 0; i < 256; i++) { h = sprintf("%02x", i); HX[h] = i; HX[toupper(h)] = i }
    for (i = 0; i < 16; i++) { h = sprintf("%x", i); HD[h] = i; HD[toupper(h)] = i }
    nids = split(ids, IDS, ",")
    for (i = 1; i <= nids; i++) {
      s = IDS[i]; sub(/^0x/, "", s); s = tolower(s)
      v = 0
      for (j = 1; j <= length(s); j++) v = v*16 + HD[substr(s, j, 1)]
      tid = int(v/65536) % 256; ei = v % 65536
      WID[tid, ++WN[tid]] = s
      WE[tid, WN[tid]] = ei
    }
  }
  { H = H $0 }
  END {
    nb = length(H) / 2
    if (nb < 16) exit 1
    if (u16(0) != 2) exit 1
    p = u16(2)
    if (u16(p) != 1) exit 1
    UCNT = u32(p+8); UTF8 = (int(u32(p+16)/256) % 2 == 1)
    US0 = p + u32(p+20); UOFF = p + 28
    p = p + u32(p+4)
    while (p + 8 <= nb) {
      t = u16(p); cs = u32(p+4)
      if (cs <= 0 || p + cs > nb) break
      if (t == 512) {
        phsz = u16(p+2); q = p + phsz; pend = p + cs
        while (q + 8 <= pend) {
          ct = u16(q); ccs = u32(q+4)
          if (ccs <= 0) break
          if (ct == 513) {
            tid = b8(q+8)
            if (tid in WN) scan_type(q, tid)
          }
          q = q + ccs
        }
      }
      p = p + cs
    }
  }'
}

# 从 APK 里查资源 ID；stdout = 每行 "<id>|<density>|<isdefault>|<value>"
arsc_get() { # $1 = apk 文件  $2 = 逗号分隔的 8 位十六进制 ID
  AGP="$1"; AGI="$2"
  [ -n "$AGP" ] && [ -f "$AGP" ] && [ -n "$UNZIP" ] && [ -n "$AGI" ] || return 1
  # 一次 inspect 里 resources.arsc 可能被查 2~3 次（应用名、图标、图标的渐变填充），
  # 而六倍体积的十六进制文本很贵：同一个 APK 只解一次、只转一次，之后复用缓存。
  AGH="$TMP/.arsc.hx"
  if [ ! -s "$AGH" ] || [ "${AGRSC_SRC:-}" != "$AGP" ]; then
    AGT="$TMP/.arsctbl"; AGB="$TMP/.arsc"
    zip_table "$AGP" > "$AGT" 2>/dev/null
    AGS=$(awk -F'\t' 'tolower($2) == "resources.arsc" { print $1; exit }' "$AGT")
    rm -f "$AGT"
    [ -n "$AGS" ] || return 1
    awk -v s="$AGS" -v m="$ARSC_MAX_BYTES" 'BEGIN{ exit !(s+0 > m+0) }' && return 1
    $UNZIP -p "$AGP" resources.arsc 2>/dev/null | head -c "$ARSC_MAX_BYTES" > "$AGB" 2>/dev/null
    [ -s "$AGB" ] || { rm -f "$AGB"; return 1; }
    hex_file "$AGB" 2>/dev/null | tr -d ' \n\t\r' > "$AGH"
    rm -f "$AGB"
    [ -s "$AGH" ] || return 1
    AGRSC_SRC="$AGP"
  fi
  arsc_lookup "$AGI" < "$AGH"
  return $?
}

# 在 arsc_get 的结果里挑一个值：任意密度(anydpi) > 设备密度的最优桶 > 默认配置
arsc_pick() { # $1 = 资源 ID  $2 = 设备密度；arsc_get 输出（结果行）从 stdin 读
  awk -F'|' -v id="$1" -v req="${2:-160}" '
  function win(c, o) {
    h = (c > o) ? c : o; l = (c > o) ? o : c
    if (req >= h) return (c == h)
    if (l >= req) return (c == l)
    if ((2*l - req) * h > req*req) return (c == l)
    return (c == h)
  }
  $1 == id && NF >= 4 {
    d = $2 + 0
    v = $4; for (i = 5; i <= NF; i++) v = v "|" $i
    if (d == 65534) { any = v; hasany = 1; next }
    if (d == 0) {
      # 同一密度 0 可能有多条配置（默认 + night/uiMode 等），优先 isdefault=1 的那条
      if (!defok) {
        if (!hasdef || ($3 + 0) == 1) {
          def = v; hasdef = 1
          if (($3 + 0) == 1) defok = 1
        }
      }
      next
    }
    if (!hasbest || win(d, bestd)) { bestd = d; best = v; hasbest = 1 }
  }
  END {
    if (hasany) { print any; exit 0 }
    if (hasbest) { print best; exit 0 }
    if (hasdef) { print def; exit 0 }
    exit 1
  }'
}

# AXML 二进制 -> 行式 XML 文本（矢量图标/渐变/自适应图标都用它先展开）
axml_dump() {
  awk '
  function b8(o) { return HX[substr(H, 2*o+1, 2)] }
  function u16(o) { return b8(o) + 256*b8(o+1) }
  function u32(o) { return b8(o) + 256*b8(o+1) + 65536*b8(o+2) + 16777216*b8(o+3) }
  function u8(o) { return sprintf("%c", b8(o)) }
  function utf8c(c) {
    if (c < 128) return sprintf("%c", c)
    if (c < 2048) return sprintf("%c%c", 192+int(c/64), 128+c%64)
    if (c < 65536) return sprintf("%c%c%c", 224+int(c/4096), 128+int(c/64)%64, 128+c%64)
    return sprintf("%c%c%c%c", 240+int(c/262144), 128+int(c/4096)%64, 128+int(c/64)%64, 128+c%64)
  }
  function f32(v,   s,e,m) {
    if (v == 0) return "0"
    s = 1
    if (int(v/2147483648) == 1) { s = -1; v = v - 2147483648 }
    e = int(v/8388608); m = v - e*8388608
    if (e == 255) return "nan"
    if (e == 0) return numstr(s * (m/8388608) * 0.000000000000000000000000000000000000011754943508222875)
    return numstr(s * (1 + m/8388608) * (2 ^ (e - 127)))
  }
  function numstr(x) {
    if (x == int(x) && x < 1e15 && x > -1e15) return sprintf("%.0f", x)
    return sprintf("%.6f", x)
  }
  function gstr(i,   o,q,ln,bl,k,j,c,c2,s2) {
    if (i in GS) return GS[i]
    if (i < 0 || i >= UCNT) { GS[i] = ""; return "" }
    o = u32(UOFF + 4*i); q = US0 + o; s2 = ""
    if (q > nb) { GS[i] = ""; return "" }
    if (UTF8) {
      ln = b8(q); k = 1
      if (ln >= 128) { ln = (ln-128)*256 + b8(q+1); k = 2 }
      bl = b8(q+k); k++
      if (bl >= 128) { bl = (bl-128)*256 + b8(q+k); k++ }
      for (j = 0; j < bl; j++) { c = b8(q+k+j); if (c == 0) break; s2 = s2 u8(q+k+j) }
    } else {
      ln = u16(q); k = 2
      if (ln >= 32768) { ln = (ln-32768)*65536 + u16(q+2); k = 4 }
      for (j = 0; j < ln; j++) {
        c = u16(q+k+2*j)
        if (c >= 55296 && c <= 56319 && j+1 < ln) {
          c2 = u16(q+k+2*j+2)
          if (c2 >= 56320 && c2 <= 57343) { c = 65536 + (c-55296)*1024 + (c2-56320); j++ }
        }
        s2 = s2 utf8c(c)
      }
    }
    GS[i] = s2
    return s2
  }
  function tval(dt, da) {
    if (dt == 3) return gstr(da)
    if (dt == 1 || dt == 2) return "@" sprintf("%08x", da)
    if (dt == 4) return f32(da)
    if (dt == 16 || dt == 17) return sprintf("%.0f", da)
    if (dt == 18) return (da != 0) ? "true" : "false"
    if (dt == 28 || dt == 29 || dt == 30 || dt == 31) return sprintf("#%08x", da)
    return ""
  }
  function esc(s) {
    gsub(/&/, "\\&amp;", s); gsub(/</, "\\&lt;")
    gsub(/>/, "\\&gt;", s); gsub(/"/, "\\&quot;", s)
    return s
  }
  BEGIN { for (i = 0; i < 256; i++) { h = sprintf("%02x", i); HX[h] = i; HX[toupper(h)] = i } }
  { H = H $0 }
  END {
    nb = length(H) / 2
    if (nb < 16) exit 1
    if (u16(0) != 3) exit 1
    p = 8; nc = 0
    while (p + 8 <= nb) {
      t = u16(p); cs = u32(p+4)
      if (cs <= 0 || p + cs > nb) break
      CH[++nc] = p; CT[nc] = t
      if (t == 1) {
        UCNT = u32(p+8); UTF8 = (int(u32(p+16)/256) % 2 == 1)
        US0 = p + u32(p+20); UOFF = p + 28
      }
      p = p + cs
    }
    for (i = 1; i <= nc; i++) {
      q = CH[i]
      if (CT[i] == 259) { print "</" gstr(u32(q+20)) ">"; continue }
      if (CT[i] != 258) continue
      tag = gstr(u32(q+20))
      if (tag == "") continue
      a = q + 16 + u16(q+24)
      ac = u16(q+28); as = u16(q+26)
      if (as < 20) as = 20
      line = "<" tag
      for (k = 0; k < ac; k++) {
        nsidx = u32(a + k*as)
        an = gstr(u32(a + k*as + 4))
        rv = u32(a + k*as + 8)
        if (an == "" || an == "xmlns") continue
        av = ""
        if (rv != 4294967295) av = gstr(rv)
        else av = tval(b8(a + k*as + 15), u32(a + k*as + 16))
        if (av == "") continue
        pre = ""
        if (nsidx != 4294967295) {
          nu = gstr(nsidx)
          if (index(nu, "xmlns") > 0) continue
          if (index(nu, "aapt") > 0) pre = "aapt:"
        }
        line = line " " pre an "=\"" esc(av) "\""
      }
      if (i + 1 <= nc && CT[i+1] == 259 && gstr(u32(CH[i+1]+20)) == tag) { print line "/>"; i++ }
      else print line ">"
    }
  }'
}

# 行式 XML -> SVG；$1=mode(vector|gradient) $2,$3=视口宽高 $4=裁剪框（可空）
svg_gen() {
  awk -v mode="$1" -v vw="$2" -v vh="$3" -v crop="$4" '
  function hexv(s,   i, v, h) {
    v = 0
    for (i = 1; i <= length(s); i++) {
      h = tolower(substr(s, i, 1))
      v = v * 16 + ((h >= "0" && h <= "9") ? h + 0 : index("abcdef", h) + 9)
    }
    return v
  }
  function cc(c, a,   al, r, g, b) {
    if (a == "") a = 1
    if (length(c) != 9) return "none"
    al = hexv(substr(c, 2, 2)) / 255 * a
    r = hexv(substr(c, 4, 2)); g = hexv(substr(c, 6, 2)); b = hexv(substr(c, 8, 2))
    if (al >= 0.999) return sprintf("#%02x%02x%02x", r, g, b)
    return sprintf("rgba(%d,%d,%d,%.3f)", r, g, b, al)
  }
  function attr(s, key,   v) {
    if (!match(s, key "=\"[^\"]*\"")) return ""
    return substr(s, RSTART + length(key) + 2, RLENGTH - length(key) - 3)
  }
  function num(s, d) { return (s == "") ? d : s + 0 }
  function is_self(s) { return (s ~ /\/>$/) }
  function pathfill(s,   f) {
    f = attr(s, "fillColor")
    if (f ~ /^#[0-9a-fA-F]{8}$/) return cc(f, attr(s, "fillAlpha"))
    if (f ~ /^#[0-9a-fA-F]{6}$/) return f
    return "none"
  }
  function gtrans(s,   tx, ty, sx, sy, rot, px, py, o) {
    tx = num(attr(s, "translateX"), 0); ty = num(attr(s, "translateY"), 0)
    sx = num(attr(s, "scaleX"), 1); sy = num(attr(s, "scaleY"), 1)
    rot = num(attr(s, "rotation"), 0)
    px = num(attr(s, "pivotX"), 0); py = num(attr(s, "pivotY"), 0)
    o = ""
    if (tx != 0 || ty != 0) o = o sprintf("translate(%g,%g) ", tx, ty)
    if (px != 0 || py != 0) o = o sprintf("translate(%g,%g) ", px, py)
    if (rot != 0) o = o sprintf("rotate(%g) ", rot)
    if (sx != 1 || sy != 1) o = o sprintf("scale(%g,%g) ", sx, sy)
    if (px != 0 || py != 0) o = o sprintf("translate(%g,%g)", -px, -py)
    return o
  }
  function elem_path(s, fill,   d, o, st, sw, lc, lj) {
    d = attr(s, "pathData")
    if (d == "") return ""
    o = "<path d=\"" d "\" fill=\"" fill "\""
    st = attr(s, "strokeColor")
    if (st ~ /^#[0-9a-fA-F]{8}$/) o = o " stroke=\"" cc(st, attr(s, "strokeAlpha")) "\""
    else if (st ~ /^#[0-9a-fA-F]{6}$/) o = o " stroke=\"" st "\""
    sw = attr(s, "strokeWidth")
    if (sw != "" && (st ~ /^#/)) o = o " stroke-width=\"" sw "\""
    if (attr(s, "fillType") == "1") o = o " fill-rule=\"evenodd\""
    lc = attr(s, "strokeLineCap")
    if (lc == "1") o = o " stroke-linecap=\"round\""
    else if (lc == "2") o = o " stroke-linecap=\"square\""
    lj = attr(s, "strokeLineJoin")
    if (lj == "1") o = o " stroke-linejoin=\"round\""
    else if (lj == "2") o = o " stroke-linejoin=\"bevel\""
    return o "/>"
  }
  function stopline(s,   c, of, al, col) {
    c = attr(s, "color"); of = attr(s, "offset"); if (of == "") of = 0
    if (length(c) != 9) return ""
    col = "#" substr(c, 4, 2) substr(c, 6, 2) substr(c, 8, 2)
    al = hexv(substr(c, 2, 2)) / 255
    if (al >= 0.999) return sprintf("<stop offset=\"%s\" stop-color=\"%s\"/>", of, col)
    return sprintf("<stop offset=\"%s\" stop-color=\"%s\" stop-opacity=\"%.3f\"/>", of, col, al)
  }
  function graddef(s, gid,   t, x1, y1, x2, y2, cx, cy, r, ang, a, tile, o) {
    t = attr(s, "type"); if (t == "") t = "0"
    tile = attr(s, "tileMode")
    if (t == "0") {
      x1 = attr(s, "startX"); y1 = attr(s, "startY")
      x2 = attr(s, "endX"); y2 = attr(s, "endY")
      ang = attr(s, "angle")
      if (ang != "" && x1 == "" && y1 == "" && x2 == "" && y2 == "") {
        a = (ang + 0) * 3.14159265358979 / 180
        r = (vw > vh ? vw : vh) / 2
        cx = vw / 2; cy = vh / 2
        x1 = cx - r * cos(a); y1 = cy + r * sin(a)
        x2 = cx + r * cos(a); y2 = cy - r * sin(a)
      }
      if (x1 == "") x1 = 0
      if (y1 == "") y1 = 0
      if (x2 == "") x2 = vw
      if (y2 == "") y2 = vh
      o = sprintf("<linearGradient id=\"%s\" gradientUnits=\"userSpaceOnUse\" x1=\"%s\" y1=\"%s\" x2=\"%s\" y2=\"%s\"", gid, x1, y1, x2, y2)
      if (tile == "1") o = o " spreadMethod=\"repeat\""
      else if (tile == "2") o = o " spreadMethod=\"reflect\""
      gend = "linearGradient"
      return o ">"
    }
    if (t == "1") {
      cx = attr(s, "centerX"); cy = attr(s, "centerY"); r = attr(s, "gradientRadius")
      if (cx == "") cx = vw / 2
      if (cy == "") cy = vh / 2
      if (r == "") r = (vw > vh ? vw : vh) / 2
      o = sprintf("<radialGradient id=\"%s\" gradientUnits=\"userSpaceOnUse\" cx=\"%s\" cy=\"%s\" r=\"%s\"", gid, cx, cy, r)
      if (tile == "1") o = o " spreadMethod=\"repeat\""
      else if (tile == "2") o = o " spreadMethod=\"reflect\""
      gend = "radialGradient"
      return o ">"
    }
    gend = ""
    return ""
  }
  BEGIN {
    if (mode == "") mode = "vector"
    if (vw == "") vw = 24
    if (vh == "") vh = 24
    vb = (crop != "") ? crop : "0 0 " vw " " vh
    state = "idle"; nd = 0; gbuf = ""; nstop = 0; gend = ""
  }
  { L = $0 }
  L == "" { next }
  state == "idle" {
    if (mode == "gradient") {
      if (L !~ /<gradient[ \/>]/) exit 1
      gopen = graddef(L, "g0")
      if (gopen == "") exit 1
      printf "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"%s\" width=\"100%%\" height=\"100%%\">\n", vb
      print "<defs>" gopen
      state = "rootgrad"
      next
    }
    if (L !~ /<vector[ \/>]/) exit 1
    s = attr(L, "viewportWidth"); if (s != "") vw = s
    s = attr(L, "viewportHeight"); if (s != "") vh = s
    if (crop == "") vb = "0 0 " vw " " vh
    printf "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"%s\" width=\"100%%\" height=\"100%%\">\n", vb
    state = "vector"
    next
  }
  state == "rootgrad" {
    if (L ~ /<item /) { print stopline(L); nstop++; next }
    if (L ~ /<\/gradient>/) {
      if (nstop == 0) print "<stop offset=\"0\" stop-color=\"#888888\"/><stop offset=\"1\" stop-color=\"#444444\"/>"
      printf "</%s></defs>\n<rect width=\"%s\" height=\"%s\" fill=\"url(#g0)\"/>\n</svg>\n", gend, vw, vh
      exit 0
    }
    next
  }
  L ~ /<\/vector>/ { print "</svg>"; exit 0 }
  L ~ /<\/group>/ { print "</g>"; next }
  L ~ /<group[ \/>]/ {
    t = gtrans(L)
    if (t == "") print "<g>"
    else printf "<g transform=\"%s\">\n", t
    next
  }
  L ~ /<clip-path/ || L ~ /<\/clip-path>/ { next }
  L ~ /<aapt:attr / {
    if (attr(L, "name") ~ /fillColor/) { want = "fill"; nd++; gid = "g" nd; gbuf = "" }
    else if (attr(L, "name") ~ /strokeColor/) { want = "stroke"; nd++; gid = "g" nd; gbuf = "" }
    else want = ""
    next
  }
  L ~ /<\/aapt:attr>/ { next }
  L ~ /<gradient[ \/>]/ { gbuf = graddef(L, gid); next }
  L ~ /<item / && gbuf != "" { gbuf = gbuf "\n" stopline(L); next }
  L ~ /<path[ \/>]/ {
    if (is_self(L) && gbuf == "") { print elem_path(L, pathfill(L)); next }
    pline = L; pdef = ""; purl = ""
    next
  }
  L ~ /<\/path>/ {
    if (gbuf != "" && gid != "") { pdef = gbuf; purl = "url(#" gid ")" }
    if (pdef != "") { print "<defs>" pdef; if (gend != "") print "</" gend ">"; print "</defs>" }
    if (pline != "") print elem_path(pline, (purl != "" ? purl : pathfill(pline)))
    gbuf = ""; pdef = ""; purl = ""; pline = ""
    next
  }
  { next }'
}

# 需要把基础包落到磁盘时统一走这里（元信息解析与资源表解析共用，只解一次）。
# $1 = 允许的最大字节数（空则用 APKMT_BASE_META_MAX），超过就放弃。
ensure_base_apk() {
  [ -n "$BASE_APK_FILE" ] && [ -f "$BASE_APK_FILE" ] && return 0
  [ -n "$BASE_NAME" ] && [ -n "$BUNDLE" ] && [ -n "$UNZIP" ] || return 1
  EBSZ=$(tbl_get "$BASE_NAME" "$TBL"); [ -n "$EBSZ" ] || EBSZ=0
  EBL="${1:-$APKMT_BASE_META_MAX}"
  awk -v s="$EBSZ" -v m="$EBL" 'BEGIN{ exit !(s+0 > 0 && s+0 <= m+0) }' || return 1
  EBA="$TMP/.base.apk"
  $UNZIP -p "$BUNDLE" "$BASE_NAME" > "$EBA" 2>/dev/null
  [ -s "$EBA" ] || { rm -f "$EBA"; return 1; }
  BASE_APK_FILE="$EBA"
  return 0
}

# APK 里的某个 XML 条目 -> 行式 XML 文本；$1=apk $2=条目名 $3=输出文件
apk_entry_text() {
  AETB="$TMP/.axml.bin"
  $UNZIP -p "$1" "$2" 2>/dev/null | head -c "$AXML_MAX_BYTES" > "$AETB" 2>/dev/null
  [ -s "$AETB" ] || { rm -f "$AETB"; return 1; }
  hex_file "$AETB" 2>/dev/null | tr -d ' \n\t\r' | axml_dump > "$3" 2>/dev/null
  rm -f "$AETB"
  [ -s "$3" ] || { rm -f "$3"; return 1; }
  return 0
}

# SVG 合法性：以 <svg 开头且体积在限内
svg_ok() {
  [ -n "$1" ] && [ -f "$1" ] && [ -s "$1" ] || return 1
  SVS=$(stat -c %s "$1" 2>/dev/null); [ -n "$SVS" ] || return 1
  [ "$SVS" -le "$ICON_SVG_MAX" ] 2>/dev/null || return 1
  head -c 4 "$1" 2>/dev/null | grep -q '^<svg' 2>/dev/null
}

# 把文件放进 icon-cache：$1=源文件 $2=扩展名 $3=后缀（bg/空）
# 目标文件名只由净化后的包名 + 后缀生成，杜绝 zip 条目名带来的 ../ 穿越。
icon_put() {
  [ -n "$ICON_DIR" ] && [ -f "$1" ] || return 1
  IPE="$2"; IPS="$3"
  ISAFE=$(printf '%s' "$META_PKG" | sed 's/[^A-Za-z0-9._-]/_/g' | cut -c1-96)
  [ -n "$ISAFE" ] || ISAFE="bundle"
  case "$ISAFE" in .|..) ISAFE="bundle";; esac
  IPN="$ISAFE"
  [ -n "$IPS" ] && IPN="$ISAFE-$IPS"
  ITMP="$ICON_DIR/.tmp.$$.$IPE"
  cp "$1" "$ITMP" 2>/dev/null || { rm -f "$ITMP"; return 2; }
  mv -f "$ITMP" "$ICON_DIR/$IPN.$IPE" 2>/dev/null || { rm -f "$ITMP"; return 2; }
  ITS=$(date +%s 2>/dev/null); [ -n "$ITS" ] || ITS=0
  ICON_PUT_REL="icon-cache/$IPN.$IPE?v$ITS"
  return 0
}

# 视口 -> 居中裁掉四周 1/6 的裁剪框（自适应图标只看中间 72dp / 108dp）
icon_crop() { # $1=宽 $2=高
  awk -v w="$1" -v h="$2" 'BEGIN{ printf "%.3f %.3f %.3f %.3f", w/6, h/6, w*2/3, h*2/3 }'
}

# 把一个资源值渲染成图层的图片文件：$1=apk $2=资源值 $3=后缀(bg/空) $4=1 表示居中裁剪
# 纯色值只在背景层有意义（作为 CSS 背景色）。
# 成功时：后缀 bg -> ICON_BG；否则 -> ICON_REL。调用方负责 ICON_SRC/ICON_SCALE。
icon_value_apply() {
  IVP="$1"; IVV="$2"; IVS="$3"; IVC="$4"
  [ -n "$IVV" ] || return 1
  case "$IVV" in
    C:*)
      if [ "$IVS" = "bg" ]; then ICON_BG="${IVV#C:}"; return 0; fi
      return 1;;
    S:*) ;;
    *) return 1;;
  esac
  IVPATH="${IVV#S:}"
  case "$IVPATH" in
    *.png|*.webp|*.jpg|*.jpeg|*.gif)
      if [ "$IVS" = "bg" ]; then
        IVB="$TMP/.ivb.img"
        $UNZIP -p "$IVP" "$IVPATH" 2>/dev/null | head -c 2097152 > "$IVB" 2>/dev/null
        IVE=$(printf '%s' "$IVPATH" | sed 's/.*\.//' | tr 'A-Z' 'a-z')
        if img_ok "$IVB" && icon_put "$IVB" "$IVE" "bg"; then
          ICON_BG="$ICON_PUT_REL"; rm -f "$IVB"; return 0
        fi
        rm -f "$IVB"; return 1
      fi
      icon_install "$IVP" "$IVPATH" "arsc" || return 1
      ICON_SCALE=1
      return 0;;
    *.xml)
      IVF="$TMP/.iv.xml"; IVG="$TMP/.iv.svg"
      apk_entry_text "$IVP" "$IVPATH" "$IVF" || return 1
      IVR=1
      if head -1 "$IVF" | grep -q '<gradient' 2>/dev/null; then
        IVCR=""; [ "$IVC" = 1 ] && IVCR=$(icon_crop 108 108)
        svg_gen gradient "108" "108" "$IVCR" < "$IVF" > "$IVG" 2>/dev/null
        [ -s "$IVG" ] && svg_ok "$IVG" && icon_put "$IVG" svg "$IVS" && IVR=0
      elif head -1 "$IVF" | grep -q '<vector' 2>/dev/null; then
        IVW=$(sed -n 's/.*<vector[^>]*viewportWidth="\([0-9.]*\)".*/\1/p' "$IVF" | head -1)
        IVH=$(sed -n 's/.*<vector[^>]*viewportHeight="\([0-9.]*\)".*/\1/p' "$IVF" | head -1)
        [ -n "$IVW" ] || IVW=108
        [ -n "$IVH" ] || IVH=108
        # 填充色是资源引用（渐变）时，先查引用再翻译；纯色引用直接当背景色
        IVREF=$(grep -o 'fillColor="@[0-9a-f]*"' "$IVF" 2>/dev/null | head -1 | sed 's/.*"@\([0-9a-f]*\)"/\1/')
        IVLIT=$(grep -c 'fillColor="#' "$IVF" 2>/dev/null); [ -n "$IVLIT" ] || IVLIT=0
        if [ -n "$IVREF" ] && [ "$IVLIT" = 0 ]; then
          IVROWS=$(arsc_get "$IVP" "$IVREF") || IVROWS=""
          IVVAL=$(printf '%s\n' "$IVROWS" | arsc_pick "$IVREF" "$DEV_DENSITY")
          case "$IVVAL" in
            C:*)
              if [ "$IVS" = "bg" ]; then
                ICON_BG="${IVVAL#C:}"; rm -f "$IVF" "$IVG"; return 0
              fi;;
            S:*)
              IVP2="${IVVAL#S:}"; IV2F="$TMP/.iv2.xml"
              if apk_entry_text "$IVP" "$IVP2" "$IV2F" && head -1 "$IV2F" | grep -q '<gradient' 2>/dev/null; then
                IVCR=$(icon_crop "$IVW" "$IVH")
                svg_gen gradient "$IVW" "$IVH" "$IVCR" < "$IV2F" > "$IVG" 2>/dev/null
                [ -s "$IVG" ] && svg_ok "$IVG" && icon_put "$IVG" svg "$IVS" && IVR=0
              fi
              rm -f "$IV2F";;
          esac
        fi
        if [ "$IVR" != 0 ]; then
          IVCR=""; [ "$IVC" = 1 ] && IVCR=$(icon_crop "$IVW" "$IVH")
          svg_gen vector "$IVW" "$IVH" "$IVCR" < "$IVF" > "$IVG" 2>/dev/null
          [ -s "$IVG" ] && svg_ok "$IVG" && icon_put "$IVG" svg "$IVS" && IVR=0
        fi
      fi
      rm -f "$IVF" "$IVG"
      [ "$IVR" = 0 ] || return 1
      if [ "$IVS" = "bg" ]; then ICON_BG="$ICON_PUT_REL"; else ICON_REL="$ICON_PUT_REL"; fi
      return 0;;
  esac
  return 1
}

# 图标资源值 -> 图标（自适应图标拆成背景/前景两层）
arsc_icon_apply() { # $1=apk $2=资源值
  AIP="$1"; AIV="$2"
  case "$AIV" in
    S:*) ;;
    *) return 1;;
  esac
  AIPATH="${AIV#S:}"
  case "$AIPATH" in
    *.xml)
      AIT="$TMP/.ai.xml"
      apk_entry_text "$AIP" "$AIPATH" "$AIT" || return 1
      if head -1 "$AIT" | grep -q '<adaptive-icon' 2>/dev/null; then
        icon_adaptive_apply "$AIP" "$AIT"
        AIR=$?
        rm -f "$AIT"
        return $AIR
      fi
      rm -f "$AIT"
      icon_value_apply "$AIP" "$AIV" "" 0 || return 1
      ICON_SRC="vector"; ICON_SCALE=1
      return 0;;
    *)
      icon_value_apply "$AIP" "$AIV" "" 0 || return 1
      ICON_SCALE=1
      return 0;;
  esac
}

# 自适应图标：background 层（纯色/渐变/位图）+ foreground 层（矢量/位图）
icon_adaptive_apply() { # $1=apk $2=行式 XML 文件
  IAR="$1"; IAF="$2"
  ABR=$(sed -n 's/.*<background[^>]*drawable="@\([0-9a-f]*\)".*/\1/p' "$IAF" | head -1)
  AFR=$(sed -n 's/.*<foreground[^>]*drawable="@\([0-9a-f]*\)".*/\1/p' "$IAF" | head -1)
  [ -n "$ABR$AFR" ] || return 1
  IAQ="$ABR"
  if [ -n "$ABR" ] && [ -n "$AFR" ]; then IAQ="$ABR,$AFR"; fi
  if [ -z "$ABR" ]; then IAQ="$AFR"; fi
  IAROWS=$(arsc_get "$IAR" "$IAQ") || IAROWS=""
  [ -n "$IAROWS" ] || return 1
  if [ -n "$ABR" ]; then
    ABV=$(printf '%s\n' "$IAROWS" | arsc_pick "$ABR" "$DEV_DENSITY")
    icon_value_apply "$IAR" "$ABV" "bg" 1 >/dev/null 2>&1
  fi
  if [ -n "$AFR" ]; then
    AFV=$(printf '%s\n' "$IAROWS" | arsc_pick "$AFR" "$DEV_DENSITY")
    icon_value_apply "$IAR" "$AFV" "" 0 >/dev/null 2>&1
  fi
  if [ -n "$ICON_REL" ]; then
    ICON_SRC="adaptive"; ICON_SCALE=1.5
    return 0
  fi
  return 1
}

# 应用名 + 图标的权威来源：resources.arsc
arsc_meta() {
  [ -n "$META_LABEL" ] && [ -n "$ICON_REL" ] && return 0
  [ -n "$UNZIP" ] || return 1
  AMF=""
  if [ "$IS_SINGLE_ZIP" = 1 ]; then
    AMF="$BUNDLE"
  else
    ALC="$APKMT_ICON_BASE_MAX"
    awk -v a="$ALC" -v b="$APKMT_BASE_META_MAX" 'BEGIN{ exit !(b+0 > 0 && b+0 < a+0) }' && ALC="$APKMT_BASE_META_MAX"
    ensure_base_apk "$ALC" || return 1
    AMF="$BASE_APK_FILE"
  fi
  [ -n "$AMF" ] && [ -f "$AMF" ] || return 1
  if [ -z "$META_LABEL_REF" ] && [ -z "$META_ICON_REF" ]; then
    meta_from_apk_file "$AMF" >/dev/null 2>&1
    if [ -z "$META_LABEL_REF" ] && [ -z "$META_ICON_REF" ]; then return 1; fi
  fi
  AID=""
  if [ -z "$META_LABEL" ] && [ -n "$META_LABEL_REF" ]; then AID="$META_LABEL_REF"; fi
  if [ -z "$ICON_REL" ] && [ -n "$ICON_DIR" ] && [ -n "$META_ICON_REF" ]; then
    if [ -n "$AID" ]; then AID="$AID,"; fi
    AID="$AID$META_ICON_REF"
  fi
  [ -n "$AID" ] || return 0
  AROWS=$(arsc_get "$AMF" "$AID") || AROWS=""
  if [ -z "$META_LABEL" ] && [ -n "$META_LABEL_REF" ] && [ -n "$AROWS" ]; then
    ALV=$(printf '%s\n' "$AROWS" | arsc_pick "$META_LABEL_REF" "$DEV_DENSITY")
    ALOOP=0
    while [ "$ALOOP" -lt 2 ]; do
      case "$ALV" in
        R:*)
          ALR="${ALV#R:}"
          ALV=$(arsc_get "$AMF" "$ALR" | arsc_pick "$ALR" "$DEV_DENSITY");;
        S:*)
          ALB=$(printf '%s' "${ALV#S:}" | tr -d '|\r\n\t')
          if [ -n "$ALB" ]; then META_LABEL="$ALB"; META_LABEL_SRC="arsc"; fi
          break;;
        *) break;;
      esac
      ALOOP=$((ALOOP + 1))
    done
  fi
  if [ -z "$ICON_REL" ] && [ -n "$ICON_DIR" ] && [ -n "$META_ICON_REF" ] && [ -n "$AROWS" ]; then
    AIV=$(printf '%s\n' "$AROWS" | arsc_pick "$META_ICON_REF" "$DEV_DENSITY")
    arsc_icon_apply "$AMF" "$AIV"
  fi
  return 0
}

# 图标探测：xapk/apkm 根 icon.* -> resources.arsc -> res/mipmap* 文件名启发式
probe_icon() {
  ICON_REL=""; ICON_BG=""; ICON_SCALE=1; ICON_SRC="none"; ICON_DIR=""; ICON_PUT_REL=""
  [ -n "$UNZIP" ] || return 0
  MD=$(moddir_get 2>/dev/null) || MD=""
  if [ -n "$MD" ]; then
    ICON_DIR="$MD/webroot/icon-cache"
    mkdir -p "$ICON_DIR" 2>/dev/null || ICON_DIR=""
  fi
  CE=""
  # 1) 外层 bundle 根目录 icon.png（xapk/apkm 规范位置，零解析成本）
  if [ "$IS_SINGLE_ZIP" != 1 ] && [ -n "$ICON_DIR" ]; then
    CE=$(icon_entry_root)
    if [ -n "$CE" ] && icon_install "$BUNDLE" "$CE" "root"; then
      ICON_SCALE=1
      arsc_meta >/dev/null 2>&1
      prune_icons
      return 0
    fi
  fi
  # 2) resources.arsc：应用名 + 图标的权威来源（自适应图标会拆成背景/前景两层）
  arsc_meta >/dev/null 2>&1
  if [ -n "$ICON_REL" ]; then prune_icons; return 0; fi
  # 3) 兜底：基础包里 res/mipmap* 的位图（资源名被混淆或 arsc 解析失败时）
  if [ -n "$BASE_APK_FILE" ] && [ -f "$BASE_APK_FILE" ]; then
    zip_table "$BASE_APK_FILE" > "$TMP/.basetbl" 2>/dev/null
    CE=$(icon_entry_apk "$TMP/.basetbl")
    rm -f "$TMP/.basetbl"
    if [ -n "$CE" ] && icon_install "$BASE_APK_FILE" "$CE" "mipmap"; then prune_icons; return 0; fi
  fi
  if [ "$IS_SINGLE_ZIP" = 1 ]; then
    zip_table "$BUNDLE" > "$TMP/.selftbl" 2>/dev/null
    CE=$(icon_entry_apk "$TMP/.selftbl")
    rm -f "$TMP/.selftbl"
    if [ -n "$CE" ] && icon_install "$BUNDLE" "$CE" "mipmap"; then prune_icons; return 0; fi
    return 0
  fi
  # 4) xapk/apkm 的 JSON 齐全时没解基础包：体积够小才为图标解一次
  if [ -z "$BASE_APK_FILE" ] && [ -n "$BASE_NAME" ]; then
    CBSZ=$(tbl_get "$BASE_NAME" "$TBL"); [ -n "$CBSZ" ] || CBSZ=0
    CLIM="$APKMT_ICON_BASE_MAX"
    awk -v a="$CLIM" -v b="$APKMT_BASE_META_MAX" 'BEGIN{ exit !(b+0 > 0 && b+0 < a+0) }' && CLIM="$APKMT_BASE_META_MAX"
    if awk -v s="$CBSZ" -v m="$CLIM" 'BEGIN{ exit !(s+0 > 0 && s+0 <= m+0) }'; then
      CIB="$TMP/.iconbase.apk"
      $UNZIP -p "$BUNDLE" "$BASE_NAME" > "$CIB" 2>/dev/null
      if [ -s "$CIB" ]; then
        zip_table "$CIB" > "$TMP/.basetbl" 2>/dev/null
        CE=$(icon_entry_apk "$TMP/.basetbl")
        rm -f "$TMP/.basetbl"
        [ -n "$CE" ] && icon_install "$CIB" "$CE" "mipmap"
      fi
      rm -f "$CIB"
    fi
  fi
  [ -n "$ICON_REL" ] && prune_icons
  return 0
}

# ---------------------------------------------------------------- 选择策略

# 全局：SEL_LIST(name<TAB>size<TAB>session_name)  ENTRY_OUT(name|size|kind|token|sel|reason)
#       TOTAL_BYTES  SELECTED_COUNT  BASE_NAME  BUNDLE_TYPE
#
# 统计选中项（必须走 awk：Android mksh 的 $(( )) 与 [ ] 都是 32 位有符号，
# 只要包体 >2GiB 或空闲空间 >2GiB 就会溢出翻转，得到负数）
sel_stats() {
  SELECTED_COUNT=$(wc -l < "$SEL_LIST" | tr -d ' ')
  TOTAL_BYTES=$(awk -F'\t' '{s += $1} END{printf "%.0f", s+0}' "$SEL_LIST")
}
prepare() {
  BUNDLE="$1"
  MODE="$2"; SPLITS="$3"; LANGPOL="$4"
  # 每个动作（inspect / install / action）都从干净状态开始
  BASE_APK_FILE=""; ICON_REL=""; ICON_SRC="none"; ICON_DIR=""; META_LABEL_SRC=""
  ICON_BG=""; ICON_SCALE=1; META_LABEL_REF=""; META_ICON_REF=""

  [ -f "$BUNDLE" ] || { rec RESULT "FAIL|FILE_NOT_FOUND|$BUNDLE"; return 1; }
  [ -r "$BUNDLE" ] || { rec RESULT "FAIL|FILE_UNREADABLE|$BUNDLE"; return 1; }

  FILESIZE=$(stat -c %s "$BUNDLE" 2>/dev/null); [ -n "$FILESIZE" ] || FILESIZE=0

  # 单文件 APK？(根目录有 AndroidManifest.xml 且没有嵌套 apk)
  IS_SINGLE_ZIP=0
  case "$(printf '%s' "$BUNDLE" | tr 'A-Z' 'a-z')" in
    *.apk) IS_SINGLE_ZIP=1;;
  esac
  if [ "$IS_SINGLE_ZIP" = 0 ]; then
    find_unzip_for "$BUNDLE"
    if [ -n "$UNZIP" ] && $UNZIP -l "$BUNDLE" 2>/dev/null | awk 'tolower($NF)=="androidmanifest.xml"{f=1} END{exit !f}'; then
      if ! $UNZIP -l "$BUNDLE" 2>/dev/null | awk -F'[ \t]+' 'tolower($NF) ~ /\.apk$/ {f=1} END{exit !f}'; then
        IS_SINGLE_ZIP=1
      fi
    fi
  fi

  if [ "$IS_SINGLE_ZIP" = 1 ]; then
    # 单个 APK：直接流式安装，会话内命名为 base.apk
    BUNDLE_TYPE="apk"
    BASE_NAME="base.apk"
    # TOTAL_BYTES / SELECTED_COUNT 在 prepare 末尾用 awk 统一统计
    EC=1
    : > "$SEL_LIST"; printf '%s\t%s\t%s\n' "$FILESIZE" "$BUNDLE" "base.apk" >> "$SEL_LIST"
    : > "$ENTRY_OUT"; printf 'base.apk|%s|base||1|base_required\n' "$FILESIZE" >> "$ENTRY_OUT"
    # 单 APK 也要读自己的 AndroidManifest.xml：包名/版本/API 是"已装版本对比"、
    # 历史记录、"打开应用"按钮的依据。旧版本在这里直接 return，元信息全是空的。
    META_PKG_SRC="none"
    find_unzip_for "$BUNDLE"
    [ -n "$UNZIP" ] && meta_from_apk_file "$BUNDLE"
    # 关键：统计必须在 return 之前做。旧代码在这里直接 return，于是单 APK
    # 安装时 SELECTED_COUNT 一直是空的，cmd_install 判定"没有选中任何文件"
    # 直接 RESULT|FAIL|NO_SELECTION，单个 .apk 根本装不上。
    sel_stats
    # 单个 .apk 也能取包内图标（res/mipmap*），前端预装阶段就能显示真图
    probe_icon
    return 0
  fi

  [ -n "$UNZIP" ] || find_unzip_for "$BUNDLE"
  [ -n "$UNZIP" ] || { rec RESULT "FAIL|NO_UNZIP|no unzip able to list this bundle"; return 1; }

  # 整包读取条目表
  zip_table "$BUNDLE" > "$TBL"
  EC=$(wc -l < "$TBL" | tr -d ' ')
  [ "$EC" -gt 0 ] || { rec RESULT "FAIL|NOT_A_PACKAGE|unable to list zip entries"; return 1; }

  BASE_NAME=$(find_base "$TBL")
  [ -n "$BASE_NAME" ] || { rec RESULT "FAIL|NO_BASE|no base apk inside"; return 1; }

  # standalone / universal 包：里面是一个个完整的 APK，不是"基础包 + 配置分片"，
  # 只能挑一个装（同一个包名装多个完整 APK 会被 pm 拒绝）
  case "$(printf '%s' "$BASE_NAME" | tr 'A-Z' 'a-z')" in
    standalone/*|standalones/*|*/standalone/*|*/standalones/*|universal.apk) BASE_KIND="standalone";;
    *) BASE_KIND="split";;
  esac

  # 类型判定
  if awk -F'\t' 'tolower($2)=="toc.pb"{f=1} END{exit !f}' "$TBL"; then
    BUNDLE_TYPE="apks"
  elif awk -F'\t' 'tolower($2) ~ /(^|\/)manifest\.json$/{f=1} END{exit !f}' "$TBL"; then
    BUNDLE_TYPE="xapk"
  elif awk -F'\t' 'tolower($2) ~ /(^|\/)info\.json$/{f=1} END{exit !f}' "$TBL"; then
    BUNDLE_TYPE="apkm"
  else
    BUNDLE_TYPE="zip"
  fi

  meta_from_bundle

  # 设备上最优密度 / 最优 ABI（只从包内真实存在的候选里挑）
  awk -F'\t' '{print $2}' "$TBL" | while read -r dpe; do
    classify "$dpe"
    [ "$CKIND" = "dpi" ] || continue
    case "$CTOK" in nodpi|anydpi) ;; *) printf '%s\n' "$CTOK";; esac
  done > "$DPI_LIST"
  awk -F'\t' '{print $2}' "$TBL" | while read -r abe; do
    classify "$abe"
    [ "$CKIND" = "abi" ] && printf '%s\n' "$CTOK"
  done > "$ABI_LIST"
  awk -F'\t' '{print $2}' "$TBL" | while read -r lge; do
    classify "$lge"
    [ "$CKIND" = "lang" ] && printf '%s\n' "$CTOK"
  done > "$LANG_LIST"
  # 语言分片是"配置桶"，不是"二选一"：values-zh 与 values-zh-rCN 是两个不同的
  # 资源桶，Android 的查找不会从一个分片回退到另一个分片，所以 bundletool 的
  # 语义是"精确匹配的分片 + 该语言的兜底分片"一起装。这里照做：
  #   5   = 与设备 locale 完全一致（zh-cn）
  #   4   = 语言一致且 script 匹配（zh-hans 对 zh-CN；hans/hant 由区域推断）
  #   3.5 = 语言一致且 region 匹配
  #   3   = 只匹配语言（兜底桶）
  #   0.5 = 语言一致但 script/region 不匹配（不装：那是别的区域/字形的桶）
  # 选中 = 分>=3 的最优项 + 同语言的兜底项；一个都没命中时退回 en(lang_default)。
  # 旧逻辑只比"语言"，zh 设备会把 zh、zh-hans、zh-hant 全选中；反过来只选
  # "语言"又会漏掉 values-zh 的资源。
  # LANGPOL 既不是 sys 也不是 all 时，按用户显式指定的语言码选（--lang ru）。
  if [ -s "$LANG_LIST" ]; then
    SEL_LANG_LINE=$(awk -v loc="$DEV_LOCALE" -v lg="$DEV_LANG" -v pol="$LANGPOL" '
      function norm(s) { gsub(/_/,"-",s); return tolower(s) }
      function langof(t,  n,a) { n=split(t,a,"-"); return a[1] }
      function scriptof(t,  n,a) { n=split(t,a,"-"); return (n>=2 && length(a[2])==4) ? a[2] : "" }
      function regionof(t,  n,a) { n=split(t,a,"-"); return (n>=2 && length(a[n])==2) ? a[n] : "" }
      function scr(r) { if (r=="cn"||r=="sg"||r=="my") return "hans"; if (r=="tw"||r=="hk"||r=="mo") return "hant"; return "" }
      function score(t,   s,r) {
        if (W!="" && W!="sys" && W!="all") {
          if (t==W) return 90
          if (langof(t)==W) return 80
          return -1
        }
        if (LG=="" || langof(t)!=LG) return -1
        if (t==L) return 5
        s=scriptof(t); r=regionof(t)
        if (s!="" && SC!="" && s==SC) return 4
        if (t==LG) return 3
        if (r!="" && RG!="" && r==RG) return 3.5
        return 0.5
      }
      BEGIN {
        L=norm(loc); LG=norm(lg); W=norm(pol); bs=-1; bt=""; bare=""
        n=split(L,pa,"-"); RG=(n>=2 && length(pa[n])==2) ? pa[n] : ""; SC=scr(RG)
      }
      { t=tolower($1); if (t=="") next
        if (t=="en") has_en=1
        if (t==LG) bare=t
        s=score(t)
        if (s>bs || (s==bs && length(t)>length(bt))) { bs=s; bt=t } }
      END {
        if (bs>=3) {
          if (bare!="" && bare!=bt && (W=="" || W=="sys")) print "system," bt "," bare
          else print "system," bt
          exit
        }
        if ((W=="" || W=="sys") && has_en) print "default,en"
      }' "$LANG_LIST")
    SEL_LANG_KIND=$(printf '%s' "$SEL_LANG_LINE" | cut -d, -f1)
    SEL_LANGS=$(printf '%s' "$SEL_LANG_LINE" | cut -d, -f2-)
  fi
  if [ -s "$DPI_LIST" ]; then
    # 完全按 AOSP ResTable_config::isBetterThan 的 density 分支来选（不是"2 倍桶"）：
    # 都比设备大取小的，都比设备小取大的，一大一小时"向下缩放比向上缩放好一倍"。
    SEL_DPI=$(awk -v req="$DEV_DENSITY" '
      function wins(cand, best,   h, l, ch) {
        if (cand == best) return 0
        if (cand > best) { h = cand; l = best; ch = h } else { h = best; l = cand; ch = cand }
        if (req >= h) return (ch == h)
        if (l >= req) return (ch == l)
        if ((2*l - req) * h > req * req) return (ch == l)
        return (ch == h)
      }
      BEGIN { req = req + 0; if (req <= 0) req = 160; b = "" }
      { d = $1 + 0; if (d <= 0) next
        if (b == "") { b = d; next }
        if (wins(d, b)) b = d }
      END { print b }' "$DPI_LIST")
  fi
  # 设备上最优 ABI：按 ro.product.cpu.abilist 的优先顺序，取包内第一个能用的。
  # 旧逻辑只认 abi_primary（严格等于第一项），遇到"设备 abilist 以 arm64-v8a 开头、
  # 包内却只有 armeabi-v7a 分片"的 32 位包时会把唯一可用的分片标成 abi_secondary
  # 不安装 → 装完因缺 lib 直接闪退。
  SEL_ABI=$(awk -F'\t' -v dev="$DEV_ABILIST" '
    function norm(s) { gsub(/[-_]/, "", s); return tolower(s) }
    BEGIN { nd = split(dev, dv, ","); for (i = 1; i <= nd; i++) dv[i] = norm(dv[i]) }
    { c[++n] = $1 }
    END { for (i = 1; i <= nd; i++)
            for (j = 1; j <= n; j++)
              if (norm(c[j]) == dv[i]) { print c[j]; exit } }' "$ABI_LIST")

  # 逐条分类 + 选择
  : > "$SEL_LIST"; : > "$ENTRY_OUT"
  # 基础包优先写入（必须先写 base）
  BSIZE=$(tbl_get "$BASE_NAME" "$TBL"); [ -n "$BSIZE" ] || BSIZE=0
  printf '%s\t%s\t%s\n' "$BSIZE" "$BASE_NAME" "base.apk" >> "$SEL_LIST"
  printf '%s|%s|base||1|base_required\n' "$BASE_NAME" "$BSIZE" >> "$ENTRY_OUT"

  while IFS='	' read -r SZ NAME; do
    [ -n "$NAME" ] || continue
    [ "$NAME" = "$BASE_NAME" ] && continue
    classify "$NAME"; KIND=$CKIND; TOK=$CTOK
    SEL=0; RSN="feature_required"
    case "$KIND" in
      master) SEL=1; RSN="module_master";;
      abi)
        if [ -n "$SEL_ABI" ] && [ "$(norm "$TOK")" = "$(norm "$SEL_ABI")" ]; then SEL=1; RSN="abi_best"
        elif contains_word "$DEV_ABILIST" "$TOK"; then SEL=0; RSN="abi_lower"
        else SEL=0; RSN="abi_unsupported"; fi
        ;;
      dpi)
        case "$TOK" in
          nodpi|anydpi) SEL=1; RSN="dpi_universal";;
          *) if [ "$TOK" = "$SEL_DPI" ]; then SEL=1; RSN="dpi_best"; else SEL=0; RSN="dpi_other"; fi;;
        esac
        ;;
      lang)
        # --mode all 也是"语言全装"，理由码要和 --lang all 一致，否则 UI 在
        # "全部分片"模式下把已选中的 en/ru 标成"非系统语言"。
        if [ "$LANGPOL" = "all" ] || [ "$MODE" = "all" ]; then SEL=1; RSN="lang_all"
        elif [ -n "$SEL_LANGS" ] && contains_word "$SEL_LANGS" "$TOK"; then
          SEL=1
          if [ "$SEL_LANG_KIND" = "default" ]; then RSN="lang_default"; else RSN="lang_system"; fi
        else SEL=0; RSN="lang_other"; fi
        ;;
      other)
        case "$(printf '%s' "$NAME" | tr 'A-Z' 'a-z')" in
          *.apk) SEL=1; RSN="feature_required";;
          *) SEL=0; RSN="not_apk";;
        esac
        ;;
    esac
    [ "$RSN" = "not_apk" ] && SEL=0
    printf '%s|%s|%s|%s|%s|%s\n' "$NAME" "$SZ" "$KIND" "$TOK" "$SEL" "$RSN" >> "$ENTRY_OUT"
    if [ "$SEL" = 1 ]; then
      SN=$(printf '%s' "$(basename "$NAME")" | sed 's/[^A-Za-z0-9._-]/_/g')
      printf '%s\t%s\t%s\n' "$SZ" "$NAME" "$SN" >> "$SEL_LIST"
    fi
  done < "$TBL"

  # standalone / universal 包：一个文件就是完整应用，只能装一个。
  # 按设备 ABI/密度挑最合适的那个（挑错 ABI 会 INSTALL_FAILED_NO_MATCHING_ABIS）。
  if [ "$BASE_KIND" = "standalone" ]; then
    BEST=$(awk -F'\t' -v abilist="$DEV_ABILIST" -v dpi="$SEL_DPI" '
      function nz(s) { gsub(/[-_]/, "", s); return tolower(s) }
      BEGIN {
        nd = split(abilist, dv, ",")
        n = dpi + 0
        if (n >= 560) db = "xxxhdpi"
        else if (n >= 400) db = "xxhdpi"
        else if (n >= 280) db = "xhdpi"
        else if (n >= 200) db = "hdpi"
        else if (n >= 140) db = "mdpi"
        else db = "ldpi"
      }
      { p = tolower($2)
        if (p !~ /\.apk$/) next
        if (p !~ /(^|\/)standalones?\// && p !~ /(^|\/)universal\.apk$/) next
        pn = nz(p)
        # 按设备 abilist 的优先序取"设备支持且包内存在"的最佳 ABI；主 ABI 缺席时
        # （32 位包在 arm64 设备上）能退到下一个 ABI，否则会挑到 arm64 包直接
        # INSTALL_FAILED_NO_MATCHING_ABIS。999 = 文件名里没有任何设备支持的 ABI。
        ra = 999
        for (i = 1; i <= nd; i++) { if (index(pn, nz(dv[i])) > 0) { ra = i; break } }
        d = (index(pn, nz(db)) > 0 || index(pn, dpi) > 0) ? 1 : 0
        if (b == "" || ra < bra || (ra == bra && d > bd) || (ra == bra && d == bd && $1 + 0 > bs)) {
          bra = ra; bd = d; bs = $1 + 0; b = $2
        } }
      END { print b }' "$TBL")
    if [ -n "$BEST" ]; then
      BASE_NAME="$BEST"
      BSIZE=$(tbl_get "$BASE_NAME" "$TBL"); [ -n "$BSIZE" ] || BSIZE=0
      : > "$SEL_LIST"
      printf '%s\t%s\t%s\n' "$BSIZE" "$BASE_NAME" "base.apk" >> "$SEL_LIST"
      : > "$ENTRY_OUT"
      printf '%s|%s|base||1|standalone_pack\n' "$BASE_NAME" "$BSIZE" >> "$ENTRY_OUT"
      awk -F'\t' -v b="$BASE_NAME" \
        '{ if ($2 != b) printf "%s|%s|other||0|standalone_other\n", $2, $1 }' "$TBL" >> "$ENTRY_OUT"
    fi
    MODE="auto"
  fi

  # 模式覆盖（standalone 已被上面的 MODE=auto 跳过，避免把别的架构/密度也装进去）
  case "$MODE" in
    all)
      : > "$SEL_LIST"
      printf '%s\t%s\t%s\n' "$BSIZE" "$BASE_NAME" "base.apk" >> "$SEL_LIST"
      while IFS='	' read -r SZ NAME; do
        [ -n "$NAME" ] || continue
        [ "$NAME" = "$BASE_NAME" ] && continue
        case "$(printf '%s' "$NAME" | tr 'A-Z' 'a-z')" in
          *.apk) SN=$(printf '%s' "$(basename "$NAME")" | sed 's/[^A-Za-z0-9._-]/_/g')
                 printf '%s\t%s\t%s\n' "$SZ" "$NAME" "$SN" >> "$SEL_LIST";;
        esac
      done < "$TBL"
      ;;
    manual)
      : > "$SEL_LIST"
      printf '%s\t%s\t%s\n' "$BSIZE" "$BASE_NAME" "base.apk" >> "$SEL_LIST"
      printf '%s\n' "$SPLITS" | tr ',' '\n' | while read -r WANT; do
        [ -n "$WANT" ] || continue
        [ "$WANT" = "$BASE_NAME" ] && continue
        SZ=$(tbl_get "$WANT" "$TBL")
        [ -n "$SZ" ] || continue
        SN=$(printf '%s' "$(basename "$WANT")" | sed 's/[^A-Za-z0-9._-]/_/g')
        printf '%s\t%s\t%s\n' "$SZ" "$WANT" "$SN" >> "$SEL_LIST"
      done
      ;;
  esac

  # ENTRY 的 sel 必须与"真正写进会话的分片表"(SEL_LIST) 一致，否则 --mode all /
  # --mode manual 下 UI 会把一条分片显示成"已选中"而安装时又不写它（v1.3.0 的
  # 手动模式就是这样：ENTRY 说 arm64_v8a 已选，实际列表里没有）。
  entry_sync_sel

  sel_stats

  # 图标提取放在最后：此时 BASE_APK_FILE / BUNDLE_TYPE / META_PKG 都已就绪
  probe_icon

  return 0
}

# ENTRY 的 sel 字段 = "这条分片会不会被写进 pm 会话"，以 SEL_LIST 为准。
# 分类原因码（base_required / abi_best / lang_other ...）保持不变：它回答的是
# "为什么（自动模式会）选/不选它"，两种模式共用同一套词典。
entry_sync_sel() {
  [ -s "$SEL_LIST" ] || return 0
  cut -f2 "$SEL_LIST" > "$TMP/.selnames" 2>/dev/null || return 0
  awk -F'|' -v OFS='|' '
    NR == FNR { keep[$1] = 1; next }
    { want = (keep[$1] == 1) ? 1 : 0
      if ($5 != want) $5 = want
      print }' "$TMP/.selnames" "$ENTRY_OUT" > "$TMP/.entry_tmp" || return 1
  cat "$TMP/.entry_tmp" > "$ENTRY_OUT"
  rm -f "$TMP/.selnames" "$TMP/.entry_tmp"
}

print_meta() {
  rec META "engine_version|$APKMT_VERSION"
  rec META "bundle|$BUNDLE"
  rec META "bundle_size|$FILESIZE"
  rec META "bundle_type|$BUNDLE_TYPE"
  rec META "pkg|$META_PKG"
  rec META "pkg_source|$META_PKG_SRC"
  rec META "label|$META_LABEL"
  rec META "label_src|${META_LABEL_SRC:-none}"
  rec META "icon|$ICON_REL"
  rec META "icon_src|$ICON_SRC"
  rec META "icon_bg|$ICON_BG"
  rec META "icon_scale|$ICON_SCALE"
  rec META "label_ref|$META_LABEL_REF"
  rec META "icon_ref|$META_ICON_REF"
  rec META "version|$META_VERSION"
  rec META "version_code|$META_VCODE"
  rec META "min_api|$META_MINAPI"
  rec META "target_api|$META_TGTAPI"
  rec META "entry_count|$EC"
  rec META "selected_count|$SELECTED_COUNT"
  rec META "total_bytes|$TOTAL_BYTES"
  rec META "device_sdk|$DEV_SDK"
  rec META "device_release|$DEV_RELEASE"
  rec META "device_model|$DEV_MODEL"
  rec META "device_abi|$DEV_ABI_PRIMARY"
  rec META "device_abilist|$DEV_ABILIST"
  rec META "device_density|$DEV_DENSITY"
  rec META "device_density_physical|$DEV_DENSITY_PHYS"
  rec META "device_density_override|$DEV_DENSITY_OVERRIDE"
  rec META "device_locale|$DEV_LOCALE"
  rec META "selected_dpi|$SEL_DPI"
  rec META "selected_abi|$SEL_ABI"
  rec META "base_kind|$BASE_KIND"
  rec META "base_sel|$BASE_NAME"
  rec META "unzip|$UNZIP"
  rec META "tmp|$TMP"
}

# ---------------------------------------------------------------- inspect

cmd_inspect() {
  init_tmp
  probe_device
  TBL="$TMP/table"; SEL_LIST="$TMP/sel"; ENTRY_OUT="$TMP/entries"; DPI_LIST="$TMP/dpi"; ABI_LIST="$TMP/abi"; LANG_LIST="$TMP/lang"
  prepare "$BUNDLE" "$MODE" "$SPLITS" "$LANGPOL" || { cleanup_tmp; return 1; }
  print_meta
  while IFS= read -r l; do [ -n "$l" ] && say "ENTRY|$l"; done < "$ENTRY_OUT"
  rec META "free_bytes|$(df -k /data 2>/dev/null | awk 'NR==2{print $4*1024}')"
  cleanup_tmp
  return 0
}

# ---------------------------------------------------------------- install

create_session() { # $1 = extra flags, $2 = total bytes
  OUT=$("$PM" install-create $1 -S "$2" 2>&1)
  printf '%s\n' "$OUT" > "$TMP/create.out"
  SID=$(printf '%s' "$OUT" | sed -n 's/.*\[\([0-9][0-9]*\)\].*/\1/p' | head -1)
  [ -n "$SID" ]
}

cmd_install() {
  init_tmp
  probe_device
  TBL="$TMP/table"; SEL_LIST="$TMP/sel"; ENTRY_OUT="$TMP/entries"; DPI_LIST="$TMP/dpi"; ABI_LIST="$TMP/abi"; LANG_LIST="$TMP/lang"
  prepare "$BUNDLE" "$MODE" "$SPLITS" "$LANGPOL" || { cleanup_tmp; return 1; }

  find_pm || { rec RESULT "FAIL|NO_PM|pm not found"; cleanup_tmp; return 1; }
  [ "$SELECTED_COUNT" -gt 0 ] || { rec RESULT "FAIL|NO_SELECTION|nothing selected"; cleanup_tmp; return 1; }

  FREE=$(df -k /data 2>/dev/null | awk 'NR==2{print $4*1024}')
  rec META "free_bytes|$FREE"
  rec META "total_bytes|$TOTAL_BYTES"
  # 不可写成 [ "$FREE" -lt "$TOTAL_BYTES" ]：mksh 的 [ 是 32 位，
  # 400GB 空闲会被读成负数，导致永远误报空间不足
  if [ -n "$FREE" ] && awk -v f="$FREE" -v t="$TOTAL_BYTES" 'BEGIN{exit !(f+0 < t+0)}'; then
    rec RESULT "FAIL|INSUFFICIENT_STORAGE|need $(fmt_size "$TOTAL_BYTES") free $(fmt_size "$FREE")"
    cleanup_tmp; return 1
  fi

  if [ "$DRY_RUN" = 1 ]; then
    rec PROGRESS "0|dry_run|0|$TOTAL_BYTES"
    rec RESULT "OK|||dry_run"
    cleanup_tmp; return 0
  fi

  # 组装 create 参数
  FLAGS="-r"
  [ "$DOWNGRADE" = 1 ] && FLAGS="$FLAGS -d"
  [ -n "$GRANT" ] && [ "$GRANT" = 1 ] && FLAGS="$FLAGS -g"
  [ -n "$INSTALLER" ] && FLAGS="$FLAGS -i $INSTALLER"
  [ -n "$USER_ID" ] && FLAGS="$FLAGS --user $USER_ID"
  # 低 targetSdk 拦截（A14+/SDK34 起才有该 flag）：targetSdk<23 必加；
  # targetSdk 未知（APKMirror 的 info.json 没有 target_api 键）时也加 ——
  # 该 flag 只在“targetSdk 低于下限被拦”时起作用，对正常包无副作用。
  if [ -z "$META_TGTAPI" ] || [ "$META_TGTAPI" -lt 23 ] 2>/dev/null; then
    case "$DEV_SDK" in
      ''|*[!0-9]*) ;;
      *) [ "$DEV_SDK" -ge 34 ] && FLAGS="$FLAGS --bypass-low-target-sdk-block";;
    esac
  fi

  rec PROGRESS "1|creating_session|0|$TOTAL_BYTES"
  if ! create_session "$FLAGS" "$TOTAL_BYTES"; then
    rec DETAIL "$(cat "$TMP/create.out" 2>/dev/null)"
    # 逐级降级重试
    if [ "$GRANT" = 1 ]; then
      rec LOG "retry_without_grant"
      FLAGS=$(printf '%s' "$FLAGS" | sed 's/ -g//')
      create_session "$FLAGS" "$TOTAL_BYTES" || {
        rec DETAIL "$(cat "$TMP/create.out" 2>/dev/null)"; rec RESULT "FAIL|CREATE_FAILED|pm install-create failed"; cleanup_tmp; return 1; }
    else
      rec RESULT "FAIL|CREATE_FAILED|pm install-create failed"; cleanup_tmp; return 1
    fi
  fi
  rec LOG "session|$SID"

  DONE=0; N=0
  while IFS='	' read -r SZ NAME SNAME; do
    [ -n "$NAME" ] || continue
    N=$((N + 1))
    rec LOG "write|$N|$SELECTED_COUNT|$SNAME|$SZ|"
    if [ "$IS_SINGLE_ZIP" = 1 ]; then
      ERROUT=$(cat "$BUNDLE" 2>&1 | "$PM" install-write -S "$SZ" "$SID" "$SNAME" - 2>&1)
    else
      ERROUT=$($UNZIP -p "$BUNDLE" "$NAME" 2>&1 | "$PM" install-write -S "$SZ" "$SID" "$SNAME" - 2>&1)
    fi
    case "$ERROUT" in
      *"Success"*) ;;
      *) rec DETAIL "$ERROUT"; rec RESULT "FAIL|WRITE_FAILED|$SNAME"; "$PM" install-abandon "$SID" >/dev/null 2>&1; cleanup_tmp; return 1;;
    esac
    # 字节累计与百分比一律交给 awk：mksh 的 $(( )) 是 32 位，
    # 仅 74MB*88 就会溢出翻转成负数
    DONE=$(awk -v a="$DONE" -v b="$SZ" 'BEGIN{printf "%.0f", a+b}')
    PCT=$(awk -v d="$DONE" -v t="$TOTAL_BYTES" 'BEGIN{if(t+0<=0)t=1; p=int(d*88/t)+5; if(p>93)p=93; print p}')
    rec PROGRESS "$PCT|writing|$DONE|$TOTAL_BYTES|$N|$SELECTED_COUNT"
  done < "$SEL_LIST"

  if [ "$TEST_WRITE" = 1 ]; then
    "$PM" install-abandon "$SID" >/dev/null 2>&1
    rec LOG "session_abandoned|$SID"
    rec PROGRESS "100|write_test_ok|$DONE|$TOTAL_BYTES"
    rec RESULT "OK|||write_test_ok"
    cleanup_tmp; return 0
  fi

  rec PROGRESS "95|committing|$DONE|$TOTAL_BYTES"
  COUT=$("$PM" install-commit "$SID" 2>&1)
  rec DETAIL "$COUT"
  case "$COUT" in
    *"Success"*)
      V=""
      if [ -n "$META_PKG" ]; then
        V=$("$PM" dump "$META_PKG" 2>/dev/null | sed -n 's/.*versionName=\([^ ]*\).*/\1/p' | head -1)
        [ -n "$V" ] || V="$META_VERSION"
      fi
      rec PROGRESS "100|done|$TOTAL_BYTES|$TOTAL_BYTES"
      rec RESULT "OK|$META_PKG|$V|installed"
      # 历史记录统一走 hist_add：<epoch>|OK|<pkg>|<ver>|<mode>|installed|<bundle>
      # （旧实现写的是 ISO 时间 + 空格分隔，WebUI 的按 | 切列解析器读不了）
      hist_add OK "$META_PKG" "$V" "installed"
      cleanup_tmp; return 0
      ;;
    *)
      CODE=$(printf '%s' "$COUT" | sed -n 's/.*Failure \[\([A-Z_0-9]*\).*/\1/p' | head -1)
      [ -n "$CODE" ] || CODE="COMMIT_FAILED"
      MSG=$(printf '%s' "$COUT" | sed -n 's/.*Failure \[[^]]*\]:* *\(.*\)\]*/\1/p' | head -1)
      rec RESULT "FAIL|$CODE|$MSG"
      hist_add FAIL "$META_PKG" "$META_VERSION" "$CODE"
      cleanup_tmp; return 1
      ;;
  esac
}

# ---------------------------------------------------------------- action

cmd_action() {
  say "APKM 直装器 v$APKMT_VERSION - 扫描下载目录"
  FOUND=""
  for d in /sdcard/Download /sdcard/Downloads /sdcard; do
    [ -d "$d" ] || continue
    for f in "$d"/*.apkm "$d"/*.apks "$d"/*.xapk "$d"/*.apk; do
      [ -f "$f" ] || continue
      mt=$(stat -c %Y "$f" 2>/dev/null); [ -n "$mt" ] || mt=0
      cost=$(stat -c %s "$f" 2>/dev/null); [ -n "$cost" ] || cost=0
      FOUND=1
    done
  done
  if [ -z "$FOUND" ]; then
    say ""
    say "没找到可安装的包。请把 .apkm/.apks/.xapk/.apk 放到 /sdcard/Download，"
    say "或直接打开 WebUI 图形界面选择文件。"
    return 0
  fi
  say ""
  TARGET=$(say_above | sort -rn | head -1 | cut -d'|' -f3)
  say "最新文件：$TARGET"
  say "----------------------------------------"
  MODE=auto LANGPOL=sys BUNDLE="$TARGET"
  init_tmp
  probe_device
  TBL="$TMP/table"; SEL_LIST="$TMP/sel"; ENTRY_OUT="$TMP/entries"; DPI_LIST="$TMP/dpi"; ABI_LIST="$TMP/abi"; LANG_LIST="$TMP/lang"
  prepare "$BUNDLE" auto "" sys || { cleanup_tmp; return 1; }
  say "包信息：type=$BUNDLE_TYPE pkg=${META_PKG:-?} ver=${META_VERSION:-?}"
  say "共 $SELECTED_COUNT 个拆分，合计 $(fmt_size "$TOTAL_BYTES")，开始安装..."
  say "----------------------------------------"
  cleanup_tmp
  cmd_install
}

# 供 cmd_action 复用：把前面打印的文件行重新取出来（简化：直接重扫）
say_above() {
  for d in /sdcard/Download /sdcard/Downloads /sdcard; do
    [ -d "$d" ] || continue
    for f in "$d"/*.apkm "$d"/*.apks "$d"/*.xapk "$d"/*.apk; do
      [ -f "$f" ] || continue
      mt=$(stat -c %Y "$f" 2>/dev/null); [ -n "$mt" ] || mt=0
      sz=$(stat -c %s "$f" 2>/dev/null); [ -n "$sz" ] || sz=0
      printf '%s|%s|%s\n' "$mt" "$sz" "$f"
    done
  done
}

# ---------------------------------------------------------------- diag

cmd_diag() {
  probe_device
  rec DIAG "engine_version|$APKMT_VERSION"
  rec DIAG "uid|$(id -u 2>/dev/null)"
  rec DIAG "whoami|$(id 2>/dev/null)"
  if find_unzip; then rec DIAG "unzip|$UNZIP"; else rec DIAG "unzip|NOT_FOUND"; fi
  if find_pm; then rec DIAG "pm|$PM"; else rec DIAG "pm|NOT_FOUND"; fi
  rec DIAG "busybox|$(command -v busybox 2>/dev/null || echo none)"
  rec DIAG "ksu_busybox|$([ -x /data/adb/ksu/bin/busybox ] && echo yes || echo no)"
  rec DIAG "state_dir|$STATE_DIR"
  if mkdir -p "$STATE_DIR" 2>/dev/null; then rec DIAG "state_dir_writable|yes"; else rec DIAG "state_dir_writable|no"; fi
  # 图标链路（v1.3.2）：模块目录解析不到 / 不可写时，前端只能显示字母或已装图标
  MDR=$(moddir_get 2>/dev/null)
  rec DIAG "moddir|${MDR:-NOT_FOUND}"
  if [ -n "$MDR" ]; then
    if mkdir -p "$MDR/webroot/icon-cache" 2>/dev/null; then
      rec DIAG "icon_cache|$MDR/webroot/icon-cache"
      rec DIAG "icon_cache_writable|yes"
      rec DIAG "icon_cache_count|$(ls -1 "$MDR/webroot/icon-cache" 2>/dev/null | wc -l | tr -d ' ')"
    else
      rec DIAG "icon_cache|NOT_WRITABLE"
    fi
  fi
  rec DIAG "device_sdk|$DEV_SDK"
  rec DIAG "device_release|$DEV_RELEASE"
  rec DIAG "device_model|$DEV_MODEL"
  rec DIAG "device_abi|$DEV_ABI_PRIMARY ($DEV_ABILIST)"
  rec DIAG "device_density|$DEV_DENSITY"
  rec DIAG "device_locale|$DEV_LOCALE"
  rec DIAG "free_data|$(df -k /data 2>/dev/null | awk 'NR==2{print $4*1024}')"
}

# ---------------------------------------------------------------- 参数解析

cmd_usage() {
  say "apkmt.sh <diag|list|inspect|install|action> [args]"
  say "  install <bundle> [--mode auto|all|manual] [--splits a,b] [--lang sys|all]"
  say "                   [--user N] [--installer PKG] [--downgrade] [--grant]"
  say "                   [--dry-run] [--test-write]"
}

BUNDLE=""; MODE="auto"; SPLITS=""; LANGPOL="sys"; USER_ID=""; INSTALLER=""; DOWNGRADE=0; GRANT=0; DRY_RUN=0; TEST_WRITE=0

CMD="${1:-}"; [ $# -gt 0 ] && shift

case "$CMD" in
  diag) cmd_diag; exit $?;;
  list) cmd_list "$@"; exit $?;;
  inspect|install|action) ;;
  *) cmd_usage; exit 1;;
esac

if [ "$CMD" != "action" ]; then
  case "$1" in
    -*) ;;
    "") cmd_usage; exit 1;;
    *) BUNDLE="$1"; shift;;
  esac
fi

while [ $# -gt 0 ]; do
  case "$1" in
    --mode) MODE="$2"; shift 2;;
    --splits) SPLITS="$2"; shift 2;;
    --lang) LANGPOL="$2"; shift 2;;
    --user) USER_ID="$2"; shift 2;;
    --installer) INSTALLER="$2"; shift 2;;
    --downgrade) DOWNGRADE=1; shift;;
    --grant) GRANT=1; shift;;
    --dry-run) DRY_RUN=1; shift;;
    --test-write) TEST_WRITE=1; shift;;
    *) shift;;
  esac
done

case "$CMD" in
  inspect) cmd_inspect; exit $?;;
  install) cmd_install; exit $?;;
  action) cmd_action; exit $?;;
esac
