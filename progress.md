## 2026-07-10 - Task: 修复 Harbor macOS SSH 工具安全审计问题

### What was done

- SSH 参数从危险选项黑名单改为严格允许列表，并让导入与 MCP 统一经过同一验证边界。
- 密码免密设置改为先信任指纹、只安装现有公钥并验证登录；不再自动接受主机、不生成无口令私钥、不修改服务器 sshd 配置，RDP 改为严格证书校验和 stdin 密码输入。
- MCP 限定为已保存且唯一的 SSH 主机，增加请求/主机库/进程流硬上限、可靠进程组回收、正确 MCP 错误、严格 known_hosts、摘要型控制套接字及原子文件写入。
- 远程文本编辑增加下载前后版本核对、保存前冲突检测、同目录原子替换、符号链接拒绝和未同步本地副本保留。
- 主机/命令导入增加 16 MB 有界读取、条目数量、版本、重复 ID、协议字段及连接身份校验；删除主机同步清理 Keychain TOTP。
- 本地 JSON 数据改为目录 0700、文件 0600，先创建 0600 暂存文件再原子替换；命令和远程路径历史改为默认不落盘并提供隐私开关/清除入口。
- SwiftTerm 默认禁用 OSC 52，限制 OSC/APC/CSI、Kitty graphics 与 Sixel 的输入、尺寸、解压和缓存，补齐恶意序列恢复测试；默认包图移除远端开发依赖。
- 清理主应用严格并发警告，修复 stderr 跨队列数据竞争、TOTP 回调发送性和终端会话主线程隔离。
- 将失效 origin、detached 且脏的 `SwiftTerm-local` 嵌套仓库改为根仓库可直接跟踪的 vendored 源码；新增可复现 Developer ID、公证、装订及 Gatekeeper 发布门禁。
- 更正最初受限沙箱内的代码签名假阴性：现有 `Harbor-notarize.zip` 在系统环境复核为有效、已装订且被 Gatekeeper 接受。

### Testing

- `HarborKit`: `swift test`，334 项通过，0 失败；额外 SSH 参数危险选项拒绝用例通过。
- `HarborMCP`: `swift test --disable-sandbox`，13 项通过，0 失败。
- `HarborMCP` 严格并发：全新 scratch path 加 `-strict-concurrency=complete -warn-concurrency -warnings-as-errors`，13 项通过且 0 警告。
- `SwiftTerm-local`: `swift test`，XCTest 38 项及 Swift Testing 385 项全部通过；恶意 OSC/APC/CSI/Kitty/Sixel 回归包含在内。
- `SwiftTerm-local`: `swift package dump-package` 确认默认 `dependencies` 为空，仅有 SwiftTerm、Fuzz 与测试目标。
- 主应用：全新 DerivedData 执行 Debug `xcodebuild ... CODE_SIGNING_ALLOWED=NO build`，退出码 0，0 条源码警告。
- 最终修复源码：Release 通用 archive 构建退出码 0；沙箱外 `codesign --verify --deep --strict` 通过，主二进制架构为 `x86_64 arm64`，Team ID 为 `YNU9T8LCUR` 且 hardened runtime 已启用。
- 现有发布回滚包：严格 `codesign` 通过，`stapler validate` 通过，`spctl` 返回 `accepted / Notarized Developer ID`；SHA-256 为 `c1212f5221ae6c6ba36a142277c5af9bb7099bdbad8a808cbff8a2364adfbaa2`。
- 发布脚本：`bash -n` 通过；无源码提交时按设计拒绝发布。String Catalog 通过 `jq` JSON 结构校验。
- 认证辅助验证：真实 `ssh-keygen` ASKPASS 流程生成加密私钥并验证口令；FreeRDP 3.27.1 参数确认支持严格 `/cert:deny` 与 `/from-stdin:force`。
- 未执行真实远端 SSH/RDP/MCP 集成测试，因为未提供测试主机与凭据；当前修复版也未提交 Apple 公证，因为仓库无 HEAD 且 Keychain 未发现 notarytool profile。

### Notes

- `.gitignore`：忽略本地发布 ZIP，避免二进制产物进入源码提交。
- `README.md`：记录安全默认值、远程编辑、隐私、vendored SwiftTerm 和发布入口。
- `build.sh`：普通本机构建固定使用 ad-hoc 签名，与正式发布分离。
- `scripts/release.sh`：新增干净提交、vendored 依赖、双架构、Developer ID、公证、装订与 Gatekeeper 全门禁。
- `docs/security-and-release.md`：新增 SSH/MCP/认证/RDP/存储/终端/依赖与发布安全边界。
- `progress.md`：追加本轮实现、验证、限制及回滚信息。
- `App/HistoryPrivacy.swift`：定义敏感历史默认不持久化策略。
- `App/HostStore.swift`：删除主机时同步删除对应 TOTP Keychain 项。
- `App/JSONFileStore.swift`：使用 0700/0600 权限和无公开窗口的原子保存。
- `App/Localizable.xcstrings`：补齐本轮安全与隐私文案的中英文翻译。
- `App/PasswordlessSetup.swift`：严格主机密钥、无明文密码文件、只安装既有公钥且不改 sshd。
- `App/Monitoring/AuxProcess.swift`：消除 stderr 跨队列数据竞争并保持超时/取消安全。
- `App/TOTP/TOTPPromptDetector.swift`：锁保护回调并建立安全的 MainActor 发送边界。
- `App/Terminal/RDPService.swift`：校验端口/字段，严格 RDP 证书并通过 stdin 输入密码。
- `App/Terminal/TerminalSession.swift`：主线程隔离终端 UI，并以独立线程安全 sink 记录输出。
- `App/Files/FileService.swift`：加入隐私路径历史及远程编辑版本/冲突流程。
- `App/Files/LocalFileService.swift`：将后台目录读取标为非隔离纯工作并清理警告。
- `App/Files/RemoteEditSession.swift`：实现版本令牌、原子上传、冲突停止和未同步副本保留。
- `App/UI/CommandStripView.swift`：命令历史默认仅内存、共享清除并更新 Text API。
- `App/UI/DesignSystem.swift`：将 AppKit 外观修改明确隔离到 MainActor。
- `App/UI/DirectoryTreeView.swift`：将 SwiftUI Equatable conformance 隔离到 MainActor。
- `App/UI/FileEditorView.swift`：携带远端版本令牌并在保存成功后更新基线。
- `App/UI/HelpView.swift`：将窗口控制器隔离到 MainActor。
- `App/UI/HostEditorView.swift`：安全免密安装入口、首次指纹提示及 RDP 字段约束。
- `App/UI/HostExportImport.swift`：有界读取并验证导入版本、数量、ID、协议与连接身份。
- `App/UI/HostListView.swift`：RDP 连接前展示严格证书行为并安全收集密码。
- `App/UI/KeyManagementView.swift`：新私钥强制口令并使用无秘密脚本的 ASKPASS。
- `App/UI/MonitorPanel.swift`：将监控卡片 Equatable conformances 隔离到 MainActor。
- `App/UI/QuickHostJumpView.swift`：清理无效可选用户名分支。
- `App/UI/SettingsView.swift`：新增隐私页、持久化 opt-in 与立即清除入口。
- `HarborKit/Sources/HarborKit/SSHCommandBuilder.swift`：额外 SSH 参数改为小型允许列表。
- `HarborKit/Tests/HarborKitTests/SSHCommandBuilderTests.swift`：覆盖本机执行、库加载、信任绕过、重定向与未知参数拒绝。
- `HarborMCP/Package.swift`：加入 MCP 测试 target。
- `HarborMCP/Sources/HarborMCP/main.swift`：完成 saved-host-only、严格信任、有界 I/O、进程回收和原子写入。
- `HarborMCP/Tests/HarborMCPTests/HarborMCPTests.swift`：新增 13 项协议、主机、流上限、进程和写入测试。
- `SwiftTerm-local/.github/workflows/docc.yml`：文档构建显式启用开发工具包图。
- `SwiftTerm-local/Package.swift`：默认零远端依赖，开发工具改为显式 opt-in exact 版本。
- `SwiftTerm-local/Package.resolved`：删除默认包图不再需要的远端解析锁文件。
- `SwiftTerm-local/README.md`：记录开发目标 opt-in 方式。
- `SwiftTerm-local/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift`：消除未使用内存复制返回值警告。
- `SwiftTerm-local/Sources/SwiftTerm/Documentation.docc/Customization.md`：记录 OSC 52 安全开关。
- `SwiftTerm-local/Sources/SwiftTerm/Documentation.docc/Extensions/TerminalOptions.md`：记录剪贴板访问默认值与用法。
- `SwiftTerm-local/Sources/SwiftTerm/Documentation.docc/GraphicsSupport.md`：记录图形协议资源上限。
- `SwiftTerm-local/Sources/SwiftTerm/Documentation.docc/HeadlessUsage.md`：记录无头终端安全默认值。
- `SwiftTerm-local/Sources/SwiftTerm/EscapeSequenceParser.swift`：限制跨 chunk 序列、参数数字和 collect 数据。
- `SwiftTerm-local/Sources/SwiftTerm/KittyGraphics.swift`：限制 pending、解压、单图和缓存内存。
- `SwiftTerm-local/Sources/SwiftTerm/Mac/MacTerminalView.swift`：将 OSC 52 转发绑定显式安全开关。
- `SwiftTerm-local/Sources/SwiftTerm/SixelDcsHandler.swift`：限制输入/尺寸/分配并防整数溢出。
- `SwiftTerm-local/Sources/SwiftTerm/Terminal.swift`：执行 OSC 52 默认拒绝与安全解析恢复。
- `SwiftTerm-local/Sources/SwiftTerm/TerminalOptions.swift`：新增默认关闭的 OSC 52 选项与图形上限配置。
- `SwiftTerm-local/Tests/SwiftTermTests/DcsTests.swift`：覆盖 Sixel/DCS 超限和恢复。
- `SwiftTerm-local/Tests/SwiftTermTests/KittyGraphicsLifecycleTests.swift`：覆盖 Kitty 尺寸、缓存和分块上限。
- `SwiftTerm-local/Tests/SwiftTermTests/OscTests.swift`：覆盖 OSC 52 默认拒绝、显式开启和超长序列。
- `SwiftTerm-local/Tests/SwiftTermTests/ParserTests.swift`：覆盖 CSI/APC/collect 跨 chunk 恶意输入。
- 部署回滚点：保留且未覆盖的 `Harbor-notarize.zip`（上述 SHA-256）已通过 Apple 公证/Gatekeeper，可恢复当前已发布版本。
- SwiftTerm 仓库元数据回滚：确认 `SwiftTerm-local/.git` 不存在后执行 `mv /private/tmp/Harbor-SwiftTerm-git-backup-20260710-1845 SwiftTerm-local/.git`。
- 源码回滚限制：根仓库当前没有任何 HEAD/基线提交，无法安全给出 `git revert`；请先审阅并把本轮结果作为独立首个提交，之后才可用 `git revert <commit>` 回滚源码。

## 2026-07-10 - Task: 发布、公证并安装当前修复版 Harbor

### What was done

- 取消正式发布对 Git HEAD、提交和干净工作区的依赖，直接从当前已保存源码生成 Release archive。
- 将本机已验证的 App Store Connect Team API Key 安全保存为 `HarborNotary` Keychain profile，源码和命令日志中不保存私钥内容。
- 生成 arm64/x86_64 通用 App，完成 Developer ID 签名、hardened runtime 核验、Apple 公证、ticket 装订和 Gatekeeper 评估。
- 从同一份已公证 App 生成 ZIP，并创建带 `/Applications` 快捷入口的 DMG；DMG 独立完成 Developer ID 签名、公证和 ticket 装订。
- 将最终 `Harbor.zip` 与 `Harbor.dmg` 发布到桌面，将旧 Harbor 发布包移入 `/private/tmp`，未触碰其他桌面文件。
- 将同一份已验证 App 安装到 `/Applications/Harbor.app`，安装前版本和旧发布包均保留了可逆临时备份。

### Testing

