#!/usr/bin/env python3
"""Minimal Converger Protocol v1 client using only the `websockets` library.

Connects to the native endpoint (/socket/converger/v1), sends `hello`, prints
`welcome` and the replayed frames, sends one `text` turn with a clientId,
waits for its `ack`, then prints live frames until interrupted.

    pip install websockets
    python converger_ws.py --url ws://localhost:4000/socket/converger/v1 \
        --token "$CONVERGER_TOKEN" --text "Where is my order?"

The token is a Converger token from POST /api/v1/converger/tokens/generate or
POST /api/v1/converger/conversations. See docs/protocol/v1.md.
"""

import argparse
import asyncio
import json
import uuid

import websockets


async def run(url: str, token: str, text: str, watermark: int, listen: bool) -> None:
    async with websockets.connect(
        url,
        subprotocols=["converger.v1"],
        additional_headers={"Authorization": f"Bearer {token}"},
    ) as ws:
        await ws.send(json.dumps({"type": "hello", "protocol": "converger/1", "watermark": watermark}))

        welcome = json.loads(await ws.recv())
        if welcome["type"] != "welcome":
            raise SystemExit(f"handshake failed: {welcome}")
        print("welcome:", json.dumps(welcome["data"]))

        client_id = f"py-{uuid.uuid4()}"
        await ws.send(json.dumps({"type": "text", "clientId": client_id, "data": {"text": text}}))

        # Replayed frames may arrive before the ack; print everything until it.
        while True:
            frame = json.loads(await ws.recv())
            if frame["type"] == "ack" and frame["clientId"] == client_id:
                print(f"ack: id={frame['id']} seq={frame['seq']}")
                break
            if frame["type"] == "error":
                raise SystemExit(f"send failed: {frame['data']}")
            print("frame:", json.dumps(frame))

        while listen:
            frame = json.loads(await ws.recv())
            print("frame:", json.dumps(frame))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--url", default="ws://localhost:4000/socket/converger/v1")
    parser.add_argument("--token", required=True)
    parser.add_argument("--text", default="Hello from Python")
    parser.add_argument("--watermark", type=int, default=0, help="last seq already seen")
    parser.add_argument("--no-listen", dest="listen", action="store_false")
    args = parser.parse_args()
    asyncio.run(run(args.url, args.token, args.text, args.watermark, args.listen))


if __name__ == "__main__":
    main()
