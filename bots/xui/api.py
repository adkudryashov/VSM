# api.py
import aiohttp
import asyncio
import json
import html as html_lib
from common.format import collapse
from datetime import datetime, timedelta, timezone

from common import datepicker as dp
from xui.database import get_all_panels

def bytes_to_gb(bytes_value):
    return bytes_value / (1024 ** 3)

def get_msk_time(ts):
    """Конвертирует timestamp в datetime по Московскому времени (UTC+3)"""
    tz_msk = timezone(timedelta(hours=3))
    return datetime.fromtimestamp(ts, tz=tz_msk)

def clean_base_url(url):
    url = url.strip()
    if url.endswith("/"):
        url = url[:-1]
    if url.endswith("/panel"):
        url = url[:-6]
    return url

async def _safe_request(session, method, url, headers, default):
    """Выполняет запрос и возвращает obj из ответа, либо default при любой ошибке/не-200 статусе."""
    try:
        async with session.request(method, url, headers=headers) as resp:
            if resp.status == 200:
                return (await resp.json()).get("obj", default)
    except Exception:
        pass
    return default

async def fetch_panel_data(name, config):
    base_url = clean_base_url(config["base_url"])
    headers = {"Authorization": f"Bearer {config['token']}"}
    timeout = aiohttp.ClientTimeout(total=5.0)

    try:
        async with aiohttp.ClientSession(timeout=timeout) as session:
            # Три запроса выполняются параллельно вместо последовательного ожидания каждого
            status_data, onlines_obj, inbounds_obj = await asyncio.gather(
                _safe_request(session, "GET", f"{base_url}/panel/api/server/status", headers, {}),
                _safe_request(session, "POST", f"{base_url}/panel/api/clients/onlines", headers, []),
                _safe_request(session, "GET", f"{base_url}/panel/api/inbounds/list", headers, []),
            )

            if not inbounds_obj and not onlines_obj and not status_data:
                return {
                    "name": name, "online": False, "online_count": -1,
                    "cpu": 0, "traffic_gb": 0, "uptime_sec": 0, "onlines": []
                }

            cpu = status_data.get("cpu", 0)
            panel_uptime = status_data.get("uptime", 0)
            sys_uptime = status_data.get("sys", {}).get("uptime", status_data.get("systemUptime", 0))
            sort_uptime_sec = int(sys_uptime) if sys_uptime else (int(panel_uptime) if panel_uptime else 0)

            unique_users_traffic = {}
            for inbound in inbounds_obj:
                for c_stat in inbound.get("clientStats", []):
                    email = c_stat.get("email")
                    if email:
                        current_bytes = c_stat.get("up", 0) + c_stat.get("down", 0)
                        unique_users_traffic[email] = max(unique_users_traffic.get(email, 0), current_bytes)

            total_bytes = sum(unique_users_traffic.values())
            total_traffic_gb = bytes_to_gb(total_bytes)
            online_count = len(onlines_obj)

            return {
                "name": name, "online": True, "online_count": online_count,
                "cpu": cpu, "traffic_gb": total_traffic_gb, "uptime_sec": sort_uptime_sec,
                "onlines": onlines_obj
            }
    except Exception:
        return {
            "name": name, "online": False, "online_count": -1,
            "cpu": 0, "traffic_gb": 0, "uptime_sec": 0, "onlines": []
        }

