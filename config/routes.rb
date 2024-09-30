

  resources :deployments, :only => [:index]

  resources :projects do
    resources :deployments, :only => [:index, :create]
  end
