// SPDX-License-Identifier: Apache-2.0
import { readFileSync } from "node:fs";
import http from "node:http";
import https from "node:https";
import net from "node:net";

const [certificatePath, keyPath] = process.argv.slice(2);
if (!certificatePath || !keyPath) {
  throw new Error("usage: node tls_proxy.mjs CERTIFICATE KEY");
}

const upstreamHost = "127.0.0.1";
const upstreamPort = 18082;
const upstreamAuthority = `localhost:${upstreamPort}`;

const server = https.createServer(
  {
    cert: readFileSync(certificatePath),
    key: readFileSync(keyPath),
  },
  (request, response) => {
    const upstream = http.request(
      {
        host: upstreamHost,
        port: upstreamPort,
        method: request.method,
        path: request.url,
        headers: { ...request.headers, host: upstreamAuthority },
        agent: false,
      },
      (upstreamResponse) => {
        response.writeHead(
          upstreamResponse.statusCode ?? 502,
          upstreamResponse.statusMessage,
          upstreamResponse.rawHeaders,
        );
        upstreamResponse.pipe(response);
      },
    );
    upstream.on("error", (error) => response.destroy(error));
    request.on("aborted", () => upstream.destroy());
    response.on("close", () => upstream.destroy());
    request.pipe(upstream);
  },
);

server.on("upgrade", (request, client, head) => {
  const upstream = net.connect(upstreamPort, upstreamHost);
  upstream.once("connect", () => {
    const headers = [];
    for (let index = 0; index < request.rawHeaders.length; index += 2) {
      const name = request.rawHeaders[index];
      const value = name.toLowerCase() === "host"
        ? upstreamAuthority
        : request.rawHeaders[index + 1];
      headers.push(`${name}: ${value}`);
    }
    upstream.write(
      `${request.method} ${request.url} HTTP/${request.httpVersion}\r\n${headers.join("\r\n")}\r\n\r\n`,
    );
    if (head.length > 0) upstream.write(head);
    client.pipe(upstream).pipe(client);
  });
  upstream.on("error", () => client.destroy());
  upstream.on("close", () => client.destroy());
  client.on("error", () => upstream.destroy());
  client.on("close", () => upstream.destroy());
});

const clients = new Set();
server.on("connection", (socket) => {
  clients.add(socket);
  socket.on("close", () => clients.delete(socket));
});

const shutdown = () => {
  for (const client of clients) client.destroy();
  server.closeAllConnections();
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(0), 1_000).unref();
};
process.on("SIGINT", shutdown);
process.on("SIGTERM", shutdown);
server.listen(18443, "127.0.0.1");
