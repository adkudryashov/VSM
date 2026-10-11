#!/usr/bin/env python3
"""
Сайт-заглушка VSM: шведский любительский футбольный клуб.

Зачем свой. 3x-ui-pro кладёт в /var/www/html один из десяти общедоступных
шаблонов, одинаковых у всех установок, — по странице установку можно опознать
(10.10.2026). Здесь сайт собирается на каждом сервере свой: название клуба
выводится из домена, остальное (цвета, герб, год основания, соперники, состав,
календарь, счёт матчей, новости) — из случайного числа, которое запоминается,
чтобы сайт не менялся от сборки к сборке. От даты сборки зависит только то,
какие матчи уже сыграны и какие новости уже вышли: пересборка раз в неделю
двигает сезон вперёд, и сайт не стоит на месте.

Без JavaScript, внешних шрифтов и чужих адресов: страница не ходит никуда и
одинаково выглядит у сканера и у человека.

    stub-site.py build --out DIR --domain adk.example.se --seed N [--date YYYY-MM-DD]
    stub-site.py name  --domain adk.example.se --seed N
"""
import argparse
import datetime as dt
import html
import random
import re
import sys
from pathlib import Path

# ------------------------------------------------------------------ словари
PREFIX = ["Björk", "Gran", "Ek", "Lind", "Al", "Sjö", "Sten", "Hall", "Berg", "Åker",
          "Häll", "Ny", "Norr", "Söder", "Väst", "Öster", "Kvarn", "Mo", "Dal", "Hed",
          "Rönn", "Ask", "Tall", "Furu", "Lövs", "Mark", "Lill", "Stor", "Ån", "Bäck"]
SUFFIX = ["vik", "by", "sund", "ås", "torp", "näs", "holm", "bo", "fors", "hult",
          "berga", "ryd", "lunda", "stad", "hammar", "dala", "mark", "red", "sjö", "tuna"]
CLUB_KIND = ["IF", "IF", "IF", "IK", "BK", "FF", "SK", "GoIF", "AIF"]

FIRST = ["Oscar", "William", "Lucas", "Elias", "Hugo", "Alexander", "Liam", "Noah", "Adam",
         "Filip", "Viktor", "Emil", "Anton", "Isak", "Albin", "Axel", "Ludvig", "Melvin",
         "Linus", "Jonathan", "Simon", "Gustav", "Erik", "Johan", "Marcus", "Daniel",
         "Sebastian", "Rasmus", "Kevin", "Andreas", "Jesper", "Oliver", "Nils", "Theo",
         "Leo", "Måns", "Samuel", "Arvid", "Edvin", "Ali", "Omar", "Luka", "Mattias",
         "Joel", "Jakob", "Hampus", "Pontus", "Ibrahim", "Dennis", "Tobias", "Carl", "Max"]
LAST = ["Andersson", "Johansson", "Karlsson", "Nilsson", "Eriksson", "Larsson", "Olsson",
        "Persson", "Svensson", "Gustafsson", "Pettersson", "Jonsson", "Hansson", "Bengtsson",
        "Jönsson", "Lindberg", "Lindqvist", "Lundgren", "Berg", "Bergström", "Holm",
        "Sandberg", "Forsberg", "Sjöberg", "Wallin", "Engström", "Ekström", "Hedlund",
        "Nyström", "Lundin", "Åberg", "Hassan", "Popović", "Kovač", "Mäkinen", "Axelsson",
        "Falk", "Strand", "Blom", "Lind", "Söderberg", "Hermansson", "Isaksson", "Hadžić"]

# (основной, акцент, текст на основном)
PALETTES = [
    ("#13294b", "#f2c230", "#ffffff"),   # тёмно-синий и жёлтый
    ("#0b6b3a", "#ffffff", "#ffffff"),   # зелёный и белый
    ("#b3121f", "#ffffff", "#ffffff"),   # красный и белый
    ("#1d4fa3", "#ffffff", "#ffffff"),   # синий и белый
    ("#111111", "#f2c230", "#ffffff"),   # чёрный и жёлтый
    ("#6b1530", "#7fb8e6", "#ffffff"),   # бордовый и голубой
    ("#e0601b", "#111111", "#ffffff"),   # оранжевый и чёрный
    ("#4b2a7b", "#ffffff", "#ffffff"),   # фиолетовый и белый
    ("#0f5e74", "#f28c28", "#ffffff"),   # морской и оранжевый
]

MONTHS = ["januari", "februari", "mars", "april", "maj", "juni", "juli", "augusti",
          "september", "oktober", "november", "december"]
WEEKDAYS = ["måndag", "tisdag", "onsdag", "torsdag", "fredag", "lördag", "söndag"]


def esc(s):
    return html.escape(str(s), quote=True)


def sv_date(d, weekday=False):
    s = f"{d.day} {MONTHS[d.month - 1]} {d.year}"
    return f"{WEEKDAYS[d.weekday()]} {s}" if weekday else s


def genitive(place):
    return place if place[-1] in "sxz" else place + "s"


def slugify(s):
    s = s.lower()
    for a, b in (("å", "a"), ("ä", "a"), ("ö", "o"), ("é", "e")):
        s = s.replace(a, b)
    return re.sub(r"[^a-z0-9]+", "-", s).strip("-")


