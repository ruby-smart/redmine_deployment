# frozen_string_literal: true

module RedmineDeployment
  module Patches
    module IssuesHelperPatch
      def self.included(base) # :nodoc:
        base.send(:include, InstanceMethods)
        base.class_eval do
          alias_method :issue_history_tabs_without_deployment, :issue_history_tabs
          alias_method :issue_history_tabs, :issue_history_tabs_with_deployment
        end
      end

      module InstanceMethods
        def issue_history_tabs_with_deployment
          tabs = issue_history_tabs_without_deployment

          if User.current.allowed_to?(:view_deployments, @project) && issue_deployments.present?
            tabs <<
              {
                :name    => 'deployments',
                :label   => :label_deployment_plural,
                :remote  => true,
                :onclick =>
                  "getRemoteTab('deployments', " \
                  "'#{tab_issue_path(@issue, :name => 'deployments')}', " \
                  "'#{issue_path(@issue, :tab => 'deployments')}')"
              }
          end

          tabs
        end

        # Deployments associated with the currently shown issue, memoized so the (potentially
        # expensive) lookup runs at most once per request. Only used to decide whether the tab
        # is shown; the tab content itself is loaded remotely via IssuesController#issue_tab.
        def issue_deployments
          @issue_deployments ||= @issue ? @issue.deployments.to_a : []
        end
      end
    end
  end
end

unless IssuesHelper.included_modules.include?(RedmineDeployment::Patches::IssuesHelperPatch)
  IssuesHelper.send(:include, RedmineDeployment::Patches::IssuesHelperPatch)
end
