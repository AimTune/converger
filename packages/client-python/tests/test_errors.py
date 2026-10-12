import pytest

from converger import ApiError
from conftest import load

CASES = load("errors.json")["cases"]


@pytest.mark.parametrize("case", CASES, ids=lambda c: c["name"])
def test_error_normalization(case):
    err = ApiError.from_response(case["status"], case["headers"], case["body"].encode("utf-8"))
    got = {k: getattr(err, k) for k in case["expected"]}
    assert got == case["expected"]
