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

          if show_deployments_tab?
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

        # Whether to show the "Deployments" tab on the issue page. We deliberately do NOT compute
        # the actual matching deployments here: that requires walking the commit DAG per candidate
        # deployment (see Deployment#changesets / Issue#deployments) and running it on every issue
        # show render caused severe page lag. Instead we show the tab whenever the issue has any
        # changesets and the user may view deployments; the (potentially empty) list of matching
        # deployments is computed lazily when the tab is opened, via IssuesController#issue_tab.
        def show_deployments_tab?
          User.current.allowed_to?(:view_deployments, @project) &&
            @issue.present? && @issue.changesets.exists?
        end
      end
    end
  end
end

unless IssuesHelper.included_modules.include?(RedmineDeployment::Patches::IssuesHelperPatch)
  IssuesHelper.send(:include, RedmineDeployment::Patches::IssuesHelperPatch)
end
