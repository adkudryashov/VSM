#!/usr/bin/env python3
"""Внешние точки наблюдения для censorcheck: check-host.net и RIPE Atlas.

Отдаёт результат одним JSON в stdout. Вызывается из censorcheck.sh, своего
вывода на экран не делает — форматированием занимается bash.

Почему Python, а не bash с jq и curl: обе площадки требуют опроса задания по
таймауту с ретраями и разбора вложенного JSON, где половина полей может быть
null. На bash это превращается в нечитаемую цепочку, а jq вдобавок не входит в
базовую поставку. Здесь достаточно стандартной библиотеки — ставить нечего.

Никакое исключение наружу не выходит: каждая проверка возвращает либо данные,
либо поле "error" с причиной. Отказ одной площадки не должен ронять весь прогон
— недоступный радар это «не проверено», а не «не заблокировано».
"""

import json
import ssl
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

CHECK_HOST_API = "https://check-host.net"
RIPE_API = "https://atlas.ripe.net/api/v2"

# Потребительские сети РФ. ТСПУ ставится у операторов, и домашний абонент видит
# не то же, что стойка в датацентре, — поэтому пробы разделяются по типу сети.
# Смешивать их в одну цифру «доступно из РФ» значит терять весь смысл радара.
RU_CONSUMER_ASNS = {
    8359: "МТС", 12389: "Ростелеком", 3216: "Билайн", 31133: "МегаФон",
    25513: "МГТС", 9049: "ЭР-Телеком", 42610: "НКС", 12714: "ТрансТелеКом",
    16345: "Билайн", 21479: "Уфанет", 34584: "Гарс", 51604: "Теле2",
    41733: "Теле2", 39927: "Мурманск-Телеком", 15774: "ТТК", 8402: "Корбина",
    12668: "Волгателеком", 8580: "Транстелеком", 35807: "Сибирские сети",
    31376: "Комкор", 29076: "Ситителеком", 44546: "Дом.ру",
}

DEFAULT_TIMEOUT = 20


def _request(url, data=None, headers=None, timeout=DEFAULT_TIMEOUT, retries=2):
    """GET/POST с ретраями. Возвращает (данные, None) или (None, причина).

    Ретраи именно здесь, а не у вызывающего: сетевой сбой по пути к площадке —
    штатное событие для сервера, который мы и подозреваем в блокировках.
    Однократная попытка регулярно давала бы «площадка недоступна» там, где
    достаточно повторить через секунду.
    """
    last = "неизвестная ошибка"
    body = json.dumps(data).encode() if data is not None else None
    hdrs = {"Accept": "application/json", "User-Agent": "VSM-censorcheck/1.0"}
    if data is not None:
        hdrs["Content-Type"] = "application/json"
    if headers:
        hdrs.update(headers)

    for attempt in range(retries + 1):
        try:
            req = urllib.request.Request(url, data=body, headers=hdrs)
            ctx = ssl.create_default_context()
            with urllib.request.urlopen(req, timeout=timeout, context=ctx) as resp:
                raw = resp.read().decode("utf-8", "replace")
            return (json.loads(raw) if raw.strip() else {}), None
        except urllib.error.HTTPError as e:
            detail = e.read().decode("utf-8", "replace")[:200]
            last = f"HTTP {e.code}: {detail}"
            # 4xx — наша вина (ключ, лимит, синтаксис), повтор не поможет.
            if 400 <= e.code < 500:
                return None, last
        except urllib.error.URLError as e:
            last = f"сеть недоступна: {e.reason}"
        except json.JSONDecodeError:
            last = "площадка вернула не JSON"
        except Exception as e:  # noqa: BLE001 — наружу исключения не выпускаем
            last = f"{type(e).__name__}: {e}"
        if attempt < retries:
            time.sleep(1.5 * (attempt + 1))
    return None, last


