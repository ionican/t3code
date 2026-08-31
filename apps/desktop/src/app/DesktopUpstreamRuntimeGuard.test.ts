import { assert, describe, it } from "@effect/vitest";
import * as Effect from "effect/Effect";
import * as Fiber from "effect/Fiber";
import * as Layer from "effect/Layer";
import * as PlatformError from "effect/PlatformError";
import * as Sink from "effect/Sink";
import * as Stream from "effect/Stream";
import * as TestClock from "effect/testing/TestClock";
import * as ChildProcessSpawner from "effect/unstable/process/ChildProcessSpawner";

import * as DesktopEnvironment from "./DesktopEnvironment.ts";
import * as DesktopUpstreamRuntimeGuard from "./DesktopUpstreamRuntimeGuard.ts";

interface RecordedCommand {
  readonly command: string;
  readonly args: ReadonlyArray<string>;
}

const processHandle = (
  exitCode: Effect.Effect<
    ChildProcessSpawner.ExitCode,
    PlatformError.PlatformError
  > = Effect.succeed(ChildProcessSpawner.ExitCode(1)),
) =>
  ChildProcessSpawner.makeHandle({
    pid: ChildProcessSpawner.ProcessId(1),
    exitCode,
    isRunning: Effect.succeed(false),
    kill: () => Effect.void,
    unref: Effect.succeed(Effect.void),
    stdin: Sink.drain,
    stdout: Stream.empty,
    stderr: Stream.empty,
    all: Stream.empty,
    getInputFd: () => Sink.drain,
    getOutputFd: () => Stream.empty,
  });

const runGuard = (input: {
  readonly platform?: NodeJS.Platform;
  readonly isPackaged?: boolean;
  readonly exitCodeFor?: (
    command: RecordedCommand,
  ) => Effect.Effect<ChildProcessSpawner.ExitCode, PlatformError.PlatformError>;
  readonly spawnErrorFor?: (command: RecordedCommand) => PlatformError.PlatformError | undefined;
  readonly commands?: RecordedCommand[];
}) => {
  const commands = input.commands ?? [];
  return DesktopUpstreamRuntimeGuard.assertUpstreamRuntimeStopped().pipe(
    Effect.provide(
      Layer.mergeAll(
        Layer.succeed(
          DesktopEnvironment.DesktopEnvironment,
          DesktopEnvironment.DesktopEnvironment.of({
            platform: input.platform ?? "darwin",
            isPackaged: input.isPackaged ?? true,
          } as DesktopEnvironment.DesktopEnvironment["Service"]),
        ),
        Layer.succeed(
          ChildProcessSpawner.ChildProcessSpawner,
          ChildProcessSpawner.make((rawCommand) => {
            const command = rawCommand as unknown as RecordedCommand;
            commands.push(command);
            const spawnError = input.spawnErrorFor?.(command);
            if (spawnError !== undefined) {
              return Effect.fail(spawnError);
            }
            const defaultExitCode = command.command === "/bin/launchctl" ? 113 : 1;
            return Effect.succeed(
              processHandle(
                input.exitCodeFor?.(command) ??
                  Effect.succeed(ChildProcessSpawner.ExitCode(defaultExitCode)),
              ),
            );
          }),
        ),
      ),
    ),
  );
};

