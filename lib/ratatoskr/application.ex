defmodule Ratatoskr.Application do
  @moduledoc false

  use Application
  require Logger

  alias Ratatoskr.Servers.Application

  @impl true
  def start(type, args) do
    Logger.info("Starting Ratatoskr message broker...")
    Application.start(type, args)
  end

  @impl true
  def stop(state) do
    Application.stop(state)
  end
end
