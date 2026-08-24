let source = null;
let historyController = null;
let topicGeneration = 0;
let pushConfig = null;
let pushTopics = [];

function readTopics() {
  try {
    const value = JSON.parse(localStorage.getItem("notify-push-topics") || "[]");
    return Array.isArray(value) ? value.filter((topic) => typeof topic === "string") : [];
  } catch (_) {
    return [];
  }
}

function errorText(body, status) {
  return body?.detail || body?.error || `HTTP ${status}`;
}

async function responseBody(response) {
  try {
    return await response.json();
  } catch (_) {
    return {};
  }
}

function csrfHeaders(csrf) {
  return csrf ? { "x-csrf-token": csrf } : {};
}

function pushState(topic, status = "") {
  const available = Boolean(
    pushConfig?.enable_web_push &&
      "serviceWorker" in navigator &&
      "PushManager" in window &&
      "Notification" in window,
  );
  return [available, Boolean(topic && pushTopics.includes(topic)), status];
}

export function bootstrap(onReady, onSession, onPush, onNotification) {
  pushTopics = readTopics();
  const language = localStorage.getItem("notify-language") === "ja" ? "ja" : "en";
  const theme = localStorage.getItem("notify-theme") || "";
  document.documentElement.dataset.theme = theme;
  const topic = new URL(window.location.href).searchParams.get("topic") || "";
  onReady(language, topic);

  fetch("/api/v1/session")
    .then(async (response) => {
      if (!response.ok) return;
      const body = await responseBody(response);
      if (typeof body.username === "string" && typeof body.csrf_token === "string") {
        onSession(body.username, body.csrf_token);
      }
    })
    .catch(() => {});

  fetch("/v1/config")
    .then(async (response) => {
      if (response.ok) pushConfig = await responseBody(response);
      onPush(...pushState(topic));
    })
    .catch(() => onPush(false, false, ""));

  if ("serviceWorker" in navigator) {
    navigator.serviceWorker.register("/sw.js").catch(() => {});
  }

  if ("BroadcastChannel" in window) {
    const channel = new BroadcastChannel("notify-webpush");
    channel.addEventListener("message", ({ data }) => {
      if (data?.event === "message" && data.message) {
        onNotification(JSON.stringify(data.message));
      }
    });
  }

  document.addEventListener("keydown", (event) => {
    const activeTag = document.activeElement?.tagName || "";
    if (event.key === "/" && !/INPUT|TEXTAREA|SELECT/.test(activeTag)) {
      event.preventDefault();
      document.querySelector("#topic")?.focus();
    }
    if (event.ctrlKey && event.key === "Enter" && activeTag === "TEXTAREA") {
      event.preventDefault();
      document.activeElement?.closest("form")?.requestSubmit();
    }
  });
}

export function open_topic(topic, onHistory, onNotification, onConnection, onPush) {
  const generation = ++topicGeneration;
  source?.close();
  historyController?.abort();
  source = null;
  historyController = new AbortController();
  onConnection("connecting");
  onPush(...pushState(topic));

  const encoded = encodeURIComponent(topic);
  fetch(`/${encoded}/json?poll=1`, { signal: historyController.signal })
    .then(async (response) => {
      if (generation !== topicGeneration) return;
      if (!response.ok) {
        const body = await responseBody(response);
        onConnection("offline");
        onHistory("");
        throw new Error(errorText(body, response.status));
      }

      const payload = await response.text();
      if (generation !== topicGeneration) return;
      onHistory(payload);

      const messages = payload
        .trim()
        .split("\n")
        .filter(Boolean)
        .map((line) => {
          try {
            return JSON.parse(line);
          } catch (_) {
            return null;
          }
        })
        .filter(Boolean);
      const last = messages.at(-1)?.id;
      const cursor = last || "all";
      const nextSource = new EventSource(
        `/${encoded}/sse?since=${encodeURIComponent(cursor)}`,
      );
      source = nextSource;
      nextSource.onopen = () => {
        if (generation === topicGeneration) onConnection("live");
      };
      nextSource.onerror = () => {
        if (generation === topicGeneration) onConnection("reconnecting");
      };
      nextSource.onmessage = ({ data }) => {
        if (generation === topicGeneration) onNotification(data);
      };
      window.history.replaceState(null, "", `/?topic=${encoded}`);
    })
    .catch((error) => {
      if (error?.name !== "AbortError" && generation === topicGeneration) {
        onConnection("offline");
      }
    });
}

