# APKM 直装器 (apkmt)

KernelSU 模块：在 WebUI 里直接安装 `.apkm` / `.apks` / `.xapk` / `.apk` 拆分包。版本 **1.3.6**，MIT 许可。

已 root 的机器上装包不再弹系统安装器：选包 → 解析 → 挑分片 → 写入，全程在模块自己的 WebUI 里完成。引擎是纯 POSIX shell，CLI 与 WebUI 共用同一套逻辑。

## 功能

| 功能 | 简介 |
| --- | --- |
| **拆分包直装** | base + 分片一次性提交，不用手动解压。 |
| **智能选片** | 按设备 ABI / 密度 / 语言自动挑，也可全选或手选。 |
| **包信息解析** | 从 `resources.arsc` 取应用名与图标，自适应图标分层渲染。 |
| **静默安装** | 走 pm 安装会话，root 直接写入，不弹系统安装器。 |
| **免重启更新** | KernelSU 官方热安装协议；不支持的版本如实提示重启。 |
| **历史与诊断** | 安装记录、设备 / 引擎自检、adb 安装校验开关。 |

## 安装

1. 下载 zip，在 KernelSU 管理器里安装为模块；
2. 重启一次（KernelSU 支持热安装时无需重启）；
3. 模块 → APKM 直装器 → 打开，即可在 WebUI 里选包。

WebUI 需要 KernelSU 管理器或 MMRL WebUI X。

## 用法

四个页签：**选包 → 安装 → 历史 → 诊断**。把包丢进 `/sdcard/Download` 就能在选包页看到。

命令行是同一套引擎（`/data/adb/modules/apkmt/bin/apkmt.sh`）：

```sh
apkmt.sh diag                 # 环境自检
apkmt.sh list /sdcard/Download
apkmt.sh inspect <bundle>     # 解析包
apkmt.sh install <bundle> --mode auto|all|manual [--splits a,b] [--lang sys|all]
```

## 更新日志

| 版本 | 主要内容 |
| --- | --- |
| **1.3.6** | WebUI 精简；准备中改为 Win11 风格的圆点转圈。 |
| 1.3.5 | 热更新只走 KernelSU 官方协议。 |
| 1.3.4 | 模块更新免重启。 |
| 1.3.3 | 解析 `resources.arsc`，补全单 APK 的应用名与自适应图标。 |
| 1.3.2 | 包内图标提取与应用名解析。 |
| 1.0.0 | 首个公开版本。 |

## 许可证

[MIT](LICENSE)
