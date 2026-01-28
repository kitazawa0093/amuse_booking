const admin = require("firebase-admin");
const fs = require("fs");

// ===== 設定 =====
const CSV_PATH = process.argv[2] || "manual.csv";
const COLLECTION = "manual_items";

// Firebase Admin 初期化（ローカル実行用）
// サービスアカウント鍵を使う
const serviceAccount = require("./serviceAccountKey.json");

admin.initializeApp({
  credential: admin.credential.cert(serviceAccount),
});

const db = admin.firestore();

function parseCSV(csvText) {
  const lines = csvText.split(/\r?\n/).filter((l) => l.trim().length > 0);
  const header = lines[0].split(",").map((h) => h.trim());
  const rows = lines.slice(1);

  return rows.map((line) => {
    // 簡易CSV（ダブルクォート対応）
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

    const obj = {};
    header.forEach((key, idx) => {
      obj[key] = (values[idx] ?? "").trim();
    });
    return obj;
  });
}

function normalizeTags(tagsStr) {
  if (!tagsStr) return [];
  return tagsStr
    .split(",")
    .map((t) => t.trim())
    .filter(Boolean);
}

function normalizeBool(v) {
  const s = String(v || "").trim().toLowerCase();
  return s === "true" || s === "1" || s === "yes" || s === "y" || s === "ok";
}

async function main() {
  if (!fs.existsSync(CSV_PATH)) {
    console.error("CSV not found:", CSV_PATH);
    process.exit(1);
  }

  const csvText = fs.readFileSync(CSV_PATH, "utf8");
  const rows = parseCSV(csvText);

  console.log("rows:", rows.length);

  let count = 0;
  const batch = db.batch();

  for (const r of rows) {
    const category = r.category || "";
    const question = r.question || "";
    const answer = r.answer || "";
    const tags = normalizeTags(r.tags || "");
    const is_public = normalizeBool(r.is_public);

    if (!question || !answer) continue;

    // docId は question から作る（同じ質問なら上書きされる）
    const docId = question
      .replace(/\s+/g, "_")
      .replace(/[\/\\#?%*:|"<>]/g, "_")
      .slice(0, 200);

    const ref = db.collection(COLLECTION).doc(docId);

    batch.set(
      ref,
      {
        category,
        question,
        answer,
        tags,
        is_public,
        updated_at: admin.firestore.FieldValue.serverTimestamp(),
      },
      { merge: true }
    );

    count++;
  }

  await batch.commit();
  console.log("Imported:", count);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});