export function publish(
  topic,
  message,
  title,
  priority,
  tags,
  csrf,
  onComplete,
) {
  const fileInput = document.querySelector("#attachment");
  const file = fileInput?.files?.[0];
  const parameters = new URLSearchParams();
  if (title) parameters.set("title", title);
  if (priority && priority !== "default") parameters.set("priority", priority);
  if (tags) parameters.set("tags", tags);
  if (file) {
    parameters.set("filename", file.name);
    parameters.set("message", message);
  }
  const query = parameters.size ? `?${parameters}` : "";
  const headers = { ...csrfHeaders(csrf) };
  if (file) headers["content-type"] = file.type || "application/octet-stream";

  fetch(`/${encodeURIComponent(topic)}${query}`, {
    method: "POST",
    headers,
    body: file || message,
  })
    .then(async (response) => {
      if (response.ok) {
        if (fileInput) fileInput.value = "";
        onComplete(true, "Sent / 送信しました");
        return;
      }
      onComplete(false, errorText(await responseBody(response), response.status));
    })
    .catch((error) => onComplete(false, error?.message || "Network error"));
}

export function login(username, password, onComplete) {
  fetch("/api/v1/session", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ username, password }),
  })
    .then(async (response) => {
      const body = await responseBody(response);
      if (response.ok) {
        onComplete(true, body.username || username, body.csrf_token || "");
      } else {
        onComplete(false, "", errorText(body, response.status));
      }
    })
    .catch((error) => onComplete(false, "", error?.message || "Network error"));
}

async function getAdminResource(url) {
  const response = await fetch(url);
  if (!response.ok) return { error: `HTTP ${response.status}` };
  return responseBody(response);
}

export function load_admin(onComplete) {
  Promise.all([
    getAdminResource("/api/v1/system/health"),
    getAdminResource("/api/v1/users"),
    getAdminResource("/api/v1/acl"),
    getAdminResource("/api/v1/delivery-jobs"),
    getAdminResource("/api/v1/attachments"),
  ])
    .then(([health, users, access, jobs, attachments]) => {
      const userLines = Array.isArray(users.items)
        ? users.items.map((user) => `${user.username} · ${user.role}`).join("\n")
        : users.error || "";
      const accessLines = Array.isArray(access.items)
        ? access.items
            .map(
              (rule) =>
                `${rule.username} → ${rule.topic_pattern}: ${rule.permission}`,
            )
            .join("\n")
        : access.error || "";
      const jobLines = Array.isArray(jobs.items)
        ? jobs.items
            .map(
              (job) =>
                `${job.kind} · ${job.state} · ${job.attempts} attempt(s) · ${job.message_id}`,
            )
            .join("\n")
        : jobs.error || "";
      const attachmentLines = Array.isArray(attachments.items)
        ? attachments.items
            .map((item) => `${item.key} · ${item.size} bytes · expires ${item.expires}`)
            .join("\n")
        : attachments.error || "";
      onComplete(
        JSON.stringify(health, null, 2),
        userLines,
        accessLines,
        jobLines,
        attachmentLines,
      );
    })
    .catch((error) =>
      onComplete(error?.message || "Network error", "", "", "", ""),
    );
}

function mutationRequest(
  operation,
  username,
  password,
  role,
  tokenLabel,
  tokenId,
  topicPattern,
  permission,
  attachmentKey,
) {
  switch (operation) {
    case "create_user":
      return {
        method: "POST",
        url: "/api/v1/users",
        body: { username, password, role },
        success: "User created / ユーザーを作成しました",
      };
    case "delete_user":
      return {
        method: "DELETE",
        url: `/api/v1/users/${encodeURIComponent(username)}`,
        success: "User deleted / ユーザーを削除しました",
      };
    case "create_token":
      return {
        method: "POST",
        url: "/api/v1/tokens",
        body: { username, label: tokenLabel },
        success: "Token created / トークンを作成しました",
      };
    case "revoke_token":
      return {
        method: "DELETE",
        url: `/api/v1/tokens/${encodeURIComponent(tokenId)}`,
        success: "Token revoked / トークンを失効しました",
      };
    case "put_acl":
      return {
        method: "PUT",
        url: "/api/v1/acl",
        body: { username, topic_pattern: topicPattern, permission },
        success: "Access rule saved / 権限ルールを保存しました",
      };
    case "delete_acl":
      return {
        method: "DELETE",
        url: "/api/v1/acl",
        body: { username, topic_pattern: topicPattern, permission },
        success: "Access rule deleted / 権限ルールを削除しました",
      };
    case "delete_attachment":
      return {
        method: "DELETE",
        url: `/api/v1/attachments/${encodeURIComponent(attachmentKey)}`,
        success: "Attachment deleted / 添付を削除しました",
      };
    default:
      return null;
  }
}

