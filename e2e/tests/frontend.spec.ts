// The generated aida frontend in a real (headless) browser: the index of the
// entities, and each entity's page drawing its rows from the API through the
// frontend's proxy. The rows are seeded by test/frontend_e2e_test.zig, which
// runs this suite, with the marker "e2e-test".
import { test, expect } from "@playwright/test";

const entities = ["docentes", "materias", "periodos", "cursos", "clases", "alumnos",
  "preguntas", "opciones", "inscripciones", "presencias", "mesas"];

test("the index links every entity, in declaration order", async ({ page }) => {
  await page.goto("/");
  await expect(page.locator("h1")).toHaveText("aida");
  await expect(page.locator("li a")).toHaveText(entities);
});

test("a link of the index opens the entity's page, and it links back", async ({ page }) => {
  await page.goto("/");
  await page.getByRole("link", { name: "clases", exact: true }).click();
  await expect(page).toHaveURL(/\/clases$/);
  await expect(page.locator("h1")).toHaveText("clases");
  await page.getByRole("link", { name: "aida" }).click();
  await expect(page).toHaveURL(/\/$/);
});

test("every entity's page answers and draws its table", async ({ page }) => {
  for (const entity of entities) {
    const res = await page.goto("/" + entity);
    expect(res?.status(), entity).toBe(200);
    await expect(page.locator("h1"), entity).toHaveText(entity);
    await expect(page.locator("thead th").first(), entity).toBeVisible();
  }
});

test("the headers are the fields' labels", async ({ page }) => {
  await page.goto("/materias");
  await expect(page.locator("thead th")).toHaveText(["materia", "denominación"]);
  await page.goto("/docentes");
  await expect(page.locator("thead th")).toHaveText(["docente", "apellido", "nombres", "cargo", "email", "email alternativo", "jefe"]);
});

test("the rows: a bigint exact, a fecha as its fields joined with '-', null as an empty cell", async ({ page }) => {
  await page.goto("/clases");
  await expect(page.locator("thead th")).toHaveText(["periodo", "materia", "orden", "fecha", "tema"]);
  const rows = page.locator("tbody tr").filter({ hasText: "e2e-test" });
  await expect(rows).toHaveCount(2);
  // 2^53 + 1: only exact if it was never a JS number
  await expect(rows.filter({ hasText: "9007199254740993" }).locator("td"))
    .toHaveText(["e2e-test", "e2e-test", "9007199254740993", "2026-3-14", ""]);
  await expect(rows.filter({ hasText: "sin fecha" }).locator("td"))
    .toHaveText(["e2e-test", "e2e-test", "1", "", "sin fecha"]);
});

test("every page links the shared stylesheet, and it is served as CSS", async ({ page, request }) => {
  const css = await request.get("/common.css");
  expect(css.status()).toBe(200);
  expect(css.headers()["content-type"]).toMatch(/^text\/css/);
  for (const path of ["/", ...entities.map((e) => "/" + e)]) {
    await page.goto(path);
    await expect(page.locator('link[rel="stylesheet"]'), path).toHaveAttribute("href", "/common.css");
  }
});

test("every page has the sidebar with every entity, its own marked as current", async ({ page }) => {
  await page.goto("/");
  await expect(page.locator("nav a")).toHaveText(entities);
  await expect(page.locator('nav a[aria-current="page"]')).toHaveCount(0);
  for (const entity of entities) {
    await page.goto("/" + entity);
    await expect(page.locator("nav a"), entity).toHaveText(entities);
    await expect(page.locator('nav a[aria-current="page"]'), entity).toHaveText(entity);
  }
});

test("the layout is an admin panel: the nav is drawn as a column left of the content", async ({ page }) => {
  await page.setViewportSize({ width: 1280, height: 800 });
  await page.goto("/clases");
  const nav = await page.locator("nav").boundingBox();
  const main = await page.locator("main").boundingBox();
  expect(nav && main).toBeTruthy();
  // side by side: the nav ends where the content starts, and they share rows
  expect(nav!.x + nav!.width).toBeLessThanOrEqual(main!.x);
  expect(nav!.y).toBeLessThan(main!.y + main!.height);
  // a column: the entity links stacked, not in a row
  const links = page.locator("nav a");
  const first = await links.first().boundingBox();
  const second = await links.nth(1).boundingBox();
  expect(second!.y).toBeGreaterThan(first!.y);
  expect(second!.x).toBe(first!.x);
});

test("a path that is not an entity is a 404", async ({ page }) => {
  const res = await page.goto("/inexistentes");
  expect(res?.status()).toBe(404);
});
