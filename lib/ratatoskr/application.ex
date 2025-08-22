defmodule Ratatoskr.Application do
  @moduledoc false

  use Application
  require Logger

  @impl true
  def start(type, args) do
    Logger.info("Starting Ratatoskr message broker...")

    # Delegate to the clean architecture application server
    Ratatoskr.Servers.Application.start(type, args)
  end

  @impl true
  def stop(state) do
    Ratatoskr.Servers.Application.stop(state)
  end
end
