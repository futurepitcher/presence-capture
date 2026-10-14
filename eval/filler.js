/**
 * Thirty days of ordinary noise around the hand-written days: screen text,
 * activity and speech in everyday words, so a search has to find its answer
 * among tens of thousands of captures. Deterministic from its seed, so every
 * run is over the same store.
 *
 * The words are common ones, as a real day's are. None is what makes an
 * answer distinctive (a name, a product, a place, a number), so the filler
 * competes with the answers the way ordinary text does, and never answers a
 * question itself.
 */

const WORDS = `
  the a an and or but so then also just still very really quite about after again all almost
  always another any around away back because before being below between both came can come
  could day days did different does done down during each early even every few find first
  following found from get give go going good got great had has have help here high home how
  however into its keep kind know large last later least left less let like little long look
  made make many may maybe means might more most much must need never new next nice now number
  off often old once only open other our out over own part people place point put quick rather
  read right same saw say see seem set several should show side since small some something
  sometimes soon start stop such sure take than that their them there these they thing things
  think this those though thought through time today together told too took toward turn under
  until upon use used using want was way well went were what when where which while who why will
  with within without word work world would year yes yet you your page section item list view
  open close window tab button menu file folder settings preferences account profile search
  result results edit copy paste save draft share link note notes message messages reply thread
  inbox archive sent label filter sort column row table chart total value field form input
  status update updated loading done ready pending active recent older newer weekly daily
  morning afternoon evening coffee lunch walk weather sunny cloudy rain light dark music song
  playlist video photo photos album camera map route street park garden kitchen chair desk lamp
`.split(/\s+/).filter(Boolean);

const APPS = [
  ['com.apple.Safari', 'Safari'], ['com.google.Chrome', 'Google Chrome'], ['com.apple.Notes', 'Notes'],
  ['com.apple.mail', 'Mail'], ['com.tinyspeck.slackmacgap', 'Slack'], ['com.apple.finder', 'Finder'],
  ['com.spotify.client', 'Spotify'], ['com.apple.Photos', 'Photos'], ['com.apple.Maps', 'Maps'],
];

/** mulberry32: small, fast, and the same everywhere. */
function prng(seed) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

/**
 * @param {{days: number, perDay: number, end: string, seed: number}} options
 *   `days` days ending on the day of `end`, `perDay` captures each, between
 *   08:00 and 20:00 UTC
 * @returns {{id: string, at: string, type: string, app: string, text: string}[]}
 */
export function filler({ days, perDay, end, seed }) {
  const random = prng(seed);
  const pick = (list) => list[Math.floor(random() * list.length)];
  const sentence = (min, max) => Array.from({ length: min + Math.floor(random() * (max - min + 1)) }, () => pick(WORDS)).join(' ');
  const last = new Date(end);
  last.setUTCHours(0, 0, 0, 0);
  const out = [];
  for (let d = days - 1; d >= 0; d--) {
    const day = new Date(last.getTime() - d * 86_400_000);
    const times = Array.from({ length: perDay }, () => day.getTime() + 8 * 3_600_000 + Math.floor(random() * 12 * 3_600_000)).sort((x, y) => x - y);
    times.forEach((t, i) => {
      const at = new Date(t).toISOString();
      const id = `fill_${day.toISOString().slice(0, 10)}_${i}`;
      const roll = random();
      const [bundle, name] = pick(APPS);
      if (roll < 0.15) {
        out.push({ id, at, type: 'activity', app: bundle, text: JSON.stringify({ app: name, window: sentence(2, 4), state: random() < 0.9 ? 'active' : 'idle' }) });
      } else if (roll < 0.25) {
        out.push({ id, at, type: 'audio_transcript', app: random() < 0.5 ? 'input' : 'output', text: sentence(8, 20) });
      } else {
        out.push({ id, at, type: 'screen_text', app: bundle, text: sentence(12, 40) });
      }
    });
  }
  return out;
}
