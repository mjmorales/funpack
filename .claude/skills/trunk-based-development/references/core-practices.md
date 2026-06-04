# Core Practices

Distilled from trunkbaseddevelopment.com (github.com/paul-hammant/tbd): Introduction, Five-minute overview, Context, Styles & Trade-offs, Committing straight to the trunk, Short-Lived Feature Branches, Continuous Integration, Continuous Code Review, Continuous Delivery, Observed habits, Deciding factors.

## Definition

A source-control branching model: developers collaborate on code in a single branch called trunk (`main` in the git community), resist any pressure to create other long-lived development branches by employing documented techniques, and thereby avoid merge hell and a broken build.

Claims:

- Do trunk-based development instead of GitFlow and other models featuring multiple long-running branches.
- Either commit/push directly to trunk (very small teams) or use a pull-request workflow — as long as feature branches stay short-lived and are the product of a single dev workstation (solo, pair, or mob). Bigger, more all-encompassing changes use feature flags, branch by abstraction, and "don't break the build".
- Teams flex up or down in size on the trunk without affecting throughput or quality (Google: 35,000 developers and QA automators in one monorepo trunk).

"Developers" throughout includes QA-automators of the same buildable thing. "Trunk" is just the branch a team focuses development on; it need not literally be named trunk.

## Distance — why a single branch

"Branches create distance between developers and we do not want that" — Frank Compagner, Guerrilla Games.

The problematic distance is to code not yet in the single shared branch, which might:

- break something unexpected once merged,
- be difficult to merge in,
- hide duplicated work until merge time,
- hide incompatibility/undesirability that does not break the build.

Tangible forms: late merges of development older than a couple of days (especially difficult ones), and a breaking build that lowers team throughput and diverts resources. Trunk-based development reduces this distance to the minimum.

## The layer cake (context)

Each layer is a prerequisite for the one above:

1. **Solid development infrastructure** — VCS installed; workstations able to build/test/run the app; Infrastructure as Code in the DevOps era.
2. **Trunk-based development** — the branching model and an individual contributor's obligations to it.
3. **Continuous Integration** — committing to trunk at least daily makes real CI possible; machines add early warnings.
4. **Continuous Delivery** — always-releasable trunk extended with automatic deployment to QA/UAT environments.
5. **Lean experiments** — continual measured improvement; only works well atop solid lower layers.

## Always release ready

If an executive commands "competitor X launched feature Y, go live now with what we have", the worst acceptable answer is "give us one hour". The rule: **never break the build, always be release ready** — the business may surprise you. Teams either release directly from trunk (higher cadence) or cut a branch just for the release (lower cadence); see releases.md.

## Daily mechanics

- **Checkout/sync:** everyone clones/checks out from trunk and pulls many times a day, *knowing* the build passes. Sync delays should be seconds.
- **Committing:** complete a piece of work that does not break the build — provably, by running the build locally **before** push. Pull/sync first if needed, build again, then push. Commit granularity is learned; commits are typically small.
- **Code review:** pair programming may count as review; otherwise the commit is marshaled for review before landing — in modern portals, a visible PR branch. Delete review branches after review completes (keep the commentary/approval history, not the branch); do not keep developing on a branch after review + merge.
- **Safety net:** CI daemons watch trunk (and the short-lived branches under review) and loudly, quickly report when trunk breaks. Some teams lock trunk and roll back; some let the CI server auto-revert. The high bar is verifying the commit *before* it lands in trunk.

## The three styles and when each fits

| Style | Active committers (same repo) | Mechanism |
|---|---|---|
| Committing straight to trunk | 1–100 | Push to trunk after local full build |
| Short-lived feature branches | 2–1000 | PR branch per change; CI + review before merge |
| Coupled patch-review system | 2–40,000 | Changes marshaled outside VCS (Mondrian → Gerrit/Rietveld/Phabricator); CI + review gate entry |

Super-scaled setups add merge/patch queues. In **all** variants, developers run the full build locally (compile, unit tests, the range of integration tests) and see it pass **before** declaring done and pushing toward review, bots, or trunk. Build automation is never a crutch for finding out whether a commit was good — the developer determines that first. Keeping the build fast is what makes every style viable; slow builds drive teams toward worse branching models, repo sharding, and slower release cadences.

Trade-offs when choosing a style:

- Does the build technology need to build *everything* per commit? (Bazel/Blaze does not.)
- Does the VCS have a push/pull bottleneck at this committer count?
- Median build duration versus commit rate (10-second build + commit every 5 minutes = great; 5-minute build + commit every 10 seconds = hell).
- Does build-automation infra fall behind the commit/PR rate?
- Can developers avoid using automated builds as a crutch?
- Are follow-up commits a workable remediation path?
- Are developers good at separating refactoring commits from functional commits ("baby commits" generally)?
- Can the team handle code-review feedback *after* push to trunk, or only before?

### Style: committing straight to the trunk

For small teams where everyone knows what others are doing; the build is fast and relatively exhaustive; breakage is rare. On a post-land break: revert immediately (possibly locking trunk briefly), or — in a really small team (3–4) — allow a fast forward-fix back to green.

