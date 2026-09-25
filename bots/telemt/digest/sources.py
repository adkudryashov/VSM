"""
Откуда сводка берёт числа. Всё локальное: файлы, журнал, базы на этом же
сервере и API движка на петле — наружу не уходит ни одного запроса.

ЛЮБАЯ НЕУДАЧА — «не знаю», а не ошибка. Источники чужие (3x-ui, fail2ban,
MTProxyL, apt), их формат может поменяться; строка сводки тогда пропадёт или
скажет «—», но сводка придёт.
"""

from __future__ import annotations

import glob
import json
import logging
import re
import shutil
import sqlite3
import subprocess
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

from config import settings
from telemt.watchdog import upgrades

XUI_DB = "/etc/x-ui/x-ui.db"
F2B_DB = "/var/lib/fail2ban/fail2ban.sqlite3"
RU_HISTORY = "/opt/mtproxyl/availability/history.jsonl"
BACKUP_DIR = "/var/backups/vsm/config"
BACKUP_TIMER = "/etc/systemd/system/vsm-backup.timer"


def _ro(path: str) -> Optional[sqlite3.Connection]:
    """Только чтение и с ожиданием: базу 3x-ui панель пишет постоянно (WAL)."""
    if not Path(path).exists():
        return None
    return sqlite3.connect(f"file:{path}?mode=ro", uri=True, timeout=5)


def _run(cmd: list, timeout: int = 20) -> str:
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout).stdout
    except Exception as exc:
        logging.info("Сводка: %s не отработал: %s", cmd[0], exc)
        return ""


# ------------------------------------------------------------------ снимок
def boot_id() -> str:
    try:
        return Path("/proc/sys/kernel/random/boot_id").read_text().strip()
    except OSError:
        return ""


def nic_bytes() -> Optional[int]:
    """Принято + отдано на интерфейсе маршрута по умолчанию, с загрузки."""
    try:
        iface = ""
        for line in Path("/proc/net/route").read_text().splitlines()[1:]:
            parts = line.split()
            if len(parts) > 1 and parts[1] == "00000000":
                iface = parts[0]
                break
        for line in Path("/proc/net/dev").read_text().splitlines()[2:]:
            name, _, rest = line.partition(":")
            if name.strip() == iface:
                f = rest.split()
                return int(f[0]) + int(f[8])
    except Exception as exc:
        logging.info("Сводка: трафик интерфейса не прочитан: %s", exc)
    return None


def xui_clients() -> Optional[list]:
    """(email, up+down, лимит, срок в мс) по клиентам 3x-ui; None — панели нет."""
    try:
        con = _ro(XUI_DB)
        if con is None:
            return None
        with con:
            rows = con.execute("select email, up + down, total, expiry_time "
                               "from client_traffics order by email").fetchall()
        return [(str(e), int(b or 0), int(t or 0), int(x or 0)) for e, b, t, x in rows]
    except Exception as exc:
        logging.info("Сводка: база 3x-ui не прочитана: %s", exc)
        return None


def firewall() -> tuple[Optional[int], bool]:
    """(отброшено пакетов политикой INPUT с загрузки, выключен ли фаервол)."""
    out = _run(["iptables", "-L", "INPUT", "-n", "-v", "-x"])
    m = re.search(r"policy (\w+) (\d+) packets", out)
    if not m:
        return None, False
    return (int(m.group(2)), False) if m.group(1) == "DROP" else (None, True)


def established(ports: set) -> int:
    """Установленные TCP-соединения на портах сервиса прямо сейчас."""
    n = 0
    for name in ("/proc/net/tcp", "/proc/net/tcp6"):
        try:
            for line in Path(name).read_text().splitlines()[1:]:
                f = line.split()
                if len(f) > 3 and f[3] == "01" and int(f[1].rsplit(":", 1)[1], 16) in ports:
                    n += 1
        except OSError:
            continue
    return n


def peak_ports() -> set:
    try:
        return {int(p) for p in str(settings.DIGEST_PEAK_PORTS).split(",") if p.strip()}
    except ValueError:
        return {443, 8444}


# ------------------------------------------------------------------- окно
def ssh_attempts(a: float, b: float) -> Optional[int]:
    """Неудачные вводы пароля SSH. Строка «Invalid user» не считается отдельно:
    за ней следует своя «Failed password», и счёт удвоился бы."""
    out = _run(["journalctl", "-u", "ssh.service", "-u", "sshd.service",
                "--since", f"@{int(a)}", "--until", f"@{int(b)}",
                "-o", "cat", "--no-pager", "-q"], timeout=60)
    if not out and not shutil.which("journalctl"):
        return None
    return sum(1 for line in out.splitlines() if "Failed password" in line)


def bans(a: float, b: float) -> Optional[tuple]:
    """(банов, адресов, дошли до суток и дольше) в тюрьме sshd; None — fail2ban нет."""
    if not shutil.which("fail2ban-client"):
        return None
    try:
        con = _ro(F2B_DB)
        if con is None:
            return (0, 0, 0)
        with con:
            row = con.execute(
                "select count(*), count(distinct ip), coalesce(sum(bantime >= 86400), 0) "
                "from bans where jail = 'sshd' and timeofban between ? and ?",
                (int(a), int(b))).fetchone()
        return tuple(int(x or 0) for x in row)
    except Exception as exc:
        logging.info("Сводка: база fail2ban не прочитана: %s", exc)
        return None


