/**
 * What is never captured (R8), decided before any bytes exist.
 * `cases/exclusion.json` holds every implementation to the same answers.
 */

/** System UI that is never a memory: the lock screen, password and Touch ID prompts, notifications. */
export const SYSTEM_APPS = {
  macos: ['usernotificationcenter', 'securityagent', 'coreautha', 'loginwindow', 'screensaverengine'],
};

/** The capture app's own windows, so it never records itself. */
export const SELF_WINDOWS = ['presence capture'];

/** The user's list: one fragment a line, '#' starts a comment, blank lines skipped, lower-cased. */
export function parseExclusionList(text) {
  return text
    .split('\n')
    .map((line) => line.replace(/#.*/, '').trim().toLowerCase())
    .filter((line) => line.length > 0);
}

/**
 * True when a window must not be captured. An adopter with windows of its own
 * passes them in `selfWindows`, alongside the built-in ones.
 *
 * A user list that exists but cannot be read is not an empty one: the caller
 * captures nothing until it can be read.
 */
export function isExcluded({ app = '', window = '' }, { fragments = [], platform = 'macos', selfWindows = [] } = {}) {
  const appName = app.toLowerCase();
  if ((SYSTEM_APPS[platform] ?? []).includes(appName)) return true;
  const title = window.toLowerCase();
  return [...SELF_WINDOWS, ...selfWindows, ...fragments]
    .some((fragment) => title.includes(fragment) || appName.includes(fragment));
}
