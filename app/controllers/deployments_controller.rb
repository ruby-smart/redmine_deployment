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

  accept_api_auth :index, :show, :create, :destroy

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
      @deployments_count = @query.deployment_count
      @deployment_count_by_group = @query.deployment_count_by_group

      @deployments_pages = Paginator.new(@deployments_count, @limit, params['page'])
      @offset            ||= @deployments_pages.offset

      @deployments                = @query.deployments(
        :order   => sort_clause,
        :limit   => @limit,
        :offset  => @offset
      )

      respond_to do |format|
        format.html
        format.atom { render_feed(@deployments, :title => "#{@project || Setting.app_title}: #{l(:label_deployments)}") }
        format.csv {
          send_data(query_to_csv(@deployments, @query, params[:csv] || {}),
                    :type => 'text/csv; header=present',
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
    respond_to do |format|
      format.html
      format.api
    end
  end

  def create
    @deployment                 = Deployment.new
    @deployment.safe_attributes = params[:deployment]

    @deployment.project    = @project
    @deployment.repository = @repository
    @deployment.user       = User.current
    if @deployment.save
      respond_to do |format|
        format.js
        format.html { redirect_to :back }
        format.api { render :action => 'show', :status => :created, :location => deployment_url(@deployment) }
      end
    else
      respond_to do |format|
        format.html { redirect_to :back }
        format.api { render_validation_errors(@deployment) }
      end
    end
  end

  private

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
