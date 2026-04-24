#!/bin/sh
set -eu
CFG="$XDG_CONFIG_HOME/pianobar/config"
FIFO=$(grep '^fifo = ' "$CFG" | head -n1 | sed 's/^fifo = //')
EVT=$(grep '^event_command = ' "$CFG" | head -n1 | sed 's/^event_command = //')

fire() {
  evt=$1
  body=$2
  printf '%s' "$body" | "$EVT" "$evt"
}

fire userlogin "pRet=1
pRetStr=OK
wRet=0
wRetStr=OK"

fire usergetstations "station0=Radio A
stationId0=111
station1=Radio B
stationId1=222
pRet=1
wRet=0"

fire songstart "title=Song1
artist=Artist1
album=Album1
songDuration=180
rating=0
stationName=Radio A
pRet=1
wRet=0"

while IFS= read -r cmd < "$FIFO"; do
  case "$cmd" in
    q) exit 0 ;;
    +) fire songlove "pRet=1
wRet=0" ;;
    -) fire songban "pRet=1
wRet=0" ;;
    n) fire songfinish ""
       fire songstart "title=Song2
artist=Artist2
album=Album2
songDuration=200
rating=0
stationName=Radio A
pRet=1
wRet=0" ;;
    s*) idx=${cmd#s}
        case "$idx" in
          0) name="Radio A" ;;
          *) name="Radio B" ;;
        esac
        fire songstart "title=NewSong
artist=NewArtist
album=NewAlbum
songDuration=120
rating=0
stationName=$name
pRet=1
wRet=0" ;;
    *) : ;;
  esac
done
