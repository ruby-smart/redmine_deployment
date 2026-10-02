# frozen_string_literal: true

require File.expand_path(File.dirname(__FILE__) + '/../test_helper')

# the graphs of the statistics page: one color per environment of the project, the same in every graph
class DeploymentGraphsTest < Redmine::ControllerTest
  tests DeploymentsController

  fixtures :projects, :users, :roles, :members, :member_roles, :enabled_modules, :repositories

  def setup
    @project = Project.find(1)
    EnabledModule.create!(:project => @project, :name => 'deployment') unless @project.module_enabled?(:deployment)
    Role.find(1).add_permission!(:view_deployments)
    @repository = Repository::Git.create!(:project => @project, :url => '/tmp/stats.git')

    # "crawler" was deployed two years ago only: it shows up in the graph per author (all deployments), not in
    # the graph per month (the last 12 months) - so the position of "production" differs between the graphs
    deploy('crawler', :created_on => 2.years.ago)
    deploy('production', :created_on => 2.years.ago)
    deploy('production', :created_on => 1.month.ago)
    deploy('staging', :created_on => 1.month.ago)
    deploy('staging', :created_on => 2.days.ago, :result => Deployment::RESULT_FAIL) # not part of the graphs

    @request.session[:user_id] = 2 # jsmith, manager of project 1
  end

  def test_every_environment_keeps_its_color_in_both_graphs
    per_month  = graph('deployments_per_month')
    per_author = graph('deployments_per_author')

    assert_equal %w[production staging], per_month['datasets'].map { |dataset| dataset['name'] }
    assert_equal %w[crawler production staging], per_author['datasets'].map { |dataset| dataset['name'] }

    colors_per_month  = colors(per_month)
    colors_per_author = colors(per_author)
    assert_equal colors_per_author.slice('production', 'staging'), colors_per_month
    assert_equal 3, colors_per_author.values.uniq.size, 'distinct colors'
    assert colors_per_author.values.all? { |color| color.match?(/\A#\h{6}\z/) }, colors_per_author.inspect
  end

  # the fixed list, by the environments of the project in alphabetical order
  def test_colors_come_from_the_fixed_list_by_environment
    assert_equal DeploymentsController::ENVIRONMENT_COLORS.first(3), graph('deployments_per_author')['datasets'].map { |dataset| dataset['color'] }
    assert_equal DeploymentsController::ENVIRONMENT_COLORS[1..2], graph('deployments_per_month')['datasets'].map { |dataset| dataset['color'] }
    assert_equal DeploymentsController::ENVIRONMENT_COLORS.uniq, DeploymentsController::ENVIRONMENT_COLORS
  end

  def test_stats_page_renders_both_graphs
    get :stats, :params => { :project_id => @project.identifier }

    assert_response :success
    assert_select 'canvas#deployments_per_month'
    assert_select 'canvas#deployments_per_author'
    assert_include "ds['color']", response.body
  end

  private

  def graph(name)
    get :graph, :params => { :project_id => @project.identifier, :graph => name }
    assert_response :success
    JSON.parse(response.body)
  end

  def colors(data)
    data['datasets'].to_h { |dataset| [dataset['name'], dataset['color']] }
  end

  def deploy(environment, created_on:, result: Deployment::RESULT_SUCCESS)
    deployment = Deployment.create!(:project => @project, :repository => @repository, :author => User.find(2),
                                    :environment => environment, :result => result,
                                    :from_revision => 'a', :to_revision => 'b')
    deployment.update_columns(:created_on => created_on)
    deployment
  end
end
