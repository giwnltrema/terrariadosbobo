const state = {
  size: "medium",
  difficulty: "classic",
  worldEvil: "random",
  selectedSeedIds: new Set(),
  specialSeeds: [],
  managementTimer: null,
  lastManagement: null,
};

const worldNameEl = document.getElementById("worldName");
const manualSeedEl = document.getElementById("manualSeed");
const maxPlayersEl = document.getElementById("maxPlayers");
const serverPortEl = document.getElementById("serverPort");
const extraArgsEl = document.getElementById("extraArgs");
const outputEl = document.getElementById("output");
const runStatusEl = document.getElementById("runStatus");
const resolvedSeedEl = document.getElementById("resolvedSeed");
const selectedSeedsLabelEl = document.getElementById("selectedSeedsLabel");

const seedModalEl = document.getElementById("seedModal");
const seedListEl = document.getElementById("seedList");
const seedSearchEl = document.getElementById("seedSearch");

const mgmtStatusEl = document.getElementById("mgmtStatus");
const activeWorldEl = document.getElementById("activeWorld");
const playersNowEl = document.getElementById("playersNow");
const sourceUpEl = document.getElementById("sourceUp");
const parserUpEl = document.getElementById("parserUp");
const replicasEl = document.getElementById("replicas");
const endpointsEl = document.getElementById("endpoints");
const worldListEl = document.getElementById("worldList");
const runtimeInfoEl = document.getElementById("runtimeInfo");
const podListEl = document.getElementById("podList");
const metricsInfoEl = document.getElementById("metricsInfo");
const serverLogsEl = document.getElementById("serverLogs");

function setStatus(chipEl, mode, text) {
  chipEl.className = `status-chip ${mode}`;
  chipEl.textContent = text;
}

function bindChoiceGroup(rootId, key) {
  const root = document.getElementById(rootId);
  for (const button of root.querySelectorAll("button")) {
    button.addEventListener("click", () => {
      for (const b of root.querySelectorAll("button")) {
        b.classList.remove("active");
      }
      button.classList.add("active");
      state[key] = button.dataset.value;
    });
  }
}

function resolveSeedPreview() {
  const manual = manualSeedEl.value.trim();
  if (manual.length > 0) {
    return { seed: manual, mode: "custom" };
  }

  const selected = state.specialSeeds.filter((seed) => state.selectedSeedIds.has(seed.id));
  if (selected.length === 0) {
    return { seed: "", mode: "random" };
  }

  const hasZenith = selected.some((seed) => seed.id === "zenith");
  if (selected.length > 1 || hasZenith) {
    return { seed: "get fixed boi", mode: "multi-special->zenith" };
  }

  return { seed: selected[0].seed, mode: `special:${selected[0].id}` };
}

function refreshSeedSummary() {
  const selected = state.specialSeeds.filter((seed) => state.selectedSeedIds.has(seed.id));
  if (selected.length === 0) {
    selectedSeedsLabelEl.textContent = "No special seeds selected";
  } else {
    selectedSeedsLabelEl.textContent = selected.map((seed) => seed.label).join(", ");
  }

  const resolved = resolveSeedPreview();
  resolvedSeedEl.textContent = resolved.seed || "(random)";
}

function renderSeedCards(filterText = "") {
  const q = filterText.trim().toLowerCase();
  seedListEl.innerHTML = "";

  for (const seed of state.specialSeeds) {
    const hay = `${seed.label} ${seed.seed} ${seed.description}`.toLowerCase();
    if (q && !hay.includes(q)) {
      continue;
    }

    const card = document.createElement("label");
    card.className = "seed-card";
    const checked = state.selectedSeedIds.has(seed.id) ? "checked" : "";

    card.innerHTML = `
      <div>
        <input type="checkbox" data-seed-id="${seed.id}" ${checked}>
        <span class="seed-name">${seed.label}</span>
      </div>
      <div class="seed-desc">${seed.description}</div>
      <div class="seed-desc">seed: ${seed.seed}</div>
    `;

    seedListEl.appendChild(card);
  }

  for (const checkbox of seedListEl.querySelectorAll("input[type='checkbox']")) {
    checkbox.addEventListener("change", () => {
      const id = checkbox.dataset.seedId;
      if (checkbox.checked) {
        state.selectedSeedIds.add(id);
      } else {
        state.selectedSeedIds.delete(id);
      }
    });
  }
}

async function loadSeeds() {
  const response = await fetch("/api/special-seeds");
  const data = await response.json();
  state.specialSeeds = data.seeds || [];
  renderSeedCards();
  refreshSeedSummary();
}

function openModal() {
  seedModalEl.classList.remove("hidden");
}

