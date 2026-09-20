"""
Разбор ответа хаба beszel: что показывать и о чём тревожить.

ЗАЧЕМ ОТДЕЛЬНЫЙ МОДУЛЬ. Здесь только счёт по готовым данным, без сети. Так это
можно прогнать проверками, а в monitor.py остаётся опрос и отправка — ровно как
сделано с дата-центрами в dcs.py.

ДВЕ РАЗНЫЕ БЕДЫ, и путать их нельзя:

  хаб молчит   — сообщений о железе больше не будет ни от кого. Это та самая
                 дыра, ради которой всё и затевалось: молчание сторожа
                 неотличимо от «всё хорошо». Мы это уже проходили с самим
                 ботом, пока не появился отдельный heartbeat.
  агент замолк — хаб жив, но конкретный сервер перестал отчитываться. Либо он
                 лёг, либо туда не доходит связь.

ПАУЗА — НЕ АВАРИЯ. Сервер, снятый с наблюдения вручную, в тревоги не идёт:
иначе бот спорил бы с осознанным решением владельца.
"""
from dataclasses import dataclass, field
from datetime import datetime, timezone

# Сколько сервер может молчать, прежде чем это считается пропажей.
# Агент отчитывается примерно раз в минуту, поэтому пять минут — это пять
# пропущенных докладов подряд, а не случайная задержка.
STALE_AFTER_SECONDS = 300


def _moment(value) -> float:
    """
    Время из хаба в секундах эпохи. Хаб пишет «2026-09-20 08:35:45.174Z» —
    с пробелом вместо T и всегда в UTC (проверено на стенде: 08:35Z при 13:35
    по Алматы). Непонятное значение — 0, то есть «времени нет», а не исключение
    посреди опроса.
    """
    if not isinstance(value, str) or not value:
        return 0.0
    try:
        stamp = datetime.fromisoformat(value.replace(" ", "T"))
    except ValueError:
        return 0.0
    if stamp.tzinfo is None:
        stamp = stamp.replace(tzinfo=timezone.utc)
    return stamp.timestamp()


@dataclass
class Row:
    """Одна строка экрана «Серверы»."""
    name: str
    status: str
    cpu: float = 0.0
    memory: float = 0.0
    disk: float = 0.0
    uptime: int = 0
    services: int = 0
    failed: int = 0
    silent: bool = False

    @property
    def alive(self) -> bool:
        return self.status == "up" and not self.silent


@dataclass
class Verdict:
    state: str = "down"
    error: str = ""
    rows: list = field(default_factory=list)
    # Имена серверов, которые молчат дольше положенного.
    silent: list = field(default_factory=list)
    # Имена серверов, которые сам хаб считает упавшими.
    offline: list = field(default_factory=list)

    @property
    def hub_ok(self) -> bool:
        return self.state == "ok"

    @property
    def trouble(self) -> list:
        """Имена серверов с бедой, без повторов и в порядке появления."""
        видели = []
        for имя in self.offline + self.silent:
            if имя not in видели:
                видели.append(имя)
        return видели


def read_verdict(answer, now: float, stale_after: int = STALE_AFTER_SECONDS) -> Verdict:
    """
    answer — HubAnswer из common.beszel. now — секунды эпохи.

    Пустой список при живом хабе — это «серверов не заведено», а не авария:
    ровно так отвечает хаб сразу после установки.
    """
    verdict = Verdict(state=getattr(answer, "state", "down"),
                      error=getattr(answer, "error", "") or "")
    if verdict.state != "ok":
        return verdict

    from common.beszel import info as _info

    for система in getattr(answer, "systems", []) or []:
        данные = _info(система)
        службы = данные.get("sv") or [0, 0]
        возраст = now - _moment(система.get("updated"))
        статус = (система.get("status") or "").lower()
        # Молчание считаем только у тех, кого хаб не остановил сам: у
        # приостановленного сервера время обновления стоит по определению.
        молчит = статус not in ("paused", "pending") and возраст > stale_after
        строка = Row(
            name=str(система.get("name") or "без имени"),
            status=статус,
            cpu=float(данные.get("cpu") or 0),
            memory=float(данные.get("mp") or 0),
            disk=float(данные.get("dp") or 0),
            uptime=int(данные.get("u") or 0),
            services=int(службы[0]) if len(службы) > 0 else 0,
            failed=int(службы[1]) if len(службы) > 1 else 0,
            silent=молчит,
        )
        verdict.rows.append(строка)
        if статус not in ("up", "paused", "pending"):
            verdict.offline.append(строка.name)
        elif молчит:
            verdict.silent.append(строка.name)

    # Упавшие и молчащие — наверх: на телефоне видно первые строки, и беда
    # должна попасть в них, а не оказаться шестой.
    verdict.rows.sort(key=lambda r: (r.alive, r.name.lower()))
    return verdict


# --- Оформление -------------------------------------------------------------

def срок(seconds: int) -> str:
    """Аптайм словами. Меньше суток показываем часами: «0 дней» ничего не говорит."""
    if seconds <= 0:
        return "—"
    дней = seconds // 86400
    if дней < 1:
        часов = seconds // 3600
        return f"{часов} ч" if часов else "меньше часа"
    остаток = дней % 100
    if 11 <= остаток <= 14:
        слово = "дней"
    elif дней % 10 == 1:
        слово = "день"
    elif дней % 10 in (2, 3, 4):
        слово = "дня"
    else:
        слово = "дней"
    return f"{дней} {слово}"


