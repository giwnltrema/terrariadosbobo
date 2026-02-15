import json
import os
import re
import time
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

import requests
from prometheus_client import Gauge, start_http_server

try:
    from lihzahrd import World
except Exception:
    World = None

API_BASE = os.getenv("TERRARIA_API_URL", "").rstrip("/")
API_TOKEN = os.getenv("TERRARIA_API_TOKEN", "")
SCRAPE_INTERVAL = int(os.getenv("SCRAPE_INTERVAL", "15"))
EXPORTER_PORT = int(os.getenv("EXPORTER_PORT", "9150"))
WORLD_FILE_PATH = os.getenv("WORLD_FILE_PATH", "")
SERVER_CONFIG_PATH = os.getenv("SERVER_CONFIG_PATH", "/config/serverconfig.txt")
TSHOCK_CONFIG_PATH = os.getenv("TSHOCK_CONFIG_PATH", "/config/config.json")
CHEST_ITEM_SERIES_LIMIT = int(os.getenv("CHEST_ITEM_SERIES_LIMIT", "500"))

K8S_NAMESPACE = os.getenv("K8S_NAMESPACE", "terraria")
K8S_TERRARIA_LABEL_SELECTOR = os.getenv("K8S_TERRARIA_LABEL_SELECTOR", "app=terraria-server")
K8S_TERRARIA_CONTAINER = os.getenv("K8S_TERRARIA_CONTAINER", "terraria")
K8S_LOG_TAIL_LINES = int(os.getenv("K8S_LOG_TAIL_LINES", "2000"))
ENABLE_LOG_PLAYER_TRACKER = os.getenv("ENABLE_LOG_PLAYER_TRACKER", "true").strip().lower() in {"1", "true", "yes", "on"}
try:
    DEFAULT_MAX_PLAYERS = float(os.getenv("DEFAULT_MAX_PLAYERS", "8"))
except ValueError:
    DEFAULT_MAX_PLAYERS = 8.0

source_up = Gauge("terraria_exporter_source_up", "1 se API de gameplay respondeu")
world_parser_up = Gauge("terraria_world_parser_up", "1 se parser do arquivo .wld respondeu")
world_runtime_up = Gauge("terraria_world_runtime_up", "1 se runtime do mundo veio de API/log em tempo real")
log_tracker_up = Gauge("terraria_log_tracker_up", "1 se fallback de logs Kubernetes funcionou")
world_parser_unsupported = Gauge(
    "terraria_world_parser_unsupported_version",
    "1 se versao .wld atual nao e suportada pelo parser instalado",
)
log_connection_attempts_window = Gauge(
    "terraria_log_connection_attempts_window",
    "Quantidade de conexoes detectadas nas ultimas linhas de log analisadas",
)
log_world_saves_window = Gauge(
    "terraria_log_world_saves_window",
    "Quantidade de ciclos de save detectados nas ultimas linhas de log analisadas",
)

players_online = Gauge("terraria_players_online", "Quantidade de jogadores online (API ou fallback logs)")
players_online_api = Gauge("terraria_players_online_api", "Quantidade de jogadores online via API")
players_online_log = Gauge("terraria_players_online_log", "Quantidade de jogadores online via fallback de logs")
players_max = Gauge("terraria_players_max", "Capacidade maxima de jogadores")

world_daytime = Gauge("terraria_world_daytime", "1 se dia, 0 se noite")
world_blood_moon = Gauge("terraria_world_blood_moon", "1 se blood moon ativa")
world_eclipse = Gauge("terraria_world_eclipse", "1 se eclipse ativa")
world_hardmode = Gauge("terraria_world_hardmode", "1 se hardmode")
world_time = Gauge("terraria_world_time", "Tempo do mundo (runtime)")
world_time_runtime = Gauge("terraria_world_time_runtime", "Tempo do mundo (runtime)")

