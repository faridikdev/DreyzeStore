use crate::{
    error::{CompanionError, Result},
    models::{PackageExpectation, PackageMetadata, ValidatedPackage},
};
use sha2::{Digest, Sha256};
use std::{
    fs::{self, File, OpenOptions},
    io::{Read, Seek, SeekFrom, Write},
    path::{Component, Path, PathBuf},
};
use zip::ZipArchive;

pub const MAX_PACKAGE_BYTES: u64 = 1_073_741_824;
pub const MAX_ENTRIES: usize = 100_000;
pub const MAX_ENTRY_BYTES: u64 = 2_147_483_648;
pub const MAX_TOTAL_UNCOMPRESSED_BYTES: u64 = 8_589_934_592;
pub const MAX_COMPRESSION_RATIO: u64 = 1_000;
pub const MAX_INFO_PLIST_BYTES: u64 = 8 * 1024 * 1024;

#[derive(Clone, Copy, Debug)]
pub struct PackageValidator;

impl PackageValidator {
    pub fn validate(&self, path: &Path, expected: &PackageExpectation) -> Result<ValidatedPackage> {
        validate_expectation(expected)?;
        let metadata = inspect_package(path)?;
        if !digest_matches(&metadata.sha256, &expected.sha256) {
            return Err(CompanionError::ChecksumMismatch);
        }
        if metadata.bundle_identifier != expected.bundle_identifier
            || metadata.version != expected.version
            || metadata.build != expected.build
            || metadata.size != expected.size
            || (expected.minimum_os_version.is_some()
                && metadata.minimum_os_version != expected.minimum_os_version)
        {
            return Err(CompanionError::MetadataMismatch);
        }
        Ok(ValidatedPackage {
            path: path.to_owned(),
            metadata,
        })
    }

    pub fn inspect(&self, path: &Path) -> Result<PackageMetadata> {
        inspect_package(path)
    }

    /// Extracts only after full preflight validation; paths and file types are
    /// checked again while writing so no archive entry can escape `target`.
    pub fn extract_for_signing(
        &self,
        package: &ValidatedPackage,
        target: &Path,
    ) -> Result<PathBuf> {
        if target.exists() {
            return Err(CompanionError::InvalidRequest(
                "signing workspace already exists".into(),
            ));
        }
        let parent = target.parent().ok_or_else(|| {
            CompanionError::InvalidRequest("signing workspace has no parent".into())
        })?;
        fs::create_dir_all(parent)?;
        let snapshot_path = parent.join(format!("{}.verified-ipa", uuid::Uuid::new_v4()));
        let snapshot_cleanup = RemoveFileOnDrop(snapshot_path.clone());
        let mut source = File::open(&package.path)?;
        let source_size = source.metadata()?.len();
        if source_size != package.metadata.size || source_size > MAX_PACKAGE_BYTES {
            return Err(CompanionError::ChecksumMismatch);
        }
        let mut snapshot = OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&snapshot_path)?;
        let mut hash = Sha256::new();
        let mut copied = 0u64;
        let mut buffer = [0u8; 64 * 1024];
        loop {
            let count = source.read(&mut buffer)?;
            if count == 0 {
                break;
            }
            copied = copied
                .checked_add(count as u64)
                .ok_or(CompanionError::ChecksumMismatch)?;
            if copied > package.metadata.size || copied > MAX_PACKAGE_BYTES {
                return Err(CompanionError::ChecksumMismatch);
            }
            hash.update(&buffer[..count]);
            snapshot.write_all(&buffer[..count])?;
        }
        snapshot.flush()?;
        snapshot.sync_all()?;
        drop(snapshot);
        source.seek(SeekFrom::Start(0))?;
        let snapshot_digest = hex::encode(hash.finalize());
        if copied != package.metadata.size
            || !digest_matches(&snapshot_digest, &package.metadata.sha256)
        {
            return Err(CompanionError::ChecksumMismatch);
        }
        fs::create_dir_all(target)?;
        let target_canonical = fs::canonicalize(target)?;
        let file = File::open(&snapshot_path)?;
        let mut archive = ZipArchive::new(file)
            .map_err(|_| CompanionError::InvalidPackage("malformed ZIP archive".into()))?;
        for index in 0..archive.len() {
            let mut entry = archive
                .by_index(index)
                .map_err(|_| CompanionError::InvalidPackage("malformed ZIP entry".into()))?;
            let relative = entry
                .enclosed_name()
                .ok_or_else(|| CompanionError::InvalidPackage("unsafe archive path".into()))?
                .to_owned();
            if relative
                .components()
                .any(|part| !matches!(part, Component::Normal(_)))
            {
                return Err(CompanionError::InvalidPackage("unsafe archive path".into()));
            }
            if entry
                .unix_mode()
                .is_some_and(|mode| mode & 0o170000 == 0o120000)
            {
                return Err(CompanionError::InvalidPackage(
                    "symbolic links are not accepted".into(),
                ));
            }
            let destination = target.join(&relative);
            if !destination.starts_with(&target_canonical) {
                return Err(CompanionError::InvalidPackage(
                    "archive path escaped the signing directory".into(),
                ));
            }
            if entry.is_dir() {
                fs::create_dir_all(&destination)?;
                continue;
            }
            if let Some(parent) = destination.parent() {
                fs::create_dir_all(parent)?;
            }
            let mut output = OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(&destination)?;
            let copied = std::io::copy(&mut entry, &mut output)?;
            if copied != entry.size() {
                return Err(CompanionError::InvalidPackage("truncated ZIP entry".into()));
            }
            output.flush()?;
        }
        // Recheck the immutable signing snapshot after extraction. This closes
        // the source-path TOCTOU gap before a signer consumes extracted bytes.
        let after = hash_file(&snapshot_path)?;
        if !digest_matches(&after, &package.metadata.sha256) {
            return Err(CompanionError::ChecksumMismatch);
        }
        drop(snapshot_cleanup);
        Ok(target.to_owned())
    }
}

