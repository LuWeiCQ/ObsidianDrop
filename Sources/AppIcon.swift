import AppKit

// MARK: - 应用图标资源（1.7.0）
//
// 图标由 tools/make-icon.swift 生成，build.sh 拷进 Contents/Resources/。
// 菜单栏必须走模板图（isTemplate = true），否则深色菜单栏上会糊成一团；
// 找不到文件时回退到系统符号，保证「源码直跑 / 资源缺失」也不会开天窗。

enum AppIcon {
    static func menuBarImage() -> NSImage {
        if let u = Bundle.main.url(forResource: "MenuBarTemplate", withExtension: "png"),
           let img = NSImage(contentsOf: u) {
            img.size = NSSize(width: 18, height: 18)
            img.isTemplate = true
            img.accessibilityDescription = "ObsidianDrop"
            return img
        }
        let fallback = NSImage(systemSymbolName: "tray.and.arrow.down.fill",
                               accessibilityDescription: "ObsidianDrop")
            ?? NSImage(size: NSSize(width: 18, height: 18))
        fallback.isTemplate = true
        return fallback
    }

    /// 关于窗口 / 面板里可能用到的品牌图。取不到返回 nil，调用方自己回退。
    static func applicationImage() -> NSImage? {
        guard let u = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
              let img = NSImage(contentsOf: u) else { return nil }
        img.size = NSSize(width: 64, height: 64)
        return img
    }
}
