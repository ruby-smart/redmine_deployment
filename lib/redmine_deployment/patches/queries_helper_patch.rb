module RedmineDeployment
  module Patches
    module QueriesHelperPatch
      def self.included(base)
        # :nodoc:
        base.send(:include, InstanceMethods)
        base.class_eval do
          alias_method :column_value_without_deployment, :column_value
          alias_method :column_value, :column_value_with_deployment
        end
      end

      module InstanceMethods
        def column_value_with_deployment(column, item, value)
          return column_value_without_deployment(column, item, value) unless item.is_a?(Deployment)

          case column.name
          when :from_revision, :to_revision
            link_to(value, controller: :repositories, action: :revision, repository_id: item.repository.identifier, id: item.project.identifier, rev: value)
          when :revisions
            if item.to_revision.blank?
              link_to(item.from_revision, controller: :repositories, action: :revision, repository_id: item.repository.identifier, id: item.project.identifier, rev: item.from_revision)
            else
              ret = ''.html_safe
              ret << link_to(item.from_revision, controller: :repositories, action: :revision, repository_id: item.repository.identifier, id: item.project.identifier, rev: item.from_revision)
              ret << ' ... '
              ret << link_to(item.to_revision, controller: :repositories, action: :revision, repository_id: item.repository.identifier, id: item.project.identifier, rev: item.to_revision)
              ret
            end
          when :result
            I18n.t(value, scope: 'results')
          else
            column_value_without_deployment(column, item, value)
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