world_snapshot_age_seconds = Gauge("terraria_world_snapshot_age_seconds", "Idade do arquivo .wld em segundos")
world_snapshot_mtime = Gauge("terraria_world_snapshot_mtime_seconds", "mtime do arquivo .wld (epoch seconds)")

world_chests = Gauge("terraria_world_chests_total", "Quantidade de baus no mundo (snapshot)")
world_houses = Gauge("terraria_world_houses_total", "Quantidade de casas conhecidas no mundo (snapshot)")
world_housed_npcs = Gauge("terraria_world_housed_npcs_total", "Quantidade de NPCs com casa (snapshot)")
world_housed_npc = Gauge("terraria_world_housed_npc", "NPC alojado (snapshot)", ["npc"])

chest_item_count = Gauge("terraria_chest_item_count", "Quantidade de item por bau", ["chest", "item"])
chest_item_count_by_item = Gauge("terraria_chest_item_count_by_item", "Quantidade total de item em todos os baus", ["item"])

player_health = Gauge("terraria_player_health", "Vida do jogador", ["player"])
player_mana = Gauge("terraria_player_mana", "Mana do jogador", ["player"])
player_deaths = Gauge("terraria_player_deaths_total", "Mortes do jogador", ["player"])
player_items = Gauge("terraria_player_item_count", "Quantidade de item por jogador", ["player", "item"])
monster_count = Gauge("terraria_monster_active", "Monstros ativos por tipo", ["monster"])

ANSI_PATTERN = re.compile(r"\x1b\[[0-9;]*m")
JOIN_PATTERNS = [
    re.compile(r"(?P<player>[A-Za-z0-9_ ]{2,32}) has joined", re.IGNORECASE),
    re.compile(r"(?P<player>[A-Za-z0-9_ ]{2,32}) joined the game", re.IGNORECASE),
]
LEAVE_PATTERNS = [
    re.compile(r"(?P<player>[A-Za-z0-9_ ]{2,32}) has left", re.IGNORECASE),
    re.compile(r"(?P<player>[A-Za-z0-9_ ]{2,32}) left the game", re.IGNORECASE),
]
CONNECTION_PATTERN = re.compile(r"(?:\d{1,3}\.){3}\d{1,3}:\d+\s+is connecting", re.IGNORECASE)
WORLD_SAVE_PATTERN = re.compile(r"backing up world file", re.IGNORECASE)


def _as_bool(value: Any) -> int:
    if isinstance(value, bool):
        return 1 if value else 0
    if isinstance(value, (int, float)):
        return 1 if value else 0
    if isinstance(value, str):
        lowered = value.strip().lower()
        return 1 if lowered in {"1", "true", "yes", "on", "day", "hardmode"} else 0
    return 0


def _normalize_name(value: Any) -> str:
    raw = str(value or "unknown")
    if raw == "unknown":
        return raw
    return raw.replace("_", " ").strip().title()


def _find_first(data: Any, keys: List[str]) -> Optional[Any]:
    if isinstance(data, dict):
        for key, value in data.items():
            normalized = key.replace("_", "").replace("-", "").lower()
            if normalized in keys:
                return value
        for value in data.values():
            found = _find_first(value, keys)
            if found is not None:
                return found
    if isinstance(data, list):
        for item in data:
            found = _find_first(item, keys)
            if found is not None:
                return found
    return None


def _request(paths: List[str]) -> Optional[Any]:
    if not API_BASE:
        return None

    params = {}
    if API_TOKEN:
        params["token"] = API_TOKEN

    for path in paths:
        url = f"{API_BASE}{path}"
        try:
            response = requests.get(url, params=params, timeout=6)
            if response.status_code != 200:
                continue
            if "application/json" in response.headers.get("content-type", ""):
                return response.json()
            return json.loads(response.text)
        except Exception:
            continue
    return None


