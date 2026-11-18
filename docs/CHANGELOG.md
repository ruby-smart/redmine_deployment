# redmine deployment - CHANGELOG

## 2026-11-18 v1.5.0
* **[add]** pipeline step type **"Tag"**: reached, if the commits are part of a matching tag _(e.g. `tag | /^v\d+\./ | Release`; read by `git for-each-ref`, annotated tags dereferenced)_
* **[add]** step values as **regular expression** `/regexp/` or `/regexp/i` _(not anchored, placeholders inserted escaped)_ - the settings forms mark an invalid one, the parser ignores it
* **[add]** regular expressions are limited to 0.1 s per match and 1 s per request _(`Environments::MatchBudget`, Ruby < 3.2 by `Timeout`)_ - a slow match counts as no match
* **[add]** plugin option **"Beginn des Tickets beachten"** _(off by default)_: pipeline and tab "Deployment" count only commits since the issue's start date _(midnight, time zone of the user)_
* **[ref]** a branch / tag step costs one query and one recursive query, whatever the number of matching branches / tags _(2,000 tags: 30 ms instead of 16 s)_
* **[ref]** cache: one entry per step and repository _(replaced when its heads change, expires after 7 days)_; branches and tags are cached for 5 minutes instead of calling git per request
* **[ref]** pipeline settings: shorter help below the table, the option "Beginn des Tickets beachten" before the table

## 2026-10-02 v1.4.0
* **[add]** the changesets of a deployment are **resolved once and stored** _(`deployment_changesets`, one recursive query)_ - issue tab, deployment details and deploy status are indexed lookups now
* **[add]** resolution in the background: `ResolveDeploymentChangesetsJob` after a deployment / fetch, rake task **`redmine:deployment:resolve_changesets`** _(run once after the update, then by cron)_
* **[add]** resolution state `changesets_resolved_at` / `changesets_error` and the notice `:not_resolved`; reloading or deleting a repository resets its deployments to pending
* **[ref]** `DeployStatus` reads the stored changesets; `Issue#deployments` no longer prunes by `created_on`
* **[fix]** deployments of an issue / issues of a deployment took minutes on real repositories _(commit graph walked in Ruby, 3,286 queries for 17,000 commits)_
* **[fix]** statistics: an environment keeps its color in both graphs _(fixed color list per environment)_

## 2026-10-02 v1.3.0
* **[add]** configurable **deployment pipeline** _("Code", branch and deployment steps with colors)_ - central in the plugin settings, overridable per project
* **[add]** dynamic step values: wildcards (`feature/*`) and issue placeholders (`{%issue.id%}`, `{%tracker.name%}`, ...), resolved per issue
* **[add]** **deploy status** of issues (`RedmineDeployment::DeployStatus`, many issues at once, cached) on the issue page, in issue query columns and via `DeploymentStatusHelper`
* **[add]** permission **"Indikator / Badge ansehen"** and project setting **"Indikator anzeigen"** _(off by default)_
* **[add]** a click on the deploy status opens the pipeline popup of the issue _(replaces the tooltip)_; `deployment_badge(status, short: true)`
* **[add]** notice `:incomplete_range` - now also on the issue tab of the deployment details
* **[ref]** renamed: permission **"Deployment Einstellungen anpassen"**, issue tab and query column **"Deployment"**; a missing `from_revision` is shown as `? ... <rev>`
* **[fix]** a deployment without both revisions claimed the whole repository history _(detail page never finished loading, every issue marked deployed)_ - both boundaries are required now
* **[fix]** Git's null revision (`000000...`) counts as "no revision" instead of prefix-matching a random commit
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
