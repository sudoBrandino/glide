//! File transfer (docs/PROTOCOL.md §6), platform independent so it is unit-tested anywhere:
//!
//! - path sanitizing (`sanitize_path`) and offer validation (`validate_offer`): every received
//!   name is untrusted;
//! - the receiver (`Incoming`): temp file → SHA-256 verify → rename, never overwriting, marked
//!   as downloaded (`mark_downloaded`: Mark-of-the-Web on Windows);
//! - the sender (`collect`, `Outgoing`): directory walk that refuses symlinks/special files,
//!   chunking + hashing;
//! - `Service`: runs one outgoing and one incoming transfer at a time for a connection, with
//!   FileAck flow control, over any transport (`SendFn`). `win::files` adds drag & drop,
//!   notifications and the UI.
//!
//! Received files are never opened or executed.

use crate::protocol::{FileEntry, FileMsg, FILE_CAPS_RECEIVE, FILE_CAPS_SEND, FILE_CHUNK_MAX, FILE_HOST_ID_BIT, FILE_SEND_WINDOW, FILE_WINDOW};
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};
use sha2::{Digest, Sha256};
use std::collections::{HashMap, VecDeque};
use std::fs::{self, File};
use std::io::{self, Read};
use std::path::{Path, PathBuf};
use std::sync::{mpsc, Arc, Condvar, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

/// Status / reason codes of FileAnswer, FileCancel and FilePullResult (§6).
pub mod status {
    pub const OK: u8 = 0;
    pub const DECLINED: u8 = 1;
    pub const TOO_LARGE: u8 = 2;
    pub const BAD_NAME: u8 = 3;
    pub const BUSY: u8 = 4;
    pub const NO_SPACE: u8 = 5;
    pub const IO: u8 = 6;
    pub const CANCELLED: u8 = 7;
    pub const VERIFY: u8 = 8;
    pub const PROTOCOL: u8 = 9;
    pub const SOURCE_CHANGED: u8 = 10;
    pub const NOTHING: u8 = 11;

    pub fn text(s: u8) -> &'static str {
        match s {
            OK => "ok",
            DECLINED => "declined",
            TOO_LARGE => "too large",
            BAD_NAME => "unsafe file name",
            BUSY => "another transfer is in progress",
            NO_SPACE => "disk full",
            IO => "I/O error",
            CANCELLED => "cancelled",
            VERIFY => "verification failed",
            PROTOCOL => "protocol error",
            SOURCE_CHANGED => "a file changed while it was being sent",
            NOTHING => "nothing to send",
            _ => "error",
        }
    }
}

/// A failed step: (status code, human-readable detail).
pub type Fail = (u8, String);

// ------------------------------------------------------------------ names

pub const MAX_PATH_BYTES: usize = 4096;
pub const MAX_DEPTH: usize = 32;
/// Sanitized components are cut to this many UTF-8 bytes (room for " (9999)" and a "_" prefix
/// under the 255-unit limit of NTFS/APFS).
pub const MAX_COMPONENT_BYTES: usize = 200;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PathError {
    Empty,
    TooLong,
    Absolute,
    TooDeep,
    EmptyComponent,
    DotComponent,
}

impl std::fmt::Display for PathError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(match self {
            PathError::Empty => "empty path",
            PathError::TooLong => "path too long",
            PathError::Absolute => "absolute path",
            PathError::TooDeep => "too deeply nested",
            PathError::EmptyComponent => "empty path component",
            PathError::DotComponent => "'.' or '..' in path",
        })
    }
}

/// Bidi overrides, zero-width and other invisible format characters (extension spoofing).
fn is_format_char(c: char) -> bool {
    matches!(c as u32, 0x061C | 0xFEFF | 0x200B..=0x200F | 0x202A..=0x202E | 0x2060..=0x2064 | 0x2066..=0x2069)
}

/// Windows device names (also with an extension: "con.txt").
fn is_reserved(base: &str) -> bool {
    let up = base.to_ascii_uppercase();
    if ["CON", "PRN", "AUX", "NUL", "CONIN$", "CONOUT$"].contains(&up.as_str()) {
        return true;
    }
    ["COM", "LPT"].iter().any(|p| {
        up.strip_prefix(p).is_some_and(|rest| {
            let mut it = rest.chars();
            matches!((it.next(), it.next()), (Some(c), None) if c.is_ascii_digit() || matches!(c, '¹' | '²' | '³'))
        })
    })
}

fn trim_trailing(s: &str) -> String {
    let t = s.trim_end_matches(['.', ' ']);
    if t.is_empty() {
        "_".into()
    } else {
        t.into()
    }
}

/// One received path component → a name that is safe on Windows and macOS (§6.3).
pub fn sanitize_component(c: &str) -> String {
    let mapped: String = c
        .chars()
        .map(|ch| if (ch as u32) < 0x20 || ch == '\u{7f}' || "\\:*?\"<>|".contains(ch) || is_format_char(ch) { '_' } else { ch })
        .collect();
    let mut s = trim_trailing(&mapped);
    if is_reserved(s.split('.').next().unwrap_or("").trim_end_matches(' ')) {
        s.insert(0, '_');
    }
    if s.len() > MAX_COMPONENT_BYTES {
        let ext = match s.rfind('.') {
            Some(i) if i > 0 && s.len() - i <= 32 => s[i..].to_string(),
            _ => String::new(),
        };
        let stem = &s[..s.len() - ext.len()];
        let mut cut = MAX_COMPONENT_BYTES - ext.len();
        while !stem.is_char_boundary(cut) {
            cut -= 1;
        }
        s = trim_trailing(&format!("{}{}", &stem[..cut], ext));
        // Cutting can expose a device name ("CON" + 197 spaces + "x" -> "CON"): check again.
        if is_reserved(s.split('.').next().unwrap_or("").trim_end_matches(' ')) {
            s.insert(0, '_');
        }
    }
    s
}

/// A wire path ('/'-separated, relative) → safe components, or an error for paths that must be
/// refused outright (traversal, absolute, too long/deep).
pub fn sanitize_path(p: &str) -> Result<Vec<String>, PathError> {
    if p.is_empty() {
        return Err(PathError::Empty);
    }
    if p.len() > MAX_PATH_BYTES {
        return Err(PathError::TooLong);
    }
    let b = p.as_bytes();
    if b[0] == b'/' || b[0] == b'\\' || (b.len() >= 2 && b[1] == b':' && b[0].is_ascii_alphabetic()) {
        return Err(PathError::Absolute);
    }
    let comps: Vec<&str> = p.split('/').collect();
    if comps.len() > MAX_DEPTH {
        return Err(PathError::TooDeep);
    }
    for c in &comps {
        if c.is_empty() {
            return Err(PathError::EmptyComponent);
        }
        if *c == "." || *c == ".." {
            return Err(PathError::DotComponent);
        }
    }
    Ok(comps.iter().map(|c| sanitize_component(c)).collect())
}

/// Collision rename: ("a.txt", 2) → "a (2).txt"; folders and dotfiles get the suffix at the end.
pub fn with_suffix(name: &str, n: u32, is_dir: bool) -> String {
    if n <= 1 {
        return name.to_string();
    }
    match name.rfind('.') {
        Some(i) if i > 0 && !is_dir => format!("{} ({n}){}", &name[..i], &name[i..]),
        _ => format!("{name} ({n})"),
    }
}

// ------------------------------------------------------------------ offers

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Limits {
    pub max_total_bytes: u64,
    pub max_files: u32,
}

impl Default for Limits {
    fn default() -> Self {
        Limits { max_total_bytes: 8 << 30, max_files: 10_000 }
    }
}

impl Limits {
    pub fn min(self, o: Limits) -> Limits {
        Limits { max_total_bytes: self.max_total_bytes.min(o.max_total_bytes), max_files: self.max_files.min(o.max_files) }
    }
}

/// Transfer ids: the host's have bit 31 set, the viewer's don't; 0 is invalid.
pub fn id_is_hosts(id: u32) -> bool {
    id & FILE_HOST_ID_BIT != 0
}

/// Checks a received offer; returns the sanitized components of every file.
pub fn validate_offer(id: u32, total: u64, files: &[FileEntry], limits: &Limits, from_host: bool) -> Result<Vec<Vec<String>>, Fail> {
    if id == 0 || id_is_hosts(id) != from_host {
        return Err((status::PROTOCOL, "transfer id outside the sender's range".into()));
    }
    if files.is_empty() {
        return Err((status::PROTOCOL, "empty offer".into()));
    }
    let sum = files.iter().try_fold(0u64, |a, f| a.checked_add(f.size));
    if sum != Some(total) {
        return Err((status::PROTOCOL, "file sizes don't add up to the total".into()));
    }
    if files.len() as u64 > limits.max_files as u64 {
        return Err((status::TOO_LARGE, format!("{} files (limit {})", files.len(), limits.max_files)));
    }
    if total > limits.max_total_bytes {
        return Err((status::TOO_LARGE, format!("{} (limit {})", human_bytes(total), human_bytes(limits.max_total_bytes))));
    }
    let mut rel = Vec::with_capacity(files.len());
    for (i, f) in files.iter().enumerate() {
        match sanitize_path(&f.path) {
            Ok(c) => rel.push(c),
            Err(e) => return Err((status::BAD_NAME, format!("file {}: {e}", i + 1))),
        }
    }
    // A name can't be both a file and a folder (case-insensitively, as on Windows/macOS).
    if let Some(c) = file_folder_conflict(&rel) {
        return Err((status::BAD_NAME, format!("'{}' is both a file and a folder", c.join("/"))));
    }
    Ok(rel)
}

