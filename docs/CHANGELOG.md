# redmine deployment - CHANGELOG

## 2026-10-02 v1.4.0
* **[add]** the changesets of a deployment are **resolved once and stored** _(table `deployment_changesets`, `Deployment#resolve_changesets!` by one recursive query - `RedmineDeployment::CommitRange`, about 15 ms for a history of 17,000 commits on MySQL 8)_: the "Deployment" tab of an issue, the issues / revisions of a deployment and the deploy status are indexed lookups now — one query for `Issue#deployments`, whatever the number of deployments; nothing walks the commit graph in a request, with or without a cache
* **[add]** the resolution runs in the background: `ResolveDeploymentChangesetsJob` right after a deployment is logged _(the deploy process - the API request - never waits for it)_, after the repository fetched new changesets _(`Repository::Git#save_revisions` - deployments logged before their commits were fetched stay pending until then)_ and by the rake task **`redmine:deployment:resolve_changesets`** _(the pending ones; `FORCE=1` all, `PROJECT=identifier`, `DEPLOYMENT=id`)_ — run it once after the update to backfill the existing deployments, and by cron after `redmine:fetch_changesets` as a safety net
* **[add]** `deployments.changesets_resolved_at` / `changesets_error` _(the state of the resolution; `Deployment.changesets_pending`, `#changesets_resolved?`)_ and `changesets_unavailable_reason` value `:not_resolved` with an explanatory notice _(en + de)_
* **[add]** when a repository is reloaded or deleted _(`Repository#clear_changesets`)_, the stored changesets of its deployments are removed and the deployments set back to pending, so they are resolved again after the fetch
* **[ref]** `RedmineDeployment::DeployStatus` reads the stored changesets of the deployments _(one indexed query per project instead of one recursive query per deployment)_; the recursive query and its Ruby fallback moved to `RedmineDeployment::CommitRange` and serve the branch steps only _(ancestors of a branch head, cached by the head as before)_
* **[ref]** `Issue#deployments` no longer prunes by `created_on` - the stored changesets are exact
* **[fix]** the deployments of an issue and the issues / revisions of a deployment took minutes on a real repository — `Deployment#changesets` walked the commit graph in Ruby with one query per generation of commits down to the root _(3,286 queries for a history of 17,000 commits)_, and `Issue#deployments` did so for every candidate deployment; fast locally only because the local deployments sit on a 100-commit demo repository
* **[fix]** statistics: an environment keeps its color in both graphs - the colors come from a fixed list _(`DeploymentsController::ENVIRONMENT_COLORS`)_ and are assigned to the environments of the project _(alphabetically, all successful deployments)_, not to the position of a dataset in a graph; the graph per month shows the last 12 months and the one per author all deployments, so the same environment could change its color between them. The color of a dataset is part of the graph data _(`color`)_

## 2026-10-02 v1.3.0
* **[add]** `changesets_unavailable_reason` value `:incomplete_range` with an explanatory notice _(en + de)_, and the issue tab of the detail page now shows the reason as well _(previously only the revisions tab did)_
* **[add]** deployment pipeline: dynamic values - wildcards (`feature/*`) and issue placeholders (`{%issue.id%}`, `{%tracker.name%}`, ...), resolved per issue
* **[add]** permission **"Indikator / Badge ansehen"** _(`view_deployment_indicator`)_ for the deploy status on the issue page and in issue lists
* **[add]** project setting **"Indikator anzeigen"** - the deploy status on the issue page is off by default
* **[add]** the pipeline popup names its issue _("Deployment-Pipeline - #42")_
* **[add]** a click on the deploy status opens the whole pipeline of the project as a popup _(replaces the tooltip)_
* **[add]** `deployment_badge(status, short: true)` - the first letter of the step only
* **[add]** configurable deployment pipeline: "Code", followed by branch and deployment steps with colors - central in the plugin settings, overridable per project
* **[add]** deploy status of issues (`RedmineDeployment::DeployStatus`), resolved for many issues at once and cached
* **[add]** issue query columns "Deploy indicator" and "Deploy badge"
* **[add]** deploy status on the issue page and `DeploymentStatusHelper` for other plugins _(taken over from RI-Customizations)_
* **[ref]** revision range of a deployment without a `from_revision` is displayed as `? ... <rev>` instead of `000000 ... <rev>`, which suggested "since the beginning"
* **[ref]** permission `manage_deployment_settings` renamed to **"Deployment Einstellungen anpassen"**
* **[ref]** issue tab renamed to **"Deployment"**
* **[ref]** issue query column "Deploy-Badge" renamed to **"Deployment"**
* **[fix]** a deployment without both revisions could make its detail page never finish loading — a missing (or not yet fetched) `from_revision` was read as "since the root commit", so the deployment claimed the *entire* repository history: every changeset and every issue ever referenced, rendered unpaginated. `Deployment#changesets` now requires **both** boundaries and returns nothing without them
* **[fix]** an all-zero revision — Git's null revision, as deploy hooks send it (`0000000000000000000000000000000000000000`, often abbreviated to `000000`) — counts as "no revision" instead of being resolved against the repository, where `Repository::Git#find_changeset_by_name`'s `scmid LIKE "<name>%"` prefix match could hit an arbitrary commit whose id starts with zeros and produce a bogus range _(`Deployment.null_revision?`, applied to the range, the deploy status and the revision links)_
* **[fix]** the same open-ended range made `RedmineDeployment::DeployStatus` mark every issue of a repository as deployed — deployments without a resolvable `from_revision` are now skipped for the deploy indicator / badge too _(the branch steps keep their "merged into this head" semantics)_
* **[fix]** failed deployments no longer count towards the deploy status

