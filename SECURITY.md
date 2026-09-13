# Security Policy

This repository provisions a Mac mini as an **unattended, always-on headless server**. To achieve that, `bootstrap_mac_node.sh` deliberately weakens several of macOS's default security protections. This is a trade-off made explicitly for automation and uptime — read this document before running the script, especially on hardware that isn't in a physically controlled location.

## Security Trade-offs Made by This Script

| Protection Disabled | Why | Risk |
| :--- | :--- | :--- |
| **FileVault** (must be disabled by the operator before running; the script only warns) | Full-disk encryption blocks unattended auto-login after a power cut/reboot | Anyone with physical access to the machine or its storage can read data at rest without a password |
| **Application Firewall** (`socketfilterfw`) | Prevents GUI confirmation prompts from blocking headless background services | Any process binding to a network interface is reachable without a prompt |
| **System sleep / display sleep / standby** | Required for 24/7 availability | Higher idle power draw and continuous fan noise |
| **Automatic OS updates** | Prevents uncoordinated reboots interrupting long-running jobs | Security patches are not applied automatically — see Operator Responsibilities below |
| **Spotlight indexing** | Reduces disk writes and background CPU load | `Cmd+Space` search stops working; use `find`/`mdfind` manually |

None of these are bugs — they are the documented, intended behavior of this project. They are listed here so anyone deploying this script makes an informed decision, not an accidental one.

## Recommended Deployment Constraints

Because of the trade-offs above, this script should only be run on a machine that is:

1. **Not directly exposed to the public internet.** Place it behind a router/NAT, a dedicated firewall, or an isolated VLAN. Do not port-forward SSH (22) or Screen Sharing (5900) from your router without a VPN in front of them.
2. **Physically secured**, or you accept the FileVault-off data-at-rest risk (locked room, rack, or cabinet).
3. **Patched on a schedule you control**, since automatic updates are disabled. Run `sudo softwareupdate -ia --restart` on a recurring manual maintenance window.
4. **Access-controlled at the account level** — use SSH key authentication rather than password auth where possible, and keep the target user's password strong, since the Application Firewall being off means every listening service is reachable to anything on the local network.

## Reporting a Vulnerability

If you find a security issue in the **script itself** (e.g. a command that does something more dangerous than documented, an injection vector via `$1`/`$2`, or a step that silently fails without being reported), please open an issue in this repository or contact the maintainer directly rather than filing it as a normal bug, so it can be reviewed before being made public.

This project has no bug bounty program. Reports are handled on a best-effort basis by the repository owner.

## Supported Versions

Only the latest commit on the default branch is supported. There are no maintained release branches.