- Risk mitigation is **everyone** running the full build (the same one CI runs) before push, and pushing only on green. This essential integration activity is an XP-era habit, valuable under every branching model.
- That locks in a new requirement: keep the full build fast. ~1 minute is fast; 10+ is slow. Effort goes into compile + **pure unit tests** (no threads, no sockets, no file IO); minimize integration-test steps without losing meaningful coverage — best trick is converting integration tests into unit tests.
- Optional hardening: a revert policy/bot for commits proven broken in CI (build-cop role, or instant bot revert as Google does); scripting so workstations only pull commits CI marked green (publish last-known-good commit ID, wrap git-pull to target it).
- Tooling: `tbdflow` (github.com/cladam/tbdflow) codifies a safe path — fetch→rebase integration with a WIP-guard snapshot, pre-flight CI status checks, a "conflict radar" for overlapping changes/red builds, and intent breadcrumbs in commit bodies.

Benefit: it is easier to objectively verify your own commit (optimally pair-programmed) and push at moments of convenience than to interrupt a teammate via a review system. The style tends toward a flow of small commits, each an incremental, individually shippable step while the larger story remains incomplete.

### Style: short-lived feature branches

Facilitated by lightweight branching (git/Mercurial). With PRs, the cut-off where teams graduate from direct-to-trunk dropped from ~100 committers to ~15; with 16+ a team is more productive on short-lived branches verified by CI before landing. The community also calls them task or topic branches; bug fixes ride them too.

Key rules:

- **Lifetime: a couple of days, maximum.** Longer risks becoming a long-lived feature branch — the antithesis of trunk-based development.
- **One developer per branch** (two if pairing). Branches may be *shared for review*, never for collaborative development.
- **Merge directionality:** merges *into* the branch only to bring it up to date with main; merges *to* main only as part of closing the branch out — immediately before deleting it.
- Before the close-out merge, a freshen-from-main is usually needed (a speculative pull before push leaves no trace if there is nothing to merge). Stash-pull-pop vs rebase (with optional squash) is personal/team preference.
- Pitfall: the one-PR-per-story mind trap. High-throughput XP teams streamed tens of individually shippable commits a day into trunk. Stream several PRs per story instead — e.g. a refactoring PR, then a functionality PR, then another refactoring PR — same story association, different short-lived branches, each deleted after merge.

The five contract-breaking moves for these branches are cataloged in anti-patterns.md.

### Style: coupled patch-review

Google hit the ceiling on direct-to-trunk committers in the early 2000s and built per-commit review + CI collation tooling (Mondrian, 2006), augmenting Perforce. Successors: Gerrit, Rietveld, Phabricator. Pending changes are held outside source control (relational schema), marshaled and guaranteed good before integration to trunk. Functionally the modern PR flow with the branch replaced by a managed queue entry.

## Continuous Integration

"Individuals practice trunk-based development, and teams practice CI" — Steve Smith.

CI as defined (Beck, XP, the 1996 C3 project; Fowler/Foemmel 2000/2006) is the *practice* of integrating everyone's work at a single integration point at least daily, with developers cultivating habits that keep that shared place high quality. This doctrine reserves the term CI for verification of an enforced single shared branch; a daemon pointed at branches of a multi-branch model is build automation, not CI (full treatment in anti-patterns.md §Daemonic CI).

- The build script developers run pre-push is **the same one** the CI service follows, broken into gated steps for succinct communication: compile, test-compile, unit tests, service tests, functional tests (the last two are integration-class).
- More than ~3 developers: hook up a CI daemon to guard trunk against bad commits and timing mistakes — after they land, and ideally before.
- **Radiators:** a left-to-right green/red pipeline view on TVs for co-located teams, click-through from notification emails. Time-to-bad-news is key — repair cost rises with every commit pushed onto a breakage.
- **Per-commit vs batching:** batching (one build verifying several commits) is fine for small teams — picking apart a batch of 2–3 is easy since concurrent commits are almost never entangled. Bigger teams want one build per commit; controller/agent CI parallelizes jobs; containerized build envs can be small replicas of prod infra.
- **Tests are never green incorrectly** (assuming well-written tests with real assertions). The inverse — red on good code — is the common flaky failure mode QA automators eternally fix. An always-green-unless-genuine-issue comprehensive build is extremely valuable; an often-red or percentage-failing nightly has greatly reduced value. Once trusted-green, run it as often as possible. Park non-functional tests (latency etc.) in a later pipeline phase rather than polluting the fast functional verdict.
- **Pre- vs post-push verification:** finding breakage after the commit lands is throughput-lowering (fixing while the team watches). Best setups get human agreement (review) and machine agreement (CI) **before** the commit lands. Timing windows still exist, so CI runs again post-push; that second build fails so rarely that auto-revert + notification is the right handling.
- **The high bar:** verify every commit before it lands, on elastic infra, within seconds-to-minutes of push. At very high commit rates (Google: one commit per ~30s) auto-rollback would stop the line too often, so pending commits are marshaled to look like they follow the last known green commit — i.e. a branch (or queue entry) verified before auto-merge. Open risk: nothing in current tooling stops a short-lived branch from sleepwalking into a long-lived one — police it yourself.
- Prefer CI products that co-locate pipeline configuration in the branch being built (supports branch-for-release cleanly).

