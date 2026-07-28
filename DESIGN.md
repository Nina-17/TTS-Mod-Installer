# TTS 本地图包安装器设计

当前实现版本：`v0.5.4`。旧版发布包继续保留。

## 1. 目标

做一个面向 Windows 普通用户的便携脚本，完成：

1. 自动识别 Tabletop Simulator（TTS）当前使用的 Mods 目录。
2. 接受拖入命令行窗口的文件夹或压缩包。
3. 自动识别图包内真正的 `Mods` 根目录。
4. 将内容合并覆盖到目标 Mods 目录，不删除已有的其他 Mod。
5. 在路径不明确、包结构异常或文件复制失败时停止并给出可理解的提示。

非目标：

- 不修改 TTS 的“Mod Save Location”游戏设置。
- 不删除目标中图包未包含的文件。
- 不在后台自动关闭 TTS。
- 第一版不做 GUI。

## 2. 推荐实现

使用 Windows PowerShell 5.1 编写，无需用户预装 Python、Node.js 或 .NET SDK。

交付一个面向用户的入口和一个脚本主体：

- `点我启动.cmd`：用户双击的启动器，负责打开并保留命令行窗口。
- `TTSModInstaller.ps1`：路径探测、解压、校验和复制的主体。

支持两种使用方式：

```text
方式一：
双击“点我启动.cmd”
→ 把图包文件夹或压缩包拖进窗口
→ 按 Enter

方式二：
把图包文件夹或压缩包直接拖到“点我启动.cmd”图标上
```

可一次拖入多个图包；整个批次只判断一次目标目录和游戏运行状态，需要管理员权限时只请求一次 UAC。安装完成后仍可继续拖入下一批。

控制台表现采用统一的柔和主题：浅粉为主色，低饱和丁香紫和雾蓝为层级辅助色，成功、警告、失败分别使用薄荷绿、沙金和珊瑚红，并配合状态 Emoji。支持虚拟终端的 Win11 控制台使用 24 位 RGB；其他宿主自动回退到兼容的 16 色。颜文字只用于启动、等待、完成和失败等关键节点；日志不写入控制台颜色控制码，继续保持可检索的时间、级别和消息格式。

## 3. 整体流程

```text
取得输入
  ↓
验证输入类型
  ↓
探测 TTS 安装目录和当前 Mods 位置
  ↓
如 TTS 正在运行则提示用户退出
  ↓
文件夹：直接分析
压缩包：预检路径、大小、文件数、压缩比和临时空间
  ↓
解压至独立临时目录后分析
  ↓
定位图包中的 Mods 根目录
  ↓
显示来源、目标、文件数量和预计大小
  ↓
合并覆盖复制
  ↓
检查复制结果并写日志
  ↓
清理临时目录
```

## 4. TTS 路径探测

### 4.1 文档模式

不能直接拼接 `%USERPROFILE%\Documents`，因为“文档”可能已迁移到 OneDrive 或其他磁盘。

通过 Windows Known Folder API（PowerShell 中的 `Environment.GetFolderPath`）取得当前用户真实的文档目录：

```text
<Documents>\My Games\Tabletop Simulator\Mods
```

### 4.2 Game Data 模式

TTS 的 Steam App ID 是 `286160`。按以下优先级寻找安装目录：

1. 如果 TTS 正在运行，读取 `Tabletop Simulator.exe` 的进程路径。
2. 查询 Steam 应用的卸载注册信息中的 `InstallLocation`。
3. 从 Steam 注册表位置找到 `libraryfolders.vdf`，逐个 Steam 库检查 `appmanifest_286160.acf`。
4. 检查 Steam 的常见默认路径，只作为最后兜底。

每个候选都必须同时验证：

```text
Tabletop Simulator.exe
Tabletop Simulator_Data
```

Game Data 模式的目标目录为：

```text
<TTS安装目录>\Tabletop Simulator_Data\Mods
```

### 4.3 判断游戏当前选中了哪一种模式

优先读取当前用户注册表：

```text
HKCU\Software\Berserk Games\Tabletop Simulator
```

