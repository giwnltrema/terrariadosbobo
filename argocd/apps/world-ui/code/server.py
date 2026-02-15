#!/usr/bin/env python3
import argparse
import json
import os
import subprocess
import time
from datetime import datetime, timezone
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Dict, List, Optional, Tuple
from urllib.parse import quote, urlparse
from urllib.request import Request, urlopen

REPO_ROOT = Path(__file__).resolve().parents[1]
STATIC_DIR = Path(__file__).resolve().parent / "static"

DEFAULT_TERRARIA_NAMESPACE = os.environ.get("TERRARIA_NAMESPACE", "terraria")
DEFAULT_TERRARIA_DEPLOYMENT = os.environ.get("TERRARIA_DEPLOYMENT", "terraria-server")
DEFAULT_TERRARIA_APP_LABEL = os.environ.get("TERRARIA_APP_LABEL", "terraria-server")
DEFAULT_TERRARIA_SERVICE = os.environ.get("TERRARIA_SERVICE", "terraria-service")
DEFAULT_PROMETHEUS_URLS = [
    "http://kube-prom-stack-kube-prome-prometheus.monitoring.svc.cluster.local:9090",
    "http://localhost:30090",
]

SPECIAL_SEEDS = [
    {
        "id": "drunk_world",
        "label": "Drunk world",
        "seed": "05162020",
        "description": "Mixed evil world style.",
    },
    {
        "id": "for_the_worthy",
        "label": "For the worthy",
        "seed": "for the worthy",
        "description": "Harder enemies and traps.",
    },
    {
        "id": "the_constant",
        "label": "The constant",
        "seed": "the constant",
        "description": "Darkness and hunger effects.",
    },
    {
        "id": "not_the_bees",
        "label": "Not the bees",
        "seed": "not the bees",
        "description": "World with heavy bee biome generation.",
    },
    {
        "id": "dont_starve",
        "label": "Dont starve",
        "seed": "dont starve",
        "description": "Cross-over hunger style world.",
    },
    {
        "id": "celebrationmk10",
        "label": "Celebrationmk10",
        "seed": "celebrationmk10",
        "description": "Celebration style world generation.",
    },
    {
        "id": "no_traps",
        "label": "No traps",
        "seed": "no traps",
        "description": "Trap focused generation changes.",
    },
    {
        "id": "dont_dig_up",
        "label": "Dont dig up",
        "seed": "dont dig up",
        "description": "Inverted progression style world.",
    },
    {
        "id": "zenith",
        "label": "Zenith (Get fixed boi)",
        "seed": "get fixed boi",
        "description": "Combined ultra-special world.",
    },
    {
        "id": "abandoned_manors",
        "label": "Abandoned manors",
        "seed": "abandoned manors",
        "description": "Custom seed library preset.",
    },
    {
        "id": "arachnophobia",
        "label": "Arachnophobia",
        "seed": "arachnophobia",
        "description": "Custom seed library preset.",
    },
    {
        "id": "beam_me_up",
        "label": "Beam me up",
        "seed": "beam me up",
        "description": "Custom seed library preset.",
    },
    {
        "id": "bring_a_towel",
        "label": "Bring a towel",
        "seed": "bring a towel",
        "description": "Custom seed library preset.",
    },
    {
        "id": "does_that_sparkle",
        "label": "Does that sparkle",
        "seed": "does that sparkle",
        "description": "Custom seed library preset.",
    },
]


def now_rfc3339() -> str:
    return datetime.now(timezone.utc).isoformat()


def parse_kube_time(value: Optional[str]) -> Optional[str]:
    if not value:
        return None
    try:
        dt = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return value
    delta = datetime.now(timezone.utc) - dt
    seconds = int(delta.total_seconds())
    if seconds < 60:
        return f"{seconds}s"
    if seconds < 3600:
        return f"{seconds // 60}m"
    if seconds < 86400:
        return f"{seconds // 3600}h"
    return f"{seconds // 86400}d"


