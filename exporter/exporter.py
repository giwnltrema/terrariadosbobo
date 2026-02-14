import json
import os
import time
from typing import Any, Dict, List, Optional

import requests
from prometheus_client import Gauge, start_http_server

API_BASE = os.getenv("TERRARIA_API_URL", "").rstrip("/")
API_TOKEN = os.getenv("TERRARIA_API_TOKEN", "")
SCRAPE_INTERVAL = int(os.getenv("SCRAPE_INTERVAL", "15"))
EXPORTER_PORT = int(os.getenv("EXPORTER_PORT", "9150"))

source_up = Gauge("terraria_exporter_source_up", "1 se API de gameplay respondeu")
players_online = Gauge("terraria_players_online", "Quantidade de jogadores online")
players_max = Gauge("terraria_players_max", "Capacidade maxima de jogadores")
world_daytime = Gauge("terraria_world_daytime", "1 se dia, 0 se noite")
world_blood_moon = Gauge("terraria_world_blood_moon", "1 se blood moon ativa")
world_eclipse = Gauge("terraria_world_eclipse", "1 se eclipse ativa")
world_hardmode = Gauge("terraria_world_hardmode", "1 se hardmode")
world_time = Gauge("terraria_world_time", "Tempo do mundo")
world_chests = Gauge("terraria_world_chests_total", "Quantidade de baus no mundo")
world_houses = Gauge("terraria_world_houses_total", "Quantidade de casas conhecidas no mundo")
world_housed_npcs = Gauge("terraria_world_housed_npcs_total", "Quantidade de NPCs com casa")
world_housed_npc = Gauge("terraria_world_housed_npc", "NPC alojado", ["npc"])
player_health = Gauge("terraria_player_health", "Vida do jogador", ["player"])
player_mana = Gauge("terraria_player_mana", "Mana do jogador", ["player"])
player_deaths = Gauge("terraria_player_deaths_total", "Mortes do jogador", ["player"])
player_items = Gauge("terraria_player_item_count", "Quantidade de item por jogador", ["player", "item"])
monster_count = Gauge("terraria_monster_active", "Monstros ativos por tipo", ["monster"])


def _as_bool(value: Any) -> int:
    if isinstance(value, bool):
        return 1 if value else 0
    if isinstance(value, (int, float)):
        return 1 if value else 0
    if isinstance(value, str):
        lowered = value.strip().lower()
        return 1 if lowered in {"1", "true", "yes", "on", "day", "hardmode"} else 0
    return 0


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


