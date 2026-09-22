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
            # an all-zero revision is Git's "no revision" placeholder, not something to link to
            Deployment.null_revision?(value) ? "-" : link_to_revision_from_deployment(item, column.name)
          when :revisions
            from = Deployment.null_revision?(item.from_revision) ? nil : :from_revision
            to   = Deployment.null_revision?(item.to_revision)   ? nil : :to_revision

            if from && to
              ret = ''.html_safe
              ret << link_to_revision_from_deployment(item, from)
              ret << ' ... '
              ret << link_to_revision_from_deployment(item, to)
              ret
            elsif to
              "? ... #{link_to_revision_from_deployment(item, to)}".html_safe
            elsif from
              "#{link_to_revision_from_deployment(item, from)} ... ?".html_safe
            else
              "-"
            end
          when :result
            I18n.t(value, scope: 'results')
          else
            column_value_without_deployment(column, item, value)
          end
        end

        def link_to_revision_from_deployment(deployment, target)
          rev = deployment.send(target)

          # no repository or project found
          return rev if deployment.repository.blank? || deployment.project.blank?

          # return link
          link_to(rev[0..7], controller: :repositories, action: :revision, repository_id: deployment.repository.identifier, id: deployment.project.identifier, rev: rev)
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