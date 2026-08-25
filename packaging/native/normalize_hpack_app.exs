# SPDX-License-Identifier: Apache-2.0
defmodule Notify.Native.NormalizeHpackApp do
  @moduledoc false

  @old_application :hpack_erl
  @new_application :hpack

  def run(path) do
    properties = read_mist_application!(path)
    applications = Keyword.fetch!(properties, :applications)

    if Enum.count(applications, &(&1 == @old_application)) != 1 do
      raise "mist.app must contain exactly one hpack_erl dependency"
    end

    if @new_application in applications do
      raise "mist.app already contains the hpack dependency"
    end

    normalized =
      Enum.map(applications, fn
        @old_application -> @new_application
        application -> application
      end)

    term = {:application, :mist, Keyword.put(properties, :applications, normalized)}
    temporary_path = path <> ".notify-native.tmp"
    mode = File.stat!(path).mode

    try do
      File.write!(temporary_path, :io_lib.format("~tp.~n", [term]))
      File.chmod!(temporary_path, mode)
      File.rename!(temporary_path, path)
    after
      File.rm(temporary_path)
    end

    verified = read_mist_application!(path) |> Keyword.fetch!(:applications)

    unless @new_application in verified and @old_application not in verified do
      raise "mist.app hpack dependency normalization did not persist"
    end
  end

  defp read_mist_application!(path) do
    case :file.consult(String.to_charlist(path)) do
      {:ok, [{:application, :mist, properties}]} when is_list(properties) ->
        properties

      other ->
        raise "unexpected mist.app contract: #{inspect(other)}"
    end
  end
end

case System.argv() do
  [path] -> Notify.Native.NormalizeHpackApp.run(path)
  _ -> raise "usage: elixir normalize_hpack_app.exs PATH_TO_MIST_APP"
end
