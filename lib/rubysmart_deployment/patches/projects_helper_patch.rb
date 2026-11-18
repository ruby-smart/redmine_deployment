# frozen_string_literal: true

module RubysmartDeployment
  module Patches
    # project settings: the tab "Deployment" - the project's own deployment pipeline (see DeploymentSetting)
    #
    # Prepended, not alias_method-chained: the RedmineUP plugins prepend ProjectsHelper#project_settings_tabs as well
    # since Redmine 7, and an alias chain over a prepended method recurses endlessly.
    module ProjectsHelperPatch
      def project_settings_tabs
        tabs = super
        if @project&.module_enabled?(:deployment) && User.current.allowed_to?(:manage_deployment_settings, @project)
          tabs << { :name => 'deployment', :action => :manage_deployment_settings,
                    :partial => 'projects/settings/deployment', :label => :label_deployment }
        end
        tabs
      end
    end
  end
end

unless ProjectsHelper.include?(RubysmartDeployment::Patches::ProjectsHelperPatch)
  ProjectsHelper.prepend(RubysmartDeployment::Patches::ProjectsHelperPatch)
end
