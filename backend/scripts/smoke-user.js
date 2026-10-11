import "dotenv/config";

const port = Number(process.env.PORT ?? 8000);
const username = `smoke_${Date.now()}`;

try {
  const created = await post("/api/users/sign-up", { username });
  const signedIn = await post("/api/users/sign-in", { username });

  console.log(JSON.stringify({
    ok: true,
    username,
    userId: created.user.user_id,
    signInReturnedSameUser: created.user.user_id === signedIn.user.user_id
  }, null, 2));
} catch (error) {
  console.error(JSON.stringify({
    ok: false,
    error: error.message
  }, null, 2));
  process.exit(1);
}

async function post(path, body) {
  const response = await fetch(`http://127.0.0.1:${port}${path}`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json"
    },
    body: JSON.stringify(body)
  });
  const responseBody = await response.json();

  if (!response.ok) {
    throw new Error(responseBody.error ?? `${path} failed.`);
  }

  return responseBody;
}
