defmodule Xoar.MixProject do
  use Mix.Project

  def project do
    [
      app: :xoar,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Xoar.Application, []}
    ]
  end

  defp deps do
    []
  end
end
