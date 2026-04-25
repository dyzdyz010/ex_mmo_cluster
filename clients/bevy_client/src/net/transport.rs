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

fn send_tcp_bytes(stream: &mut TcpStream, bytes: &[u8]) -> io::Result<()> {
    let mut written = 0;
    while written < bytes.len() {
        match stream.write(&bytes[written..]) {
            Ok(0) => {
                return Err(io::Error::new(
                    io::ErrorKind::WriteZero,
                    "socket closed while writing",
                ));
            }
            Ok(n) => written += n,
            Err(err) if err.kind() == io::ErrorKind::WouldBlock => {
                thread::sleep(Duration::from_millis(5))
            }
            Err(err) if err.kind() == io::ErrorKind::Interrupted => continue,
            Err(err) => return Err(err),
        }
    }
    Ok(())
}
