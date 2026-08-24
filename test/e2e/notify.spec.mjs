import { test, expect, request as requestFactory } from "@playwright/test";
import AxeBuilder from "@axe-core/playwright";

const administrator = "e2e_admin";
const administratorPassword = "e2e administrator password";
const blockedUser = "e2e_blocked";
const blockedPassword = "e2e blocked user password";
const topic = "browser-e2e";

test("setup, live publishing, administration, access, Web Push, i18n, and responsive keyboard flow", async ({
  page,
  context
}) => {
  const setupUrl = process.env.NOTIFY_E2E_SETUP_URL;
  expect(setupUrl, "the runner must provide the one-time setup URL").toBeTruthy();

  await context.grantPermissions(["notifications"]);
  await page.addInitScript(() => {
    let subscription = null;
    const manager = {
      async getSubscription() {
        return subscription;
      },
      async subscribe() {
        subscription = {
          endpoint:
            "https://updates.push.services.mozilla.com/wpush/v2/notify-browser-e2e",
          toJSON() {
            return {
              endpoint: this.endpoint,
              keys: {
                auth: "kSC3T8aN1JCQxxPdrFLrZg",
                p256dh:
                  "BMKKbxdUU_xLS7G1Wh5AN8PvWOjCzkCuKZYb8apcqYrDxjOF_2piggBnoJLQYx9IeSD70fNuwawI3e9Y8m3S3PE"
              }
            };
          },
          async unsubscribe() {
            subscription = null;
            return true;
          }
        };
        return subscription;
      }
    };

    Object.defineProperty(Notification, "requestPermission", {
      configurable: true,
      value: async () => "granted"
    });
    Object.defineProperty(ServiceWorkerRegistration.prototype, "pushManager", {
      configurable: true,
      get: () => manager
    });
  });

  await page.goto(setupUrl);
  await expect(page.getByRole("heading", { name: "Create the first administrator" })).toBeVisible();
  await page.getByLabel(/Username/).fill(administrator);
  await page.getByLabel(/Password/).fill(administratorPassword);
  await page.getByLabel(/Anonymous access/).selectOption("deny");
  await Promise.all([
    page.waitForURL(new RegExp("/$")),
    page.getByRole("button", { name: /Complete setup/ }).click()
  ]);

  await expect(page.getByRole("heading", { name: "Timeline" })).toBeVisible();
  await page.getByRole("button", { name: "Sign in" }).click();
  const login = page.getByRole("dialog");
  await login.getByLabel("Username").fill(administrator);
  await login.getByLabel("Password").fill(administratorPassword);
  await login.getByRole("button", { name: "Sign in" }).click();
  await expect(page.getByRole("button", { name: administrator })).toBeVisible();

  await page.getByRole("button", { name: "日本語" }).click();
  await expect(page.getByRole("heading", { name: "タイムライン" })).toBeVisible();
  await page.getByRole("button", { name: "English" }).click();

  await page.keyboard.press("/");
  const topicInput = page.locator("#topic");
  await expect(topicInput).toBeFocused();
  await topicInput.fill(topic);
  await topicInput.press("Enter");
  await expect(page.getByText("Live", { exact: true })).toBeVisible();

  const composer = page.locator("form.composer");
  const messageInput = composer.locator('textarea[name="message"]');
  await composer.locator('input[name="title"]').fill("Keyboard publish");
  await messageInput.fill("Published with Ctrl+Enter");
  await page.keyboard.press("Control+Enter");
  await expect(page.getByText("Published with Ctrl+Enter", { exact: true })).toBeVisible();

  await composer.locator('input[name="title"]').fill("Attachment publish");
  await messageInput.fill("Browser attachment");
  await page.locator("#attachment").setInputFiles({
    name: "browser.txt",
    mimeType: "text/plain",
    buffer: Buffer.from("browser attachment payload")
  });
  await page.getByRole("button", { name: "Publish" }).click();
  await expect(page.getByText("Browser attachment", { exact: true })).toBeVisible();

  await page.getByRole("button", { name: "System & access" }).click();
  const administration = page.locator(".admin-panel");
  await expect(administration.getByRole("heading", { name: "Administration" })).toBeVisible();

  const users = administration.getByRole("heading", { name: "Users" }).locator("..");
  const createUser = users.locator("form").first();
  await createUser.getByLabel("Username").fill(blockedUser);
  await createUser.getByLabel("Password").fill(blockedPassword);
  await createUser.getByRole("button", { name: "Create user" }).click();
  await expect(administration.locator(".admin-status")).toContainText("User created");

  const tokens = administration.getByRole("heading", { name: "Tokens" }).locator("..");
  const createToken = tokens.locator("form").first();
  await createToken.getByLabel("Username").fill(blockedUser);
  await createToken.getByLabel("Label").fill("browser-e2e");
  await createToken.getByRole("button", { name: "Create token" }).click();
  const issuedSecret = administration.locator(".issued-secret code");
  await expect(issuedSecret).toContainText("tk_");

  const access = administration
    .getByRole("heading", { name: "Access rules" })
    .locator("..");
  await access.getByLabel("Username").fill(blockedUser);
  await access.getByLabel("Topic pattern").fill(topic);
  await access.getByLabel("Permission").selectOption("deny");
  await access.getByRole("button", { name: "Save rule" }).click();
  await expect(administration.locator(".admin-status")).toContainText("Access rule saved");
  await expect(administration.locator(".issued-secret")).toBeHidden();

  const blockedClient = await requestFactory.newContext({
    baseURL: process.env.NOTIFY_E2E_BASE_URL || "http://localhost:18082",
    extraHTTPHeaders: {
      authorization: `Basic ${Buffer.from(`${blockedUser}:${blockedPassword}`).toString("base64")}`
    }
  });
  const denied = await blockedClient.post(`/${topic}`, { data: "must be denied" });
  expect(denied.status()).toBe(403);
  await blockedClient.dispose();

  const attachments = administration
    .getByRole("heading", { name: "Attachments" })
    .locator("..");
  await expect(attachments.locator("li")).toContainText("bytes");
  await administration.getByRole("button", { name: "Close" }).click();

  const enablePush = page.getByRole("button", { name: "Enable notifications" });
  await expect(enablePush).toBeVisible();
  const [registered] = await Promise.all([
    page.waitForResponse(
      (response) =>
        response.url().endsWith("/v1/webpush") && response.request().method() === "POST"
    ),
    enablePush.click()
  ]);
  expect(registered.status()).toBe(200);
  await expect(page.getByRole("button", { name: "Disable notifications" })).toBeVisible();
  const [removed] = await Promise.all([
    page.waitForResponse(
      (response) =>
        response.url().endsWith("/v1/webpush") && response.request().method() === "DELETE"
    ),
    page.getByRole("button", { name: "Disable notifications" }).click()
  ]);
  expect(removed.status()).toBe(200);

  await page.setViewportSize({ width: 390, height: 844 });
  await expect(page.getByRole("heading", { name: "Timeline" })).toBeVisible();
  await page.keyboard.press("/");
  await expect(topicInput).toBeFocused();

  const accessibility = await new AxeBuilder({ page })
    .withTags(["wcag2a", "wcag2aa", "wcag21a", "wcag21aa", "wcag22aa"])
    .analyze();
  expect(accessibility.violations).toEqual([]);
});
