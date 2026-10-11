/**
 * JSON lines, framed the one way every protocol here uses (the driver, sensor
 * plugins, MCP over stdio): a message is one line ending in "\n", and nothing
 * else ends a line.
 *
 * Node's readline also ends a line at U+2028 and U+2029, which
 * JSON.stringify leaves unescaped. Captured text often holds them (a web
 * page's line separators), so a message carrying one would be cut in two.
 * Readers here split on "\n" alone, and writers escape both, so a reader that
 * splits on them too still gets whole messages.
 */

/** Call onLine with each "\n"-terminated line of a readable stream, then onEnd. */
export function eachLine(readable, onLine, onEnd = () => {}) {
  readable.setEncoding('utf8');
  let buffered = '';
  readable.on('data', (chunk) => {
    buffered += chunk;
    let at;
    while ((at = buffered.indexOf('\n')) !== -1) {
      const line = buffered.slice(0, at).replace(/\r$/, '');
      buffered = buffered.slice(at + 1);
      onLine(line);
    }
  });
  readable.on('end', () => {
    if (buffered !== '') onLine(buffered.replace(/\r$/, ''));
    buffered = '';
    onEnd();
  });
}

/** One message as one line: JSON, with U+2028 and U+2029 escaped, and "\n". */
export function jsonLine(value) {
  return `${JSON.stringify(value).replace(/\u2028/g, '\\u2028').replace(/\u2029/g, '\\u2029')}\n`;
}
