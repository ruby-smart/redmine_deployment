class Deployment < ApplicationRecord
  include Redmine::SafeAttributes

  RESULT_SUCCESS = 'success'
  RESULT_FAIL    = 'fail'
  RESULTS        = [RESULT_SUCCESS, RESULT_FAIL]

  belongs_to :author, :class_name => 'User', :foreign_key => 'author_id'
  belongs_to :project
  belongs_to :repository

  validates_presence_of :user, :project, :repository
  validates_inclusion_of :result, :in => RESULTS

  acts_as_event :title       => Proc.new { |o| "DEPLOYMENT" },
                :type        => 'deployment',
                :group       => :repository,
                :url         => Proc.new { |o| { controller: :notes, action: :show, id: o.id } },
                :description => Proc.new { |o| "todo" }

  after_create :send_notification

  attr_protected :id if ActiveRecord::VERSION::MAJOR <= 4
  safe_attributes 'from_revision', 'to_revision', 'environment', 'servers'

  def revisions
    if to_revision.blank?
      from_revision
    else
      "#{from_revision} ... #{to_revision}"
    end
  end

  private

  def send_notification

  end
end