"""Bounded, non-executing IPA archive inspection for the isolated validator job."""

from __future__ import annotations

import hashlib
import json
import os
import plistlib
import re
import stat
import struct
import zipfile
import argparse
from pathlib import PurePosixPath
from typing import Any

MAX_PACKAGE_BYTES = 1_073_741_824
MAX_ENTRIES = 20_000
MAX_CENTRAL_DIRECTORY_BYTES = 32 * 1024 * 1024
MAX_TOTAL_UNCOMPRESSED = 4_294_967_296
MAX_ENTRY_BYTES = 1_073_741_824
MAX_COMPRESSION_RATIO = 200
MAX_PLIST_BYTES = 1_048_576
BUNDLE_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9-]*(?:\.[A-Za-z0-9][A-Za-z0-9-]*)+$")
BUILD_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+-]{0,63}$")
VERSION_PATTERN = re.compile(
    r"^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)"
    r"(?:-([0-9A-Za-z.-]+))?(?:\+([0-9A-Za-z.-]+))?$"
)
OS_PATTERN = re.compile(r"^\d{1,3}(?:\.\d{1,3}){1,2}$")


class PackageValidationError(ValueError):
    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code


def inspect_ipa(path: str, expected_size: int | None = None) -> dict[str, Any]:
    if not os.path.isfile(path):
        raise PackageValidationError("invalid_archive", "Package file does not exist.")
    actual_size = os.path.getsize(path)
    if actual_size < 22 or actual_size > MAX_PACKAGE_BYTES:
        raise PackageValidationError("package_size_invalid", "Package size is outside the permitted range.")
    if expected_size is not None and expected_size != actual_size:
        raise PackageValidationError("package_size_mismatch", "Downloaded byte count did not match the upload session.")

    preflight_zip_directory(path, actual_size)

    digest = hashlib.sha256()
    with open(path, "rb") as package:
        for block in iter(lambda: package.read(1024 * 1024), b""):
            digest.update(block)

    try:
        with zipfile.ZipFile(path, "r") as archive:
            infos = archive.infolist()
            if not infos:
                raise PackageValidationError("invalid_payload", "The archive does not contain a Payload directory.")
            if len(infos) > MAX_ENTRIES:
                raise PackageValidationError("entry_count_limit", "The archive contains an unsupported number of entries.")
            normalized: set[str] = set()
            total_size = 0
            for info in infos:
                name = normalize_zip_path(info.filename)
                if name in normalized:
                    raise PackageValidationError("duplicate_archive_path", "The archive contains duplicate paths.")
                normalized.add(name)
                mode = (info.external_attr >> 16) & 0xFFFF
                if stat.S_ISLNK(mode):
                    raise PackageValidationError("unsafe_archive", "Symbolic links are not permitted in the package.")
                if info.flag_bits & 0x1:
                    raise PackageValidationError("unsafe_archive", "Encrypted archive entries are not supported.")
                if info.file_size < 0 or info.file_size > MAX_ENTRY_BYTES:
                    raise PackageValidationError("uncompressed_size_limit", "An archive entry is too large.")
                total_size += info.file_size
                if total_size > MAX_TOTAL_UNCOMPRESSED:
                    raise PackageValidationError("uncompressed_size_limit", "The archive expands beyond the allowed limit.")
                if info.file_size and (info.compress_size == 0 or info.file_size / info.compress_size > MAX_COMPRESSION_RATIO):
                    raise PackageValidationError("compression_ratio_limit", "An archive entry exceeds the allowed compression ratio.")
                if info.compress_type not in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED, zipfile.ZIP_BZIP2, zipfile.ZIP_LZMA):
                    raise PackageValidationError("unsupported_compression", "The archive uses an unsupported compression method.")

            app_roots = sorted({
                name.split("/", 2)[1]
                for name in normalized
                if name.startswith("Payload/") and len(name.split("/", 2)) >= 2 and name.split("/", 2)[1].endswith(".app")
            })
            if len(app_roots) != 1:
                raise PackageValidationError("invalid_payload", "The archive must contain exactly one top-level Payload app bundle.")
            app_root = "Payload/" + app_roots[0]
            info_path = app_root + "/Info.plist"
            try:
                info_entry = archive.getinfo(info_path)
            except KeyError as error:
                raise PackageValidationError("missing_info_plist", "The app bundle does not contain Info.plist.") from error
            if info_entry.file_size < 1 or info_entry.file_size > MAX_PLIST_BYTES:
                raise PackageValidationError("invalid_metadata", "Info.plist is empty or too large.")
            try:
                metadata = plistlib.loads(archive.read(info_entry))
            except (plistlib.InvalidFileException, ValueError, OSError, zipfile.BadZipFile) as error:
                raise PackageValidationError("invalid_metadata", "Info.plist could not be read.") from error
            if not isinstance(metadata, dict):
                raise PackageValidationError("invalid_metadata", "Info.plist must contain a dictionary.")

            bundle = string_value(metadata, "CFBundleIdentifier", BUNDLE_PATTERN, 255)
            version = string_value(metadata, "CFBundleShortVersionString", VERSION_PATTERN, 100)
            build = string_value(metadata, "CFBundleVersion", BUILD_PATTERN, 64)
            minimum_os = string_value(metadata, "MinimumOSVersion", OS_PATTERN, 32)
            executable_name = metadata.get("CFBundleExecutable")
            if not isinstance(executable_name, str) or not re.fullmatch(r"[^/\\.]{1,255}(?:\.[^/\\.]{1,32})?", executable_name):
                raise PackageValidationError("invalid_metadata", "CFBundleExecutable is missing or invalid.")
            executable_path = app_root + "/" + executable_name
            try:
                executable_info = archive.getinfo(executable_path)
            except KeyError as error:
                raise PackageValidationError("missing_executable", "The declared app executable is missing.") from error
            if executable_info.is_dir() or executable_info.file_size < 1:
                raise PackageValidationError("missing_executable", "The declared app executable is not a file.")
            if stat.S_ISLNK((executable_info.external_attr >> 16) & 0xFFFF):
                raise PackageValidationError("unsafe_archive", "The declared executable cannot be a symbolic link.")

            display_name = metadata.get("CFBundleDisplayName", metadata.get("CFBundleName", app_roots[0][:-4]))
            if not isinstance(display_name, str) or not display_name.strip() or len(display_name) > 160:
                raise PackageValidationError("invalid_metadata", "The app display name is invalid.")
            return {
                "result": "passed",
                "bundleIdentifier": bundle,
                "version": version,
                "build": build,
                "minimumOS": minimum_os,
                "displayName": display_name.strip(),
                "size": actual_size,
                "sha256": digest.hexdigest(),
            }
    except PackageValidationError:
        raise
    except (zipfile.BadZipFile, OSError, EOFError, RuntimeError, ValueError) as error:
        raise PackageValidationError("invalid_archive", "The IPA is not a readable ZIP archive.") from error


