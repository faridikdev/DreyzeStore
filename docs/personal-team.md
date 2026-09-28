# Apple Personal Team notes

Apple documents Personal Team provisioning through Xcode, not a Windows provisioning API. This Companion's Windows flow calls a third-party reverse-engineered Apple protocol and is not an Apple-supported replacement for Xcode. It may fail for a free account even when the entered credentials are valid.

Apple publishes current limits and profile lifetime details in its [developer account overview](https://developer.apple.com/help/account/basics/about-your-developer-account). The Companion does not hardcode account quotas as policy. It displays returned certificate/profile dates where available and reports provisioning errors without attempting to bypass an Apple limit.

Personal Team setup requires the device owner to trust the PC, explicitly enable Developer Mode, and approve device registration. Provisioning/profile acceptance remains subject to Apple's systems and on-device validation. The Companion does not use enterprise certificates, another person's account, leaked certificates, jailbreaks, or exploits.

The current protocol integration also has a deliberately narrow app compatibility envelope. Apps with extensions, universal binaries, DER entitlements, or capabilities beyond the allowlist are rejected before provisioning/signing. The user should keep a separate copy of the original verified IPA and understand that changing a bundle ID can affect app data sharing and updates.

## Verification status

- Apple account authentication against a live service: **NOT TESTED**.
- Real team/certificate/App ID/profile creation: **NOT TESTED**.
- Physical iPhone install, launch, refresh, update, and uninstall: **NOT VERIFIED**.
- Automatic no-manual-`.p12`/no-manual-profile setup: implemented as an experimental path, but **not yet demonstrated end-to-end**.

See [the physical-device install test plan](physical-device-install-test.md).
