# redmine deployment - CHANGELOG

## unreleased
* **[add]** deployment pipeline: "Code", followed by the deploy environments _(type "Branch": merged into the branch, type "Deployment": a successful deployment of the environment)_, each in its own color - managed as a table _(drag & drop, color picker)_ centrally in the plugin settings and overridable per project _(project settings, tab "Deployment", new permission `manage_deployment_settings`; stored in the plugin settings like redmine_contacts: `projects` => `{ <project id> => { custom, environments } }` - see `DeploymentSetting`)_; "Code" is a static step with a changeable label and color
* **[add]** deploy status of issues (`RedmineDeployment::DeployStatus`): resolved for many issues at once with the pipeline of each project - the commit range of a deployment and the ancestors of a branch head are computed by a recursive SQL query and cached
* **[add]** issue query columns "Deploy indicator" and "Deploy badge" _(loaded for all listed issues at once - `Issue.load_deployment_statuses`, CSV/PDF export as text)_
* **[add]** deploy status on the issue page, right of the subject _(indicator and badge, projects with the module "deployment")_ - `DeploymentStatusHelper` with the central render methods `deployment_indicator`, `deployment_badge` and `deployment_pipeline` for other plugins _(taken over from RI-Customizations, whose former setting is moved by its migration)_

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
