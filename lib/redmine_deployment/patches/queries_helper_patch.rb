module RedmineDeployment
  module Patches
    module QueriesHelperPatch
      def self.included(base)
        # :nodoc:
        base.send(:include, DeploymentStatusHelper)
        base.send(:include, InstanceMethods)
        base.class_eval do
          alias_method :column_value_without_deployment, :column_value
          alias_method :column_value, :column_value_with_deployment

          alias_method :csv_value_without_deployment, :csv_value
          alias_method :csv_value, :csv_value_with_deployment
        end
      end

      module InstanceMethods
        def column_value_with_deployment(column, item, value)
          # issue queries: the deploy indicator and the deploy badge (see IssueQueryPatch)
          if item.is_a?(Issue) && RedmineDeployment::Patches::IssueQueryPatch::DEPLOYMENT_COLUMNS.include?(column.name)
            return ''.html_safe unless value

            return column.name == :deployment_indicator ? deployment_indicator(value) : deployment_badge(value)
          end
          return column_value_without_deployment(column, item, value) unless item.is_a?(Deployment)

          case column.name
          when :from_revision, :to_revision
            value.blank? ? "-" : link_to_revision_from_deployment(item, column.name)
          when :revisions
            link_to_deployment_revisions(item)
          when :result
            I18n.t(value, scope: 'results')
          else
            column_value_without_deployment(column, item, value)
          end
        end

        # CSV and PDF: the deploy status as text
        def csv_value_with_deployment(column, object, value)
          if object.is_a?(Issue) && RedmineDeployment::Patches::IssueQueryPatch::DEPLOYMENT_COLUMNS.include?(column.name)
            return '' unless value

            return column.name == :deployment_indicator ? deployment_indicator_text(value) : deployment_status_label(value)
          end
          csv_value_without_deployment(column, object, value)
        end

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
          if deployment.to_revision.present? && deployment.from_revision.present?
            ret = ''.html_safe
            ret << link_to_revision_from_deployment(deployment, :from_revision)
            ret << ' ... '
            ret << link_to_revision_from_deployment(deployment, :to_revision)
            ret
          elsif deployment.to_revision.present?
            "000000 ... #{link_to_revision_from_deployment(deployment, :to_revision)}".html_safe
          elsif deployment.from_revision.present?
            "#{link_to_revision_from_deployment(deployment, :from_revision)} ... ?".html_safe
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
    end
  end
end

unless QueriesHelper.included_modules.include?(RedmineDeployment::Patches::QueriesHelperPatch)
  QueriesHelper.send(:include, RedmineDeployment::Patches::QueriesHelperPatch)
end