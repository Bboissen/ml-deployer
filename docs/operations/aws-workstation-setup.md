# AWS workstation setup

Implementation milestone M2 builds on the short project configuration in PR27.
Keep the Python controller and bootstrap its local runtime with Bash. This
milestone installs operator tools and assists authentication; it does not apply
infrastructure or transfer project data.

The installer will pin and verify AWS CLI, OpenTofu, uv, Python and the Session
Manager plugin in a user-owned directory. It will preserve existing cloud
profiles, credentials and shell startup files, provide an offline check-only
mode, and report exact repair instructions for missing operating-system tools.

Initial host matrix: Ubuntu 22.04/24.04 and macOS 13 or newer, on x86_64 and arm64.
Linux and macOS are first-release requirements. Installer acceptance and native
deployment acceptance are separate: the existing operator key check still
requires Linux RAM-backed storage.

Implementation and offline checks are in progress. Clean macOS installation and
the full generalized Deploy journey remain acceptance work.
