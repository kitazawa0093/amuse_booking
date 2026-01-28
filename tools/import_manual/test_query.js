const admin = require("firebase-admin");
const serviceAccount = require("./serviceAccountKey.json");

admin.initializeApp({
  credential: admin.credential.cert(serviceAccount),
});

const db = admin.firestore();

async function test() {
  const snap = await db
    .collection("manual_items")
    .where("tags", "array-contains", "システム")
    .get();

  console.log("hit:", snap.size);

  snap.forEach(doc => {
    console.log(doc.id, doc.data().tags);
  });
}

test();
