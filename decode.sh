#!/bin/bash

if [ -z "$1" ]; then
    echo "Usage: $0 '<string>'"
    exit 1
fi

INPUT="$1"

utf8_bytes() {
    local cp=$1
    if [ "$cp" -le 127 ]; then
        printf "\\$(printf '%03o' "$cp")"
    elif [ "$cp" -le 2047 ]; then
        printf "\\$(printf '%03o' $(( 0xC0 | (cp >> 6) )))\\$(printf '%03o' $(( 0x80 | (cp & 0x3F) )))"
    elif [ "$cp" -le 65535 ]; then
        printf "\\$(printf '%03o' $(( 0xE0 | (cp >> 12) )))\\$(printf '%03o' $(( 0x80 | ((cp >> 6) & 0x3F) )))\\$(printf '%03o' $(( 0x80 | (cp & 0x3F) )))"
    else
        printf "\\$(printf '%03o' $(( 0xF0 | (cp >> 18) )))\\$(printf '%03o' $(( 0x80 | ((cp >> 12) & 0x3F) )))\\$(printf '%03o' $(( 0x80 | ((cp >> 6) & 0x3F) )))\\$(printf '%03o' $(( 0x80 | (cp & 0x3F) )))"
    fi
}

printf "Base64 Decode: "
B64_CLEAN=$(echo -n "$INPUT" | tr -d ' \t\n')
if [[ "$B64_CLEAN" =~ ^[A-Za-z0-9+/]+=?=?$ ]]; then
    echo -n "$B64_CLEAN" | base64 -d 2>/dev/null
fi
echo

printf "Base64 URL-safe Decode: "
B64URL=$(echo -n "$INPUT" | tr -d ' \t\n')
B64URL="${B64URL//-/+}"
B64URL="${B64URL//_//}"
if [[ "$B64URL" =~ ^[A-Za-z0-9+/]+=?=?$ ]]; then
    B64URL_PAD=$(( (4 - ${#B64URL} % 4) % 4 ))
    if [ "$B64URL_PAD" -gt 0 ]; then
        B64URL="${B64URL}$(printf '=%.0s' $(seq 1 "$B64URL_PAD"))"
    fi
    echo -n "$B64URL" | base64 -d 2>/dev/null
fi
echo

printf "Base32 Decode: "
B32_CLEAN=$(echo -n "$INPUT" | tr -d ' \t\n' | tr 'a-z' 'A-Z')
if [[ "$B32_CLEAN" =~ ^[A-Z2-7]+=*$ ]]; then
    echo -n "$B32_CLEAN" | base32 -d 2>/dev/null
fi
echo

printf "Base85 (Z85) Decode: "
if command -v basenc >/dev/null 2>&1; then
    Z85_CLEAN=$(echo -n "$INPUT" | tr -d ' \t\n')
    if [ -n "$Z85_CLEAN" ] && [ $(( ${#Z85_CLEAN} % 5 )) -eq 0 ]; then
        echo -n "$Z85_CLEAN" | basenc --z85 -d 2>/dev/null
    fi
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
[ ${#OCT_TOKENS[@]} -eq 0 ] && OCT_VALID=0
for TOKEN in "${OCT_TOKENS[@]}"; do
    if [[ "$TOKEN" =~ ^[0-7]{1,3}$ ]]; then
        VAL=$((8#$TOKEN))
        if [ "$VAL" -gt 255 ]; then OCT_VALID=0; break; fi
    else
        OCT_VALID=0; break
    fi
done
if [ "$OCT_VALID" -eq 1 ]; then
    for TOKEN in "${OCT_TOKENS[@]}"; do
        printf "\\$(printf '%03o' "$((8#$TOKEN))")"
    done
fi
echo

printf "Decimal Decode: "
read -ra DEC_TOKENS <<< "$INPUT"
DEC_VALID=1
[ ${#DEC_TOKENS[@]} -eq 0 ] && DEC_VALID=0
for TOKEN in "${DEC_TOKENS[@]}"; do
    if [[ "$TOKEN" =~ ^[0-9]{1,3}$ ]]; then
        VAL=$((10#$TOKEN))
        if [ "$VAL" -gt 255 ]; then DEC_VALID=0; break; fi
    else
        DEC_VALID=0; break
    fi
done
if [ "$DEC_VALID" -eq 1 ]; then
    for TOKEN in "${DEC_TOKENS[@]}"; do
        printf "\\$(printf '%03o' "$((10#$TOKEN))")"
    done
fi
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
URL_TMP="${INPUT//\\/\\\\}"
URL_TMP="${URL_TMP//+/ }"
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
    if [ "$HTML_VAL" -le 1114111 ] && ! { [ "$HTML_VAL" -ge 55296 ] && [ "$HTML_VAL" -le 57343 ]; }; then
        HTML_OUT+=$(utf8_bytes "$HTML_VAL")
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