# ------------------------------------------------------------------ модель
def place_from_domain(domain):
    """Место — из второго уровня домена, если оно похоже на слово: на
    egevad.se клуб «Egevads IF» выглядит естественно. Иначе — None."""
    labels = [x for x in domain.lower().strip(".").split(".") if x]
    if len(labels) < 2:
        return None
    word = labels[-2]
    if re.fullmatch(r"[a-zåäö]{4,12}", word) and re.search(r"[aeiouyåäö]", word):
        return word[0].upper() + word[1:]
    return None


def random_place(rnd, taken):
    while True:
        p = rnd.choice(PREFIX) + rnd.choice(SUFFIX)
        p = p.replace("ss", "s") if p.count("s") > 2 else p
        if p not in taken:
            taken.add(p)
            return p


def club_name(place, kind):
    return f"IFK {place}" if kind == "IFK" else f"{genitive(place)} {kind}"


def person(rnd, used):
    while True:
        n = f"{rnd.choice(FIRST)} {rnd.choice(LAST)}"
        if n not in used:
            used.add(n)
            return n


class Club:
    def __init__(self, domain, seed):
        rnd = random.Random(seed)
        self.rnd = rnd
        self.domain = domain
        taken = set()
        self.place = place_from_domain(domain) or random_place(rnd, taken)
        taken.add(self.place)
        kind = rnd.choice(CLUB_KIND + ["IFK"])
        self.name = club_name(self.place, kind)
        self.short = "IFK" if kind == "IFK" else (self.place[0] + kind.replace("o", "")).upper()
        self.seed_tag = rnd.randrange(16 ** 4)
        self.founded = rnd.randint(1921, 1986)
        self.c1, self.c2, self.ink = rnd.choice(PALETTES)
        self.arena = rnd.choice([f"{genitive(self.place)}vallen", f"{self.place} IP",
                                 f"{self.place} idrottsplats"])
        self.division = rnd.choice(["Division 4", "Division 5", "Division 5", "Division 6"])
        self.members = rnd.randrange(240, 900, 10)
        self.teams = rnd.randint(9, 24)
        self.crest_style = rnd.choice(["stripes", "diagonal", "split", "band"])
        self.train_days = rnd.choice([("tisdagar", "torsdagar"), ("måndagar", "onsdagar"),
                                      ("tisdagar", "fredagar")])
        self.train_time = rnd.choice(["18.00–19.30", "18.30–20.00", "19.00–20.30"])
        # Соперники: одиннадцать выдуманных клубов, тот же способ, что у нас.
        self.teams_in_league = [self.name]
        for _ in range(11):
            self.teams_in_league.append(club_name(random_place(rnd, taken), rnd.choice(CLUB_KIND)))
        used = set()
        self.coach = person(rnd, used)
        self.assistant = person(rnd, used)
        self.manager = person(rnd, used)
        self.chair = person(rnd, used)
        self.squad = []
        nums = rnd.sample(range(2, 31), 21)
        layout = [("Målvakter", 2), ("Försvarare", 7), ("Mittfältare", 7), ("Anfallare", 5)]
        for pos, n in layout:
            for i in range(n):
                num = 1 if pos == "Målvakter" and i == 0 else nums.pop()
                self.squad.append((pos, num, person(rnd, used), rnd.randint(17, 34)))
        self.forwards = [p for p in self.squad if p[0] in ("Anfallare", "Mittfältare")]


# ------------------------------------------------------------------ сезон
def nth_weekday(year, month, weekday, n):
    d = dt.date(year, month, 1)
    d += dt.timedelta(days=(weekday - d.weekday()) % 7)
    return d + dt.timedelta(weeks=n - 1)


def round_dates(year):
    """22 тура: с третьей субботы апреля до середины июня, пауза на июль,
    с первой субботы августа до конца октября — как у низших дивизионов."""
    spring = nth_weekday(year, 4, 5, 3)
    autumn = nth_weekday(year, 8, 5, 1)
    return [spring + dt.timedelta(weeks=i) for i in range(10)] + \
           [autumn + dt.timedelta(weeks=i) for i in range(12)]


def schedule(club, year):
    """Двойной круг по методу кругового расписания, счёт каждой игры —
    из случайного числа клуба и года, а не из даты сборки."""
    teams = list(range(12))
    rnd = random.Random(f"{club.name}|{year}")
    rnd.shuffle(teams)
    rounds = []
    t = teams[:]
    for r in range(11):
        pairs = []
        for i in range(6):
            a, b = t[i], t[11 - i]
            pairs.append((a, b) if (r + i) % 2 == 0 else (b, a))
        rounds.append(pairs)
        t = [t[0]] + [t[-1]] + t[1:-1]
    rounds += [[(b, a) for a, b in pairs] for pairs in rounds]
    dates = round_dates(year)
    goals = [0, 0, 1, 1, 1, 2, 2, 2, 3, 3, 4, 5]
    games = []
    for rno, pairs in enumerate(rounds):
        for a, b in pairs:
            day = dates[rno] + dt.timedelta(days=rnd.choice([0, 0, 0, 1, 1, -2]))
            hour = {5: "15.00", 6: "14.00"}.get(day.weekday(), "19.00")
            ga, gb = rnd.choice(goals), rnd.choice(goals)
            # Свой клуб чуть сильнее среднего: не чемпион и не аутсайдер.
            if 0 in (a, b) and rnd.random() < 0.25:
                if a == 0:
                    ga += 1
                else:
                    gb += 1
            games.append({"round": rno + 1, "date": day, "time": hour,
                          "home": a, "away": b, "hg": ga, "ag": gb})
    return games


