#!/bin/zsh
# Démarre/arrête une instance Dovecot locale et jetable (sans root, 127.0.0.1 seulement).
#   start_dovecot.sh start [port]   (par défaut 14500)    start_dovecot.sh stop    start_dovecot.sh status
cd "$(dirname "$0")/../.." || exit 1
ROOT="$PWD/.dovecot"
PORT=${2:-14500}
DOVECOT=/opt/homebrew/opt/dovecot/sbin/dovecot
mkdir -p "$ROOT/run" "$ROOT/state" "$ROOT/home" "$ROOT/Maildir"
sed -e "s#@ROOT@#$ROOT#g" -e "s#@USER@#$(id -un)#" -e "s#@GROUP@#$(id -gn)#" \
    -e "s#@UID@#$(id -u)#" -e "s#@GID@#$(id -g)#" -e "s#@PORT@#$PORT#" \
    Fixtures/dovecot/dovecot.conf.in > "$ROOT/dovecot.conf"
case "$1" in
  start)  "$DOVECOT" -c "$ROOT/dovecot.conf" >/dev/null 2>&1 </dev/null && sleep 1 && echo "Dovecot prêt sur 127.0.0.1:$PORT (utilisateur test / mot de passe test)" ;;
  stop)   "$DOVECOT" -c "$ROOT/dovecot.conf" stop && echo "Dovecot arrêté" ;;
  status) pgrep -fl "dovecot.*$ROOT" || echo "arrêté" ;;
  *) echo "usage: $0 start [port] | stop | status"; exit 2 ;;
esac