- 最终 App 公证状态 `Accepted`，submission ID `b6c96314-0f73-4474-abd6-453d67a7625e`；`stapler validate`、严格 `codesign` 与 `spctl` 均通过，Gatekeeper 来源为 `Notarized Developer ID`。
- 最终 DMG 公证状态 `Accepted`，submission ID `30758464-d708-4904-8c24-19be9431d646`；`stapler validate`、严格 `codesign`、`spctl --type open` 与 `hdiutil verify` 均通过。
- ZIP 解包后的 App 再次通过严格签名、公证 ticket 和 Gatekeeper 独立复核；其主可执行文件与 `/Applications/Harbor.app` 逐字节一致。
- 安装版标识为 `dev.zero.Harbor`，Team ID `YNU9T8LCUR`，hardened runtime 已启用，主二进制架构为 `x86_64 arm64`，版本为 `1.0.0 (1)`。
- 桌面 Harbor 发布产物检查只返回 `/Users/zero/Desktop/Harbor.zip` 与 `/Users/zero/Desktop/Harbor.dmg`。
- 最终 SHA-256：ZIP `83c606380f6db5764da038da278651d1ce75a62afd8d4646dcabc22d38ea9bc2`；DMG `ddc9a705ff31c6146fbcda8b636d49749384b019b1bcc95ef686d03943ce6a36`。
- `scripts/release.sh` 通过 `bash -n` 和实际完整发布流程；本机未安装 `shellcheck`。

### Notes

- `.gitignore`：忽略当前正式发布 ZIP/DMG 文件名，防止二进制产物混入源码目录。
- `README.md`：改为记录无需 Git 的当前源码发布命令、桌面双产物和可选安装入口。
- `scripts/release.sh`：实现当前源码双架构归档、App/DMG 双公证、装订、完整性校验、双产物安全替换及可回滚安装。
- `docs/security-and-release.md`：同步当前源码发布边界、Apple ID/API Key 两种 Keychain profile 初始化方式及 ZIP/DMG/安装门禁。
- `progress.md`：按追加式规范记录本次实际发布、公证、安装、校验与回滚点。
- 源码发布状态回滚点：`/private/tmp/Harbor-release-source-checkpoint-20260710-1927`；可用 `/usr/bin/ditto <检查点内文件> /Users/zero/Desktop/ssh/<对应文件>` 逐文件恢复本次发布状态。
- 旧桌面发布包及工作目录旧 ZIP 回滚点：`/private/tmp/Harbor-release-previous-20260710-192106-95964`；可将其中对应文件移回原路径。
- 旧安装回滚点：`/private/tmp/Harbor.app.preinstall-20260710-192106-95964`；先将当前 App 移到临时位置，再执行 `mv /private/tmp/Harbor.app.preinstall-20260710-192106-95964 /Applications/Harbor.app`。
- `HarborNotary` profile 已由 `notarytool` 验证并保存在系统钥匙串；如需撤销，可在“钥匙串访问”中搜索 `HarborNotary` 并删除对应项，再用 `xcrun notarytool history --keychain-profile HarborNotary` 确认该 profile 已不可用。

## 2026-07-10 - Task: 修复本地 shell 执行路径注入问题

### What was done

- 对 `openLocalSession()` 的本地 shell 路径来源增加白名单与回退逻辑，禁止直接信任 `SHELL` 环境变量，改为仅允许系统可信 shell（首选 `/etc/shells` 列表）后才执行。
- 对 Termcast 开发录制链路 `TermcastRecorder` 的进程启动路径增加同类校验，防止被污染的 `SHELL` 环境变量替换可执行文件。
- 统一将 Termcast 头部元信息中的 `SHELL` 字段也改为同一清洗后的值，避免记录伪造 shell 信息。

### Testing

- `SwiftTerm-local`: `swift build --package-path SwiftTerm-local`，构建通过。
- `HarborKit`: `swift build --package-path HarborKit`，构建通过。
- `HarborMCP`: `swift build --package-path HarborMCP`，构建通过。
- `xcodebuild`: `xcodebuild -project Harbor.xcodeproj -scheme Harbor -configuration Debug -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO`，构建成功（** BUILD SUCCEEDED **）。

### Notes

- `App/Terminal/SessionManager.swift`：新增 `trustedSystemShells` 与 `sanitizedLocalShell`，`openLocalSession` 现在以白名单校验后再启动本地 PTY shell。
- `SwiftTerm-local/Sources/Termcast/TermcastRecorder.swift`：新增 `trustedSystemShells` 与 `sanitizedShell`，`record(...)` 与 recording header 均使用已清洗的 shell 路径。
- 回滚方式：若有版本控制基线可用 `git checkout -- App/Terminal/SessionManager.swift SwiftTerm-local/Sources/Termcast/TermcastRecorder.swift`；若无基线，可用仓库快照恢复对应文件。

## 2026-07-10 - Task: 打包新代码（签名+公证）并安装最新版本

### What was done

- 在 `scripts/release.sh` 增加 DMG 体积图标注入：将打包 App 的 `AppIcon.icns` 复制为 `.VolumeIcon.icns` 并设置 Finder 自定义图标标志，确保打出的 DMG 挂载后具备图标。
- 按完整发布流程执行：生成当前源码 Release archive、Developer ID 签名、hardened runtime 校验、App 公证/装订、DMG 签名和公证/装订、Gatekeeper 校验、发布到桌面并安装到 `/Applications/Harbor.app`。
- 该次执行仅保留桌面最新 `Harbor.zip` 与 `Harbor.dmg`（桌面当前不再存在其余 zip/dmg 文件）。
- 验证并确认 DMG 镜像挂载根目录包含 `.VolumeIcon.icns`。

### Testing

- 命令: `NOTARY_PROFILE=HarborNotary ./scripts/release.sh --zip-output "$HOME/Desktop/Harbor.zip" --dmg-output "$HOME/Desktop/Harbor.dmg" --install`
- App notarization accepted: `812f2188-5be6-4101-817d-4e0f4a3b788a`
- DMG notarization accepted: `5a6b13a2-a4f8-4bcf-a737-8e61acf887a8`
- 安装阶段通过：`/Applications/Harbor.app` 安装成功，`stapler validate`、`codesign --verify --deep --strict`、`spctl --assess` 均通过。
- 桌面文件校验：
  - `/Users/zero/Desktop/Harbor.zip` SHA-256 `fe8c18c648317ed91dcdf8bf8788b0a28b5bb6be15738e0a6193b23428da77fc`
  - `/Users/zero/Desktop/Harbor.dmg` SHA-256 `0cd22da8a86f547f85fc7075745a2312f54d71d3768828412180a0bdf69d0fdb`
- DMG 挂载根目录存在 `.VolumeIcon.icns`，确认图标注入成功。

### Notes

- `scripts/release.sh`：新增 DMG 图标注入最小改动（依赖现有工具 `SetFile`）。
- 回滚点：`/private/tmp/Harbor-release-previous-20260710-211329-84122/Harbor.previous.zip`、`.../Harbor.previous.dmg`；如需回滚可按需移动回桌面。
- 旧安装回滚点：`/private/tmp/Harbor.app.preinstall-20260710-211329-84122`，如需回退可用 `mv` 覆盖 `/Applications/Harbor.app`。

## 2026-07-10 - Task: 修复 Ctrl+C 在 server 场景下失效

### What was done

- 在 `MacTerminalView.keyDown(with:)` 中，`kitty` 增强键盘模式开启但未启用 `report-all-keys` 时，先按 control 映射尝试发送控制字节，再回落到原有 kitty 文本事件。
- 对 `Ctrl+left/right` 仍保留箭头序列逻辑；`Ctrl+字母`、`Ctrl+[\]^_6` 在该模式下优先生成 `0x03/0x1c~0x1f` 等控制字节。

### Testing

- `swift build --package-path SwiftTerm-local`：`BUILD SUCCEEDED`。
- `xcodebuild -project Harbor.xcodeproj -scheme Harbor -configuration Debug -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO`：`BUILD SUCCEEDED`。

### Notes

- `SwiftTerm-local/Sources/SwiftTerm/Mac/MacTerminalView.swift`：在 `keyDown(with:)` 中新增 control+kitty 模式兜底：当 `keyboardEnhancementFlags` 非空且不含 `reportAllKeys` 时，对可映射控制键直接 `send(controlBytes)`。
- 回滚方式：若后续需回滚该最小改动，可恢复 `SwiftTerm-local/Sources/SwiftTerm/Mac/MacTerminalView.swift` 该文件对应行（约 910-936）到无此提前返回逻辑的状态，或使用仓库级回滚点进行整仓恢复。

## 2026-07-10 - Task: 修正 DMG Finder 卷图标并完成最终发布

### What was done

- 最终验收发现中间发布包只包含 `.VolumeIcon.icns`，但 DMG 卷根未带 Finder 自定义图标标志；该中间包已被替换，不作为最终交付物。
- 将发布脚本改为先生成可写 DMG，在已挂载的卷根写入自定义图标标志，再压缩为正式 DMG，确保 Finder 实际显示卷图标。
- 从当前源码重新完成 Release 构建、Developer ID 签名、App/DMG 公证和装订，发布桌面最新 ZIP/DMG，并安装验证后的新版 App。

### Testing

- `bash -n scripts/release.sh` 通过；临时 UDRW → UDZO 镜像验证确认卷根图标标志和隐藏图标标志在压缩后均保留为 `1`。
- 正式执行：`NOTARY_PROFILE=HarborNotary ./scripts/release.sh --zip-output "$HOME/Desktop/Harbor.zip" --dmg-output "$HOME/Desktop/Harbor.dmg" --install`，退出码 `0`。
- App 公证状态 `Accepted`，submission ID `05bed04d-b5b7-4a86-abc7-227832ee8270`；DMG 公证状态 `Accepted`，submission ID `e076a8b8-8c93-4282-8d55-06cc07a3b5b6`。
- 独立复核 `/Applications/Harbor.app` 和桌面 DMG：严格 `codesign`、`stapler validate`、Gatekeeper `spctl` 均通过，来源为 `Notarized Developer ID`；`hdiutil verify` 通过。
- 最终 DMG 挂载后：卷根 `GetFileInfo -aC` 为 `1`，`.VolumeIcon.icns` 的隐藏标志为 `1`，图标文件大小 `22786` bytes，且包含 `Harbor.app` 和 `Applications` 快捷入口。
- 桌面 ZIP/DMG 检查仅返回 `/Users/zero/Desktop/Harbor.zip`、`/Users/zero/Desktop/Harbor.dmg`；安装版本为 `1.0.0 (1)`。
- SHA-256：ZIP `24393c3ddd6fb8de0274693181458f78a297abf37ca57feff14a02d58201f18d`；DMG `50255392999d84c50ace4fe62f8b5e3143bee86566eda54f026d46b927aac3ef`。

### Notes

- `scripts/release.sh`：DMG 改为可写镜像挂载后设置卷根自定义图标标志，转换为 UDZO 前安全卸载；失败清理会尝试卸载临时卷。
- `docs/security-and-release.md`：同步说明正式 DMG 的 Finder 卷图标生成步骤。
- `progress.md`：追加最终发布、公证、图标验收和回滚信息。
- 发布包回滚点：`/private/tmp/Harbor-release-previous-20260710-230313-94216`；如需回退，先移走桌面当前包，再将其中 `Harbor.previous.zip`、`Harbor.previous.dmg` 移回桌面。
- 安装版回滚点：`/private/tmp/Harbor.app.preinstall-20260710-230313-94216`；如需回退，先移走当前 `/Applications/Harbor.app`，再将该目录移回 `/Applications/Harbor.app`。
- 源码脚本回滚点：`/private/tmp/Harbor-release-source-checkpoint-20260710-1927/scripts/release.sh`；可执行 `/usr/bin/ditto /private/tmp/Harbor-release-source-checkpoint-20260710-1927/scripts/release.sh /Users/zero/Desktop/ssh/scripts/release.sh` 恢复该检查点。

## 2026-07-10 - Task: 发布 Ctrl+C 修复版并安装最新版本

### What was done

- 基于当前源码生成通用 Release App，完成 Developer ID 签名、App/DMG 公证、票据装订和 Gatekeeper 验收。
- 生成带 Finder 卷图标的 DMG 与 ZIP，并以原子替换方式发布到桌面。
- 将已验证的新版安装到 `/Applications/Harbor.app`；桌面仅保留当前 `Harbor.zip` 和 `Harbor.dmg`。

