"""Small GitHub Actions adapter: lease a private package, inspect it, and report metadata."""

from __future__ import annotations

import argparse
import base64
import json
import os
import re
import tempfile
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

from validate_ipa import MAX_PACKAGE_BYTES, PackageValidationError, inspect_ipa


class RejectRedirects(urllib.request.HTTPRedirectHandler):
    """Signed URLs and bearer-authenticated callbacks must not forward credentials."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


NO_REDIRECT_OPENER = urllib.request.build_opener(RejectRedirects())


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=("lease", "inspect", "report"))
    parser.add_argument("--upload-id", default="")
    parser.add_argument("--download-url", default="")
    parser.add_argument("--report-nonce", default="")
    parser.add_argument("--expected-size", type=int, default=0)
    parser.add_argument("--report-b64", default="")
    parser.add_argument("--error-code", default="")
    parser.add_argument("--dispatch-ticket", default="")
    args = parser.parse_args()

    if args.mode == "lease":
        lease(args.upload_id, args.dispatch_ticket)
    elif args.mode == "inspect":
        inspect_and_output(args.download_url, args.report_nonce, args.expected_size)
    else:
        report(args.report_nonce, args.report_b64, args.error_code)


def lease(upload_id: str, dispatch_ticket: str) -> None:
    if not re.fullmatch(r"[0-9a-f-]{36}", upload_id):
        raise RuntimeError("Invalid validator upload identifier.")
    base = api_base()
    token = get_oidc_token()
    if not re.fullmatch(r"[A-Za-z0-9_-]{40,64}", dispatch_ticket):
        raise RuntimeError("Invalid validator dispatch ticket.")
    result = post_json(base + "/api/v1/validator/uploads/" + upload_id + "/lease", {"dispatchTicket": dispatch_ticket}, token)
    data = result.get("data")
    if not isinstance(data, dict):
        raise RuntimeError("The validator lease response was invalid.")
    url = data.get("downloadURL")
    nonce = data.get("reportNonce")
    size = data.get("expectedSize")
    if not isinstance(url, str) or not isinstance(nonce, str) or not isinstance(size, int):
        raise RuntimeError("The validator lease response was incomplete.")
    validate_staging_url(url)
    if not re.fullmatch(r"[A-Za-z0-9_-]{40,64}", nonce) or size < 1 or size > MAX_PACKAGE_BYTES:
        raise RuntimeError("The validator lease response failed validation.")
    output({"download_url": url, "report_nonce": nonce, "expected_size": str(size)})


def inspect_and_output(url: str, nonce: str, expected_size: int) -> None:
    validate_staging_url(url)
    if not re.fullmatch(r"[A-Za-z0-9_-]{40,64}", nonce) or expected_size < 1 or expected_size > MAX_PACKAGE_BYTES:
        raise RuntimeError("The validator lease parameters are invalid.")
    report: dict[str, Any]
    try:
        with tempfile.TemporaryDirectory(prefix="dreyzestore-validator-") as temporary:
            package_path = Path(temporary) / "upload.ipa"
            download(url, package_path, expected_size)
            report = inspect_ipa(str(package_path), expected_size)
    except PackageValidationError as error:
        report = {"result": "failed", "errorCode": error.code}
    except (OSError, TimeoutError, urllib.error.URLError, RuntimeError):
        report = {"result": "failed", "errorCode": "validator_download_failed"}
    except Exception:
        report = {"result": "failed", "errorCode": "validator_runner_failed"}
    encoded = base64.urlsafe_b64encode(json.dumps(report, separators=(",", ":"), ensure_ascii=True).encode()).decode()
    output({"report_b64": encoded})


def report(nonce: str, encoded_report: str, error_code: str = "") -> None:
    if not re.fullmatch(r"[A-Za-z0-9_-]{40,64}", nonce) or len(encoded_report) > 12_000 or \
            (error_code and error_code != "validator_runner_failed") or (bool(encoded_report) == bool(error_code)):
        raise RuntimeError("The validation report is invalid.")
    if error_code:
        payload = {"result": "failed", "errorCode": error_code}
    else:
        try:
            payload = json.loads(base64.urlsafe_b64decode(encoded_report + "=" * (-len(encoded_report) % 4)))
        except (ValueError, json.JSONDecodeError) as error:
            raise RuntimeError("The validation report could not be decoded.") from error
    if not isinstance(payload, dict):
        raise RuntimeError("The validation report is not an object.")
    token = get_oidc_token()
    result = post_json(api_base() + "/api/v1/validator/uploads/" + os.environ["UPLOAD_ID"] + "/result", {
        "reportNonce": nonce,
        **payload,
    }, token)
    state = result.get("data", {}).get("state") if isinstance(result.get("data"), dict) else None
    if state not in ("ready_for_review", "validation_failed"):
        raise RuntimeError("The API did not accept the validation result.")
    print("Package validation result accepted by the DreyzeStore API: " + state)


def get_oidc_token() -> str:
    request_url = os.environ.get("ACTIONS_ID_TOKEN_REQUEST_URL", "")
    request_secret = os.environ.get("ACTIONS_ID_TOKEN_REQUEST_TOKEN", "")
    if not request_url or not request_secret:
        raise RuntimeError("GitHub Actions OIDC is not available to this job.")
    separator = "&" if "?" in request_url else "?"
    configured_audience = os.environ.get("DREYZESTORE_VALIDATOR_AUDIENCE", "")
    if not configured_audience or len(configured_audience) > 255:
        raise RuntimeError("Configure DREYZESTORE_VALIDATOR_AUDIENCE as a repository variable.")
    url = request_url + separator + urllib.parse.urlencode({"audience": configured_audience})
    request = urllib.request.Request(url, headers={"Authorization": "Bearer " + request_secret, "Accept": "application/json"})
    with NO_REDIRECT_OPENER.open(request, timeout=15) as response:
        body = json.load(response)
    token = body.get("value") if isinstance(body, dict) else None
    if not isinstance(token, str) or len(token) > 12_000:
        raise RuntimeError("GitHub Actions did not return a valid OIDC token.")
    return token


def post_json(url: str, payload: dict[str, Any], bearer: str) -> dict[str, Any]:
    body = json.dumps(payload, separators=(",", ":")).encode()
    request = urllib.request.Request(url, data=body, method="POST", headers={
        "Authorization": "Bearer " + bearer,
        "Content-Type": "application/json",
        "Accept": "application/json",
    })
    try:
        with NO_REDIRECT_OPENER.open(request, timeout=30) as response:
            result = json.load(response)
    except urllib.error.HTTPError as error:
        # Do not echo response bodies because service diagnostics can contain sensitive details.
        raise RuntimeError("DreyzeStore validator API rejected the request (HTTP " + str(error.code) + ").") from error
    if not isinstance(result, dict):
        raise RuntimeError("DreyzeStore validator API returned an invalid response.")
    return result


def validate_staging_url(value: str) -> None:
    if len(value) > 8192 or "\r" in value or "\n" in value:
        raise RuntimeError("The staging URL is invalid.")
    parsed = urllib.parse.urlsplit(value)
    if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password or parsed.fragment:
        raise RuntimeError("The staging URL is not a safe HTTPS URL.")
    r2_suffix = ".r2.cloudflarestorage.com"
    host_prefix = parsed.hostname[:-len(r2_suffix)] if parsed.hostname.endswith(r2_suffix) else ""
    bucket, separator, account = host_prefix.rpartition(".")
    if not separator or not re.fullmatch(r"[a-z0-9][a-z0-9.-]{0,61}", bucket, re.IGNORECASE) or \
            ".." in bucket or bucket.endswith(".") or not re.fullmatch(r"[a-f0-9]{32}", account, re.IGNORECASE) or \
            parsed.port is not None or not parsed.query:
        raise RuntimeError("The staging URL is not an R2 signed object URL.")
    normalized = urllib.parse.urljoin("/", parsed.path)
    if normalized != parsed.path or "/../" in parsed.path or not parsed.path.startswith("/"):
        raise RuntimeError("The staging URL path is invalid.")


def download(url: str, destination: Path, expected_size: int) -> None:
    request = urllib.request.Request(url, headers={"Accept": "application/octet-stream"})
    # R2 presigned object URLs should be served directly. Refusing all redirects avoids
    # leaking signed query strings and keeps the validator pinned to the bucket host.
    with NO_REDIRECT_OPENER.open(request, timeout=90) as response:
        final = urllib.parse.urlsplit(response.geturl())
        if final.scheme != "https" or final.hostname != urllib.parse.urlsplit(url).hostname:
            raise RuntimeError("The staging download redirected outside its signed R2 host.")
        declared = response.headers.get("Content-Length")
        if declared:
            try:
                declared_size = int(declared)
            except ValueError as error:
                raise PackageValidationError("package_size_mismatch", "The staged package size header is invalid.") from error
            if declared_size != expected_size:
                raise PackageValidationError("package_size_mismatch", "The staged package size does not match.")
        written = 0
        with destination.open("xb") as package:
            while True:
                block = response.read(1024 * 1024)
                if not block:
                    break
                written += len(block)
                if written > expected_size or written > MAX_PACKAGE_BYTES:
                    raise PackageValidationError("package_size_mismatch", "The staging object exceeded its expected size.")
                package.write(block)
        if written != expected_size:
            raise PackageValidationError("package_size_mismatch", "The staging object size did not match.")


def api_base() -> str:
    value = os.environ.get("DREYZESTORE_API_BASE_URL", "").rstrip("/")
    parsed = urllib.parse.urlsplit(value)
    if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password or parsed.query or parsed.fragment or \
            parsed.path not in ("", "/") or parsed.port is not None:
        raise RuntimeError("Configure DREYZESTORE_API_BASE_URL as an HTTPS origin repository variable.")
    return value


def output(values: dict[str, str]) -> None:
    path = os.environ.get("GITHUB_OUTPUT")
    if not path:
        raise RuntimeError("This command must run inside a GitHub Actions job.")
    lines = []
    for key, value in values.items():
        if "\n" in value or "\r" in value:
            raise RuntimeError("Workflow output contained an invalid line break.")
        lines.append(f"{key}={value}\n")
    with open(path, "a", encoding="utf-8") as stream:
        stream.writelines(lines)


if __name__ == "__main__":
    main()
