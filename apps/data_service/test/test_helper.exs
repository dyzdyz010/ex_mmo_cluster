# Start required applications for Ecto tests
Application.ensure_all_started(:jason)
Application.ensure_all_started(:postgrex)
Application.ensure_all_started(:ecto_sql)
{:ok, _} = DataService.Repo.start_link()

ExUnit.start()
