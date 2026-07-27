import asyncio
import threading
import geoip2.database
from pathlib import Path
from typing import Optional, Dict, Any
from config import settings

_city_reader = None
_asn_reader = None
_lock = asyncio.Lock()
_reader_init_lock = threading.Lock()  # для безопасной ленивой инициализации из sync-потоков (asyncio.to_thread)

def _open_city_reader():
    path = Path(settings.GEOIP_CITY_DB)
    if path.is_file():
        return geoip2.database.Reader(str(path))
    raise FileNotFoundError(f"City DB not found: {path}")

def _open_asn_reader():
    path = Path(settings.GEOIP_ASN_DB)
    if path.is_file():
        return geoip2.database.Reader(str(path))
    raise FileNotFoundError(f"ASN DB not found: {path}")

def get_geoip_readers():
    """
    Возвращает общие кэшированные ридеры (city, asn), открывая их при первом
    обращении. Безопасно вызывать как из async-кода, так и из синхронных
    функций, выполняемых через asyncio.to_thread — используется единый
    threading.Lock, а не asyncio.Lock (тот не защищает от гонки между потоками).
    Позволяет reports.py и map.py переиспользовать эти же ридеры вместо
    открытия собственных копий тех же .mmdb файлов.
    """
    global _city_reader, _asn_reader
    if _city_reader is None or _asn_reader is None:
        with _reader_init_lock:
            if _city_reader is None:
                try:
                    _city_reader = _open_city_reader()
                except Exception:
                    pass
            if _asn_reader is None:
                try:
                    _asn_reader = _open_asn_reader()
                except Exception:
                    pass
    return _city_reader, _asn_reader

def country_flag(code: str) -> str:
    if not code or len(code) != 2:
        return ''
    offset = ord('🇦') - ord('A')
    return chr(ord(code[0]) + offset) + chr(ord(code[1]) + offset)

async def get_ip_info(ip: str, lang: str = 'en') -> Optional[Dict[str, Any]]:
    global _city_reader, _asn_reader
    async with _lock:
        try:
            if _city_reader is None or _asn_reader is None:
                get_geoip_readers()

            # --- City ---
            try:
                city_resp = _city_reader.city(ip)
                country_code = city_resp.country.iso_code
                country = city_resp.country.name or '—'
                city = city_resp.city.name or ''
                lat = city_resp.location.latitude
                lon = city_resp.location.longitude
            except Exception:
                try:
                    _city_reader.close()
                except Exception:
                    pass
                _city_reader = _open_city_reader()
                try:
                    city_resp = _city_reader.city(ip)
                    country_code = city_resp.country.iso_code
                    country = city_resp.country.name or '—'
                    city = city_resp.city.name or ''
                    lat = city_resp.location.latitude
                    lon = city_resp.location.longitude
                except Exception:
                    country_code = ''
                    country = '—'
                    city = ''
                    lat = None
                    lon = None

            # --- ASN ---
            as_number = None
            as_org = ''
            try:
                asn_resp = _asn_reader.asn(ip)
                as_number = asn_resp.autonomous_system_number
                as_org = asn_resp.autonomous_system_organization or ''
                asn = f"AS{as_number}" if as_number else '—'
                isp = as_org
            except Exception:
                try:
                    _asn_reader.close()
                except Exception:
                    pass
                _asn_reader = _open_asn_reader()
                try:
                    asn_resp = _asn_reader.asn(ip)
                    as_number = asn_resp.autonomous_system_number
                    as_org = asn_resp.autonomous_system_organization or ''
                    asn = f"AS{as_number}" if as_number else '—'
                    isp = as_org
                except Exception:
                    asn = '—'
                    isp = ''

            if not country_code and not as_number:
                return None

            return {
                'query': ip,
                'country': country,
                'countryCode': country_code,
                'city': city,
                'as': f"AS{as_number} {as_org}" if as_number else '—',
                'isp': isp,
                'asn': asn,
                'lat': lat,
                'lon': lon,
            }
        except Exception:
            return None
