// The generated aida frontend in a real (headless) browser: the index of the
// entities, each entity's page drawing its rows from the API through the
// frontend's proxy, the page of one row, which can delete it, and the page
// that creates a row. The rows
// are seeded by
// test/frontend_e2e_test.zig, which runs this suite, with the marker
// "e2e-test".
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

test("the first cell of each row links to the row's page, its URL mirroring the API's", async ({ page }) => {
  await page.goto("/clases");
  const row = page.locator("tbody tr").filter({ hasText: "9007199254740993" });
  // only the first cell is a link
  await expect(row.locator("td").first().locator("a")).toHaveText("e2e-test");
  await expect(row.locator("td a")).toHaveCount(1);
  await row.locator("td a").click();
  // the pk in the query string, in pk order; the bigint exact
  await expect(page).toHaveURL(/\/clases\?periodo=e2e-test&materia=e2e-test&orden=9007199254740993$/);
});

test("the row's page: its fields as label/value pairs, read from the API with the same query string", async ({ page }) => {
  await page.goto("/clases?periodo=e2e-test&materia=e2e-test&orden=9007199254740993");
  await expect(page.locator("h1")).toHaveText("clases");
  await expect(page.locator('nav a[aria-current="page"]')).toHaveText("clases");
  await expect(page.locator("main dl dt")).toHaveText(["periodo", "materia", "orden", "fecha", "tema"]);
  // the bigint exact, the fecha its fields joined with '-', null an empty value
  await expect(page.locator("main dl dd")).toHaveText(["e2e-test", "e2e-test", "9007199254740993", "2026-3-14", ""]);
  // the row's page shows the row, not the list
  await expect(page.locator("main table")).toHaveCount(0);
});

test("a struct in the pk is one parameter per field, like the API's", async ({ page }) => {
  await page.goto("/mesas");
  const row = page.locator("tbody tr").filter({ hasText: "e2e-test" });
  await row.locator("td a").click();
  await expect(page).toHaveURL(/\/mesas\?periodo=e2e-test&materia=e2e-test&fecha\.a%C3%B1o=2026&fecha\.mes=3&fecha\.d%C3%ADa=14$/);
  await expect(page.locator("main dl dt")).toHaveText(["periodo", "materia", "fecha", "presidente", "vocal"]);
  await expect(page.locator("main dl dd")).toHaveText(["e2e-test", "e2e-test", "2026-3-14", "", ""]);
});

test("the page of a pk with no row shows a not-found message", async ({ page }) => {
  await page.goto("/periodos?periodo=no-existe");
  await expect(page.locator("h1")).toHaveText("periodos");
  await expect(page.locator("main")).toContainText("No row with that pk.");
  await expect(page.locator("main dl")).toHaveCount(0);
  await expect(page.locator("main table")).toHaveCount(0);
});

test("the row's page has a Delete button that asks for confirmation on the page; Cancel keeps the row", async ({ page, request }) => {
  await page.goto("/periodos?periodo=e2e-test-cancel");
  await expect(page.locator("main dl dd")).toHaveText(["e2e-test-cancel"]);
  await page.getByRole("button", { name: "Delete", exact: true }).click();
  // the confirmation, on the page (no native dialog)
  await expect(page.locator("main")).toContainText("Delete this row?");
  await expect(page.getByRole("button", { name: "Delete", exact: true })).toHaveCount(0);
  await page.getByRole("button", { name: "Cancel" }).click();
  await expect(page.locator("main")).not.toContainText("Delete this row?");
  await expect(page.getByRole("button", { name: "Delete", exact: true })).toBeVisible();
  await expect(page).toHaveURL(/\/periodos\?periodo=e2e-test-cancel$/);
  expect((await request.get("/api/periodos?periodo=e2e-test-cancel")).status()).toBe(200);
});

test("confirming the delete removes the row and goes back to the list", async ({ page, request }) => {
  await page.goto("/periodos?periodo=e2e-test-delete");
  await page.getByRole("button", { name: "Delete", exact: true }).click();
  await page.getByRole("button", { name: "Yes, delete" }).click();
  await expect(page).toHaveURL(/\/periodos$/);
  await expect(page.locator("tbody tr").first()).toBeVisible();
  await expect(page.locator("tbody tr").filter({ hasText: "e2e-test-delete" })).toHaveCount(0);
  expect((await request.get("/api/periodos?periodo=e2e-test-delete")).status()).toBe(404);
});

test("a delete the database rejects (a referenced row) shows a generic error and stays on the row", async ({ page, request }) => {
  // the periodo of a curso
  await page.goto("/periodos?periodo=e2e-test");
  await page.getByRole("button", { name: "Delete", exact: true }).click();
  await page.getByRole("button", { name: "Yes, delete" }).click();
  await expect(page.locator("main")).toContainText("The row could not be deleted.");
  await expect(page).toHaveURL(/\/periodos\?periodo=e2e-test$/);
  await expect(page.locator("main dl dd")).toHaveText(["e2e-test"]);
  expect((await request.get("/api/periodos?periodo=e2e-test")).status()).toBe(200);
});

