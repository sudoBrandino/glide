//! WinHTTP implementation of `transport::Http` and `transport::WebSocket` (Windows). WinHTTP uses
//! the system's proxy configuration (automatic proxy: WPAD / PAC / the configured proxy) and
//! Schannel with the OS certificate store, so an organization's proxies and TLS-inspection roots
//! work without anything Glide-specific (docs/ENTERPRISE.md §3.3). TLS 1.2+, no redirects.

use super::managed::registry::RegSource;
use super::managed::Url;
use super::transport::{Http, Request, Response, WebSocket, WsConnectError, WsMsg, MAX_MESSAGE};
use std::io;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use windows::core::PCWSTR;
use windows::Win32::Networking::WinHttp::*;

/// Largest HTTP response body read (API answers are small).
const MAX_BODY: usize = 4 << 20;
/// A WebSocket that receives nothing for this long is dead (the hub pings every 30 s; sessions
/// carry 2 Hz Glide pings).
const WS_RECEIVE_TIMEOUT: Duration = Duration::from_secs(120);

fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(Some(0)).collect()
}

fn last_error(what: &str) -> String {
    format!("{what}: {}", windows::core::Error::from_thread())
}

/// An owned WinHTTP handle.
struct Handle(*mut core::ffi::c_void);
unsafe impl Send for Handle {}
unsafe impl Sync for Handle {}

impl Handle {
    fn new(h: *mut core::ffi::c_void, what: &str) -> Result<Handle, String> {
        if h.is_null() {
            Err(last_error(what))
        } else {
            Ok(Handle(h))
        }
    }
}

impl Drop for Handle {
    fn drop(&mut self) {
        if !self.0.is_null() {
            unsafe {
                let _ = WinHttpCloseHandle(self.0);
            }
        }
    }
}

pub struct WinHttp {
    session: Option<Handle>,
}

impl Default for WinHttp {
    fn default() -> Self {
        Self::new()
    }
}

impl WinHttp {
    pub fn new() -> WinHttp {
        let agent = wide(&format!("Glide/{} (Windows)", env!("CARGO_PKG_VERSION")));
        let session = unsafe {
            let mut h = WinHttpOpen(PCWSTR(agent.as_ptr()), WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY, PCWSTR::null(), PCWSTR::null(), 0);
            if h.is_null() {
                // Before Windows 8.1: the WinHTTP default proxy (netsh winhttp).
                h = WinHttpOpen(PCWSTR(agent.as_ptr()), WINHTTP_ACCESS_TYPE_DEFAULT_PROXY, PCWSTR::null(), PCWSTR::null(), 0);
            }
            Handle::new(h, "WinHttpOpen").ok()
        };
        if let Some(s) = &session {
            unsafe {
                let protocols = (WINHTTP_FLAG_SECURE_PROTOCOL_TLS1_2 | WINHTTP_FLAG_SECURE_PROTOCOL_TLS1_3).to_le_bytes();
                if WinHttpSetOption(Some(s.0), WINHTTP_OPTION_SECURE_PROTOCOLS, Some(&protocols)).is_err() {
                    // TLS 1.3 unknown to older WinHTTP: 1.2 only.
                    let _ = WinHttpSetOption(Some(s.0), WINHTTP_OPTION_SECURE_PROTOCOLS, Some(&WINHTTP_FLAG_SECURE_PROTOCOL_TLS1_2.to_le_bytes()));
                }
                let _ = WinHttpSetOption(Some(s.0), WINHTTP_OPTION_REDIRECT_POLICY, Some(&WINHTTP_OPTION_REDIRECT_POLICY_NEVER.to_le_bytes()));
            }
        }
        WinHttp { session }
    }

