class Deployment < ApplicationRecord
  include Redmine::SafeAttributes

  RESULT_SUCCESS = 'success'
  RESULT_FAIL    = 'fail'
  RESULTS        = [RESULT_SUCCESS, RESULT_FAIL]

  belongs_to :author, :class_name => 'User', :foreign_key => 'author_id'
  belongs_to :project
  belongs_to :repository

  validates_presence_of :author, :project, :repository
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

  # Changesets deployed by this deployment, i.e. those committed after +from_revision+
  # and up to (and including) +to_revision+.
  #
  # BOTH boundaries are required. A deployment that is missing one of them (a failed or
  # incompletely reported deployment) has an *undefined* range, not an open-ended one: it
  # deploys nothing. Falling back to an open-ended range used to leave the scope unfiltered,
  # so such a deployment claimed the entire repository history - every changeset and every
  # issue ever referenced, rendered unpaginated - which made the detail page effectively
  # never finish loading.
  def changesets
    return Changeset.none if changesets_unavailable_reason

    repository.changesets.
      where("#{Changeset.table_name}.committed_on > ?", from_changeset.committed_on).
      where("#{Changeset.table_name}.committed_on <= ?", to_changeset.committed_on)
  end

  # Explains why +changesets+ is empty for reasons other than "the range genuinely contains
  # no commits", so the view can show a meaningful notice. Returns a symbol or +nil+:
  #   :no_repository       - the deployment has no repository
  #   :incomplete_range    - +from_revision+ and/or +to_revision+ is blank, so there is no range
  #   :revision_not_found  - a boundary revision has not been fetched into Redmine yet
  def changesets_unavailable_reason
    return :no_repository unless repository
    return :incomplete_range if self.class.null_revision?(from_revision) || self.class.null_revision?(to_revision)
    return :revision_not_found unless from_changeset && to_changeset

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

  # The boundary changesets, memoized: +changesets+ and +changesets_unavailable_reason+ both
  # resolve them, and the detail page calls both in a single request.
  def from_changeset
    return @from_changeset if defined?(@from_changeset)

    @from_changeset = self.class.null_revision?(from_revision) ? nil : repository.find_changeset_by_name(from_revision)
  end

  def to_changeset
    return @to_changeset if defined?(@to_changeset)

    @to_changeset = self.class.null_revision?(to_revision) ? nil : repository.find_changeset_by_name(to_revision)
  end
end