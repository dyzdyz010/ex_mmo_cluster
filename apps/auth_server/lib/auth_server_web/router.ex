defmodule AuthServerWeb.Router do
  use AuthServerWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {AuthServerWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :account do
    plug AuthServerWeb.Plugs.AccountRateLimit
  end
  pipeline :game_account do
    plug AuthServerWeb.Plugs.AccountAccess
  end
  scope "/account", AuthServerWeb do
    pipe_through [:api,:account]
    get "/registration-policy", AccountController, :policy
    get "/session", AccountController, :session
    post "/registration-email", AccountController, :registration_email
    post "/claim-email", AccountController, :claim_email
    post "/claim", AccountController, :claim
    post "/register", AccountController, :register
    post "/login", AccountController, :login
    post "/refresh", AccountController, :refresh
    post "/logout", AccountController, :logout
    post "/logout-all", AccountController, :logout_all
    post "/forgot-password", AccountController, :forgot_password
    post "/reset-password", AccountController, :reset_password
    post "/change-password", AccountController, :change_password
    post "/game-ticket", AccountController, :game_ticket
    post "/admin/policy", AccountController, :admin_policy
    get "/admin/invites", AccountController, :invite_list
    post "/admin/invites", AccountController, :invite_create
    delete "/admin/invites/:id", AccountController, :invite_delete
    post "/admin/invites/:id/revoke", AccountController, :invite_revoke
  end
  scope "/game", AuthServerWeb do
    pipe_through :game_account
    post "/regions", IngameController, :game_regions
    post "/prefabs", IngameController, :game_prefabs
  end
  scope "/auth", AuthServerWeb do
    pipe_through [:browser, :account]
    get "/", AccountPortalController, :index
    get "/login", AccountPortalController, :login_page
    post "/login", AccountPortalController, :login
    get "/register", AccountPortalController, :register_page
    post "/registration-email", AccountPortalController, :registration_email
    post "/register", AccountPortalController, :register
    get "/forgot", AccountPortalController, :forgot_page
    post "/forgot", AccountPortalController, :forgot
    get "/reset", AccountPortalController, :reset_page
    post "/reset", AccountPortalController, :reset
    get "/claim", AccountPortalController, :claim_page
    post "/claim-email", AccountPortalController, :claim_email
    post "/claim", AccountPortalController, :claim
    post "/change-password", AccountPortalController, :change_password
    post "/logout", AccountPortalController, :logout
    post "/logout-all", AccountPortalController, :logout_all
  end
  scope "/admin", AuthServerWeb do
    pipe_through [:browser,:account]
    get "/login", AccountAdminController, :login_page
    post "/login", AccountAdminController, :login
    post "/logout", AccountAdminController, :logout
    get "/", AccountAdminController, :index
    post "/policy", AccountAdminController, :policy
    post "/invites", AccountAdminController, :create
    post "/invites/:id/delete", AccountAdminController, :delete
    post "/invites/:id/revoke", AccountAdminController, :revoke
  end

  scope "/playtest", AuthServerWeb do
    pipe_through :api
    post "/login", IngameController, :playtest_login
    post "/regions", IngameController, :playtest_regions
    post "/prefabs", IngameController, :playtest_prefabs
  end

  scope "/ingame", AuthServerWeb do
    pipe_through :api

    post "/auto_login", IngameController, :auto_login
    post "/voxel/regions", IngameController, :voxel_regions
    post "/voxel/prefabs", IngameController, :voxel_prefabs
  end

  # Other scopes may use custom stacks.
  # scope "/api", AuthServerWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard in development
  if Application.compile_env(:auth_server, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: AuthServerWeb.Telemetry
    end
  end
end
