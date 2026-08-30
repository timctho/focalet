use std::{
    env, fs, io,
    path::{Path, PathBuf},
};

use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use ed25519_dalek::{Signer, SigningKey};
use rand_core::OsRng;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use uuid::Uuid;

const IDENTITY_VERSION: u64 = 1;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct StoredIdentity {
    version: u64,
    private_key: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    device_token: Option<String>,
    #[serde(default)]
    scopes: Vec<String>,
}

pub struct DeviceIdentity {
    path: PathBuf,
    stored: StoredIdentity,
    signing_key: SigningKey,
}

impl DeviceIdentity {
    pub fn load_or_create() -> io::Result<Self> {
        Self::load_or_create_at(identity_path())
    }

    fn load_or_create_at(path: PathBuf) -> io::Result<Self> {
        match load(&path) {
            Ok(identity) => return Ok(identity),
            Err(error) if error.kind() != io::ErrorKind::NotFound => return Err(error),
            Err(_) => {}
        }
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)?;
        }
        let signing_key = SigningKey::generate(&mut OsRng);
        let stored = StoredIdentity {
            version: IDENTITY_VERSION,
            private_key: URL_SAFE_NO_PAD.encode(signing_key.to_bytes()),
            device_token: None,
            scopes: Vec::new(),
        };
        match create_private_file(&path, &serde_json::to_vec_pretty(&stored)?) {
            Ok(()) => Ok(Self {
                path,
                stored,
                signing_key,
            }),
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => load(&path),
            Err(error) => Err(error),
        }
    }

    pub fn connect_device(
        &self,
        nonce: &str,
        signed_at: u64,
        scopes: &[String],
        signature_token: Option<&str>,
        platform: &str,
    ) -> Value {
        let public_key = self.signing_key.verifying_key().to_bytes();
        let device_id = hex_sha256(&public_key);
        let wire_platform = match platform {
            "windows" => "win32",
            "macos" => "darwin",
            value => value,
        };
        let payload = [
            "v3",
            &device_id,
            "cli",
            "cli",
            "operator",
            &scopes.join(","),
            &signed_at.to_string(),
            signature_token.unwrap_or_default(),
            nonce,
            wire_platform,
            "",
        ]
        .join("|");
        let signature = self.signing_key.sign(payload.as_bytes());
        json!({
            "id": device_id,
            "publicKey": URL_SAFE_NO_PAD.encode(public_key),
            "signature": URL_SAFE_NO_PAD.encode(signature.to_bytes()),
            "signedAt": signed_at,
            "nonce": nonce
        })
    }

    pub fn stored_device_token(&self) -> Option<&str> {
        self.stored.device_token.as_deref()
    }

    pub fn stored_scopes(&self) -> &[String] {
        &self.stored.scopes
    }

    pub fn store_device_token(&mut self, token: &str, scopes: &[String]) -> io::Result<()> {
        if token.is_empty() {
            return Ok(());
        }
        self.stored.device_token = Some(token.into());
        self.stored.scopes = scopes.to_vec();
        replace_private_file(&self.path, &serde_json::to_vec_pretty(&self.stored)?)
    }
}

fn identity_path() -> PathBuf {
    if let Some(path) = env::var_os("ZOMMI_OPENCLAW_DEVICE_IDENTITY_PATH") {
        return path.into();
    }
    let home = env::var_os("HOME")
        .or_else(|| env::var_os("USERPROFILE"))
        .map(PathBuf::from)
        .unwrap_or_else(env::temp_dir);
    if cfg!(target_os = "windows") {
        env::var_os("APPDATA")
            .map(PathBuf::from)
            .unwrap_or(home)
            .join("Zommi")
            .join("openclaw-device.json")
    } else if cfg!(target_os = "macos") {
        home.join("Library")
            .join("Application Support")
            .join("Zommi")
            .join("openclaw-device.json")
    } else {
        env::var_os("XDG_STATE_HOME")
            .map(PathBuf::from)
            .unwrap_or_else(|| home.join(".local").join("state"))
            .join("zommi")
            .join("openclaw-device.json")
    }
}

