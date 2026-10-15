# Generates packages/conformance/webhook-signatures.json from the server's
# real signer, Converger.Channels.InboundSignature.sign/3 (the function the
# webhook adapter calls for every outbound delivery).
#
#     mix run --no-start packages/conformance/scripts/generate_signature_vectors.exs
#
# test/converger/channels/webhook_signature_vectors_test.exs fails when the
# committed file and the signer disagree, and every SDK verifies against the
# same file (see packages/conformance/README.md).

alias Converger.Channels.InboundSignature

out = Path.expand("../webhook-signatures.json", __DIR__)

sign_inputs = [
  %{
    "name" => "documented",
    "description" => "The test vector published in docs/webhooks.md.",
    "secret" => "whsec_test_secret",
    "timestamp" => 1_700_000_000,
    "body" => ~s({"id":"9b2f6c1e-0000-4000-8000-000000000001","text":"hello"})
  },
  %{
    "name" => "activity",
    "description" => "A realistic webhook body: the canonical activity plus timestamp.",
    "secret" => "whsec_9f8e7d6c5b4a39281706f5e4d3c2b1a0",
    "timestamp" => 1_760_000_000,
    "body" =>
      ~s({"attachments":[],"conversation_id":"3f6d1c2e-8a4b-4f1e-9c51-0e6a2b7d9f10","deleted_at":null,"edited_at":null,"id":"a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d","idempotency_key":null,"inserted_at":"2026-10-09T12:05:41.004512Z","metadata":{},"reply_to_id":null,"sender":"bot","seq":3,"tenant_id":"c2a4e6f8-1b3d-4f5a-9c7e-2d4f6a8b0c1e","text":"We are open 9 to 5.","timestamp":"2026-10-09T12:05:41.010000Z","type":"message"})
  },
  %{
    "name" => "unicode",
    "description" => "Non-ASCII UTF-8 in the body: the HMAC is over the raw bytes.",
    "secret" => "s3cr3t-ünïcode",
    "timestamp" => 1_760_000_123,
    "body" => ~s({"text":"Merhaba dünya 👋 — ç ğ ı ö ş ü"})
  },
  %{
    "name" => "empty_body",
    "description" => "An empty body is signed as \"<t>.\".",
    "secret" => "whsec_empty",
    "timestamp" => 1_700_000_001,
    "body" => ""
  },
  %{
    "name" => "whitespace",
    "description" => "Whitespace and newlines are significant: verify the raw body, never re-serialized JSON.",
    "secret" => "whsec_ws",
    "timestamp" => 1_760_000_999,
    "body" => "{\n  \"text\": \"pretty printed\"\n}\n"
  }
]

sign =
  for input <- sign_inputs do
    Map.put(input, "header", InboundSignature.sign(input["secret"], input["body"], input["timestamp"]))
  end

by_name = Map.new(sign, &{&1["name"], &1})
a = by_name["activity"]
t = a["timestamp"]
v1 = fn secret, body, ts -> InboundSignature.hmac_hex(secret, "#{ts}.#{body}") end
good = v1.(a["secret"], a["body"], t)
wrong = v1.("not-the-secret", a["body"], t)

verify_case = fn name, attrs ->
  Map.merge(
    %{
      "name" => name,
      "secret" => a["secret"],
      "body" => a["body"],
      "now" => t,
      "headers" => %{"x-converger-signature" => a["header"]},
      "valid" => true,
      "error" => nil
    },
    attrs
  )
end

invalid = fn name, error, attrs -> verify_case.(name, Map.merge(%{"valid" => false, "error" => error}, attrs)) end

