#!/usr/bin/env python3
import argparse
import json
import os
import subprocess
import shutil
import time
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse, parse_qs
from typing import Any, Dict, List, Tuple

REPO_ROOT = Path(__file__).resolve().parents[1]
STATIC_DIR = Path(__file__).resolve().parent / "static"

DEFAULT_NAMESPACE = os.environ.get("WORLD_UI_NAMESPACE", "terraria")
DEFAULT_DEPLOYMENT = os.environ.get("WORLD_UI_DEPLOYMENT", "terraria-server")
DEFAULT_PVC_NAME = os.environ.get("WORLD_UI_PVC_NAME", "terraria-config")

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

    namespace = str(payload.get("namespace", DEFAULT_NAMESPACE)).strip() or DEFAULT_NAMESPACE
    deployment = str(payload.get("deployment", DEFAULT_DEPLOYMENT)).strip() or DEFAULT_DEPLOYMENT
    pvc_name = str(payload.get("pvc_name", DEFAULT_PVC_NAME)).strip() or DEFAULT_PVC_NAME

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
            "-Namespace",
            namespace,
            "-Deployment",
            deployment,
            "-PvcName",
            pvc_name,
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
            "--namespace",
            namespace,
            "--deployment",
            deployment,
            "--pvc-name",
            pvc_name,
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
        "namespace": namespace,
        "deployment": deployment,
        "pvc_name": pvc_name,
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


def run_command(command: List[str], timeout_seconds: int = 3600, stdin_text: str = "") -> Dict:
    started = time.time()
    try:
        result = subprocess.run(
            command,
            cwd=REPO_ROOT,
            text=True,
            capture_output=True,
            timeout=timeout_seconds,
            check=False,
            input=stdin_text,
        )
    except FileNotFoundError as exc:
        return {
            "ok": False,
            "exit_code": 127,
            "output": f"Executable not found: {exc}",
            "duration_seconds": round(time.time() - started, 2),
        }
    except subprocess.TimeoutExpired:
        return {
            "ok": False,
            "exit_code": 124,
            "output": f"Command timed out after {timeout_seconds}s.",
            "duration_seconds": round(time.time() - started, 2),
        }

    output_parts = []
    if result.stdout:
        output_parts.append(result.stdout.rstrip())
    if result.stderr:
        output_parts.append(result.stderr.rstrip())

    return {
        "ok": result.returncode == 0,
        "exit_code": result.returncode,
        "output": "\n\n".join(output_parts).strip(),
        "duration_seconds": round(time.time() - started, 2),
    }


