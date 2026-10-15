# Handover: Kotoba Collab fixes from the fork into upstream PRs

For the agent who turns the fork's collaboration work into pull requests on `hattoriai/kotoba`.
Written 2026-10-15 by the agent who built it (with Andreas Ronge, the fork's owner).

**This directory (`handover/`) is not for upstream.** It names the downstream application that
drove the work; no PR branch may contain it, and no PR, commit, CHANGELOG entry, comment, test,
dev page or guide may name that application or depend on it. A PR may describe the
*requirements* in general terms (below, "What the downstream app needs"), never the app.

## Where things are

| What | Where |
|---|---|
| The fork | `git@github.com:andreasronge/kotoba.git` (`origin`), branch `feat/collab-shared-socket` |
| Upstream | `git@github.com:hattoriai/kotoba.git` (`upstream`), `main` at `26ebed8` (Release 0.2.1, #37) |
| The fork's work | 3 commits on `26ebed8`: `5e92256`, `e91f02a`, `d1d10a8` (below) |
| The downstream spike (private) | `~/projects/tyra/ska-collab`, branch `spike/kotoba-collab`, depends on this checkout by path (`{:kotoba, path: "../../kotoba"}`) |
| Benchmark | `handover/journal_bench.exs` (`mix run handover/journal_bench.exs`) |

Commands (this repo):

- `mix precommit`: warnings as errors, format, `credo --strict`, tests (574 pass on the fork tip).
- `mix test.e2e` (Playwright, all three engines; `E2E_BROWSERS=chromium` for one, `E2E_PORT` for
  another port than 4098). The collaboration specs: `cd e2e && npx playwright test
  collaboration collaboration-many submit two-editors` (211 passed on the fork tip, 3 engines).
- The dev page the specs use: `mix dev`, then `/collab` and `/collab/many` (`dev.exs`; query
  params: `count`, `join=visible`, `park_after`, `text=1`, `nodes`, `scroller`, `badcollab`,
  `deny`, `required`, `repeat`, `name`, `document`; a nested LiveView variant and a "Crash this
  LiveView" button, `#many-crash`).

## The problem

Kotoba 0.2's collaboration (`Kotoba.Collab`, #33) works for one or two shared editors per page.
A page of **many** shared editors (a document made of 20+ text blocks, each its own shared
document) broke in four ways:

1. **Lost keystrokes (a bug in 0.2.1).** A remote transaction re-renders the shared editor and
   restores its selection; restoring it in an editor *without focus* also set the DOM selection,
   which moved the focus there. A colleague typing in block 7 took the caret out of block 3: the
   next keystrokes went to the wrong block or were lost.
2. **One WebSocket and one eager join per editor.** 20 editors = 20 sockets and 20 joins on load,
   all repeated on every reconnect (a deploy reconnects every tab at once).
3. **Idle tabs and reconnects.** Credentials live 5 minutes (`max_age: 300`); Phoenix's own
   channel rejoin reuses the original join params, so a tab idle or offline past that rejoined
   with expired credentials, got refused, and retried the same credentials. Retries had no
   backoff of their own.
4. **Form submit before the editors were ready.** A submit right after load, or before an editor
   had joined (or after it changed since its flush), posted no accepted revision for it: the
   submitted content missed what was typed.

Found while testing in the downstream app, then reproduced on Kotoba's own dev page:

5. **Status attribute lost on re-render.** LiveView merges the data attributes of a
   `phx-update="ignore"` element from the server's render. The render has no
   `data-collab-state`, so after a nested LiveView crashed and rejoined (or any patch of the
   element) the editor had no state attribute until the next status change. Finding: on a child
   LiveView crash the hooks are *not* remounted (they get disconnected/updated/reconnected) and the
   channels stay joined.

## What the downstream app needs (may be quoted in PRs, without naming the app)

- Documents of many text blocks, each a shared editor; typically 8 on screen out of 20+.
- About 1,000 concurrent editing sessions (one tab per organization, a keystroke per second) on
  one node, with Postgres; no Redis.
- Nothing typed is lost across a LiveView crash, a nested LiveView crash, a deploy, an idle or
  offline tab, or a submit right after load.
- A form submit (publish) contains every accepted keystroke of every editor in the form.
- Nested LiveViews (a child LiveView holding editors inside a parent page).
- Application-defined access that can change mid-session (revocation), checked cheaply.

## The solution on the fork

### `5e92256` Collab: a colleague's edit no longer takes the caret from another editor

`assets/src/collab/binding.ts`: an editor without focus restores its selection in the model only
(Lexical's `skip-dom-selection` tag). Adds the `/collab/many` dev page and
`e2e/specs/collaboration-many.spec.ts`. Small, self-contained: **PR 1**.

### `e91f02a` Collab: the editors of a page share one socket, and can join on visibility

Large (13 files, +1,992/-126; the spec alone is 966 lines). It mixes four things that should be
separate PRs (see the plan). What it does:

- **Shared socket** (`collab/sockets.ts`): the editors of a page lease one Phoenix socket per URL,
  one channel each; a second editor of the same document on the page gets its own socket
  (Phoenix holds one channel per topic per socket). A frozen draft leaves its channel.
- **Lazy joins** (`Kotoba.Collab.token(..., join: :visible, park_after: ms)`; default `:eager`
  unchanged): join when the editor comes within 200 px of the window *and of every clipping
  box*, is focused, or has edits to send (restored unsent edits and waiting inserts included);
  leave after `park_after` (30 s) off screen or in a hidden tab with nothing to send or confirm.
  Visibility is measured on IntersectionObserver callbacks, scroll, resize and a timer (a page
  that renders no frames gets no callbacks). Until its first join an editor shows its field's
  saved text read-only; a server `insert_node` waits for that join (it used to be replaced by the
  snapshot).
- **The connection state machine** (`collab/connection.ts`): idle, waiting for the socket,
  renewing, joining, joined, backing off, frozen. Every event goes through it; whether a channel
  is wanted is decided in one place (the client's `demand()`); Phoenix never retries a channel by
  itself. Credentials older than 4 minutes are renewed (one renewal at a time, once the LiveView
  is connected) before a join, a rejoin after a disconnection, a channel retry and after a join
  refused as expired. Errors and timeouts back off 1 s doubling to 30 s. A refused renewal
  freezes the draft (with its download, as a refused join does).
- **The form coordinator** (`forms.ts`, in the core bundle, since editors register at mount): it
  owns a form's shared editors from mount (starting, failed, started) and the whole submit:
  waits for every editor to start (node modules, extensions, the local backup) and join, keeps
  every editor and its toolbars read-only (also against the app's `set_readonly`) until all have
  a confirmed revision, flushes in rounds those added or changed meanwhile, lets every flush
  settle before it submits or reports a failure, resubmits only with a submit button still in
  the form, refuses the form while one of its editors could not start, and leaves out an editor
  removed meanwhile.
- Unreadable credentials no longer stop the LiveView's join for the whole page: logged, and the
  form refuses to submit until that editor is removed.
- `guides/collaboration.md`, `lib/kotoba/collab.ex` (`token/3` options, validated),
  `test/kotoba/collab/channel_test.exs`, CHANGELOG `[Unreleased]`.

### `d1d10a8` Collab: an editor keeps its data-collab-state when its LiveView renders it again

`Collaboration.showStatus()` (was the private `updateStatus`); the hook's `syncAttributes()`
(from `updated()`) calls it, and so does the end of the collaboration's start. Spec: a nested
LiveView that crashes and rejoins keeps its editors and their status, and the parent's editor
stays (failed before the fix: state `""`; 9/9 across the three engines after). The dev page got
the crash button and shows its mount count. **PR 2.**

## Choices made, and why

- **Two owners instead of patches.** The first versions handled connection and submit events
  where they arrived; codex review kept finding a new race in each round (rejoin with old
  credentials, a retry reopening a parked editor, a submit racing a join, a flush failing while
  others were in flight). The root cause was that no single component owned the channel's state
  or the submit. The state machine and the coordinator ended the rounds. Keep them as the unit of
  review; don't split a state machine across PRs.
- **Disable Phoenix's channel rejoin** rather than patching its params: Phoenix rejoins with the
  original (expired) credentials.
- **One socket per URL, a second socket for a duplicate topic**, not one per editor and not
  multiplexing one topic: Phoenix's one-channel-per-topic rule.
- **200 px margin, every clipping box, a timer fallback**: an editor inside a scrolling box can be
  in the window and still hidden; background tabs and headless pages render no frames.
- **Renew at 4 minutes** against the 5-minute `max_age`, one renewal in flight per page, only with
  the LiveView connected (a renewal goes through `kotoba:collab_token`).
- **Saved text read-only until the first join** so a lazy editor never shows empty, and never
  takes input that isn't on the shared document yet.
- **The coordinator in the core bundle**, not the collab bundle: editors register with it at
  mount, before the collab bundle has loaded.
- **`:eager` stays the default**: existing apps see no change unless they pass `join: :visible`.

## Experiments and numbers

All on one 10-core MacBook, client, server and Postgres together.

**Kotoba's document cost grows with history** (`handover/journal_bench.exs`, one 480-character
block typed a character per commit, re-run today):

| Commits so far | `Document.commit/3` | JSON encode of the state | State size |
|---:|---:|---:|---:|
| 100 | 0.4 ms | 3.8 ms | 481 KB |
| 1,000 | 0.8 ms | 12 ms | 1.3 MB |
| 2,000 | 1.4 ms | 26 ms | 2.2 MB |

About 0.9 KB per keystroke: the `"transactions"` journal is never compacted and every character
is an atom with 16 attributes. The 16 MB `max_bytes` refuses a block after about 17,000
keystrokes. The DocServer persists the whole state through `Store.save/5` on every commit, and
the size check JSON-encodes it.

**Load** (the downstream app on the fork, an ETS store, one tab per organization, 8 of 20 blocks
joined lazily, a character and a caret move per second per tab):

| Concurrent tabs | App's access check cached | Keystrokes/s (target) | p95 | What stops it |
|---:|---|---:|---:|---|
| 100 | no | 100 (100) | 54 ms | - |
| 250 | no | 251 (250) | 14 ms | - |
| 500 | no | 299 (500) | 2.1 s | the Ecto pool (10) |
| 1,000 | no | 255 (1,000) | 3.5 s | the Ecto pool |
| 500 | yes (60 s) | 499 (500) | 139 ms | - |
| 1,000 | yes (60 s) | 367 (1,000) | 565 ms | the DocServers (96% of reductions) |

- `Kotoba.Collab.Channel` calls the app's `authorize/3` on join, on **every incoming message and
  every outgoing broadcast per peer**. The app's check is 8 queries; that made about 4 checks and
  31 database transactions per keystroke, 9,800 queries/s, each waiting ~58 ms for a pool
  connection while Postgres used under one core. Cached in the app, 0.3 per keystroke.
- With access cached, the DocServers are the limit: the whole-state encode per commit above.
- Memory at 500 tabs: DocServers 4.4 GB (4,000 documents), websocket processes ~2.5 MB each.
  The in-memory store (one process) reached 4.6 GB at 500 tabs and stopped; an ETS store fixed
  that for the test.
- Connecting 1,000 tabs (8 channels each, 100 tabs/s) took 100 s; the 95th-percentile channel
  join waited 65 s: each join loads and seeds a DocServer.
- The shared socket and lazy joins are what make these numbers possible at all: eager joins
  would be 20 channels and 20 sockets per tab.

## The plan: PRs

Each PR from its own branch off `upstream/main` (stacked only where noted), its own spec (cut from
`collaboration-many.spec.ts`, only the tests for that change), its CHANGELOG `[Unreleased]` entry,
the guide where the API changes, `mix precommit` and `mix test.e2e` (three engines) passing on
that branch alone, and codex review until no P1/P2 remains. Title and description in upstream's
style (see #33, #37: a plain title, a prose summary of the change, then a "Validation" paragraph
with the test counts). PR descriptions end with your session's attribution line.

| # | PR | Contents | Depends on |
|---|---|---|---|
| 1 | Fix: a colleague's edit takes the caret from another shared editor of the page | `5e92256`; the `/collab/many` page (eager join only) and the caret spec | - |
| 2 | Fix: a shared editor loses `data-collab-state` when its LiveView renders it again | `d1d10a8`; the nested-crash spec. Needs a nested LiveView on the dev page: add a minimal eager one here if PR 5 isn't merged | 1 |
| 3 | Fix: a form submit posts no accepted revision for editors not started or joined | `forms.ts` (the coordinator), its hook wiring, the unreadable-credentials fix; the submit specs that don't need parked editors | - (or 1, for the dev page) |
| 4 | Fix: an idle or offline editor rejoins with expired credentials | `connection.ts` (the state machine), renewal and backoff; `Lease` as a one-socket-per-editor stub until PR 5; the renewal/backoff/freeze specs | - |
| 5 | Shared editors of a page share one socket and can join when visible | `sockets.ts`, `join: :visible`/`park_after` in `token/3`, the visibility tracking, saved text until the first join, `insert_node` waiting; the guide; the parking/visibility specs | 4 (and 3 for "a form publishes parked editors") |

Suggested spec split (test titles in `collaboration-many.spec.ts`; check each against the code):

- PR 1: "a colleague's edit in another editor of the page leaves the caret where it is".
- PR 2: "a nested LiveView that crashes and joins again keeps its editors and their status...".
- PR 3: "a submit right after the page loads waits for every editor", "...keeps every editor
  locked until all of them have joined and flushed", "...waits for an editor still loading its
  node modules", "...waits for its only editor...", "an editor removed while it starts / opens
  its local backup no longer holds the form's submit", "...keeps the toolbars locked too",
  "a failed flush keeps the other editors locked...", "an editor added while the others flush...",
  "an editor changed by the server after its flush...", "an editor whose flush failed and that is
  removed...", "a form with a shared editor that could not start refuses to submit", "removing a
  started editor keeps a later editor that could not start...", "a held submit whose button is
  gone...", "a resubmit stopped by the browser's validation...", "an editor whose credentials
  cannot be read refuses the form's submit...", "the app making an editor writable during a
  submit...", "an editor that fails to start while the form submits refuses the submit".
- PR 4: "a rejoin after a long disconnection renews the credentials first", "an editor opened
  while offline renews old credentials...", "a channel error with old credentials renews them...",
  "a join refused as expired renews once...", "...whose renewal is refused freezes the draft...",
  "old credentials whose renewal is refused freeze the draft...", "a joined editor whose periodic
  renewal is refused freezes the draft", "a channel retry whose credentials grow old during the
  backoff...", "typing while a channel retry waits does not join before the backoff", "joins
  refused as expired again and again after renewals are paced...", "a submit with the
  collaboration socket down gives up...", "an editor's status follows its connection...",
  "a server insert does not change a frozen draft".
- PR 5: the rest ("share one socket", "a second editor of the same document gets its own
  socket", the `join: :visible` / park / hidden tab / clipping box / scrolling box / reload /
  offline-and-parked / nested-share-socket / nested renewal / insert-waits-for-join tests, "a
  parked editor renews old credentials before it joins again").

PR 5 is a design change; say in its description that the approach is open to discussion. If
upstream prefers another shape, ask Andreas before reworking the downstream app's use of it.

**Before opening any PR:** the stack must equal the fork. With PRs 1-5 applied in order on
`upstream/main`, `git diff feat/collab-shared-socket <stack tip> -- . ':!handover'` is empty (or
every difference is a deliberate cleanup, listed in the PR). Then point the downstream spike at
the stack tip (it uses this checkout by path) and run its collab journeys:
`cd ~/projects/tyra/ska-collab && env -u PHX_SERVER -u DATABASE_URL -u POOL_SIZE
MIX_TEST_PARTITION=_collab E2E_PORT=4112 mix test.e2e test/e2e/collab_spike_test.exs` (4 pass
today). Don't change the downstream repo.

Opening them: from branches pushed to the fork (`origin`), `gh pr create -R hattoriai/kotoba
--head andreasronge:<branch>`. Andreas has asked for upstream PRs; confirm with him once, with the
list of PR titles, before the first `gh pr create`.

## The plan: issues (not built yet)

These change Kotoba's server and store contract, so they go upstream as issues with the numbers
above, for the maintainer to agree on a design first. Link the benchmark to #13 ("Add repeatable
large-document editing benchmarks"). In the app-neutral words:

- **K1 Bounded state, incremental persistence.** The store gets each accepted transaction
  (`append`) and a periodic snapshot (`checkpoint`), after which older transactions and receipts
  go (kept for a window long enough for a reconnecting tab's pending ids); attribute-less atoms
  store no defaults; the size check counts bytes as they change instead of encoding the state;
  tombstones are reclaimed only when no channel is joined, so no connected replica holds a caret
  or undo step on a reclaimed anchor. Requirement as a measured bound: one 500-character paragraph,
  continuously joined, typed and deleted for 10,000 transactions, commit and append under 2 ms
  each at the end.
- **K2 Authorization once per join, then on the app's events.** `authorize/3` on join; per
  message and per broadcast only through a callback the app can make cheap; unknown messages
  passed to the app (`handle_access/2`) so an access change can stop a channel.
- **K3 A reset API fenced by the store's epoch.** An app that replaces or removes a document's
  content outside collaboration writes the new epoch in its own transaction; a DocServer's next
  append fails the epoch compare; `Kotoba.Collab.reset/2` then only notifies (stop, tell the
  tabs, freeze pending work with its download).
- **K4 Drafts outlive their editor.** Pending work of a removed editor stays (IndexedDB, and the
  page's memory when IndexedDB is unavailable) and `Kotoba.Collab.orphans()` lists it for a
  page-level notice; it goes only when the user discards it (a download can be cancelled).
- **K5 The page owns pending work, not the editor.** The shared-socket registry keeps clients by
  document id; a removed editor detaches instead of disposing, a client with pending work stays
  headless until acknowledged, a remounted editor reattaches (no Web Lock handoff within the
  page); `Kotoba.Collab.flushAll(prefix)` flushes a document's clients, skipping recovery-only
  ones. Builds on PR 5.

## Known residuals

- A patch arriving during the collaboration's start isn't directly tested (codex, d1d10a8 review).
- `collaboration-many.spec.ts` uses short `park_after` values and timers; watch for flakiness on
  WebKit when splitting it.
- The downstream measurements used an ETS store, not a durable one; K1's numbers on a durable
  store are not measured yet.