fn validate_expectation(value: &PackageExpectation) -> Result<()> {
    if value.request_id.len() > 80
        || value.app_name.trim().is_empty()
        || value.app_name.len() > 180
        || value.bundle_identifier.len() > 255
        || !valid_bundle_id(&value.bundle_identifier)
        || value.version.len() > 64
        || value.build.len() > 64
        || value.version.trim().is_empty()
        || value.build.trim().is_empty()
        || value.size == 0
        || value.size > MAX_PACKAGE_BYTES
        || value.sha256.len() != 64
        || !value.sha256.bytes().all(|c| c.is_ascii_hexdigit())
    {
        return Err(CompanionError::InvalidRequest(
            "invalid or oversized release metadata".into(),
        ));
    }
    Ok(())
}

fn inspect_package(path: &Path) -> Result<PackageMetadata> {
    let file = File::open(path)?;
    let actual_size = file.metadata()?.len();
    if actual_size == 0 || actual_size > MAX_PACKAGE_BYTES {
        return Err(CompanionError::InvalidPackage(
            "package size is outside the supported limit".into(),
        ));
    }
    let sha256 = hash_file(path)?;
    let mut archive = ZipArchive::new(file).map_err(|_| {
        CompanionError::InvalidPackage("file is not a valid IPA/ZIP archive".into())
    })?;
    if archive.len() == 0 || archive.len() > MAX_ENTRIES {
        return Err(CompanionError::InvalidPackage(
            "archive entry count exceeds limits".into(),
        ));
    }
    let mut total_uncompressed = 0u64;
    let mut entries = Vec::with_capacity(archive.len());
    let mut app_roots = Vec::new();
    for index in 0..archive.len() {
        let entry = archive
            .by_index(index)
            .map_err(|_| CompanionError::InvalidPackage("malformed ZIP directory".into()))?;
        let name = entry.name().replace('\\', "/");
        let relative = entry.enclosed_name().ok_or_else(|| {
            CompanionError::InvalidPackage("absolute or traversing ZIP path".into())
        })?;
        if relative
            .components()
            .any(|part| !matches!(part, Component::Normal(_)))
        {
            return Err(CompanionError::InvalidPackage(
                "absolute or traversing ZIP path".into(),
            ));
        }
        if entry
            .unix_mode()
            .is_some_and(|mode| mode & 0o170000 == 0o120000)
        {
            return Err(CompanionError::InvalidPackage(
                "archive contains a symbolic link".into(),
            ));
        }
        let expanded = entry.size();
        if expanded > MAX_ENTRY_BYTES {
            return Err(CompanionError::InvalidPackage(
                "an archive entry exceeds the expanded-size limit".into(),
            ));
        }
        total_uncompressed = total_uncompressed.checked_add(expanded).ok_or_else(|| {
            CompanionError::InvalidPackage("archive expanded-size overflow".into())
        })?;
        if total_uncompressed > MAX_TOTAL_UNCOMPRESSED_BYTES {
            return Err(CompanionError::InvalidPackage(
                "archive expanded-size limit exceeded".into(),
            ));
        }
        if expanded > 0
            && (entry.compressed_size() == 0
                || expanded / entry.compressed_size().max(1) > MAX_COMPRESSION_RATIO)
        {
            return Err(CompanionError::InvalidPackage(
                "archive compression ratio exceeds the limit".into(),
            ));
        }
        if name.starts_with("Payload/") && name.ends_with(".app/Info.plist") {
            let root = name
                .strip_suffix("Info.plist")
                .unwrap_or_default()
                .trim_end_matches('/')
                .to_owned();
            if !root["Payload/".len()..].contains('/') {
                app_roots.push((root, index, expanded));
            }
        }
        entries.push(name);
    }
    if app_roots.len() != 1 {
        return Err(CompanionError::InvalidPackage(
            "IPA must contain exactly one top-level Payload/*.app".into(),
        ));
    }
    let (app_root, plist_index, plist_size) = app_roots.remove(0);
    if plist_size == 0 || plist_size > MAX_INFO_PLIST_BYTES {
        return Err(CompanionError::InvalidPackage(
            "Info.plist size exceeds limits".into(),
        ));
    }
    let info: plist::Value = {
        let mut entry = archive
            .by_index(plist_index)
            .map_err(|_| CompanionError::InvalidPackage("Info.plist is missing".into()))?;
        let mut bytes = Vec::with_capacity(plist_size as usize);
        entry.read_to_end(&mut bytes)?;
        if bytes.len() as u64 != plist_size {
            return Err(CompanionError::InvalidPackage(
                "Info.plist is truncated".into(),
            ));
        }
        plist::from_bytes(&bytes)
            .map_err(|_| CompanionError::InvalidPackage("Info.plist cannot be decoded".into()))?
    };
    let dictionary = info
        .as_dictionary()
        .ok_or_else(|| CompanionError::InvalidPackage("Info.plist is not a dictionary".into()))?;
    let string = |key: &str| -> Result<String> {
        dictionary
            .get(key)
            .and_then(plist::Value::as_string)
            .map(ToOwned::to_owned)
            .filter(|value| !value.trim().is_empty())
            .ok_or_else(|| CompanionError::InvalidPackage(format!("Info.plist is missing {key}")))
    };
    let bundle_identifier = string("CFBundleIdentifier")?;
    let version = string("CFBundleShortVersionString")?;
    let build = string("CFBundleVersion")?;
    let executable = string("CFBundleExecutable")?;
    if !valid_bundle_id(&bundle_identifier)
        || !valid_version(&version)
        || !valid_version(&build)
        || executable.contains(['/', '\\'])
    {
        return Err(CompanionError::InvalidPackage(
            "Info.plist contains malformed app identifiers or versions".into(),
        ));
    }
    let executable_path = format!("{app_root}/{executable}");
    if !entries.iter().any(|entry| entry == &executable_path) {
        return Err(CompanionError::InvalidPackage(
            "CFBundleExecutable does not exist in the app bundle".into(),
        ));
    }
    let minimum_os_version = dictionary
        .get("MinimumOSVersion")
        .and_then(plist::Value::as_string)
        .map(ToOwned::to_owned);
    if minimum_os_version
        .as_ref()
        .is_some_and(|value| !valid_version(value))
    {
        return Err(CompanionError::InvalidPackage(
            "MinimumOSVersion is malformed".into(),
        ));
    }
    let app_name = dictionary
        .get("CFBundleDisplayName")
        .or_else(|| dictionary.get("CFBundleName"))
        .and_then(plist::Value::as_string)
        .map(ToOwned::to_owned);
    Ok(PackageMetadata {
        bundle_identifier,
        version,
        build,
        minimum_os_version,
        app_name,
        size: actual_size,
        sha256,
    })
}

