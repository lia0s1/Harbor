# Harbor 云同步设计方案

> 版本：v2（2026-10-14）。状态：文件夹同步路线，实现中。
> v1 → v2 修订：**载体从 NSUbiquitousKeyValueStore 改为同步目录 JSON 文件**（用户没有 Apple 开发者账号，KV 所需的 iCloud entitlement + Developer ID provisioning profile 走不通，见 §3.2 决策记录）。合并算法、tombstone、envelope schema、隐私边界不变。
> 前置摸底：本文基于 v1.5.0 代码现状（`App/JSONFileStore.swift`、`App/HostStore.swift`、`App/HostFolderStore.swift`、`App/QuickCommandStore.swift`、`App/Scripts/ScriptStore.swift`、`App/Workspaces/WorkspaceStore.swift`、`App/TOTP/TOTPStore.swift`、`App/HistoryPrivacy.swift`、`App/UI/HostExportImport.swift`、`project.yml`）。

---

## 1. 目标

- 多台 Mac 之间自动同步用户的核心配置数据：主机、文件夹、快捷命令、脚本、工作区。
- Apple 原生路线，不自建服务（明确不抄 FinalShell 的 HTTP 自建 + 邮箱通道）。
- 同步对现有存储层零侵入或最小侵入：`JSONFileStore` 的原子写 / 0600 / corrupt-aside 语义不变，本地永远是 source of truth，云只是副本合并通道。
- 敏感数据边界清晰：密码、私钥、TOTP、历史、录制默认不出本机。
- 没登录 iCloud 的用户体验不降级：功能静默停用，本地一切照旧。

非目标（本期不做）：

- iOS / iPadOS 端（没有 Harbor iOS 客户端，CloudKit 跨端价值为零）。
- 多用户共享 / 团队协作（CloudKit share）。
- 会话录制、命令历史、主题文件、GeoIP 缓存的同步。

## 2. 现状摸底结论（设计的输入）

| 数据 | 位置 | 量级 | 同步价值 | 敏感性 |
|---|---|---|---|---|
| hosts.json | App Support/Harbor/ | 几 KB ~ 几十 KB | 高（核心） | 中：主机名/用户名/密钥路径；`notes` 自由文本可能敏感；**无密码**（密码走 askpass 交互式输入，不落盘） |
| folders.json | 同上 | < 几 KB | 高（hosts.folderID 引用它） | 低 |
| commands.json | 同上 | 几 KB ~ 几十 KB | 高 | 中高：命令模板可能写入明文口令（导出文案已承认这点） |
| scripts.json | 同上 | 可达几十 KB | 中 | 中：脚本内容可能含内网地址、token |
| workspaces.json | 同上 | 几 KB | 中 | 低：只存 hostID 引用 |
| TOTP secret | Data Protection Keychain，`WhenUnlockedThisDeviceOnly` | 极小 | 有需求 | **高：本机锁死，物理出不了本机** |
| 私钥文件 | ~/.ssh/ | — | 有需求 | **高：绝不能进云** |
| 命令/路径历史 | UserDefaults，且**默认不落盘**（HistoryPrivacy） | — | 低 | 高 → 坚决不同步 |
| 会话录制 | 本地文件 | 大 | 低 | 高 → 坚决不同步 |
| GeoIP 缓存 / 系统信息缓存 | 本地 | — | 零（可再生） | 低 → 不同步 |
| .harbortheme 主题 | App Support/Harbor/Themes/ | 小 | 低 | 低 → 本期不同步，二期可选 |
| 隧道规则 | 无独立持久化，`PortForward` 在 `SSHHost.portForwards` 内 | — | — | 随 hosts.json 自动覆盖 |

关键技术事实：