def table(club, games, today):
    rows = {i: {"team": i, "p": 0, "w": 0, "d": 0, "l": 0, "gf": 0, "ga": 0} for i in range(12)}
    for g in games:
        if g["date"] >= today:
            continue
        for me, other, gf, ga in ((g["home"], g["away"], g["hg"], g["ag"]),
                                  (g["away"], g["home"], g["ag"], g["hg"])):
            r = rows[me]
            r["p"] += 1
            r["gf"] += gf
            r["ga"] += ga
            if gf > ga:
                r["w"] += 1
            elif gf == ga:
                r["d"] += 1
            else:
                r["l"] += 1
    out = list(rows.values())
    for r in out:
        r["pts"] = r["w"] * 3 + r["d"]
    out.sort(key=lambda r: (-r["pts"], -(r["gf"] - r["ga"]), -r["gf"],
                            club.teams_in_league[r["team"]]))
    return out


# ------------------------------------------------------------------ герб
def crest_svg(club, size=None):
    c1, c2 = club.c1, club.c2
    shield = "M50 4 L92 16 V52 C92 78 72 92 50 100 C28 92 8 78 8 52 V16 Z"
    if club.crest_style == "stripes":
        fill = "".join(f'<rect x="{x}" y="0" width="12" height="104" fill="{c2}"/>'
                       for x in (20, 44, 68))
    elif club.crest_style == "diagonal":
        fill = f'<path d="M0 70 L100 10 V40 L0 100 Z" fill="{c2}"/>'
    elif club.crest_style == "split":
        fill = f'<rect x="50" y="0" width="50" height="104" fill="{c2}"/>'
    else:
        fill = f'<rect x="0" y="38" width="100" height="26" fill="{c2}"/>'
    # Буквы и год — на плашках цвета клуба, чтобы читались поверх любых полос.
    # У «пояса» плашкой служит сам пояс, и буквы на нём основного цвета.
    if club.crest_style == "band":
        plate, ink = "", c1
    else:
        plate, ink = f'<rect x="16" y="38" width="68" height="26" rx="4" fill="{c1}"/>', c2
    font = 'text-anchor="middle" font-family="Arial,Helvetica,sans-serif" font-weight="700"'
    dims = f' width="{size}" height="{size}"' if size else ""
    clip = f"c{club.seed_tag}{size or ''}"
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 104"{dims} role="img" '
            f'aria-label="{esc(club.name)}"><defs><clipPath id="{clip}"><path d="{shield}"/></clipPath>'
            f'</defs><g clip-path="url(#{clip})"><rect width="100" height="104" fill="{c1}"/>{fill}</g>'
            # Светлая кайма: в шапке щит лежит на фоне своего же цвета.
            f'<path d="{shield}" fill="none" stroke="#ffffff" stroke-width="5"/>'
            f'<path d="{shield}" fill="none" stroke="{c1}" stroke-width="1.5"/>{plate}'
            f'<text x="50" y="57" {font} font-size="16" fill="{ink}">{esc(club.short)}</text>'
            f'<rect x="32" y="72" width="36" height="15" rx="3" fill="{c1}"/>'
            f'<text x="50" y="83.5" {font} font-size="10" fill="{c2}">{club.founded}</text></svg>')


# ------------------------------------------------------------------ новости
def match_report(club, g, rnd):
    us_home = g["home"] == 0
    us, them = (g["hg"], g["ag"]) if us_home else (g["ag"], g["hg"])
    opp = club.teams_in_league[g["away"] if us_home else g["home"]]
    venue = club.arena if us_home else f"bortaplan mot {opp}"
    score = f"{g['hg']}–{g['ag']}"
    scorers = [rnd.choice(club.forwards)[2] for _ in range(us)]
    if us > them:
        title = rnd.choice([f"Tre viktiga poäng mot {opp}", f"Seger mot {opp}",
                            f"Klar seger på {venue}" if us - them > 1 else f"Knapp seger mot {opp}"])
        mood = rnd.choice(["Laget gjorde en stabil insats från start till slut.",
                           "Det var en match där vi tog hand om våra chanser."])
        coach = rnd.choice(["Jag är stolt över grabbarna. Vi höll ihop laget och jobbade för varandra hela vägen.",
                            "Vi har tränat mycket på omställningar och i dag satt det. Nu tar vi nästa match."])
    elif us == them:
        title = rnd.choice([f"Delad pott mot {opp}", f"Oavgjort mot {opp}"])
        mood = "Matchen var jämn och båda lagen hade perioder då de var bättre."
        coach = rnd.choice(["En poäng är okej, men vi hade lägen att avgöra. Det får vi bli bättre på.",
                            "Vi visade karaktär efter en tung inledning. Det tar vi med oss."])
    else:
        title = rnd.choice([f"Förlust mot {opp}", f"Tungt mot {opp}"])
        mood = "Det blev en tung eftermiddag och motståndarna var bättre på dagen."
        coach = rnd.choice(["Vi var inte tillräckligt bra i dag. Vi analyserar matchen och kommer tillbaka.",
                            "Vi släppte in för enkla mål. Det ska vi jobba med på veckans träningar."])
    goals_txt = ""
    if scorers:
        names = sorted(set(scorers), key=scorers.index)
        parts = [f"{n} ({scorers.count(n)})" if scorers.count(n) > 1 else n for n in names]
        goals_txt = ("Målskytt för oss: " if len(parts) == 1 else "Målskyttar för oss: ") + \
            ", ".join(parts) + "."
    body = [f"Omgång {g['round']} spelades {sv_date(g['date'], True)} på {venue} och slutade {score}. {mood}",
            goals_txt,
            f"– {coach}, säger huvudtränaren {club.coach}.",
            "Tack till alla som kom och hejade – ni gör skillnad!" if us_home else
            "Tack till alla supportrar som följde med på bortaresan!"]
    return title, [p for p in body if p]


