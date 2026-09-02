const board = document.getElementById("board");
const summary = document.getElementById("summary");
const form = document.getElementById("add-form");
const formError = document.getElementById("form-error");
const footer = document.getElementById("footer");
const REFRESH_MS = 5000;

async function loadSites() {
  try {
    const res = await fetch("/api/sites");
    if (!res.ok) throw new Error(`api returned ${res.status}`);
    const data = await res.json();
    render(data.sites);
    footer.textContent =
      `each site is checked every ${data.check_interval_seconds}s by the worker · ` +
      `this board refreshes every ${REFRESH_MS / 1000}s`;
  } catch (err) {
    summary.textContent = `cannot reach api: ${err.message}`;
  }
}

function render(sites) {
  board.replaceChildren();
  if (sites.length === 0) {
    const p = document.createElement("p");
    p.className = "empty";
    p.textContent = "no sites yet. add one above.";
    board.appendChild(p);
    summary.textContent = "";
    return;
  }

  let up = 0, down = 0;
  for (const site of sites) {
    const s = site.status;
    const state = !s ? "pending" : s.ok ? "up" : "down";
    if (state === "up") up++;
    if (state === "down") down++;

    const tile = document.createElement("div");
    tile.className = `tile ${state}`;

    const remove = document.createElement("button");
    remove.className = "remove";
    remove.title = "remove site";
    remove.textContent = "×";
    remove.addEventListener("click", () => deleteSite(site.id));

    const h2 = document.createElement("h2");
    h2.textContent = site.name;

    const url = document.createElement("div");
    url.className = "url";
    url.textContent = site.url;

    const stateEl = document.createElement("div");
    stateEl.className = "state";
    stateEl.textContent = state;

    const meta = document.createElement("div");
    meta.className = "meta";
    meta.textContent = s
      ? `${s.latency_ms} ms · ${s.status_code ?? "no response"} · ${timeAgo(s.checked_at)}`
      : "waiting for first check";

    tile.append(remove, h2, url, stateEl, meta);

    if (s && s.error) {
      const err = document.createElement("div");
      err.className = "err";
      err.textContent = s.error;
      tile.appendChild(err);
    }
    board.appendChild(tile);
  }
  summary.textContent = `${up} up · ${down} down · ${sites.length - up - down} pending`;
}

function timeAgo(iso) {
  const secs = Math.max(0, Math.round((Date.now() - new Date(iso).getTime()) / 1000));
  if (secs < 60) return `${secs}s ago`;
  const mins = Math.round(secs / 60);
  if (mins < 60) return `${mins}m ago`;
  return `${Math.round(mins / 60)}h ago`;
}

async function deleteSite(id) {
  await fetch(`/api/sites/${id}`, { method: "DELETE" });
  loadSites();
}

form.addEventListener("submit", async (e) => {
  e.preventDefault();
  formError.textContent = "";
  const url = document.getElementById("url").value.trim();
  const name = document.getElementById("name").value.trim();
  const res = await fetch("/api/sites", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ url, name: name || null }),
  });
  if (!res.ok) {
    const body = await res.json().catch(() => ({}));
    formError.textContent = typeof body.detail === "string" ? body.detail : `error ${res.status}`;
    return;
  }
  form.reset();
  loadSites();
});

loadSites();
setInterval(loadSites, REFRESH_MS);