- `JSONFileStore<Element>` 是所有持久化的唯一入口：`items` 是 `@Published private(set)`，一切变更收敛到 `save()`（编码 → 串行后台原子写）。**这是同步引擎唯一的挂钩点**——不需要改任何业务代码，在基类加一个变更回调即可覆盖全部五个 store。
- 模型层 `SSHHost` / `HostFolder` / `QuickCommand` 没有 `updatedAt`；`ScriptSnippet` 有 `createdAt`，`Workspace` 有 `updatedAt`。→ 同步元数据（修改时间戳、tombstone）**不进现有模型**，由同步层在 envelope 里维护，避免污染编解码和导出格式。
- `HostExportImport.merge` 已有可复用的合并思想：按 ID 合并、`sameConnectionIdentity` 防 ID 串号（同 ID 不同连接目标 → 重新分配 ID）。同步合并器直接借用 `sameConnectionIdentity` 规则。
- `project.yml`：无 entitlements 文件，`ENABLE_APP_SANDBOX: NO`，Hardened Runtime 开，Debug 用 ad-hoc（`CODE_SIGN_IDENTITY: "-"`），Release 用 Developer ID 直发，不进 App Store。

## 3. 载体决策

### 3.1 候选对比（v1 评审记录）

| 维度 | NSUbiquitousKeyValueStore | iCloud Drive（ubiquity container） | CloudKit 私有库 |
|---|---|---|---|
| 容量 | 1 MB 总量 / 单 key 1 MB | 用户 iCloud 配额 | 大 |
| 数据适配度 | **全量 envelope 约 50–300 KB，远低于上限** | 合适 | 大材小用 |
| 合并控制 | 自己实现（本文第 5 节） | NSFileVersion 冲突 + 自己合并 | per-record + change token，最强 |
| 工程成本 | **低**：无 container、无文件协调器、无 subscription | 中：NSFileCoordinator/Presenter、冲突副本处理、下线文件驱逐 | 高：container、schema、subscription、错误/限流矩阵 |
| 文件可见性 | 不可见（用户无法误删） | **Finder 可见，用户可误删/改坏** | 不可见 |
| Developer ID 直发 | 支持（`ubiquity-kvstore-identifier` entitlement + Developer ID provisioning profile） | 支持（同前置） | 支持（同前置，但配置面更大） |
| 无 iCloud 账户 | 静默退化为本地 KV，天然降级 | 需自己判 ubiquityIdentityToken | 需处理 account status |
| 延迟 | 秒级到分钟级，不保证实时 | 类似 | 最快 |

### 3.2 决策：同步目录 JSON 文件（v2 修订）

**决策记录**：v1 选了 NSUbiquitousKeyValueStore；动工前确认用户**没有 Apple 开发者账号**，KV/iCloud entitlement 需要付费开发者计划的 provisioning profile 才能在 Developer ID 直发包里生效——路线整体死亡，不做 spike 了。CloudKit 同理（container 也要 entitlement）。iCloud Drive ubiquity container（`NSFileCoordinator` 那套）同样需要 iCloud entitlement。

剩下唯一零账号依赖的载体：**普通文件 + 用户已有的文件同步通道**。

- 默认目录：`~/Library/Mobile Documents/com~apple~CloudDocs/Harbor/`（iCloud Drive 的用户可见区）。**非沙盒 app（ENABLE_APP_SANDBOX=NO）直接读写该路径，不需要任何 entitlement**——ubiquity container 才要，CloudDocs 用户区不要。
- 用户可在设置里改选**任意目录**：Dropbox / Syncthing / NAS 挂载点 / 普通本地目录（仅备份不跨机）都行，载体与合并逻辑彻底解耦。
- 同步文件：`<目录>/sync-envelope.json`，五个集合合并在**一个文件**里（原 KV 方案是每集合一个 key；单文件让「读-合并-写」天然原子，避免五 key 之间的撕裂状态）。
- 写入：临时文件 + rename 原子替换（与 `JSONStorePersistence` 同一模式），0600。
- 外部变更监听：`DispatchSource` 文件系统事件监听**目录**（不是文件——iCloud 用 rename 替换文件，fd 级监听会丢），去抖 1s 后走一次合并循环；按内容 hash 抑制自己写入引发的回声。
- iCloud Drive 目录不存在（未登录 iCloud）→ 设置页显示「未检测到 iCloud Drive，请选择其他同步目录」+ 目录选择器；功能不报错不崩溃。
- 错误语义：同步文件**存在但解析失败**时中止本轮合并、绝不覆写（防坏文件被本地覆盖丢数据），设置页报错并允许用户手动删除重来。

v1 放弃的「可见即攻击面」论点在 v2 重新权衡：可见性换来零账号门槛与载体自由；误删/改坏由「解析失败中止 + 本地永远是 source of truth + 空 envelope 不盖满库（§5.5）」兜底——最坏情况是重新全量推一份。