def news(club, year, games, today):
    rnd = random.Random(f"{club.name}|news|{year}")
    items = []

    def add(date, title, paras, tag):
        items.append({"date": date, "title": title, "paras": paras, "tag": tag})

    add(dt.date(year, 1, 20) + dt.timedelta(days=rnd.randint(0, 10)),
        f"{club.coach} ny huvudtränare", [
            f"Styrelsen är glad att kunna meddela att {club.coach} tar över som huvudtränare för A-laget inför säsongen {year}.",
            f"{club.coach.split()[0]} har tidigare tränat flera ungdomslag i föreningen och känner både spelarna och klubben väl. Som assisterande tränare fortsätter {club.assistant}.",
            f"– Det känns hedrande att få förtroendet. Vi har en ung och hungrig trupp, och målet är att utvecklas match för match, säger {club.coach}.",
            "Försäsongsträningen drar i gång i början av februari. Nya spelare är välkomna att höra av sig till kansliet."],
        "Föreningen")
    am = nth_weekday(year, 3, 3, 2)
    add(am - dt.timedelta(days=24), "Kallelse till årsmöte", [
        f"Medlemmarna i {club.name} kallas härmed till ordinarie årsmöte {sv_date(am, True)} klockan 19.00 i klubbstugan på {club.arena}.",
        f"Motioner ska vara styrelsen tillhanda senast två veckor före mötet. Handlingarna finns att hämta i klubbstugan en vecka innan.",
        "Efter mötet bjuder föreningen på kaffe och smörgås. Välkomna!"], "Föreningen")
    add(dt.date(year, 5, 2) + dt.timedelta(days=rnd.randint(0, 8)), "Anmälan till fotbollsskolan är öppen", [
        f"I sommar arrangerar vi återigen fotbollsskola på {club.arena}. Den hålls vecka 26 för barn födda {year - 11}–{year - 6}.",
        "Varje dag bjuder på träning i små grupper, lekar, matcher och lunch. Ledarna är spelare och tränare från föreningens egna lag.",
        "Anmälan görs i klubbstugan eller via e-post till kansliet. Antalet platser är begränsat, så vänta inte för länge!"],
        "Ungdom")
    add(dt.date(year, 5, 20) + dt.timedelta(days=rnd.randint(0, 6)), "Vi söker fler kioskvärdar", [
        "Kiosken på hemmamatcherna är en viktig inkomstkälla för föreningen och går direkt till ungdomsverksamheten.",
        "Vi behöver fler som kan ställa upp ett par gånger per säsong. Det är enkelt, roligt och ett bra sätt att lära känna andra i klubben.",
        "Skriv upp dig på listan i klubbstugan eller hör av dig till kansliet."], "Föreningen")
    add(dt.date(year, 7, 3) + dt.timedelta(days=rnd.randint(0, 5)), f"Planen på {club.arena} får ny dränering", [
        f"Under sommaruppehållet görs arbete på huvudplanen på {club.arena}. Planen får ny dränering och sås om på de mest slitna ytorna.",
        "Träningarna flyttas under tiden till grusplanen bakom klubbstugan. Vi räknar med att vara tillbaka på gräset till serieomstarten i augusti."],
        "Arena")
    add(dt.date(year, 8, 12) + dt.timedelta(days=rnd.randint(0, 6)), "Höstens träningstider", [
        f"A-laget tränar {club.train_days[0]} och {club.train_days[1]} klockan {club.train_time} på {club.arena}.",
        "Ungdomslagens träningstider finns hos respektive lagledare. Är du ny och vill börja spela – kom förbi en träning och prova på, det kostar ingenting."],
        "Träning")
    add(dt.date(year, 9, 8) + dt.timedelta(days=rnd.randint(0, 10)), "Ungdomslagen i full gång", [
        f"Hösten är i full gång för föreningens {club.teams} lag. Under helgerna spelas det matcher från förmiddag till kväll.",
        "Ett stort tack till alla föräldrar och ledare som ställer upp – utan er ingen ungdomsfotboll."],
        "Ungdom")
    ours = [g for g in games if 0 in (g["home"], g["away"]) and g["date"] < today]
    for g in ours[-3:] + ours[:1]:
        title, paras = match_report(club, g, rnd)
        add(g["date"] + dt.timedelta(days=1), title, paras, "Match")
    out, seen = [], set()
    for it in sorted(items, key=lambda x: x["date"], reverse=True):
        if it["date"] > today or it["title"] in seen:
            continue
        seen.add(it["title"])
        it["slug"] = f"{it['date']:%Y-%m-%d}-{slugify(it['title'])}"
        out.append(it)
    return out