/// The first file whose path is also a folder of another file (case-insensitively), if any.
/// Sorted keys plus one binary search per file: O(n log n) in time and O(total bytes) in memory.
/// (Collecting every folder prefix in a set costs O(depth²·length) per file, which a hostile
/// 10 000-file, 4 KiB-path offer turns into ~1 GB and seconds of work.)
fn file_folder_conflict(rel: &[Vec<String>]) -> Option<&Vec<String>> {
    let mut keys: Vec<(String, usize)> = rel.iter().enumerate().map(|(i, c)| (c.join("/").to_lowercase(), i)).collect();
    keys.sort_unstable();
    for (k, i) in &keys {
        let dir = format!("{k}/");
        let at = keys.partition_point(|(o, _)| o.as_str() < dir.as_str());
        if keys.get(at).is_some_and(|(o, _)| o.starts_with(&dir)) {
            return Some(&rel[*i]);
        }
    }
    None
}

/// Latest modification time a receiver applies: 9999-12-31T23:59:59.999Z.
pub const MAX_MTIME_MS: i64 = 253_402_300_799_999;

/// An offer's `mtime_ms` as a time to apply, or None (unknown, negative or absurd: ignored).
pub fn mtime_from_ms(ms: i64) -> Option<SystemTime> {
    if !(1..=MAX_MTIME_MS).contains(&ms) {
        return None;
    }
    UNIX_EPOCH.checked_add(Duration::from_millis(ms as u64))
}

pub fn human_bytes(n: u64) -> String {
    const U: [&str; 5] = ["bytes", "KB", "MB", "GB", "TB"];
    if n < 1000 {
        return format!("{n} bytes");
    }
    let mut v = n as f64;
    let mut i = 0;
    while v >= 1000.0 && i < U.len() - 1 {
        v /= 1000.0;
        i += 1;
    }
    if v < 10.0 {
        format!("{v:.1} {}", U[i])
    } else {
        format!("{v:.0} {}", U[i])
    }
}

pub fn count_files(n: u32) -> String {
    if n == 1 {
        "1 file".into()
    } else {
        format!("{n} files")
    }
}

// ------------------------------------------------------------------ receiving

/// Marks a received file (or folder) as downloaded from the internet. Windows: the
/// `Zone.Identifier` stream with ZoneId=3 (Mark-of-the-Web), so SmartScreen / Office Protected
/// View treat it like a browser download.
pub fn mark_downloaded(path: &Path, is_dir: bool) -> io::Result<()> {
    #[cfg(windows)]
    {
        if is_dir {
            return Ok(());
        }
        let mut s = path.as_os_str().to_owned();
        s.push(":Zone.Identifier");
        fs::write(PathBuf::from(s), b"[ZoneTransfer]\r\nZoneId=3\r\nReferrerUrl=glide:remote\r\n")
    }
    #[cfg(not(windows))]
    {
        let _ = (path, is_dir);
        Ok(())
    }
}

pub type MarkFn = fn(&Path, bool) -> io::Result<()>;

/// Rename that fails (AlreadyExists) instead of replacing an existing file.
fn rename_noreplace(from: &Path, to: &Path) -> io::Result<()> {
    #[cfg(windows)]
    {
        use windows::core::PCWSTR;
        use windows::Win32::Storage::FileSystem::{MoveFileExW, MOVE_FILE_FLAGS};
        let w = |p: &Path| -> Vec<u16> {
            use std::os::windows::ffi::OsStrExt;
            p.as_os_str().encode_wide().chain(std::iter::once(0)).collect()
        };
        let (f, t) = (w(from), w(to));
        // No MOVEFILE_REPLACE_EXISTING: fails with ERROR_ALREADY_EXISTS if `to` exists.
        unsafe { MoveFileExW(PCWSTR(f.as_ptr()), PCWSTR(t.as_ptr()), MOVE_FILE_FLAGS(0)) }.map_err(|_| io::Error::last_os_error())
    }
    #[cfg(not(windows))]
    {
        fs::hard_link(from, to)?;
        fs::remove_file(from)
    }
}

/// Moves `tmp` to `dir/name`, or `dir/name (2)` … if taken. Never replaces anything.
fn finalize(tmp: &Path, dir: &Path, name: &str) -> io::Result<PathBuf> {
    for n in 1..=9999 {
        let cand = dir.join(with_suffix(name, n, false));
        if fs::symlink_metadata(&cand).is_ok() {
            continue;
        }
        match rename_noreplace(tmp, &cand) {
            Ok(()) => return Ok(cand),
            Err(e) if e.kind() == io::ErrorKind::AlreadyExists => continue,
            Err(e) => return Err(e),
        }
    }
    Err(io::Error::new(io::ErrorKind::AlreadyExists, "no free file name"))
}

fn io_fail(what: &str, e: &io::Error) -> Fail {
    let st = if e.kind() == io::ErrorKind::StorageFull { status::NO_SPACE } else { status::IO };
    (st, format!("{what}: {e}"))
}

struct Current {
    tmp: PathBuf,
    dir: PathBuf,
    file: File,
    written: u64,
    hash: Sha256,
}

/// One incoming transfer, written under `root`. Files are written to a hidden temp file in their
/// final folder, verified (size + SHA-256), marked, then renamed into place without
/// overwriting. Each top-level folder of the offer becomes a new folder ("Photos (2)" if
/// "Photos" exists), so nothing is ever merged into an existing folder.
pub struct Incoming {
    pub id: u32,
    root: PathBuf,
    entries: Vec<FileEntry>,
    rel: Vec<Vec<String>>,
    tops: HashMap<String, String>,
    cur: Option<Current>,
    next: u32,
    received: u64,
    total: u64,
    /// Top-level items created (files and folders), in order.
    pub saved: Vec<PathBuf>,
    mark: MarkFn,
}

impl Incoming {
    pub fn new(id: u32, root: &Path, entries: Vec<FileEntry>, rel: Vec<Vec<String>>, mark: MarkFn) -> io::Result<Incoming> {
        fs::create_dir_all(root)?;
        let total = entries.iter().map(|e| e.size).sum();
        Ok(Incoming {
            id,
            root: root.to_path_buf(),
            entries,
            rel,
            tops: HashMap::new(),
            cur: None,
            next: 0,
            received: 0,
            total,
            saved: Vec::new(),
            mark,
        })
    }

    pub fn received(&self) -> u64 {
        self.received
    }
    pub fn total(&self) -> u64 {
        self.total
    }
    pub fn file_count(&self) -> u32 {
        self.entries.len() as u32
    }
    pub fn root(&self) -> &Path {
        &self.root
    }

    fn dir_for(&mut self, index: usize) -> io::Result<PathBuf> {
        let comps = self.rel[index].clone();
        if comps.len() == 1 {
            return Ok(self.root.clone());
        }
        let top = &comps[0];
        if !self.tops.contains_key(top) {
            let mut n = 1;
            let made = loop {
                let cand = with_suffix(top, n, true);
                let p = self.root.join(&cand);
                if fs::symlink_metadata(&p).is_err() {
                    match fs::create_dir(&p) {
                        Ok(()) => break cand,
                        Err(e) if e.kind() == io::ErrorKind::AlreadyExists => {}
                        Err(e) => return Err(e),
                    }
                }
                n += 1;
                if n > 9999 {
                    return Err(io::Error::new(io::ErrorKind::AlreadyExists, "no free folder name"));
                }
            };
            let p = self.root.join(&made);
            if let Err(e) = (self.mark)(&p, true) {
                eprintln!("files: cannot mark {} as downloaded: {e}", p.display());
            }
            self.saved.push(p);
            self.tops.insert(top.clone(), made);
        }
        let mut d = self.root.join(&self.tops[top]);
        for c in &comps[1..comps.len() - 1] {
            d.push(c);
            match fs::create_dir(&d) {
                Ok(()) => {
                    if let Err(e) = (self.mark)(&d, true) {
                        eprintln!("files: cannot mark {} as downloaded: {e}", d.display());
                    }
                }
                // Existing (e.g. "X" vs "x" on a case-insensitive disk): must be a real folder, not a link.
                Err(e) if e.kind() == io::ErrorKind::AlreadyExists && fs::symlink_metadata(&d).is_ok_and(|m| m.is_dir()) => {}
                Err(e) => return Err(e),
            }
        }
        Ok(d)
    }

    fn open(&mut self, index: u32) -> Result<(), Fail> {
        let dir = self.dir_for(index as usize).map_err(|e| io_fail("cannot create folder", &e))?;
        let tmp = dir.join(format!(".glide-{:08x}-{index}.part", self.id));
        let file = fs::OpenOptions::new().write(true).create_new(true).open(&tmp).map_err(|e| io_fail("cannot create file", &e))?;
        self.cur = Some(Current { tmp, dir, file, written: 0, hash: Sha256::new() });
        Ok(())
    }

