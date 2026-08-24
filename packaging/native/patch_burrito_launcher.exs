# SPDX-License-Identifier: Apache-2.0
defmodule Notify.Native.PatchBurritoLauncher do
  @moduledoc false

  @expected_sha256 "dbfe076914ce3cb3bb13abcbeb83d6463bf74678eec76e136c7f1ca790c341f7"
  @original """
          "-elixir ansi_enabled true",
          "-noshell",
          "-s elixir start_cli",
          "-mode embedded",
  """
  @replacement """
          "-elixir",
          "ansi_enabled",
          "true",
          "-noshell",
          "-s",
          "notify",
          "main",
          "-s",
          "init",
          "stop",
          "-mode",
          "embedded",
  """

  def run(path) do
    source = File.read!(path)
    actual_sha256 = :crypto.hash(:sha256, source) |> Base.encode16(case: :lower)

    unless actual_sha256 == @expected_sha256 do
      raise "unexpected Burrito 1.5.0 launcher SHA-256: #{actual_sha256}"
    end

    unless occurrences(source, @original) == 1 and occurrences(source, @replacement) == 0 do
      raise "Burrito launcher does not contain exactly one expected OTP argv block"
    end

    patched = String.replace(source, @original, @replacement)
    temporary_path = path <> ".notify-native.tmp"
    mode = File.stat!(path).mode

    try do
      File.write!(temporary_path, patched, [:binary, :exclusive])
      File.chmod!(temporary_path, mode)
      File.rename!(temporary_path, path)
    after
      File.rm(temporary_path)
    end

    persisted = File.read!(path)

    unless occurrences(persisted, @original) == 0 and
             occurrences(persisted, @replacement) == 1 do
      raise "Burrito launcher OTP argv patch did not persist"
    end
  end

  defp occurrences(source, pattern) do
    source |> :binary.matches(pattern) |> length()
  end
end

case System.argv() do
  [path] -> Notify.Native.PatchBurritoLauncher.run(path)
  _ -> raise "usage: elixir patch_burrito_launcher.exs PATH_TO_LAUNCHER"
end
