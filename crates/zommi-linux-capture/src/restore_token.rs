//! Portal grants are opaque, single-use tokens. Rotate them after each Start
//! and keep them private; no stream stays open between user captures.
use std::{
    env, fs,
    io::{self, Read, Write},
    os::unix::fs::{DirBuilderExt, OpenOptionsExt},
    path::PathBuf,
};

pub struct RestoreToken(Option<PathBuf>);

impl RestoreToken {
    pub fn for_user() -> Self {
        let root = env::var_os("XDG_STATE_HOME")
            .map(PathBuf::from)
            .filter(|path| path.is_absolute())
            .or_else(|| env::var_os("HOME").map(|home| PathBuf::from(home).join(".local/state")));
        Self(root.map(|root| root.join("zommi/screencast-restore-token")))
    }

    pub fn take(&self) -> Option<String> {
        let path = self.0.as_ref()?;
        let mut token = String::new();
        let result =
            fs::File::open(path).and_then(|file| file.take(4097).read_to_string(&mut token));
        // A token can only be used once. A rejected or interrupted restore must
        // lead to a fresh permission request on the next attempt.
        let _ = fs::remove_file(path);
        (result.is_ok() && !token.is_empty() && token.len() <= 4096 && !token.contains('\0'))
            .then_some(token)
    }

    pub fn save(&self, token: Option<&str>) -> io::Result<()> {
        let Some(path) = &self.0 else { return Ok(()) };
        let Some(token) = token.filter(|token| !token.is_empty() && token.len() <= 4096) else {
            return Ok(());
        };
        fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(path.parent().unwrap())?;
        let temporary = path.with_extension(format!("{}.tmp", std::process::id()));
        let result = (|| {
            let mut file = fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .mode(0o600)
                .open(&temporary)?;
            file.write_all(token.as_bytes())?;
            file.sync_all()?;
            fs::rename(&temporary, path)
        })();
        let _ = fs::remove_file(temporary);
        result
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        os::unix::fs::PermissionsExt,
        time::{SystemTime, UNIX_EPOCH},
    };

    #[test]
    fn grants_are_private_consumed_and_rotated_across_helpers() {
        let root = env::temp_dir().join(format!(
            "zommi-portal-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let path = root.join("grant");
        let first = RestoreToken(Some(path.clone()));
        assert_eq!(first.take(), None);
        first.save(Some("first-grant")).unwrap();
        assert_eq!(
            fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o600
        );
        let next = RestoreToken(Some(path.clone()));
        assert_eq!(next.take().as_deref(), Some("first-grant"));
        assert_eq!(next.take(), None);
        next.save(Some("rotated-grant")).unwrap();
        assert_eq!(first.take().as_deref(), Some("rotated-grant"));
        next.save(None).unwrap();
        assert!(!path.exists());
        fs::write(&path, "x".repeat(5000)).unwrap();
        assert_eq!(first.take(), None);
        assert!(!path.exists());
        fs::remove_dir_all(root).unwrap();
    }
}
