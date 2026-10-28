import { Component, type ReactNode } from "react";

/**
 * Keeps one broken view from blanking the whole window. Shows a compact
 * recoverable error instead; "Try again" remounts the subtree.
 */
export class ErrorBoundary extends Component<{ children: ReactNode; label?: string }, { error: Error | null }> {
  state = { error: null as Error | null };

  static getDerivedStateFromError(error: Error) { return { error }; }

  componentDidCatch(error: Error) { console.error(`[cortex] ${this.props.label ?? "view"} crashed`, error); }

  render() {
    if (!this.state.error) return this.props.children;
    return (
      <div className="glass-window" style={{ alignItems: "center", justifyContent: "center", gap: 12, padding: 24, textAlign: "center" }}>
        <div className="display" style={{ fontSize: 15, color: "rgba(255,255,255,0.85)" }}>Something went wrong</div>
        <div className="mono" style={{ fontSize: 11.5, color: "rgba(255,255,255,0.4)", maxWidth: 420, wordBreak: "break-word" }}>
          {this.state.error.message}
        </div>
        <button className="btn-glass btn-accent" onClick={() => this.setState({ error: null })}>Try again</button>
      </div>
    );
  }
}