明确放弃的方案（v1 结论保留）：CloudKit 仍列为二期演进路径（envelope 已 record 化，可平移 CKRecord）；entitlement 类载体在用户有开发者账号前一律不考虑。

### 3.3 降级路径

| 场景 | 行为 |
|---|---|
| 未登录 iCloud（默认目录不存在）且未选自定目录 | 同步开关旁显示「未检测到 iCloud Drive，请选择其他同步目录」；本地功能零影响 |
| 自定目录被卸载/删除（NAS 掉线、Dropbox 退出） | 读写失败 → 状态置「不可用」+ lastError；本地数据完整保留；目录恢复后下一轮合并自动继续 |
| 同步文件损坏（同步通道写了一半、用户改坏） | 解析失败 → 中止合并、不覆写，设置页显示错误与文件路径；用户确认后可删文件重新首同步 |
| 用户关闭同步开关 | 停止读写与监听，本地数据不动；云端残留文件提供「删除云端同步数据」按钮，不自动删 |
| envelopeVersion 高于本地认识 | 只读合并不写回（防旧版覆盖新版格式），设置页提示升级 |

## 4. 同步范围与禁区

### 4.1 同步（默认全开，可按集合逐项关闭）

| 集合 | envelope 字段 | 说明 |
|---|---|---|
| hosts | `hosts` | 含 `portForwards`（隧道规则随主机走）、`osID/osName` |
| folders | `folders` | 必须先于 hosts 合并（引用完整性） |
| quick commands | `commands` | 文案明确警告：命令模板可能含口令 |
| scripts | `scripts` | 同上警告 |
| workspaces | `workspaces` | 只含 hostID 引用，天然轻 |

设置页提供五个独立 Toggle + 一个子开关：

- **「不同步主机备注（notes）」**：默认**开**（即默认剥离 notes）。notes 是自由文本，是最可能写入敏感信息的字段；同步时 envelope 里该字段置空串，合并时空串不覆盖本地非空（见 5.4 字段规则）。这是唯一的字段级开关，其它集合不拆字段。

### 4.2 坚决不同步

| 数据 | 原因 |
|---|---|
| 私钥文件（~/.ssh/…） | 不可挽回的泄密面；`identityFile` 只同步路径字符串，密钥本身用户自行分发（ssh-copy-id / 手动拷贝） |
| 命令/路径历史 | 与 `HistoryPrivacyPreference` 的「默认不落盘」隐私承诺一致——不落盘的东西更不能上云 |
| 会话录制 | 同上，且体积大 |
| GeoIP 缓存、系统信息缓存 | 可再生数据 |
| recentHostIDs（最近连接） | 本机使用痕迹，隐私等价于历史 |
| `.harbortheme` 主题文件 | 本期不同步（二期可选：它们是自包含文件，适合 iCloud Drive 而非 KV） |
| App 外观/终端字体等 `@AppStorage` 设置 | 与本机硬件/屏幕强相关；KV 同步 UserDefaults 是另一套机制，本期不做 |

### 4.3 TOTP：维持本机锁死（v2 本期不做钥匙串同步）

现状：`TOTPStore` 用 `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`——该属性在 Keychain 层物理锁死本机，**任何文件级同步方案都够不到它**，这是正确的默认。

v1 曾设计「通过 iCloud 钥匙串同步 TOTP 密钥」开关（`kSecAttrSynchronizable` 迁移方案，见 v1 存档）。**v2 本期不做**：TOTP secret 一律不进 envelope、不进同步目录，保持 `ThisDeviceOnly`。若未来有需求，v1 的迁移语义设计仍然成立，可单独立项。

## 5. 数据流与冲突合并算法

### 5.1 Envelope schema（单文件 `sync-envelope.json`，五集合合并其中）

```json
{
  "envelopeVersion": 1,
  "writerDeviceID": "A1B2-…-stable-per-install",
  "writtenAt": "2026-10-14T08:30:00.000Z",
  "devices": { "A1B2-…": "2026-10-14T08:30:00.000Z" },
  "folders": {
    "orderSnapshot": ["<id1>", "<id2>"],
    "orderModifiedAt": "2026-10-14T08:30:00.000Z",
    "orderDeviceID": "A1B2-…",
    "records": [
      {
        "id": "<uuid>",
        "modifiedAt": "2026-10-14T08:25:11.000Z",
        "deviceID": "A1B2-…",
        "deletedAt": null,
        "payload": { "…HostFolder 的全部现有 JSON 字段…" }
      }
    ]
  },
  "hosts": { "…同结构…" },
  "commands": { "…同结构…" },
  "scripts": { "…同结构…" },
  "workspaces": { "…同结构…" }
}
```