fn load(path: &Path) -> io::Result<DeviceIdentity> {
    let bytes = fs::read(path)?;
    let stored: StoredIdentity = serde_json::from_slice(&bytes).map_err(io::Error::other)?;
    if stored.version != IDENTITY_VERSION {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "unsupported OpenClaw device identity version",
        ));
    }
    let private = URL_SAFE_NO_PAD
        .decode(&stored.private_key)
        .map_err(io::Error::other)?;
    let private: [u8; 32] = private.try_into().map_err(|_| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            "OpenClaw device private key is not 32 bytes",
        )
    })?;
    Ok(DeviceIdentity {
        path: path.into(),
        stored,
        signing_key: SigningKey::from_bytes(&private),
    })
}

#[cfg(unix)]
fn create_private_file(path: &Path, bytes: &[u8]) -> io::Result<()> {
    use std::io::Write as _;
    use std::os::unix::fs::OpenOptionsExt as _;

    let mut file = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(path)?;
    file.write_all(bytes)?;
    file.sync_all()
}

#[cfg(not(unix))]
fn create_private_file(path: &Path, bytes: &[u8]) -> io::Result<()> {
    use std::io::Write as _;

    let mut file = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(path)?;
    file.write_all(bytes)?;
    file.sync_all()
}

fn replace_private_file(path: &Path, bytes: &[u8]) -> io::Result<()> {
    let temporary =
        path.with_extension(format!("pending-{}-{}", std::process::id(), Uuid::new_v4()));
    create_private_file(&temporary, bytes)?;
    #[cfg(target_os = "windows")]
    if path.exists() {
        fs::remove_file(path)?;
    }
    fs::rename(temporary, path)
}

fn hex_sha256(value: &[u8]) -> String {
    Sha256::digest(value)
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

#[cfg(test)]
mod tests {
    use base64::Engine as _;
    use ed25519_dalek::{Signature, Verifier as _, VerifyingKey};

    use super::{DeviceIdentity, URL_SAFE_NO_PAD, Uuid};

    #[test]
    fn connect_signature_uses_v4_challenge_identity_shape() {
        let root = std::env::temp_dir().join(format!(
            "zommi-device-test-{}-{}",
            std::process::id(),
            Uuid::new_v4()
        ));
        let path = root.join("device.json");
        std::fs::create_dir_all(&root).expect("create test directory");
        let identity = DeviceIdentity::load_or_create_at(path.clone()).expect("create identity");
        let scopes = ["operator.read".into(), "operator.write".into()];
        let signed_at = 1_800_000_000_000;
        let device = identity.connect_device("nonce", signed_at, &scopes, Some("token"), "linux");
        assert_eq!(device["id"].as_str().map(str::len), Some(64));
        assert_eq!(device["publicKey"].as_str().map(str::len), Some(43));
        assert_eq!(device["signature"].as_str().map(str::len), Some(86));
        assert_eq!(device["nonce"], "nonce");

        let public_key: [u8; 32] = URL_SAFE_NO_PAD
            .decode(device["publicKey"].as_str().expect("public key"))
            .expect("decode public key")
            .try_into()
            .expect("32-byte public key");
        let signature: [u8; 64] = URL_SAFE_NO_PAD
            .decode(device["signature"].as_str().expect("signature"))
            .expect("decode signature")
            .try_into()
            .expect("64-byte signature");
        let payload = format!(
            "v3|{}|cli|cli|operator|{}|{signed_at}|token|nonce|linux|",
            device["id"].as_str().expect("device id"),
            scopes.join(",")
        );
        VerifyingKey::from_bytes(&public_key)
            .expect("valid public key")
            .verify(payload.as_bytes(), &Signature::from_bytes(&signature))
            .expect("valid challenge signature");

        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt as _;
            assert_eq!(
                std::fs::metadata(&path)
                    .expect("identity metadata")
                    .permissions()
                    .mode()
                    & 0o777,
                0o600
            );
        }
        let _ = std::fs::remove_dir_all(root);
    }
}
