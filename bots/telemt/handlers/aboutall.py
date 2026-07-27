from telemt.utils.helpers import send_long_message
import asyncio
from aiogram import Router, types
from aiogram.filters import Command
from telemt.api.client import TelemtAPIClient

router = Router()
api = TelemtAPIClient()

@router.message(Command("aboutall"))
async def cmd_aboutall(message: types.Message):
    try:
        # Параллельно собираем все нужные данные
        health, gates, init, dcs_resp, writers_resp, upstreams_resp = await asyncio.gather(
            api.health(),
            api.runtime_gates(),
            api.runtime_initialization(),
            api.dcs(),
            api.me_writers(),
            api.upstreams(),
            return_exceptions=True
        )

        lines = ["📋 <b>Базовые статусы сервиса</b>\n"]

        # Health
        if isinstance(health, dict) and health.get("data"):
            status = health["data"]["status"]
            ro = health["data"]["read_only"]
            icon = "✅" if status == "ok" else "❌"
            lines.append(f"🏥 API: {icon} {status} (read-only: {'🔒' if ro else '🔓'})")
        else:
            lines.append("🏥 API: ❌ недоступен")

        # Runtime
        if isinstance(gates, dict) and isinstance(init, dict):
            g = gates.get("data", {})
            i = init.get("data", {})
            accept = g.get("accepting_new_connections", False)
            me_ready = g.get("me_runtime_ready", False)
            status_text = i.get("status", "?")
            stage = i.get("current_stage", "?")
            progress = i.get("progress_pct", 0)
            transport = i.get("transport_mode", "?")
            lines.append(
                f"⚙️ Runtime: прием={'✅' if accept else '❌'} "
                f"ME={'✅' if me_ready else '❌'} "
                f"статус={status_text} ({stage}, {progress:.0f}%) "
                f"транспорт={transport}"
            )
        else:
            lines.append("⚙️ Runtime: ❌ данные недоступны")

        # DC coverage (кратко)
        if isinstance(dcs_resp, dict) and dcs_resp.get("data", {}).get("middle_proxy_enabled"):
            dcs = dcs_resp["data"].get("dcs", [])
            dc_parts = []
            for dc in dcs:
                dc_id = dc["dc"]
                cov = dc["coverage_pct"]
                alive = dc["alive_writers"]
                req = dc["required_writers"]
                icon = "🟢" if cov >= 100 else ("🟡" if cov >= 80 else "🔴")
                dc_parts.append(f"{icon} DC{dc_id}: {alive}/{req}")
            lines.append("🌍 DC покрытие: " + " | ".join(dc_parts))
        else:
            lines.append("🌍 DC покрытие: ❌ нет данных")

        # ME writers (кратко)
        if isinstance(writers_resp, dict) and writers_resp.get("data", {}).get("summary"):
            w_summary = writers_resp["data"]["summary"]
            cov_pct = w_summary["coverage_pct"]
            alive = w_summary["alive_writers"]
            req = w_summary["required_writers"]
            lines.append(f"✍️ ME писатели: {cov_pct:.0f}% ({alive}/{req})")
        else:
            lines.append("✍️ ME писатели: ❌ нет данных")

        # Upstreams
        if isinstance(upstreams_resp, dict) and upstreams_resp.get("data", {}).get("summary"):
            us_summary = upstreams_resp["data"]["summary"]
            total = us_summary["configured_total"]
            healthy = us_summary["healthy_total"]
            unhealthy = us_summary["unhealthy_total"]
            lines.append(f"🔄 Upstream: всего {total}, здоровых {healthy}, больных {unhealthy}")
        else:
            lines.append("🔄 Upstream: ❌ нет данных")

        await send_long_message(message, "\n".join(lines), )
    except Exception as e:
        await send_long_message(message, f"❌ Ошибка: {e}")
