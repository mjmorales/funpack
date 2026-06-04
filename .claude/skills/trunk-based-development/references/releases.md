# Releases

Distilled from trunkbaseddevelopment.com (github.com/paul-hammant/tbd): Branch for release, Release from trunk, Concurrent development of consecutive releases.

"Branch: only when necessary, on incompatible policy, late, and instead of freeze" — Laura Wingerd & Christopher Seiwald, *High-Level SCM Best Practices* (Perforce, 1998). A release branch exists because its policy (stability, no development) is incompatible with trunk's policy (full-speed commits); that incompatibility is the only reason it exists.

## Release from trunk (funpack's policy)

Teams with a high release cadence do not need — and cannot use — release branches: they release directly from the trunk.

- Versioning tends toward commit-number or date-time referent schemes rather than Dewey-decimal; a tag on main marks the release.
- Bugs are **fixed forward:** reproduce on trunk, fix as if it were a feature (as quickly as possible), release again from trunk.
- No slowdown around a release; bug fixes are inline with normal commits.
- Teams releasing about daily or less *might* still cut a branch purely to cherry-pick a fix to and release from — but a tag is the cheaper optimization.
- **Branches can be created retroactively.** Never cut a branch "in case". Any modern VCS can branch from a past revision/tag later, with an outcome identical to having cut it at the time. A production bug against an old tag → retroactive branch from that tag → cherry-pick the trunk fix → point release.

## Branch for release (documented; not funpack's default)

For lower cadences (e.g. monthly) with bug-fix releases in between:

- Cut the branch from trunk **just in time** — a few days before the release. It becomes a stable place while developers keep streaming to trunk at full speed.
- The incompatible policy: the release branch **receives no continued development work.** Developers as a group never commit to it. The branch cut itself is just a lightweight commit.
- High-throughput Continuous Delivery teams skip all of this: a lemon in production is rolled forward — fix on trunk, release from trunk.

### Fix production bugs on trunk

Best practice: reproduce the bug **on trunk**, fix it there with a test, let CI verify it, then **cherry-pick to the release branch** and let a CI pipeline focused on that branch verify it there too (yes, the trunk pipeline is duplicated for each active release branch).

- A cherry-pick is not a regular merge: it takes specific commits, skipping others since the branch cut; VCS merge tracking remembers what moved so later picks still work.
- **Direction is trunk → branch only.** Fixing on the branch with intent to merge back risks forgetting in the heat of the moment — and a forgotten merge-back is a production regression weeks later at the next branch cut. This rule is the hardest for teams to accept; one regression usually converts them.
- Sole exception: a bug that genuinely cannot be reproduced on trunk may be fixed on the branch and merged back — with the regression risk consciously accepted.
- Google (Rachel Potvin, @Scale 2015): "a release branch is typically a snapshot from trunk with an optional number of cherry picks that are developed on trunk and then pulled into the branch." Development branches at Google are exceedingly rare; releases use branches in exactly this snapshot+picks form.

### Merge meister

Cherry-picking trunk→branch is a single-developer (or pair) part-time role, possibly rotating daily. The meister polices rules before each pick — e.g. which business representative signed off — and the team keeps an audit trail (wiki or tickets) of what reached the branch after the cut.

### Patch releases and branch deletion

- A production bug after a branch-based release: cherry-pick the trunk fix to the branch, issue a point release from it.
- Release branches are deleted once their release is clearly no longer in production (when succeeding releases have gone live) — a harmless tidying, since branches restore easily. **They are never merged back into trunk.** In git, tag the released commit before deleting the branch — dangling commits get garbage-collected.

## Concurrent development of consecutive releases

The setup: business plans a stream of major functionality at a fixed cadence, possibly 18 months ahead, with marketing/training/finance commitments — and multiple teams in the same codebase working toward different planned releases. Random bad-news events (a 50% underestimate discovered late, a partner slipping) then threaten the whole train.

- One compelling answer is **reordering releases.** Under merge-heavy branching models that demands a selective un-merge or commenting-out frenzy — disruptive, scary, and slow.
- A team that has institutionalized trunk-based development, **feature flags**, and pluggable components behind abstractions (kin to branch by abstraction) can reorder with small impact: spin up a CI pipeline with the flags flipped to the new permutation and fix what it finds.
- Case study (airline, 2012): late in development a partner missed their date; the team stood up a new pipeline with toggles flipped, confirmed the command-line build's failures, made a couple of quick fixes, and assured management the releases could happen in any order. Flags + abstractions are a **hedging strategy** against scheduling changes.
- Warning, in the strongest terms: **consecutive development of consecutive releases is far superior.** Finish and ship a releasable slice before the team starts the next. Only PM/BA/tech-lead lookahead runs a couple of weeks ahead; the majority of the team picks up new release work only as the previous release ships. Concurrent trains are the thing to escape, not to optimize.
