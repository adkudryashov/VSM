from telemt.utils.helpers import send_long_message, send_rich_or_fallback
import asyncio
import html
import httpx
from aiogram import Router, types
from aiogram.filters import Command
from config import settings
from telemt.api.client import TelemtAPIClient

router = Router()
api = TelemtAPIClient()
PROMETHEUS_URL = settings.PROMETHEUS_METRICS_URL


def parse_metric(text: str, name: str) -> float | None:
    for line in text.splitlines():
        if line.startswith('#'):
            continue
        if line.startswith(name + " ") or line.startswith(name + "{"):
            try:
                parts = line.rsplit(" ", 1)
                if len(parts) == 2:
                    return float(parts[1])
            except ValueError:
                pass
    return None


def fmt_pct(value, total):
    """Возвращает строку вида "value (pct%)"."""
    if total and total > 0:
        return f"{int(value)} ({value/total*100:.1f}%)"
    return str(int(value))


@router.message(Command("metrics"))
async def cmd_metrics(message: types.Message):
    try:
        # Параллельный сбор всех данных
        prom, health, runtime_gates, runtime_init, dcs_resp, writers_resp, upstreams_resp = await asyncio.gather(
            asyncio.to_thread(lambda: httpx.get(PROMETHEUS_URL, timeout=5).text),
            api.health(),
            api.runtime_gates(),
            api.runtime_initialization(),
            api.dcs(),
            api.me_writers(),
            api.upstreams(),
        )

        conn_total = parse_metric(prom, "telemt_connections_total") or 0
        conn_bad = parse_metric(prom, "telemt_connections_bad_total") or 0
        hs_timeout = parse_metric(prom, "telemt_handshake_timeouts_total") or 0
        active_writers = parse_metric(prom, "telemt_me_writers_active_current")
        warm_writers = parse_metric(prom, "telemt_me_writers_warm_current")
        k_sent = parse_metric(prom, "telemt_me_keepalive_sent_total") or 0
        k_fail = parse_metric(prom, "telemt_me_keepalive_failed_total") or 0
        rec_att = parse_metric(prom, "telemt_me_reconnect_attempts_total") or 0
        rec_suc = parse_metric(prom, "telemt_me_reconnect_success_total") or 0
        kdf = parse_metric(prom, "telemt_me_kdf_drift_total") or 0
        reject = parse_metric(prom, "telemt_me_handshake_reject_total") or 0
        qfull = parse_metric(prom, "telemt_me_route_drop_queue_full_total") or 0
        desync = parse_metric(prom, "telemt_desync_total") or 0
        swaps = parse_metric(prom, "telemt_pool_swap_total") or 0
        drain = parse_metric(prom, "telemt_pool_drain_active") or 0
        up_att = parse_metric(prom, "telemt_upstream_connect_attempt_total") or 0
        up_fail = parse_metric(prom, "telemt_upstream_connect_fail_total") or 0
        up_hard = parse_metric(prom, "telemt_upstream_connect_failfast_hard_error_total") or 0

        output = ["📊 Показатели сервиса Telemt\n"]

        health_data = health.get("data", {})
        gates_data = runtime_gates.get("data", {})
        init_data = runtime_init.get("data", {})

        api_status = health_data.get("status", "?")
        ro = health_data.get("read_only", False)
        accept = gates_data.get("accepting_new_connections", False)
        me_ready = gates_data.get("me_runtime_ready", False)
        runtime_status = init_data.get("status", "?")
        progress = init_data.get("progress_pct", 0)

        output.append(
            f"🏥 API: {'✅ ok' if api_status == 'ok' else '❌ ' + api_status} ({'🔒 RO' if ro else '🔓 RW'}) | "
            f"⚙️ Runtime: {'✅ ready' if accept and me_ready else '❌ ' + runtime_status} ({progress:.0f}%)"
        )

        if conn_total:
            output.append(
                f"📡 Соединений: {int(conn_total)} | "
                f"Bad: {fmt_pct(conn_bad, conn_total)} | "
                f"Timeout: {fmt_pct(hs_timeout, conn_total)}"
            )
        output.append("")

        anomalies = []
        if qfull > 0: anomalies.append(f"• Очередь полна (Queue full): {int(qfull)} ⚠️")
        if desync > 0: anomalies.append(f"• Рассинхронизация (Desync): {int(desync)} ⚠️")
        if kdf > 0: anomalies.append(f"• Дрифт ключей (KDF drift): {int(kdf)} ⚠️")
        if reject > 0: anomalies.append(f"• Отклонено хэндшейков (Reject): {int(reject)} ⚠️")
        if k_fail > 0: anomalies.append(f"• Сбои keepalive: {int(k_fail)} ⚠️")

        if anomalies:
            output.append("🚨 Обнаружены аномалии в работе:")
            output.extend(anomalies)
            output.append("")

        if dcs_resp.get("data", {}).get("middle_proxy_enabled"):
            dcs = dcs_resp["data"].get("dcs", [])
            if dcs:
                total_dcs = len(dcs)
                unhealthy_dcs = [dc for dc in dcs if dc.get("coverage_pct", 0) < 100]

                output.append("🌍 Статус инфраструктуры DC:")
                if not unhealthy_dcs:
                    output.append(f"🟢 Все {total_dcs} датацентров в целевом состоянии (100%)")
                else:
                    output.append(f"🟡 Просадка покрытия в {len(unhealthy_dcs)}/{total_dcs} DC:")
                    for dc in unhealthy_dcs:
                        output.append(f"  • 🔴 DC-{dc['dc']}: покрытие {dc['coverage_pct']:.0f}% ({dc['alive_writers']}/{dc['required_writers']})")
                output.append("")

        w_cov = writers_resp.get("data", {}).get("summary", {})
        cov_pct = w_cov.get("coverage_pct", 0) if w_cov else 0

        output.append("⚙️ Внутренние процессы:")
        output.append(
            f"• ME‑писатели: Active {int(active_writers) if active_writers else '?'} / "
            f"Warm {int(warm_writers) if warm_writers else '?'} (Покрытие: {cov_pct:.0f}%)"
        )
        output.append(f"• Reconnect ME: успешно {int(rec_suc)} / попыток {int(rec_att)}")
        if swaps:
            output.append(f"• Пул памяти: Swaps {int(swaps)} | Drain {int(drain)}")
        output.append("")

        us_data = upstreams_resp.get("data", {})
        output.append("🌐 Маршрутизация (Upstreams):")
        if us_data.get("summary"):
            summary = us_data["summary"]
            output.append(
                f"• Серверы: всего {summary['configured_total']} | "
                f"🟢 {summary['healthy_total']} здоровых | "
                f"🔴 {summary['unhealthy_total']} больных"
            )
        output.append(
            f"• Запросы: всего {int(up_att)} | "
            f"неудач {int(up_fail)}" + (f" (hard {int(up_hard)})" if up_hard else "")
        )

        fallback_text = "\n".join(output)

        # --- Rich Message: те же данные в виде таблиц ---
        rich = ["<h2>Показатели сервиса Telemt</h2>"]

        rich.append("<table><tr><th>Показатель</th><th>Значение</th></tr>")
        rich.append(
            f"<tr><td>API</td><td>{'✅ ok' if api_status == 'ok' else '❌ ' + html.escape(str(api_status))} "
            f"({'🔒 RO' if ro else '🔓 RW'})</td></tr>"
        )
        rich.append(
            f"<tr><td>Runtime</td><td>{'✅ ready' if accept and me_ready else '❌ ' + html.escape(str(runtime_status))} "
            f"({progress:.0f}%)</td></tr>"
        )
        if conn_total:
            rich.append(
                f"<tr><td>Соединений</td><td>{int(conn_total)} | Bad: {fmt_pct(conn_bad, conn_total)} | "
                f"Timeout: {fmt_pct(hs_timeout, conn_total)}</td></tr>"
            )
        rich.append("</table>")

        if anomalies:
            rich.append("<h3>🚨 Обнаружены аномалии в работе</h3><ul>")
            for a in anomalies:
                rich.append(f"<li>{html.escape(a.lstrip('• ').rstrip(' ⚠️'))}</li>")
            rich.append("</ul>")

        if dcs_resp.get("data", {}).get("middle_proxy_enabled"):
            dcs = dcs_resp["data"].get("dcs", [])
            if dcs:
                total_dcs = len(dcs)
                unhealthy_dcs = [dc for dc in dcs if dc.get("coverage_pct", 0) < 100]
                rich.append("<h3>🌍 Статус инфраструктуры DC</h3>")
                if not unhealthy_dcs:
                    rich.append(f"<p>🟢 Все {total_dcs} датацентров в целевом состоянии (100%)</p>")
                else:
                    rich.append(
                        f"<p>🟡 Просадка покрытия в {len(unhealthy_dcs)}/{total_dcs} DC</p>"
                        f"<table><tr><th>DC</th><th>Покрытие</th></tr>"
                    )
                    for dc in unhealthy_dcs:
                        rich.append(
                            f"<tr><td>DC-{dc['dc']}</td><td>🔴 {dc['coverage_pct']:.0f}% "
                            f"({dc['alive_writers']}/{dc['required_writers']})</td></tr>"
                        )
                    rich.append("</table>")

        rich.append("<h3>⚙️ Внутренние процессы</h3><table>")
        rich.append(
            f"<tr><td>ME‑писатели</td><td>Active {int(active_writers) if active_writers else '?'} / "
            f"Warm {int(warm_writers) if warm_writers else '?'} (Покрытие {cov_pct:.0f}%)</td></tr>"
        )
        rich.append(f"<tr><td>Reconnect ME</td><td>успешно {int(rec_suc)} / попыток {int(rec_att)}</td></tr>")
        if swaps:
            rich.append(f"<tr><td>Пул памяти</td><td>Swaps {int(swaps)} | Drain {int(drain)}</td></tr>")
        rich.append("</table>")

        rich.append("<h3>🌐 Маршрутизация (Upstreams)</h3><table>")
        if us_data.get("summary"):
            summary = us_data["summary"]
            rich.append(
                f"<tr><td>Серверы</td><td>всего {summary['configured_total']} | "
                f"🟢 {summary['healthy_total']} здоровых | 🔴 {summary['unhealthy_total']} больных</td></tr>"
            )
        rich.append(
            f"<tr><td>Запросы</td><td>всего {int(up_att)} | неудач {int(up_fail)}"
            + (f" (hard {int(up_hard)})" if up_hard else "") + "</td></tr>"
        )
        rich.append("</table>")

        await send_rich_or_fallback(message, "".join(rich), fallback_text)
    except Exception as e:
        await send_long_message(message, f"❌ Ошибка получения метрик: {e}", )
