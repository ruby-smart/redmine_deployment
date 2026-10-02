module RedmineDeployment
  module Patches
    module ChangesetPatch
      def self.included(base) # :nodoc:
        base.class_eval do
          # the deployments the changeset is part of (DeploymentChangeset) - gone with the changeset
          has_many :deployment_changesets, :dependent => :delete_all
        end
      end

      def branches
        @branches ||= if repository.scm_adapter != Redmine::Scm::Adapters::GitAdapter
                        []
                      else
                        branches = []
                        begin
                          repository.scm.send(:git_cmd, ["branch", "--contains=#{self.revision}"]) do |io|
                            io.each_line do |line|
                              branches << line.gsub('*','').strip
                            end
                          end
                        rescue
                          branches = []
                        end

                        branches.compact_blank
                      end
      end
    end
  end
end

unless Changeset.included_modules.include?(RedmineDeployment::Patches::ChangesetPatch)
  Changeset.send(:include, RedmineDeployment::Patches::ChangesetPatch)
end