## 2026-07-08 v1.2.2
* **[fix]** deployment↔issue matching could take >60s — `Issue#deployments` now prunes candidate deployments by `created_on` _(after the issue was created, at or before now)_ before running the per-candidate commit-DAG membership check, so the expensive walk runs on only a handful of deployments instead of every deployment on the repository
* **[ref]** memoize `Deployment#changesets`' DAG-range computation so the walk runs at most once per instance _(the detail page previously walked it twice, via `changesets` and `related_issues`)_

## 2026-07-08 v1.2.1
* **[fix]** severe issue-page lag introduced in v1.2.0 — the "Deployments" tab no longer resolves matching deployments (and walks the commit DAG) on every issue show render; the tab is now shown whenever the issue has changesets and the matching deployments are computed lazily only when the tab is opened

## 2026-07-08 v1.2.0
* **[add]** "Deployments" tab on the issue page, listing every deployment whose commit range includes one of the issue's changesets _(shown only with the `view_deployments` permission)_
* **[add]** DAG-based changeset resolution — `Deployment#changesets` now walks the git parent graph (`from..to`, like `git log from..to`) instead of a commit-time window, correctly excluding commits from other branches that were never merged
* **[add]** `changesets_unavailable_reason` with explanatory notices when a range can't be computed _(no repository, commit graph unavailable, or deployed revision not yet fetched)_
* **[add]** `ChangesetParent` model — read-only access to the `changeset_parents` commit DAG for efficient graph traversal
* **[add]** `MAX_TRAVERSAL` guard against pathological histories, logged rather than silently truncated
* **[add]** test suite _(deployment model, issue↔deployment matching, issue tab, revision-links helper)_
* **[add]** `label_deployment_plural` and changeset-unavailable / repository-deleted locale strings _(en + de)_
* **[ref]** extracted the linked "from ... to" revision range into a shared `link_to_deployment_revisions` helper, now reused on the detail page and issue tab
* **[fix]** deployments details page shows unassigned issues
* **[fix]** deployments now survive deletion of their repository — `repository` association is optional _(still required on create)_, and API/HTML views degrade gracefully when it is gone

## 2026-06-16 v1.1.1
* **[add]** contextual navigation between the deployments overview & statistics pages
* **[add]** branch value on the detail page links to the repository branch
* **[ref]** replaced the sidebar overview/statistics links with the contextual navigation

## 2026-06-16 v1.1.0
* **[add]** deployment detail page _(HTML show)_ summarizing the key deployment data
* **[add]** related issues & related revisions on the detail page, shown as tabs
* **[add]** deployment statistics page _(successful deployments per month & per author, by environment)_
* **[add]** sidebar links _(overview & statistics)_ and a link from the deployments list to each detail page

## 2024-10-01 v1.0.0
* **[add]** API endpoint
* **[add]** branches-resolving for changesets
* **[add]** application menu
* **[add]** LICENSE
* **[ref]** hooks & patches
* **[fix]** minor bugs

## 2024-09-30 v0.0.1
* Initial commit
* docs, version, structure
