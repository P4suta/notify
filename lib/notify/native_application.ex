defmodule Notify.NativeApplication do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _arguments) do
    argv =
      if Code.ensure_loaded?(Burrito.Util.Args) do
        Burrito.Util.Args.argv()
      else
        System.argv()
      end

    Application.put_env(:notify, :native_argv, argv)

    children = [
      {Task,
       fn ->
         :notify.main()
         System.halt(0)
       end}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Notify.NativeSupervisor)
  end
end
