# redmine deployment - CHANGELOG

## 2026-09-22 v1.1.2
* **[add]** `Deployment#changesets_unavailable_reason` and explanatory notices on both tabs of the detail page _(en + de)_ when no range can be determined: missing revision, revision not fetched into Redmine, or no repository _(previously a bare "no data")_
* **[fix]** a deployment without both revisions could make its detail page never finish loading — an unknown boundary simply left the changeset scope unfiltered, so the deployment claimed the *entire* repository history: every changeset and every issue ever referenced, rendered unpaginated. `Deployment#changesets` now requires **both** revisions and returns nothing without them
* **[fix]** an all-zero `from_revision` — Git's null revision, as deploy hooks send it (`0000000000000000000000000000000000000000`, often abbreviated to `000000`) — counts as "no revision" instead of being resolved against the repository, where `Repository::Git#find_changeset_by_name`'s `scmid LIKE "<name>%"` prefix match could hit an arbitrary commit whose id starts with zeros and produce a bogus range
* **[ref]** revision range of a deployment without a `from_revision` is displayed as `? ... <rev>` instead of `000000 ... <rev>`, which suggested "since the beginning"

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
