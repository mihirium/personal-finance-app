import crypto from "node:crypto";
import { query } from "./database.js";

export function createUserId(username) {
  const normalizedUsername = normalizeUsername(username);
  const hash = crypto.createHash("sha256").update(normalizedUsername).digest("hex").slice(0, 16);
  return `user_${hash}`;
}

export function normalizeUsername(username) {
  return String(username ?? "").trim().toLowerCase();
}

export function validateUsername(username) {
  const normalizedUsername = normalizeUsername(username);

  if (normalizedUsername.length < 3) {
    return {
      ok: false,
      error: "Username must be at least 3 characters."
    };
  }

  if (!/^[a-z0-9_][a-z0-9_.-]*$/.test(normalizedUsername)) {
    return {
      ok: false,
      error: "Username can only contain letters, numbers, underscores, periods, and hyphens."
    };
  }

  return {
    ok: true,
    username: normalizedUsername
  };
}

export async function signUpUser(username) {
  const validation = validateUsername(username);
  if (!validation.ok) {
    return {
      ok: false,
      status: 400,
      error: validation.error
    };
  }

  const user = {
    user_id: createUserId(validation.username),
    username: validation.username
  };
  try {
    const result = await query(`
      insert into users (user_id, username)
      values ($1, $2)
      returning user_id, username
    `, [user.user_id, user.username]);

    return {
      ok: true,
      user: result.rows[0]
    };
  } catch (error) {
    if (error.code === "23505") {
      return {
        ok: false,
        status: 409,
        error: "That username is already taken."
      };
    }

    throw error;
  }
}

export async function signInUser(username) {
  const validation = validateUsername(username);
  if (!validation.ok) {
    return {
      ok: false,
      status: 400,
      error: validation.error
    };
  }

  const result = await query(
    "select user_id, username from users where username = $1",
    [validation.username]
  );
  const data = result.rows[0];

  if (!data) {
    return {
      ok: false,
      status: 404,
      error: "No account found for that username."
    };
  }

  return {
    ok: true,
    user: data
  };
}
