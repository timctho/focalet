//! Keep CLI launcher descendants inside the broker's lifetime.
use std::{io, mem, ptr};
use windows_sys::Win32::{
    Foundation::CloseHandle,
    System::{
        JobObjects::{
            AssignProcessToJobObject, CreateJobObjectW, JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
            JOBOBJECT_EXTENDED_LIMIT_INFORMATION, JobObjectExtendedLimitInformation,
            SetInformationJobObject,
        },
        Threading::GetCurrentProcess,
    },
};

pub fn contain_children() -> io::Result<()> {
    // The handle intentionally lives until process exit. Windows closes it even
    // after a crash/TerminateProcess, including npm/cmd launcher descendants.
    unsafe {
        let job = CreateJobObjectW(ptr::null(), ptr::null());
        if job.is_null() {
            return Err(io::Error::last_os_error());
        }
        let mut limits: JOBOBJECT_EXTENDED_LIMIT_INFORMATION = mem::zeroed();
        limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        if SetInformationJobObject(
            job,
            JobObjectExtendedLimitInformation,
            &limits as *const _ as *const _,
            mem::size_of_val(&limits) as u32,
        ) == 0
            || AssignProcessToJobObject(job, GetCurrentProcess()) == 0
        {
            let error = io::Error::last_os_error();
            CloseHandle(job);
            return Err(error);
        }
    }
    Ok(())
}
