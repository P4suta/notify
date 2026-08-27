# SPDX-License-Identifier: Apache-2.0
defmodule Notify.NativeRelease do
  @moduledoc false

  @generated_hpack_path "$RELEASE_LIB/hpack_erl/ebin/hpack-0.3.0/ebin"
  @canonical_hpack_path "$RELEASE_LIB/hpack-0.3.0/ebin"
  @notify_core_modules [
    :notify@core@acl,
    :notify@core@action,
    :notify@core@delay,
    :notify@core@filter,
    :notify@core@message,
    :notify@core@message_json,
    :notify@core@topic
  ]
  @runtime_dependency_modules %{
    gleam_quic: [
      :gleam_quic,
      :"gleam_quic@client",
      :"gleam_quic@server",
      :gleam_quic_crypto_ffi,
      :gleam_quic_tls_ffi,
      :gleam_quic_udp_ffi
    ],
    http3: [
      :http3,
      :"http3@client",
      :"http3@server",
      :"http3@websocket",
      :http3_address_ffi,
      :http3_websocket_ffi
    ]
  }
  @development_modules %{
    gleam_quic: [:gleam_quic_test_ffi, :qlog_test_ffi],
    http3: [
      :gleam_quic_test_ffi,
      :http3_benchmark_ffi,
      :http3_diagnostic_ffi,
      :http3_phase4_interop,
      :http3_quicgo_interop,
      :http3_test_ffi
    ]
  }

  def prepare_runtime_boot(release) do
    validate_notify_core!(release)
    prune_development_modules!(release)
    validate_runtime_dependencies!(release)
    normalize_hpack_boot(release)
  end

  defp prune_development_modules!(release) do
    Enum.each(@development_modules, fn {application, development_modules} ->
      [directory] =
        release.path
        |> Path.join("lib/#{application}-*/ebin")
        |> Path.wildcard()

      application_path = Path.join(directory, "#{application}.app")

      properties =
        case :file.consult(String.to_charlist(application_path)) do
          {:ok, [{:application, ^application, configured}]} -> configured
          _ -> raise "release contains invalid #{application} application metadata"
        end

      runtime_modules = Keyword.fetch!(properties, :modules) -- development_modules
      updated = Keyword.put(properties, :modules, runtime_modules)
      encoded = :io_lib.format(~c"~p.~n", [{:application, application, updated}])
      File.write!(application_path, encoded)

      Enum.each(development_modules, fn module ->
        File.rm(Path.join(directory, Atom.to_string(module) <> ".beam"))
      end)
    end)
  end

  defp validate_runtime_dependencies!(release) do
    Enum.each(@runtime_dependency_modules, fn {application, required_modules} ->
      directories =
        release.path
        |> Path.join("lib/#{application}-*/ebin")
        |> Path.wildcard()

      directory =
        case directories do
          [path] -> path
          _ -> raise "release must contain exactly one #{application} application directory"
        end

      application_path = Path.join(directory, "#{application}.app")

      configured_modules =
        case :file.consult(String.to_charlist(application_path)) do
          {:ok, [{:application, ^application, properties}]} ->
            Keyword.fetch!(properties, :modules)

          _ ->
            raise "release contains invalid #{application} application metadata"
        end

      Enum.each(required_modules, fn module ->
        beam_path = Path.join(directory, Atom.to_string(module) <> ".beam")

        unless File.regular?(beam_path) do
          raise "release is missing #{application} runtime module #{module}"
        end

        if String.contains?(Atom.to_string(module), "@") and
             module not in configured_modules do
          raise "#{application}.app omits required runtime module #{module}"
        end
      end)

      Enum.each(Map.fetch!(@development_modules, application), fn module ->
        beam = Atom.to_string(module) <> ".beam"

        if File.exists?(Path.join(directory, beam)) or module in configured_modules do
          raise "release contains forbidden development module #{module}"
        end
      end)
    end)
  end

  defp validate_notify_core!(release) do
    core_directories =
      release.path
      |> Path.join("lib/notify_core-*/ebin")
      |> Path.wildcard()

    core_directory =
      case core_directories do
        [directory] -> directory
        _ -> raise "release must contain exactly one notify_core application directory"
      end

    application_path = Path.join(core_directory, "notify_core.app")

    configured_modules =
      case :file.consult(String.to_charlist(application_path)) do
        {:ok, [{:application, :notify_core, properties}]} ->
          Keyword.fetch!(properties, :modules)

        _ ->
          raise "release contains invalid notify_core application metadata"
      end

    unless Enum.sort(configured_modules) == Enum.sort(@notify_core_modules) do
      raise "release notify_core module inventory does not match the runtime contract"
    end

    Enum.each(@notify_core_modules, fn module ->
      beam_path = Path.join(core_directory, Atom.to_string(module) <> ".beam")

      unless File.regular?(beam_path) do
        raise "release is missing notify_core runtime module #{module}"
      end
    end)
  end

  defp normalize_hpack_boot(release) do
    release_directory = Path.join([release.path, "releases", release.version])
    script_path = Path.join(release_directory, "start.script")
    boot_path = Path.join(release_directory, "start.boot")
    script = File.read!(script_path)

    unless occurrences(script, @generated_hpack_path) == 2 and
             occurrences(script, @canonical_hpack_path) == 0 do
      raise "release script does not contain the expected generated hpack paths"
    end

    normalized = String.replace(script, @generated_hpack_path, @canonical_hpack_path)

    temporary_root =
      Path.join(release_directory, "start.notify-native-#{System.unique_integer([:positive])}")

    temporary_script = temporary_root <> ".script"
    temporary_boot = temporary_root <> ".boot"

    try do
      File.write!(temporary_script, normalized, [:binary, :exclusive])
      File.chmod!(temporary_script, File.stat!(script_path).mode)

      case :systools.script2boot(String.to_charlist(temporary_root)) do
        :ok -> :ok
        error -> raise "could not regenerate release boot file: #{inspect(error)}"
      end

      if File.stat!(temporary_boot).size == 0 do
        raise "regenerated release boot file is empty"
      end

      File.chmod!(temporary_boot, File.stat!(boot_path).mode)
      File.rename!(temporary_script, script_path)
      File.rename!(temporary_boot, boot_path)
    after
      File.rm(temporary_script)
      File.rm(temporary_boot)
    end

    persisted = File.read!(script_path)

    unless occurrences(persisted, @generated_hpack_path) == 0 and
             occurrences(persisted, @canonical_hpack_path) == 2 do
      raise "release hpack boot path normalization did not persist"
    end

    release
  end

  defp occurrences(source, pattern) do
    source |> :binary.matches(pattern) |> length()
  end
end
