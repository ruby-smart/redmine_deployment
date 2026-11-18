# frozen_string_literal: true

module RubysmartDeployment
  module Patches
    # Query lists: the cells of the deployment list (revisions as links, the result translated) and the deploy columns
    # of the issue list (see IssueQueryPatch) - in HTML, CSV and PDF.
    #
    # Prepended, not alias_method-chained: the RedmineUP plugins (Contacts, Checklists) prepend
    # QueriesHelper#column_value / #csv_value as well since Redmine 7, and an alias chain over a prepended method
    # recurses endlessly ("stack level too deep" / "no superclass method `column_value'").
    #
    # The helper methods come with the patch (its ancestors are inserted with it): a module included into QueriesHelper
    # afterwards would not reach the views and controllers that included QueriesHelper before.
    module QueriesHelperPatch
      # the helper methods of the deployment views (included, they override nothing)
      module HelperMethods
        def link_to_revision_from_deployment(deployment, target)
          rev = deployment.send(target)

          # no repository or project found
          return rev if deployment.repository.blank? || deployment.project.blank?

          # return link
          link_to(rev[0..7], controller: :repositories, action: :revision, repository_id: deployment.repository.identifier, id: deployment.project.identifier, rev: rev)
        end

        # Linked "from ... to" revision range for a deployment, mirroring
        # Deployment#revisions but with each revision rendered as a link to the
        # repository revision page (falls back to plain text without a repository).
        def link_to_deployment_revisions(deployment)
          from = Deployment.null_revision?(deployment.from_revision) ? nil : :from_revision
          to   = Deployment.null_revision?(deployment.to_revision)   ? nil : :to_revision

          if from && to
            ret = ''.html_safe
            ret << link_to_revision_from_deployment(deployment, from)
            ret << ' ... '
            ret << link_to_revision_from_deployment(deployment, to)
            ret
          elsif to
            "? ... #{link_to_revision_from_deployment(deployment, to)}".html_safe
          elsif from
            "#{link_to_revision_from_deployment(deployment, from)} ... ?".html_safe
          else
            "-"
          end
        end

        def redirect_to_deployment_query(options)
          if @project
            redirect_to project_deployments_path(@project, options)
          else
            redirect_to deployment_path(options)
          end
        end
      end

      include DeploymentStatusHelper
      include HelperMethods

      def column_value(column, item, value)
        # issue queries: the deploy indicator and the deploy badge (see IssueQueryPatch)
        if item.is_a?(Issue) && RubysmartDeployment::Patches::IssueQueryPatch::DEPLOYMENT_COLUMNS.include?(column.name)
          return ''.html_safe unless value

          # the click opens the pipeline of the issue, so neither of them carries a tooltip
          return deployment_status_toggle(item) do
            column.name == :deployment_indicator ? deployment_indicator(value, title: false) : deployment_badge(value, title: false)
          end
        end
        return super unless item.is_a?(Deployment)

        case column.name
        when :from_revision, :to_revision
          # an all-zero revision is Git's "no revision" placeholder, not something to link to
          Deployment.null_revision?(value) ? "-" : link_to_revision_from_deployment(item, column.name)
        when :revisions
          link_to_deployment_revisions(item)
        when :result
          I18n.t(value, scope: 'results')
        else
          super
        end
      end

      # CSV and PDF: the deploy status as text
      def csv_value(column, object, value)
        if object.is_a?(Issue) && RubysmartDeployment::Patches::IssueQueryPatch::DEPLOYMENT_COLUMNS.include?(column.name)
          return '' unless value

          return column.name == :deployment_indicator ? deployment_indicator_text(value) : deployment_status_label(value)
        end
        super
      end
    end
  end
end

unless QueriesHelper.include?(RubysmartDeployment::Patches::QueriesHelperPatch)
  QueriesHelper.prepend(RubysmartDeployment::Patches::QueriesHelperPatch)
end
