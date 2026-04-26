//! Lightweight structured observe sink for the Bevy client.

use bevy::prelude::Resource;
use std::{
    fs::{OpenOptions, create_dir_all},
    io::{BufWriter, Write},
    path::Path,
    sync::Arc,
    sync::atomic::{AtomicUsize, Ordering},
    sync::mpsc::{self, Sender},
    thread,
    time::{SystemTime, UNIX_EPOCH},
};

/// Audit E-M1: how many silent send-failures we tolerate before announcing
/// the loss on stderr. Above this we still keep counting (so the operator
/// sees a final tally), but we throttle the noise so a torn-down sink does
/// not spam every emit call.
const OBSERVER_DROP_LOG_INTERVAL: usize = 256;

#[derive(Clone, Default, Resource)]
/// File/stdout-backed structured event sink used by local automation and QA.
pub struct ClientObserver {
    sink: Option<Sender<String>>,
    stdout: bool,
    /// Cumulative count of lines dropped because the sink-channel send failed
    /// (writer thread gone or channel closed). Shared via Arc so cloned
    /// observers (Bevy's `Resource` is cloned across threads) accumulate
    /// into the same counter.
    dropped: Arc<AtomicUsize>,
}

impl ClientObserver {
    /// Creates a new observer that can write to a file and/or stdout.
    pub fn new(path: Option<String>, stdout: bool) -> Self {
        let sink = path.and_then(|path| {
            let path = Path::new(&path);
            if let Some(parent) = path.parent() {
                let _ = create_dir_all(parent);
            }

            let file = OpenOptions::new()
                .create(true)
                .append(true)
                .open(path)
                .ok()?;

            let (tx, rx) = mpsc::channel::<String>();
            thread::spawn(move || {
                let mut writer = BufWriter::new(file);
                while let Ok(line) = rx.recv() {
                    let _ = writer.write_all(line.as_bytes());
                    let _ = writer.flush();
                }
            });

            Some(tx)
        });

        Self {
            sink,
            stdout,
            dropped: Arc::new(AtomicUsize::new(0)),
        }
    }

    /// Total number of observe lines dropped so far because the sink channel
    /// was closed. Test/diagnostic accessor.
    pub fn dropped_count(&self) -> usize {
        self.dropped.load(Ordering::Relaxed)
    }

    /// Returns whether any observe sink is enabled.
    pub fn enabled(&self) -> bool {
        self.stdout || self.sink.is_some()
    }

    /// Emits one structured observe line.
    pub fn emit(&self, source: &str, event: &str, fields: &[(&str, String)]) {
        if !self.enabled() {
            return;
        }

        let mut line = format!("ts={} source={source:?} event={event:?}", unix_millis());

        for (key, value) in fields {
            line.push(' ');
            line.push_str(key);
            line.push('=');
            line.push_str(&format!("{value:?}"));
        }

        line.push('\n');

        if self.stdout {
            print!("{line}");
        }

        if let Some(sink) = &self.sink
            && sink.send(line).is_err()
        {
            // Audit E-M1: previously the SendError was swallowed so a dead
            // writer thread looked identical to a working one. Track the
            // count and announce on stderr at coarse intervals so the
            // operator notices instead of hunting the missing log file.
            let prev = self.dropped.fetch_add(1, Ordering::Relaxed);
            let now = prev + 1;
            if now == 1 || now.is_multiple_of(OBSERVER_DROP_LOG_INTERVAL) {
                eprintln!(
                    "[bevy_client::observe] sink dropped {now} line(s); writer thread is gone"
                );
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn drop_counter_starts_at_zero() {
        let observer = ClientObserver::default();
        assert_eq!(observer.dropped_count(), 0);
    }

    #[test]
    fn dropped_count_is_shared_across_clones() {
        // Construct a sink whose receiver is dropped immediately so any
        // send fails. We can't go through `new()` (it requires a real
        // file path), so build the struct manually.
        let (tx, rx) = mpsc::channel::<String>();
        drop(rx);
        let observer = ClientObserver {
            sink: Some(tx),
            stdout: false,
            dropped: Arc::new(AtomicUsize::new(0)),
        };
        let twin = observer.clone();

        observer.emit("test", "first", &[]);
        observer.emit("test", "second", &[]);
        twin.emit("test", "third", &[]);

        assert_eq!(observer.dropped_count(), 3);
        assert_eq!(twin.dropped_count(), 3);
    }
}

fn unix_millis() -> u128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
}
