# Security policy

## Reporting a vulnerability

Please report security issues privately through
[GitHub's private vulnerability reporting](https://github.com/mnsn/ado-pulse/security/advisories/new),
not in a public issue.

Describe what's affected, how to reproduce it and the impact you expect. This is a personal
project maintained in spare time, so a reply may take a few days.

## Scope

ADO Pulse reads your Azure DevOps pull requests with a token from the Azure CLI's sign-in. Worth
reporting:

- any way it could change anything in Azure DevOps: it's meant to send only GET requests,
- any way it could expose your token, or your pull requests' titles and comments, outside your Mac,
  including by sending them to a model other than Apple Intelligence's on-device model,
- with **Pull Requests Sent in Chats** on: any way it could change Notification Center's data, keep a
  message's text, keep what it found where other programs running as you can read it, or let a
  notification make it open something other than an Azure DevOps pull request or the message it came
  in; and any way something other than you could turn it on,
- any way a program it starts, or anything that can change one, could use its permissions, such as
  its Full Disk Access, and any way a program could by starting ADO Pulse itself (with its
  command-line modes, arguments, environment or output),
- any way another app or a web page could make it run a command or open a link it shouldn't, and
- problems with how the build scripts and workflows here build, sign or publish the app.

Vulnerabilities in Azure DevOps or the Azure CLI themselves should go to Microsoft through the
[Microsoft Security Response Center](https://msrc.microsoft.com/create-report).

## How it handles your sign-in

- ADO Pulse never asks for a password or a personal access token. It runs
  `az account get-access-token` for Azure DevOps, keeps the token in memory until shortly before it
  expires, and sends it only to `dev.azure.com` and `app.vssps.visualstudio.com`, over HTTPS.
- It doesn't write the token anywhere: not to disk, its preferences or its logs. The Azure CLI keeps
  its own sign-in, in its own files.
- Its requests use an ephemeral session: no cookies, no cache.

## Programs it starts

macOS lets a program use the privacy permissions of the app that started it, its "responsible
process". ADO Pulse starts the Azure CLI, a Python program, usually in `/opt/homebrew`; your login
shell, which it asks where `az` is; the helper that opens ADO Pulse again once you've allowed Full
Disk Access; and `tccutil`, to remove that access when you turn pull requests sent in chats off.
Anything running as you can change the Azure CLI, the Python files it runs, and your
shell's startup files. So ADO Pulse starts every program responsible for itself, with only the
permissions macOS gave that program, never ADO Pulse's Full Disk Access. The call that does
it (`responsibility_spawnattrs_setdisclaim`, which Chromium and LLDB use too) is private to macOS:
without it, ADO Pulse starts nothing. Apps, links and files it opens (your browser, Teams, Terminal for
`az login`) are opened by macOS, which makes each responsible for itself. Tests check that a program it
starts is responsible for itself, and that nothing else in the app starts programs.

## Programs that start ADO Pulse

Any program running as you can start ADO Pulse itself, through LaunchServices
(`open -n -g --stdout out.txt "ADO Pulse.app" --args --chats`) or with its responsibility
disclaimed. ADO Pulse then has its own Full Disk Access, and that program chose its arguments and
environment, and can read its output. So, started that way, ADO Pulse runs none of its command-line
modes or `--render` (`--help` still prints), ignores `-key value` arguments that would set its
preferences and `ADO_PULSE_NOTIFICATIONS_DB`, which could name a copy that only Full Disk Access
reads, and sends its output to `/dev/null`. It tells by asking macOS which executable it's
attributed to, and when macOS can't say, it counts as its own permissions. Run from a shell, they
run with the permissions of the app the shell runs in, such as Terminal's. `ADO_PULSE_AZ` still
applies: `az` runs with its own permissions. Tests check the decision, and run the built app both
ways.

## Pull requests sent in chats

- **What it reads with Full Disk Access stays with it.** The links it finds in other apps'
  notifications, with who sent them, in which app and chat, and when, and which of those pull
  requests you've seen, are kept in memory only. Its preferences, which any program running as you
  can read and change (`defaults read com.asaf.ADOPulse`), hold its settings and which of your own
  pull requests you've seen, but nothing from Notification Center; nor does its log or anything on
  disk. Earlier builds kept the links in the preferences: ADO Pulse removes them at launch. The
  command line never has them.
- **Only you can turn it on.** It isn't a preference or a launch argument, which any program could
  set. Started as an app, ADO Pulse reads with its own Full Disk Access, which only you can give it,
  so the setting is on exactly while it has that access. Turning it off removes the access
  (`tccutil reset`), so ADO Pulse holds no Full Disk Access while it's off. If that fails, a
  preference that can only keep it off does so, at every launch while the access is left, and ADO
  Pulse asks you to remove it in System Settings › Privacy & Security › Full Disk Access.

Tests check that the preferences hold nothing from chats after links are found, that a forged
preference or launch argument doesn't start reading, that earlier builds' links go at launch, and
that the setting stays off when removing the access fails.

## Supported versions

Only the latest release, and the latest commit on `main`, are supported.

## Verifying a download

Releases are built and published by the
[release workflow](https://github.com/mnsn/ado-pulse/blob/main/.github/workflows/release.yml)
from the tagged source, with a build provenance attestation. To check that an `ADO-Pulse.zip` you
downloaded came from it, use the [GitHub CLI](https://cli.github.com):

```sh
gh attestation verify ADO-Pulse.zip --repo mnsn/ado-pulse
```

Each release also lists the zip's SHA-256, which `shasum -a 256 ADO-Pulse.zip` prints. The app isn't
notarized, so macOS can't tie it to this project; the attestation can. It's signed with the project's
own certificate, so you can also check the app itself:

```sh
codesign -d -r- "/Applications/ADO Pulse.app"
```

prints a designated requirement that ends with `certificate leaf = H"…"`, the SHA-1 in
[scripts/release-certificate.sha1](https://github.com/mnsn/ado-pulse/blob/main/scripts/release-certificate.sha1).
The certificate's private key is a secret of the repository's `release` environment, not a
repository secret, so only the release workflow's signing job can use it, for a `v*` tag, after a
maintainer approves the release. The job imports it into a keychain of its own, where only codesign
may use it and nothing can export it, and deletes that keychain before any other step runs.
