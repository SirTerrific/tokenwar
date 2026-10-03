#!/usr/bin/env bats

setup() {
    REPORT_DIR="$BATS_TEST_DIRNAME/../study-usecase"
    REPORT="$REPORT_DIR/index.html"
}

@test "study-usecase publishes the role-based agent stack report" {
    [ -f "$REPORT" ]
    grep -q "Oui, prenez les trois" "$REPORT"
    grep -q "Agent de code" "$REPORT"
    grep -q "Agent d’architecture" "$REPORT"
    grep -q "Agent DevOps / SRE" "$REPORT"
    grep -q "Claude‑mem" "$REPORT"
}

@test "study-usecase ships every relative evidence link" {
    # node rather than python3: node is already a hard dependency, while a stock
    # Windows box has only the python3 alias that opens the Microsoft Store.
    REPORT_PATH="$(cd "$REPORT_DIR" && pwd -W 2>/dev/null || pwd)/index.html" node -e '
const fs = require("fs"), path = require("path");
const report = process.env.REPORT_PATH;
const html = fs.readFileSync(report, "utf8");
const missing = [];
for (const m of html.matchAll(/\bhref\s*=\s*(?:"([^"]*)"|\x27([^\x27]*)\x27)/gi)) {
    const href = (m[1] ?? m[2]).replace(/&amp;/g, "&");
    if (/^(#|https?:\/\/|mailto:)/.test(href)) continue;
    const target = decodeURIComponent(href.split("#")[0]);
    if (target && !fs.existsSync(path.join(path.dirname(report), target))) missing.push(href);
}
if (missing.length) { console.error("missing evidence links: " + missing.join(", ")); process.exit(1); }
'
}

@test "study-usecase source-code evidence uses immutable GitHub commits" {
    ! grep -Eq 'href="(graphify|serena|openwiki)/' "$REPORT"
    grep -q "Graphify-Labs/graphify/blob/33362d969292b57eda82f3fbd9eb5f3f5bc9bbc2" "$REPORT"
    grep -q "oraios/serena/blob/801a388c2b7a6a8998f313291678b1609664e794" "$REPORT"
    grep -q "langchain-ai/openwiki/blob/5c69350c757f3361360de26fc170e1aab6843bbc" "$REPORT"
}
