#!/bin/bash

# ======================================================
# NETWORK & INFRASTRUCTURE OBSERVABILITY PLATFORM
# Automated Backup Script - Zabbix 7.0 + Grafana
# ======================================================

# Colors for terminal output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

show_splash() {
    clear
    echo -e "${PURPLE}"
    echo "███████╗ █████╗ ██████╗ ██████╗ ██╗██╗   ██╗"
    echo "╚══███╔╝██╔══██╗██╔══██╗██╔══██╗██║╚██╗ ██╔╝"
    echo "  ███╔╝ ███████║██████╔╝██████╔╝██║ ╚████╔╝ "
    echo " ███╔╝  ██╔══██║██╔══██╗██╔══██╗██║  ╚██╔╝  "
    echo "███████╗██║  ██║██████╔╝██████╔╝██║   ██║   "
    echo "╚══════╝╚═╝  ╚═╝╚═════╝ ╚═════╝ ╚═╝   ╚═╝   "
    echo -e "${NC}"
    echo -e "${CYAN}========================================================${NC}"
    echo -e "         ${YELLOW}📡 OBSERVABILITY PLATFORM BACKUP SYSTEM${NC}"
    echo -e "         ${YELLOW}🔧 Infrastructure & Monitoring Ops${NC}"
    echo -e "${CYAN}========================================================${NC}"
    echo ""
    sleep 1
}

show_splash

# ======================================================
# CONFIGURATIONS
# ======================================================
BACKUP_DIR="/var/backups/zabbix_grafana"
DATE=$(date +%Y-%m-%d)
BACKUP_PATH="$BACKUP_DIR/bkp_$DATE"
ZABBIX_DIRS="/etc/zabbix /usr/share/zabbix /usr/lib/zabbix /var/log/zabbix"
GRAFANA_DIRS="/etc/grafana /var/lib/grafana /usr/share/grafana"
GRAFANA_DB_SQLITE="/var/lib/grafana/grafana.db"
GRAFANA_API_KEY_FILE="/etc/grafana/api_key"
GRAFANA_URL="http://localhost:3000"

# Root check
if [ "$(id -u)" != "0" ]; then
    echo -e "${RED}❌ Error: This script must be run as root.${NC}"
    exit 1
fi

# Dependency check
for cmd in jq curl tar gzip mysqldump; do
    if ! command -v $cmd &> /dev/null; then
        echo -e "${RED}❌ Error: Dependency '$cmd' not found. Please install it first.${NC}"
        exit 1
    fi
done

# Create backup directory
mkdir -p "$BACKUP_PATH" || { echo -e "${RED}❌ Failed to create backup directory.${NC}"; exit 1; }
chmod 700 "$BACKUP_PATH"

# ======================================================
# DATABASE BACKUP FUNCTION
# ======================================================
backup_database() {
    local db_type=$1 db_user=$2 db_pass=$3 db_name=$4 db_host=$5
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local file="$BACKUP_PATH/${db_type}_db_${timestamp}.sql.gz"
    local min_size=50000

    echo -e "\n🔍 Starting $db_type database backup..."

    if [ "$db_type" == "zabbix" ]; then
        if ! MYSQL_PWD="$db_pass" mysql -h "$db_host" -u "$db_user" -e "USE $db_name" 2>/dev/null; then
            echo -e "${RED}❌ Could not connect to Zabbix Database.${NC}"
            return 1
        fi

        local mysql_version=$(MYSQL_PWD="$db_pass" mysql -h "$db_host" -u "$db_user" -e "SELECT VERSION()" -s 2>/dev/null)
        local extra_opts=""
        [[ "$mysql_version" == *"MariaDB"* || "$mysql_version" =~ 8\.0 ]] && extra_opts="--column-statistics=0"

        if ! MYSQL_PWD="$db_pass" mysqldump -h "$db_host" -u "$db_user" \
            --single-transaction --routines --triggers --events \
            --default-character-set=utf8mb4 --no-tablespaces $extra_opts \
            "$db_name" | gzip > "$file"; then
            echo -e "${RED}❌ Failed to dump Zabbix database.${NC}"
            rm -f "$file"
            return 1
        fi

        [ $(wc -c < "$file") -lt "$min_size" ] && { echo -e "${RED}❌ Backup file is below expected size limits.${NC}"; rm -f "$file"; return 1; }
        echo -e "${GREEN}✅ Zabbix DB backup created: $file ($(du -h "$file" | cut -f1))${NC}"

    elif [ "$db_type" == "grafana" ]; then
        [ ! -f "$GRAFANA_DB_SQLITE" ] && { echo -e "${YELLOW}ℹ️ Grafana SQLite database not found. Skipping.${NC}"; return 0; }

        local grafana_file="$BACKUP_PATH/grafana_db_${timestamp}.sqlite3.gz"
        gzip -c "$GRAFANA_DB_SQLITE" > "$grafana_file"
        [ $(wc -c < "$grafana_file") -lt 1000 ] && { echo -e "${RED}❌ Grafana DB backup failed.${NC}"; rm -f "$grafana_file"; return 1; }
        echo -e "${GREEN}✅ Grafana DB backup created: $grafana_file${NC}"
    fi

    return 0
}

