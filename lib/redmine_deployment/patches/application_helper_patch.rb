module RedmineDeployment
  module Patches
    module ApplicationHelperPatch
      def self.included(base)
        # :nodoc:
        base.send(:include, InstanceMethods)
        base.class_eval do
          alias_method :format_object_without_deployment, :format_object
          alias_method :format_object, :format_object_with_deployment
        end
      end

      module InstanceMethods
        def format_object_with_deployment(object, html = true, &block)
          case object
          when Repository
            link_to(object.identifier, controller: :repositories, action: :show, repository_id: object.identifier, id: object.project.identifier)
          else
            format_object_without_deployment(object, html, &block)
          end
        end
      end
    end
  end
end

unless ApplicationHelper.included_modules.include?(RedmineDeployment::Patches::ApplicationHelperPatch)
  ApplicationHelper.send(:include, RedmineDeployment::Patches::ApplicationHelperPatch)
end