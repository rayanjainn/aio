import React, { lazy, Suspense } from "react";
import ReactDOM from "react-dom/client";
import App from "./App";
import { initAppearance } from "./lib/appearance";

const WidgetHost = lazy(() => import("./widgets/WidgetHost"));
const Dock       = lazy(() => import("./dock/Dock"));
const Island     = lazy(() => import("./island/Island"));

initAppearance().catch(() => {});

// One bundle, several windows: the hash picks the surface.
const widgetId = location.hash.match(/^#\/widget\/([\w-]+)/)?.[1];
const isDock = location.hash.startsWith("#/dock");
const isIsland = location.hash.startsWith("#/island");

ReactDOM.createRoot(document.getElementById("root")!).render(
  <React.StrictMode>
    {widgetId ? <Suspense fallback={null}><WidgetHost id={widgetId} /></Suspense>
      : isDock ? <Suspense fallback={null}><Dock /></Suspense>
      : isIsland ? <Suspense fallback={null}><Island /></Suspense>
      : <App />}
  </React.StrictMode>
);
