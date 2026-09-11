# frozen_string_literal: true

module RedmineDeployment
  module Patches
    # Issue queries: the columns "deploy indicator" and "deploy badge" (the deploy status of the issues, see
    # DeploymentStatusHelper) - available with the module "deployment" and the permission +view_deployments+. The
    # deploy statuses of the listed issues are loaded at once (like the spent hours of Redmine).
    module IssueQueryPatch
      DEPLOYMENT_COLUMNS = [:deployment_indicator, :deployment_badge].freeze

      def self.included(base) # :nodoc:
        base.send(:include, InstanceMethods)
        base.class_eval do
          alias_method :available_columns_without_deployment, :available_columns
          alias_method :available_columns, :available_columns_with_deployment

          alias_method :issues_without_deployment, :issues
          alias_method :issues, :issues_with_deployment
        end
      end

      module InstanceMethods
        def available_columns_with_deployment
          columns = available_columns_without_deployment
          unless @deployment_columns_added
            @deployment_columns_added = true
            if deployment_columns_available?
              columns << QueryColumn.new(:deployment_indicator, :caption => :label_deployment_indicator)
              columns << QueryColumn.new(:deployment_badge, :caption => :label_deployment_badge)
            end
          end
          columns
        end

        def issues_with_deployment(options = {})
          issues = issues_without_deployment(options)
          Issue.load_deployment_statuses(issues) if DEPLOYMENT_COLUMNS.any? { |name| has_column?(name) }
          issues
        end

        private

        def deployment_columns_available?
          if project
            project.module_enabled?(:deployment) && User.current.allowed_to?(:view_deployments, project)
          else
            User.current.allowed_to?(:view_deployments, nil, :global => true)
          end
        end
      end
    end
  end
end

unless IssueQuery.included_modules.include?(RedmineDeployment::Patches::IssueQueryPatch)
  IssueQuery.send(:include, RedmineDeployment::Patches::IssueQueryPatch)
end
