"""Patch the pinned upstream zsign CLI to read P12 passwords from stdin.

The upstream `--password` option accepts argv text, which is visible to local
process inspectors. DreyzeStore adds `--password-stdin` with a 4-byte
little-endian length prefix; no Apple credential is placed in argv or env.
"""

from __future__ import annotations

import argparse
from pathlib import Path


def replace_once(text: str, before: str, after: str, label: str) -> str:
    count = text.count(before)
    if count != 1:
        raise SystemExit(f"Expected one upstream {label} anchor, found {count}.")
    return text.replace(before, after, 1)


def patch(source: Path) -> None:
    text = source.read_text(encoding="utf-8")
    if "--password-stdin" in text:
        if "Post-sign signature verification failed!" not in text:
            text = replace_once(
                text,
                '\tif (bRet && bCheckSignature && !bundle.m_strAppFolder.empty()) {\n'
                '\t\tCheckSignedBinary(bundle.m_strAppFolder);\n'
                '\t}\n',
                '\tif (bRet && bCheckSignature && !bundle.m_strAppFolder.empty()) {\n'
                '\t\tif (CheckSignedBinary(bundle.m_strAppFolder) != 0) {\n'
                '\t\t\tZLog::Error(">>> Post-sign signature verification failed!\\n");\n'
                '\t\t\tbRet = false;\n'
                '\t\t}\n'
                '\t}\n',
                "post-sign verification result handling",
            )
            source.write_text(text, encoding="utf-8", newline="\n")
        return
    text = replace_once(
        text,
        '#include "common.h"\n',
        '#include "common.h"\n#include <iostream>\n#include <openssl/crypto.h>\n',
        "include block",
    )
    text = replace_once(
        text,
        '\t{"password", required_argument, NULL, \'p\'},\n',
        '\t{"password", required_argument, NULL, \'p\'},\n\t{"password-stdin", no_argument, NULL, \'Z\'},\n',
        "password option",
    )
    text = replace_once(
        text,
        '\tZLog::Print("-p, --password\\t\\tPassword for private key or p12 file.\\n");\n',
        '\tZLog::Print("-p, --password\\t\\tPassword for private key or p12 file.\\n");\n'
        '\tZLog::Print("    --password-stdin\\tRead a length-prefixed P12 password from stdin.\\n");\n',
        "password help",
    )
    text = replace_once(
        text,
        '\tstring strPassword;\n',
        '\tstring strPassword;\n'
        '\tstruct PasswordWiper { string& value; ~PasswordWiper() { if (!value.empty()) OPENSSL_cleanse(&value[0], value.size()); } } passwordWiper{strPassword};\n',
        "password storage",
    )
    text = replace_once(
        text,
        '"dfva2LhiqwCRSEWUPc:k:m:o:p:e:b:n:z:l:D:t:r:x:M:I:"',
        '"dfva2LhiqwCRSEWUPZc:k:m:o:p:e:b:n:z:l:D:t:r:x:M:I:"',
        "short option string",
    )
    text = replace_once(
        text,
        "\t\tcase 'p':\n\t\t\tstrPassword = optarg;\n\t\t\tbreak;\n",
        "\t\tcase 'p':\n\t\t\tstrPassword = optarg;\n\t\t\tbreak;\n"
        "\t\tcase 'Z': {\n"
        "\t\t\tunsigned char lengthBytes[4] = {};\n"
        "\t\t\tif (!std::cin.read(reinterpret_cast<char*>(lengthBytes), sizeof(lengthBytes))) return -1;\n"
        "\t\t\tuint32_t length = static_cast<uint32_t>(lengthBytes[0])\n"
        "\t\t\t\t| (static_cast<uint32_t>(lengthBytes[1]) << 8)\n"
        "\t\t\t\t| (static_cast<uint32_t>(lengthBytes[2]) << 16)\n"
        "\t\t\t\t| (static_cast<uint32_t>(lengthBytes[3]) << 24);\n"
        "\t\t\tif (length == 0 || length > 2048) return -1;\n"
        "\t\t\tstrPassword.resize(length);\n"
        "\t\t\tif (!std::cin.read(&strPassword[0], length)) { OPENSSL_cleanse(&strPassword[0], strPassword.size()); return -1; }\n"
        "\t\t\tif (std::cin.peek() != std::char_traits<char>::eof()) { OPENSSL_cleanse(&strPassword[0], strPassword.size()); return -1; }\n"
        "\t\t\tbreak;\n"
        "\t\t}\n",
        "password input handler",
    )
    text = replace_once(
        text,
        '\tif (bRet && bCheckSignature && !bundle.m_strAppFolder.empty()) {\n'
        '\t\tCheckSignedBinary(bundle.m_strAppFolder);\n'
        '\t}\n',
        '\tif (bRet && bCheckSignature && !bundle.m_strAppFolder.empty()) {\n'
        '\t\tif (CheckSignedBinary(bundle.m_strAppFolder) != 0) {\n'
        '\t\t\tZLog::Error(">>> Post-sign signature verification failed!\\n");\n'
        '\t\t\tbRet = false;\n'
        '\t\t}\n'
        '\t}\n',
        "post-sign verification result handling",
    )
    source.write_text(text, encoding="utf-8", newline="\n")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path, help="Path to pinned upstream src/zsign.cpp")
    args = parser.parse_args()
    patch(args.source)


if __name__ == "__main__":
    main()
