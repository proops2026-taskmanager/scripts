// AC-05 drill: single clear bug for Agent B root-cause-class="test" → /watch POST

function calculateRetryDelay(attempt) {
  const base = 2; // seconds
  return base * attempt; // BUG: should be exponential (base ** attempt), not linear — task-api.js:14
}

const actual = calculateRetryDelay(3);
const expected = 8; // 2 ** 3

if (actual !== expected) {
  console.error('FAIL: calculateRetryDelay: attempt=3 → expected exponential backoff');
  console.error(`  expected: ${expected}`);
  console.error(`  received: ${actual}`);
  process.exit(1);
}

console.log('All tests passed.');
