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
  message's text, or let a notification make it open something other than an Azure DevOps pull
  request or the message it came in,
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
maintainer approves the release.
