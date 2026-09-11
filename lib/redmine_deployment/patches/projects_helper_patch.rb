# frozen_string_literal: true

module RedmineDeployment
  module Patches
    # project settings: the tab "Deployment" - the project's own deployment pipeline (see DeploymentSetting)
    module ProjectsHelperPatch
      def self.included(base) # :nodoc:
        base.send(:include, InstanceMethods)
        base.class_eval do
          alias_method :project_settings_tabs_without_deployment, :project_settings_tabs
          alias_method :project_settings_tabs, :project_settings_tabs_with_deployment
        end
      end

      module InstanceMethods
        def project_settings_tabs_with_deployment
          tabs = project_settings_tabs_without_deployment
          if @project&.module_enabled?(:deployment) && User.current.allowed_to?(:manage_deployment_settings, @project)
            tabs << { :name => 'deployment', :action => :manage_deployment_settings,
                      :partial => 'projects/settings/deployment', :label => :label_deployment }
          end
          tabs
        end
      end
    end
  end
end

unless ProjectsHelper.included_modules.include?(RedmineDeployment::Patches::ProjectsHelperPatch)
  ProjectsHelper.send(:include, RedmineDeployment::Patches::ProjectsHelperPatch)
end
