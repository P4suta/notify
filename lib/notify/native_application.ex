defmodule Notify.NativeApplication do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _arguments) do
    Supervisor.start_link([], strategy: :one_for_one, name: Notify.NativeSupervisor)
  end
end
