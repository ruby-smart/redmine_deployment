# frozen_string_literal: true

# A changeset of a deployment: one row per changeset of the commit range from_revision..to_revision of the
# deployment, stored by Deployment#resolve_changesets! (in the background - ResolveDeploymentChangesetsJob, the
# fetch of the repository, the rake task redmine:deployment:resolve_changesets). With it, "which changesets and
# issues has this deployment" (Deployment#changesets, #related_issues) and "which deployments have this changeset
# or issue" (Issue#deployments, RedmineDeployment::DeployStatus) are indexed lookups - nothing walks the commit
# graph in a request.
class DeploymentChangeset < ApplicationRecord
  belongs_to :deployment
  belongs_to :changeset
end
