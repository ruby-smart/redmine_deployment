# frozen_string_literal: true

# Resolves the changesets of a deployment (Deployment#resolve_changesets!) in the background: enqueued right after a
# deployment was logged, so the deploy process - the API request - never waits for the commit graph. A deployment
# whose revisions are not fetched into Redmine yet stays pending and is resolved after the next fetch of the
# repository (RedmineDeployment::Patches::RepositoryGitPatch) or by the rake task
# redmine:deployment:resolve_changesets.
class ResolveDeploymentChangesetsJob < ActiveJob::Base
  queue_as :default

  def perform(deployment_id)
    Deployment.find_by(:id => deployment_id)&.resolve_changesets!
  end
end
