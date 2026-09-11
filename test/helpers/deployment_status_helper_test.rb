# frozen_string_literal: true

require File.expand_path(File.dirname(__FILE__) + '/../test_helper')

# the central methods to render the deploy status: indicator, badge and pipeline
class DeploymentStatusHelperTest < Redmine::HelperTest
  include DeploymentStatusHelper

  Status      = RedmineDeployment::DeployStatus::Result
  Environment = RedmineDeployment::DeployStatus::Environment
  Code        = RedmineDeployment::Environments::Code

  def test_indicator
    html = deployment_indicator(status([0, 1, 2], code: Code.new('Git', '#445566')))

    assert_select_in html, 'span.deploy-seg' do |indicator|
      assert indicator.first['title'].start_with?("Live\nGit: 2 commits"), indicator.first['title']
      assert_select 'i', 4
      assert_select 'i.on[style=?]', '--e: #445566', 1 # the step "Code"
      assert_select 'i.off[style=?]', '--e: #2f6db5'
      assert_select 'i.partial[style=?]', '--e: #7657b8'
      assert_select 'i.on[style=?]', '--e: #2f9e44'
    end
  end

  def test_badge_states
    assert_select_in deployment_badge(status([2, 2, 2])), 'span.deploy-badge.deploy-badge-live[style=?]', '--e: #2f9e44', text: 'Live'
    assert_select_in deployment_badge(status([2, 2, 0])), 'span.deploy-badge.deploy-badge-reached[style=?]', '--e: #7657b8', text: 'Staging'
    assert_select_in deployment_badge(status([2, 1, 0])), 'span.deploy-badge.deploy-badge-partial', text: 'Staging'
    # skipped environments: the last one with commits
    assert_select_in deployment_badge(status([0, 0, 2])), 'span.deploy-badge.deploy-badge-live', text: 'Live'
    # only "Code" - its label and color of the pipeline
    assert_select_in deployment_badge(status([0, 0, 0])), 'span.deploy-badge.deploy-badge-code[style=?]', '--e: #66707a', text: 'Code'
    assert_select_in deployment_badge(status([0, 0, 0], code: Code.new('Commits', '#c2417f'))),
                     'span.deploy-badge.deploy-badge-code[style=?][title^=?]', '--e: #c2417f', 'Commits: 2 commits', text: 'Commits'
  end

  def test_pipeline_is_the_indicator_and_the_badge
    html = deployment_pipeline(status([2, 2, 2]))

    assert_select_in html, 'span.deploy-pipe.deploy-pipe-live' do
      assert_select '> span.deploy-seg + span.deploy-badge.deploy-badge-live', text: 'Live'
    end
  end

  private

  # covered changesets (of 2) of the environments Develop, Staging, Live
  def status(covered, code: Code.new(nil, RedmineDeployment::Environments::CODE_COLOR))
    environments = [%w[Develop #2f6db5], %w[Staging #7657b8], %w[Live #2f9e44]].each_with_index.map do |(label, color), index|
      Environment.new(key: "deployment:#{label.downcase}", label: label, color: color, covered: covered[index], total: 2)
    end
    Status.new(changeset_count: 2, code: code, environments: environments)
  end
end
