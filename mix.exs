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
      erlc_paths: [
        "_build/#{Mix.env()}/lib/notify/_gleam_artefacts",
        "_build/#{Mix.env()}/lib/notify/build",
        "src"
      ],
      erlc_include_path: "_build/#{Mix.env()}/lib/notify/include",
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
    [{:burrito, "~> 1.6", only: :prod, runtime: false}]
  end

  defp releases do
    [
      notify: [
        steps: [:assemble, &Burrito.wrap/1],
        strip_beams: false,
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
