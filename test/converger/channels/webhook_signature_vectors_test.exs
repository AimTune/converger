defmodule Converger.Channels.WebhookSignatureVectorsTest do
  # The SDKs (packages/client-*) verify webhook signatures against
  # packages/conformance/webhook-signatures.json. This test pins that file to
  # the signer the webhook adapter actually uses, so a change to the scheme
  # cannot ship without regenerating the vectors (and breaking the SDK tests).
  use ExUnit.Case, async: true

  alias Converger.Channels.InboundSignature

  @path Path.expand("../../../packages/conformance/webhook-signatures.json", __DIR__)
  @external_resource @path
  @vectors @path |> File.read!() |> Jason.decode!()

  test "the header name and default tolerance match the server" do
    assert @vectors["header"] == "x-converger-signature"
    assert @vectors["default_tolerance_seconds"] == InboundSignature.tolerance_seconds()
  end

  for vector <- @vectors["sign"] do
    @vector vector
    test "sign vector #{vector["name"]} is what the server signer produces" do
      %{"secret" => secret, "body" => body, "timestamp" => t, "header" => header} = @vector
      assert InboundSignature.sign(secret, body, t) == header
    end

    test "sign vector #{vector["name"]} verifies with the server verifier when fresh" do
      %{"secret" => secret, "body" => body} = @vector
      header = InboundSignature.sign(secret, body)

      assert InboundSignature.verify(%{secret: secret}, [{"x-converger-signature", header}], body) ==
               :ok
    end
  end

  test "every verify vector names a documented error" do
    errors = @vectors["errors"]

    for v <- @vectors["verify"] do
      assert is_boolean(v["valid"])
      if v["valid"], do: assert(is_nil(v["error"])), else: assert(v["error"] in errors)
    end
  end

  test "the documented test vector in docs/webhooks.md is the first sign vector" do
    docs = File.read!(Path.expand("../../../docs/webhooks.md", __DIR__))
    [documented | _] = @vectors["sign"]
    assert docs =~ documented["header"]
  end
end
