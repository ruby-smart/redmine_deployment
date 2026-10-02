module RedmineDeployment
  module Patches
    module RepositoryPatch
      def self.included(base) # :nodoc:
        base.class_eval do
          has_many :deployments
        end
      end
    end

    # Redmine clears the changesets of a repository by plain SQL (Repository#clear_changesets - before it is
    # destroyed and when it is reloaded), so no callback of Changeset sees it: the stored changesets of the
    # deployments (DeploymentChangeset) are removed here as well, and the deployments are set back to pending -
    # after the reload the commits get new ids, so the ranges are resolved again after the next fetch (see
    # RepositoryGitPatch) or by the rake task redmine:deployment:resolve_changesets.
    module RepositoryClearChangesetsPatch
      private

      def clear_changesets
        cs = Changeset.table_name
        dc = DeploymentChangeset.table_name
        self.class.connection.delete(
          "DELETE FROM #{dc} WHERE #{dc}.changeset_id IN (SELECT #{cs}.id FROM #{cs} WHERE #{cs}.repository_id = #{id})"
        )
        Deployment.where(:repository_id => id).update_all(:changesets_resolved_at => nil, :changesets_error => nil)
        super
      end
    end
  end
end

unless Repository.included_modules.include?(RedmineDeployment::Patches::RepositoryPatch)
  Repository.send(:include, RedmineDeployment::Patches::RepositoryPatch)
end

unless Repository.ancestors.include?(RedmineDeployment::Patches::RepositoryClearChangesetsPatch)
  Repository.prepend(RedmineDeployment::Patches::RepositoryClearChangesetsPatch)
end
