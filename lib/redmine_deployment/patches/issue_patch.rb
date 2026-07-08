# frozen_string_literal: true

module RedmineDeployment
  module Patches
    module IssuePatch
      def self.included(base) # :nodoc:
        base.send(:include, InstanceMethods)
      end

      module InstanceMethods
        # Deployments whose commit range (see Deployment#changesets) includes at least one
        # of this issue's changesets. There is no stored issue<->deployment link, so we start
        # from the repositories the issue's changesets live in, take the deployments on those
        # repositories, and keep the ones whose computed range actually contains one of the
        # issue's changesets. Ordered newest deployment first.
        def deployments
          changeset_ids_by_repository = changesets.group_by(&:repository_id)
          return Deployment.none if changeset_ids_by_repository.empty?

          candidates = Deployment.
            where(:repository_id => changeset_ids_by_repository.keys).
            order("#{Deployment.table_name}.created_on DESC")

          matching = candidates.select do |deployment|
            issue_changeset_ids = changeset_ids_by_repository[deployment.repository_id].map(&:id)
            deployment.changesets.where(:id => issue_changeset_ids).exists?
          end

          Deployment.where(:id => matching.map(&:id)).
            order("#{Deployment.table_name}.created_on DESC")
        end
      end
    end
  end
end

unless Issue.included_modules.include?(RedmineDeployment::Patches::IssuePatch)
  Issue.send(:include, RedmineDeployment::Patches::IssuePatch)
end
