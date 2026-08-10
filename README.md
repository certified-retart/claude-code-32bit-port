# Claude Code x86 port kit

This kit installs the newest JavaScript-based Claude Code npm release on 32-bit Windows. It does not include or redistribute Claude Code itself: the installer downloads Anthropic's public npm package directly and keeps Anthropic's license intact.

## What it installs

- Claude Code `2.1.112`, the final npm release containing the Node.js CLI
- Official Node.js `22.22.2` for Windows x86 (`ia32`)
- Microsoft's `@vscode/ripgrep-win32-ia32` package
- The matching Windows x86 Sharp and libvips packages for image handling
- A `claude-x86.cmd` launcher with automatic updates disabled

The installer does not run npm. It downloads exact registry archives, verifies their SHA-512 hashes, and extracts them using the confirmed 32-bit Node.js runtime. This avoids npm selecting or launching an incompatible architecture helper on older systems.

Installation is shown as seven numbered stages, with download percentages, checksum status, extraction percentages, and cooldown messages. The installer uses Windows' ACPI temperature sensor when the laptop exposes one. At 85 C it pauses until the reported temperature falls to 75 C; if the machine does not expose a usable sensor, it reports that limitation and inserts short conservative pauses between heavy stages.

Versions `2.1.113` and later are tiny installer packages that fetch Anthropic's 64-bit native executable, so this port must remain pinned to `2.1.112`.

## Requirements

- Windows 10 32-bit is the primary target.
- PowerShell 5.1 and internet access during installation.
- Git Bash for Windows x86 if you want Claude's Bash tool. Git for Windows `2.48.1` was the final release with a 32-bit installer; `2.40.1` was the final release with full 32-bit support.
- A valid Claude account/API configuration. This kit does not bypass authentication, subscriptions, or Anthropic service restrictions.

## Install

1. Extract this zip.
2. Double-click `install.cmd`.
3. Open a new Command Prompt.
4. Run `claude-x86 --version`, then `claude-x86`.

The default location is `%LOCALAPPDATA%\ClaudeCode-x86`. To choose another location, run:

```powershell
powershell -ExecutionPolicy Bypass -File .\Install-ClaudeCode-x86.ps1 -InstallDir "C:\Tools\ClaudeCode-x86" -AddToPath
```

Always keep `extract-tgz.js` beside the PowerShell installer. Do not download only `install.cmd` by itself.

The default temperature thresholds can be changed when launching the PowerShell installer:

```powershell
powershell -ExecutionPolicy Bypass -File .\Install-ClaudeCode-x86.ps1 -HighTemperatureC 82 -ResumeTemperatureC 72
```

The resume threshold must be lower than the high-temperature threshold. Temperature monitoring is best-effort because many older PCs do not publish CPU temperature through Windows. It does not require administrator rights.

## Limitations

- Voice/audio capture is unavailable because Anthropic did not publish a Windows `ia32` audio-capture module.
- The 32-bit process has a much smaller address space. Very large repositories or long sessions may run out of memory; the launcher caps V8's old-generation heap at 1024 MB.
- Anthropic no longer maintains the JavaScript distribution. Server-side/API changes could eventually make `2.1.112` stop working.
- Do not run Claude Code's native installer or updater from this installation. It only supports 64-bit targets. The launcher sets `DISABLE_AUTOUPDATER=1` for this reason.

## Removal

Delete `%LOCALAPPDATA%\ClaudeCode-x86`, then remove that directory from your user `PATH`. If the installer replaced an earlier copy, it preserves that copy in a timestamped `.backup-*` directory next to the installation.

## Security and provenance

The installer verifies the official Node.js archive against Node's published SHA-256 checksum and verifies every npm registry archive against its pinned SHA-512 integrity value. Review `Install-ClaudeCode-x86.ps1` before running it if you want to inspect every download and file operation.
