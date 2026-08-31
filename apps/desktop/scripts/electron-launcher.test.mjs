import { assert, describe, it } from "vite-plus/test";

import {
  APP_BUNDLE_ID,
  APP_DISPLAY_NAME,
  APP_PROTOCOL_SCHEMES,
  makeDevelopmentLauncherScript,
  resolveElectronBinaryPath,
  resolveLauncherIdentity,
  resolveMacLauncherIconPaths,
  resolveMacLauncherPaths,
} from "./electron-launcher.mjs";

describe("electron development launcher", () => {
  it("resolves isolated identities in both production and development", () => {
    assert.deepEqual(resolveLauncherIdentity(false, "t3code"), {
      displayName: "T3 Code Auto",
      bundleId: "com.codepanda.t3code-auto",
      protocolSchemes: ["t3code-auto"],
    });
    assert.deepEqual(resolveLauncherIdentity(true, "claude-account-failover"), {
      displayName: "T3 Code Auto (Dev)",
      bundleId: "com.codepanda.t3code-auto.dev.claudeaccountfailover",
      protocolSchemes: ["t3code-auto-dev"],
    });
  });

  it("uses the fork identity for its bundle and URL scheme", () => {
    const isDevelopment = Boolean(process.env.VITE_DEV_SERVER_URL);
    assert.equal(APP_DISPLAY_NAME, isDevelopment ? "T3 Code Auto (Dev)" : "T3 Code Auto");
    if (isDevelopment) {
      assert.match(APP_BUNDLE_ID, /^com\.codepanda\.t3code-auto\.dev\.[a-z0-9]+$/);
      assert.deepEqual(APP_PROTOCOL_SCHEMES, ["t3code-auto-dev"]);
    } else {
      assert.equal(APP_BUNDLE_ID, "com.codepanda.t3code-auto");
      assert.deepEqual(APP_PROTOCOL_SCHEMES, ["t3code-auto"]);
    }
  });

  it("uses captured values only as fallbacks for a live runner environment", () => {
    const script = makeDevelopmentLauncherScript({
      electronBinaryPath: "/repo/node_modules/electron/Electron",
      mainEntryPath: "/repo/apps/desktop/dist-electron/main.cjs",
      desktopRoot: "/repo/apps/desktop",
      environment: {
        VITE_DEV_SERVER_URL: "http://127.0.0.1:8526",
        T3CODE_PORT: "16566",
        T3CODE_HOME: "/tmp/t3",
      },
    });

    assert.include(
      script,
      "if [ -z \"${VITE_DEV_SERVER_URL:-}\" ]; then export VITE_DEV_SERVER_URL='http://127.0.0.1:8526'; fi",
    );
    assert.notInclude(script, "\nexport VITE_DEV_SERVER_URL=");
    assert.include(
      script,
      "exec '/repo/node_modules/electron/Electron' --t3code-dev-root='/repo/apps/desktop' '/repo/apps/desktop/dist-electron/main.cjs' \"$@\"",
    );
  });

  it("repairs Electron before loading the package entrypoint", () => {
    const calls = [];
    const electronPath = resolveElectronBinaryPath({
      ensureRuntime: () => {
        calls.push("ensure");
      },
      createRequire: () => (specifier) => {
        calls.push(`require:${specifier}`);
        return "/repo/node_modules/electron/dist/Electron.app/Contents/MacOS/Electron";
      },
      moduleUrl: import.meta.url,
    });

    assert.equal(
      electronPath,
      "/repo/node_modules/electron/dist/Electron.app/Contents/MacOS/Electron",
    );
    assert.deepEqual(calls, ["ensure", "require:electron"]);
  });

  it("keeps the native Electron executable name inside the branded macOS bundle", () => {
    const appBundlePath = `/repo/apps/desktop/.electron-runtime/${APP_DISPLAY_NAME}.app`;
    const paths = resolveMacLauncherPaths(appBundlePath, APP_DISPLAY_NAME);

    assert.equal(paths.launcherExecutableName, `${APP_DISPLAY_NAME} Launcher`);
    assert.equal(
      paths.launcherBinaryPath,
      `${appBundlePath}/Contents/MacOS/${APP_DISPLAY_NAME} Launcher`,
    );
    assert.equal(paths.runtimeElectronBinaryPath, `${appBundlePath}/Contents/MacOS/Electron`);

    const script = makeDevelopmentLauncherScript({
      electronBinaryPath: paths.runtimeElectronBinaryPath,
      mainEntryPath: "/repo/apps/desktop/dist-electron/main.cjs",
      desktopRoot: "/repo/apps/desktop",
      environment: {},
    });
    assert.include(script, `exec '${appBundlePath}/Contents/MacOS/Electron'`);
    assert.notInclude(script, "node_modules/electron");
  });

  it("derives launcher icons from canonical development and production assets", () => {
    const development = resolveMacLauncherIconPaths("/runtime", true);
    const production = resolveMacLauncherIconPaths("/runtime", false);

    assert.match(development.sourceIconPath, /assets\/dev\/blueprint-macos-1024\.png$/);
    assert.equal(development.generatedIconPath, "/runtime/icon-dev.icns");
    assert.match(production.sourceIconPath, /assets\/prod\/black-macos-1024\.png$/);
    assert.equal(production.generatedIconPath, "/runtime/icon-prod.icns");
  });
});