# ------------------------------------------------------------------ вёрстка
CSS = """:root{--c1:%(c1)s;--c2:%(c2)s;--ink-on:%(ink)s;--bg:#f5f6f8;--card:#fff;--ink:#14171c;
--muted:#5d6673;--line:#e3e6eb;--r:14px}
*{box-sizing:border-box}html{-webkit-text-size-adjust:100%%}
body{margin:0;background:var(--bg);color:var(--ink);font:16px/1.6 system-ui,-apple-system,"Segoe UI",Roboto,"Helvetica Neue",Arial,sans-serif}
a{color:var(--c1)}a:hover{opacity:.85}img,svg{max-width:100%%}
.wrap{max-width:1120px;margin:0 auto;padding:0 20px}
header{position:sticky;top:0;z-index:5;background:var(--c1);color:var(--ink-on);box-shadow:0 2px 12px rgba(0,0,0,.15)}
.bar{display:flex;align-items:center;gap:18px;min-height:68px}
.brand{display:flex;align-items:center;gap:12px;color:inherit;text-decoration:none;font-weight:800;letter-spacing:.2px;font-size:19px;white-space:nowrap}
.brand svg{width:40px;height:42px;flex:none}
nav{margin-left:auto;display:flex;gap:4px;overflow-x:auto;scrollbar-width:none}
nav a{color:inherit;text-decoration:none;padding:8px 12px;border-radius:999px;font-weight:600;font-size:15px;white-space:nowrap;opacity:.9}
nav a.on,nav a:hover{background:rgba(255,255,255,.16);opacity:1}
.hero{background:linear-gradient(120deg,var(--c1) 0%%,var(--c1) 55%%,color-mix(in srgb,var(--c1) 70%%,#000) 100%%);color:var(--ink-on);position:relative;overflow:hidden}
.hero:after{content:"";position:absolute;inset:0;background:repeating-linear-gradient(115deg,transparent 0 70px,rgba(255,255,255,.05) 70px 140px);pointer-events:none}
.hero .wrap{position:relative;z-index:1;display:grid;grid-template-columns:1.2fr 1fr;gap:32px;padding-top:56px;padding-bottom:56px;align-items:center}
.kicker{display:inline-block;background:var(--c2);color:var(--c1);font-weight:800;font-size:12px;letter-spacing:1.2px;text-transform:uppercase;padding:5px 10px;border-radius:6px}
.hero h1{font-size:clamp(30px,5vw,52px);line-height:1.08;margin:14px 0 12px;letter-spacing:-.5px}
.hero p{opacity:.88;font-size:18px;margin:0 0 22px;max-width:520px}
.btn{display:inline-block;background:var(--c2);color:var(--c1);font-weight:800;text-decoration:none;padding:12px 20px;border-radius:10px}
.btn.ghost{background:transparent;color:var(--ink-on);border:2px solid rgba(255,255,255,.4);margin-left:8px}
.next{background:rgba(255,255,255,.1);backdrop-filter:blur(6px);border:1px solid rgba(255,255,255,.18);border-radius:var(--r);padding:22px}
.next h2{margin:0 0 14px;font-size:14px;text-transform:uppercase;letter-spacing:1.2px;opacity:.85}
.vs{display:grid;grid-template-columns:1fr auto 1fr;align-items:center;gap:10px;text-align:center;font-weight:800;font-size:18px}
.vs .x{font-size:28px;opacity:.7}
.meta{margin-top:14px;text-align:center;opacity:.85;font-size:15px}
main{padding:40px 0 56px}
.grid{display:grid;grid-template-columns:2fr 1fr;gap:28px}
.sec h2{font-size:22px;margin:0 0 16px;letter-spacing:-.2px}
.cards{display:grid;grid-template-columns:repeat(auto-fill,minmax(250px,1fr));gap:18px}
.card{background:var(--card);border:1px solid var(--line);border-radius:var(--r);overflow:hidden;display:flex;flex-direction:column;text-decoration:none;color:inherit;transition:transform .15s,box-shadow .15s}
a.card:hover{transform:translateY(-2px);box-shadow:0 10px 24px rgba(20,23,28,.08);opacity:1}
.card .top{height:8px;background:linear-gradient(90deg,var(--c1),var(--c2))}
.card .in{padding:18px}
.tag{font-size:12px;font-weight:700;text-transform:uppercase;letter-spacing:1px;color:var(--c1)}
.card h3{margin:6px 0 8px;font-size:18px;line-height:1.3}
.card p{margin:0;color:var(--muted);font-size:15px}
.date{color:var(--muted);font-size:13px}
.box{background:var(--card);border:1px solid var(--line);border-radius:var(--r);padding:18px;margin-bottom:22px}
table{width:100%%;border-collapse:collapse;font-size:14px}
th,td{padding:8px 6px;text-align:right;border-bottom:1px solid var(--line);white-space:nowrap}
th:nth-child(2),td:nth-child(2){text-align:left;white-space:normal}
th{color:var(--muted);font-weight:600;font-size:12px;text-transform:uppercase}
tr.us td{font-weight:800;color:var(--c1)}
.res{display:flex;justify-content:space-between;gap:10px;padding:10px 0;border-bottom:1px solid var(--line);font-size:15px}
.res:last-child{border:0}.res b{white-space:nowrap}
.pill{display:inline-block;min-width:26px;text-align:center;border-radius:6px;padding:1px 6px;font-size:12px;font-weight:800;color:#fff}
.W{background:#1f9d55}.D{background:#8a94a3}.L{background:#d64545}
.page-h{background:var(--c1);color:var(--ink-on);padding:38px 0}
.page-h h1{margin:0;font-size:clamp(26px,4vw,38px)}
.page-h p{margin:6px 0 0;opacity:.85}
.list .row{display:grid;grid-template-columns:150px 1fr auto;gap:14px;align-items:center;background:var(--card);border:1px solid var(--line);border-radius:12px;padding:14px 18px;margin-bottom:10px}
.list .row .t{font-weight:600}.list .row .sc{font-weight:800;font-size:18px}
.squad{display:grid;grid-template-columns:repeat(auto-fill,minmax(220px,1fr));gap:14px;margin-bottom:28px}
.pl{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:14px 16px;display:flex;gap:14px;align-items:center}
.pl .n{font-size:26px;font-weight:900;color:var(--c1);min-width:40px;text-align:center}
.pl .m{color:var(--muted);font-size:14px}
article{max-width:740px}article p{font-size:17px}
.prose h2{margin-top:30px}
footer{background:#0f1216;color:#aeb6c2;padding:36px 0;font-size:14px}
footer .wrap{display:flex;flex-wrap:wrap;gap:24px;justify-content:space-between;align-items:center}
footer a{color:#dfe5ee}
@media (max-width:860px){.hero .wrap,.grid{grid-template-columns:1fr}.list .row{grid-template-columns:1fr;gap:4px}.bar{flex-wrap:wrap;padding:10px 0}nav{margin-left:0;width:100%%}}
"""

