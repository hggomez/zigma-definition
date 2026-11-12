#!/usr/bin/env python3
"""Comprueba comandos y límites entre paquetes sin iniciar aplicaciones ni servicios."""

import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
ZIG = sys.argv.pop(1) if len(sys.argv) > 1 else "zig"


def copy_framework_without_examples(destination):
    """Paquete mínimo que conserva el build real, sin el ejemplo ni sus snapshots."""
    destination.mkdir()
    for name in ("build.zig", "build.zig.zon"):
        shutil.copyfile(ROOT / name, destination / name)
    shutil.copytree(ROOT / "build", destination / "build")
    (destination / "src").symlink_to(ROOT / "src", target_is_directory=True)


class BuildCommandsTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # Un error de compilación del build es un error del test, no el rojo
        # esperado por la presencia o ausencia de un comando.
        result = subprocess.run(
            [ZIG, "build", "--help"], cwd=ROOT, text=True,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        if result.returncode:
            raise RuntimeError(f"Falló zig build --help:\n{result.stderr}")
        section = result.stdout.split("Steps:\n", 1)[1].split("\n\n", 1)[0]
        cls.steps = {line.split()[0] for line in section.splitlines() if line.strip()}

    def test_local_suite_is_published(self):
        self.assertIn("test-local", self.steps)

    def test_framework_does_not_publish_application_commands(self):
        application_steps = {
            "run-aida", "run-aida-rest", "check-aida", "check-aida-rest",
            "run", "run-backend", "check-schema", "migration",
            "accept-migration", "init-migrations", "apply-migrations",
        }
        self.assertFalse(application_steps & self.steps,
                         f"Comandos de aplicación en la raíz: {application_steps & self.steps}")

    def test_direct_ddl_startup_is_not_public(self):
        self.assertNotIn("run-postgres-bootstrap", self.steps)

    def test_old_migration_command_has_no_alias(self):
        self.assertNotIn("run-postgres-liquibase-bootstrap", self.steps)

    def test_framework_test_commands_remain_available(self):
        expected = {
            "test", "test-model", "test-json", "test-aida-launcher",
            "test-postgres", "test-rest-postgres", "test-migrations",
            "test-runtime", "test-runtime-backend",
        }
        self.assertFalse(expected - self.steps, f"Comandos faltantes: {expected - self.steps}")

    def test_aida_owns_application_and_migration_commands(self):
        result = subprocess.run(
            [ZIG, "build", "--help"], cwd=ROOT / "examples/aida", text=True,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=120,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        section = result.stdout.split("Steps:\n", 1)[1].split("\n\n", 1)[0]
        steps = {line.split()[0] for line in section.splitlines() if line.strip()}
        expected = {
            "frontend", "test-frontend", "run", "run-backend", "check", "check-backend",
            "check-schema", "migration", "accept-migration", "init-migrations", "apply-migrations",
        }
        self.assertFalse(expected - steps, f"Comandos faltantes en AIDA: {expected - steps}")
        self.assertFalse({"testing-backend", "test-backend"} & steps,
                         "El consumidor todavía publica comandos del backend retirado")

    def test_aida_publishes_test_commands(self):
        """AIDA ofrece pruebas propias, rechazos de compilación y una suite local."""
        result = subprocess.run(
            [ZIG, "build", "--help"], cwd=ROOT / "examples/aida", text=True,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=120,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        section = result.stdout.split("Steps:\n", 1)[1].split("\n\n", 1)[0]
        steps = {line.split()[0] for line in section.splitlines() if line.strip()}
        expected = {"test", "test-compile-errors", "test-frontend", "test-local"}
        self.assertFalse(expected - steps, f"Comandos de pruebas faltantes en AIDA: {expected - steps}")


class AidaTestOwnershipTest(unittest.TestCase):
    # Estos archivos prueban decisiones del consumidor. Las suites genéricas que
    # usan AIDA como fixture siguen perteneciendo al framework.
    domain_suites = (
        "fecha_test.zig", "fecha_codec_test.zig", "fecha_rest_test.zig",
        "docente_age_test.zig", "docente_age_rest_test.zig", "aida_rest_test.zig",
        "aida_nullable_test.zig", "aida_schema_reference_test.zig",
    )
    cargo_rejections = (
        "cargo_wrong_field_type.zig", "validar_cargo_missing_field.zig", "cargo_unknown_field.zig",
    )

    @classmethod
    def setUpClass(cls):
        temporary = tempfile.TemporaryDirectory(prefix="zigma aida published tests ")
        cls.addClassCleanup(temporary.cleanup)
        cls.package_root = Path(temporary.name).resolve()
        cache = Path(os.environ.get("ZIG_GLOBAL_CACHE_DIR", cls.package_root / "cache")).resolve()
        environment = {**os.environ, "ZIG_GLOBAL_CACHE_DIR": str(cache)}

        def export_package(source, destination):
            # Zig aplica realmente .paths: una copia completa del repo ocultaría
            # dependencias accidentales de los tests privados del framework.
            result = subprocess.run(
                [ZIG, "fetch", str(source)], cwd=cls.package_root, env=environment,
                text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=180,
            )
            if result.returncode:
                raise RuntimeError(f"No se pudo empaquetar {source}:\n{result.stderr}")
            package_hash = result.stdout.strip()
            with tarfile.open(cache / "p" / f"{package_hash}.tar.gz") as package:
                package.extractall(cls.package_root / "unpacked", filter="data")
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.move(cls.package_root / "unpacked" / package_hash, destination)

        cls.published_framework = cls.package_root / "framework"
        export_package(ROOT, cls.published_framework)
        export_package(ROOT / "examples/aida", cls.published_framework / "examples/aida")

    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="zigma aida test case ")
        self.addCleanup(temporary.cleanup)
        self.framework = Path(temporary.name).resolve() / "framework"
        shutil.copytree(self.published_framework, self.framework)
        self.aida = self.framework / "examples/aida"

    def run_build(self, directory, step):
        return subprocess.run(
            [ZIG, "build", step, "--summary", "all"], cwd=directory, text=True,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=240,
            env={**os.environ, "LIQUIBASE_BIN": str(self.framework / "liquibase-no-disponible")},
        )

    def test_aida_package_owns_domain_suites_and_rejections(self):
        """Los tests propios y su build se publican en AIDA y salen del test raíz."""
        owned_paths = [Path("build/tests.zig")]
        owned_paths += [Path("test") / name for name in self.domain_suites]
        owned_paths += [Path("test/compile_errors") / name for name in self.cargo_rejections]
        missing = [str(path) for path in owned_paths if not (self.aida / path).is_file()]
        self.assertFalse(missing, f"Archivos propios ausentes del paquete AIDA: {missing}")
        duplicated = [str(path) for path in owned_paths[1:] if (ROOT / path).exists()]
        self.assertFalse(duplicated, f"Pruebas de AIDA todavía presentes en el test raíz: {duplicated}")

    def test_aida_runs_domain_tests_with_the_published_framework(self):
        """La suite conserva los casos de dominio sin acceder a tests privados del framework."""
        self.assertFalse((self.framework / "test/fecha_test.zig").exists())
        self.assertFalse((self.framework / "test/fixtures").exists())
        result = self.run_build(self.aida, "test")
        output = result.stdout + result.stderr
        self.assertEqual(result.returncode, 0, output)
        totals = [int(total) for total in re.findall(r"(\d+)/\d+ tests passed", output)]
        # 49 casos en las ocho suites completas, más 2 reglas de negocio y 3
        # conversiones de contexto que hoy están mezcladas con tests genéricos.
        self.assertGreaterEqual(max(totals, default=0), 54, output)

    def test_aida_runs_the_published_local_suite(self):
        """La suite local reúne dominio y frontend sin PostgreSQL, libpq ni Liquibase."""
        frontend_test = self.framework / "test/integration/run_frontend_test.mjs"
        frontend_test.write_text('console.log("AIDA_FRONTEND_EXECUTED");\n' + frontend_test.read_text())
        result = self.run_build(self.aida, "test-local")
        output = result.stdout + result.stderr
        self.assertEqual(result.returncode, 0, output)
        self.assertRegex(output, r"\d+/\d+ tests passed")
        self.assertIn("AIDA_FRONTEND_EXECUTED", output)

    def test_domain_failure_fails_the_aida_suite(self):
        """El comando test ejecuta las pruebas trasladadas y propaga sus fallos."""
        suite = self.aida / "test/fecha_test.zig"
        self.assertTrue(suite.is_file(), "Falta trasladar y publicar la suite de Fecha en AIDA")
        with suite.open("a") as source:
            source.write('\ntest "la suite ejecuta los casos propios de AIDA" {\n'
                         '    return error.PruebaDeAidaEjecutada;\n}\n')
        result = self.run_build(self.aida, "test")
        self.assertNotEqual(result.returncode, 0, "La suite omitió el test que falla")
        self.assertIn("PruebaDeAidaEjecutada", result.stdout + result.stderr)

    def test_aida_checks_all_three_cargo_rejections(self):
        """Los tres fragmentos de Cargo se compilan con sus diagnósticos esperados."""
        result = self.run_build(self.aida, "test-compile-errors")
        output = result.stdout + result.stderr
        self.assertEqual(result.returncode, 0, output)
        for filename in self.cargo_rejections:
            self.assertIn(Path(filename).stem, output)

    def test_aida_suite_rejects_a_stale_snapshot(self):
        """Test conserva la comprobación del snapshot aceptado sin conectar a la base."""
        snapshot = self.aida / "db/schema.snapshot.json"
        source = snapshot.read_text()
        stale = source.replace('"sql_type":"TEXT"', '"sql_type":"BIGINT"', 1)
        self.assertNotEqual(stale, source, "La mutación debe cambiar un tipo SQL existente")
        snapshot.write_text(stale)
        result = self.run_build(self.aida, "test")
        self.assertNotEqual(result.returncode, 0, "El test aceptó un snapshot diferente del modelo")
        self.assertIn("PostgreSQL schema differs from db/schema.snapshot.json", result.stdout + result.stderr)

    def test_root_delegates_once_and_propagates_aida_failure(self):
        """Zig build test en la raíz conserva la cobertura delegando al consumidor."""
        # Esta prueba sí representa el checkout completo: las suites genéricas
        # necesitan sus fixtures privados. Solo se reemplaza el build del ejemplo.
        shutil.rmtree(self.framework / "test")
        (self.framework / "test").symlink_to(ROOT / "test", target_is_directory=True)
        (self.aida / "build.zig").write_text('''
const std = @import("std");
pub fn build(b: *std.Build) void {
    _ = b.standardTargetOptions(.{});
    _ = b.standardOptimizeOption(.{});
    const probe = b.addSystemCommand(&.{"python3"});
    probe.addFileArg(b.path("delegation_probe.py"));
    b.step("test", "Prueba de delegación al consumidor").dependOn(&probe.step);
}
''')
        (self.aida / "delegation_probe.py").write_text('''
from pathlib import Path
with Path(__file__).with_name("delegation.txt").open("a") as marker:
    marker.write("test\\n")
raise SystemExit("AIDA_TEST_DELEGATION")
''')
        result = self.run_build(self.framework, "test")
        marker = self.aida / "delegation.txt"
        self.assertTrue(marker.is_file(), "El test raíz no invocó el comando test del consumidor AIDA\n"
                        + result.stdout + result.stderr)
        self.assertEqual(marker.read_text().splitlines(), ["test"], "AIDA se ejecutó más de una vez")
        self.assertNotEqual(result.returncode, 0, "La raíz ocultó el fallo del consumidor")
        self.assertIn("AIDA_TEST_DELEGATION", result.stdout + result.stderr)


class FrontendConsumerTest(unittest.TestCase):
    def test_default_build_installs_only_frontend_without_a_rest_adapter(self):
        with tempfile.TemporaryDirectory(prefix="zigma frontend consumer ") as directory:
            root = Path(directory).resolve()
            framework = root / "framework without examples"
            copy_framework_without_examples(framework)
            (root / "build.zig.zon").write_text(
                '.{ .name = .migration_consumer, .version = "0.0.0", '
                '.fingerprint = 0x61be1bea1581417f, '
                '.dependencies = .{ .zigma_definition = .{ .path = '
                + json.dumps(os.path.relpath(framework, root)) + ' } }, '
                '.paths = .{ "build.zig", "build.zig.zon", "system.zig" } }\n'
            )
            (root / "build.zig").write_text('''
const std = @import("std");
const zigma = @import("zigma_definition");
pub fn build(b: *std.Build) void {
    const dep = b.dependency("zigma_definition", .{});
    _ = zigma.addAppFromDep(b, dep, .{
        .system_root = b.path("system.zig"),
        .title = "Independent inventory",
    });
}
''')
            (root / "system.zig").write_text('''
const zigma = @import("zigma");
pub const type_defs = zigma.common_type_defs;
const definition = .{
    .fields = zigma.record(type_defs, .{ .id = .{ .type = "integer" } }),
    .pk = .{"id"},
};
pub const entity_defs = zigma.defineEntities(.{
    .products = .{ .Type = zigma.Entity(type_defs, definition), .definition = definition },
});
''')
            prefix = root / "custom installation"
            result = subprocess.run(
                [ZIG, "build", "--prefix", str(prefix)], cwd=root, text=True,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=180,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            frontend = prefix / "frontend"
            for filename in ("index.html", "main.js", "api-config.js", "title.js", "frontend.wasm"):
                self.assertTrue((frontend / filename).is_file(), filename)
            self.assertEqual((frontend / "frontend.wasm").read_bytes()[:8], b"\x00asm\x01\x00\x00\x00")
            self.assertIn("Independent inventory", (frontend / "title.js").read_text())
            self.assertFalse((prefix / "bin").exists(), "El frontend no debe instalar un backend implícito")


class FrameworkModulesTest(unittest.TestCase):
    def test_default_framework_build_does_not_require_aida_or_its_snapshot(self):
        with tempfile.TemporaryDirectory(prefix="zigma standalone framework ") as directory:
            framework = Path(directory).resolve() / "framework without examples"
            copy_framework_without_examples(framework)
            result = subprocess.run(
                [ZIG, "build"], cwd=framework, text=True,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=180,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertFalse((framework / "zig-out/bin").exists())

    def test_framework_registration_preserves_application_owned_modules(self):
        with tempfile.TemporaryDirectory(prefix="zigma framework modules ") as directory:
            root = Path(directory).resolve()
            (root / "build").mkdir()
            (root / "build/modules.zig").symlink_to(ROOT / "build/modules.zig")
            (root / "src").symlink_to(ROOT / "src", target_is_directory=True)
            # No contiene examples/: este build solo usa el registro del framework.
            # Los nombres del dominio pertenecen al consumidor y no deben colisionar.
            for name in ("aida", "aida_rest", "aida_postgres"):
                (root / f"{name}.zig").write_text(f'pub const owner = "consumer:{name}";\n')
            (root / "build.zig").write_text('''
const std = @import("std");
const framework = @import("build/modules.zig");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const names = .{ "aida", "aida_rest", "aida_postgres" };
    inline for (names) |name| {
        _ = b.addModule(name, .{
            .root_source_file = b.path(name ++ ".zig"),
            .target = target,
            .optimize = optimize,
        });
    }
    const modules = framework.create(b, target, optimize);
    const probe = b.createModule(.{
        .root_source_file = b.path("probe.zig"),
        .target = target,
        .optimize = optimize,
    });
    probe.addImport("zigma", modules.zigma);
    inline for (names) |name| probe.addImport(name, b.modules.get(name).?);
    const tests = b.addTest(.{ .root_module = probe });
    const run = b.addRunArtifact(tests);
    b.default_step.dependOn(&run.step);
}
''')
            (root / "probe.zig").write_text('''
const std = @import("std");
test "framework and application modules coexist without example sources" {
    try std.testing.expect(@hasDecl(@import("zigma"), "Framework"));
    try std.testing.expectEqualStrings("consumer:aida", @import("aida").owner);
    try std.testing.expectEqualStrings("consumer:aida_rest", @import("aida_rest").owner);
    try std.testing.expectEqualStrings("consumer:aida_postgres", @import("aida_postgres").owner);
}
''')
            result = subprocess.run(
                [ZIG, "build"], cwd=root, text=True,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=180,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