动态寻找 `ConfigGame_h*` 值，不写死哈希后缀。该值包含游戏配置 JSON：

```json
{
  "ConfigMods": {
    "Location": 0
  }
}
```

- `Location = 0`：Documents。
- `Location = 1`：Game Data。

这是 TTS/Unity 的内部存储格式，不属于稳定的官方接口，因此必须有退路：

1. 收集所有可解析的 `ConfigGame_h*`；结果一致时使用该结果。
2. 多个配置对位置给出冲突结果：列出配置来源并要求用户选择。
3. 注册表不可解析，且仅一个候选 Mods 目录存在：使用该候选。
4. 两个目录都存在或都不存在：显示两个完整路径，让用户选择；默认推荐 Documents，但不静默猜测。
5. 用户选择只影响本次安装，不擅自修改游戏配置。

启动时始终显示最终判定，例如：

```text
TTS 安装目录：D:\SteamLibrary\steamapps\common\Tabletop Simulator
当前 Mods 模式：Game Data（读取自 TTS 配置）
安装目标：D:\SteamLibrary\steamapps\common\Tabletop Simulator\Tabletop Simulator_Data\Mods
```

## 5. 输入和图包结构识别

### 5.1 输入处理

- 支持带空格、中文和括号的完整路径。
- 自动移除拖入命令行后路径两侧的引号。
- 拒绝不存在的路径、快捷方式、网络 URL 和不支持的文件类型。
- 文件夹可直接处理。
- `.zip` 使用 `Expand-Archive`；`.ttsmod` 使用系统自带的 `System.IO.Compression.ZipFile`，避免 `Expand-Archive` 的扩展名限制。
- `.7z`、`.rar` 优先使用发布包内置的官方 7-Zip 26.02 命令行组件；用户无需安装 7-Zip。
- 内置组件按 Windows 原生架构选择 x86、x64 或 ARM64；每套包含未经修改的 `7z.exe` 和 `7z.dll`。
- 执行前校验内置组件 SHA-256；组件缺失时可回退到系统已安装的 7-Zip，哈希不匹配时停止。
- ZIP/TTSMOD/7Z/RAR 在解压前检查条目路径、文件数、声明的解压大小、异常压缩比和临时磁盘空间。
- 7-Zip 返回退出码 `1` 时视为非致命警告：继续检查解压内容，安装成功后以黄色警告状态结束；退出码 `> 1` 仍视为解压失败。
- 安全上限为 250000 个文件、250 GB 声明解压大小；大于 1 GB 且压缩比超过 1000:1 时拒绝处理。
- 每个压缩包解压到 `安装器目录\运行数据\Temp\Extract\<GUID>`，在 `finally` 中清理。

### 5.2 Mods 根目录识别

按以下优先级判断：

1. 输入文件夹本身名为 `Mods`：使用本身。
2. 输入根目录下存在 `Mods`：使用该目录。
3. 只有一个外层包装目录，且其下存在 `Mods`：使用该 `Mods`。
4. 输入根目录直接包含典型 Mods 内容（如 `Images`、`Models`、`Workshop`、`Assetbundles`、`Audio`）：把输入根目录视为 Mods 内容。
5. 找到多个可能的 `Mods`，或完全没有结构特征：停止并列出候选，要求用户重新选择。

搜索深度限制为 2 层，避免在大型图包中递归扫描出内部无关的同名目录。

复制时永远是：

```text
<源Mods根目录的内容> → <目标Mods目录>
```

而不是复制源 `Mods` 目录本身，因此不会产生：

```text
...\Mods\Mods\Images
```

## 6. 覆盖语义

“覆盖”定义为合并覆盖：

- 源中存在、目标中不存在：新增。
- 源和目标同名但内容不同：用源覆盖目标。
- 目标中存在、源中不存在：保留。
- 不使用 `/MIR`，不删除任何目标文件。

实际复制建议使用系统自带 `robocopy`：

