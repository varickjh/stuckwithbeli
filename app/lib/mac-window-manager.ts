import { execFile } from "node:child_process";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

const tileRankingAppsScript = String.raw`
ObjC.import("ApplicationServices");
ObjC.import("AppKit");
ObjC.import("Foundation");

const systemEvents = Application("System Events");
const currentApp = Application.currentApplication();
currentApp.includeStandardAdditions = true;

function requireAccessibilityPermission() {
    const options = $.NSDictionary.dictionaryWithObjectForKey(
        $.NSNumber.numberWithBool(true),
        $.kAXTrustedCheckOptionPrompt,
    );

    if (!Boolean($.AXIsProcessTrustedWithOptions(options))) {
        throw new Error("AUTO_BELI_ACCESSIBILITY_REQUIRED");
    }
}

function runningProcessNames() {
    return systemEvents.applicationProcesses.name();
}

function focusChromiumLocalhostTab(appName) {
    const browser = Application(appName);
    const windows = browser.windows();

    for (let windowIndex = 0; windowIndex < windows.length; windowIndex += 1) {
        const tabs = windows[windowIndex].tabs();
        for (let tabIndex = 0; tabIndex < tabs.length; tabIndex += 1) {
            const url = tabs[tabIndex].url();
            if (typeof url === "string" && url.includes("localhost")) {
                windows[windowIndex].activeTabIndex = tabIndex + 1;
                windows[windowIndex].index = 1;
                browser.activate();
                return true;
            }
        }
    }

    return false;
}

function focusSafariLocalhostTab() {
    const browser = Application("Safari");
    const windows = browser.windows();

    for (let windowIndex = 0; windowIndex < windows.length; windowIndex += 1) {
        const tabs = windows[windowIndex].tabs();
        for (let tabIndex = 0; tabIndex < tabs.length; tabIndex += 1) {
            const url = tabs[tabIndex].url();
            if (typeof url === "string" && url.includes("localhost")) {
                windows[windowIndex].currentTab = tabs[tabIndex];
                windows[windowIndex].index = 1;
                browser.activate();
                return true;
            }
        }
    }

    return false;
}

function findLocalhostBrowser() {
    const processes = runningProcessNames();
    const chromiumBrowsers = [
        "Google Chrome",
        "Arc",
        "Brave Browser",
        "Microsoft Edge",
    ];

    for (const appName of chromiumBrowsers) {
        if (processes.includes(appName) && focusChromiumLocalhostTab(appName)) {
            return appName;
        }
    }

    if (processes.includes("Safari") && focusSafariLocalhostTab()) {
        return "Safari";
    }

    throw new Error("No open browser tab with a localhost URL was found.");
}

function waitForProcess(processName) {
    for (let attempt = 0; attempt < 50; attempt += 1) {
        const process = systemEvents.applicationProcesses.byName(processName);
        if (process.exists()) return process;
        delay(0.2);
    }

    throw new Error(processName + " did not open.");
}

function mainVisibleFrame() {
    const screen = $.NSScreen.mainScreen;
    const frame = screen.frame;
    const visibleFrame = screen.visibleFrame;

    return {
        left: Number(visibleFrame.origin.x),
        top: Number(
            frame.size.height -
            visibleFrame.origin.y -
            visibleFrame.size.height,
        ),
        width: Number(visibleFrame.size.width),
        height: Number(visibleFrame.size.height),
    };
}

requireAccessibilityPermission();
const browserName = findLocalhostBrowser();
currentApp.doShellScript("/usr/bin/open -a 'iPhone Mirroring'");
const phoneProcess = waitForProcess("iPhone Mirroring");
delay(1);

const visibleFrame = mainVisibleFrame();
const browserProcess = systemEvents.applicationProcesses.byName(browserName);
const browserWindow = browserProcess.windows[0];
const phoneWindow = phoneProcess.windows[0];
const phoneSize = phoneWindow.size();
const gap = 12;
const phoneLeft = visibleFrame.left + visibleFrame.width - phoneSize[0];
const browserWidth = Math.max(
    480,
    phoneLeft - visibleFrame.left - gap,
);

browserProcess.frontmost = true;
browserWindow.position = [visibleFrame.left, visibleFrame.top];
browserWindow.size = [browserWidth, visibleFrame.height];

phoneWindow.position = [phoneLeft, visibleFrame.top];
phoneProcess.frontmost = true;
`;

export class MacWindowManagerError extends Error {
    constructor(
        readonly code: "accessibility_required" | "automation_failed",
        message: string,
    ) {
        super(message);
        this.name = "MacWindowManagerError";
    }
}

export async function openRankingWorkspace() {
    if (process.platform !== "darwin") {
        throw new Error("The ranking workspace requires macOS.");
    }

    try {
        await execFileAsync(
            "/usr/bin/osascript",
            ["-l", "JavaScript", "-e", tileRankingAppsScript],
            { timeout: 20_000 },
        );
    } catch (error) {
        const commandError = error as Error & { stderr?: string };
        const detail = `${commandError.message}\n${commandError.stderr ?? ""}`;

        if (detail.includes("AUTO_BELI_ACCESSIBILITY_REQUIRED")) {
            throw new MacWindowManagerError(
                "accessibility_required",
                "Allow the app running Beli in System Settings → Privacy & Security → Accessibility, then click Continue again.",
            );
        }

        throw new MacWindowManagerError(
            "automation_failed",
            "iPhone Mirroring opened, but macOS could not arrange the windows.",
        );
    }
}