NAV = [("index.html", "Start"), ("matcher.html", "Matcher"), ("nyheter.html", "Nyheter"),
       ("laget.html", "Laget"), ("foreningen.html", "Föreningen")]


def page(club, title, active, body, depth=0, desc=None):
    up = "../" * depth
    on = ' class="on"'
    nav = "".join(f'<a href="{up}{href}"{on if href == active else ""}>{esc(lbl)}</a>'
                  for href, lbl in NAV)
    full = club.name if title is None else f"{title} – {club.name}"
    desc = desc or f"{club.name} – fotbollsförening sedan {club.founded}. Matcher, nyheter och information om föreningen."
    return f"""<!DOCTYPE html>
<html lang="sv">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{esc(full)}</title>
<meta name="description" content="{esc(desc)}">
<meta name="theme-color" content="{club.c1}">
<link rel="icon" href="{up}favicon.svg" type="image/svg+xml">
<link rel="stylesheet" href="{up}css/site.css">
</head>
<body>
<header><div class="wrap bar"><a class="brand" href="{up}index.html">{crest_svg(club)}<span>{esc(club.name)}</span></a><nav>{nav}</nav></div></header>
{body}
<footer><div class="wrap"><div><strong style="color:#fff">{esc(club.name)}</strong><br>Ideell förening · Grundad {club.founded}<br>{esc(club.arena)}</div>
<div>Kansliet: <a href="mailto:kansli@{esc(club.mail_domain)}">kansli@{esc(club.mail_domain)}</a><br>© {club.year} {esc(club.name)}</div></div></footer>
</body>
</html>
"""


def team(club, i):
    return club.teams_in_league[i]


def fixtures_html(club, games, today, limit=None, upcoming=False):
    ours = [g for g in games if 0 in (g["home"], g["away"])]
    sel = [g for g in ours if (g["date"] >= today) == upcoming]
    if not upcoming:
        sel = sel[::-1]
    if limit:
        sel = sel[:limit]
    return sel


def outcome(g):
    us_home = g["home"] == 0
    us, them = (g["hg"], g["ag"]) if us_home else (g["ag"], g["hg"])
    return "W" if us > them else "D" if us == them else "L"


OUT_SV = {"W": "V", "D": "O", "L": "F"}
ONE = {"Målvakter": "Målvakt", "Försvarare": "Försvarare", "Mittfältare": "Mittfältare",
       "Anfallare": "Anfallare"}