def run_subprocess(command: List[str], timeout: int = 1200, cwd: Path = REPO_ROOT) -> Dict:
    started = time.time()
    try:
        result = subprocess.run(
            command,
            cwd=str(cwd),
            text=True,
            capture_output=True,
            timeout=timeout,
            check=False,
        )
    except FileNotFoundError as exc:
        return {
            "ok": False,
            "exit_code": 127,
            "stdout": "",
            "stderr": str(exc),
            "output": f"Executable not found: {exc}",
            "duration_seconds": round(time.time() - started, 2),
        }
    except subprocess.TimeoutExpired:
        return {
            "ok": False,
            "exit_code": 124,
            "stdout": "",
            "stderr": "",
            "output": f"Command timed out after {timeout}s.",
            "duration_seconds": round(time.time() - started, 2),
        }

    stdout = (result.stdout or "").rstrip()
    stderr = (result.stderr or "").rstrip()
    output = "\n\n".join([part for part in [stdout, stderr] if part]).strip()

    return {
        "ok": result.returncode == 0,
        "exit_code": result.returncode,
        "stdout": stdout,
        "stderr": stderr,
        "output": output,
        "duration_seconds": round(time.time() - started, 2),
    }


def kubectl(args: List[str], timeout: int = 120) -> Dict:
    return run_subprocess(["kubectl", *args], timeout=timeout)


def kubectl_json(args: List[str], timeout: int = 120) -> Tuple[Optional[dict], Optional[str]]:
    res = kubectl(args + ["-o", "json"], timeout=timeout)
    if not res["ok"]:
        return None, res["output"] or f"kubectl failed ({res['exit_code']})"
    try:
        return json.loads(res["stdout"] or "{}"), None
    except json.JSONDecodeError as exc:
        return None, f"invalid kubectl json output: {exc}"


def resolve_seed(custom_seed: str, selected_seed_ids: List[str]) -> Tuple[str, str]:
    custom_seed = (custom_seed or "").strip()
    if custom_seed:
        return custom_seed, "custom"

    selected = [seed for seed in SPECIAL_SEEDS if seed["id"] in set(selected_seed_ids or [])]
    if not selected:
        return "", "random"

    if len(selected) > 1 or any(seed["id"] == "zenith" for seed in selected):
        return "get fixed boi", "multi-special->zenith"

    return selected[0]["seed"], f"special:{selected[0]['id']}"


def sanitize_choice(value: str, allowed: set, default: str) -> str:
    if value in allowed:
        return value
    return default


def build_extra_create_args(world_evil: str, extra_create_args: str) -> str:
    chunks: List[str] = []
    if world_evil in {"corruption", "crimson"}:
        chunks.append(f"-worldevil {world_evil}")

    extra_create_args = (extra_create_args or "").strip()
    if extra_create_args:
        chunks.append(extra_create_args)

    return " ".join(chunks)


def build_world_command(payload: Dict) -> Tuple[List[str], Dict]:
    world_name = str(payload.get("world_name", "test.wld")).strip() or "test.wld"
    if not world_name.endswith(".wld"):
        world_name += ".wld"

    world_size = sanitize_choice(str(payload.get("world_size", "medium")).lower(), {"small", "medium", "large"}, "medium")
    difficulty = sanitize_choice(
        str(payload.get("difficulty", "classic")).lower(),
        {"classic", "expert", "master", "journey"},
        "classic",
    )
    world_evil = sanitize_choice(str(payload.get("world_evil", "random")).lower(), {"random", "corruption", "crimson"}, "random")

    try:
        max_players = int(payload.get("max_players", 8))
    except (TypeError, ValueError):
        max_players = 8
    max_players = max(1, min(255, max_players))

    try:
        server_port = int(payload.get("server_port", 7777))
    except (TypeError, ValueError):
        server_port = 7777
    server_port = max(1, min(65535, server_port))

    selected_seed_ids = payload.get("special_seed_ids", [])
    if not isinstance(selected_seed_ids, list):
        selected_seed_ids = []

    seed, seed_mode = resolve_seed(str(payload.get("seed", "")), selected_seed_ids)
    extra_args = build_extra_create_args(world_evil, str(payload.get("extra_create_args", "")))

    if os.name == "nt":
        script_path = REPO_ROOT / "scripts" / "upload-world.ps1"
        command = [
            "powershell",
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            str(script_path),
            "-WorldName",
            world_name,
            "-WorldSize",
            world_size,
            "-MaxPlayers",
            str(max_players),
            "-Difficulty",
            difficulty,
            "-ServerPort",
            str(server_port),
        ]
        if seed:
            command.extend(["-Seed", seed])
        if extra_args:
            command.extend(["-ExtraCreateArgs", extra_args])
    else:
        script_path = REPO_ROOT / "scripts" / "upload-world.sh"
        command = [
            "bash",
            str(script_path),
            "--world-name",
            world_name,
            "--world-size",
            world_size,
            "--max-players",
            str(max_players),
            "--difficulty",
            difficulty,
            "--server-port",
            str(server_port),
        ]
        if seed:
            command.extend(["--seed", seed])
        if extra_args:
            command.extend(["--extra-create-args", extra_args])

    meta = {
        "world_name": world_name,
        "world_size": world_size,
        "difficulty": difficulty,
        "world_evil": world_evil,
        "max_players": max_players,
        "server_port": server_port,
        "resolved_seed": seed,
        "seed_mode": seed_mode,
        "extra_create_args": extra_args,
    }

    return command, meta