test("only the page of an existing row has a Delete button", async ({ page }) => {
  await page.goto("/periodos");
  await expect(page.locator("tbody tr").first()).toBeVisible();
  await expect(page.getByRole("button", { name: "Delete", exact: true })).toHaveCount(0);
  await page.goto("/periodos?periodo=no-existe");
  await expect(page.locator("main")).toContainText("No row with that pk.");
  await expect(page.getByRole("button", { name: "Delete", exact: true })).toHaveCount(0);
});

test("the list links to the entity's new-row page: a form with an input per field, a struct one per part", async ({ page }) => {
  await page.goto("/clases");
  await page.getByRole("link", { name: "New", exact: true }).click();
  await expect(page).toHaveURL(/\/clases\/new$/);
  await expect(page.locator("h1")).toHaveText("clases");
  await expect(page.locator('nav a[aria-current="page"]')).toHaveText("clases");
  for (const label of ["periodo", "materia", "orden", "tema", "año", "mes", "día"]) {
    await expect(page.getByLabel(label, { exact: true }), label).toBeVisible();
  }
  await expect(page.locator("fieldset legend")).toHaveText("fecha");
  await expect(page.getByRole("button", { name: "Create" })).toBeVisible();
});

test("creating a row posts it and goes back to the list", async ({ page, request }) => {
  await page.goto("/periodos/new");
  await page.getByLabel("periodo", { exact: true }).fill("e2e-test-create");
  await page.getByRole("button", { name: "Create" }).click();
  await expect(page).toHaveURL(/\/periodos$/);
  await expect(page.locator("tbody tr").filter({ hasText: "e2e-test-create" })).toHaveCount(1);
  expect((await request.get("/api/periodos?periodo=e2e-test-create")).status()).toBe(200);
});

test("a created row keeps a bigint exact, a struct by its parts, and an empty nullable field as null", async ({ page, request }) => {
  await page.goto("/clases/new");
  await page.getByLabel("periodo", { exact: true }).fill("e2e-test");
  await page.getByLabel("materia", { exact: true }).fill("e2e-test");
  await page.getByLabel("orden", { exact: true }).fill("9007199254740995");
  await page.getByLabel("año", { exact: true }).fill("2026");
  await page.getByLabel("mes", { exact: true }).fill("4");
  await page.getByLabel("día", { exact: true }).fill("1");
  await page.getByRole("button", { name: "Create" }).click();
  await expect(page).toHaveURL(/\/clases$/);
  // the response's text: 2^53 + 3 only survives if it never was a JS number
  const created = await (await request.get("/api/clases?periodo=e2e-test&materia=e2e-test&orden=9007199254740995")).text();
  expect(created).toBe('{"periodo":"e2e-test","materia":"e2e-test","orden":9007199254740995,"fecha":{"año":2026,"mes":4,"día":1},"tema":null}');

  // a struct left empty: null
  await page.goto("/clases/new");
  await page.getByLabel("periodo", { exact: true }).fill("e2e-test");
  await page.getByLabel("materia", { exact: true }).fill("e2e-test");
  await page.getByLabel("orden", { exact: true }).fill("2");
  await page.getByLabel("tema", { exact: true }).fill("sin fecha 2");
  await page.getByRole("button", { name: "Create" }).click();
  await expect(page).toHaveURL(/\/clases$/);
  const without = await (await request.get("/api/clases?periodo=e2e-test&materia=e2e-test&orden=2")).text();
  expect(without).toBe('{"periodo":"e2e-test","materia":"e2e-test","orden":2,"fecha":null,"tema":"sin fecha 2"}');
});

test("a create the API rejects (a duplicate pk) shows a generic error and stays on the form", async ({ page }) => {
  await page.goto("/periodos/new");
  await page.getByLabel("periodo", { exact: true }).fill("e2e-test");
  await page.getByRole("button", { name: "Create" }).click();
  await expect(page.locator("main")).toContainText("The row could not be created.");
  await expect(page).toHaveURL(/\/periodos\/new$/);
  await expect(page.getByLabel("periodo", { exact: true })).toHaveValue("e2e-test");
});

test("Cancel on the new-row page goes back to the list without creating anything", async ({ page, request }) => {
  await page.goto("/periodos/new");
  await page.getByLabel("periodo", { exact: true }).fill("e2e-test-never");
  await page.getByRole("link", { name: "Cancel" }).click();
  await expect(page).toHaveURL(/\/periodos$/);
  expect((await request.get("/api/periodos?periodo=e2e-test-never")).status()).toBe(404);
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
