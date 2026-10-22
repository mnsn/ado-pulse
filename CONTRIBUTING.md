# Contributing to ADO Pulse

Thanks for your interest! Bug reports, ideas and pull requests are all welcome.

## Getting started

You need macOS 15 or later and Swift 6. Xcode works, and so do just the Command Line Tools. Running
it with your own pull requests needs the Azure CLI, signed in (`az login`); the tests and the demo
don't.

```sh
git clone https://github.com/mnsn/ado-pulse.git
cd ado-pulse
make test    # run the tests
make demo    # run the app with made-up pull requests (Ctrl-C to quit)
make run     # run the app with your own pull requests
```

`make demo` uses made-up pull requests in every state (`DemoData`), and a few seconds after it
starts, a made-up comment arrives, to show how a new event looks. Use it to work on the UI and to
take screenshots without showing your own pull requests. In the app bundle,
`open "build/ADO Pulse.app" --args --demo` also posts that comment as a notification.

Other useful targets:

```sh
make build         # debug build
make demo-check    # check that the demo pull requests land in the expected groups
make screenshots   # render the README screenshots from the demo data
make app           # build "ADO Pulse.app" into ./build without installing
make package       # build the universal app for a release, check it and zip it into build/release
make install       # build the app, copy it to ~/Applications and launch it
make icon          # regenerate Resources/AppIcon.icns
make signing-identity  # optional: a certificate to sign builds with, so Full Disk Access survives rebuilds;
                       # each build then asks for your login password: choose Allow, never Always Allow
make signing-key-check # check, in throwaway keychains, that the signing keys can't be exported or used unasked
```

[How it works](docs/how-it-works.md) explains where the data comes from and how a pull request's
group is decided.

## Project layout

```text
Sources/ADOPulseCore/   the engine; UI-free, and fully tested
  Auth                  the token provider protocol, and the Azure CLI provider
  ProcessRunner         starts every program the app runs, each responsible for itself
  Attribution           whose permissions ADO Pulse has: its own, or those of the app starting it
  ADOClient             GET-only HTTP client, endpoint URLs, Retry-After handling
  APIModels             the Azure DevOps JSON it reads, decoded leniently
  PullRequest           pull requests, reviewers and votes
  PRDetails             branch policies as checks, comment threads, and activity from system threads
  PRStatus              the classifier: each pull request's group, reason and unseen events
  SeenState             what you've already seen, and the RefreshPlanner that schedules detail requests
  PulseEngine           polls the lists and details and publishes snapshots
  Notifications         decides what's worth a notification
  Brief                 picks the brief's items and words the prompts for the on-device model
  OrganizationDiscovery finds your organizations
  NotificationCenter    read-only access to Notification Center's database, and its records
  ChatLinks             finds pull request links in notifications, and remembers them
  ChatLinkMonitor       watches Notification Center for new links
  DemoData              made-up pull requests in every state
Sources/ADOPulse/       the AppKit/SwiftUI app: menu bar, panel, widget, settings, notifications,
                        on-device summaries, command line and renderer
Tests/ADOPulseCoreTests/  Swift Testing suites, including the engine against a stub Azure DevOps
Tests/ADOPulseTests/    the app's own logic that keeps your data, such as its settings
scripts/                app bundling, signing, checking and packaging, and the icon
```

## Debugging

The app binary doubles as a command-line tool:

```sh
.build/debug/ADOPulse --dump            # table of every pull request and its status
.build/debug/ADOPulse --json            # the same as JSON, with counts
.build/debug/ADOPulse --watch           # print changes as they happen
.build/debug/ADOPulse --orgs            # your organizations, and the ones with pull requests
.build/debug/ADOPulse --chats           # pull request links in Notification Center (Terminal needs Full Disk Access)
.build/debug/ADOPulse --render <dir>    # draw the menu bar with the panel open, and each widget size, to PNGs (light and dark)
```

Add `--demo` to any of them to use the made-up pull requests, or `--org <name>` to read another
organization. They read the app's settings (organizations, what you've seen) but never change them,
and they leave out pull requests sent in chats, which only the app has, in memory: `--chats` lists
the links Notification Center has. `make dump`, `make watch` and `make render` run them from a debug
build; `make render` writes your own pull requests to `render/`, which git ignores.

