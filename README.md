# redmine deployment Plugin

![](https://img.shields.io/badge/version-1.0.0-blue.svg "version")
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
    rake redmine:plugins
    ```
* restart server

------------------------------------

## API Endpoints

#### Log new deployment
_Creates new deployment through API_
```
[POST] /projects/:project_id/deploy/:repository_id'
=> {deployment: {...}}
```

------------------------------------

## License

The plugin is available as open source under the terms of the [GNU general public license version 3 (GPL-3.0)](https://opensource.org/licenses/GPL-3.0).

A copy of the [LICENSE](docs/LICENSE.txt) can be found @ the docs.
