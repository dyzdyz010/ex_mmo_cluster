//! Byte-cursor reader/writer for the voxel wire codec.
//!
//! The voxel protocol is big-endian throughout (mirroring the Elixir
//! `SceneServer.Voxel.Codec`), with **one exception**: `FieldRegionSnapshot`
//! (0x73) encodes its f32 value arrays little-endian. The `_le` accessors
//! exist solely for that case; everything else uses the big-endian methods.

use crate::protocol::ProtocolError;

/// Sequential big-endian reader over a borrowed payload slice.
pub struct Reader<'a> {
    data: &'a [u8],
    pos: usize,
}

impl<'a> Reader<'a> {
    pub fn new(data: &'a [u8]) -> Self {
        Self { data, pos: 0 }
    }

    pub fn remaining(&self) -> usize {
        self.data.len().saturating_sub(self.pos)
    }

    pub fn position(&self) -> usize {
        self.pos
    }

    fn take(&mut self, n: usize, what: &str) -> Result<&'a [u8], ProtocolError> {
        if self.pos + n > self.data.len() {
            return Err(ProtocolError(format!(
                "voxel wire: need {n} bytes for {what} at offset {}, only {} remain",
                self.pos,
                self.remaining()
            )));
        }
        let slice = &self.data[self.pos..self.pos + n];
        self.pos += n;
        Ok(slice)
    }

    pub fn u8(&mut self, what: &str) -> Result<u8, ProtocolError> {
        Ok(self.take(1, what)?[0])
    }

    pub fn u16(&mut self, what: &str) -> Result<u16, ProtocolError> {
        let b = self.take(2, what)?;
        Ok(u16::from_be_bytes([b[0], b[1]]))
    }

    pub fn u32(&mut self, what: &str) -> Result<u32, ProtocolError> {
        let b = self.take(4, what)?;
        Ok(u32::from_be_bytes([b[0], b[1], b[2], b[3]]))
    }

    pub fn u64(&mut self, what: &str) -> Result<u64, ProtocolError> {
        let b = self.take(8, what)?;
        Ok(u64::from_be_bytes([
            b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
        ]))
    }

    pub fn i16(&mut self, what: &str) -> Result<i16, ProtocolError> {
        Ok(self.u16(what)? as i16)
    }

    pub fn i32(&mut self, what: &str) -> Result<i32, ProtocolError> {
        Ok(self.u32(what)? as i32)
    }

    pub fn i64(&mut self, what: &str) -> Result<i64, ProtocolError> {
        Ok(self.u64(what)? as i64)
    }

    pub fn f32_be(&mut self, what: &str) -> Result<f32, ProtocolError> {
        Ok(f32::from_bits(self.u32(what)?))
    }

    /// Little-endian f32 — only for `FieldRegionSnapshot` (0x73) value arrays.
    pub fn f32_le(&mut self, what: &str) -> Result<f32, ProtocolError> {
        let b = self.take(4, what)?;
        Ok(f32::from_le_bytes([b[0], b[1], b[2], b[3]]))
    }

    pub fn f64(&mut self, what: &str) -> Result<f64, ProtocolError> {
        Ok(f64::from_bits(self.u64(what)?))
    }

    /// Reads exactly `n` raw bytes (e.g. opaque forward-compat payloads).
    pub fn bytes(&mut self, n: usize, what: &str) -> Result<&'a [u8], ProtocolError> {
        self.take(n, what)
    }

    /// Asserts the whole payload was consumed (no trailing bytes), mirroring
    /// the Elixir decoders' strict trailing-byte guard.
    pub fn expect_end(&self, what: &str) -> Result<(), ProtocolError> {
        if self.pos != self.data.len() {
            return Err(ProtocolError(format!(
                "voxel wire: {what} has {} trailing bytes after offset {}",
                self.data.len() - self.pos,
                self.pos
            )));
        }
        Ok(())
    }
}

/// Sequential big-endian writer; the mirror of [`Reader`] for round-trip
/// (decode → encode → assert byte-equal) parity tests and client→server intents.
#[derive(Default)]
pub struct Writer {
    buf: Vec<u8>,
}

impl Writer {
    pub fn new() -> Self {
        Self { buf: Vec::new() }
    }

    pub fn into_bytes(self) -> Vec<u8> {
        self.buf
    }

    pub fn len(&self) -> usize {
        self.buf.len()
    }

    pub fn is_empty(&self) -> bool {
        self.buf.is_empty()
    }

    pub fn u8(&mut self, v: u8) {
        self.buf.push(v);
    }

    pub fn u16(&mut self, v: u16) {
        self.buf.extend_from_slice(&v.to_be_bytes());
    }

    pub fn u32(&mut self, v: u32) {
        self.buf.extend_from_slice(&v.to_be_bytes());
    }

    pub fn u64(&mut self, v: u64) {
        self.buf.extend_from_slice(&v.to_be_bytes());
    }

    pub fn i16(&mut self, v: i16) {
        self.u16(v as u16);
    }

    pub fn i32(&mut self, v: i32) {
        self.u32(v as u32);
    }

    pub fn i64(&mut self, v: i64) {
        self.u64(v as u64);
    }

    pub fn f32_be(&mut self, v: f32) {
        self.u32(v.to_bits());
    }

    /// Little-endian f32 — only for `FieldRegionSnapshot` (0x73) value arrays.
    pub fn f32_le(&mut self, v: f32) {
        self.buf.extend_from_slice(&v.to_le_bytes());
    }

    pub fn f64(&mut self, v: f64) {
        self.u64(v.to_bits());
    }

    pub fn bytes(&mut self, b: &[u8]) {
        self.buf.extend_from_slice(b);
    }
}
