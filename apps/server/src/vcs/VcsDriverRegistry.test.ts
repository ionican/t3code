import { assert, it, describe } from "@effect/vitest";
import * as NodeServices from "@effect/platform-node/NodeServices";
import * as Effect from "effect/Effect";
import * as FileSystem from "effect/FileSystem";
import * as Layer from "effect/Layer";
import * as Path from "effect/Path";
import { ChildProcessSpawner } from "effect/unstable/process";

import * as VcsProcess from "./VcsProcess.ts";
import * as VcsProjectConfig from "./VcsProjectConfig.ts";
import * as VcsDriverRegistry from "./VcsDriverRegistry.ts";

const processOutput = (stdout: string): VcsProcess.VcsProcessOutput => ({
  exitCode: ChildProcessSpawner.ExitCode(0),
  stdout,
  stderr: "",
  stdoutTruncated: false,
  stderrTruncated: false,
});

const normalizeGitArgs = (args: ReadonlyArray<string>): ReadonlyArray<string> =>
  args[0] === "-C" && args.length >= 2 ? args.slice(2) : args;

describe("VcsDriverRegistry", () => {
  it.effect("routes directly by VCS driver kind for non-repository workflows", () => {
    const layer = Layer.effect(VcsDriverRegistry.VcsDriverRegistry, VcsDriverRegistry.make).pipe(
      Layer.provide(NodeServices.layer),
      Layer.provide(
        Layer.mock(VcsProjectConfig.VcsProjectConfig)({
          resolveKind: (input) => Effect.succeed(input.requestedKind ?? "auto"),
        }),
      ),
      Layer.provide(
        Layer.mock(VcsProcess.VcsProcess)({
          run: () => Effect.succeed(processOutput("")),
        }),
      ),
    );

    return Effect.gen(function* () {
      const registry = yield* VcsDriverRegistry.VcsDriverRegistry;
      const driver = yield* registry.get("git");

      assert.strictEqual(driver.capabilities.kind, "git");
    }).pipe(Effect.provide(layer));
  });

  it.effect("caches repository detection for repeated resolves in the same cwd and kind", () => {
    const calls: VcsProcess.VcsProcessInput[] = [];
    return Effect.gen(function* () {
      const fileSystem = yield* FileSystem.FileSystem;
      const path = yield* Path.Path;
      const cwd = yield* fileSystem.makeTempDirectoryScoped({
        prefix: "t3-vcs-driver-registry-cache-",
      });
      const canonicalCwd = yield* fileSystem.realPath(cwd);
      yield* fileSystem.makeDirectory(path.join(cwd, ".git"));
      const layer = Layer.effect(VcsDriverRegistry.VcsDriverRegistry, VcsDriverRegistry.make).pipe(
        Layer.provide(NodeServices.layer),
        Layer.provide(
          Layer.mock(VcsProjectConfig.VcsProjectConfig)({
            resolveKind: (input) => Effect.succeed(input.requestedKind ?? "auto"),
          }),
        ),
        Layer.provide(
          Layer.mock(VcsProcess.VcsProcess)({
            run: (input) =>
              Effect.sync(() => {
                calls.push(input);
                const normalizedArgs = normalizeGitArgs(input.args);
                const command = normalizedArgs.join(" ");
                if (command === "rev-parse --is-inside-work-tree") {
                  return processOutput("true\n");
                }
                if (command === "rev-parse --show-toplevel") {
                  return processOutput(`${canonicalCwd}\n`);
                }
                if (command === "rev-parse --git-common-dir") {
                  return processOutput(`${path.join(canonicalCwd, ".git")}\n`);
                }
                return processOutput("");
              }),
          }),
        ),
      );
      yield* Effect.gen(function* () {
        const registry = yield* VcsDriverRegistry.VcsDriverRegistry;
        const first = yield* registry.resolve({ cwd, requestedKind: "git" });
        const second = yield* registry.resolve({ cwd, requestedKind: "git" });

        assert.equal(first.repository.rootPath, canonicalCwd);
        assert.equal(second.repository.rootPath, canonicalCwd);
        assert.deepStrictEqual(
          calls.map((call) => normalizeGitArgs(call.args).join(" ")),
          [
            "rev-parse --is-inside-work-tree",
            "rev-parse --show-toplevel",
            "rev-parse --git-common-dir",
          ],
        );
      }).pipe(Effect.provide(layer));
    }).pipe(Effect.provide(NodeServices.layer));
  });

  it.effect("detects a repository created after a negative lookup", () => {
    let insideWorkTreeChecks = 0;
    return Effect.gen(function* () {
      const fileSystem = yield* FileSystem.FileSystem;
      const path = yield* Path.Path;
      const cwd = yield* fileSystem.makeTempDirectoryScoped({
        prefix: "t3-vcs-driver-registry-late-repo-",
      });
      const canonicalCwd = yield* fileSystem.realPath(cwd);
      const layer = Layer.effect(VcsDriverRegistry.VcsDriverRegistry, VcsDriverRegistry.make).pipe(
        Layer.provide(NodeServices.layer),
        Layer.provide(
          Layer.mock(VcsProjectConfig.VcsProjectConfig)({
            resolveKind: (input) => Effect.succeed(input.requestedKind ?? "auto"),
          }),
        ),
        Layer.provide(
          Layer.mock(VcsProcess.VcsProcess)({
            run: (input) =>
              Effect.sync(() => {
                const command = normalizeGitArgs(input.args).join(" ");
                if (command === "rev-parse --is-inside-work-tree") {
                  insideWorkTreeChecks += 1;
                  return processOutput("true\n");
                }
                if (command === "rev-parse --show-toplevel") {
                  return processOutput(`${canonicalCwd}\n`);
                }
                if (command === "rev-parse --git-common-dir") {
                  return processOutput(`${path.join(canonicalCwd, ".git")}\n`);
                }
                return processOutput("");
              }),
          }),
        ),
      );
      yield* Effect.gen(function* () {
        const registry = yield* VcsDriverRegistry.VcsDriverRegistry;

        assert.equal(yield* registry.detect({ cwd }), null);
        yield* fileSystem.makeDirectory(path.join(cwd, ".git"));
        assert.equal((yield* registry.detect({ cwd }))?.repository.rootPath, canonicalCwd);
        assert.equal(insideWorkTreeChecks, 1);
      }).pipe(Effect.provide(layer));
    }).pipe(Effect.provide(NodeServices.layer));
  });
});
