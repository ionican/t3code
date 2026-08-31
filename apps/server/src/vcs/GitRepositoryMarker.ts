import * as Duration from "effect/Duration";
import * as Effect from "effect/Effect";
import * as FileSystem from "effect/FileSystem";
import * as Option from "effect/Option";
import * as Path from "effect/Path";

export interface GitRepositoryMarker {
  readonly rootPath: string;
  readonly gitPath: string;
}

/**
 * Find the nearest `.git` file or directory without starting Git in the
 * candidate workspace. Besides avoiding a subprocess for ordinary folders,
 * this keeps Git out of File Provider-backed directories until we know that
 * they are repositories.
 */
export const findGitRepositoryMarker = Effect.fn("findGitRepositoryMarker")(function* (
  cwd: string,
) {
  const fileSystem = yield* FileSystem.FileSystem;
  const path = yield* Path.Path;

  const canonicalCwd = yield* fileSystem.realPath(path.resolve(cwd)).pipe(
    Effect.timeoutOption(Duration.seconds(1)),
    Effect.orElseSucceed(() => Option.none<string>()),
  );
  if (Option.isNone(canonicalCwd)) {
    return undefined;
  }

  let directory = canonicalCwd.value;
  for (;;) {
    const gitPath = path.join(directory, ".git");
    const marker = yield* fileSystem.stat(gitPath).pipe(Effect.option);
    if (Option.isSome(marker)) {
      return { rootPath: directory, gitPath } satisfies GitRepositoryMarker;
    }

    const parent = path.dirname(directory);
    if (parent === directory) {
      return undefined;
    }
    directory = parent;
  }
});