describe("DesktopUpstreamRuntimeGuard", () => {
  it.effect("skips probes outside packaged macOS builds", () => {
    const commands: RecordedCommand[] = [];
    return Effect.gen(function* () {
      yield* runGuard({ platform: "linux", commands });
      yield* runGuard({ isPackaged: false, commands });
      assert.deepEqual(commands, []);
    });
  });

  it.effect("allows startup when the upstream app and service are stopped", () => runGuard({}));

  it.effect("refuses startup while the upstream application is running", () =>
    Effect.gen(function* () {
      const error = yield* runGuard({
        exitCodeFor: ({ command }) =>
          Effect.succeed(ChildProcessSpawner.ExitCode(command === "/usr/bin/pgrep" ? 0 : 113)),
      }).pipe(Effect.flip);

      assert.instanceOf(error, DesktopUpstreamRuntimeGuard.DesktopUpstreamRuntimeConflictError);
      assert.deepEqual(error.conflicts, ["application"]);
    }),
  );

  it.effect("refuses startup while the upstream background service is running", () =>
    Effect.gen(function* () {
      const error = yield* runGuard({
        exitCodeFor: ({ command }) =>
          Effect.succeed(ChildProcessSpawner.ExitCode(command === "/bin/launchctl" ? 0 : 1)),
      }).pipe(Effect.flip);

      assert.instanceOf(error, DesktopUpstreamRuntimeGuard.DesktopUpstreamRuntimeConflictError);
      assert.deepEqual(error.conflicts, ["background-service"]);
    }),
  );

  it.effect("reports both upstream conflicts", () =>
    Effect.gen(function* () {
      const error = yield* runGuard({
        exitCodeFor: () => Effect.succeed(ChildProcessSpawner.ExitCode(0)),
      }).pipe(Effect.flip);

      assert.instanceOf(error, DesktopUpstreamRuntimeGuard.DesktopUpstreamRuntimeConflictError);
      assert.deepEqual(error.conflicts, ["application", "background-service"]);
    }),
  );

  it.effect("fails closed when pgrep returns an error status", () =>
    Effect.gen(function* () {
      const error = yield* runGuard({
        exitCodeFor: ({ command }) =>
          Effect.succeed(ChildProcessSpawner.ExitCode(command === "/usr/bin/pgrep" ? 2 : 113)),
      }).pipe(Effect.flip);

      assert.instanceOf(error, DesktopUpstreamRuntimeGuard.DesktopUpstreamRuntimeProbeError);
      assert.equal(error.probe, "application");
    }),
  );

  it.effect("fails closed when launchctl returns an unexpected status", () =>
    Effect.gen(function* () {
      const error = yield* runGuard({
        exitCodeFor: () => Effect.succeed(ChildProcessSpawner.ExitCode(1)),
      }).pipe(Effect.flip);

      assert.instanceOf(error, DesktopUpstreamRuntimeGuard.DesktopUpstreamRuntimeProbeError);
      assert.equal(error.probe, "background-service");
    }),
  );

  it.effect("fails closed when a probe cannot be spawned", () => {
    const spawnCause = PlatformError.systemError({
      _tag: "PermissionDenied",
      module: "ChildProcessSpawner",
      method: "spawn",
      pathOrDescriptor: "/usr/bin/pgrep",
    });

    return Effect.gen(function* () {
      const error = yield* runGuard({
        spawnErrorFor: ({ command }) => (command === "/usr/bin/pgrep" ? spawnCause : undefined),
      }).pipe(Effect.flip);

      assert.instanceOf(error, DesktopUpstreamRuntimeGuard.DesktopUpstreamRuntimeProbeError);
      assert.equal(error.probe, "application");
      assert.strictEqual(error.cause, spawnCause);
    });
  });

  it.effect("fails closed when a probe times out", () =>
    Effect.gen(function* () {
      const fiber = yield* runGuard({
        exitCodeFor: ({ command }) =>
          command === "/usr/bin/pgrep"
            ? Effect.never
            : Effect.succeed(ChildProcessSpawner.ExitCode(113)),
      }).pipe(Effect.flip, Effect.forkScoped);
      yield* Effect.yieldNow;
      yield* TestClock.adjust("2 seconds");
      const error = yield* Fiber.join(fiber);

      assert.instanceOf(error, DesktopUpstreamRuntimeGuard.DesktopUpstreamRuntimeProbeError);
      assert.equal(error.probe, "application");
    }).pipe(Effect.provide(TestClock.layer())),
  );
});
