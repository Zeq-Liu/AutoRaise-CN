# AutoRaise 6.1

简体中文版。基于上游 [AutoRaise-UI v5.7.0](https://github.com/sbmpost/AutoRaise-UI) 与
[AutoRaise v5.7](https://github.com/sbmpost/AutoRaise)（GPL-3.0）。

**系统要求：macOS 14.0+** ｜ 通用二进制（Intel + Apple Silicon）

---

## 亮点

1. **关掉上层窗口后，鼠标移到下层窗口不再提升** —— 已修复。
2. **中文系统上的一批功能失效** —— 已修复。不是翻译问题，是上游在非英文系统上的功能性缺陷。

---

## 修复

### 核心

- 关闭上层窗口后，鼠标移到下层窗口永久不再提升

### 引擎

- 跨应用提升失败时不再整轮放弃
- 取窗口 id 失败不再被误判为窗口已销毁
- 窗口 id 被系统复用时不再永久卡死
- 延迟触发提升时不再访问已释放对象
- 无标题窗口不再绕过忽略应用名单
- 后台应用的无标题主窗口不再被拒绝提升
- 应用关完所有窗口后不再静默不激活

### 中文系统

- 访达（Finder）的识别不再依赖应用显示名
- 系统设置等系统应用的窗口可正常提升（原来中文系统下失效）
- 忽略应用名单的匹配不再受应用显示名语言影响

### 界面

- 菜单栏、偏好窗口、弹窗全部简体中文
- 偏好窗口重写为 SwiftUI，移除 CocoaPods，可断网编译
- 设置项 11 项可用性改进：合并绕口的双开关、延迟显示真实生效值、中文逗号自动纠正、
  隐藏菜单栏图标前弹确认并写明恢复方式等
- 左键点图标 = 启停，右键 = 菜单
- 后台服务异常退出时图标自动回正
- 全新安装不再静默失效（原来界面显示 300ms、实际功能不工作）
- 旧配置自动迁移

---

## 兼容性

偏好键名、命令行参数与上游完全一致，零迁移成本。上游 CLI 用法、第三方脚本继续有效。

---

## 已知限制

- **未用 Apple Developer ID 签名**（需年费 $99）。首次打开需手动放行，包内附一键脚本。
- **「开机时自动启动」在未签名构建下不可用** —— 登录项注册需要签名带 Team ID。
- 跨应用提升依赖系统激活接口，「提升」动作本身只在应用内生效。
- 「强制聚焦优先」依赖私有接口，上游自己标为实验特性，未来 macOS 可能失效。

---

## 安装

1. 打开 DMG
2. 在 `安装 AutoRaise.command` 上 **右键 → 打开**（未签名脚本首次必然被 Gatekeeper 拦）
3. 按提示输入密码，脚本自动备份旧版、装到「应用程序」、去隔离标记
4. 启动后**必须**授予辅助功能权限（系统设置 → 隐私与安全性 → 辅助功能）

详细步骤见 DMG 内 `安装说明.md`。

---

## 升级与回退

**升级**：替换 `/Applications/AutoRaise.app` 即可，旧配置自动迁移。

**回退到上游 v5.7**：

```bash
git checkout 2dab968 -- AutoRaise.mm Launcher/ Info.plist
xcodebuild -project AutoRaise.xcodeproj -scheme AutoRaise -configuration Release build
```

**重置配置**：`defaults delete com.autoraise.app`

---

## 许可证

**GNU GPL v3**（daemon 原始为 GPL-2.0-or-later，允许升版）。

原作者的版权与署名完整保留，未作删改。本仓库为修改版（derivative work），**非上游官方发布**。

- 原作者：Stefan Post（[sbmpost](https://github.com/sbmpost)）、Lothar Haeger（[lhaeger](https://github.com/lhaeger)）
- 中文版维护：coderLiu
- 修改日期：2026-11
- 第三方：[MASShortcut](https://github.com/shpakovski/MASShortcut)（MIT，© Vadim Shpakovski），已离线重建

下游复用须遵守 GPL-3.0：保留 `LICENSE.md` 与本声明。