async def get_all_servers_status_parts():
    """
    Строит (rich_html, fallback_text) для Rich Message (Bot API 10.1): таблица со статусом панелей +
    сворачиваемый список клиентов онлайн под каждой панелью.
    """
    current_panels = await get_all_panels()
    tasks = [fetch_panel_data(name, cfg) for name, cfg in current_panels.items()]
    results = await asyncio.gather(*tasks)

    sorted_results = sorted(results, key=lambda x: (x["online_count"], x["uptime_sec"]), reverse=True)
    today = datetime.now().date()

    def format_expiry_cell(panel_name):
        date_str = current_panels.get(panel_name, {}).get("expiry_date")
        if not date_str:
            return "—"
        try:
            expiry_date = datetime.strptime(date_str, '%Y-%m-%d').date()
            days_left = (expiry_date - today).days
            if days_left <= 0:   icon = "🔴"
            elif days_left <= 3: icon = "🟠"
            elif days_left <= 7: icon = "🟡"
            else:                icon = "🟢"
            # Формат берём из datepicker, а не своим strftime: иначе таблица
            # снова разойдётся с экранами ввода, как было до этой правки.
            return f"{icon} {dp.to_display(expiry_date)} ({days_left}д)"
        except ValueError:
            return "—"

    # Заголовка здесь БОЛЬШЕ НЕТ — его ставит вызывающий.
    #
    # Прежде эта функция открывалась своим <h2>, и вторая половина сводки —
    # статус telemt — тоже. Два равновесных заголовка подряд читаются как два
    # несвязанных отчёта, а не как одна сводка. Теперь обе части отдают только
    # содержимое, а шапку выбирает тот, кто их складывает.
    parts = []
    plain = []
    parts.append("<table><tr><th>Панель</th><th>CPU</th><th>Онлайн</th><th>Трафик</th><th>VPS до</th></tr>")
    for r in sorted_results:
        name = html_lib.escape(r["name"])
        expiry_cell = format_expiry_cell(r["name"])
        if r["online"]:
            parts.append(
                f"<tr><td>🟢 {name}</td><td>{r['cpu']:.1f}%</td>"
                f"<td>{r['online_count']}</td><td>{r['traffic_gb']:.1f} GB</td>"
                f"<td>{expiry_cell}</td></tr>"
            )
            plain.append(
                f"🟢 <b>{name}</b> · CPU {r['cpu']:.1f}% · онлайн {r['online_count']} "
                f"· {r['traffic_gb']:.1f} GB · до {expiry_cell}"
            )
        else:
            parts.append(f"<tr><td>🔴 {name}</td><td>—</td><td>—</td><td>—</td><td>{expiry_cell}</td></tr>")
            plain.append(f"🔴 <b>{name}</b> · не отвечает · до {expiry_cell}")
    parts.append("</table>")

    for r in sorted_results:
        if r["online"] and r["onlines"]:
            panel_name = html_lib.escape(r["name"])
            names_html = " | ".join(html_lib.escape(email) for email in r["onlines"])
            parts.append(
                f"<details open><summary>Клиенты онлайн, {panel_name} ({len(r['onlines'])})</summary>"
                f"<p>{names_html}</p></details>"
            )
            # В запасном пути список клиентов сворачивается: у панели на два
            # десятка человек он занимает экран целиком, а нужен по требованию.
            plain.append(collapse(names_html.replace(" | ", "\n"),
                                  f"👥 Клиенты онлайн, {panel_name} ({len(r['onlines'])})"))

    return "".join(parts), "\n".join(plain)


async def get_all_servers_status_rich():
    """Только HTML — для мест, где запасной текст не нужен."""
    rich, _ = await get_all_servers_status_parts()
    return rich

