import SwiftUI

struct WelcomeGuideView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var currentPage = 0
    @State private var appeared = false

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
                GuideFeature(icon: "magnifyingglass.circle.fill", color: .blue, title: "⌘K 快速跳转", desc: "模糊搜索所有已保存主机并连接"),
                GuideFeature(icon: "text.badge.checkmark", color: .green, title: "命令条", desc: "底部保存常用命令，一键发送到终端"),
                GuideFeature(icon: "square.stack.3d.up.fill", color: .orange, title: "⌘B 批量执行", desc: "同一命令同时发送到多台服务器"),
            ]
        ),
    ]

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                ForEach(Array(Self.pages.enumerated()), id: \.offset) { index, page in
                    if index == currentPage {
                        pageView(page)
                            .transition(.asymmetric(
                                insertion: .move(edge: .trailing).combined(with: .opacity),
                                removal: .move(edge: .leading).combined(with: .opacity)
                            ))
                    }
                }
            }
            .animation(.spring(duration: 0.22), value: currentPage)
            .clipped()

            Spacer(minLength: 0)

            HStack(spacing: 16) {
                HStack(spacing: 8) {
                    ForEach(0..<Self.pages.count, id: \.self) { index in
                        Capsule()
                            .fill(index == currentPage ? Color.accentColor : Color.secondary.opacity(0.25))
                            .frame(width: index == currentPage ? 20 : 7, height: 7)
                            .animation(.spring(duration: 0.2), value: currentPage)
                            .onTapGesture {
                                withAnimation(.spring(duration: 0.22)) { currentPage = index }
                            }
                    }
                }

                Spacer()

                if currentPage > 0 {
                    Button {
                        withAnimation(.spring(duration: 0.22)) { currentPage -= 1 }
                    } label: {
                        Text(L("上一步"))
                            .frame(width: 70)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }

                Button {
                    if currentPage < Self.pages.count - 1 {
                        withAnimation(.spring(duration: 0.22)) { currentPage += 1 }
                    } else {
                        dismiss()
                    }
                } label: {
                    Text(currentPage < Self.pages.count - 1 ? L("继续") : L("开始使用"))
                        .frame(width: 70)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding(.horizontal, 30)
            .padding(.bottom, 22)
            .padding(.top, 10)
        }
        .frame(width: 540, height: 430)
        .onAppear {
            withAnimation(.easeOut(duration: 0.22).delay(0.03)) { appeared = true }
        }
    }

    private func pageView(_ page: GuidePage) -> some View {
        VStack(spacing: 0) {
            ZStack {
                LinearGradient(
                    colors: page.gradient,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                Image(systemName: page.symbol)
                    .font(.system(size: 48, weight: .thin))
                    .foregroundStyle(.white.opacity(0.9))
                    .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
                    .scaleEffect(appeared ? 1.0 : 0.6)
                    .opacity(appeared ? 1.0 : 0)
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
