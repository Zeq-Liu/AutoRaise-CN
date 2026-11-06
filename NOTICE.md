AutoRaise & Launcher（简体中文修改版）
======================================

本软件是基于以下上游项目的修改版本（derivative work）：

  上游 UI 仓库 : https://github.com/sbmpost/AutoRaise-UI
  上游 daemon  : https://github.com/sbmpost/AutoRaise   (Stefan Post)
                 https://github.com/lhaeger/AutoRaise    (Lothar Haeger)

原版权声明见 LICENSE.md（GNU General Public License v3）。
原作者：Stefan Post、Lothar Haeger。其版权与署名予以完整保留，未作删改。

本修改版变更内容：
  - 简体中文界面（菜单栏、偏好窗口、弹窗等全部可见文案）
  - 偏好窗口使用 SwiftUI 在 macOS 14 及以上重写（原基于 XIB / Interface Builder）
  - 离线重建 MASShortcut 依赖，移除 CocoaPods，支持无网络 Xcode 编译

修改日期：2026-11-01
修改者  ：coderLiu（开源贡献者，昵称，未使用真实姓名）

本修改版以 GNU General Public License v3 发布，与上游许可完全一致。
根据 GPL-3.0 第 5(a) 条，本文件及 README.md 顶部的修改声明即为对
"已修改及修改日期"的显著标注。

上游许可（均予保留）
--------------------
本仓库聚合了两个上游项目的代码，外加一个第三方依赖，其许可证均须保留：

1. UI 外壳（AppDelegate / MainMenu.xib / PreferencesView.swift 等）
   来源：https://github.com/sbmpost/AutoRaise-UI
   许可：GNU GPL v3（全文见 LICENSE.md）
   原版权：Stefan Post, Lothar Haeger

2. 焦点跟随 daemon（AutoRaise.mm）
   来源：https://github.com/sbmpost/AutoRaise
   许可：GNU GPL v2.0 或更高版本（"version 2 of the License, or any later version"）
   原版权：Copyright (C) 2026 sbmpost（见 AutoRaise.mm 文件头声明，已保留未删）
   说明：因 daemon 允许"任意更高版本"，本仓库整体以 GPL-3.0 分发，符合其授权。

3. 第三方依赖 MASShortcut.framework（离线重建，提供快捷键监听）
   来源：https://github.com/shpakovski/MASShortcut
   许可：MIT（见 MASShortcut.framework/LICENSE_MASShortcut.txt）
   原作者：Vadim Shpakovski

三者许可文本（GPL-3.0 / GPL-2.0 / MIT）各自独立，互不影响；本作品作为整体以
GPL-3.0 分发，同时保留 daemon 的 GPL-2.0-or-later 标识与 MASShortcut 的 MIT 声明。
