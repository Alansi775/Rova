#!/bin/bash
# Measures how often İETT actually publishes a new fix, by polling one line
# every 30 s and recording distinct son_konum_zamani values per vehicle.
LINE=${1:-146}
N=${2:-20}
OUT=${3:-/tmp/rova-refresh.jsonl}
URL=https://api.ibb.gov.tr/iett/FiloDurum/SeferGerceklesme.asmx
REQ=$(mktemp)
cat > "$REQ" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/" xmlns:tns="http://tempuri.org/">
<soap:Body><tns:GetHatOtoKonum_json><tns:HatKodu>$LINE</tns:HatKodu></tns:GetHatOtoKonum_json></soap:Body></soap:Envelope>
EOF
: > "$OUT"
for i in $(seq 1 "$N"); do
  body=$(curl -s -m 25 -X POST -H "Content-Type: text/xml; charset=utf-8" \
    -H "SOAPAction: \"http://tempuri.org/GetHatOtoKonum_json\"" \
    --data-binary @"$REQ" "$URL")
  payload=$(printf '%s' "$body" | sed -e 's/.*<GetHatOtoKonum_jsonResult>//' -e 's|</GetHatOtoKonum_jsonResult>.*||')
  printf '{"polled_at":"%s","line":"%s","payload":%s}\n' "$(date -u +%FT%TZ)" "$LINE" "${payload:-null}" >> "$OUT"
  sleep 30
done
