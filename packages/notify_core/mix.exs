defmodule NotifyCore.MixProject do
  use Mix.Project

  def project do
    [
      app: :notify_core,
      version: "0.1.0", # x-release-please-version
      elixir: "~> 1.17",
      archives: [mix_gleam: "== 0.6.2"],
      compilers: [:gleam | Mix.compilers()],
      aliases: ["deps.get": ["deps.get", "gleam.deps.get"]],
      # MixGleam's compile-package output stays under build/dev for every MIX_ENV.
      erlc_paths: [
        "build/dev/erlang/notify_core/_gleam_artefacts",
        "build/dev/erlang/notify_core/build",
        "src"
      ],
      erlc_include_path: "build/dev/erlang/notify_core/include",
      prune_code_paths: false,
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:crypto]]
  end

  defp deps do
    [
      {:gleam_json, "== 3.1.0"},
      {:gleam_stdlib, "== 1.0.5"}
    ]
  end
end