要点：

- **payload 就是现有 Codable 模型的 JSON**——`HostStoreCodec`/`QuickCommandStoreCodec` 的编解码直接复用（它们已是 tolerant decode，缺字段给默认值，天然向前兼容）。模型不加任何同步字段。
- 同步元数据（`modifiedAt`/`deletedAt`/`deviceID`）只在 envelope 的 record 包装层，不进模型。tombstone 的 `payload` 为 null。
- `orderSnapshot` 单独携带数组顺序（hosts 手排顺序、folders 的 order、commands 组内顺序都是「集合级」状态，record 级合并管不到），用独立的 `(orderModifiedAt, orderDeviceID)` 做 LWW。
- `devices` 记录见过的设备与最后写入时间，设置页显示设备数；30 天未见面的条目随 tombstone 一起 GC。
- `envelopeVersion` 用于将来 schema 演进；**收到高于本地认识的版本：只读合并不写回**（防旧版覆盖新版格式）。
- `writerDeviceID`：安装时生成、存 UserDefaults 的稳定 UUID，用于冲突 tiebreak 和调试。
- 本地侧另有 `App Support/Harbor/sync-state.json`（不进同步目录）记录每条 record 的 `(modifiedAt, deviceID, deletedAt, contentHash)` 与顺序快照，用于感知「哪条变了 / 哪条被删了」——store 模型本身没有 updatedAt，删除只能靠对账发现。

### 5.2 本地侧挂钩（唯一改动点）

`JSONFileStore` 增加一个可选的变更观察者：

```swift
/// 每次内存态变更（save 前的 items 快照）通知同步引擎。
/// 由 SyncEngine 注入；store 本身不认识 iCloud。
var onItemsChanged: (([Element]) -> Void)?
```

五个 store 的 `add/update/upsert/delete/replaceAll/append/duplicate/move` 全部收敛到 `save()`，所以在 `save()` 头部（或 items 赋值后）回调一次即可全覆盖。回灌路径（远端 → 本地）调 `replaceAll(with:)` 时**不触发**该回调（用标志位或专用入口 `applyRemote(_:)` 区分），避免本地→云→本地的回声循环。

### 5.3 合并器（纯函数，放 HarborKit）

```swift
public enum SyncMerger {
    /// 输入本地与远端 collection，输出合并结果：
    /// - merged: 新的权威 collection（双方都收敛到它）
    /// - orderedItems: 落地用的存活 payload（按合并后顺序）
    /// - localNeedsApply: 本地需要 applyRemote 时为 true
    /// - remoteNeedsWrite: 远端落后，需要回写文件时为 true
    public static func merge<Payload: Codable & Sendable>(
        local: SyncCollection<Payload>,
        remote: SyncCollection<Payload>,
        now: Date,
        preserveNonEmptyNotes: Bool
    ) -> SyncMergeResult<Payload>
}
```

算法（按 record 处理）：

1. **键集合并**：取两边 record id 的并集。
2. **同 id 决策**，比较 `(modifiedAt, deviceID)` 二元组（字典序，deviceID 仅在时间戳完全相等时决胜，保证时钟偏移下仍确定性收敛；二元组也完全相等时取远端——同设备同秒写入只可能是落地修正差异，取远端保证所有设备收敛到文件内容）：
   - 一边没有 → 取另一边；
   - 两边都有 → 取二元组大者；
   - 胜者 `deletedAt != nil` → 该 id 结果为 tombstone（逻辑删除，payload 置空）；
   - 胜者 `deletedAt == nil` → 该 id 结果为胜者的 payload。
