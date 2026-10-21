# How ADO Pulse works

## Signing in

ADO Pulse gets bearer tokens from the Azure CLI:

```sh
az account get-access-token --resource 499b84ac-1321-427f-aa17-267ca6975798 --output json
```

The GUID is Azure DevOps's application ID. The CLI answers silently from its own token cache and
refreshes its sign-in by itself, so ADO Pulse never shows a sign-in screen unless the CLI is signed
out. A token lasts about an hour; ADO Pulse reuses it until five minutes before it expires, and asks
again if Azure DevOps rejects it. The token also says who it's for: when you sign in to the CLI as
someone else, ADO Pulse starts over with their pull requests, and what they've seen.

An app started from Finder or as a login item doesn't get your shell's `PATH`, so ADO Pulse looks
for `az` in `/opt/homebrew/bin`, `/usr/local/bin` and the other usual places, then asks your login
shell (`command -v az`). Its runs of `az` turn off the CLI's telemetry and warnings, and each is
limited to a minute: `az` runs in a process group of its own, which is ended at the time limit, and
anything it leaves running that keeps its output open is ended half a second after it exits.

Signing in sits behind a small protocol (`AccessTokenProvider`). A provider using Microsoft's
authentication library (MSAL) can be added once there's an app registration to sign in with.

## Where the data comes from

All requests are GETs to the Azure DevOps REST API (version 7.1):

| Request | When | Provides |
|---|---|---|
| `_apis/connectionData` | once per organization, and again when you sign in as someone else | your identity ID and name |
| `_apis/git/pullrequests?searchCriteria.creatorId=…&status=active` | every refresh | your active pull requests, across all projects |
| `_apis/git/pullrequests?searchCriteria.reviewerId=…&status=active` | every refresh | the ones you review |
| `_apis/git/pullrequests?searchCriteria.creatorId=…&status=completed&minTime=…` | every refresh | yours completed in the Done window |
| `{project}/_apis/policy/evaluations?artifactId=vstfs:///CodeReview/CodeReviewId/{project}/{id}` | per pull request | builds, status checks, reviewer and other policies |
| `{project}/_apis/git/repositories/{repo}/pullRequests/{id}/threads` | per pull request | comment threads, and activity: pushes, votes, reviewer changes |
| `_apis/git/pullrequests/{id}` | when one of yours leaves the active list: five a refresh, the ones not looked up yet first; one that fails is tried again on the next refresh, then less and less often | whether it was completed or abandoned |
| `app.vssps.visualstudio.com/_apis/profile/profiles/me`, `…/_apis/accounts` | finding your organizations | your organizations; then each one is checked for your pull requests, and when none were found because some couldn't be checked (offline, say), it tries again a minute later |

The list endpoints have no "last updated" field, and new comments don't change anything in them,
so a pull request's details (policies and threads, two requests) are fetched on a schedule
(`RefreshPlanner`):

- every pull request without details, which is all of them on the first load, in parallel, four at a
  time;
- then, at most eight others a refresh: changed ones first (a push, a vote, a merge status or draft
  change), then those with a build or check in progress (every minute), the others every three
  minutes, and drafts and idle ones every fifteen.

Requests honor `Retry-After`: when Azure DevOps asks to slow down, nothing is sent until the time it
gave. When nothing can be read (offline, for example), refreshes back off up to ten minutes, and
waking the Mac or getting back online refreshes right away.

Azure DevOps can't push updates to a personal app: service hooks need a project administrator and a
server reachable from the internet. Pull requests and builds take minutes to hours, so a refresh a
minute is plenty.

## How a pull request's group is decided

The [groups table in the README](../README.md#what-the-groups-mean) lists them. In more detail:

**Checks.** Each branch policy becomes a check:

- **Build**: approved is passed, rejected is failed, running is running. A queued build whose
  context says `isExpired` has expired and has to run again; a queued build without a build ID
  hasn't run at all (for example, because it's queued by hand).
