import { createApp } from "./app.js";
import { env } from "./config/env.js";

const app = createApp();

app.listen(env.PORT, () => {
  console.log(`🔎 QADIYA API running on http://localhost:${env.PORT}/api/health`);
});