

  resources :deployments, :only => [:index]

  resources :projects do
    resources :deployments, :only => [:index, :show, :create]
  end

  match 'projects/:project_id/deploy/:repository_id' => 'deployments#create', :via => [:post]