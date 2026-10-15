defmodule ConvergerClient.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/AimTune/converger/tree/main/packages/client-elixir"

  def project do
    [
      app: :converger_client,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      description:
        "Elixir client for Converger: REST (Req), Protocol v1 WebSocket client with resume (Mint.WebSocket) and webhook signature verification.",
      package: package(),
      docs: [main: "readme", extras: ["README.md"], source_ref: "client-elixir/v#{@version}"],
      source_url: @source_url
    ]
  end

  def application do
    [extra_applications: [:logger, :crypto]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:req, "~> 0.5"},
      {:mint, "~> 1.6"},
      {:mint_web_socket, "~> 1.0"},
      {:jason, "~> 1.4"},
      {:plug_crypto, "~> 2.0"},
      {:bandit, "~> 1.5", only: :test},
      {:websock_adapter, "~> 0.5", only: :test},
      {:plug, "~> 1.15", only: :test},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      name: "converger_client",
      licenses: ["MIT"],
      files: ~w(lib mix.exs README.md CHANGELOG.md),
      links: %{
        "Source" => @source_url,
        "Docs" => "https://converger.aimtune.dev/sdk/elixir"
      }
    ]
  end
end