    fn check_index(&self, index: u32) -> Result<(), Fail> {
        if index != self.next || index as usize >= self.entries.len() {
            return Err((status::PROTOCOL, format!("data for file {index}, expected {}", self.next)));
        }
        Ok(())
    }

    pub fn chunk(&mut self, index: u32, offset: u64, data: &[u8]) -> Result<(), Fail> {
        self.check_index(index)?;
        if self.cur.is_none() {
            self.open(index)?;
        }
        let size = self.entries[index as usize].size;
        let cur = self.cur.as_mut().unwrap();
        if offset != cur.written || data.is_empty() || data.len() > FILE_CHUNK_MAX || cur.written + data.len() as u64 > size {
            return Err((status::PROTOCOL, format!("bad chunk (file {index}, offset {offset}, {} bytes)", data.len())));
        }
        use std::io::Write;
        cur.file.write_all(data).map_err(|e| io_fail("write failed", &e))?;
        cur.hash.update(data);
        cur.written += data.len() as u64;
        self.received += data.len() as u64;
        Ok(())
    }

    /// File `index` is complete. Returns the saved path; `all_done()` tells if it was the last.
    pub fn end(&mut self, index: u32, sha256: &[u8; 32]) -> Result<PathBuf, Fail> {
        self.check_index(index)?;
        if self.cur.is_none() {
            self.open(index)?; // empty file
        }
        let e = self.entries[index as usize].clone();
        let cur = self.cur.take().unwrap();
        let Current { tmp, dir, file, written, hash, .. } = cur;
        let ok = written == e.size && hash.finalize().as_slice() == sha256;
        let res = (|| {
            if !ok {
                return Err((status::VERIFY, format!("'{}' does not match its SHA-256 / size", e.path)));
            }
            if let Some(t) = mtime_from_ms(e.mtime_ms) {
                let _ = file.set_modified(t);
            }
            file.sync_all().map_err(|err| io_fail("flush failed", &err))?;
            drop(file);
            if let Err(err) = (self.mark)(&tmp, false) {
                eprintln!("files: cannot mark {} as downloaded: {err}", tmp.display());
            }
            let name = self.rel[index as usize].last().unwrap().clone();
            finalize(&tmp, &dir, &name).map_err(|err| io_fail("cannot save file", &err))
        })();
        match res {
            Ok(p) => {
                if self.rel[index as usize].len() == 1 {
                    self.saved.push(p.clone());
                }
                self.next += 1;
                Ok(p)
            }
            Err(f) => {
                let _ = fs::remove_file(&tmp);
                Err(f)
            }
        }
    }

    pub fn all_done(&self) -> bool {
        self.next as usize == self.entries.len()
    }

    /// Stop: delete the partial file (completed files stay).
    pub fn abort(&mut self) {
        if let Some(c) = self.cur.take() {
            drop(c.file);
            let _ = fs::remove_file(&c.tmp);
        }
    }
}

impl Drop for Incoming {
    fn drop(&mut self) {
        self.abort();
    }
}

// ------------------------------------------------------------------ sending

pub struct SourceFile {
    pub abs: PathBuf,
    pub entry: FileEntry,
}

#[derive(Default)]
pub struct Collected {
    pub files: Vec<SourceFile>,
    /// What was left out and why (symlinks, special files, too deep).
    pub skipped: Vec<String>,
    pub total: u64,
}

fn mtime_ms(m: &fs::Metadata) -> i64 {
    m.modified().ok().and_then(|t| t.duration_since(UNIX_EPOCH).ok()).map_or(0, |d| d.as_millis() as i64)
}

/// Dropped/picked paths → the files to send, folders recursively with relative paths. Symlinks
/// (and junctions) and special files are refused, never followed.
pub fn collect(paths: &[PathBuf], limits: &Limits) -> Result<Collected, Fail> {
    fn add(out: &mut Collected, abs: PathBuf, rel: String, m: &fs::Metadata, limits: &Limits) -> Result<(), Fail> {
        out.total += m.len();
        out.files.push(SourceFile { abs, entry: FileEntry { path: rel, size: m.len(), mtime_ms: mtime_ms(m) } });
        if out.files.len() as u64 > limits.max_files as u64 {
            return Err((status::TOO_LARGE, format!("more than {} files", limits.max_files)));
        }
        if out.total > limits.max_total_bytes {
            return Err((status::TOO_LARGE, format!("more than {}", human_bytes(limits.max_total_bytes))));
        }
        Ok(())
    }
    fn walk(out: &mut Collected, dir: &Path, rel: &str, depth: usize, limits: &Limits) -> Result<(), Fail> {
        let rd = match fs::read_dir(dir) {
            Ok(r) => r,
            Err(e) => {
                out.skipped.push(format!("{rel} (can't read: {e})"));
                return Ok(());
            }
        };
        let mut ents: Vec<fs::DirEntry> = rd.filter_map(|e| e.ok()).collect();
        ents.sort_by_key(|e| e.file_name());
        for e in ents {
            let name = e.file_name().to_string_lossy().into_owned();
            let r = format!("{rel}/{name}");
            // DirEntry::file_type/metadata don't follow symlinks.
            let Ok(m) = fs::symlink_metadata(e.path()) else { continue };
            let ft = m.file_type();
            // On Windows is_symlink() also covers junctions/mount points (name-surrogate reparse points).
            if ft.is_symlink() {
                out.skipped.push(format!("{r} (link)"));
            } else if ft.is_dir() {
                if depth + 1 >= MAX_DEPTH {
                    out.skipped.push(format!("{r} (too deeply nested)"));
                } else {
                    walk(out, &e.path(), &r, depth + 1, limits)?;
                }
            } else if ft.is_file() {
                add(out, e.path(), r, &m, limits)?;
            } else {
                out.skipped.push(format!("{r} (not a regular file)"));
            }
        }
        Ok(())
    }
    let mut out = Collected::default();
    for p in paths {
        let Some(name) = p.file_name().map(|n| n.to_string_lossy().into_owned()) else {
            out.skipped.push(format!("{} (no name)", p.display()));
            continue;
        };
        let m = match fs::symlink_metadata(p) {
            Ok(m) => m,
            Err(e) => {
                out.skipped.push(format!("{name} ({e})"));
                continue;
            }
        };
        let ft = m.file_type();
        if ft.is_symlink() {
            out.skipped.push(format!("{name} (link)"));
        } else if ft.is_dir() {
            walk(&mut out, p, &name, 1, limits)?;
        } else if ft.is_file() {
            add(&mut out, p.clone(), name, &m, limits)?;
        } else {
            out.skipped.push(format!("{name} (not a regular file)"));
        }
    }
    Ok(out)
}

/// One outgoing transfer: yields Chunk/End messages in order, hashing as it reads.
pub struct Outgoing {
    pub id: u32,
    files: Vec<SourceFile>,
    idx: usize,
    cur: Option<(File, Sha256, u64)>,
    /// Chunk bytes produced so far.
    pub sent: u64,
    pub total: u64,
    buf: Vec<u8>,
}

impl Outgoing {
    pub fn new(id: u32, c: Collected) -> Outgoing {
        Outgoing { id, total: c.total, files: c.files, idx: 0, cur: None, sent: 0, buf: Vec::new() }
    }

    pub fn file_count(&self) -> u32 {
        self.files.len() as u32
    }

    pub fn offer(&self) -> FileMsg {
        FileMsg::Offer { id: self.id, total_bytes: self.total, files: self.files.iter().map(|f| f.entry.clone()).collect() }
    }

    /// The next Chunk or End message; None once every file has been sent.
    pub fn next_msg(&mut self) -> Result<Option<FileMsg>, Fail> {
        let Some(f) = self.files.get(self.idx) else { return Ok(None) };
        let size = f.entry.size;
        let changed = |what: &str| (status::SOURCE_CHANGED, format!("'{}' {what}", f.entry.path));
        if self.cur.is_none() {
            let file = File::open(&f.abs).map_err(|e| (status::IO, format!("cannot read '{}': {e}", f.entry.path)))?;
            if file.metadata().map(|m| m.len()).ok() != Some(size) {
                return Err(changed("changed size"));
            }
            self.cur = Some((file, Sha256::new(), 0));
        }
        let (file, hash, pos) = self.cur.as_mut().unwrap();
        if *pos < size {
            let want = (size - *pos).min(FILE_CHUNK_MAX as u64) as usize;
            self.buf.resize(want, 0);
            let mut got = 0;
            while got < want {
                match file.read(&mut self.buf[got..]) {
                    Ok(0) => break,
                    Ok(n) => got += n,
                    Err(e) if e.kind() == io::ErrorKind::Interrupted => {}
                    Err(e) => return Err((status::IO, format!("cannot read '{}': {e}", f.entry.path))),
                }
            }
            if got == 0 {
                return Err(changed("got shorter while being sent"));
            }
            hash.update(&self.buf[..got]);
            let offset = *pos;
            *pos += got as u64;
            self.sent += got as u64;
            return Ok(Some(FileMsg::Chunk { id: self.id, index: self.idx as u32, offset, data: self.buf[..got].to_vec() }));
        }
        let mut one = [0u8; 1];
        if matches!(file.read(&mut one), Ok(n) if n > 0) {
            return Err(changed("grew while being sent"));
        }
        let sha256: [u8; 32] = std::mem::take(hash).finalize().into();
        self.cur = None;
        let index = self.idx as u32;
        self.idx += 1;
        Ok(Some(FileMsg::End { id: self.id, index, sha256 }))
    }
}

