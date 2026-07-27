from telemt.utils.helpers import send_long_message
from aiogram import Router, types
from aiogram.filters import Command
from telemt.api.client import TelemtAPIClient

router = Router()
api = TelemtAPIClient()

@router.message(Command("writers"))
async def cmd_writers(message: types.Message):
    try:
        resp = await api.me_writers()
        data = resp.get("data")
        if not data or not data.get("middle_proxy_enabled"):
            await send_long_message(message, "ME‑пул не активен.")
            return
        summary = data["summary"]
        writers = data.get("writers", [])
        text = [
            f"📝 <b>ME‑писатели</b>\n"
            f"Покрытие: {summary['coverage_pct']:.1f}% ({summary['alive_writers']}/{summary['required_writers']})\n",
        ]
        for w in writers[:20]:
            if w.get("draining") or w.get("degraded"):
                state = "🔴"
            else:
                state = "🟢"
            rtt = f"rtt={w['rtt_ema_ms']:.0f}ms" if w.get("rtt_ema_ms") else ""
            text.append(
                f"  {state} {w['endpoint']} DC={w.get('dc','?')} "
                f"gen={w['generation']} clients={w['bound_clients']} {rtt}"
            )
        await send_long_message(message, "\n".join(text))
    except Exception as e:
        await send_long_message(message, f"❌ Ошибка: {e}")

@router.message(Command("dcs"))
async def cmd_dcs(message: types.Message):
    try:
        resp = await api.dcs()
        data = resp.get("data")
        if not data or not data.get("middle_proxy_enabled"):
            await send_long_message(message, "Информация о DC недоступна.")
            return
        dcs = data.get("dcs", [])
        if not dcs:
            await send_long_message(message, "DC не найдены.")
            return
        lines = ["🌍 <b>Датацентры:</b>"]
        for dc in dcs:
            dc_id = dc["dc"]
            cov = dc["coverage_pct"]
            rtt = dc.get("rtt_ms")
            rtt_str = f"{rtt:.0f}ms" if rtt else "—"

            if cov >= 100:
                cov_icon = "🟢"
            elif cov >= 80:
                cov_icon = "🟡"
            else:
                cov_icon = "🔴"

            lines.append(
                f"{cov_icon} DC{dc_id}: покрытие {cov:.0f}% ({dc['alive_writers']}/{dc['required_writers']}) "
                f"RTT={rtt_str} загрузка={dc['load']}"
            )
        await send_long_message(message, "\n".join(lines), )
    except Exception as e:
        await send_long_message(message, f"❌ Ошибка: {e}")

@router.message(Command("upstreams"))
async def cmd_upstreams(message: types.Message):
    try:
        resp = await api.upstreams()
        data = resp.get("data")
        if not data or not data.get("enabled"):
            await send_long_message(message, "Информация об upstream недоступна.")
            return
        summary = data.get("summary")
        ups = data.get("upstreams", [])
        text = ["🔄 <b>Upstream серверы:</b>"]
        if summary:
            text.append(
                f"Всего: {summary['configured_total']}, "
                f"здоровых: {summary['healthy_total']}, "
                f"больных: {summary['unhealthy_total']}"
            )
        for u in ups:
            healthy = "✅" if u["healthy"] else "❌"
            text.append(
                f"  {healthy} {u['route_kind']} {u['address']} "
                f"вес={u['weight']} сбои={u['fails']}"
            )
        await send_long_message(message, "\n".join(text))
    except Exception as e:
        await send_long_message(message, f"❌ Ошибка: {e}")

@router.message(Command("runtime"))
async def cmd_runtime(message: types.Message):
    try:
        gates = await api.runtime_gates()
        init = await api.runtime_initialization()
        g = gates["data"]
        i = init["data"]
        text = (
            "⚙️ <b>Runtime</b>\n"
            f"Приём соединений: {g['accepting_new_connections']}\n"
            f"ME готов: {g['me_runtime_ready']}\n"
            f"Статус инициализации: {i['status']} (этап: {i['current_stage']}, {i['progress_pct']:.0f}%)\n"
            f"Транспорт: {i['transport_mode']}"
        )
        await send_long_message(message, text, )
    except Exception as e:
        await send_long_message(message, f"❌ Ошибка: {e}")
