import "dotenv/config";

const summary = {
  hasClientId: Boolean(process.env.PLAID_CLIENT_ID),
  hasSecret: Boolean(process.env.PLAID_SECRET),
  hasDatabaseUrl: Boolean(process.env.DATABASE_URL),
  hasAccessTokenEncryptionKey: Boolean(process.env.PLAID_ACCESS_TOKEN_ENCRYPTION_KEY),
  plaidEnv: process.env.PLAID_ENV ?? "sandbox",
  port: Number(process.env.PORT ?? 8000)
};

console.log(JSON.stringify(summary, null, 2));

if (
  !summary.hasClientId
  || !summary.hasSecret
  || !summary.hasDatabaseUrl
  || !summary.hasAccessTokenEncryptionKey
) {
  process.exitCode = 1;
}
