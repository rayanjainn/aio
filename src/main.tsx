import React from "react";
import ReactDOM from "react-dom/client";
import App from "./App";
import { initAppearance } from "./lib/appearance";

initAppearance().catch(() => {});

ReactDOM.createRoot(document.getElementById("root")!).render(
  <React.StrictMode>
    <App />
  </React.StrictMode>
);