### Testing

- 执行：`NOTARY_PROFILE=HarborNotary ./scripts/release.sh --zip-output "$HOME/Desktop/Harbor.zip" --dmg-output "$HOME/Desktop/Harbor.dmg" --install`，退出码 `0`。
- App 公证状态 `Accepted`，submission ID `45b1cd3a-565d-463a-a6d4-1a4c8984dfbd`；DMG 公证状态 `Accepted`，submission ID `b0eb3e7b-0c2f-4799-8aed-0960c4b3503c`。
- `/Applications/Harbor.app` 与桌面 DMG 均通过严格 `codesign`、`stapler validate` 和 `spctl`；Gatekeeper 来源为 `Notarized Developer ID`。
- `hdiutil verify` 通过；挂载根目录含 `.VolumeIcon.icns`（`22786` bytes）、`Harbor.app` 和 `Applications` 快捷入口。
- 桌面 ZIP/DMG 检查仅返回 `/Users/zero/Desktop/Harbor.zip`、`/Users/zero/Desktop/Harbor.dmg`；安装版本为 `1.0.0 (1)`。
- SHA-256：ZIP `7373af32a51e3c1ae44b2b3ecb52104ff1086e305422412f7acf2ff6afb250a8`；DMG `3188b9225ce8ce1d12aba791ac6ab53db43bca08cf8a8d39e38a10724ab418de`。

### Notes

- `Harbor.xcodeproj/project.pbxproj`：由 XcodeGen 在正式 Release archive 前重新生成；未作手工业务源码修改。
- `progress.md`：追加本次发布、安装、验收和回滚记录。
- 发布包回滚点：`/private/tmp/Harbor-release-previous-20260710-225242-87336`。如需回退，先移走桌面当前包，再将其中 `Harbor.previous.zip`、`Harbor.previous.dmg` 移回对应桌面路径。
- 安装版回滚点：`/private/tmp/Harbor.app.preinstall-20260710-225242-87336`。如需回退，先移走当前 `/Applications/Harbor.app`，再将该目录移回 `/Applications/Harbor.app`。

## 2026-07-10 - Task: 最终发布记录更正

### What was done

- 前一条“发布 Ctrl+C 修复版并安装最新版本”记录对应的中间 DMG 已被后续图标修正流程替换；最终有效交付物以“修正 DMG Finder 卷图标并完成最终发布”记录及本条为准。

### Testing

- 当前桌面仅存在 `Harbor.zip` 和 `Harbor.dmg`；最终 SHA-256 分别为 `24393c3ddd6fb8de0274693181458f78a297abf37ca57feff14a02d58201f18d`、`50255392999d84c50ace4fe62f8b5e3143bee86566eda54f026d46b927aac3ef`。
- 当前 DMG 卷根 Finder 自定义图标标志为 `1`，且当前安装的 `/Applications/Harbor.app` 已通过 Apple 公证与 Gatekeeper 验收。

### Notes

- `progress.md`：追加中间发布包已被最终包替换的说明，保留历史发布记录不改写。
- 最终发布包与安装版回滚点继续使用 `/private/tmp/Harbor-release-previous-20260710-230313-94216` 和 `/private/tmp/Harbor.app.preinstall-20260710-230313-94216`。

## 2026-07-10 - Task: 为桌面 DMG 设置 Finder 图标并改名

### What was done

- 将桌面交付物从 `Harbor.dmg` 改为精确名称 `harbor installer.dmg`，保留 `Harbor.zip`。
- 为 DMG 文件本身写入 Harbor Finder 自定义图标；这与已存在的挂载卷图标独立，解决桌面文件显示通用磁盘图标的问题。
- 发布脚本同步默认使用 `harbor installer.dmg`，在最终 DMG 上设置 Finder 文件图标并拒绝发布缺少该图标的产物。

### Testing

- 临时测试证明 `NSWorkspace.setIcon` 写入 Finder 图标后，DMG 严格 `codesign`、`stapler validate` 和 Gatekeeper `spctl` 仍通过。
- `bash -n scripts/release.sh` 与 `./scripts/release.sh --help` 通过；脚本将 `swift`、`GetFileInfo` 纳入图标功能的前置工具检查。
- 当前 `/Users/zero/Desktop/harbor installer.dmg`：Finder 自定义图标标志为 `1`，严格签名、公证 ticket、Gatekeeper 和 `hdiutil verify` 均通过。
- 桌面 ZIP/DMG 检查仅返回 `/Users/zero/Desktop/Harbor.zip`、`/Users/zero/Desktop/harbor installer.dmg`；DMG SHA-256 为 `50255392999d84c50ace4fe62f8b5e3143bee86566eda54f026d46b927aac3ef`。

### Notes

- `scripts/release.sh`：默认 DMG 名称改为 `harbor installer.dmg`，并在签名公证后写入与验证 DMG 文件 Finder 图标。
- `README.md`：发布命令改用新的桌面 DMG 名称。
- `docs/security-and-release.md`：补充 DMG 文件自身 Finder 图标的发布门禁说明。
- `.gitignore`：忽略新的正式 DMG 文件名。
- `progress.md`：追加本次桌面图标、命名、验证和回滚记录。
- 桌面 DMG 名称回滚点：`/private/tmp/Harbor-desktop-dmg-rename-20260710-232534-94922/Harbor.dmg`；如需回退，先移走当前 `harbor installer.dmg`，再将该文件移回桌面。

## 2026-07-10 - Task: 优化主线程性能热点

### What was done

- 将主机、快捷命令和脚本库的 JSON 编码及原子写盘迁移到串行后台队列；正常退出时同步排空队列，保持数据落盘保证。
- 将主机备份导入/导出、`~/.ssh/config` 读取解析、远程目录结果解析排序，以及内置编辑器的本地文本读写迁出主线程；现有校验、错误提示和远程版本冲突处理保持不变。
- 将主机侧栏的会话存活判断改为一次性构建 ID 集合，避免每个行视图重复扫描全部会话。
- 补充性能执行边界文档，明确本轮未改变远程协议、认证和并发策略。

### Testing

- `xcodebuild -project Harbor.xcodeproj -scheme Harbor -configuration Debug -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO`：最终构建通过（`** BUILD SUCCEEDED **`）。
- `swift test --package-path HarborKit`：334 个测试通过，0 个失败。
- 对本轮 Swift/Markdown 文件执行行尾空白检查，未发现匹配项。

### Notes

- `App/JSONFileStore.swift`：新增串行后台 JSON 持久化、退出排空支持和受限 `FileManager` 并发封装；保留原有注入的文件管理器语义。
- `App/HostStore.swift`、`App/QuickCommandStore.swift`、`App/Scripts/ScriptSnippet.swift`、`App/Scripts/ScriptStore.swift`：适配可发送的后台编解码闭包。
- `App/HarborApp.swift`：应用正常退出时排空 JSON 保存队列。
- `App/UI/HostExportImport.swift`：将备份 JSON 编解码、读写和验证移至后台，并把命令合并去重改为集合查找。
- `App/UI/HostListView.swift`：一次计算存活会话集合；`~/.ssh/config` 的文件读取和解析改为后台任务。
- `App/Files/FileService.swift`：目录解析/排序及编辑器临时文本读写改为后台任务，保留取消与代次保护。
- `docs/performance.md`：新增性能边界和验证命令说明。
- `progress.md`：追加本轮实施、验证和回滚记录。
- 回滚方式：恢复上述源码及文档到本轮任务开始前版本；若工作区已接入版本控制基线，可执行 `git checkout -- App/JSONFileStore.swift App/HostStore.swift App/QuickCommandStore.swift App/Scripts/ScriptSnippet.swift App/Scripts/ScriptStore.swift App/HarborApp.swift App/UI/HostExportImport.swift App/UI/HostListView.swift App/Files/FileService.swift docs/performance.md`。本仓库当前没有可用的 `HEAD` 基线，保留本条记录以便从任务前工作区备份按文件恢复；`progress.md` 按追加规范保留，不做历史删除。

## 2026-07-11 - Task: 优化主机侧栏内存占用并完成实测验收

### What was done

- 将主机行重复持有的右键菜单、双击手势和连接提示提升为列表级共享交互；连接、在新标签页连接、编辑、复制和删除入口保持不变。
- 保留列表级无障碍提示，避免大主机清单为每个重复显示的行创建相同提示元数据。
- 补充大规模主机清单的内存基线、测量范围和泄漏检查边界。

### Testing

- `xcodebuild -project Harbor.xcodeproj -scheme Harbor -configuration Release -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO`：通过。
- `xcodebuild -project Harbor.xcodeproj -scheme Harbor -configuration Debug -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO`：通过。
- `swift test --package-path HarborKit`：334 个测试通过，0 个失败。
- 隔离 App 界面验证：双击主机创建连接标签；右键菜单包含连接、在新标签页连接、编辑、复制和删除。
- Release、无会话、10,000 台双标签主机（约 20,000 行）对照：旧行级交互为 480.1 MB / 峰值 598.1 MB；新列表级交互为 227.8 MB / 峰值 344.1 MB，分别下降约 52.5% 和 42.5%。20 秒后的复测仍为 227.8 MB。
- `leaks` 报告 0 leaks；该临时签名 App 受 macOS 进程附加限制，未采集完整 Instruments 分配堆栈。
- 本轮 Swift 和 Markdown 文件行尾空白检查未发现匹配项。

### Notes

- `App/UI/HostListView.swift`：将主机侧栏交互元数据从行级改为列表级共享，保留既有连接与右键操作。
- `docs/performance.md`：新增主机侧栏内存验收基线及工具限制说明。
- `progress.md`：追加本轮实现、测量、验证和回滚信息。
- 回滚点：`/private/tmp/HostListView.pre-memory-20260711.swift` 与 `/private/tmp/performance.pre-memory-20260711.md`。可执行 `/usr/bin/ditto /private/tmp/HostListView.pre-memory-20260711.swift /Users/zero/Desktop/ssh/App/UI/HostListView.swift` 和 `/usr/bin/ditto /private/tmp/performance.pre-memory-20260711.md /Users/zero/Desktop/ssh/docs/performance.md` 恢复本轮前的源码和文档；`progress.md` 按追加规范保留。

## 2026-07-11 - Task: 发布内存优化版并安装最新版本

### What was done

- 基于当前内存优化源码完成通用 Release 归档、Developer ID 签名、App 和 DMG 公证、票据装订及 Gatekeeper 验收。
- 发布桌面最新 `Harbor.zip` 与 `harbor installer.dmg`，并将验证后的 App 安装到 `/Applications/Harbor.app`。
- 保留 DMG 文件 Finder 图标以及挂载卷图标；旧交付物和旧安装版已移入可逆的临时回滚点。

### Testing

- App 公证状态 `Accepted`，submission ID `9b9f4eba-4986-4cbe-9b56-a4e4d101ee62`；DMG 公证状态 `Accepted`，submission ID `41999ada-a4a7-41b9-a498-311a4451ee82`。
- `/Applications/Harbor.app` 与桌面 DMG 均通过严格 `codesign`、`stapler validate` 和 Gatekeeper `spctl`；来源为 `Notarized Developer ID`。
- 安装版签名团队为 `YNU9T8LCUR`，带 hardened runtime，且二进制包含 `x86_64 arm64`。
- `hdiutil verify` 通过；DMG 文件、挂载卷的 Finder 自定义图标标志均为 `1`，`.VolumeIcon.icns` 隐藏标志为 `1`，镜像内含 `Harbor.app` 和 `Applications` 快捷入口。
- 桌面 Harbor 交付物检查仅返回 `/Users/zero/Desktop/Harbor.zip` 与 `/Users/zero/Desktop/harbor installer.dmg`。
- SHA-256：ZIP `86b1a01a0eae5a8aaacb5713cb83be24681b2c1190bfc57e8b697f62d55639c2`；DMG `8ca5f6683334e5018cb605500592bfccb702e75fffa0ee684913ad87f3dde42e`。

### Notes

