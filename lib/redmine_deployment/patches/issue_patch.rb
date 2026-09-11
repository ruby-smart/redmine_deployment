# frozen_string_literal: true

module RedmineDeployment
  module Patches
    module IssuePatch
      def self.included(base) # :nodoc:
        base.send(:include, InstanceMethods)
        base.extend(ClassMethods)
      end

      module ClassMethods
        # Loads the deploy status of the issues at once (RedmineDeployment::DeployStatus - no N+1), e.g. for the
        # deploy columns of an issue query (see IssueQueryPatch).
        def load_deployment_statuses(issues, user = User.current)
          issues = issues.to_a
          return if issues.empty?

          deploy = RedmineDeployment::DeployStatus.new(issues, user: user)
          issues.each { |issue| issue.deployment_status = deploy.enabled? ? deploy[issue] : nil }
        end
      end

      module InstanceMethods
        # @return [RedmineDeployment::DeployStatus::Result, nil] the deploy status of the issue for the current user (nil:
        #   no module "deployment", no permission, no environments or no changesets) - preloaded for issue lists
        def deployment_status
          return @deployment_status if defined?(@deployment_status)

          deploy = RedmineDeployment::DeployStatus.new([self])
          @deployment_status = deploy.enabled? ? deploy[self] : nil
        end

        attr_writer :deployment_status

        # the values of the query columns "deploy indicator" and "deploy badge" (see IssueQueryPatch)
        def deployment_indicator
          deployment_status
        end

        def deployment_badge
          deployment_status
        end

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
