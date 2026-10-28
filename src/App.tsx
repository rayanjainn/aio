import { useState, useEffect, useRef, lazy, Suspense } from "react";
import { CommandPalette } from "./components/CommandPalette";
import { ErrorBoundary } from "./components/ErrorBoundary";
import { IN_TAURI, invoke, resizeWindow } from "./lib/tauri";
import "./styles/globals.css";

const Onboarding       = lazy(() => import("./components/Onboarding"));
const Setup            = lazy(() => import("./components/Setup"));
const Settings         = lazy(() => import("./components/Settings"));
const ExecutionConfirm = lazy(() => import("./components/ExecutionConfirm"));
const Studio           = lazy(() => import("./components/Studio"));

type AppScreen = "loading" | "setup" | "onboarding" | "main";

export interface ExecutorPlan {
  command: string;
  explanation: string;
  is_destructive: boolean;
}

export default function App() {
  const [screen, setScreen]             = useState<AppScreen>("loading");
  const [showSettings, setShowSettings] = useState(false);
  const [execPlan, setExecPlan]         = useState<ExecutorPlan | null>(null);
  const [studioTab, setStudioTab]       = useState<string | null>(null);

  useEffect(() => {
    (async () => {
      if (!IN_TAURI) { setScreen("main"); return; }
      try {
        const onboarded = await invoke<boolean>("get_onboarding_complete");
        setScreen(onboarded ? "main" : "onboarding");
      } catch {
        setScreen("main");
      }
    })();
  }, []);

  // Resize the window to fit each screen — palette is compact,
  // onboarding/setup/settings need more room.
  useEffect(() => {
    if (!IN_TAURI || screen === "loading") return;
    const [w, h] =
      studioTab                 ? [1080, 720] :
      showSettings              ? [820, 600] :
      screen === "onboarding"   ? [820, 680] :
      screen === "setup"        ? [640, 560] :
                                  [880, 540];   // main palette (room for preview pane)
    resizeWindow(w, h);
  }, [screen, showSettings, studioTab]);

  // Click-away closes the window everywhere. External opens (OAuth, perms,
  // downloads) suppress this; it re-arms whenever Cortex regains focus.
  useEffect(() => {
    if (!IN_TAURI || screen === "loading") return;
    // The studio stays open while you click on the widgets it is arranging.
    invoke("set_autohide", { enabled: !studioTab }).catch(() => {});
  }, [screen, showSettings, studioTab]);

  useEffect(() => {
    if (!IN_TAURI) return;
    let unlisten: (() => void) | undefined;
    (async () => {
      const { getCurrentWindow } = await import("@tauri-apps/api/window");
      unlisten = await getCurrentWindow().onFocusChanged(({ payload: focused }) => {
        if (focused && !studioRef.current) invoke("set_autohide", { enabled: true }).catch(() => {});
      });
    })();
    return () => unlisten?.();
  }, []);

  const studioRef = useRef<string | null>(null);
  studioRef.current = studioTab;

  // Tray / widget menus / search widget → open the studio (or just the palette).
  useEffect(() => {
    if (!IN_TAURI) return;
    let unlisten: (() => void) | undefined;
    (async () => {
      const { listen } = await import("@tauri-apps/api/event");
      unlisten = await listen<string>("open-studio", e => {
        setShowSettings(false);
        setStudioTab(e.payload === "palette" ? null : e.payload || "widgets");
      });
    })();
    return () => unlisten?.();
  }, []);

  // Tray "Re-run Onboarding" → backend emits this event.
  useEffect(() => {
    if (!IN_TAURI) return;
    let unlisten: (() => void) | undefined;
    (async () => {
      const { listen } = await import("@tauri-apps/api/event");
      unlisten = await listen("open-onboarding", () => { setShowSettings(false); setScreen("onboarding"); });
    })();
    return () => unlisten?.();
  }, []);

  // ⌘, toggles settings
  useEffect(() => {
    const fn = (e: KeyboardEvent) => {
      if ((e.metaKey || e.ctrlKey) && e.key === ",") {
        e.preventDefault();
        setShowSettings(s => !s);
      }
    };
    window.addEventListener("keydown", fn);
    return () => window.removeEventListener("keydown", fn);
  }, []);

  if (screen === "loading") return null;

  return (
    <ErrorBoundary label="app">
    <Suspense fallback={null}>
      {screen === "setup" && <Setup onReady={() => setScreen("onboarding")} />}

      {screen === "onboarding" && <Onboarding onComplete={() => setScreen("main")} />}

      {/* One surface at a time: overlays used to sit on top of a live palette
          and, being translucent, showed it through. */}
      {screen === "main" && !studioTab && !showSettings && (
        <CommandPalette
          onOpenSettings={() => setShowSettings(true)}
          onExecPlan={(plan: ExecutorPlan) => setExecPlan(plan)}
          onOpenOnboarding={() => setScreen("onboarding")}
          onOpenStudio={(tab: string) => setStudioTab(tab)}
        />
      )}

      {showSettings && <Settings onClose={() => setShowSettings(false)} />}

      {studioTab && <Studio tab={studioTab} onClose={() => setStudioTab(null)} />}

      {execPlan && (
        <ExecutionConfirm
          plan={execPlan}
          onClose={() => setExecPlan(null)}
          /* don't close on confirm — the dialog runs the command and shows
             output itself; closing here unmounted it before output appeared. */
        />
      )}
    </Suspense>
    </ErrorBoundary>
  );
}