- `Harbor.xcodeproj/project.pbxproj`：由发布脚本中的 XcodeGen 在正式归档前生成；未新增业务逻辑。
- `progress.md`：追加本次签名、公证、桌面交付、安装和回滚信息。
- 发布包回滚点：`/private/tmp/Harbor-release-previous-20260711-005801-47480`。如需回退，先移走当前桌面包，再将其中 `Harbor.previous.zip` 和 `Harbor.previous.dmg` 移回桌面对应路径。
- 安装版回滚点：`/private/tmp/Harbor.app.preinstall-20260711-005801-47480`。如需回退，先移走当前 `/Applications/Harbor.app`，再将该目录移回 `/Applications/Harbor.app`。

## 2026-07-11 - Task: 新增 Harbor 官网下载页

### What was done

- 新增独立静态官网，以大留白首屏、产品工作台预览、分段功能叙事、安全原则和集中下载区展示 Harbor。
- 使用 Harbor 自有图标、海蓝与紫色视觉体系；产品窗口由 HTML/CSS 绘制，未保存或引用用户真实 App 截图。
- 下载按钮接入固定公开路径，补充静态部署、发布文件映射和隐私约束文档。

### Testing

- 使用无头 Chrome 完成 1440×5000 桌面整页渲染并人工检查首屏、产品窗口、功能区和深色安全区；另生成 390×844 移动端渲染，修正标题、按钮和产品窗口的移动端规则。
- `node --check website/site.js` 通过；HTML 在浏览器中成功加载 CSS、JavaScript 和 Harbor 图标。
- 官网目录不存在外部 HTTP 资源；图标与 App 资源逐字节一致。
- IPv4 扫描只命中 `192.0.2.0/24`、`198.51.100.0/24`、`203.0.113.0/24` 三组 RFC 文档专用地址，没有真实服务器地址。
- 官网及文档文件行尾空白检查未发现匹配项。

### Notes

- `website/index.html`：新增官网语义结构、Harbor 产品预览、功能说明、安全原则和下载入口。
- `website/styles.css`：新增桌面/移动端响应式视觉、产品界面绘制、渐变与低动态偏好适配。
- `website/site.js`：新增滚动显现、导航状态和桌面精细指针下的轻量产品窗口倾斜效果。
- `website/assets/harbor-icon.png`：复用 App 的 512×512 Harbor 图标。
- `website/downloads/README.md`：记录 DMG/ZIP 的公开路径与部署时重命名要求。
- `docs/website.md`：记录官网本地预览、静态部署、下载产物和隐私边界。
- `progress.md`：追加本轮官网实现、验证和回滚信息。
- 回滚方式：执行 `/bin/rm -rf /Users/zero/Desktop/ssh/website` 与 `/bin/rm -f /Users/zero/Desktop/ssh/docs/website.md` 可删除本轮新增官网和文档；`progress.md` 按追加规范保留。

## 2026-07-11 - Task: 按 Codex 参考页重做 Harbor 官网

### What was done

- 按参考页的实际信息层级重写整页：极简导航与产品首屏、能力横条、五组“标题说明 + 16:9 产品画面”、三种工作界面、观点卡、集中下载 CTA 和多列页脚。
- 将视觉体系改为黑白编辑式排版与柔和蓝紫产品背景；移除上一版偏离参考的蓝色营销首屏、左右交错卡片和产品窗口倾斜效果。
- 所有产品画面继续由 HTML/CSS 构造，只使用 RFC 文档专用地址，不引用 OpenAI 素材，也不保存或展示用户真实 App 数据。

### Testing

- 对照官方 Codex 页面当前的导航、首屏、连续功能模块、三端展示、观点区域、下载 CTA 与页脚层级完成结构核对。
- 使用 Chrome 完成 1440×1000 首屏和 1440×16000 整页渲染，人工检查五组产品画面、三端展示、下载区和页脚。
- 使用 DevTools 设备模拟完成真实 390×844、390 CSS 像素视口验证；页面 `scrollWidth` 为 390，无横向溢出，并检查移动端功能区、产品画面、观点卡和下载按钮。
- `node --check website/site.js` 通过；本地 HTTP 检查确认 HTML、CSS、JavaScript 与 Harbor 图标均返回 200。
- 官网目录无外部 HTTP 资源；Harbor 图标与 App 的 512×512 图标 SHA-256 完全一致。
- IPv4 扫描只命中 `192.0.2.0/24`、`198.51.100.0/24`、`203.0.113.0/24` 三组 RFC 文档专用地址；官网及文档文件行尾空白检查无匹配项。

### Notes

- `website/index.html`：重写为参考页同类信息架构，并替换为 Harbor 自有产品文案与隐私安全的界面演示。
- `website/styles.css`：重写黑白排版、整宽柔和渐变产品画面、三端卡片、下载区、页脚和响应式规则。
- `website/site.js`：保留导航滚动状态与进入视口显现，删除已不再使用的窗口倾斜交互。
- `docs/website.md`：补充新版页面结构和无外部运行资源说明。
- `progress.md`：追加本轮重做、验证与回滚记录。
- 回滚点：`/private/tmp/harbor-website-pre-codex-redesign-20260711`。可执行 `/usr/bin/ditto /private/tmp/harbor-website-pre-codex-redesign-20260711/index.html /Users/zero/Desktop/ssh/website/index.html`、`/usr/bin/ditto /private/tmp/harbor-website-pre-codex-redesign-20260711/styles.css /Users/zero/Desktop/ssh/website/styles.css`、`/usr/bin/ditto /private/tmp/harbor-website-pre-codex-redesign-20260711/site.js /Users/zero/Desktop/ssh/website/site.js` 和 `/usr/bin/ditto /private/tmp/harbor-website-pre-codex-redesign-20260711/website.md /Users/zero/Desktop/ssh/docs/website.md` 恢复重做前版本；`progress.md` 按追加规范保留。

## 2026-07-11 - Task: 以 90% 以上目标高精度还原 Codex 官网布局

### What was done

- 使用 1440×1000 实际浏览器视口逐屏读取参考页，按测量值重写 Harbor 官网：64px 固定导航、1640px 蓝紫纹理首屏、底部 1100×650 产品窗口、五组 437px 文案与 907×510 产品画面左右交替、三列产品入口、3×2 工作流观点卡、纹理下载 CTA 和五列页脚。
- 将主排版修正为参考页的 64/64 产品标题、48/55.68 主区标题、30/39.6 功能标题和 17/28 正文，移除上一版过大的 238px 标题与紧凑行距。
- 生成并接入 Harbor 自有蓝紫抽象纹理，压缩为 136 KB 本地 WebP；未复制参考站品牌资产。产品界面继续使用 HTML/CSS 和 RFC 文档地址构造。

### Testing

- 1440px 参考页总高 8047px，新版为 8083px；参考页 H1 位于 y=306、字号/行高 64/64，新版位于 y=307、字号/行高 64/64。
- 参考页五张产品画面均为 907×510，x 坐标按 501/32 交替，y 坐标为 1800、2438、3076、3714、4352；新版尺寸和 x 坐标完全一致，y 坐标分别为 1799、2437、3075、3713、4351。
- 使用 Chrome 对 1440×1000 的首屏、八个滚动位置逐屏截图检查；产品窗口、五组功能、三列入口、六张观点卡、纹理 CTA 和页脚均无错位。
- 使用真实 390×844 设备模拟检查首屏和功能区；`innerWidth` 与 `scrollWidth` 均为 390，无横向溢出。
- `node --check website/site.js` 通过；HTML、CSS、JavaScript、图标和纹理通过本地 HTTP 加载检查，均返回 200。
- 官网与文档无外部 HTTP 资源；IPv4 扫描只命中三组 RFC 文档专用地址；源码、文档行尾空白检查无匹配项。

### Notes

- `website/index.html`：按参考页实际模块层级与交替布局重写整页，保留 Harbor 自有内容和隐私安全的虚构界面。
- `website/styles.css`：按参考实测字号、列宽、画面尺寸和垂直坐标重写桌面与移动端视觉。
- `website/site.js`：简化为固定导航的滚动背景状态，不再使用与参考无关的进入视口动画。
- `website/assets/harbor-hero-texture.webp`：新增由图像生成技能制作的 Harbor 自有 1806×871 蓝紫纹理背景。
- `docs/website.md`：同步新版页面结构与本地纹理资源说明。
- `progress.md`：追加本轮高精度还原、对照验证和回滚记录。
- 回滚点：`/private/tmp/harbor-website-pre-90-redesign-20260711`。可执行 `/usr/bin/ditto /private/tmp/harbor-website-pre-90-redesign-20260711/index.html /Users/zero/Desktop/ssh/website/index.html`、`/usr/bin/ditto /private/tmp/harbor-website-pre-90-redesign-20260711/styles.css /Users/zero/Desktop/ssh/website/styles.css`、`/usr/bin/ditto /private/tmp/harbor-website-pre-90-redesign-20260711/site.js /Users/zero/Desktop/ssh/website/site.js` 和 `/usr/bin/ditto /private/tmp/harbor-website-pre-90-redesign-20260711/website.md /Users/zero/Desktop/ssh/docs/website.md` 恢复本轮前版本，再执行 `/bin/rm -f /Users/zero/Desktop/ssh/website/assets/harbor-hero-texture.webp` 删除本轮新增纹理；`progress.md` 按追加规范保留。

## 2026-07-11 - Task: 让官网产品画面与 Harbor 实际 App 一致

### What was done

- 保留已经对齐参考页的外层版式，将首屏工作台、五组功能画面和三张产品细节图全部改成 Harbor 当前 App 的实际界面结构。
- 产品画面覆盖真实的主机头像与搜索侧栏、会话标签、SwiftTerm 终端、命令输入条、底部文件抽屉、右侧监控检查器和主机编辑表单。
- 所有界面继续使用 HTML/CSS 与虚构数据绘制，不截取用户 App，不读取或展示任何真实服务器信息。

### Testing

- 使用 Chrome 在 1440px 桌面视口逐段截图检查首屏、五张功能画面以及 Terminal、SFTP、Monitor 三张细节图；资源加载检查为 0 张失败图片、1 张有效样式表。
- 使用 390×844 设备模拟检查功能画面与三张细节图；`innerWidth` 与 `scrollWidth` 均为 390，无横向溢出。
- 本地 HTTP 检查确认 HTML、CSS、JavaScript、512×512 App 图标和 1806×871 纹理均返回 200；`node --check website/site.js` 通过。
- 官网与文档无外部 HTTP 资源；IPv4 扫描只命中 RFC 文档专用地址；源码与文档行尾空白检查无匹配项。

### Notes

- `website/index.html`：将所有产品演示内容替换为与 Harbor 当前 App 一致的窗口、侧栏、终端、文件、监控和连接表单结构。
- `website/styles.css`：新增上述真实产品结构的桌面与移动端绘制规则，并修正监控卡片的紧凑排版。
- `docs/website.md`：记录产品画面与 App 源码结构的对应关系及隐私边界。
- `progress.md`：追加本轮产品画面对齐、验证和回滚信息。
- 回滚方式：当前可用回滚点为 `/private/tmp/harbor-website-pre-90-redesign-20260711`；执行 `/usr/bin/ditto /private/tmp/harbor-website-pre-90-redesign-20260711/index.html /Users/zero/Desktop/ssh/website/index.html`、`/usr/bin/ditto /private/tmp/harbor-website-pre-90-redesign-20260711/styles.css /Users/zero/Desktop/ssh/website/styles.css`、`/usr/bin/ditto /private/tmp/harbor-website-pre-90-redesign-20260711/site.js /Users/zero/Desktop/ssh/website/site.js` 和 `/usr/bin/ditto /private/tmp/harbor-website-pre-90-redesign-20260711/website.md /Users/zero/Desktop/ssh/docs/website.md` 可恢复到此前稳定基线；该回滚会同时撤销后续高精度版式和本轮产品画面改动，`progress.md` 按追加规范保留。

## 2026-07-11 - Task: 使用真实 Harbor 截图并补齐动态特效

### What was done

- 重新逐段比对当前 OpenAI Codex 官网，确认主要差距是持续运动的首屏背景、真实产品截图、产品窗口轻微悬浮、滚动进入与卡片悬停反馈。
- 在隔离 App 数据目录中启动 Harbor 正式版，连接仅监听 `localhost:22222` 的临时合成 SSH 服务，取得工作台全景、终端与监控、文件面板和主机编辑表单四张真实窗口截图。
- 将首屏、五组功能画面和三张产品入口全部切换为真实截图；新增持续背景漂移、窗口悬浮、错峰滚动进入和卡片悬停动效，并保留减少动态效果适配。
- 截图后关闭隔离 Harbor 会话与假 SSH 服务，删除临时 App 数据和脚本，并移除本轮写入的本地主机指纹。