function closeModal() {
  seedModalEl.classList.add("hidden");
}

function stringifyCommand(command) {
  if (!Array.isArray(command)) {
    return "";
  }
  return command.map((part) => String(part)).join(" ");
}

async function createWorld() {
  const payload = {
    world_name: worldNameEl.value.trim() || "test.wld",
    seed: manualSeedEl.value.trim(),
    special_seed_ids: Array.from(state.selectedSeedIds),
    world_size: state.size,
    difficulty: state.difficulty,
    world_evil: state.worldEvil,
    max_players: Number(maxPlayersEl.value || 8),
    server_port: Number(serverPortEl.value || 7777),
    extra_create_args: extraArgsEl.value.trim(),
  };

  setStatus(runStatusEl, "running", "running");
  outputEl.textContent = "Running upload-world script...";
  document.getElementById("createWorld").disabled = true;

  try {
    const response = await fetch("/api/create-world", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    });
    const result = await response.json();

    const lines = [
      `ok: ${result.ok}`,
      `exit_code: ${result.exit_code}`,
      `seed_mode: ${result.seed_mode}`,
      `resolved_seed: ${result.resolved_seed || "(random)"}`,
      `duration_seconds: ${result.duration_seconds}`,
      "",
      "command:",
      stringifyCommand(result.command),
      "",
      "output:",
      result.output || "(no output)",
    ];

    outputEl.textContent = lines.join("\n");
    setStatus(runStatusEl, result.ok ? "success" : "error", result.ok ? "success" : "error");

    await fetchManagement();
  } catch (error) {
    outputEl.textContent = `Request failed: ${error}`;
    setStatus(runStatusEl, "error", "error");
  } finally {
    document.getElementById("createWorld").disabled = false;
  }
}

function metricValue(value) {
  if (value === null || value === undefined || Number.isNaN(value)) {
    return "-";
  }
  if (Number.isInteger(value)) {
    return `${value}`;
  }
  return `${Number(value).toFixed(2)}`;
}

function renderKV(container, pairs) {
  container.innerHTML = "";
  for (const [key, value] of pairs) {
    const row = document.createElement("div");
    row.className = "kv-row";
    row.innerHTML = `<span>${key}</span><strong>${value ?? "-"}</strong>`;
    container.appendChild(row);
  }
}

function renderWorldList(snapshot) {
  worldListEl.innerHTML = "";
  const worlds = snapshot.worlds || [];
  if (worlds.length === 0) {
    worldListEl.innerHTML = `<div class="muted">No .wld file found in /config</div>`;
    return;
  }

  const activeWorld = (snapshot.deployment || {}).world || "";
  for (const world of worlds) {
    const row = document.createElement("div");
    row.className = "world-row";
    const isActive = world === activeWorld;
    row.innerHTML = `
      <div>
        <strong>${world}</strong>
        <span class="muted">${isActive ? "active" : "available"}</span>
      </div>
      <button class="${isActive ? "secondary" : "ghost"}" data-world="${world}" ${isActive ? "disabled" : ""}>
        ${isActive ? "Active" : "Set Active"}
      </button>
    `;
    worldListEl.appendChild(row);
  }

  for (const button of worldListEl.querySelectorAll("button[data-world]")) {
    button.addEventListener("click", async () => {
      const world = button.dataset.world;
      await serverAction("set_world", { world_name: world, restart: true });
    });
  }
}

function renderPods(snapshot) {
  podListEl.innerHTML = "";
  const pods = snapshot.pods || [];
  if (pods.length === 0) {
    podListEl.innerHTML = `<div class="muted">No pod found for app=${snapshot.deployment_name}</div>`;
    return;
  }

  for (const pod of pods) {
    const row = document.createElement("div");
    row.className = "pod-row";
    row.innerHTML = `
      <div class="pod-main">
        <strong>${pod.name}</strong>
        <span>${pod.phase}</span>
      </div>
      <div class="pod-sub">
        ready ${pod.ready} | restarts ${pod.restarts} | age ${pod.age || "-"}
      </div>
    `;
    podListEl.appendChild(row);
  }
}

