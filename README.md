# Harbor

<p align="center">
  <img src="App/Assets.xcassets/AppIcon.appiconset/icon_128x128.png" width="112" alt="Harbor app icon">
</p>

<p align="center"><strong>The native control room for your infrastructure.</strong></p>

<p align="center">
  A focused macOS SSH workspace for people who live in terminals,<br>
  move real files, and need to see what every server is doing.
</p>

<p align="center">
  <a href="#中文">中文</a> · <a href="#english">English</a> · <a href="#日本語">日本語</a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS%2026%2B-111827?style=for-the-badge&logo=apple&logoColor=white" alt="macOS 26 or later">
  <img src="https://img.shields.io/badge/built%20with-SwiftUI-F05138?style=for-the-badge&logo=swift&logoColor=white" alt="Built with SwiftUI">
  <img src="https://img.shields.io/badge/license-MIT-16A34A?style=for-the-badge" alt="MIT License">
</p>

> [!NOTE]
> Harbor targets macOS 26 (Tahoe) or later and requires Xcode 26 to build. It is a native SwiftUI application, not a web wrapper.

---

<table>
  <tr>
    <td width="25%" align="center"><strong>⌘ Terminal</strong><br><sub>Persistent SSH tabs,<br>search, shortcuts, broadcast.</sub></td>
    <td width="25%" align="center"><strong>⇄ Files</strong><br><sub>SFTP workspace with<br>safe remote editing.</sub></td>
    <td width="25%" align="center"><strong>◌ Monitor</strong><br><sub>Agentless Linux insight<br>over your existing SSH link.</sub></td>
    <td width="25%" align="center"><strong>⌁ Workflow</strong><br><sub>Hosts, tunnels, commands,<br>and everyday operations.</sub></td>
  </tr>
</table>

---

## 中文

**Harbor** 是面向 macOS 的原生 SSH 工作台。它把主机管理、标签页终端、远程文件、无代理监控与常用命令收在一个简洁的 SwiftUI 应用里：少切换窗口，多完成工作。

### 亮点

- **主机与连接管理** — 搜索、标签分组、快速连接、导入 `~/.ssh/config`，并支持本地、远程和动态端口转发。
- **真正的终端标签页** — 基于 SwiftTerm 与系统 `ssh`，保留滚动缓冲和运行中的会话；支持快捷键、查找和广播输入。
- **远程文件面板** — 目录树、上传下载、批量操作、文本编辑，以及避免静默覆盖的并发修改检测。
- **无代理监控** — 复用现有 SSH 会话读取 Linux 的 CPU、内存、磁盘、网络、进程和延迟信息，无需在服务器安装代理。
- **隐私与安全默认值** — 主机数据采用受限权限存储；TOTP 放入 Keychain；命令与远程路径历史默认不落盘；危险 SSH 参数会被拒绝。
- **原生 macOS 体验** — Liquid Glass 外观、深浅色模式、中文/English 即时切换、终端主题与背景自定义。

### 快速开始

```sh
git clone https://github.com/<your-account>/Harbor.git
cd Harbor
brew install xcodegen
./build.sh open
```

也可以在 Xcode 中构建：

```sh
xcodegen generate
open Harbor.xcodeproj
```

### 测试

```sh
cd HarborKit
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

完整的构建、公证和安装流程见 [安全与发布说明](docs/security-and-release.md)，日常操作说明见 [工作流文档](docs/workflows.md)。

---

## English

**Harbor** is a native macOS SSH workspace. It brings host management, tabbed terminals, remote files, agentless monitoring, and reusable commands into one focused SwiftUI app—less window switching, more getting things done.

### Highlights

- **Host and connection management** — search, tags, quick connect, `~/.ssh/config` import, and local, remote, or dynamic port forwarding.
- **Real terminal tabs** — built on SwiftTerm and the system `ssh`; live sessions and scrollback survive tab switches, with find, shortcuts, and broadcast input.
- **Remote file workspace** — directory tree, uploads, downloads, batch operations, text editing, and conflict checks that prevent silent overwrites.
- **Agentless monitoring** — reuse the existing SSH connection to inspect Linux CPU, memory, disks, network, processes, and latency. No server-side agent required.
- **Private and safe by default** — restrictive local data permissions, Keychain-backed TOTP, opt-in command/path history, and strict SSH option validation.
- **Native macOS polish** — Liquid Glass, light and dark appearance, live Chinese/English switching, and customizable terminal themes and backgrounds.

### Quick start

```sh
git clone https://github.com/<your-account>/Harbor.git
cd Harbor
brew install xcodegen
./build.sh open
```

Or generate the project and open it in Xcode:

```sh
xcodegen generate
open Harbor.xcodeproj
```

### Test

```sh
cd HarborKit
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

See [Security and release](docs/security-and-release.md) for signed-release guidance and [Workflows](docs/workflows.md) for everyday operations.

---

## 日本語

**Harbor** は、macOS 向けのネイティブ SSH ワークスペースです。ホスト管理、タブ型ターミナル、リモートファイル、エージェント不要の監視、よく使うコマンドを、ひとつの SwiftUI アプリにまとめました。ウィンドウを切り替える時間を減らし、運用そのものに集中できます。

### 主な機能

- **ホストと接続の管理** — 検索、タグ、クイック接続、`~/.ssh/config` の読み込み、ローカル／リモート／動的ポートフォワーディング。
- **本格的なターミナルタブ** — SwiftTerm とシステムの `ssh` を使用。タブを切り替えてもセッションとスクロールバックを保持し、検索・ショートカット・一括入力に対応。
- **リモートファイル操作** — ディレクトリツリー、アップロード／ダウンロード、一括操作、テキスト編集、上書きを防ぐ競合検出。
- **エージェント不要の監視** — 既存の SSH 接続を再利用して Linux の CPU、メモリ、ディスク、ネットワーク、プロセス、遅延を確認。サーバーへのエージェント導入は不要です。
- **安全な初期設定** — ローカルデータの権限を制限し、TOTP は Keychain に保存。コマンドとパスの履歴は既定で保存せず、SSH オプションを厳格に検証します。
- **macOS らしい UI** — Liquid Glass、ライト／ダークモード、中文／English の即時切替、ターミナルテーマと背景のカスタマイズ。

### はじめかた

```sh
git clone https://github.com/<your-account>/Harbor.git
cd Harbor
brew install xcodegen
./build.sh open
```

テストの実行:

```sh
cd HarborKit
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

署名付きリリースの手順は [Security and release](docs/security-and-release.md)、日常的な使い方は [Workflows](docs/workflows.md) を参照してください。

---

## Project

| Area | Details |
| --- | --- |
| Platform | macOS 26 (Tahoe) or later |
| Language | Swift / SwiftUI |
| Terminal | Vendored [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) + system OpenSSH |
| Build | Xcode 26 + XcodeGen |
| License | [MIT](LICENSE) |

### Repository layout

```text
App/             SwiftUI application, terminal, files, monitoring, and UI
HarborKit/       Side-effect-free core logic and unit tests
HarborMCP/       MCP integration
SwiftTerm-local/ Vendored terminal library
scripts/         Build, icon, and signed-release tooling
docs/            Security, release, workflow, and performance documentation
```

## Contributing

Issues and pull requests are welcome. Please keep changes focused, include tests where practical, and avoid committing build products, signing material, or local configuration.

## License

Harbor is released under the [MIT License](LICENSE). Third-party notices remain with their respective components.
