# Scale and VCS

Distilled from trunkbaseddevelopment.com (github.com/paul-hammant/tbd): Monorepos, Expanding/Contracting Monorepos, VCS choices, VCS features, Game Changers, Publications.

## Monorepos

A monorepo is a specific trunk-based development implementation: all applications/services/libraries/frameworks in **one trunk**, with developers committing together — atomically.

Principal goals:

- Acquire as many third-party and in-house dependencies as possible from the same repo/branch in the same sync operation.
- Keep all teams in agreement on dependency versions via **lock-step upgrades**.

Secondary goals: atomic commits across modules; extraction of new common dependencies in atomic commits; everyone focused on HEAD; multi-module bisecting of production bugs.

- Google (most famously), Facebook, Netflix, Uber (iOS) rest on company-wide trunks. Google additionally shares **at source level, not binaries:** in-house dependencies have no version numbers — HEAD effectively *is* the version; lock-step upgrades for everything.
- Third-party dependencies are checked in, one version for all (e.g. `third_party/java_testing/junit.jar`, unversioned filename). Language SDKs install conventionally, not from the repo.
- **Diamond dependency problem:** vanishes in-house (everyone at HEAD — the first team needing new functionality upgrades it for all consumers, accepted/rejected atomically in review). For third-party, lock-step can hurt when backward compatibility breaks: Google's JUnit 3.8→4.x upgrade change-set struggled to keep up with the rate developers added tests.
- **Lock-step deployment is NOT implied:** a dependency upgrade only means the *next* deployment of each consumer contains it; each team still owns its release cadence. Monorepos say *what* ships, not *when*.
- **Warning — chaotic directory layout:** monorepos require globally enforced, uniform source trees (a developer from one team instantly reads another team's layout; Buck/Bazel layouts embody this). If you cannot overhaul your whole repository's directory structure, do not entertain a monorepo.
- **Build systems:** directed-graph builds (Google Blaze; open-source Bazel; Facebook's Buck) compute the subset to compile/test for the current intention and share compiled-object caches — on workstations and CI alike. Recursive builds (Maven, Ant) forward-declare `<modules>`, which fights computed/sparse trees (workarounds: rewrite poms per expansion, or wish for `<calculate/>`).
- **If you choose multiple repos instead:** separate no finer than the applications/services with distinct deployment cadences. One-repo-per-microservice is the community convention, though hundreds of microservices could share a monorepo. Android Repo (with Gerrit) and git-repo federate many repos; VFS for Git attacks the same scale problems from the git side.

## Expanding and contracting checkouts

At monorepo scale a full checkout outgrows disks, IDEs, or local build patience. The answer is intelligent **sparse checkout:**

- Google's `gcheckout` (Blaze-era scripting) maps the multi-gigabyte trunk HEAD down to the **smallest subset** a developer's current intention needs; rerun it any time to expand/contract/reshape the working copy.
- Changing a shared dependency: expand to the union of the dependency and all its consumers; review approves the whole change atomically (common code ownership — the needing team makes the change for everyone rather than feeding a maintainers' backlog); contract afterward.
- Mechanisms: git sparse-checkout (plus, if needed, a once-or-twice-a-year split-history maneuver), Subversion sparse checkouts / svn-viewspec, Perforce client-specs ("views"), PlasticSCM cloaked.conf.

## VCS features that matter

Trunk-based development is possible on any VCS with atomic commits (everything after CVS). What divides them is productivity and governance:

- **Pull/update/sync speed:** the back-to-back no-op sync is the honest benchmark (<3s no-op; <15s when behind). Tree-walking client-server designs (CVS/Subversion) pay per-directory chatter; Perforce keeps the answer server-side in RAM (cost: read-only bits and a permanent connection); git/hg transfer pre-zipped pack data — one fast clone/pull for the whole repo, no sub-directory checkouts.
- **Commit/push speed:** roughly comparable across viable tools; git/hg force a local commit (fast) and a pull-before-push; Subversion/Perforce can push deltas without having latest locally if no line-level clash.
- **Three-way merge:** trunk-based teams merge *more often* but *smaller* (mostly implicitly into the working copy). A good merge tool matters — P4Merge is good enough that teams on other VCSes configure it in. Semantic merge (PlasticSCM) understands refactorings: a moved-and-edited method is not a clash, and a "move method" diff is exact rather than ±50 lines.
- **Integrated code review** turned out to be the killer VCS-platform feature — Mondrian proved it (2006), GitHub productized it (2008). Crucible, UpSource, Gerrit, Phabricator exist, but platform integration wins; CI hooks should fire for every branch including review branches/forks (Facebook's SLA: results ten minutes after entering the review queue).
- **Governance:** enterprises carve permissions finely — e.g. "can commit to trunk, cannot create release branches". Git itself has no branch/directory permissions; hosting platforms add branch permissions (you cannot stop local branches in a DVCS, only pushes). Directory-level read restrictions cut against common-code-ownership ideals; trunk reads should never be impeded.
- **Size/scale:** limitless server-side storage matters to monorepo and big-binary (games) teams. Perforce handles terabytes (Pixar, Adidas; Google until 2012). Git/hg historically ~1GB zipped-history comfort ceiling — mitigations: Git-LFS, `--shallow-since`, partial clone (blobs on demand), archive-and-restart (rename read-only, keep history/issues/reviews), submodules/subtrees/git-repo, VFS for Git (Microsoft, from their Source Depot heritage).

VCS notes: git — `main` convention, origin nickname, fork-based PR review before consuming back to `origin:main`. Mercurial — comparable; inching toward huge-repo capability. Perforce — client-specs, Swarm/GitSwarm for review, Git Fusion / p4-git bridges. Subversion — default trunk/tags/branches dirs (the Subversion team itself does not practice trunk-based development); git-svn gives local branching at clone-speed cost. TFS — TFVC or git modes, trunk-compatible. PlasticSCM — DVCS, big binaries, Branch Explorer, semantic merge.

## Game changers — 40 years of pushes toward and away from trunk

| Year | Event | Direction |
|---|---|---|
| 1982 | **RCS** (Tichy): "a young revision tree is slender"; branches for four reasons, two explicitly temporary, returning to trunk at the earliest opportunity | toward |
| 1990 | **CVS** popularizes the name "trunk"; merging painful, so trunk-based use was the sensible choice; no atomic commits (teams coordinated who was checking in) | toward |
| 1995 | **Microsoft Secrets**: SLM ("slime") one-branch workflow — checkout, implement, build, test, sync, merge, build, test, smoke, check in; designated buildmeister makes a daily build from HEAD (echoed by McConnell 1996 and the Joel Test 2000) | toward |
| 1997 | **NetScape Tinderbox**: public CI over a single-branch CVS trunk; subset checkouts | toward |
| 1998 | **Perforce & ClearCase** win the corporate market; willingness to experiment with parallel active branches → dark years (Microsoft's Source Depot likely multi-branch; Google installs Perforce and goes trunk from the outset). Wingerd & Seiwald's best-practices paper: "branch only when necessary, on incompatible policy, late, and instead of freeze" | away |
| 1999 | **XP's Continuous Integration** (Beck): integrate and build many times a day, every completed task; fast builds ("a few minutes") are the enabling requirement; C3 project on Smalltalk/ENVY pioneered it | toward |
| 2000/2006 | **Fowler & Foemmel's CI article** (rewritten 2006) | toward |
| 2001 | **CruiseControl**: accessible CI daemon; quiet periods for non-atomic CVS; pipeline config co-located in source control. **Apache Gump**: integration-in-the-large early warnings for interdependent OSS | toward |
| 2000–01 | **Subversion**: CVS + atomicity (kills the quiet period), but "lightweight" branching invites parallel branches; merge tracking inadequate until 1.5 (2008), edge-case bugs after. **BitKeeper `bk pull`**: peer-to-peer pulls; the unsolicited-donation/forgiveness model eight years before GitHub formalized it | away |
| 2005 | **Git**: lightweight local branching, strong merge engine with tracking from the start, history rewriting (squash before push). Made multi-branch setups much easier to sustain | away |
| 2006+ | **Google's internal DevOps** revealed: pre-commit CI on proposed commits plucked from workstations; **Mondrian** per-commit review (LGTM culture, speedy competitive reviews, anyone reviews anything); elastic **Selenium farm** second tier; 70:20:10 small:medium:large test ratio (small = sub-1ms, no threads/IO) | toward |
| 2007 | **Branch by Abstraction** named (Stacy Curl; Hammant's writeup) — the trunk answer to big disruptive change | toward |
| 2008 | **GitHub**: forks + Pull Requests (Feb 2008) with built-in review — killed emailed patch-sets, forced the whole industry to respond; also greatly facilitated multi-branch (sadly including long-lived). **Rietveld** then **Gerrit** continue the Mondrian line; Facebook's **Phabricator** follows (2010) | both |
| 2010 | **Continuous Delivery book** (Humble/Farley, from the 2007 AOL engagement): pipelines, delta-script DB migrations, lean feedback loops; pipeline thinking mirrors the Test Pyramid | toward |
| 2011 | **Travis CI** GitHub integration + pass/fail badges on PRs | toward |
| 2011–12 | **Microservices**: many small repos reinforce non-trunk mindshare; monorepos laughed out of the room | away |
| 2012 | **HP LaserJet firmware case study** (*A Practical Approach to Large-Scale Agile Development*): 400 engineers, 10M lines, 10+ long-lived branches, 1-week builds, 6-week manual regression → trunk + CI on a git super-repo, per-variant features as config, 1-hour builds, 24-hour automated suite; support work 25%→5% of time, new features 5%→40% — an 8× productivity gain | toward |
| 2012–13 | **Speculative-merge CI** (Travis first; TeamCity, Snap-CI follow): per-commit "would this merge to main and pass?" verification, discarded after analysis. High bar since: every commit, every branch, results in seconds. Run it under any model — all-green-everywhere is the (dis)proof of your branching model | toward |
| 2013 | **PlasticSCM semantic merge**: refactoring-aware diffs/merges ease all models | both |
| 2016 | **Google reveals the monorepo trunk** (ACM; Potvin @Scale): ~35,000 devs/QA, 95% on one trunk, a commit every ~30 seconds, Piper (in-house, replaced Perforce 2012). **Thierry de Pauw's "Feature Branching Considered Evil"** talk series (later the "On the Evilness of Feature Branching" article series) | toward |
| 2017 | **VFS for Git** (Microsoft): git at Source-Depot scale; branch reduction among the motivators | toward |

## Further reading (publications promoting this doctrine)

- *Software Configuration Management Patterns* — Berczuk with Appleton (2003)
- *Continuous Integration* — Duvall, Matyas, Glover (2007)
- *Continuous Delivery* — Humble & Farley (2010) — the bestselling marching orders
- *Lean Enterprise* — Humble, Molesky, O'Reilly (2015)
- The DevOps Handbook and the trunkbaseddevelopment.com site/book itself

The introduction's standing claim: many publications promote trunk-based development as described here — "this should not even be controversial anymore."
