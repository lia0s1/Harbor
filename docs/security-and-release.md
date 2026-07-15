# 安全边界与发布流程

## SSH 输入与主机密钥

- Harbor 只把结构化字段转换为系统 `/usr/bin/ssh` 的参数，不通过本机 shell 拼接执行。
- 主机的“额外 SSH 参数”采用允许列表。允许诊断、压缩、超时、算法和认证偏好等客户端选项；会执行本地命令、加载提供程序、改写配置来源、绕过主机密钥校验、建立控制套接字或改变目标/转发的参数会被拒绝。
- 密码/一次性密码流程不得自动接受新主机密钥。首次连接必须先由用户在交互式终端确认指纹，之后自动化步骤只接受 `known_hosts` 中已存在且匹配的密钥。
- MCP 默认不公开任何远程工具。启动时必须设置 `HARBOR_MCP_ALLOWED_HOSTS` 为逗号分隔的已保存主机名称或主机名，才能使用只读工具；`run_command` 还要求 `HARBOR_MCP_ENABLE_RUN_COMMAND=1`，`write_file` 还要求 `HARBOR_MCP_ENABLE_WRITE_FILE=1`。MCP 只接受唯一匹配的已保存 SSH 主机，并沿用相同的参数校验与严格主机密钥策略；不接受任意临时目标。它使用独立的摘要型 ControlMaster 命名空间，并忽略会破坏非交互管道的 `-n`、`-N`、PTY 和调试输出开关。

  ```sh
  # 只允许读取 Harbor 中名为 production 的主机
  HARBOR_MCP_ALLOWED_HOSTS=production harbor-mcp

  # 仅在受信任的 MCP 宿主中额外开放命令与文件写入
  HARBOR_MCP_ALLOWED_HOSTS=production \
    HARBOR_MCP_ENABLE_RUN_COMMAND=1 \
    HARBOR_MCP_ENABLE_WRITE_FILE=1 \
    harbor-mcp
  ```

## 认证与 RDP

- “安装公钥并验证登录”只使用已有本机公钥。密码不进入 argv 或明文临时文件；ASKPASS 可执行文件本身不含秘密。未知或变更的主机指纹会在密码发送前失败。
- Harbor 只追加当前用户的 `authorized_keys` 并验证密钥登录，不修改、重载或放宽服务器 `sshd_config`。没有现有密钥时，用户需在密钥设置中显式生成且必须填写私钥口令。
- RDP 使用主机配置中的实际端口。FreeRDP 采用严格证书拒绝策略，密码经 stdin 提交；不受信任、自签名但未受信任、过期或主机名不匹配的证书不会被自动忽略。

## 本地数据与历史

- `Application Support/Harbor` 目录收紧为 `0700`，其中 JSON 数据文件收紧为 `0600`。保存先写入同目录 `0600` 暂存文件再原子替换，不存在“先发布为 0644、随后 chmod”的可读窗口。
- TOTP 密钥保存在 Keychain。删除主机时同步删除对应 TOTP 项，避免 UUID 冲突或遗留秘密被误关联。
- 命令历史和远程路径历史默认只保存在当前运行的内存中。只有用户在“设置 → 隐私”明确开启后才写入 UserDefaults；关闭或点击清除会删除已有持久化历史。
- 导入包限制为 16 MB、最多 10000 台主机和 10000 条命令，并校验版本、重复 ID、协议字段及 SSH 参数。冲突 ID 不会继承已有主机的 TOTP 关联。

## 远程文件编辑

文件面板用 GNU `find` 的固定宽度 NUL 分隔协议读取目录元数据；文件名可包含换行或看似 `ls` 行的文本，仍只会对应一个条目。编辑器下载前后都会核对远程文件版本。保存时先上传到目标目录的唯一临时文件，再次比较原版本，最后用同文件系统 `rename` 原子替换。若远端在此期间发生变化，Harbor 停止保存并报告冲突；外部编辑器的未同步本地副本会保留。为避免原子替换把链接本身覆盖掉，符号链接不进入远程编辑流程。

MCP 的 `write_file` 同样使用目标目录内的唯一临时文件和原子 `rename`，原样保留 UTF-8 字节且不擅自补换行，并拒绝替换符号链接。MCP 单条 JSON 请求上限 8 MiB、`hosts.json` 4 MiB、进程 stdin/stdout 各 4 MiB、stderr 1 MiB；任一流超限都会终止对应进程并返回工具错误。

## 终端内容边界

远端 OSC 52 剪贴板写入默认不执行；需要由调用方显式授权。OSC/APC、Kitty graphics 和 Sixel 解析均设置输入、尺寸与内存上限，超限序列会被丢弃而不是持续占用内存。

`SwiftTerm-local` 作为普通 vendored 源码由 Harbor 根仓库直接跟踪，不保留嵌套 `.git`/gitlink。Harbor 默认引用它时不解析任何远端 Swift Package。Termcast、Benchmark 与 DocC 工具只有在设置 `SWIFTTERM_INCLUDE_DEVELOPMENT_TARGETS=1` 后才进入包图，且直接依赖固定到 exact 版本；发布脚本会拒绝重新出现的嵌套仓库。

## 可发布构建

普通本机构建运行 `./build.sh`，使用 ad-hoc 签名，不是可公开分发产物。公开发布必须满足：

1. 审阅需要发布的源码，提交到 Git，并保持工作区没有未提交或未跟踪的源码。发布脚本会拒绝没有 `HEAD` 或工作区不干净的发布请求，并输出该次发布对应的 Git revision。
2. 在 Keychain 中保存 Apple 公证凭据（密码只在 `notarytool` 的安全提示中输入）：

   ```sh
   xcrun notarytool store-credentials HarborNotary \
     --apple-id <APPLE_ID> --team-id <YOUR_TEAM_ID>
   ```

   也可以使用 App Store Connect Team API Key；`ISSUER_ID`、`KEY_ID` 和私钥路径只在本机凭据初始化命令中提供，不写入仓库：

   ```sh
   xcrun notarytool store-credentials HarborNotary \
     --key <AUTH_KEY_PATH> --key-id <KEY_ID> --issuer <ISSUER_ID>
   ```

3. 运行完整发布门禁：

   ```sh
   NOTARY_PROFILE=HarborNotary ./scripts/release.sh \
     --zip-output "$HOME/Desktop/Harbor.zip" \
     --dmg-output "$HOME/Desktop/harbor installer.dmg" \
     --install
   ```

脚本会生成 arm64/x86_64 通用 Release archive，使用环境变量 `TEAM_ID` 指定的 Developer ID 签名并核对 hardened runtime 与签名团队。它先公证并装订 App，再生成 ZIP；随后先创建可写 DMG、在卷根写入 Finder 自定义图标标志及隐藏的 `.VolumeIcon.icns`，压缩为最终 DMG 后再签名、公证和装订。最终 `.dmg` 文件本身也会写入 Harbor Finder 图标并重新通过签名、公证 ticket 与 Gatekeeper 评估。只有全部成功才会发布最终 ZIP/DMG；同名旧产物与旧安装会移入 `/private/tmp` 作为可逆备份。`--install` 安装的正是已经通过上述门禁的 App。

后续重新发布必须走上述流程，不能用普通 `build.sh` 产物覆盖。公证凭据只通过 Keychain profile 使用，不写入脚本、仓库或命令行秘密参数。