### Testing

- 使用当前官方 Codex 页面核对首屏动态背景、真实产品图、功能模块、产品入口和观点区域的运动层级。
- Chrome 桌面验证检测到 17 个持续运行的命名动画；3 秒间隔首屏截图内容发生变化，确认不是静态背景。
- 1440×1000 逐段检查首屏、五张功能画面和三张产品入口；四张 WebP 均为 2482×1802，合计约 430 KB，全部通过本地 HTTP 200 加载。
- 390×844 设备模拟的 `innerWidth` 与 `scrollWidth` 均为 390，无横向溢出；移动端真实 App 截图采用放大裁切，避免界面文字过小。
- 使用 macOS Vision 对四张截图执行 OCR；未识别到任何 IPv4 地址，只出现 `localhost`、`22222` 和合成演示内容。
- `node --check website/site.js` 通过；网站运行资源无外部 HTTP URL，源码行尾空白检查无匹配项。

### Notes

- `website/index.html`：首屏、功能画面和产品入口接入四张真实 Harbor 截图，并为非首屏截图启用延迟解码和懒加载。
- `website/styles.css`：新增动态纹理、光晕漂移、真实窗口悬浮、滚动进入、卡片悬停和移动端截图裁切规则。
- `website/site.js`：新增基于 `IntersectionObserver` 的一次性滚动进入控制，并尊重系统减少动态效果设置。
- `website/assets/harbor-app-overview.webp`：新增 Harbor 连接本机合成服务后的真实工作台全景。
- `website/assets/harbor-app-terminal-monitor.webp`：新增真实终端命令与动态监控画面。
- `website/assets/harbor-app-files.webp`：新增真实终端与文件面板画面。
- `website/assets/harbor-app-host-editor.webp`：新增填写 `localhost:22222` 的真实主机编辑表单画面。
- `docs/website.md`：记录真实截图来源、临时假服务、动态效果与隐私清理边界。
- `progress.md`：追加本轮实现、验证和回滚记录。
- 回滚方式：执行 `/usr/bin/ditto /private/tmp/harbor-website-pre-90-redesign-20260711/index.html /Users/zero/Desktop/ssh/website/index.html`、`/usr/bin/ditto /private/tmp/harbor-website-pre-90-redesign-20260711/styles.css /Users/zero/Desktop/ssh/website/styles.css`、`/usr/bin/ditto /private/tmp/harbor-website-pre-90-redesign-20260711/site.js /Users/zero/Desktop/ssh/website/site.js` 和 `/usr/bin/ditto /private/tmp/harbor-website-pre-90-redesign-20260711/website.md /Users/zero/Desktop/ssh/docs/website.md` 恢复到此前稳定基线，再执行 `/bin/rm -f /Users/zero/Desktop/ssh/website/assets/harbor-app-overview.webp /Users/zero/Desktop/ssh/website/assets/harbor-app-terminal-monitor.webp /Users/zero/Desktop/ssh/website/assets/harbor-app-files.webp /Users/zero/Desktop/ssh/website/assets/harbor-app-host-editor.webp` 删除本轮真实截图；该回滚会同时撤销后续高精度版式，`progress.md` 按追加规范保留。

## 2026-07-11 - Task: 将产品图改为铺满展示的真实 App 原窗截图

### What was done

- 从上一轮 Harbor 正式 App 原始截图生成首屏比例与五组 16:9 产品位专用裁切，保留原生标题栏、侧栏、终端、文件面板、监控和主机表单。
- 首屏和五张功能图全部切换到专用真实截图资产；产品图宽高提升到展示框的 92%，不再以缩小的完整窗口嵌在大面积渐变背景中。
- 移动端使用真实 16:9 截图放大裁切，保持终端与监控内容可辨认，同时维持 390px 页面无横向滚动。

### Testing

- Chrome 1440×1000 检查首屏和第一组功能图，确认显示资源分别为 `harbor-app-hero.webp` 和 `harbor-app-terminal-feature.webp`，无模拟界面覆盖。
- 390×844 设备模拟的 `innerWidth` 与 `scrollWidth` 均为 390；移动端产品截图实际显示宽度约 550px，由容器安全裁切。
- 五张新增 WebP 均通过本地 HTTP 200 加载；`node --check website/site.js` 与源码行尾空白检查通过。
- 使用 macOS Vision 对五张裁切截图执行 OCR，未识别到任何 IPv4 地址，只出现 `localhost`、`22222` 和合成演示文字。

### Notes

- `website/index.html`：首屏和五组功能图改用真实 App 专用裁切资产。
- `website/styles.css`：放大桌面产品图并调整移动端真实截图裁切比例。
- `website/assets/harbor-app-hero.webp`：新增适配首屏工作台容器的真实 App 全景裁切。
- `website/assets/harbor-app-terminal-feature.webp`：新增真实终端与监控 16:9 裁切。
- `website/assets/harbor-app-overview-feature.webp`：新增真实工作台全景 16:9 裁切。
- `website/assets/harbor-app-files-feature.webp`：新增真实文件面板 16:9 裁切。
- `website/assets/harbor-app-host-editor-feature.webp`：新增真实主机编辑表单 16:9 裁切。
- `docs/website.md`：补充真实截图裁切与不重绘原则。
- `progress.md`：追加本轮实现、验证和回滚信息。
- 回滚方式：将 `website/index.html` 中 `*-feature.webp` 与 `harbor-app-hero.webp` 引用恢复为上一轮四张 `harbor-app-*.webp`，将 `website/styles.css` 的桌面产品图宽高恢复为 `84%`/`88%`、移动端恢复为 `155%`/`78%`，并将移动端 `.shot-editor` 宽度恢复为 `112%`；再执行 `/bin/rm -f /Users/zero/Desktop/ssh/website/assets/harbor-app-hero.webp /Users/zero/Desktop/ssh/website/assets/harbor-app-terminal-feature.webp /Users/zero/Desktop/ssh/website/assets/harbor-app-overview-feature.webp /Users/zero/Desktop/ssh/website/assets/harbor-app-files-feature.webp /Users/zero/Desktop/ssh/website/assets/harbor-app-host-editor-feature.webp`；`progress.md` 按追加规范保留。

## 2026-07-11 - Task: 为工作流观点卡补充虚构人物头像

### What was done

- 为六张“远程工作应该是什么样”观点卡生成并接入六位不同的虚构工程师头像，替换原有字母色块。
- 头像统一为 256×256 WebP、本地静态资源和 64×64 圆角展示，并保留懒加载与可访问性描述。
- 明确记录头像不对应真实人物，避免暗示真实用户、评价人或身份背书。

### Testing

- 本地 HTTP 检查确认页面和六张头像资源全部返回 200；六张资源均为 256×256 WebP，单张约 4.4 KB 至 6.1 KB。
- Chrome 1440×1000 实际渲染检查确认六张头像按三列两行加载，`naturalWidth` 与 `naturalHeight` 均为 256。
- Chrome 390×844 移动端检查确认头像与卡片正常单列显示，`innerWidth` 与 `scrollWidth` 均为 390，无横向溢出。
- `/opt/homebrew/bin/node --check website/site.js`、旧字母头像残留扫描和源码行尾空白检查均通过。

### Notes

- `website/index.html`：六张观点卡改用虚构工程师头像，并新增观点区锚点。
- `website/styles.css`：将字母渐变色块样式改为人物图片裁切与阴影样式，删除不再使用的色块变体。
- `website/assets/voice-ops.webp`：新增虚构站点可靠性工程师头像。
- `website/assets/voice-platform.webp`：新增虚构平台工程师头像。
- `website/assets/voice-devops.webp`：新增虚构 DevOps 工程师头像。
- `website/assets/voice-security.webp`：新增虚构安全工程师头像。
- `website/assets/voice-software.webp`：新增虚构软件工程师头像。
- `website/assets/voice-infra.webp`：新增虚构基础设施工程师头像。
- `docs/website.md`：补充观点卡头像的虚构人物与隐私边界说明。
- `progress.md`：追加本轮头像接入、验证与回滚信息。
- 回滚方式：将 `website/index.html` 中六个头像 `<img>` 恢复为原来的 `OP`、`MX`、`FT`、`HK`、`QC`、`ID` 字母色块，恢复 `website/styles.css` 中 `.voice-avatar` 的渐变背景及五个颜色变体，删除 `docs/website.md` 的虚构头像说明，再执行 `/bin/rm -f /Users/zero/Desktop/ssh/website/assets/voice-ops.webp /Users/zero/Desktop/ssh/website/assets/voice-platform.webp /Users/zero/Desktop/ssh/website/assets/voice-devops.webp /Users/zero/Desktop/ssh/website/assets/voice-security.webp /Users/zero/Desktop/ssh/website/assets/voice-software.webp /Users/zero/Desktop/ssh/website/assets/voice-infra.webp`；`progress.md` 按追加规范保留。

## 2026-07-11 - Task: 将首屏能力标识替换为官方品牌资产

### What was done

- 将“为高强度远程工作而生”区域的五个文字造型替换为 OpenSSH、Swift 和 Apple 的真实官方标识，并保留 SSH、SFTP、macOS Keychain、SwiftUI 与 Apple 公证的能力说明。
- OpenSSH 官方标识同时用于 SSH 与 SFTP，因为 OpenSSH 官方套件包含 `ssh`、`sftp` 与 `sftp-server`；未虚构独立的 SFTP 品牌 Logo。
- 将三类官方资产全部本地化，网站运行时不向 OpenSSH、Swift 或 Apple 官网发起图片请求。
- 增加移动端首屏高度并下移产品图，避免真实 Logo 增高后遮挡第五项 Apple 公证。

### Testing

- 本地 HTTP 检查确认页面、OpenSSH GIF、Swift SVG 与 Apple SVG 全部返回 200。
- Chrome 1440×1000 检查确认五个标识按单行完整显示；OpenSSH 渲染为 145×48，Swift 渲染为 154×48，Apple 渲染为 38×44，均保持原始比例。
- Chrome 390×844 检查确认五项按两列、两列、单列排列，Logo 区底部与产品图顶部保留 36px 间隔；`innerWidth` 与 `scrollWidth` 均为 390，无横向溢出。
- `/opt/homebrew/bin/node --check website/site.js` 通过；旧文字造型修饰类残留扫描无匹配项。

### Notes

- `website/index.html`：首屏五项能力接入官方品牌图片并补充对应能力标签。
- `website/styles.css`：新增官方 Logo 的等比布局规则，并修正移动端首屏与产品图位置。
- `website/assets/openssh-official.gif`：新增来自 OpenSSH 官网的官方标识原图。
- `website/assets/swift-official.svg`：新增来自 Swift.org 的官方 Swift 标识原图。
- `website/assets/apple-official.svg`：新增取自 Apple 官网全局导航的官方 Apple 矢量路径。
- `docs/website.md`：记录官方品牌资产来源、本地化方式与能力对应关系。
- `progress.md`：追加本轮官方 Logo 替换、验证与回滚信息。
- 回滚方式：将 `website/index.html` 的五个 `.capability-mark` 恢复为 `SSH`、`SFTP`、`Keychain`、`SwiftUI`、`Notarized` 文字标识，恢复 `website/styles.css` 中原 `.capability-mark` 及其 `serif`、`light`、`boxed`、`underline` 变体，将移动端 `.hero` 最小高度恢复为 `1160px`、`.hero-product` 顶部恢复为 `745px`，删除 `docs/website.md` 的官方资产说明，再执行 `/bin/rm -f /Users/zero/Desktop/ssh/website/assets/openssh-official.gif /Users/zero/Desktop/ssh/website/assets/swift-official.svg /Users/zero/Desktop/ssh/website/assets/apple-official.svg`；`progress.md` 按追加规范保留。

## 2026-07-11 - Task: 优化 OpenSSH 与公证图标并新增 2.5 秒平台翻转

### What was done

