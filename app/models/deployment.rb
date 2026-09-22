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

  validates_presence_of :author, :project
  validates_presence_of :repository, :on => :create
  validates_inclusion_of :result, :in => RESULTS

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

  # Defensive upper bound on how many changesets we walk while computing a range,
  # guarding against pathological histories. Logged if hit; never silently truncated.
  MAX_TRAVERSAL = 50_000

  # Changesets deployed by this deployment: the git commit range +from_revision..to_revision+,
  # i.e. commits reachable from +to_revision+ by following the parent DAG, minus commits
  # reachable from +from_revision+ (exclusive of +from_revision+, inclusive of +to_revision+).
  # This mirrors <tt>git log from..to</tt> and, unlike a commit-time window, correctly excludes
  # commits on other branches that were never merged into the deployed revision.
  #
  # BOTH boundaries are required. A deployment that is missing one of them (a failed or
  # incompletely reported deployment) has an *undefined* range, not an open-ended one: it
  # returns no changesets at all. Treating a missing +from_revision+ as "since the root commit"
  # used to make such a deployment claim the entire repository history - every changeset and
  # every issue ever referenced - which made the detail page effectively never finish loading.
  #
  # Returns an ActiveRecord::Relation so callers can chain +preload+/+reorder+/+select+.
  # When the range cannot be computed from the DAG (see +changesets_unavailable_reason+) it
  # returns +Changeset.none+ rather than falling back to an approximate time window.
  def changesets
    return Changeset.none if changesets_unavailable_reason

    ids = changeset_range_ids
    ids.empty? ? Changeset.none : repository.changesets.where(:id => ids)
  end

  # Explains why +changesets+ is empty for reasons other than "the range genuinely contains
  # no commits", so the view can show a meaningful notice. Returns a symbol or +nil+:
  #   :no_repository       - the deployment has no repository
  #   :incomplete_range    - +from_revision+ and/or +to_revision+ is missing (blank or Git's
  #                          null revision), so there is no range
  #   :dag_unavailable     - non-git repo, or a git repo whose parent graph was never populated
  #   :revision_not_found  - a boundary revision has not been fetched into Redmine yet
  def changesets_unavailable_reason
    return :no_repository unless repository
    return :incomplete_range if self.class.null_revision?(from_revision) || self.class.null_revision?(to_revision)
    return :dag_unavailable unless dag_available?
    return :revision_not_found unless resolved_from_changeset && resolved_to_changeset

    nil
  end

  # Issues referenced by the changesets that are part of this deployment
  def related_issues
    return Issue.none unless repository

    Issue.joins(:changesets).
      where(:changesets => { :id => changesets.select(:id) }).
      distinct
  end

  private

  # Ids of the changesets in this deployment's +from..to+ range, memoized so the (expensive) DAG
  # walk runs at most once per instance even when +changesets+/+related_issues+ are both called
  # in a single request (e.g. the deployment show page).
  def changeset_range_ids
    return @changeset_range_ids if defined?(@changeset_range_ids)

    @changeset_range_ids = commit_range_ids(resolved_from_changeset, resolved_to_changeset)
  end

  def resolved_from_changeset
    return @resolved_from_changeset if defined?(@resolved_from_changeset)

    @resolved_from_changeset =
      self.class.null_revision?(from_revision) ? nil : repository.find_changeset_by_name(from_revision)
  end

  def resolved_to_changeset
    return @resolved_to_changeset if defined?(@resolved_to_changeset)

    @resolved_to_changeset =
      self.class.null_revision?(to_revision) ? nil : repository.find_changeset_by_name(to_revision)
  end

  # True when the parent DAG is usable for this repository: a git repository whose
  # +changeset_parents+ edges have actually been populated.
  def dag_available?
    return @dag_available if defined?(@dag_available)

    @dag_available =
      repository.is_a?(Repository::Git) &&
      ChangesetParent.where(:changeset_id => repository.changesets.select(:id)).exists?
  end

  # Ids of the commits in the range +from_changeset..to_changeset+ (inclusive of +to+,
  # exclusive of +from+ and its ancestors). Walks up the parent DAG from +to+, pruning the
  # cone of ancestors of +from+.
  def commit_range_ids(from_changeset, to_changeset)
    # Both boundaries required - see +changesets+. Without +from+ the walk below would run all
    # the way to the root commit and return the whole repository history.
    return [] unless from_changeset && to_changeset

    excluded = ancestor_ids([from_changeset.id])
    result   = Set.new
    visited  = Set.new([to_changeset.id])
    frontier = [to_changeset.id]

    while frontier.any? && result.size < MAX_TRAVERSAL
      frontier.each { |id| result << id unless excluded.include?(id) }
      parent_ids = parent_ids_for(frontier)
      frontier = parent_ids.reject { |pid| visited.include?(pid) || excluded.include?(pid) }
      visited.merge(frontier)
    end

    warn_traversal_cap('commit_range_ids') if result.size >= MAX_TRAVERSAL
    result.to_a
  end

  # All ancestor ids of the given seeds, inclusive of the seeds themselves.
  def ancestor_ids(seed_ids)
    visited  = Set.new(seed_ids)
    frontier = seed_ids

    while frontier.any? && visited.size < MAX_TRAVERSAL
      parent_ids = parent_ids_for(frontier)
      frontier = parent_ids.reject { |pid| visited.include?(pid) }
      visited.merge(frontier)
    end

    warn_traversal_cap('ancestor_ids') if visited.size >= MAX_TRAVERSAL
    visited
  end

  def parent_ids_for(changeset_ids)
    return [] if changeset_ids.empty?

    ChangesetParent.where(:changeset_id => changeset_ids).distinct.pluck(:parent_id)
  end

  def warn_traversal_cap(context)
    Rails.logger.warn(
      "Deployment##{id}: #{context} hit MAX_TRAVERSAL (#{MAX_TRAVERSAL}); " \
      'changeset range may be incomplete.'
    )
  end
end
