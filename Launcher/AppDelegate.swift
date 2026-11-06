// AutoRaise & Launcher — 简体中文修改版
// 基于 https://github.com/sbmpost/AutoRaise-UI （GPL-3.0）
// 原版权: Stefan Post, Lothar Haeger（见 LICENSE.md）
// 修改: 2026-11-01 by coderLiu — 简体中文界面 + SwiftUI 偏好窗口重构（去 xib）

/*
 *
 * AutoRaise Launcher
 *
 * Copyright (c) 2024 Stefan Post (sbmpost), Lothar Haeger
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */

import Cocoa
import Foundation
import AppKit
import ServiceManagement
import SwiftUI
import MASShortcut

class AppDelegate: NSObject, NSApplicationDelegate {

    let prefs = UserDefaults.standard

    override init() {
        super.init()
        NSApp.delegate = self
        migrateLegacyPreferencesIfNeeded()
    }

    /// Bundle id 从 com.sbmpost.AutoRaise 改为 com.autoraise.app 后，UserDefaults 域随之改变。
    /// 一次性把旧域里的设置搬到新域，避免用户配置丢失；搬完打标记，之后不再搬。
    private func migrateLegacyPreferencesIfNeeded() {
        let oldSuite = "com.sbmpost.AutoRaise"
        let marker = "migratedFromLegacySuite"
        guard !prefs.bool(forKey: marker) else { return }
        prefs.set(true, forKey: marker)   // 先打标记，防止半途失败导致重复搬
        guard let old = UserDefaults(suiteName: oldSuite) else { return }

        // 只搬 AutoRaise 自己的键：suiteName 读出的字典会混入全局域（AppleLanguages 等）与
        // 无关应用的键，直接全搬会污染新域（旧域 8 键 → 新域 170 键）。
        let knownKeys = [
            "autoRaiseDelay", "autoFocusDelay", "mouseDelta", "pollMillis",
            "enableWarp", "enableCursorScaling", "enableAltTaskSwitcher", "warpOnlyAcrossScreens",
            "enableOnLaunch", "hideMenubarIcon", "requireMouseStop", "requireMultipleScreens",
            "requireScreenChange", "ignoreSpaceChanged", "invertDisableKey", "invertIgnoreApps",
            "ignoreApps", "ignoreTitles", "stayFocusedBundleIds", "disableKey", "openAtLogin",
            "HotKey", "_diag_log"
        ]
        var moved = 0
        for key in knownKeys {
            if let value = old.object(forKey: key) {
                prefs.set(value, forKey: key)
                moved += 1
            }
        }
        if moved > 0 {
            NSLog("[AutoRaise] 已从旧设置域迁移 \(moved) 项")
        }
    }

    var menuBarItem: NSStatusItem?
    var menu: NSMenu = NSMenu()
    var menuItemPrefs: NSMenuItem = NSMenuItem()
    var menuItemQuit: NSMenuItem = NSMenuItem()
    var menuItemAccessibility: NSMenuItem = NSMenuItem()
    var autoRaiseService: Process = Process()
    var preferencesWindow: NSWindow?

    // Settings (kept in sync with UserDefaults via readPreferences())
    var autoRaiseDelay: Int = 0
    var autoFocusDelay: Int = 0
    var mouseDelta: Int = 0
    var pollMillis: Int = 50
    var enableWarp = false
    var enableCursorScaling = false
    var enableAltTaskSwitcher = false
    var warpOnlyAcrossScreens = false
    var enableOnLaunch = false
    var hideMenubarIcon = false
    var requireMouseStop = true
    var requireMultipleScreens = false
    var requireScreenChange = false
    var ignoreSpaceChanged = false
    var invertDisableKey = false
    var invertIgnoreApps = false
    var ignoreApps = ""
    var ignoreTitles = ""
    var stayFocusedBundleIds = ""
    var disableKey = "control"
    var debounceItem: DispatchWorkItem?
    private var accessibilityHeartbeat: Timer?

    // MARK: - Lifecycle