- 将横幅式 OpenSSH 官网图替换为紧凑的方形 OpenSSH 图标，SSH 与 SFTP 仍保持清晰的能力标签。
- 将“Apple 公证”的 Apple 标识替换为本机 Xcode 正式 App 图标，文案调整为“Xcode / 公证”。
- 新增能力区双面 3D 翻转：正面显示 SSH、SFTP、Keychain、SwiftUI 与 Xcode，背面显示 AWS、Google Cloud、Microsoft Azure、DigitalOcean 与 Cloudflare。
- 翻转按 5 秒完整周期无限循环，两次换面间隔为 2.5 秒；减少动态效果开启时停留在核心能力正面。
- 平台标题明确使用“适配你常用的远程平台”，不将兼容性展示伪装成未经确认的商业合作关系。

### Testing

- Chrome 桌面端在 0 秒、2.5 秒、5 秒连续取样，变换矩阵依次为正面、180 度背面、正面，确认循环与换面节奏正确。
- 1440×1000 实际截图检查确认核心能力与五个平台 Logo 均完整等距显示，翻转过程中无布局跳动。
- 390×844 移动端检查确认平台按两列、两列、单列排列；`innerWidth` 与 `scrollWidth` 均为 390，Logo 区底部与产品图顶部保留 36px 间隔。
- 页面、样式、OpenSSH、Xcode 与五个平台资产均通过本地 HTTP 200 加载；十张翻转区图片的 `complete` 与原始尺寸检查全部有效。
- `/opt/homebrew/bin/node --check website/site.js` 通过。

### Notes

- `website/index.html`：将能力区改成正反双面结构，接入 Xcode、紧凑 OpenSSH 与五个平台图标。
- `website/styles.css`：新增 5 秒循环的 3D 翻转、双面隐藏、品牌图标尺寸及移动端容器高度规则。
- `website/assets/openssh-clean.webp`：新增紧凑 OpenSSH 图标，替换并删除旧横幅 GIF。
- `website/assets/xcode-icon.webp`：新增由本机正式 Xcode 图标生成的 256×256 WebP。
- `website/assets/platform-aws.svg`：新增 AWS 平台标识。
- `website/assets/platform-google-cloud.svg`：新增 Google Cloud 平台标识。
- `website/assets/platform-azure.svg`：新增 Microsoft Azure 平台标识。
- `website/assets/platform-digitalocean.svg`：新增 DigitalOcean 平台标识。
- `website/assets/platform-cloudflare.svg`：新增 Cloudflare 平台标识。
- `docs/website.md`：记录翻转节奏、图标来源与“兼容不等于合作”的展示边界。
- `progress.md`：追加本轮图标优化、翻转实现、验证与回滚信息。
- 回滚方式：将 `website/index.html` 的 `.trusted-switcher` 双面结构恢复为上一轮单个 `.trusted-row`，将 `website/styles.css` 中 `.trusted-switcher`、`.trusted-flipper`、`.trusted-face`、`.trusted-platforms`、`.capability-logo.xcode`、`.capability-logo.platform` 与 `trustedFlip` 规则删除，将 OpenSSH 引用恢复为 `assets/openssh-official.gif`、公证项恢复为 Apple 标识，并从上一轮资产重新恢复 `website/assets/openssh-official.gif`；再执行 `/bin/rm -f /Users/zero/Desktop/ssh/website/assets/openssh-clean.webp /Users/zero/Desktop/ssh/website/assets/xcode-icon.webp /Users/zero/Desktop/ssh/website/assets/platform-aws.svg /Users/zero/Desktop/ssh/website/assets/platform-google-cloud.svg /Users/zero/Desktop/ssh/website/assets/platform-azure.svg /Users/zero/Desktop/ssh/website/assets/platform-digitalocean.svg /Users/zero/Desktop/ssh/website/assets/platform-cloudflare.svg`；`progress.md` 按追加规范保留。

## 2026-07-11 - Task: 将平台切换从旋转改为淡入淡出

### What was done

- 删除能力区的 3D 旋转、透视与背面翻转效果，保留原有 2.5 秒换面节奏。
- 切换方式改为当前内容淡出并上移 8px、下一组内容从下方 8px 淡入，容器高度与产品图位置保持不变。
- 减少动态效果开启时禁用两组动画并只显示核心能力，避免两层内容重叠。

### Testing

- Chrome 桌面端在 0 秒、2.5 秒、5 秒取样，前后两组透明度依次为 `1/0`、`0/1`、`1/0`，确认循环节奏正确。
- 三个时间点的计算样式仅包含纵向 `8px` 位移，不包含任何旋转矩阵或透视效果。
- 1440×1000 实际截图确认平台面稳定显示，无重影、翻面或布局跳动。
- 390×844 移动端检查确认 `innerWidth` 与 `scrollWidth` 均为 390，内容区与产品图保持 44px 间隔。

### Notes

- `website/styles.css`：用两组透明度与纵向位移动画替换原 3D 旋转动画，并完善减少动态效果规则。
- `docs/website.md`：将首屏切换说明更新为淡出、轻微上移与淡入，不再描述 3D 翻转。
- `progress.md`：追加本轮动画调整、验证与回滚信息。
- 回滚方式：将 `website/styles.css` 中 `trustedPrimaryFade` 与 `trustedSecondaryFade` 动画恢复为上一轮 `trustedFlip` 旋转动画，并恢复 `.trusted-switcher` 的 `perspective`、`.trusted-flipper` 的 `transform-style` 与 `.trusted-platforms` 的 `rotateY(180deg)`；`docs/website.md` 恢复上一轮 3D 翻转说明；`progress.md` 按追加规范保留。

## 2026-07-11 - Task: 官网接入中英文国际化与真实英文 App 截图

### What was done

- 官网新增简体中文 `zh-CN` 与英文 `en-US`，首次访问按浏览器首选语言自动识别，页头和页脚均可手动切换，并以 `localStorage` 的 `harbor.locale` 记住选择。
- 语言切换同步覆盖页面标题、描述元数据、导航、正文、按钮、页脚、图片替代文本和 ARIA 标签；两个语言选择器保持同步。
- 使用隔离的 `localhost:22222` 合成 SSH 环境重新启动英文 Harbor App，实拍终端、监控、文件面板和主机编辑表单，并生成英文页面对应的全尺寸与裁切 WebP 资产；未在图片上覆盖或修改文字。
- 修复 App 监控运行时间单位硬编码中文的问题，使天、小时、分钟和秒随 App 当前语言显示，避免英文截图残留中文。

### Testing

- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path HarborKit`：335 项通过，0 失败；新增中英文运行时间格式用例通过。
- `xcodebuild -project Harbor.xcodeproj -scheme Harbor -configuration Debug -destination 'platform=macOS' -derivedDataPath /private/tmp/harbor-en-derived CODE_SIGNING_ALLOWED=NO build`：`BUILD SUCCEEDED`。
- Chrome DevTools 实测：无已保存选择且首选语言为 `en-US` 时自动进入英文并加载 `*.en.webp`；模拟 `zh-CN` 时自动进入中文；页头或页脚手动切换后两个选择器同步，刷新后仍保持所选语言。
- 英文页面可见文本扫描为 0 条中文残留；标题、描述、主导航 ARIA、截图替代文本均随语言变化。8 个页面实际引用的英文截图全部解码成功，尺寸为 2482×1468、2482×1396 或 2482×1802。
- Chrome 390×844 移动端实测 `innerWidth` 与 `scrollWidth` 均为 390；1440×1000 桌面截图确认页头语言控件、英文文案和真实英文产品图正常显示。
- `node --check website/site.js`、本地资源存在性、行尾空白扫描通过；下载目录中的 DMG/ZIP 仍按发布流程外置，不属于源码仓库资源。
- 临时 SSH 监听已关闭，临时 App 数据已清理；用户 `~/.ssh/known_hosts` 与操作前备份逐字节一致。

### Notes

- `HarborKit/Sources/HarborKit/MonitorFormat.swift`：运行时间格式新增 Locale 参数及中英文单位。
- `HarborKit/Tests/HarborKitTests/MonitorFormatTests.swift`：固定中文测试并新增英文运行时间测试。
- `App/UI/MonitorPanel.swift`：监控概览使用当前 SwiftUI Locale 格式化运行时间。
- `App/UI/SystemInfoView.swift`：系统信息报告使用当前 SwiftUI Locale 格式化运行时间。
- `App/UI/MonitorProcessDetailView.swift`：进程运行时长使用当前 SwiftUI Locale 格式化。
- `website/index.html`：在页头与页脚新增可访问的语言选择器。
- `website/styles.css`：新增语言选择器的桌面、移动端与键盘焦点样式。
- `website/site.js`：新增双语字典、浏览器语言识别、手动切换、localStorage 持久化、元数据/无障碍文本和截图同步逻辑。
- `website/assets/harbor-app-overview.en.webp`：新增英文完整工作台真实截图。
- `website/assets/harbor-app-terminal-monitor.en.webp`：新增英文终端与监控真实截图。
- `website/assets/harbor-app-files.en.webp`：新增英文文件工作流真实截图。
- `website/assets/harbor-app-host-editor.en.webp`：新增英文主机编辑真实截图。
- `website/assets/harbor-app-hero.en.webp`：新增英文首屏真实截图裁切。
- `website/assets/harbor-app-terminal-feature.en.webp`：新增英文终端功能图裁切。
- `website/assets/harbor-app-overview-feature.en.webp`：新增英文完整工作台功能图裁切。
- `website/assets/harbor-app-files-feature.en.webp`：新增英文文件功能图裁切。
- `website/assets/harbor-app-host-editor-feature.en.webp`：新增英文主机编辑功能图裁切。
- `docs/website.md`：记录双语规则、持久化键、截图命名和隐私边界。
- `progress.md`：追加本轮实现、验证和回滚信息。
- 回滚方式：删除 `website/index.html` 的两个 `[data-language-select]` 控件与 `website/site.js` 的国际化区块，删除 `website/styles.css` 的 `.language-switch`、`.footer-language-switch` 和 `.visually-hidden` 规则；将三个 App 调用点恢复为 `MonitorFormat.uptime(seconds:)`，并将 `MonitorFormat.uptime` 恢复为原中文单位实现与原测试；再执行 `/bin/rm -f /Users/zero/Desktop/ssh/website/assets/harbor-app-overview.en.webp /Users/zero/Desktop/ssh/website/assets/harbor-app-terminal-monitor.en.webp /Users/zero/Desktop/ssh/website/assets/harbor-app-files.en.webp /Users/zero/Desktop/ssh/website/assets/harbor-app-host-editor.en.webp /Users/zero/Desktop/ssh/website/assets/harbor-app-hero.en.webp /Users/zero/Desktop/ssh/website/assets/harbor-app-terminal-feature.en.webp /Users/zero/Desktop/ssh/website/assets/harbor-app-overview-feature.en.webp /Users/zero/Desktop/ssh/website/assets/harbor-app-files-feature.en.webp /Users/zero/Desktop/ssh/website/assets/harbor-app-host-editor-feature.en.webp`；`docs/website.md` 删除“国际化”章节，`progress.md` 按追加规范保留。

## 2026-07-11 - Task: 官网所有产品截图改为完整窗口展示

### What was done

- 首屏、五组功能图与三张产品卡全部改用 2482×1802 的完整 Harbor App 窗口截图，不再引用预裁切资源。
- 截图统一按原始宽高比和 `object-fit: contain` 展示；移除首屏缩放、产品卡悬停放大和移动端 145%/155% 超宽展示，避免任何窗口边缘被容器裁掉。
- 桌面端与移动端截图容器都调整为原始截图比例；删除不再使用的中英文首屏及功能裁切资产。

### Testing

- Chrome 1440×1000 实测 9 个产品图位置均加载 2482×1802 完整资源；首屏与五张功能图渲染宽高比为 1.377/1.378，`object-fit` 均为 `contain`，页面 `scrollWidth` 与视口宽度同为 1440。
- Chrome 390×844 实测首屏截图渲染为 352×255，比例 1.380，四边完整显示；`innerWidth` 与 `scrollWidth` 均为 390，无横向溢出。
- 桌面和移动端实际截图检查确认 Harbor 窗口的顶部工具栏、左右侧栏及底部文件区域同时可见，没有放大裁切。
- 静态引用检查确认 9 个截图位置仅使用 4 张完整中文原图，所有文件及对应英文 `.en.webp` 均存在，裁切资源引用为 0；`node --check website/site.js` 与行尾空白检查通过。

### Notes

- `website/index.html`：首屏与五个功能位由裁切图改为完整窗口图。
- `website/styles.css`：截图容器改用原始比例与 contain，移除会导致裁切的缩放和超宽移动端规则。
- `website/assets/harbor-app-hero.webp`：删除不再使用的中文首屏裁切图。
- `website/assets/harbor-app-hero.en.webp`：删除不再使用的英文首屏裁切图。
- `website/assets/harbor-app-terminal-feature.webp`：删除不再使用的中文终端裁切图。
- `website/assets/harbor-app-terminal-feature.en.webp`：删除不再使用的英文终端裁切图。
- `website/assets/harbor-app-overview-feature.webp`：删除不再使用的中文工作台裁切图。
- `website/assets/harbor-app-overview-feature.en.webp`：删除不再使用的英文工作台裁切图。
- `website/assets/harbor-app-files-feature.webp`：删除不再使用的中文文件裁切图。
- `website/assets/harbor-app-files-feature.en.webp`：删除不再使用的英文文件裁切图。
- `website/assets/harbor-app-host-editor-feature.webp`：删除不再使用的中文主机编辑裁切图。
- `website/assets/harbor-app-host-editor-feature.en.webp`：删除不再使用的英文主机编辑裁切图。
- `docs/website.md`：将裁切策略更新为完整窗口展示规则。
- `progress.md`：追加本轮实现、验证和回滚信息。
- 回滚方式：将 `website/index.html` 的六个完整图引用恢复为上一轮 `harbor-app-hero.webp` 与四个 `*-feature.webp`，将 `website/styles.css` 的全局截图恢复为 `object-fit: cover`、首屏恢复 1100×650 与缩放动画、功能位恢复 16:9、移动端恢复 155%（编辑图 145%）、产品卡恢复悬停放大；裁切资产可从对应完整 PNG/WebP 居中裁切为首屏 2482×1468、功能图 2482×1396 后用 `/opt/homebrew/bin/cwebp -q 88` 重新生成；`docs/website.md` 恢复上一轮裁切说明，`progress.md` 按追加规范保留。

## 2026-07-11 - Task: 校正 SSH 协议图标语义

### What was done

- 将首屏 SSH 项从 OpenSSH 河豚标识替换为 Harbor 自绘的中性 SSH 协议图标，避免把实现项目标识误表示为协议官方 Logo。
- 核实 SFTP 是 SSH File Transfer Protocol，未发现独立官方品牌标识；页面继续保留 OpenSSH 图标，仅表达 Harbor 使用系统 OpenSSH 提供 SFTP 能力。
- 图标源图采用单色抠图后本地压缩为带 Alpha 的 WebP，页面不新增外部图片请求。

### Testing

- `curl -fsSI http://127.0.0.1:4173/` 与 `curl -fsSI http://127.0.0.1:4173/assets/ssh-protocol.webp` 均返回 200；图标资源为 `image/webp`。
- `node --check website/site.js` 通过；静态断言确认 SSH 图标引用、替代文本、48px 尺寸规则和图标语义说明均已存在。
- `sips -g pixelWidth -g pixelHeight -g hasAlpha website/assets/ssh-protocol.webp` 确认资源为 256×256 且带 Alpha 通道。

