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
end