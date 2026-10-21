# Contributing to ADO Pulse

## Getting started

You need macOS 15 or later and Swift 6. Xcode works, and so do just the Command Line Tools.

```sh
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
make install       # build the app, copy it to ~/Applications and launch it
make icon          # regenerate Resources/AppIcon.icns
```

[How it works](docs/how-it-works.md) explains where the data comes from and how a pull request's
group is decided.

## Project layout

```text
Sources/ADOPulseCore/   the engine; UI-free, and fully tested
  Auth                  the token provider protocol, and the Azure CLI provider
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
  DemoData              made-up pull requests in every state
Sources/ADOPulse/       the AppKit/SwiftUI app: menu bar, panel, widget, settings, notifications,
                        on-device summaries, command line and renderer
Tests/ADOPulseCoreTests/  Swift Testing suites, including the engine against a stub Azure DevOps
scripts/                app bundling, checking, and the icon
```

## Debugging

The app binary doubles as a command-line tool:

```sh
.build/debug/ADOPulse --dump            # table of every pull request and its status
.build/debug/ADOPulse --json            # the same as JSON, with counts
.build/debug/ADOPulse --watch           # print changes as they happen
.build/debug/ADOPulse --orgs            # your organizations, and the ones with pull requests
.build/debug/ADOPulse --render <dir>    # draw the menu bar with the panel open, and each widget size, to PNGs (light and dark)
```

Add `--demo` to any of them to use the made-up pull requests, or `--org <name>` to read another
organization. They read the app's settings (organizations, what you've seen) but never change them.
`make dump`, `make watch` and `make render` run them from a debug build; `make render` writes your
own pull requests to `render/`, which git ignores.

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
- **On-device summaries only.** Use `SystemLanguageModel.default`, never Private Cloud Compute or a
  cloud model: pull request titles and comments mustn't leave the Mac. Decide in code what matters,
  and give the model one item at a time.
- **Logic goes in `ADOPulseCore`.** Keep it free of UI code and cover changes with tests in
  `Tests/ADOPulseCoreTests`. The app target only displays what the engine publishes.
- **Use made-up data.** Pull request titles, people's names, comments and repository names from
  your own organizations are private. Don't put them in tests, screenshots, issues or pull requests.
- **The API is lenient here.** Azure DevOps adds fields and policy types over time. When you rely on
  a new field, handle its absence, and add a test with a small made-up sample.

## Pull requests

- Keep each pull request focused, and describe the change users will see.
- Run `make test` and `make demo-check` first.
- Update the README, or [How it works](docs/how-it-works.md), when behavior or settings change.
- For UI changes, include before and after screenshots from `make screenshots`.
