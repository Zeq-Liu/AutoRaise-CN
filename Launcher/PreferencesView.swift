// AutoRaise & Launcher — 简体中文修改版
// 基于 https://github.com/sbmpost/AutoRaise-UI （GPL-3.0）
// 原版权: Stefan Post, Lothar Haeger（见 LICENSE.md）
// 修改: 2026-11-01 by coderLiu — 简体中文界面 + SwiftUI 偏好窗口重构
// 修改: 2026-11-04 — 设置项按用户任务重分组，补齐格式 / 数值 / 后果说明

import SwiftUI
import AppKit
import MASShortcut

struct MASShortcutViewRepresentable: NSViewRepresentable {
    var associatedUserDefaultsKey: String
    func makeNSView(context: Context) -> MASShortcutView {
        let v = MASShortcutView()
        v.associatedUserDefaultsKey = associatedUserDefaultsKey
        v.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        return v
    }
    func updateNSView(_ nsView: MASShortcutView, context: Context) {
        nsView.associatedUserDefaultsKey = associatedUserDefaultsKey
    }
}

/// 把底层 `disableKey` + `invertDisableKey` 两个偏好键映射成一个可读的停用方式。
/// 键名与取值完全不变，AppDelegate / daemon 的参数契约零改动。
private enum DisableMode: String, CaseIterable, Identifiable {
    case off
    case controlPause
    case optionPause
    case controlOnly
    case optionOnly

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: return "不设停用键"
        case .controlPause: return "按住 control 时暂停"
        case .optionPause: return "按住 option 时暂停"
        case .controlOnly: return "仅按住 control 时启用"
        case .optionOnly: return "仅按住 option 时启用"
        }
    }

    init(key: String, invert: Bool) {
        switch key {
        case "control": self = invert ? .controlOnly : .controlPause
        case "option": self = invert ? .optionOnly : .optionPause
        default: self = .off
        }
    }

    var key: String {
        switch self {
        case .off: return "disabled"
        case .controlPause, .controlOnly: return "control"
        case .optionPause, .optionOnly: return "option"
        }
    }

    var invert: Bool {
        switch self {
        case .controlOnly, .optionOnly: return true
        default: return false
        }
    }
}

@available(macOS 14, *)
private struct SettingsTab: View {
    // 键名与默认值全部保持不变，旧偏好零迁移
    @AppStorage("enableWarp") var enableWarp = false
    @AppStorage("enableCursorScaling") var enableCursorScaling = false
    @AppStorage("enableAltTaskSwitcher") var enableAltTaskSwitcher = false
    @AppStorage("warpOnlyAcrossScreens") var warpOnlyAcrossScreens = false
    @AppStorage("enableOnLaunch") var enableOnLaunch = false
    @AppStorage("requireMouseStop") var requireMouseStop = true
    @AppStorage("requireMultipleScreens") var requireMultipleScreens = false
    @AppStorage("requireScreenChange") var requireScreenChange = false
    @AppStorage("ignoreSpaceChanged") var ignoreSpaceChanged = false
    @AppStorage("invertDisableKey") var invertDisableKey = false
    @AppStorage("invertIgnoreApps") var invertIgnoreApps = false
    @AppStorage("hideMenubarIcon") var hideMenubarIcon = false
    @AppStorage("openAtLogin") var openAtLogin = false
    @AppStorage("autoRaiseDelay") var autoRaiseDelay = 300
    @AppStorage("autoFocusDelay") var autoFocusDelay = 300
    @AppStorage("mouseDelta") var mouseDelta = 0
    @AppStorage("pollMillis") var pollMillis = 50
    @AppStorage("ignoreApps") var ignoreApps = ""
    @AppStorage("ignoreTitles") var ignoreTitles = ""
    @AppStorage("stayFocusedBundleIds") var stayFocusedBundleIds = ""
    @AppStorage("disableKey") var disableKey = "control"

    // P1：单 Picker 双向映射到底层两个键
    private var disableMode: Binding<DisableMode> {
        Binding(
            get: { DisableMode(key: disableKey, invert: invertDisableKey) },
            set: { mode in
                disableKey = mode.key
                invertDisableKey = mode.invert
            }
        )
    }

    // 与 AppDelegate.readPreferences() 的 clamp 规则保持一致
    private var effectivePoll: Int { max(pollMillis, 20) }