def ru_checks(a: float, b: float) -> Optional[tuple]:
    """(проверок, провальных) из истории MTProxyL; None — истории нет."""
    p = Path(RU_HISTORY)
    if not p.exists():
        return None
    n = bad = 0
    try:
        for line in p.read_text(encoding="utf-8", errors="replace").splitlines():
            try:
                r = json.loads(line)
                t = datetime.strptime(r["checked_at"], "%Y-%m-%dT%H:%M:%SZ") \
                    .replace(tzinfo=timezone.utc).timestamp()
            except Exception:
                continue
            if a <= t <= b:
                n += 1
                if float(r.get("percentage") or 0) < float(settings.RU_CHECK_FLOOR_PCT):
                    bad += 1
    except OSError:
        return None
    return n, bad


def backup(a: float, b: float) -> Optional[tuple]:
    """("ok", размер) | ("missing", была ли ошибка); None — копии VSM не настроены."""
    best = None
    for f in glob.glob(f"{BACKUP_DIR}/config-*.tar.gz"):
        st = Path(f).stat()
        if a <= st.st_mtime <= b and (best is None or st.st_mtime > best[0]):
            best = (st.st_mtime, st.st_size)
    if best:
        return ("ok", best[1])
    if not Path(BACKUP_TIMER).exists():
        return None
    result = _run(["systemctl", "show", "vsm-backup.service", "-p", "Result", "--value"]).strip()
    return ("missing", bool(result) and result != "success")


def _cert_days() -> list:
    out = []
    for cert in glob.glob("/etc/letsencrypt/live/*/cert.pem"):
        end = _run(["openssl", "x509", "-enddate", "-noout", "-in", cert]).strip()
        m = re.search(r"notAfter=(.+)$", end)
        if not m:
            continue
        try:
            t = datetime.strptime(m.group(1).replace("  ", " "), "%b %d %H:%M:%S %Y %Z")
        except ValueError:
            continue
        days = int((t.replace(tzinfo=timezone.utc).timestamp()
                    - datetime.now(timezone.utc).timestamp()) // 86400)
        out.append((days, Path(cert).parent.name))
    return out


def maintenance(a: float, b: float, xui: Optional[list], telemt_users: Optional[list]) -> list:
    """Строки «надо что-то сделать». Пусто — ничего не надо."""
    out = []
    pk = upgrades.packages_between(a, b)
    if pk:
        out.append(f"Автообновления: {len(pk)} {_pk(len(pk))}")
    if Path("/run/reboot-required").exists():
        try:
            pkgs = Path("/run/reboot-required.pkgs").read_text()
        except OSError:
            pkgs = ""
        out.append("⚠️ Нужна перезагрузка" + (" (ядро)" if "linux-image" in pkgs else ""))
    for days, dom in sorted(_cert_days())[:1]:
        if days < 21:
            out.append(f"⚠️ Сертификат {dom}: осталось {days} дн.")
    try:
        u = shutil.disk_usage("/")
        pct = round(u.used / u.total * 100)
        if pct >= 85:
            out.append(f"⚠️ Диск занят на {pct}%")
    except OSError:
        pass
    out += limits(xui, telemt_users, b)
    return out


def _pk(n: int) -> str:
    from telemt.digest.report import plural
    return plural(n, "пакет", "пакета", "пакетов")


def limits(xui: Optional[list], telemt_users: Optional[list], now: float) -> list:
    """Клиенты, у которых кончается трафик (≥ 90%) или срок (≤ 7 дней).
    Молчит, пока лимиты не заданы — у владельца их сейчас нет."""
    import html
    out = []
    week = 7 * 86400
    for email, used, total, expiry_ms in xui or []:
        if total > 0 and used >= 0.9 * total:
            out.append(f"⚠️ 3x-ui {html.escape(email)}: израсходовано {round(used / total * 100)}% трафика")
        if expiry_ms > 0 and 0 <= expiry_ms / 1000 - now <= week:
            out.append(f"⚠️ 3x-ui {html.escape(email)}: срок через {int((expiry_ms / 1000 - now) // 86400)} дн.")
    for u in telemt_users or []:
        name = html.escape(str(u.get("username")))
        quota = int(u.get("data_quota_bytes") or 0)
        used = int(u.get("total_octets") or 0)
        if quota > 0 and used >= 0.9 * quota:
            out.append(f"⚠️ telemt {name}: израсходовано {round(used / quota * 100)}% трафика")
        exp = u.get("expiration_rfc3339")
        if exp:
            try:
                t = datetime.fromisoformat(str(exp).replace("Z", "+00:00")).timestamp()
                if 0 <= t - now <= week:
                    out.append(f"⚠️ telemt {name}: срок через {int((t - now) // 86400)} дн.")
            except ValueError:
                pass
    return out