# ---------------------------------------------------------------------------
# CHECK-HOST.NET — датацентровые узлы, без ключа и квот
# ---------------------------------------------------------------------------
def check_host_tcp(targets, nodes=("ru1", "ru2", "ru3"), wait=25):
    """TCP-доступность списка «хост:порт» с российских узлов check-host.

    Узлы датацентровые. Это ценно как быстрый и всегда доступный сигнал
    «сервер вообще виден из РФ», но фильтрацию ТСПУ у домашнего абонента
    так не поймать — для этого есть радар на RIPE Atlas ниже.
    """
    out = {}
    node_hosts = [f"{n}.node.check-host.net" for n in nodes]
    query_nodes = "".join(f"&node={urllib.parse.quote(h)}" for h in node_hosts)

    pending = {}
    for target in targets:
        url = f"{CHECK_HOST_API}/check-tcp?host={urllib.parse.quote(target)}{query_nodes}"
        data, err = _request(url)
        if err or not data or not data.get("request_id"):
            out[target] = {"error": err or "площадка не выдала идентификатор задания"}
            continue
        pending[target] = data["request_id"]

    # Задания ставятся все сразу, а опрашиваются потом: последовательный
    # «поставил-подождал» умножал бы ожидание на число проверяемых портов.
    deadline = time.time() + wait
    results = {t: None for t in pending}
    while pending and time.time() < deadline:
        time.sleep(3)
        for target, rid in list(pending.items()):
            data, err = _request(f"{CHECK_HOST_API}/check-result/{rid}", retries=1)
            if err:
                continue
            if data and all(v is not None for v in data.values()):
                results[target] = data
                del pending[target]

    for target, rid in pending.items():
        results[target] = None  # не дождались

    for target, data in results.items():
        if data is None:
            out[target] = {"error": "узлы не ответили за отведённое время"}
            continue
        per_node = {}
        for node, res in data.items():
            short = node.split(".")[0]
            if not res or not isinstance(res, list) or not res[0]:
                per_node[short] = {"ok": False, "detail": "нет ответа"}
            elif isinstance(res[0], dict) and "error" in res[0]:
                per_node[short] = {"ok": False, "detail": res[0]["error"]}
            elif isinstance(res[0], dict) and "time" in res[0]:
                per_node[short] = {"ok": True, "detail": f"{res[0]['time']:.2f} c"}
            else:
                per_node[short] = {"ok": False, "detail": str(res[0])[:60]}
        out[target] = {"nodes": per_node}
    return out


# ---------------------------------------------------------------------------
# RIPE ATLAS — пробы в реальных сетях РФ, включая домашние и мобильные
# ---------------------------------------------------------------------------
def _atlas_probe_networks(probe_ids, key):
    """ASN и оператор для проб. Пустой словарь, если метаданные не достались:
    без них разбивка по типу сети пропадёт, но сам замер останется валидным."""
    if not probe_ids:
        return {}
    ids = ",".join(str(p) for p in sorted(set(probe_ids))[:200])
    url = f"{RIPE_API}/probes/?id__in={ids}&fields=id,asn_v4,country_code"
    data, err = _request(url, headers={"Authorization": f"Key {key}"}, retries=1)
    if err or not data:
        return {}
    return {p["id"]: p.get("asn_v4") for p in data.get("results", [])}