function renderManagement(snapshot) {
  state.lastManagement = snapshot;
  const deployment = snapshot.deployment || {};
  const metrics = snapshot.metrics || {};
  const service = snapshot.service || {};

  activeWorldEl.textContent = deployment.world || "-";
  playersNowEl.textContent = `${metricValue(metrics.players_online)} / ${metricValue(metrics.players_max)}`;
  sourceUpEl.textContent = metricValue(metrics.source_up);
  parserUpEl.textContent = metricValue(metrics.world_parser_up);
  replicasEl.textContent = `${deployment.replicas_ready ?? 0}/${deployment.replicas_desired ?? 0}`;
  endpointsEl.textContent = `${(snapshot.endpoints || {}).ready ?? 0}`;

  renderWorldList(snapshot);
  renderPods(snapshot);

  renderKV(runtimeInfoEl, [
    ["Namespace", snapshot.namespace],
    ["Deployment", snapshot.deployment_name],
    ["Service", snapshot.service_name],
    ["Image", deployment.image || "-"],
    ["World path", deployment.worldpath || "-"],
    ["Service type", service.type || "-"],
    ["NodePort 7777", service.node_port_terraria || "-"],
    ["NodePort API", service.node_port_api || "-"],
    ["Cluster IP", service.cluster_ip || "-"],
  ]);

  renderKV(metricsInfoEl, [
    ["Players online", metricValue(metrics.players_online)],
    ["Players max", metricValue(metrics.players_max)],
    ["Hardmode", metricValue(metrics.hardmode)],
    ["Blood moon", metricValue(metrics.blood_moon)],
    ["Eclipse", metricValue(metrics.eclipse)],
    ["World time", metricValue(metrics.world_time)],
    ["Chests", metricValue(metrics.chests_total)],
    ["Houses", metricValue(metrics.houses_total)],
    ["Housed NPCs", metricValue(metrics.housed_npcs_total)],
  ]);

  serverLogsEl.textContent = (snapshot.logs || {}).tail || "(no logs)";

  if (snapshot.ok) {
    setStatus(mgmtStatusEl, "success", "ok");
  } else {
    const issue = (snapshot.issues || [])[0] || "degraded";
    setStatus(mgmtStatusEl, "error", issue);
  }
}

async function fetchManagement() {
  setStatus(mgmtStatusEl, "running", "refreshing");
  try {
    const response = await fetch("/api/management");
    const snapshot = await response.json();
    renderManagement(snapshot);
  } catch (error) {
    setStatus(mgmtStatusEl, "error", "offline");
    serverLogsEl.textContent = `Failed to load management data: ${error}`;
  }
}

async function serverAction(action, payload = {}) {
  setStatus(mgmtStatusEl, "running", `${action}...`);
  try {
    const response = await fetch("/api/server-action", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ action, ...payload }),
    });
    const result = await response.json();

    const summary = [
      `action: ${action}`,
      `ok: ${result.ok}`,
      "",
      ...(result.results || []).flatMap((entry) => [
        `$ ${stringifyCommand(entry.command)}`,
        entry.output || "(no output)",
        "",
      ]),
    ].join("\n");

    outputEl.textContent = summary;
    setStatus(runStatusEl, result.ok ? "success" : "error", result.ok ? "success" : "error");
  } catch (error) {
    outputEl.textContent = `Server action failed: ${error}`;
    setStatus(runStatusEl, "error", "error");
  }
  await fetchManagement();
}

function boot() {
  bindChoiceGroup("sizeChoices", "size");
  bindChoiceGroup("difficultyChoices", "difficulty");
  bindChoiceGroup("evilChoices", "worldEvil");

  manualSeedEl.addEventListener("input", refreshSeedSummary);

  document.getElementById("openSeedModal").addEventListener("click", openModal);
  document.getElementById("closeSeedModal").addEventListener("click", closeModal);
  document.getElementById("applySeeds").addEventListener("click", () => {
    refreshSeedSummary();
    closeModal();
  });

  document.getElementById("clearSeeds").addEventListener("click", () => {
    state.selectedSeedIds.clear();
    renderSeedCards(seedSearchEl.value);
    refreshSeedSummary();
  });

  seedSearchEl.addEventListener("input", () => renderSeedCards(seedSearchEl.value));

  seedModalEl.addEventListener("click", (event) => {
    if (event.target === seedModalEl) {
      closeModal();
    }
  });

  document.getElementById("createWorld").addEventListener("click", createWorld);
  document.getElementById("refreshMgmt").addEventListener("click", fetchManagement);
  document.getElementById("startServer").addEventListener("click", () => serverAction("start"));
  document.getElementById("stopServer").addEventListener("click", () => serverAction("stop"));
  document.getElementById("restartServer").addEventListener("click", () => serverAction("restart"));

  setStatus(runStatusEl, "idle", "idle");
  setStatus(mgmtStatusEl, "idle", "idle");

  loadSeeds()
    .then(fetchManagement)
    .catch((error) => {
      outputEl.textContent = `Failed to load initial data: ${error}`;
      setStatus(runStatusEl, "error", "error");
    });

  state.managementTimer = setInterval(fetchManagement, 20000);
}

boot();
