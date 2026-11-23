# OpenList Magisk/KernelSU/APatch 模块

[![Release](https://img.shields.io/github/v/release/BLACK-BIRTHDAY/OpenList-Magisk?label=release&sort=semver)](https://github.com/BLACK-BIRTHDAY/OpenList-Magisk/releases)
[![License](https://img.shields.io/github/license/BLACK-BIRTHDAY/OpenList-Magisk?label=license)](https://github.com/BLACK-BIRTHDAY/OpenList-Magisk/blob/main/LICENSE)
[![Bundled binary](https://img.shields.io/badge/bundled%20openlist-AGPL--3.0-orange)](https://github.com/BLACK-BIRTHDAY/OpenList-Magisk/blob/main/THIRD-PARTY.md)
[![Arch](https://img.shields.io/badge/arch-arm%20%7C%20arm64-blueviolet)](#系统要求)
[![Platform](https://img.shields.io/badge/platform-Magisk%20%7C%20KernelSU%20%7C%20APatch-success)](#系统要求)

> **项目说明**：本模块（[BLACK-BIRTHDAY/OpenList-Magisk](https://github.com/BLACK-BIRTHDAY/OpenList-Magisk)）基于上游 [Alien-Et/OpenList-Magisk](https://github.com/Alien-Et/OpenList-Magisk) 维护，在完整同步上游 WebUI 控制台、`control.sh` 与 `v4.2.10` 特性的基础上，内置 `OpenListHelper` 伴侣应用，提供浏览器划词与磁力链接一键 115 离线下载能力。
>
> **许可提示**：本模块的脚本、WebUI、伴侣应用与文档使用 **MIT** 许可（见 [LICENSE](LICENSE)）；安装包内打包的 OpenList 可执行文件（`openlist-arm` / `openlist-arm64`）来自上游 [OpenListTeam/OpenList](https://github.com/OpenListTeam/OpenList)，使用 **AGPL-3.0**（见 [THIRD-PARTY.md](THIRD-PARTY.md) 与 [LICENSE-AGPL-3.0.txt](LICENSE-AGPL-3.0.txt)）。

OpenList 模块将 [OpenList](https://github.com/OpenListTeam/OpenList) 文件服务器集成到 Android 系统中，通过 Magisk、KernelSU 或 APatch 以系统化方式运行，支持 ARM 和 ARM64 架构。

## 功能亮点

- **浏览器划词与磁力链接 115 离线下载（OpenListHelper 伴侣应用）**：原生接入系统划词菜单（`PROCESS_TEXT`）、分享菜单（`SEND`）与 `magnet:` 协议关联（`VIEW`），菜单可见性与守护服务存活、模块启停及已启用的 115 存储强绑定（未添加或禁用 115 存储时自动隐藏）；支持划选纯文本/InfoHash、直接点击超链接或长按分享链接一键唤起半屏确认弹窗，提供交互式目录选择器与预设路径标签快速选择，提交后自动双阶段刷新目标目录缓存
- **配置与 Token 自动同步及存储自动重连**：服务启动自动从 `data.db` 提取 OpenList API Token 并剥离类型后缀，桥接至伴侣应用私有目录，网络就绪后自动重连 115 等云存储；在 WebUI 中保存下载配置、启停存储或切换数据目录也会即时联动同步
- **灵活安装选项**：支持三种二进制安装位置
  - `/data/adb/openlist/bin`
  - 模块目录 `bin/`
  - 模块目录 `system/bin`
- **数据目录可选**：支持两种数据存储位置
  - `/data/adb/openlist/`
  - `/storage/emulated/0/Android/openlist/`
- **账号初始化**：首次打开网页按向导设置管理员账号
- **动态服务管理**：通过 Magisk/KernelSU/APatch 的「操作」按钮一键控制服务
- **WebUI 控制台**（KernelSU / APatch）：查看状态、启停、路径体检、全版本升级/回退、在线更新二进制与镜像测速、改下载配置、改管理员账号、存储启停、离线任务、迁移数据/二进制目录、双页日志查看
- **命令行控制**：`control.sh` 三家框架通用，WebUI 也调用它
- **界面**：毛玻璃 + 大圆角，自动/浅色/深色主题
- **智能网络适配**：优先识别默认路由 IP，自动避开虚拟网卡
- **日志支持**：`service.log` 与自动 1MB 轮转的 `openlist.log` 双日志记录

## 系统要求

- Android 设备（支持 ARM 或 ARM64 架构，x86 会直接中止安装）
- Magisk v20.4 或更高版本，或 KernelSU，或 APatch
- Root 权限

## 安装步骤

1. **下载模块**
   - 从 [GitHub Releases](https://github.com/BLACK-BIRTHDAY/OpenList-Magisk/releases) 下载最新版本

2. **安装配置**
   - 打开 Magisk 管理器、KernelSU 管理器 或 APatch 管理器
   - 选择「从本地安装」
   - 进入安装配置界面：
     - 选择二进制文件安装位置
     - 选择数据目录存储位置
     - 更新安装时如果检测到旧数据，会多问一句要不要一起迁过来

3. **完成安装**
   - 等待安装完成
   - 重启设备

## 使用说明

### 服务管理

- 系统启动后自动运行（先等 `sys.boot_completed` 最多 120 秒，数据目录在 `/sdcard` 或 `/storage` 时再等可写最多 180 秒）
- 通过 Magisk/KernelSU/APatch「操作」按钮（`action.sh`）控制服务
- 服务状态显示在 `module.prop`：
  - 运行中：显示访问地址和 PID
  - 已停止：显示启动提示

### WebUI 控制台（KernelSU / APatch）

在 KernelSU 或 APatch 管理器里打开模块，点击 WebUI 入口即可：

- 状态：运行中/已停止、访问地址、PID、数据目录、架构（停止时自动隐藏伴侣菜单）
- 启停/重启服务、打开网页
- 路径体检：扫描二进制与数据目录占用，清理多余副本、切换数据目录（同步桥接 `offline.conf` 并刷新伴侣菜单）
- 版本与更新：拉取 OpenList 官方 Release，按 CPU 架构选择 `android-arm64 / android-arm / android-amd64 / android-386`，后台下载、进度实时显示，替换失败自动用 `.bak` 回滚；下载可选 15 个国内镜像自动测速
- 下载配置：修改 `offline.conf` 的端口、Token、目标路径、离线引擎、删除策略、预设路径（保存后即时桥接至伴侣应用）
- 管理员账号：改用户名、改密码（走 OpenList 管理 API，在线生效，不重启）
- 存储：列表、启用/禁用、全部重载（变更存储后自动异步刷新 115 伴侣菜单可见性）
- 离线任务：查看进行中的任务、取消
- 迁移数据目录 / 二进制路径（校验通过才删源）
- 查看和清空 `service.log` / `openlist.log`

> Magisk 没有 `webroot` WebUI 机制，看不到这个入口，请用「操作」按钮或下面的命令行。

### 命令行控制（Magisk / KernelSU / APatch 通用）

```sh
sh /data/adb/modules/openlist/control.sh status
sh /data/adb/modules/openlist/control.sh start|stop|restart
sh /data/adb/modules/openlist/control.sh check
sh /data/adb/modules/openlist/control.sh update --force          # 更新二进制
sh /data/adb/modules/openlist/control.sh update --tag v4.2.10   # 切换/回退到指定版本（不查 API）
sh /data/adb/modules/openlist/control.sh logs 200
sh /data/adb/modules/openlist/control.sh config-get
sh /data/adb/modules/openlist/control.sh mirror-rank            # 看镜像实测排序
```

`update` 先试直连，再按实测延迟顺序试国内镜像；镜像偏好（自动 / 直连 / 指定）在 WebUI 里选，存到 `<数据目录>/mirror.conf`。
WebUI 里点更新走的是 `update-bg`（后台跑）+ `update-status`（轮询），宿主超时不会把下载掐断。

### 访问方式

- Web 界面访问：`http://<设备IP>:5244`
- 首次打开会进入安装向导，按提示设置管理员账号和密码
- 完成向导前，WebUI 里存储、离线任务、设置会提示「还没有管理员账号」

### 浏览器 115 离线下载（OpenListHelper 伴侣应用）

模块内置轻量级伴侣应用 `OpenListHelper`（包名：`io.openlist.helper`），无需后台常驻进程与剪贴板监听，支持以下三种便捷触发方式快速唤起半屏离线弹窗：

#### 浏览器三种触发方式

1. **纯文本磁力/Hash**：长按划选文字（磁力链接 `magnet:?xt=...` 或 40 位 Hex / 32 位 Base32 InfoHash）→ 点击系统划词菜单 **「115 离线」**。
2. **超链接形式的磁力链接（`<a href="magnet:...">`）**：直接**点击磁力超链接**即可唤起半屏确认弹窗。
3. **长按磁力超链接分享**：长按磁力超链接 → 点击 **「共享链接」**（或「分享链接」）→ 选择 **「OpenList 115 离线」** 唤起半屏确认弹窗。

#### 交互流程与离线投递

1. **唤起半屏弹窗**：通过上述任意一种方式触发后，系统底部弹出离线确认半屏弹窗（预览磁力与文件特征）。
2. **确认目标路径**：
   - **交互式文件夹选择器**：点击「📁 选择目录」唤起目录浏览器，通过 OpenList 原生接口（`POST /api/fs/list`）拉取并展示文件夹列表，支持逐级钻取子目录、返回上级目录与退回根目录；点击「🔄 刷新」或「🔄 重试」时携带 `"refresh": true` 强制穿透 OpenList 内存缓存更新最新目录。
   - **预设路径快速选择**：点击输入框下方的横向预设标签（如 `/115/影视/`、`/115/` 或历史记录）瞬间填入，同时支持自由手动编辑。
3. **一键投递执行**：点击「立即离线」，伴侣应用调用本地 OpenList（`http://127.0.0.1:5244/api/fs/add_offline_download`），通过 `115 Open` 驱动投递至云端离线下载；任务添加成功后，伴侣应用自动执行即时与 1.5 秒延迟双阶段目标目录缓存刷新（`POST /api/fs/list` 携带 `"refresh": true`），确保云端秒传与离线完成文件在 OpenList Web UI 与 WebDAV 列表中无需手动刷新即可立即可见；新路径自动记忆至最近预设列表供下次快速使用。

#### 离线配置文件（`offline.conf`）与自动同步

配置文件位于 OpenList 数据目录：`$DATA_DIR/offline.conf`（默认 `/data/adb/openlist/offline.conf`）。

每次 OpenList 守护服务启动时，`service.sh` 会自动完成：
- 从 OpenList 数据库（`$DATA_DIR/data.db`）自动读取当前有效 API Token（并自动清洗连续记录中的类型后缀）写入 `TOKEN=` 字段。
- 动态获取当前运行端口并更新 `PORT=` 字段。
- 自动将完整配置安全桥接至 `/data/local/tmp/openlist_offline.conf` 与伴侣应用私有目录 `/data/data/io.openlist.helper/files/offline.conf`，实现**完全免手动配置 Token**。
- 开机网络与 DNS 就绪后，后台自动调用 OpenList API（`POST /api/admin/storage/load_all`）重载所有存储驱动，避免开机初始无网络导致的 `115 Open` 等云存储初始化失败。

此外，在 WebUI「下载配置」保存修改或通过「路径体检」切换数据目录时，也会即时桥接最新 `offline.conf` 至伴侣应用。

配置字段定义：

```ini
# OpenList 115 离线下载伴侣配置
HOST=127.0.0.1                          # OpenList 监听主机
PORT=5244                               # OpenList 运行端口（服务启动时动态探测并更新）
TOKEN=openlist-xxxx...                  # OpenList API Token（服务启动时自动从数据库提取）
PATH=/115/影视/                          # 默认目标虚拟路径
TOOL=115 Open                           # 离线下载驱动名称（固定为 115 Open）
DELETE_POLICY=delete_on_upload_succeed  # 下载成功后的清理策略
PRESET_PATHS=/115/影视/,/115/            # 半屏弹窗预设路径快速选择列表（逗号分隔）
```

升级模块与服务重启会自动保留用户对 `PATH`、`DELETE_POLICY` 和 `PRESET_PATHS` 的自定义修改。

#### 系统菜单可见性智能联动

为防止在未配置 115 网盘或服务未运行时误触无效菜单，伴侣应用的系统划词菜单、分享菜单与磁力协议拦截入口采用严格的状态强绑定机制：
- **未添加 / 未启用 115 存储时自动隐藏**：OpenList 启动及运行期间自动探测存储配置（三级阶梯：HTTP API → SQLite 数据库 → 二进制扫描），若用户未在 OpenList 中添加 115 网盘（`115 Cloud` / `115 Open`）或所有已添加的 115 存储均处于禁用状态，系统菜单将保持隐藏；一旦在 OpenList 后台或 WebUI「存储」页添加并启用 115 存储，菜单会即时动态暴露。
- **服务停止或模块禁用时自动隐藏**：通过「操作」按钮、WebUI、`control.sh stop` 停止服务，模块在管理器中被禁用/标记卸载，或开机启动异常时，立即调用 `pm disable` 隐藏菜单入口，彻底避免残留无效选项。

### 数据存储

- 默认数据目录：`/data/adb/openlist/`
- 模块日志位置：`/data/adb/modules/openlist/service.log` 与 `/data/adb/modules/openlist/openlist.log`
- **卸载默认保留数据**：只清理二进制与伴侣应用。要连数据一起删，卸载前执行
  `touch /data/adb/modules/openlist/.delete_data_on_uninstall`，或卸载后手动 `rm -rf`

## 故障排除

### 常见问题

1. **无法访问服务**
   - 检查网络连接
   - 检查服务状态：`pgrep -f openlist`
   - 查看日志文件：`/data/adb/modules/openlist/service.log` 与 `openlist.log`
   - 手动重启服务：`su -c /data/adb/modules/openlist/service.sh`

2. **IP 地址获取失败**
   - 确认 WiFi 或移动网络已连接
   - 检查网络接口状态
   - 查看模块日志

3. **服务无法启动**
   - 检查二进制文件权限
   - 确认数据目录可写
   - 查看详细日志

4. **系统菜单未显示「115 离线」或离线投递失败**
   - 确认 OpenList 守护服务运行中，且模块未被禁用
   - 确认已在 OpenList 后台添加并**启用**至少一个 115 存储（`115 Cloud` / `115 Open`）；未添加或全部禁用时菜单会自动隐藏
   - 执行 `su -c 'pm list packages | grep io.openlist.helper'` 确认伴侣应用已安装；若缺失或 Token 未同步，重启服务即可重新安装并桥接 `offline.conf`
   - 若提示鉴权失败或目录读取失败，可在 WebUI「下载配置」确认 `PORT` 与 `TOKEN`，并查看 `/data/adb/modules/openlist/service.log`

### 手动操作

- 查看状态：`su -c sh /data/adb/modules/openlist/control.sh status`
- 停止服务：`su -c sh /data/adb/modules/openlist/control.sh stop`
- 启动服务：`su -c sh /data/adb/modules/openlist/control.sh start`
- 查看日志：`cat /data/adb/modules/openlist/service.log` / `cat /data/adb/modules/openlist/openlist.log`

## 更新说明

- 支持通过 Magisk/KernelSU/APatch 更新检查
- 更新不会清除现有数据，并保留 `offline.conf` 自定义配置
- 可在安装时重新选择配置选项
- 版本列表只走 GitHub 官方 API；遇到 403 限流时可在模块目录放一个 `.github_token`（一行 PAT）把额度从 60 次/小时提到 5000

## 更新日志

### v4.2.10 (2026-11-23)

- 同步上游 `Alien-Et/OpenList-Magisk` `v4.2.10`：WebUI 控制台、`control.sh`、后台更新与镜像测速、安装/WebUI 校验式迁移、开机外部存储等待、`openlist.log` 自动轮转及完整 MIT + AGPL-3.0 许可文件
- 深化 `OpenListHelper` 115 伴侣应用与 WebUI / `control.sh` 联动（停服隐菜单、保存下载配置即时桥接、存储变更异步刷新菜单、切换数据目录同步配置，兼容 `v4.2.9` 旧版配置升级）
- 退役 ADR 0002 运行时 SQLite 二进制补丁与日志调优（OpenList `v4.2.10` PR #3344 已原生支持 SQLite WAL + `busy_timeout(10000)` 与 `SQLITE_BUSY` 重试）

## 数据迁移说明

1. 安装时可选择数据目录与二进制位置；更新安装时若检测到旧数据且换了目录，安装界面会多问一次「音量+ 迁移 / 音量- 跳过」（默认跳过，迁移失败不删源）
2. 装好后也能在 WebUI 迁移页随时改：选目标目录 → 「开始迁移」
3. 迁移 = 移动：复制、校验文件数与 `data.db` 的 md5 全部通过后，才同步 `config.json` 路径并删除源目录
4. 二进制迁移同理，校验一致后删除旧文件，不会同时留两份
5. 迁移完成后 WebUI 自动刷新状态、路径体检与日志

## 致谢与上游项目

- 上游 Magisk 模块与 WebUI 控制台：[Alien-Et/OpenList-Magisk](https://github.com/Alien-Et/OpenList-Magisk)
- OpenList 文件服务器核心：[OpenListTeam/OpenList](https://github.com/OpenListTeam/OpenList)

## 贡献

- 欢迎提交 Issue 和 Pull Request
- 问题反馈：[GitHub Issues](https://github.com/BLACK-BIRTHDAY/OpenList-Magisk/issues)

## 许可证

模块自身的脚本、WebUI、伴侣应用与文档基于 [MIT 许可证](../LICENSE) 发布（衍生自上游 [Alien-Et/OpenList-Magisk](https://github.com/Alien-Et/OpenList-Magisk)）。

模块内打包的 `openlist` 二进制来自 [OpenList 官方 Release](https://github.com/OpenListTeam/OpenList/releases)，遵循上游 **AGPL-3.0** 许可证，对应源码见 [OpenListTeam/OpenList](https://github.com/OpenListTeam/OpenList)。

安装包内随附 [LICENSE](LICENSE)（MIT 副本）、[LICENSE-AGPL-3.0.txt](LICENSE-AGPL-3.0.txt)（AGPL-3.0 全文）与 [THIRD-PARTY.md](THIRD-PARTY.md)（第三方组件说明）。

## 文档

- [01. 整体架构](../docs/01.整体架构.md)
- [02. control 命令](../docs/02.control命令.md)
- [03. WebUI 界面](../docs/03.WebUI界面.md)
- [04. 更新与回滚](../docs/04.更新与回滚.md)
- [05. 迁移与路径](../docs/05.迁移与路径.md)
- [06. 安装选项矩阵](../docs/06.安装选项矩阵.md)
- [07. 总结](../docs/07.总结.md)
- [ADR 0001：内置 PROCESS_TEXT 伴侣 APK 实现浏览器 115 离线下载](../docs/adr/0001-companion-apk-process-text-offline-download.md)
- [ADR 0002：SQLite 并发锁自愈与日志轮转调优（已取代）](../docs/adr/0002-sqlite-wal-and-busy-timeout-patch.md)
