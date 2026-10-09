#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d /tmp/revoyage-storage-watcher.XXXXXX)"
WATCHER_PID=""
cleanup() {
    if [[ -n "$WATCHER_PID" ]]; then kill "$WATCHER_PID" >/dev/null 2>&1 || true; fi
    rm -rf "$TMP"
}
trap cleanup EXIT

PAIRING_KEY=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
printf '%s\n' "$PAIRING_KEY" > "$TMP/pairing.key"
chmod 600 "$TMP/pairing.key"

clang -O2 -Wall -Wextra -Wno-unused-parameter -fobjc-arc \
  -arch "$(uname -m)" -mmacosx-version-min=10.15 \
  "$ROOT/StorageWatcher/main.m" \
  "$ROOT/TargetBridge-Receiver/TBReceiverC/src/tb_storage_bridge.m" \
  -framework Foundation -o "$TMP/StorageWatcher"

"$TMP/StorageWatcher" --pairing-key-path "$TMP/pairing.key" \
  >"$TMP/watcher.out.log" 2>"$TMP/watcher.err.log" &
WATCHER_PID=$!

python3 - "$PAIRING_KEY" <<'PY'
import hashlib
import hmac
import json
import socket
import struct
import sys
import time

key = sys.argv[1].encode()

def read_exact(sock, length):
    chunks = bytearray()
    while len(chunks) < length:
        data = sock.recv(length - len(chunks))
        if not data:
            raise RuntimeError("storage watcher closed the connection")
        chunks.extend(data)
    return bytes(chunks)

def read_packet(sock):
    length = struct.unpack("!I", read_exact(sock, 4))[0]
    if not 1 <= length <= 65536:
        raise RuntimeError(f"invalid packet length: {length}")
    packet = read_exact(sock, length)
    return packet[0], packet[1:]

deadline = time.monotonic() + 10
while True:
    try:
        client = socket.create_connection(("127.0.0.1", 54322), timeout=2)
        break
    except OSError:
        if time.monotonic() >= deadline:
            raise
        time.sleep(0.1)

with client:
    client.settimeout(5)
    packet_type, nonce = read_packet(client)
    assert packet_type == 0x41 and len(nonce) == 32, "invalid storage challenge"
    digest = hmac.new(key, nonce + b"ReVoyageStorageMonitorV1", hashlib.sha256).digest()
    auth = bytes([0x42]) + digest
    client.sendall(struct.pack("!I", len(auth)) + auth)
    packet_type, payload = read_packet(client)
    assert packet_type == 0x43, f"expected snapshot, received packet 0x{packet_type:02x}"
    snapshot = json.loads(payload)
    assert snapshot.get("schemaVersion") == 1
    assert isinstance(snapshot.get("volumes"), list) and len(snapshot["volumes"]) <= 32
    print(f"Storage watcher handshake passed; snapshot schema 1 with {len(snapshot['volumes'])} removable volume(s).")
PY