# Порог, с которого строка красится в жёлтый. Это ТОЛЬКО оформление экрана, а
# не тревога: пороговые сообщения о железе настраиваются в самом beszel, и
# второй хозяин у одного события — прямой путь к двум сообщениям об одном и
# том же.
ВНИМАНИЕ_ДИСК = 85.0
ВНИМАНИЕ_ПАМЯТЬ = 90.0


def parts(verdict):
    """
    Экран «Серверы»: (богатая разметка, запасной текст).

    ОБРАЗЦОМ ВЗЯТА СВОДКА 3x-ui (`bots/xui/api.py`). Первая редакция печатала
    построчный текст, и рядом со сводкой-таблицей он выглядел чужеродно —
    сказано владельцем по снимку экрана 20.09.2026. Разные способы показать
    однородные данные в одном боте — это не свобода, а разнобой.

    ЗАПАСНОЙ ТЕКСТ СОБИРАЕТСЯ ЗДЕСЬ ЖЕ, тем же проходом. Срезать теги
    регуляркой нельзя: таблица превращается в слипшуюся строку значений без
    разделителей, и случается это ровно тогда, когда что-то уже сломалось.

    Значки — из общего словаря `bots/telemt/handlers/aboutall.py`: три азбуки
    статусов в одном боте уже разводили однажды. Ввозим внутри функции: модуль
    сторожа не должен тянуть за собой обработчики при каждом опросе.
    """
    import html as _html
    from common.format import collapse
    from telemt.handlers.aboutall import BAD, OK, WARN

    if verdict.state == "rejected":
        текст = ("🔑 <b>beszel не принимает учётную запись</b>\n"
                 f"{_html.escape(verdict.error or '')}\n"
                 "Хаб при этом работает. Проверьте логин и пароль бота в хабе.")
        return текст, текст
    if not verdict.hub_ok:
        текст = ("🚨 <b>Хаб beszel не отвечает</b>\n"
                 f"{_html.escape(verdict.error or '')}")
        return текст, текст
    if not verdict.rows:
        # Две причины пустого списка, и различить их снаружи нельзя: хаб
        # отдаёт ровно то, что видит ЭТА учётная запись. В beszel сервер
        # принадлежит пользователю, который его завёл, и заведённой отдельно
        # записи бота не видно ничего — проверено 20.09.2026: все четыре
        # сервера числились за первым пользователем. Молчать про второй случай
        # значит отправить человека искать пропавшие серверы.
        текст = ("Хаб отвечает, но этой учётной записи не видно ни одного "
                 "сервера. Либо серверы ещё не заведены, либо они принадлежат "
                 "другой учётной записи: в beszel сервер видит тот, кто его "
                 "добавил.")
        return f"<h2>🖥 Все серверы</h2><p>{текст}</p>", f"🖥 <b>Все серверы</b>\n\n{текст}"

    html_части = ["<h2>🖥 Все серверы</h2>",
                  "<table><tr><th>Сервер</th><th>CPU</th><th>RAM</th>"
                  "<th>DISK</th><th>UPTIME</th></tr>"]
    plain = []
    for строка in verdict.rows:
        имя = _html.escape(строка.name)
        if not строка.alive:
            причина = "молчит" if строка.silent else "не отвечает"
            html_части.append(
                f"<tr><td>{BAD} {имя}</td><td>—</td><td>—</td><td>—</td>"
                f"<td>{причина}</td></tr>")
            plain.append(f"{BAD} <b>{имя}</b> · {причина}")
            continue
        значок = WARN if (строка.disk >= ВНИМАНИЕ_ДИСК
                          or строка.memory >= ВНИМАНИЕ_ПАМЯТЬ) else OK
        html_части.append(
            f"<tr><td>{значок} {имя}</td><td>{строка.cpu:.1f}%</td>"
            f"<td>{строка.memory:.0f}%</td><td>{строка.disk:.0f}%</td>"
            f"<td>{срок(строка.uptime)}</td></tr>")
        plain.append(
            f"{значок} <b>{имя}</b> · CPU {строка.cpu:.1f}% · "
            f"RAM {строка.memory:.0f}% · DISK {строка.disk:.0f}% · "
            f"{срок(строка.uptime)}")
    html_части.append("</table>")

    # Упавшие службы показываем, ТОЛЬКО когда они есть. Строка «упавших нет» у
    # каждого сервера занимала четверть экрана и не сообщала ничего: раздел,
    # который всегда говорит одно и то же, читать перестают.
    упавшие = [с for с in verdict.rows if с.failed]
    if упавшие:
        перечень = " | ".join(
            f"{_html.escape(с.name)} — {с.failed} из {с.services}" for с in упавшие)
        html_части.append(
            f"<details open><summary>Упавшие службы ({len(упавшие)})</summary>"
            f"<p>{перечень}</p></details>")
        plain.append(collapse(перечень.replace(" | ", "\n"),
                              f"⚠️ Упавшие службы ({len(упавшие)})"))

    return "".join(html_части), "\n".join(plain)
