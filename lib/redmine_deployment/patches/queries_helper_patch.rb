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
          if item.is_a?(Deployment) && %i[from_revision to_revision].include?(column.name)
            link_to(value, controller: :repositories, action: :revision, repository_id: item.repository.identifier, id: item.project.identifier, rev: value)
          else
            column_value_without_deployment(column, item, value)
          end
        end
      end
    end
  end
end

unless QueriesHelper.included_modules.include?(RedmineDeployment::Patches::QueriesHelperPatch)
  QueriesHelper.send(:include, RedmineDeployment::Patches::QueriesHelperPatch)
end