# frozen_string_literal: true

module RedmineDeployment
  module Patches
    # A deployment is usually logged before its revisions are fetched into Redmine (the deploy hook reports it right
    # after the push), so its changesets can't be resolved at once (Deployment#resolve_changesets! leaves it
    # pending). They are resolved as soon as the repository fetched new changesets - right after
    # Repository::Git#save_revisions stored them, be it from the repository page (autofetch), the sys API or the
    # rake task redmine:fetch_changesets.
    #
    # Prepended (not alias-chained): +save_revisions+ is private.
    #
    # +tag_revisions+: the commits of the tags (the pipeline steps "tag", see RedmineDeployment::DeployStatus).
    module RepositoryGitPatch
      # one line per tag: its object, the commit of an annotated tag (empty for a lightweight one) and its name
      TAG_FORMAT = '%(objectname) %(*objectname) %(refname)'
      TAG_LINE   = %r{\A(\h{40}) (\h{40})? refs/tags/(.+)\z}.freeze

      # The tags of the repository with their commits (<tt>git for-each-ref refs/tags</tt> - one call, annotated tags
      # dereferenced to their commit). Redmine's +tags+ has the names only.
      #
      # @return [Hash{String => String}] revision of the commit by tag name
      def tag_revisions
        revisions = {}
        scm.send(:git_cmd, ['for-each-ref', "--format=#{TAG_FORMAT}", 'refs/tags']) do |io|
          io.each_line do |line|
            match = TAG_LINE.match(line.chomp)
            revisions[scm_iconv_tag(match[3])] = match[2] || match[1] if match
          end
        end
        revisions
      end

      private

      def scm_iconv_tag(name)
        scm.send(:scm_iconv, 'UTF-8', scm.path_encoding, name)
      end

      def save_revisions(prev_db_heads, repo_heads)
        result = super
        resolve_pending_deployment_changesets
        result
      end

      # The pending deployments of this repository, resolved right here (a few indexed queries and one recursive
      # query each, typically a handful of deployments) rather than enqueued: the fetch runs from the rake task and
      # the sys API as well, where a job of the async queue adapter wouldn't survive the end of the process.
      def resolve_pending_deployment_changesets
        Deployment.where(:repository_id => id).changesets_pending.find_each(&:resolve_changesets!)
      rescue StandardError => e
        Rails.logger.error("RedmineDeployment: resolving the pending deployments of repository #{id} failed: #{e.message}")
      end
    end
  end
end

unless Repository::Git.ancestors.include?(RedmineDeployment::Patches::RepositoryGitPatch)
  Repository::Git.prepend(RedmineDeployment::Patches::RepositoryGitPatch)
end