def list_worlds_from_pvc(namespace: str, pvc_name: str, manager_image: str = "ghcr.io/beardedio/terraria:latest") -> Dict[str, Any]:
    if shutil.which("kubectl") is None:
        return {
            "ok": False,
            "error": "kubectl nao encontrado no ambiente do world-ui",
            "namespace": namespace,
            "pvc_name": pvc_name,
            "worlds": [],
        }

    pod_name = f"world-ui-ls-{int(time.time() * 1000)}"
    manifest = f"""
apiVersion: v1
kind: Pod
metadata:
  name: {pod_name}
  namespace: {namespace}
spec:
  restartPolicy: Never
  containers:
    - name: world-manager
      image: {manager_image}
      command: ["sh", "-c", "sleep 240"]
      volumeMounts:
        - name: terraria-config
          mountPath: /config
  volumes:
    - name: terraria-config
      persistentVolumeClaim:
        claimName: {pvc_name}
""".strip()

    try:
        apply_result = run_command(["kubectl", "apply", "-f", "-"], timeout_seconds=120, stdin_text=manifest)
        if not apply_result["ok"]:
            return {
                "ok": False,
                "error": "falha ao criar pod auxiliar para listar mundos",
                "details": apply_result["output"],
                "namespace": namespace,
                "pvc_name": pvc_name,
                "worlds": [],
            }

        wait_result = run_command(
            [
                "kubectl",
                "wait",
                "--for=condition=Ready",
                f"pod/{pod_name}",
                "-n",
                namespace,
                "--timeout=180s",
            ],
            timeout_seconds=210,
        )
        if not wait_result["ok"]:
            return {
                "ok": False,
                "error": "pod auxiliar nao ficou pronto para leitura do PVC",
                "details": wait_result["output"],
                "namespace": namespace,
                "pvc_name": pvc_name,
                "worlds": [],
            }

        list_script = "for f in /config/*.wld; do [ -f \"$f\" ] || continue; b=$(basename \"$f\"); s=$(wc -c < \"$f\" 2>/dev/null || echo 0); m=$(date -r \"$f\" +%s 2>/dev/null || echo 0); printf \"%s|%s|%s\\n\" \"$b\" \"$s\" \"$m\"; done"
        list_result = run_command(
            ["kubectl", "exec", "-n", namespace, pod_name, "--", "sh", "-lc", list_script],
            timeout_seconds=90,
        )
        if not list_result["ok"]:
            return {
                "ok": False,
                "error": "falha ao listar arquivos .wld no PVC",
                "details": list_result["output"],
                "namespace": namespace,
                "pvc_name": pvc_name,
                "worlds": [],
            }

        worlds: List[Dict[str, Any]] = []
        for line in (list_result["output"] or "").splitlines():
            parts = line.strip().split("|")
            if len(parts) != 3:
                continue

            name = parts[0].strip()
            try:
                size_bytes = int(parts[1])
            except ValueError:
                size_bytes = 0

            try:
                modified_epoch = int(parts[2])
            except ValueError:
                modified_epoch = 0

            if not name:
                continue

            worlds.append(
                {
                    "name": name,
                    "size_bytes": size_bytes,
                    "modified_epoch": modified_epoch,
                }
            )

        worlds.sort(key=lambda item: item["name"].lower())

        return {
            "ok": True,
            "namespace": namespace,
            "pvc_name": pvc_name,
            "pod_name": pod_name,
            "worlds": worlds,
        }
    finally:
        cleanup_result = run_command(
            [
                "kubectl",
                "delete",
                "pod",
                pod_name,
                "-n",
                namespace,
                "--ignore-not-found",
                "--wait=false",
            ],
            timeout_seconds=30,
        )
        if not cleanup_result["ok"]:
            print(f"[world-ui] warning: failed to cleanup helper pod {pod_name}: {cleanup_result['output']}")
class WorldCreatorHandler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
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
                },
            )

        if parsed.path == "/api/special-seeds":
            return self.send_json(200, {"seeds": SPECIAL_SEEDS})

        if parsed.path == "/api/worlds":
            query = parse_qs(parsed.query)
            namespace = (query.get("namespace", [DEFAULT_NAMESPACE])[0] or DEFAULT_NAMESPACE).strip()
            pvc_name = (query.get("pvc_name", [DEFAULT_PVC_NAME])[0] or DEFAULT_PVC_NAME).strip()
            manager_image = (query.get("manager_image", ["ghcr.io/beardedio/terraria:latest"])[0] or "ghcr.io/beardedio/terraria:latest").strip()

            worlds_result = list_worlds_from_pvc(namespace=namespace, pvc_name=pvc_name, manager_image=manager_image)
            status = 200 if worlds_result.get("ok") else 500
            return self.send_json(status, worlds_result)

        if parsed.path.startswith("/api/"):
            return self.send_json(404, {"ok": False, "error": "Endpoint not found"})

        return super().do_GET()
    def do_POST(self):
        parsed = urlparse(self.path)
        if parsed.path != "/api/create-world":
            return self.send_json(404, {"ok": False, "error": "Endpoint not found"})

        content_length = int(self.headers.get("Content-Length", "0"))
        if content_length <= 0:
            return self.send_json(400, {"ok": False, "error": "Empty body"})

        raw = self.rfile.read(content_length)
        try:
            payload = json.loads(raw.decode("utf-8"))
        except json.JSONDecodeError:
            return self.send_json(400, {"ok": False, "error": "Invalid JSON payload"})

        command, meta = build_world_command(payload)
        result = run_command(command)

        response = {
            "ok": result["ok"],
            "command": command,
            **meta,
            **result,
        }

        return self.send_json(200 if result["ok"] else 500, response)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Terraria world creation UI backend")
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



