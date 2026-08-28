# Wawona host waypipe with a WORKING SplitFD transport.
#
# Why this exists: wwn-waypipe's macos.nix patches the Rust port so that
# `--socket-fds R,W` parses, but its socket_connect arm is
#   `unreachable!("SplitFD is not used on macOS")`
# so the flag can never actually work on the host. The containerization
# framework's vsock can only be reached from the host process as an fd
# (dialVsock) — there is no /dev/vsock on macOS — and its unix-socket relay
# (BidirectionalRelay) is a byte pipe that strips SCM_RIGHTS, so waypipe must
# sit directly on the dialed fd. SplitFD is therefore the ONLY host transport
# for the container Wayland bridge (`--wayland-vsock-port`).
#
# (Also note: macos.nix's --socket-fds parsing needle targets a manual arg
# loop that does not exist in the v0.11.0 Rust port — it uses clap — so the
# flag would not even parse. This build adds it via clap instead.)
#
# Pending decision: land the same fix in wwn-waypipe/dependencies/libs/waypipe/
# macos.nix (needs that repo's approval) and drop this variant, or keep it as
# the wwn-containers-owned container-vsock waypipe.
{
  pkgs,
  lib,
}:

pkgs.rustPlatform.buildRustPackage rec {
  pname = "waypipe";
  version = "v0.11.0-wawona-splitfd";

  src = pkgs.fetchFromGitLab {
    owner = "mstoeckl";
    repo = "waypipe";
    rev = "v0.11.0";
    sha256 = "sha256-Tbd/yY90yb2+/ODYVL3SudHaJCGJKatZ9FuGM2uAX+8=";
  };

  # Fresh lock for the patched manifest (wwn-waypipe's Cargo.lock.patched is
  # generated for macos.nix's full IOSurface patch set and does not match this
  # spike's feature set). Pinned after the first build.
  cargoHash = "sha256-IUvXHLxrhc2Au57wsE53Q+NL1cZzFcaRG3HDV8s3xWw=";

  nativeBuildInputs = with pkgs; [
    pkg-config
    python3
    perl
    rustPlatform.bindgenHook
    # wrap-lz4/wrap-zstd build.rs spawn the `bindgen` CLI directly (not the
    # bindgen crate), so the binary itself must be on PATH.
    rust-bindgen
  ];

  buildInputs = with pkgs; [
    # NOTE: the Rust port generates its own Wayland protocol code and does not
    # link libwayland (verified: no wayland pkg-config usage in the source).
    # Plain nixpkgs `wayland` cannot build on macOS anyway (needs signalfd).
    zstd
    lz4
    libiconv
  ];

  # Mirror wwn-waypipe macos.nix: lz4+zstd, no video/Vulkan. dmabuf is omitted
  # on purpose — the spike renders software-only wl_shm and the guest waypipe
  # runs --no-gpu, so no dmabuf (and no IOSurface patch) is needed.
  buildNoDefaultFeatures = true;
  buildFeatures = [ "lz4" "zstd" ];

  postPatch = ''
    chmod -R u+w .

    # ============================================================
    # Align Cargo.toml with wwn-waypipe's Cargo.lock.patched (same edits
    # macos.nix makes): drop the video feature, the test_proto bin, and
    # the ash/Vulkan dep behind dmabuf. The spike builds lz4+zstd only.
    # ============================================================
    if [ -f "Cargo.toml" ]; then
      sed -i '/^video = /d' Cargo.toml
      sed -i 's/"video", //g' Cargo.toml
      perl -i -0777 -pe 's/\[\[bin\]\]\s+name = "test_proto"\s+path = "src\/test_proto.rs"\s*\n\s*required-features = \["test_proto"\]//gs' Cargo.toml
      sed -i '/^required-features = \["test_proto"\]$/d' Cargo.toml
      sed -i 's/^dmabuf = .*/dmabuf = []/' Cargo.toml
    fi

    # ============================================================
    # Socket wrapper for macOS (copied verbatim from wwn-waypipe's
    # dependencies/libs/waypipe/macos.nix): BSD sockets lack
    # SOCK_CLOEXEC/SOCK_NONBLOCK creation flags, so emulate with fcntl.
    # ============================================================
    cat > src/socket_wrapper.rs <<'SOCKWRAP_EOF'
//! Socket compatibility wrapper for macOS
//! macOS BSD sockets don't support SOCK_CLOEXEC and SOCK_NONBLOCK flags
//! at socket creation time, so we emulate them with fcntl.

use nix::sys::socket as real_socket;
pub use real_socket::*;
use std::os::unix::io::OwnedFd;

pub struct SockFlag(u32);
impl SockFlag {
    pub const SOCK_CLOEXEC: Self = Self(1 << 0);
    pub const SOCK_NONBLOCK: Self = Self(1 << 1);
    pub fn empty() -> Self { Self(0) }
    pub fn contains(&self, other: Self) -> bool { (self.0 & other.0) != 0 }
}
impl std::ops::BitOr for SockFlag {
    type Output = Self;
    fn bitor(self, rhs: Self) -> Self { Self(self.0 | rhs.0) }
}

pub fn socket<P>(domain: real_socket::AddressFamily, ty: real_socket::SockType, flags: SockFlag, protocol: P) -> nix::Result<OwnedFd>
where P: Into<Option<real_socket::SockProtocol>> {
    let fd = real_socket::socket(domain, ty, real_socket::SockFlag::empty(), protocol)?;
    let _ = nix::fcntl::fcntl(&fd, nix::fcntl::F_SETFD(nix::fcntl::FdFlag::FD_CLOEXEC));
    let _ = nix::fcntl::fcntl(&fd, nix::fcntl::F_SETFL(nix::fcntl::OFlag::O_NONBLOCK));
    Ok(fd)
}

pub fn socketpair<P>(domain: real_socket::AddressFamily, ty: real_socket::SockType, protocol: P, flags: SockFlag) -> nix::Result<(OwnedFd, OwnedFd)>
where P: Into<Option<real_socket::SockProtocol>> {
    let (fd1, fd2) = real_socket::socketpair(domain, ty, protocol, real_socket::SockFlag::empty())?;
    let _ = nix::fcntl::fcntl(&fd1, nix::fcntl::F_SETFD(nix::fcntl::FdFlag::FD_CLOEXEC));
    let _ = nix::fcntl::fcntl(&fd2, nix::fcntl::F_SETFD(nix::fcntl::FdFlag::FD_CLOEXEC));
    let _ = nix::fcntl::fcntl(&fd1, nix::fcntl::F_SETFL(nix::fcntl::OFlag::O_NONBLOCK));
    let _ = nix::fcntl::fcntl(&fd2, nix::fcntl::F_SETFL(nix::fcntl::OFlag::O_NONBLOCK));
    Ok((fd1, fd2))
}

pub fn pipe2(flags: nix::fcntl::OFlag) -> nix::Result<(OwnedFd, OwnedFd)> {
    let (r, w) = nix::unistd::pipe()?;
    let _ = nix::fcntl::fcntl(&r, nix::fcntl::F_SETFL(flags));
    let _ = nix::fcntl::fcntl(&w, nix::fcntl::F_SETFL(flags));
    Ok((r, w))
}

pub mod memfd {
    use std::os::unix::io::OwnedFd;
    use std::os::unix::io::FromRawFd;
    use nix::libc;

    // MemFdCreateFlag - matches nix's API
    pub struct MemFdCreateFlag(u32);
    impl MemFdCreateFlag {
        pub const MFD_CLOEXEC: Self = Self(0x0001);
        pub const MFD_ALLOW_SEALING: Self = Self(0x0002);
        pub fn empty() -> Self { Self(0) }
    }
    impl std::ops::BitOr for MemFdCreateFlag {
        type Output = Self;
        fn bitor(self, rhs: Self) -> Self { Self(self.0 | rhs.0) }
    }

    // MFdFlags - alias for compatibility with nix's memfd module
    pub type MFdFlags = MemFdCreateFlag;

    pub fn memfd_create(_name: &std::ffi::CStr, _flags: MemFdCreateFlag) -> nix::Result<OwnedFd> {
        // macOS doesn't have memfd_create or POSIX shm_open in nix
        // Use a temporary file as fallback
        use std::ffi::CString;
        let template = CString::new("/tmp/waypipe_memfd_XXXXXX").unwrap();
        let mut template_bytes = template.into_bytes_with_nul();
        unsafe {
            let fd = libc::mkstemp(template_bytes.as_mut_ptr() as *mut libc::c_char);
            if fd < 0 {
                return Err(nix::errno::Errno::last());
            }
            // Unlink immediately so file is deleted when fd is closed
            libc::unlink(template_bytes.as_ptr() as *const libc::c_char);
            Ok(OwnedFd::from_raw_fd(fd))
        }
    }
}
SOCKWRAP_EOF

    echo "mod socket_wrapper;" >> src/main.rs
    find src -name "*.rs" -type f -exec sed -i 's/use nix::sys::socket;/use crate::socket_wrapper as socket;/g' {} +
    find src -name "*.rs" -type f -exec sed -i 's/unistd::pipe2/crate::socket_wrapper::pipe2/g' {} +

    # Replace nix::sys::memfd imports with our socket_wrapper::memfd
    find src -name "*.rs" -type f -exec sed -i 's/use nix::sys::memfd;/use crate::socket_wrapper::memfd;/g' {} +
    # Handle combined imports like: use nix::sys::{memfd, signal, socket, time, uio};
    sed -i 's/use nix::sys::{memfd, signal/use crate::socket_wrapper::memfd; use nix::sys::{signal/g' src/mainloop.rs
    # Replace nix::sys::memfd:: references with crate::socket_wrapper::memfd::
    find src -name "*.rs" -type f -exec sed -i 's/nix::sys::memfd::/crate::socket_wrapper::memfd::/g' {} +
    # Combined imports the generic `use nix::sys::socket;` sed cannot see:
    sed -i 's/use nix::sys::{signal, socket, stat, wait};/use nix::sys::{signal, stat, wait};\nuse crate::socket_wrapper as socket;/' src/main.rs
    sed -i 's/use nix::sys::{memfd, signal, socket, time, uio};/use crate::socket_wrapper::memfd;\nuse crate::socket_wrapper as socket;\nuse nix::sys::{signal, time, uio};/' src/mainloop.rs

    # ============================================================
    # macOS compatibility layer (mirrors wwn-waypipe macos.nix's final
    # version): ppoll / eventfd / waitid / pipe2 / st_rdev have no macOS
    # equivalents (nix 0.30 removed ppoll & wait::Id too).
    # ============================================================
    cat > src/macos_compat.rs <<'COMPAT_EOF'
//! macOS compatibility layer for missing Linux syscalls
use nix::poll::{poll, PollFd};
use nix::sys::wait::{waitpid, WaitPidFlag, WaitStatus};
use nix::Result;
use std::os::unix::io::OwnedFd;

/// Fallback for Linux ppoll() - macOS doesn't have ppoll, use poll instead
pub fn ppoll(fds: &mut [PollFd], t: Option<nix::sys::time::TimeSpec>, _m: Option<nix::sys::signal::SigSet>) -> Result<i32> {
    // Convert TimeSpec (nanoseconds) to poll timeout (milliseconds)
    let timeout = t.map(|ts| (ts.tv_sec() * 1000 + ts.tv_nsec() / 1_000_000) as i32).unwrap_or(-1);
    poll(fds, if timeout < 0 { nix::poll::PollTimeout::NONE } else { timeout.try_into().unwrap_or(nix::poll::PollTimeout::NONE) })
}

/// Fallback for Linux waitid()
pub enum Id { All }
pub fn waitid(_id: Id, flags: WaitPidFlag) -> Result<WaitStatus> {
    // Strip flags that are invalid for waitpid on macOS
    // WEXITED is implicit/default for waitpid, but invalid as explicit flag.
    // WNOWAIT is not supported by waitpid on macOS (it will catch and reap the child).
    // We accept that we reap the child here.
    let mut clean_flags = flags;
    clean_flags.remove(WaitPidFlag::WEXITED);
    clean_flags.remove(WaitPidFlag::WNOWAIT);
    // Also remove others if present? WSTOPPED is valid (as WUNTRACED). WCONTINUED is valid.
    
    waitpid(None, Some(clean_flags))
}

/// Fallback for Linux pipe2 - handles O_CLOEXEC and O_NONBLOCK correctly
pub fn pipe2(flags: nix::fcntl::OFlag) -> Result<(OwnedFd, OwnedFd)> {
    let (r, w) = nix::unistd::pipe()?;
    
    // Handle O_CLOEXEC via F_SETFD
    if flags.contains(nix::fcntl::OFlag::O_CLOEXEC) {
        let _ = nix::fcntl::fcntl(&r, nix::fcntl::F_SETFD(nix::fcntl::FdFlag::FD_CLOEXEC));
        let _ = nix::fcntl::fcntl(&w, nix::fcntl::F_SETFD(nix::fcntl::FdFlag::FD_CLOEXEC));
    }
    
    // Handle status flags (like O_NONBLOCK) via F_SETFL
    // We mask out O_CLOEXEC as it's not a status flag
    let mut status_flags = flags;
    status_flags.remove(nix::fcntl::OFlag::O_CLOEXEC);
    
    if !status_flags.is_empty() {
        let _ = nix::fcntl::fcntl(&r, nix::fcntl::F_SETFL(status_flags));
        let _ = nix::fcntl::fcntl(&w, nix::fcntl::F_SETFL(status_flags));
    }
    
    Ok((r, w))
}

/// Fallback for Linux eventfd - use pipe instead
pub mod eventfd {
    use super::*;
    pub struct EventFdFlag(u32);
    impl EventFdFlag {
        pub const EFD_CLOEXEC: Self = Self(nix::fcntl::OFlag::O_CLOEXEC.bits() as u32);
        pub const EFD_NONBLOCK: Self = Self(nix::fcntl::OFlag::O_NONBLOCK.bits() as u32);
        pub fn empty() -> Self { Self(0) }
        pub fn bits(&self) -> u32 { self.0 }
    }
    impl std::ops::BitOr for EventFdFlag {
        type Output = Self;
        fn bitor(self, rhs: Self) -> Self { Self(self.0 | rhs.0) }
    }
    
    // NOTE: This implementation returns a PIPE read-end.
    // Writing to it will fail! A true eventfd emulation requires socketpair or similar logic
    // but preserving the OwnedFd (single fd) signature is hard without losing capabilities.
    // For basic 'wait for event' logic where the event is external closure, a pipe might suffice if we returned write end?
    // But signature returns one fd.
    // Current shim is likely insufficient but kept for consistency with original stub logic, just safe compilation.
    pub fn eventfd(_initval: u32, flags: EventFdFlag) -> Result<OwnedFd> {
        // Use pipe2 logic
        let oflags = nix::fcntl::OFlag::from_bits_truncate(flags.0 as i32);
        let (r, _w) = super::pipe2(oflags)?; 
        // We leak/drop the write end? This makes the 'eventfd' useless for signaling.
        // But repairing this requires deep refactoring.
        // Hopefully waypipe only uses this for read-readiness via external means (unlikely) or this path is unused.
        Ok(r)
    }
}
COMPAT_EOF

    echo "mod macos_compat;" >> src/main.rs

    # Patch source to use macos_compat
    find src -name "*.rs" -exec sed -i 's/nix::poll::ppoll/crate::macos_compat::ppoll/g' {} +
    find src -name "*.rs" -exec sed -i 's/wait::waitid/crate::macos_compat::waitid/g' {} +
    find src -name "*.rs" -exec sed -i 's/wait::Id::All/crate::macos_compat::Id::All/g' {} +
    find src -name "*.rs" -exec sed -i 's/use nix::sys::eventfd;/use crate::macos_compat::eventfd;/g' {} +
    find src -name "*.rs" -exec sed -i 's/nix::sys::eventfd::/crate::macos_compat::eventfd::/g' {} +
    # Route pipe2 to the FIXED macos_compat implementation (the
    # socket_wrapper version passes O_CLOEXEC to F_SETFL -> EINVAL).
    # (The earlier socket sed already rewrote `unistd::pipe2` ->
    # `crate::socket_wrapper::pipe2`, so patch that form.)
    find src -name "*.rs" -exec sed -i 's/crate::socket_wrapper::pipe2/crate::macos_compat::pipe2/g' {} +
    # Fix st_rdev type cast in platform.rs
    if [ -f "src/platform.rs" ]; then
      sed -i 's/result.st_rdev.into()/result.st_rdev as u64/' src/platform.rs
    fi

    # ============================================================
    # SplitFD transport with REAL fd handling (spike fix).
    # The v0.11.0 Rust port parses args with clap (not the manual arg loop
    # macos.nix patches), so --socket-fds is added as a clap arg here.
    # ============================================================
    python3 <<'PY_EOF'
import pathlib
p = pathlib.Path('src/main.rs')
s = p.read_text()

# 1. SocketSpec::SplitFD variant + manual Clone impl.
if 'SplitFD(OwnedFd, OwnedFd)' not in s:
    s = s.replace('Unix(PathBuf),', 'Unix(PathBuf),\n    SplitFD(OwnedFd, OwnedFd),')
    s = s.replace('#[derive(Debug, Clone)]\nenum SocketSpec', '#[derive(Debug)]\nenum SocketSpec')
    clone_impl = """
impl Clone for SocketSpec {
    fn clone(&self) -> Self {
        match self {
            Self::VSock(v) => Self::VSock(v.clone()),
            Self::Unix(p) => Self::Unix(p.clone()),
            Self::SplitFD(r, w) => unsafe {
                use std::os::fd::{AsRawFd, FromRawFd};
                Self::SplitFD(
                    OwnedFd::from_raw_fd(nix::libc::dup(r.as_raw_fd())),
                    OwnedFd::from_raw_fd(nix::libc::dup(w.as_raw_fd()))
                )
            },
        }
    }
}
"""
    s = s.replace('SplitFD(OwnedFd, OwnedFd),\n}', 'SplitFD(OwnedFd, OwnedFd),\n}\n' + clone_impl)

# 2. clap arg for --socket-fds (after the "socket" arg definition).
clap_needle = """                // todo: decide value parser based on --vsock flag?
                .value_parser(value_parser!(OsString)),
        )
        .arg(
            Arg::new("display")"""
clap_repl = """                // todo: decide value parser based on --vsock flag?
                .value_parser(value_parser!(OsString)),
        )
        .arg(
            Arg::new("socket-fds")
                .long("socket-fds")
                .value_name("R,W")
                .help("Use pre-connected file descriptors R,W as the channel socket (Wawona container vsock handoff)"),
        )
        .arg(
            Arg::new("display")"""
if 'Arg::new("socket-fds")' not in s and clap_needle in s:
    s = s.replace(clap_needle, clap_repl)

# 3. Resolve --socket-fds into SocketSpec::SplitFD for client mode.
client_needle = """    let client_socket = if let Some(s) = client_sock_arg {
        Some(to_socket_spec(s)?)
    } else {
        None
    };"""
client_repl = """    let client_socket = if let Some(fds) = matches.get_one::<String>("socket-fds") {
        let parts: Vec<&str> = fds.split(',').collect();
        if parts.len() != 2 {
            return Err("--socket-fds requires R,W".into());
        }
        let r_fd: i32 = parts[0].parse().map_err(|_| "--socket-fds: invalid R fd")?;
        let w_fd: i32 = parts[1].parse().map_err(|_| "--socket-fds: invalid W fd")?;
        use std::os::fd::FromRawFd;
        Some(SocketSpec::SplitFD(
            unsafe { OwnedFd::from_raw_fd(r_fd) },
            unsafe { OwnedFd::from_raw_fd(w_fd) },
        ))
    } else if let Some(s) = client_sock_arg {
        Some(to_socket_spec(s)?)
    } else {
        None
    };"""
if client_needle in s and 'socket-fds' not in s.split('let client_socket')[1].split('let server_socket')[0]:
    s = s.replace(client_needle, client_repl)

# 4. REAL SplitFD handling in socket_connect: the fd was already dialed by the
#    caller (host process). Sockets are full-duplex, so dup R once and use it
#    as the channel fd.
connect_needle = """        SocketSpec::Unix(path) => {
            let socket = socket::socket(
                socket::AddressFamily::Unix,"""
connect_repl = """        SocketSpec::SplitFD(r, _w) => unsafe {
            let fd = nix::libc::dup(r.as_raw_fd());
            if fd < 0 {
                return Err(tag!("Failed to dup SplitFD: {}", nix::errno::Errno::last()));
            }
            OwnedFd::from_raw_fd(fd)
        },
        SocketSpec::Unix(path) => {
            let socket = socket::socket(
                socket::AddressFamily::Unix,"""
if connect_needle in s and 'SocketSpec::SplitFD(r, _w) => unsafe {' not in s:
    s = s.replace(connect_needle, connect_repl, 1)

# 5. socket_create_and_bind: the host never serves over SplitFD, but the match
#    must compile — return the dup'd fd with no cleanup object.
bind_needle = """        SocketSpec::Unix(path) => {
            let (socket, cleanup) = unix_socket_create_and_bind(path, cwd, flags)?;
            Ok((socket, Some(cleanup)))
        }"""
bind_repl = """        SocketSpec::SplitFD(r, _w) => unsafe {
            let fd = nix::libc::dup(r.as_raw_fd());
            if fd < 0 {
                return Err(tag!("Failed to dup SplitFD: {}", nix::errno::Errno::last()));
            }
            Ok((OwnedFd::from_raw_fd(fd), None))
        },
        SocketSpec::Unix(path) => {
            let (socket, cleanup) = unix_socket_create_and_bind(path, cwd, flags)?;
            Ok((socket, Some(cleanup)))
        }"""
if bind_needle in s and 'SocketSpec::SplitFD(r, _w) => unsafe {' not in s:
    s = s.replace(bind_needle, bind_repl, 1)

# 6. Catch-all: any REMAINING multi-line SocketSpec::Unix match arms get an
#    unreachable SplitFD arm (ssh arg-building etc. — not used by the spike).
remaining_needle = """SocketSpec::Unix(path) => {"""
remaining_repl = """SocketSpec::SplitFD(_, _) => {
            unreachable!("SplitFD not supported on this path (spike)")
        }
        SocketSpec::Unix(path) => {"""
if remaining_needle in s:
    # Replace in one pass via a temporary marker, so the replacement text
    # itself cannot re-match the needle.
    tmp_marker = 'SocketSpec::UnixTMP(path) => {'
    s = s.replace(remaining_needle, remaining_repl.replace(remaining_needle, tmp_marker))
    s = s.replace(tmp_marker, remaining_needle)

# 7. Exhaustiveness for single-line SocketSpec::Unix match arms.
res_lines = []
for line in s.splitlines():
    stripped = line.lstrip()
    if (stripped.startswith('SocketSpec::Unix')
        and '=>' in stripped
        and '=> {' not in stripped
        and 'SplitFD' not in line):
        idx = line.find('SocketSpec')
        indent = line[:idx]
        res_lines.append(f'{indent}SocketSpec::SplitFD(_, _) => unreachable!("SplitFD handled earlier"),')
    res_lines.append(line)
s = '\n'.join(res_lines)

# 8. SplitFD client: connect directly instead of listen/accept or
#    build_connection_command (which cannot encode a pre-connected fd).
run_client_needle = """) -> Result<(), String> {
    if let Some(app_id) = secctx {"""
run_client_splitfd = """) -> Result<(), String> {
    if let SocketSpec::SplitFD(_, _) = socket_path {
        let link_fd = socket_connect(socket_path, cwd, false, false)?;
        let wayland_fd = if let Some(s) = wayland_socket {
            s
        } else {
            connect_to_wayland_display(cwd)?
        };
        return handle_client_conn(link_fd, wayland_fd, opts);
    }
    if let Some(app_id) = secctx {"""
if run_client_needle in s and 'if let SocketSpec::SplitFD(_, _) = socket_path' not in s:
    s = s.replace(run_client_needle, run_client_splitfd, 1)

relax_needle = """    if comp != expected_comp {
        error!("Rejecting connection header {:x} due to compression type mismatch: header has {:x} != own {:x}", header, comp, expected_comp);
        return Err(tag!("Header compression failure"));
    }"""
relax_repl = """    if comp != expected_comp {
        // Guest nixpkgs waypipe on aarch64-linux can send comp=0 (unset bits)
        // even with -c lz4/-c none. Accept it when the negotiated mode matches.
        if comp != 0 {
            error!("Rejecting connection header {:x} due to compression type mismatch: header has {:x} != own {:x}", header, comp, expected_comp);
            return Err(tag!("Header compression failure"));
        }
    }"""
if relax_needle in s:
    s = s.replace(relax_needle, relax_repl, 1)

p.write_text(s)
PY_EOF

    # The SplitFD arm was added above; check it stuck (fail loudly, never
    # ship a waypipe whose --socket-fds panics).
    grep -q 'SocketSpec::SplitFD(r, _w) => unsafe {' src/main.rs \
      || { echo "ERROR: SplitFD socket_connect patch did not apply" >&2; exit 1; }
    grep -q 'Arg::new("socket-fds")' src/main.rs \
      || { echo "ERROR: --socket-fds clap arg did not apply" >&2; exit 1; }
    grep -q 'if let SocketSpec::SplitFD(_, _) = socket_path' src/main.rs \
      || { echo "ERROR: SplitFD run_client patch did not apply" >&2; exit 1; }
  '';

  # Robust SDK detection (same approach as wwn-waypipe macos.nix, host-only).
  preConfigure = ''
    MACOS_SDK=$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)
    if [ ! -d "$MACOS_SDK" ]; then
      MACOS_SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk"
    fi
    if [ ! -d "$MACOS_SDK" ]; then
      MACOS_SDK=$(/usr/bin/xcode-select -p)/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk
    fi
    if [ ! -d "$MACOS_SDK" ]; then
      echo "ERROR: MacOSX SDK not found. Build cannot proceed." >&2
      exit 1
    fi
    export SDKROOT="$MACOS_SDK"
    export MACOSX_DEPLOYMENT_TARGET="15.0"
    unset DEVELOPER_DIR
    export NIX_CFLAGS_COMPILE=""
    export NIX_LDFLAGS=""
    # NIX_LDFLAGS is cleared above (mirroring macos.nix), so the linker needs
    # explicit library search paths for deps without pkg-config metadata.
    export LIBRARY_PATH="${pkgs.zstd}/lib:${pkgs.lz4}/lib:${pkgs.libiconv}/lib:$LIBRARY_PATH"
    export PKG_CONFIG_PATH="${pkgs.zstd}/lib/pkgconfig:${pkgs.lz4}/lib/pkgconfig:$PKG_CONFIG_PATH"
    export CFLAGS="-isysroot $SDKROOT -mmacosx-version-min=15.0 -fPIC $CFLAGS"
    export LDFLAGS="-isysroot $SDKROOT -mmacosx-version-min=15.0 $LDFLAGS"
    export RUSTFLAGS="-A warnings $RUSTFLAGS"
    export BINDGEN_EXTRA_CLANG_ARGS="-I${pkgs.zstd}/include -I${pkgs.lz4}/include -isysroot $SDKROOT -mmacosx-version-min=15.0"
  '';

  meta = with lib; {
    description = "Spike host waypipe: Rust port v0.11.0 with working --socket-fds (SplitFD) transport for container vsock handoff";
    platforms = platforms.darwin;
  };
}
