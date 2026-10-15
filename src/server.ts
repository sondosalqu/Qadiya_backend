import express from "express";

const app = express();

app.get("/api/health", (_req, res) => {
  res.json({ status: "ok", time: new Date().toISOString() });
});

app.listen(4000, () => {
  console.log("🔎 QADIYA API running on http://localhost:4000/api/health");
});