def _extract_dict_list(payload: Any, keys: List[str]) -> List[Dict[str, Any]]:
    if isinstance(payload, list):
        return [i for i in payload if isinstance(i, dict)]
    if isinstance(payload, dict):
        for key in keys:
            value = payload.get(key)
            if isinstance(value, list):
                return [i for i in value if isinstance(i, dict)]
    return []


def _chest_items(chest: Dict[str, Any]) -> List[Dict[str, Any]]:
    for key in ["items", "inventory", "contents", "chestItems", "Slots", "slots"]:
        value = chest.get(key)
        if isinstance(value, list):
            return [i for i in value if isinstance(i, dict)]
    return []


def _item_name(item: Dict[str, Any]) -> str:
    return _normalize_name(item.get("name") or item.get("itemName") or item.get("type") or "unknown")


def _item_amount(item: Dict[str, Any]) -> float:
    amount = item.get("stack", item.get("amount", item.get("count", item.get("quantity", 0))))
    if isinstance(amount, (int, float)):
        return float(amount)
    return 0.0


def _safe_float(value: Any) -> Optional[float]:
    if isinstance(value, (int, float)):
        return float(value)
    return None


def _read_max_players_from_config() -> Optional[float]:
    path = Path(SERVER_CONFIG_PATH)
    if not path.exists() or not path.is_file():
        return None
    try:
        for raw in path.read_text(encoding="utf-8", errors="ignore").splitlines():
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            if "=" not in line:
                continue
            key, value = line.split("=", 1)
            if key.strip().lower() == "maxplayers":
                parsed = _safe_float(int(value.strip()))
                if parsed is not None:
                    return parsed
    except Exception:
        return None
    return None


def _read_max_players_from_tshock_config() -> Optional[float]:
    path = Path(TSHOCK_CONFIG_PATH)
    if not path.exists() or not path.is_file():
        return None

    try:
        payload = json.loads(path.read_text(encoding="utf-8", errors="ignore"))
    except Exception:
        return None

    if not isinstance(payload, dict):
        return None

    settings = payload.get("Settings", {})
    if not isinstance(settings, dict):
        return None

    value = settings.get("MaxSlots")
    if isinstance(value, (int, float)):
        return float(value)
    return None


def _reset_metrics() -> None:
    source_up.set(0)
    world_parser_up.set(0)
    world_runtime_up.set(0)
    log_tracker_up.set(0)
    world_parser_unsupported.set(0)
    log_connection_attempts_window.set(0)
    log_world_saves_window.set(0)

    players_online.set(0)
    players_online_api.set(0)
    players_online_log.set(0)
    players_max.set(0)

    world_daytime.set(0)
    world_blood_moon.set(0)
    world_eclipse.set(0)
    world_hardmode.set(0)
    world_time.set(0)
    world_time_runtime.set(0)

    world_snapshot_age_seconds.set(0)
    world_snapshot_mtime.set(0)

    world_chests.set(0)
    world_houses.set(0)
    world_housed_npcs.set(0)
    world_housed_npc.clear()

    chest_item_count.clear()
    chest_item_count_by_item.clear()
    player_health.clear()
    player_mana.clear()
    player_deaths.clear()
    player_items.clear()
    monster_count.clear()


def _sanitize_log_message(msg: str) -> str:
    clean = ANSI_PATTERN.sub("", msg).strip()
    return clean


def _extract_player(regex_list: List[re.Pattern], line: str) -> Optional[str]:
    for pattern in regex_list:
        match = pattern.search(line)
        if not match:
            continue
        candidate = match.group("player").strip(" <>[]()\"'")
        if "]" in candidate:
            candidate = candidate.split("]")[-1].strip()
        if ":" in candidate:
            candidate = candidate.split(":")[-1].strip()
        if candidate:
            return candidate[:32]
    return None


