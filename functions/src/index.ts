import {onCall, onRequest} from "firebase-functions/v2/https";
import * as logger from "firebase-functions/logger";
import Stripe from "stripe";

import * as admin from "firebase-admin";
import * as crypto from "crypto";
declare const fetch: any;

admin.initializeApp();
const db = admin.firestore();


export const createBeerpongPayment = onCall(
  {
    secrets: ["STRIPE_SECRET_KEY"],
  },
  async (request) => {
    logger.info("createBeerpongPayment called");

    // 認証チェック
    if (!request.auth) {
      logger.error("Unauthenticated request");
      throw new Error("ログインが必要です");
    }

    // Secret存在チェック（値は出さない）
    logger.info("STRIPE_SECRET_KEY exists:", {
      exists: !!process.env.STRIPE_SECRET_KEY,
    });

    if (!process.env.STRIPE_SECRET_KEY) {
      logger.error("STRIPE_SECRET_KEY is missing");
      throw new Error("決済設定が未完了です");
    }

    // Stripe初期化
    const stripe = new Stripe(process.env.STRIPE_SECRET_KEY);


    // 🔥重要：Stripeアカウント確認（世界ズレ検知）
    try {
      const account = await stripe.accounts.retrieve();

      // emailは型に無い場合があるので、unknown→Record経由で安全に取る
      const accountObj = account as unknown as Record<string, unknown>;
      const email =
  typeof accountObj["email"] === "string" ? accountObj["email"] : null;

      logger.info("Stripe account info", {
        id: account.id,
        email,
      });
    } catch (e) {
      logger.warn("Could not retrieve Stripe account info", e as Error);
    }

    const {peopleCount} = request.data;
    logger.info("peopleCount", {peopleCount});

    if (typeof peopleCount !== "number" || peopleCount <= 0) {
      throw new Error("人数を正しく指定してください");
    }

    const amount = peopleCount * 700;

    try {
      const paymentIntent = await stripe.paymentIntents.create({
        amount,
        currency: "jpy",

        // ✅ PaymentSheetと相性が良い
        automatic_payment_methods: {enabled: true},

        metadata: {
          uid: request.auth.uid,
          type: "beerpong",
        },
      });

      logger.info("PaymentIntent created", {
        id: paymentIntent.id,
        hasClientSecret: !!paymentIntent.client_secret,
      });

      // 🔥存在確認（これが通ればIntentはStripe上に存在する）
      const check = await stripe.paymentIntents.retrieve(paymentIntent.id);
      logger.info("PaymentIntent retrieve OK", {
        id: check.id,
        status: check.status,
      });

      return {
        clientSecret: paymentIntent.client_secret,
      };
    } catch (error) {
      logger.error("Stripe error", error as Error);
      throw new Error("決済作成中にエラーが発生しました");
    }
  }
);


// ===== LINE Webhook =====
const LINE_SECRET = process.env.LINE_SECRET || "";
const LINE_TOKEN = process.env.LINE_TOKEN || "";

/**
 * LINE署名検証
 * @param {Buffer} rawBody リクエストの生Body（署名検証に使用）
 * @param {string} signature x-line-signature ヘッダー値
 * @return {boolean} 署名が正しければ true
 */
function validateLineSignature(rawBody: Buffer, signature: string): boolean {
  const hash = crypto
    .createHmac("sha256", LINE_SECRET)
    .update(rawBody)
    .digest("base64");
  return hash === signature;
}

/**
 * LINEへ返信を送る
 * @param {string} replyToken LINEのreplyToken
 * @param {string} text 返信メッセージ本文
 * @return {Promise<void>} なし
 */
async function replyMessage(replyToken: string, text: string) {
  const res = await fetch("https://api.line.me/v2/bot/message/reply", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "Authorization": `Bearer ${LINE_TOKEN}`,
    },
    body: JSON.stringify({
      replyToken,
      messages: [{type: "text", text}],
    }),
  });

  if (!res.ok) {
    const body = await res.text();
    logger.error("LINE reply error", {status: res.status, body});
  }
}

export const lineWebhook = onRequest(
  {region: "us-central1"},
  async (req, res) => {
    try {
      const signature = req.headers["x-line-signature"] as string | undefined;
      if (!signature) {
        res.status(400).send("Missing signature");
        return;
      }

      if (!LINE_SECRET || !LINE_TOKEN) {
        res.status(500).send("Missing LINE env");
        return;
      }

      const rawBody = Buffer.isBuffer(req.rawBody) ?
        req.rawBody :
        Buffer.from(JSON.stringify(req.body));

      if (!validateLineSignature(rawBody, signature)) {
        res.status(401).send("Invalid signature");
        return;
      }

      const events = req.body?.events ?? [];

      for (const event of events) {
        if (event.type !== "message") continue;
        if (event.message?.type !== "text") continue;

        const text: string = (event.message.text ?? "").trim();

        const candidates = [
          "ビアポン",
          "ダーツ",
          "料金",
          "延長",
          "会計",
          "泥酔",
          "トラブル",
          "ルール",
          "予約",
        ];
        const matched = candidates.find((t) => text.includes(t));

        let reply =
        "該当するマニュアルが見つかりませんでした。店長に確認してください🙏";

        if (matched) {
          const snap = await db
            .collection("manual_items")
            .where("is_public", "==", true)
            .where("tags", "array-contains", matched)
            .limit(1)
            .get();

          if (!snap.empty) {
            const doc = snap.docs[0].data() as any;
            reply = `【${doc.category ?? "マニュアル"}】\n${doc.answer ?? ""}`;
          }
        }

        await replyMessage(event.replyToken, reply);
      }

      res.status(200).send("OK");
    } catch (e) {
      logger.error(e);
      res.status(500).send("Error");
    }
  }
);