// ------------------------------------------------------------------ service

/// Sends a file message to the peer; `bulk` = a chunk (low priority, `Sender::send_bulk`).
pub type SendFn = Arc<dyn Fn(&FileMsg, bool) -> io::Result<()> + Send + Sync>;

#[derive(Clone)]
pub struct ServiceConfig {
    /// Where received files go (created on demand).
    pub download_dir: PathBuf,
    /// Largest transfer accepted or sent.
    pub limits: Limits,
    /// Accept offers from the peer.
    pub receive: bool,
    pub mark: MarkFn,
    /// We are the host (our transfer ids have bit 31 set). The viewer passes false.
    pub host_role: bool,
}

/// Something the UI should tell the user.
#[derive(Debug, Clone, PartialEq)]
pub enum Notice {
    /// A transfer from the peer completed: `items` = top-level files/folders created in `dir`.
    Received { files: u32, bytes: u64, dir: PathBuf, items: Vec<PathBuf> },
    /// Our transfer was verified and saved by the peer.
    Sent { files: u32, bytes: u64 },
    /// A transfer started (incoming = from the peer).
    Started { incoming: bool, files: u32, bytes: u64 },
    Failed(String),
    Info(String),
}

/// Live progress of an active transfer.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Progress {
    pub incoming: bool,
    pub files: u32,
    /// Bytes confirmed (outgoing: acknowledged by the peer; incoming: written).
    pub done: u64,
    pub total: u64,
}

#[derive(Debug, Clone, PartialEq)]
enum Phase {
    Offered,
    Sending,
    WaitDone,
    Declined(u8, String),
    PeerCancelled(u8, String),
    Done,
}

struct Out {
    id: u32,
    files: u32,
    total: u64,
    acked: u64,
    phase: Phase,
}

struct Peer {
    send: SendFn,
    caps: Option<(u32, Limits)>,
}

struct State {
    peer: Option<Peer>,
    /// Bumped on every connect/disconnect: work from an older connection is dropped.
    gen: u64,
    queue: VecDeque<Vec<PathBuf>>,
    out: Option<Out>,
    /// The user cancelled the outgoing transfer.
    out_cancel: bool,
    inc: Option<Progress>,
    inc_id: u32,
    next_id: u32,
}

enum IncJob {
    Offer { gen: u64, id: u32, total: u64, files: Vec<FileEntry> },
    Chunk { gen: u64, id: u32, index: u32, offset: u64, data: Vec<u8> },
    End { gen: u64, id: u32, index: u32, sha256: [u8; 32] },
    /// The peer cancelled transfer `id`.
    PeerCancel { id: u32, reason: u8, detail: String },
    /// The peer ignored flow control (chunks piling up unprocessed): cancel transfer `id`.
    Overflow { id: u32 },
    /// Drop whatever is in progress (user cancel or disconnect); tell the peer if `notify`.
    Abort { notify: bool },
}

struct Shared {
    st: Mutex<State>,
    cv: Condvar,
    cfg: Mutex<ServiceConfig>,
    notify: Box<dyn Fn(Notice) + Send + Sync>,
    inc_tx: Mutex<mpsc::Sender<IncJob>>,
    /// Chunk bytes handed to the writer thread but not yet written.
    queued: AtomicU64,
    overflowed: AtomicBool,
    /// Offers handed to the worker but not yet answered. A sender runs one transfer at a time
    /// (§6.4), so more than a couple means it ignores that; extra offers are dropped instead of
    /// queueing up to 32 MiB each.
    pending_offers: AtomicU32,
}

/// Offers that may wait for the worker at once (one being validated, one queued).
const MAX_PENDING_OFFERS: u32 = 2;

/// Unwritten chunk bytes a receiver tolerates before it cancels (a sender honoring the window
/// never gets near this; bounds memory against one that doesn't).
pub const RECEIVE_QUEUE_MAX: u64 = 4 * FILE_WINDOW;

/// File transfers for one viewer (or, in tests, host) over successive connections.
#[derive(Clone)]
pub struct Service {
    sh: Arc<Shared>,
}

impl Service {
    pub fn start(cfg: ServiceConfig, notify: impl Fn(Notice) + Send + Sync + 'static) -> Service {
        let (tx, rx) = mpsc::channel();
        let next_id = if cfg.host_role { FILE_HOST_ID_BIT | 1 } else { 1 };
        let sh = Arc::new(Shared {
            st: Mutex::new(State {
                peer: None,
                gen: 0,
                queue: VecDeque::new(),
                out: None,
                out_cancel: false,
                inc: None,
                inc_id: 0,
                next_id,
            }),
            cv: Condvar::new(),
            cfg: Mutex::new(cfg),
            notify: Box::new(notify),
            inc_tx: Mutex::new(tx),
            queued: AtomicU64::new(0),
            overflowed: AtomicBool::new(false),
            pending_offers: AtomicU32::new(0),
        });
        {
            let sh = sh.clone();
            std::thread::Builder::new().name("glide-files-out".into()).spawn(move || out_worker(&sh)).expect("spawn files-out");
        }
        {
            let sh = sh.clone();
            std::thread::Builder::new().name("glide-files-in".into()).spawn(move || in_worker(&sh, rx)).expect("spawn files-in");
        }
        Service { sh }
    }

    pub fn set_config(&self, cfg: ServiceConfig) {
        *self.sh.cfg.lock().unwrap() = cfg;
    }

    pub fn download_dir(&self) -> PathBuf {
        self.sh.cfg.lock().unwrap().download_dir.clone()
    }

    /// A new authenticated connection; file messages may flow once the peer's caps are known.
    pub fn connected(&self, send: SendFn) {
        let mut st = self.sh.st.lock().unwrap();
        st.gen += 1;
        st.peer = Some(Peer { send, caps: None });
        self.sh.cv.notify_all();
    }

    /// The connection is gone: active transfers end (partial files are deleted).
    pub fn disconnected(&self) {
        let (had_out, had_inc) = {
            let mut st = self.sh.st.lock().unwrap();
            st.gen += 1;
            st.peer = None;
            let r = (st.out.is_some(), st.inc.is_some());
            st.inc = None;
            self.sh.cv.notify_all();
            r
        };
        let _ = self.sh.inc_tx.lock().unwrap().send(IncJob::Abort { notify: false });
        if had_out || had_inc {
            (self.sh.notify)(Notice::Failed("File transfer interrupted: connection lost".into()));
        }
    }

    /// The host's FileCaps (viewer) — or, for a host-role service, the caps we advertise.
    pub fn set_peer_caps(&self, flags: u32, limits: Limits) {
        let mut st = self.sh.st.lock().unwrap();
        if let Some(p) = st.peer.as_mut() {
            p.caps = Some((flags, limits));
        }
        self.sh.cv.notify_all();
    }

    /// FileCaps flags of the peer (None: not negotiated / not connected).
    pub fn peer_flags(&self) -> Option<u32> {
        self.sh.st.lock().unwrap().peer.as_ref().and_then(|p| p.caps.map(|c| c.0))
    }

    /// Queue files/folders to send to the peer.
    pub fn send_paths(&self, paths: Vec<PathBuf>) {
        if paths.is_empty() {
            return;
        }
        let msg = {
            let mut st = self.sh.st.lock().unwrap();
            match st.peer.as_ref().map(|p| p.caps) {
                None => Some("Not connected — files not sent"),
                Some(None) | Some(Some((0, _))) => Some("This host doesn't support file transfer"),
                Some(Some((f, _))) if f & FILE_CAPS_RECEIVE == 0 => Some("This host doesn't accept files"),
                Some(_) => {
                    st.queue.push_back(paths);
                    self.sh.cv.notify_all();
                    None
                }
            }
        };
        if let Some(m) = msg {
            (self.sh.notify)(Notice::Failed(m.into()));
        }
    }

    /// Ask the host for the files on its pasteboard (Ctrl+Alt+Shift+V).
    pub fn pull(&self) -> Result<(), String> {
        let send = {
            let st = self.sh.st.lock().unwrap();
            match st.peer.as_ref() {
                None => return Err("Not connected".into()),
                Some(p) => match p.caps {
                    Some((f, _)) if f & FILE_CAPS_SEND != 0 => p.send.clone(),
                    _ => return Err("This host can't send files".into()),
                },
            }
        };
        send(&FileMsg::Pull, false).map_err(|e| e.to_string())
    }

    /// Cancel everything (both directions and the queue). Returns true if anything was active.
    pub fn cancel_all(&self) -> bool {
        let (any, inc) = {
            let mut st = self.sh.st.lock().unwrap();
            let q = !st.queue.is_empty();
            st.queue.clear();
            let out = st.out.is_some();
            if out {
                st.out_cancel = true;
            }
            let inc = st.inc.is_some();
            self.sh.cv.notify_all();
            (q || out || inc, inc)
        };
        if inc {
            let _ = self.sh.inc_tx.lock().unwrap().send(IncJob::Abort { notify: true });
        }
        any
    }