## Continuous Code Review

The team commits to processing proposed commits speedily; reviews are never allowed to back up. Someone between work items picks up the review before starting new work (multi-tasking costs). Pair programming may count as the review (Guido van Rossum: code review is "basically asynchronous pair-programming" — the best alternative to pairing).

- A PR signals "reviewers get busy, CI wake up". From colleagues it should be processed toward merge **fast**: minutes is best, tens of minutes acceptable; more than an hour or two measurably hurts cycle time. (Unsolicited open-source PRs are exempt — volunteers review when they review.)
- Squash-before-review vs keep-commits is team policy; some leave it to the developer.
- **Common code ownership:** commits are never rejected for "only I may change this package". Rejections must cite objective, published reasons.

## Continuous Delivery and Continuous Deployment

CD extends CI by automatically redeploying a proven build to QA/UAT environments — per commit, if bounce time allows; the radiator pipeline grows deploy stages. Continuous **Deployment** pushes all the way to production per commit (Netflix, Etsy, GitHub style); money-handling domains are more conservative. CD is a broad practice layer *above* trunk-based development (see the Humble/Farley book); lean experiments belong to CD, not to the branching model.

## Observed habits of practicing teams

- **No code freeze; every day is the same.** No slowdown near releases. At most a couple of developers focus on an imminent release; the majority works business-as-usual at full commit rate.
- **Quick reviews.** Scrutiny is welcomed and pulled earlier (pairing, review-on-submit).
- **Chasing HEAD.** Update/pull/sync from trunk many times a day.
- **Run the build locally.** Very small teams can even defer standing up a CI server, because nobody pushes red. If someone beat you to the push: pull, rebuild, push again.
- **Facilitating commits.** A wholesale rename/move that would inconvenience everyone goes in first as its own commit; the substantive rework follows separately (mechanics in techniques.md).
- **Powering through broken builds.** Best: automatic rollback of a breaking commit, quiet workstation fix. Developers avoid pulling a known-broken HEAD — sync to the last known good commit (some teams publish it and wrap the pull command). If CI batches or builds are long, a build-cop may lock trunk and bisect.
- **Shared-nothing workstations.** A microcosm setup: bring the app up locally and run all unit/integration/functional tests with no TCP leaving the box (wire mocking / service virtualization, e.g. Mountebank). Sacrifices non-functional fidelity for functional correctness — fine for development + per-commit CI. Real integration happens in many named QA/UAT environments with real dependent services, which should not share services with each other (shared dev/QA licenses are a classic productivity-killing mistake).
- **Common code ownership.** Broad permission to change unfamiliar code, balanced by standards, CI checks, and speedy human review.
- **Always release ready.** Going live on one hour's notice, backed by the automated test suite.
- **Thin vertical slices.** Stories completable by one developer/pair in a short time and a small number of commits, crossing all tiers of the stack without specialist handoffs; INVEST is the splitting aid (full treatment in techniques.md).

## Deciding factors

- **Iteration length / cadence:** rigid 4-week+ iterations can still follow trunk discipline but will not reach CD. Waterfall is simply incompatible with "do not break the build" — adopt a short-iteration method first.
- **Story size:** optimal is hours from start to review-ready. Beyond a couple of days, pressure mounts for multi-developer branches, forks of in-progress branches, or intermediate merges of incomplete work — all bad. Split relentlessly (INVEST; see techniques.md).
- **Build times** directly set commit rate: ~2-minute builds sustain a high pace; 30-minute builds throttle developers to a couple of commits a day.
- **VCS speed:** no-op sync should be <3 seconds; <15 seconds when behind. (Historic ClearCase/PVCS at 30–45 minutes made trunk-based development impossible.)
- **Binaries and repo size:** use LFS for big binaries in git; keep zipped git history around ≤1GB or plan mitigation — archive-and-restart (rename repo read-only, keep history/issues/review record), `--shallow-since` clones, partial clone (history without blobs until needed).
- **Peak commit frequency:** pure git's pull-before-push creates a "race to push" on hot repos; PR bots keeping branches abreast of origin:main, and GitHub Merge Queue (GA July 2023), mitigate. Very high commit rates still serialize (a Microsoft motivation for VFS for Git).
- **Conway's law:** if a monorepo does not fit the organization's communication structure, microservices/multi-repo may fit better — see scale-and-vcs.md.
- **Database migrations:** handle table-shape changes and data backfill under source control with delta scripts — Sadalage/Ambler's *Refactoring Databases*; see techniques.md.
- **Shared code:** common-ownership or at least objective contribution rules with prioritized fair review; fine-grained *write* permissions are acceptable, but **never** any impediment to reading anything in the trunk.