They, and `ADO_PULSE_NOTIFICATIONS_DB`, work only with the permissions of the app that started
ADO Pulse, such as Terminal. Started as an app (Finder, a login item, `open`), or by a program that
disclaimed it, ADO Pulse has its own Full Disk Access, so it refuses them and ignores the variable
([Ground rules](#ground-rules)). Run `make demo`, `make demo-check` and the rest from a shell, as
the Makefile does.

Diagnostics go to the system log:

```sh
log show --last 10m --info --predicate 'subsystem == "com.asaf.ADOPulse"' --style compact
```

## Building with only the Command Line Tools

- `make test` passes Swift Testing's macro plugin folder to the compiler explicitly. Without it,
  `swift test` sometimes fails with "plugin for module 'TestingMacros' not found".
- The `@State`, `@Entry` and `#Preview` SwiftUI macros aren't available without Xcode, so the views
  use a small `@LocalState` property wrapper instead of `@State`.
- FoundationModels' `@Generable` and `@Guide` macros aren't available either, so the summaries use
  plain-text prompts and instructions.

## Ground rules

- **Never write to Azure DevOps.** Every request goes through `ADOClient`, which only sends GET
  requests without a body. Don't add another way to make requests, and test new requests against
  the stub server in the tests.
- **Notification Center is read, never written.** Open its database read-only, keep reads short,
  and keep only pull request links and who sent them where: never a message's text. Test with the
  made-up database in the tests, or `ADO_PULSE_NOTIFICATIONS_DB` pointing at a copy.
- **Nothing from Notification Center goes to the preferences**, which any program running as you can
  read with `defaults read`, nor to the log or disk: the links people send in chats, and which of the
  pull requests listed only because of them you've seen, stay in memory. And no preference or launch
  argument turns the feature on: started as an app, ADO Pulse reads with its own Full Disk Access,
  which is the switch, and turning the feature off removes it. `ChatLinkSettingsTests` and
  `ChatReadingTests` check both, without reading Notification Center or changing Full Disk Access.
- **Whoever starts ADO Pulse as an app chooses its arguments and environment, and can read its
  output.** Started by LaunchServices (`open --env … --stdout … --args …`), or by a program that
  disclaimed it, ADO Pulse has its own Full Disk Access (`Attribution.itself`). So nothing a caller
  chooses may decide what it reads with that access, or carry what it read anywhere the caller can
  read: no command-line mode or `--render` runs (`CLI.refusal`), `-key value` arguments don't
  reach its preferences, its standard output and error go to `/dev/null`, and the variables that
  point it at other data are read only through `Attribution.environment`, which is empty then. A
  test fails if code reads the environment anywhere else, until it's checked and listed with its
  reason.
- **On-device summaries only.** Use `SystemLanguageModel.default`, never Private Cloud Compute or a
  cloud model: pull request titles and comments mustn't leave the Mac. Decide in code what matters,
  and give the model one item at a time.
- **Logic goes in `ADOPulseCore`.** Keep it free of UI code and cover changes with tests in
  `Tests/ADOPulseCoreTests`. The app target displays what the engine publishes, and keeps your
  settings in its preferences: test what it keeps there in `Tests/ADOPulseTests`.
- **Use made-up data.** Pull request titles, people's names, comments and repository names from
  your own organizations are private. Don't put them in tests, screenshots, issues or pull requests.
- **The API is lenient here.** Azure DevOps adds fields and policy types over time. When you rely on
  a new field, handle its absence, and add a test with a small made-up sample.

## Pull requests

- Keep each pull request focused, and describe the change users will see.
- Run `make test` and `make demo-check` first. CI also runs them on macOS 15 and macOS 26, packages
  the universal app, signs it as a release would but with a throwaway certificate, and runs it on
  macOS 15 on Apple silicon and Intel.
- Update the README, or [How it works](docs/how-it-works.md), when behavior or settings change.
- For UI changes, include before and after screenshots from `make screenshots`.

## Releasing

Releases are built by GitHub Actions, not on a maintainer's Mac.

Every release is signed with the project's own certificate, so macOS keeps the Full Disk Access
people give ADO Pulse (for pull requests sent in chats) when they update. Before the first release,
once:

1. Run `scripts/make-release-certificate.sh ~/ado-pulse-release-certificate`. It creates the
   certificate, and writes its SHA-1 to `scripts/release-certificate.sha1`; every release is checked
   against it. Commit that file.
2. In **Settings › Environments**, create the `release` environment. Give it a required reviewer,
   who approves each release, and under **Deployment branches and tags**, allow only tags that
   match `v*`.
3. Add the two files the script wrote to that folder as secrets of the `release` environment, named
   after them: `RELEASE_SIGNING_P12` and `RELEASE_SIGNING_P12_PASSWORD`. Not as repository secrets:
   any workflow on any branch can read those, and this key signs apps that keep the Full Disk Access
   people gave ADO Pulse.
4. Keep both somewhere safe, such as a password manager, then delete the folder.

GitHub Free has environments only in public repositories. The certificate is valid for ten years. A
new one makes everyone allow Full Disk Access again, so keep this one; the script refuses to replace
it without `--replace`.

To release a version:

1. Set the new version as `CFBundleShortVersionString` in `Resources/Info.plist`, as three numbers
   such as `0.2.0`. The build sets `CFBundleVersion` to the same value. A release fails unless its
   version is higher than every earlier tag.
2. Add a section for it at the top of `CHANGELOG.md`, such as `## 0.2.0 - 2026-11-30`. It becomes
   the release notes, so write it for users.
3. Push to `main` and wait for CI.
4. Tag the commit and push the tag:

   ```sh
   git tag v0.2.0
   git push origin v0.2.0
   ```

The tag starts the [release workflow](.github/workflows/release.yml). Its first job checks the
version, then builds, checks and tests the universal app on macOS 26 (`scripts/package.sh`), without
the signing key. The second job runs in the `release` environment, so it waits for your approval.
Then it signs the app with the release certificate and checks it (`scripts/sign-package.sh`),
attests the zip's build provenance, and publishes the release with `ADO-Pulse.zip`, its SHA-256 and
the changelog section. Turn on private vulnerability reporting (**Settings › Security**) for
[SECURITY.md](SECURITY.md) too.

The certificate isn't Apple's, and the app isn't notarized, which is why the README explains the
Gatekeeper step. It doesn't update itself yet: users download each release.

## License

ADO Pulse is licensed under the GNU General Public License, version 3 or later. By contributing, you
agree that your contributions are licensed under the same terms.
