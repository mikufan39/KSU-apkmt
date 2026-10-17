/* ============================================================================
 * apkmt WebUI — 前端应用
 *
 * 运行环境：KernelSU 管理器 WebView（mui.kernelsu.org），通过 window.ksu 以 root
 * 执行 shell。本文件除「渲染层」外，桥接方式、引擎子命令、记录协议、状态语义、
 * 落盘路径与 localStorage 前缀均与既有实现保持一致。
 *
 * 引擎记录协议（纯 ASCII，中文全部由本层词典映射）：
 *   META|key|value
 *   ENTRY|name|size|kind|token|sel|reason
 *   PROGRESS|pct|stage|done|total|splits_done|splits_total
 *   RESULT|OK|pkg|ver|msg            RESULT|FAIL|code|msg
 *   DETAIL|raw                       LOG|...
 *   DIAG|key|value
 *   LS|HDR|dir  LS|D|name|size|mtime  LS|F|name|size|mtime  LS|END|n
 *   LS|ERROR|...  LS|TRUNC|800
 * ========================================================================== */
(function () {
  'use strict';

  /* ================================================================ 桥接层 */

  var KSU = window.ksu || window.kernelsu || null;
  var cbSeq = 0;
  function cbName(prefix) { cbSeq += 1; return prefix + '_' + Date.now().toString(36) + '_' + cbSeq; }

  // 异步 exec：native 要求回调以「全局函数名」传入（它用 loadUrl 调 callback(...)）
  function exec(cmd, options) {
    return new Promise(function (resolve, reject) {
      if (!KSU || typeof KSU.exec !== 'function') { reject(new Error('NO_KSU')); return; }
      var name = cbName('exec');
      window[name] = function (errno, stdout, stderr) {
        try { delete window[name]; } catch (e) { window[name] = undefined; }
        resolve({ errno: errno, stdout: stdout || '', stderr: stderr || '' });
      };
      try { KSU.exec(cmd, JSON.stringify(options || {}), name); }
      catch (err) {
        try { delete window[name]; } catch (e2) { window[name] = undefined; }
        reject(err);
      }
    });
  }

  // 流式 spawn：整条命令交给 root shell，逐行回调
  function runStream(cmdline, onLine, onDone) {
    if (!KSU || typeof KSU.spawn !== 'function') { onDone(-1, 'NO_KSU'); return; }
    var name = cbName('spawn'), bufO = '', bufE = '', errText = '', finished = false;

    function finish(code) {
      if (finished) return;
      finished = true;
      if (bufO) { onLine(bufO.replace(/\r$/, ''), 'o'); bufO = ''; }
      if (bufE) { errText += bufE; bufE = ''; }
      try { delete window[name]; } catch (e) { window[name] = undefined; }
      onDone(code, errText);
    }

    function feed(raw, tag) {
      var d = String(raw == null ? '' : raw), buf;
      if (tag === 'o') { bufO += d; buf = bufO; } else { bufE += d; buf = bufE; }
      var out = [], rest = buf, idx;
      while ((idx = rest.indexOf('\n')) >= 0) { out.push(rest.slice(0, idx)); rest = rest.slice(idx + 1); }
      // 一次 data 回调可能是「一行」（libsu CallbackList 的常态，不带换行），
      // 也可能是「多行」（有宿主/预览桥接把若干行 join 成一个 chunk）。
      // 因此：换行切完后剩下的尾巴只要长得像一条完整记录，就当成一条完整记录发出，
      // 否则会与下一个 chunk 的首行粘成 `META|bundle_type|apkmMETA|pkg|...` 这种畸形记录。
      if (rest && /^[A-Za-z_]+\|/.test(rest)) { out.push(rest); rest = ''; }
      for (var i = 0; i < out.length; i++) {
        var l = out[i].replace(/\r$/, '');
        if (tag === 'o') { if (l !== '') onLine(l, 'o'); } else errText += l + '\n';
      }
      if (tag === 'o') bufO = rest; else bufE = rest;
    }

    var child = {
      stdout: { emit: function (ev, d) { if (ev === 'data') feed(d, 'o'); } },
      stderr: { emit: function (ev, d) { if (ev === 'data') feed(d, 'e'); } },
      emit: function (ev, d) {
        if (ev === 'error') errText += (d && d.message) ? String(d.message) : String(d);
        else if (ev === 'exit') finish(typeof d === 'number' ? d : parseInt(d, 10) || 0);
      }
    };

    window[name] = child;
    try { KSU.spawn(cmdline, '[]', '{}', name); }
    catch (err) {
      try { delete window[name]; } catch (e) { window[name] = undefined; }
      onDone(-1, String(err));
    }
  }

  /* ================================================================ 工具 */

  function byId(id) { return document.getElementById(id); }
  function show(node, on) { if (node) node.classList.toggle('hidden', !on); }
  function el(tag, cls, txt) { var e = document.createElement(tag); if (cls) e.className = cls; if (txt != null) e.textContent = txt; return e; }
  function setText(id, txt) { var n = byId(id); if (n) n.textContent = txt == null ? '' : String(txt); }
  function clear(node) { if (node) node.innerHTML = ''; }
  function esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"]/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c];
    });
  }
  function ico(name, cls) {
    return '<svg class="ico' + (cls ? ' ' + cls : '') + '" viewBox="0 0 24 24" aria-hidden="true"><use href="#i-' + name + '"/></svg>';
  }
  // 单引号 shell 引用
  function shq(s) { return "'" + String(s).replace(/'/g, "'\\''") + "'"; }
  function fmtSize(n) {
    n = Number(n || 0);
    if (!isFinite(n) || n <= 0) return '0 B';
    var u = ['B', 'KB', 'MB', 'GB', 'TB'], i = 0;
    while (n >= 1024 && i < u.length - 1) { n /= 1024; i += 1; }
    return (i === 0 ? n.toFixed(0) : (n < 10 ? n.toFixed(1) : n.toFixed(0))) + ' ' + u[i];
  }
  // 时间：秒级 epoch（历史 / 文件 mtime）格式化成 MM-DD HH:MM；传入无法解析的字符串
  // （旧记录时间戳损坏）时原样显示，绝不显示 NaN。
  function fmtTime(sec) {
    var raw = (sec == null) ? '' : String(sec).replace(/^\s+|\s+$/g, '');
    if (!raw) return '';
    var n = Number(raw);
    if (isFinite(n) && n > 0) {
      var d = new Date(n * 1000);
      if (!isNaN(d.getTime())) {
        var p = function (x) { return (x < 10 ? '0' : '') + x; };
        return p(d.getMonth() + 1) + '-' + p(d.getDate()) + ' ' + p(d.getHours()) + ':' + p(d.getMinutes());
      }
    }
    return isNaN(n) ? raw : '';
  }

  // 应用名：包内 label 优先，退回包名，再退回占位词（以前没有 label 的包只显示包名，
  // 用户看不出这是哪个应用；hero / 标题 / 完成页都用它）。
  function displayLabel(meta) {
    var m = meta || {};
    var label = String(m.label == null ? '' : m.label).replace(/^\s+|\s+$/g, '');
    if (label) return label;
    var pkg = String(m.pkg == null ? '' : m.pkg).replace(/^\s+|\s+$/g, '');
    return pkg || '未知应用';
  }

  // 图标候选（按优先级）：包内提取的图标（引擎给的是相对 webroot 的 URL）→ 已安装应用的
  // ksu:// 图标（只有包名非空才拼）→ 空数组，调用方回退到首字母兜底。
  function iconCandidates(meta) {
    var m = meta || {};
    var out = [];
    var icon = String(m.icon == null ? '' : m.icon).replace(/^\s+|\s+$/g, '');
    if (icon) out.push(icon);
    var pkg = String(m.pkg == null ? '' : m.pkg).replace(/^\s+|\s+$/g, '');
    if (pkg) out.push('ksu://icon/' + pkg);
    return out;
  }

  // 图标分层（v1.3.3）：自适应图标 = 背景层 + 前景层，引擎把各层信息分开给出：
  //   META|icon       前景（或整张图标）URL，自适应图标是 108dp 画布、可见安全区 72dp；
  //   META|icon_bg    '#rrggbb' / 'rgba(r,g,b,a)' 等合法 CSS 颜色 = 背景颜色，
  //                   其余非空值 = 背景图 URL（只有自适应图标才有背景层）；
  //   META|icon_scale 前景放大倍数（自适应图标 1.5，普通图标 1）。
  // 这里只做「元数据 → 渲染计划」的纯换算，方便单测；真正落 DOM 在 renderPkg 里。
  function iconPlan(meta) {
    var m = meta || {};
    var icon = String(m.icon == null ? '' : m.icon).replace(/^\s+|\s+$/g, '');
    var bg = String(m.icon_bg == null ? '' : m.icon_bg).replace(/^\s+|\s+$/g, '');
    var scale = Number(String(m.icon_scale == null ? '' : m.icon_scale).replace(/^\s+|\s+$/g, ''));
    if (!isFinite(scale) || scale <= 0) scale = 1;
    var bgLow = bg.toLowerCase();
    var isColor = !!bg && (bg.charAt(0) === '#' || bgLow.indexOf('rgb(') === 0 || bgLow.indexOf('rgba(') === 0 || bgLow === 'transparent');
    return {
      fgUrl: icon,
      bgColor: isColor ? bg : '',
      bgUrl: (bg && !isColor) ? bg : '',
      scale: scale,
      fallback: displayLabel(m).trim().charAt(0) || 'A'
    };
  }

  // icon_bg 的颜色按契约已与 CSS 兼容，直接赋给 style.backgroundColor；只有 8 位
  // #AARRGGBB（老引擎可能输出，alpha 在前）才换算成 #rrggbb / rgba(...)，其余原样透传。
  function iconBgCss(v) {
    var s = String(v == null ? '' : v).replace(/^\s+|\s+$/g, '');
    if (!/^#[0-9a-fA-F]{8}$/.test(s)) return s;
    var a = parseInt(s.slice(1, 3), 16) / 255;
    if (a >= 1) return '#' + s.slice(3, 9).toLowerCase();
    return 'rgba(' + parseInt(s.slice(3, 5), 16) + ',' + parseInt(s.slice(5, 7), 16) + ',' + parseInt(s.slice(7, 9), 16) + ',' + (Math.round(a * 1000) / 1000) + ')';
  }

  /* 历史记录：两种格式归一成同一条记录，无法识别时返回 null（调用方回退到原始文本）。
     规范（引擎 1.3.1 起，竖线分隔，v1.3.2 起 META 追加 icon/label_src/icon_src，
     v1.3.3 起再追加 icon_bg/icon_scale）：
       <epoch>|OK|<pkg>|<ver>|<mode>|installed|<bundle path>
       <epoch>|FAIL|<pkg>|<ver>|<mode>|<错误码>|<bundle path>
     旧版（<=1.2.x，空格分隔，仍留在老设备的 history.log 里）：
       2026-01-02T03:04:05 OK /sdcard/Download/a.apk pkg=com.x ver=1.2
       2026-01-02T03:04:06 FAIL /sdcard/Download/b.apk code=INSTALL_FAILED_X msg=...
     raw 一律保留整行原文（含包路径 / msg），失败时由渲染层展开原文排查。 */
  function parseHistoryLine(line) {
    // 旧格式里 pkg= / ver= / code= 是空格分隔的独立 token，取第一个命中项
    function tokenOf(text, key) {
      var parts = String(text).split(/[ \t]+/);
      for (var i = 0; i < parts.length; i++) {
        if (parts[i].indexOf(key + '=') === 0) return parts[i].slice(key.length + 1);
      }
      return '';
    }
    // 旧格式时间戳是本地时间 "YYYY-MM-DDTHH:MM:SS"；解析不了就保留字符串，让 fmtTime 兜底
    function stampToEpoch(stamp) {
      if (/^[0-9]+$/.test(stamp)) return Number(stamp);
      var ms = Date.parse(stamp);
      if (isNaN(ms)) return stamp;
      return Math.floor(ms / 1000);
    }

    var s = (line == null) ? '' : String(line).replace(/^\s+|\s+$/g, '');
    if (!s) return null;

    var f = s.split('|');
    if (f.length >= 5 && (f[1] === 'OK' || f[1] === 'FAIL')) {
      return {
        ok: f[1] === 'OK',
        pkg: f[2] || '',
        ver: f[3] || '',
        mode: f[4] || '',
        t: /^[0-9]+$/.test(f[0]) ? Number(f[0]) : f[0],
        code: f[5] || '',
        raw: s
      };
    }

    var m = /^(\S+)[ \t]+(OK|FAIL)[ \t]+(.*)$/.exec(s);
    if (!m) return null;
    var body = m[3];
    return {
      ok: m[2] === 'OK',
      pkg: tokenOf(body, 'pkg'),
      ver: tokenOf(body, 'ver'),
      mode: '',
      t: stampToEpoch(m[1]),
      code: tokenOf(body, 'code'),
      raw: s
    };
  }

  // 历史文本 → 记录数组（保持文件顺序：旧在前新在后，渲染层再倒序取最新 60 条）
  function normalizeHistory(text) {
    var lines = String(text == null ? '' : text).split('\n');
    var out = [];
    for (var i = 0; i < lines.length; i++) {
      var rec = parseHistoryLine(lines[i]);
      if (rec) out.push(rec);
    }
    return out;
  }
  function plural(n, one, many) { return String(n) + ' ' + (n === 1 ? one : many); }

  var toastTimer = null;
  function toast(msg, ms) {
    var t = byId('toast');
    if (!t) return;
    t.textContent = msg;
    t.classList.add('is-on');
    if (toastTimer) clearTimeout(toastTimer);
    toastTimer = setTimeout(function () { t.classList.remove('is-on'); }, ms || 2200);
  }

  // 远程日志：/data/local/tmp/apkmt-ui.log（adb shell 可读），电脑端排查的唯一手段
  var ulogCount = 0;
  function ulog(msg) {
    if (ulogCount > 80 || !KSU || typeof KSU.exec !== 'function') return;
    ulogCount += 1;
    try {
      var stamp = new Date().toISOString().replace(/^.*T/, '').replace(/\..*$/, '');
      var name = cbName('ulog');
      window[name] = function () { try { delete window[name]; } catch (e) { window[name] = undefined; } };
      KSU.exec('printf "%s %s\\n" ' + shq(stamp) + ' ' + shq(String(msg)).replace(/\\n/g, ' ') + ' >> /data/local/tmp/apkmt-ui.log; chmod 644 /data/local/tmp/apkmt-ui.log 2>/dev/null',
        JSON.stringify({}), name);
    } catch (e) { }
  }

  var LS = {
    get: function (k, d) { try { var v = localStorage.getItem('apkmt.' + k); return v == null ? d : v; } catch (e) { return d; } },
    set: function (k, v) { try { localStorage.setItem('apkmt.' + k, String(v)); } catch (e) { } },
    del: function (k) { try { localStorage.removeItem('apkmt.' + k); } catch (e) { } }
  };
  /* ================================================================ 词典 */

  var KIND_ZH = { base: '基础包', master: '主分片', abi: '架构', dpi: '密度', lang: '语言', other: '功能/其他' };
  var KIND_ORDER = ['base', 'master', 'abi', 'dpi', 'lang', 'other'];
  var REASON_ZH = {
    base_required: '必需的基础包', module_master: '主分片（必需）',
    abi_best: '最佳可用 ABI（按设备 abilist 优先序）', abi_lower: '次选 ABI（设备支持但非首选）', abi_unsupported: '设备不支持该 ABI',
    dpi_universal: '通用密度（nodpi/anydpi）', dpi_best: '最接近设备密度', dpi_other: '其他密度',
    lang_all: '已选全部语言', lang_system: '匹配系统语言', lang_default: '英文回退（系统语言无对应分片）', lang_other: '其他语言',
    feature_required: '功能分片（需一起安装）', not_apk: '不是 APK，忽略',
    standalone_pack: '独立包（只装这一个）', standalone_other: '独立包的其它变体（未安装）'
  };
  var STAGE_ZH = {
    dry_run: '试运行', creating_session: '创建安装会话', writing: '写入分片',
    write_test_ok: '分片校验完成', committing: '提交安装', done: '完成'
  };
  var BUNDLE_ZH = { apkm: '.apkm', apks: '.apks', xapk: '.xapk', apk: '单个 APK', zip: '未知压缩包' };
  // 应用名 / 图标来源（META label_src = json|manifest|arsc|none；v1.3.3 起 arsc = 从资源表
  // 解析资源引用。icon_src = json|root|mipmap|arsc|adaptive|vector|none，后三个为 v1.3.3 新增）
  var LABEL_SRC_ZH = { json: '包内元数据', manifest: 'APK 清单', arsc: '资源表(ARSC)', none: '未找到' };
  var ICON_SRC_ZH = {
    json: '包内元数据', root: '包内图标文件', mipmap: 'APK 资源提取',
    arsc: '资源表(ARSC)', adaptive: '自适应图标', vector: '矢量图标', none: '未找到'
  };
  var DIAG_ZH = {
    engine_version: '引擎版本', uid: 'UID', whoami: '运行身份', unzip: 'unzip', pm: 'pm 命令',
    busybox: 'busybox', ksu_busybox: 'KernelSU busybox', state_dir: '状态目录',
    state_dir_writable: '状态目录可写', device_sdk: 'SDK', device_release: 'Android',
    device_model: '机型', device_abi: 'ABI', device_density: '密度', device_locale: '语言区域', free_data: '可用空间',
    device_density_physical: '物理密度', device_density_override: '密度覆盖', selected_abi: '选中 ABI', pkg_source: '包名来源'
  };
  var LS_ERR_ZH = {
    no_dir: '没有指定目录', need_absolute_path: '需要绝对路径',
    not_a_directory: '这个路径不是目录，或者已经被移除了'
  };

  /* 引擎错误码 →「发生了什么|你该怎么办」。同时登记去掉 INSTALL_FAILED_ 前缀的短码，
     这样 INSTALL_FAILED_FOO 与 FOO 会被当成同一件事。 */
  var ERR_S = [
    'FILE_NOT_FOUND|找不到这个文件|文件可能已被删除或移动，回「选包」重新选择。',
    'FILE_UNREADABLE|文件无法读取|root 也读不到时，试试把包放到 /data/media/0/Download 或 /data/local/tmp。',
    'NO_UNZIP|没有可用的 unzip|引擎试过 KernelSU busybox 与系统 unzip 都无法解析该包，可能不是 zip 格式。',
    'NOT_A_PACKAGE|不是有效的安装包|无法列出压缩包内容，可能文件损坏或下载不完整。',
    'NO_BASE|包内没有 base.apk|缺少基础包无法安装；这是打包不完整的 .apkm。',
    'NO_PM|找不到 pm 命令|系统环境异常。',
    'NO_SELECTION|没有选中任何分片|至少需要基础包。',
    'INSUFFICIENT_STORAGE|存储空间不足|清理 /data 空间后重试。',
    'CREATE_FAILED|无法创建安装会话|常见于 ROM 限制静默安装（开发者选项里的「USB 安装/通过 USB 安装应用」需要打开）。',
    'WRITE_FAILED|写入分片失败|重试一次；若反复失败，可能是分片体积过大或存储异常。',
    'COMMIT_FAILED|提交安装失败|展开下方的技术详情，可以看到系统给出的原始原因。',
    'ENGINE_NO_OUTPUT|引擎没有任何输出|安装脚本没有被执行，或执行中途崩溃了。到「诊断」页确认 apkmt 模块已启用、/data/adb/modules/apkmt/bin/apkmt.sh 存在且可执行，然后重试。',
    'INSTALL_FAILED_ALREADY_EXISTS|应用已存在且签名不同|先卸载原应用再装，或换用签名一致的升级包。',
    'INSTALL_FAILED_INVALID_APK|APK 无效或已损坏|重新下载安装包。',
    'INSTALL_FAILED_INSUFFICIENT_STORAGE|存储空间不足|清理空间后重试。',
    'INSTALL_FAILED_UPDATE_INCOMPATIBLE|签名不一致|新包与原包签名不同（如官方版↔第三方版）。需要先卸载原应用；有数据的话先备份。',
    'INSTALL_FAILED_UPDATE_INCOMPATIBLE_MATCHING|签名不一致|同上：先卸载原应用。',
    'INSTALL_FAILED_MISSING_SHARED_LIBRARY|缺少共享库|该包依赖设备不具备的共享库。',
    'INSTALL_FAILED_CONFLICTING_PROVIDER|ContentProvider 冲突|已有应用占用了同名 provider，卸载冲突应用。',
    'INSTALL_FAILED_TEST_ONLY|这是 testOnly 包|安装时加 -t；或让打包方去掉 testOnly。',
    'INSTALL_FAILED_INVALID_INSTALL_LOCATION|安装位置无效|清理后重试。',
    'INSTALL_FAILED_VERIFICATION_FAILURE|安装校验失败|到「诊断」页关闭 adb 安装校验后重装（写入 verifier_verify_adb_installs=0）。',
    'INSTALL_FAILED_PACKAGE_CHANGED|包在安装过程中被修改|重新下载后重试。',
    'INSTALL_FAILED_VERSION_DOWNGRADE|不允许降级安装|已装版本更高。想降级需要 root 下改安装器策略或先卸载（会丢数据）。',
    'INSTALL_FAILED_MISSING_SPLIT|缺少必需的分片|回到分片列表，把被排除的 abi / 密度 / 语言分片勾上（用「全选」最稳）。',
    'INSTALL_FAILED_DEPRECATED_SDK_VERSION|targetSdk 过低被系统拒绝|Android 14+ 拒绝 targetSdk<23 的应用；引擎已自动带 bypass 参数，仍然失败说明该 ROM 屏蔽了这个 flag。',
    'INSTALL_PARSE_FAILED_NOT_APK|文件不是 APK|可能是压缩包结构不对或下载不完整。',
    'INSTALL_PARSE_FAILED_BAD_MANIFEST|AndroidManifest 损坏|重新下载安装包。',
    'INSTALL_PARSE_FAILED_NO_CERTIFICATES|APK 未签名|重新下载安装包。',
    'INSTALL_PARSE_FAILED_INCONSISTENT_CERTIFICATES|分包签名不一致|APKMirror 包被改动过，或混入了不同来源的分片。',
    'INSTALL_FAILED_INTERNAL_ERROR|系统内部错误|重启手机后重试。',
    'INSTALL_FAILED_USER_RESTRICTED|被 ROM 限制安装|MIUI / HyperOS 请在开发者选项打开「USB 安装」，必要时关闭 MIUI 优化后重试。',
    'INSTALL_FAILED_DUPLICATE_PERMISSION|自定义权限重复|已有应用声明了同名权限，卸载它。',
    'INSTALL_FAILED_NO_MATCHING_ABIS|没有匹配的 CPU 架构|该包不含设备 ABI 的分片，或者选错了分片。',
    'INSTALL_FAILED_ABORTED|安装被中止|重试。',
    'INSTALL_FAILED_SESSION_INVALID|会话已失效|重试一次。',
    'INSTALL_FAILED_BLOCKED_CROSS_SIGNATURE|被安装器策略拦截（跨签名）|系统策略禁止跨签名替换，需先卸载原应用。',
    'INSTALL_FAILED_BLOCKED_INCOMPAT_SIGNATURE|被安装器策略拦截（签名不兼容）|先卸载原应用再装。',
    'INSTALL_FAILED_BLOCKED_DOWNGRADE|被安装器策略拦截（降级）|已装版本更高，先卸载再装。',
    'INSTALL_FAILED_VERIFICATION_TIMEOUT|校验超时|关闭 adb 安装校验后重试。',
    'INSTALL_FAILED_MEDIA_UNAVAILABLE|存储不可用|确认内部存储已挂载。',
    'INSTALL_FAILED_CONTAINER_ERROR|应用容器加密失败|重启后重试。',
    'INSTALL_FAILED_OLDER_SDK|应用要求更高的系统版本|当前系统版本过低。',
    'INSTALL_FAILED_NEWER_SDK|应用不支持当前系统版本|targetSdk 过高。',
    'INSTALL_FAILED_DEXOPT|dex 优化失败|重启后重试。',
    'INSTALL_FAILED_SHARED_USER_INCOMPATIBLE|共享 UID 不兼容|签名与共享 UID 配置不匹配。'
  ];

  var ERR = {};
  for (var ei = 0; ei < ERR_S.length; ei++) {
    var ep = ERR_S[ei].split('|');
    ERR[ep[0]] = [ep[1], ep[2]];
    ERR[ep[0].replace(/^INSTALL_FAILED_/, '')] = [ep[1], ep[2]];
  }

  function errInfo(code, fix) {
    var hit = code ? (ERR[code] || ERR[String(code).replace(/^INSTALL_FAILED_/, '')]) : null;
    if (hit) return hit[fix ? 1 : 0];
    if (fix) return '展开下方的技术详情，把原始输出发出来可以进一步定位。';
    return '安装没有完成';
  }


  /* ================================================================ 状态 */

  var ENG = '/data/adb/modules/apkmt/bin/apkmt.sh';
  var MODDIR = '/data/adb/modules/apkmt';

  var S = {
    ready: false,
    busy: false,
    bundle: '',
    meta: {},
    entries: [],
    device: {},
    mode: LS.get('mode', 'auto'),
    lang: LS.get('lang', 'sys'),
    checked: {},
    manualTouched: false,
    dir: LS.get('dir', '/sdcard/Download'),
    files: [],
    lastResult: null,
    history: null,
    historyText: '',
    installed: {},
    view: 'install',
    scr: '',
    focusAfterInspect: false,
    testWrite: false,
    errCode: '',
    okPkg: ''
  };

  function engineCmd(sub, rest) {
    var parts = ['sh', shq(ENG), sub];
    if (rest) parts = parts.concat(rest);
    return parts.join(' ');
  }

  // 引擎记录：KEY|f1|f2...
  function parseRecords(line, sink) {
    var i = line.indexOf('|');
    if (i < 0) { if (sink.raw) sink.raw(line); return; }
    var key = line.slice(0, i), body = line.slice(i + 1);
    var f = body.split('|');
    if (sink[key]) sink[key](f, line); else if (sink.raw) sink.raw(line);
  }

  /* ============================================================ 视图路由 */

  var SCREENS = {
    install: ['scrBoot', 'scrBlocked', 'scrEmpty', 'scrInspecting', 'scrFail', 'scrPkg'],
    manager: ['scrManager'],
    files: ['scrFiles'],
    history: ['scrHistory'],
    diag: ['scrDiag'],
    running: ['scrRunning'],
    done: ['scrDone'],
    error: ['scrError']
  };
  var BACK = {
    manager: { view: 'install', scr: '' },
    running: { view: 'install', scr: '' },
    done: { view: 'install', scr: '' },
    error: { view: 'install', scr: '' }
  };
  var TITLES = {
    install: 'apkmt', manager: '分片', files: '选择安装包',
    history: '安装历史', diag: '诊断',
    running: '正在安装', done: '安装完成', error: '安装失败'
  };

  function setScreen(view, scr, opts) {
    opts = opts || {};
    var ids = SCREENS[view] || [];
    // 安装页不指定具体屏时按状态自动选：启动中→scrBoot、未自检→scrBlocked、
    // 解析失败→scrFail、已解析→scrPkg、其余→scrEmpty（否则点「安装」标签会一直看到骨架屏）
    var chosen = scr || (view === 'install' ? pkgScreenId() : ids[0]);

    for (var v in SCREENS) {
      if (!SCREENS.hasOwnProperty(v)) continue;
      var sec = byId('view-' + v);
      if (!sec) continue;
      var active = (v === view);
      sec.classList.toggle('is-active', active);
      if (!active) continue;
      for (var i = 0; i < SCREENS[v].length; i++) {
        var sc = byId(SCREENS[v][i]);
        if (sc) sc.hidden = (SCREENS[v][i] !== chosen);
      }
      document.body.setAttribute('data-screen', SCREENS[v].indexOf(chosen) >= 0 ? chosen : SCREENS[v][0]);
    }

    var tabs = document.querySelectorAll('.tab');
    for (var t = 0; t < tabs.length; t++) {
      tabs[t].classList.toggle('is-active', tabs[t].getAttribute('data-view') === view);
    }

    var backTo = (opts.back === undefined) ? BACK[view] : opts.back;
    show(byId('btnBack'), !!backTo);
    setText('tbTitle', opts.title || TITLES[view] || 'apkmt');

    S.view = view;
    S.scr = chosen;
    if (view === 'files') browse(S.dir);
    if (view === 'history') loadHistory();
    if (view === 'diag') loadDiag();
  }

  function goBack() {
    if (S.view === 'manager') { setScreen('install', pkgScreenId()); return; }
    if (S.view === 'running') {
      setProgress(0, '准备中', '—', '—');
      setScreen('install', pkgScreenId());
      return;
    }
    if (S.view === 'done' || S.view === 'error') { setScreen('install', pkgScreenId()); return; }
  }

  function hasFail() {
    return !!(S.bundle && S.meta && S.meta._fail);
  }

  function pkgScreenId() {
    if (document.body.getAttribute('data-boot') === '1') return 'scrBoot';
    if (!S.ready) return 'scrBlocked';
    if (hasFail()) return 'scrFail';
    if (S.bundle && S.meta && S.meta.pkg !== undefined) return 'scrPkg';
    return 'scrEmpty';
  }

  function setBusy(busy) {
    S.busy = !!busy;
    var bi = byId('btnInstall'), bt = byId('btnTestWrite');
    if (bi) bi.disabled = S.busy || !S.bundle || !S.ready;
    if (bt) bt.disabled = S.busy || !S.bundle || !S.ready;
    var ri = byId('btnReinspect');
    if (ri) ri.disabled = S.busy;
  }

  function setStatus(text) { setText('tbSub', text); }

  function defaultStatus() {
    if (!S.ready) {
      setStatus(!KSU || typeof KSU.exec !== 'function' ? '未检测到 KernelSU 接口' : '正在自检运行环境…');
      return;
    }
    var model = S.device.device_model || S.meta.device_model || '';
    var rel = S.device.device_release || S.meta.device_release || '';
    var parts = [];
    if (model) parts.push(model);
    if (rel) parts.push('Android ' + rel);
    setStatus(parts.join(' · '));
  }

  function setBoot(on, note) {
    document.body.setAttribute('data-boot', on ? '1' : '0');
    var tabs = document.querySelectorAll('.tab');
    for (var i = 0; i < tabs.length; i++) tabs[i].disabled = !!on;
    if (note) setText('bootNote', note);
  }

  /* ============================================================ 通用小件 */

  function tag(text, kind) {
    return el('span', 'tag' + (kind ? ' tag--' + kind : ''), text);
  }

  function kvInto(box, k, v, mono, ltr) {
    if (!box) return;
    var r = el('div', 'kv-r');
    r.appendChild(el('span', 'kv-k', k));
    var cls = 'kv-v';
    if (mono) cls += ' mono';
    if (ltr) cls += ' dir';
    r.appendChild(el('span', cls, (v == null || v === '') ? '—' : String(v)));
    box.appendChild(r);
    return r;
  }
  function kvIntoNode(box, k, valueNode) {
    if (!box) return;
    var r = el('div', 'kv-r');
    r.appendChild(el('span', 'kv-k', k));
    if (valueNode) {
      valueNode.classList.add('kv-v');
      r.appendChild(valueNode);
    }
    box.appendChild(r);
    return r;
  }

  function segIndex(seg, attr, value) {
    if (!seg) return 0;
    var btns = seg.querySelectorAll('button'), idx = 0;
    for (var i = 0; i < btns.length; i++) {
      var on = btns[i].getAttribute(attr) === value;
      btns[i].classList.toggle('is-on', on);
      if (on) idx = i;
    }
    seg.style.setProperty('--seg-n', String(btns.length));
    seg.style.setProperty('--seg-i', String(idx));
    return idx;
  }

  function waitingRow(text) {
    var d = el('div', 'waiting');
    d.appendChild(el('span', '', text));
    var dots = el('span', 'dots');
    dots.appendChild(el('i')); dots.appendChild(el('i')); dots.appendChild(el('i'));
    d.appendChild(dots);
    return d;
  }

  function skList(rows) {
    var wrap = document.createDocumentFragment();
    for (var r = 0; r < rows; r++) {
      var row = el('div', 'sk-row');
      row.appendChild(el('span', 'sk sk-ico'));
      var tx = el('div');
      tx.appendChild(el('span', 'sk sk-line', ''));
      var l2 = el('span', 'sk sk-line sk-line--sm', '');
      l2.style.width = '58%';
      tx.appendChild(l2);
      row.appendChild(tx);
      wrap.appendChild(row);
    }
    return wrap;
  }

  /* ============================================================ 安装页：解析 */

  function showInspecting(path) {
    setText('inspectPath', path);
    setScreen('install', 'scrInspecting', { title: 'apkmt' });
  }

  function inspect(path, done, focus) {
    S.bundle = path;
    S.focusAfterInspect = !!focus;
    S.meta = {}; S.entries = []; S.device = {};
    S.checked = {};
    var args = ['--mode', 'auto', '--lang', S.lang];
    var raw = [];
    var sawRecord = false;
    setBusy(true);
    showInspecting(path);
    setStatus('正在解析安装包…');

    runStream(engineCmd('inspect', [shq(path)].concat(args)), function (line, tag) {
      if (tag !== 'o') return;
      parseRecords(line, {
        META: function (f) {
          sawRecord = true;
          var val = f.slice(1).join('|');
          S.meta[f[0]] = val;
          // 设备信息两边都放：S.device 供顶栏/诊断，S.meta 供安装页信息表（renderPkg 读的是 S.meta.device_*）
          if (/^device_/.test(f[0])) S.device[f[0]] = val;
        },
        ENTRY: function (f) {
          sawRecord = true;
          S.entries.push({ name: f[0], size: f[1], kind: f[2], token: f[3], sel: f[4] === '1', reason: f[5] });
        },
        RESULT: function (f) {
          sawRecord = true;
          if (f[0] === 'FAIL') S.meta._fail = f[1] + '|' + f.slice(2).join('|');
        },
        DETAIL: function (f, l) { raw.push(l); },
        LOG: function () { }
      });
    }, function (code, err) {
      setBusy(false);
      if (S.meta._fail) {
        var ef = S.meta._fail.split('|');
        var code2 = ef[0], msg = ef.slice(1).join('|');
        ulog('inspect FAIL code=' + code2 + ' msg=' + msg);
        S.focusAfterInspect = false;
        renderInspectFail(path, code2, msg || err || '');
        if (done) done(false);
        return;
      }
      // 传输层校验：桥接自己没报错，但引擎一条记录都没吐出来（脚本缺失 / 语法错误 /
      // 权限不足 / shell 不对）。此时 S.meta 是空的，直接 renderPkg 会得到一张空白信息页。
      if (!S.meta.bundle_type && (!sawRecord || code !== 0)) {
        ulog('inspect no-output exit=' + code + ' records=' + (sawRecord ? 1 : 0) + ' entries=' + S.entries.length + ' err=' + String(err || '').slice(0, 160));
        S.focusAfterInspect = false;
        renderInspectFail(path, 'ENGINE_NO_OUTPUT', 'exit=' + code + ' ' + (err || ''));
        if (done) done(false);
        return;
      }
      ulog('inspect ok type=' + S.meta.bundle_type + ' entries=' + S.entries.length + ' sel=' + S.meta.selected_count + ' bytes=' + S.meta.total_bytes + ' unzip=' + S.meta.unzip + ' pkg=' + (S.meta.pkg || '?'));
      renderPkg();
      applyModeSelection();
      if (done) done(true);
    });
  }

  function renderInspectFail(path, code, msg) {
    setText('inspectFailTitle', errInfo(code, false));
    setText('inspectFailText', errInfo(code, true));
    var kv = byId('inspectFailKv');
    clear(kv);
    kvInto(kv, '文件', path, true, true);
    kvInto(kv, '错误码', code || 'FAIL', true, true);
    if (msg) kvInto(kv, '引擎输出', msg, true, true);
    setText('inspectFailRaw', [path, code, msg].filter(Boolean).join('\n'));
    setScreen('install', 'scrFail', { title: '无法解析' });
    defaultStatus();
    toast('这个包无法安装');
  }

  function renderPkg() {
    var m = S.meta;
    var pkg = m.pkg || '';

    setText('pkgName', displayLabel(m));
    setText('pkgId', pkg || '包内没有 info.json，无法确定包名');

    // 图标：背景层（纯色 / 背景图）+ 前景层（整图或自适应前景）+ 首字母兜底。
    // 自适应图标的前景是 108dp 画布、只有中间 72dp 可见，按 icon_scale（1.5）放大后由
    // .ico-slot 的 overflow:hidden + 圆角裁切，效果等同桌面启动器的图标遮罩。
    var slot = byId('pkgIcoSlot'), img = byId('pkgIco'), fb = byId('pkgIcoFb');
    var plan = iconPlan(m);
    if (fb) fb.textContent = plan.fallback;
    if (slot) {
      slot.classList.remove('has-img');
      slot.style.backgroundColor = iconBgCss(plan.bgColor);
      // 背景图层动态创建（index.html 未预置）；重复解析时先清掉旧的，避免叠层
      var oldBg = byId('pkgIcoBg');
      if (oldBg && oldBg.parentNode) oldBg.parentNode.removeChild(oldBg);
      if (plan.bgUrl) {
        var bg = el('img', 'ico-bg');
        bg.id = 'pkgIcoBg';
        bg.alt = '';
        bg.onerror = function () { if (bg.parentNode) bg.parentNode.removeChild(bg); };
        slot.insertBefore(bg, slot.firstChild);
        bg.src = plan.bgUrl;
      }
    }
    if (img) {
      var cands = iconCandidates(m);
      // 只有包内图标（自适应前景层）在候选首位时才放大；ksu:// 是完整图标，放大会被裁掉
      var fgScale = function (i) {
        if (!plan.fgUrl || i !== 0 || plan.scale === 1) return '';
        return 'scale(' + plan.scale + ')';
      };
      img.classList.add('ico-fg');
      img.style.transform = fgScale(0);
      if (cands.length) {
        // 逐个候选试：加载失败才换下一个；全部失败就藏起 <img>、露出首字母兜底。
        // idx 只增不减，所以不会在候选之间来回重试（不会死循环）。
        var idx = 0;
        img.classList.remove('hidden');
        img.onload = function () { if (slot) slot.classList.add('has-img'); };
        img.onerror = function () {
          idx += 1;
          if (idx < cands.length) { img.style.transform = fgScale(idx); img.src = cands[idx]; return; }
          img.onerror = null;
          img.removeAttribute('src');
          img.classList.add('hidden');
          if (slot) slot.classList.remove('has-img');
        };
        img.src = cands[0];
      } else {
        img.onload = null;
        img.onerror = null;
        img.style.transform = '';
        img.classList.add('hidden');
        img.removeAttribute('src');
      }
    }

    var chips = byId('pkgChips');
    clear(chips);
    if (chips) {
      chips.appendChild(tag(BUNDLE_ZH[m.bundle_type] || m.bundle_type || '安装包', 'accent'));
      if (m.bundle_size) chips.appendChild(tag(fmtSize(m.bundle_size)));
      if (m.version) chips.appendChild(tag('v' + m.version));
      if (m.version_code) chips.appendChild(tag('build ' + m.version_code));
      // 包名来源：manifest / info.json 是打包方写入的权威值，不必吓唬用户；
      // 只有从 toc.pb 猜出来的、或完全没解析出来时才用警告色。
      if (m.pkg_source) {
        var srcKind = (m.pkg_source === 'toc.pb(guess)' || m.pkg_source === 'none') ? 'warn' : '';
        chips.appendChild(tag('包名来源 ' + m.pkg_source, srcKind));
      }
    }

    var kv = byId('pkgKv');
    clear(kv);
    kvInto(kv, '文件名', m.bundle || S.bundle, true, true);
    if (m.label && m.label !== byId('pkgName').textContent) kvInto(kv, '应用名', m.label);
    if (m.label_src) kvInto(kv, '应用名来源', LABEL_SRC_ZH[m.label_src] || m.label_src);
    if (m.icon_src) kvInto(kv, '图标来源', ICON_SRC_ZH[m.icon_src] || m.icon_src);
    kvInto(kv, 'minSdk', m.min_api);
    kvInto(kv, 'targetSdk', m.target_api);
    kvInto(kv, '原生 ABI', m.device_abi);
    kvInto(kv, '密度 / 语言', (m.device_density || '?') + 'dpi · ' + (m.device_locale || '?'));
    if (m.device_density_physical || m.device_density_override) {
      kvInto(kv, '物理密度 / 覆盖', (m.device_density_physical || '?') + 'dpi · ' + (m.device_density_override || '未覆盖'));
    }
    if (m.selected_abi) kvInto(kv, '选中 ABI', m.selected_abi);

    renderSplitsSummary();
    renderSplits();
    // 从「选包」页点进来的（focus=true）就跳到安装页；否则解析期间用户可能已切到
    // 「选包 / 历史 / 诊断」，别把界面硬拽回安装页
    if (S.focusAfterInspect) { S.focusAfterInspect = false; setScreen('install', 'scrPkg', { title: 'apkmt' }); }
    else if (!S.view || S.view === 'install') setScreen('install', 'scrPkg', { title: 'apkmt' });
    else if (S.view === 'manager') renderSplits();
    defaultStatus();
    loadInstalledVersion(pkg);
  }

  function loadInstalledVersion(pkg) {
    if (!pkg || !KSU) return;
    exec('pm list packages --show-versioncode ' + shq(pkg) + ' 2>/dev/null | head -1', {}).then(function (r) {
      var s = (r.stdout || '').trim();
      if (!s) return;
      var mv = /versionCode:(\d+)/.exec(s);
      var code = mv ? (parseInt(mv[1], 10) || 0) : 0;
      S.installed[pkg] = code;
      var chips = byId('pkgChips');
      if (!chips || S.meta.pkg !== pkg) return;
      var old = chips.querySelector('.tag--installed');
      if (old) old.remove();
      var t = tag(code ? '已安装 build ' + code : '已安装', 'ok');
      t.classList.add('tag--installed');
      chips.appendChild(t);
      var newCode = parseInt(S.meta.version_code || '0', 10) || 0;
      if (newCode && code && newCode < code) {
        var w = tag('降级包 ' + code + ' → ' + newCode, 'warn');
        w.classList.add('tag--installed');
        chips.appendChild(w);
      }
    }).catch(function () { });
  }

  /* ============================================================ 安装页：分片 */

  function isApkEntry(e) { return /\.apk$/i.test(e.name); }

  function entryChecked(e) {
    if (S.mode === 'all') return isApkEntry(e);
    if (S.mode === 'manual') {
      if (e.kind === 'base') return true;
      return !!S.checked[e.name];
    }
    return !!e.sel;
  }

  function applyModeSelection() {
    if (S.mode === 'auto') {
      S.checked = {};
      S.entries.forEach(function (e) { if (e.sel) S.checked[e.name] = true; });
    } else if (S.mode === 'all') {
      S.checked = {};
      S.entries.forEach(function (e) { if (isApkEntry(e)) S.checked[e.name] = true; });
    }
    segIndex(byId('segMode'), 'data-mode', S.mode);
    var note = byId('modeNote');
    if (note) {
      if (S.mode === 'all') note.textContent = '安装包内全部分片，兼容性最好，占用空间最大。';
      else if (S.mode === 'manual') note.textContent = '只安装你勾选的分片。基础包始终包含，缺失 ABI / 密度分片可能安装失败。';
      else note.textContent = '按设备 ABI、屏幕密度与系统语言自动挑选分片。';
    }
    renderSplitsSummary();
  }

  function selectionStats() {
    var n = 0, bytes = 0, total = 0;
    S.entries.forEach(function (e) {
      if (isApkEntry(e)) total += 1;
      if (entryChecked(e)) { n += 1; bytes += parseInt(e.size || '0', 10) || 0; }
    });
    return { n: n, bytes: bytes, total: total || S.entries.length };
  }

  function renderSplitsSummary() {
    if (!S.entries.length) return;
    var s = selectionStats();
    var sum = byId('splitsSummary');
    if (sum) sum.textContent = s.n + ' / ' + s.total + ' 个分片 · ' + fmtSize(s.bytes);
    var note = byId('splitNote');
    if (note) {
      if (S.mode === 'all') note.textContent = '已选全部分片（含其他架构 / 密度 / 语言），体积最大但兼容性最好。';
      else if (S.mode === 'manual') note.textContent = '手动模式：只安装你勾选的分片。base 必需，缺失 abi / 密度分片可能报 MISSING_SPLIT。';
      else note.textContent = '推荐模式：按设备 ABI / 密度 / 系统语言自动挑选，等价于 APKMirror Installer 的行为。';
    }
  }

  function entryLabel(e) {
    if (e.kind === 'base' || e.kind === 'master') return e.kind === 'base' ? '基础包' : '主分片';
    return e.token || (KIND_ZH[e.kind] || e.kind);
  }

  function renderSplits() {
    var box = byId('splitList');
    if (!box) return;
    clear(box);
    if (!S.entries.length) return;

    var groups = {};
    S.entries.forEach(function (e) {
      var k = KIND_ORDER.indexOf(e.kind) >= 0 ? e.kind : 'other';
      (groups[k] = groups[k] || []).push(e);
    });

    KIND_ORDER.forEach(function (kind) {
      var list = groups[kind];
      if (!list || !list.length) return;
      var card = el('article', 'card');
      card.setAttribute('data-od-id', 'split-group-' + kind);
      card.appendChild(el('div', 'grp-hd', KIND_ZH[kind] + ' · ' + list.length));

      list.forEach(function (e) {
        var on = entryChecked(e);
        var row = el('div', 'split');
        var cb = document.createElement('input');
        cb.type = 'checkbox';
        cb.className = 'split-cb';
        cb.checked = on;
        cb.disabled = (e.kind === 'base') || !isApkEntry(e);
        cb.setAttribute('aria-label', e.name);
        cb.onchange = function () {
          if (S.mode !== 'manual') {
            S.checked = {};
            S.entries.forEach(function (x) { if (entryChecked(x)) S.checked[x.name] = true; });
            S.mode = 'manual';
            LS.set('mode', 'manual');
            segIndex(byId('segMode'), 'data-mode', 'manual');
          }
          S.checked[e.name] = cb.checked;
          S.manualTouched = true;
          renderSplits();
        };
        row.appendChild(cb);

        var tx = el('div', 'split-tx');
        var t = el('div', 'split-t' + (e.kind === 'other' || e.kind === 'base' ? ' mono' : ''));
        t.textContent = e.name;
        tx.appendChild(t);
        tx.appendChild(el('div', 'split-s', (REASON_ZH[e.reason] || e.reason || '') + (!isApkEntry(e) ? ' · 不可安装' : '')));
        row.appendChild(tx);

        var meta = el('div', 'split-meta');
        var tg = el('span', 'split-tag' + (on ? ' is-sel' : ''), entryLabel(e));
        meta.appendChild(tg);
        meta.appendChild(el('span', 'split-sz', fmtSize(e.size)));
        row.appendChild(meta);

        if (!isApkEntry(e)) row.classList.add('is-dim');
        card.appendChild(row);
      });
      box.appendChild(card);
    });

    renderSplitsSummary();
  }

  function pickSplits(kind) {
    if (kind === 'recommended') { S.mode = 'auto'; LS.set('mode', 'auto'); }
    else if (kind === 'all') { S.mode = 'all'; LS.set('mode', 'all'); }
    else { S.mode = 'manual'; LS.set('mode', 'manual'); S.checked = {}; S.manualTouched = true; }
    applyModeSelection();
    renderSplits();
    segIndex(byId('segPick'), 'data-pick', kind);
    if (kind === 'none') toast('只保留基础包');
  }

  /* ============================================================ 安装页：执行 */

  function buildInstallCmd(testWrite) {
    var args = [shq(S.bundle), '--mode', S.mode, '--lang', S.lang];
    if (S.mode === 'manual') {
      var sel = Object.keys(S.checked).filter(function (k) { return S.checked[k]; });
      args = args.concat(['--splits', shq(sel.join(','))]);
    }
    if (byId('optDowngrade') && byId('optDowngrade').checked) args.push('--downgrade');
    if (byId('optGrant') && byId('optGrant').checked) args.push('--grant');
    var inst = byId('optInstaller') ? byId('optInstaller').value : '';
    if (inst) args = args.concat(['--installer', shq(inst)]);
    if (testWrite) args.push('--test-write');
    return engineCmd('install', args);
  }

  var runLogLines = '';
  function appendLog(text) {
    runLogLines += text + '\n';
    ['runLog', 'doneLog', 'errLog'].forEach(function (id) {
      var n = byId(id);
      if (n) n.textContent = runLogLines;
    });
    var live = byId('runLog');
    if (live && live.parentNode && live.parentNode.open) live.scrollTop = live.scrollHeight;
  }
  function resetLog() {
    runLogLines = '';
    ['runLog', 'doneLog', 'errLog'].forEach(function (id) {
      var n = byId(id);
      if (n) n.textContent = '（暂无输出）';
    });
  }

  function ringSet(ringId, fillId, pct) {
    var ring = byId(ringId), fill = byId(fillId);
    if (ring) ring.classList.toggle('is-indet', pct == null);
    if (!fill) return;
    var c = ring && ring.classList.contains('ring--lg') ? 326.73 : 276.46;
    fill.style.strokeDashoffset = String(pct == null ? c : c * (1 - Math.max(0, Math.min(100, pct)) / 100));
  }

  function setProgress(pct, stage, detail, step) {
    var indet = (pct == null);
    var shown = indet ? 0 : Math.max(0, Math.min(100, pct));
    ringSet('ring', 'ringFill', indet ? null : shown);
    ringSet('runRing', 'runRingFill', indet ? null : shown);
    // 不确定态保留一个不可见占位，避免进度环内的文字在两种状态间跳动
    setText('runPct', indet ? '\u00a0' : shown + '%');
    if (stage) setText('runStage', stage);
    if (detail != null) setText('runDetail', detail);
    if (step != null) setText('runStep', step);
  }

  function runInstall(testWrite) {
    if (!S.bundle || S.busy) return;
    if (!S.ready) { toast('KernelSU 接口不可用'); return; }
    var s = selectionStats();
    if (!s.n) { toast('至少选中基础包'); return; }

    S.testWrite = !!testWrite;
    S.errCode = '';
    setBusy(true);
    setStatus(testWrite ? '正在校验分片…' : '正在安装…');
    resetLog();
    setProgress(null, testWrite ? '准备写入' : '准备中', '正在创建安装会话…', '—');
    setScreen('running', 'scrRunning', { title: testWrite ? '正在校验' : '正在安装' });

    var failed = false, ok = null, sawResult = false;

    runStream(buildInstallCmd(testWrite), function (line, tag) {
      if (tag !== 'o') return;
      parseRecords(line, {
        META: function (f) {
          if (f[0] === 'free_bytes' || f[0] === 'total_bytes') S.meta[f[0]] = f.slice(1).join('|');
        },
        PROGRESS: function (f) {
          var pctRaw = String(f[0] == null ? '' : f[0]).trim();
          var pct = (pctRaw === '' || isNaN(parseInt(pctRaw, 10))) ? null : parseInt(pctRaw, 10);
          var stage = STAGE_ZH[f[1]] || f[1] || '处理中';
          var d = parseInt(f[2], 10) || 0, t = parseInt(f[3], 10) || 0;
          var sd = f[4], st = f[5];
          var detail = t ? fmtSize(d) + ' / ' + fmtSize(t) : '';
          if (sd && st) detail += (detail ? ' · ' : '') + '第 ' + sd + ' / ' + st + ' 个分片';
          var step = (sd && st) ? ('第 ' + sd + ' / ' + st + ' 个分片') : '—';
          setProgress(pct, stage, detail || '处理中…', step);
        },
        LOG: function (f) {
          if (f[0] === 'session') appendLog('安装会话 #' + f[1]);
          else if (f[0] === 'write') {
            appendLog('写入 ' + f[1] + '/' + f[2] + '  ' + f[3] + '（' + fmtSize(f[4]) + '）');
          }
          else if (f[0] === 'session_abandoned') appendLog('已放弃会话 #' + f[1] + '（未提交）');
          else if (f[0] === 'retry_without_grant') appendLog('授予权限失败，去掉 -g 后重试');
          else appendLog(line);
        },
        DETAIL: function (f, l) { appendLog('> ' + String(l).replace(/^[A-Z_]+\|/, '')); },
        RESULT: function (f) {
          sawResult = true;
          if (f[0] === 'OK') ok = { pkg: f[1] || '', ver: f[2] || '', msg: f[3] || '' };
          else { failed = true; ok = { code: f[1], msg: f.slice(2).join('|') }; }
        },
        DIAG: function () { }
      });
    }, function (code, err) {
      setBusy(false);
      ulog('install done exit=' + code + ' mode=' + S.mode + ' lang=' + S.lang + ' result=' + JSON.stringify(ok || null).slice(0, 220) + ' err=' + String(err || '').slice(0, 160));
      if (err) appendLog('stderr: ' + err.trim());
      finishInstall(testWrite, failed, ok, err, sawResult, code);
    });
  }

  function finishInstall(testWrite, failed, ok, err, sawResult, code) {
    if (failed || !ok) {
      // 传输层校验：一条 RESULT 都没收到又非正常退出，说明脚本根本没跑起来，
      // 报 COMMIT_FAILED 会把用户引到错误方向。
      var noOutput = !sawResult && code !== 0;
      var c = (ok && ok.code) || (noOutput ? 'ENGINE_NO_OUTPUT' : 'COMMIT_FAILED');
      var msg = ok && ok.msg;
      if (c === 'ENGINE_NO_OUTPUT') {
        msg = 'exit=' + code + (err ? ' ' + String(err).replace(/^\s+|\s+$/g, '').slice(0, 240) : '');
      }
      S.errCode = c;
      setProgress(100, '未完成', '', null);
      showError(c, msg, err);
      return;
    }
    setProgress(100, testWrite ? '校验完成' : '完成', '', null);
    if (testWrite) {
      showDone({
        title: '分片校验通过',
        text: '所有分片都能写入安装会话，真正安装时不会卡在写入阶段。',
        okPkg: '',
        rows: [
          ['分片', selectionStats().n + ' 个'],
          ['写入体积', fmtSize(selectionStats().bytes)],
          ['说明', '会话已放弃，系统里的应用没有被改动。']
        ]
      });
      return;
    }
    S.lastResult = ok;
    var rows = [];
    if (ok.pkg) rows.push(['包名', ok.pkg]);
    if (ok.ver) rows.push(['已安装版本', ok.ver]);
    rows.push(['方式', S.mode === 'auto' ? '推荐分片' : (S.mode === 'all' ? '全部分片' : '手动分片')]);
    rows.push(['提示', 'root 静默安装，没有经过系统安装器。']);
    showDone({
      title: '安装成功',
      text: (S.meta.label || ok.pkg || '应用') + ' 已经装到系统里了。',
      okPkg: ok.pkg || '',
      rows: rows
    });
    toast('安装成功');
    if (ok.pkg) loadInstalledVersion(ok.pkg);
  }

  function showDone(cfg) {
    setText('doneTitle', cfg.title);
    setText('doneText', cfg.text || '');
    var kv = byId('doneKv');
    clear(kv);
    (cfg.rows || []).forEach(function (r) { kvInto(kv, r[0], r[1], r[0] === '包名', r[0] === '包名'); });
    S.okPkg = cfg.okPkg || '';
    show(byId('btnOpenApp'), !!S.okPkg);
    setScreen('done', 'scrDone', { title: '安装完成' });
    defaultStatus();
  }

  function showError(code, msg, err) {
    setText('errTitle', errInfo(code, false));
    setText('errText', errInfo(code, true));
    setText('errFix', errInfo(code, true));
    var kv = byId('errKv');
    clear(kv);
    kvInto(kv, '当前包', S.meta.label || S.bundle, false, false);
    kvInto(kv, '安装方式', S.mode === 'auto' ? '推荐分片' : (S.mode === 'all' ? '全部分片' : '手动分片'));
    kvInto(kv, '错误码', code, true, true);
    if (msg) kvInto(kv, '系统返回', msg, true, true);
    if (err) kvInto(kv, 'stderr', String(err).trim().slice(0, 300), true, true);
    setScreen('error', 'scrError', { title: '安装失败' });
    defaultStatus();
    toast('安装没有完成');
  }

  /* ============================================================ 选包页 */

  var QUICK = ['/sdcard/Download', '/sdcard', '/storage/emulated/0/Download', '/data/media/0/Download', '/data/local/tmp'];

  function joinPath(dir, name) { return (dir.replace(/\/+$/, '') || '') + '/' + name; }

  function renderQuick() {
    var q = byId('quickDirs');
    if (!q) return;
    clear(q);
    QUICK.forEach(function (d) {
      var label = d.replace('/storage/emulated/0', '/sdcard');
      var b = el('button', 'chip', label);
      b.type = 'button';
      b.title = d;
      b.classList.toggle('is-on', S.dir.replace(/\/+$/, '') === d.replace(/\/+$/, ''));
      b.onclick = function () { browse(d); };
      q.appendChild(b);
    });
  }

  function browse(dir) {
    if (!dir) dir = S.dir || '/sdcard/Download';
    S.dir = dir;
    LS.set('dir', dir);
    setText('curDir', dir);
    renderQuick();
    var box = byId('fileList');
    if (!box) return;
    clear(box);
    var sk = el('article', 'card');
    sk.appendChild(skList(5));
    box.appendChild(sk);
    setStatus('读取目录…');

    var rows = [], errMsg = '';
    runStream(engineCmd('list', [shq(dir)]), function (line, tag) {
      if (tag !== 'o') return;
      parseRecords(line, {
        LS: function (f) {
          if (f[0] === 'D') rows.push({ dir: true, name: f[1], size: 0, mt: f[3] });
          else if (f[0] === 'F') rows.push({ dir: false, name: f[1], size: f[2], mt: f[3] });
          else if (f[0] === 'ERROR') errMsg = f[1] + (f[2] ? ' · ' + f[2] : '');
        },
        raw: function () { }
      });
    }, function (code, err) {
      defaultStatus();
      clear(box);
      if (errMsg) {
        var key = errMsg.split(' · ')[0];
        var mini = el('article', 'card');
        var inner = el('div', 'blank-mini');
        inner.appendChild(el('h3', 'blank-t', '读不到这个目录'));
        inner.appendChild(el('p', 'blank-p', (LS_ERR_ZH[key] || errMsg) + '。试试下面的快捷目录，例如 /data/media/0/Download。'));
        mini.appendChild(inner);
        box.appendChild(mini);
        return;
      }

      var onlyPkg = byId('optFilter') ? byId('optFilter').checked : true;
      rows.sort(function (a, b) {
        if (a.dir !== b.dir) return a.dir ? -1 : 1;
        return a.name.localeCompare(b.name);
      });

      var card = el('article', 'card');
      var shown = 0;
      rows.forEach(function (r) {
        var isPkg = !r.dir && /\.(apk|apkm|apks|xapk|apkv)$/i.test(r.name);
        if (r.dir && r.name === '.') return;
        if (r.dir && r.name === '..') return;
        if (!r.dir && onlyPkg && !isPkg) return;
        shown += 1;

        var row = el('div', 'frow');
        var ic = el('span', 'frow-ico' + (!r.dir && isPkg ? ' is-pkg' : ''));
        ic.innerHTML = ico(r.dir ? 'folder' : (isPkg ? 'pkg' : 'doc'));
        row.appendChild(ic);

        var tx = el('div', 'frow-tx');
        tx.appendChild(el('div', 'frow-t' + (!r.dir ? ' is-pkg' : ''), r.name));
        tx.appendChild(el('div', 'frow-s', r.dir ? '文件夹' : (fmtSize(r.size) + ' · ' + fmtTime(r.mt))));
        row.appendChild(tx);
        if (!r.dir && !isPkg) row.classList.add('is-dim');

        var caret = el('span', '');
        if (r.dir) caret.innerHTML = ico('chevron', 'nav-caret');
        else if (isPkg) caret.innerHTML = ico('arrow-up-right', 'nav-caret');
        else caret.innerHTML = '';
        row.appendChild(caret);

        if (r.dir || isPkg) {
          row.classList.add('is-tap');
          row.onclick = function () {
            if (r.dir) { browse(joinPath(S.dir, r.name)); return; }
            inspect(joinPath(S.dir, r.name), null, true);
          };
        }
        card.appendChild(row);
      });

      if (shown) {
        card.appendChild(el('div', 'list-foot', '共 ' + plural(shown, '项', '项') + (shown < rows.length ? '（已按过滤器隐藏 ' + (rows.length - shown) + ' 项）' : '')));
        box.appendChild(card);
      } else {
        var em = el('article', 'card');
        var ei = el('div', 'blank-mini');
        ei.appendChild(el('h3', 'blank-t', onlyPkg ? '这里没有安装包' : '空目录'));
        ei.appendChild(el('p', 'blank-p', onlyPkg ? '关掉「只看安装包」可以看到全部文件，或换一个目录。' : '这个目录里没有任何内容。'));
        em.appendChild(ei);
        box.appendChild(em);
      }
    });
  }

  /* ============================================================ 历史页 */

  function loadHistory(force) {
    var box = byId('historyList');
    if (!box) return;
    if (S.history && !force) { renderHistory(S.history, S.historyText); return; }
    clear(box);
    var card = el('article', 'card');
    card.appendChild(waitingRow('正在读取安装记录'));
    box.appendChild(card);
    exec('cat /data/adb/apkmt/history.log 2>/dev/null || cat /data/local/tmp/apkmt/history.log 2>/dev/null', {}).then(function (r) {
      var s = (r.stdout || '').replace(/^\s+|\s+$/g, '');
      // 读失败且没有任何输出：仍然显示空态，但把原因写进远程日志，不静默吞掉
      if (!s && r.errno) ulog('history read errno=' + r.errno + ' stderr=' + String(r.stderr || '').slice(0, 160));
      S.history = s ? normalizeHistory(s) : [];
      S.historyText = s;
      renderHistory(S.history, S.historyText);
    }).catch(function (e) {
      ulog('history exec failed ' + (e && e.message ? e.message : e));
      S.history = [];
      S.historyText = '';
      renderHistory([], '');
    });
  }

  // items：normalizeHistory 的输出（文件顺序，旧在前）；rawText：原始文本，用于兜底
  function renderHistory(items, rawText) {
    var box = byId('historyList');
    if (!box) return;
    clear(box);

    if (!items.length) {
      // 文件里有内容但一条都识别不出来：给原始文本，别让用户看到「还没有安装记录」
      var text = (rawText == null ? '' : String(rawText)).replace(/^\s+|\s+$/g, '');
      if (text) {
        var pre = el('article', 'card');
        pre.appendChild(el('div', 'grp-hd', '原始记录'));
        pre.appendChild(el('pre', 'code', text.split('\n').reverse().join('\n')));
        box.appendChild(pre);
        return;
      }
      var card = el('article', 'card');
      var inner = el('div', 'blank-mini');
      inner.appendChild(el('h3', 'blank-t', '还没有安装记录'));
      inner.appendChild(el('p', 'blank-p', '装过一次之后，成功与失败都会记在这里。'));
      card.appendChild(inner);
      box.appendChild(card);
      return;
    }

    // 追加写的日志：最新在文件末尾，倒序取，最多 60 行
    var rows = [];
    for (var i = items.length - 1; i >= 0 && rows.length < 60; i--) rows.push(items[i]);

    var lastOk = null;
    for (var k = 0; k < rows.length; k++) { if (rows[k].ok && rows[k].pkg) { lastOk = rows[k]; break; } }

    var list = el('article', 'card');
    rows.forEach(function (it) {
      var row = el('div', 'hrow');
      var ic = el('span', 'hrow-ico ' + (it.ok ? 'is-ok' : 'is-bad'));
      ic.innerHTML = ico(it.ok ? 'check' : 'x');
      row.appendChild(ic);
      var tx = el('div', 'hrow-tx');
      tx.appendChild(el('div', 'hrow-t', it.pkg || '未知包名'));
      var mode = it.mode === 'auto' ? '推荐分片' : (it.mode === 'all' ? '全部分片' : (it.mode === 'manual' ? '手动分片' : it.mode));
      var sub = [fmtTime(it.t), it.ver ? 'v' + it.ver : '', mode].filter(Boolean);
      tx.appendChild(el('div', 'hrow-s', sub.join(' · ')));
      row.appendChild(tx);
      row.appendChild(el('span', 'hrow-tag ' + (it.ok ? 'is-ok' : 'is-bad'), it.ok ? '成功' : '失败'));
      list.appendChild(row);
    });
    box.appendChild(list);

    // 注意：这里**不能**用 .dock —— .dock 是 position: fixed 的底部操作条，
    // 塞进列表里会变成第二根固定操作条，叠在真正的底部按钮上方（残影的来源）。
    if (lastOk) {
      var actCard = el('article', 'card hact');
      var bOpen = el('button', 'btn btn--tint', '打开最近安装的应用');
      bOpen.type = 'button';
      bOpen.onclick = function () { openApp(lastOk.pkg); };
      actCard.appendChild(bOpen);
      box.appendChild(actCard);
    }
  }

  function openApp(pkg) {
    if (!pkg) return;
    exec('monkey -p ' + shq(pkg) + ' -c android.intent.category.LAUNCHER 1', {}).then(function (r) {
      if (/No activities found|aborted/i.test((r.stdout || '') + (r.stderr || ''))) toast('这个包没有可启动的界面');
    }).catch(function () { });
  }

  /* ============================================================ 诊断页 */

  var verifierOriginal = LS.get('verifier_orig', '');

  function loadDiag() {
    defaultStatus();
    var kv = byId('diagKv'), box = byId('diagBox');
    if (kv) {
      clear(kv);
      kv.appendChild(el('div', 'kv-r'));
      var r0 = kv.firstChild;
      r0.appendChild(el('span', 'sk sk-line sk-line--sm', ''));
      var r1 = el('div', 'kv-r');
      r1.appendChild(el('div', 'waiting', '正在读取引擎信息'));
      kv.appendChild(r1);
    }
    if (box) box.textContent = '正在读取…';

    var lines = [], vals = {};
    runStream(engineCmd('diag', []), function (line, tag) {
      if (tag !== 'o') return;
      parseRecords(line, {
        DIAG: function (f) {
          var v = f.slice(1).join('|');
          vals[f[0]] = v;
          lines.push(f[0] + ' = ' + v);
        },
        raw: function (l) { lines.push(l); }
      });
    }, function (code) {
      if (box) box.textContent = lines.join('\n') || '（引擎没有输出）';
      if (kv) {
        clear(kv);
        if (code !== 0 && !lines.length) {
          kvInto(kv, '状态', '引擎没有响应');
          kvInto(kv, '建议', '到 KernelSU 管理器确认 apkmt 模块已启用，然后重新自检。');
        } else {
          kvInto(kv, '机型', vals.device_model);
          kvInto(kv, '系统', (vals.device_release || '?') + ' · SDK ' + (vals.device_sdk || '?'));
          kvInto(kv, 'ABI', vals.device_abi);
          kvInto(kv, '密度 / 区域', (vals.device_density || '?') + 'dpi · ' + (vals.device_locale || '?'));
          if (vals.device_density_physical || vals.device_density_override) {
            kvInto(kv, '物理密度 / 覆盖', (vals.device_density_physical || '?') + 'dpi · ' + (vals.device_density_override || '未覆盖'));
          }
          if (vals.selected_abi) kvInto(kv, '选中 ABI', vals.selected_abi);
          kvInto(kv, '可用空间', fmtSize(vals.free_data));
          kvInto(kv, '运行身份', (vals.whoami || '?') + ' · uid ' + (vals.uid || '?'));
          kvInto(kv, 'unzip', vals.unzip);
          kvInto(kv, 'pm', vals.pm);
        }
      }
      if (vals.device_model) S.meta.device_model = vals.device_model;
      if (vals.device_sdk) S.device.device_sdk = vals.device_sdk;
      if (vals.engine_version) S.meta.engine_version = vals.engine_version;
      renderAbout();
      defaultStatus();
    });
    // 放在 diag 流之后发起：它的回调会晚于 diag 返回，写入的键值是最终显示值
    loadVerifier();
  }

  function renderAbout() {
    var box = byId('aboutBox');
    if (!box) return;
    clear(box);
    kvInto(box, '引擎版本', S.meta.engine_version || '—');
    kvInto(box, '模块目录', MODDIR, true, true);
    kvInto(box, '引擎脚本', ENG, true, true);
    kvInto(box, '包名与版本', '来自包内 manifest / info.json（打包方写入的权威值）；两者都没有时才从 toc.pb 猜测。');
    kvInto(box, '应用名 / 图标', '优先级：info.json / manifest.json → resources.arsc（资源引用）→ manifest 字面量 → 文件名 / 首字母。');
    kvInto(box, 'APK 图标', '.apk 的图标从资源表（resources.arsc）解析；自适应图标按「背景层 + 前景层」分层渲染，前景层取 108dp 画布、只保留中间 72dp 可见安全区。');
  }

  function loadVerifier() {
    var kv = byId('verifierKv');
    if (!kv) return;
    clear(kv);
    var r = el('div', 'kv-r');
    r.appendChild(el('span', 'kv-k', '读取中'));
    r.appendChild(el('div', 'kv-v', ''));
    var d = el('span', 'dots');
    d.appendChild(el('i')); d.appendChild(el('i')); d.appendChild(el('i'));
    r.lastChild.appendChild(d);
    kv.appendChild(r);

    exec('settings get global verifier_verify_adb_installs; echo "---"; settings get global package_verifier_enable; echo "---"; settings get global package_verifier_user_consent', {}).then(function (res) {
      var p = (res.stdout || '').split('---');
      var a = (p[0] || '').trim(), b = (p[1] || '').trim(), c = (p[2] || '').trim();
      clear(kv);
      kvInto(kv, '状态', a === '0' ? '已关闭（安装不再走校验）' : '开启');
      kvInto(kv, 'adb 校验值', a === 'null' ? '未设置' : a, true, true);
      kvInto(kv, '校验总开关', b === 'null' ? '未设置' : b, true, true);
      kvInto(kv, '用户同意', c === 'null' ? '未设置' : c, true, true);
      kvInto(kv, '原始值', verifierOriginal || '尚未由本模块修改', true, true);
    }).catch(function () {
      clear(kv);
      kvInto(kv, '状态', '读取失败');
    });
  }

  function setVerifier(off) {
    if (off) {
      exec('settings get global verifier_verify_adb_installs', {}).then(function (r) {
        var v = (r.stdout || '').trim();
        if (!verifierOriginal) { verifierOriginal = v || 'null'; LS.set('verifier_orig', verifierOriginal); }
        return exec('settings put global verifier_verify_adb_installs 0', {});
      }).then(function () {
        toast('已关闭 adb 安装校验');
        loadVerifier();
      }).catch(function (e) { toast('写入失败：' + e); });
    } else {
      var v = verifierOriginal || 'null';
      var cmd = (v === 'null' || v === '') ? 'settings delete global verifier_verify_adb_installs'
        : 'settings put global verifier_verify_adb_installs ' + shq(v);
      exec(cmd, {}).then(function () {
        toast('已恢复原设置');
        LS.del('verifier_orig');
        verifierOriginal = '';
        loadVerifier();
      }).catch(function (e) { toast('恢复失败：' + e); });
    }
  }

  function loadUiLog() {
    var box = byId('uiLogBox');
    if (!box) return;
    box.textContent = '正在读取…';
    exec('tail -n 120 /data/local/tmp/apkmt-ui.log 2>/dev/null', {}).then(function (r) {
      box.textContent = (r.stdout || '').trim() || '（还没有日志；打开过本页面就会有）';
    }).catch(function (e) { box.textContent = '读取失败：' + e; });
  }

  /* ============================================================ 启动 */

  function applyModuleDir() {
    try {
      var raw = (typeof KSU.moduleInfo === 'function') ? KSU.moduleInfo() : '';
      var info = (typeof raw === 'string') ? JSON.parse(raw) : raw;
      if (info && info.moduleDir) {
        MODDIR = info.moduleDir;
        ENG = MODDIR.replace(/\/+$/, '') + '/bin/apkmt.sh';
      }
    } catch (e) { }
  }

  function showBlocked(title, text) {
    setText('blockedTitle', title);
    setText('blockedText', text);
    setBoot(false);
    setScreen('install', 'scrBlocked', { title: 'apkmt', back: null });
    setStatus('未连接');
  }

  function autoBoot(attempt) {
    attempt = attempt || 0;
    setBoot(true, attempt ? '正在重新自检运行环境…' : '正在自检运行环境…');
    setScreen('install', 'scrBoot', { title: 'apkmt', back: null });
    setStatus('正在连接 KernelSU…');
    S.ready = false;

    if (!KSU || typeof KSU.exec !== 'function') {
      ulog('boot no ksu');
      showBlocked('没有检测到 KernelSU 环境',
        '请在 KernelSU 管理器的「模块 → apkmt → 打开 WebUI」里使用本页面；普通浏览器里打开会因为拿不到 root 而无法工作。');
      return;
    }

    applyModuleDir();
    ulog('boot ksu=' + (!!KSU) + ' exec=' + (typeof KSU.exec) + ' spawn=' + (typeof KSU.spawn) + ' mInfo=' + (typeof KSU.moduleInfo) + ' moddir=' + MODDIR + ' eng=' + ENG);

    try { if (typeof KSU.fullScreen === 'function') KSU.fullScreen(false); } catch (e) { }
    try { if (typeof KSU.enableEdgeToEdge === 'function') KSU.enableEdgeToEdge(true); } catch (e) { }

    // 桥接自检：验证 spawn + 逐行回调（外部依赖里风险最高的一环）
    if (typeof KSU.spawn !== 'function') {
      ulog('boot no spawn');
      showBlocked('KernelSU 桥接不可用', '当前环境没有提供流式执行接口（ksu.spawn），无法读取引擎输出。请升级 KernelSU 管理器或改用 MMRL WebUI X 打开本页。');
      return;
    }

    var probeGot = false;
    runStream('echo __apkmt_probe__', function (line) {
      if (line.indexOf('__apkmt_probe__') >= 0) probeGot = true;
    }, function (pcode, perr) {
      ulog('probe code=' + pcode + ' got=' + probeGot + ' err=' + String(perr || '').slice(0, 160));
      if (!probeGot) {
        showBlocked('桥接自检没有通过',
          '命令已经发出，但没有收到任何输出。到「诊断」页可以查看 WebUI 自检日志，把日志发出来能定位问题。');
        return;
      }
      setText('bootNote', '正在读取设备与引擎信息…');
      runStream(engineCmd('diag', []), function (line, tag) {
        if (tag !== 'o') return;
        parseRecords(line, {
          DIAG: function (f) {
            if (f[0] === 'device_model') S.meta.device_model = f[1];
            if (f[0] === 'engine_version') S.meta.engine_version = f[1];
            if (f[0] === 'device_sdk') S.device.device_sdk = f[1];
            if (f[0] === 'device_release') S.device.device_release = f[1];
          }
        });
      }, function (code, err) {
        if (code !== 0) {
          showBlocked('引擎没有响应', 'apkmt 的安装脚本没有输出。到 KernelSU 管理器确认模块已启用并已重启过一次系统，然后点「重新自检」。');
          ulog('diag code=' + code + ' err=' + String(err || '').slice(0, 160));
          return;
        }
        S.ready = true;
        setBoot(false);
        setBusy(false);
        setScreen('install', pkgScreenId(), { title: 'apkmt', back: null });
        defaultStatus();
        renderAbout();
        ulog('diag code=' + code + ' engine=' + (S.meta.engine_version || '?') + ' sdk=' + (S.device.device_sdk || '?'));
        // 每次打开都落在「选包」页：不自动解析上次的包，由用户挑一个再解析安装
        setScreen('files', null, { back: null });
        ulog('land files ' + (S.dir || ''));
        maybeDemo();
      });
    });
  }

  // 预览/演示深链（仅当 demo.js 注入了假桥接时才会被满足）
  function maybeDemo() {
    if (!/demo/i.test(window.location.search)) return;
    var m = /demo=([a-z]+)/i.exec(window.location.search);
    var kind = m ? m[1].toLowerCase() : '';
    if (kind === 'files') { setScreen('files', null, { back: null }); browse('/sdcard/Download'); }
    else if (kind === 'history') { setScreen('history', null, { back: null }); loadHistory(true); }
    else if (kind === 'diag') { setScreen('diag', null, { back: null }); loadDiag(); }
  }

  function initOptions() {
    var optDown = byId('optDowngrade'), optGrant = byId('optGrant'),
      optVer = byId('optVerifier'), optInst = byId('optInstaller');
    if (optDown) optDown.checked = LS.get('optDowngrade', '0') === '1';
    if (optGrant) optGrant.checked = LS.get('optGrant', '0') === '1';
    if (optVer) optVer.checked = LS.get('optVerifier', '0') === '1';
    if (optInst) optInst.value = LS.get('optInstaller', '');
    ['optDowngrade', 'optGrant', 'optVerifier'].forEach(function (id) {
      var n = byId(id);
      if (!n) return;
      n.onchange = function () { LS.set(id, this.checked ? '1' : '0'); };
    });
    if (optInst) optInst.onchange = function () { LS.set('optInstaller', this.value); };
    // 「关闭 adb 校验」开关直接落盘全局设置
    if (optVer) optVer.addEventListener('change', function () { setVerifier(!!this.checked); });
  }

  function initEvents() {
    var tabs = document.querySelectorAll('.tab');
    for (var i = 0; i < tabs.length; i++) {
      tabs[i].onclick = function () { setScreen(this.getAttribute('data-view'), null, { back: null }); };
    }

    if (byId('btnBack')) byId('btnBack').onclick = goBack;
    if (byId('btnRetryBoot')) byId('btnRetryBoot').onclick = function () { autoBoot(1); };
    if (byId('btnGoFiles')) byId('btnGoFiles').onclick = function () { setScreen('files', null, { back: null }); };
    if (byId('btnFailPick')) byId('btnFailPick').onclick = function () { setScreen('files', null, { back: null }); };
    if (byId('btnFailRetry')) byId('btnFailRetry').onclick = function () { if (S.bundle) inspect(S.bundle); };

    if (byId('btnReinspect')) byId('btnReinspect').onclick = function () { if (S.bundle) inspect(S.bundle); };
    if (byId('btnManageSplits')) byId('btnManageSplits').onclick = function () {
      if (!S.entries.length) { toast('这个包里没有可管理的分片'); return; }
      renderSplits();
      segIndex(byId('segPick'), 'data-pick', S.mode === 'all' ? 'all' : (S.mode === 'manual' ? 'none' : 'recommended'));
      setScreen('manager', 'scrManager', { title: '分片' });
    };
    if (byId('btnSplitsDone')) byId('btnSplitsDone').onclick = function () { setScreen('install', 'scrPkg', { title: 'apkmt' }); };

    var segMode = byId('segMode');
    if (segMode) {
      var mb = segMode.querySelectorAll('button');
      for (var a = 0; a < mb.length; a++) {
        mb[a].onclick = function () {
          S.mode = this.getAttribute('data-mode');
          LS.set('mode', S.mode);
          S.manualTouched = false;
          applyModeSelection();
          if (S.view === 'manager') renderSplits();
          segIndex(byId('segPick'), 'data-pick', S.mode === 'all' ? 'all' : (S.mode === 'manual' ? 'none' : 'recommended'));
        };
      }
    }
    var segLang = byId('segLang');
    if (segLang) {
      var lb = segLang.querySelectorAll('button');
      for (var b = 0; b < lb.length; b++) {
        lb[b].onclick = function () {
          S.lang = this.getAttribute('data-lang');
          LS.set('lang', S.lang);
          segIndex(segLang, 'data-lang', S.lang);
          if (S.bundle) inspect(S.bundle);
        };
      }
    }
    var segPick = byId('segPick');
    if (segPick) {
      var pb = segPick.querySelectorAll('button');
      for (var c = 0; c < pb.length; c++) {
        pb[c].onclick = function () { pickSplits(this.getAttribute('data-pick')); };
      }
    }

    if (byId('btnInstall')) byId('btnInstall').onclick = function () { runInstall(false); };
    if (byId('btnTestWrite')) byId('btnTestWrite').onclick = function () { runInstall(true); };
    if (byId('btnErrRetry')) byId('btnErrRetry').onclick = function () { runInstall(S.testWrite); };
    if (byId('btnErrChoose')) byId('btnErrChoose').onclick = function () { setScreen('files', null, { back: null }); };
    if (byId('btnAgain')) byId('btnAgain').onclick = function () { runInstall(S.testWrite); };
    if (byId('btnOpenApp')) byId('btnOpenApp').onclick = function () { openApp(S.okPkg); };

    if (byId('optFilter')) byId('optFilter').onchange = function () { browse(S.dir); };
    if (byId('btnUp')) byId('btnUp').onclick = function () {
      var d = S.dir.replace(/\/+$/, '');
      var up = d.replace(/\/[^/]*$/, '');
      browse(up || '/');
    };

    if (byId('btnReloadHistory')) byId('btnReloadHistory').onclick = function () { loadHistory(true); };
    if (byId('btnClearHistory')) byId('btnClearHistory').onclick = function () {
      exec('rm -f /data/adb/apkmt/history.log /data/local/tmp/apkmt/history.log', {}).then(function () {
        S.history = null;
        toast('已清空记录');
        loadHistory(true);
      }).catch(function () { toast('清空失败'); });
    };

    if (byId('btnReloadDiag')) byId('btnReloadDiag').onclick = function () { autoBoot(1); };
    if (byId('btnReloadUilog')) byId('btnReloadUilog').onclick = loadUiLog;
    if (byId('btnClearUilog')) byId('btnClearUilog').onclick = function () {
      exec('rm -f /data/local/tmp/apkmt-ui.log', {}).then(function () { ulogCount = 0; loadUiLog(); toast('已清空'); });
    };
    if (byId('btnVerifierOff')) byId('btnVerifierOff').onclick = function () { setVerifier(true); };
    if (byId('btnVerifierRestore')) byId('btnVerifierRestore').onclick = function () { setVerifier(false); };
  }

  function markDocked() {
    // 屏内有 .dock（底部固定操作条）时打个类，CSS 会给它留出操作条的高度
    var scs = document.querySelectorAll('.screen');
    for (var i = 0; i < scs.length; i++) {
      try { if (scs[i].querySelector('.dock')) scs[i].classList.add('is-docked'); } catch (e) { }
    }
  }

  function boot() {
    initEvents();
    initOptions();
    markDocked();

    setBusy(false);
    segIndex(byId('segMode'), 'data-mode', S.mode);
    segIndex(byId('segLang'), 'data-lang', S.lang);
    segIndex(byId('segPick'), 'data-pick', 'recommended');
    resetLog();
    if (byId('curDir')) byId('curDir').textContent = S.dir;

    if (byId('optFilter')) byId('optFilter').checked = true;

    autoBoot(0);
  }

  function start() {
    try {
      if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', boot);
      else boot();
    } catch (e) {
      try { ulog('boot crash ' + (e && e.message ? e.message : e)); } catch (e2) { }
    }
  }
  start();
})();
