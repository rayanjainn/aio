//! cortexd (installed as Helpers/aiod) — started by AIO.app; exits when the app that launched it is gone.

use cortexd_lib::{engine::Engine, rpc};
use std::io::Write;

/// stderr + ~/.cortex/logs/cortexd.log, tantivy / embedding chatter muted.
struct Tee(Option<std::fs::File>);
impl Write for Tee {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        let _ = std::io::stderr().write_all(buf);
        if let Some(f) = self.0.as_mut() { let _ = f.write_all(buf); }
        Ok(buf.len())
    }
    fn flush(&mut self) -> std::io::Result<()> { Ok(()) }
}

fn init_logging() {
    let dir = dirs::home_dir().unwrap_or_default().join(".cortex/logs");
    let _ = std::fs::create_dir_all(&dir);
    let path = dir.join("cortexd.log");
    if std::fs::metadata(&path).map(|m| m.len() > 5_000_000).unwrap_or(false) {
        let _ = std::fs::rename(&path, dir.join("cortexd.log.1"));
    }
    let file = std::fs::OpenOptions::new().create(true).append(true).open(path).ok();
    let shared = std::sync::Arc::new(std::sync::Mutex::new(Tee(file)));
    struct W(std::sync::Arc<std::sync::Mutex<Tee>>);
    impl Write for W {
        fn write(&mut self, b: &[u8]) -> std::io::Result<usize> { self.0.lock().map(|mut t| t.write(b)).unwrap_or(Ok(b.len())) }
        fn flush(&mut self) -> std::io::Result<()> { Ok(()) }
    }
    tracing_subscriber::fmt()
        .with_env_filter(
            std::env::var("CORTEX_LOG").unwrap_or_else(|_| "info,tantivy=warn,cortexd_lib::embed=warn,cortexd_lib::embeddings=warn".into()),
        )
        .with_ansi(false)
        .with_writer(move || W(shared.clone()))
        .compact()
        .init();
}

#[tokio::main(worker_threads = 4)]
async fn main() {
    init_logging();
    tracing::info!("cortexd {} starting (pid {})", env!("CARGO_PKG_VERSION"), std::process::id());

    // Never outlive the app: when the launching process dies we are re-parented to launchd (pid 1).
    #[cfg(unix)]
    {
        let parent = unsafe { libc::getppid() };
        if parent > 1 {
            tokio::spawn(async move {
                loop {
                    tokio::time::sleep(std::time::Duration::from_secs(2)).await;
                    if unsafe { libc::getppid() } != parent { tracing::info!("parent exited — shutting down"); let _ = std::fs::remove_file(rpc::socket_path()); std::process::exit(0); }
                }
            });
        }
    }

    let engine = match Engine::start().await {
        Ok(e) => e,
        Err(e) => { tracing::error!("engine failed to start: {e}"); std::process::exit(1); }
    };
    if let Err(e) = rpc::serve(engine).await {
        tracing::error!("rpc server: {e}");
        std::process::exit(1);
    }
}