def get_terraria_pods(namespace: str, app_label: str) -> List[Dict]:
    data, err = kubectl_json(["-n", namespace, "get", "pods", "-l", f"app={app_label}"])
    if err or not data:
        return []
    return data.get("items", []) or []


def first_running_pod_name(namespace: str, app_label: str) -> Optional[str]:
    pods = get_terraria_pods(namespace, app_label)
    for item in pods:
        if item.get("status", {}).get("phase") == "Running":
            return item.get("metadata", {}).get("name")
    if pods:
        return pods[0].get("metadata", {}).get("name")
    return None


def list_worlds(namespace: str, app_label: str) -> List[str]:
    pod_name = first_running_pod_name(namespace, app_label)
    if not pod_name:
        manager_data, _ = kubectl_json(["-n", namespace, "get", "pod", "world-manager"])
        if manager_data:
            pod_name = "world-manager"
    if not pod_name:
        return []

    command = [
        "-n",
        namespace,
        "exec",
        pod_name,
        "--",
        "sh",
        "-lc",
        "ls -1 /config/*.wld 2>/dev/null | sed 's#.*/##' | sort",
    ]
    res = kubectl(command, timeout=60)
    if not res["ok"]:
        return []
    return [line.strip() for line in (res["stdout"] or "").splitlines() if line.strip()]


def get_prometheus_urls() -> List[str]:
    raw = os.environ.get("PROMETHEUS_URLS", "")
    if not raw.strip():
        return DEFAULT_PROMETHEUS_URLS
    urls = [entry.strip().rstrip("/") for entry in raw.split(",") if entry.strip()]
    return urls or DEFAULT_PROMETHEUS_URLS


def query_prometheus_scalar(query: str) -> Optional[float]:
    for base_url in get_prometheus_urls():
        try:
            url = f"{base_url}/api/v1/query?query={quote(query, safe='')}"
            req = Request(url, method="GET")
            with urlopen(req, timeout=3) as response:
                payload = json.loads(response.read().decode("utf-8"))
            if payload.get("status") != "success":
                continue
            result = payload.get("data", {}).get("result", [])
            if not result:
                return 0.0
            value = result[0].get("value", [None, None])[1]
            return float(value)
        except Exception:
            continue
    return None


def scrape_metric_snapshot() -> Dict:
    def pick(query: str) -> Optional[float]:
        return query_prometheus_scalar(query)

    return {
        "source_up": pick("max(terraria_exporter_source_up)"),
        "world_parser_up": pick("max(terraria_world_parser_up)"),
        "players_online": pick("max(terraria_players_online)"),
        "players_max": pick("max(terraria_players_max)"),
        "hardmode": pick("max(terraria_world_hardmode)"),
        "blood_moon": pick("max(terraria_world_blood_moon)"),
        "eclipse": pick("max(terraria_world_eclipse)"),
        "world_time": pick("max(terraria_world_time)"),
        "chests_total": pick("max(terraria_world_chests_total)"),
        "houses_total": pick("max(terraria_world_houses_total)"),
        "housed_npcs_total": pick("max(terraria_world_housed_npcs_total)"),
    }