def scrape_once() -> None:
    source_up.set(0)
    players_online.set(0)
    players_max.set(0)
    world_daytime.set(0)
    world_blood_moon.set(0)
    world_eclipse.set(0)
    world_hardmode.set(0)
    world_time.set(0)
    world_chests.set(0)
    world_houses.set(0)
    world_housed_npcs.set(0)
    world_housed_npc.clear()
    player_health.clear()
    player_mana.clear()
    player_deaths.clear()
    player_items.clear()
    monster_count.clear()

    status = _request(["/status", "/v2/server/status", "/v3/server/status", "/v2/status"])
    players = _request(["/players", "/v2/players/list", "/v3/players/list", "/v2/players"])
    world = _request(["/world", "/v2/world/status", "/v3/world/status", "/v2/world"])
    monsters = _request(["/monsters", "/v2/monsters/list", "/v3/monsters/list", "/v2/npcs/list"])
    chests = _request(["/v2/world/chests", "/v3/world/chests", "/chests"])
    houses = _request(["/v2/world/houses", "/v3/world/houses", "/houses"])
    housed_npcs = _request(["/v2/world/housednpcs", "/v3/world/housednpcs", "/v2/npcs/housed", "/housednpcs"])

    if all(v is None for v in [status, players, world, monsters, chests, houses, housed_npcs]):
        return

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

    online = _find_first(merged, ["onlineplayers", "playersonline", "playercount", "online"])
    maxp = _find_first(merged, ["maxplayers", "slots", "playerlimit"])

    if isinstance(online, (int, float)):
        players_online.set(float(online))
    if isinstance(maxp, (int, float)):
        players_max.set(float(maxp))

    daytime = _find_first(merged, ["daytime", "isday", "day"])
    blood = _find_first(merged, ["bloodmoon", "isbloodmoon"])
    eclipse = _find_first(merged, ["eclipse", "issolareclipse"])
    hardmode = _find_first(merged, ["hardmode", "ishardmode"])
    time_value = _find_first(merged, ["time", "worldtime", "timeofday"])

    if daytime is not None:
        world_daytime.set(_as_bool(daytime))
    if blood is not None:
        world_blood_moon.set(_as_bool(blood))
    if eclipse is not None:
        world_eclipse.set(_as_bool(eclipse))
    if hardmode is not None:
        world_hardmode.set(_as_bool(hardmode))
    if isinstance(time_value, (int, float)):
        world_time.set(float(time_value))

    parsed_players = _extract_dict_list(players, ["players", "onlinePlayers", "playerList", "data"])
    if parsed_players:
        players_online.set(float(len(parsed_players)))

    for player in parsed_players:
        name = str(player.get("name") or player.get("playerName") or player.get("username") or "unknown")
        life = player.get("health", player.get("life", player.get("hp", 0)))
        mana = player.get("mana", player.get("mp", 0))
        deaths = player.get("deaths", player.get("deathCount", 0))

        if isinstance(life, (int, float)):
            player_health.labels(player=name).set(float(life))
        if isinstance(mana, (int, float)):
            player_mana.labels(player=name).set(float(mana))
        if isinstance(deaths, (int, float)):
            player_deaths.labels(player=name).set(float(deaths))

        inventory = player.get("inventory", [])
        if isinstance(inventory, list):
            for item in inventory:
                if not isinstance(item, dict):
                    continue
                item_name = str(item.get("name") or item.get("itemName") or "unknown")
                amount = item.get("stack", item.get("amount", 0))
                if isinstance(amount, (int, float)):
                    player_items.labels(player=name, item=item_name).set(float(amount))

    parsed_monsters = _extract_dict_list(monsters, ["monsters", "npcs", "activeMonsters", "activeNPCs", "data"])
    bucket: Dict[str, int] = {}
    for monster in parsed_monsters:
        mname = str(monster.get("name") or monster.get("npcName") or monster.get("type") or "unknown")
        bucket[mname] = bucket.get(mname, 0) + 1
    for mname, count in bucket.items():
        monster_count.labels(monster=mname).set(float(count))

    parsed_chests = _extract_dict_list(chests, ["chests", "data", "list"])
    if parsed_chests:
        world_chests.set(float(len(parsed_chests)))
    else:
        chests_count = _find_first(chests if chests is not None else {}, ["chestcount", "chests", "count"])
        if isinstance(chests_count, (int, float)):
            world_chests.set(float(chests_count))

    parsed_houses = _extract_dict_list(houses, ["houses", "data", "list"])
    if parsed_houses:
        world_houses.set(float(len(parsed_houses)))
    else:
        houses_count = _find_first(houses if houses is not None else {}, ["housecount", "houses", "count"])
        if isinstance(houses_count, (int, float)):
            world_houses.set(float(houses_count))

    parsed_housed_npcs = _extract_dict_list(housed_npcs, ["npcs", "housednpcs", "data", "list"])
    if parsed_housed_npcs:
        world_housed_npcs.set(float(len(parsed_housed_npcs)))
        for npc in parsed_housed_npcs:
            nname = str(npc.get("name") or npc.get("npcName") or npc.get("type") or "unknown")
            world_housed_npc.labels(npc=nname).set(1)
    else:
        housed_count = _find_first(housed_npcs if housed_npcs is not None else {}, ["housednpccount", "npcs", "count"])
        if isinstance(housed_count, (int, float)):
            world_housed_npcs.set(float(housed_count))


def main() -> None:
    start_http_server(EXPORTER_PORT)
    while True:
        try:
            scrape_once()
        except Exception:
            source_up.set(0)
        time.sleep(SCRAPE_INTERVAL)


if __name__ == "__main__":
    main()
