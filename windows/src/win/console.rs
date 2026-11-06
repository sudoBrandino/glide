//! Console helpers: hide password echo; detach from a console we own (GUI launch).

use windows::Win32::System::Console::*;

pub struct EchoOff {
    handle: windows::Win32::Foundation::HANDLE,
    old: CONSOLE_MODE,
}

impl EchoOff {
    pub fn new() -> Option<EchoOff> {
        unsafe {
            let handle = GetStdHandle(STD_INPUT_HANDLE).ok()?;
            let mut old = CONSOLE_MODE::default();
            GetConsoleMode(handle, &mut old).ok()?;
            SetConsoleMode(handle, old & !ENABLE_ECHO_INPUT).ok()?;
            Some(EchoOff { handle, old })
        }
    }
}

impl Drop for EchoOff {
    fn drop(&mut self) {
        unsafe {
            let _ = SetConsoleMode(self.handle, self.old);
        }
    }
}

/// If the console window exists only for this process (double-clicked exe), hide it.
pub fn detach_if_own_console() {
    unsafe {
        let mut pids = [0u32; 4];
        if GetConsoleProcessList(&mut pids) == 1 {
            let _ = FreeConsole();
        }
    }
}