verify =
  [
    verify_case.("valid", %{}),
    verify_case.("valid_at_past_tolerance_boundary", %{"now" => t + 300}),
    verify_case.("valid_at_future_tolerance_boundary", %{"now" => t - 300}),
    invalid.("expired", "timestamp_out_of_tolerance", %{"now" => t + 301}),
    invalid.("too_far_in_future", "timestamp_out_of_tolerance", %{"now" => t - 301}),
    verify_case.("custom_tolerance", %{"now" => t + 500, "tolerance" => 600}),
    invalid.("custom_tolerance_exceeded", "timestamp_out_of_tolerance", %{"now" => t + 61, "tolerance" => 60}),
    invalid.("tampered_body", "invalid_signature", %{"body" => String.replace(a["body"], "9 to 5", "9 to 6")}),
    invalid.("wrong_secret", "invalid_signature", %{"secret" => "whsec_wrong"}),
    invalid.("uppercase_hex_is_not_accepted", "invalid_signature", %{
      "headers" => %{"x-converger-signature" => "t=#{t},v1=#{String.upcase(good)}"}
    }),
    verify_case.("multiple_v1_one_matches", %{
      "description" => "Several v1 values (secret rotation): one match is enough.",
      "headers" => %{"x-converger-signature" => "t=#{t},v1=#{wrong},v1=#{good}"}
    }),
    verify_case.("receiver_secret_list", %{
      "description" => "The receiver may pass several secrets (rotation on its side).",
      "secret" => ["whsec_old_rotated_out", a["secret"]]
    }),
    verify_case.("spaces_around_parts", %{"headers" => %{"x-converger-signature" => "t=#{t}, v1=#{good}"}}),
    verify_case.("reordered_parts", %{"headers" => %{"x-converger-signature" => "v1=#{good},t=#{t}"}}),
    verify_case.("unknown_parts_ignored", %{
      "headers" => %{"x-converger-signature" => "t=#{t},v0=deadbeef,v1=#{good}"}
    }),
    verify_case.("header_name_case_insensitive", %{"headers" => %{"X-Converger-Signature" => a["header"]}}),
    invalid.("missing_header", "missing_signature", %{"headers" => %{"content-type" => "application/json"}}),
    invalid.("empty_header", "missing_signature", %{"headers" => %{"x-converger-signature" => ""}}),
    invalid.("empty_secret", "no_secret", %{"secret" => ""}),
    invalid.("legacy_sha256_not_accepted", "malformed_signature", %{
      "description" => "Outbound webhooks never use the legacy sha256= form; SDKs reject it.",
      "headers" => %{"x-converger-signature" => InboundSignature.sign_legacy(a["secret"], a["body"])}
    }),
    invalid.("missing_timestamp", "malformed_signature", %{"headers" => %{"x-converger-signature" => "v1=#{good}"}}),
    invalid.("non_integer_timestamp", "malformed_signature", %{
      "headers" => %{"x-converger-signature" => "t=17600000x0,v1=#{good}"}
    }),
    invalid.("missing_v1", "malformed_signature", %{"headers" => %{"x-converger-signature" => "t=#{t}"}}),
    invalid.("garbage", "malformed_signature", %{"headers" => %{"x-converger-signature" => "not a signature"}})
  ] ++
    for name <- ["documented", "unicode", "empty_body", "whitespace"] do
      s = by_name[name]

      verify_case.("sign_vector_#{name}", %{
        "secret" => s["secret"],
        "body" => s["body"],
        "now" => s["timestamp"],
        "headers" => %{"x-converger-signature" => s["header"]}
      })
    end

doc = %{
  "description" =>
    "Converger outbound webhook signature test vectors, generated from Converger.Channels.InboundSignature.sign/3 by packages/conformance/scripts/generate_signature_vectors.exs. Do not edit by hand.",
  "header" => "x-converger-signature",
  "scheme" => "t=<unix seconds>,v1=<lowercase hex HMAC-SHA256(secret, \"<t>.\" + raw body)>",
  "default_tolerance_seconds" => 300,
  "errors" => [
    "missing_signature",
    "no_secret",
    "malformed_signature",
    "timestamp_out_of_tolerance",
    "invalid_signature"
  ],
  "sign" => sign,
  "verify" => verify
}

File.write!(out, Jason.encode_to_iodata!(doc, pretty: true) |> IO.iodata_to_binary() |> Kernel.<>("\n"))
IO.puts("wrote #{Path.relative_to_cwd(out)} (#{length(sign)} sign, #{length(verify)} verify vectors)")
