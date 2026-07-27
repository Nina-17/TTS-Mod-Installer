# TTS 本地图包安装器 v0.4.0

Windows 上通过拖放，将 Tabletop Simulator 本地图包自动合并覆盖到游戏当前使用的 Mods 目录。

## 使用方法

下载发布包后请先选择“全部解压”，不要直接在 ZIP 预览窗口中运行启动器。

### 方法一：在窗口中拖入

1. 双击 `Install-TTS-Mods.cmd`。
2. 把一个或多个图包文件夹/压缩包拖进命令行窗口。
3. 按 Enter。

也可以输入 `F` 打开文件选择窗口。完成后可以继续安装下一批图包。

### 方法二：直接拖到启动器

把一个或多个图包文件夹/压缩包直接拖到 `Install-TTS-Mods.cmd` 图标上。

批量安装时只探测一次目标位置；如果 Game Data 目录需要管理员权限，只请求一次 UAC。

## 支持范围

- Windows 10/11。
- Windows PowerShell 5.1，无需安装 Python 或 Node.js。
- 文件夹、ZIP 和 TTSMOD（`.ttsmod`）原生支持；`.ttsmod` 按 ZIP 处理。
- 7Z/RAR：发布包内置官方便携 7-Zip 26.02 组件，用户无需安装 7-Zip。
- 自动识别 Documents 和 Game Data 两种 TTS Mods 保存位置。
- 支持 Steam 默认库和其他磁盘上的附加 Steam 库。
- 解压前检查路径安全、文件数量、声明大小、异常压缩比和临时磁盘空间。

安装器会根据 Windows 原生架构自动选择内置的 x86、x64 或 ARM64 组件，并在运行前校验 `7z.exe` 和 `7z.dll` 的 SHA-256。若完整发布包中的内置组件不存在，仍会尝试使用电脑中已安装的 7-Zip 作为后备。

控制台界面使用分阶段彩色提示、状态 Emoji 和少量颜文字区分扫描、解压、复制、成功、警告与失败；纯文本日志仍保留时间、级别和完整消息，方便排查问题。

常见图包结构均可识别：

```text
Mods\Images
Mods\Models
Mods\Workshop
```

```text
图包名称\Mods\Images
```

```text
Images
Models
Workshop
```

## 覆盖规则

安装器执行“合并覆盖”：

- 图包中的新文件会添加。
- 同名文件会由图包版本覆盖；即使时间戳和大小相同，也以图包版本为准。
- 目标中其他已有 Mod 文件会保留。
- 不使用镜像同步，不删除目标中的文件。

如果 TTS 正在运行，安装器默认要求先退出游戏；它不会自动结束游戏进程。

## 自动路径识别

Documents 模式使用 Windows 当前用户真实的“文档”Known Folder，兼容 OneDrive 重定向：

```text
<文档>\My Games\Tabletop Simulator\Mods
```

Game Data 模式：

```text
<TTS安装目录>\Tabletop Simulator_Data\Mods
```

安装器会读取所有可解析的 `ConfigGame_h*` 配置：

- 多个配置结果一致：自动使用该位置。
- 配置结果互相冲突：列出配置和两个完整路径，让用户选择。
- 配置无法读取：根据目录存在情况判断；仍有歧义时让用户选择。

安装器不会在存在冲突时采用注册表枚举到的第一个结果。

## 命令行

也可以直接运行 PowerShell 主体：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\TTSModInstaller.ps1 "D:\Downloads\图包.zip"
```

可选参数：

```text
-LocationMode Auto|Documents|GameData
-DestinationPath <明确的目标 Mods 路径>
-ForceWhileRunning
-NonInteractive
```

`-DestinationPath` 主要用于测试或高级用法。使用它时，安装器不会再判断游戏当前的 Mods 设置。

## 日志

日志保存在：

```text
%LOCALAPPDATA%\TTSModInstaller\Logs
```

其中 `install-*.log` 是安装器流程日志，`robocopy-*.log` 是详细复制日志。

安装器会尽力清理：

- 30 天前的安装日志。
- 1 天前因异常退出遗留的解压目录和 UAC 交接文件。

当前安装正在使用的文件不会被清理。

7-Zip 返回非致命警告时，安装器会继续检查并安装能够正常读取的 Mods 内容，最终以黄色显示“安装完成，但压缩包处理有警告”。程序退出码仍为 `0`；如果游戏中出现素材缺失，建议重新获取或手动解压该图包。

如果复制已经开始后发生错误，部分文件可能已经写入目标。安装器会明确提示；修复磁盘空间、权限等问题后，可以重新安装同一个图包完成覆盖。

## 退出码

| 退出码 | 含义 |
|---:|---|
| 0 | 安装成功 |
| 1 | 用户取消或 TTS 仍在运行 |
| 2 | 输入无效或图包结构无法识别 |
| 3 | 无法定位 TTS/Mods 目标 |
| 4 | 解压失败 |
| 5 | 权限或 UAC 失败 |
| 8 | 文件复制失败 |
| 10 | 不是 Windows |
| 99 | 未分类异常 |

更完整的设计和验收矩阵见 [DESIGN.md](DESIGN.md)。

## 开发测试

在 Windows PowerShell 5.1 中运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1
```

测试覆盖 TTS 配置解析与冲突处理、Steam 库解析、`robocopy` 退出码、多路径拖放、压缩包预检、ZIP/TTSMOD 安全检查与解压、7Z/RAR 技术列表解析与警告语义、Mods 包装目录识别和模拟批量端到端安装。

## 版本

- `v0.4.0`：新增 `.ttsmod` 支持，按普通 ZIP 图包完成预检、解压和 Mods 合并安装；不额外处理 `Saves`。
- `v0.3.0`：内置官方便携 7-Zip 26.02，7Z/RAR 不再要求用户预装软件；支持 x86、x64 和 ARM64，并校验组件哈希。
- `v0.2.0`：增加配置冲突处理、压缩包预检、多图包批次、文件选择窗口、扫描进度、UAC 结果回传和旧文件清理。
- `v0.1.0`：最初的稳定脚本版，发布包继续保留在 `dist` 目录。

## 第三方组件

发布包包含未经修改的 7-Zip 26.02 命令行组件。7-Zip 使用 GNU LGPL 等许可，详细声明见 `THIRD-PARTY-NOTICES.txt` 和发布包内的 `tools\7zip\License.txt`。源代码可从 [7-Zip 官网](https://www.7-zip.org/download.html) 获取。
