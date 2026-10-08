// Webhook sink for the chaos harness (no dependencies, Node >= 22).
//
// Accepts every request on POST /hook, answers 200 and appends one JSON line
// per request to $SINK_OUT (default /out/sink.jsonl): the delivery id header,
// the activity id and idempotency key from the body. Duplicates (same
// x-converger-delivery-id) are recorded too; verify.js de-duplicates them.
//
// GET /stats returns {requests, unique_deliveries}.
"use strict";

const http = require("node:http");
const fs = require("node:fs");

const port = Number(process.env.SINK_PORT || 8080);
const out = process.env.SINK_OUT || "/out/sink.jsonl";

const stream = fs.createWriteStream(out, { flags: "a" });
const seen = new Set();
let requests = 0;

const server = http.createServer((req, res) => {
  if (req.method === "GET" && req.url === "/stats") {
    res.writeHead(200, { "content-type": "application/json" });
    res.end(JSON.stringify({ requests, unique_deliveries: seen.size }));
    return;
  }

  if (req.method !== "POST" || req.url !== "/hook") {
    res.writeHead(404);
    res.end();
    return;
  }

  const chunks = [];
  req.on("data", (c) => chunks.push(c));
  req.on("end", () => {
    let body = {};
    try {
      body = JSON.parse(Buffer.concat(chunks).toString("utf8"));
    } catch (_e) {
      body = {};
    }

    const deliveryId = req.headers["x-converger-delivery-id"] || null;
    requests += 1;
    if (deliveryId) seen.add(deliveryId);

    stream.write(
      JSON.stringify({
        delivery_id: deliveryId,
        activity_id: body.id || null,
        conversation_id: body.conversation_id || null,
        idempotency_key: body.idempotency_key || null,
        text: body.text || null,
        at: Date.now(),
      }) + "\n",
    );

    res.writeHead(200, { "content-type": "application/json" });
    res.end("{}");
  });
});

server.listen(port, "0.0.0.0", () => {
  console.log(`sink listening on :${port}, writing ${out}`);
});

process.on("SIGTERM", () => {
  stream.end(() => process.exit(0));
});
