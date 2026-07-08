# frozen_string_literal: true

require File.expand_path(File.dirname(__FILE__) + '/../test_helper')

class DeploymentRevisionsHelperTest < Redmine::HelperTest
  include QueriesHelper

  fixtures :projects, :users, :repositories

  def setup
    super
    @project    = Project.find(1)
    @repository = Repository::Git.create!(:project => @project, :url => '/tmp/repo.git')
  end

  def test_link_to_deployment_revisions_links_both_boundaries
    deployment = build_deployment(:from_revision => 'aaaaaaaaaaaa', :to_revision => 'bbbbbbbbbbbb')

    html = link_to_deployment_revisions(deployment)

    assert_select_in html, 'a', 2
    assert_select_in html, 'a[href=?]', revision_path('aaaaaaaaaaaa')
    assert_select_in html, 'a[href=?]', revision_path('bbbbbbbbbbbb')
    assert_includes html, ' ... '
  end

  def test_link_to_deployment_revisions_with_only_to_revision
    deployment = build_deployment(:from_revision => nil, :to_revision => 'bbbbbbbbbbbb')

    html = link_to_deployment_revisions(deployment)

    assert_includes html, '000000 ... '
    assert_select_in html, 'a[href=?]', revision_path('bbbbbbbbbbbb')
  end

  def test_link_to_deployment_revisions_falls_back_to_plain_text_without_repository
    deployment = build_deployment(:from_revision => 'aaaaaaaaaaaa', :to_revision => 'bbbbbbbbbbbb')
    deployment.repository = nil

    html = link_to_deployment_revisions(deployment)

    assert_not_includes html, '<a '
    assert_includes html, 'aaaaaaaaaaaa'
    assert_includes html, 'bbbbbbbbbbbb'
  end

  private

  def revision_path(rev)
    url_for(:controller => 'repositories', :action => 'revision', :only_path => true,
            :repository_id => @repository.identifier, :id => @project.identifier, :rev => rev)
  end

  def build_deployment(attrs = {})
    Deployment.new({
      :project    => @project,
      :repository => @repository,
      :author     => User.find(2),
      :result     => Deployment::RESULT_SUCCESS
    }.merge(attrs))
  end
end
