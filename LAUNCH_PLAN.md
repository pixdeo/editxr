# editxr Launch Plan — 1.4.0 (Windows + Obsidian-style linking)

**Type:** Major-update launch · **Budget:** Organic only · **Reach:** pixdeo blog + X (otherwise cold)
**Target launch day:** Wed, July 1, 2026 (fallback: Tue, July 7) · **Plan created:** 2026-06-21

Channels are tuned for a free, open-source terminal tool — not the App Store.
The big day-one moments are **Show HN** + **Product Hunt**, amplified by Reddit,
Lobsters, dev newsletters, and a build-in-public X thread off pixdeo.com.

---

## The angle (what this launch is *about*)

Lead with the story, not the feature list. Two hooks, pick the dominant one per channel:

1. **"Obsidian in the terminal"** — wikilinks, backlinks, `[[link]]` navigation,
   live Markdown rendering. Best for Reddit (r/ObsidianMD, r/commandline) + PH.
2. **"A native Markdown editor that runs everywhere now — including Windows"** —
   zero deps, instant open, one binary, macOS/Linux/Windows. Best for Show HN + r/swift.

One-liner to reuse everywhere:
> editxr — a WYSIWYG Markdown editor for the terminal. Renders as you type, follows
> `[[wikilinks]]` like Obsidian, edits sections with AI inline diffs. 100% Swift, zero
> deps, instant. macOS, Linux & Windows.

---

## Pre-launch checklist (now → June 30)

### Assets (most already done — verify, don't rebuild)
- [x] Landing page live (committed)
- [x] "Obsidian in the terminal" blog post (committed) — schedule/publish for launch morning
- [x] Demo GIFs: render, ai, links, themes, focus, raw, find, open
- [x] Homebrew tap (`brew install pixdeo/tap/editxr`)
- [x] Signed & notarised macOS universal + Linux x86_64/aarch64 + Windows x64 binaries
- [ ] **Cut & tag the 1.4.0 release** with all platform binaries attached (do this 2–3 days early so installs work on launch day)
- [ ] Verify `curl … install.sh | bash` works clean on a fresh macOS, Linux, and Windows box
- [ ] One 20–30s **screen-recorded demo video** (not just GIFs) for PH + X — show: type Markdown → renders live → `[[link]]` jump → AI section diff. Loop-friendly.
- [ ] README top: confirm the first 3 lines sell it in <10 seconds (they do)

### Channel prep
- [ ] **Product Hunt:** create the listing as a draft — tagline, gallery (GIFs + the video), first comment (maker story), topics: Developer Tools / Open Source / Productivity. Line up a hunter or self-post.
- [ ] **Show HN:** draft the title + first comment (see Copy bank below). No marketing speak.
- [ ] **Reddit:** pick the 4 subs, read each rule page, draft a *different* post per sub (no copy-paste): r/commandline, r/swift, r/ObsidianMD, r/opensource (r/programming optional, strict).
- [ ] **Lobsters:** confirm you have an account / invite (it's invite-only — ask in your network now if not).
- [ ] **Newsletters/directories — submit ahead (lead times vary):**
  - [ ] Terminal Trove (terminal tools directory)
  - [ ] Console.dev (dev tools newsletter — submit form)
  - [ ] Changelog News (submit)
  - [ ] Add to relevant `awesome-*` lists via PR: awesome-cli-apps, awesome-swift, awesome-markdown, awesome-tuis
- [ ] **X:** draft the build-in-public launch thread (5–7 posts) + a standalone "it's live" post with the video.

### Logistics
- [ ] Be free the entire launch day to answer HN/PH/Reddit comments within minutes — response speed is the single biggest lever on a dev-tool launch.
- [ ] Prep a short FAQ (Why not VS Code/nvim? Does it work over SSH? Windows really? Which AI/does it need a key? Telemetry? — answer: none).
- [ ] Set up basic install/traffic visibility: GitHub release download counts, repo traffic/stars, pixdeo.com analytics, Homebrew tap install analytics if available.

---

## Launch day — Wed July 1 (times in your local tz, aim for US-morning overlap)

**~06:00 PT / your morning:**
- [ ] Confirm 1.4.0 release is live with all binaries; install one-liner works.
- [ ] Publish the "Obsidian in the terminal" blog post.
- [ ] **Product Hunt goes live at 00:01 PT** — PH ranks on full-day votes, so launch it at the day's start, not your morning. (If you can't be up, schedule it and front-load your network.)
- [ ] **Post Show HN** (HN rewards US morning, ~8–10am ET). Title: see Copy bank.
- [ ] Post the X launch thread + pinned "it's live" post with the demo video.