```text
robocopy <源> <目标> /E /COPY:DAT /DCOPY:DAT /R:2 /W:1 /XJ /IS /IT /NP /UNILOG:<日志>
```

注意 `robocopy` 的退出码 `0` 到 `7` 都不表示致命失败，只有 `>= 8` 才作为失败处理。
不使用 `/TEE`，避免逐文件状态刷满控制台；主进程通过异步 PowerShell 管道等待 `robocopy`，等待期间在同一行绘制往返进度轨道并轮换颜文字。动画只表达“仍在工作”，不伪造整批百分比；完整 Unicode 输出写入便携日志。

`/IS /IT` 确保即使同名文件的时间戳、大小或属性相同，也以图包中的文件为准；`/XJ` 用于避免跟随目录联接。复制前还应拒绝源 Mods 根本身为 reparse point 的异常输入。

## 7. 安全和异常处理

### 7.1 游戏正在运行

复制前检查 `Tabletop Simulator.exe`：

- 默认要求用户先退出游戏，再重新检测。
- 可提供“仍然继续”的高级选项，但明确提示运行中的游戏可能同时写入缓存。
- 不自动结束进程。

### 7.2 写入权限

Documents 模式通常不需要管理员权限；Steam 位于 `Program Files` 时，Game Data 模式可能需要。

脚本先确认安装器目录可以创建便携运行数据，再在目标目录做一次可删除的零字节写入测试。只有目标拒绝访问时，才用 `RunAs` 重新启动主体脚本，并通过安装器专属交接文件带入整个批次和目标路径，避免用户再次拖入或多次确认 UAC。

交接文件必须位于 `安装器目录\运行数据\Temp\Handoff` 且符合随机 GUID 文件名；管理员子进程会把每个图包的退出码、目标和日志路径写回父进程。

### 7.3 复制前检查

安装前显示：

- 识别出的源 Mods 根。
- 目标 Mods 路径及判定依据。
- 文件总数和总大小。
- 图包中会覆盖的同名文件数量。
- 本次写入量和目标磁盘预计净增长（两者不同）。
- 磁盘可用空间是否足够。

若没有任何文件，直接停止。

第一版不默认创建图包整包备份，因为大型图包可能非常大；可增加 `-BackupConflicts` 参数，只备份即将被覆盖的文件到：

```text
安装器目录\运行数据\Backups\Mods-<时间戳>
```

### 7.4 日志和退出码

日志目录：

```text
安装器目录\运行数据\Logs
```

日志至少包含：

- 脚本版本和 Windows/PowerShell 版本。
- 输入、规范化后的源根、目标。
- 路径判定依据。
- 解压工具。
- `robocopy` 摘要和最终退出码。
- 临时目录清理结果。

每扫描 1000 个文件输出一次进度。30 天前的日志和更新备份，以及 1 天前的异常解压、UAC、更新遗留文件会被尽力清理。

建议退出码：

| 退出码 | 含义 |
|---:|---|
| 0 | 安装成功 |
| 1 | 用户取消 |
| 2 | 输入无效或包结构无法识别 |
| 3 | 无法定位 TTS 或 Mods 目标 |
| 4 | 解压失败 |
| 5 | 权限/UAC 失败 |
| 8 | 文件复制失败 |
| 42 | 更新助手已启动；CMD 启动器应直接退出且不暂停 |

### 7.5 自动更新

- 每次普通用户启动都请求 GitHub `releases/latest`；不做按天缓存。
- GitHub API 直连失败时，以 `https://gh-proxy.com/` 加原始 GitHub URL 的形式自动重试。
- API 经备用通道成功后，本次更新的 ZIP 和 SHA-256 文件直接沿用备用通道；资产直连单独失败时也会自动切换。
- 内部 UAC 子进程、更新后的提权进程和 `-NonInteractive` 模式跳过检查，避免重复提示。
- 只接受版本号高于当前版本的正式 Release。
- 更新资产必须严格命名为 `TTSModInstaller-vX.Y.Z.zip`。
- 使用 GitHub 资产 digest 和同名 `.sha256` 文件校验下载结果；两者同时存在时必须一致。
- 主脚本只负责下载、校验和解压到临时目录。
- 临时 `TTSModUpdater.ps1` 等待主脚本退出后，备份旧版核心文件、合并覆盖新版并重新启动。
- 更新失败时尝试从 `安装器目录\运行数据\Backups` 恢复，不影响目标 Mods 内容。
- 日志、临时解压、UAC 交接、更新下载和备份均不得写入 `%LOCALAPPDATA%` 或 Windows `%TEMP%`。
- 网络或 API 错误只显示警告，继续运行当前版本。

