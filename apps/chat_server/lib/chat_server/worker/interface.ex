defmodule ChatServer.Interface do
  @moduledoc """
  Registers the chat runtime as a discoverable MMO service.

  The process has no chat state. Its only responsibility is cluster presence so
  Gate nodes can find the Chat runtime without coupling to Scene ownership.
  """

  use GenServer
  require Logger

  @resource :chat_server

  @doc "Starts the chat service interface process."
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, [], opts)
  end

  @impl true
  def init(_opts) do
    {:ok, %{server_state: :waiting_requirements}, {:continue, :setup}}
  end

  @impl true
  def handle_continue(:setup, state) do
    Logger.info("===Starting chat_server node initialization===", ansi_color: :blue)

    BeaconServer.Client.join_cluster()
    BeaconServer.Client.register(@resource)

    Logger.info("===Chat server initialization complete, server ready===", ansi_color: :blue)
    {:noreply, %{state | server_state: :ready}}
  end
end