**Throughout the day:**
- [ ] Stagger Reddit posts (don't fire all 4 at once — space 1–2 hrs, lead with r/commandline or r/ObsidianMD). Each post unique to its sub.
- [ ] Reply to **every** HN/PH/Reddit comment fast and substantively. Engineers reward the maker showing up.
- [ ] If Show HN hits the front page, don't re-post elsewhere in a way that looks like vote-brigading.
- [ ] Share milestones on X ("front page of HN", "#3 on Product Hunt", "1k stars").

**Evening:**
- [ ] Thank early adopters + first contributors/issue-filers publicly.
- [ ] Triage GitHub issues fast — a quick first-day fix + re-release is great signal.
- [ ] Note what resonated (which hook, which sub) to double down tomorrow.

---

## Week 1 (July 1–8)

- [ ] Keep replying to every comment/issue across all threads for 48–72h (HN/Reddit threads stay live).
- [ ] Daily X post: a feature spotlight GIF, a user quote, or a milestone.
- [ ] Submit to any newsletters/directories that didn't make the pre-launch cut.
- [ ] Lobsters post if not done day-one (it's lower volume, fine to stagger).
- [ ] Ship a small 1.4.x with the top day-one fix; "fixed X you reported" posts well.
- [ ] If r/ObsidianMD lands well, consider an Obsidian-forum / Discord share — that crowd loves terminal+linking.
- [ ] Write a short retro on pixdeo.com ("what launching a terminal editor on HN taught me") — build-in-public compounds.

## Month 1

- [ ] Turn the strongest hook into an evergreen pixdeo post + pin the repo.
- [ ] PR into the `awesome-*` lists that didn't merge yet; ask happy users to star.
- [ ] Plan the next feature-led mini-launch from the roadmap (sidebar/backlinks panel, inline images) — each is its own Show HN-able moment.
- [ ] Reach out to YouTubers/streamers in the terminal/dotfiles/Obsidian niche with the binary + a 2-line pitch.

---

## Channels — full distribution list

Show HN is a lottery; Reddit + niche communities are where editxr's people are.
Ordered by fit. ⭐ = highest ROI, do these first.

### A. PKM / Obsidian — your strongest untapped angle ("Obsidian in the terminal")
- [ ] ⭐ **forum.obsidian.md** — Share & showcase section
- [ ] ⭐ **Obsidian Discord** — share in the relevant channel
- [ ] ⭐ **r/PKMS** — high fit, receptive
- [ ] **r/Zettelkasten**
- [ ] **r/ObsidianMD**
- [ ] **r/Markdown** — small but exact

### B. Dev-tool launch platforms (PH alternatives)
- [ ] ⭐ **Devhunt.org** — "Product Hunt for developer tools"
- [ ] **Product Hunt** — still worth it, not done yet
- [ ] **Peerlist Launchpad**
- [ ] **Uneed.best**
- [ ] **TinyLaunch**
- [ ] **MicroLaunch**

### C. Terminal / dev directories & newsletters
- [ ] ⭐ **Terminal Trove** — dedicated terminal-tools directory, perfect fit
- [ ] **Console.dev** — dev tools newsletter (beta/new section)
- [ ] **Changelog News** — submit
- [ ] **TLDR** newsletter — submit
- [ ] **Pointer.io** — submit
- [ ] **awesome-list PRs:** awesome-cli-apps, awesome-tuis, awesome-swift, awesome-markdown
- [ ] **r/coolgithubprojects**, **r/github**

### D. Reddit — niche subs (Reddit is already working, double down)
- [ ] ⭐ **r/unixporn** — terminal GIFs crush here; post render/themes GIF, not a pitch
- [ ] **r/neovim**
- [ ] **r/vim**
- [ ] **r/zsh**
- [ ] **r/commandline** (if not already)
- [ ] **r/opensource**
- [ ] **r/SideProject**

### E. FOSS social & high-signal aggregators
- [ ] ⭐ **Fosstodon / Mastodon** — `#FOSS #cli #terminal #opensource`, generous boosts
- [ ] **Lobsters** — invite-only, top technical audience (secure an invite)
- [ ] **Tildes.net** — small, technical, high signal
- [ ] **Bluesky** — growing dev community

### F. Swift-specific
- [ ] **Swift Forums** (forums.swift.org) → "Related Projects" — "100% Swift, zero deps, runs on Windows" is news here
- [ ] **iOS Dev Weekly** — submit
- [ ] **Swift Weekly Brief** — submit

### G. YouTube creators — highest mid-term leverage (DM binary + 2-line pitch)
- [ ] ⭐ **No Boilerplate** — makes Obsidian + Markdown + terminal videos; perfect fit
- [ ] **typecraft**
- [ ] **Dreams of Code**
- [ ] **DistroTube**

> **Pick-5 this week:** Obsidian forum + r/PKMS · Devhunt · Terminal Trove · r/unixporn (GIF) · DM No Boilerplate.

---

## Copy bank

**Show HN title** (no hype, factual, the surprise is "terminal + Obsidian + Windows"):
> Show HN: editxr – a WYSIWYG Markdown editor for the terminal (Swift, zero deps)

**Show HN first comment** (be the maker, lead with the "why"):
> I wanted Obsidian's [[wikilinks]] and live-rendered Markdown, but in a terminal that
> opens instantly and works over SSH. editxr renders Markdown in place as you type
> (the line you're on stays raw), follows `[[links]]` and backlinks across notes, and
> can hand a section to an LLM and show the change as an inline diff before it lands.
> It's a single native Swift binary, no dependencies, and as of 1.4.0 it runs on
> macOS, Linux and Windows. MIT. Happy to answer anything — what would you want from a
> terminal Markdown editor?

**Product Hunt tagline:**
> Obsidian-style Markdown editing, in your terminal

**X launch post:**
> editxr 1.4.0 is out 🎉
> A Markdown editor that lives in your terminal — renders as you type, follows
> [[wikilinks]] like Obsidian, edits sections with AI inline diffs.
> 100% Swift · zero deps · opens instantly · macOS, Linux & now Windows.
> [demo video] [link]

**Reddit angle per sub:**
- r/commandline → "renders as you type, zero deps, opens instantly" (TUI craft)
- r/ObsidianMD → "[[wikilinks]] + backlinks + link graph, but in the terminal"
- r/swift → "100% Swift, no dependencies, now compiles & ships on Windows too"
- r/opensource → MIT, single binary, the porting story (PORTING_TO_WINDOWS.md)

---

## Success metrics (organic, free tool — measure attention + installs, not revenue)

| Window | Realistic | Stretch |
|---|---|---|
| **Day 1** | Show HN front page (top 30) for a few hrs; PH top 10 in Dev Tools; 200–500 new stars; 300+ install-script/Homebrew pulls | HN top 10; PH #1 Dev Tools; 1k+ stars |
| **Week 1** | 800–1,500 stars; listed in 1–2 newsletters/directories; first outside contributors | 3k+ stars; a YouTuber/newsletter feature |
| **Month 1** | 2k+ stars; steady weekly installs; merged into 2–3 awesome-lists; next mini-launch queued | 5k+ stars; recurring inbound issues/PRs = real community |

> Star counts are vanity-ish but the standard pulse for OSS dev tools. The metric that
> actually matters: **daily installs holding up after the launch spike** + issues/PRs
> from people who weren't in your network.
