pub mod capture;
pub mod context;
pub mod memory;
pub mod privacy;
pub mod session;
pub mod storage;

#[allow(unused_imports)]
pub use capture::{ocr_jpeg, FrameCapture, ScreenCapturer};
#[allow(unused_imports)]
pub use context::{get_app_context, AppContext};
#[allow(unused_imports)]
pub use memory::{CaptureConfig, MemoryDaemon};
#[allow(unused_imports)]
pub use privacy::PrivacyGuard;
pub use session::{FrameHit, SessionGraph, SessionRecord};
#[allow(unused_imports)]
pub use storage::{StorageConfig, StorageManager};