3. **同 id、同 timestamp、不同连接目标的 hosts 特判**：复用 `HostExportImport.sameConnectionIdentity`——若两边 payload 连接身份（protocol+hostname+port+username+rdpDomain）不一致，说明是不同设备各自新建撞 ID（概率极低但导入功能会制造这种情况），**不互相覆盖**：远端记录重新分配新 id 并入。防止 A 机的 TOTP/会话挂到 B 机的同 id 不同主机上。
4. **顺序**：`orderModifiedAt` 大者的 `orderSnapshot` 为权威顺序；快照里没有的 id（新合并进来的）按 id 字典序追加到尾部；快照里多余的 id 丢弃。folders 的 `order` 字段在落地时按数组下标归一化（与 `HostFolderStore` 现状一致）。
5. **引用完整性**（落地前最后一步）：hosts 的 `folderID` 指向合并后 folder 集合里不存在的 id → 置 nil（与 `HostExportImport.merge` 一致）；workspaces 的 `hostIDs/tabs` 引用不存在的 host → 恢复时跳过（`WorkspaceStore.restore` 已有此语义，不改）。

### 5.4 字段规则

- **notes 剥离开关开启时**：写 envelope 前把 payload 的 `notes` 置空。合并时若胜者的 `notes` 为空且败者非空 → 保留败者的 notes（「空不覆盖非空」是本设计唯一的字段级特例，成本一行，收益是远端剥离版不会洗掉本地备注）。
- 其余字段一律 record 级 LWW。字段级合并不做：单用户多设备同时改同一台主机不同字段的概率极低，字段级合并的复杂度（每字段时间戳、三维 diff）不成比例。

### 5.5 删除传播与首次同步方向

- **删除 = tombstone**：本地 `delete(ids:)` 后，对应 id 在 envelope 里写入 `deletedAt: now` 的 tombstone，而不是移除记录。tombstone 与正常记录走同一套 LWW：后到的更晚 `modifiedAt` 记录可以「复活」条目（用户在另一台机重新建了同 id 的主机——主要发生在导入场景）。
- **tombstone 清理**：`deletedAt` 超过 30 天的 tombstone 在下一次写 envelope 时物理移除。30 天内未同步过的设备再上线会拿不回删除信息（条目复活）——接受这个权衡并在文案中不承诺「跨设备删除超过 30 天未开机的设备」。
- **首次同步方向判断**（防「空库覆盖满库」）：
  | 本地 | 云端 | 动作 |
  |---|---|---|
  | 空 | 空 | 无事，写一份空 envelope 占位 |
  | 空 | 有 | 直接拉取落地（本地没有可失去的东西） |
  | 有 | 空 | 直接推全量 |
  | 有 | 有 | 走 5.3 合并 |
  安全性来自合并语义本身：云端空 envelope 里**没有任何 tombstone**，合并对本地条目零影响；空覆盖满库只可能由 tombstone 造成，而 tombstone 只能由真实删除操作产生。

### 5.6 触发模型

| 时机 | 动作 |
|---|---|
| App 启动（同步已启用且目录可用） | 读 `sync-envelope.json`（不存在视为空远端）→ 5.3 合并 → 需要则 `applyRemote` 回灌 + 回写文件 |
| 本地任何 store 变更 | `onItemsChanged` → 防抖 **3 秒**（连续编辑合并成一次写）→ 读最新文件 → 逐集合重建 + 合并 → 写回。**「读-合并-写」而非盲写**，把多设备并发写的互相覆盖窗口收敛到一次合并循环 |
| 目录监听发现文件被外部改动（另一台机经 iCloud/Dropbox 落盘） | 去抖 **1 秒** → 读文件 → 内容 hash 等于自己上次写入则忽略（回声抑制）→ 否则合并 → 回灌 + 必要时回写 |
| App 变为活跃 | 轻量对账：比较文件 mtime / hash 与本地最后所见，不一致就走一次合并 |
| 退出 | 现有 `JSONStorePersistence.flush()` 不变；同步文件本身已在磁盘，不阻塞退出 |

**回灌不丢用户编辑态**的保证：`HostEditorView` 等编辑界面是 sheet 内编辑 draft、点保存才 `update()` 进 store 的模式；`applyRemote` 走 `replaceAll` 只替换 store 的 `items`，不影响 sheet 持有的 draft 副本。用户点保存时其变更作为一次新的本地变更进入下一轮合并（LWW，时间戳更新，必然赢）。需在实现时逐个确认编辑器确为 draft 模式；若发现 live-binding 的编辑面，回灌时跳过该 id 并在日志记录。

