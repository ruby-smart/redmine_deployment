module RedmineDeployment
  module Patches
    module RepositoryPatch
      def self.included(base) # :nodoc:
        base.class_eval do
          has_many :deployments
        end
      end
    end
  end
end

unless Repository.included_modules.include?(RedmineDeployment::Patches::RepositoryPatch)
  Repository.send(:include, RedmineDeployment::Patches::RepositoryPatch)
end