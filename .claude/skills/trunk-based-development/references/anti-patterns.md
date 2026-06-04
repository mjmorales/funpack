# Anti-Patterns and Rejected Models

Distilled from trunkbaseddevelopment.com (github.com/paul-hammant/tbd): You're doing it wrong, Alternative branching models, Short-Lived Feature Branches §breaking-the-contract, Continuous Integration §industry-confusion. This is the catalog behind the SKILL.md tripwires: each entry is a violation, why it fails, and the corrective.

## The violation catalog ("you're doing it wrong")

1. **Merely naming a branch "trunk".** Having a branch called trunk (e.g. Subversion's default dirs) while grouping multiple developers on other branches that live longer than a couple of days is not trunk-based development. *Corrective:* one shared development branch; everything else short-lived, single-owner, deleted on merge.

2. **Fixing bugs on the release branch and merging down to trunk.** The merge-down gets forgotten in the heat of the moment (tired developer, 3am fix) → regression at the next branch cut → "egg on face, and recriminations". *Corrective:* reproduce and fix **on trunk** with a test, CI-verify, cherry-pick to the release branch, verify there, release. Only a truly-unreproducible-on-trunk bug may be fixed branch-side and merged back, with regression risk consciously accepted.

3. **General merges trunk → release branch in the run-up to a release.** (Cherry-picking *every* commit since the cut is the same thing.) It means the branch was cut on the wrong day — usually date pressure from the business side. *Corrective:* cut later; land only sign-off-gated cherry-picks.

4. **"Short-lived" branches that aren't.** A branch older than a day or two diverges enough for the merge back to hurt. *Corrective:* after review + CI approval, merge and **delete the branch as proof of convergence**; start the next branch for the next story. Age cap: two days.

5. **Multiple developers on one "short-lived" branch.** More than the developer (plus pairing partner) makes it a de-facto release branch under active development. A teammate pulling changes from someone's feature branch (because review "takes too long") compounds it — and no portal can technically prevent that pull; only policy can. *Corrective:* one owner per branch; need the code sooner → land it on trunk faster (split, flag).

6. **Days not being the same / code freeze / unmerge.** Slowdowns near releases, freezes, or backing commits out of trunk because they are "not ready" or someone's release is imminent all signal a broken model. Code that is not ready should not have merged; incremental work on trunk belongs **behind a feature flag** so a release can be cut at any moment. Team leadership protects the majority from release distraction. *Corrective:* flags + release-from-trunk or late-cut branches; never freeze, never unmerge.

7. **Keeping a single release branch across releases.** The branch's principal landing mechanism is its own creation; cherry-picks should diminish to zero over time (1.1, 1.1.1, 1.1.2 tags from one branch), then activity reconvenes on a *new* branch cut from trunk for 1.2. *Corrective:* a release branch per release line, deleted when its release leaves production.

8. **Merging release branch → release branch.** Merges only ever go trunk → release branch, only as cherry-picks, only a small percentage of trunk commits. Two release branches may briefly coexist; cherry-pick from trunk to each (Perforce/Subversion can do both in one atomic commit; not required). *Corrective:* trunk is the single source; branches never feed each other.

9. **"Merge everything back" at the end of a release branch.** If you never developed on the branch (correct), there is nothing to merge back — just delete it once no more releases will happen from it. *Corrective:* tag, delete, done.

## Breaking the short-lived-branch contract

For a part-complete short-lived feature branch, these five moves are **not allowed:**

1. Intermediate merges to main — at least where the commit could not go live on its own.
2. Merges (intermediate or not) to other people's short-lived feature branches.
3. Merges (intermediate or not) to any release branch.
4. Workstation-direct variants of #2 (pulling straight from a colleague's clone).
5. Additional developers joining the branch (beyond the pairing partner).

Merges *into* the branch from main (to bring it up to date) are always fine and usually necessary before the close-out merge.

## Daemonic CI

A CI daemon pointed at every branch of a multi-active-branch model is not Continuous Integration — it is build automation. CI as defined is the *practice* of integrating to a single shared point at least daily (Fowler: "Continuous Integration Certification", "Semantic Diffusion"; surveys show "no one agrees how to define CI or CD"). Automation attached to non-trunk branches/patch queues is pre-integration *verification* — valuable, but not CI itself. The honest test of any branching model: per-commit speculative-merge builds on every branch — if everything is green everywhere you are release-ready, and very few multi-branch teams are.

## Rejected branching models

### GitHub flow — the near miss

Individual developers (or pairs) on short-lived branches/forks, PRs with review — very close to PR-centric trunk-based development. **The crucial difference is where the release happens:** GitHub flow deploys/releases from the *branch* before merging back. Failure modes: the release ships but the branch never merges → regression next release; the branch lacks trunk commits that were in a previous release → regression now. *The trunk-based modification:* merge first (review commentary survives branch deletion; commits zip into history, optionally squashed), then release from trunk/tag.

### GitFlow — incompatible

Groups of developers concurrently active in multiple long-running branches (develop, feature branches, release branches, hotfix branches). Plenty of people swear by it; it forecloses concurrent development of consecutive releases and the hedging that feature flags and branch by abstraction enable. Do not adopt it; do not partially adopt it (a `develop` branch is GitFlow's gateway drug).

### More than one trunk — consider not

Many trunks in one repository (per-module trunk + branches + tags) at least allows atomic cross-trunk commits, but turns undesirable with lock-step releases: building the larger thing from root gets harder. *Corrective:* one trunk containing modules with a recursive or directed-graph build (Buck/Bazel); one release branch with cherry-picks; different cadences handled by build-level subsetting, not extra trunks.

### Mainline (ClearCase-style) — diametrically opposite

A forever branch off which **teams** develop on project/release branches, merging down big at completion (possibly after a freeze). The merge choreography compounds: early pulls of incomplete work, post-release fix merge-downs, merges-of-merges across 1.0/1.1/1.2 teams — and these are sweep-merges ("everything not merged yet"), never cherry-picks. Always release ready? "Not on your life" — planned work must complete, defects must drain, formal testing phases must kick in. The doctrine's claim: companies that choose Mainline wither and die, so there is no forever.

### Cascade — incompatible

One branch per future release, each merging daily from its upstream when green. Problems compound with concurrent releases: an upstream butterfly is a downstream tsunami of unmergeability; downstream merges get skipped or "fixed in branch" (diverging from upstream); merges are sweeps, not picks. Larger organizations juggling many concurrent releases should question application size (microservices) rather than adopt cascade.

## Tripwire mapping

| SKILL.md tripwire | Catalog entry |
|---|---|
| Branch likely to outlive 2 days | §4, contract §5 |
| Second owner on a branch | §5, contract §5 |
| Red/skipped validators on main | Daemonic CI; core-practices "keep the build green" |
| Bulk merge into main | §9, contract §1, Mainline/Cascade |
| Cherry-pick into main | §2 |
| develop / release-train / env branches, second trunk | GitFlow, Cascade, Mainline, multi-trunk |
| Code freeze / unmerge | §6 |
| Release from non-main | GitHub flow delta, §3 |
| History rewrite of main | §6 (unmerge variant) |
