defmodule DataService.Repo do
  use Ecto.Repo,
    otp_app: :data_service,
    adapter: Ecto.Adapters.Postgres
end
