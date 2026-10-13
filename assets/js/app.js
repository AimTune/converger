// Admin panel and tenant portal (ADR-0060). Bundled by esbuild from deps/
// (NODE_PATH, no npm): `mix assets.build`, or the dev watcher.

// Handles method=PUT/DELETE links and data-confirm in plain HTML forms.
import "phoenix_html"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import topbar from "../vendor/topbar"

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken}
})

// Progress bar on live navigation and form submits
topbar.config({barColors: {0: "#2563eb"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

liveSocket.connect()

// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)
window.liveSocket = liveSocket

// Flash messages of controller-rendered pages (login, password change): click to dismiss.
document.querySelectorAll("[role=alert][data-flash]").forEach((el) => {
  el.addEventListener("click", () => el.setAttribute("hidden", ""))
})