    /// Connects and sends one request; returns (connection, request, status).
    fn exchange(&self, method: &str, url: &str, headers: &[(String, String)], body: Option<&[u8]>, timeout: Duration, upgrade: bool) -> Result<(Handle, Handle, u16), String> {
        let session = self.session.as_ref().ok_or("WinHTTP is unavailable")?;
        let u = Url::parse(url)?;
        let secure = u.secure();
        if !secure && !u.is_loopback() {
            return Err("refusing an unencrypted connection to a remote host".into());
        }
        let host = wide(&u.host);
        let conn = Handle::new(unsafe { WinHttpConnect(session.0, PCWSTR(host.as_ptr()), u.port, 0) }, "WinHttpConnect")?;
        let verb = wide(method);
        let path = wide(&u.path);
        let flags = if secure { WINHTTP_FLAG_SECURE } else { WINHTTP_OPEN_REQUEST_FLAGS(0) };
        let req = Handle::new(
            unsafe { WinHttpOpenRequest(conn.0, PCWSTR(verb.as_ptr()), PCWSTR(path.as_ptr()), PCWSTR::null(), PCWSTR::null(), std::ptr::null(), flags) },
            "WinHttpOpenRequest",
        )?;
        let ms = timeout.as_millis().clamp(1000, i32::MAX as u128) as i32;
        unsafe {
            let _ = WinHttpSetTimeouts(req.0, ms.min(15_000), ms.min(15_000), ms, ms);
            if upgrade {
                WinHttpSetOption(Some(req.0), WINHTTP_OPTION_UPGRADE_TO_WEB_SOCKET, None).map_err(|e| format!("WebSocket upgrade option: {e}"))?;
            }
        }
        let mut hdr = String::new();
        for (k, v) in headers {
            if k.contains(['\r', '\n', ':']) || v.contains(['\r', '\n']) {
                return Err("invalid header".into());
            }
            hdr.push_str(&format!("{k}: {v}\r\n"));
        }
        let hdr_w: Vec<u16> = hdr.encode_utf16().collect();
        let body = body.unwrap_or(&[]);
        unsafe {
            WinHttpSendRequest(
                req.0,
                if hdr_w.is_empty() { None } else { Some(&hdr_w) },
                if body.is_empty() { None } else { Some(body.as_ptr() as *const _) },
                body.len() as u32,
                body.len() as u32,
                0,
            )
            .map_err(|e| format!("cannot reach {}: {e}", u.host))?;
            WinHttpReceiveResponse(req.0, std::ptr::null_mut()).map_err(|e| format!("no answer from {}: {e}", u.host))?;
        }
        let mut status = 0u32;
        let mut len = 4u32;
        unsafe {
            WinHttpQueryHeaders(
                req.0,
                WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
                PCWSTR::null(),
                Some(&mut status as *mut u32 as *mut _),
                &mut len,
                std::ptr::null_mut(),
            )
            .map_err(|e| format!("HTTP status: {e}"))?;
        }
        Ok((conn, req, status as u16))
    }
}

impl Http for WinHttp {
    fn request(&self, r: &Request) -> Result<Response, String> {
        let (_conn, req, status) = self.exchange(r.method, &r.url, &r.headers, r.body.as_deref(), r.timeout, false)?;
        let mut body = Vec::new();
        loop {
            let mut avail = 0u32;
            unsafe { WinHttpQueryDataAvailable(req.0, &mut avail) }.map_err(|e| format!("reading the answer: {e}"))?;
            if avail == 0 {
                break;
            }
            if body.len() + avail as usize > MAX_BODY {
                return Err("answer too large".into());
            }
            let start = body.len();
            body.resize(start + avail as usize, 0);
            let mut read = 0u32;
            unsafe { WinHttpReadData(req.0, body[start..].as_mut_ptr() as *mut _, avail, &mut read) }.map_err(|e| format!("reading the answer: {e}"))?;
            body.truncate(start + read as usize);
            if read == 0 {
                break;
            }
        }
        Ok(Response { status, body })
    }

    fn websocket(&self, url: &str, headers: &[(String, String)]) -> Result<Arc<dyn WebSocket>, WsConnectError> {
        let (conn, req, status) = self.exchange("GET", url, headers, None, Duration::from_secs(30), true).map_err(WsConnectError::Transport)?;
        if status != 101 {
            return Err(WsConnectError::Status(status));
        }
        let ws = unsafe { WinHttpWebSocketCompleteUpgrade(req.0, None) };
        if ws.is_null() {
            return Err(WsConnectError::Transport(last_error("WinHttpWebSocketCompleteUpgrade")));
        }
        drop(req);
        let ms = WS_RECEIVE_TIMEOUT.as_millis() as i32;
        unsafe {
            let _ = WinHttpSetTimeouts(ws, 15_000, 15_000, 30_000, ms);
        }
        Ok(Arc::new(WinWs { ws: AtomicUsize::new(ws as usize), _conn: conn, send: Mutex::new(()), recv: Mutex::new(()), closed: AtomicBool::new(false) }))
    }
}

pub struct WinWs {
    /// The WebSocket handle (0 once closed).
    ws: AtomicUsize,
    _conn: Handle,
    send: Mutex<()>,
    recv: Mutex<()>,
    closed: AtomicBool,
}

impl WinWs {
    fn handle(&self) -> io::Result<*const core::ffi::c_void> {
        match self.ws.load(Ordering::SeqCst) {
            0 => Err(io::Error::new(io::ErrorKind::NotConnected, "WebSocket closed")),
            h => Ok(h as *const _),
        }
    }
}

