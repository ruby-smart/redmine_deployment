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

  def revisions
    if to_revision.present? && from_revision.present?
      "#{from_revision[0..7]} ... #{to_revision[0..7]}"
    elsif to_revision.present?
      "000000 ... #{to_revision[0..7]}"
    elsif from_revision.present?
      "#{from_revision[0..7]} ... ?"
    else
      "-"
    end
  end

  # Changesets deployed by this deployment, i.e. those committed after +from_revision+
  # and up to (and including) +to_revision+. Falls back to an open-ended range when only
  # one of the boundary revisions is known.
  def changesets
    return Changeset.none unless repository

    from_changeset = from_revision.present? ? repository.find_changeset_by_name(from_revision) : nil
    to_changeset   = to_revision.present?   ? repository.find_changeset_by_name(to_revision)   : nil

    scope = repository.changesets
    scope = scope.where("#{Changeset.table_name}.committed_on <= ?", to_changeset.committed_on) if to_changeset
    scope = scope.where("#{Changeset.table_name}.committed_on > ?", from_changeset.committed_on) if from_changeset
    scope
  end

  # Issues referenced by the changesets that are part of this deployment
  def related_issues
    return Issue.none unless repository

    Issue.joins(:changesets).
      where(:changesets => { :id => changesets.select(:id) }).
      distinct
  end
end