    /// Active transfers (outgoing first).
    pub fn progress(&self) -> Vec<Progress> {
        let st = self.sh.st.lock().unwrap();
        let mut v = Vec::new();
        if let Some(o) = &st.out {
            v.push(Progress { incoming: false, files: o.files, done: o.acked, total: o.total });
        }
        if let Some(i) = st.inc {
            v.push(i);
        }
        v
    }

    pub fn busy(&self) -> bool {
        let st = self.sh.st.lock().unwrap();
        st.out.is_some() || st.inc.is_some() || !st.queue.is_empty()
    }

    /// A file message from the peer (receive thread; returns quickly).
    pub fn on_message(&self, m: FileMsg) {
        let host_role = self.sh.cfg.lock().unwrap().host_role;
        let mut st = self.sh.st.lock().unwrap();
        let gen = st.gen;
        let ours = |id: u32| id != 0 && id_is_hosts(id) == host_role;
        let job = match m {
            FileMsg::Caps { flags, max_total_bytes, max_files } => {
                if let Some(p) = st.peer.as_mut() {
                    p.caps = Some((flags, Limits { max_total_bytes, max_files }));
                }
                None
            }
            FileMsg::Offer { id, total_bytes, files } => {
                self.sh.overflowed.store(false, Ordering::Relaxed);
                if self.sh.pending_offers.fetch_add(1, Ordering::Relaxed) >= MAX_PENDING_OFFERS {
                    self.sh.pending_offers.fetch_sub(1, Ordering::Relaxed);
                    eprintln!("files: dropping offer {id:#x}: the peer sent offers faster than they can be answered");
                    None
                } else {
                    Some(IncJob::Offer { gen, id, total: total_bytes, files })
                }
            }
            FileMsg::Chunk { id, index, offset, data } => {
                let n = data.len() as u64;
                if self.sh.overflowed.load(Ordering::Relaxed) {
                    None
                } else if self.sh.queued.load(Ordering::Relaxed) + n > RECEIVE_QUEUE_MAX {
                    self.sh.overflowed.store(true, Ordering::Relaxed);
                    Some(IncJob::Overflow { id })
                } else {
                    self.sh.queued.fetch_add(n, Ordering::Relaxed);
                    Some(IncJob::Chunk { gen, id, index, offset, data })
                }
            }
            FileMsg::End { id, index, sha256 } => Some(IncJob::End { gen, id, index, sha256 }),
            FileMsg::Cancel { id, reason, detail } if !ours(id) => Some(IncJob::PeerCancel { id, reason, detail }),
            FileMsg::Answer { id, status: s, detail } => {
                if let Some(o) = st.out.as_mut().filter(|o| o.id == id && o.phase == Phase::Offered) {
                    o.phase = if s == status::OK { Phase::Sending } else { Phase::Declined(s, detail) };
                }
                None
            }
            FileMsg::Ack { id, bytes } => {
                if let Some(o) = st.out.as_mut().filter(|o| o.id == id) {
                    o.acked = o.acked.max(bytes.min(o.total));
                }
                None
            }
            FileMsg::Done { id, .. } => {
                if let Some(o) = st.out.as_mut().filter(|o| o.id == id) {
                    o.phase = Phase::Done;
                }
                None
            }
            FileMsg::Cancel { id, reason, detail } => {
                if let Some(o) = st.out.as_mut().filter(|o| o.id == id) {
                    o.phase = Phase::PeerCancelled(reason, detail);
                }
                None
            }
            FileMsg::PullResult { status: s, detail } => {
                drop(st);
                if s != status::OK {
                    let d = if detail.is_empty() { status::text(s).to_string() } else { detail };
                    (self.sh.notify)(Notice::Info(d));
                }
                return;
            }
            FileMsg::Pull => None, // host-side request; a viewer never receives it
        };
        self.sh.cv.notify_all();
        drop(st);
        if let Some(j) = job {
            let _ = self.sh.inc_tx.lock().unwrap().send(j);
        }
    }
}

/// Outgoing transfers, one at a time.
fn out_worker(sh: &Shared) {
    loop {
        // Wait for work: connected, caps known, queue non-empty.
        let (paths, send, gen, peer_limits) = {
            let mut st = sh.st.lock().unwrap();
            loop {
                if let (Some(Peer { send, caps: Some((_, l)) }), false) = (st.peer.as_ref(), st.queue.is_empty()) {
                    let (send, l) = (send.clone(), *l);
                    let paths = st.queue.pop_front().unwrap();
                    st.out_cancel = false;
                    break (paths, send, st.gen, l);
                }
                if !st.queue.is_empty() && st.peer.is_none() {
                    st.queue.clear();
                }
                st = sh.cv.wait(st).unwrap();
            }
        };
        let limits = sh.cfg.lock().unwrap().limits.min(peer_limits);
        let c = match collect(&paths, &limits) {
            Ok(c) => c,
            Err((_, why)) => {
                (sh.notify)(Notice::Failed(format!("Files not sent: {why}")));
                continue;
            }
        };
        if !c.skipped.is_empty() {
            eprintln!("files: skipped {:?}", c.skipped);
            (sh.notify)(Notice::Info(format!("Skipped {} (links or special files): {}", count_files(c.skipped.len() as u32), c.skipped.join(", "))));
        }
        if c.files.is_empty() {
            (sh.notify)(Notice::Failed("Nothing to send (only empty folders or links)".into()));
            continue;
        }
        let id = {
            let mut st = sh.st.lock().unwrap();
            if st.gen != gen {
                continue;
            }
            let id = st.next_id;
            let host = id_is_hosts(id);
            st.next_id = st.next_id.wrapping_add(1);
            if st.next_id & !FILE_HOST_ID_BIT == 0 || id_is_hosts(st.next_id) != host {
                st.next_id = if host { FILE_HOST_ID_BIT | 1 } else { 1 };
            }
            st.out = Some(Out { id, files: c.files.len() as u32, total: c.total, acked: 0, phase: Phase::Offered });
            id
        };
        let mut og = Outgoing::new(id, c);
        let (files, total) = (og.file_count(), og.total);
        eprintln!("files: offering {} ({}) as transfer {id:#x}", count_files(files), human_bytes(total));
        let result = run_outgoing(sh, &send, gen, &mut og);
        let mut st = sh.st.lock().unwrap();
        st.out = None;
        drop(st);
        match result {
            Ok(()) => (sh.notify)(Notice::Sent { files, bytes: total }),
            Err(Some(why)) => (sh.notify)(Notice::Failed(why)),
            Err(None) => {} // connection gone: disconnected() already told the user
        }
    }
}

/// Offer → wait for the answer → stream chunks within the ack window → wait for Done.
/// Err(None) = the connection went away.
fn run_outgoing(sh: &Shared, send: &SendFn, gen: u64, og: &mut Outgoing) -> Result<(), Option<String>> {
    let id = og.id;
    let lost = |e: io::Error| {
        eprintln!("files: send failed: {e}");
        None
    };
    send(&og.offer(), false).map_err(lost)?;
    // Wait until `pred` holds for the current phase/acks; returns the phase.
    let wait = |pred: &dyn Fn(&Out) -> bool, timeout: Duration| -> Result<Phase, Option<String>> {
        let deadline = Instant::now() + timeout;
        let mut st = sh.st.lock().unwrap();
        loop {
            if st.gen != gen {
                return Err(None);
            }
            if st.out_cancel {
                drop(st);
                let _ = send(&FileMsg::Cancel { id, reason: status::CANCELLED, detail: "cancelled by the user".into() }, false);
                return Err(Some("File transfer cancelled".into()));
            }
            let o = st.out.as_ref().unwrap();
            match &o.phase {
                Phase::Declined(s, d) => {
                    let d = if d.is_empty() { status::text(*s).to_string() } else { format!("{} — {d}", status::text(*s)) };
                    return Err(Some(format!("Files not sent: the host declined ({d})")));
                }
                Phase::PeerCancelled(s, d) => {
                    let d = if d.is_empty() { status::text(*s).to_string() } else { format!("{} — {d}", status::text(*s)) };
                    return Err(Some(format!("File transfer stopped by the host ({d})")));
                }
                _ if pred(o) => return Ok(o.phase.clone()),
                _ => {}
            }
            let now = Instant::now();
            if now >= deadline {
                drop(st);
                let _ = send(&FileMsg::Cancel { id, reason: status::CANCELLED, detail: "timed out".into() }, false);
                return Err(Some("File transfer timed out".into()));
            }
            st = sh.cv.wait_timeout(st, (deadline - now).min(Duration::from_millis(500))).unwrap().0;
        }
    };
    wait(&|o| o.phase != Phase::Offered, Duration::from_secs(60))?;
    (sh.notify)(Notice::Started { incoming: false, files: og.file_count(), bytes: og.total });
    loop {
        // Flow control: at most FILE_SEND_WINDOW unacknowledged (bounds what sits ahead of input).
        let sent = og.sent;
        wait(&|o| sent.saturating_sub(o.acked) + FILE_CHUNK_MAX as u64 <= FILE_SEND_WINDOW, Duration::from_secs(60))?;
        match og.next_msg() {
            Ok(Some(m)) => {
                let bulk = matches!(m, FileMsg::Chunk { .. });
                if bulk {
                    send(&m, true).map_err(lost)?;
                } else {
                    send(&m, false).map_err(lost)?;
                }
            }
            Ok(None) => break,
            Err((s, why)) => {
                let _ = send(&FileMsg::Cancel { id, reason: s, detail: why.clone() }, false);
                return Err(Some(format!("File transfer failed: {why}")));
            }
        }
    }
    {
        let mut st = sh.st.lock().unwrap();
        if let Some(o) = st.out.as_mut() {
            if o.phase == Phase::Sending {
                o.phase = Phase::WaitDone;
            }
        }
    }
    wait(&|o| o.phase == Phase::Done, Duration::from_secs(120)).map(|_| ())
}

