import SwiftUI

@main struct IslandSpeedApp: App {
    @StateObject private var monitor = SpeedMonitor()
    var body: some Scene {
        WindowGroup { ContentView(monitor: monitor) }
    }
}

struct ContentView: View {
    @ObservedObject var monitor: SpeedMonitor
    @State private var busy = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack(spacing: 12) {
                        rate("下载", "arrow.down", monitor.down, .green)
                        rate("上传", "arrow.up", monitor.up, .cyan)
                    }
                    Toggle("实验性后台保活", isOn: $monitor.keepAlive)
                        .disabled(monitor.running || busy)
                    Text("开启后循环播放无声本地音频，尝试在切换 App 后继续采样。可能增加耗电、受音频中断或系统限制影响。不需要定位、VPN 或网络服务器。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button {
                        busy = true
                        Task {
                            if monitor.running { await monitor.stop() } else { await monitor.start() }
                            busy = false
                        }
                    } label: {
                        Text(monitor.running ? "停止灵动岛网速" : "开启灵动岛网速")
                            .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 8)
                    }.buttonStyle(.borderedProminent).disabled(busy)
                    Text(monitor.status).font(.subheadline).foregroundStyle(.secondary)
                    Text("网速为 Wi-Fi 与蜂窝接口的估算流量，每秒采样，不是测速结果。灵动岛刷新由 iOS 控制；单次实时活动最长 8 小时。")
                        .font(.footnote).foregroundStyle(.secondary)
                }.padding(20)
            }.navigationTitle("灵动网速")
        }
    }
    private func rate(_ title: String, _ icon: String, _ value: Double, _ color: Color) -> some View {
        let p = RateText.parts(value)
        return VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon).foregroundStyle(color)
            Text(p.0).font(.system(size: 32, weight: .semibold, design: .rounded)).monospacedDigit().minimumScaleFactor(0.5).lineLimit(1)
            Text(p.1).font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(16).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }
}