def atlas_tls(domain, port, key, probes=10, wait=180):
    """Замер TLS-хендшейка к домену с российских проб RIPE Atlas.

    Тип sslcert, а не ping: ТСПУ режет именно TLS по SNI, и пинг при этом
    продолжает ходить. Проверять доступность пингом здесь значило бы получать
    зелёный результат на заблокированном сервере.
    """
    if not key:
        return {"error": "ключ RIPE Atlas не задан", "configurable": True}

    # Ключ уходит в заголовок HTTP, а заголовки кодируются latin-1. Любой
    # не-ASCII символ (лишняя кириллическая буква при вставке, неразрывный
    # пробел из буфера обмена) роняет urllib с UnicodeEncodeError, и вместо
    # понятной причины пользователь получал трассировку питона.
    if not key.isascii():
        return {"error": "ключ RIPE Atlas содержит недопустимые символы "
                         "(ожидается UUID из латиницы, цифр и дефисов)",
                "configurable": True}

    body = {
        "definitions": [{
            "type": "sslcert", "af": 4, "target": domain, "port": int(port),
            "description": f"VSM censorcheck {domain}:{port}",
        }],
        "probes": [{"requested": int(probes), "type": "country", "value": "RU"}],
        "is_oneoff": True,
    }
    data, err = _request(f"{RIPE_API}/measurements/", data=body,
                         headers={"Authorization": f"Key {key}"}, retries=1)
    if err:
        hint = None
        if "credits" in err.lower() or "balance" in err.lower():
            hint = "закончились кредиты RIPE Atlas"
        elif "401" in err or "403" in err:
            hint = "ключ RIPE Atlas отклонён"
        return {"error": hint or f"замер не создан ({err})"}

    ids = (data or {}).get("measurements") or []
    if not ids:
        return {"error": "RIPE Atlas не вернул идентификатор замера"}
    msm_id = ids[0]

    # Ждём не «все пробы», а «перестали прибывать»: часть проб всегда молчит,
    # и требование полного комплекта означало бы ожидание до таймаута всегда.
    deadline, results, stable = time.time() + wait, [], 0
    while time.time() < deadline:
        time.sleep(10)
        data, err = _request(f"{RIPE_API}/measurements/{msm_id}/results/",
                             headers={"Authorization": f"Key {key}"}, retries=1)
        if err or data is None:
            continue
        if len(data) == len(results):
            stable += 1
            if stable >= 2 and results:
                break
        else:
            stable = 0
        results = data
        if len(results) >= probes:
            break

    if not results:
        return {"error": "пробы не прислали результатов за отведённое время",
                "measurement": msm_id}

    asn_by_probe = _atlas_probe_networks([r.get("prb_id") for r in results], key)
    home, dc = [], []
    for r in results:
        asn = asn_by_probe.get(r.get("prb_id"))
        # Успех sslcert — наличие цепочки сертификатов в ответе. Ошибка
        # хендшейка приезжает полем err или пустым cert.
        ok = bool(r.get("cert")) and not r.get("err")
        detail = "TLS установлен" if ok else str(r.get("err") or "хендшейк не прошёл")[:70]
        row = {"probe": r.get("prb_id"), "asn": asn,
               "operator": RU_CONSUMER_ASNS.get(asn), "ok": ok, "detail": detail}
        (home if asn in RU_CONSUMER_ASNS else dc).append(row)

    # requested отдаётся наружу намеренно: если ответила треть проб, отчёт
    # обязан это показать. «2 успешных из 2» на десяти запрошенных выглядит
    # убедительнее, чем есть на самом деле.
    return {"measurement": msm_id, "home": home, "other": dc,
            "total": len(results), "requested": int(probes),
            "ok_total": sum(1 for r in home + dc if r["ok"])}


# ---------------------------------------------------------------------------
# ПРИНАДЛЕЖНОСТЬ АДРЕСОВ СЕТИ
# ---------------------------------------------------------------------------
def asn_lookup(ips):
    """AS и владелец для списка адресов через ipinfo.io (без ключа).

    Нужно, чтобы отличить подмену DNS от обычного поведения CDN. Крупные сайты
    раздают разным резолверам разные адреса своих же точек присутствия, и
    сравнение адресов «в лоб» помечало бы подменой любой сайт за anycast.
    Сравнивать надо владельца сети: разные адреса одной AS — норма, адрес в
    чужой AS у одного резолвера из четырёх — уже признак.

    Недоступность ipinfo не считается ошибкой проверки: без этих данных вывод
    просто становится осторожнее, а не ложно тревожным.
    """
    out = {}
    for ip in list(dict.fromkeys(ips))[:8]:
        data, err = _request(f"https://ipinfo.io/{ip}/json", timeout=8, retries=1)
        if err or not data:
            out[ip] = {"error": err or "нет данных"}
            continue
        org = data.get("org") or ""
        asn = org.split()[0] if org.startswith("AS") else None
        out[ip] = {"asn": asn, "org": org[len(asn) + 1:] if asn else org}
    return out


def main():
    try:
        cfg = json.load(sys.stdin)
    except Exception as e:  # noqa: BLE001
        print(json.dumps({"fatal": f"не разобрал задание: {e}"}))
        return 1

    out = {}
    if cfg.get("asn_lookup"):
        out["asn"] = asn_lookup(cfg["asn_lookup"])
    if cfg.get("checkhost_targets"):
        out["checkhost"] = check_host_tcp(cfg["checkhost_targets"])
    if cfg.get("atlas_domain"):
        out["atlas"] = atlas_tls(cfg["atlas_domain"], cfg.get("atlas_port", 443),
                                 cfg.get("ripe_key"), int(cfg.get("atlas_probes", 10)))
    print(json.dumps(out, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