class KubernetesLogTracker:
    def __init__(self) -> None:
        self.token_path = Path("/var/run/secrets/kubernetes.io/serviceaccount/token")
        self.ca_path = Path("/var/run/secrets/kubernetes.io/serviceaccount/ca.crt")
        self.host = os.getenv("KUBERNETES_SERVICE_HOST", "")
        self.port = os.getenv("KUBERNETES_SERVICE_PORT", "443")

    def _enabled(self) -> bool:
        return (
            ENABLE_LOG_PLAYER_TRACKER
            and bool(self.host)
            and self.token_path.exists()
            and self.ca_path.exists()
        )

    def _headers(self) -> Dict[str, str]:
        token = self.token_path.read_text(encoding="utf-8").strip()
        return {"Authorization": f"Bearer {token}"}

    def _request(self, path: str, params: Optional[Dict[str, Any]] = None) -> Optional[Any]:
        if not self._enabled():
            return None

        url = f"https://{self.host}:{self.port}{path}"
        try:
            response = requests.get(
                url,
                params=params,
                headers=self._headers(),
                timeout=6,
                verify=str(self.ca_path),
            )
            if response.status_code != 200:
                return None
            if "application/json" in response.headers.get("content-type", ""):
                return response.json()
            return response.text
        except Exception:
            return None

    def _pick_running_pod(self) -> Optional[str]:
        payload = self._request(
            f"/api/v1/namespaces/{K8S_NAMESPACE}/pods",
            {"labelSelector": K8S_TERRARIA_LABEL_SELECTOR},
        )
        if not isinstance(payload, dict):
            return None

        items = payload.get("items", []) or []
        running: List[Tuple[str, str]] = []
        for item in items:
            if not isinstance(item, dict):
                continue
            phase = item.get("status", {}).get("phase")
            if phase != "Running":
                continue
            name = item.get("metadata", {}).get("name")
            created = item.get("metadata", {}).get("creationTimestamp", "")
            if isinstance(name, str) and name:
                running.append((created, name))

        if not running:
            return None
        running.sort()
        return running[-1][1]

    def _fetch_logs(self, pod_name: str) -> Optional[str]:
        return self._request(
            f"/api/v1/namespaces/{K8S_NAMESPACE}/pods/{pod_name}/log",
            {
                "container": K8S_TERRARIA_CONTAINER,
                "tailLines": str(K8S_LOG_TAIL_LINES),
                "timestamps": "false",
            },
        )

    def parse(self) -> Dict[str, Any]:
        result: Dict[str, Any] = {
            "ok": False,
            "pod": None,
            "players_online": 0,
            "players": [],
            "blood_moon": None,
            "eclipse": None,
            "daytime": None,
            "connection_attempts": 0,
            "world_saves": 0,
        }

        if not self._enabled():
            return result

        pod_name = self._pick_running_pod()
        if not pod_name:
            return result
        result["pod"] = pod_name

        raw_logs = self._fetch_logs(pod_name)
        if not isinstance(raw_logs, str):
            return result

        online: Dict[str, str] = {}
        blood_moon: Optional[int] = None
        eclipse: Optional[int] = None
        daytime: Optional[int] = None
        connection_attempts = 0
        world_saves = 0

        for raw_line in raw_logs.splitlines():
            line = _sanitize_log_message(raw_line)
            if not line:
                continue
            lowered = line.lower()

            if CONNECTION_PATTERN.search(line):
                connection_attempts += 1
            if WORLD_SAVE_PATTERN.search(lowered):
                world_saves += 1

            join_player = _extract_player(JOIN_PATTERNS, line)
            if join_player:
                online[join_player.lower()] = join_player

            leave_player = _extract_player(LEAVE_PATTERNS, line)
            if leave_player:
                online.pop(leave_player.lower(), None)

            if "blood moon is rising" in lowered:
                blood_moon = 1
            elif "blood moon is over" in lowered or "blood moon has ended" in lowered:
                blood_moon = 0

            if "solar eclipse is happening" in lowered or "eclipse has begun" in lowered:
                eclipse = 1
            elif "solar eclipse has ended" in lowered or "eclipse is over" in lowered:
                eclipse = 0

            if "night has fallen" in lowered:
                daytime = 0
            elif "day has dawned" in lowered:
                daytime = 1

        result["ok"] = True
        result["players_online"] = len(online)
        result["players"] = sorted(online.values())
        result["blood_moon"] = blood_moon
        result["eclipse"] = eclipse
        result["daytime"] = daytime
        result["connection_attempts"] = connection_attempts
        result["world_saves"] = world_saves
        return result