### Notes

- `website/index.html`：SSH 能力项改为引用自绘协议图标。
- `website/styles.css`：补充 SSH 图标的 48px 显示规则。
- `website/assets/ssh-protocol.webp`：新增自绘 SSH 协议图标。
- `docs/website.md`：澄清 SSH/SFTP 与 OpenSSH 标识的关系及资产来源。
- `progress.md`：追加本轮图标调整、验证与回滚说明。
- 回滚方式：将 `website/index.html` 的 SSH 项恢复为 `assets/openssh-clean.webp` 和 `OpenSSH` 替代文本，删除 `website/styles.css` 中 `.capability-logo.ssh img` 规则，执行 `/bin/rm -f /Users/zero/Desktop/ssh/website/assets/ssh-protocol.webp`，并恢复 `docs/website.md` 本轮说明；`progress.md` 按追加规范保留。

## 2026-07-11 - Task: 重绘 SSH 协议图标

### What was done

- 用更轻量的终端框、命令提示符与远程连接节点图形重绘 SSH 图标，移除上一版笨重的钥匙孔意象。
- 保持原有文件名、透明背景和 48px 页面展示规则，页面无需变更引用或加载逻辑。

### Testing

- `sips -g pixelWidth -g pixelHeight -g hasAlpha website/assets/ssh-protocol.webp` 确认替换后的资源仍为 256×256 且带 Alpha 通道。
- Pillow 像素检查确认 65,536 个输出像素中可见的绿色主导像素为 0，抠图后没有残留色键背景。
- `curl -fsSI http://127.0.0.1:4173/` 与 `curl -fsSI http://127.0.0.1:4173/assets/ssh-protocol.webp` 均返回 200；图标资源为 `image/webp`，页面 SSH 图标引用存在。

### Notes

- `website/assets/ssh-protocol.webp`：替换为新版自绘 SSH 协议图标。
- `docs/website.md`：更新自绘图标的视觉说明。
- `progress.md`：追加本轮图标重绘、验证与回滚说明。
- 回滚方式：执行 `/usr/bin/ditto /private/tmp/harbor-ssh-protocol-before-v2-20260711.webp /Users/zero/Desktop/ssh/website/assets/ssh-protocol.webp`，并将 `docs/website.md` 中图标意象恢复为“终端提示符与安全隧道/钥匙孔意象”；`progress.md` 按追加规范保留。

## 2026-07-11 - Task: 修复全项目安全审计发现

### What was done

- 将远程目录枚举改为 NUL 分隔的 GNU `find` 元数据协议，避免带换行或伪造 `ls` 行的文件名生成误导性文件条目。
- MCP 默认不开放任何远程能力；仅在显式指定保存主机后开放只读工具，命令执行和文件写入分别需要独立环境开关。
- 发布流程要求存在已审阅的 Git 提交且工作区干净，并在发布输出中记录对应的源代码 revision。

### Testing

- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`（`HarborKit`）通过，包含远程文件名含换行与超范围时间戳的回归测试。
- `swift test`（`HarborMCP`）通过，包含默认拒绝、主机范围和破坏性能力开关的授权测试。
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Harbor.xcodeproj -scheme Harbor -configuration Release -derivedDataPath .build/AuditDerivedData CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= build` 成功；`codesign --verify --deep --strict` 通过。
- `bash -n scripts/release.sh` 与 `node --check website/site.js` 通过；在无 Git `HEAD` 的当前工作区执行发布脚本会按预期拒绝发布。

### Notes

- `HarborKit/Sources/HarborKit/RemoteFiles.swift`：远程目录解析改为固定字段、NUL 分隔协议。
- `HarborKit/Tests/HarborKitTests/RemoteLsParserTests.swift`：更新协议测试并新增控制字符与时间戳回归覆盖。
- `HarborMCP/Sources/HarborMCP/main.swift`：增加显式主机授权和高风险工具独立开关。
- `HarborMCP/Tests/HarborMCPTests/HarborMCPTests.swift`：增加 MCP 默认拒绝和能力边界测试。
- `scripts/release.sh`：拒绝无提交或脏工作区的发布，并输出源代码 revision。
- `README.md`：补充受审阅提交和干净工作区的发布前提。
- `docs/security-and-release.md`：更新 MCP 授权、远程目录解析和发布来源规则。
- `progress.md`：追加本轮实现、验证和回滚信息。
- 回滚点：本轮开始前的用户工作区。当前仓库没有可用 Git 提交，不能执行 `git restore` 自动回退；恢复时请从该工作区副本还原上述七个实现/文档文件，并保留 `progress.md` 的追加历史。

## 2026-07-11 - Task: 提升官网按钮反馈与动画速度

### What was done

- 取消全局锚点平滑滚动，让导航和功能 CTA 点击后立即跳转到目标区块。
- 为主 CTA 增加按下缩放反馈，缩短观点卡与产品卡悬停动效。
- 将滚动进入动画从 0.8–0.9 秒、44px 位移收紧为 0.18–0.22 秒、16px 位移，并缩短错峰延迟。

### Testing

- `curl -fsSI http://127.0.0.1:4173/`、`/styles.css`、`/site.js` 在临时本地服务中均返回 200；服务验证后已停止。
- `node --check website/site.js` 通过。
- 静态断言确认即时锚点跳转、CTA 按下状态、220ms 以内的入场动画和 40/80ms 错峰延迟均已写入样式。
- 浏览器控制连接当前不可用，未完成可视化自动化回归；本轮页面加载和样式规则已完成本地验证。

### Notes

- `website/styles.css`：缩短交互动效，移除锚点平滑滚动并增加 CTA 按下反馈。
- `docs/website.md`：更新官网动效与 CTA 反馈规则。
- `progress.md`：追加本轮实现、验证与回滚信息。
- 回滚方式：将 `website/styles.css` 中 `scroll-behavior` 恢复为 `smooth`，删除 `.pill-button:active` 规则，并将本轮产品卡、观点卡、`motion-ready .reveal` 与两个 `transition-delay` 的时长恢复为修改前数值；将 `docs/website.md` 的本轮动效说明恢复为上一版。当前仓库没有 Git 基线，回滚前请保留这三个文件的副本。

## 2026-07-11 - Task: 恢复官网原有动效

### What was done

- 恢复官网原有的锚点平滑滚动、CTA 样式、卡片悬停时长、滚动入场时长与错峰节奏。
- 恢复官网文档中的原始动效说明；后续仅处理原生 App 的响应问题。

### Testing

- `node --check website/site.js` 通过。
- 静态断言确认 `scroll-behavior: smooth`、原有 0.8–0.9 秒滚动入场规则存在，且 CTA 按下态规则已移除。

### Notes

- `website/styles.css`：恢复本轮前的官网动效规则。
- `docs/website.md`：恢复本轮前的官网动效说明。
- `progress.md`：追加恢复原因、验证与回滚信息。
- 回滚方式：恢复本条目之前的 `website/styles.css` 与 `docs/website.md` 版本即可重新应用上一轮官网提速调整；当前仓库没有 Git 基线，操作前请先备份这两个文件。

## 2026-07-11 - Task: 提升原生 App 交互响应

### What was done

- 将 Harbor 的 Xcode 默认运行方案从未优化的 Debug 改为 Release，确保日常运行使用编译器优化后的 App。
- 将首次欢迎引导的页切换和首屏进入动画缩短至约 0.2 秒，减少点击“继续”后的等待感。
- 恢复官网原有动效；本轮未再修改官网样式或行为。

### Testing

- `xcodegen generate` 成功生成工程；生成后的 `Harbor.xcscheme` 的 `LaunchAction` 为 `Release`。
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Harbor.xcodeproj -scheme Harbor -configuration Release -derivedDataPath .build/AppResponseDerivedData CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= build` 成功。
- `xcodebuild -showBuildSettings` 确认 Release 使用 `SWIFT_OPTIMIZATION_LEVEL = -O` 与 whole-module 编译；`codesign --verify --deep --strict` 通过。
- 桌面自动化连接不可用，未完成实际点击时延采样；构建、运行方案和动画时长均已完成静态复核。

### Notes

- `project.yml`：默认 Xcode Run 使用 Release。
- `App/UI/WelcomeGuideView.swift`：缩短欢迎引导的切换和进入动画。
- `README.md`：说明日常运行与 Xcode 默认方案使用 Release，Debug 仅用于显式断点调试。
- `docs/performance.md`：补充默认运行配置与性能评估边界。
- `progress.md`：追加本轮实现、验证与回滚信息。
- 回滚方式：将 `project.yml` 的 `schemes.Harbor.run.config` 恢复为 `Debug` 后执行 `xcodegen generate`；将 `App/UI/WelcomeGuideView.swift` 的本轮 `0.2/0.22/0.03` 动画时长恢复为 `0.35/0.4/0.6/0.1`，并恢复 README 与性能文档的本轮说明。当前仓库没有 Git 基线，操作前请先备份上述文件。

## 2026-07-12 - Task: 添加监控阈值与通知

### What was done

- 为 CPU、内存、磁盘使用率及 1 分钟负载增加默认阈值（90%、90%、90%、4.0）和面板内配置入口。
- 监控面板在阈值超出时持续显示告警卡片；可选的 macOS 系统通知只在用户显式开启并授权后发送。
- 以主机、端口和告警类型为粒度节流，持续异常时同类系统通知最多每 10 分钟一次；多标签页不会重复刷通知。

### Testing

- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc -parse App/Monitoring/MonitorService.swift App/UI/MonitorPanel.swift` 通过。
- `git diff --check` 通过。
- Release 全量构建已启动并通过监控模块编译阶段；当前被并行开发中的 `ContentView`、`ScriptLibraryView`、`RecordingPlayer` 和 `WorkspaceStore` 编译错误阻塞，未出现本轮监控文件的诊断。