/// Incoming transfers (offers, chunk writes, verification), one at a time.
struct PendingOffer<'a>(&'a AtomicU32);

impl Drop for PendingOffer<'_> {
    fn drop(&mut self) {
        self.0.fetch_sub(1, Ordering::Relaxed);
    }
}

fn in_worker(sh: &Shared, rx: mpsc::Receiver<IncJob>) {
    let mut cur: Option<(u64, Incoming)> = None;
    let peer_send = |gen: u64| -> Option<SendFn> {
        let st = sh.st.lock().unwrap();
        (st.gen == gen).then(|| st.peer.as_ref().map(|p| p.send.clone())).flatten()
    };
    let set_progress = |p: Option<Progress>, id: u32| {
        let mut st = sh.st.lock().unwrap();
        st.inc = p;
        st.inc_id = id;
    };
    for job in rx {
        match job {
            IncJob::Offer { gen, id, total, files } => {
                // Decrements when this job is done (any path out of this arm).
                let _pending = PendingOffer(&sh.pending_offers);
                let Some(send) = peer_send(gen) else { continue };
                let cfg = sh.cfg.lock().unwrap().clone();
                let n = files.len() as u32;
                eprintln!("files: offer {id:#x}: {} ({})", count_files(n), human_bytes(total));
                let answer = |s: u8, detail: String| {
                    if s != status::OK {
                        eprintln!("files: declining {id:#x}: {} ({detail})", status::text(s));
                    }
                    let _ = send(&FileMsg::Answer { id, status: s, detail }, false);
                };
                if !cfg.receive {
                    answer(status::DECLINED, "receiving files is turned off on this PC".into());
                    continue;
                }
                if let Some((g, _)) = &cur {
                    if *g == gen {
                        answer(status::BUSY, "another transfer is in progress".into());
                        continue;
                    }
                    cur = None; // stale (previous connection)
                }
                let rel = match validate_offer(id, total, &files, &cfg.limits, !cfg.host_role) {
                    Ok(r) => r,
                    Err((s, why)) => {
                        answer(s, why.clone());
                        (sh.notify)(Notice::Failed(format!("Refused files from the host: {why}")));
                        continue;
                    }
                };
                match Incoming::new(id, &cfg.download_dir, files, rel, cfg.mark) {
                    Ok(inc) => {
                        answer(status::OK, String::new());
                        set_progress(Some(Progress { incoming: true, files: n, done: 0, total }), id);
                        (sh.notify)(Notice::Started { incoming: true, files: n, bytes: total });
                        cur = Some((gen, inc));
                    }
                    Err(e) => {
                        let (s, why) = io_fail("cannot create the download folder", &e);
                        answer(s, why.clone());
                        (sh.notify)(Notice::Failed(why));
                    }
                }
            }
            IncJob::Chunk { gen, id, index, offset, data } => {
                sh.queued.fetch_sub(data.len() as u64, Ordering::Relaxed);
                let Some((_, inc)) = cur.as_mut().filter(|(g, i)| *g == gen && i.id == id) else { continue };
                let r = inc.chunk(index, offset, &data);
                after_step(sh, &mut cur, gen, id, r.map(|_| None), &peer_send, &set_progress);
            }
            IncJob::End { gen, id, index, sha256 } => {
                let Some((_, inc)) = cur.as_mut().filter(|(g, i)| *g == gen && i.id == id) else { continue };
                let r = inc.end(index, &sha256);
                after_step(sh, &mut cur, gen, id, r.map(Some), &peer_send, &set_progress);
            }
            IncJob::PeerCancel { id, reason, detail } => {
                if cur.as_ref().is_some_and(|(_, i)| i.id == id) {
                    cur = None;
                    set_progress(None, 0);
                    let d = if detail.is_empty() { status::text(reason).to_string() } else { detail };
                    (sh.notify)(Notice::Failed(format!("The host stopped sending files ({d})")));
                }
            }
            IncJob::Overflow { id } => {
                if let Some((gen, _)) = cur.as_ref().filter(|(_, i)| i.id == id) {
                    let gen = *gen;
                    after_step(sh, &mut cur, gen, id, Err((status::PROTOCOL, "the sender ignored flow control".into())), &peer_send, &set_progress);
                }
            }
            IncJob::Abort { notify } => {
                if let Some((gen, inc)) = cur.take() {
                    if notify {
                        if let Some(send) = peer_send(gen) {
                            let _ = send(&FileMsg::Cancel { id: inc.id, reason: status::CANCELLED, detail: "cancelled by the user".into() }, false);
                        }
                    }
                    drop(inc); // deletes the partial file
                    set_progress(None, 0);
                }
            }
        }
    }
}

/// After a chunk/end: ack, finish, or cancel with an error.
fn after_step(
    sh: &Shared,
    cur: &mut Option<(u64, Incoming)>,
    gen: u64,
    id: u32,
    r: Result<Option<PathBuf>, Fail>,
    peer_send: &dyn Fn(u64) -> Option<SendFn>,
    set_progress: &dyn Fn(Option<Progress>, u32),
) {
    let Some(send) = peer_send(gen) else {
        *cur = None;
        return;
    };
    let inc = &cur.as_ref().unwrap().1;
    match r {
        Ok(saved) => {
            let _ = send(&FileMsg::Ack { id, bytes: inc.received() }, false);
            if let Some(p) = saved {
                eprintln!("files: saved {}", p.display());
            }
            if inc.all_done() {
                let _ = send(&FileMsg::Done { id, files: inc.file_count() }, false);
                let (_, inc) = cur.take().unwrap();
                set_progress(None, 0);
                (sh.notify)(Notice::Received { files: inc.file_count(), bytes: inc.total(), dir: inc.root().to_path_buf(), items: inc.saved.clone() });
            } else {
                set_progress(Some(Progress { incoming: true, files: inc.file_count(), done: inc.received(), total: inc.total() }), id);
            }
        }
        Err((s, why)) => {
            eprintln!("files: incoming {id:#x} failed: {why}");
            let _ = send(&FileMsg::Cancel { id, reason: s, detail: why.clone() }, false);
            *cur = None;
            set_progress(None, 0);
            (sh.notify)(Notice::Failed(format!("File transfer failed: {why}")));
        }
    }
}

/// Default download folder: `<Downloads>/Glide`.
pub fn default_download_dir(downloads: Option<PathBuf>) -> Option<PathBuf> {
    downloads.map(|d| d.join("Glide"))
}

