# Changelog

## v1.1.0 - 2026-05-19

- Add persistent Alibaba Cloud Workbench SSH inbound fix for Tailscale `ts-input`.
- Insert Workbench allow rules before Tailscale's `DROP !tailscale0 100.64.0.0/10` guard.
- Add a `tailscaled.service` drop-in so Workbench allow rules are restored after Tailscale restarts.
- Document Workbench `SocketTimeoutException` diagnostics and verification steps.
- Fix the quick-start raw GitHub URL to use the repository's `master` branch.

## v1.0.0 - 2026-05-18

- Initial one-shot installer for Alibaba Cloud internal route bypass rules.
- Persist policy routes for metadata, internal DNS, and package mirror endpoints.
