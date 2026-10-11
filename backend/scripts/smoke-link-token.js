import "dotenv/config";

const port = Number(process.env.PORT ?? 8000);

try {
  const response = await fetch(`http://127.0.0.1:${port}/api/link/token/create`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json"
    },
    body: JSON.stringify({
      userId: "local-smoke-test"
    })
  });
  const body = await response.json();

  if (!response.ok) {
    throw new Error(body.error ?? "Link token request failed.");
  }

  console.log(JSON.stringify({
    ok: true,
    linkTokenPrefix: body.linkToken.slice(0, 18),
    expiration: body.expiration,
    requestId: body.requestId
  }, null, 2));
} catch (error) {
  console.error(JSON.stringify({
    ok: false,
    error: error.message
  }, null, 2));
  process.exit(1);
}
