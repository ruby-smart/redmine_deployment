class DeploymentsController < ApplicationController
  helper :context_menus
  helper :sort
  include SortHelper
  helper :queries
  include QueriesHelper
  include ApplicationHelper

  default_search_scope :deployments

  before_action :find_optional_project
  before_action :find_project_repository, :only => :create

  accept_api_auth :index, :show, :create

  def index
    retrieve_query
    sort_init(@query.sort_criteria.empty? ? [['created_on', 'desc']] : @query.sort_criteria)
    sort_update(@query.sortable_columns)
    @query.sort_criteria = sort_criteria.to_a

    if @query.valid?
      case params[:format]
      when 'csv', 'xls'
        @limit = Setting.issues_export_limit.to_i
      when 'atom'
        @limit = Setting.feeds_limit.to_i
      when 'xml', 'json'
        @offset, @limit = api_offset_and_limit
      else
        @limit = per_page_option
      end
      @deployments_count         = @query.deployment_count
      @deployment_count_by_group = @query.deployment_count_by_group

      @deployments_pages = Paginator.new(@deployments_count, @limit, params['page'])
      @offset            ||= @deployments_pages.offset

      @deployments = @query.deployments(
        :order  => sort_clause,
        :limit  => @limit,
        :offset => @offset
      )

      respond_to do |format|
        format.html
        format.atom { render_feed(@deployments, :title => "#{@project || Setting.app_title}: #{l(:label_deployments)}") }
        format.csv {
          send_data(query_to_csv(@deployments, @query, params[:csv] || {}),
                    :type     => 'text/csv; header=present',
                    :filename => 'deployments.csv')
        }
        format.api
      end
    else
      respond_to do |format|
        format.html
        format.any(:atom, :csv, :pdf) { render(:nothing => true) }
        format.api { render_validation_errors(@query) }
      end
    end
  end

  def show
    @deployment ||= Deployment.find(params[:id])
    @related_issues = @deployment.related_issues.
      visible.
      preload(:status, :tracker, :priority).
      reorder("#{Issue.table_name}.id DESC").
      to_a

    @related_changesets = @deployment.changesets.
      preload(:user).
      reorder("#{Changeset.table_name}.committed_on DESC, #{Changeset.table_name}.id DESC").
      to_a

    respond_to do |format|
      format.html
      format.api
    end
  end

  def stats
    (render_404; return) unless @project
  end

  # Returns JSON data for deployment graphs
  def graph
    (render_404; return) unless @project

    data =
      case params[:graph]
      when 'deployments_per_month'
        graph_deployments_per_month(@project)
      when 'deployments_per_author'
        graph_deployments_per_author(@project)
      end

    if data
      render :json => data
    else
      render_404
    end
  end

  def create
    @deployment                 = Deployment.new
    @deployment.safe_attributes = params[:deployment]

    @deployment.project    = @project
    @deployment.repository = @repository
    @deployment.author     = User.current

    if @deployment.save
      respond_to do |format|
        format.js
        format.html { redirect_to :back }
        format.api { render :action => 'show', :status => :created }
      end
    else
      respond_to do |format|
        format.html { redirect_to :back }
        format.api { render_validation_errors(@deployment) }
      end
    end
  end

  private

  # Successful deployments of the given project, used as the basis for the statistics graphs
  def successful_deployments(project)
    Deployment.where(:project_id => project.id, :result => Deployment::RESULT_SUCCESS)
  end

  # Display label for an environment value (deployments without an environment are bucketed together)
  def environment_label(environment)
    environment.presence || l(:label_none)
  end

  # Sorted list of distinct environment labels found in the given deployments
  def environment_labels(deployments)
    deployments.map {|d| environment_label(d.environment)}.uniq.sort
  end

  # Number of successful deployments per month (last 12 months), one dataset per environment.
  # Mirrors RepositoriesController#graph_commits_per_month.
  def graph_deployments_per_month(project)
    date_to   = User.current.today
    date_from = date_to << 11
    date_from = Date.civil(date_from.year, date_from.month, 1)

    deployments = successful_deployments(project).
      where("created_on BETWEEN ? AND ?", date_from.beginning_of_day, date_to.end_of_day).to_a

    labels = []
    12.times {|m| labels << month_name(((date_to.month - 1 - m) % 12) + 1)}

    datasets = environment_labels(deployments).map do |env|
      counts = [0] * 12
      deployments.each do |d|
        next unless environment_label(d.environment) == env

        counts[(date_to.month - d.created_on.to_date.month) % 12] += 1
      end
      {:name => env, :data => counts.reverse}
    end

    {:labels => labels.reverse, :datasets => datasets}
  end

  # Number of successful deployments per author (top 10), one dataset per environment.
  # Mirrors RepositoriesController#graph_commits_per_author.
  def graph_deployments_per_author(project)
    deployments = successful_deployments(project).includes(:author).to_a

    authors = deployments.map(&:author).compact.uniq.
      sort_by {|a| -deployments.count {|d| d.author_id == a.id}}.first(10)

    datasets = environment_labels(deployments).map do |env|
      data = authors.map do |author|
        deployments.count {|d| d.author_id == author.id && environment_label(d.environment) == env}
      end
      {:name => env, :data => data.reverse}
    end

    {:labels => authors.map(&:name).reverse, :datasets => datasets}
  end

  def find_project_repository
    if params[:repository_id].present?
      @repository = @project.repositories.find_by_identifier_param(params[:repository_id])
    else
      @repository = @project.repository || @project.repositories.first
    end
    (render_404; return false) unless @repository
  rescue ActiveRecord::RecordNotFound
    render_404
  rescue InvalidRevisionParam
    show_error_not_found
  end

  def retrieve_query
    if params[:query_id].present?
      cond = 'project_id IS NULL'
      cond << " OR project_id = #{@project.id}" if @project
      @query = ::DeploymentQuery.where(cond).find(params[:query_id])
      raise ::Unauthorized unless @query.visible?

      @query.project             = @project
      @query.group_by            = session[:deployment_query][:group_by] if session[:deployment_query] && session[:deployment_query][:group_by]
      @query.column_names        = session[:deployment_query][:column_names] if session[:deployment_query] && session[:deployment_query][:column_names]
      session[:deployment_query] = { id: @query.id, project_id: @query.project_id }
      sort_clear
    elsif api_request? || params[:set_filter] || session[:deployment_query].nil? || session[:deployment_query][:project_id] != (@project ? @project.id : nil)
      # Give it a name, required to be valid
      @query         = ::DeploymentQuery.new(:name => '_')
      @query.project = @project
      @query.build_from_params(params)
      session[:deployment_query] = { project_id: @query.project_id, filters: @query.filters, group_by: @query.group_by, column_names: @query.column_names }
    else
      # retrieve from session
      @query         = ::DeploymentQuery.find(session[:deployment_query][:id]) if session[:deployment_query][:id]
      @query         ||= ::DeploymentQuery.new(name: '_', filters: session[:deployment_query][:filters], group_by: session[:deployment_query][:group_by], column_names: session[:deployment_query][:column_names])
      @query.project = @project
    end
  end
end