def build(club, today, out: Path):
    club.year = today.year
    club.mail_domain = ".".join(club.domain.split(".")[-2:])
    year = today.year
    games = schedule(club, year)
    tab = table(club, games, today)
    items = news(club, year, games, today)
    played = fixtures_html(club, games, today)
    upcoming = fixtures_html(club, games, today, upcoming=True)
    pos = next(i for i, r in enumerate(tab, 1) if r["team"] == 0)

    files = {}
    files["css/site.css"] = CSS % {"c1": club.c1, "c2": club.c2, "ink": club.ink}
    files["favicon.svg"] = crest_svg(club) + "\n"
    files["robots.txt"] = "User-agent: *\nAllow: /\n"

    # --- hero
    if upcoming:
        g = upcoming[0]
        next_box = f"""<div class="next"><h2>Nästa match · Omgång {g['round']}</h2>
<div class="vs"><span>{esc(team(club, g['home']))}</span><span class="x">–</span><span>{esc(team(club, g['away']))}</span></div>
<div class="meta">{esc(sv_date(g['date'], True).capitalize())} kl. {g['time']}<br>{esc(club.arena if g['home'] == 0 else 'Bortamatch')}</div></div>"""
        if played:
            lead = f"{club.division} {year}. Vi ligger på plats {pos} i tabellen – kom och heja på laget!"
        else:
            lead = f"Seriepremiären i {club.division.lower()} spelas {sv_date(g['date'])}. Välkommen till {club.arena}!"
    else:
        last = played[0] if played else None
        if last:
            lead = f"Säsongen {year} är över. Vi slutade på plats {pos} i {club.division.lower()}. Tack för i år!"
        else:
            lead = f"Seriepremiären i {club.division.lower()} spelas i april. Försäsongen är i full gång!"
        next_box = f"""<div class="next"><h2>Träning</h2><div class="meta" style="margin:0;text-align:left">
A-laget tränar {club.train_days[0]} och {club.train_days[1]} kl. {club.train_time} på {esc(club.arena)}.<br><br>Nya spelare är alltid välkomna att prova på.</div></div>"""
    hero = f"""<section class="hero"><div class="wrap"><div><span class="kicker">{esc(club.division)} · {year}</span>
<h1>Välkommen till {esc(club.name)}</h1><p>{esc(lead)}</p>
<a class="btn" href="matcher.html">Matcher &amp; tabell</a><a class="btn ghost" href="foreningen.html">Bli medlem</a></div>
{next_box}</div></section>"""

    cards = "".join(f"""<a class="card" href="nyheter/{it['slug']}.html"><div class="top"></div><div class="in">
<span class="tag">{esc(it['tag'])}</span><h3>{esc(it['title'])}</h3><p>{esc(it['paras'][0][:140].rsplit(' ', 1)[0])}…</p>
<p class="date" style="margin-top:10px">{esc(sv_date(it['date']))}</p></div></a>""" for it in items[:4])

    def tab_html(rows):
        trs = "".join(f"""<tr{' class="us"' if r['team'] == 0 else ''}><td>{i}</td><td>{esc(team(club, r['team']))}</td>
<td>{r['p']}</td><td>{r['w']}</td><td>{r['d']}</td><td>{r['l']}</td><td>{r['gf']}–{r['ga']}</td><td>{r['pts']}</td></tr>"""
                      for i, r in rows)
        return f"""<table><thead><tr><th>#</th><th>Lag</th><th>S</th><th>V</th><th>O</th><th>F</th><th>Mål</th><th>P</th></tr></thead><tbody>{trs}</tbody></table>"""

    short_tab = [(i, r) for i, r in enumerate(tab, 1)]
    if len(short_tab) > 8:
        lo = max(0, min(pos - 4, len(short_tab) - 8))
        short_tab = short_tab[lo:lo + 8]
    short_rows = "".join(f"""<tr{' class="us"' if r['team'] == 0 else ''}><td>{i}</td><td>{esc(team(club, r['team']))}</td><td>{r['p']}</td><td>{r['pts']}</td></tr>"""
                         for i, r in short_tab)
    res_rows = "".join(f"""<div class="res"><span>{esc(team(club, g['home']))} – {esc(team(club, g['away']))}</span>
<b>{g['hg']}–{g['ag']} <span class="pill {outcome(g)}">{OUT_SV[outcome(g)]}</span></b></div>""" for g in played[:5])
    side = f"""<div class="box"><h2 style="font-size:18px;margin:0 0 10px">Tabell</h2>
<table><thead><tr><th>#</th><th>Lag</th><th>S</th><th>P</th></tr></thead><tbody>{short_rows}</tbody></table>
<p style="margin:12px 0 0;font-size:14px"><a href="matcher.html">Hela tabellen →</a></p></div>"""
    if res_rows:
        side += f"""<div class="box"><h2 style="font-size:18px;margin:0 0 6px">Senaste resultat</h2>{res_rows}</div>"""
    home = f"""{hero}<main><div class="wrap grid"><section class="sec"><h2>Senaste nytt</h2><div class="cards">{cards}</div>
<div class="box" style="margin-top:28px"><h2 style="font-size:20px;margin:0 0 8px">Vill du spela fotboll?</h2>
<p style="margin:0;color:var(--muted)">Vi har lag för alla åldrar – från knattefotboll till seniorer. Kontakta kansliet eller kom förbi en träning på {esc(club.arena)}.</p></div>
</section><aside>{side}</aside></div></main>"""
    files["index.html"] = page(club, None, "index.html", home)

    # --- matcher
    def rows(sel, show_score):
        if not sel:
            return '<p style="color:var(--muted)">Inga matcher att visa.</p>'
        out = []
        for g in sel:
            sc = f"{g['hg']}–{g['ag']}" if show_score else ""
            where = club.arena if g["home"] == 0 else "Bortamatch"
            out.append(f"""<div class="row"><span class="date">{esc(sv_date(g['date'], True))}<br>kl. {g['time']}</span>
<span class="t">{esc(team(club, g['home']))} – {esc(team(club, g['away']))}<br><span class="date">Omgång {g['round']} · {esc(where)}</span></span>
<span class="sc">{sc}</span></div>""")
        return "".join(out)
    m_body = f"""<section class="page-h"><div class="wrap"><h1>Matcher</h1><p>{esc(club.division)} {year}</p></div></section>
<main><div class="wrap grid"><section class="list">
{'<h2>Kommande</h2>' + rows(upcoming, False) if upcoming else ''}
<h2>Spelade</h2>{rows(played, True)}</section>
<aside><div class="box"><h2 style="font-size:18px;margin:0 0 10px">Tabell</h2>{tab_html(list(enumerate(tab, 1)))}</div></aside></div></main>"""
    files["matcher.html"] = page(club, "Matcher", "matcher.html", m_body)

    # --- nyheter
    lst = "".join(f"""<a class="card" href="nyheter/{it['slug']}.html"><div class="top"></div><div class="in">
<span class="tag">{esc(it['tag'])}</span><h3>{esc(it['title'])}</h3><p class="date">{esc(sv_date(it['date']))}</p></div></a>""" for it in items)
    files["nyheter.html"] = page(club, "Nyheter", "nyheter.html",
                                 f"""<section class="page-h"><div class="wrap"><h1>Nyheter</h1><p>Det senaste från {esc(club.name)}</p></div></section>
<main><div class="wrap"><div class="cards">{lst}</div></div></main>""")
    for it in items:
        paras = "".join(f"<p>{esc(p)}</p>" for p in it["paras"])
        files[f"nyheter/{it['slug']}.html"] = page(
            club, it["title"], "nyheter.html",
            f"""<section class="page-h"><div class="wrap"><span class="kicker">{esc(it['tag'])}</span><h1 style="margin-top:12px">{esc(it['title'])}</h1>
<p>{esc(sv_date(it['date']))}</p></div></section><main><div class="wrap"><article>{paras}
<p style="margin-top:32px"><a href="../nyheter.html">← Alla nyheter</a></p></article></div></main>""",
            depth=1, desc=it["paras"][0][:150])

    # --- laget
    blocks = ""
    for pos_name in ("Målvakter", "Försvarare", "Mittfältare", "Anfallare"):
        ps = sorted((p for p in club.squad if p[0] == pos_name), key=lambda p: p[1])
        one = ONE[pos_name]
        cards_p = "".join(f"""<div class="pl"><span class="n">{num}</span><div><strong>{esc(name)}</strong><div class="m">{one} · {age} år</div></div></div>"""
                          for _, num, name, age in ps)
        blocks += f"<h2>{pos_name}</h2><div class=\"squad\">{cards_p}</div>"
    staff = f"""<h2>Ledare</h2><div class="squad">
<div class="pl"><div><strong>{esc(club.coach)}</strong><div class="m">Huvudtränare</div></div></div>
<div class="pl"><div><strong>{esc(club.assistant)}</strong><div class="m">Assisterande tränare</div></div></div>
<div class="pl"><div><strong>{esc(club.manager)}</strong><div class="m">Lagledare</div></div></div></div>"""
    files["laget.html"] = page(club, "Laget", "laget.html",
                               f"""<section class="page-h"><div class="wrap"><h1>A-laget {year}</h1><p>{esc(club.division)}</p></div></section>
<main><div class="wrap prose">{blocks}{staff}</div></main>""")

    # --- föreningen
    f_body = f"""<section class="page-h"><div class="wrap"><h1>Om föreningen</h1><p>{esc(club.name)} · grundad {club.founded}</p></div></section>
<main><div class="wrap grid"><article class="prose">
<p>{esc(club.name)} bildades {club.founded} av en grupp fotbollsintresserade i {esc(club.place)}. Sedan dess har föreningen vuxit till en av ortens största, med omkring {club.members} medlemmar och {club.teams} lag – från knattefotboll till seniorer.</p>
<p>Vår ambition är att erbjuda fotboll för alla, oavsett ålder och nivå. Verksamheten bygger på ideella krafter: ledare, föräldrar och supportrar som lägger ner sin tid för att barn, ungdomar och vuxna ska få spela.</p>
<h2>Hemmaplan</h2>
<p>Våra hemmamatcher spelas på {esc(club.arena)}. Vid matcherna håller kiosken öppet med kaffe, korv och fika – intäkterna går till ungdomsverksamheten.</p>
<h2>Träningstider</h2>
<p>A-laget tränar {club.train_days[0]} och {club.train_days[1]} klockan {club.train_time}. Ungdomslagens tider får du av respektive lagledare.</p>
<h2>Bli medlem</h2>
<p>Medlemsavgiften för {year} är 300 kronor för seniorer, 200 kronor för ungdomar och 600 kronor för familj. Anmäl dig till kansliet, så skickar vi uppgifter för betalning.</p>
</article><aside><div class="box"><h2 style="font-size:18px;margin:0 0 10px">Kontakt</h2>
<p style="margin:0 0 6px"><strong>Kansliet</strong><br><a href="mailto:kansli@{esc(club.mail_domain)}">kansli@{esc(club.mail_domain)}</a></p>
<p style="margin:12px 0 0"><strong>Ordförande</strong><br>{esc(club.chair)}</p>
<p style="margin:12px 0 0"><strong>Huvudtränare</strong><br>{esc(club.coach)}</p></div>
<div class="box" style="text-align:center">{crest_svg(club, 120)}</div></aside></div></main>"""
    files["foreningen.html"] = page(club, "Om föreningen", "foreningen.html", f_body)

    for rel, text in files.items():
        p = out / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text, encoding="utf-8")
    return sorted(files)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[1])
    ap.add_argument("cmd", choices=["build", "name"])
    ap.add_argument("--domain", required=True)
    ap.add_argument("--seed", required=True, type=int)
    ap.add_argument("--date", help="YYYY-MM-DD, по умолчанию сегодня")
    ap.add_argument("--out")
    a = ap.parse_args(argv)
    club = Club(a.domain, a.seed)
    if a.cmd == "name":
        print(club.name)
        return 0
    if not a.out:
        ap.error("для build нужен --out")
    today = dt.date.fromisoformat(a.date) if a.date else dt.date.today()
    for f in build(club, today, Path(a.out)):
        print(f)
    return 0


if __name__ == "__main__":
    sys.exit(main())
