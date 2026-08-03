#!/bin/bash

# Цвета для вывода
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${YELLOW}>>> Начинаю удаление VSM...${NC}"

TARGET_DIR="/root/VSM"

# 1. Удаление символических ссылок из /usr/local/bin
# Перебором по цели ссылки: поимённый список отставал от install.sh и
# оставлял битые ссылки на menu_xui.sh, menu_telemt.sh, telemt-stack.sh и др.
echo -e "${YELLOW}>>> Удаление системных ссылок...${NC}"
removed=0
for link in /usr/local/bin/*; do
    [ -L "$link" ] || continue
    case "$(readlink -f "$link" 2>/dev/null)" in
        "$TARGET_DIR"/*)
            rm -f "$link"
            echo -e "${GREEN}✓ Ссылка $(basename "$link") удалена${NC}"
            removed=$((removed + 1))
            ;;
    esac
done
# Ссылка могла остаться битой, если каталог репозитория уже удалён
for link in /usr/local/bin/*; do
    [ -L "$link" ] && [ ! -e "$link" ] && rm -f "$link" && \
        echo -e "${GREEN}✓ Битая ссылка $(basename "$link") удалена${NC}" && removed=$((removed + 1))
done
[ "$removed" -eq 0 ] && echo -e "${YELLOW}! Ссылок меню не найдено${NC}"

# 2.1 Telegram-боты живут внутри репозитория — их надо снять до его удаления
if [ -f /etc/systemd/system/3xui-telemt-bot.service ] \
   || [ -f /etc/systemd/system/telemt-bot.service ] \
   || [ -f /etc/systemd/system/3xui-monitor.service ]; then
    echo -e "${YELLOW}>>> Обнаружены установленные Telegram-боты.${NC}"
    echo -e "${RED}    Вместе с репозиторием будут удалены их базы:"
    echo -e "    история подключений по IP и список панелей 3x-ui.${NC}"
    read -p "Остановить и удалить ботов? (y/n): " confirm_bots
    if [[ $confirm_bots == [yY] ]]; then
        for unit in 3xui-telemt-bot telemt-bot 3xui-monitor; do
            systemctl disable --now "$unit" &>/dev/null && echo -e "${GREEN}✓ $unit остановлен${NC}"
            rm -f "/etc/systemd/system/$unit.service"
        done
        systemctl daemon-reload
        rm -f /etc/vsm/bots.conf
        echo -e "${GREEN}✓ Службы ботов и их настройки удалены${NC}"
    else
        echo -e "${YELLOW}! Боты оставлены. Учтите: удаление репозитория ниже${NC}"
        echo -e "${YELLOW}  сломает их — код лежит в $TARGET_DIR/bots.${NC}"
    fi
fi

# 3. Удаление основной директории репозитория
if [ -d "$TARGET_DIR" ]; then
    read -p "Удалить папку репозитория $TARGET_DIR со всеми скриптами? (y/n): " confirm
    if [[ $confirm == [yY] ]]; then
        rm -rf "$TARGET_DIR"
        echo -e "${GREEN}✓ Директория $TARGET_DIR полностью удалена${NC}"
    else
        echo -e "${YELLOW}! Директория сохранена${NC}"
    fi
fi
# 4. Удаление автозапуска из .bashrc
echo -e "${YELLOW}>>> Очистка автозапуска из ~/.bashrc...${NC}"
if grep -q "vsm" ~/.bashrc; then
    # Удаляем строку, содержащую "vsm", и сохраняем во временный файл
    sed -i '/vsm/d' ~/.bashrc
    echo -e "${GREEN}✓ Автозапуск удален из ~/.bashrc${NC}"
else
    echo -e "${YELLOW}! Запись автозапуска не найдена${NC}"
fi

# Бонус: очистка пустых строк, которые могли остаться в конце файла
sed -i '${/^$/d;}' ~/.bashrc
echo -e "${GREEN}======================================================"
echo -e "✅ УДАЛЕНИЕ ЗАВЕРШЕНО"
echo -e "------------------------------------------------------"
echo -e "Система очищена от скриптов меню."
echo -e "======================================================${NC}"