    private func effectiveDelay(_ ms: Int) -> (ticks: Int, ms: Int) {
        let ticks = ms / effectivePoll
        // 与 daemon 对齐：AutoRaise.mm:1501 打印的是 (delayCount-1)*pollMillis。
        // delayCount=1 时 daemon 立即触发（无延迟）；delayCount=0 时整个关闭提升。
        return (ticks, max(ticks - 1, 0) * effectivePoll)
    }

    // P2：避免「填了但静默不生效」
    private func normalizedList(_ raw: String) -> String {
        raw.replacingOccurrences(of: "，", with: ",")
            .replacingOccurrences(of: ", ", with: ",")
    }

    // P6：勾选前确认，避免隐藏后再也打不开设置
    private var hideMenubarIconConfirmed: Binding<Bool> {
        Binding(
            get: { hideMenubarIcon },
            set: { newValue in
                if !newValue {
                    hideMenubarIcon = false
                    return
                }
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "隐藏菜单栏图标？"
                alert.informativeText = """
                隐藏后菜单栏图标和菜单都会消失，本应用也没有 Dock 图标。
                恢复方式：再次打开本应用（启动台 / 访达 / open -a AutoRaise）会显示设置窗口；
                或在终端执行 defaults write com.autoraise.app hideMenubarIcon -bool false 后重启应用。
                """
                alert.addButton(withTitle: "仍然隐藏")
                alert.addButton(withTitle: "取消")
                if alert.runModal() == .alertFirstButtonReturn {
                    hideMenubarIcon = true
                }
            }
        )
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(.caption).foregroundColor(.secondary)
    }