pub fn now_ms() -> i64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.as_millis() as i64)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn vectors() -> serde_json::Value {
        serde_json::from_str(include_str!("../../docs/file-transfer-vectors.json")).unwrap()
    }

    #[test]
    fn path_sanitizer_matches_shared_vectors() {
        let v = vectors();
        let paths = v["paths"].as_array().unwrap();
        assert!(paths.len() > 40);
        for p in paths {
            let input = p["in"].as_str().unwrap();
            let got = sanitize_path(input).ok();
            let want: Option<Vec<String>> = p["out"].as_array().map(|a| a.iter().map(|s| s.as_str().unwrap().to_string()).collect());
            assert_eq!(got, want, "path {input:?}");
        }
        for s in v["suffix"].as_array().unwrap() {
            let got = with_suffix(s["name"].as_str().unwrap(), s["n"].as_u64().unwrap() as u32, s["dir"].as_bool().unwrap());
            assert_eq!(got, s["out"].as_str().unwrap());
        }
    }

    #[test]
    fn sanitized_components_are_always_safe() {
        // Property check over many adversarial strings: no separators, no traversal, no
        // reserved device names, no trailing dot/space, bounded length.
        let pieces = ["..", ".", " ", "CON", "con", "LPT1", "\\", ":", "\u{202e}", "\0", "a", "日本", "x".repeat(150).leak(), "?", "nul", "COM¹"];
        let mut n = 0;
        for a in pieces {
            for b in pieces {
                for c in pieces {
                    let s = format!("{a}{b}{c}");
                    let out = sanitize_component(&s);
                    n += 1;
                    assert!(!out.is_empty() && out.len() <= MAX_COMPONENT_BYTES + 1, "{s:?} -> {out:?}");
                    assert!(!out.contains(['/', '\\', ':', '\0', '\u{202e}']), "{s:?} -> {out:?}");
                    assert!(out != "." && out != "..", "{s:?}");
                    assert!(!out.ends_with('.') && !out.ends_with(' '), "{s:?} -> {out:?}");
                    assert!(!is_reserved(out.split('.').next().unwrap().trim_end_matches(' ')), "{s:?} -> {out:?}");
                    assert_eq!(sanitize_component(&out), out, "idempotent for {s:?}");
                }
            }
        }
        assert!(n > 1000);
    }

    fn entry(p: &str, size: u64) -> FileEntry {
        FileEntry { path: p.into(), size, mtime_ms: 0 }
    }

    #[test]
    fn offer_validation() {
        let l = Limits { max_total_bytes: 100, max_files: 3 };
        let ok = validate_offer(0x8000_0001, 3, &[entry("a/b.txt", 1), entry("a/c.txt", 2)], &l, true).unwrap();
        assert_eq!(ok, vec![vec!["a", "b.txt"], vec!["a", "c.txt"]]);
        let st = |r: Result<Vec<Vec<String>>, Fail>| r.unwrap_err().0;
        assert_eq!(st(validate_offer(1, 1, &[entry("a", 1)], &l, true)), status::PROTOCOL, "viewer id from host");
        assert_eq!(st(validate_offer(0x8000_0001, 1, &[entry("a", 1)], &l, false)), status::PROTOCOL, "host id from viewer");
        assert_eq!(st(validate_offer(0, 1, &[entry("a", 1)], &l, false)), status::PROTOCOL);
        assert_eq!(st(validate_offer(1, 0, &[], &l, false)), status::PROTOCOL);
        assert_eq!(st(validate_offer(1, 5, &[entry("a", 1)], &l, false)), status::PROTOCOL, "bad total");
        assert_eq!(st(validate_offer(1, 0, &[entry("a", u64::MAX), entry("b", 1)], &l, false)), status::PROTOCOL, "overflow");
        assert_eq!(st(validate_offer(1, 101, &[entry("a", 101)], &l, false)), status::TOO_LARGE);
        let four: Vec<FileEntry> = (0..4).map(|i| entry(&format!("f{i}"), 0)).collect();
        assert_eq!(st(validate_offer(1, 0, &four, &l, false)), status::TOO_LARGE);
        assert_eq!(st(validate_offer(1, 1, &[entry("../x", 1)], &l, false)), status::BAD_NAME);
        assert_eq!(st(validate_offer(1, 1, &[entry("C:\\x", 1)], &l, false)), status::BAD_NAME);
        assert_eq!(st(validate_offer(1, 2, &[entry("d", 1), entry("D/x", 1)], &l, false)), status::BAD_NAME, "file/folder clash");
        // Same name twice is fine (the second becomes "x (2)").
        assert!(validate_offer(1, 2, &[entry("x", 1), entry("X", 1)], &l, false).is_ok());
    }

    fn tmpdir(tag: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("glide-files-{tag}-{}-{}", std::process::id(), now_ms()));
        fs::create_dir_all(&d).unwrap();
        d
    }

    fn sha(b: &[u8]) -> [u8; 32] {
        Sha256::digest(b).into()
    }

    fn no_mark(_: &Path, _: bool) -> io::Result<()> {
        Ok(())
    }

    #[test]
    fn incoming_writes_verifies_and_never_overwrites() {
        let root = tmpdir("in");
        fs::write(root.join("a.txt"), b"existing").unwrap();
        fs::create_dir(root.join("Photos")).unwrap();
        let files = vec![entry("a.txt", 5), entry("Photos/x.jpg", 3), entry("Photos/sub/y", 0), entry("Photos/X.JPG", 1)];
        let rel = validate_offer(1, 9, &files, &Limits::default(), false).unwrap();
        let mut inc = Incoming::new(1, &root, files, rel, no_mark).unwrap();
        inc.chunk(0, 0, b"hel").unwrap();
        assert!(inc.chunk(0, 1, b"x").is_err(), "non-contiguous offset");
        drop(inc);
        let mut inc = {
            let files = vec![entry("a.txt", 5), entry("Photos/x.jpg", 3), entry("Photos/sub/y", 0), entry("Photos/X.JPG", 1)];
            let rel = validate_offer(2, 9, &files, &Limits::default(), false).unwrap();
            Incoming::new(2, &root, files, rel, no_mark).unwrap()
        };
        inc.chunk(0, 0, b"hel").unwrap();
        inc.chunk(0, 3, b"lo").unwrap();
        assert_eq!(inc.chunk(0, 5, b"!").unwrap_err().0, status::PROTOCOL, "past the declared size");
        assert_eq!(inc.end(0, &sha(b"hello")).unwrap(), root.join("a (2).txt"));
        assert_eq!(fs::read(root.join("a.txt")).unwrap(), b"existing", "never overwritten");
        assert_eq!(inc.chunk(2, 0, b"z").unwrap_err().0, status::PROTOCOL, "out of order");
        inc.chunk(1, 0, b"jpg").unwrap();
        inc.end(1, &sha(b"jpg")).unwrap();
        inc.end(2, &sha(b"")).unwrap();
        inc.chunk(3, 0, b"J").unwrap();
        let last = inc.end(3, &sha(b"J")).unwrap();
        assert!(inc.all_done());
        // The existing "Photos" folder is not merged into.
        assert_eq!(fs::read(root.join("Photos (2)/x.jpg")).unwrap(), b"jpg");
        assert!(root.join("Photos (2)/sub/y").is_file());
        assert!(fs::read_dir(root.join("Photos")).unwrap().next().is_none());
        // Case-insensitive file systems: "X.JPG" collides with "x.jpg" → renamed; else as-is.
        assert!(last == root.join("Photos (2)/X.JPG") || last == root.join("Photos (2)/X (2).JPG"), "{last:?}");
        assert_eq!(inc.saved, vec![root.join("a (2).txt"), root.join("Photos (2)")]);
        // No temp files left.
        let parts = walk_names(&root).into_iter().filter(|n| n.ends_with(".part")).count();
        assert_eq!(parts, 0);
        fs::remove_dir_all(&root).unwrap();
    }

    fn walk_names(d: &Path) -> Vec<String> {
        let mut v = Vec::new();
        for e in fs::read_dir(d).unwrap().flatten() {
            v.push(e.file_name().to_string_lossy().into_owned());
            if e.file_type().unwrap().is_dir() {
                v.extend(walk_names(&e.path()));
            }
        }
        v
    }

    #[test]
    fn incoming_rejects_bad_hash_and_cleans_up() {
        let root = tmpdir("bad");
        let files = vec![entry("evil.bin", 4)];
        let rel = validate_offer(1, 4, &files, &Limits::default(), false).unwrap();
        let mut inc = Incoming::new(1, &root, files, rel, no_mark).unwrap();
        inc.chunk(0, 0, b"evil").unwrap();
        assert_eq!(inc.end(0, &sha(b"good")).unwrap_err().0, status::VERIFY);
        assert!(walk_names(&root).is_empty(), "nothing left behind: {:?}", walk_names(&root));
        // Abort mid-file removes the partial file.
        let files = vec![entry("big.bin", 10)];
        let rel = validate_offer(2, 10, &files, &Limits::default(), false).unwrap();
        let mut inc = Incoming::new(2, &root, files, rel, no_mark).unwrap();
        inc.chunk(0, 0, b"12345").unwrap();
        assert_eq!(walk_names(&root).len(), 1);
        drop(inc);
        assert!(walk_names(&root).is_empty());
        fs::remove_dir_all(&root).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn collect_refuses_links_and_special_files() {
        let d = tmpdir("collect");
        let src = d.join("Folder");
        fs::create_dir_all(src.join("sub/deeper")).unwrap();
        fs::write(src.join("a.txt"), b"a").unwrap();
        fs::write(src.join("sub/deeper/b.txt"), b"bb").unwrap();
        fs::create_dir(src.join("empty")).unwrap();
        std::os::unix::fs::symlink("/etc/passwd", src.join("passwd-link")).unwrap();
        std::os::unix::fs::symlink("/etc", src.join("etc-link")).unwrap();
        std::os::unix::fs::symlink(src.join("a.txt"), d.join("top-link")).unwrap();
        let c = collect(&[src.clone(), d.join("top-link")], &Limits::default()).unwrap();
        let rels: Vec<&str> = c.files.iter().map(|f| f.entry.path.as_str()).collect();
        assert_eq!(rels, vec!["Folder/a.txt", "Folder/sub/deeper/b.txt"]);
        assert_eq!(c.total, 3);
        assert_eq!(c.skipped.len(), 3, "{:?}", c.skipped);
        // Limits
        assert_eq!(collect(&[src.clone()], &Limits { max_total_bytes: 2, max_files: 10 }).err().unwrap().0, status::TOO_LARGE);
        assert_eq!(collect(&[src], &Limits { max_total_bytes: 100, max_files: 1 }).err().unwrap().0, status::TOO_LARGE);
        fs::remove_dir_all(&d).unwrap();
    }

    #[test]
    fn outgoing_detects_changed_source() {
        let d = tmpdir("out");
        let f = d.join("f.bin");
        fs::write(&f, vec![1u8; 300_000]).unwrap();
        let c = collect(&[f.clone()], &Limits::default()).unwrap();
        fs::write(&f, vec![1u8; 10]).unwrap(); // shrinks before sending
        let mut og = Outgoing::new(1, c);
        assert_eq!(og.next_msg().unwrap_err().0, status::SOURCE_CHANGED);
        fs::remove_dir_all(&d).unwrap();
    }

    /// Two services back to back (viewer role ↔ host role) through the real wire encoding.
    fn pair(a_dir: &Path, b_dir: &Path) -> (Service, Service, mpsc::Receiver<Notice>, mpsc::Receiver<Notice>) {
        let (atx, arx) = mpsc::channel();
        let (btx, brx) = mpsc::channel();
        let atx = Mutex::new(atx);
        let btx = Mutex::new(btx);
        let a = Service::start(
            ServiceConfig { download_dir: a_dir.into(), limits: Limits::default(), receive: true, mark: no_mark, host_role: false },
            move |n| {
                let _ = atx.lock().unwrap().send(n);
            },
        );
        let b = Service::start(
            ServiceConfig { download_dir: b_dir.into(), limits: Limits::default(), receive: true, mark: no_mark, host_role: true },
            move |n| {
                let _ = btx.lock().unwrap().send(n);
            },
        );
        let wire = |to: Service, host_to_viewer: bool| -> SendFn {
            let (tx, rx) = mpsc::channel::<Vec<u8>>();
            std::thread::spawn(move || {
                for bytes in rx {
                    let m = if host_to_viewer {
                        match crate::protocol::HostMsg::decode(bytes).unwrap() {
                            crate::protocol::HostMsg::File(m) => m,
                            _ => unreachable!(),
                        }
                    } else {
                        match crate::protocol::ClientMsg::decode(&bytes).unwrap() {
                            crate::protocol::ClientMsg::File(m) => m,
                            _ => unreachable!(),
                        }
                    };
                    to.on_message(m);
                }
            });
            let tx = Mutex::new(tx);
            Arc::new(move |m: &FileMsg, _bulk: bool| {
                tx.lock().unwrap().send(m.encode()).map_err(|_| io::Error::from(io::ErrorKind::BrokenPipe))
            })
        };
        a.connected(wire(b.clone(), false));
        b.connected(wire(a.clone(), true));
        let caps = FILE_CAPS_RECEIVE | FILE_CAPS_SEND;
        a.on_message(FileMsg::Caps { flags: caps, max_total_bytes: 8 << 30, max_files: 10_000 });
        b.set_peer_caps(caps, Limits::default());
        (a, b, arx, brx)
    }

    fn wait_for(rx: &mpsc::Receiver<Notice>, f: impl Fn(&Notice) -> bool) -> Notice {
        let end = Instant::now() + Duration::from_secs(20);
        loop {
            let n = rx.recv_timeout(end.saturating_duration_since(Instant::now())).expect("notice timeout");
            if f(&n) {
                return n;
            }
        }
    }

    fn pseudo_random(n: usize, seed: u32) -> Vec<u8> {
        let mut x = seed;
        (0..n)
            .map(|_| {
                x ^= x << 13;
                x ^= x >> 17;
                x ^= x << 5;
                x as u8
            })
            .collect()
    }

    #[test]
    fn loopback_transfer_both_directions() {
        let base = tmpdir("loop");
        let (a_dir, b_dir, src) = (base.join("viewer-dl"), base.join("host-dl"), base.join("src"));
        fs::create_dir_all(src.join("Album/nested")).unwrap();
        let big = pseudo_random(3_000_000 + 12_345, 7);
        fs::write(src.join("Album/big.bin"), &big).unwrap();
        fs::write(src.join("Album/nested/small.txt"), b"small").unwrap();
        fs::write(src.join("Album/empty.dat"), b"").unwrap();
        fs::write(src.join("single.txt"), b"one").unwrap();
        let (a, b, arx, brx) = pair(&a_dir, &b_dir);

        // viewer → host
        a.send_paths(vec![src.join("Album"), src.join("single.txt")]);
        let n = wait_for(&brx, |n| matches!(n, Notice::Received { .. }));
        let Notice::Received { files, bytes, items, .. } = n else { unreachable!() };
        assert_eq!((files, bytes), (4, big.len() as u64 + 5 + 3));
        assert_eq!(items, vec![b_dir.join("Album"), b_dir.join("single.txt")]);
        assert_eq!(fs::read(b_dir.join("Album/big.bin")).unwrap(), big);
        assert_eq!(fs::read(b_dir.join("Album/nested/small.txt")).unwrap(), b"small");
        assert_eq!(fs::read(b_dir.join("Album/empty.dat")).unwrap(), b"");
        assert!(matches!(wait_for(&arx, |n| matches!(n, Notice::Sent { .. })), Notice::Sent { files: 4, .. }));
        // mtime preserved
        let src_m = fs::metadata(src.join("Album/big.bin")).unwrap().modified().unwrap();
        let dst_m = fs::metadata(b_dir.join("Album/big.bin")).unwrap().modified().unwrap();
        let diff = src_m.duration_since(dst_m).unwrap_or_else(|e| e.duration());
        assert!(diff < Duration::from_millis(2), "{diff:?}");

        // Again: new names, nothing overwritten.
        a.send_paths(vec![src.join("Album"), src.join("single.txt")]);
        wait_for(&brx, |n| matches!(n, Notice::Received { .. }));
        assert_eq!(fs::read(b_dir.join("Album (2)/big.bin")).unwrap(), big);
        assert_eq!(fs::read(b_dir.join("single (2).txt")).unwrap(), b"one");

        // host → viewer
        b.send_paths(vec![src.join("Album/big.bin")]);
        wait_for(&arx, |n| matches!(n, Notice::Received { .. }));
        assert_eq!(fs::read(a_dir.join("big.bin")).unwrap(), big);
        wait_for(&brx, |n| matches!(n, Notice::Sent { .. }));
        assert!(!a.busy() && !b.busy());

        // Cancel mid-transfer from the receiving side: partial file removed, sender told.
        let huge = pseudo_random(40 << 20, 3);
        fs::write(src.join("huge.bin"), &huge).unwrap();
        b.send_paths(vec![src.join("huge.bin")]);
        wait_for(&arx, |n| matches!(n, Notice::Started { incoming: true, .. }));
        assert!(a.cancel_all());
        wait_for(&brx, |n| matches!(n, Notice::Failed(m) if m.contains("stopped by the host") || m.contains("cancelled")));
        std::thread::sleep(Duration::from_millis(200));
        assert!(!a_dir.join("huge.bin").exists());
        assert!(walk_names(&a_dir).iter().all(|n| !n.ends_with(".part")), "{:?}", walk_names(&a_dir));
        assert!(!a.busy());
        fs::remove_dir_all(&base).unwrap();
    }

    #[test]
    fn disconnect_mid_transfer_cleans_up() {
        let base = tmpdir("disc");
        let (a_dir, b_dir) = (base.join("a"), base.join("b"));
        fs::create_dir_all(&base).unwrap();
        fs::write(base.join("f.bin"), pseudo_random(30 << 20, 9)).unwrap();
        let (a, b, arx, _brx) = pair(&a_dir, &b_dir);
        b.send_paths(vec![base.join("f.bin")]);
        wait_for(&arx, |n| matches!(n, Notice::Started { incoming: true, .. }));
        a.disconnected();
        b.disconnected();
        wait_for(&arx, |n| matches!(n, Notice::Failed(_)));
        std::thread::sleep(Duration::from_millis(200));
        assert!(walk_names(&a_dir).is_empty(), "{:?}", walk_names(&a_dir));
        fs::remove_dir_all(&base).unwrap();
    }

    #[test]
    fn hostile_mtimes_are_ignored() {
        for ms in [i64::MAX, i64::MIN, -1, 0, MAX_MTIME_MS + 1, u64::MAX as i64] {
            assert_eq!(mtime_from_ms(ms), None, "{ms}");
        }
        assert!(mtime_from_ms(1_700_000_000_123).is_some());
        assert!(mtime_from_ms(MAX_MTIME_MS).is_some());
        // End to end: a file with a hostile mtime is still saved (mtime just not applied).
        let root = tmpdir("mtime");
        let files = vec![FileEntry { path: "t.txt".into(), size: 1, mtime_ms: i64::MAX }, FileEntry { path: "u.txt".into(), size: 0, mtime_ms: -5 }];
        let rel = validate_offer(1, 1, &files, &Limits::default(), false).unwrap();
        let mut inc = Incoming::new(1, &root, files, rel, no_mark).unwrap();
        inc.chunk(0, 0, b"x").unwrap();
        inc.end(0, &sha(b"x")).unwrap();
        inc.end(1, &sha(b"")).unwrap();
        assert!(inc.all_done() && root.join("t.txt").is_file() && root.join("u.txt").is_file());
        fs::remove_dir_all(&root).unwrap();
    }

    #[test]
    fn human_sizes() {
        assert_eq!(human_bytes(999), "999 bytes");
        assert_eq!(human_bytes(1500), "1.5 KB");
        assert_eq!(human_bytes(27_100_000), "27 MB");
        assert_eq!(count_files(1), "1 file");
    }
}
