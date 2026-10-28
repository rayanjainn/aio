import React, { lazy, Suspense } from "react";
import ReactDOM from "react-dom/client";
import App from "./App";
import { initAppearance } from "./lib/appearance";

const WidgetHost = lazy(() => import("./widgets/WidgetHost"));

initAppearance().catch(() => {});

// One bundle, several windows: the hash picks the surface.
const widgetId = location.hash.match(/^#\/widget\/([\w-]+)/)?.[1];

ReactDOM.createRoot(document.getElementById("root")!).render(
  <React.StrictMode>
    {widgetId
      ? <Suspense fallback={null}><WidgetHost id={widgetId} /></Suspense>
      : <App />}
  </React.StrictMode>
);
