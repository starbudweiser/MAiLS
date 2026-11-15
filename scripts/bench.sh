#!/bin/zsh
# Banc d'essai reproductible du moteur : serveur local (100 000 messages) + synchro + requêtes.
# Usage : ./bench.sh [nombre_de_messages]   (par défaut 100000)
set -e
cd "$(dirname "$0")/.."
N=${1:-100000}
PORT=$((20000 + RANDOM % 10000))
DIR=$(mktemp -d)
DB="$DIR/bench.db"
B=.build/release/mails-bench

swift build -c release >/dev/null
python3 -I Fixtures/fake_imap_server.py --port $PORT --messages $N --log "$DIR/commandes.log" >"$DIR/serveur.out" 2>&1 &
SERVER=$!
trap 'kill $SERVER 2>/dev/null; rm -rf "$DIR"' EXIT
sleep 2

admin() { printf 'a LOGIN test test\r\nb SELECT INBOX\r\nc %s\r\nd LOGOUT\r\n' "$1" | nc -w 2 127.0.0.1 $PORT >/dev/null; }

echo "=== Synchro initiale ($N messages) ==="; $B sync --port $PORT --db "$DB" 2>/dev/null
echo; echo "=== Liste et recherche ===";        $B latest --port $PORT --db "$DB"; $B search --port $PORT --db "$DB"
echo; echo "=== Resynchro sans changement ===";  $B sync --port $PORT --db "$DB" 2>/dev/null | grep -E "nouveaux|durée"
echo; echo "=== +50 messages, 1 lu, 1 supprimé ==="
admin "XADD 50"; admin "XFLAG $((N - 10)) \\Seen"; admin "XEXPUNGE $((N - 9))"
$B sync --port $PORT --db "$DB" 2>/dev/null | grep -E "nouveaux|supprimés|fenêtres|durée"
echo; echo "=== Corps d'un message ===";          $B body --port $PORT --uid $((N - 1000)) | head -1
echo; echo "=== IDLE ==="; ( sleep 1.5; admin "XADD 1" ) & TRIGGER=$!; $B idle --port $PORT; wait $TRIGGER
echo; echo "=== Commandes vues par le serveur (le moteur n'émet que EXAMINE ; SELECT vient des commandes d'essai) ==="
sort "$DIR/commandes.log" | uniq -c | sort -rn
