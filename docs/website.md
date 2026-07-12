# 官网下载页

Harbor 官网源码位于 `website/`，采用无第三方运行依赖的静态 HTML、CSS 和 JavaScript，可直接部署到任意静态托管服务。

## 页面结构

页面采用蓝紫动态纹理产品首屏、底部工作台预览、五组左右交替的“说明 + 产品画面”、三种工作界面、六张工作流观点卡、纹理下载 CTA 与五列页脚。产品画面使用 Harbor 当前正式 App 的真实窗口截图，覆盖 `NavigationSplitView`、主机侧栏、会话标签、SwiftTerm 终端、命令输入条、底部文件抽屉、右侧监控检查器和主机编辑表单。首屏纹理与所有截图都是 Harbor 自有本地 WebP 资产，不依赖外部图片或第三方脚本。

动态效果包括首屏纹理与光晕的持续漂移、产品窗口的轻微悬浮、功能区与观点卡的滚动进入，以及产品卡片的悬停位移；系统开启“减少动态效果”时会自动缩短动画。

官网首屏、五组功能图和三张工作界面卡统一使用 2482×1802 的完整 App 窗口截图。图片容器遵循截图原始宽高比并使用 `object-fit: contain`，桌面端与移动端都完整显示窗口四边，不再使用放大裁切图或悬停缩放。

## 国际化

- 官网支持简体中文 `zh-CN` 与英文 `en-US`。未手动选择时，按浏览器首选语言自动判断：中文语言环境使用 `zh-CN`，其他语言环境使用 `en-US`。
- 页头与页脚都提供语言选择器；任一选择器切换后会同步另一个，并将结果写入 `localStorage` 的 `harbor.locale`，后续刷新继续使用该选择。
- 语言切换覆盖页面标题、描述元数据、导航、正文、按钮、页脚、图片替代文本与 ARIA 标签，并同步切换产品截图。
- 中文页面使用 `harbor-app-*.webp`，英文页面使用同名的 `harbor-app-*.en.webp`。两套图片都来自真实 Harbor App，不允许在图片上覆盖、重绘或直接替换界面文字。
- 英文截图通过 App 的 `en-US` 界面重新拍摄，连接对象是隔离的本机演示服务 `localhost:22222`；其中不包含真实服务器地址、账号、凭据或文件。
- App 监控区域的运行时间单位随当前 App 语言格式化，避免英文 App 截图中残留中文“天 / 小时 / 分钟 / 秒”。

## 内容与隐私

- 页面使用仓库内 Harbor App 图标。
- 首屏能力区每 2.5 秒在“核心能力”和“常用远程平台”之间进行淡出、轻微上移与淡入切换，不使用旋转或透视效果；平台列表仅表达 SSH 使用场景与兼容方向，不代表 Harbor 与 AWS、Google Cloud、Microsoft Azure、DigitalOcean 或 Cloudflare 存在商业合作关系。
- 核心能力使用本地化资产：SSH 使用 Harbor 自绘的中性协议图标；OpenSSH 图标只用于说明由系统 OpenSSH 支持的 SFTP 能力；Swift.org 官方标识用于说明 Swift/SwiftUI，Apple 官网导航标识用于说明 macOS Keychain，Xcode 本机正式图标用于说明签名与公证工具链；页面运行时不请求外部图片。
- 六张工作流观点卡使用本地生成的虚构工程师头像，不对应真实人物，也不包含姓名或身份信息。
- 产品窗口来自隔离启动的 Harbor 正式 App；截图时仅连接监听在本机 `localhost:22222` 的临时合成 SSH 服务。
- 演示会话、文件列表、命令输出和监控指标全部为合成数据；截图后临时服务、隔离 App 数据与临时主机指纹均已清理。
- 演示主机只使用 `192.0.2.0/24`、`198.51.100.0/24` 和 `203.0.113.0/24` 文档专用地址，禁止替换为真实服务器信息。

官方品牌资产来源：

- SSH：Harbor 自绘中性协议图标（终端提示符与远程连接节点意象），不表示 SSH 协议存在官方品牌标识。
- OpenSSH：`https://dashboardicons.com/icons/external/openssh`（CC BY 4.0，来源标注为 selfh.st/icons）；仅用于页面中的 SFTP 能力项。
- Swift：`https://www.swift.org/assets/images/swift.svg`
- Apple：`https://www.apple.com/` 全局导航内嵌 Apple 标识
- Xcode：本机 `/Applications/Xcode.app/Contents/Resources/Xcode.icns`
- 常用平台图标：Simple Icons 本地化 SVG，仅用于兼容平台展示

## 本地预览

可直接打开 `website/index.html`，或在仓库根目录启动任意静态文件服务器，将站点根目录指向 `website/`。

## 下载文件

页面固定引用以下公开路径：

- `/downloads/harbor-installer.dmg`
- `/downloads/Harbor.zip`

正式部署时只发布已经过 `scripts/release.sh` 完整签名、公证和验证的产物。桌面文件 `harbor installer.dmg` 发布到网站时重命名为 URL 安全的 `harbor-installer.dmg`；不要把发布二进制提交进源码仓库。