async def get_detailed_panel_report(name, config):
    base_url = clean_base_url(config["base_url"])
    headers = {"Authorization": f"Bearer {config['token']}"}
    timeout = aiohttp.ClientTimeout(total=5.0)

    try:
        async with aiohttp.ClientSession(timeout=timeout) as session:
            async with session.get(f"{base_url}/panel/api/inbounds/list", headers=headers) as r_inb, \
                     session.post(f"{base_url}/panel/api/clients/onlines", headers=headers) as r_onl, \
                     session.post(f"{base_url}/panel/api/clients/lastOnline", headers=headers) as r_lst:

                if r_inb.status == 200:
                    try:
                        inbounds_obj = (await r_inb.json()).get("obj", [])
                        online_emails = (await r_onl.json()).get("obj", []) if r_onl.status == 200 else []
                        last_seen_map = (await r_lst.json()).get("obj", {}) if r_lst.status == 200 else {}
                    except Exception:
                        return "<p>❌ Ошибка: панель вернула неверный формат JSON.</p>"

                    report_title = f"<h2>Панель: {html_lib.escape(name)}</h2>"

                    unique_clients = {}
                    for inbound in inbounds_obj:
                        clients_raw = inbound.get("settings", "")
                        if isinstance(clients_raw, str) and clients_raw:
                            try:
                                clients_raw = json.loads(clients_raw).get("clients", [])
                            except Exception:
                                clients_raw = []
                        elif not isinstance(clients_raw, list):
                            clients_raw = []

                        client_limits = {c.get("email"): c for c in clients_raw if c.get("email")}

                        for c_stat in inbound.get("clientStats", []):
                            email = c_stat.get("email")
                            if not email:
                                continue

                            current_bytes = c_stat.get("up", 0) + c_stat.get("down", 0)

                            if email not in unique_clients:
                                unique_clients[email] = {
                                    "max_bytes": current_bytes, "total": 0, "expiryTime": 0, "enable": True, "last_seen": 0
                                }
                            else:
                                unique_clients[email]["max_bytes"] = max(unique_clients[email]["max_bytes"], current_bytes)
                        
                            limit_info = client_limits.get(email, {})
                            total_bytes = limit_info.get("totalGB", c_stat.get("total", 0))
                            expiry_ts = limit_info.get("expiryTime", c_stat.get("expiryTime", 0))
                            
                            if total_bytes > 0:
                                unique_clients[email]["total"] = total_bytes
                            if expiry_ts > 0:
                                unique_clients[email]["expiryTime"] = expiry_ts
                                
                            if not c_stat.get("enable", True) or not limit_info.get("enable", True):
                                unique_clients[email]["enable"] = False

                    if not unique_clients:
                        return report_title + "<p>Пользователи не найдены.</p>"

                    client_list = []
                    for email, data in unique_clients.items():
                        last_ts = last_seen_map.get(email, 0)
                        if last_ts > 9999999999:
                            last_ts /= 1000
                        data["last_seen"] = last_ts

                        if email in online_emails:
                            data["status_priority"] = 0
                        elif not data["enable"]:
                            data["status_priority"] = 2
                        else:
                            data["status_priority"] = 1
                        
                        client_list.append((email, data))

                    client_list.sort(key=lambda x: (x[1]["status_priority"], -x[1]["last_seen"]))

                    rows = []
                    for email, data in client_list:
                        if data["status_priority"] == 0:
                            status_dot = "🟢"
                        elif data["status_priority"] == 2:
                            status_dot = "⚪"
                        else:
                            status_dot = "🔴"

                        used_gb = bytes_to_gb(data["max_bytes"])
                        if data["total"] > 0:
                            # total всегда приходит в байтах (и из settings.clients, и из clientStats)
                            limit_gb = bytes_to_gb(data["total"])
                            traffic_str = f"{used_gb:.2f} / {limit_gb:.1f} GB"
                        else:
                            traffic_str = f"{used_gb:.2f} GB / ∞"

                        exp_ts = data["expiryTime"]
                        if exp_ts > 0:
                            if exp_ts > 9999999999:
                                exp_ts /= 1000
                            expiry_str = get_msk_time(exp_ts).strftime('%d.%m.%y')
                        else:
                            expiry_str = "безлимит"

                        if data["status_priority"] == 0:
                            last_str = "сейчас"
                        elif data["last_seen"] > 0:
                            last_str = get_msk_time(data["last_seen"]).strftime('%d.%m %H:%M')
                        else:
                            last_str = "нет данных"

                        rows.append(
                            f"<tr><td>{status_dot} {html_lib.escape(email)}</td>"
                            f"<td>{html_lib.escape(traffic_str)}</td>"
                            f"<td>{html_lib.escape(expiry_str)}</td>"
                            f"<td>{html_lib.escape(last_str)}</td></tr>"
                        )

                    table = (
                        "<table><tr><th>Клиент</th><th>Трафик</th><th>До</th><th>Активность</th></tr>"
                        + "".join(rows) + "</table>"
                    )
                    return report_title + table
                else:
                    return f"<p>❌ Ошибка панели: статус {r_inb.status}</p>"
    except Exception as e:
        return f"<p>❌ Критическая ошибка при генерации отчета: {html_lib.escape(str(e))}</p>"
