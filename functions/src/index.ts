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

export const createPayPayPayment = onCall(
  {
    secrets: ["PAYPAY_API_KEY", "PAYPAY_API_SECRET", "PAYPAY_MERCHANT_ID"],
  },
  async (request) => {
    logger.info("createPayPayPayment called");

    if (!request.auth) {
      throw new Error("ログインが必要です");
    }

    if (
      !process.env.PAYPAY_API_KEY ||
      !process.env.PAYPAY_API_SECRET ||
      !process.env.PAYPAY_MERCHANT_ID
    ) {
      logger.error("PayPay secrets missing");
      throw new Error("PayPay決済の設定が未完了です");
    }

    const apiKey = process.env.PAYPAY_API_KEY;
    const apiSecret = process.env.PAYPAY_API_SECRET;
    const merchantId = process.env.PAYPAY_MERCHANT_ID;

    const { amount, orderId } = request.data;
    if (typeof amount !== "number" || amount <= 0) {
      throw new Error("金額が不正です");
    }

    const merchantPaymentId =
      typeof orderId === "string" && orderId ? orderId : crypto.randomUUID();

    const payload = {
      merchantPaymentId,
      amount: { amount, currency: "JPY" },
      codeType: "ORDER_QR",
      redirectUrl: "https://example.com/complete",
    };

    const nonce = crypto.randomUUID();
    const timestamp = Date.now().toString();
    const body = JSON.stringify(payload);

    const signature = crypto
      .createHmac("sha256", apiSecret)
      .update(timestamp + "\n" + nonce + "\n" + body + "\n")
      .digest("base64");

    const headers: Record<string, string> = {
      "Content-Type": "application/json",
      "X-ASSUME-MERCHANT": merchantId,
      "X-PAYPAY-API-KEY": apiKey,
      "X-PAYPAY-NONCE": nonce,
      "X-PAYPAY-TIMESTAMP": timestamp,
      "X-PAYPAY-SIGNATURE": signature,
    };

    try {
      const res = await fetch("https://stg-api.paypay.ne.jp/v2/codes", {
        method: "POST",
        headers,
        body,
      });

      const json = (await res.json()) as {
        resultInfo?: { code?: string };
        data?: { url?: string; codeId?: string };
      };

      if (!res.ok) {
        logger.error("PayPay API error", { status: res.status, json });
        throw new Error("PayPay決済作成に失敗しました");
      }

      const url = json.data?.url;
      if (!url) {
        logger.error("PayPay response missing url", json);
        throw new Error("PayPay決済作成に失敗しました");
      }

      logger.info("PayPay QR created", { codeId: json.data?.codeId });

      return { url };
    } catch (e) {
      if (e instanceof Error && e.message.startsWith("PayPay")) throw e;
      logger.error("PayPay error", e);
      throw new Error("PayPay決済作成に失敗しました");
    }
  }
);

// ===== LINE Webhook =====
function validateLineSignature(rawBody: Buffer, signature: string): boolean {
  const hash = crypto
    .createHmac("sha256", process.env.LINE_SECRET!)
    .update(rawBody)
    .digest("base64");
  return hash === signature;
}

async function replyMessage(replyToken: string, text: string) {
  const res = await fetch("https://api.line.me/v2/bot/message/reply", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "Authorization": `Bearer ${process.env.LINE_TOKEN}`,
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
  {
    region: "us-central1",
    secrets: ["LINE_SECRET", "LINE_TOKEN"],
  },
  async (req, res) => {
    try {
      const signature = req.headers["x-line-signature"] as string | undefined;
      if (!signature) {
        res.status(400).send("Missing signature");
        return;
      }

      const rawBody = Buffer.isBuffer(req.rawBody)
        ? req.rawBody
        : Buffer.from(JSON.stringify(req.body));

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
          "ビアポン","ダーツ","料金","延長","会計",
          "泥酔","トラブル","ルール","予約",
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

export const confirmPayPayPayment = onCall(
  {
    secrets: ["PAYPAY_API_KEY", "PAYPAY_API_SECRET", "PAYPAY_MERCHANT_ID"],
  },
  async (request) => {
    if (!request.auth) throw new Error("ログインが必要です");

    const { orderId } = request.data;
    if (!orderId) throw new Error("orderId missing");

    const bookingRef = db.collection("bookings").doc(orderId);
    const bookingSnap = await bookingRef.get();

    if (!bookingSnap.exists) throw new Error("予約が存在しません");

    const booking = bookingSnap.data();

    if (booking?.uid !== request.auth.uid) {
      throw new Error("不正なアクセス");
    }

    if (booking?.paymentStatus === "paid") {
      return { success: true };
    }

    const apiKey = process.env.PAYPAY_API_KEY!;
    const apiSecret = process.env.PAYPAY_API_SECRET!;
    const merchantId = process.env.PAYPAY_MERCHANT_ID!;

    const nonce = crypto.randomUUID();
    const timestamp = Date.now().toString();
    const body = "";

    const signature = crypto
      .createHmac("sha256", apiSecret)
      .update(timestamp + "\n" + nonce + "\n" + body + "\n")
      .digest("base64");

    const headers = {
      "X-ASSUME-MERCHANT": merchantId,
      "X-PAYPAY-API-KEY": apiKey,
      "X-PAYPAY-NONCE": nonce,
      "X-PAYPAY-TIMESTAMP": timestamp,
      "X-PAYPAY-SIGNATURE": signature,
    };

    const res = await fetch(
      `https://stg-api.paypay.ne.jp/v2/codes/payments/${orderId}`,
      { method: "GET", headers }
    );

    const json = await res.json();

    if (!res.ok) {
      logger.error("PayPay confirm error", json);
      throw new Error("支払い確認失敗");
    }

    if (json.data?.status !== "COMPLETED") {
      throw new Error("まだ支払いが完了していません");
    }

    // =========================
    // ⏰ ここが超重要
    // =========================

    const now = new Date();

    const lastSnapshot = await db
      .collection("bookings")
      .where("type", "==", "beerpong")
      .where("paymentStatus", "==", "paid")
      .orderBy("endAt", "desc")
      .limit(1)
      .get();

    let startAt = now;
    if (!lastSnapshot.empty) {
      const lastEnd = lastSnapshot.docs[0].data().endAt?.toDate();
      if (lastEnd && lastEnd > now) startAt = lastEnd;
    }

    const endAt = new Date(startAt.getTime() + 30 * 60000);

    // 🟢 確定
    await bookingRef.update({
      paymentStatus: "paid",
      paidAt: admin.firestore.FieldValue.serverTimestamp(),
      startAt,
      endAt,
    });

    logger.info("PayPay payment confirmed", { orderId });

    return { success: true };
  }
);