### 5.7 SwiftUI 无感刷新

`applyRemote` 调 `replaceAll(with:)` → `items` 是 `@Published` → 所有观察 store 的视图自动刷新，**不需要额外的刷新机制**。这是现状架构白送的收益。

## 6. 隐私边界与文案

设置页「云同步」tab 的固定文案要点：

1. 同步内容清单：主机（地址、用户名、端口、密钥**路径**、隧道规则）、文件夹、快捷命令、脚本、工作区。
2. 明确不同步：私钥本体、密码（Harbor 本就不存密码）、TOTP 密钥（本机锁死）、命令历史、会话录制、IP 归属地缓存。
3. 警告：快捷命令与脚本的正文是明文，若你把口令写进了命令模板，它会随之进入你的 iCloud 账户。建议用 `{参数}` 占位符在运行时输入口令。
4. 数据去向：用户选择的同步目录（默认 iCloud Drive 的 `~/Library/Mobile Documents/com~apple~CloudDocs/Harbor/`，可改 Dropbox/Syncthing/NAS 等任意目录）；Harbor 不经过任何自建服务器，数据出本机的范围完全由所选目录的同步通道决定。
5. 「关闭同步」语义：停止读写同步文件，本地数据不动；云端残留数据提供「删除云端同步数据」按钮（删 `sync-envelope.json`），不自动删。

## 7. 工程落地清单

### 7.1 签名与配置

**零改动**。文件夹同步路线不需要任何 entitlement：非沙盒 app 直接读写 `~/Library/Mobile Documents/com~apple~CloudDocs/` 用户区。App Sandbox 保持关闭，Hardened Runtime 不变，ad-hoc 签名的 Debug 构建功能同样可用（v1 KV 路线的最大卡点不复存在）。`App/Harbor.entitlements` 里已有的 kvstore 条目为空壳残留，可在发布前清理，不清理也无影响（无 provisioning profile 时被忽略）。

### 7.2 代码

| 动作 | 文件 | 说明 |
|---|---|---|
| 新增 | `HarborKit/Sources/HarborKit/SyncEnvelope.swift` | `SyncRecord`/`SyncCollection` Codable 模型 + `SyncMerger` 纯函数合并器（含 orderSnapshot、tombstone GC、notes 特例、无 Apple 框架依赖，可纯单测） |
| 新增 | `HarborKit/Tests/HarborKitTests/SyncMergerTests.swift` | 见 7.3 |
| 新增 | `App/Sync/CloudSyncEngine.swift` | @MainActor ObservableObject：注册五个 store、防抖推送、合并循环调度、状态机（disabled/unavailable/idle/syncing/error）暴露给 UI |
| 新增 | `App/Sync/SyncEnvelopeFile.swift` | 单文件五集合的 Codable 模型 + 容错日期编解码（小数秒 ISO8601，兼容整秒） |
| 新增 | `App/Sync/SyncStateStore.swift` | 本地 `sync-state.json`：每 record 的 `(modifiedAt, deviceID, deletedAt, contentHash)` + 顺序快照，0600 原子写 |
| 新增 | `App/Sync/CollectionSync.swift` | 泛型单集合同步：变更对账（hash diff）、tombstone 生成、合并结果回灌、状态更新 |
| 新增 | `App/Sync/SyncFileTransport.swift` | 同步目录解析、原子读写、DispatchSource 目录监听（1s 去抖 + 自写回声抑制） |
| 新增 | `App/Sync/SyncSettings.swift` | 开关存储（UserDefaults 键）：总开关、五集合开关、notes 剥离开关、同步目录、deviceID |
| 修改 | `App/JSONFileStore.swift` | 加 `syncCollectionID` / `onItemsChanged` 回调 + `applyRemote(_:)`（不回声）；init 末尾按 `syncCollectionID` 自动向引擎注册；约 40 行 |
| 修改 | 五个 store 各 2 行 | override `syncCollectionID` 声明所属集合；其余业务代码零改动 |
| 修改 | `App/UI/SettingsView.swift` | 新增「云同步」tab（图标 `icloud`）：总开关、目录选择、状态行、五集合开关、notes 开关、上次同步时间、「立即同步」「删除云端同步数据」 |
| 修改 | `App/Localizable.xcstrings` | 新增全部文案的中英条目 |
| 不做 | TOTP 迁移（§4.3） | v2 本期不做钥匙串同步开关，TOTP 维持 `ThisDeviceOnly` |

