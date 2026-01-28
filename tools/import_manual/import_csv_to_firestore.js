/**
 * CSV（category,question,answer,tags,is_public）を
 * Firestore manual_items に一括登録する（tagsは配列）
 *
 * tags は "ビアポン,料金,システム" のようにカンマ区切り
 *
 * 使い方：
 *   node import_csv_to_firestore.js ../../manual.csv
 *
 * 事前準備：
 *   - tools/import_manual/serviceAccountKey.json を配置
 *   - npm install firebase-admin
 */

const admin = require("firebase-admin");
const fs = require("fs");
const path = require("path");

// ===== 設定 =====
const COLLECTION = "manual_items";
const SERVICE_ACCOUNT_PATH = path.join(__dirname, "serviceAccountKey.json");

// CSVパス（引数優先）
const DEFAULT_CSV_PATH = path.join(__dirname, "../../manual.csv");
const CSV_PATH = process.argv[2]
  ? path.resolve(process.argv[2])
  : DEFAULT_CSV_PATH;

// ===== Firebase Admin 初期化 =====
if (!fs.existsSync(SERVICE_ACCOUNT_PATH)) {
  console.error("❌ serviceAccountKey.json が見つかりません:", SERVICE_ACCOUNT_PATH);
  process.exit(1);
}

const serviceAccount = require(SERVICE_ACCOUNT_PATH);

admin.initializeApp({
  credential: admin.credential.cert(serviceAccount),
});

const db = admin.firestore();

// ===== CSV パース（ダブルクォート対応）=====
function parseCSVLine(line) {
  const values = [];
  let current = "";
  let inQuotes = false;

  for (let i = 0; i < line.length; i++) {
    const ch = line[i];

    if (ch === '"' && line[i + 1] === '"') {
      current += '"';
      i++;
      continue;
    }

    if (ch === '"') {
      inQuotes = !inQuotes;
      continue;
    }

    if (ch === "," && !inQuotes) {
      values.push(current);
      current = "";
      continue;
    }

    current += ch;
  }

  values.push(current);
  return values.map((v) => v.trim());
}

function parseCSV(text) {
  const lines = text.split(/\r?\n/).filter((l) => l.trim().length > 0);
  if (lines.length <= 1) return [];

  const headers = parseCSVLine(lines[0]).map((h) => h.trim());
  const rows = lines.slice(1);

  return rows.map((line) => {
    const cols = parseCSVLine(line);
    const obj = {};
    headers.forEach((h, i) => {
      obj[h] = (cols[i] ?? "").trim();
    });
    return obj;
  });
}

// ===== 正規化 =====

// tags: "ビアポン,料金,システム"
function normalizeTags(tagsStr) {
  if (!tagsStr) return [];
  return [...new Set(
    tagsStr
      .split(/[,\|、]/) // 半角カンマ / | / 日本語読点 全対応
      .map((t) => t.trim())
      .filter(Boolean)
  )];
}

// is_public は TRUE/FALSE, true/false, 1/0 等対応
function normalizeBool(v) {
  const s = String(v || "").trim().toLowerCase();
  return s === "true" || s === "1" || s === "yes" || s === "y" || s === "ok";
}

// docId は question ベース（上書き可能）
function makeDocId(question) {
  return String(question || "")
    .trim()
    .replace(/\s+/g, "_")
    .replace(/[\/\\#?%*:|"<>]/g, "_")
    .slice(0, 200);
}

// ===== メイン処理 =====
async function main() {
  if (!fs.existsSync(CSV_PATH)) {
    console.error("❌ CSV が見つかりません:", CSV_PATH);
    process.exit(1);
  }

  console.log("CSV:", CSV_PATH);

  const csvText = fs.readFileSync(CSV_PATH, "utf8");
  const rows = parseCSV(csvText);

  console.log("rows:", rows.length);

  const batchSize = 450;
  let imported = 0;
  let skipped = 0;

  for (let i = 0; i < rows.length; i += batchSize) {
    const batch = db.batch();
    const chunk = rows.slice(i, i + batchSize);

    for (const r of chunk) {
      const category = r.category || "";
      const question = r.question || "";
      const answer = r.answer || "";
      const tags = normalizeTags(r.tags || "");
      const is_public = normalizeBool(r.is_public);

      if (!question || !answer) {
        skipped++;
        continue;
      }

      const docId = makeDocId(question);
      const ref = db.collection(COLLECTION).doc(docId);

      batch.set(
        ref,
        {
          category,
          question,
          answer,
          tags, // ← ★ 配列でそのまま保存
          is_public,
          updated_at: admin.firestore.FieldValue.serverTimestamp(),
        },
        { merge: true }
      );

      imported++;
    }

    await batch.commit();
    console.log(`✅ committed ${Math.min(i + batchSize, rows.length)}/${rows.length}`);
  }

  console.log("🎉 DONE");
  console.log("Imported:", imported);
  console.log("Skipped:", skipped);
}

main().catch((e) => {
  console.error("❌ import failed:", e);
  process.exit(1);
});