## 8. 建议的脚本内部结构

```text
Get-InputPath
Get-DocumentsModsPath
Get-SteamInstallPath
Get-TTSInstallPath
Get-TTSModLocationSetting
Resolve-TTSModsDestination
Expand-ModPackage
Resolve-SourceModsRoot
Get-CopySummary
Test-DestinationWriteAccess
Invoke-ElevatedInstaller
Invoke-ModCopy
Get-LatestInstallerRelease
Start-InstallerUpdate
TTSModUpdater.ps1
Write-InstallerLog
```

路径探测、包结构识别和复制应拆开，便于分别测试。

## 9. 验收测试

至少覆盖以下情况：

| 场景 | 预期 |
|---|---|
| 默认 Documents 模式 | 写入真实 Known Folder 下的 Mods |
| Documents 被 OneDrive 重定向 | 不写入错误的 `%USERPROFILE%\Documents` |
| Steam 在 C 盘默认库 | 找到正确 TTS 目录 |
| Steam 在 D/E 盘附加库 | 通过 `libraryfolders.vdf` 和 manifest 找到 |
| Game Data 模式 | 写入 `Tabletop Simulator_Data\Mods` |
| 两处都残留旧 Mods | 以注册表设置为准；读取失败则询问 |
| 拖入名为 Mods 的文件夹 | 复制其内容，不产生双层 Mods |
| 拖入“包装目录\Mods” | 自动剥离包装层 |
| 拖入 ZIP | 解压、识别、安装、清理临时目录 |
| 拖入 TTSMOD | 按 ZIP 解压、识别、安装、清理临时目录 |
| ZIP 声明大小超过临时盘空间 | 解压前停止 |
| ZIP 路径穿越或异常压缩比 | 解压前拒绝 |
| RAR/7z 且无 7-Zip | 明确提示，不产生半成品 |
| 一次拖入多个图包 | 顺序安装并输出批次成功数量 |
| 多图包写入 Game Data | 整批只请求一次 UAC |
| 多个 ConfigGame 配置互相冲突 | 不任意选择，列出结果并询问 |
| 目标已有其他 Mod | 保留不相关文件 |
| 同名文件冲突 | 源文件覆盖目标 |
| TTS 正在运行 | 默认要求退出，不自动杀进程 |
| Program Files 无写权限 | 仅此时请求 UAC |
| `robocopy` 返回 1–7 | 正确视为成功 |
| `robocopy` 返回 8+ | 报错并保留日志 |
| GitHub 无法访问 | 显示警告，继续使用当前版本 |
| Release 版本更高 | 提供立即更新和本次跳过 |
| 更新包哈希不一致 | 拒绝覆盖当前版本 |
| 更新复制失败 | 恢复旧版并重新打开 |

## 10. 实现顺序

第一阶段（可用版本）：

- Documents/Game Data 自动探测。
- 文件夹和 ZIP。
- Mods 根识别。
- 合并覆盖、运行中提示、日志。

第二阶段：

- 7-Zip/RAR。
- 冲突备份参数。
- 多图包队列和纯命令行静默模式。
- Windows 沙盒或 CI 中的 Pester 自动测试。

## 参考

- TTS 官方技术信息：<https://kb.tabletopsimulator.com/getting-started/technical-info/>
- TTS 官方导入 Mods 说明：<https://kb.tabletopsimulator.com/custom-content/importing-mods/>
- TTS 官方配置菜单说明：<https://kb.tabletopsimulator.com/getting-started/configuration-menu/>
