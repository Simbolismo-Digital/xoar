defmodule Mix.Tasks.Tar do
  @shortdoc "Package Xoar into xoar.tar.gz"
  @moduledoc "Creates a xoar.tar.gz archive of the project, excluding build artifacts."

  use Mix.Task

  @impl true
  def run(_args) do
    excludes = ~w(
      _build deps xoar.tar.gz .elixir_ls
      .git erl_crash.dump
    )

    exclude_flags =
      Enum.flat_map(excludes, fn e -> ["--exclude", e] end)

    args = ["czf", "xoar.tar.gz"] ++ exclude_flags ++ ["-C", "..", Path.basename(File.cwd!())]
    {_, return} = System.cmd("tar", args)
    # Code 0 is success, code 1 mean some files changed but success
    true = return in [0, 1]
    Mix.shell().info("Created xoar.tar.gz")
  end
end
