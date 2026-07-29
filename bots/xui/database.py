# database.py
import aiosqlite

from config import settings

# Общий каталог данных: объединённый и отдельный боты работают с одной базой,
# поэтому переключение между ними не теряет список панелей.
DB_NAME = settings.PANELS_DB

async def init_db():
    # Схема повторяет то, что реально лежит в боевой базе: там есть id, а имя
    # объявлено UNIQUE, а не PRIMARY KEY. IF NOT EXISTS на живой базе не
    # срабатывает, так что раньше расхождение не мешало — но свежая установка
    # получала таблицу, отличную от прода.
    async with aiosqlite.connect(DB_NAME) as db:
        await db.execute('''
            CREATE TABLE IF NOT EXISTS panels (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT UNIQUE NOT NULL,
                base_url TEXT NOT NULL,
                token TEXT NOT NULL,
                expiry_date TEXT
            )
        ''')
        await db.commit()

async def get_all_panels():
    async with aiosqlite.connect(DB_NAME) as db:
        async with db.execute('SELECT name, base_url, token, expiry_date FROM panels') as cursor:
            rows = await cursor.fetchall()

    panels = {}
    for row in rows:
        panels[row[0]] = {"base_url": row[1], "token": row[2], "expiry_date": row[3]}
    return panels

async def add_new_panel(name, base_url, token, expiry_date):
    async with aiosqlite.connect(DB_NAME) as db:
        try:
            await db.execute(
                'INSERT INTO panels (name, base_url, token, expiry_date) VALUES (?, ?, ?, ?)',
                (name, base_url, token, expiry_date)
            )
            await db.commit()
            return True
        except aiosqlite.IntegrityError:
            return False

async def update_panel_expiry(name, expiry_date):
    # Возвращает bool, а не None: пока в одной админской сессии открыт
    # календарь, панель могли удалить из другой — вызывающий должен это увидеть.
    async with aiosqlite.connect(DB_NAME) as db:
        cursor = await db.execute(
            'UPDATE panels SET expiry_date = ? WHERE name = ?', (expiry_date, name)
        )
        await db.commit()
        return cursor.rowcount > 0

async def delete_panel_by_name(name):
    async with aiosqlite.connect(DB_NAME) as db:
        cursor = await db.execute('DELETE FROM panels WHERE name = ?', (name,))
        await db.commit()
        return cursor.rowcount > 0
