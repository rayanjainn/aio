/**
 * Root of a desktop-widget window (`index.html#/widget/<id>`). Drag anywhere
 * on the slab to move it; right-click for the native menu (size, layer, lock,
 * settings, remove). Edit mode (from Studio) wiggles widgets iOS-style.
 */
import { useCallback, useEffect, useState } from "react";
import type { Widget, WidgetConfig } from "./types";
import { SIZES, sizeClass } from "./types";
import { KIND_MAP } from "./registry";
import { invoke } from "../lib/tauri";
import { WidgetCard } from "./WidgetCard";

export default function WidgetHost({ id }: { id: string }) {
  const [w, setW] = useState<Widget | null>(null);
  const [edit, setEdit] = useState(false);

  useEffect(() => {
    document.documentElement.classList.add("widget-window");
    invoke<Widget | null>("widget_get", { id }).then(setW).catch(() => {});
    const offs: (() => void)[] = [];
    import("@tauri-apps/api/event").then(async ({ listen }) => {
      offs.push(await listen<Widget>("widget-updated", e => { if (e.payload.id === id) setW(e.payload); }));
      offs.push(await listen<boolean>("widgets-edit-mode", e => setEdit(e.payload)));
    });
    return () => offs.forEach(f => f());
  }, [id]);

  const update = useCallback((patch: Partial<Widget> & { config?: WidgetConfig }) => {
    setW(cur => cur && { ...cur, ...patch, config: patch.config ? { ...cur.config, ...patch.config } : cur.config });
    invoke("widget_update", { id, patch }).catch(() => {});
  }, [id]);
  const setConfig = useCallback((config: WidgetConfig) => update({ config }), [update]);
  const remove = useCallback(() => invoke("widget_remove", { id }).catch(() => {}), [id]);

  const onMouseDown = async (e: React.MouseEvent) => {
    if (e.button !== 0 || !w || w.locked) return;
    if ((e.target as HTMLElement).closest("button, input, textarea, select, a, [data-nodrag]")) return;
    const { getCurrentWindow } = await import("@tauri-apps/api/window");
    getCurrentWindow().startDragging().catch(() => {});
  };

  const onContextMenu = async (e: React.MouseEvent) => {
    e.preventDefault();
    if (!w) return;
    const { Menu, MenuItem, CheckMenuItem, PredefinedMenuItem, Submenu } = await import("@tauri-apps/api/menu");
    const k = KIND_MAP[w.kind];
    const cur = sizeClass(w.w, w.h);
    const sizes = await Promise.all((k?.sizes ?? ["s"]).map(s => CheckMenuItem.new({
      text: SIZES[s].label, checked: s === cur,
      action: () => update({ w: SIZES[s].w, h: SIZES[s].h }),
    })));
    const menu = await Menu.new({ items: [
      await Submenu.new({ text: "Size", items: sizes }),
      await CheckMenuItem.new({ text: "Keep on Desktop", checked: w.layer === "desktop", action: () => update({ layer: "desktop" }) }),
      await CheckMenuItem.new({ text: "Float Above Windows", checked: w.layer === "floating", action: () => update({ layer: "floating" }) }),
      await CheckMenuItem.new({ text: "Lock Position", checked: w.locked, action: () => update({ locked: !w.locked }) }),
      await PredefinedMenuItem.new({ item: "Separator" }),
      await MenuItem.new({ text: "Edit Widget…", action: () => invoke("open_studio", { tab: `widget:${w.id}` }).catch(() => {}) }),
      await MenuItem.new({ text: "Edit Widgets & Dock…", action: () => invoke("open_studio", { tab: "widgets" }).catch(() => {}) }),
      await PredefinedMenuItem.new({ item: "Separator" }),
      await MenuItem.new({ text: `Remove “${k?.name ?? w.kind}”`, action: remove }),
    ] });
    menu.popup().catch(() => {});
  };

  if (!w) return null;
  return (
    <div className="w-root" onMouseDown={onMouseDown} onContextMenu={onContextMenu}>
      <WidgetCard widget={w} setConfig={setConfig} edit={edit} onRemove={remove} />
    </div>
  );
}
