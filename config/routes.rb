

  resources :deployments, :only => [:index]

  resources :projects do
    resources :deployments, :only => [:index, :show, :create] do
      collection do
        get :statistics, :to => 'deployments#stats'
        get :graph
      end
    end
  end

  match 'projects/:project_id/deploy/:repository_id' => 'deployments#create', :via => [:post]