# ======================================================
# GRAFANA API & DASHBOARD EXPORT FUNCTIONS
# ======================================================
criar_api_key_grafana() {
    echo -e "\n🔑 Generating Grafana API Service Account Token..."
    read -p "Grafana Admin User: " GRAFANA_USER
    read -s -p "Grafana Admin Password: " GRAFANA_PASS
    echo ""

    if ! curl -s -u "$GRAFANA_USER:$GRAFANA_PASS" -f "$GRAFANA_URL/api/user/preferences" &> /dev/null; then
        echo -e "${RED}❌ Invalid credentials or Grafana is unreachable.${NC}"
        return 1
    fi

    SA_ID=$(curl -s -u "$GRAFANA_USER:$GRAFANA_PASS" "$GRAFANA_URL/api/serviceaccounts/search" \
            | jq -r '.serviceAccounts[] | select(.name=="backup-script") | .id')

    [ -z "$SA_ID" ] && SA_ID=$(curl -s -u "$GRAFANA_USER:$GRAFANA_PASS" \
        -H "Content-Type: application/json" \
        -d '{"name":"backup-script","role":"Admin"}' \
        "$GRAFANA_URL/api/serviceaccounts" | jq -r '.id')

    TOKEN_NAME="token-backup"
    TOKEN_ID=$(curl -s -u "$GRAFANA_USER:$GRAFANA_PASS" "$GRAFANA_URL/api/serviceaccounts/$SA_ID/tokens" \
        | jq -r --arg TOKEN_NAME "$TOKEN_NAME" '.[] | select(.name==$TOKEN_NAME) | .id')

    [ -n "$TOKEN_ID" ] && curl -s -u "$GRAFANA_USER:$GRAFANA_PASS" -X DELETE "$GRAFANA_URL/api/serviceaccounts/$SA_ID/tokens/$TOKEN_ID" &>/dev/null

    API_KEY=$(curl -s -u "$GRAFANA_USER:$GRAFANA_PASS" \
        -H "Content-Type: application/json" \
        -d '{"name":"'"$TOKEN_NAME"'"}' \
        "$GRAFANA_URL/api/serviceaccounts/$SA_ID/tokens" | jq -r '.key')

    [ -z "$API_KEY" ] && { echo -e "${RED}❌ Failed to generate API token.${NC}"; return 1; }
    echo "$API_KEY" > "$GRAFANA_API_KEY_FILE"
    chmod 600 "$GRAFANA_API_KEY_FILE"
    echo -e "${GREEN}✅ API Token created at: $GRAFANA_API_KEY_FILE${NC}"
}

exportar_dashboards() {
    local API_KEY=$1
    TEMP_DIR=$(mktemp -d)
    DASHBOARDS=$(curl -s -H "Authorization: Bearer $API_KEY" "$GRAFANA_URL/api/search?type=dash-db")
    COUNT=0
    for uid in $(echo "$DASHBOARDS" | jq -r '.[].uid'); do
        dash_json=$(curl -s -H "Authorization: Bearer $API_KEY" "$GRAFANA_URL/api/dashboards/uid/$uid")
        title=$(echo "$dash_json" | jq -r '.dashboard.title' | tr ' ' '_' | tr '/' '-')
        echo "$dash_json" > "$TEMP_DIR/${title}.json"
        ((COUNT++))
    done
    [ $COUNT -gt 0 ] && tar -czf "$BACKUP_PATH/grafana_dashboards_$DATE.tar.gz" -C "$TEMP_DIR" .
    rm -rf "$TEMP_DIR"
    echo -e "${GREEN}✅ $COUNT Grafana dashboards exported successfully.${NC}"
}

# ======================================================
# BACKUP EXECUTION
# ======================================================
echo -e "\n🔧 Infrastructure Observability Backup"
echo "📂 Backup Target Path: $BACKUP_PATH"

# ZABBIX BACKUP
echo -e "\n🔵 Processing Zabbix Database..."
read -p "Zabbix DB User: " ZABBIX_DB_USER
read -s -p "Zabbix DB Password: " ZABBIX_DB_PASS
echo ""
backup_database "zabbix" "$ZABBIX_DB_USER" "$ZABBIX_DB_PASS" "zabbix" "localhost"
tar -czf "$BACKUP_PATH/zabbix_dirs_$DATE.tar.gz" $ZABBIX_DIRS 2>/dev/null && echo -e "${GREEN}✅ Zabbix configurations compressed.${NC}"

# GRAFANA BACKUP
read -p "Include Grafana Backup? (y/n): " INCLUIR_GRAFANA
if [[ "$INCLUIR_GRAFANA" =~ [yY|sS] ]]; then
    [ ! -f "$GRAFANA_API_KEY_FILE" ] && criar_api_key_grafana
    backup_database "grafana" "" "" "" ""
    tar -czf "$BACKUP_PATH/grafana_dirs_$DATE.tar.gz" $GRAFANA_DIRS 2>/dev/null && echo -e "${GREEN}✅ Grafana configurations compressed.${NC}"
    [ -f "$GRAFANA_API_KEY_FILE" ] && exportar_dashboards "$(cat $GRAFANA_API_KEY_FILE)"
fi

# SUMMARY
echo -e "\n📋 Backup Summary:"
echo "================================="
du -sh "$BACKUP_PATH"/*
echo -e "\n✅ Backup completed at: $BACKUP_PATH"
echo "================================="
