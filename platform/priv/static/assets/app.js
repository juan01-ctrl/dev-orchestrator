import { Socket } from "/assets/phoenix.mjs";
import { LiveSocket } from "/assets/phoenix_live_view.esm.js";
import "/assets/phoenix_html.js";

document.addEventListener("click", async (event) => {
  const button = event.target.closest("[data-copy]");
  if (!button) return;

  const label = button.querySelector(".copy-label");
  const defaultLabel = label?.textContent ?? "Copy command";
  try {
    await navigator.clipboard.writeText(button.dataset.copy);
    if (label) label.textContent = "Copied";
  } catch {
    if (label) label.textContent = "Copy failed";
  }

  window.setTimeout(() => {
    if (label?.isConnected) label.textContent = defaultLabel;
  }, 2000);
});

const csrfToken = document.querySelector("meta[name='csrf-token']")?.content;
const liveSocket = new LiveSocket("/live", Socket, { params: { _csrf_token: csrfToken } });
liveSocket.connect();
