import { onRequest } from "firebase-functions/v2/https";

export const helloWorld = onRequest((req, res) => {
  res.send("Default functions OK");
});
