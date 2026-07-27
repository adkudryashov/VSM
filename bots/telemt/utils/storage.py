import aiosqlite
from datetime import datetime, timedelta, timezone

from config import settings

DB_PATH = settings.IP_HISTORY_DB

async def init_db():
    async with aiosqlite.connect(DB_PATH) as db:
        await db.execute("""
            CREATE TABLE IF NOT EXISTS ip_log (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                username TEXT NOT NULL,
                ip TEXT NOT NULL,
                first_seen TEXT NOT NULL,
                last_seen TEXT NOT NULL,
                count INTEGER DEFAULT 1
            )
        """)
        await db.execute("""
            CREATE UNIQUE INDEX IF NOT EXISTS idx_user_ip 
            ON ip_log(username, ip)
        """)
        await db.commit()

async def bulk_save_ips(user_ips: list[tuple[str, str]]):
    """Массовое обновление IP адресов за одну транзакцию."""
    if not user_ips:
        return
        
    now = datetime.now(timezone.utc).isoformat(timespec='minutes')
    # Подготавливаем данные: (username, ip, first_seen, last_seen)
    data = [(u, ip, now, now) for u, ip in user_ips]
    
    async with aiosqlite.connect(DB_PATH) as db:
        # Требует SQLite 3.24+ (ON CONFLICT)
        await db.executemany("""
            INSERT INTO ip_log (username, ip, first_seen, last_seen, count)
            VALUES (?, ?, ?, ?, 1)
            ON CONFLICT(username, ip) DO UPDATE SET
                last_seen = excluded.last_seen,
                count = ip_log.count + 1
        """, data)
        await db.commit()

async def get_all_ips_by_user():
    result = {}
    async with aiosqlite.connect(DB_PATH) as db:
        cursor = await db.execute(
            "SELECT username, ip, first_seen, last_seen, count FROM ip_log ORDER BY username, first_seen DESC"
        )
        rows = await cursor.fetchall()
        for username, ip, first, last, cnt in rows:
            result.setdefault(username, []).append((ip, first, last, cnt))
    return result

async def get_ips_by_username(username: str) -> list:
    async with aiosqlite.connect(DB_PATH) as db:
        cursor = await db.execute(
            "SELECT ip, first_seen, last_seen, count FROM ip_log WHERE username=? ORDER BY count DESC",
            (username,)
        )
        return await cursor.fetchall()

async def cleanup_old_ips(retention_hours: int) -> int:
    """
    Удаляет записи об IP, которые не были активны дольше retention_hours.
    Возвращает количество удалённых строк.

    retention_hours <= 0 отключает очистку: история хранится бессрочно.
    """
    if retention_hours <= 0:
        return 0

    cutoff = (datetime.now(timezone.utc) - timedelta(hours=retention_hours)).isoformat(timespec='minutes')
    async with aiosqlite.connect(DB_PATH) as db:
        cursor = await db.execute("DELETE FROM ip_log WHERE last_seen < ?", (cutoff,))
        await db.commit()
        return cursor.rowcount
