defmodule Mix.Tasks.Kotoba.BuildTest do
  # Builds the real bundles into priv/static, so it does not run in parallel
  # with other tests. It needs npm (and the network for the first `npm ci`),
  # so it runs only with `mix test --include build`.
  use ExUnit.Case, async: false

  @root Path.expand("../../..", __DIR__)
  @static Path.join(@root, "priv/static")
  @files ~w(kotoba.esm.js kotoba.cjs.js kotoba-collab.esm.js kotoba-collab.cjs.js kotoba.css kotoba-sumi.css)
  @exports ~w(AttachmentNode FootnoteDefinitionNode FootnoteReferenceNode GalleryNode ImageNode
              Kotoba MentionNode highlightRenderedContent registerCollaboration)

  @moduletag :build
  @moduletag timeout: 600_000

  unless System.find_executable("npm") do
    @moduletag skip: "npm is not on the path, so mix kotoba.build cannot run"
  end

  setup_all do
    # Files from an earlier build must not make the test pass, and a stray
    # file must be gone after the build.
    for file <- @files, do: File.rm(Path.join(@static, file))
    File.mkdir_p!(Path.join(@static, "stray"))
    File.write!(Path.join(@static, "stray/leftover.js"), "")

    mix = System.find_executable("mix") || flunk("mix is not on the path")

    {output, status} =
      System.cmd(mix, ["kotoba.build"],
        cd: @root,
        env: [{"MIX_ENV", "dev"}],
        stderr_to_stdout: true
      )

    %{output: output, status: status}
  end

  test "mix kotoba.build writes the bundles and the style sheets", %{
    output: output,
    status: status
  } do
    assert status == 0, "mix kotoba.build failed:\n" <> output

    for file <- @files do
      path = Path.join(@static, file)
      assert File.regular?(path), "#{file} is missing"
      assert File.stat!(path).size > 0, "#{file} is empty"
    end
  end

  test "priv/static holds only the six files of the package" do
    assert @static |> File.ls!() |> Enum.sort() == Enum.sort(@files)
  end

  test "the ESM bundle exports the hook and the node classes" do
    esm = File.read!(Path.join(@static, "kotoba.esm.js"))
    [exports] = Regex.run(~r/export\{([^}]*)\}/, esm, capture: :all_but_first)
    names = exports |> String.split(",") |> Enum.map(&(&1 |> String.split(" as ") |> List.last()))

    for name <- @exports, do: assert(name in names, "kotoba.esm.js does not export #{name}")
  end

  describe "mix hex.build" do
    @describetag :tmp_dir

    test "packages the bundles and the guides, and no development files", %{tmp_dir: tmp_dir} do
      mix = System.find_executable("mix")
      out = Path.join(tmp_dir, "package")

      {output, status} =
        System.cmd(mix, ["hex.build", "--unpack", "--output", out],
          cd: @root,
          env: [{"MIX_ENV", "dev"}],
          stderr_to_stdout: true
        )

      assert status == 0, "mix hex.build failed:\n" <> output

      files =
        out
        |> Path.join("**")
        |> Path.wildcard(match_dot: true)
        |> Enum.filter(&File.regular?/1)
        |> Enum.map(&Path.relative_to(&1, out))

      for file <- @files do
        assert "priv/static/#{file}" in files, "the package has no priv/static/#{file}"
      end

      assert files |> Enum.filter(&String.starts_with?(&1, "priv/")) |> Enum.sort() ==
               @files |> Enum.map(&"priv/static/#{&1}") |> Enum.sort()

      guides =
        @root
        |> Path.join("guides/*.md")
        |> Path.wildcard()
        |> Enum.map(&Path.relative_to(&1, @root))

      assert guides != []
      for guide <- guides, do: assert(guide in files, "the package has no #{guide}")

      for file <- files, prefix <- ~w(tmp/ dev/ e2e/ test/ assets/ deps/ _build/ doc/) do
        refute String.starts_with?(file, prefix), "the package has #{file}"
      end

      refute "dev.exs" in files
    end
  end

  describe "the CJS bundle" do
    if System.find_executable("node") == nil do
      @describetag skip: "node is not on the path, so the CJS bundle cannot be required"
    end

    test "require() of the package entry point gives the hook and the node classes" do
      script = """
      const kotoba = require("./priv/static/kotoba.cjs.js");
      process.stdout.write(JSON.stringify(Object.keys(kotoba).sort()));
      """

      {output, status} = System.cmd("node", ["-e", script], cd: @root, stderr_to_stdout: true)

      assert status == 0, "node could not require kotoba.cjs.js:\n" <> output
      assert JSON.decode!(output) == @exports
    end
  end
end
