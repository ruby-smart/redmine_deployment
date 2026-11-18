# frozen_string_literal: true

module RubysmartDeployment
  module Patches
    # The issue page: the deploy status right of the subject and the tab "Deployment".
    #
    # Prepended, not alias_method-chained: the RedmineUP plugins prepend IssuesHelper#issue_history_tabs as well since
    # Redmine 7, and an alias chain over a prepended method recurses endlessly.
    #
    # DeploymentStatusHelper comes with the patch (its ancestors are inserted with it): a module included into
    # IssuesHelper afterwards would not reach the views that included IssuesHelper before.
    module IssuesHelperPatch
      include DeploymentStatusHelper

      # The issue page: the deploy status of the issue right of its subject (the h3 in the details box) - it floats
      # right in front of the subject (see DeploymentStatusHelper#deployment_issue_status).
      def render_issue_subject_with_tree(issue)
        html   = super
        status = deployment_issue_status(issue)
        status.present? ? html.to_str.sub('<h3>', "#{status}<h3>").html_safe : html
      end

      def issue_history_tabs
        tabs = super

        if show_deployments_tab?
          tabs <<
            {
              :name    => 'deployments',
              :label   => :label_deployment_issue_tab,
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

unless IssuesHelper.include?(RubysmartDeployment::Patches::IssuesHelperPatch)
  IssuesHelper.prepend(RubysmartDeployment::Patches::IssuesHelperPatch)
end