### 7.3 测试策略

- **合并器纯逻辑（HarborKitTests，无 Apple 服务依赖）**：
  - 同 id 双侧修改 → 时间戳大者胜；时间戳相等 → deviceID 字典序决胜（确定性）；
  - 删除 vs 修改 → 大者胜（含「复活」路径）；
  - 同 id 不同连接身份（`sameConnectionIdentity` false）→ 重新分配 id，不互相覆盖；
  - 空 envelope 合并满本地 → 本地零变化（首同步守卫）；
  - 满远端合并空本地 → 全量落地；
  - tombstone 超 30 天清理；
  - orderSnapshot LWW + 新 id 追加尾部；
  - notes 空不覆盖非空；
  - envelopeVersion 高于本地 → 不写回；
  - 引用完整性：folderID 悬空置 nil。
- **App 层**（无独立测试 target；通过 JSONFileStore 临时目录注入手动/脚本验证）：
  - `onItemsChanged` 在 add/update/delete/replaceAll 各触发一次；
  - `applyRemote` 不触发回调（无回声）；
  - 防抖窗口内多次变更只写一次同步文件。
- **手动验证矩阵**：两台真机共用一个 iCloud Drive（或 Syncthing 目录）：同时改同一主机、一删一改、离线改后上线、退出 iCloud 再开（目录消失/恢复）、把同步文件改坏验证「中止不覆写」、双机同时改触发冲突收敛。

## 8. 风险与对策

| 风险 | 等级 | 对策 |
|---|---|---|
| 用户误删/改坏同步文件（Finder 可见） | 中 | 解析失败 → 中止合并且**不覆写**，设置页报错给文件路径；本地永远是 source of truth，删掉坏文件后下一轮推全量重建 |
| 多设备并发写互相覆盖 | 中 | 「读-合并-写」循环 + 目录监听对账收敛；用户场景写频极低（手动改配置），冲突窗口秒级；iCloud 产生 conflict 副本时按 mtime 取最新并在日志记录 |
| 设备时钟偏移导致 LWW 结果反直觉 | 低 | `(modifiedAt, deviceID)` 字典序决胜保证**确定性收敛**（不保证「真实最新」，但保证所有设备收敛到同一结果） |
| 同步通道（Dropbox/Syncthing）半截写入 | 低 | 原子写（tmp+rename）保证本机不产生半截文件；对端半截文件触发「解析失败中止」路径 |
| tombstone 30 天后老设备上线导致删除复活 | 低 | 已接受权衡；老设备上线后其本地条目会以更老时间戳输给其他设备的现状（除非它恰好在删除后又编辑过该条目） |
| 用户关同步后数据残留云端 | 低 | 设置页提供「删除云端同步数据」显式按钮；不自动删（防误操作丢另一台机的数据源） |
| 回灌打断正在进行的编辑 | 低 | sheet draft 模式天然免疫；实现期逐个编辑器确认，live-binding 处跳过该 id |
| envelope 格式未来演进 | 低 | `envelopeVersion` 门闸：新版只读不写，等全设备升级后自然收敛 |
| notes 默认剥离导致「同步了但备注没了」的困惑 | 低 | 设置文案写明默认值与原因；开关一行可改 |
| 同步目录挂在慢速/网络文件系统上卡住 UI | 低 | 文件读写全部走后台队列，主线程只做内存合并；读写超时按失败处理进 lastError |

## 9. 分期建议

- **一期（本设计，v2 文件夹路线）**：单文件五集合同步 + notes 剥离开关 + 合并器 + 设置页。TOTP 维持本机锁死。
- **二期（按需）**：CloudKit 平移（envelope 的 record 化结构可直接映射 CKRecord，需开发者账号）；`.harbortheme` 主题同步（同为文件载体，顺手）；`@AppStorage` 外观/终端设置同步；TOTP 钥匙串同步开关（v1 §4.3 方案）。
- **不做**：自建服务器、邮箱通道、端到端自建加密（如未来有强需求，方向是 envelope payload 层加一层用户口令派生密钥的 AES-GCM——与载体解耦，届时单独立项）。