def build_management_snapshot(namespace: str, deployment: str, service: str, app_label: str) -> Dict:
    snapshot: Dict = {
        "ok": True,
        "timestamp": now_rfc3339(),
        "namespace": namespace,
        "deployment_name": deployment,
        "service_name": service,
        "issues": [],
    }

    deployment_data, deployment_err = kubectl_json(["-n", namespace, "get", "deployment", deployment])
    if deployment_err:
        snapshot["issues"].append(f"deployment: {deployment_err}")
        snapshot["ok"] = False
        snapshot["deployment"] = None
    else:
        spec = deployment_data.get("spec", {})
        status = deployment_data.get("status", {})
        containers = (spec.get("template", {}).get("spec", {}).get("containers", []) or [])
        env_vars = {}
        image = ""
        if containers:
            first = containers[0]
            image = first.get("image", "")
            for env in first.get("env", []) or []:
                name = env.get("name")
                if name:
                    env_vars[name] = env.get("value", "")
        snapshot["deployment"] = {
            "replicas_desired": spec.get("replicas", 0),
            "replicas_ready": status.get("readyReplicas", 0),
            "replicas_available": status.get("availableReplicas", 0),
            "observed_generation": status.get("observedGeneration"),
            "image": image,
            "world": env_vars.get("world", ""),
            "worldpath": env_vars.get("worldpath", ""),
        }

    service_data, service_err = kubectl_json(["-n", namespace, "get", "service", service])
    if service_err:
        snapshot["issues"].append(f"service: {service_err}")
        snapshot["service"] = None
    else:
        ports = service_data.get("spec", {}).get("ports", []) or []
        port_map = {port.get("name"): port for port in ports}
        snapshot["service"] = {
            "cluster_ip": service_data.get("spec", {}).get("clusterIP"),
            "type": service_data.get("spec", {}).get("type"),
            "node_port_terraria": (port_map.get("terraria") or {}).get("nodePort"),
            "node_port_api": (port_map.get("terraria-api") or {}).get("nodePort"),
            "port_terraria": (port_map.get("terraria") or {}).get("port"),
            "port_api": (port_map.get("terraria-api") or {}).get("port"),
        }

    endpoints_data, endpoints_err = kubectl_json(["-n", namespace, "get", "endpoints", service])
    if endpoints_err:
        snapshot["issues"].append(f"endpoints: {endpoints_err}")
        snapshot["endpoints"] = {"ready": 0}
    else:
        subsets = endpoints_data.get("subsets", []) or []
        ready_addresses = sum(len(subset.get("addresses", []) or []) for subset in subsets)
        snapshot["endpoints"] = {"ready": ready_addresses}

    pods = get_terraria_pods(namespace, app_label)
    pod_rows = []
    for item in pods:
        status = item.get("status", {})
        metadata = item.get("metadata", {})
        statuses = status.get("containerStatuses", []) or []
        ready = sum(1 for entry in statuses if entry.get("ready"))
        total = len(statuses)
        restarts = sum(entry.get("restartCount", 0) for entry in statuses)
        pod_rows.append(
            {
                "name": metadata.get("name"),
                "phase": status.get("phase"),
                "ready": f"{ready}/{total}" if total else "0/0",
                "restarts": restarts,
                "age": parse_kube_time(metadata.get("creationTimestamp")),
                "pod_ip": status.get("podIP"),
                "node": status.get("nodeName"),
            }
        )
    snapshot["pods"] = pod_rows

    worlds = list_worlds(namespace, app_label)
    snapshot["worlds"] = worlds
    active_world = ""
    if snapshot.get("deployment"):
        active_world = snapshot["deployment"].get("world", "")
    snapshot["active_world_exists"] = bool(active_world and active_world in worlds)

    logs = kubectl(["-n", namespace, "logs", f"deploy/{deployment}", "--tail=120"], timeout=90)
    snapshot["logs"] = {
        "ok": logs["ok"],
        "tail": logs["output"] if logs["output"] else "(no logs)",
    }

    snapshot["metrics"] = scrape_metric_snapshot()
    return snapshot


