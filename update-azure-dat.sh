#!/bin/sh
# update-azure-dat.sh - builds a geoip dataset (azure.dat) from Azure Service Tags.
#
# Tag names are uppercased and every run of non-alphanumeric characters is
# replaced by a single dash, prefixed with "AZURE-":
#   AzureCloud          -> AZURE-AZURECLOUD
#   Storage             -> AZURE-STORAGE
#   Sql.WestEurope      -> AZURE-SQL-WESTEUROPE
#
# Examples:
#   ./update-azure-dat.sh                          # all tags -> ./azure.dat
#   ./update-azure-dat.sh --tags 'Sql.*'           # only SQL tags
#   ./update-azure-dat.sh --tags 'Sql.*,Storage.*' # SQL + Storage
#   ./update-azure-dat.sh --file tags.json         # from a local JSON
#   ./update-azure-dat.sh --output /tmp/azure.dat  # explicit output path
set -eu

SOURCE_URL=${SOURCE_URL:-https://download.microsoft.com/download/7/1/D/71D86715-5596-4529-9B13-DA13A5DE5B63/ServiceTags_Public_latest.json}
TAGS=${TAGS:-*}
OUTPUT=${OUTPUT:-azure.dat}
LOCAL_JSON=

usage() {
	cat <<'EOF'
usage: update-azure-dat.sh [options]

  --file PATH        read a local ServiceTags_Public*.json instead of downloading
  --source URL       alternate ServiceTags URL (default: Microsoft)
  --tags LIST        comma-separated glob list: '*' (default), 'Sql.*',
                     'Sql.*,Storage.WestEurope'
  --output PATH      output .dat path (default: ./azure.dat)
  -h, --help         this help

environment: SOURCE_URL, TAGS, OUTPUT
EOF
}

while [ $# -gt 0 ]; do
	case $1 in
	--file) LOCAL_JSON=$2; shift 2 ;;
	--source) SOURCE_URL=$2; shift 2 ;;
	--tags) TAGS=$2; shift 2 ;;
	--output) OUTPUT=$2; shift 2 ;;
	-h | --help) usage; exit 0 ;;
	*) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
	esac
done

TMP=$(mktemp -d "${TMPDIR:-/tmp}/azure-dat.XXXXXX")
trap 'rm -rf "$TMP"' EXIT INT TERM

JSON="$TMP/tags.json"
if [ -n "$LOCAL_JSON" ]; then
	cp "$LOCAL_JSON" "$JSON"
else
	echo "downloading $SOURCE_URL"
	if command -v curl >/dev/null 2>&1; then
		curl -fsSL --max-time 180 "$SOURCE_URL" -o "$JSON"
	elif command -v wget >/dev/null 2>&1; then
		wget -q -O "$JSON" "$SOURCE_URL"
	else
		echo "error: curl or wget is required" >&2
		exit 1
	fi
fi

