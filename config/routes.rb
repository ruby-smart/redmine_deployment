

  resources :deployments, :only => [:index]

  # the pipeline of an issue as the popup of its deploy status (deployment_status.js)
  get 'issues/:id/deployment_pipeline', :to => 'deployment_status#show', :as => 'issue_deployment_pipeline'

  resources :projects do
    # the project's own deploy environments (project settings, tab "Deployment")
    resource :deployment_settings, :only => [:update]

    resources :deployments, :only => [:index, :show, :create] do
      collection do
        get :statistics, :to => 'deployments#stats'
        get :graph
      end
    end
  end

  match 'projects/:project_id/deploy/:repository_id' => 'deployments#create', :via => [:post]