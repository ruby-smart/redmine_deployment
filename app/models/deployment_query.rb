class DeploymentQuery < Query

  self.queried_class   = Deployment
  self.view_permission = :view_deployments

  self.available_columns = [
    QueryColumn.new(:from_revision),
    QueryColumn.new(:to_revision),
    QueryColumn.new(:environment, sortable: "#{Deployment.table_name}.environment", groupable: true),
    QueryColumn.new(:revisions, caption: :label_revision_plural),
    QueryColumn.new(:servers),
    QueryColumn.new(:repository, sortable: "#{Deployment.table_name}.repository_id", groupable: true, caption: :label_repository),
    QueryColumn.new(:author, sortable: "#{Deployment.table_name}.author_id", groupable: true),
    QueryColumn.new(:project, sortable: "#{Project.table_name}.name", groupable: true),
    QueryColumn.new(:created_on, sortable: "#{Deployment.table_name}.created_on", :default_order => 'desc')
  ]

  def initialize(attributes = nil, *args)
    super attributes
    self.filters ||= {}
  end

  def environment_values
    if project
      project.deployments.distinct.pluck(:environment)
    else
      Deployment.all.distinct.pluck(:environment)
    end
  end

  def repository_values
    q = Project.allowed_to(:view_repositories).has_module(:repository).has_module(:deployment)
    q.where!(id: project.id) if project

    Repository.where(project_id: q).map{|repository| [repository.identifier, repository.id]}
  end

  def initialize_available_filters
    add_available_filter "from_revision", :type => :string, :order => 0
    add_available_filter "to_revision", :type => :string, :order => 1
    add_available_filter "servers", :type => :text, :order => 2
    add_available_filter "environment", :type => :list, :values => lambda { environment_values }, :order => 3

    add_available_filter(
      "project_id",
      :type => :list, :values => lambda { project_values }
    ) if project.nil?

    add_available_filter(
      "repository_id",
      :type => :list, :values => lambda { repository_values }, label: :label_repository
    )

    add_available_filter("author_id", :order => 4, :type => :list_optional, :values => author_values)
  end

  def available_columns
    return @available_columns if @available_columns
    @available_columns = self.class.available_columns.dup
  end

  def default_columns_names
    @default_columns_names ||= project.nil? ? [:project, :repository, :created_on, :author, :revisions, :environment] : [:created_on, :author, :revisions, :environment]
  end

  def base_scope
    Deployment.joins(:project).where(statement)
  end

  # Returns the issue count
  def deployment_count
    base_scope.count
  rescue ::ActiveRecord::StatementInvalid => e
    raise StatementInvalid.new(e.message)
  end

  def deployment_count_by_group
    return unless grouped?

    base_scope.
      joins(joins_for_order_statement(group_by_statement)).
      group(group_by_statement).count
  end

  def object_count_by_group
    r = nil
    if grouped?
      begin
        # Rails3 will raise an (unexpected) RecordNotFound if there's only a nil group value
        r = objects_scope.
          joins(joins_for_order_statement(group_by_statement)).
          group(group_by_statement).count
      rescue ActiveRecord::RecordNotFound
        r = { nil => object_count }
      end
      c = group_by_column
      if c.is_a?(QueryCustomFieldColumn)
        r = r.keys.inject({}) { |h, k| h[c.custom_field.cast_value(k)] = r[k]; h }
      end
    end
    r
  rescue ::ActiveRecord::StatementInvalid => e
    raise Query::StatementInvalid.new(e.message)
  end

  def deployments(options = {})
    order_option = [group_by_sort_order, (options[:order] || sort_clause)].flatten.reject(&:blank?)

    scope = base_scope.
      includes(([:project] + (options[:include] || [])).uniq).
      where(options[:conditions]).
      order(order_option).
      joins(joins_for_order_statement(order_option.join(','))).
      limit(options[:limit]).
      offset(options[:offset])

    scope =
      scope.preload(
        [:user] & columns.map(&:name)
      )

    scope.to_a
  rescue ::ActiveRecord::StatementInvalid => e
    raise StatementInvalid.new(e.message)
  end
end