- **Status** (posted by another service): rejected is failed; queued means waiting for it.
- **Minimum number of reviewers**, **Required reviewers** and **Proof Of Presence** are about
  approvals.
- **Require a merge strategy** is checked when the pull request is completed, so it doesn't count
  against being ready.
- Other requirements, such as **Work item linking** and **Comment requirements**, are reported as
  rejected until they're met: that means pending, not failed.

Only blocking policies count. A disabled policy is ignored. When a project doesn't let you read its
policies, nobody can tell whether a pull request there is ready: it waits, as **Can't read its
policies**, even when its threads couldn't be read that time. And ready means ready as the pull
request is now: until its policies have been read again after a push or a vote, it waits.

**Your pull requests** are, in order: in **Needs You** if something new needs you; **Idle** if
they're drafts or have had no activity (comments, pushes, votes) for two weeks; **Failing** for a
failed build or status check, merge conflicts or an expired build; **Waiting** while a reviewer
wants changes; **Ready to Complete** when every blocking policy passes (or, without reviewer
policies, someone approved); and **Waiting** otherwise, with what it's waiting for.

**Pull requests you review** are in **Needs You** for something new, **Idle** if they're drafts,
inactive, or you approved or declined them, **To Review** if you haven't voted, and **Waiting** if
you asked the author for changes.

## What counts as new

Azure DevOps has no read or unread state for pull requests, so ADO Pulse keeps its own
(`SeenState`): activity up to a pull request's cutoff counts as seen. The cutoff is when you last
opened the pull request from ADO Pulse (or clicked **Mark as Seen**), or, if that's earlier, three
days before ADO Pulse first ran. Each account you sign in to the Azure CLI with has its own, since
two accounts can see the same pull request: switching back to an account picks up where it left off,
and nothing from the other account is announced.

After the cutoff, these need you:

- a comment by someone else (not a build service or bot) in a thread you've commented in, after your
  last comment there: a **reply**;
- a comment that @mentions you: a **mention**;
- on your pull request, a comment by someone else in a thread you haven't joined: a **comment**;
- a reviewer's "waiting for author" or "rejected" vote on your pull request, while it still stands
  and you haven't pushed since;
- on a pull request you review: being added as a reviewer (or the draft being published) when you
  haven't voted yet, and new commits since your vote.

Approvals are news too: they're announced, but they don't need you.

## Notifications

After each refresh, ADO Pulse compares the new list with the previous one (`NotificationPlanner`)
and announces events it hasn't seen before, as well as your pull requests that start failing,
become ready or complete. Events from before ADO Pulse started aren't announced: they're in the
panel. When there's a lot at once, it posts the three newest and one "more updates" notification.
Changing a setting or time passing never causes a notification. Clicking one opens the comment it's
about, and marks the pull request seen.

## The brief

The brief picks, in code, the newest pull request that needs you, the newest failure and the newest
one that's ready (then more of what needs you, up to three). Items about a comment go to Apple
Intelligence's on-device model one at a time, with the commenter, the title and the comment, and
come back as one sentence such as "Sam asks you to cap the backoff at 30 seconds on …". The others
are plain sentences. Results are kept for as long as the app runs, never block the panel, and fall
back to the plain sentence if the model isn't available or fails. ADO Pulse explicitly uses
`SystemLanguageModel.default`: nothing goes to Private Cloud Compute or any other model.

## Why not a WidgetKit widget?

For the same reasons as [Copilot Pulse](https://github.com/mnsn/copilot-pulse/blob/main/docs/how-it-works.md#why-not-a-widgetkit-widget):
the system budgets how often WidgetKit widgets reload, and building one needs Xcode. ADO Pulse's
widget is a borderless panel the app draws itself, at desktop level.

## Limits

- Pull requests assigned only to a group or team you're in aren't listed: Azure DevOps's reviewer
  search matches you, not your groups.
- Organizations in other Microsoft Entra tenants than the Azure CLI's default can't be read with its
  token.
- A failed build's errors aren't part of a pull request's policies, so the panel names the build
  without saying why it failed.
