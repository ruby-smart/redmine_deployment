# frozen_string_literal: true

require File.expand_path('../test_helper', __dir__)

class EnvironmentsTest < ActiveSupport::TestCase
  fixtures :projects

  Environments = RedmineDeployment::Environments

  def setup
    Setting.clear_cache
    Setting.plugin_redmine_deployment = {}
  end

  def teardown
    Setting.clear_cache
  end

  def test_global
    assert_equal [%w[deployment development Development], %w[deployment staging Staging], %w[deployment production Live]],
                 Environments.global.map { |environment| [environment.type, environment.value, environment.label] }

    Setting.plugin_redmine_deployment = { 'environments' => "branch|develop\r\n\n# comment\n  deployment |  pre prod  | Pre Prod  \n" \
                                                             "branch | develop | Duplicate\nbranch | release/2.0 | Release\n" }
    environments = Environments.global
    assert_equal [%w[branch develop Develop], ['deployment', 'pre prod', 'Pre Prod'], ['branch', 'release/2.0', 'Release']],
                 environments.map { |environment| [environment.type, environment.value, environment.label] }
    assert_equal ['branch:develop', 'deployment:pre prod', 'branch:release/2.0'], environments.map(&:key)
    assert environments.first.branch?
    assert environments.second.deployment?

    Setting.plugin_redmine_deployment = { 'environments' => '' }
    assert_empty Environments.global
  end

  def test_colors
    # at least 8 different colors
    assert_operator Environments::COLORS.values.uniq.size, :>=, 8
    Environments::COLORS.each_value { |color| assert_match Environments::COLOR_FORMAT, color }

    # without a color: by position, the last environment is green
    Setting.plugin_redmine_deployment = { 'environments' => "branch | develop\nbranch | stage\ndeployment | qa\ndeployment | production | Live" }
    assert_equal %w[#2f6db5 #7657b8 #c98a00 #2f9e44], Environments.global.map(&:color)

    # by name or '#rrggbb', an empty label keeps the default label
    Setting.plugin_redmine_deployment = { 'environments' => "branch | develop | | pink\ndeployment | production | Live | #ABCDEF\ndeployment | qa" }
    assert_equal [['Develop', '#c2417f'], ['Live', '#abcdef'], ['Qa', '#2f9e44']],
                 Environments.global.map { |environment| [environment.label, environment.color] }
  end

  def test_line
    Setting.plugin_redmine_deployment = { 'environments' => "branch | develop\ndeployment | production | Live | pink" }

    lines = Environments.global.map { |environment| Environments.line(environment) }

    assert_equal ['branch | develop | Develop | #2f6db5', 'deployment | production | Live | #c2417f'], lines
    lines.each { |line| assert_match Environments::FORMAT, line }
  end

  def test_invalid_lines_are_ignored
    Setting.plugin_redmine_deployment = { 'environments' => "tag | v1 | V1\nbranch |  | Empty\ndeployment | a | b | c\ndeployment | a | b | #12345\n" \
                                                             "Branch | main\nbranch | main | Main" }

    assert_equal ['branch:main'], Environments.global.map(&:key)
  end

  def test_legacy_lines_are_converted
    Setting.plugin_redmine_deployment = { 'environments' => "staging: Stage\n\nproduction\nstaging = Duplicate\nbranch | main\n" }

    assert_equal "deployment | staging | Stage\n\ndeployment | production | Production\ndeployment | staging | Duplicate\nbranch | main",
                 Environments.global_text
    assert_equal [%w[deployment:staging Stage], %w[deployment:production Production], %w[branch:main Main]],
                 Environments.global.map { |environment| [environment.key, environment.label] }
  end

  def test_pattern_is_javascript_compatible
    # the settings form checks the lines with the same pattern (new RegExp(pattern)) - no Ruby-only syntax
    assert_no_match(/\\[AzZh]|\(\?[<>imx]/, Environments::PATTERN)
    assert_match Environments::FORMAT, 'branch | feature/x-1 | Feature'
    assert_no_match Environments::FORMAT, 'branch | feature x | Feature | more'
    assert_match Environments::FORMAT, 'branch | feature/x-1 | Feature | purple'
    assert_match Environments::FORMAT, 'deployment | production | | #1a2B3c'
    assert_no_match Environments::FORMAT, 'deployment | production | Live | rot'
    assert_no_match Environments::FORMAT, 'deployment | production | Live | green | more'
  end

  def test_code
    # without a code line: the default label (nil - translated "Code") and color
    assert_equal [nil, '#66707a'], Environments.global_code.to_a

    Setting.plugin_redmine_deployment = { 'environments' => "branch | develop\ncode |  | Commits | teal\ncode | | Other | red" }
    # the first code line - it is no environment
    assert_equal ['Commits', '#1c8a8a'], Environments.global_code.to_a
    assert_equal ['branch:develop'], Environments.global.map(&:key)

    # the lines of the pipeline: "Code" first
    assert_equal "code |  | Commits | #1c8a8a\nbranch | develop | Develop | #2f9e44", Environments.text(Environments.global_code, Environments.global)
    assert_equal 'code |  |  | #66707a', Environments.line(Environments::Code.new(nil, '#66707a'))
  end

  def test_code_lines_have_no_value
    assert_match Environments::FORMAT, 'code |  | Commits | #112233'
    assert_match Environments::FORMAT, 'code |'
    assert_no_match Environments::FORMAT, 'code | main | Commits'
    assert_no_match Environments::FORMAT, 'code |  | Commits | rot'
    assert_nil Environments.parse_line('code |  | Commits')
  end

  def test_the_code_of_a_project
    Setting.plugin_redmine_deployment = { 'environments' => "code |  | Central | blue\ndeployment | production | Live" }
    project = Project.find(1)
    assert_equal ['Central', '#2f6db5'], Environments.code_for(project).to_a

    DeploymentSetting.update_project(project, 'custom' => '1', 'environments' => "code |  | Own | pink\nbranch | main")
    assert_equal ['Own', '#c2417f'], Environments.code_for(project).to_a
    assert_equal ['Central', '#2f6db5'], Environments.code_for(Project.find(2)).to_a
  end

  def test_the_environments_of_a_project
    Setting.plugin_redmine_deployment = { 'environments' => "deployment | staging | Staging\ndeployment | production | Live" }
    project = Project.find(1)

    # without own environments: the central ones
    assert_equal %w[Staging Live], Environments.for(project).map(&:label)
    assert_not Environments.custom?(project)

    # own environments, but not activated: the central ones
    DeploymentSetting.update_project(project, 'custom' => '0', 'environments' => "branch | main | Main")
    assert_equal %w[Staging Live], Environments.for(project).map(&:label)

    # own environments (colors by position)
    DeploymentSetting.update_project(project, 'custom' => '1')
    assert_equal [['branch', 'main', 'Main', '#2f9e44']], Environments.for(project).map(&:to_a)
    assert Environments.custom?(project)
    assert_equal %w[Staging Live], Environments.for(Project.find(2)).map(&:label)
    assert_equal %w[Staging Live], Environments.for(nil).map(&:label)

    # own, but empty: no environments
    DeploymentSetting.update_project(project, 'environments' => '')
    assert_empty Environments.for(project)
  end

  def test_the_project_settings_are_deleted_with_the_project
    project = Project.find(2)
    DeploymentSetting.update_project(project, 'custom' => '1', 'environments' => "branch | main")

    project.destroy

    assert_empty DeploymentSetting.project_settings(2)
    assert_not DeploymentSetting.settings['projects'].to_h.key?(2)
  end
end
