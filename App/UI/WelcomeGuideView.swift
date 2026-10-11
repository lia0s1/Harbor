import SwiftUI

struct WelcomeGuideView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var currentPage = 0

    private static let pages: [GuidePage] = [
        GuidePage(
            symbol: "sailboat.fill",
            gradient: [Color(red: 0.18, green: 0.47, blue: 0.92), Color(red: 0.40, green: 0.72, blue: 1.0)],
            title: "欢迎使用 Harbor",
            subtitle: "原生 macOS SSH 连接管理器，为专业运维而生。",
            features: [
                GuideFeature(icon: "lock.shield.fill", color: .green, title: "安全连接", desc: "基于系统 OpenSSH，支持密钥认证与跳板机"),
                GuideFeature(icon: "bolt.circle.fill", color: .purple, title: "GPU 加速", desc: "Metal 渲染终端，滚动流畅，帧率极高"),
                GuideFeature(icon: "globe.americas.fill", color: .orange, title: "双语界面", desc: "中英文自由切换，菜单跟随语言设置"),
            ]
        ),
        GuidePage(
            symbol: "plus.circle.fill",
            gradient: [Color(red: 0.12, green: 0.52, blue: 0.42), Color(red: 0.25, green: 0.75, blue: 0.55)],
            title: "添加你的第一台服务器",
            subtitle: "多种方式快速上手，选你顺手的。",
            features: [
                GuideFeature(icon: "plus.rectangle.fill.on.rectangle.fill", color: .blue, title: "手动添加", desc: "点击侧栏 + 或按 ⌘N，填写地址和凭据"),
                GuideFeature(icon: "bolt.horizontal.fill", color: .yellow, title: "快速连接", desc: "侧栏底部输入 user@host 回车即连"),
                GuideFeature(icon: "square.and.arrow.down.fill", color: .teal, title: "批量导入", desc: "菜单 文件 → 从 ~/.ssh/config 一键导入"),
            ]
        ),
        GuidePage(
            symbol: "chart.xyaxis.line",
            gradient: [Color(red: 0.88, green: 0.42, blue: 0.18), Color(red: 1.0, green: 0.62, blue: 0.28)],
            title: "连接即监控",
            subtitle: "SSH 连接建立后自动开启，无需额外配置。",
            features: [
                GuideFeature(icon: "heart.text.square.fill", color: .red, title: "系统指标", desc: "CPU、内存、磁盘、网络实时图表"),
                GuideFeature(icon: "cube.fill", color: .indigo, title: "Docker 管理", desc: "查看容器状态，启停、日志、终端一键直达"),
                GuideFeature(icon: "folder.fill.badge.gearshape", color: .mint, title: "文件传输", desc: "内置 SFTP 文件浏览器，拖拽上传下载"),
            ]
        ),
        GuidePage(
            symbol: "keyboard.fill",
            gradient: [Color(red: 0.52, green: 0.28, blue: 0.82), Color(red: 0.68, green: 0.48, blue: 1.0)],
            title: "效率快捷键",
            subtitle: "掌握这些组合键，事半功倍。",
            features: [
                GuideFeature(icon: "magnifyingglass.circle.fill", color: .blue, title: "⌘P 快速跳转", desc: "模糊搜索所有已保存主机并连接"),
                GuideFeature(icon: "text.badge.checkmark", color: .green, title: "命令条", desc: "底部保存常用命令，一键发送到终端"),
                GuideFeature(icon: "square.stack.3d.up.fill", color: .orange, title: "⌘⇧B 批量执行", desc: "同一命令同时发送到多台服务器"),
            ]
        ),
    ]

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                ForEach(Array(Self.pages.enumerated()), id: \.offset) { index, page in
                    if index == currentPage {
                        pageView(page)
                            .transition(
                                reduceMotion
                                ? .opacity
                                : .asymmetric(
                                    insertion: .move(edge: .trailing).combined(with: .opacity),
                                    removal: .move(edge: .leading).combined(with: .opacity)
                                )
                            )
                    }
                }
            }
            .animation(DS.Anim.state, value: currentPage)
            .clipped()

            Spacer(minLength: 0)

            HStack(spacing: 16) {
                Button(L("跳过")) { dismiss() }
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.cancelAction)
                    .help(L("跳过引导"))

                HStack(spacing: 8) {
                    ForEach(0..<Self.pages.count, id: \.self) { index in
                        Capsule()
                            .fill(index == currentPage ? Color.accentColor : Color.secondary.opacity(0.25))
                            .frame(width: index == currentPage ? 20 : 7, height: 7)
                            .animation(DS.Anim.state, value: currentPage)
                            .pressFeedback()
                            .onTapGesture {
                                withAnimation(DS.Anim.state) { currentPage = index }
                            }
                    }
                }

                Spacer()

                if currentPage > 0 {
                    Button {
                        withAnimation(DS.Anim.state) { currentPage -= 1 }
                    } label: {
                        Text(L("上一步"))
                            .frame(width: 70)
                    }
                    .buttonStyle(.glass)
                    .controlSize(.large)
                }

                Button {
                    if currentPage < Self.pages.count - 1 {
                        withAnimation(DS.Anim.state) { currentPage += 1 }
                    } else {
                        dismiss()
                    }
                } label: {
                    Text(currentPage < Self.pages.count - 1 ? L("继续") : L("开始使用"))
                        .frame(width: 70)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
            }
            .padding(.horizontal, 30)
            .padding(.bottom, 22)
            .padding(.top, 10)
        }
        .frame(width: 540, height: 430)
    }

    private func pageView(_ page: GuidePage) -> some View {
        VStack(spacing: 0) {
            ZStack {
                LinearGradient(
                    colors: page.gradient,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                GuideHeroIcon(symbol: page.symbol)
            }
            .frame(height: 110)

            VStack(spacing: 5) {
                Text(L(page.title))
                    .font(.system(size: 21, weight: .bold, design: .rounded))
                Text(L(page.subtitle))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 18)
            .padding(.horizontal, 30)

            VStack(alignment: .leading, spacing: 14) {
                ForEach(page.features, id: \.title) { feature in
                    featureRow(feature)
                }
            }
            .padding(.top, 22)
            .padding(.horizontal, 40)

            Spacer(minLength: 0)
        }
    }

    private func featureRow(_ feature: GuideFeature) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: feature.icon)
                .font(.system(size: 22))
                .foregroundStyle(feature.color)
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 1) {
                Text(L(feature.title))
                    .font(.system(size: 13, weight: .semibold))
                Text(L(feature.desc))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }
}

/// The gradient-header hero icon. Animates itself in (scale + fade) on appear,
/// so every page change re-triggers the entrance — not only the first page
/// (each page's subtree is freshly inserted by the ZStack transition, so its
/// `onAppear` fires anew). Under Reduce Motion it appears immediately with no
/// scale or fade.
private struct GuideHeroIcon: View {
    let symbol: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 48, weight: .thin))
            .foregroundStyle(.white.opacity(0.9))
            .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
            .scaleEffect(reduceMotion ? 1.0 : (shown ? 1.0 : 0.6))
            .opacity(shown ? 1.0 : 0)
            .onAppear {
                if reduceMotion {
                    shown = true
                } else {
                    withAnimation(DS.Anim.state.delay(0.03)) { shown = true }
                }
            }
    }
}

private struct GuidePage {
    let symbol: String
    let gradient: [Color]
    let title: String
    let subtitle: String
    let features: [GuideFeature]
}

private struct GuideFeature {
    let icon: String
    let color: Color
    let title: String
    let desc: String
}
