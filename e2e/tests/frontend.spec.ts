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

test("a path that is not an entity is a 404", async ({ page }) => {
  const res = await page.goto("/inexistentes");
  expect(res?.status()).toBe(404);
});