export function admin_mutation(
  operation,
  username,
  password,
  role,
  tokenLabel,
  tokenId,
  topicPattern,
  permission,
  attachmentKey,
  csrf,
  onComplete,
) {
  const request = mutationRequest(
    operation,
    username,
    password,
    role,
    tokenLabel,
    tokenId,
    topicPattern,
    permission,
    attachmentKey,
  );
  if (!request) {
    onComplete(false, "Unsupported administration operation", "");
    return;
  }
  const headers = { ...csrfHeaders(csrf) };
  if (request.body) headers["content-type"] = "application/json";
  fetch(request.url, {
    method: request.method,
    headers,
    body: request.body ? JSON.stringify(request.body) : undefined,
  })
    .then(async (response) => {
      const body = response.status === 204 ? {} : await responseBody(response);
      if (!response.ok) {
        onComplete(false, errorText(body, response.status), "");
        return;
      }
      const issued = body.token ? `ID: ${body.id}\n${body.token}` : "";
      onComplete(true, request.success, issued);
    })
    .catch((error) =>
      onComplete(false, error?.message || "Network error", ""),
    );
}

function urlB64ToUint8Array(value) {
  const padding = "=".repeat((4 - (value.length % 4)) % 4);
  const raw = atob((value + padding).replace(/-/g, "+").replace(/_/g, "/"));
  return Uint8Array.from([...raw].map((character) => character.charCodeAt(0)));
}

async function persistPushTopics(topics, csrf) {
  const registration = await navigator.serviceWorker.ready;
  let subscription = await registration.pushManager.getSubscription();
  if (!topics.length) {
    if (subscription) {
      const response = await fetch("/v1/webpush", {
        method: "DELETE",
        headers: { "content-type": "application/json", ...csrfHeaders(csrf) },
        body: JSON.stringify({ endpoint: subscription.endpoint }),
      });
      if (!response.ok) throw new Error(errorText(await responseBody(response), response.status));
      await subscription.unsubscribe();
    }
    return;
  }

  if (!subscription) {
    const permission = await Notification.requestPermission();
    if (permission !== "granted") {
      throw new Error("Notification permission was not granted");
    }
    subscription = await registration.pushManager.subscribe({
      userVisibleOnly: true,
      applicationServerKey: urlB64ToUint8Array(pushConfig.web_push_public_key),
    });
  }

  const serialized = subscription.toJSON();
  const response = await fetch("/v1/webpush", {
    method: "POST",
    headers: { "content-type": "application/json", ...csrfHeaders(csrf) },
    body: JSON.stringify({
      endpoint: subscription.endpoint,
      auth: serialized.keys.auth,
      p256dh: serialized.keys.p256dh,
      topics,
    }),
  });
  if (!response.ok) throw new Error(errorText(await responseBody(response), response.status));
}

export function toggle_push(topic, csrf, onComplete) {
  const [available] = pushState(topic);
  if (!available || !topic) {
    onComplete(available, false, "Web Push is unavailable");
    return;
  }
  const topics = new Set(pushTopics);
  if (topics.has(topic)) topics.delete(topic);
  else topics.add(topic);
  const next = [...topics];
  persistPushTopics(next, csrf)
    .then(() => {
      pushTopics = next;
      localStorage.setItem("notify-push-topics", JSON.stringify(next));
      onComplete(true, next.includes(topic), "Notification settings updated / 通知設定を更新しました");
    })
    .catch((error) => onComplete(true, pushTopics.includes(topic), error?.message || "Web Push failed"));
}

export function store_language(language) {
  localStorage.setItem("notify-language", language);
  document.documentElement.lang = language;
}

export function toggle_theme() {
  const current = document.documentElement.dataset.theme;
  const next = current === "dark" ? "light" : "dark";
  document.documentElement.dataset.theme = next;
  localStorage.setItem("notify-theme", next);
}
