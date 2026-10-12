import pytest

from converger import WebhookSignatureError, is_valid_signature, sign, verify_signature
from conftest import load

VECTORS = load("webhook-signatures.json")


@pytest.mark.parametrize("v", VECTORS["sign"], ids=lambda v: v["name"])
def test_sign_vectors(v):
    assert sign(v["secret"], v["body"].encode("utf-8"), v["timestamp"]) == v["header"]
    assert sign(v["secret"], v["body"], v["timestamp"]) == v["header"]


@pytest.mark.parametrize("v", VECTORS["verify"], ids=lambda v: v["name"])
def test_verify_vectors(v):
    kwargs = {"tolerance": v.get("tolerance", VECTORS["default_tolerance_seconds"]), "now": v["now"]}
    body = v["body"].encode("utf-8")
    if v["valid"]:
        verify_signature(v["headers"], body, v["secret"], **kwargs)
        assert is_valid_signature(list(v["headers"].items()), body, v["secret"], **kwargs)
    else:
        with pytest.raises(WebhookSignatureError) as exc:
            verify_signature(v["headers"], body, v["secret"], **kwargs)
        assert exc.value.reason == v["error"]
        assert not is_valid_signature(v["headers"], body, v["secret"], **kwargs)


def test_fresh_signature_verifies_with_the_clock():
    header = sign("whsec_x", b"{}")
    verify_signature({"x-converger-signature": header}, b"{}", "whsec_x")