def _update_from_api() -> Dict[str, Any]:
    status = _request(["/status", "/v2/server/status", "/v3/server/status", "/v2/status"])
    players = _request(["/players", "/v2/players/list", "/v3/players/list", "/v2/players"])
    world = _request(["/world", "/v2/world/status", "/v3/world/status", "/v2/world"])
    monsters = _request(["/monsters", "/v2/monsters/list", "/v3/monsters/list", "/v2/npcs/list"])
    chests = _request(["/v2/world/chests", "/v3/world/chests", "/chests"])
    houses = _request(["/v2/world/houses", "/v3/world/houses", "/houses"])
    housed_npcs = _request(["/v2/world/housednpcs", "/v3/world/housednpcs", "/v2/npcs/housed", "/housednpcs"])

    response: Dict[str, Any] = {
        "api_up": False,
        "players_online": None,
        "players_max": None,
        "runtime_world_up": False,
    }

    if all(v is None for v in [status, players, world, monsters, chests, houses, housed_npcs]):
        return response

    response["api_up"] = True
    source_up.set(1)

    merged = {
        "status": status if status is not None else {},
        "players": players if players is not None else {},
        "world": world if world is not None else {},
        "monsters": monsters if monsters is not None else {},
        "chests": chests if chests is not None else {},
        "houses": houses if houses is not None else {},
        "housed_npcs": housed_npcs if housed_npcs is not None else {},
    }

    online = _safe_float(_find_first(merged, ["onlineplayers", "playersonline", "playercount", "online"]))
    maxp = _safe_float(_find_first(merged, ["maxplayers", "slots", "playerlimit"]))

    if online is not None:
        players_online_api.set(online)
        players_online.set(online)
        response["players_online"] = online

    if maxp is not None:
        players_max.set(maxp)
        response["players_max"] = maxp

    daytime = _find_first(merged, ["daytime", "isday", "day"])
    blood = _find_first(merged, ["bloodmoon", "isbloodmoon"])
    eclipse = _find_first(merged, ["eclipse", "issolareclipse"])
    hardmode = _find_first(merged, ["hardmode", "ishardmode"])
    time_value = _safe_float(_find_first(merged, ["time", "worldtime", "timeofday"]))

    runtime_points = 0
    if daytime is not None:
        world_daytime.set(_as_bool(daytime))
        runtime_points += 1
    if blood is not None:
        world_blood_moon.set(_as_bool(blood))
        runtime_points += 1
    if eclipse is not None:
        world_eclipse.set(_as_bool(eclipse))
        runtime_points += 1
    if hardmode is not None:
        world_hardmode.set(_as_bool(hardmode))
        runtime_points += 1
    if time_value is not None:
        world_time.set(time_value)
        world_time_runtime.set(time_value)
        runtime_points += 1

    parsed_players = _extract_dict_list(players, ["players", "onlinePlayers", "playerList", "data"])
    if parsed_players:
        online_from_list = float(len(parsed_players))
        players_online_api.set(online_from_list)
        players_online.set(online_from_list)
        response["players_online"] = online_from_list

    for player in parsed_players:
        name = str(player.get("name") or player.get("playerName") or player.get("username") or "unknown")
        life = _safe_float(player.get("health", player.get("life", player.get("hp", 0))))
        mana = _safe_float(player.get("mana", player.get("mp", 0)))
        deaths = _safe_float(player.get("deaths", player.get("deathCount", 0)))

        if life is not None:
            player_health.labels(player=name).set(life)
        if mana is not None:
            player_mana.labels(player=name).set(mana)
        if deaths is not None:
            player_deaths.labels(player=name).set(deaths)

        inventory = player.get("inventory", [])
        if isinstance(inventory, list):
            for item in inventory:
                if not isinstance(item, dict):
                    continue
                item_name = _item_name(item)
                amount = _item_amount(item)
                if amount > 0:
                    player_items.labels(player=name, item=item_name).set(amount)

    parsed_monsters = _extract_dict_list(monsters, ["monsters", "npcs", "activeMonsters", "activeNPCs", "data"])
    bucket: Dict[str, int] = {}
    for monster in parsed_monsters:
        mname = _normalize_name(monster.get("name") or monster.get("npcName") or monster.get("type") or "unknown")
        bucket[mname] = bucket.get(mname, 0) + 1
    for mname, count in bucket.items():
        monster_count.labels(monster=mname).set(float(count))

    parsed_chests = _extract_dict_list(chests, ["chests", "data", "list"])
    if parsed_chests:
        world_chests.set(float(len(parsed_chests)))
        totals: Dict[str, float] = {}
        chest_pairs: List[Tuple[str, str, float]] = []

        for chest in parsed_chests:
            chest_id = str(chest.get("id") or chest.get("index") or chest.get("name") or "unknown")
            for item in _chest_items(chest):
                item_name = _item_name(item)
                amount = _item_amount(item)
                if amount <= 0:
                    continue
                chest_pairs.append((chest_id, item_name, amount))
                totals[item_name] = totals.get(item_name, 0.0) + amount

        chest_pairs.sort(key=lambda x: x[2], reverse=True)
        for chest_id, item_name, amount in chest_pairs[:CHEST_ITEM_SERIES_LIMIT]:
            chest_item_count.labels(chest=chest_id, item=item_name).set(amount)
        for item_name, total in totals.items():
            chest_item_count_by_item.labels(item=item_name).set(total)

    parsed_houses = _extract_dict_list(houses, ["houses", "data", "list"])
    if parsed_houses:
        world_houses.set(float(len(parsed_houses)))

    parsed_housed_npcs = _extract_dict_list(housed_npcs, ["npcs", "housednpcs", "data", "list"])
    if parsed_housed_npcs:
        world_housed_npcs.set(float(len(parsed_housed_npcs)))
        for npc in parsed_housed_npcs:
            nname = _normalize_name(npc.get("name") or npc.get("npcName") or npc.get("type") or "unknown")
            world_housed_npc.labels(npc=nname).set(1)

    if runtime_points > 0:
        world_runtime_up.set(1)
        response["runtime_world_up"] = True

    return response


