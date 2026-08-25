defmodule Notify.MixProject do
  use Mix.Project

  def project do
    [
      app: :notify,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      archives: [mix_gleam: "== 0.6.2"],
      compilers: [:gleam | Mix.compilers()],
      aliases: ["deps.get": ["deps.get", "gleam.deps.get"]],
      # MixGleam's compile-package output stays under build/dev for every MIX_ENV.
      erlc_paths: [
        "build/dev/erlang/notify/_gleam_artefacts",
        "build/dev/erlang/notify/build",
        "src"
      ],
      erlc_include_path: "build/dev/erlang/notify/include",
      prune_code_paths: false,
      releases: releases(),
      deps: deps()
    ]
  end

  def application do
    [
      mod: {Notify.NativeApplication, []},
      extra_applications: [:logger, :crypto, :inets, :public_key, :ssl]
    ]
  end

  defp deps do
    [
      {:argus, "== 1.0.4"},
      {:beecrypt, "== 0.4.0"},
      {:gleam_crypto, "== 1.6.0"},
      {:gleam_erlang, "== 1.3.0"},
      {:gleam_http, "== 4.3.0"},
      {:gleam_json, "== 3.1.0"},
      {:gleam_otp, "== 1.3.0"},
      {:gleam_stdlib, "== 1.0.5"},
      # The Hex package is named hpack_erl, but it publishes the :hpack OTP app.
      {:hpack_erl, "== 0.3.0", app: false, override: true},
      {:mist, "== 6.0.3"},
      {:notify_core, path: "packages/notify_core"},
      {:postgleam, "== 0.8.0"},
      {:sqlight, "== 1.2.0"},
      {:burrito, "== 1.5.0", only: :prod, runtime: false}
    ]
  end

  defp releases do
    [
      notify: [
        steps: [:assemble, &Notify.NativeRelease.prepare_runtime_boot/1, &Burrito.wrap/1],
        strip_beams: false,
        applications: [hpack: :permanent],
        burrito: [
          targets: [
            linux_amd64: [os: :linux, cpu: :x86_64],
            linux_arm64: [os: :linux, cpu: :aarch64],
            macos_amd64: [os: :darwin, cpu: :x86_64],
            macos_arm64: [os: :darwin, cpu: :aarch64],
            windows_amd64: [os: :windows, cpu: :x86_64]
          ]
        ]
      ]
    ]
  end
end
