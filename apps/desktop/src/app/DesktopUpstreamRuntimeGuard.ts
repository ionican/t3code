import * as Duration from "effect/Duration";
import * as Effect from "effect/Effect";
import * as Schema from "effect/Schema";
import * as ChildProcess from "effect/unstable/process/ChildProcess";
import * as ChildProcessSpawner from "effect/unstable/process/ChildProcessSpawner";

import * as DesktopEnvironment from "./DesktopEnvironment.ts";

const UPSTREAM_SERVICE_LABEL = "com.t3tools.t3code.service";
const UPSTREAM_PROCESS_PATTERN =
  "/T3 Code( \\((Alpha|Beta|Nightly)\\))?\\.app/Contents/MacOS/T3 Code";
const PROBE_TIMEOUT = Duration.seconds(2);

const DesktopUpstreamRuntimeConflict = Schema.Literals(["application", "background-service"]);
type DesktopUpstreamRuntimeConflict = typeof DesktopUpstreamRuntimeConflict.Type;

export class DesktopUpstreamRuntimeConflictError extends Schema.TaggedErrorClass<DesktopUpstreamRuntimeConflictError>()(
  "DesktopUpstreamRuntimeConflictError",
  {
    conflicts: Schema.Array(DesktopUpstreamRuntimeConflict),
  },
) {
  override get message(): string {
    return `T3 Code Auto uses the existing T3 Code backend. Quit the upstream T3 Code app and turn off its access-when-closed service before starting Auto (${this.conflicts.join(", ")}).`;
  }
}

export class DesktopUpstreamRuntimeProbeError extends Schema.TaggedErrorClass<DesktopUpstreamRuntimeProbeError>()(
  "DesktopUpstreamRuntimeProbeError",
  {
    probe: Schema.String,
    cause: Schema.Defect(),
  },
) {
  override get message(): string {
    return `Could not verify that the upstream T3 Code runtime is stopped (${this.probe}).`;
  }
}

const runProbe = Effect.fn("desktop.upstreamRuntimeGuard.runProbe")(function* (input: {
  readonly name: string;
  readonly command: string;
  readonly args: ReadonlyArray<string>;
  readonly absentExitCodes: ReadonlyArray<number>;
}) {
  const spawner = yield* ChildProcessSpawner.ChildProcessSpawner;
  const exitCode = yield* Effect.scoped(
    Effect.gen(function* () {
      const handle = yield* spawner.spawn(
        ChildProcess.make(input.command, input.args, {
          stdin: "ignore",
          stdout: "ignore",
          stderr: "ignore",
          killSignal: "SIGTERM",
          forceKillAfter: Duration.seconds(1),
        }),
      );
      return yield* handle.exitCode;
    }),
  ).pipe(
    Effect.timeout(PROBE_TIMEOUT),
    Effect.mapError(
      (cause) =>
        new DesktopUpstreamRuntimeProbeError({
          probe: input.name,
          cause,
        }),
    ),
  );
  const numericExitCode = exitCode as unknown as number;
  if (numericExitCode === 0) {
    return true;
  }
  if (input.absentExitCodes.includes(numericExitCode)) {
    return false;
  }
  return yield* new DesktopUpstreamRuntimeProbeError({
    probe: input.name,
    cause: new Error(`${input.command} exited with unexpected status ${numericExitCode}`),
  });
});

export const assertUpstreamRuntimeStopped = Effect.fn("desktop.upstreamRuntimeGuard.assertStopped")(
  function* () {
    const environment = yield* DesktopEnvironment.DesktopEnvironment;
    if (environment.platform !== "darwin" || !environment.isPackaged) {
      return;
    }

    const userId = process.getuid?.();
    if (userId === undefined) {
      return yield* new DesktopUpstreamRuntimeProbeError({
        probe: "user-id",
        cause: new Error("process.getuid is unavailable on macOS"),
      });
    }

    const [applicationRunning, serviceRunning] = yield* Effect.all(
      [
        runProbe({
          name: "application",
          command: "/usr/bin/pgrep",
          args: ["-f", UPSTREAM_PROCESS_PATTERN],
          absentExitCodes: [1],
        }),
        runProbe({
          name: "background-service",
          command: "/bin/launchctl",
          args: ["print", `gui/${userId}/${UPSTREAM_SERVICE_LABEL}`],
          absentExitCodes: [113],
        }),
      ],
      { concurrency: 2 },
    );

    const conflicts: DesktopUpstreamRuntimeConflict[] = [];
    if (applicationRunning) conflicts.push("application");
    if (serviceRunning) conflicts.push("background-service");
    if (conflicts.length > 0) {
      return yield* new DesktopUpstreamRuntimeConflictError({ conflicts });
    }
  },
);
