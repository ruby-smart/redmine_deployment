# frozen_string_literal: true

module RubysmartDeployment
  module Patches
    # Issue queries: the columns "deploy indicator" and "deploy badge" (the deploy status of the issues, see
    # DeploymentStatusHelper) - available with the module "deployment" and the permission +view_deployment_indicator+. The
    # deploy statuses of the listed issues are loaded at once (like the spent hours of Redmine).
    #
    # Prepended, not alias_method-chained: the RedmineUP plugins prepend IssueQuery#available_columns as well since
    # Redmine 7, and an alias chain over a prepended method recurses endlessly ("stack level too deep").
    module IssueQueryPatch
      DEPLOYMENT_COLUMNS = [:deployment_indicator, :deployment_badge].freeze

      def available_columns
        columns = super
        unless @deployment_columns_added
          @deployment_columns_added = true
          if deployment_columns_available?
            columns << QueryColumn.new(:deployment_indicator, :caption => :label_deployment_indicator)
            columns << QueryColumn.new(:deployment_badge, :caption => :label_deployment_badge)
          end
        end
        columns
      end

      def issues(options = {})
        issues = super
        Issue.load_deployment_statuses(issues) if DEPLOYMENT_COLUMNS.any? { |name| has_column?(name) }
        issues
      end

      private

      def deployment_columns_available?
        if project
          project.module_enabled?(:deployment) &&
            User.current.allowed_to?(RubysmartDeployment::DeployStatus::INDICATOR_PERMISSION, project)
        else
          User.current.allowed_to?(RubysmartDeployment::DeployStatus::INDICATOR_PERMISSION, nil, :global => true)
        end
      end
    end
  end
end

unless IssueQuery.include?(RubysmartDeployment::Patches::IssueQueryPatch)
  IssueQuery.prepend(RubysmartDeployment::Patches::IssueQueryPatch)
end
