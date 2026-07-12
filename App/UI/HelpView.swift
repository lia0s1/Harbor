import SwiftUI
import AppKit

// MARK: - Help window controller

@MainActor
final class HelpWindowController {
    static let shared = HelpWindowController()
    private var window: NSWindow?

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        if let window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let controller = NSHostingController(rootView: HelpView())
        let win = NSWindow(contentViewController: controller)
        win.isReleasedWhenClosed = false
        win.title = "Harbor 使用说明"
        win.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        win.setContentSize(NSSize(width: 660, height: 580))
        win.center()
        win.makeKeyAndOrderFront(nil)
        self.window = win
    }
}

// MARK: - Help window

struct HelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                Divider().padding(.vertical, 12)
                sections
                    .padding(.bottom, 24)
            }
            .padding(28)
        }
        .frame(width: 660, height: 580)
        .background(.background)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "sailboat.fill")
                .font(.system(size: 36, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 52, height: 52)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.accentColor.opacity(0.12))
                )
            VStack(alignment: .leading, spacing: 3) {
                Text("Harbor 使用说明")
                    .font(.title2.bold())
                Text("原生 macOS SSH 客户端 · v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    // MARK: All sections

    private var sections: some View {
        VStack(alignment: .leading, spacing: 20) {
            HelpSection(icon: "bolt.fill", color: .orange, title: "快速开始") {
                HelpRow(keys: ["⌘N"], desc: "新建主机 — 填写主机名/IP、端口、用户名，选择密码或 SSH 密钥")
                HelpRow(keys: ["⌘T"], desc: "快速连接 — 直接输入 user@host 或 user@host:port 秒连")
                HelpRow(desc: "侧栏点击主机即连接；连接中显示橙色，已连接显示绿色")
                HelpRow(desc: "主机右键 → 编辑、复制、删除；拖动可调整顺序")
                HelpRow(desc: "支持备注字段，在主机编辑中填写，侧栏灰色显示")
            }

            HelpSection(icon: "terminal.fill", color: .green, title: "终端") {
                HelpRow(keys: ["⌘K"], desc: "清空终端（等同 Ctrl-L + 清除历史滚动区域）")
                HelpRow(keys: ["⌘D"], desc: "复制当前会话（相同主机再开一个标签页）")
                HelpRow(keys: ["⌘1–⌘9"], desc: "切换标签页")
                HelpRow(keys: ["⌘W"], desc: "关闭当前标签页")
                HelpRow(keys: ["Tab"], desc: "在命令输入框自动补全历史命令（最近匹配）")
                HelpRow(desc: "右键终端 → 复制、粘贴、清空终端")
                HelpRow(desc: "会话意外断开后自动重连，最多 5 次，成功后显示绿色")
            }

            HelpSection(icon: "folder.fill", color: .blue, title: "文件管理") {
                HelpRow(keys: ["⌘J"], desc: "显示 / 隐藏文件面板（底部抽屉）")
                HelpRow(desc: "双击目录进入，双击文件立即下载到「下载」文件夹")
                HelpRow(desc: "右键 → 下载、上传、重命名、权限、编辑、解压到当前目录")
                HelpRow(desc: "从 Finder 拖入文件或文件夹 → 直接上传到当前目录")
                HelpRow(desc: "工具栏上传按钮 → 选择本地文件上传；支持整个目录（自动压缩）")
                HelpRow(desc: "传输列表按钮 → 查看进度、速率；失败行点 ↻ 重试")
                HelpRow(desc: "左侧目录树可折叠；拖动分割线调整宽度")
            }

            HelpSection(icon: "chart.bar.fill", color: .purple, title: "监控面板") {
                HelpRow(keys: ["⌘I"], desc: "显示 / 隐藏监控面板（右侧抽屉）")
                HelpRow(desc: "CPU / 内存 / 交换区 — 实时仪表盘，点击展开历史图表")
                HelpRow(desc: "进程列表 — 按 CPU/内存排序；右键 → 结束进程 / 强制结束")
                HelpRow(desc: "监听端口 — 查看 ss -tulnp 占用情况；右键 → 结束占用进程")
                HelpRow(desc: "网络流量 — 下载 / 上传实时速率 + 折线图；下方显示活动网卡")
                HelpRow(desc: "磁盘 I/O — 分区读写速率；延迟 — ping 往返时间")
            }

            HelpSection(icon: "arrow.left.arrow.right", color: .cyan, title: "端口转发") {
                HelpRow(desc: "在主机编辑页「端口转发」中预配置规则（本地端口 → 远程地址:端口）")
                HelpRow(desc: "连接后在监控面板底部找到「转发」卡，点开关逐条启用 / 关闭")
                HelpRow(desc: "点「添加转发」可在当前已连接会话中临时新建转发规则（不保存到主机配置）")
                HelpRow(desc: "临时规则右侧点 🗑 立即取消；会话关闭后自动失效")
            }

            HelpSection(icon: "key.fill", color: .yellow, title: "密钥管理") {
                HelpRow(desc: "密菜单 → 密钥管理 — 生成 / 导入 / 查看 / 删除 SSH 密钥对")
                HelpRow(desc: "密菜单 → 复制 SSH 公钥 — 从 ~/.ssh 选 .pub 文件复制到剪贴板")
                HelpRow(desc: "无密码登录：把公钥加到服务器 ~/.ssh/authorized_keys，主机配置选对应私钥")
            }

            HelpSection(icon: "square.and.arrow.up.on.square", color: .mint, title: "主机备份 / 迁移") {
                HelpRow(desc: "文件 → 导出主机配置 — 把全部主机 + 快捷命令保存为 JSON 文件")
                HelpRow(desc: "文件 → 导入主机配置 — 从 JSON 恢复，自动去重合并")
                HelpRow(desc: "私钥和密码不在导出文件内（安全考虑），迁移后需重新填写")
            }

            HelpSection(icon: "gearshape.fill", color: .gray, title: "外观 / 偏好") {
                HelpRow(keys: ["⌘,"], desc: "打开设置")
                HelpRow(desc: "外观 — 浅色 / 深色 / 跟随系统，实时切换无需重启")
                HelpRow(desc: "语言 — 中文 / English，实时切换")
                HelpRow(desc: "终端主题、字体大小、背景图、透明度")
                HelpRow(desc: "传输 — 文件夹压缩打包传输开关")
            }
        }
    }
}

// MARK: - Section

private struct HelpSection<Content: View>: View {
    let icon: String
    let color: Color
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(color)
                    .frame(width: 20)
                Text(title)
                    .font(.headline)
            }
            VStack(alignment: .leading, spacing: 3) {
                content
            }
            .padding(.leading, 28)
        }
    }
}

// MARK: - Row

private struct HelpRow: View {
    var keys: [String] = []
    let desc: String

    init(keys: [String] = [], desc: String) {
        self.keys = keys
        self.desc = desc
    }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            if !keys.isEmpty {
                HStack(spacing: 3) {
                    ForEach(keys, id: \.self) { key in
                        Text(key)
                            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(Color.primary.opacity(0.08))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                                            .strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5)
                                    )
                            )
                    }
                }
                .frame(minWidth: 50, alignment: .leading)
            } else {
                Text("·")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
                    .frame(width: 10)
            }
            Text(desc)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}
