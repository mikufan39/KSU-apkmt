#!/system/bin/sh
# ==============================================================================
#  APKM 直装器 (apkmt) 引擎  v1.0.0
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
#  用法：
#    apkmt.sh diag
#    apkmt.sh list <dir>
#    apkmt.sh inspect <bundle> [--mode auto|all|manual] [--splits a,b] [--lang sys|all]
#    apkmt.sh install <bundle> [--mode ...] [--splits ...] [--lang ...] [--user N]
#                               [--installer PKG] [--downgrade] [--grant] [--dry-run]
#                               [--test-write]  仅流式写入后 abandon（不提交，诊断用）
#    apkmt.sh action
# ==============================================================================

APKMT_VERSION="1.0.0"
STATE_DIR="/data/adb/apkmt"
TMP_BASE="/data/local/tmp/apkmt"

PATH="/system/bin:/system/xbin:$PATH"
[ -d /data/adb/ksu/bin ] && PATH="/data/adb/ksu/bin:$PATH"
export PATH
LC_ALL=C
export LC_ALL

# ---------------------------------------------------------------- 基础工具

say() { printf '%s\n' "$*"; }
rec() { printf '%s|%s\n' "$1" "$2"; }

# 历史记录落盘位置（root 下用 STATE_DIR，非 root 调试时退回 TMP_BASE）
hist_file() {
  if [ -d "$STATE_DIR" ] && [ -w "$STATE_DIR" ]; then echo "$STATE_DIR/history.log"
  else echo "$TMP_BASE/history.log"; fi
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
  DEV_DENSITY=$(wm density 2>/dev/null | sed -n 's/.*[Pp]hysical density: *\([0-9][0-9]*\).*/\1/p' | head -1)
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

# 找出基础包（base）
find_base() {
  T="$1"
  B=$(awk -F'\t' 'tolower($2) == "base.apk" { print $2; exit }' "$T")
  [ -n "$B" ] && { printf '%s' "$B"; return; }
  B=$(awk -F'\t' 'tolower($2) == "base-master.apk" { print $2; exit }' "$T")
  [ -n "$B" ] && { printf '%s' "$B"; return; }
  # 无 split/config/master 字样的最大 apk
  B=$(awk -F'\t' 'tolower($2) ~ /\.apk$/ && tolower($2) !~ /split|config|master/ { print $1 "\t" $2 }' "$T" | sort -rn | head -1 | cut -f2)
  [ -n "$B" ] && { printf '%s' "$B"; return; }
  # 兜底：最大 apk
  awk -F'\t' 'tolower($2) ~ /\.apk$/ { print $1 "\t" $2 }' "$T" | sort -rn | head -1 | cut -f2
}

# 分类：结果写入全局 CKIND / CTOK（kind: base|abi|dpi|lang|other）
# 禁止在这里用命令替换 + "${x%%|*}" 解析：Android 的 mksh(R59) 把模式里的 '|'
# 当作交替符，${c%%|*} 会返回空串（kernelsu 的 busybox ash 则不会），两边行为不一致。
classify() {
  CKIND="other"; CTOK=""
  n=$(basename "$1"); s=$(printf '%s' "$n" | tr 'A-Z' 'a-z')
  case "$s" in *.apk) ;; *) return;; esac
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
  # 语言：bundletool b+zh+Hans / 末段 xx / 末段 -rXX
  case "$stem" in
    *b+*)
      L=$(printf '%s' "$stem" | sed -n 's/.*b+\([a-z][a-z][a-z]*\).*/\1/p')
      [ -n "$L" ] && { CKIND="lang"; CTOK="$L"; return; }
      ;;
  esac
  last=${stem##*.}; last=${last##*-}
  case "$last" in
    [a-z][a-z]|[a-z][a-z][a-z]) CKIND="lang"; CTOK="$last"; return;;
  esac
  case "$stem" in
    *-r[a-z][a-z])
      L=$(printf '%s' "$stem" | sed -n 's/.*-r\([a-z][a-z]\)$/\1/p')
      [ -n "$L" ] && { CKIND="lang"; CTOK="$L"; return; }
      ;;
  esac
}

# ---------------------------------------------------------------- 元信息