# --- JSON -> "TAG CIDR" pairs ----------------------------------------------
LC_ALL=C awk -v pat="$TAGS" '
function mktag(n,  t) {
	t = toupper(n)
	gsub(/[^A-Z0-9]+/, "-", t)
	sub(/^-+/, "", t)
	sub(/-+$/, "", t)
	return "AZURE-" t
}
function glob2re(g,  r) {
	r = g
	gsub(/\./, "\\.", r)
	gsub(/\*/, ".*", r)
	gsub(/\?/, ".", r)
	return "^" r "$"
}
BEGIN {
	n = split(pat, pats, ",")
	for (i = 1; i <= n; i++) re[i] = glob2re(pats[i])
}
/^[[:space:]]*"name":/ {
	line = $0
	sub(/.*"name":[[:space:]]*"/, "", line)
	sub(/".*/, "", line)
	want = 0
	for (i = 1; i <= n; i++)
		if (line ~ re[i]) { want = 1; break }
	tag = want ? mktag(line) : ""
	next
}
want && /"addressPrefixes"/ {
	if ($0 ~ /\[[[:space:]]*\]/) { want = 0; next }
	inlist = 1
	next
}
inlist {
	if ($0 ~ /\]/) { inlist = 0; want = 0; next }
	line = $0
	gsub(/[[:space:]",]/, "", line)
	if (line != "")
		print tag "\t" line
}
' "$JSON" | LC_ALL=C sort -u >"$TMP/pairs.txt"

if [ ! -s "$TMP/pairs.txt" ]; then
	echo "error: no Service Tag matched '$TAGS'" >&2
	exit 1
fi

# --- pairs -> protobuf .dat -------------------------------------------------
# GeoIP { string country_code = 1; repeated CIDR cidr = 2; }
# CIDR  { bytes ip = 1; uint32 prefix = 2; }
DAT=$TMP/azure.dat
LC_ALL=C awk -F '\t' '
function put(c) { printf "%c", c }
function putvar(n) { while (n >= 128) { put(n % 128 + 128); n = int(n / 128) } put(n) }
function hex(h,  i, c, v) {
	v = 0
	for (i = 1; i <= length(h); i++) {
		c = index("0123456789abcdef", tolower(substr(h, i, 1))) - 1
		v = v * 16 + c
	}
	return v
}
function put16(g) { v = hex(g); put(int(v / 256)); put(v % 256) }
function put_ip6(a,  left, right, L, R, need, l, r, i) {
	if (match(a, /::/)) {
		left = substr(a, 1, RSTART - 1)
		right = substr(a, RSTART + 2)
	} else {
		left = a
		right = ""
	}
	L = (left == "") ? 0 : split(left, l, ":")
	R = (right == "") ? 0 : split(right, r, ":")
	need = 8 - L - R
	for (i = 1; i <= L; i++) put16(l[i])
	for (i = 0; i < need; i++) { put(0); put(0) }
	for (i = 1; i <= R; i++) put16(r[i])
}
function split_cidr(c,  a, o) {
	split(c, a, "/")
	PREFIX = a[2] + 0
	addrs = a[1]
	if (index(addrs, ":") > 0) { IPLEN = 16; return }
	IPLEN = 4
	split(addrs, o, ".")
	O1 = o[1] + 0; O2 = o[2] + 0; O3 = o[3] + 0; O4 = o[4] + 0
}
function vlen(n) { return n < 128 ? 1 : (n < 16384 ? 2 : 3) }
function reclen(c,  a, l, p) {
	split(c, a, "/")
	l = (index(a[1], ":") > 0 ? 16 : 4)
	p = a[2] + 0
	return 1 + vlen(l + 3 + vlen(p)) + l + 3 + vlen(p)
}
function emit_record(c) {
	split_cidr(c)
	put(18); putvar(IPLEN + 3 + vlen(PREFIX))  # field 2 (cidr), nested length
	put(10); put(IPLEN)                        # field 1 (ip)
	if (IPLEN == 16) put_ip6(addrs)
	else { put(O1); put(O2); put(O3); put(O4) }
	put(16); putvar(PREFIX)                    # field 2 (prefix)
}
function put_header(t) {
	body = 2 + length(t) + bytes[t]
	put(10); putvar(body)       # field 1 (GeoIP), record length
	put(10); put(length(t))     # field 1 (country_code)
	printf "%s", t
}
{
	T[NR] = $1
	C[NR] = $2
}
END {
	for (i = 1; i <= NR; i++) {
		t = T[i]
		if (!(t in bytes)) bytes[t] = 0
		bytes[t] += reclen(C[i])
	}
	cur = ""
	for (i = 1; i <= NR; i++) {
		if (T[i] != cur) { cur = T[i]; put_header(cur) }
		emit_record(C[i])
	}
}
' "$TMP/pairs.txt" >"$DAT"

TAGS_COUNT=$(awk -F '\t' '!seen[$1]++ { n++ } END { print n + 0 }' "$TMP/pairs.txt")
PREFIXES=$(wc -l <"$TMP/pairs.txt")
SIZE=$(wc -c <"$DAT")

if [ -f "$OUTPUT" ] && cmp -s "$DAT" "$OUTPUT" 2>/dev/null; then
	echo "no changes: $OUTPUT (tags $TAGS_COUNT, prefixes $PREFIXES, $SIZE bytes)"
	exit 0
fi

mkdir -p "$(dirname "$OUTPUT")"
cp "$DAT" "$OUTPUT.new"
mv -f "$OUTPUT.new" "$OUTPUT"
echo "built $OUTPUT: tags $TAGS_COUNT, prefixes $PREFIXES, $SIZE bytes"