    func applicationWillFinishLaunching(_ notification: Notification) {}

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        // 显式设置后台代理模式，确保状态栏在 GUI 会话正常渲染
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: false)

        setupStatusBar()
        readPreferences()
        syncLoginItem()
        updateAccessibilityState()
        registerHotkeyFromDefaults()
        startAccessibilityMonitoring()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(defaultsChanged(_:)),
            name: UserDefaults.didChangeNotification,
            object: nil
        )

        let instances = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == Bundle.main.bundleIdentifier && $0 != NSRunningApplication.current
        }
        if instances.isEmpty {
            DistributedNotificationCenter.default().addObserver(
                self,
                selector: #selector(activateExistingInstance(_:)),
                name: Notification.Name("com.autoraise.app.activate"),
                object: nil
            )
            if enableOnLaunch {
                startService(self)
            }
        } else {
            // 已有实例在跑：本实例仍显示状态栏/首选项并接管 daemon
            DistributedNotificationCenter.default().postNotificationName(
                Notification.Name("com.autoraise.app.activate"), object: nil)
            if enableOnLaunch {
                startService(self)
            }
        }
    }

    /// 隐藏菜单栏图标后，用户再次打开本应用（启动台 / 访达 / `open -a AutoRaise`）
    /// 时仍能找回设置窗口。已用最小 LSUIElement demo 实测该回调会触发。
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        showPreferences(self)
        return true
    }

    /// 后启动的实例会 post `com.autoraise.app.activate`；主实例收到后打开设置窗口。
    /// 只有主实例注册 observer，post 方不注册，避免自收导致启动时误弹窗口。
    @objc private func activateExistingInstance(_ note: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.showPreferences(self)
        }
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        accessibilityHeartbeat?.invalidate()
        accessibilityHeartbeat = nil
        NotificationCenter.default.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        stopService(self)
        MASShortcutMonitor.shared().unregisterAllShortcuts()
    }

    // MARK: - Status bar

    func setupStatusBar() {
        menuBarItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = menuBarItem?.button else { return }

        // 取图标：优先 MenuIcon → SF Symbol → 兜底标题"AR"
        var img = NSImage(named: "MenuIcon")
        if img == nil, #available(macOS 11, *) {
            img = NSImage(systemSymbolName: "cursorarrow.motionlines.click",
                          accessibilityDescription: "AutoRaise")
        }
        img?.isTemplate = true
        button.image = img
        if img == nil { button.title = "AR" }

        button.action = #selector(menuBarItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.toolTip = "AutoRaise"

        menuItemAccessibility.title = "授予辅助功能权限"
        menuItemAccessibility.action = #selector(requestAccessibility(_:))
        menu.addItem(menuItemAccessibility)

        menuItemPrefs.title = "首选项"
        menuItemPrefs.action = #selector(showPreferences(_:))
        menu.addItem(menuItemPrefs)

        menu.addItem(NSMenuItem.separator())

        menuItemQuit.title = "退出"
        menuItemQuit.action = #selector(quitApplication(_:))
        menu.addItem(menuItemQuit)

        menuBarItem?.isVisible = true
    }

    func updateAccessibilityState() {
        let trusted = AXIsProcessTrusted()
        menuItemAccessibility.isHidden = trusted
        menuBarItem?.button?.appearsDisabled = !trusted
        menuBarItem?.button?.toolTip = trusted ? "AutoRaise" :
            "AutoRaise 没有辅助功能权限，无法提升或聚焦任何窗口"
    }

    /// 权限状态变化时刷新菜单，不用等用户下次点图标。三路冗余，任何一路被吞掉都不影响：
    /// - `com.apple.accessibility.api`：HIServices 在辅助功能列表变更时发的分布式通知
    ///   （字面量已在本机 dyld shared cache 中核实存在）；Apple 未公开文档化，「移除整行」不发它。
    /// - `NSWorkspace.didActivateApplicationNotification`：实测每次 App 切换都触发，
    ///   覆盖「去系统设置授权完切回来」的主场景。
    /// - 低频心跳：直接读 `AXIsProcessTrusted()`，不依赖任何未文档化通知；
    ///   实测单次约 0.009ms，5 秒一次成本可忽略。
    private func startAccessibilityMonitoring() {
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(accessibilityStateChanged(_:)),
            name: Notification.Name("com.apple.accessibility.api"),
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(accessibilityStateChanged(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        let heartbeat = Timer(timeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.updateAccessibilityState()
        }
        RunLoop.main.add(heartbeat, forMode: .common)
        accessibilityHeartbeat = heartbeat
    }

    @objc private func accessibilityStateChanged(_ note: Notification) {
        DispatchQueue.main.async { [weak self] in
            self?.updateAccessibilityState()
        }
    }

    @objc func requestAccessibility(_ sender: AnyObject) {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
        updateAccessibilityState()
    }

    @objc func menuBarItemClicked(_ sender: NSStatusBarButton) {
        updateAccessibilityState()
        guard let event = NSApp.currentEvent else {
            toggleService()
            return
        }
        if event.type == .rightMouseUp {
            // 右键：弹出功能菜单（首选项 / 辅助功能 / 退出）
            menuBarItem?.menu = menu
            menuBarItem?.button?.performClick(nil)
            menuBarItem?.menu = nil
        } else {
            // 左键：启停 AutoRaise 守护进程（原版行为）
            toggleService()
        }
    }

    // MARK: - Preferences window (SwiftUI)

    @objc func showPreferences(_ sender: AnyObject) {
        guard #available(macOS 14, *) else {
            let alert = NSAlert()
            alert.messageText = "需要 macOS 14 或更高版本"
            alert.informativeText = "本版本的首选项界面使用 SwiftUI 构建，需要 macOS 14 或更高版本。"
            alert.runModal()
            return
        }
        if preferencesWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 480),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "AutoRaise 首选项"
            window.center()
            window.contentViewController = NSHostingController(rootView: PreferencesView())
            window.isReleasedWhenClosed = false
            preferencesWindow = window
        }
        preferencesWindow?.makeKeyAndOrderFront(self)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Service control

    func toggleService() {
        // MASShortcut 热键回调的线程归属无法从预编译 framework 证实；
        // 统一在这里挡一道，保证所有 UI / Process 操作都落在主线程。
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.toggleService() }
            return
        }
        if autoRaiseService.isRunning {
            stopService(self)
        } else {
            startService(self)
        }
    }

    @objc func startService(_ sender: AnyObject) {
        // 所有 UI / Process 操作统一在主线程。MASShortcut 热键回调线程归属无法证实，
        // 且 @objc 入口可能被任意调用点直接触发，所以每个入口各挡一道。
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.startService(sender) }
            return
        }
        guard !autoRaiseService.isRunning else {
            setRunningIcon(running: true)
            return
        }
        readPreferences()
        guard let autoRaiseCmd = Bundle.main.url(forResource: "AutoRaise", withExtension: "") else {
            NSLog("[AutoRaise] 找不到 daemon 可执行文件，启动中止")
            setRunningIcon(running: false)
            return
        }

        let process = Process()
        process.launchPath = autoRaiseCmd.path
        process.arguments = buildArguments()

        // daemon 退出时（崩溃、缺辅助功能权限立即退出、被系统杀掉）把图标设回停止态，
        // 避免界面显示「运行中」而功能其实已死。
        // terminationHandler 在后台线程触发，UI 必须切回主线程；用 identity 判断，
        // 防止 stop→start 快速切换时旧进程的回调把新进程的图标误关。
        process.terminationHandler = { [weak self] terminated in
            DispatchQueue.main.async {
                guard let self = self,
                      self.autoRaiseService === terminated else { return }
                self.setRunningIcon(running: false)
                self.updateAccessibilityState()
            }
        }

        autoRaiseService = process
        do {
            try process.run()
        } catch {
            NSLog("[AutoRaise] daemon 启动失败: \(error.localizedDescription)")
            setRunningIcon(running: false)
            return
        }
        setRunningIcon(running: true)
    }

    func buildArguments() -> [String] {
        var args: [String] = []
        let poll = max(pollMillis, 1)
        args += ["-delay", String(autoRaiseDelay / poll)]
        args += ["-focusDelay", String(autoFocusDelay / poll)]
        args += ["-mouseDelta", String(mouseDelta)]
        args += ["-pollMillis", String(pollMillis)]
        if enableWarp {
            args += ["-warpX", "0.5", "-warpY", "0.5"]
            args += ["-scale", enableCursorScaling ? "2.0" : "1.0"]
            if warpOnlyAcrossScreens {
                args += ["-warpOnlyAcrossScreens", "true"]
            }
        }
        if enableAltTaskSwitcher {
            args += ["-altTaskSwitcher", "true"]
        }
        if !ignoreApps.isEmpty {
            args += ["-ignoreApps", ignoreApps]
        }
        if !ignoreTitles.isEmpty {
            args += ["-ignoreTitles", ignoreTitles]
        }
        if !stayFocusedBundleIds.isEmpty {
            args += ["-stayFocusedBundleIds", stayFocusedBundleIds]
        }
        if !disableKey.isEmpty {
            args += ["-disableKey", disableKey]
        }
        if !requireMouseStop {
            args += ["-requireMouseStop", "false"]
        }
        if requireMultipleScreens {
            args += ["-requireMultipleScreens", "true"]
        }
        if requireScreenChange {
            args += ["-requireScreenChange", "true"]
        }
        if ignoreSpaceChanged {
            args += ["-ignoreSpaceChanged", "true"]
        }
        if invertDisableKey {
            args += ["-invertDisableKey", "true"]
        }
        if invertIgnoreApps {
            args += ["-invertIgnoreApps", "true"]
        }
        return args
    }

    @objc func stopService(_ sender: AnyObject) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.stopService(sender) }
            return
        }
        // 必须先换实例再 terminate：否则 waitUntilExit() 内部若主队列被 drain，
        // 旧进程的 terminationHandler 会抢在换实例之前命中 identity，冗余刷新仍会发生。
        // 实测（20/20）：顶层同步调用「点图标停止 / 退出 app」下这个顺序是必需的。
        let stopping = autoRaiseService
        autoRaiseService = Process()
        if stopping.isRunning {
            stopping.terminate()
            stopping.waitUntilExit()
        }
        setRunningIcon(running: false)
    }

    func setRunningIcon(running: Bool) {
        guard let button = menuBarItem?.button else { return }
        let key = running ? "MenuIconRunning" : "MenuIcon"
        var img = NSImage(named: key)
        if img == nil, #available(macOS 11, *) {
            img = NSImage(systemSymbolName: "cursorarrow.motionlines.click",
                          accessibilityDescription: "AutoRaise")
        }
        img?.isTemplate = true
        button.image = img
        if img == nil { button.title = running ? "AR▶" : "AR" }
    }

    @objc func quitApplication(_ sender: AnyObject) {
        NSApplication.shared.terminate(sender)
    }

    // MARK: - Hotkey

    func registerHotkeyFromDefaults() {
        let monitor = MASShortcutMonitor.shared()
        monitor.unregisterAllShortcuts()
        if let data = prefs.data(forKey: "HotKey"),
           let sc = NSKeyedUnarchiver.unarchiveObject(with: data) as? MASShortcut {
            monitor.register(sc, withAction: { [weak self] in
                self?.toggleService()
            })
        }
    }

    // MARK: - Login item

    func syncLoginItem() {
        let enabled = prefs.bool(forKey: "openAtLogin")
        setLoginItem(enabled: enabled)
    }

    func setLoginItem(enabled: Bool) {
        guard #available(macOS 13.0, *) else { return }
        do {
            if enabled {
                if SMAppService.mainApp.status == .requiresApproval {
                    showLoginItemApproval()
                } else if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                    if SMAppService.mainApp.status == .requiresApproval {
                        showLoginItemApproval()
                    }
                }
            } else if SMAppService.mainApp.status != .notRegistered {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "无法更新登录项"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    @available(macOS 13.0, *)
    func showLoginItemApproval() {
        let alert = NSAlert()
        alert.messageText = "需要批准"
        alert.informativeText = "允许 AutoRaise 在您登录时自动打开：请在「系统设置 > 通用 > 登录项」中批准。"
        alert.addButton(withTitle: "打开登录项")
        alert.addButton(withTitle: "暂不")
        if alert.runModal() == .alertFirstButtonReturn {
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    // MARK: - Preferences reading

    func readPreferences() {
        // 从未设置过时用 300ms 默认（与 PreferencesView 的 @AppStorage 初值一致）。
        // @AppStorage 的初值只在「键不存在时用于界面显示」，不会写回 UserDefaults，
        // 所以这里 integer(forKey:) 对缺失键会返回 0 —— 而 buildArguments() 里
        // autoRaiseDelay / poll = 0，daemon 拿到 -delay 0 的语义正是「关闭提升」。
        // 结果就是全新安装后界面显示 300ms、实际功能整个静默失效。
        // 与下面 pollMillis / requireMouseStop 的处理方式保持一致：缺失才补默认，
        // 已存在（含用户显式设成 0）则原样尊重。
        if prefs.object(forKey: "autoRaiseDelay") == nil {
            autoRaiseDelay = 300
        } else {
            autoRaiseDelay = max(prefs.integer(forKey: "autoRaiseDelay"), 0)
        }
        if prefs.object(forKey: "autoFocusDelay") == nil {
            autoFocusDelay = 300
        } else {
            autoFocusDelay = max(prefs.integer(forKey: "autoFocusDelay"), 0)
        }
        mouseDelta = prefs.integer(forKey: "mouseDelta")
        if mouseDelta < 0 { mouseDelta = 0 }
        // 从未设置过时保持 50ms 默认；已设置则夹到最小 20ms。
        // 旧实现「<20 就重置为 50」与 UI 上「最小 20」的提示不一致。
        if prefs.object(forKey: "pollMillis") == nil {
            pollMillis = 50
        } else {
            pollMillis = max(prefs.integer(forKey: "pollMillis"), 20)
        }

        enableWarp = prefs.bool(forKey: "enableWarp")
        enableCursorScaling = prefs.bool(forKey: "enableCursorScaling")
        enableAltTaskSwitcher = prefs.bool(forKey: "enableAltTaskSwitcher")
        warpOnlyAcrossScreens = prefs.bool(forKey: "warpOnlyAcrossScreens")
        enableOnLaunch = prefs.bool(forKey: "enableOnLaunch")
        hideMenubarIcon = prefs.bool(forKey: "hideMenubarIcon")

        if prefs.object(forKey: "requireMouseStop") == nil {
            requireMouseStop = true
        } else {
            requireMouseStop = prefs.bool(forKey: "requireMouseStop")
        }
        requireMultipleScreens = prefs.bool(forKey: "requireMultipleScreens")
        requireScreenChange = prefs.bool(forKey: "requireScreenChange")
        ignoreSpaceChanged = prefs.bool(forKey: "ignoreSpaceChanged")
        invertDisableKey = prefs.bool(forKey: "invertDisableKey")
        invertIgnoreApps = prefs.bool(forKey: "invertIgnoreApps")

        ignoreApps = prefs.string(forKey: "ignoreApps") ?? ""
        ignoreTitles = prefs.string(forKey: "ignoreTitles") ?? ""
        stayFocusedBundleIds = prefs.string(forKey: "stayFocusedBundleIds") ?? ""
        disableKey = prefs.string(forKey: "disableKey") ?? "control"

        menuBarItem?.isVisible = !hideMenubarIcon
    }

    // MARK: - Defaults change observer (decoupled from SwiftUI)

    @objc func defaultsChanged(_ notification: Notification) {
        debounceItem?.cancel()
        debounceItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.readPreferences()
            self.registerHotkeyFromDefaults()
            if self.autoRaiseService.isRunning {
                self.stopService(self)
                self.startService(self)
            }
            self.syncLoginItem()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: debounceItem!)
    }
}