meta_from_json() {
  J="$1"
  V=$(printf '%s' "$J" | sed -n 's/.*"pname"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
  [ -n "$V" ] || V=$(printf '%s' "$J" | sed -n 's/.*"package_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
  [ -n "$V" ] && { META_PKG="$V"; META_PKG_SRC="info.json"; }

  V=$(printf '%s' "$J" | sed -n 's/.*"release_version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
  [ -n "$V" ] || V=$(printf '%s' "$J" | sed -n 's/.*"version_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
  [ -n "$V" ] && META_VERSION="$V"

  V=$(printf '%s' "$J" | sed -n 's/.*"versioncode"[[:space:]]*:[[:space:]]*"\([0-9][0-9]*\)".*/\1/p' | head -1)
  [ -n "$V" ] || V=$(printf '%s' "$J" | sed -n 's/.*"version_code"[[:space:]]*:[[:space:]]*"\([0-9][0-9]*\)".*/\1/p' | head -1)
  [ -n "$V" ] && META_VCODE="$V"

  V=$(printf '%s' "$J" | sed -n 's/.*"min_api"[[:space:]]*:[[:space:]]*"*\([0-9][0-9]*\).*/\1/p' | head -1)
  [ -n "$V" ] || V=$(printf '%s' "$J" | sed -n 's/.*"min_sdk_version"[[:space:]]*:[[:space:]]*"*\([0-9][0-9]*\).*/\1/p' | head -1)
  [ -n "$V" ] && META_MINAPI="$V"

  V=$(printf '%s' "$J" | sed -n 's/.*"target_api"[[:space:]]*:[[:space:]]*"*\([0-9][0-9]*\).*/\1/p' | head -1)
  [ -n "$V" ] || V=$(printf '%s' "$J" | sed -n 's/.*"target_sdk_version"[[:space:]]*:[[:space:]]*"*\([0-9][0-9]*\).*/\1/p' | head -1)
  [ -n "$V" ] && META_TGTAPI="$V"

  V=$(printf '%s' "$J" | sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
  [ -n "$V" ] || V=$(printf '%s' "$J" | sed -n 's/.*"app_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
  [ -n "$V" ] || V=$(printf '%s' "$J" | sed -n 's/.*"apk_title"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
  [ -n "$V" ] || V=$(printf '%s' "$J" | sed -n 's/.*"release_title"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
  [ -n "$V" ] && META_LABEL="$V"
}

meta_from_bundle() {
  # 1) info.json / manifest.json / meta.json
  METAFILE=$(awk -F'\t' 'tolower($2) ~ /(^|\/)(info|manifest|meta)\.json$/ { print $2; exit }' "$TBL")
  if [ -n "$METAFILE" ]; then
    J=$($UNZIP -p "$BUNDLE" "$METAFILE" 2>/dev/null | tr '\n' ' ' | head -c 65536)
    meta_from_json "$J"
  fi
  # 2) toc.pb（bundletool / SAI 的 .apks）：从二进制里捞包名
  if [ -z "$META_PKG" ] && awk -F'\t' 'tolower($2) == "toc.pb" { found=1 } END { exit !found }' "$TBL"; then
    C=$($UNZIP -p "$BUNDLE" toc.pb 2>/dev/null | strings 2>/dev/null | grep -E '^[a-z][a-z0-9_]*(\.[a-z0-9_]+)+$' | grep -vE '^(android|androidx|com\.android|java|kotlin|org\.)' | head -1)
    [ -n "$C" ] && { META_PKG="$C"; META_PKG_SRC="toc.pb(guess)"; }
  fi
}

# ---------------------------------------------------------------- 选择策略

# 全局：SEL_LIST(name<TAB>size<TAB>session_name)  ENTRY_OUT(name|size|kind|token|sel|reason)
#       TOTAL_BYTES  SELECTED_COUNT  BASE_NAME  BUNDLE_TYPE
prepare() {
  BUNDLE="$1"
  MODE="$2"; SPLITS="$3"; LANGPOL="$4"

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
    UNZIP="${UNZIP:-none}"
    : > "$SEL_LIST"; printf '%s\t%s\t%s\n' "$FILESIZE" "$BUNDLE" "base.apk" >> "$SEL_LIST"
    : > "$ENTRY_OUT"; printf 'base.apk|%s|base||1|base_required\n' "$FILESIZE" >> "$ENTRY_OUT"
    META_PKG_SRC="none"
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

  # 设备上最优密度
  awk -F'\t' '{print $2}' "$TBL" | while read -r e; do
    classify "$e"
    [ "$CKIND" = "dpi" ] || continue
    case "$CTOK" in nodpi|anydpi) ;; *) printf '%s\n' "$CTOK";; esac
  done > "$DPI_LIST"
  if [ -s "$DPI_LIST" ]; then
    SEL_DPI=$(awk -v dev="$DEV_DENSITY" 'BEGIN{b="";bd=0}
      { d=$1+0; if (d<=0) next; x=d/dev; if (x<1) x=1/x;
        r=0; while (x>1.0000001) { x/=2; r++ }   # 桶间距（2 的幂近似）
        if (b=="" || r<bd) { b=$1; bd=r } }
      END{print b}' "$DPI_LIST")
  fi

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
        if [ "$(norm "$TOK")" = "$(norm "$DEV_ABI_PRIMARY")" ]; then SEL=1; RSN="abi_primary"
        elif contains_word "$DEV_ABILIST" "$TOK"; then SEL=0; RSN="abi_secondary"
        else SEL=0; RSN="abi_unsupported"; fi
        ;;
      dpi)
        case "$TOK" in
          nodpi|anydpi) SEL=1; RSN="dpi_universal";;
          *) if [ "$TOK" = "$SEL_DPI" ]; then SEL=1; RSN="dpi_best"; else SEL=0; RSN="dpi_other"; fi;;
        esac
        ;;
      lang)
        if [ "$LANGPOL" = "all" ]; then SEL=1; RSN="lang_all"
        elif [ "$TOK" = "$DEV_LANG" ] || [ "$TOK" = "en" ]; then SEL=1; RSN="lang_system"
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

  # 模式覆盖
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
      printf '%s' "$SPLITS" | tr ',' '\n' | while read -r WANT; do
        [ -n "$WANT" ] || continue
        [ "$WANT" = "$BASE_NAME" ] && continue
        SZ=$(tbl_get "$WANT" "$TBL")
        [ -n "$SZ" ] || continue
        SN=$(printf '%s' "$(basename "$WANT")" | sed 's/[^A-Za-z0-9._-]/_/g')
        printf '%s\t%s\t%s\n' "$SZ" "$WANT" "$SN" >> "$SEL_LIST"
      done
      ;;
  esac

  # 统一统计（必须走 awk：Android mksh 的 $(( )) 与 [ ] 都是 32 位有符号，
  # 只要包体 >2GiB 或空闲空间 >2GiB 就会溢出翻转，得到负数）
  SELECTED_COUNT=$(wc -l < "$SEL_LIST" | tr -d ' ')
  TOTAL_BYTES=$(awk -F'\t' '{s += $1} END{printf "%.0f", s+0}' "$SEL_LIST")

  return 0
}

print_meta() {
  rec META "engine_version|$APKMT_VERSION"
  rec META "bundle|$BUNDLE"
  rec META "bundle_size|$FILESIZE"
  rec META "bundle_type|$BUNDLE_TYPE"
  rec META "pkg|$META_PKG"
  rec META "pkg_source|$META_PKG_SRC"
  rec META "label|$META_LABEL"
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
  rec META "device_locale|$DEV_LOCALE"
  rec META "selected_dpi|$SEL_DPI"
  rec META "unzip|$UNZIP"
  rec META "tmp|$TMP"
}

# ---------------------------------------------------------------- inspect

cmd_inspect() {
  init_tmp
  probe_device
  TBL="$TMP/table"; SEL_LIST="$TMP/sel"; ENTRY_OUT="$TMP/entries"; DPI_LIST="$TMP/dpi"
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
  TBL="$TMP/table"; SEL_LIST="$TMP/sel"; ENTRY_OUT="$TMP/entries"; DPI_LIST="$TMP/dpi"
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
      echo "$(date +%Y-%m-%dT%H:%M:%S) OK $BUNDLE pkg=$META_PKG ver=$V" >> "$(hist_file)" 2>/dev/null
      cleanup_tmp; return 0
      ;;
    *)
      CODE=$(printf '%s' "$COUT" | sed -n 's/.*Failure \[\([A-Z_0-9]*\).*/\1/p' | head -1)
      [ -n "$CODE" ] || CODE="COMMIT_FAILED"
      MSG=$(printf '%s' "$COUT" | sed -n 's/.*Failure \[[^]]*\]:* *\(.*\)\]*/\1/p' | head -1)
      rec RESULT "FAIL|$CODE|$MSG"
      echo "$(date +%Y-%m-%dT%H:%M:%S) FAIL $BUNDLE code=$CODE $MSG" >> "$(hist_file)" 2>/dev/null
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
  TBL="$TMP/table"; SEL_LIST="$TMP/sel"; ENTRY_OUT="$TMP/entries"; DPI_LIST="$TMP/dpi"
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