fn hash_file(path: &Path) -> Result<String> {
    let mut hash = Sha256::new();
    let mut file = File::open(path)?;
    let mut buffer = [0u8; 64 * 1024];
    loop {
        let read = file.read(&mut buffer)?;
        if read == 0 {
            break;
        }
        hash.update(&buffer[..read]);
    }
    Ok(hex::encode(hash.finalize()))
}

struct RemoveFileOnDrop(PathBuf);
impl Drop for RemoveFileOnDrop {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.0);
    }
}

fn valid_bundle_id(value: &str) -> bool {
    let parts: Vec<_> = value.split('.').collect();
    parts.len() >= 2
        && parts.iter().all(|part| {
            !part.is_empty() && part.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')
        })
}

fn valid_version(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 64
        && value
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'-' | b'+' | b'_'))
}

fn digest_matches(actual: &str, expected: &str) -> bool {
    actual.len() == expected.len() && actual.eq_ignore_ascii_case(expected)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use zip::{ZipWriter, write::SimpleFileOptions};

    fn fixture(path: &Path, with_payload: bool) -> PackageExpectation {
        let file = File::create(path).unwrap();
        let mut zip = ZipWriter::new(file);
        if with_payload {
            zip.start_file(
                "Payload/Sample.app/Info.plist",
                SimpleFileOptions::default(),
            )
            .unwrap();
            let mut dict = plist::Dictionary::new();
            dict.insert(
                "CFBundleIdentifier".into(),
                plist::Value::String("org.dreyze.sample".into()),
            );
            dict.insert(
                "CFBundleExecutable".into(),
                plist::Value::String("Sample".into()),
            );
            dict.insert(
                "CFBundleShortVersionString".into(),
                plist::Value::String("1.2.0".into()),
            );
            dict.insert("CFBundleVersion".into(), plist::Value::String("14".into()));
            dict.insert(
                "MinimumOSVersion".into(),
                plist::Value::String("16.0".into()),
            );
            dict.insert("CFBundleName".into(), plist::Value::String("Sample".into()));
            plist::Value::Dictionary(dict)
                .to_writer_xml(&mut zip)
                .unwrap();
            zip.start_file("Payload/Sample.app/Sample", SimpleFileOptions::default())
                .unwrap();
            zip.write_all(b"Mach-O test fixture").unwrap();
        }
        zip.finish().unwrap();
        let bytes = fs::read(path).unwrap();
        PackageExpectation {
            request_id: "test-request".into(),
            bundle_identifier: "org.dreyze.sample".into(),
            version: "1.2.0".into(),
            build: "14".into(),
            minimum_os_version: Some("16.0".into()),
            sha256: hex::encode(Sha256::digest(&bytes)),
            size: bytes.len() as u64,
            app_name: "Sample".into(),
        }
    }

    #[test]
    fn validates_authorized_sample_ipa_metadata_and_checksum() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("fixture.ipa");
        let expected = fixture(&path, true);
        let validated = PackageValidator.validate(&path, &expected).unwrap();
        assert_eq!(
            validated.metadata.bundle_identifier,
            expected.bundle_identifier
        );
        assert_eq!(validated.metadata.version, "1.2.0");
    }

    #[test]
    fn rejects_checksum_metadata_mismatch_and_non_zip_files() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("fixture.ipa");
        let mut expected = fixture(&path, true);
        let valid_sha256 = expected.sha256.clone();
        expected.sha256 = "0".repeat(64);
        assert_eq!(
            PackageValidator
                .validate(&path, &expected)
                .unwrap_err()
                .to_string(),
            "package checksum mismatch"
        );
        expected.sha256 = valid_sha256;
        expected.bundle_identifier = "org.other.app".into();
        assert!(matches!(
            PackageValidator.validate(&path, &expected),
            Err(CompanionError::MetadataMismatch)
        ));
        fs::write(&path, b"not a zip").unwrap();
        assert!(matches!(
            PackageValidator.inspect(&path),
            Err(CompanionError::InvalidPackage(_))
        ));
    }

    #[test]
    fn rejects_missing_payload_and_parent_paths() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("missing.ipa");
        let expected = fixture(&path, false);
        assert!(matches!(
            PackageValidator.validate(&path, &expected),
            Err(CompanionError::InvalidPackage(_))
        ));
        let mut writer = ZipWriter::new(File::create(&path).unwrap());
        writer
            .start_file("../escaped", SimpleFileOptions::default())
            .unwrap();
        writer.write_all(b"x").unwrap();
        writer.finish().unwrap();
        assert!(matches!(
            PackageValidator.inspect(&path),
            Err(CompanionError::InvalidPackage(_))
        ));
    }
}
