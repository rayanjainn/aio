import { useEffect, useCallback } from "react";

interface UseKeyboardOptions {
  onUp: () => void;
  onDown: () => void;
  onEnter: () => void;
  onEscape: () => void;
  onTab: () => void;
}

export function useKeyboard({
  onUp,
  onDown,
  onEnter,
  onEscape,
  onTab,
}: UseKeyboardOptions) {
  const handler = useCallback(
    (e: KeyboardEvent) => {
      switch (e.key) {
        case "ArrowUp":
          e.preventDefault();
          onUp();
          break;
        case "ArrowDown":
          e.preventDefault();
          onDown();
          break;
        case "Enter":
          e.preventDefault();
          onEnter();
          break;
        case "Escape":
          e.preventDefault();
          onEscape();
          break;
        case "Tab":
          e.preventDefault();
          onTab();
          break;
      }
    },
    [onUp, onDown, onEnter, onEscape, onTab]
  );

  useEffect(() => {
    window.addEventListener("keydown", handler);
    return () => window.removeEventListener("keydown", handler);
  }, [handler]);
}