### Notes

- `App/Monitoring/MonitorService.swift`：计算阈值告警、处理系统通知授权，并实现跨会话的 10 分钟通知节流。
- `App/UI/MonitorPanel.swift`：新增告警状态卡片、铃铛设置入口及阈值/系统通知配置弹窗。
- `progress.md`：追加本轮实现、验证和回滚说明。
- 回滚方式：执行 `git restore --source=22999e4 -- App/Monitoring/MonitorService.swift App/UI/MonitorPanel.swift`；`progress.md` 按追加规范保留历史记录。

## 2026-07-12 - Task: 添加本地—远程目录对比与安全同步

### What was done

- 为当前远程目录增加本地目录 dry-run 对比：按文件名、大小和秒级修改时间列出本地新增、差异和仅远程文件。
- 增加确认前预览，明确展示本地与远程元数据；确认后只复用现有 SFTP 队列上传本地新增或差异文件。
- 同步过程不包含远程删除，目录和符号链接也不会被自动遍历或上传；远程目录改变后会拒绝使用旧预览。

### Testing

- `swiftc -typecheck -target arm64-apple-macosx26.0 -I HarborKit/.build/arm64-apple-macosx/debug/Modules App/Files/DirectorySync.swift` 通过。
- `xcodegen generate` 成功，新建的目录对比模型和预览视图已加入 Harbor target。
- `git diff --check -- App/Files/FileService.swift App/UI/FilePanelView.swift App/Files/DirectorySync.swift App/UI/FileSyncPreviewView.swift` 通过。
- Release 全量构建已启动；当前被并行开发中的 `ContentView`、`ScriptLibraryView` 和 `WorkspaceStore` 编译错误阻塞，未出现本轮目录同步文件的诊断。

### Notes

- `App/Files/DirectorySync.swift`：后台生成目录差异预览，只纳入第一层常规文件。
- `App/Files/FileService.swift`：保存预览状态、异步比对，并在确认后仅调用既有上传队列。
- `App/UI/FileSyncPreviewView.swift`：展示新增、差异与仅远程项，并提供明确上传确认。
- `App/UI/FilePanelView.swift`：增加“与本地目录对比…”入口、比较进度和预览弹窗。
- `progress.md`：追加本轮实现、验证和回滚说明。
- 回滚方式：执行 `git restore --source=22999e4 -- App/Files/FileService.swift App/UI/FilePanelView.swift && rm App/Files/DirectorySync.swift App/UI/FileSyncPreviewView.swift && xcodegen generate`；`progress.md` 按追加规范保留历史记录。

## 2026-07-12 - Task: 添加工作区保存与一键恢复

### What was done

- 增加命名工作区：保存已打开标签的顺序、选中标签、关联保存主机、本地终端标签，以及监控和文件面板的显示状态。
- 增加工具栏和会话标签栏入口，支持保存、恢复、删除和缺失主机提示；同名保存会更新已有工作区。
- 恢复前明确确认关闭当前标签；缺失主机自动跳过，若工作区内没有任何可恢复标签则保留当前会话不作变更。

### Testing

- `jq empty App/Localizable.xcstrings` 与 `git diff --check` 通过。
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Harbor.xcodeproj -scheme Harbor -configuration Release -derivedDataPath .build/WorkspaceDerivedData CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= build` 成功，输出 `** BUILD SUCCEEDED **`。

### Notes

- `App/Workspaces/WorkspaceStore.swift`：定义可版本化、原子持久化的工作区快照和安全恢复逻辑。
- `App/Workspaces/WorkspaceManagerView.swift`：提供命名保存、恢复确认、删除及缺失主机状态提示。
- `App/UI/ContentView.swift`：注入工作区存储，增加全局入口和工作区管理表单；拆分视图修饰器以避免 SwiftUI 编译器类型推导超时。
- `App/UI/SessionTabsView.swift`：在会话标签栏加入工作区入口并暴露管理回调。
- `App/Localizable.xcstrings`：补充工作区中英文文案。
- `progress.md`：追加本轮实现、验证与回滚信息。
- 回滚方式：执行 `git restore --source=22999e4 -- App/UI/ContentView.swift App/UI/SessionTabsView.swift App/Localizable.xcstrings && rm -rf App/Workspaces && xcodegen generate`；`progress.md` 按追加规范保留历史记录。

## 2026-07-12 - Task: 完善录制检索与高风险命令确认

### What was done

- 为会话录制回放增加流式文本检索、命中列表和按命中位置跳转，避免加载整份录制文件；结果最多保留前 200 条。
- 为命令栏、批量执行、快捷命令和脚本库接入统一的高风险命令识别与执行前确认，覆盖递归删除、磁盘格式化/写盘、重启关机、服务停启、强制终止、Docker 清理和 Kubernetes 删除等操作。
- 汇总工作区、目录对比同步、监控告警、录制检索与命令确认的使用边界和操作方式。

### Testing

- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`（`HarborKit`）通过，341 项测试全部成功，包含新增高风险命令识别用例。
- `swift test`（`HarborMCP`）通过，15 项测试全部成功。
- `xcodegen generate` 成功；`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Harbor.xcodeproj -scheme Harbor -configuration Release -derivedDataPath .build/FeatureDerivedData CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= build` 成功，输出 `** BUILD SUCCEEDED **`。
- 未能建立桌面自动化连接，因此未执行可视化点击验收；功能已通过 Release 编译和单元测试验证。

### Notes

- `HarborKit/Sources/HarborKit/CommandRisk.swift`：定义高风险命令分类与检测规则。
- `HarborKit/Tests/HarborKitTests/CommandRiskTests.swift`：覆盖风险识别和常规命令不误报。
- `App/Recording/RecordingPlayer.swift`：增加分块检索、命中预览和位置跳转支持。
- `App/UI/RecordingPlayerView.swift`：增加回放窗口搜索栏、命中切换和跳转菜单。
- `App/UI/CommandStripView.swift`、`App/UI/BatchExecView.swift`、`App/UI/QuickCommandPanelView.swift`、`App/UI/ScriptLibraryView.swift`：在执行风险命令前展示明确确认。
- `README.md`、`docs/workflows.md`：补充五项运维工作流的入口、边界和使用说明。
- `progress.md`：追加本轮实现、验证和回滚信息。
- 回滚方式：执行 `git restore --source=22999e4 -- App/Recording/RecordingPlayer.swift App/UI/RecordingPlayerView.swift App/UI/CommandStripView.swift App/UI/BatchExecView.swift App/UI/QuickCommandPanelView.swift App/UI/ScriptLibraryView.swift README.md`，再删除 `HarborKit/Sources/HarborKit/CommandRisk.swift`、`HarborKit/Tests/HarborKitTests/CommandRiskTests.swift` 和 `docs/workflows.md` 后运行 `xcodegen generate`；`progress.md` 按追加规范保留历史记录。

## 2026-07-12 - Task: 冻结 Harbor 1.1.0 正式发布源码

### What was done

- 将包含五项运维工作流增强的用户可见版本从 1.0.0 升级为 1.1.0，并将构建号递增至 2。
- 核对 Developer ID 签名身份、`HarborNotary` Keychain 公证配置和正式发布工具链，确认可以执行后续签名、公证、带图标 DMG 打包与安装流程。

### Testing

- `security find-identity -v -p codesigning` 确认 `Developer ID Application: Wenhua Qiu (YNU9T8LCUR)` 有效。
- `xcrun notarytool history --keychain-profile HarborNotary --output-format json` 成功，最近 Harbor App 与 DMG 公证记录均为 `Accepted`。
- `xcodegen generate`、HarborKit 341 项测试、HarborMCP 15 项测试和 Harbor Release 构建均已在本轮发布前验证通过。

### Notes

- `project.yml`：升级 Marketing Version 到 1.1.0，Build 到 2。
- `progress.md`：追加本轮发布冻结、凭据和验证信息。
- 回滚方式：执行 `git restore --source=22999e4 -- project.yml`，然后运行 `xcodegen generate`；`progress.md` 按追加规范保留历史记录。

## 2026-07-12 - Task: 修复远程文件面板空列表

### What was done

- 修复远程目录枚举协议：`find` 现在输出数字 UID/GID（`%U` / `%G`），与客户端仅接受数字所有者字段的解析器一致。
- 此前服务器返回 `root` 等用户名/组名时，命令虽然成功但所有记录均被解析器跳过，最终表现为已连接但文件列表为空。
- 将修复版本升级为 Harbor 1.1.1（build 3），用于替换已安装的 1.1.0。

### Testing

- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`（`HarborKit`）通过，341 项测试全部成功。
- 使用当前已连接服务器的复用 SSH 通道执行修复后的枚举字段检查：返回 `entries=16 invalidNumericOwnerFields=0`。
- `git diff --check` 通过。

### Notes

- `HarborKit/Sources/HarborKit/RemoteFiles.swift`：远端目录协议改为输出数字所有者 ID。
- `HarborKit/Tests/HarborKitTests/RemoteLsParserTests.swift`：更新目录协议的精确命令断言。
- `project.yml`：升级 Marketing Version 到 1.1.1，Build 到 3。
- `progress.md`：追加根因、验证与回滚信息。
- 回滚方式：执行 `git restore --source=f613dd9 -- HarborKit/Sources/HarborKit/RemoteFiles.swift HarborKit/Tests/HarborKitTests/RemoteLsParserTests.swift project.yml`，然后运行 `xcodegen generate`；`progress.md` 按追加规范保留历史记录。
## 2026-07-12 - Task: 准备 Harbor 公开开源仓库

### What was done

- 将项目首页改为中文、English、日本語三语入口，统一说明核心能力、构建、测试、文档与贡献方式。
- 新增 MIT 许可证，明确 Harbor 对外开源许可。

### Testing

- 已核对 README 的三语锚点、仓库内文档链接和 LICENSE 链接均指向存在的文件；本轮仅修改文档与许可证，未改变应用代码。

### Notes

- `README.md`：重写为三语项目首页，加入图标、功能概览、快速开始、测试与目录说明。
- `LICENSE`：新增 MIT 开源许可证（Copyright 归属为 Harbor contributors）。
- `progress.md`：追加本轮开源准备记录。
- 回滚方式：有 Git 基线时执行 `git revert <本轮提交>`；推送前可删除新增 `LICENSE` 并从上一提交恢复 `README.md` 与 `progress.md`。
## 2026-07-12 - Task: 从公开仓库移除官网源码并强化开源首页

### What was done

- 将官网源码目录加入忽略规则，避免后续提交时进入 Harbor 的公开源码仓库。
- 强化三语 README 的首屏信息层次，增加平台、技术栈和许可证标识，以及终端、文件、监控和工作流的能力总览。

### Testing

- 待完成公开历史重写与远端推送后，复核 GitHub `main` 不包含 `website/`，并确认 README 与许可证可访问。

### Notes

- `.gitignore`：忽略独立部署的 `website/` 源码目录。
- `README.md`：更新开源项目首屏视觉、定位文案和功能总览。
- `progress.md`：追加本轮隔离官网源码与 README 优化记录。
- 回滚方式：公开历史重写前的本地分支保存在 `pre-open-source-cleanup` 标签；如需恢复可将该标签强制推回 `main`。官网文件只从 Git 跟踪中移除，保留在本地工作区。