def _update_from_world_file() -> Dict[str, Any]:
    response: Dict[str, Any] = {"snapshot_up": False}
    if World is None or not WORLD_FILE_PATH:
        return response

    world_file = Path(WORLD_FILE_PATH)
    if not world_file.exists() or not world_file.is_file():
        return response

    try:
        stat = world_file.stat()
        world_snapshot_mtime.set(float(stat.st_mtime))
        world_snapshot_age_seconds.set(max(0.0, time.time() - float(stat.st_mtime)))
    except Exception:
        pass

    try:
        world = World.create_from_file(str(world_file))
    except NotImplementedError:
        world_parser_unsupported.set(1)
        return response
    except Exception:
        return response

    world_parser_up.set(1)
    response["snapshot_up"] = True

    world_hardmode.set(1 if bool(getattr(world, "is_hardmode", False)) else 0)

    chests = list(getattr(world, "chests", []) or [])
    world_chests.set(float(len(chests)))

    item_totals: Dict[str, float] = {}
    chest_pairs: List[Tuple[str, str, float]] = []
    for index, chest in enumerate(chests):
        chest_label = str(index)
        contents = list(getattr(chest, "contents", []) or [])
        for stack in contents:
            if stack is None:
                continue
            quantity = _safe_float(getattr(stack, "quantity", 0))
            if quantity is None or quantity <= 0:
                continue

            item_type = getattr(stack, "type", None)
            item_name = _normalize_name(getattr(item_type, "name", item_type))

            chest_pairs.append((chest_label, item_name, quantity))
            item_totals[item_name] = item_totals.get(item_name, 0.0) + quantity

    chest_pairs.sort(key=lambda x: x[2], reverse=True)
    for chest_label, item_name, quantity in chest_pairs[:CHEST_ITEM_SERIES_LIMIT]:
        chest_item_count.labels(chest=chest_label, item=item_name).set(quantity)

    for item_name, total in item_totals.items():
        chest_item_count_by_item.labels(item=item_name).set(total)

    rooms = list(getattr(world, "rooms", []) or [])
    world_houses.set(float(len(rooms)))

    housed_count = 0
    npcs = list(getattr(world, "npcs", []) or [])
    for npc in npcs:
        if getattr(npc, "home", None) is None:
            continue
        housed_count += 1
        npc_name = str(getattr(npc, "name", "") or _normalize_name(getattr(getattr(npc, "type", None), "name", "unknown")))
        world_housed_npc.labels(npc=npc_name).set(1)

    if housed_count == 0 and rooms:
        for room in rooms:
            room_npc = getattr(room, "npc", None)
            room_npc_name = _normalize_name(getattr(room_npc, "name", room_npc))
            world_housed_npc.labels(npc=room_npc_name).set(1)
        housed_count = len(rooms)

    world_housed_npcs.set(float(housed_count))
    return response


