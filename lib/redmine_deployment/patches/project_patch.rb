module RedmineDeployment
  module Patches
    module ProjectPatch
      def self.included(base) # :nodoc:
        base.class_eval do
          has_many :deployments
        end
      end
    end
  end
end

unless Project.included_modules.include?(RedmineDeployment::Patches::ProjectPatch)
  Project.send(:include, RedmineDeployment::Patches::ProjectPatch)
end