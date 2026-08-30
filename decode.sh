#!/bin/bash

if [ -z "$1" ]; then
    echo "Usage: $0 '<string>'"
    exit 1
fi

INPUT="$1"

printf "Base64 Decode: "
echo -n "$INPUT" | base64 -d 2>/dev/null
echo

printf "Base64 URL-safe Decode: "
B64URL="${INPUT//-/+}"
B64URL="${B64URL//_//}"
B64URL_PAD=$(( (4 - ${#B64URL} % 4) % 4 ))
if [ "$B64URL_PAD" -gt 0 ]; then
    B64URL="${B64URL}$(printf '=%.0s' $(seq 1 "$B64URL_PAD"))"
fi
echo -n "$B64URL" | base64 -d 2>/dev/null
echo

printf "Base32 Decode: "
echo -n "$INPUT" | base32 -d 2>/dev/null
echo

printf "Base85 (Z85) Decode: "
if command -v basenc >/dev/null 2>&1; then
    echo -n "$INPUT" | basenc --z85 -d 2>/dev/null
fi
echo

printf "Hexadecimal Decode: "
HEX_CLEAN=$(echo -n "$INPUT" | tr -d ' \t')
if [[ "$HEX_CLEAN" =~ ^[0-9A-Fa-f]+$ ]] && [ -n "$HEX_CLEAN" ] && [ $(( ${#HEX_CLEAN} % 2 )) -eq 0 ]; then
    for (( i=0; i<${#HEX_CLEAN}; i+=2 )); do
        BYTE="${HEX_CLEAN:i:2}"
        printf "\\$(printf '%03o' "$((16#$BYTE))")"
    done
fi
echo

printf "Octal Decode: "
read -ra OCT_TOKENS <<< "$INPUT"
OCT_VALID=1
OCT_OUT=""
[ ${#OCT_TOKENS[@]} -eq 0 ] && OCT_VALID=0
for TOKEN in "${OCT_TOKENS[@]}"; do
    if [[ "$TOKEN" =~ ^[0-7]{1,3}$ ]]; then
        VAL=$((8#$TOKEN))
        if [ "$VAL" -gt 255 ]; then OCT_VALID=0; break; fi
        OCT_OUT+=$(printf "\\$(printf '%03o' "$VAL")")
    else
        OCT_VALID=0; break
    fi
done
[ "$OCT_VALID" -eq 1 ] && [ -n "$OCT_OUT" ] && printf '%s' "$OCT_OUT"
echo

printf "Decimal Decode: "
read -ra DEC_TOKENS <<< "$INPUT"
DEC_VALID=1
DEC_OUT=""
[ ${#DEC_TOKENS[@]} -eq 0 ] && DEC_VALID=0
for TOKEN in "${DEC_TOKENS[@]}"; do
    if [[ "$TOKEN" =~ ^[0-9]{1,3}$ ]]; then
        VAL=$((10#$TOKEN))
        if [ "$VAL" -gt 255 ]; then DEC_VALID=0; break; fi
        DEC_OUT+=$(printf "\\$(printf '%03o' "$VAL")")
    else
        DEC_VALID=0; break
    fi
done
[ "$DEC_VALID" -eq 1 ] && [ -n "$DEC_OUT" ] && printf '%s' "$DEC_OUT"
echo

printf "Binary Decode: "
BIN_CLEAN=$(echo -n "$INPUT" | tr -d ' \t')
if [[ "$BIN_CLEAN" =~ ^[01]+$ ]] && [ -n "$BIN_CLEAN" ] && [ $(( ${#BIN_CLEAN} % 8 )) -eq 0 ]; then
    for (( i=0; i<${#BIN_CLEAN}; i+=8 )); do
        BYTE="${BIN_CLEAN:i:8}"
        printf "\\$(printf '%03o' "$((2#$BYTE))")"
    done
fi
echo

printf "URL Decode: "
URL_TMP="${INPUT//+/ }"
printf '%b' "${URL_TMP//%/\\x}"
echo

printf "ROT13 Decode: "
echo -n "$INPUT" | tr 'A-Za-z' 'N-ZA-Mn-za-m'
echo

printf "ROT47 Decode: "
echo -n "$INPUT" | tr '!-~' 'P-~!-O'
echo

printf "Atbash Decode: "
echo -n "$INPUT" | tr 'A-Za-z' 'ZYXWVUTSRQPONMLKJIHGFEDCBAzyxwvutsrqponmlkjihgfedcba'
echo

printf "HTML Entity Decode: "
HTML_NAMED=$(echo -n "$INPUT" | sed \
    -e 's/&lt;/</g' \
    -e 's/&gt;/>/g' \
    -e 's/&quot;/"/g' \
    -e "s/&apos;/'/g" \
    -e 's/&nbsp;/ /g' \
    -e 's/&copy;/(c)/g' \
    -e 's/&reg;/(r)/g' \
    -e 's/&trade;/(tm)/g' \
    -e 's/&hellip;/.../g' \
    -e 's/&mdash;/—/g' \
    -e 's/&ndash;/–/g')
HTML_S="$HTML_NAMED"
HTML_OUT=""
while [[ "$HTML_S" =~ \&#(x[0-9A-Fa-f]+|X[0-9A-Fa-f]+|[0-9]+)\; ]]; do
    HTML_MATCH="${BASH_REMATCH[0]}"
    HTML_CODE="${BASH_REMATCH[1]}"
    HTML_OUT+="${HTML_S%%"$HTML_MATCH"*}"
    if [[ "$HTML_CODE" == x* || "$HTML_CODE" == X* ]]; then
        HTML_VAL=$((16#${HTML_CODE:1}))
    else
        HTML_VAL=$((10#$HTML_CODE))
    fi
    if [ "$HTML_VAL" -le 255 ]; then
        HTML_OUT+=$(printf "\\$(printf '%03o' "$HTML_VAL")")
    else
        HTML_OUT+="&#${HTML_CODE};"
    fi
    HTML_S="${HTML_S#*"$HTML_MATCH"}"
done
HTML_OUT+="$HTML_S"
HTML_OUT="${HTML_OUT//&amp;/\&}"
printf '%s' "$HTML_OUT"
echo

echo "--- All 25 Caesar/ROT Shifts ---"
ALPHA_UPPER="ABCDEFGHIJKLMNOPQRSTUVWXYZ"
ALPHA_LOWER="abcdefghijklmnopqrstuvwxyz"
for SHIFT in $(seq 1 25); do
    UP_SHIFTED="${ALPHA_UPPER:SHIFT}${ALPHA_UPPER:0:SHIFT}"
    LOW_SHIFTED="${ALPHA_LOWER:SHIFT}${ALPHA_LOWER:0:SHIFT}"
    RESULT=$(echo -n "$INPUT" | tr "${ALPHA_UPPER}${ALPHA_LOWER}" "${UP_SHIFTED}${LOW_SHIFTED}")
    printf "  Shift %2d: %s\n" "$SHIFT" "$RESULT"
done
