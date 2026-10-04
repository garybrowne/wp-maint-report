#!/bin/bash
# wp-report.sh - monthly WordPress update report using WP-CLI
#
# Usage:
#   wp-report.sh snapshot   Save the current versions as the baseline
#   wp-report.sh report     Compare the baseline with now (changes nothing)
#   wp-report.sh rollover   Report on last month, save it, start a new baseline
#                           (run this one from cron on the 1st of each month)

set -euo pipefail

# --- Settings: change WP_PATH to your site ----------------------------------
WP_PATH="$HOME/www/example.com/public_html"
REPORT_DIR="$HOME/wp-reports"
# -----------------------------------------------------------------------------

export PATH="$PATH:/usr/local/bin:/usr/bin"
WP="wp --path=$WP_PATH --skip-plugins --skip-themes"
BASELINE="$REPORT_DIR/baseline.tsv"

mkdir -p "$REPORT_DIR/archive"
chmod 700 "$REPORT_DIR"

# Convert WP-CLI JSON into: type <tab> slug <tab> title <tab> version
to_tsv() {
  php -r '
    $type = $argv[1];
    $items = json_decode(stream_get_contents(STDIN), true) ?: [];
    foreach ($items as $i) {
      $title = trim(html_entity_decode(strip_tags($i["title"] ?? $i["name"])));
      if ($title === "") $title = $i["name"];
      echo "$type\t{$i["name"]}\t$title\t{$i["version"]}\n";
    }' "$1"
}

take_snapshot() {
  printf 'core\twordpress\tWordPress\t%s\n' "$($WP core version)"
  $WP plugin list --fields=name,title,version --format=json | to_tsv plugin
  $WP theme list --fields=name,title,version --format=json | to_tsv theme
}

# Compare two snapshots ($1 = old, $2 = new) and print the report
compare() {
  awk -F'\t' '
    NR == FNR { k = $1 FS $2; ov[k] = $4; ot[k] = $3; oty[k] = $1; oord[++on] = k; next }
              { k = $1 FS $2; nv[k] = $4; nt[k] = $3; nty[k] = $1; nord[++nn] = k }
    END {
      split("core plugin theme", types, " ")
      split("WordPress|Plugins|Themes", heads, "|")
      for (t = 1; t <= 3; t++) {
        print heads[t]; c = 0
        for (i = 1; i <= nn; i++) {
          k = nord[i]; if (nty[k] != types[t]) continue
          if (!(k in ov))          { print nt[k] " - newly installed (v" nv[k] ")"; added++; c++ }
          else if (ov[k] != nv[k]) { print nt[k] " - v" ov[k] " → v" nv[k]; updated++; c++ }
        }
        for (i = 1; i <= on; i++) {
          k = oord[i]; if (oty[k] != types[t]) continue
          if (!(k in nv)) { print ot[k] " - removed (was v" ov[k] ")"; removed++; c++ }
        }
        if (!c) print "No updates"
        print ""
      }
      printf "Total: %d updated, %d installed, %d removed\n", updated, added, removed
    }' "$1" "$2"
}

need_baseline() {
  if [ ! -f "$BASELINE" ]; then
    echo "No baseline yet. Run: $0 snapshot" >&2
    exit 1
  fi
}

TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

case "${1:-report}" in
  snapshot)
    take_snapshot > "$TMP"
    cp "$TMP" "$BASELINE"
    echo "Baseline saved to $BASELINE"
    ;;
  report)
    need_baseline
    take_snapshot > "$TMP"
    compare "$BASELINE" "$TMP"
    ;;
  rollover)
    need_baseline
    take_snapshot > "$TMP"
    MONTH_LABEL=$(date -d yesterday '+%B %Y')
    MONTH_FILE=$(date -d yesterday '+%Y-%m')
    REPORT="$REPORT_DIR/report-$MONTH_FILE.txt"
    { echo "Update report: $MONTH_LABEL"; echo; compare "$BASELINE" "$TMP"; } > "$REPORT"
    cp "$BASELINE" "$REPORT_DIR/archive/baseline-$MONTH_FILE.tsv"
    cp "$TMP" "$BASELINE"
    cat "$REPORT"
    ;;
  *)
    echo "Usage: $0 {snapshot|report|rollover}" >&2
    exit 1
    ;;
esac
