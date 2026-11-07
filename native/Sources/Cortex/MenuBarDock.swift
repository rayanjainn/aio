import AppKit
import Combine

/// The Dock as a menu-bar menu: pinned and running apps, folders, with their icons.
@MainActor
final class MenuBarDock: NSObject, NSMenuDelegate {
    private var item: NSStatusItem?
    private weak var model: DockModel?

    func attach(_ model: DockModel) { self.model = model }

    func setVisible(_ on: Bool) {
        if on, item == nil {
            let i = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            i.button?.image = NSImage(systemSymbolName: "dock.rectangle", accessibilityDescription: "Cortex Dock")
            let menu = NSMenu()
            menu.delegate = self
            i.menu = menu
            item = i
        } else if !on, let i = item {
            NSStatusBar.system.removeStatusItem(i)
            item = nil
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let model else { return }
        for it in model.items where it.kind == .app || it.kind == .folder {
            let mi = NSMenuItem(title: it.name + (it.running ? "  •" : ""), action: #selector(open(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = it.id
            let icon = model.icon(for: it).copy() as? NSImage
            icon?.size = NSSize(width: 18, height: 18)
            mi.image = icon
            menu.addItem(mi)
        }
    }

    @objc private func open(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let it = model?.item(withID: id) else { return }
        model?.activate(it)
    }
}
