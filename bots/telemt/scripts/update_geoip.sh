#!/bin/bash
# Путь считается от расположения скрипта, чтобы не зависеть от места установки
GEOIP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/geoip"
mkdir -p $GEOIP_DIR
echo "Начало обновления баз GeoIP..."
wget -O $GEOIP_DIR/GeoLite2-ASN.mmdb https://git.io/GeoLite2-ASN.mmdb
wget -O $GEOIP_DIR/GeoLite2-City.mmdb https://git.io/GeoLite2-City.mmdb
wget -O $GEOIP_DIR/GeoLite2-Country.mmdb https://git.io/GeoLite2-Country.mmdb
echo "Обновление завершено."
