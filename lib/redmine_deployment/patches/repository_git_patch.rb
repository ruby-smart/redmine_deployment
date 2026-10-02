# frozen_string_literal: true

module RedmineDeployment
  module Patches
    # A deployment is usually logged before its revisions are fetched into Redmine (the deploy hook reports it right
    # after the push), so its changesets can't be resolved at once (Deployment#resolve_changesets! leaves it
    # pending). They are resolved as soon as the repository fetched new changesets - right after
    # Repository::Git#save_revisions stored them, be it from the repository page (autofetch), the sys API or the
    # rake task redmine:fetch_changesets.
    #
    # Prepended (not alias-chained): +save_revisions+ is private.
    module RepositoryGitPatch
      private

      def save_revisions(prev_db_heads, repo_heads)
        result = super
        resolve_pending_deployment_changesets
        result
      end

      # The pending deployments of this repository, resolved right here (a few indexed queries and one recursive
      # query each, typically a handful of deployments) rather than enqueued: the fetch runs from the rake task and
      # the sys API as well, where a job of the async queue adapter wouldn't survive the end of the process.
      def resolve_pending_deployment_changesets
        Deployment.where(:repository_id => id).changesets_pending.find_each(&:resolve_changesets!)
      rescue StandardError => e
        Rails.logger.error("RedmineDeployment: resolving the pending deployments of repository #{id} failed: #{e.message}")
      end
    end
  end
end

unless Repository::Git.ancestors.include?(RedmineDeployment::Patches::RepositoryGitPatch)
  Repository::Git.prepend(RedmineDeployment::Patches::RepositoryGitPatch)
end
