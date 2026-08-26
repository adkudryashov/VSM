from telemt.utils.helpers import send_long_message
import asyncio
from aiogram import Router, types
from aiogram.filters import Command
from telemt.api.client import TelemtAPIClient

router = Router()
api = TelemtAPIClient()

# Один словарь значков на весь ответ.
#
# Прежде здесь соседствовали три азбуки: ✅/❌ у базовых статусов, 🟢/🔴 у
# покрытия DC и ещё раз ✅/❌ у upstream. Глаз перестраивается на каждой
# строке, а разницы в смысле между «✅ API» и «🟢 DC» никакой не было.
#
# Разведено по смыслу, а не по вкусу: кружок — СОСТОЯНИЕ, у которого бывают
# градации; ✅/⚠️/🚨 остаются событиям и тревогам, где градаций нет, и живут
# в сторожевой карточке. Белый кружок — «данных нет»: это не поломка, и
# красный на его месте врал бы.
OK = "🟢"
WARN = "🟡"
BAD = "🔴"
NODATA = "⚪"


def _mark(good: bool) -> str:
    return OK if good else BAD


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
            lines.append(
                f"🏥 API · {_mark(status == 'ok')} {status} · "
                f"{'только чтение' if ro else 'запись разрешена'}"
            )
        else:
            lines.append(f"🏥 API · {NODATA} недоступен")

        # Runtime.
        #
        # Была цепочка «прием=✅ ME=✅ статус=ok (running, 100%) транспорт=tcp» —
        # формат строки журнала, а не отчёта человеку. Плюс «прием» без ё:
        # единственная опечатка на всю переписку ботов.
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
                f"⚙️ Runtime · приём {_mark(accept)} · ME {_mark(me_ready)} · "
                f"{status_text}, {progress:.0f}% ({stage}) · транспорт {transport}"
            )
        else:
            lines.append(f"⚙️ Runtime · {NODATA} данных нет")

        # DC coverage (кратко)
        if isinstance(dcs_resp, dict) and dcs_resp.get("data", {}).get("middle_proxy_enabled"):
            dcs = dcs_resp["data"].get("dcs", [])
            dc_parts = []
            for dc in dcs:
                dc_id = dc["dc"]
                cov = dc["coverage_pct"]
                alive = dc["alive_writers"]
                req = dc["required_writers"]
                icon = OK if cov >= 100 else (WARN if cov >= 80 else BAD)
                dc_parts.append(f"{icon} DC{dc_id} {alive}/{req}")
            lines.append("🌍 Покрытие DC · " + " · ".join(dc_parts))
        else:
            lines.append(f"🌍 Покрытие DC · {NODATA} данных нет")

        # ME writers (кратко)
        if isinstance(writers_resp, dict) and writers_resp.get("data", {}).get("summary"):
            w_summary = writers_resp["data"]["summary"]
            cov_pct = w_summary["coverage_pct"]
            alive = w_summary["alive_writers"]
            req = w_summary["required_writers"]
            icon = OK if cov_pct >= 100 else (WARN if cov_pct >= 80 else BAD)
            lines.append(f"✍️ Писатели ME · {icon} {cov_pct:.0f}% ({alive}/{req})")
        else:
            lines.append(f"✍️ Писатели ME · {NODATA} данных нет")

        # Upstreams
        if isinstance(upstreams_resp, dict) and upstreams_resp.get("data", {}).get("summary"):
            us_summary = upstreams_resp["data"]["summary"]
            total = us_summary["configured_total"]
            healthy = us_summary["healthy_total"]
            unhealthy = us_summary["unhealthy_total"]
            icon = OK if unhealthy == 0 else (WARN if healthy > unhealthy else BAD)
            lines.append(
                f"🔄 Upstream · {icon} здоровых {healthy} из {total}"
                + (f" · больных {unhealthy}" if unhealthy else "")
            )
        else:
            lines.append(f"🔄 Upstream · {NODATA} данных нет")

        await send_long_message(message, "\n".join(lines))
    except Exception as e:
        await send_long_message(message, f"❌ Ошибка: {e}")
