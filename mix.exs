defmodule Kotoba.MixProject do
  use Mix.Project

  @version "0.3.0"
  @source_url "https://github.com/hattoriai/kotoba"

  # KOTOBA_OLDEST=1 resolves the oldest Phoenix and LiveView that Kotoba
  # supports, for the floor job of CI (with `mix deps.update phoenix
  # phoenix_live_view`).
  @oldest System.get_env("KOTOBA_OLDEST") in ["1", "true"]

  def project do
    [
      app: :kotoba,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      test_ignore_filters: [&String.starts_with?(&1, "test/fixtures/")],
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      # For the code reloader of the development server (dev.exs). The
      # listener is Phoenix 1.8's, so the oldest versions go without it.
      listeners: if(@oldest, do: [], else: [Phoenix.CodeReloader]),
      dialyzer: [
        plt_add_apps: [:mix, :ex_unit, :esbuild],
        plt_core_path: "priv/plts",
        plt_file: {:no_warn, "priv/plts/project.plt"}
      ],
      package: package(),
      docs: docs(),
      description: description(),
      name: "Kotoba",
      source_url: @source_url,
      homepage_url: @source_url
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  def cli do
    [preferred_envs: [precommit: :test]]
  end

  # The development node (dev/lib) is compiled in :test for its tests in
  # test/dev.
  defp elixirc_paths(:test), do: ["lib", "test/support", "dev/lib"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:bandit, "~> 1.5", only: :dev},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev], runtime: false},
      {:ecto, "~> 3.13"},
      {:esbuild, "~> 0.10", only: :dev, runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:lazy_html, "~> 0.1", only: :test},
      {:mdex, "~> 0.13"},
      {:phoenix, if(@oldest, do: "~> 1.7.14", else: "~> 1.7.14 or ~> 1.8")},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.6", only: :dev},
      {:phoenix_live_view, if(@oldest, do: "~> 1.1.0", else: "~> 1.1")},
      {:stream_data, "~> 1.1", only: :test}
    ]
  end

  defp description do
    "Rich text for Phoenix: a prebuilt Lexical editor, an Ecto content type, rendering and sanitization."
  end

  defp package do
    [
      name: "kotoba",
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      # The six bundle files by name: other build output in priv/static
      # never goes into the package.
      files: ~w(
        lib
        priv/static/kotoba.esm.js
        priv/static/kotoba.cjs.js
        priv/static/kotoba-collab.esm.js
        priv/static/kotoba-collab.cjs.js
        priv/static/kotoba.css
        priv/static/kotoba-sumi.css
        package.json
        mix.exs
        .formatter.exs
        guides
        README.md
        CHANGELOG.md
        LICENSE
        NOTICE
      )
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      source_url: @source_url,
      extras: [
        "README.md",
        "guides/quickstart.md",
        "guides/forms.md",
        "guides/collaboration.md",
        "guides/features.md",
        "guides/rendering.md",
        "guides/uploads.md",
        "guides/prompts.md",
        "guides/suggestions.md",
        "guides/custom_nodes.md",
        "guides/extensions.md",
        "guides/theming.md",
        "guides/security.md",
        "guides/accessibility.md",
        "guides/limits.md",
        "CHANGELOG.md"
      ],
      groups_for_extras: [
        Guides: [
          "guides/quickstart.md",
          "guides/forms.md",
          "guides/collaboration.md",
          "guides/features.md",
          "guides/rendering.md",
          "guides/uploads.md",
          "guides/prompts.md",
          "guides/suggestions.md",
          "guides/custom_nodes.md",
          "guides/extensions.md",
          "guides/theming.md"
        ],
        Reference: [
          "guides/security.md",
          "guides/accessibility.md",
          "guides/limits.md"
        ]
      ],
      groups_for_modules: [
        Editor: [
          Kotoba,
          Kotoba.Components,
          Kotoba.Live,
          Kotoba.MarkdownPaste,
          Kotoba.Prompts,
          Kotoba.Features,
          Kotoba.CodeLanguages
        ],
        Content: [Kotoba.Content, Kotoba.Document, Kotoba.Renderer, Kotoba.Sanitizer],
        Nodes: [Kotoba.Node, Kotoba.Node.Field, Kotoba.Nodes, ~r/^Kotoba\.Nodes\./],
        Attachments: [
          Kotoba.Attachments,
          Kotoba.Storage,
          Kotoba.Storage.Local,
          Kotoba.Storage.Local.Plug
        ]
      ]
    ]
  end

  # The browser tests need their npm packages; `npm ci` runs once.
  defp e2e_deps(_args) do
    unless File.dir?("e2e/node_modules") do
      Mix.Task.run("cmd", ~w(--cd e2e npm ci))
    end
  end

  defp aliases do
    [
      "assets.build": ["kotoba.build"],
      dev: "run --no-halt dev.exs",
      "test.e2e": [&e2e_deps/1, "cmd --cd e2e npm test"],
      # The compile and the asset build run in a child VM: once anything
      # compiles in this VM, Mix no longer finds the tasks of the Hex archive
      # (Elixir 1.20, Hex 2.5). hex.publish stays in this VM so that it can
      # read the two-factor code from the terminal. The check refuses a
      # priv/static with anything but the six bundle files.
      release: [
        "cmd mix kotoba.build",
        "cmd mix kotoba.release_check",
        "hex.publish --yes",
        "cmd git tag v#{@version} -f",
        "cmd git push",
        "cmd git push --tags"
      ],
      precommit: [
        "compile --warnings-as-errors",
        "deps.unlock --unused",
        "format",
        "credo --strict",
        "test"
      ]
    ]
  end
end
