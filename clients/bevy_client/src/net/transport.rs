//! Pure I/O helpers for TCP / UDP framing used by the network thread.
//!
//! No protocol decisions, no state — only "given a stream and a message,
//! send it" and "given a hostname, resolve it" primitives.

use std::{
    io::{self, Write},
    net::{IpAddr, SocketAddr, TcpStream, ToSocketAddrs, UdpSocket},
    thread,
    time::Duration,
};

use crate::protocol::{ClientMessage, encode_client_frame, encode_client_payload};

pub(super) fn resolve_gate_addr(gate_addr: &str) -> io::Result<SocketAddr> {
    gate_addr
        .to_socket_addrs()?
        .next()
        .ok_or_else(|| io::Error::new(io::ErrorKind::AddrNotAvailable, "no socket addresses"))
}

pub(super) fn open_udp_socket(endpoint: SocketAddr) -> io::Result<UdpSocket> {
    let bind_addr = match endpoint.ip() {
        IpAddr::V4(_) => "0.0.0.0:0",
        IpAddr::V6(_) => "[::]:0",
    };

    let socket = UdpSocket::bind(bind_addr)?;
    socket.connect(endpoint)?;
    socket.set_nonblocking(true)?;
    Ok(socket)
}

pub(super) fn send_tcp_message(stream: &mut TcpStream, message: &ClientMessage) -> io::Result<()> {
    let frame = encode_client_frame(message);
    send_tcp_bytes(stream, &frame)
}

pub(super) fn send_udp_message(socket: &UdpSocket, message: &ClientMessage) -> io::Result<()> {
    let payload = encode_client_payload(message);
    socket.send(&payload).map(|_| ())
}

/// Maximum cumulative time we will spend retrying `WouldBlock` on a single
/// outbound TCP frame before giving up. Audit A-S2: previously the code did
/// a hard `thread::sleep(5ms)` with no cap, so a stuck send-buffer could
/// block the network thread for arbitrary time.
const MAX_TCP_SEND_WAIT: Duration = Duration::from_millis(1_000);

/// Initial backoff after a `WouldBlock`. Doubles each retry, clamped to
/// `MAX_TCP_SEND_BACKOFF` so progressively-longer waits stay bounded.
const INITIAL_TCP_SEND_BACKOFF: Duration = Duration::from_millis(1);
const MAX_TCP_SEND_BACKOFF: Duration = Duration::from_millis(64);

fn send_tcp_bytes(stream: &mut TcpStream, bytes: &[u8]) -> io::Result<()> {
    let mut written = 0;
    let mut waited = Duration::ZERO;
    let mut backoff = INITIAL_TCP_SEND_BACKOFF;

    while written < bytes.len() {
        match stream.write(&bytes[written..]) {
            Ok(0) => {
                return Err(io::Error::new(
                    io::ErrorKind::WriteZero,
                    "socket closed while writing",
                ));
            }
            Ok(n) => {
                written += n;
                // Successful progress resets the backoff window.
                waited = Duration::ZERO;
                backoff = INITIAL_TCP_SEND_BACKOFF;
            }
            Err(err) if err.kind() == io::ErrorKind::WouldBlock => {
                if waited >= MAX_TCP_SEND_WAIT {
                    return Err(io::Error::new(
                        io::ErrorKind::TimedOut,
                        format!(
                            "tcp send blocked > {}ms ({} of {} bytes written)",
                            MAX_TCP_SEND_WAIT.as_millis(),
                            written,
                            bytes.len()
                        ),
                    ));
                }
                thread::sleep(backoff);
                waited += backoff;
                backoff = (backoff * 2).min(MAX_TCP_SEND_BACKOFF);
            }
            Err(err) if err.kind() == io::ErrorKind::Interrupted => continue,
            Err(err) => return Err(err),
        }
    }
    Ok(())
}