fn ws_err(code: u32, what: &str) -> io::Error {
    io::Error::other(format!("{what}: {}", windows::core::Error::from_hresult(windows::core::HRESULT::from_win32(code))))
}

impl WebSocket for WinWs {
    fn send(&self, m: WsMsg) -> io::Result<()> {
        let _g = self.send.lock().unwrap();
        let h = self.handle()?;
        let (ty, data) = match &m {
            WsMsg::Text(t) => (WINHTTP_WEB_SOCKET_UTF8_MESSAGE_BUFFER_TYPE, t.as_bytes()),
            WsMsg::Binary(b) => (WINHTTP_WEB_SOCKET_BINARY_MESSAGE_BUFFER_TYPE, b.as_slice()),
            WsMsg::Close(c, r) => {
                drop(_g);
                self.close(*c, r);
                return Ok(());
            }
        };
        let rc = unsafe { WinHttpWebSocketSend(h, ty, if data.is_empty() { None } else { Some(data) }) };
        if rc != 0 {
            return Err(ws_err(rc, "WebSocket send"));
        }
        Ok(())
    }

    fn recv(&self) -> io::Result<WsMsg> {
        let _g = self.recv.lock().unwrap();
        let mut msg: Vec<u8> = Vec::new();
        let mut chunk = vec![0u8; 64 << 10];
        loop {
            let h = match self.handle() {
                Ok(h) => h,
                Err(_) => return Ok(WsMsg::Close(1000, String::new())),
            };
            let mut read = 0u32;
            let mut ty = WINHTTP_WEB_SOCKET_BUFFER_TYPE(0);
            let rc = unsafe { WinHttpWebSocketReceive(h, chunk.as_mut_ptr() as *mut _, chunk.len() as u32, &mut read, &mut ty) };
            if rc != 0 {
                if self.closed.load(Ordering::SeqCst) {
                    return Ok(WsMsg::Close(1000, String::new()));
                }
                return Err(ws_err(rc, "WebSocket receive"));
            }
            if ty == WINHTTP_WEB_SOCKET_CLOSE_BUFFER_TYPE {
                let mut status = 0u16;
                let mut reason = [0u8; 123];
                let mut used = 0u32;
                let rc = unsafe { WinHttpWebSocketQueryCloseStatus(h, &mut status, Some(reason.as_mut_ptr() as *mut _), reason.len() as u32, &mut used) };
                let text = if rc == 0 { String::from_utf8_lossy(&reason[..used as usize]).into_owned() } else { String::new() };
                self.close(1000, "");
                return Ok(WsMsg::Close(if rc == 0 { status } else { 1005 }, text));
            }
            if msg.len() + read as usize > MAX_MESSAGE {
                return Err(io::Error::new(io::ErrorKind::InvalidData, "WebSocket message too large"));
            }
            msg.extend_from_slice(&chunk[..read as usize]);
            if ty == WINHTTP_WEB_SOCKET_BINARY_MESSAGE_BUFFER_TYPE {
                return Ok(WsMsg::Binary(msg));
            }
            if ty == WINHTTP_WEB_SOCKET_UTF8_MESSAGE_BUFFER_TYPE {
                return String::from_utf8(msg).map(WsMsg::Text).map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "WebSocket text is not UTF-8"));
            }
            // A fragment: keep reading.
        }
    }

    fn close(&self, code: u16, reason: &str) {
        if self.closed.swap(true, Ordering::SeqCst) {
            return;
        }
        let h = self.ws.swap(0, Ordering::SeqCst);
        if h == 0 {
            return;
        }
        let r = reason.as_bytes();
        let r = &r[..r.len().min(123)];
        unsafe {
            // Send our close frame without waiting for the answer, then close the handle: a
            // receive blocked on another thread returns with an error (seen as closed).
            let _ = WinHttpWebSocketShutdown(h as *const _, code, if r.is_empty() { None } else { Some(r.as_ptr() as *const _) }, r.len() as u32);
            let _ = WinHttpCloseHandle(h as *mut _);
        }
    }
}

impl Drop for WinWs {
    fn drop(&mut self) {
        self.close(1000, "");
    }
}

/// "10.0.26100" (major.minor.build) from the registry.
pub fn os_version() -> String {
    use super::managed::PolicySource;
    let r = RegSource::hklm("SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion");
    let major = r.dword("CurrentMajorVersionNumber").unwrap_or(10);
    let minor = r.dword("CurrentMinorVersionNumber").unwrap_or(0);
    let build = r.string("CurrentBuildNumber").or_else(|| r.string("CurrentBuild")).unwrap_or_default();
    if build.is_empty() {
        format!("{major}.{minor}")
    } else {
        format!("{major}.{minor}.{build}")
    }
}