def normalize_zip_path(raw: str) -> str:
    if not raw or "\x00" in raw or "\\" in raw or raw.startswith("/") or re.match(r"^[A-Za-z]:", raw):
        raise PackageValidationError("unsafe_archive", "The archive contains an absolute or invalid path.")
    segments = raw.rstrip("/").split("/")
    if not segments or any(part in ("", ".", "..") for part in segments):
        raise PackageValidationError("unsafe_archive", "The archive contains path traversal.")
    path = PurePosixPath(raw)
    parts = path.parts
    if any(part in ("", ".", "..") for part in parts) or path.is_absolute():
        raise PackageValidationError("unsafe_archive", "The archive contains path traversal.")
    normalized = "/".join(parts)
    if len(normalized) > 1024:
        raise PackageValidationError("unsafe_archive", "An archive path is too long.")
    return normalized


def preflight_zip_directory(path: str, file_size: int) -> None:
    """Bound central-directory allocation before zipfile reads attacker-controlled names."""
    tail_size = min(file_size, 22 + 65_535)
    with open(path, "rb") as package:
        package.seek(file_size - tail_size)
        tail = package.read(tail_size)
    eocd_offset = tail.rfind(b"PK\x05\x06")
    if eocd_offset < 0 or eocd_offset + 22 > len(tail):
        raise PackageValidationError("invalid_archive", "The ZIP end directory is missing or malformed.")
    try:
        signature, disk, directory_disk, disk_entries, entry_count, directory_size, directory_offset, comment_size = struct.unpack_from(
            "<4s4H2LH", tail, eocd_offset,
        )
    except struct.error as error:
        raise PackageValidationError("invalid_archive", "The ZIP end directory is malformed.") from error
    absolute_eocd = file_size - tail_size + eocd_offset
    if signature != b"PK\x05\x06" or eocd_offset + 22 + comment_size != len(tail) or \
            disk != 0 or directory_disk != 0 or disk_entries != entry_count:
        raise PackageValidationError("invalid_archive", "Multi-disk ZIPs and trailing archive data are not supported.")
    if entry_count in (0xFFFF,) or directory_size == 0xFFFFFFFF or directory_offset == 0xFFFFFFFF:
        raise PackageValidationError("unsupported_archive", "ZIP64 archives are not supported for this package size limit.")
    if entry_count > MAX_ENTRIES:
        raise PackageValidationError("entry_count_limit", "The archive contains an unsupported number of entries.")
    if directory_size > MAX_CENTRAL_DIRECTORY_BYTES or directory_size < entry_count * 46 or \
            directory_offset + directory_size != absolute_eocd:
        raise PackageValidationError("central_directory_limit", "The ZIP central directory is malformed or too large.")


def string_value(metadata: dict[str, Any], key: str, pattern: re.Pattern[str], limit: int) -> str:
    value = metadata.get(key)
    if not isinstance(value, str) or len(value) > limit or not pattern.fullmatch(value):
        raise PackageValidationError("invalid_metadata", f"{key} is missing or invalid.")
    return value


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("package")
    parser.add_argument("--expected-size", type=int)
    arguments = parser.parse_args()
    try:
        report = inspect_ipa(arguments.package, arguments.expected_size)
    except PackageValidationError as error:
        print(json.dumps({"result": "failed", "errorCode": error.code}, separators=(",", ":")))
        raise SystemExit(1) from error
    print(json.dumps(report, separators=(",", ":")))


if __name__ == "__main__":
    main()
