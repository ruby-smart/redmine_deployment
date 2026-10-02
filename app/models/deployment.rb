# frozen_string_literal: true

class Deployment < ApplicationRecord
  include Redmine::SafeAttributes

  RESULT_SUCCESS = 'success'
  RESULT_FAIL    = 'fail'
  RESULTS        = [RESULT_SUCCESS, RESULT_FAIL]

  belongs_to :author, :class_name => 'User', :foreign_key => 'author_id'
  belongs_to :project
  # Optional so a deployment can outlive its repository: repositories are not deleted
  # together with their deployments (see RepositoryPatch's +has_many :deployments+ without
  # +dependent:+), leaving existing records with a dangling +repository_id+. A repository is
  # still required when creating a deployment (validation below).
  belongs_to :repository, :optional => true
  # the changesets of the commit range +from_revision..to_revision+, stored by +resolve_changesets!+
  has_many :deployment_changesets, :dependent => :delete_all

  validates_presence_of :author, :project
  validates_presence_of :repository, :on => :create
  validates_inclusion_of :result, :in => RESULTS

  # Resolving the changesets reads the commit graph - never in the request that logs the deployment: the deploy
  # process must not wait for it. A job of the background queue does it right after the commit.
  after_commit :resolve_changesets_later, :on => :create

  # deployments whose changesets have not been resolved (yet) - see +resolve_changesets!+
  scope :changesets_pending, -> { where(:changesets_resolved_at => nil) }

  attr_protected :id if ActiveRecord::VERSION::MAJOR <= 4
  safe_attributes 'from_revision', 'to_revision', 'environment', 'servers', 'result', 'branch'

  # Git spells "no revision" as an all-zero SHA - the null revision of its hooks
  # ("0000000000000000000000000000000000000000"), which deploy scripts routinely abbreviate
  # to any number of zeros ("000000"). Such a value is a placeholder, not a revision.
  NULL_REVISION = /\A0+\z/.freeze

  # True when the given revision means "none": blank, or Git's null revision.
  #
  # An all-zero value must never be resolved against the repository: Repository::Git's
  # +find_changeset_by_name+ falls back to an <tt>scmid LIKE "<name>%"</tt> prefix match, so a
  # short placeholder like "000000" happily matches any commit whose id starts with zeros and
  # would turn an "unknown boundary" into an arbitrary commit range.
  def self.null_revision?(revision)
    revision.blank? || NULL_REVISION.match?(revision.to_s.strip)
  end

  # Resolves the changesets of the deployments of the scope (see +resolve_changesets!+) - the rake task
  # redmine:deployment:resolve_changesets.
  #
  # @param [ActiveRecord::Relation] scope the deployments, the pending ones by default
  # @return [Hash] <tt>{ :resolved => count, :unresolved => { 'reason' => count } }</tt>
  def self.resolve_changesets!(scope = changesets_pending)
    summary = { :resolved => 0, :unresolved => Hash.new(0) }
    scope.preload(:repository).find_each do |deployment|
      if deployment.resolve_changesets!
        summary[:resolved] += 1
      else
        summary[:unresolved][deployment.changesets_error] += 1
      end
    end
    summary
  end

  def revisions
    from = self.class.null_revision?(from_revision) ? nil : from_revision
    to   = self.class.null_revision?(to_revision)   ? nil : to_revision

    if from && to
      "#{from[0..7]} ... #{to[0..7]}"
    elsif to
      "? ... #{to[0..7]}"
    elsif from
      "#{from[0..7]} ... ?"
    else
      "-"
    end
  end

  # Changesets deployed by this deployment: the git commit range +from_revision..to_revision+, i.e. commits
  # reachable from +to_revision+ by following the parent DAG, minus commits reachable from +from_revision+
  # (exclusive of +from_revision+, inclusive of +to_revision+ - <tt>git log from..to</tt>, which unlike a
  # commit-time window correctly excludes commits on other branches that were never merged). The range is
  # resolved once and stored (DeploymentChangeset, see +resolve_changesets!+): this is an indexed lookup,
  # nothing walks the commit graph here.
  #
  # BOTH boundaries are required. A deployment that is missing one of them (a failed or incompletely reported
  # deployment) has an *undefined* range, not an open-ended one: it returns no changesets at all.
  #
  # Returns an ActiveRecord::Relation so callers can chain +preload+/+reorder+/+select+. While the range is not
  # resolved (yet) or can't be (see +changesets_unavailable_reason+) it returns +Changeset.none+.
  def changesets
    return Changeset.none if changesets_unavailable_reason

    Changeset.where(:id => deployment_changesets.select(:changeset_id))
  end

  # Explains why +changesets+ is empty for reasons other than "the range genuinely contains
  # no commits", so the view can show a meaningful notice. Returns a symbol or +nil+:
  #   :no_repository       - the deployment has no repository
  #   :incomplete_range    - +from_revision+ and/or +to_revision+ is missing (blank or Git's
  #                          null revision), so there is no range
  #   :dag_unavailable     - non-git repo, or a git repo whose parent graph was never populated
  #                          (found by the last attempt to resolve the changesets)
  #   :revision_not_found  - a boundary revision has not been fetched into Redmine yet (found by
  #                          the last attempt - tried again after the next fetch of the repository)
  #   :not_resolved        - the changesets have not been resolved yet (see +resolve_changesets!+)
  def changesets_unavailable_reason
    return :no_repository unless repository
    return :incomplete_range if self.class.null_revision?(from_revision) || self.class.null_revision?(to_revision)
    return changesets_error.to_sym if changesets_error.present?
    return :not_resolved unless changesets_resolved?

    nil
  end

  # true, if the changesets of the commit range are stored (see +resolve_changesets!+)
  def changesets_resolved?
    changesets_resolved_at.present?
  end

  # Issues referenced by the changesets that are part of this deployment
  def related_issues
    return Issue.none if changesets_unavailable_reason

    Issue.joins(:changesets).
      where(:changesets => { :id => deployment_changesets.select(:changeset_id) }).
      distinct
  end

  # Resolves the commit range +from_revision..to_revision+ (RedmineDeployment::CommitRange - one recursive query)
  # and stores its changesets (DeploymentChangeset). Once: the range of a deployment never changes. It runs in
  # the background - ResolveDeploymentChangesetsJob right after the deployment was logged, after the repository
  # fetched new changesets (RedmineDeployment::Patches::RepositoryGitPatch) and from the rake task
  # redmine:deployment:resolve_changesets - never in a request.
  #
  # A deployment without a range (no repository, a missing boundary - see +changesets_unavailable_reason+) is
  # resolved as "no changesets". A boundary that has not been fetched into Redmine yet, or a repository without
  # a commit graph, leaves the deployment pending (+changesets_pending+, +changesets_error+ names the reason):
  # it is tried again after the next fetch of the repository and by the rake task.
  #
  # @return [Boolean] true, if the changesets are resolved now
  def resolve_changesets!
    return false if new_record?

    from = to = nil
    error =
      if repository.nil? || self.class.null_revision?(from_revision) || self.class.null_revision?(to_revision)
        nil # no range at all - resolved as "nothing" (the reason is derived from the record)
      elsif !RedmineDeployment::CommitRange.dag_available?(repository)
        :dag_unavailable
      else
        from = repository.find_changeset_by_name(from_revision)
        to   = repository.find_changeset_by_name(to_revision)
        :revision_not_found unless from && to
      end

    if error
      transaction do
        deployment_changesets.delete_all
        update_columns(:changesets_resolved_at => nil, :changesets_error => error.to_s)
      end
      return false
    end

    store_changesets(from && to ? RedmineDeployment::CommitRange.ids(to.id, from.id) : [])
    true
  end

  private

  def resolve_changesets_later
    ResolveDeploymentChangesetsJob.perform_later(id)
  end

  def store_changesets(changeset_ids)
    rows = changeset_ids.map { |changeset_id| { :deployment_id => id, :changeset_id => changeset_id } }
    transaction do
      deployment_changesets.delete_all
      DeploymentChangeset.insert_all(rows) if rows.any?
      update_columns(:changesets_resolved_at => Time.now, :changesets_error => nil)
    end
  end
end
