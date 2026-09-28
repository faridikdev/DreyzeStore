# Privacy

This document describes the current DreyzeStore client, backend, admin and Windows Companion behavior. A production service operator may have additional infrastructure logging obligations; this repository does not configure a production deployment.

## iOS client

The client sends requests to the HTTPS catalog API configured for that build. Requests include the requested endpoint and query, such as catalog pagination, a search phrase, app details, or published update metadata. Standard network infrastructure can observe IP address, request time, user agent and response status. The public store API does not need an Apple identity or a DreyzeStore user account.

The client keeps recent searches, user preferences, cached catalog responses, cached images, verified packages, update history and a Companion inventory snapshot on device. Pairing information, including its opaque authentication token and TLS certificate pin, is stored in iOS Keychain. The user can clear catalog/image cache and managed downloads from Settings → Storage. Removing downloads does not uninstall an app.

## Windows Companion

The Companion keeps local installation records, diagnostic state and its local TLS service identity on the PC. Imported development certificate/profile material is protected locally using Windows DPAPI; the P12 password is stored in Windows Credential Manager. The Companion must access the USB-connected iPhone and the user's local signing files to sign/install apps.

When paired, iPhone and Companion exchange device readiness, installed bundle IDs/versions/builds, signing expiry metadata and installation requests over the pinned local HTTPS connection. Pairing is explicit and can be removed in the iOS Companion settings and Windows Companion UI.

## Backend and admin

The public API stores and returns published catalog metadata, release metadata, assets and package references. Admin sessions and audit events are stored by the backend. The service operator may receive normal request telemetry from Cloudflare or the configured object-storage/CDN provider. See [deployment](deployment.md) before running a public instance.

## Never sent to the DreyzeStore catalog backend

- Apple Account password or 2FA code.
- Private signing keys, P12 password, Apple development certificate private key, or provisioning profile contents.
- Companion pairing token, local TLS private key, or local Windows credential-store values.
- Full installed-app inventory. Inventory stays between the paired iPhone and the Windows Companion; the iOS app sends only the canonical bundle/version/build/channel items needed to query public updates.

## Verification limits

SHA-256 and package metadata checks establish that downloaded bytes match the published digest and declared app identity/version. They do not prove that an app is benign, virus-free, reviewed, or legally redistributable. Only install packages you are authorized to use and trust the source.

## Contact and changes

Review changes through the public source repository. This policy is versioned with the application; deployment operators should publish the policy URL and contact details appropriate to their own service.
