# redmine deployment Plugin

![](https://img.shields.io/badge/version-1.3.0-blue.svg "version")
[![Author](https://img.shields.io/badge/author-ruby--smart-blue)](https://ruby-smart.org)

[![License](https://img.shields.io/badge/license-GPL--3.0-green)](docs/LICENSE.txt)

A plugin for repository deployments

------------------------------------

## Environment

**Ruby**

![](https://img.shields.io/badge/ruby_2.4-unknown-yellow.svg "Ruby 2.4")
![](https://img.shields.io/badge/ruby_2.5-unknown-yellow.svg "Ruby 2.5")
![](https://img.shields.io/badge/ruby_2.6-unknown-yellow.svg "Ruby 2.6")
![](https://img.shields.io/badge/ruby_2.7-stable-green.svg "Ruby 2.7")
![](https://img.shields.io/badge/ruby_3.0-stable-green.svg "Ruby 3.0")
![](https://img.shields.io/badge/ruby_3.1-stable-green.svg "Ruby 3.1")
![](https://img.shields.io/badge/ruby_3.2-stable-green.svg "Ruby 3.2")

**Rails**

![](https://img.shields.io/badge/rails_4.2-unknown-yellow.svg "Rails 4.2")
![](https://img.shields.io/badge/rails_5.2-unknown-yellow.svg "Rails 5.2")
![](https://img.shields.io/badge/rails_6.0-stable-green.svg "Rails 6.0")
![](https://img.shields.io/badge/rails_6.1-stable-green.svg "Rails 6.1")
![](https://img.shields.io/badge/rails_7.1-unknown-yellow.svg "Rails 7.1")

**Redmine**

![](https://img.shields.io/badge/redmine_3.4-unknown-yellow.svg "Redmine 3.4")
![](https://img.shields.io/badge/redmine_4.0-unknown-yellow.svg "Redmine 4.0")
![](https://img.shields.io/badge/redmine_4.1-unknown-yellow.svg "Redmine 4.1")
![](https://img.shields.io/badge/redmine_4.2-unknown-yellow.svg "Redmine 4.2")
![](https://img.shields.io/badge/redmine_5.0-stable-green.svg "Redmine 5.0")
![](https://img.shields.io/badge/redmine_5.1-stable-green.svg "Redmine 5.1")

------------------------------------

## Docs

[CHANGELOG](docs/CHANGELOG.md)

------------------------------------
## Features

* Adds `deployment` project module
* Adds `deployment` read + create rights
* Deployment 'logging' for repositories
* logs success / fail deployments through API
  * logs DateTime, Author, Branch, Revisions, Environment, Servers, Project & Repository
* belongs to project & repository
* supports queries
* **Deployment pipeline** _(the deploy status of issues)_: "Code" _(the changesets of the issue)_, followed by the deploy environments - every step in its color, reached / partial _(newer commits pending)_ / not reached:
  * managed as a table: centrally in the plugin settings _(Administration » Plugins)_ and overridable per project _(project settings, tab "Deployment", permission "Edit deployment settings")_ - both are stored in the plugin settings _(`DeploymentSetting`, like redmine_contacts: `environments` and `projects` => `{ <project id> => { custom, environments } }`)_
  * "Code" is the static first step - only its label and color can be changed; the other steps are sortable by drag & drop
  * type "Branch": reached, if the commits are merged into the branch of the repository _(ancestors of the branch head, which has to be fetched into Redmine)_
  * type "Deployment": reached by a successful deployment of the environment _(its commit range, like `git log from..to` - a deployment needs **both** revisions, one alone is no range and covers nothing; the changesets of a deployment are stored, see "Changesets of a deployment" below)_
  * dynamic values, resolved per issue: `*` matches any characters _(e.g. `feature/*` - merged into any feature branch)_, placeholders `{%object.attribute%}` insert issue attributes _(e.g. `feature/{%issue.id%}-*`, `review-{%tracker.name%}`; objects: `issue`, `tracker`, `project`, `status`, `priority`, `category`, `version`, `author`, `assigned_to` - attributes: their columns, users only `id`, `login`, `firstname`, `lastname`, `name`)_. Dynamic values match case-insensitively, a placeholder without a value _(e.g. no assignee)_ makes the step unreachable for that issue; the popup shows the resolved value
  * stored as text, one step per line: `code | | label | color` and `type | value | label | color` _(color: 12 names or `#rrggbb`, default by position - the last environment is green)_, every row is checked by the pattern of the parser
  * shown on the issue page _(right of the subject: indicator and badge - with the permission "View indicator / badge")_ and available for other plugins: `RedmineDeployment::DeployStatus` _(all issues at once by indexed queries: the stored changesets of the deployments; the ancestors of a branch head are computed by one recursive SQL query and cached)_ and the central render methods of `DeploymentStatusHelper` _(e.g. the SCRUM taskboard of RI-Customizations)_:
    * `deployment_indicator(status)` - the segments: "Code", then every environment in its color
    * `deployment_badge(status)` - the last reached step in its color _(live filled, reached outlined, newer commits pending dashed)_
    * `deployment_pipeline(status)` - indicator and badge
  * issue queries: the columns "Deploy indicator" and "Deploy badge" _(with the module "deployment" and the permission "View indicator / badge"; the deploy statuses of the listed issues are loaded at once, CSV/PDF as text)_
* Additional _(side)_ features:
  * Adds Branches-lookup for changesets _(so related branches are shown in Revision details)_ `GIT-only`
  * Adds Branches-summary for related-issues _(so branches are shown in issue-changesets-tab)_ `GIT-only`

------------------------------------

## Installation

* copy plugin to **{RAILS_APP}/plugins** directory
* run bundler
    ```
    bundle install --without development test RAILS_ENV=production
    ```
* run rake task
    ```
    rake redmine:plugins:migrate RAILS_ENV=production
    ```
* restart server
* resolve the changesets of the existing deployments once _(update from a version before 1.4 - see below)_
    ```
    rake redmine:deployment:resolve_changesets RAILS_ENV=production
    ```

------------------------------------

## Changesets of a deployment

The changesets of a deployment - its commit range `from_revision..to_revision`, like `git log from..to` over the commit graph Redmine stores in `changeset_parents` - are **resolved once and stored** (`deployment_changesets`). Every page that asks for them is an indexed lookup, whatever the size of the repository history or the number of deployments: the "Deployment" tab of an issue, the issues and revisions of a deployment, the deploy status (indicator, badge, pipeline, SCRUM taskboard). Nothing walks the commit graph in a request, and nothing is cached that could expire.

A deployment is resolved
* **in the background right after it is logged** _(`ResolveDeploymentChangesetsJob`, ActiveJob - the deploy process never waits for it; Redmine's default queue adapter runs the job in the server process)_,
* **after the repository fetched new changesets** _(the usual order of events: the deploy hook logs the deployment before Redmine has fetched the deployed commits - the deployment stays pending, with "revision not fetched yet" on its page, and is resolved by the fetch: repository page, `sys/fetch_changesets`, `rake redmine:fetch_changesets`)_,
* **by the rake task** - the pending ones by default, all of them with `FORCE=1`:
    ```
    rake redmine:deployment:resolve_changesets RAILS_ENV=production
    rake redmine:deployment:resolve_changesets PROJECT=identifier FORCE=1 RAILS_ENV=production
    rake redmine:deployment:resolve_changesets DEPLOYMENT=42 RAILS_ENV=production
    ```
    Run it once after the update to 1.4 _(the backfill of the existing deployments - one recursive query per deployment, about 15 ms each on MySQL 8 for a history of 17,000 commits)_ and, as a safety net, by cron after `redmine:fetch_changesets`.

Resolving a deployment runs **one recursive SQL query** (`RedmineDeployment::CommitRange` - MySQL 8 / MariaDB, PostgreSQL, SQLite); on a database without recursive CTEs it falls back to a walk over the graph in Ruby, which is slow but still runs in the background only. A deployment without both revisions has no range and no changesets. When a repository is reloaded, its deployments are set back to pending and resolved again after the fetch.

------------------------------------

## API Endpoints

### Log deployment
_Creates new deployment through API_
```
[POST] /projects/:project_id/deploy/:repository_id'
=> {deployment: {...}}
```

### Log deployment with capistrano
_Automatically log success/failed deployment with capistrano tasks_
Use the gem `capistrano-redmine-deployment` to hook into capistrano tasks.

------------------------------------

## License

The plugin is available as open source under the terms of the [GNU general public license version 3 (GPL-3.0)](https://opensource.org/licenses/GPL-3.0).

A copy of the [LICENSE](docs/LICENSE.txt) can be found @ the docs.
