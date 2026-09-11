module RedmineDeployment
  module Patches
    module ProjectPatch
      def self.included(base) # :nodoc:
        base.class_eval do
          has_many :deployments
          # the project's own deployment pipeline (DeploymentSetting - plugin settings 'projects')
          after_destroy { DeploymentSetting.delete_project(id) }
        end
      end
    end
  end
end

unless Project.included_modules.include?(RedmineDeployment::Patches::ProjectPatch)
  Project.send(:include, RedmineDeployment::Patches::ProjectPatch)
end