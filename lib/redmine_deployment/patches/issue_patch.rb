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

          # A deployment can only contain one of this issue's changesets if it happened after the
          # issue existed (the changeset references the issue, so it was committed — and therefore
          # deployed — no earlier than the issue's creation) and no later than now. Pruning by
          # +created_on+ first drops the vast majority of candidates cheaply, so the expensive
          # per-candidate DAG membership check below runs on only a handful of deployments.
          candidates = Deployment.
            where(:repository_id => changeset_ids_by_repository.keys).
            where("#{Deployment.table_name}.created_on >= ?", created_on).
            where("#{Deployment.table_name}.created_on <= ?", Time.now).
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
