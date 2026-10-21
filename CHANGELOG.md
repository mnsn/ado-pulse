# Changelog

## Unreleased

Fixes:

- A pull request in a project whose policies you can't read no longer shows as ready to complete;
  it waits, as "Can't read its policies". Nor does one whose policies haven't been read again since
  its latest push or vote.
- A vote from a reviewer who was removed from a pull request no longer keeps it in Needs You.
- A notification opens the comment it's about, rather than the one the panel would.
- Abandoned pull requests reach Done even when many leave the list at once, or looking one up fails.
- Signing in to the Azure CLI as someone else shows their pull requests, rather than the first
  person's.
- Starting ADO Pulse while offline no longer leaves it with no organizations to watch: it tries
  again.
- A run of the Azure CLI can't hang refreshes: what it leaves running is ended.
- `--demo` works with `--orgs` and `--watch`, rather than reading your own organizations.

## 0.1.0 - 2026-10-21

The first release.

- **Menu bar**: the ADO Pulse icon with a count for each group you can act on: pull requests that
  need you (a reply, a mention, a comment, a review request, new commits since your vote, or a
  reviewer waiting for you), that are failing (a build or check, merge conflicts, an expired build)
  and that are ready to complete. Click it to see every pull request by group.
- **A brief by Apple Intelligence**: one sentence each for the newest thing that needs you, the
  newest failure and the newest pull request that's ready, written on your Mac by its on-device
  model.
- **Notifications** for new replies, mentions, comments, review requests, votes and commits, and for
  your pull requests failing, becoming ready or completing.
- **One click to the comment**: click a pull request to open it in your browser, at the thread that
  needs you.
- **Desktop widget**: an optional widget-style panel in three sizes, on the desktop behind your
  windows or floating above them.
- **No token to manage**: signs in with the Azure CLI, and finds the organizations where you have
  pull requests.
- **Private and read-only**: every request to Azure DevOps is a GET, summaries never leave your Mac,
  and it collects no data.
- A universal app for Apple silicon and Intel Macs with macOS 15 or later. Summaries need Apple
  Intelligence, on macOS 26 or later.
