/* ============================================================================
 * apkmt WebUI — 演示桥接（可选文件）
 *
 * 用途：在普通浏览器 / 预览器里（没有 window.ksu）注入一份最小可用的假桥接，
 * 让界面与全部加载动画真正跑起来，方便预览与验收。
 *
 * 边界（必须遵守）：
 *   - 真机 KernelSU WebView 里 window.ksu 一定存在，此时本文件立刻返回，
 *     不注册任何全局回调、不覆盖任何逻辑，真机数据流完全不受影响；
 *   - 它只「伪造引擎记录」，不参与任何解析与状态机逻辑——app.js 的桥接、
 *     记录解析、状态语义与真机逐字一致；
 *   - 输出格式严格照抄引擎协议（META / ENTRY / PROGRESS / RESULT / LOG /
 *     DETAIL / DIAG / LS），并且故意把多行塞进同一次 data 回调，
 *     以便验证 app.js 的逐行缓冲逻辑。
 * ========================================================================== */
(function () {
  'use strict';

  if (typeof window.ksu !== 'undefined') return;   // 真机：完全静默
  if (typeof window.kernelsu !== 'undefined') return;

  var DEV = {
    sdk: '35', release: '15', model: 'Pixel 8 Pro',
    abi: 'arm64-v8a', abilist: 'arm64-v8a,armeabi-v7a,armeabi',
    density: '420', densityPhysical: '440', densityOverride: '420', locale: 'zh-CN'
  };
  var MODDIR = '/data/adb/modules/apkmt';

  // demo 图标（96x96 渐变 PNG，由 _audit/tests/gen_demo_icon.py 生成）。
  // 真机引擎给的是 icon-cache/<file>.png?v<ts> 同源相对 URL，demo 用同源 data URL，
  // 两者走的是同一条 <img src> 加载路径，用来验证图标成功分支。
  var DEMO_ICON = 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAGAAAABgCAYAAADimHc4AAACo0lEQVR42u3dVU8jcRQF8Pt1Fnd3d3d3d5d1+ZgUaUuNwhrPZyc80JCyQOnM/xI4N/klN5PJPJzzPlfEobn+8Q6vibzUuf6egLdMJfS/3xJB0ZwP/msS6HHOhP/F+jg9mb3hf04GxS7u4P98SgHF73nhf0wF2Sf2Aj6kgewTW/jv00H2e1L4vw8zQM55OPwD6yVy3AMFZIKcd3/4+1kgc6IK+LWXDTInuoDdHJA5d8PfyQWZFylgOw9k3m0BP7fyQeZFCti0HpBxkQI2CkDmRQpYLwSZdxP+1VoRSI9crRaD9MjVSglIj1wtl4L0yOVSKUiPXC6WgfTI5UI5SI9czleA9Eh4rhKkR8KzVSA9Ep6pBumR8LS1kBq5mKoB6ZGLyVqQHquAOpAeuZioB+mR0HgDSI+ExhpBeiQ02gTSI6ERayE1EhxuBumR4FALSI8EB1tBeiQ40AbSI4H+dpAeCfR1gPRIoNdaSI0EejpBesTf3QXSI/6ubpAe8Xf2gPSIv6MXpEd87X0gPeJrsxZSI77WfpAe8bUMgPTIefMgSI+cNw2B9FgFDIP0yHnjCEiPeBtGQXrEW28tpEa8dWMgPeKtHQfpEU/NBEiPeKonQXrEUzUF0iOeymmQHnFXTIP0iLt8BqRH3GWzID3iLp0D6bn5b9xZyTzIvNu/Jp4VL4DMixRQtAgyL1JAofWAjLst4LRgCWRepID8ZZB5d24InOatgMyJuqBxmrsKMieqgJOcNZA5915SOsleBznvv3fETrI3QM578JreSZb1EjnmSfckjzM3QfaL6aLqccYWyD4x3xM+Tt8G2edZV7WP03ZA8Yv7trwrdRcUO7FzXCl7oKcTJ8aVbH2cHiVOjytpHxRNNOYo8QBvmbzUOUo4xGviVFD/ABUvYmDyYsPhAAAAAElFTkSuQmCC';

  // 自适应图标的前景层（v1.3.5）：108dp 画布，内容只占中间 72dp 可见安全区，
  // 由 WebUI 按 icon_scale=1.5 放大后裁切。用内联 SVG data URI，走与真机
  // icon-cache/*.svg 完全相同的 <img src> 加载路径。
  var DEMO_FG_SVG = 'data:image/svg+xml;charset=utf-8,' + encodeURIComponent(
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 108 108">' +
    '<circle cx="54" cy="54" r="27" fill="#ffffff"/>' +
    '<path d="M48 42 L70 54 L48 66 Z" fill="#3d5afe"/>' +
    '</svg>'
  );

  /* ------------------------------------------------------------ 假包内容 */

  function bundle(name, pkg, label, ver, code, minApi, tgtApi) {
    var e = [
      { n: 'base.apk', s: 41960512, k: 'base', t: '', sel: '1', r: 'base_required' },
      { n: 'split_config.arm64_v8a.apk', s: 8421376, k: 'abi', t: 'arm64-v8a', sel: '1', r: 'abi_best' },
      { n: 'split_config.armeabi_v7a.apk', s: 7864320, k: 'abi', t: 'armeabi-v7a', sel: '0', r: 'abi_lower' },
      { n: 'split_config.x86_64.apk', s: 9125888, k: 'abi', t: 'x86_64', sel: '0', r: 'abi_unsupported' },
      { n: 'split_config.xxhdpi.apk', s: 1153434, k: 'dpi', t: 'xxhdpi', sel: '1', r: 'dpi_best' },
      { n: 'split_config.hdpi.apk', s: 962560, k: 'dpi', t: 'hdpi', sel: '0', r: 'dpi_other' },
      { n: 'split_config.zh.apk', s: 271360, k: 'lang', t: 'zh', sel: '1', r: 'lang_system' },
      { n: 'split_config.en.apk', s: 253952, k: 'lang', t: 'en', sel: '0', r: 'lang_other' },
      { n: 'split_config.ja.apk', s: 245760, k: 'lang', t: 'ja', sel: '0', r: 'lang_other' },
      { n: 'split_feature.stories.apk', s: 1013760, k: 'other', t: 'stories', sel: '1', r: 'feature_required' },
      { n: 'icon.png', s: 20480, k: 'other', t: '', sel: '0', r: 'not_apk' },
      { n: 'info.json', s: 620, k: 'other', t: '', sel: '0', r: 'not_apk' }
    ];
    return {
      path: '/sdcard/Download/APKMirror/' + name, pkg: pkg, label: label, ver: ver, code: code,
      minApi: minApi, tgtApi: tgtApi, type: 'apkm', size: 63963136, entries: e
    };
  }

  var BUNDLES = {
    instagram: bundle('Instagram_v371.0.0.34.108_apkmirror.com.apkm', 'com.instagram.android', 'Instagram', '371.0.0.34.108', '371034108', '29', '34'),
    whatsapp: bundle('WhatsApp_Messenger_v2.25.11.76_apkmirror.com.apkm', 'com.whatsapp', 'WhatsApp', '2.25.11.76', '251176008', '24', '35'),
    adaptive: bundle('演示应用_v1.3.5_adaptive.apkm', 'com.demo.adaptive', '演示应用', '1.3.5', '10305', '26', '35')
  };

  // 图标 / 应用名来源夹具：
  //   adaptive —— v1.3.5 自适应图标：前景是 108dp 画布 SVG、背景是纯色，icon_scale=1.5，
  //               按「背景层 + 前景层」分层渲染（与桌面启动器遮罩一致）；
  //   instagram —— 普通 mipmap 位图图标（整图，icon_scale=1），走原有加载路径；
  //   whatsapp —— 故意没有图标，用来预览「ksu://icon/<包名> → 首字母兜底」的回退链。
  BUNDLES.adaptive.icon = DEMO_FG_SVG;
  BUNDLES.adaptive.iconBg = '#3d5afe';
  BUNDLES.adaptive.iconScale = '1.5';
  BUNDLES.adaptive.iconSrc = 'adaptive';
  BUNDLES.adaptive.labelSrc = 'arsc';
  BUNDLES.instagram.icon = DEMO_ICON;
  BUNDLES.instagram.iconBg = '';
  BUNDLES.instagram.iconScale = '1';
  BUNDLES.instagram.iconSrc = 'mipmap';
  BUNDLES.instagram.labelSrc = 'json';
  BUNDLES.whatsapp.icon = '';
  BUNDLES.whatsapp.iconBg = '';
  BUNDLES.whatsapp.iconScale = '';
  BUNDLES.whatsapp.iconSrc = 'none';
  BUNDLES.whatsapp.labelSrc = 'json';

  var current = BUNDLES.instagram;

  function bundleByPath(p) {
    var key = String(p || '').toLowerCase();
    if (key.indexOf('whatsapp') >= 0) return BUNDLES.whatsapp;
    if (key.indexOf('演示应用') >= 0 || key.indexOf('adaptive') >= 0) return BUNDLES.adaptive;
    return BUNDLES.instagram;
  }

  function selectedOf(b) {
    var out = [];
    b.entries.forEach(function (e) {
      if (e.sel === '1' && /\.apk$/i.test(e.n)) out.push(e);
    });
    return out;
  }

  /* ------------------------------------------------------------ 记录生成 */

  function linesInspect(b) {
    var L = [];
    L.push('META|engine_version|1.3.5');
    L.push('META|bundle|' + b.path);
    L.push('META|bundle_size|' + b.size);
    L.push('META|bundle_type|' + b.type);
    L.push('META|pkg|' + b.pkg);
    L.push('META|pkg_source|info.json');
    L.push('META|label|' + b.label);
    L.push('META|label_src|' + (b.labelSrc || 'json'));
    L.push('META|icon|' + (b.icon || ''));
    L.push('META|icon_bg|' + (b.iconBg || ''));
    L.push('META|icon_scale|' + (b.iconScale || ''));
    L.push('META|icon_src|' + (b.iconSrc || 'none'));
    L.push('META|version|' + b.ver);
    L.push('META|version_code|' + b.code);
    L.push('META|min_api|' + b.minApi);
    L.push('META|target_api|' + b.tgtApi);
    L.push('META|entry_count|' + b.entries.length);
    L.push('META|selected_count|' + selectedOf(b).length);
    L.push('META|total_bytes|' + selectedOf(b).reduce(function (s, e) { return s + e.s; }, 0));
    L.push('META|device_sdk|' + DEV.sdk);
    L.push('META|device_release|' + DEV.release);
    L.push('META|device_model|' + DEV.model);
    L.push('META|device_abi|' + DEV.abi);
    L.push('META|device_abilist|' + DEV.abilist);
    L.push('META|device_density|' + DEV.density);
    L.push('META|device_density_physical|' + DEV.densityPhysical);
    L.push('META|device_density_override|' + DEV.densityOverride);
    L.push('META|device_locale|' + DEV.locale);
    L.push('META|selected_dpi|xxhdpi');
    L.push('META|selected_abi|' + DEV.abi);
    L.push('META|unzip|/data/adb/ksu/bin/busybox unzip');
    L.push('META|tmp|/data/adb/apkmt/tmp/1042');
    L.push('META|free_bytes|41690132480');
    b.entries.forEach(function (e) {
      L.push('ENTRY|' + e.n + '|' + e.s + '|' + e.k + '|' + e.t + '|' + e.sel + '|' + e.r);
    });
    L.push('META|selected_count|' + selectedOf(b).length);
    L.push('META|total_bytes|' + selectedOf(b).reduce(function (s, e) { return s + e.s; }, 0));
    return L;
  }

  function linesInstall(b, testWrite) {
    var sel = selectedOf(b);
    var total = sel.reduce(function (s, e) { return s + e.s; }, 0);
    var L = [];
    L.push('META|free_bytes|41690132480');
    L.push('META|total_bytes|' + total);
    L.push('PROGRESS|1|creating_session|0|' + total);
    L.push('DETAIL|Success');
    L.push('LOG|session|1242377');
    var done = 0;
    sel.forEach(function (e, i) {
      done += e.s;
      L.push('LOG|write|' + (i + 1) + '|' + sel.length + '|' + e.n + '|' + e.s + '|');
      L.push('PROGRESS|' + Math.round(done / total * 94) + '|writing|' + done + '|' + total + '|' + (i + 1) + '|' + sel.length);
    });
    if (testWrite) {
      L.push('LOG|session_abandoned|1242377');
      L.push('PROGRESS|100|write_test_ok|' + total + '|' + total);
      L.push('RESULT|OK|||write_test_ok');
      return L;
    }
    if (/fail/i.test(b.path)) {
      L.push('DETAIL|Failure [INSTALL_FAILED_MISSING_SPLIT: Missing split for com.instagram.android]');
      L.push('RESULT|FAIL|INSTALL_FAILED_MISSING_SPLIT|Missing split for com.instagram.android');
      return L;
    }
    L.push('PROGRESS|95|committing|' + total + '|' + total);
    L.push('DETAIL|Success');
    L.push('PROGRESS|100|done|' + total + '|' + total);
    L.push('RESULT|OK|' + b.pkg + '|' + b.ver + '|installed');
    return L;
  }

  function linesDiag() {
    return [
      'DIAG|engine_version|1.3.5',
      'DIAG|uid|0',
      'DIAG|whoami|uid=0(root) gid=0(root)',
      'DIAG|unzip|/data/adb/ksu/bin/busybox unzip',
      'DIAG|pm|/system/bin/pm',
      'DIAG|busybox|/data/adb/ksu/bin/busybox',
      'DIAG|ksu_busybox|yes',
      'DIAG|state_dir|/data/adb/apkmt',
      'DIAG|state_dir_writable|yes',
      'DIAG|device_sdk|' + DEV.sdk,
      'DIAG|device_release|' + DEV.release,
      'DIAG|device_model|' + DEV.model,
      'DIAG|device_abi|' + DEV.abi + ' (' + DEV.abilist + ')',
      'DIAG|device_density|' + DEV.density,
      'DIAG|device_density_physical|' + DEV.densityPhysical,
      'DIAG|device_density_override|' + DEV.densityOverride,
      'DIAG|selected_abi|' + DEV.abi,
      'DIAG|device_locale|' + DEV.locale,
      'DIAG|free_data|41690132480'
    ];
  }

  var FILES = {
    '/sdcard/Download': [
      ['D', 'APKMirror', 0, 1749800000],
      ['D', 'Telegram', 0, 1749750000],
      ['F', 'Instagram_v371.0.0.34.108_apkmirror.com.apkm', 63963136, 1749812400],
      ['F', 'WhatsApp_Messenger_v2.25.11.76_apkmirror.com.apkm', 58130432, 1749711200],
      ['F', '演示应用_v1.3.5_adaptive.apkm', 31457280, 1749900000],
      ['F', 'XposedInstaller_v4.6.2.apk', 4194304, 1749611000],
      ['F', 'notes.txt', 1284, 1749510000],
      ['F', 'IMG_20250612_181233.jpg', 3826176, 1749400000]
    ],
    '/sdcard/Download/APKMirror': [
      ['F', 'Instagram_v371.0.0.34.108_apkmirror.com.apkm', 63963136, 1749812400],
      ['F', 'WhatsApp_Messenger_v2.25.11.76_apkmirror.com.apkm', 58130432, 1749711200],
      ['F', '演示应用_v1.3.5_adaptive.apkm', 31457280, 1749900000],
      ['F', 'YouTube_19.16.39_apkmirror.com.apkm', 120586240, 1749611000],
      ['F', 'Spotify_8.9.84.582_apkmirror.com.apkm', 41943040, 1749550000],
      ['F', 'Google_Maps_11.135.0.xapk', 96468992, 1749490000]
    ],
    '/sdcard': [
      ['D', 'Download', 0, 1749800000],
      ['D', 'DCIM', 0, 1749790000],
      ['D', 'Android', 0, 1749780000],
      ['D', 'Pictures', 0, 1749770000],
      ['D', 'Documents', 0, 1749760000]
    ],
    '/data/local/tmp': [
      ['D', 'apkmt', 0, 1749805000],
      ['F', 'apkmt-ui.log', 6144, 1749812000]
    ]
  };

  function linesList(dir) {
    if (!dir) return ['LS|ERROR|no_dir'];
    if (dir.charAt(0) !== '/') return ['LS|ERROR|need_absolute_path'];
    var rows = FILES[dir.replace(/\/+$/, '') || '/'];
    if (!rows) return ['LS|ERROR|not_a_directory|' + dir];
    var L = ['LS|HDR|' + dir];
    rows.forEach(function (r) { L.push('LS|' + r[0] + '|' + r[1] + '|' + r[2] + '|' + r[3]); });
    L.push('LS|END|' + rows.length);
    return L;
  }

  // 故意混两种格式：新的竖线记录（当前协议）与旧版空格记录（升级前留下的），
  // 用来验证 app.js 的 parseHistoryLine 归一化与原始文本兜底。
  var HISTORY = [
    '1749550000|FAIL|com.google.android.youtube|19.16.39|manual|INSTALL_FAILED_MISSING_SPLIT|/sdcard/Download/YouTube_19.16.39_apkmirror.com.apkm',
    '1749611000|OK|de.robv.android.xposed.installer|4.6.2|all|installed|/sdcard/Download/XposedInstaller_v4.6.2.apk',
    '1749711200|FAIL|com.whatsapp|2.25.11.76|auto|INSTALL_FAILED_UPDATE_INCOMPATIBLE|/sdcard/Download/WhatsApp_Messenger_v2.25.11.76_apkmirror.com.apkm',
    '1749812400|OK|com.instagram.android|371.0.0.34.108|auto|installed|/sdcard/Download/Instagram_v371.0.0.34.108_apkmirror.com.apkm',
    '2026-01-02T03:04:05 OK /sdcard/Download/Telegram_v11.2.0.apk pkg=org.telegram.messenger ver=11.2.0',
    '2026-01-02T03:04:06 FAIL /sdcard/Download/XposedInstaller_v4.6.2.apk code=INSTALL_FAILED_MISSING_SPLIT msg=Missing split for host'
  ];

  /* ------------------------------------------------------------ 播放器 */

  function linesFor(cmd) {
    var s = String(cmd);
    if (s.indexOf('__apkmt_probe__') >= 0) return [['__apkmt_probe__'], 0];
    if (!current && s.indexOf('apkmt.sh') >= 0) current = BUNDLES.instagram;

    if (s.indexOf('apkmt.sh') >= 0) {
      if (/\bdiag\b/.test(s)) return [linesDiag(), 0];
      if (/\blist\b/.test(s)) {
        var m = /sh\s+'[^']*'\s+list\s+'([^']*)'/.exec(s);
        var d = m ? m[1] : '';
        var hasErr = linesList(d).join('\n').indexOf('LS|ERROR') >= 0;
        return [linesList(d), hasErr ? 1 : 0];
      }
      if (/\binspect\b/.test(s)) {
        var mp = /inspect\s+'([^']*)'/.exec(s);
        current = bundleByPath(mp ? mp[1] : '');
        return [linesInspect(current), 0];
      }
      if (/\binstall\b/.test(s)) {
        var test = /--test-write/.test(s);
        var out = linesInstall(current, test);
        var failed = out.join('\n').indexOf('RESULT|FAIL') >= 0;
        return [out, failed ? 1 : 0];
      }
      return [['apkmt.sh <diag|list|inspect|install|action> [args]'], 1];
    }
    if (s.indexOf('apkmt-ui.log') >= 0 && s.indexOf('rm -f') < 0 && s.indexOf('>>') < 0) {
      return [[
        '09:31:02 boot ksu=true exec=function spawn=function mInfo=function moddir=' + MODDIR,
        '09:31:03 probe code=0 got=true err=',
        '09:31:03 diag code=0 engine=1.3.5 sdk=' + DEV.sdk,
        '09:31:05 inspect ok type=apkm entries=12 sel=6 bytes=52024394 unzip=busybox pkg=com.instagram.android',
        '09:31:22 install done exit=0 mode=auto lang=sys result={"pkg":"com.instagram.android"} err='
      ], 0];
    }
    if (s.indexOf('history.log') >= 0 && s.indexOf('rm -f') < 0) return [HISTORY, 0];
    if (s.indexOf('settings get global verifier_verify_adb_installs') >= 0) {
      return [['0', '---', 'null', '---', 'null'], 0];
    }
    if (s.indexOf('settings put global verifier_verify_adb_installs') >= 0) return [[''], 0];
    if (s.indexOf('settings delete global verifier_verify_adb_installs') >= 0) return [[''], 0];
    if (s.indexOf('rm -f') >= 0) return [[''], 0];
    if (s.indexOf('pm list packages') >= 0) {
      var pk = /'([^']*)'/.exec(s);
      var name = pk ? pk[1] : '';
      if (name === 'com.whatsapp') return [['package:' + name + ' versionCode:251174000'], 0];
      if (name === 'com.instagram.android') return [['package:' + name + ' versionCode:370034000'], 0];
      return [[''], 0];
    }
    if (s.indexOf('monkey') >= 0) return [['Events injected: 1'], 0];
    return [[''], 0];
  }

  // 让记录分批、带延迟地逐行吐出：既真实，也顺便验证 app.js 的逐行缓冲。
  // 开头的记录刻意慢一些（创建会话 / 首个分片），中间稳定推进，末尾快速收尾。
  function play(lines, done) {
    var i = 0;
    function step() {
      if (i >= lines.length) { done(); return; }
      var n = 1 + Math.floor(Math.random() * 2);
      var at = i;
      var chunk = lines.slice(i, i + n).join('\n');
      i += n;
      cb.stdout.emit('data', chunk);
      setTimeout(step, at < 4 ? 300 + Math.random() * 200 : 80 + Math.random() * 130);
    }
    step();
  }

  var cb = null;

  function dispatch(cmdline) {
    var r = linesFor(cmdline);
    var lines = r[0], code = r[1];
    var slow = /apkmt\.sh/.test(cmdline) && /(inspect|install)/.test(cmdline);
    if (!slow) {
      cb.stdout.emit('data', lines.join('\n'));
      setTimeout(function () { cb.emit('exit', code); }, 30);
      return;
    }
    // 解析 / 安装：先停顿一下（真实设备上这一步本来就要等），再逐行吐记录
    setTimeout(function () { play(lines, function () { cb.emit('exit', code); }); }, 650);
  }

  window.ksu = {
    exec: function (cmd, options, name) {
      var fn = window[name];
      if (typeof fn !== 'function') return;
      var r = linesFor(cmd);
      var text = r[0].join('\n');
      setTimeout(function () {
        try { fn(r[1] === 0 ? 0 : 0, text, ''); }
        catch (e) { try { fn(0, '', String(e)); } catch (e2) { } }
      }, 220 + Math.random() * 380);
    },
    spawn: function (command, argsJson, optionsJson, name) {
      setTimeout(function () {
        cb = window[name];
        if (!cb || typeof cb.stdout !== 'object') return;
        dispatch(command);
      }, 120);
    },
    toast: function () { },
    fullScreen: function () { },
    enableEdgeToEdge: function () { },
    moduleInfo: function () { return JSON.stringify({ moduleDir: MODDIR, version: 'v1.3.5', versionCode: 10305 }); },
    exit: function () { }
  };
})();