    var body: some View {
        Form {
            // P5：两个「打开 / 启用」分清楚，并说明都不勾时的表现
            Section("启动行为") {
                Toggle("开机时自动启动本应用", isOn: $openAtLogin)
                Toggle("启动后自动开启跟随功能（自动拉起 daemon）", isOn: $enableOnLaunch)
                hint("前者管开机启动，后者管功能是否已开启；都不勾时，需点菜单栏图标手动启用。")
            }

            // P3：显示真实生效值，不再让用户以为填的毫秒就是生效的毫秒
            Section("提升与聚焦") {
                hint("提升 = 把窗口移到最前；聚焦 = 让它成为键盘输入目标。")
                HStack {
                    Text("鼠标停留多久后提升窗口")
                    Spacer()
                    TextField("", value: $autoRaiseDelay, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                    Text("毫秒")
                }
                hint("实际生效 ≈ \(effectiveDelay(autoRaiseDelay).ms) ms"
                     + "（\(effectiveDelay(autoRaiseDelay).ticks) × \(effectivePoll) ms 轮询）")
                HStack {
                    Text("提升窗口后多久再聚焦")
                    Spacer()
                    TextField("", value: $autoFocusDelay, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                    Text("毫秒")
                }
                hint("实际生效 ≈ \(effectiveDelay(autoFocusDelay).ms) ms"
                     + "（\(effectiveDelay(autoFocusDelay).ticks) × \(effectivePoll) ms 轮询）")
            }

            // P8 / P9：把说反的文案和「临时」的确切时长写准
            Section("鼠标传送") {
                Toggle("将鼠标指针传送到激活窗口中心", isOn: $enableWarp)
                Toggle("切换应用后短暂放大光标（约 0.4 秒后放大 2 倍，1 秒后恢复）",
                       isOn: $enableCursorScaling)
                Toggle("点击窗口、Dock 等方式切换应用时也传送鼠标",
                       isOn: $enableAltTaskSwitcher)
                hint("默认仅 command-tab 切换应用时传送鼠标。")
            }

            // P7：条件开关收拢，明确是叠加限制（AND）
            Section("生效条件") {
                hint("以下条件需同时满足；同时勾选 = 限制叠加。")
                Toggle("至少连接两块屏幕时才生效", isOn: $requireMultipleScreens)
                Toggle("仅当焦点窗口与鼠标不在同一屏幕时生效", isOn: $requireScreenChange)
                Toggle("鼠标停下后才开始计时", isOn: $requireMouseStop)
                Toggle("切换工作区（Space）后暂不生效", isOn: $ignoreSpaceChanged)
                Toggle("鼠标传送仅限其他屏幕上的窗口", isOn: $warpOnlyAcrossScreens)
            }

            // P1 / P2：反转写清楚，三个输入框补齐格式与匹配方式
            Section("例外应用与窗口") {
                Text("忽略的应用（按应用名匹配）")
                TextField("", text: $ignoreApps)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: ignoreApps) { _, newValue in
                        let norm = normalizedList(newValue)
                        if norm != newValue { ignoreApps = norm }
                    }
                hint("英文逗号分隔，如 Safari,微信；逗号后不要加空格。")
                Toggle("仅对列出的应用生效（反转忽略列表）", isOn: $invertIgnoreApps)
                hint("关闭时：列出的应用被忽略；开启时：只有列出的应用会触发。")

                Text("忽略的窗口标题（正则匹配）")
                TextField("", text: $ignoreTitles)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: ignoreTitles) { _, newValue in
                        let norm = normalizedList(newValue)
                        if norm != newValue { ignoreTitles = norm }
                    }
                hint("英文逗号分隔的正则表达式，如 ^DevTools,控制台$")

                Text("保持聚焦的应用（Bundle ID，精确匹配）")
                TextField("", text: $stayFocusedBundleIds)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: stayFocusedBundleIds) { _, newValue in
                        let norm = normalizedList(newValue)
                        if norm != newValue { stayFocusedBundleIds = norm }
                    }
                hint("如 com.apple.Safari；前台是这些应用时不提升窗口。")
            }

            // P1 五选项 Picker + P11 快捷键标签
            Section("临时停用与快捷键") {
                HStack {
                    Text("临时停用方式")
                    Spacer()
                    Picker("", selection: disableMode) {
                        ForEach(DisableMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .frame(width: 220)
                }
                hint("「暂停」= 按住时停用；「仅…时启用」= 不按住就停用。")
                HStack {
                    Text("启停跟随功能的全局快捷键（改完立即生效）：")
                    Spacer()
                    MASShortcutViewRepresentable(associatedUserDefaultsKey: "HotKey")
                        .fixedSize()
                }
            }

            // P10 / P4 / P6：单位、实时值、危险项确认
            Section("高级") {
                HStack {
                    Text("鼠标移动阈值（像素，0 = 最敏感）")
                    Spacer()
                    Slider(value: Binding(get: { Double(mouseDelta) },
                                          set: { mouseDelta = Int($0) }),
                           in: 0...100, step: 1)
                        .frame(width: 200)
                }
                hint("鼠标位移超过该值才算「在移动」。")
                HStack {
                    Text("轮询间隔（毫秒，最小 20）")
                    Spacer()
                    TextField("", value: $pollMillis, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                }
                hint("当前生效：\(effectivePoll) ms。间隔越小响应越快、CPU 占用越高；"
                     + "上面的延迟会按轮询次数取整。")
                Toggle("隐藏菜单栏图标", isOn: hideMenubarIconConfirmed)
                hint("隐藏后仍可通过再次打开本应用找回设置窗口；勾选时会先确认。")
            }
        }
        .formStyle(.grouped)
    }
}

@available(macOS 14, *)
private struct AboutTab: View {
    var body: some View {
        Form {
            Section {
                Text("AutoRaise & Launcher").font(.headline)
                Text("版本 " + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"))
                    .foregroundColor(.secondary)
                Text("原作者：Stefan Post、Lothar Haeger")
                    .foregroundColor(.secondary)
                Text("中文版维护：coderLiu")
                    .foregroundColor(.secondary)
                Text("GNU General Public License v3")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("本程序为修改版（derivative work），修改日期 2026-11，非上游官方发布。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("源码") {
                Button("查看源代码（原作者 sbmpost）") {
                    NSWorkspace.shared.open(URL(string: "https://github.com/sbmpost/AutoRaise")!)
                }
                Button("查看源代码（维护者 lhaeger）") {
                    NSWorkspace.shared.open(URL(string: "https://github.com/lhaeger/AutoRaise")!)
                }
                Button("查看中文版仓库（Zeq-Liu/AutoRaise-CN）") {
                    NSWorkspace.shared.open(URL(string: "https://github.com/Zeq-Liu/AutoRaise-CN")!)
                }
            }
        }
        .formStyle(.grouped)
    }
}

@available(macOS 14, *)
struct PreferencesView: View {
    var body: some View {
        TabView {
            SettingsTab().tabItem { Label("设置", systemImage: "gear") }
            AboutTab().tabItem { Label("关于", systemImage: "info.circle") }
        }
        .padding()
        .frame(minWidth: 560, minHeight: 560)
    }
}