def run_server_action(namespace: str, deployment: str, action: str, payload: Dict) -> Dict:
    action = (action or "").strip().lower()
    commands: List[List[str]] = []

    if action == "start":
        commands.append(["-n", namespace, "scale", f"deployment/{deployment}", "--replicas=1"])
    elif action == "stop":
        commands.append(["-n", namespace, "scale", f"deployment/{deployment}", "--replicas=0"])
    elif action == "restart":
        commands.append(["-n", namespace, "rollout", "restart", f"deployment/{deployment}"])
    elif action == "set_world":
        world_name = str(payload.get("world_name", "")).strip()
        if not world_name:
            return {"ok": False, "error": "world_name is required for set_world"}
        if not world_name.endswith(".wld"):
            world_name += ".wld"
        commands.append(
            [
                "-n",
                namespace,
                "set",
                "env",
                f"deployment/{deployment}",
                f"world={world_name}",
                "worldpath=/config",
            ]
        )
        if str(payload.get("restart", "true")).lower() in {"1", "true", "yes", "on"}:
            commands.append(["-n", namespace, "rollout", "restart", f"deployment/{deployment}"])
    else:
        return {"ok": False, "error": f"unsupported action: {action}"}

    outputs = []
    for command in commands:
        res = kubectl(command, timeout=120)
        outputs.append({"command": ["kubectl", *command], **res})
        if not res["ok"]:
            return {"ok": False, "action": action, "results": outputs}
    return {"ok": True, "action": action, "results": outputs}


class WorldCreatorHandler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        self.namespace = os.environ.get("WORLD_UI_NAMESPACE", DEFAULT_TERRARIA_NAMESPACE)
        self.deployment = os.environ.get("WORLD_UI_DEPLOYMENT", DEFAULT_TERRARIA_DEPLOYMENT)
        self.service = os.environ.get("WORLD_UI_SERVICE", DEFAULT_TERRARIA_SERVICE)
        self.app_label = os.environ.get("WORLD_UI_APP_LABEL", DEFAULT_TERRARIA_APP_LABEL)
        super().__init__(*args, directory=str(STATIC_DIR), **kwargs)

    def log_message(self, fmt: str, *args) -> None:
        print(f"[world-ui] {self.address_string()} - {fmt % args}")

    def send_json(self, status_code: int, payload: dict) -> None:
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status_code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def parse_json_body(self) -> Tuple[Optional[dict], Optional[str]]:
        content_length = int(self.headers.get("Content-Length", "0"))
        if content_length <= 0:
            return None, "Empty body"
        raw = self.rfile.read(content_length)
        try:
            return json.loads(raw.decode("utf-8")), None
        except json.JSONDecodeError:
            return None, "Invalid JSON payload"

    def do_GET(self):
        parsed = urlparse(self.path)
        if parsed.path == "/api/health":
            return self.send_json(
                200,
                {
                    "ok": True,
                    "repo_root": str(REPO_ROOT),
                    "static_dir": str(STATIC_DIR),
                    "platform": os.name,
                    "namespace": self.namespace,
                    "deployment": self.deployment,
                    "service": self.service,
                },
            )

        if parsed.path == "/api/special-seeds":
            return self.send_json(200, {"seeds": SPECIAL_SEEDS})

        if parsed.path == "/api/worlds":
            worlds = list_worlds(self.namespace, self.app_label)
            return self.send_json(200, {"ok": True, "worlds": worlds})

        if parsed.path == "/api/management":
            payload = build_management_snapshot(self.namespace, self.deployment, self.service, self.app_label)
            return self.send_json(200, payload)

        if parsed.path.startswith("/api/"):
            return self.send_json(404, {"ok": False, "error": "Endpoint not found"})

        return super().do_GET()

    def do_POST(self):
        parsed = urlparse(self.path)

        if parsed.path == "/api/create-world":
            payload, err = self.parse_json_body()
            if err:
                return self.send_json(400, {"ok": False, "error": err})

            command, meta = build_world_command(payload or {})
            result = run_subprocess(command, timeout=3600)
            response = {
                "ok": result["ok"],
                "command": command,
                **meta,
                **result,
            }
            return self.send_json(200 if result["ok"] else 500, response)

        if parsed.path == "/api/server-action":
            payload, err = self.parse_json_body()
            if err:
                return self.send_json(400, {"ok": False, "error": err})
            result = run_server_action(
                namespace=self.namespace,
                deployment=self.deployment,
                action=str((payload or {}).get("action", "")).strip(),
                payload=payload or {},
            )
            return self.send_json(200 if result.get("ok") else 500, result)

        return self.send_json(404, {"ok": False, "error": "Endpoint not found"})


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Terraria world creation and server management UI backend")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", default=8787, type=int)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    server = ThreadingHTTPServer((args.host, args.port), WorldCreatorHandler)
    print(f"[world-ui] Serving on http://{args.host}:{args.port}")
    print(f"[world-ui] Repo root: {REPO_ROOT}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
