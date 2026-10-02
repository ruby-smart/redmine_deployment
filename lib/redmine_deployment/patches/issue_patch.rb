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
        # deploy columns of an issue query (see IssueQueryPatch) - with the permission +view_deployment_indicator+.
        def load_deployment_statuses(issues, user = User.current)
          issues = issues.to_a
          return if issues.empty?

          deploy = RedmineDeployment::DeployStatus.new(issues, user: user, permission: RedmineDeployment::DeployStatus::INDICATOR_PERMISSION)
          issues.each { |issue| issue.deployment_status = deploy.enabled? ? deploy[issue] : nil }
        end
      end

      module InstanceMethods
        # @return [RedmineDeployment::DeployStatus::Result, nil] the deploy status of the issue for the current user (nil:
        #   no module "deployment", no permission, no environments or no changesets) - preloaded for issue lists
        def deployment_status
          return @deployment_status if defined?(@deployment_status)

          deploy = RedmineDeployment::DeployStatus.new([self], permission: RedmineDeployment::DeployStatus::INDICATOR_PERMISSION)
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

        # Deployments whose commit range (see Deployment#changesets) includes at least one of this
        # issue's changesets - by the stored changesets of the deployments (DeploymentChangeset, resolved
        # once in the background): one indexed query, whatever the size of the repository history or the
        # number of deployments. Ordered newest deployment first.
        def deployments
          changesets_issues = "#{Changeset.table_name_prefix}changesets_issues#{Changeset.table_name_suffix}"
          deploying = DeploymentChangeset.
            joins("INNER JOIN #{changesets_issues} ci ON ci.changeset_id = #{DeploymentChangeset.table_name}.changeset_id").
            where('ci.issue_id' => id).
            select(:deployment_id)

          Deployment.where(:id => deploying).order("#{Deployment.table_name}.created_on DESC")
        end
      end
    end
  end
end

unless Issue.included_modules.include?(RedmineDeployment::Patches::IssuePatch)
  Issue.send(:include, RedmineDeployment::Patches::IssuePatch)
end
