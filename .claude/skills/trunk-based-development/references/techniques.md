# Techniques

Distilled from trunkbaseddevelopment.com (github.com/paul-hammant/tbd): Feature flags, Branch by Abstraction, Application strangulation, Deciding factors §database-migrations, Observed habits §facilitating-commits / §thin-vertical-slices.

These are the techniques that make a single always-releasable branch viable for work too big, too slow, or too risky to land in one green commit. They are the documented answer to every "we need a long-lived branch" argument.

## Feature flags (toggles)

A time-honored way to control application/service capabilities in a large, decisive way. Fowler calls them Feature Toggles; flags is the wider industry term.

- **Shape:** e.g. an app launched with `--withOneClickPurchase` activates one purchasing component; without it, the shopping-cart component runs. Flags need not be A/B or new/old — they can be **additive**, and several can interact. Name flags in the same language the business uses for the capability.
- **Granularity** ranges from whole-component (`OneClickPurchasing` vs `ShoppingCart`) down to tiny (`--temp=F|C|K`).
- **Implementation:** prefer an abstraction selected once at the most primordial boot location (hand-rolled conditional or DI/config: `bootContainer.addComponent(classFromName(config.get("purchasingCompleting")))`). Avoid if/else path choices scattered through the code — hence the emphasis on an abstraction at the seam.
- **CI must guard the reasonable expected flag permutations:** post-launch tests adapt per permutation, and the pipeline fans out **after unit tests** per meaningful permutation (crudely: run the whole pipeline in parallel per permutation, each trunk commit kicking off several builds on elastic infra).
- **Build flags:** set at build time; the artifact is incapable of the gated behavior unless built with the flag. (funpack: `ENABLE_X :: #config(ENABLE_X, false)` + `when ENABLE_X { … }` — gated code still compiles/type-checks but is excluded from the artifact; determinism is per artifact+config.)
- **Runtime-switchable flags:** for conditions outside your control (e.g. a partner integration that support must switch off without relaunch when runbook conditions are met). Requirements: the state **persists across restarts** (a restart must not reset the choice) and propagates across all nodes of a horizontally scaled cluster — hold it in Consul/etcd or equivalent.
- **A/B tests and betas:** dark-shipped code in production can be turned on for chosen subsets — marketing-driven A/B, beta cohorts.
- **The tech-debt pitfall:** flags get forgotten once the business pivots — the app works fine with the toggle left in, so nobody pays to remove it. Spencer & Collyer's "#ifdef considered harmful" (1992) is the canonical warning; Brad Appleton notes flags rot exactly the way feature branches did. Countermeasures: keep unit tests covering even the turned-off code; schedule remediation of a flag (and the code it gates) about a month after the release that settled it; record a "review for delete" date with the flag. **funpack policy: every flag gets a removal condition and a scrum task at birth** (`claude-prove scrum task create --title "Remove flag ENABLE_X" --milestone <m>`).
- History: Zeller & Snelting's feature logic (1996) and Zeller's version-sets thesis (1997) prefigure flags; the #ifdef warning predates both.

## Branch by Abstraction

A set-piece technique to effect a *longer-to-complete* change **inside the trunk** — the answer when a change (say five days, possibly repetitive, predicted disruptive) creates pressure for an unstable place outside main.

Rules:

1. Many developers already depend on the code being changed; they must not be slowed down at all.
2. No commit pushed to the shared repository may jeopardize the ability to go live.

Ideal steps (each step is one or more green, pushable commits):

1. **Introduce an abstraction** around the code to be replaced; point all indirect users at the abstraction.
2. **Write the second implementation** behind the abstraction, "turned off" so nobody depends on it yet; tweak the abstraction as needed — never breaking the build.
3. **Flip the switch** to the new implementation for everyone (a tiny commit).
4. **Remove the old implementation.**
5. **Remove the abstraction** — or keep it deliberately if it earns its place as a mocking seam for unit tests.

Case study: ThoughtWorks' Go CI daemon swapped its ORM (iBatis → Hibernate) exactly this way while teammates kept full speed and the product stayed shippable. The contrived metaphor: replacing a car's wheels one at a time inside wheel-like containers, the car drivable after every step — software construction has no gravity, so the choreography is cheap.

Secondary benefits:

- **Pause and resume cheaply.** The compiler (and unit tests for both alternates) guard the incomplete second implementation merely by building it. A paused real branch instead carries an exponential restart cost as it ages. Pause/resume is normal in organizations without limitless coffers.
- **Cancellation stays cheap** — deleting the abstraction *thing* is only incrementally more expensive than deleting a branch.

Not a panacea: it does not fit having to support old APIs/releases for a long period where dependent customers choose their own upgrade moment (KDE 4.x/5.0-style parallel maintenance).

History: practiced long before Stacy Curl named it in 2007 (publicized via a 2005 Bank of America engagement). Before BbA, teams *had to* branch for big disruptive changes — or send everyone on vacation. Dedicated site: branchbyabstraction.com.

## Application strangulation

For a very large disruptive replacement that must not interrupt go-live ability — where old and new are **incompatible (not in the same process/language)**, so branch by abstraction cannot host the seam in code.

- Route invocations between old and new at an infrastructure seam. Canonical example: Apache fronting a legacy Perl app **conditionally routes HTTP** (by URL) to the new Elixir/Phoenix app as milestones complete; the two apps agree on URLs and cookies and deploy in lockstep.
- Late in the strangulation, invert the fronting (new app first, falling through to old) before deleting the last legacy code and snipping the delegation.
- Named by Martin Fowler after strangler vines. Rule of thumb: same/compatible language and process → branch by abstraction; incompatible → strangulation.

## Evolutionary data and contract migrations (expand → migrate → contract)

Trunk-based development requires schema/shape changes to be managed as source-controlled delta scripts that also migrate existing data (Sadalage & Ambler, *Refactoring Databases*; the *Continuous Delivery* book). The shape that keeps every commit shippable:

1. **Expand:** add the new column/field/shape alongside the old; both readable, build green.
2. **Migrate:** move readers/writers and backfill data in small green commits.
3. **Contract:** remove the old shape once nothing depends on it.

funpack mapping: the Index Contract is schema-versioned with all fields mandatory and exact-match — a reshape is a spec-side version bump plus an expand/migrate/contract sequence across `funpack` (producer) and `warden`/runtime (consumers), each step independently green and shippable. Divergence found mid-migration is a spec bug or implementation bug — file it in `spec/`; never a silent fork.

## Facilitating commits

When one imagined change would inconvenience everyone (a big directory rename inside an extensive rework): land the **rename/move first as its own commit** for teammates to absorb in their next sync, then the smaller substantive rework after. Git and Mercurial track content rather than names, which softens the mechanics — separate the commits anyway; reviewers and bisects also thank you.

## Thin vertical slices (story splitting)

Stories/tasks pulled from the backlog should be completable by a developer or pair in a short time and a small number of commits, **transcending all tiers of the stack** without hopping between specialists. INVEST (Independent, Negotiable, Valuable, Estimable, Small, Testable) is the splitting mnemonic. Optimal start-to-review-ready is hours; beyond a couple of days the pressure for multi-developer branches and intermediate merges of incomplete work begins — split further by whatever means available. Small stories are what make every other rule in this skill cheap to follow.
