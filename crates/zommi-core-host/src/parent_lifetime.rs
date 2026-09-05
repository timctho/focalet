use std::{io, thread, time::Duration};

pub(crate) fn bind_to_parent() -> io::Result<()> {
    let parent = unsafe { libc::getppid() };
    thread::Builder::new()
        .name("zommi-parent".into())
        .spawn(move || {
            loop {
                if unsafe { libc::getppid() } != parent {
                    std::process::exit(0);
                }
                thread::sleep(Duration::from_millis(100));
            }
        })
        .map(|_| ())
}