def _apply_log_fallback(tracker: KubernetesLogTracker, api_data: Dict[str, Any]) -> None:
    result = tracker.parse()
    if not result.get("ok"):
        return

    log_tracker_up.set(1)
    log_players = float(result.get("players_online", 0))
    players_online_log.set(log_players)
    log_connection_attempts_window.set(float(result.get("connection_attempts", 0)))
    log_world_saves_window.set(float(result.get("world_saves", 0)))

    if api_data.get("players_online") is None:
        players_online.set(log_players)

    if result.get("blood_moon") is not None and not api_data.get("runtime_world_up"):
        world_blood_moon.set(int(result["blood_moon"]))
        world_runtime_up.set(1)

    if result.get("eclipse") is not None and not api_data.get("runtime_world_up"):
        world_eclipse.set(int(result["eclipse"]))
        world_runtime_up.set(1)

    if result.get("daytime") is not None and not api_data.get("runtime_world_up"):
        world_daytime.set(int(result["daytime"]))
        world_runtime_up.set(1)

    if (
        not api_data.get("runtime_world_up")
        and (result.get("connection_attempts", 0) > 0 or result.get("world_saves", 0) > 0)
    ):
        world_runtime_up.set(1)


def scrape_once(tracker: KubernetesLogTracker) -> None:
    _reset_metrics()

    api_data: Dict[str, Any] = {}
    try:
        api_data = _update_from_api()
    except Exception:
        source_up.set(0)

    try:
        _update_from_world_file()
    except Exception:
        world_parser_up.set(0)

    if (api_data or {}).get("players_max") is None:
        max_from_config = _read_max_players_from_config()
        if max_from_config is None:
            max_from_config = _read_max_players_from_tshock_config()
        if max_from_config is None:
            max_from_config = DEFAULT_MAX_PLAYERS
        players_max.set(max_from_config)

    try:
        _apply_log_fallback(tracker, api_data or {})
    except Exception:
        log_tracker_up.set(0)


def main() -> None:
    tracker = KubernetesLogTracker()
    start_http_server(EXPORTER_PORT)
    while True:
        scrape_once(tracker)
        time.sleep(SCRAPE_INTERVAL)


if __name__ == "__main__":
    main()
