import crypto from "node:crypto";

const algorithm = "aes-256-gcm";
const ivLength = 12;
const keyLength = 32;

export function encryptAccessToken(accessToken) {
  const key = accessTokenEncryptionKey();
  const iv = crypto.randomBytes(ivLength);
  const cipher = crypto.createCipheriv(algorithm, key, iv);
  const encrypted = Buffer.concat([
    cipher.update(String(accessToken), "utf8"),
    cipher.final()
  ]);

  return {
    encryptedAccessToken: encrypted.toString("base64"),
    accessTokenIV: iv.toString("base64"),
    accessTokenAuthTag: cipher.getAuthTag().toString("base64")
  };
}

export function decryptAccessToken({ encryptedAccessToken, accessTokenIV, accessTokenAuthTag }) {
  const key = accessTokenEncryptionKey();
  const decipher = crypto.createDecipheriv(
    algorithm,
    key,
    Buffer.from(accessTokenIV, "base64")
  );
  decipher.setAuthTag(Buffer.from(accessTokenAuthTag, "base64"));

  return Buffer.concat([
    decipher.update(Buffer.from(encryptedAccessToken, "base64")),
    decipher.final()
  ]).toString("utf8");
}

function accessTokenEncryptionKey() {
  const encodedKey = process.env.PLAID_ACCESS_TOKEN_ENCRYPTION_KEY;
  if (!encodedKey) {
    throw new Error("PLAID_ACCESS_TOKEN_ENCRYPTION_KEY must be set.");
  }

  const key = Buffer.from(encodedKey, "base64");
  if (key.length !== keyLength) {
    throw new Error("PLAID_ACCESS_TOKEN_ENCRYPTION_KEY must be a base64-encoded 32-byte key.");
  }

  return key;
}
