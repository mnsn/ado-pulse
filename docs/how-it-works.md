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
someone else, ADO Pulse starts over with their pull requests.

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
| `_apis/git/pullrequests/{id}` | when one of yours leaves the active list: five a refresh, again until it works | whether it was completed or abandoned |
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
policies**. And ready means ready as the pull request is now: until its policies have been read
again after a push or a vote, it waits.

**Your pull requests** are, in order: in **Needs You** if something new needs you; **Idle** if
they're drafts or have had no activity (comments, pushes, votes) for two weeks; **Failing** for a
failed build or status check, merge conflicts or an expired build; **Waiting** while a reviewer
wants changes; **Ready to Complete** when every blocking policy passes (or, without reviewer
policies, someone approved); and **Waiting** otherwise, with what it's waiting for.

**Pull requests you review** are in **Needs You** for something new, **Idle** if they're drafts,
inactive, or you approved or declined them, **To Review** if you haven't voted, and **Waiting** if
you asked the author for changes.

A pull request that would be **Idle** or **Waiting** is in **Answered** instead while there's
something you answered yourself that you haven't seen yet (see below).

## What counts as new

Azure DevOps has no read or unread state for pull requests, so ADO Pulse keeps its own
(`SeenState`): activity up to a pull request's cutoff counts as seen. The cutoff is when you last
opened the pull request from ADO Pulse (or clicked **Mark as Seen**), or, if that's earlier, three
days before ADO Pulse first ran.

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

### Answered

Each of those can also be answered in Azure DevOps (`PRClassifier.answers`): a reply or mention by
your comment after it in the same thread (on your pull request, any comment); a review request by
your vote; new commits since your vote by voting again; a vote that wanted changes on your pull
request by your push; and a link someone sent you by your vote, your comment or, on your pull
request, your push. Voting on a pull request you weren't asked to review adds you as a reviewer
yourself, which doesn't count as a request.

When something that needed you after the cutoff has been answered in the last day, the pull request
is in **Answered**, with what you did ("You approved") and what it answered ("Dana Whitfield sent
this in Teams"), unless it's failing, ready to complete or to review. It isn't counted in the menu
bar, announced, or in the brief. When the panel closes, each pull request it showed in Answered is
marked seen up to when you answered it, not up to the time it closed, so anything that came later
still counts as new.

## Pull requests sent in chats

When you turn on **Pull Requests Sent in Chats**, ADO Pulse reads Notification Center's database,
`~/Library/Group Containers/group.com.apple.usernoted/db2/db`, which keeps the notifications every app
has posted (about the latest hundred per app; for Teams, a couple of days).

- It opens the database with a read-only SQLite connection, for a short read each time, and never
  changes it. Like any SQLite reader, it takes brief shared locks and updates SQLite's shared-memory
  index (`db-shm`) while it reads; neither changes any notification. It reads it when you turn the
  setting on, whenever the database's write-ahead log changes (watched with kqueue, so a new message
  shows within a second), when you open the panel, and once a minute.
- Each notification's title, subtitle and text are searched for links to pull requests:
  `dev.azure.com/{org}/{project}/_git/{repo}/pullrequest/{id}` and the older
  `{org}.visualstudio.com/…/pullrequest/{id}`.
- In Teams, only chat messages count: the notification has a reply box and names a chat. Channel
  posts and reactions don't. The sender is the title in a 1:1 chat and comes before the colon in a
  group chat. In other apps, the title is taken as the sender.
- Emails from Azure DevOps itself and ADO Pulse's own notifications are skipped.
- It keeps only the link, the app, the sender, the time and, for Teams, the chat and message IDs (to
  open the message). Never the message itself. Links are kept for two weeks, and forgotten when you
  turn the setting off.

A pull request that isn't in your lists (you're not its author or a reviewer) is read with a GET by
its ID, and listed only while the link needs you. A link needs you until you open the pull request
from ADO Pulse, vote or comment on it after the message (or push to it, if it's yours), it closes,
or a week passes. Once you've voted or commented, it's in **Answered** until you've seen that.
Links aren't announced: the app they came in already did.

macOS protects that database, so ADO Pulse needs Full Disk Access, which it asks for when you turn the
setting on, and macOS ties that access to the app's code signature. A build from source is signed ad
hoc, a signature that changes with every build, so access has to be allowed again after each one.
macOS keeps the requirement of the build you allowed, and turning the switch off and on keeps it too:
remove ADO Pulse from the list, or run `tccutil reset SystemPolicyAllFiles com.asaf.ADOPulse`, and add
it again.
`make signing-identity` instead creates a self-signed certificate, and builds signed with it keep the
same designated requirement, so access survives rebuilds. It imports the certificate's key with
`scripts/signing-key.swift`, so that no app may use it without asking, codesign and security included,
and nothing can export it, not even an app you allow: macOS asks for your login password each time a
build is signed. (`security import -T ""` trusts no app either, but its `-x` has no effect on a
PKCS #12, whose key could then be exported.) A key that some app could use without asking (Always
Allow) would let anything running as you sign its own code as ADO Pulse, and get the Full Disk Access
you gave it, so each build first reads the key's access list, which asks nothing, and won't sign with
such a key. Releases are signed with the project's own certificate, whose key the release workflow
imports the same way, for codesign only (see "Releasing" in [CONTRIBUTING.md](../CONTRIBUTING.md)), so
access survives updates.

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

- Pull requests sent in chats are only as complete as Notification Center: a message you saw in the
  app before it posted a notification, or one older than the notifications it keeps, isn't there.
- Pull requests assigned only to a group or team you're in aren't listed: Azure DevOps's reviewer
  search matches you, not your groups.
- Organizations in other Microsoft Entra tenants than the Azure CLI's default can't be read with its
  token.
- A failed build's errors aren't part of a pull request's policies, so the panel names the build
  without saying why it failed.
