#!/usr/bin/env python3
import argparse
import json
import os
import subprocess
import time
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse
from typing import Dict, List, Tuple

REPO_ROOT = Path(__file__).resolve().parents[1]
STATIC_DIR = Path(__file__).resolve().parent / "static"

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


def run_command(command: List[str]) -> Dict:
    started = time.time()
    try:
        result = subprocess.run(
            command,
            cwd=REPO_ROOT,
            text=True,
            capture_output=True,
            timeout=3600,
            check=False,
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
            "output": "World creation command timed out after 3600s.",
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




