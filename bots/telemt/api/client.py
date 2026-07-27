import httpx
from typing import Optional, Dict, Any, List
from config import settings

class TelemtAPIError(Exception):
    def __init__(self, status_code: int, error_data: dict):
        self.status_code = status_code
        self.error_data = error_data
        super().__init__(f"API error {status_code}: {error_data.get('error', {}).get('message', 'Unknown')}")

class TelemtAPIClient:
    _instance = None
    _client = None

    def __new__(cls, *args, **kwargs):
        if cls._instance is None:
            cls._instance = super().__new__(cls)
            cls._instance.base_url = settings.TELEMT_API_URL.rstrip("/")
            cls._instance.headers = {}
            if settings.TELEMT_API_KEY:
                cls._instance.headers["Authorization"] = settings.TELEMT_API_KEY
        return cls._instance

    @property
    def client(self) -> httpx.AsyncClient:
        if TelemtAPIClient._client is None or TelemtAPIClient._client.is_closed:
            TelemtAPIClient._client = httpx.AsyncClient(timeout=30.0)
        return TelemtAPIClient._client

    async def _request(self, method: str, path: str, **kwargs) -> dict:
        url = f"{self.base_url}{path}"
        try:
            response = await self.client.request(method, url, headers=self.headers, **kwargs)
            data = response.json()
            if response.status_code >= 400:
                raise TelemtAPIError(response.status_code, data)
            return data
        except httpx.HTTPError as e:
            raise TelemtAPIError(0, {"error": {"message": str(e)}})

    async def close(self):
        if TelemtAPIClient._client and not TelemtAPIClient._client.is_closed:
            await TelemtAPIClient._client.aclose()

    async def health(self) -> dict: return await self._request("GET", "/v1/health")
    async def system_info(self) -> dict: return await self._request("GET", "/v1/system/info")
    async def summary(self) -> dict: return await self._request("GET", "/v1/stats/summary")
    
    async def users(self) -> List[dict]:
        resp = await self._request("GET", "/v1/users")
        return resp.get("data", [])

    async def get_user(self, username: str) -> dict: return await self._request("GET", f"/v1/users/{username}")
    async def create_user(self, payload: dict) -> dict: return await self._request("POST", "/v1/users", json=payload)
    async def patch_user(self, username: str, payload: dict) -> dict: return await self._request("PATCH", f"/v1/users/{username}", json=payload)
    async def delete_user(self, username: str) -> dict: return await self._request("DELETE", f"/v1/users/{username}")
    async def me_writers(self) -> dict: return await self._request("GET", "/v1/stats/me-writers")
    async def dcs(self) -> dict: return await self._request("GET", "/v1/stats/dcs")
    async def upstreams(self) -> dict: return await self._request("GET", "/v1/stats/upstreams")
    async def minimal_all(self) -> dict: return await self._request("GET", "/v1/stats/minimal/all")
    async def zero_all(self) -> dict: return await self._request("GET", "/v1/stats/zero/all")
    async def runtime_gates(self) -> dict: return await self._request("GET", "/v1/runtime/gates")
    async def runtime_initialization(self) -> dict: return await self._request("GET", "/v1/runtime/initialization")
    async def runtime_me_pool_state(self) -> dict: return await self._request("GET", "/v1/runtime/me_pool_state")
    async def runtime_me_quality(self) -> dict: return await self._request("GET", "/v1/runtime/me_quality")
